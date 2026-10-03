import AVFoundation
import Foundation
import Speech
import UIKit
import WatchConnectivity

/// iPhone side of KemoSabe on Apple Watch. A watch request runs through the same
/// AppStore as typed chat, so the selected model, context broker, and approvals
/// apply unchanged, and it appears in the iPhone conversation. Clips are
/// transcribed on this iPhone with on-device recognition and deleted; the reply
/// returns to the watch. Nothing here contacts a server.
@MainActor final class WatchBridge: NSObject, WCSessionDelegate {
    static let shared = WatchBridge()
    private weak var store: AppStore?
    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }
    /// Requests being answered, and the last few results kept in memory for the
    /// watch to collect if a pushed reply doesn't arrive.
    private var running: Set<UUID> = []
    /// A watch request is being answered right now (its reply notification arrives quietly).
    var answeringWatch: Bool { !running.isEmpty }
    private var results: [UUID: WatchLink.Reply] = [:]
    private var resultOrder: [UUID] = []
    private var lease: UIBackgroundTaskIdentifier = .invalid
    /// Runs a spoken command (an animation, a theme, a setting) the way the
    /// iPhone does, so the watch gets the same commands as the phone.
    var onCommand: ((VoiceCommand) -> Void)?
    /// Answers watch requests while the iPhone is locked, from a small working set (see `LockedWatchMode`).
    lazy var locked = LockedWatchMode(folder: { AccountDirectory.currentFolder.appendingPathComponent("watch-locked", isDirectory: true) })

    func start(store: AppStore) {
        guard let session else { return }
        self.store = store
        // A watch request can launch this app in the background while the iPhone
        // is locked, when its protected files can't be read. Load them once the
        // person unlocks instead of leaving a storage alert for the next visit, then
        // bring in what the watch asked while the iPhone was locked. The store is looked up
        // each time, since a sign-in or sign-out can replace it while the app runs.
        NotificationCenter.default.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let store = self?.store, store.failedToLoad { store.retrySave() }
                self?.publishStatus()
            }
        }
        // Record which model answers while locked just before the iPhone locks.
        NotificationCenter.default.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.publishStatus() }
        }
        session.delegate = self
        session.activate()
        // The watch shows and changes the personality too.
        NotificationCenter.default.addObserver(forName: CompanionIdentity.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.publishStatus() }
        }
    }
    /// Answers the watch through the store of the account now open, after a sign-in or sign-out
    /// finished while the app ran.
    func use(_ store: AppStore) {
        self.store = store
        publishStatus()
    }
    /// Tells the watch which model will answer, where it sends requests, and whether
    /// it is ready, with Kemo's palette, the dark app theme, and the reading voice.
    func publishStatus() {
        // Launched in the background while locked, the store hasn't loaded; publishing its
        // empty defaults would reset the watch's model, palette, and name.
        guard let session, session.activationState == .activated, let store, !store.failedToLoad, !locked.isLocked else { return }
        guard session.isPaired, session.isWatchAppInstalled else { return locked.clear(allProfiles: store.state.apiProfiles ?? []) }
        locked.refresh(route: store.modelRoute, apple: store.appleModel, profile: store.activeAPIProfile, allProfiles: store.state.apiProfiles ?? [])
        catchUpAfterUnlock()
        let destination: String? = switch store.modelRoute {
        case .onDevice: store.appleModel == .privateCloud ? "Apple’s Private Cloud Compute" : nil
        case .api: store.activeAPIProfile?.endpoint.host ?? "your server"
        }
        let dark = MobileAppearance.shared.colors(.dark)
        let voice = VoiceCatalog.selected(nil).map {
            WatchLink.Voice(identifier: $0.identifier, language: $0.language, name: $0.name, rate: VoiceCatalog.rate(store.state.speechRate))
        }
        let status = WatchLink.Status(model: store.modelLabel, ready: store.canChat, note: store.canChat ? "" : store.availability,
            destination: destination, palette: .init(store.state.theme),
            theme: .init(background: dark.background, foreground: dark.foreground, accent: dark.accent), voice: voice,
            name: CompanionIdentity.name == CompanionIdentity.defaultName ? nil : CompanionIdentity.name,
            models: [.init(id: WatchLink.ModelChoice.onDevice, title: AppleModel.onDevice.title)]
                // Offered only while the iPhone's system offers it; the watch confirms it with its one line.
                + (store.privateCloudStatus.isAvailable
                   ? [.init(id: WatchLink.ModelChoice.privateCloud, title: AppleModel.privateCloud.title, destination: "Apple’s Private Cloud Compute")] : [])
                + (store.state.apiProfiles ?? []).map { .init(id: $0.id.uuidString, title: $0.name, destination: $0.endpoint.host) },
            selectedModel: store.modelRoute == .api ? store.activeAPIProfile?.id.uuidString
                : store.modelRoute == .onDevice ? (store.appleModel == .privateCloud ? WatchLink.ModelChoice.privateCloud : WatchLink.ModelChoice.onDevice) : nil,
            palettes: ThemeShelf.visible.map { .init($0) },
            personality: CompanionIdentity.personality?.rawValue,
            setUp: Onboarding.finished())
        guard let data = try? WatchLink.encode(status) else { return }
        try? session.updateApplicationContext([WatchLink.statusKey: data])
    }

    // MARK: Answering

    private func handle(_ request: WatchLink.Request) -> WatchLink.Reply {
        switch request {
        case .check(let id):
            if let result = results[id] { return result }
            return running.contains(id) ? .init(id: id, status: .received)
                : .init(id: id, status: .failed, text: "Lost that one. Try again.")
        case .change(let setting):
            return apply(setting)
        case .ask(let ask):
            if let problem = WatchLink.problem(with: ask) { return .init(id: ask.id, status: .failed, text: problem) }
            if let reason = unavailableReason(busy: !running.isEmpty) { return .init(id: ask.id, status: .failed, text: reason) }
            running.insert(ask.id)
            Task { finish(await answer(ask)) }
            return .init(id: ask.id, status: .received)
        }
    }
    /// Applies a setting chosen on the watch, the same way its iPhone control would.
    private func apply(_ setting: WatchLink.Setting) -> WatchLink.Reply {
        let id = UUID()
        // The tone is an account setting, readable while locked; the model and palette live in locked data.
        if case .personality(let raw) = setting {
            CompanionIdentity.setPersonality(raw.flatMap(CompanionPersonality.init(rawValue:)))
            publishStatus()
            return .init(id: id, status: .answered, text: "Done.")
        }
        if locked.isLocked { return .init(id: id, status: .failed, text: "Unlock your iPhone to change this.") }
        guard let store, store.storageError == nil else { return .init(id: id, status: .failed, text: "Open KemoSabe on iPhone.") }
        switch setting {
        case .model(let choice):
            if choice == WatchLink.ModelChoice.onDevice { store.selectAppleModel(.onDevice) }
            else if choice == WatchLink.ModelChoice.privateCloud {
                store.selectAppleModel(.privateCloud)
                if store.appleModel != .privateCloud { return .init(id: id, status: .failed, text: "Private Cloud isn't available.") }
            }
            else if let profile = store.state.apiProfiles?.first(where: { $0.id.uuidString == choice }) {
                // The watch showed where messages go before sending this.
                do { try store.selectAPIProfile(profile) } catch { return .init(id: id, status: .failed, text: error.localizedDescription) }
            } else { return .init(id: id, status: .failed, text: "That model was removed.") }
        case .palette(let themeID):
            guard let theme = (ThemeShelf.visible + (store.state.customThemes ?? [])).first(where: { $0.id == themeID }) else {
                return .init(id: id, status: .failed, text: "That palette isn't available.")
            }
            store.state.theme = theme; store.save(); AccountStore.shared.companionChanged()
        case .personality: break
        }
        publishStatus()
        return .init(id: id, status: .answered, text: "Done.", model: store.modelLabel)
    }
    /// Why the iPhone can't take a request right now, or nil when it can.
    /// Watch-facing lines stay one short line (the owner's instruction, September 25, 2026).
    private func unavailableReason(busy: Bool = false) -> String? {
        guard let store else { return "Open KemoSabe on iPhone." }
        // Everything runs through the account: signed out, nothing answers.
        if AppleAccountSession.shared.needsSignIn { return "Sign in on your iPhone." }
        // KemoSabe's files are readable only while the iPhone is unlocked; a locked
        // request is answered from the small working set instead (`LockedWatchMode`).
        if locked.isLocked { return busy ? "Busy. Try again in a moment." : nil }
        if store.failedToLoad { store.retrySave() }
        guard store.storageError == nil else { return "Open KemoSabe on iPhone." }
        guard store.canChat else { return "Not ready. Open KemoSabe on iPhone." }
        guard !busy, !store.isThinking, !store.working else { return "Busy. Try again in a moment." }
        return nil
    }
    /// Answers Talk to Kemo and Ask Kemo on this iPhone (the Action button, a Control, or Siri) exactly
    /// like a watch request: on-device transcription, the same harness and selected model, and while
    /// locked only the small working set (`LockedWatchMode`). A failed reply carries its one-line reason.
    func answerAnywhere(audio: Data? = nil, text: String? = nil) async -> WatchLink.Reply {
        let ask = audio.map { WatchLink.Ask(audio: $0) } ?? WatchLink.Ask(text: text ?? "")
        if let reason = unavailableReason(busy: !running.isEmpty) { return .init(id: ask.id, status: .failed, text: reason) }
        running.insert(ask.id)
        defer { running.remove(ask.id) }
        return await answer(ask, device: .iPhone)
    }
    private func answer(_ ask: WatchLink.Ask, device: ConversationDevice = .watch) async -> WatchLink.Reply {
        holdBackground()
        defer { releaseBackground() }
        var heard: String?
        var text = ask.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let audio = ask.audio {
            do { heard = try await transcribeClip(audio, surface: device == .watch ? .watch : .talkToKemo); text = heard ?? "" }
            catch {
                // On-device speech may not run while locked either; say so in one line, never silently.
                let message = locked.isLocked ? LockedWatchMode.unlockToAnswer : (error as? WatchBridgeError)?.errorDescription ?? "Couldn't hear that. Try again."
                return .init(id: ask.id, status: .failed, text: message)
            }
        }
        let model = store?.modelLabel ?? ""
        func failed(_ message: String) -> WatchLink.Reply { .init(id: ask.id, status: .failed, text: message, heard: heard, model: model) }
        text = WakeName.stripped(text)
        guard !text.isEmpty else { return failed("Didn't catch that. Try again.") }
        if locked.isLocked {
            // Commands change the iPhone's saved state, which stays locked.
            if ask.capture != true, let command = VoiceCommand.parse(text), command.worksFromWatch { return failed("Unlock your iPhone to do that.") }
            switch await locked.answer(text, capture: ask.capture == true) {
            case .answered(let reply):
                return .init(id: ask.id, status: .answered, text: WatchLink.trimmed(reply), heard: heard,
                             spoken: WatchLink.trimmed(SpeechText.prepared(reply)))
            case .failed(let message): return failed(message)
            }
        }
        if ask.capture == true { text = WatchCapture.request(text) }
        else if let command = VoiceCommand.parse(text), command.worksFromWatch, let onCommand, let store {
            // Commands answer on the iPhone the same way they do when typed there.
            store.appendVisibleMessage(role: "You", text: text)
            let before = store.conversationMessages.count
            onCommand(command)
            try? await Task.sleep(for: .milliseconds(300))
            let said = store.conversationMessages.dropFirst(before).last { $0.role == "KemoSabe" }?.text ?? "Done."
            return .init(id: ask.id, status: .answered, text: said, heard: heard, model: model, spoken: SpeechText.prepared(said))
        }
        // Transcription takes time; the iPhone may have changed since the request arrived.
        if let reason = unavailableReason() { return failed(reason) }
        guard let store else { return failed("Open KemoSabe on iPhone.") }
        let proposals = store.proposalRevision
        store.noteConversationStart(on: device)
        let reply: String? = await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            store.send(text, completion: { once.resume($0) })
            // A cancelled request never completes; the watch must not wait forever.
            Task { try? await Task.sleep(for: .seconds(100)); once.resume(nil) }
        }
        guard let reply, !reply.isEmpty else { return failed("Couldn't finish that. Try again.") }
        // Proposals are review-only and are approved on the iPhone, never from the watch.
        let review = store.proposalRevision != proposals
        return .init(id: ask.id, status: .answered, text: WatchLink.trimmed(reply), heard: heard, model: model,
                     spoken: WatchLink.trimmed(SpeechText.prepared(reply)), review: review ? true : nil)
    }
    /// A finite OS grace period to finish an answer when the watch woke this app.
    private func holdBackground() {
        guard lease == .invalid else { return }
        lease = UIApplication.shared.beginBackgroundTask(withName: "KemoWatchRequest") { [weak self] in
            Task { @MainActor in self?.releaseBackground() }
        }
    }
    private func releaseBackground() {
        if lease != .invalid { UIApplication.shared.endBackgroundTask(lease); lease = .invalid }
    }
    private func finish(_ reply: WatchLink.Reply) {
        running.remove(reply.id)
        results[reply.id] = reply; resultOrder.append(reply.id)
        while resultOrder.count > 8 { results.removeValue(forKey: resultOrder.removeFirst()) }
        // Best effort: the watch also collects the result with a check.
        guard let session, let data = try? WatchLink.encode(reply) else { return }
        let message = [WatchLink.replyKey: data]
        // A live message when the watch is listening, queued delivery otherwise; a message that
        // fails (the watch went to sleep mid-answer) falls back to the queue too.
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil) { _ in
                Task { @MainActor in if session.isWatchAppInstalled { session.transferUserInfo(message) } }
            }
        } else if session.isWatchAppInstalled { session.transferUserInfo(message) }
    }
    /// After unlock: exchanges answered while locked join their conversations, and requests that
    /// waited (notes, reminders, alarms) run through the full harness one at a time.
    private func catchUpAfterUnlock() {
        guard let store, !locked.isLocked, !store.failedToLoad else { return }
        runWaiting(locked.importAnswered(into: store))
    }
    private var runningWaiting = false
    private func runWaiting(_ waiting: [LockedWatchMode.Exchange]) {
        guard let next = waiting.first, !runningWaiting else { return }
        guard let request = next.request else { locked.remove(next); return runWaiting(Array(waiting.dropFirst())) }
        // Busy now; the next unlock or return to the app tries again.
        guard let store, running.isEmpty, store.canChat, !store.isThinking, !store.working else { return }
        runningWaiting = true
        store.noteConversationStart(on: .watch)
        Task {
            let _: String? = await withCheckedContinuation { continuation in
                let once = ResumeOnce(continuation)
                store.send(request, completion: { once.resume($0) })
                // A cancelled request never completes; don't hold the rest forever.
                Task { try? await Task.sleep(for: .seconds(100)); once.resume(nil) }
            }
            locked.remove(next); runningWaiting = false
            runWaiting(Array(waiting.dropFirst()))
        }
    }
    /// Kemo's name and palette names, so they come through instead of sound-alikes.
    private static var hints: [String] { [CompanionIdentity.name, "KemoSabe", "Kemo Sabe", "Kemo", "dance", "wave", "animation", "theme", "remind me", "remember"] + BotTheme.presets.map(\.name) }

    /// The transcription model chosen in Voice settings, or on the device when that's Apple's
    /// (or the cloud one can't be reached). On-device Whisper reads a watch clip only while this
    /// iPhone app is in front and unlocked, alongside Apple's recognizer, and Apple's text stays
    /// if Whisper can't finish in time; Talk to Kemo always uses Apple's recognizer.
    private func transcribeClip(_ audio: Data, surface: WhisperTranscription.Surface) async throws -> String {
        let cloud = CloudVoice.activeTranscriber(in: store)
        if cloud == nil, OnDeviceWhisper.shouldRun(surface) {
            async let whisper = OnDeviceWhisper.outcome(clip: audio, fileExtension: "m4a", surface: surface)
            let apple: Result<String, Error>
            do { apple = .success(try await Self.transcribe(audio)) } catch { apple = .failure(error) }
            let final = WhisperTranscription.finalText(apple: (try? apple.get()) ?? "", outcome: await whisper, names: WhisperTranscription.hintedNames)
            if final.source == .whisper { return final.text }
            return try apple.get()
        }
        if let model = cloud, let store, let key = CloudVoice.key(in: store),
           let heard = try? await OpenAIAudio(key: key).transcribe(audio, fileName: "clip.m4a", model: model), !heard.isEmpty {
            return heard
        }
        return try await Self.transcribe(audio)
    }
    private static func transcribe(_ audio: Data) async throws -> String {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { throw WatchBridgeError.speechPermission }
        if let modern = try? await transcribeWithAnalyzer(audio), !modern.isEmpty { return modern }
        return try await transcribeWithRecognizer(audio)
    }
    /// Apple's newer on-device transcriber, used only when its speech model is
    /// already installed (the iPhone's Voice settings download it). No network.
    private static func transcribeWithAnalyzer(_ audio: Data) async throws -> String? {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else { return nil }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        try audio.write(to: url, options: [.completeFileProtectionUntilFirstUserAuthentication])
        defer { try? FileManager.default.removeItem(at: url) }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let context = AnalysisContext()
        context.contextualStrings[.general] = hints
        try await analyzer.setContext(context)
        let collected = Task {
            var text = ""
            for try await result in transcriber.results where result.isFinal { text += String(result.text.characters) }
            return text
        }
        try await analyzer.start(inputAudioFile: AVAudioFile(forReading: url), finishAfterFile: true)
        return try await collected.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func transcribeWithRecognizer(_ audio: Data) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.supportsOnDeviceRecognition else {
            throw WatchBridgeError.onDeviceSpeechUnavailable
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        try audio.write(to: url, options: [.completeFileProtectionUntilFirstUserAuthentication])
        defer { try? FileManager.default.removeItem(at: url) }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        // The same hints the iPhone's own listening uses, so Kemo's name and
        // palette names come through.
        request.contextualStrings = hints
        return try await withCheckedThrowingContinuation { continuation in
            let once = ThrowingResumeOnce(continuation)
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal { once.resume(.success(result.bestTranscription.formattedString)) }
                else if let error { once.resume(.failure(error)) }
            }
        }
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.publishStatus() }
    }
    /// The watch's pet game numbers, for your profile.
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext[WatchLink.petKey] as? Data,
              let summary = try? WatchLink.decode(WatchLink.PetSummary.self, from: data) else { return }
        Task { @MainActor in
            summary.save()
            NotificationCenter.default.post(name: WatchLink.PetSummary.changed, object: nil)
        }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) { Task { @MainActor in self.publishStatus() } }
    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data, replyHandler: @escaping (Data) -> Void) {
        guard let request = try? WatchLink.decode(WatchLink.Request.self, from: messageData) else {
            replyHandler((try? WatchLink.encode(WatchLink.Reply(id: UUID(), status: .failed, text: "Update KemoSabe on your iPhone and watch, then try again."))) ?? Data())
            return
        }
        Task { @MainActor in replyHandler((try? WatchLink.encode(self.handle(request))) ?? Data()) }
    }
}

/// Quick capture from the watch hands over a note or task. Anything with a time
/// or a to-do becomes a reminder request, everything else something to remember;
/// both go through the same review and permissions as asking on the iPhone.
enum WatchCapture {
    static func request(_ words: String) -> String {
        let text = " " + VoiceTurnPolicy.normalized(words) + " "
        let task = [" remind", " todo ", " to do ", " task", " tomorrow", " today", " tonight", " at ", " by ", " buy ", " call ",
                    " email ", " text ", " pick up ", " book ", " schedule", " pay ", " finish ", " send "].contains { text.contains($0) }
        return task ? "Add this as a reminder: \(words)" : "Remember this: \(words)"
    }
}

extension WatchLink.Palette {
    init(_ theme: BotTheme) {
        // Matches CharacterPlate, which draws only the approved Apricot palette untinted.
        self.init(id: theme.id, name: theme.name, body: theme.body, accent: theme.accent, tinted: theme != BotTheme.presets[0])
    }
}

enum WatchBridgeError: LocalizedError {
    case speechPermission, onDeviceSpeechUnavailable
    var errorDescription: String? {
        switch self {
        case .speechPermission: "Allow speech in KemoSabe on iPhone."
        case .onDeviceSpeechUnavailable: "Speech isn't ready on iPhone."
        }
    }
}

/// Resumes a continuation exactly once, whichever of completion or timeout comes first.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }
    func resume(_ value: T) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(returning: value)
    }
}
private final class ThrowingResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
    func resume(_ result: Result<T, Error>) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(with: result)
    }
}

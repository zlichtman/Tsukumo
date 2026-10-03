import ActivityKit
import AppIntents
import AVFoundation
import Observation
import Speech
import UIKit

/// The app's side of Talk to Kemo (see `TalkToKemoIntent`). A turn runs in this app's process:
///
/// 1. A Live Activity starts first (iOS stops a background recording without one), then the
///    microphone records one clip until the person stops talking (`VoiceEndpointer`).
/// 2. The clip goes through `WatchBridge.answerAnywhere`, the same path as a watch request: on-device
///    transcription (or the cloud transcriber the person opted into), then the selected model through
///    the same harness as typed chat, or, while locked, only `LockedWatchMode`'s working set.
/// 3. The reply is read aloud in the chosen voice, the Live Activity shows it, and it ends.
///
/// One clip, never an open microphone: iOS shows its recording indicator and the Live Activity the
/// whole time, and pressing the Action button or Control again ends listening early. The in-app
/// voice lifecycle gates are unchanged (`VoiceController` stays blocked while a turn runs).
@MainActor @Observable final class VoiceAnywhere: NSObject {
    static let shared = VoiceAnywhere()

    /// Counts requests to open the in-app voice mode; `AssistantShell` answers each one.
    private(set) var inAppRequests = 0
    /// A background turn holds the audio session; the in-app voice waits for it.
    private(set) var running = false
    /// The current turn, for the Live Activity.
    private(set) var machine = VoiceAnywhereMachine()

    @ObservationIgnored private var pendingInApp = false
    @ObservationIgnored private weak var store: AppStore?
    @ObservationIgnored private var activity: Activity<KemoVoiceAttributes>?
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var recordingURL: URL?
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var turnTask: Task<Void, Never>?
    @ObservationIgnored private var throttle = LiveActivityThrottle()
    @ObservationIgnored private let clock = ContinuousClock()
    @ObservationIgnored private var started = ContinuousClock.now
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var lease: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        synthesizer.delegate = self
        // Siri hears the companion's current name in "Talk to <name> in KemoSabe".
        observers.append(NotificationCenter.default.addObserver(forName: CompanionIdentity.changed, object: nil, queue: .main) { _ in
            KemoAppShortcuts.updateAppShortcutParameters()
        })
    }

    /// The store of the account now open (set at launch and after a sign-in or sign-out).
    func use(_ store: AppStore) { self.store = store }

    // MARK: Routing

    func route() -> VoiceAnywhereRoute {
        let locked = WatchBridge.shared.locked
        return VoiceAnywhereRoute.decide(
            appActive: UIApplication.shared.applicationState == .active,
            microphoneAllowed: AVAudioApplication.shared.recordPermission == .granted,
            speechAllowed: SFSpeechRecognizer.authorizationStatus() == .authorized,
            liveActivitiesAllowed: ActivityAuthorizationInfo().areActivitiesEnabled,
            locked: locked.isLocked, lockedAnswerReady: locked.workingSet != nil)
    }
    /// Asks the app to open Chat with its voice mode listening.
    func requestInApp() { pendingInApp = true; inAppRequests += 1 }
    /// Returns a waiting in-app request once.
    func takeInAppRequest() -> Bool { defer { pendingInApp = false }; return pendingInApp }

    // MARK: A background turn

    /// Starts listening with Kemo in a Live Activity. Throws when iOS won't start the Live
    /// Activity or the microphone in the background; the caller then opens the app instead.
    func startBackgroundTurn() async throws {
        if running {
            // A second press: listening ends now and the words go ahead; otherwise it stops.
            if machine.phase == .listening { finishListening() } else { stop() }
            return
        }
        await endStaleActivities()
        machine = VoiceAnywhereMachine(); throttle = LiveActivityThrottle(); started = clock.now
        let content = machine.content
        activity = try Activity.request(attributes: attributes(), content: .init(state: content, staleDate: nil), pushType: nil)
        do {
            try startRecording()
        } catch {
            await endActivity(dismissal: .immediate)
            throw error
        }
        running = true
    }

    /// Stops the turn: listening is discarded, a reply stops being read aloud.
    func stop() {
        guard running else { return }
        if machine.phase == .speaking { stopSpeaking() }
        turnTask?.cancel()
        discardRecording()
        apply(.stop)
        finishTurn()
    }

    private func startRecording() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("talk-" + UUID().uuidString + ".m4a")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000,
                                       AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else { try? session.setActive(false); throw VoiceAnywhereError.microphone }
        self.recorder = recorder; recordingURL = url
        meterTask = Task { [weak self] in
            var endpointer = VoiceEndpointer()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(60))
                guard let self, let recorder = self.recorder else { return }
                recorder.updateMeters()
                let level = Self.level(decibels: recorder.averagePower(forChannel: 0))
                self.apply(.level(level))
                switch endpointer.feed(level: level, at: self.elapsed) {
                case .keepListening: continue
                case .finished: self.finishListening(); return
                case .heardNothing: self.discardRecording(); self.apply(.heardNothing); self.finishTurn(); return
                }
            }
        }
    }
    /// Microphone power in decibels as 0–1, on the same scale as the in-app voice level.
    nonisolated static func level(decibels: Float) -> Double {
        guard decibels.isFinite else { return 0 }
        return min(1, max(0, Double(pow(10, decibels / 20)) * 8))
    }
    private var elapsed: TimeInterval {
        let duration = clock.now - started
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// Ends listening and sends what was heard to the harness.
    private func finishListening() {
        guard machine.phase == .listening else { return }
        meterTask?.cancel(); meterTask = nil
        recorder?.stop(); recorder = nil
        let url = recordingURL; recordingURL = nil
        let audio = url.flatMap { try? Data(contentsOf: $0) }
        if let url { try? FileManager.default.removeItem(at: url) }
        guard let audio, !audio.isEmpty else { apply(.heardNothing); finishTurn(); return }
        apply(.transcribing)
        holdBackground()
        turnTask = Task { [weak self] in
            let reply = await WatchBridge.shared.answerAnywhere(audio: audio)
            guard let self, !Task.isCancelled, self.running else { return }
            self.releaseBackground()
            switch reply.status {
            case .answered:
                self.apply(.answered(reply: reply.text, heard: reply.heard))
                if self.machine.phase == .speaking { self.speak(reply.spoken ?? reply.text) } else { self.finishTurn() }
            case .failed, .received:
                self.apply(.failed(VoiceAnywhereText.phoneLine(reply.text.isEmpty ? VoiceAnywhereText.lost : reply.text)))
                self.finishTurn()
            }
        }
    }
    private func discardRecording() {
        meterTask?.cancel(); meterTask = nil
        recorder?.stop(); recorder?.deleteRecording(); recorder = nil
        if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
        recordingURL = nil
    }
    private func finishTurn() {
        releaseBackground()
        running = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        // The reply stays readable on the Lock Screen for a while; a failure goes sooner.
        let dismissal: ActivityUIDismissalPolicy = machine.phase == .answered ? .after(.now + 120) : .after(.now + 20)
        Task { await endActivity(dismissal: dismissal) }
    }

    // MARK: Speaking

    private func speak(_ text: String) {
        let state = store?.state
        let utterance = VoiceCatalog.utterance(for: text, voiceID: nil, rate: state?.speechRate)
        if let voice = CloudVoice.activeVoice(in: store), let store, let key = CloudVoice.key(in: store) {
            // The OpenAI voice the person opted into; the Apple voice if it can't be fetched.
            turnTask = Task { [weak self] in
                let audio = try? await OpenAIAudio(key: key).speech(SpeechText.prepared(text), voice: voice)
                guard let self, !Task.isCancelled, self.running, self.machine.phase == .speaking else { return }
                if let audio, let player = try? AVAudioPlayer(data: audio) {
                    player.delegate = self; player.isMeteringEnabled = true
                    self.player = player; player.play(); self.animatePlayer()
                } else { self.synthesizer.speak(utterance) }
            }
        } else {
            synthesizer.speak(utterance)
        }
    }
    /// A cloud voice has no word callbacks; its loudness moves the mouth instead.
    private func animatePlayer() {
        meterTask = Task { [weak self] in
            var open = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                guard let self, let player = self.player, player.isPlaying else { return }
                player.updateMeters()
                let loud = Self.level(decibels: player.averagePower(forChannel: 0)) > 0.25
                if loud != open { open = loud; self.apply(.word) }
            }
        }
    }
    private func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
        meterTask?.cancel(); meterTask = nil
        player?.stop(); player = nil
    }
    private func finishedSpeaking() {
        guard running, machine.phase == .speaking else { return }
        meterTask?.cancel(); meterTask = nil; player = nil
        apply(.finishedSpeaking)
        finishTurn()
    }

    // MARK: Live Activity

    private func apply(_ event: VoiceAnywhereMachine.Event) {
        guard machine.handle(event) else { return }
        publish()
    }
    private func publish() {
        guard activity != nil else { return }
        let now = elapsed
        if throttle.allows(phase: machine.phase, line: machine.line, at: now) {
            flushTask?.cancel(); flushTask = nil
            send(machine.content)
        } else if flushTask == nil {
            // The latest level or mouth goes out when the gap closes.
            let wait = throttle.wait(at: now)
            flushTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard let self, !Task.isCancelled else { return }
                self.flushTask = nil
                self.publish()
            }
        }
    }
    private func send(_ content: KemoVoiceAttributes.ContentState) {
        guard let activity else { return }
        Task { await activity.update(.init(state: content, staleDate: nil)) }
    }
    private func endActivity(dismissal: ActivityUIDismissalPolicy) async {
        flushTask?.cancel(); flushTask = nil
        guard let activity else { return }
        self.activity = nil
        await activity.end(.init(state: machine.content, staleDate: nil), dismissalPolicy: dismissal)
    }
    private func endStaleActivities() async {
        for stale in Activity<KemoVoiceAttributes>.activities { await stale.end(nil, dismissalPolicy: .immediate) }
    }
    private func attributes() -> KemoVoiceAttributes {
        let theme = store.flatMap { $0.failedToLoad ? nil : $0.state.theme } ?? BotTheme.presets[0]
        let dark = MobileAppearance.shared.colors(.dark)
        return KemoVoiceAttributes(name: CompanionIdentity.name, body: theme.body, accent: theme.accent,
                                   tinted: theme != BotTheme.presets[0], background: dark.background,
                                   foreground: dark.foreground, themeAccent: dark.accent)
    }

    // MARK: Background time while thinking (no audio plays then)

    private func holdBackground() {
        guard lease == .invalid else { return }
        lease = UIApplication.shared.beginBackgroundTask(withName: "KemoTalk") { [weak self] in
            Task { @MainActor in self?.releaseBackground() }
        }
    }
    private func releaseBackground() {
        if lease != .invalid { UIApplication.shared.endBackgroundTask(lease); lease = .invalid }
    }
}

#if DEBUG
extension VoiceAnywhere {
    /// `--demo-voice-activity`: plays one scripted turn in the Live Activity (no microphone, no model),
    /// so the Lock Screen and Dynamic Island can be checked in the simulator.
    func demoActivity() async {
        machine = VoiceAnywhereMachine(); throttle = LiveActivityThrottle(); started = ContinuousClock.now
        await endStaleActivities()
        activity = try? Activity.request(attributes: attributes(), content: .init(state: machine.content, staleDate: nil), pushType: nil)
        let pause = { (seconds: Double) in try? await Task.sleep(for: .seconds(seconds)) }
        await pause(6)
        for step in 0..<16 { apply(.level(0.35 + 0.35 * sin(Double(step)))); await pause(0.4) }
        apply(.transcribing); await pause(5)
        apply(.answered(reply: "You have two meetings today: the design review at 10 and lunch with Sam at 12:30.", heard: "What's on my calendar today?"))
        for _ in 0..<24 { apply(.word); await pause(0.3) }
        apply(.finishedSpeaking)
        await endActivity(dismissal: .after(.now + 600))
    }
}
#endif

extension VoiceAnywhere: AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        Task { @MainActor in self.apply(.word) }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishedSpeaking() }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishedSpeaking() }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.finishedSpeaking() }
    }
}

enum VoiceAnywhereError: LocalizedError {
    case microphone
    var errorDescription: String? { "The microphone couldn't start." }
}

/// The app's implementation behind the shared intents (the widget extension has an inert one).
enum VoiceAnywhereHost {
    static var companionName: String {
        let name = CompanionIdentity.name
        return name
    }
    @MainActor static func talk(_ intent: TalkToKemoIntent) async throws {
        let anywhere = VoiceAnywhere.shared
        switch anywhere.route() {
        case .background:
            do { try await anywhere.startBackgroundTurn(); return }
            catch {
                // iOS refused to record from the background here; KemoSabe opens listening instead.
                try await openInApp(intent, dialog: nil)
            }
        case .inApp:
            try await openInApp(intent, dialog: nil)
        case .openToAllow:
            try await openInApp(intent, dialog: "Open KemoSabe to allow the microphone and speech recognition.")
        case .unlockFirst:
            try await openInApp(intent, dialog: IntentDialog(stringLiteral: VoiceAnywhereText.unlock))
        }
    }
    @MainActor private static func openInApp(_ intent: TalkToKemoIntent, dialog: IntentDialog?) async throws {
        VoiceAnywhere.shared.requestInApp()
        let mode = intent.systemContext.currentMode
        guard mode != .foreground, mode.canContinueInForeground else { return }
        try await intent.continueInForeground(dialog, alwaysConfirm: false)
    }
    static func stop() async { await MainActor.run { VoiceAnywhere.shared.stop() } }
}

/// "Ask KemoSabe": Siri asks what you'd like to know, and the answer comes back through the same
/// harness (and, while locked, the same working set) as every other request. Siri shows and reads
/// the answer; in Shortcuts it's the action's output.
struct AskKemoIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask KemoSabe"
    static let description = IntentDescription("Ask KemoSabe a question and get the answer from your model.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Question", requestValueDialog: "What would you like to ask?")
    var question: String

    init() {}

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let reply = await WatchBridge.shared.answerAnywhere(text: question)
        let text = reply.status == .answered ? reply.text : VoiceAnywhereText.phoneLine(reply.text.isEmpty ? VoiceAnywhereText.lost : reply.text)
        return .result(value: text, dialog: IntentDialog(stringLiteral: reply.spoken ?? text))
    }
}

/// Siri phrases. Each phrase must name the app; the companion's own name comes in as a parameter.
struct KemoAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TalkToKemoIntent(), phrases: [
            "Talk to \(.applicationName)", "Talk with \(.applicationName)", "Start talking to \(.applicationName)",
            "Talk to \(\.$companion) in \(.applicationName)", "Talk to \(\.$companion) on \(.applicationName)"
        ], shortTitle: "Talk to KemoSabe", systemImageName: "mic.fill")
        AppShortcut(intent: AskKemoIntent(), phrases: [
            "Ask \(.applicationName)", "Ask \(.applicationName) a question", "Ask \(.applicationName) something"
        ], shortTitle: "Ask KemoSabe", systemImageName: "bubble.left.and.text.bubble.right")
    }
    static let shortcutTileColor: ShortcutTileColor = .orange
}

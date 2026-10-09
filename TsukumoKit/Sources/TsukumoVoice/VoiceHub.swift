import Foundation
import Observation
import TsukumoCore
#if os(iOS)
import UIKit
#endif

// The app's voice in one place, shared by the iPhone and the Mac (the old app's `SpeechVoices`,
// `VoiceAuto`, and the listening half of `VoiceController` and `MacVoiceInput`): the two better models and
// the one consent that downloads them, what listens and speaks now (always the best this device can run,
// never a menu), each bot's voice, the speaking pace, whether replies are spoken, a turn of listening, and a
// reply being spoken.

/// Always the best this device can run (the owner, September 30, 2026: "no one wants a worse model").
public enum VoiceAuto {
    public struct Device: Equatable, Sendable {
        /// A Metal GPU MLX can use (not the Simulator).
        public var neuralSupported: Bool
        /// iPhone: the app is in front, so the GPU is available. Always true on Mac.
        public var canRunNow: Bool
        public var whisperInstalled: Bool
        public var kokoroInstalled: Bool
        public init(neuralSupported: Bool, canRunNow: Bool = true, whisperInstalled: Bool, kokoroInstalled: Bool) {
            self.neuralSupported = neuralSupported; self.canRunNow = canRunNow
            self.whisperInstalled = whisperInstalled; self.kokoroInstalled = kokoroInstalled
        }
    }
    public enum Listening: Equatable, Sendable { case whisper, apple }
    public enum Speaking: Equatable, Sendable { case kokoro(voice: String), apple(voiceID: String?) }

    /// Whisper on this device once it's downloaded and the device can run it; otherwise Apple's recognizer.
    public static func listening(_ device: Device) -> Listening {
        device.neuralSupported && device.whisperInstalled ? .whisper : .apple
    }
    /// Kokoro in the bot's voice once it's downloaded and can run now; otherwise Apple's best installed voice
    /// closest to it.
    public static func speaking(_ device: Device, voice: KokoroVoices.Voice, apple: [AppleVoices.Option]) -> Speaking {
        if device.neuralSupported, device.canRunNow, device.kokoroInstalled { return .kokoro(voice: voice.id) }
        return .apple(voiceID: AppleVoices.closest(to: voice, in: apple)?.identifier)
    }
    /// The better models this device could run and doesn't have yet. Empty where MLX can't run, since
    /// Apple's models are already the best there.
    public static func missing(_ device: Device) -> [VoiceModelPack] {
        guard device.neuralSupported else { return [] }
        return [device.whisperInstalled ? nil : VoiceModelPack.whisper, device.kokoroInstalled ? nil : VoiceModelPack.kokoro].compactMap { $0 }
    }
}

/// The owner's voice settings on this device (the models are device data, so they don't sync; each bot's
/// voice is on the bot, which does).
public struct VoiceSettings: Codable, Equatable, Sendable {
    /// When you talk to a bot, it answers out loud.
    public var speaksReplies = true
    /// 0.40 to 0.56; 0.48 is natural.
    public var pace = 0.48
    /// The owner agreed once to download the better voice models.
    public var betterModelsAgreed = false
    public static let paceRange: ClosedRange<Double> = 0.40...0.56
    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        speaksReplies = (try? c.decodeIfPresent(Bool.self, forKey: .speaksReplies)) ?? true
        pace = min(Self.paceRange.upperBound, max(Self.paceRange.lowerBound, (try? c.decodeIfPresent(Double.self, forKey: .pace)) ?? 0.48))
        betterModelsAgreed = (try? c.decodeIfPresent(Bool.self, forKey: .betterModelsAgreed)) ?? false
    }
}

/// One line of Settings: what listens or speaks now, and why.
public struct VoiceStatusLine: Equatable, Sendable {
    public let title: String
    public let detail: String
    /// The best model is running (a green check); otherwise a calm secondary line.
    public let best: Bool
}

/// One turn of listening: the live level and words, then the text.
@MainActor @Observable public final class VoiceListener {
    public enum Phase: Equatable, Sendable {
        /// Asking for the microphone, or starting it.
        case starting
        case listening
        /// Whisper is reading what you said.
        case transcribing
        /// The text went to the bot.
        case sent(String)
        case failed(String)
        case cancelled
        public var isLive: Bool { self == .starting || self == .listening || self == .transcribing }
    }
    public let id = UUID()
    /// Who it's for (a bot), or nil for the composer of a chat.
    public let botID: UUID?
    /// Hold to talk: it ends when you let go, not when you pause.
    public private(set) var hold: Bool
    public private(set) var phase: Phase = .starting
    /// 0 to 1, for the meter.
    public private(set) var level: Double = 0
    /// Apple's words so far.
    public private(set) var partial = ""
    public let startedAt: Date

    @ObservationIgnored private var end: EndOfSpeech
    @ObservationIgnored private weak var hub: VoiceHub?
    @ObservationIgnored let capture: any SpeechCapturing
    @ObservationIgnored let onText: @MainActor (String) -> Void
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored let clock: () -> Date

    init(botID: UUID?, hold: Bool, hub: VoiceHub, capture: any SpeechCapturing, clock: @escaping () -> Date, onText: @escaping @MainActor (String) -> Void) {
        self.botID = botID; self.hold = hold; self.hub = hub; self.capture = capture; self.onText = onText; self.clock = clock
        startedAt = clock()
        end = EndOfSpeech(hold: hold, startedAt: startedAt.timeIntervalSinceReferenceDate)
    }

    func begin(hints: [String], keepAudio: Bool) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.capture.start(hints: hints, keepAudio: keepAudio) { [weak self] event in self?.handle(event) }
                guard self.phase == .starting else { self.capture.cancel(); return }
                self.phase = .listening
                self.ticker = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(100))
                        guard let self, self.phase == .listening else { return }
                        self.apply(self.end.decide(at: self.clock().timeIntervalSinceReferenceDate))
                    }
                }
            } catch {
                guard self.phase == .starting else { return }
                self.phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                self.hub?.listenerEnded(self)
            }
        }
    }

    private func handle(_ event: CaptureEvent) {
        guard phase == .listening else { return }
        let now = clock().timeIntervalSinceReferenceDate
        switch event {
        case .level(let db):
            level = EndOfSpeech.meter(db)
            apply(end.level(db, at: now))
        case .partial(let text):
            partial = text
            apply(end.words(text, at: now))
        case .ended:
            // Apple's recognizer stopped on its own; in tap-to-talk that ends the turn once something was said.
            if !hold, end.heardSpeech || !partial.isEmpty { stop() }
        }
    }
    private func apply(_ decision: EndOfSpeech.Decision) {
        switch decision {
        case .keepListening: break
        case .finish: stop()
        case .nothingHeard: fail("Didn’t catch that. Try again.")
        }
    }

    /// Holding turned into tapping, or the other way (the press ended before the hold threshold).
    public func setHold(_ on: Bool) {
        guard hold != on, phase.isLive else { return }
        hold = on
        var fresh = EndOfSpeech(hold: on, startedAt: startedAt.timeIntervalSinceReferenceDate)
        _ = fresh.words(partial, at: clock().timeIntervalSinceReferenceDate)
        end = fresh
    }

    /// Stops listening and sends what was said.
    public func stop() {
        guard phase == .listening || phase == .starting else { return }
        let wasStarting = phase == .starting
        ticker?.cancel()
        phase = .transcribing
        level = 0
        guard !wasStarting else { capture.cancel(); fail("Didn’t catch that. Try again."); return }
        Task { [weak self] in
            guard let self, let hub = self.hub else { return }
            let samples = await self.capture.finish()
            let text = await hub.finalText(apple: self.partial, samples: samples)
            guard self.phase == .transcribing else { return }
            if text.isEmpty { self.fail("Didn’t catch that. Try again."); return }
            self.phase = .sent(text)
            self.onText(text)
            hub.listenerEnded(self)
        }
    }
    /// Stops listening and drops what was said.
    public func cancel() {
        guard phase.isLive else { return }
        ticker?.cancel()
        capture.cancel()
        phase = .cancelled
        level = 0
        hub?.listenerEnded(self)
    }
    private func fail(_ message: String) {
        ticker?.cancel()
        capture.cancel()
        phase = .failed(message)
        level = 0
        hub?.listenerEnded(self)
    }
}

/// Listening and speaking for an app, shared by the iPhone and the Mac.
@MainActor @Observable public final class VoiceHub {
    /// The host may refuse persisted mutations while its store is recovering.
    @ObservationIgnored public var canWrite: @MainActor () -> Bool = { true }
    public let whisper: VoiceModelStore
    public let kokoro: VoiceModelStore
    /// "Mac" or "iPhone", for the words in Settings.
    public let deviceName: String
    public private(set) var settings: VoiceSettings
    /// The turn of listening now (one at a time).
    public private(set) var listener: VoiceListener?
    /// The last turn that ended, for a moment (its bubble says what happened).
    public private(set) var lastListener: VoiceListener?
    /// The bot speaking a reply now.
    public private(set) var speakingBot: UUID?
    /// The voice being previewed in Settings.
    public private(set) var previewing: String?

    @ObservationIgnored let runtime: (any NeuralVoiceRuntime)?
    @ObservationIgnored let makeCapture: @MainActor () -> any SpeechCapturing
    @ObservationIgnored let makeOutput: @MainActor () -> any AudioOutput
    @ObservationIgnored let appleVoices: @MainActor () -> [AppleVoices.Option]
    @ObservationIgnored let makeAppleEngine: @MainActor (String?, Double) -> any SpeechEngine
    @ObservationIgnored let settingsURL: URL?
    @ObservationIgnored public var foreground: @MainActor () -> Bool
    @ObservationIgnored public var clock: () -> Date = Date.init
    @ObservationIgnored private var reply: ReplySpeech?
    @ObservationIgnored private var preview: SpeechQueue?
    @ObservationIgnored private var clearLast: Task<Void, Never>?

    /// `folder` holds the downloaded models (device data, excluded from backup); `settingsURL` the owner's
    /// voice settings. `runtime` is the app's MLX runtime (nil: Apple's recognizer and voices only).
    /// `seeds` are folders where the same pinned models may already be (the old KemoSabe app's).
    public init(folder: URL, settingsURL: URL?, deviceName: String, runtime: (any NeuralVoiceRuntime)?,
                transport: any VoiceModelTransport = URLSessionVoiceModelTransport(), seeds: [URL] = [],
                makeCapture: @escaping @MainActor () -> any SpeechCapturing = { AppleSpeechCapture() },
                makeOutput: @escaping @MainActor () -> any AudioOutput = { AVAudioOutput() },
                appleVoices: @escaping @MainActor () -> [AppleVoices.Option] = { AppleVoices.installed },
                makeAppleEngine: @escaping @MainActor (String?, Double) -> any SpeechEngine = { AppleSpeechEngine(voiceID: $0, pace: $1) },
                foreground: @escaping @MainActor () -> Bool = VoiceHub.appIsInFront) {
        whisper = VoiceModelStore(pack: .whisper, root: folder, transport: transport, seeds: seeds)
        kokoro = VoiceModelStore(pack: .kokoro, root: folder, transport: transport, seeds: seeds)
        self.deviceName = deviceName; self.runtime = runtime; self.settingsURL = settingsURL
        self.makeCapture = makeCapture; self.makeOutput = makeOutput; self.appleVoices = appleVoices
        self.makeAppleEngine = makeAppleEngine; self.foreground = foreground
        settings = settingsURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(VoiceSettings.self, from: $0) } ?? VoiceSettings()
    }

    public static func appIsInFront() -> Bool {
        #if os(iOS)
        UIApplication.shared.applicationState != .background
        #else
        true
        #endif
    }

    // MARK: What listens and speaks

    public var device: VoiceAuto.Device {
        VoiceAuto.Device(neuralSupported: runtime?.isSupported ?? false, canRunNow: foreground(),
                         whisperInstalled: whisper.isInstalled, kokoroInstalled: kokoro.isInstalled)
    }
    public var listening: VoiceAuto.Listening { VoiceAuto.listening(device) }
    public func speaking(for bot: BotSpec) -> VoiceAuto.Speaking {
        VoiceAuto.speaking(device, voice: KokoroVoices.voice(for: bot), apple: appleVoices())
    }
    /// The better models this device could run and doesn't have yet.
    public var missing: [VoiceModelPack] { VoiceAuto.missing(device) }
    /// One download consent shows while a better model could run here and the owner hasn't agreed.
    public var offersDownload: Bool { !missing.isEmpty && !settings.betterModelsAgreed }
    public var hasBetterModels: Bool { whisper.isInstalled || kokoro.isInstalled || whisper.state.isBusy || kokoro.state.isBusy }

    /// "Whisper on this Mac", or Apple's recognizer and why.
    public var speechIn: VoiceStatusLine {
        if listening == .whisper {
            return VoiceStatusLine(title: "Whisper on this \(deviceName)", detail: "OpenAI’s Whisper large-v3-turbo. What you say never leaves this \(deviceName).", best: true)
        }
        let title = "Apple’s recognizer on this \(deviceName)"
        guard device.neuralSupported else { return VoiceStatusLine(title: title, detail: "The best this \(deviceName) can run.", best: true) }
        return VoiceStatusLine(title: title, detail: Self.progress(whisper, waiting: "Whisper is better; download it below."), best: false)
    }
    /// "Kokoro on this Mac", or Apple's voices and why.
    public var speechOut: VoiceStatusLine {
        if device.neuralSupported, device.kokoroInstalled {
            return VoiceStatusLine(title: "Kokoro on this \(deviceName)", detail: "Each bot speaks in its own voice, made on this \(deviceName).", best: true)
        }
        let best = appleVoices().first
        let title = "Apple’s voices on this \(deviceName)"
        let quality = best.map { "Apple’s \($0.quality.title) voices" } ?? "Apple’s voices"
        guard device.neuralSupported else { return VoiceStatusLine(title: title, detail: "\(quality), the best this \(deviceName) can run.", best: true) }
        return VoiceStatusLine(title: title, detail: Self.progress(kokoro, waiting: "Kokoro sounds more natural; download it below."), best: false)
    }
    static func progress(_ store: VoiceModelStore, waiting: String) -> String {
        switch store.state {
        case .downloading(let fraction): "\(store.pack.title): downloading \(Int((fraction * 100).rounded()))%"
        case .waitingForWiFi: "\(store.pack.title): waiting for Wi-Fi"
        case .verifying: "\(store.pack.title): checking the download"
        case .failed(let reason): "\(store.pack.title) didn’t download. \(reason)"
        case .installed, .notDownloaded: waiting
        }
    }

    // MARK: Settings

    public func setSpeaksReplies(_ on: Bool) {
        guard canWrite() else { return }
        settings.speaksReplies = on; save(); if !on { stopSpeaking() }
    }
    public func setPace(_ pace: Double) {
        guard canWrite() else { return }
        settings.pace = min(VoiceSettings.paceRange.upperBound, max(VoiceSettings.paceRange.lowerBound, pace)); save()
    }
    private func save() {
        guard let settingsURL, let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: settingsURL, options: .atomic)
    }

    /// The owner agreed once: download every better model this device can run, in the background, on
    /// Wi-Fi. Nothing is chosen: each is used as soon as it's ready.
    public func downloadBetterModels() {
        guard canWrite() else { return }
        settings.betterModelsAgreed = true; save()
        resumeBetterModels()
    }
    /// At launch and when the app comes forward: finish or start what was agreed to.
    public func resumeBetterModels() {
        guard settings.betterModelsAgreed, device.neuralSupported else { return }
        for store in [whisper, kokoro] where !store.isInstalled && !store.state.isBusy { store.download() }
    }
    /// Removes both models and stops them coming back until the owner agrees again.
    public func removeBetterModels() {
        guard canWrite() else { return }
        settings.betterModelsAgreed = false; save()
        for store in [whisper, kokoro] { store.delete() }
        let runtime = self.runtime
        Task { await runtime?.unload() }
    }

    // MARK: Listening

    /// Starts a turn of listening for a bot (or the composer). A reply being spoken stops first (barge-in);
    /// a turn already listening is stopped and sent. `names` are the bots' names, which the recognizer
    /// expects and Whisper's text is spelled with.
    @discardableResult
    public func listen(to botID: UUID?, hold: Bool = false, names: [String] = [], onText: @escaping @MainActor (String) -> Void) -> VoiceListener {
        stopSpeaking()
        if let listener, listener.phase.isLive { listener.cancel() }
        hints = Self.hints(names)
        let listener = VoiceListener(botID: botID, hold: hold, hub: self, capture: makeCapture(), clock: clock, onText: onText)
        self.listener = listener
        lastListener = nil
        let whisperRuns = WhisperTranscription.shouldRun(conditions)
        if whisperRuns, let runtime { let folder = whisper.folder; Task.detached(priority: .utility) { await runtime.prepareWhisper(folder: folder) } }
        listener.begin(hints: hints, keepAudio: whisperRuns)
        return listener
    }
    @ObservationIgnored private var hints: [String] = []
    static func hints(_ names: [String]) -> [String] {
        (["KemoSabe", "Tsukumo"] + names).reduce(into: [String]()) { list, name in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !list.contains(trimmed) { list.append(trimmed) }
        }
    }
    var conditions: WhisperTranscription.Conditions {
        #if os(iOS)
        let unlocked = UIApplication.shared.isProtectedDataAvailable
        #else
        let unlocked = true
        #endif
        return .init(installed: whisper.isInstalled, supported: runtime?.isSupported ?? false, foreground: foreground(), unlocked: unlocked)
    }
    /// What was said: Whisper's reading of the audio, or Apple's words when Whisper can't run, fails, or
    /// runs long.
    func finalText(apple: String, samples: [Float]) async -> String {
        guard let runtime, !samples.isEmpty else { return WhisperTranscription.finalText(apple: apple, outcome: .skipped).text }
        let folder = whisper.folder
        let final = await WhisperTranscription.select(apple: apple, conditions: conditions, audioSeconds: Double(samples.count) / WhisperAudioInput.sampleRate,
                                                      names: hints) {
            try await runtime.transcribe(samples, whisperFolder: folder)
        }
        return final.text
    }
    func listenerEnded(_ ended: VoiceListener) {
        guard listener === ended else { return }
        listener = nil
        lastListener = ended
        clearLast?.cancel()
        clearLast = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, self?.lastListener === ended else { return }
            self?.lastListener = nil
        }
    }

    // MARK: Speaking

    /// Starts speaking a reply from `bot` (fed as it streams in), when replies are spoken and the bot may
    /// speak. Returns nil otherwise. A reply already playing stops.
    public func speakReply(from bot: BotSpec) -> ReplySpeech? {
        guard settings.speaksReplies, bot.permissions.speaks else { return nil }
        stopSpeaking()
        let queue = SpeechQueue(engine: engine(for: bot), fallback: { [weak self] in self?.appleEngine(for: bot) ?? AppleSpeechEngine(voiceID: nil, pace: 0.48) },
                                output: makeOutput())
        let reply = ReplySpeech(botID: bot.id, queue: queue)
        queue.onDone = { [weak self, weak reply] in
            guard let self, let reply, self.reply === reply else { return }
            self.reply = nil
            self.speakingBot = nil
        }
        self.reply = reply
        speakingBot = bot.id
        return reply
    }
    /// Stops whatever is being spoken (a reply or a preview).
    public func stopSpeaking() {
        reply?.stop(); reply = nil; speakingBot = nil
        preview?.stop(); preview = nil; previewing = nil
    }
    /// Plays a short line in a voice (Settings and the bot editors); again stops it.
    public func preview(_ voice: KokoroVoices.Voice, for bot: BotSpec) {
        if previewing == voice.id { stopSpeaking(); return }
        stopSpeaking()
        var sample = bot
        sample.voice = voice.id
        let queue = SpeechQueue(engine: engine(for: sample), fallback: { [weak self] in self?.appleEngine(for: sample) ?? AppleSpeechEngine(voiceID: nil, pace: 0.48) },
                                output: makeOutput())
        queue.onDone = { [weak self, weak queue] in
            guard let self, let queue, self.preview === queue else { return }
            self.preview = nil; self.previewing = nil
        }
        preview = queue
        previewing = voice.id
        queue.append("Hi, I’m \(bot.name). This is how I sound.")
        queue.finish()
    }

    /// The best voice for a bot now.
    public func engine(for bot: BotSpec) -> any SpeechEngine {
        switch speaking(for: bot) {
        case .kokoro(let voice):
            guard let runtime else { return appleEngine(for: bot) }
            return KokoroSpeechEngine(runtime: runtime, folder: kokoro.folder, voice: voice, pace: settings.pace)
        case .apple(let voiceID):
            return makeAppleEngine(voiceID, settings.pace)
        }
    }
    func appleEngine(for bot: BotSpec) -> any SpeechEngine {
        makeAppleEngine(AppleVoices.closest(to: KokoroVoices.voice(for: bot), in: appleVoices())?.identifier, settings.pace)
    }
}

/// The words both apps' Voice settings use, so the iPhone's and the Mac's say the same (AGENTS.md rule 9).
public enum VoiceCopy {
    /// The cards, in order.
    public static let listening = "Listening", speaking = "Speaking", models = "Better voice models", voices = "Voices", talking = "Talking to a bot"
    public static let speakReplies = "Speak replies"
    public static let speakRepliesDetail = "When you talk to a bot, it answers out loud in its own voice."
    public static let pace = "Speaking pace"
    public static let download = "Download better voice models"
    public static func downloadDetail(device: String) -> String {
        "Whisper for listening and Kokoro for speaking, \(VoiceModelPack.betterSizeLabel) in all, kept and run only on this \(device)."
    }
    public static let consentTitle = "Download better voice models?"
    public static func consentMessage(device: String) -> String {
        "Whisper (listening) and Kokoro (speaking), \(VoiceModelPack.betterSizeLabel) from Hugging Face, pinned and checked file by file. They stay and run on this \(device); nothing you say or hear is sent anywhere. They download in the background on Wi-Fi and are used as soon as they’re ready."
    }
    public static let remove = "Remove voice models"
    public static let removeTitle = "Remove the voice models?"
    public static func removeMessage(device: String) -> String {
        "Apple’s recognizer and voices take over on this \(device). You can download them again here."
    }
    public static func installed(device: String) -> String { "Whisper and Kokoro are on this \(device)." }
    public static func unsupported(device: String) -> String { "This \(device) already uses the best it can run: Apple’s on-device recognizer and voices." }
    public static let voicesFooter = "Each bot speaks in its own voice. Change it in the bot’s editor, under Voice."
    public static let footer = "Always the best this device can run, with no model to choose."
}

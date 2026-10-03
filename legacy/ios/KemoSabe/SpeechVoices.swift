import Foundation
import AVFoundation
import Observation

/// The app's voice models in one place: the on-device downloads (Kokoro, Whisper, and the Your voice
/// model), the person's own voice, which voice the companion sounds like, and what speaks and listens
/// now, always the best this device can run (`VoiceAuto`). Shared by the iPhone and the Mac.
@MainActor @Observable final class SpeechVoices {
    static let shared = SpeechVoices()
    let kokoro: VoiceModelStore
    let pocket: VoiceModelStore
    /// On-device Whisper for transcription, downloaded the same way.
    let whisper: VoiceModelStore
    let own: OwnVoiceStore
    /// Mirrors the saved voice so views update when it changes.
    private(set) var persona: VoicePersona
    /// Whether the person agreed to download the better voice models (a device setting: they're
    /// device data). Once agreed, they download in the background on Wi-Fi and stay up to date.
    private(set) var betterModelsAgreed: Bool

    init(kokoro: VoiceModelStore? = nil, pocket: VoiceModelStore? = nil, own: OwnVoiceStore? = nil, whisper: VoiceModelStore? = nil,
         defaults: UserDefaults = .standard) {
        self.kokoro = kokoro ?? VoiceModelStore(pack: .kokoro)
        self.pocket = pocket ?? VoiceModelStore(pack: .pocketTTS)
        self.whisper = whisper ?? VoiceModelStore(pack: .whisper)
        self.own = own ?? OwnVoiceStore()
        self.defaults = defaults
        persona = VoicePersona.current
        betterModelsAgreed = defaults.bool(forKey: Self.betterModelsKey)
        wifiOnly = defaults.object(forKey: Self.wifiOnlyKey) as? Bool ?? true
        self.kokoro.wifiOnly = wifiOnly; self.pocket.wifiOnly = wifiOnly; self.whisper.wifiOnly = wifiOnly
        NeuralSpeechRuntime.watchMemory()
        // The voice chosen on another device arrives with the account's settings.
        settingsObserver = NotificationCenter.default.addObserver(forName: AccountSettingsAdapter.didApply, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.persona = VoicePersona.current }
        }
    }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var settingsObserver: NSObjectProtocol?

    /// Voice model downloads wait for Wi-Fi (no cellular, Personal Hotspot, or Low Data Mode).
    /// On by default; a device setting, since the models are device data. "Use cellular this time"
    /// on a waiting download is the only way past it.
    static let wifiOnlyKey = "kemo.voice.downloadsWiFiOnly"
    static let betterModelsKey = "kemo.voice.betterModelsAgreed"
    var wifiOnly: Bool {
        didSet {
            defaults.set(wifiOnly, forKey: Self.wifiOnlyKey)
            kokoro.wifiOnly = wifiOnly; pocket.wifiOnly = wifiOnly; whisper.wifiOnly = wifiOnly
        }
    }

    /// The one voice choice: which voice the companion sounds like.
    func choose(_ persona: VoicePersona) {
        VoicePersona.current = persona; self.persona = persona
    }
    /// Re-reads the saved voice (after an account switch or sync) and what's on the device.
    func reload() {
        persona = VoicePersona.current
        kokoro.refresh(); pocket.refresh(); whisper.refresh(); own.reload()
    }

    // MARK: Always the best this device can run

    /// What this device has and can run now. Ready also means the app is in front, since the GPU
    /// isn't available to it in the background.
    var device: VoiceAuto.Device {
        .init(neuralSupported: NeuralSpeechRuntime.isSupported, canRunNow: NeuralSpeechRuntime.canRunNow,
              whisperInstalled: whisper.isInstalled, kokoroInstalled: kokoro.isInstalled, ownVoiceReady: pocket.isInstalled && own.isEnrolled)
    }
    /// What speaks a reply now: the OpenAI voice when it's opted into and connected, otherwise automatic.
    func route(openAIVoice: String? = nil) -> SpeechRouting.Route { VoiceAuto.speaking(device, persona: persona, openAIVoice: openAIVoice) }
    /// What reads what you say now.
    func listening(openAI: CloudVoice.Transcriber? = nil) -> VoiceAuto.Listening { VoiceAuto.listening(device, openAI: openAI) }
    /// The better models this device could run and doesn't have yet.
    var missing: [VoiceModelPack] { VoiceAuto.missing(device) }
    private var betterStores: [VoiceModelStore] { [whisper, kokoro] }

    /// The person agreed once: download every better model this device can run, on Wi-Fi, in the
    /// background. Nothing is chosen: each is used as soon as it's ready.
    func downloadBetterModels() {
        betterModelsAgreed = true; defaults.set(true, forKey: Self.betterModelsKey)
        resumeBetterModels()
    }
    /// At launch and when the app comes forward: finish or start what was agreed to. Never in tests.
    func resumeBetterModels() {
        guard betterModelsAgreed, NeuralSpeechRuntime.isSupported, !AccountDirectory.isTestHost else { return }
        for store in betterStores where !store.isInstalled && !store.state.isBusy { store.download() }
    }
    /// Removes the downloaded Kokoro and Whisper models and stops downloading them again, until the
    /// person agrees once more. Apple's voice and recognizer take over.
    func removeBetterModels() {
        betterModelsAgreed = false; defaults.set(false, forKey: Self.betterModelsKey)
        for store in betterStores { store.cancel(); if store.isInstalled { store.delete() } }
        Task { await NeuralSpeechWorker.shared.unload(); await WhisperWorker.shared.unload() }
    }

    /// The engine behind a route. Apple is always available as the fallback.
    func engine(for route: SpeechRouting.Route, appleRate: Double?, openAIKey: String? = nil) -> any SpeechEngine {
        switch route {
        case .apple: AppleSpeechEngine(rate: appleRate)
        case .openAI: OpenAISpeechEngine(key: openAIKey)
        case .kokoro: KokoroSpeechEngine(store: kokoro, speed: Self.kokoroSpeed(appleRate))
        case .ownVoice: OwnVoiceSpeechEngine(store: pocket, voice: own)
        }
    }
    /// Maps the Speaking pace slider (0.40–0.56, natural 0.48) onto Kokoro's speed.
    static func kokoroSpeed(_ rate: Double?) -> Float { Float(1 + ((rate ?? 0.48) - 0.48) * 3) }
}

/// Plays an engine's speech a sentence at a time: while one sentence plays, the next is being
/// made, so a long reply starts speaking quickly. `onFinish` runs once, with the error and the
/// sentences not yet spoken if the engine failed, so the caller can fall back to Apple.
@MainActor final class SpeechPlayer: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var task: Task<Void, Never>?
    private var finished: CheckedContinuation<Void, Error>?
    private(set) var isPlaying = false

    func play(_ text: String, engine: any SpeechEngine, voice: String?,
              onFinish: @escaping @MainActor (_ error: Error?, _ unspoken: [String]) -> Void) {
        stop()
        let chunks = SpeechChunks.sentences(SpeechText.prepared(text))
        guard !chunks.isEmpty else { onFinish(nil, []); return }
        isPlaying = true
        task = Task { @MainActor [weak self] in
            var spoken = 0
            var next: Task<SpeechAudio, Error>? = Task { @MainActor in try await engine.synthesize(chunks[0], voice: voice) }
            do {
                for index in chunks.indices {
                    guard let pending = next else { break }
                    let audio = try await pending.value
                    try Task.checkCancellation()
                    next = index + 1 < chunks.count ? Task { @MainActor in try await engine.synthesize(chunks[index + 1], voice: voice) } : nil
                    try await self?.playAndWait(audio)
                    spoken = index + 1
                }
                self?.isPlaying = false
                if !Task.isCancelled { onFinish(nil, []) }
            } catch {
                next?.cancel()
                self?.isPlaying = false
                guard !(error is CancellationError), !Task.isCancelled else { return }
                onFinish(error, Array(chunks[spoken...]))
            }
        }
    }
    func stop() {
        task?.cancel(); task = nil
        player?.stop(); player = nil; isPlaying = false
        finished?.resume(throwing: CancellationError()); finished = nil
    }
    private func playAndWait(_ audio: SpeechAudio) async throws {
        let player = try AVAudioPlayer(data: audio.playableData())
        player.delegate = self
        self.player = player
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            finished = continuation
            if !player.play() { finished = nil; continuation.resume(throwing: SpeechEngineError.synthesisFailed("playback didn't start")) }
        }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard player === self.player else { return }
            self.player = nil
            let continuation = self.finished; self.finished = nil
            continuation?.resume()
        }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            guard player === self.player else { return }
            self.player = nil
            let continuation = self.finished; self.finished = nil
            continuation?.resume(throwing: error ?? SpeechEngineError.synthesisFailed("audio couldn't be decoded"))
        }
    }
}

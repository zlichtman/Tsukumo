import Foundation
import Metal
import MLX
import MLXAudioCore
import MLXAudioTTS
import HuggingFace
#if os(iOS)
import UIKit
#endif

/// On-device neural voices, run with MLX (mlx-audio-swift) on the GPU: Kokoro-82M for Kemo's
/// read-aloud and Pocket TTS for the person's own voice. Nothing here touches the network; the
/// models come only from `VoiceModelStore`, which checked every file against its pinned SHA-256.
enum NeuralSpeechRuntime {
    /// MLX needs a Metal GPU. The Simulator has none it can use, so these voices stay off there
    /// and the Apple voice speaks.
    static var isSupported: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return MTLCreateSystemDefaultDevice() != nil
        #endif
    }
    /// iOS doesn't let an app use the GPU from the background, so the neural voices only speak
    /// while the app is in front; otherwise the Apple voice does.
    @MainActor static var canRunNow: Bool {
        #if os(iOS)
        return UIApplication.shared.applicationState != .background
        #else
        return true
        #endif
    }
    /// Frees the loaded model when the system is short of memory, and on iPhone when the app
    /// goes to the background. Installed once by `SpeechVoices`.
    @MainActor static func watchMemory() {
        guard !watchingMemory else { return }
        watchingMemory = true
        let unload: @Sendable () -> Void = { Task { await NeuralSpeechWorker.shared.unload() } }
        #if os(iOS)
        for name in [UIApplication.didReceiveMemoryWarningNotification, UIApplication.didEnterBackgroundNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in unload() }
        }
        #else
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler(handler: unload)
        source.resume()
        memorySource = source
        #endif
    }
    @MainActor private static var watchingMemory = false
    #if os(macOS)
    @MainActor private static var memorySource: DispatchSourceMemoryPressure?
    #endif
    /// mlx-audio looks for Kokoro's English G2P in the Hugging Face cache. Points that cache at
    /// this app's backup-excluded VoiceModels folder (never ~/.cache on the Mac) before anything
    /// reads it; `KokoroG2PMirror` fills it from the verified download. Runs once, first.
    static let configureCache: Void = {
        if getenv("HF_HUB_CACHE") == nil {
            setenv("HF_HUB_CACHE", VoiceModelFiles.defaultRoot.appendingPathComponent("huggingface", isDirectory: true).path, 0)
        }
    }()
}

/// Runs one neural voice at a time and keeps at most one model in memory.
actor NeuralSpeechWorker {
    static let shared = NeuralSpeechWorker()
    private var kokoro: (folder: URL, model: KokoroModel)?
    private var pocket: (folder: URL, model: PocketTTSModel)?
    private var prompt: (url: URL, modified: Date, audio: MLXArray)?

    /// Touches MLX only where it can run: without a usable Metal device (the Simulator) even
    /// setting its cache limit stops the process, so this worker does nothing there.
    init() {
        _ = NeuralSpeechRuntime.configureCache
        if NeuralSpeechRuntime.isSupported { Memory.cacheLimit = 64 << 20 }
    }

    func kokoroSamples(_ text: String, voice: String, speed: Float, folder: URL) async throws -> SpeechAudio {
        guard NeuralSpeechRuntime.isSupported else { throw SpeechEngineError.unsupportedHardware }
        // MLX reports its errors as Swift errors inside `withError`, so a failure falls back to
        // the Apple voice instead of stopping the app.
        let (samples, rate) = try await withError {
            let model = try await loadKokoro(folder)
            model.speed = min(1.4, max(0.7, speed))
            var samples: [Float] = []
            for chunk in SpeechChunks.sentences(text, maxCharacters: 280) {
                try Task.checkCancellation()
                let audio = try await model.generate(text: chunk, voice: KokoroVoices.normalized(voice), refAudio: nil, refText: nil, language: "en-us")
                samples.append(contentsOf: audio.asArray(Float.self))
            }
            return (samples, model.sampleRate)
        }
        Memory.clearCache()
        guard !samples.isEmpty else { throw SpeechEngineError.synthesisFailed("no audio") }
        return SpeechAudio(payload: .pcm(samples, sampleRate: rate))
    }

    func ownVoiceSamples(_ text: String, sample: URL, folder: URL) async throws -> SpeechAudio {
        guard NeuralSpeechRuntime.isSupported else { throw SpeechEngineError.unsupportedHardware }
        let (samples, rate) = try await withError {
            let model = try await loadPocket(folder)
            let reference = try referenceAudio(sample, sampleRate: model.sampleRate)
            let audio = try await model.generate(text: text, voice: nil, refAudio: reference, refText: nil, language: nil)
            return (audio.asArray(Float.self), model.sampleRate)
        }
        Memory.clearCache()
        guard !samples.isEmpty else { throw SpeechEngineError.synthesisFailed("no audio") }
        return SpeechAudio(payload: .pcm(samples, sampleRate: rate))
    }

    /// The voice being set up, from its reference in memory ("Hear it" before saving).
    func ownVoiceSamples(_ text: String, reference: [Float], folder: URL) async throws -> SpeechAudio {
        guard NeuralSpeechRuntime.isSupported else { throw SpeechEngineError.unsupportedHardware }
        guard !reference.isEmpty else { throw SpeechEngineError.notEnrolled }
        let (samples, rate) = try await withError {
            let model = try await loadPocket(folder)
            let audio = try await model.generate(text: text, voice: nil, refAudio: MLXArray(reference), refText: nil, language: nil)
            return (audio.asArray(Float.self), model.sampleRate)
        }
        Memory.clearCache()
        guard !samples.isEmpty else { throw SpeechEngineError.synthesisFailed("no audio") }
        return SpeechAudio(payload: .pcm(samples, sampleRate: rate))
    }

    /// Frees the models (on memory pressure, or when the voice is turned off or deleted).
    func unload() {
        guard NeuralSpeechRuntime.isSupported else { return }
        kokoro = nil; pocket = nil; prompt = nil
        Memory.clearCache()
    }

    private func loadKokoro(_ folder: URL) async throws -> KokoroModel {
        if let kokoro, kokoro.folder == folder { return kokoro.model }
        pocket = nil; prompt = nil; Memory.clearCache()
        try KokoroG2PMirror.prepare(from: folder.appendingPathComponent("g2p", isDirectory: true))
        let model = try await KokoroModel.fromModelDirectory(folder.appendingPathComponent("model", isDirectory: true),
                                                             textProcessor: MisakiTextProcessor())
        kokoro = (folder, model)
        return model
    }
    private func loadPocket(_ folder: URL) async throws -> PocketTTSModel {
        if let pocket, pocket.folder == folder { return pocket.model }
        kokoro = nil; Memory.clearCache()
        let model = try await PocketTTSModel.fromModelDirectory(folder.appendingPathComponent("model", isDirectory: true))
        pocket = (folder, model)
        return model
    }
    /// The person's recorded sample as the voice prompt, reused while the file is unchanged.
    private func referenceAudio(_ url: URL, sampleRate: Int) throws -> MLXArray {
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
        if let prompt, prompt.url == url, prompt.modified == modified { return prompt.audio }
        let (_, audio) = try loadAudioArray(from: url, sampleRate: sampleRate)
        prompt = (url, modified, audio)
        return audio
    }
}

/// mlx-audio's English G2P loads its lexicons from the Hugging Face cache folder for
/// `beshkenadze/kitten-tts-g2p`. This copies the verified files there (and the empty config
/// mlx-audio checks for) so it finds them and never downloads anything itself.
enum KokoroG2PMirror {
    static var destination: URL {
        _ = NeuralSpeechRuntime.configureCache
        return HubCache.default.cacheDirectory.appendingPathComponent("mlx-audio", isDirectory: true)
            .appendingPathComponent("beshkenadze_kitten-tts-g2p", isDirectory: true)
    }
    static func prepare(from source: URL, to target: URL = destination) throws {
        let files = FileManager.default
        try files.createDirectory(at: target, withIntermediateDirectories: true)
        guard let pinned = VoiceModelPack.kokoro.sources.first(where: { $0.folder == "g2p" }) else { throw SpeechEngineError.notInstalled }
        for file in pinned.files {
            let from = source.appendingPathComponent(file.path), to = target.appendingPathComponent(file.path)
            let size = (try? files.attributesOfItem(atPath: to.path)[.size] as? NSNumber)?.int64Value
            guard size != file.size else { continue }
            try? files.removeItem(at: to)
            try files.copyItem(at: from, to: to)
        }
        let config = target.appendingPathComponent("config.json")
        if !files.fileExists(atPath: config.path) { try Data("{}".utf8).write(to: config) }
        try? VoiceModelFiles.excludeFromBackup(target)
    }
}

/// Kokoro-82M behind the speech boundary: on this device, after the optional download.
@MainActor final class KokoroSpeechEngine: SpeechEngine {
    let kind = SpeechEngineKind.kokoro
    let destination: String? = nil
    let store: VoiceModelStore
    let speed: Float
    init(store: VoiceModelStore, speed: Float = 1) { self.store = store; self.speed = speed }
    var isAvailable: Bool { store.isInstalled && NeuralSpeechRuntime.isSupported }
    var voices: [SpeechVoiceOption] { KokoroVoices.all.map { .init(id: $0.id, name: $0.name, detail: $0.detail) } }
    func synthesize(_ text: String, voice: String?) async throws -> SpeechAudio {
        guard store.isInstalled else { throw SpeechEngineError.notInstalled }
        guard NeuralSpeechRuntime.canRunNow else { throw SpeechEngineError.inBackground }
        let prepared = SpeechText.prepared(text)
        guard !prepared.isEmpty else { throw SpeechEngineError.emptyText }
        return try await NeuralSpeechWorker.shared.kokoroSamples(prepared, voice: KokoroVoices.normalized(voice), speed: speed, folder: store.folder)
    }
}

/// The person's own voice: Pocket TTS prompted with their recorded sample, on this device only.
@MainActor final class OwnVoiceSpeechEngine: SpeechEngine {
    let kind = SpeechEngineKind.ownVoice
    let destination: String? = nil
    let store: VoiceModelStore
    let voice: OwnVoiceStore
    init(store: VoiceModelStore, voice: OwnVoiceStore) { self.store = store; self.voice = voice }
    var isAvailable: Bool { store.isInstalled && voice.isEnrolled && NeuralSpeechRuntime.isSupported }
    var voices: [SpeechVoiceOption] { voice.isEnrolled ? [.init(id: "own", name: "Your voice", detail: "Cloned on this device")] : [] }
    func synthesize(_ text: String, voice _: String?) async throws -> SpeechAudio {
        guard store.isInstalled else { throw SpeechEngineError.notInstalled }
        guard NeuralSpeechRuntime.canRunNow else { throw SpeechEngineError.inBackground }
        guard let sample = voice.sampleURL else { throw SpeechEngineError.notEnrolled }
        let prepared = SpeechText.prepared(text)
        guard !prepared.isEmpty else { throw SpeechEngineError.emptyText }
        return try await NeuralSpeechWorker.shared.ownVoiceSamples(prepared, sample: sample, folder: store.folder)
    }
}

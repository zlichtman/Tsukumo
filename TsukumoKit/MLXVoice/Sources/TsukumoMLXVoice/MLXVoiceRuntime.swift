import Foundation
import HuggingFace
import Metal
import MLX
import MLXAudioCore
import MLXAudioSTT
import MLXAudioTTS
import TsukumoVoice
#if os(iOS)
import UIKit
#endif

// Whisper and Kokoro on the GPU, ported from the old KemoSabe app (`legacy/ios/KemoSabe/NeuralSpeechEngines.swift`
// and `OnDeviceWhisper.swift`'s `WhisperWorker`). Nothing here touches the network: the models come only
// from TsukumoVoice's `VoiceModelStore`, which checked every file against its pinned SHA-256, and Kokoro's
// G2P files are copied from that verified download into the folder mlx-audio reads, so its own Hugging Face
// downloader is never reached. MLX errors are caught (`withError`), so a model failure becomes a Swift error
// and the Apple voice or recognizer takes over, never a crash.

/// The app's `NeuralVoiceRuntime`: one model loaded at a time, freed on memory pressure.
public final class MLXVoiceRuntime: NeuralVoiceRuntime, @unchecked Sendable {
    /// `cacheFolder` is where mlx-audio may look for Kokoro's G2P (inside the app's voice models folder,
    /// never ~/.cache).
    public init(cacheFolder: URL) {
        Self.configure(cacheFolder)
        Self.watchMemory()
    }

    /// The voice models' and runtime's licenses, bundled with the app (Settings, Models, Voice, Licenses).
    public static var noticeURL: URL? { Bundle.module.url(forResource: "VoiceEngines-NOTICE", withExtension: "txt") }

    /// MLX needs a Metal GPU. The Simulator has none it can use, so these models stay off there.
    public var isSupported: Bool { Self.supported }
    static let supported: Bool = {
        #if targetEnvironment(simulator)
        return false
        #else
        return MTLCreateSystemDefaultDevice() != nil
        #endif
    }()

    public func transcribe(_ samples: [Float], whisperFolder: URL) async throws -> String {
        try await WhisperWorker.shared.transcribe(samples, folder: whisperFolder)
    }
    public func prepareWhisper(folder: URL) async { await WhisperWorker.shared.prepare(folder: folder) }
    public func speak(_ text: String, voice: String, speed: Float, kokoroFolder: URL) async throws -> SpeechAudio {
        try await KokoroWorker.shared.samples(text, voice: voice, speed: speed, folder: kokoroFolder)
    }
    public func unload() async {
        await KokoroWorker.shared.unload()
        await WhisperWorker.shared.unload()
    }

    private static let lock = NSLock()
    private static var configured = false
    /// Points mlx-audio's Hugging Face cache at the app's backup-excluded voice models folder before
    /// anything reads it.
    static func configure(_ folder: URL) {
        lock.lock(); defer { lock.unlock() }
        guard !configured else { return }
        configured = true
        setenv("HF_HUB_CACHE", folder.appendingPathComponent("huggingface", isDirectory: true).path, 1)
        if supported { Memory.cacheLimit = 64 << 20 }
    }
    private static var memorySource: DispatchSourceMemoryPressure?
    /// Frees the models when the system is short of memory, and on iPhone when the app goes to the back.
    static func watchMemory() {
        lock.lock(); defer { lock.unlock() }
        guard memorySource == nil else { return }
        let unload: @Sendable () -> Void = { Task { await KokoroWorker.shared.unload(); await WhisperWorker.shared.unload() } }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler(handler: unload)
        source.resume()
        memorySource = source
        #if os(iOS)
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in unload() }
        #endif
    }
}

/// Kokoro-82M, one sentence at a time.
actor KokoroWorker {
    static let shared = KokoroWorker()
    private var loaded: (folder: URL, model: KokoroModel)?

    func samples(_ text: String, voice: String, speed: Float, folder: URL) async throws -> SpeechAudio {
        guard MLXVoiceRuntime.supported else { throw SpeechEngineError.unsupportedHardware }
        let (samples, rate) = try await withError {
            let model = try await load(folder)
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
        return SpeechAudio(samples: samples, sampleRate: rate)
    }
    func unload() {
        guard MLXVoiceRuntime.supported, loaded != nil else { return }
        loaded = nil
        Memory.clearCache()
    }
    private func load(_ folder: URL) async throws -> KokoroModel {
        if let loaded, loaded.folder == folder { return loaded.model }
        loaded = nil; Memory.clearCache()
        try KokoroG2PMirror.prepare(from: folder.appendingPathComponent("g2p", isDirectory: true))
        let processor = MisakiTextProcessor()
        let model = try await KokoroModel.fromModelDirectory(folder.appendingPathComponent("model", isDirectory: true), textProcessor: processor)
        loaded = (folder, model)
        return model
    }
}

/// mlx-audio's English G2P loads its lexicons from the Hugging Face cache folder for
/// `beshkenadze/kitten-tts-g2p`. This copies the verified files there (and the config mlx-audio checks
/// for), so it finds them and never downloads anything itself.
enum KokoroG2PMirror {
    static var destination: URL {
        HubCache.default.cacheDirectory.appendingPathComponent("mlx-audio", isDirectory: true)
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

/// Whisper large-v3-turbo, greedy, English, kept loaded between turns.
actor WhisperWorker {
    static let shared = WhisperWorker()
    private var loaded: (folder: URL, model: WhisperModel)?

    static let parameters = STTGenerateParameters(maxTokens: 440, temperature: 0, topP: 1, topK: 0, verbose: false,
                                                  language: "en", chunkDuration: 30, minChunkDuration: 0.1)
    enum Failure: Error { case lowMemory }

    func transcribe(_ samples: [Float], folder: URL) async throws -> String {
        guard MLXVoiceRuntime.supported else { throw SpeechEngineError.unsupportedHardware }
        guard samples.count >= Int(WhisperAudioInput.sampleRate / 4) else { return "" }
        try await makeRoom(loaded: loaded?.folder == folder)
        let text = try await withError {
            let model = try await load(folder)
            return model.generate(audio: MLXArray(samples), generationParameters: Self.parameters).text
        }
        Memory.clearCache()
        return text
    }
    func prepare(folder: URL) async {
        guard MLXVoiceRuntime.supported, loaded?.folder != folder, (try? await makeRoom(loaded: false)) != nil else { return }
        _ = try? await withError { try await load(folder) }
    }
    /// Measured in the old app: about 1.9 GB while loading, 1.4 GB once loaded. On iPhone, with less than
    /// that left, the reply voice is unloaded first; if there's still not enough, Apple's text is used
    /// rather than risking the app.
    private func makeRoom(loaded: Bool) async throws {
        #if os(iOS)
        let needed = loaded ? 1_500_000_000 : 2_000_000_000
        guard os_proc_available_memory() < needed else { return }
        await KokoroWorker.shared.unload()
        if os_proc_available_memory() < needed { throw Failure.lowMemory }
        #endif
    }
    func unload() {
        guard MLXVoiceRuntime.supported, loaded != nil else { return }
        loaded = nil
        Memory.clearCache()
    }
    private func load(_ folder: URL) async throws -> WhisperModel {
        if let loaded, loaded.folder == folder { return loaded.model }
        loaded = nil; Memory.clearCache()
        let model = try await WhisperModel.fromDirectory(folder.appendingPathComponent("model", isDirectory: true))
        loaded = (folder, model)
        return model
    }
}

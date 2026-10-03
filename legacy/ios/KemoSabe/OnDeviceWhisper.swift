import Foundation
import AVFoundation
import MLX
import MLXAudioCore
import MLXAudioSTT
import os
#if os(iOS)
import UIKit
#endif

// On-device Whisper (September 26, 2026; automatic since September 30): once it's downloaded and the
// device can run it, it's what listens (`VoiceAuto`), with no choice to make. Apple's recognizer still gives
// the live "Listening…" words and finds the end of what you say; then Whisper reads the same
// audio again, on this device, and its text replaces Apple's before anything is sent or placed
// in the message box. Audio never leaves the device on this path. See design/VOICE-ENGINES.md.

extension VoiceModelPack {
    /// OpenAI's Whisper large-v3-turbo (MIT), 4-bit MLX weights with its own tokenizer files, so
    /// nothing is fetched at load time. Chosen by measurement (design/VOICE-ENGINES.md): the most
    /// accurate of the sizes tried, faster than real time on Apple silicon, and 466 MB.
    static let whisper = VoiceModelPack(id: "whisper-large-v3-turbo", title: "Whisper", version: 1, sources: [
        .init(repository: "mlx-community/whisper-large-v3-turbo-asr-4bit", revision: "321a6ead9f6e0646bc8188a54d2a470e275c6b76",
              license: "MIT (openai/whisper-large-v3-turbo)", folder: "model", files: [
            .init(path: "config.json", size: 1506, sha256: "9135b2ae07e6450a8f4e87ad1124abe970f705d72ea426030f969cb5014b82e9"),
            .init(path: "generation_config.json", size: 3772, sha256: "cce11bfe3aaa6ae9e072ea2637caaec8795e68d9b67e655a5af16ee509681a4c"),
            .init(path: "model.safetensors", size: 463462815, sha256: "45298f6dc48df8c11e0a8d1dc5e0197c688bfa530646fa21f1a0238d2b0ecda3"),
            .init(path: "tokenizer.json", size: 2710337, sha256: "297b13372ac43916285644fb9687add3cc62ee2a1adb60da3dc25cc94c1871fd"),
            .init(path: "tokenizer_config.json", size: 282843, sha256: "844b642c73a91359722f47b35705f7174686df33d252695d8572cf9ac03a6389"),
            .init(path: "special_tokens_map.json", size: 2186, sha256: "baea4ea09372eb4fca86b4e4346139fd73cb807d5087e9de0948e971739c3e74"),
            .init(path: "added_tokens.json", size: 34648, sha256: "3c51f66c4c21f9e126970078f11ae77a78c74aee8df606ee9daba86e467108e0"),
        ]),
    ])
}

/// The rules for when Whisper runs and which text wins. Pure, so they're unit tested.
enum WhisperTranscription {
    /// Where the words came from.
    enum Surface: Equatable, Sendable {
        /// iPhone voice mode (the in-app microphone).
        case voiceMode
        /// The Mac composer's dictation, which fills the message box.
        case dictation
        /// A clip from Apple Watch, answered on the iPhone.
        case watch
        /// Talk to Kemo from the Action button, a Control, or Siri. Always Apple's recognizer.
        case talkToKemo
    }
    struct Conditions: Equatable, Sendable {
        var installed: Bool
        /// A Metal GPU MLX can use (not the Simulator).
        var supported: Bool
        /// iPhone: the app is in front. Always true on Mac.
        var foreground: Bool
        /// iPhone: protected data is readable (the device is unlocked). Always true on Mac.
        var unlocked: Bool
        var surface: Surface
    }
    /// Whisper runs only when downloaded and able to run now. Talk to Kemo, the background, and a
    /// locked iPhone quietly keep Apple's recognizer.
    static func shouldRun(_ conditions: Conditions) -> Bool {
        conditions.installed && conditions.supported && conditions.foreground
            && conditions.unlocked && conditions.surface != .talkToKemo
    }

    enum Outcome: Equatable, Sendable { case transcribed(String), failed, timedOut, skipped }
    enum Source: Equatable, Sendable { case whisper, apple }
    struct Final: Equatable, Sendable {
        let text: String
        let source: Source
    }
    /// Whisper's text when it produced a usable transcript; Apple's otherwise (failure, timeout,
    /// skipped, empty, or a known silence hallucination).
    static func finalText(apple: String, outcome: Outcome, names: [String] = []) -> Final {
        let heard = apple.trimmingCharacters(in: .whitespacesAndNewlines)
        guard case .transcribed(let raw) = outcome else { return Final(text: heard, source: .apple) }
        let text = restoringNames(normalized(raw), apple: heard, names: names)
        guard !text.isEmpty, !looksLikeHallucination(text, apple: heard) else { return Final(text: heard, source: .apple) }
        return Final(text: text, source: .whisper)
    }

    /// Apple's recognizer is given Kemo's name as a hint; Whisper isn't, and hears "KemoSabe" as
    /// "Kimo Saib" or "chemo save". When Apple heard a name and Whisper didn't, the closest one-
    /// to three-word stretch of Whisper's text that sounds like it is spelled as the name.
    static func restoringNames(_ text: String, apple: String, names: [String]) -> String {
        var words = text.split(separator: " ").map(String.init)
        for name in names {
            let target = letters(name)
            guard target.count >= 4, letters(apple).contains(target), !letters(text).contains(target), !words.isEmpty else { continue }
            var best: (range: Range<Int>, score: Double)?
            for start in words.indices {
                for length in 1...3 where start + length <= words.count {
                    let candidate = letters(words[start..<(start + length)].joined())
                    guard !candidate.isEmpty else { continue }
                    let score = Double(editDistance(candidate, target)) / Double(target.count)
                    if score < (best?.score ?? .infinity) { best = (start..<(start + length), score) }
                }
            }
            guard let best, best.score <= 0.4 else { continue }
            let trailing = String(words[best.range.upperBound - 1].reversed().prefix { !$0.isLetter && !$0.isNumber }.reversed())
            let leading = String(words[best.range.lowerBound].prefix { !$0.isLetter && !$0.isNumber })
            words.replaceSubrange(best.range, with: [leading + name + trailing])
        }
        return words.joined(separator: " ")
    }
    private static func letters(_ text: String) -> String { String(text.lowercased().filter { $0.isLetter }) }
    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var previous = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, y) in b.enumerated() { current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (x == y ? 0 : 1)) }
            previous = current
        }
        return previous[b.count]
    }

    /// How long to wait for Whisper before keeping Apple's text: a fixed allowance for a cold
    /// start plus time proportional to the audio, capped so a long turn never stalls.
    static func timeout(forAudioSeconds seconds: Double) -> TimeInterval {
        guard seconds.isFinite, seconds > 0 else { return minimumTimeout }
        return min(maximumTimeout, minimumTimeout + seconds * perAudioSecond)
    }
    static let minimumTimeout: TimeInterval = 3
    static let perAudioSecond: TimeInterval = 0.5
    static let maximumTimeout: TimeInterval = 20

    /// Cleans Whisper's text: drops non-speech tags ("[BLANK_AUDIO]", "(music)"), a leading dash,
    /// and stray whitespace, so what's left is only what was said.
    static func normalized(_ text: String) -> String {
        var result = text.replacingOccurrences(of: #"\[[^\]]{0,40}\]"#, with: " ", options: .regularExpression)
        // "(music)" or "*laughs*" go; a real parenthetical ("(the blue one)") stays.
        let tags = (try? NSRegularExpression(pattern: #"[\(\*][^\)\*]{0,30}[\)\*]"#))?
            .matches(in: result, range: NSRange(result.startIndex..., in: result)) ?? []
        for match in tags.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let inner = result[range].dropFirst().dropLast().lowercased()
            if nonSpeech.contains(where: { inner.contains($0) }) { result.replaceSubrange(range, with: " ") }
        }
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("-") || result.hasPrefix(">>") {
            result = String(result.drop { $0 == "-" || $0 == ">" }).trimmingCharacters(in: .whitespaces)
        }
        return result
    }
    private static let nonSpeech = ["music", "laugh", "applause", "silence", "inaudible", "noise", "sigh", "cough",
                                    "blank", "static", "breath", "clears throat", "background"]

    /// Phrases Whisper is known to produce from silence or noise, and runaway repetition. Kept
    /// only when Apple heard the same thing.
    static func looksLikeHallucination(_ whisper: String, apple: String) -> Bool {
        let bare = whisper.lowercased().components(separatedBy: CharacterSet.letters.union(.whitespaces).inverted).joined()
            .trimmingCharacters(in: .whitespaces)
        if silencePhrases.contains(bare), !apple.lowercased().contains(bare) { return true }
        if !apple.isEmpty, whisper.count > apple.count * 3 + 60 { return true }
        return false
    }
    private static let silencePhrases: Set<String> = ["you", "thank you", "thanks for watching", "thank you for watching",
                                                      "thank you so much for watching", "please subscribe", "bye"]

    /// Runs `work` against a deadline. MLX can't be interrupted mid-pass, so a late result is
    /// simply ignored; the caller has already moved on with Apple's text.
    static func race(timeout: TimeInterval, _ work: @escaping @Sendable () async throws -> String) async -> Outcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            let once = FirstOutcome(continuation)
            Task.detached(priority: .userInitiated) {
                do { once.resume(.transcribed(try await work())) } catch { once.resume(.failed) }
            }
            Task.detached {
                try? await Task.sleep(for: .seconds(max(0, timeout)))
                once.resume(.timedOut)
            }
        }
    }
    /// The whole choice for one utterance: skip when Whisper can't run, otherwise race it
    /// against its timeout and pick the text.
    static func select(apple: String, conditions: Conditions, audioSeconds: Double, timeout: TimeInterval? = nil, names: [String] = [],
                       transcribe: @escaping @Sendable () async throws -> String) async -> Final {
        guard shouldRun(conditions) else { return finalText(apple: apple, outcome: .skipped) }
        let outcome = await race(timeout: timeout ?? self.timeout(forAudioSeconds: audioSeconds), transcribe)
        return finalText(apple: apple, outcome: outcome, names: names)
    }
    /// The names Apple's recognizer is hinted with, which Whisper should spell the same way.
    static var hintedNames: [String] {
        var names = [CompanionIdentity.name, "KemoSabe", "Tsukumo"]
        names.removeAll { $0.isEmpty }
        return names.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }
}

private final class FirstOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<WhisperTranscription.Outcome, Never>?
    init(_ continuation: CheckedContinuation<WhisperTranscription.Outcome, Never>) { self.continuation = continuation }
    func resume(_ outcome: WhisperTranscription.Outcome) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(returning: outcome)
    }
}

/// Whisper's input: 16 kHz mono Float32 samples.
enum WhisperAudioInput {
    static let sampleRate: Double = 16_000
    enum Failure: Error { case format }
    static var format: AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
    }

    /// Captured microphone buffers (any rate, any channel count) as 16 kHz mono. Runs of
    /// buffers with the same format convert together, so a route change mid-turn still works.
    static func monoSamples(from buffers: [AVAudioPCMBuffer]) throws -> [Float] {
        var samples: [Float] = []
        var index = buffers.startIndex
        while index < buffers.endIndex {
            let format = buffers[index].format
            var run: [AVAudioPCMBuffer] = []
            while index < buffers.endIndex, buffers[index].format == format { run.append(buffers[index]); index += 1 }
            samples += try convert(run, from: format)
        }
        return samples
    }
    /// An audio file (the watch's clip, a recording) as 16 kHz mono.
    static func monoSamples(contentsOf url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard file.length > 0, file.length < AVAudioFramePosition(format.sampleRate * 120),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else { throw Failure.format }
        try file.read(into: buffer)
        return try monoSamples(from: [buffer])
    }
    /// A clip received as bytes: written to a temporary file only long enough to decode it, then
    /// deleted before transcription starts. Complete file protection on iPhone (Whisper runs only
    /// while it's unlocked); owner-only permissions on Mac, like the app's other voice files.
    static func monoSamples(fromClip data: Data, fileExtension: String) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-\(UUID().uuidString).\(fileExtension)")
        defer { try? FileManager.default.removeItem(at: url) }
        #if os(iOS)
        try data.write(to: url, options: [.completeFileProtection, .withoutOverwriting])
        #else
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw Failure.format }
        #endif
        return try monoSamples(contentsOf: url)
    }

    private static func convert(_ run: [AVAudioPCMBuffer], from source: AVAudioFormat) throws -> [Float] {
        guard let target = format, source.sampleRate > 0 else { throw Failure.format }
        if source.commonFormat == .pcmFormatFloat32, source.sampleRate == sampleRate, source.channelCount == 1 {
            return run.flatMap { buffer in
                guard let channel = buffer.floatChannelData?[0] else { return [Float]() }
                return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            }
        }
        guard let converter = AVAudioConverter(from: source, to: target) else { throw Failure.format }
        converter.downmix = true
        let frames = run.reduce(0) { $0 + Int($1.frameLength) }
        let capacity = AVAudioFrameCount(Double(frames) * sampleRate / source.sampleRate) + 4096
        var samples: [Float] = []
        samples.reserveCapacity(Int(capacity))
        var next = run.startIndex
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw Failure.format }
            var failure: NSError?
            let status = converter.convert(to: output, error: &failure) { _, state in
                guard next < run.endIndex else { state.pointee = .endOfStream; return nil }
                defer { next += 1 }
                state.pointee = .haveData
                return run[next]
            }
            if let failure { throw failure }
            if let channel = output.floatChannelData?[0], output.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            }
            switch status {
            case .haveData: continue
            case .error: throw Failure.format
            default: return samples
            }
        }
    }
}

/// Runs Whisper on the GPU with MLX and keeps at most one copy loaded. Nothing here touches the
/// network: the model comes only from `VoiceModelStore`, verified against its pinned SHA-256,
/// and the tokenizer files are part of that download.
actor WhisperWorker {
    static let shared = WhisperWorker()
    private var loaded: (folder: URL, model: WhisperModel)?

    init() {
        _ = NeuralSpeechRuntime.configureCache
        if NeuralSpeechRuntime.isSupported { Memory.cacheLimit = 64 << 20 }
    }

    static let parameters = STTGenerateParameters(maxTokens: 440, temperature: 0, topP: 1, topK: 0, verbose: false,
                                                  language: "en", chunkDuration: 30, minChunkDuration: 0.1)

    enum Failure: Error { case lowMemory }

    func transcribe(_ samples: [Float], folder: URL) async throws -> String {
        guard NeuralSpeechRuntime.isSupported else { throw SpeechEngineError.unsupportedHardware }
        guard samples.count >= Int(WhisperAudioInput.sampleRate / 4) else { return "" }
        try await makeRoom(loaded: loaded?.folder == folder)
        let text = try await withError {
            let model = try await load(folder)
            return model.generate(audio: MLXArray(samples), generationParameters: Self.parameters).text
        }
        Memory.clearCache()
        return text
    }
    /// Loads the model ahead of the first utterance, so the first answer isn't a cold start.
    func prepare(folder: URL) async {
        guard NeuralSpeechRuntime.isSupported, loaded?.folder != folder, (try? await makeRoom(loaded: false)) != nil else { return }
        _ = try? await withError { try await load(folder) }
    }
    /// Measured peaks (design/VOICE-ENGINES.md): about 1.9 GB with loading, 1.4 GB more once
    /// loaded. On iPhone, if the app doesn't have that much left, the reply voice's model is
    /// unloaded first; if there's still not enough, Apple's text is used rather than risking
    /// the app being stopped.
    private func makeRoom(loaded: Bool) async throws {
        #if os(iOS)
        let needed = loaded ? 1_500_000_000 : 2_000_000_000
        guard os_proc_available_memory() < needed else { return }
        await NeuralSpeechWorker.shared.unload()
        if os_proc_available_memory() < needed { throw Failure.lowMemory }
        #endif
    }
    func unload() {
        guard NeuralSpeechRuntime.isSupported, loaded != nil else { return }
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

/// The app's entry points for on-device Whisper, shared by the iPhone and the Mac.
@MainActor enum OnDeviceWhisper {
    static var store: VoiceModelStore { SpeechVoices.shared.whisper }
    static var isReady: Bool { store.isInstalled && NeuralSpeechRuntime.isSupported }
    /// The microphone keeps the utterance's audio (in memory only) for re-transcription.
    static var keepsUtteranceAudio: Bool { isReady }

    static func conditions(for surface: WhisperTranscription.Surface) -> WhisperTranscription.Conditions {
        #if os(iOS)
        let app = UIApplication.shared
        let foreground = app.applicationState == .active, unlocked = app.isProtectedDataAvailable
        #else
        let foreground = true, unlocked = true
        #endif
        return .init(installed: store.isInstalled, supported: NeuralSpeechRuntime.isSupported,
                     foreground: foreground, unlocked: unlocked, surface: surface)
    }
    static func shouldRun(_ surface: WhisperTranscription.Surface) -> Bool {
        WhisperTranscription.shouldRun(conditions(for: surface))
    }

    /// The final text for one utterance captured by the microphone: Whisper's, or Apple's when
    /// Whisper can't run, fails, or runs past its timeout. The buffers never touch disk.
    static func finalText(apple: String, buffers: [AVAudioPCMBuffer], surface: WhisperTranscription.Surface) async -> WhisperTranscription.Final {
        let conditions = conditions(for: surface)
        guard WhisperTranscription.shouldRun(conditions), !buffers.isEmpty else {
            return WhisperTranscription.finalText(apple: apple, outcome: .skipped)
        }
        let seconds = buffers.reduce(0.0) { $0 + Double($1.frameLength) / max(1, $1.format.sampleRate) }
        let folder = store.folder
        let pending = UncheckedBuffers(buffers)
        return await WhisperTranscription.select(apple: apple, conditions: conditions, audioSeconds: seconds, names: WhisperTranscription.hintedNames) {
            let samples = try WhisperAudioInput.monoSamples(from: pending.buffers)
            return try await WhisperWorker.shared.transcribe(samples, folder: folder)
        }
    }
    /// Whisper's reading of a recorded clip (the watch), run alongside Apple's recognizer; the
    /// caller picks the text with `WhisperTranscription.finalText`.
    static func outcome(clip: Data, fileExtension: String, surface: WhisperTranscription.Surface) async -> WhisperTranscription.Outcome {
        guard shouldRun(surface), let samples = try? WhisperAudioInput.monoSamples(fromClip: clip, fileExtension: fileExtension) else { return .skipped }
        let folder = store.folder
        return await WhisperTranscription.race(timeout: WhisperTranscription.timeout(forAudioSeconds: Double(samples.count) / WhisperAudioInput.sampleRate)) {
            try await WhisperWorker.shared.transcribe(samples, folder: folder)
        }
    }

    /// For the own-voice passage and consent checks: the recording's text by on-device Whisper,
    /// or nil when Whisper isn't downloaded, can't run now, or doesn't finish in time, so the
    /// caller keeps using Apple's recognizer. Nothing leaves the device.
    static func transcribeRecording(_ url: URL) async -> String? {
        let conditions = conditions(for: .voiceMode)
        guard WhisperTranscription.shouldRun(conditions), let samples = try? WhisperAudioInput.monoSamples(contentsOf: url) else { return nil }
        let folder = store.folder
        let outcome = await WhisperTranscription.race(timeout: WhisperTranscription.timeout(forAudioSeconds: Double(samples.count) / WhisperAudioInput.sampleRate) + 10) {
            try await WhisperWorker.shared.transcribe(samples, folder: folder)
        }
        guard case .transcribed(let text) = outcome else { return nil }
        let cleaned = WhisperTranscription.normalized(text)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Loads the model in the background when listening starts, if it'll be used.
    static func prewarm() {
        guard keepsUtteranceAudio else { return }
        watchMemory()
        let folder = store.folder
        Task.detached(priority: .utility) { await WhisperWorker.shared.prepare(folder: folder) }
    }
    /// Frees the model on memory pressure, and on iPhone when the app goes to the background.
    static func watchMemory() {
        guard !watching else { return }
        watching = true
        let unload: @Sendable () -> Void = { Task { await WhisperWorker.shared.unload() } }
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
    private static var watching = false
    #if os(macOS)
    private static var memorySource: DispatchSourceMemoryPressure?
    #endif
}

/// Captured buffers handed to the conversion task. They're copies nobody else touches.
private struct UncheckedBuffers: @unchecked Sendable {
    let buffers: [AVAudioPCMBuffer]
    init(_ buffers: [AVAudioPCMBuffer]) { self.buffers = buffers }
}

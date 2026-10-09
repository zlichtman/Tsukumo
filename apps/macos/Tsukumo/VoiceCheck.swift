#if DEBUG
import AppKit
import AVFoundation
import Speech
import TsukumoVoice
import TsukumoMLXVoice

// A developer check: `--voice-check <folder>` (DEBUG, with `--ui-testing`) runs the real voice stack on this
// Mac without a microphone and writes `voice-check.json` there, then quits. An Apple voice says a sentence;
// Whisper reads it back; Kokoro says it and Whisper reads that back too; Apple's recognizer reads the same
// audio only if this build is already allowed speech recognition (it never asks). Whisper and Kokoro are
// used where they're already on this Mac (this app's folder, or the old KemoSabe app's, read only); nothing
// is downloaded.

extension TsukumoDelegate {
    func startVoiceCheck() {
        let arguments = CommandLine.arguments
        guard isTesting, let index = arguments.firstIndex(of: "--voice-check"), index + 1 < arguments.count else { return }
        let folder = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        Task { @MainActor in
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let report = await Self.voiceCheck(cache: storage.url("VoiceModels"), into: folder)
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: folder.appendingPathComponent("voice-check.json"))
            }
            NSApp.terminate(nil)
        }
    }

    private static func voiceCheck(cache: URL, into folder: URL) async -> [String: String] {
        var report: [String: String] = [:]
        let sentence = "Remind me to call Sarah at seven thirty tonight."
        report["sentence"] = sentence
        let runtime = MLXVoiceRuntime(cacheFolder: cache)
        report["mlxSupported"] = String(runtime.isSupported)
        func found(_ pack: VoiceModelPack) -> URL? {
            [cache, Storage.oldVoiceModels].map { $0.appendingPathComponent(pack.id) }.first { VoiceModelFiles.isInstalled(pack, at: $0) }
        }
        let whisper = found(.whisper), kokoro = found(.kokoro)
        report["whisperFolder"] = whisper?.path ?? "not on this Mac"
        report["kokoroFolder"] = kokoro?.path ?? "not on this Mac"
        do {
            let best = AppleVoices.installed.first
            report["appleVoice"] = best.map { "\($0.name) (\($0.quality.title))" } ?? "none"
            let spoken = try await AppleSpeechEngine(voiceID: best?.identifier, pace: 0.48).synthesize(sentence)
            report["appleVoiceSeconds"] = String(format: "%.2f", spoken.duration)
            try spoken.wav.write(to: folder.appendingPathComponent("apple-voice.wav"))
            let samples = try resampled(spoken)
            if let whisper {
                let start = Date()
                report["whisperHeardAppleVoice"] = try await runtime.transcribe(samples, whisperFolder: whisper)
                report["whisperColdSeconds"] = String(format: "%.2f", Date().timeIntervalSince(start))
                let warm = Date()
                _ = try await runtime.transcribe(samples, whisperFolder: whisper)
                report["whisperWarmSeconds"] = String(format: "%.2f", Date().timeIntervalSince(warm))
            }
            report["appleRecognizerHeardAppleVoice"] = await appleRecognizer(folder.appendingPathComponent("apple-voice.wav"))
        } catch {
            report["appleVoiceError"] = error.localizedDescription
        }
        if let kokoro {
            do {
                let start = Date()
                let spoken = try await runtime.speak(sentence, voice: "af_heart", speed: 1, kokoroFolder: kokoro)
                report["kokoroSeconds"] = String(format: "%.2f audio in %.2f", spoken.duration, Date().timeIntervalSince(start))
                try spoken.wav.write(to: folder.appendingPathComponent("kokoro-heart.wav"))
                if let whisper { report["whisperHeardKokoro"] = try await runtime.transcribe(try resampled(spoken), whisperFolder: whisper) }
            } catch {
                report["kokoroError"] = error.localizedDescription
            }
        }
        return report
    }

    /// Mono samples at any rate, as Whisper's 16 kHz.
    private static func resampled(_ audio: SpeechAudio) throws -> [Float] {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(audio.sampleRate), channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.samples.count)) else { return [] }
        buffer.frameLength = AVAudioFrameCount(audio.samples.count)
        audio.samples.withUnsafeBufferPointer { source in buffer.floatChannelData?[0].update(from: source.baseAddress!, count: source.count) }
        return try WhisperAudioInput.monoSamples(from: [buffer])
    }

    /// Apple's on-device recognizer on a file, only if speech recognition is already allowed.
    private static func appleRecognizer(_ file: URL) async -> String {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return "skipped: speech recognition isn’t allowed for this build (not asked)" }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.supportsOnDeviceRecognition else { return "on-device recognition unavailable" }
        let request = SFSpeechURLRecognitionRequest(url: file)
        request.requiresOnDeviceRecognition = true
        return await withCheckedContinuation { continuation in
            let once = Once(continuation)
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal { once.resume(result.bestTranscription.formattedString) }
                else if let error { once.resume("error: \(error.localizedDescription)") }
            }
        }
    }
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String, Never>?
        init(_ continuation: CheckedContinuation<String, Never>) { self.continuation = continuation }
        func resume(_ value: String) {
            lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
            pending?.resume(returning: value)
        }
    }
}
#endif

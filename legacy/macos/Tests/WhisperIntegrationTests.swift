import AVFoundation
import MLX
import MLXAudioSTT
import Speech
import XCTest
@testable import KemoSabeMac

/// On-device Whisper on this Mac's GPU, only when asked:
/// `TEST_RUNNER_KEMO_WHISPER_INTEGRATION=1 xcodebuild test …` downloads the pinned model (466 MB)
/// into `$TMPDIR/KemoSabeVoiceModelTests` the first time, synthesizes a sentence with an Apple
/// voice, and transcribes it through the app's own path.
///
/// `TEST_RUNNER_KEMO_WHISPER_BENCH=<models folder>` with `TEST_RUNNER_KEMO_WHISPER_CLIPS=<clips
/// folder with refs.tsv>` measures candidate models (the numbers in design/VOICE-ENGINES.md).
final class WhisperIntegrationTests: XCTestCase {
    private var cache: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("KemoSabeVoiceModelTests", isDirectory: true)
    }

    @MainActor func testWhisperTranscribesASynthesizedClipOnThisMac() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KEMO_WHISPER_INTEGRATION"] == "1",
                          "Set TEST_RUNNER_KEMO_WHISPER_INTEGRATION=1 to download Whisper and transcribe on this Mac.")
        try XCTSkipUnless(NeuralSpeechRuntime.isSupported, "Needs a Metal GPU")
        let store = VoiceModelStore(pack: .whisper, root: cache)
        store.wifiOnly = false
        if !store.isInstalled { store.download(); await store.waitUntilDone() }
        XCTAssertEqual(store.state, .installed, "\(store.state)")
        XCTAssertTrue(VoiceModelFiles.isExcludedFromBackup(store.folder))

        let sentence = "Remind me to call Priya about the quarterly budget tomorrow afternoon."
        let buffers = try await Self.synthesize(sentence)
        let seconds = buffers.reduce(0.0) { $0 + Double($1.frameLength) / $1.format.sampleRate }
        XCTAssertGreaterThan(seconds, 2)
        let samples = try WhisperAudioInput.monoSamples(from: buffers)

        let cold = Date()
        let first = try await WhisperWorker.shared.transcribe(samples, folder: store.folder)
        let coldSeconds = Date().timeIntervalSince(cold)
        let warm = Date()
        let text = try await WhisperWorker.shared.transcribe(samples, folder: store.folder)
        let warmSeconds = Date().timeIntervalSince(warm)
        print("WHISPER-TIMING \(String(format: "%.2f", seconds)) s of audio: cold \(String(format: "%.2f", coldSeconds)) s (includes loading), warm \(String(format: "%.2f", warmSeconds)) s → “\(text)”")
        XCTAssertEqual(first, text, "greedy decoding is deterministic")
        XCTAssertLessThan(Self.wordErrorRate(reference: sentence, hypothesis: text), 0.15, text)
        XCTAssertLessThan(warmSeconds, seconds, "faster than real time on Apple silicon")
        XCTAssertLessThan(warmSeconds, WhisperTranscription.timeout(forAudioSeconds: seconds))

        // The whole selection path the Mac's dictation uses: Whisper's text replaces Apple's.
        let final = await WhisperTranscription.select(apple: "remind me to call korea", conditions: .init(
            installed: true, supported: true, foreground: true, unlocked: true, surface: .dictation), audioSeconds: seconds) {
            try await WhisperWorker.shared.transcribe(samples, folder: store.folder)
        }
        XCTAssertEqual(final.source, .whisper)
        XCTAssertTrue(final.text.contains("Priya"), final.text)
        await WhisperWorker.shared.unload()
    }

    /// Measures each model folder in `KEMO_WHISPER_BENCH` on the clips in `KEMO_WHISPER_CLIPS`:
    /// load time, word error rate, real-time factor (warm), and MLX peak memory.
    func testMeasureCandidateModels() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelsPath = environment["KEMO_WHISPER_BENCH"], let clipsPath = environment["KEMO_WHISPER_CLIPS"] else {
            throw XCTSkip("Set TEST_RUNNER_KEMO_WHISPER_BENCH and TEST_RUNNER_KEMO_WHISPER_CLIPS to measure models.")
        }
        try XCTSkipUnless(NeuralSpeechRuntime.isSupported, "Needs a Metal GPU")
        let clipsFolder = URL(fileURLWithPath: clipsPath)
        let refs = try String(contentsOf: clipsFolder.appendingPathComponent("refs.tsv"), encoding: .utf8)
            .split(separator: "\n").map { $0.split(separator: "\t", maxSplits: 1).map(String.init) }.filter { $0.count == 2 }
        let clips = try refs.map { row in
            (name: row[0], reference: row[1], samples: try WhisperAudioInput.monoSamples(contentsOf: clipsFolder.appendingPathComponent(row[0] + ".wav")))
        }
        // Apple's newer on-device recognizer on the same clips, with the app's name hints, as the baseline.
        var appleErrors = 0.0, appleWords = 0.0
        for clip in refs {
            guard let text = try await Self.appleTranscript(clipsFolder.appendingPathComponent(clip[0] + ".wav")) else { break }
            let count = Double(Self.words(clip[1]).count)
            appleErrors += Self.wordErrorRate(reference: clip[1], hypothesis: text) * count; appleWords += count
            print("BENCH apple \(clip[0]): \(text)")
        }
        if appleWords > 0 { print(String(format: "BENCH-SUMMARY apple-speechtranscriber · WER %.1f%%", appleErrors / appleWords * 100)) }

        let folders = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: modelsPath), includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for folder in folders where FileManager.default.fileExists(atPath: folder.appendingPathComponent("config.json").path) {
            Memory.clearCache(); Memory.peakMemory = 0
            let loadStart = Date()
            let model: any STTGenerationModel
            if folder.lastPathComponent.contains("parakeet") { model = try ParakeetModel.fromDirectory(folder) }
            else { model = try await WhisperModel.fromDirectory(folder) }
            let loadSeconds = Date().timeIntervalSince(loadStart)
            let loadPeak = Memory.peakMemory
            Memory.clearCache(); Memory.peakMemory = 0
            let size = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
                .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            _ = model.generate(audio: MLXArray(clips[0].samples), generationParameters: WhisperWorker.parameters) // warm up
            var errors = 0.0, words = 0.0, audio = 0.0, compute = 0.0
            for clip in clips {
                let start = Date()
                let text = model.generate(audio: MLXArray(clip.samples), generationParameters: WhisperWorker.parameters).text
                compute += Date().timeIntervalSince(start)
                audio += Double(clip.samples.count) / 16_000
                let count = Double(Self.words(clip.reference).count)
                errors += Self.wordErrorRate(reference: clip.reference, hypothesis: text) * count; words += count
                print("BENCH \(folder.lastPathComponent) \(clip.name): \(WhisperTranscription.normalized(text))")
            }
            print(String(format: "BENCH-SUMMARY %@ size %.0f MB · load %.2f s (peak %.0f MB) · WER %.1f%% · RTF %.3f (%.2f s for %.1f s, %.2f s per clip) · inference peak %.0f MB",
                         folder.lastPathComponent, Double(size) / 1e6, loadSeconds, Double(loadPeak) / 1e6, errors / words * 100, compute / audio,
                         compute, audio, compute / Double(clips.count), Double(Memory.peakMemory) / 1e6))
            Memory.clearCache()
        }
    }

    // MARK: Helpers

    /// Apple's SpeechTranscriber on a file, when its English model is installed on this Mac.
    static func appleTranscript(_ url: URL) async throws -> String? {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else { return nil }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else { return nil }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let context = AnalysisContext()
        context.contextualStrings[.general] = ["KemoSabe", "Kemo Sabe", "Kemo"]
        try await analyzer.setContext(context)
        let collected = Task {
            var text = ""
            for try await result in transcriber.results where result.isFinal { text += String(result.text.characters) }
            return text
        }
        try await analyzer.start(inputAudioFile: AVAudioFile(forReading: url), finishAfterFile: true)
        return try await collected.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Speaks a sentence with an Apple voice into buffers (no file, nothing played aloud).
    @MainActor static func synthesize(_ text: String) async throws -> [AVAudioPCMBuffer] {
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        return try await withCheckedThrowingContinuation { continuation in
            var buffers: [AVAudioPCMBuffer] = []
            var finished = false
            synthesizer.write(utterance) { buffer in
                guard !finished else { return }
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    finished = true
                    _ = synthesizer
                    continuation.resume(returning: buffers)
                } else if let copy = AVAudioPCMBuffer(pcmFormat: pcm.format, frameCapacity: pcm.frameLength) {
                    copy.frameLength = pcm.frameLength
                    let from = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: pcm.audioBufferList))
                    let to = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
                    for index in 0..<min(from.count, to.count) {
                        if let source = from[index].mData, let target = to[index].mData { memcpy(target, source, Int(from[index].mDataByteSize)) }
                    }
                    buffers.append(copy)
                }
            }
        }
    }

    /// Lowercased words, punctuation dropped, numbers spelled out ("4:30" → "four thirty").
    static func words(_ text: String) -> [String] {
        let speller = NumberFormatter()
        speller.numberStyle = .spellOut
        speller.locale = Locale(identifier: "en_US")
        let spaced = text.lowercased().replacingOccurrences(of: "kemo sabe", with: "kemosabe")
            .replacingOccurrences(of: "stand-up", with: "standup").replacingOccurrences(of: "stand up", with: "standup")
            .replacingOccurrences(of: #"(\d)\.(\d)"#, with: "$1 $2", options: .regularExpression)
        return spaced.components(separatedBy: CharacterSet(charactersIn: " \n\t:-")).flatMap { raw -> [String] in
                let token = raw.trimmingCharacters(in: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "'")))
                    .replacingOccurrences(of: "’", with: "'")
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;\"'"))
                guard !token.isEmpty else { return [] }
                if let number = Int(token), let spelled = speller.string(from: NSNumber(value: number)) {
                    return spelled.components(separatedBy: CharacterSet(charactersIn: " -"))
                }
                return [token]
            }
    }
    static func wordErrorRate(reference: String, hypothesis: String) -> Double {
        let ref = words(reference), hyp = words(hypothesis)
        guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }
        var previous = Array(0...hyp.count)
        for (i, word) in ref.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: hyp.count)
            for (j, other) in hyp.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (word == other ? 0 : 1))
            }
            previous = current
        }
        return Double(previous[hyp.count]) / Double(ref.count)
    }
}

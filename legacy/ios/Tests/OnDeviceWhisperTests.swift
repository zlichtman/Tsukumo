import AVFoundation
import XCTest
#if os(macOS)
@testable import KemoSabeMac
#else
@testable import KemoSabe
#endif

/// On-device Whisper's rules, without the GPU: the pinned download, which text wins (success,
/// failure, timeout, and the background/locked/Talk to Kemo fallbacks), the 16 kHz mono
/// conversion, and transcript cleanup. Real transcription on the Mac's GPU is
/// `WhisperIntegrationTests` (gated).
final class OnDeviceWhisperTests: XCTestCase {
    // MARK: Manifest

    func testWhisperIsPinnedToACommitAndEveryFilesSizeAndChecksum() throws {
        let pack = VoiceModelPack.whisper
        XCTAssertEqual(pack.sources.count, 1)
        let source = try XCTUnwrap(pack.sources.first)
        XCTAssertEqual(source.repository, "mlx-community/whisper-large-v3-turbo-asr-4bit")
        XCTAssertEqual(source.revision, "321a6ead9f6e0646bc8188a54d2a470e275c6b76")
        XCTAssertTrue(source.license.hasPrefix("MIT"))
        XCTAssertEqual(source.folder, "model")
        var seen = Set<String>()
        for file in source.files {
            XCTAssertEqual(file.sha256.count, 64, file.path)
            XCTAssertTrue(file.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase }, file.path)
            XCTAssertGreaterThan(file.size, 0)
            XCTAssertTrue(seen.insert(file.path).inserted, "duplicate \(file.path)")
            let url = try XCTUnwrap(source.url(for: file))
            XCTAssertEqual(url.host, "huggingface.co")
            XCTAssertEqual(url.scheme, "https")
            XCTAssertTrue(url.path.contains("/resolve/\(source.revision)/"), "never a moving branch")
        }
        // The tokenizer ships in the pack, so loading never reaches for the network.
        XCTAssertEqual(seen, ["config.json", "generation_config.json", "model.safetensors", "tokenizer.json",
                              "tokenizer_config.json", "special_tokens_map.json", "added_tokens.json"])
        XCTAssertFalse(seen.contains { $0.hasSuffix(".npz") || $0.hasSuffix(".bin") })
        XCTAssertEqual(source.files.first { $0.path == "model.safetensors" }?.sha256,
                       "45298f6dc48df8c11e0a8d1dc5e0197c688bfa530646fa21f1a0238d2b0ecda3")
        XCTAssertEqual(pack.totalBytes, 466_498_107)
        XCTAssertEqual(pack.shortSizeLabel, "466 MB")
        XCTAssertNotEqual(pack.id, VoiceModelPack.kokoro.id)
        XCTAssertNotEqual(pack.id, VoiceModelPack.pocketTTS.id)
    }

    @MainActor func testTheWhisperDownloadFollowsTheWiFiOnlySetting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-voices-" + UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let voices = SpeechVoices(kokoro: VoiceModelStore(pack: .kokoro, root: root), pocket: VoiceModelStore(pack: .pocketTTS, root: root),
                                  whisper: VoiceModelStore(pack: .whisper, root: root))
        let saved = voices.wifiOnly
        defer { voices.wifiOnly = saved }
        voices.wifiOnly = true
        XCTAssertTrue(voices.whisper.wifiOnly)
        voices.wifiOnly = false
        XCTAssertFalse(voices.whisper.wifiOnly)
        XCTAssertEqual(voices.whisper.state, .notDownloaded)
        XCTAssertEqual(voices.whisper.folder.lastPathComponent, "whisper-large-v3-turbo")
    }

    // MARK: No choice

    /// OpenAI's transcribers are an opt-in that names where audio goes; nothing on the device is one.
    func testOpenAITranscribersNameTheirDestination() async {
        for model in CloudVoice.Transcriber.allCases { XCTAssertTrue(model.menuTitle.contains(CloudVoice.host), model.rawValue) }
        XCTAssertEqual(Set(CloudVoice.Transcriber.allCases), [.whisper, .gpt4oTranscribe, .gpt4oMiniTranscribe])
        do { _ = try await OpenAIAudio(key: "test").transcribe(Data(), fileName: "a.wav", model: .whisper); XCTFail("Nothing to send") } catch {}
    }

    /// Whisper is used as soon as it's on the device; there's no transcription menu, only the OpenAI opt-in.
    func testWhisperIsUsedOnceDownloadedWithNothingToChoose() {
        XCTAssertTrue(WhisperTranscription.shouldRun(conditions()))
        XCTAssertEqual(VoiceAuto.listening(.init(neuralSupported: true, whisperInstalled: true, kokoroInstalled: false, ownVoiceReady: false)), .whisper)
    }

    // MARK: Final text

    private func conditions(installed: Bool = true, supported: Bool = true, foreground: Bool = true,
                            unlocked: Bool = true, surface: WhisperTranscription.Surface = .voiceMode) -> WhisperTranscription.Conditions {
        .init(installed: installed, supported: supported, foreground: foreground, unlocked: unlocked, surface: surface)
    }

    func testWhisperRunsOnlyWhenChosenDownloadedInFrontAndUnlocked() {
        XCTAssertTrue(WhisperTranscription.shouldRun(conditions()))
        XCTAssertTrue(WhisperTranscription.shouldRun(conditions(surface: .dictation)))
        XCTAssertTrue(WhisperTranscription.shouldRun(conditions(surface: .watch)))
        XCTAssertFalse(WhisperTranscription.shouldRun(conditions(installed: false)))
        XCTAssertFalse(WhisperTranscription.shouldRun(conditions(supported: false)))
        XCTAssertFalse(WhisperTranscription.shouldRun(conditions(foreground: false)), "background keeps Apple")
        XCTAssertFalse(WhisperTranscription.shouldRun(conditions(unlocked: false)), "locked keeps Apple")
        XCTAssertFalse(WhisperTranscription.shouldRun(conditions(surface: .talkToKemo)), "Talk to Kemo keeps Apple")
    }

    func testWhisperWinsWhenItSucceeds() async {
        let final = await WhisperTranscription.select(apple: "remind me to call pria", conditions: conditions(), audioSeconds: 3) {
            " Remind me to call Priya. "
        }
        XCTAssertEqual(final, .init(text: "Remind me to call Priya.", source: .whisper))
    }

    func testAppleStaysWhenWhisperFails() async {
        struct Broken: Error {}
        let final = await WhisperTranscription.select(apple: "call Priya", conditions: conditions(), audioSeconds: 2) { throw Broken() }
        XCTAssertEqual(final, .init(text: "call Priya", source: .apple))
    }

    func testAppleStaysWhenWhisperRunsPastItsTimeout() async {
        let started = Date()
        let final = await WhisperTranscription.select(apple: "call Priya", conditions: conditions(), audioSeconds: 2, timeout: 0.2) {
            try await Task.sleep(for: .seconds(5))
            return "too late"
        }
        XCTAssertEqual(final, .init(text: "call Priya", source: .apple))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "never waits for the slow pass")
    }

    func testBackgroundLockedAndTalkToKemoNeverStartWhisper() async {
        for skipped in [conditions(foreground: false), conditions(unlocked: false), conditions(surface: .talkToKemo), conditions(installed: false)] {
            let ran = Flag()
            let final = await WhisperTranscription.select(apple: "call Priya", conditions: skipped, audioSeconds: 2) {
                ran.set(); return "Whisper text"
            }
            XCTAssertEqual(final, .init(text: "call Priya", source: .apple))
            XCTAssertFalse(ran.isSet)
        }
    }

    func testEmptyOrSilenceHallucinationsKeepApple() {
        XCTAssertEqual(WhisperTranscription.finalText(apple: "hello", outcome: .transcribed("  ")).source, .apple)
        XCTAssertEqual(WhisperTranscription.finalText(apple: "", outcome: .transcribed("Thank you.")), .init(text: "", source: .apple))
        XCTAssertEqual(WhisperTranscription.finalText(apple: "set a timer", outcome: .transcribed("Thanks for watching!")).text, "set a timer")
        XCTAssertEqual(WhisperTranscription.finalText(apple: "thank you", outcome: .transcribed("Thank you.")).source, .whisper,
                       "a real thank-you Apple heard too is kept")
        let loop = String(repeating: "I'm going to the store. ", count: 20)
        XCTAssertEqual(WhisperTranscription.finalText(apple: "I'm going to the store", outcome: .transcribed(loop)).source, .apple)
        XCTAssertEqual(WhisperTranscription.finalText(apple: "a", outcome: .timedOut), .init(text: "a", source: .apple))
        XCTAssertEqual(WhisperTranscription.finalText(apple: "a", outcome: .skipped).source, .apple)
    }

    func testTheTimeoutScalesWithTheAudioAndIsCapped() {
        XCTAssertEqual(WhisperTranscription.timeout(forAudioSeconds: 0), 3)
        XCTAssertEqual(WhisperTranscription.timeout(forAudioSeconds: 4), 5, accuracy: 0.001)
        XCTAssertEqual(WhisperTranscription.timeout(forAudioSeconds: 10), 8, accuracy: 0.001)
        XCTAssertEqual(WhisperTranscription.timeout(forAudioSeconds: 60), 20)
        XCTAssertEqual(WhisperTranscription.timeout(forAudioSeconds: .nan), 3)
        XCTAssertLessThan(WhisperTranscription.timeout(forAudioSeconds: 2), WhisperTranscription.timeout(forAudioSeconds: 6))
    }

    // MARK: Normalization

    func testTranscriptsAreCleanedOfNonSpeechTagsAndStrayWhitespace() {
        XCTAssertEqual(WhisperTranscription.normalized("  Remind me   to call\nPriya.  "), "Remind me to call Priya.")
        XCTAssertEqual(WhisperTranscription.normalized("[BLANK_AUDIO]"), "")
        XCTAssertEqual(WhisperTranscription.normalized("(upbeat music) What's the weather?"), "What's the weather?")
        XCTAssertEqual(WhisperTranscription.normalized("So *laughs* that's it"), "So that's it")
        XCTAssertEqual(WhisperTranscription.normalized("- Draft a note to Marcus."), "Draft a note to Marcus.")
        XCTAssertEqual(WhisperTranscription.normalized(">> Hey Kemo"), "Hey Kemo")
        XCTAssertEqual(WhisperTranscription.normalized("Pick the second one (the blue one) please"), "Pick the second one (the blue one) please",
                       "a real parenthetical stays")
        XCTAssertEqual(WhisperTranscription.normalized("Meet at 9:15 — okay?"), "Meet at 9:15 — okay?")
    }

    func testKemosNameIsSpelledTheWayAppleHeardIt() {
        let names = ["Mochi", "KemoSabe", "Tsukumo"]
        XCTAssertEqual(WhisperTranscription.restoringNames("Hey Kimo Saib, can you draft a note?", apple: "hey KemoSabe can you draft a note", names: names),
                       "Hey KemoSabe, can you draft a note?")
        XCTAssertEqual(WhisperTranscription.restoringNames("Hey chemo save, what's next?", apple: "Hey KemoSabe what's next", names: names),
                       "Hey KemoSabe, what's next?")
        XCTAssertEqual(WhisperTranscription.restoringNames("Thanks, Mochee.", apple: "thanks Mochi", names: names), "Thanks, Mochi.")
        // Only when Apple heard the name: Whisper's text is otherwise left alone.
        XCTAssertEqual(WhisperTranscription.restoringNames("I had chemo on Monday.", apple: "I had chemo on Monday", names: names),
                       "I had chemo on Monday.")
        // Nothing close enough: unchanged.
        XCTAssertEqual(WhisperTranscription.restoringNames("Book a table for two.", apple: "KemoSabe book a table for two", names: names),
                       "Book a table for two.")
        XCTAssertEqual(WhisperTranscription.finalText(apple: "hey KemoSabe", outcome: .transcribed("Hey, Kimo Saib."), names: names),
                       .init(text: "Hey, KemoSabe.", source: .whisper))
    }

    // MARK: 16 kHz mono

    func testStereo48kHzBecomes16kHzMonoWithTheSameSignal() throws {
        let buffer = try Self.tone(frequency: 440, seconds: 1, rate: 48_000, channels: 2)
        let samples = try WhisperAudioInput.monoSamples(from: [buffer])
        XCTAssertEqual(Double(samples.count), 16_000, accuracy: 200)
        XCTAssertEqual(Double(Self.crossings(samples.dropFirst(800).dropLast(800))) / (Double(samples.count - 1600) / 16_000),
                       880, accuracy: 20, "a 440 Hz tone crosses zero 880 times a second")
        XCTAssertEqual(Double(Self.rms(Array(samples.dropFirst(800).dropLast(800)))), 0.5 / 2.0.squareRoot(), accuracy: 0.05)
    }

    func testSeveralBuffersAndARouteChangeConvertInOrder() throws {
        let first = try Self.tone(frequency: 300, seconds: 0.5, rate: 44_100, channels: 1)
        let second = try Self.tone(frequency: 300, seconds: 0.5, rate: 44_100, channels: 1)
        let afterRouteChange = try Self.tone(frequency: 300, seconds: 0.25, rate: 24_000, channels: 1)
        let samples = try WhisperAudioInput.monoSamples(from: [first, second, afterRouteChange])
        XCTAssertEqual(Double(samples.count), 16_000 * 1.25, accuracy: 300)
        XCTAssertTrue(samples.allSatisfy(\.isFinite))
    }

    func testSixteenKilohertzMonoPassesThroughUnchanged() throws {
        let buffer = try Self.tone(frequency: 200, seconds: 0.1, rate: 16_000, channels: 1)
        let samples = try WhisperAudioInput.monoSamples(from: [buffer])
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        XCTAssertEqual(samples, Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))))
    }

    func testAClipIsDecodedAndItsTemporaryFileIsGoneAfterwards() throws {
        let buffer = try Self.tone(frequency: 440, seconds: 0.5, rate: 44_100, channels: 1)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tone-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forWriting: url, settings: buffer.format.settings)
        try file.write(from: buffer)
        file.close() // finishes the WAV header
        let clip = try Data(contentsOf: url)
        let before = Self.whisperTemporaryFiles()
        let samples = try WhisperAudioInput.monoSamples(fromClip: clip, fileExtension: "wav")
        XCTAssertEqual(Double(samples.count), 8_000, accuracy: 200)
        XCTAssertEqual(Self.whisperTemporaryFiles(), before, "the decoded clip is deleted right away")
        XCTAssertTrue(try WhisperAudioInput.monoSamples(from: []).isEmpty)
    }

    func testTheUtteranceRecorderHandsOverBuffersOnceWithoutWritingAFile() throws {
        let recorder = UtteranceRecorder()
        let buffer = try Self.tone(frequency: 440, seconds: 0.2, rate: 48_000, channels: 1)
        recorder.append(buffer)
        XCTAssertTrue(recorder.takeBuffers().isEmpty, "nothing is kept until it's switched on")
        recorder.reset(enabled: true)
        recorder.append(buffer); recorder.append(buffer)
        XCTAssertEqual(recorder.takeBuffers().reduce(0) { $0 + Int($1.frameLength) }, Int(buffer.frameLength) * 2)
        XCTAssertTrue(recorder.takeBuffers().isEmpty, "handed over once, then cleared")
    }

    // MARK: Helpers

    static func tone(frequency: Double, seconds: Double, rate: Double, channels: AVAudioChannelCount) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false))
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            let data = try XCTUnwrap(buffer.floatChannelData?[channel])
            for index in 0..<Int(frames) { data[index] = Float(0.5 * sin(2 * .pi * frequency * Double(index) / rate)) }
        }
        return buffer
    }
    private static func crossings<C: Collection>(_ samples: C) -> Int where C.Element == Float {
        zip(samples, samples.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
    }
    private static func rms(_ samples: [Float]) -> Float {
        (samples.reduce(0) { $0 + $1 * $1 } / Float(max(1, samples.count))).squareRoot()
    }
    private static func whisperTemporaryFiles() -> Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []).filter { $0.hasPrefix("whisper-") })
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

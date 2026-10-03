import XCTest
#if os(macOS)
@testable import KemoSabeMac
#else
@testable import KemoSabe
#endif

/// The "Your voice" training flow without a microphone or the GPU: the clean-up of takes on
/// synthetic signals, passage choice and the checks, the session's rules (redo, record more),
/// and a whole session run through the trainer with a stand-in microphone.
final class OwnVoiceTrainingTests: XCTestCase {
    private let rate = OwnVoiceAudio.sampleRate

    // MARK: Synthetic signals

    private func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * Double(rate))) }
    private func tone(_ hz: Float, seconds: Double, amplitude: Float) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { amplitude * sin(2 * .pi * hz * Float($0) / Float(rate)) }
    }
    /// Seeded white noise, the same every run.
    private func noise(_ seconds: Double, amplitude: Float, seed: UInt64 = 1) -> [Float] {
        var state = seed
        return (0..<Int(seconds * Double(rate))).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return amplitude * (Float(state >> 40) / Float(1 << 24) * 2 - 1)
        }
    }
    /// A voice-like signal: a 140 Hz hum with harmonics, in syllables.
    private func voice(_ seconds: Double, amplitude: Float = 0.3) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { index in
            let t = Float(index) / Float(rate)
            let syllables = 0.3 + 0.7 * max(0, sin(2 * .pi * 3 * t))
            return amplitude * syllables * (1...5).reduce(Float(0)) { $0 + sin(2 * .pi * 140 * Float($1) * t) / Float($1) } / 2
        }
    }
    private func add(_ a: [Float], _ b: [Float]) -> [Float] { a.indices.map { a[$0] + (b.isEmpty ? 0 : b[$0 % b.count]) } }
    private func db(_ samples: [Float]) -> Float { OwnVoiceAudio.decibels(OwnVoiceAudio.rms(samples)) }

    // MARK: Audio processing

    func testTrimRemovesLeadingAndTrailingSilenceButKeepsAPad() {
        let hiss = noise(2.2, amplitude: 0.0005)
        let take = add(silence(0.6) + voice(1.0) + silence(0.6), hiss)
        let trimmed = OwnVoiceAudio.trimSilence(take)
        let seconds = Double(trimmed.count) / Double(rate)
        XCTAssertEqual(seconds, 1.0 + 2 * 0.12, accuracy: 0.08, "the voice plus a short pad either side")
        XCTAssertTrue(OwnVoiceAudio.trimSilence(silence(1)).count <= rate, "nothing to keep in pure silence")
    }

    func testHighPassTakesOutRumbleAndKeepsTheVoiceBand() {
        let rumble = tone(30, seconds: 1, amplitude: 0.5), speech = tone(1_000, seconds: 1, amplitude: 0.5)
        let settle = rate / 5
        XCTAssertLessThan(db(Array(OwnVoiceAudio.highPass(rumble).dropFirst(settle))), db(rumble) - 20)
        XCTAssertEqual(db(Array(OwnVoiceAudio.highPass(speech).dropFirst(settle))), db(speech), accuracy: 0.5)
    }

    func testLoudnessIsBroughtToTheTargetWithoutPassingTheCeiling() {
        let quiet = voice(2, amplitude: 0.02)
        let leveled = OwnVoiceAudio.normalizeLoudness(quiet)
        XCTAssertEqual(OwnVoiceAudio.speechLevel(leveled), OwnVoiceAudio.targetLevel, accuracy: 0.5)
        // A take with one sharp peak is only turned up until that peak reaches the ceiling.
        var peaky = voice(2, amplitude: 0.02)
        peaky[rate] = 0.9
        let limited = OwnVoiceAudio.normalizeLoudness(peaky)
        XCTAssertLessThanOrEqual(OwnVoiceAudio.peak(limited), OwnVoiceAudio.amplitude(OwnVoiceAudio.peakCeiling) + 1e-4)
        XCTAssertEqual(OwnVoiceAudio.normalizeLoudness(silence(1)), silence(1), "silence stays silence")
    }

    func testClippingIsDetectedAndACleanTakeIsNot() {
        let clipped = tone(220, seconds: 1, amplitude: 1.4).map { max(-1, min(1, $0)) }
        XCTAssertTrue(OwnVoiceAudio.clipping(clipped).isClipped)
        XCTAssertFalse(OwnVoiceAudio.clipping(tone(220, seconds: 1, amplitude: 0.5)).isClipped)
        var one = tone(220, seconds: 1, amplitude: 0.5)
        one[100] = 0.99
        XCTAssertFalse(OwnVoiceAudio.clipping(one).isClipped, "one stray sample isn't a clipped take")
        let report = OwnVoiceAudio.report(clipped)
        XCTAssertTrue(report.clipped)
        XCTAssertEqual(OwnVoiceAudio.problem(with: report), .clipped)
    }

    func testSpectralGateLowersSteadyNoiseAndKeepsTheVoice() {
        let hiss = noise(3, amplitude: 0.02, seed: 9)
        let take = add(silence(1) + voice(1, amplitude: 0.3) + silence(1), hiss)
        let gated = OwnVoiceAudio.spectralGate(take, noise: noise(2, amplitude: 0.02, seed: 4))
        XCTAssertEqual(gated.count, take.count)
        let rate = self.rate
        let pause = { (s: [Float]) in Array(s[(rate / 5)..<(rate * 4 / 5)]) }
        let speech = { (s: [Float]) in Array(s[(rate + rate / 5)..<(2 * rate - rate / 5)]) }
        XCTAssertLessThan(db(pause(gated)), db(pause(take)) - 8, "the pauses get much quieter")
        XCTAssertEqual(db(speech(gated)), db(speech(take)), accuracy: 2, "the voice keeps its level")
        XCTAssertTrue(gated.allSatisfy(\.isFinite))
    }

    func testTheRoomCheckIgnoresOneClickAndFlagsANoisyRoom() {
        var quiet = noise(3, amplitude: 0.0005)
        for index in 0..<200 { quiet[rate + index] = 0.8 }
        let calm = OwnVoiceAudio.roomNoise(quiet)
        XCTAssertFalse(calm.isNoisy, "a click doesn't make the room noisy")
        XCTAssertFalse(calm.needsNoiseReduction)
        let loud = OwnVoiceAudio.roomNoise(noise(3, amplitude: 0.05))
        XCTAssertTrue(loud.isNoisy)
        XCTAssertTrue(loud.needsNoiseReduction)
    }

    func testLiveFeedbackSaysTooQuietOrTooLoud() {
        XCTAssertEqual(OwnVoiceAudio.feedback(recentLevels: [], recentPeak: 0), .listening)
        XCTAssertEqual(OwnVoiceAudio.feedback(recentLevels: [Float](repeating: -55, count: 20), recentPeak: 0.01), .tooQuiet)
        XCTAssertEqual(OwnVoiceAudio.feedback(recentLevels: [Float](repeating: -55, count: 3), recentPeak: 0.01), .listening, "not before it's heard a moment")
        XCTAssertEqual(OwnVoiceAudio.feedback(recentLevels: [-60, -22, -18], recentPeak: 0.4), .good, "pauses between words don't count")
        XCTAssertEqual(OwnVoiceAudio.feedback(recentLevels: [-20], recentPeak: 0.99), .tooLoud)
        XCTAssertEqual(OwnVoiceAudio.LevelFeedback.tooQuiet.label, "Too quiet")
        XCTAssertEqual(OwnVoiceAudio.LevelFeedback.tooLoud.label, "Too loud")
    }

    func testACleanTakeInAQuietRoomKeepsItsVoice() {
        let raw = silence(0.3) + voice(7, amplitude: 0.08) + silence(0.3)
        let filtered = OwnVoiceAudio.highPass(raw)
        XCTAssertTrue(filtered.allSatisfy(\.isFinite))
        XCTAssertEqual(Double(OwnVoiceAudio.trimSilence(filtered).count) / Double(rate), 7.24, accuracy: 0.1,
                       "a take that's nearly all speech keeps all of it")
        let take = OwnVoiceAudio.process(raw, text: "a line", room: .init(decibels: -80), noiseSample: nil)
        XCTAssertEqual(take.report.seconds, 7.24, accuracy: 0.2)
        XCTAssertEqual(take.noiseReduction, .none)
    }

    func testProcessingATakeCleansItUp() {
        let hum = tone(50, seconds: 3.2, amplitude: 0.01)
        let raw = add(add(silence(0.8) + voice(2, amplitude: 0.05) + silence(0.4), hum), noise(1, amplitude: 0.003))
        let room = OwnVoiceAudio.roomNoise(noise(2, amplitude: 0.003))
        let take = OwnVoiceAudio.process(raw, text: "a line", room: room, noiseSample: noise(2, amplitude: 0.003, seed: 5))
        XCTAssertEqual(take.report.speechDecibels, OwnVoiceAudio.targetLevel, accuracy: 1)
        XCTAssertLessThan(take.report.seconds, 2.6, "the silence either side is gone")
        XCTAssertGreaterThan(take.report.seconds, 1.9)
        XCTAssertFalse(take.report.clipped)
        XCTAssertNotEqual(take.noiseReduction, .none, "a room with noise gets noise reduction")
        let quietRoom = OwnVoiceAudio.RoomNoise(decibels: -75)
        XCTAssertEqual(OwnVoiceAudio.process(raw, text: "a line", room: quietRoom, noiseSample: nil).noiseReduction, .none,
                       "a quiet room leaves the voice untouched")
    }

    func testTheReferenceIsTheBestTakesFirstUpToTheModelsLength() {
        func take(_ text: String, seconds: Double, snr: Float, clipped: Bool = false) -> OwnVoiceAudio.ProcessedTake {
            .init(samples: voice(seconds), text: text,
                  report: .init(seconds: seconds, speechDecibels: -20, peak: 0.5, clipped: clipped, signalToNoise: snr), noiseReduction: .none)
        }
        let takes = [take("ok", seconds: 8, snr: 30), take("best", seconds: 8, snr: 45), take("clipped", seconds: 8, snr: 60, clipped: true),
                     take("good", seconds: 8, snr: 40), take("fine", seconds: 8, snr: 35)]
        let reference = OwnVoiceAudio.reference(from: takes, length: .init(target: 20, maximum: 30))
        XCTAssertEqual(reference.segments.map(\.text), ["best", "good", "fine"], "best first, never a clipped take, stops at the target")
        XCTAssertEqual(reference.seconds, 24 + 2 * 0.3, accuracy: 0.01)
        let short = OwnVoiceAudio.reference(from: takes, length: .init(target: 12, maximum: 12))
        XCTAssertLessThanOrEqual(short.seconds, 12)
        XCTAssertGreaterThan(short.seconds, 10, "the second take is cut at a quiet moment, not dropped")
        XCTAssertEqual(short.segments.first?.text, "best")
    }

    func testSoundIsolationWhenAvailableKeepsTheVoice() throws {
        try XCTSkipUnless(AppleSoundIsolation.isAvailable, "No sound isolation unit here")
        let take = add(voice(2, amplitude: 0.2), noise(2, amplitude: 0.01))
        guard let isolated = AppleSoundIsolation.isolate(take, sampleRate: rate) else { throw XCTSkip("Sound isolation didn't render offline here") }
        XCTAssertEqual(isolated.count, take.count, accuracy: rate / 100)
        XCTAssertGreaterThan(OwnVoiceAudio.speechLevel(isolated), OwnVoiceAudio.speechLevel(take) - 20)
    }

    // MARK: The model

    func testTheVoiceStaysOnThePinnedPocketTTSAtItsMeasuredLength() throws {
        // Pocket TTS stays the Your voice model (see VOICE-ENGINES.md for the comparison).
        let pack = VoiceModelPack.pocketTTS
        XCTAssertEqual(pack.id, "pocket-tts")
        let source = try XCTUnwrap(pack.sources.first)
        XCTAssertEqual(source.repository, "mlx-community/pocket-tts")
        XCTAssertEqual(source.revision, "cbf71d5f6657bbc3f4bc02f85ee408261225bec7")
        XCTAssertTrue(source.license.hasPrefix("CC-BY-4.0"))
        XCTAssertTrue(pack.files.allSatisfy { $0.file.sha256.count == 64 })
        XCTAssertEqual(pack.shortSizeLabel, "236 MB")
        XCTAssertEqual(OwnVoiceAudio.ReferenceLength.pocketTTS, .init(target: 18, maximum: 20))
    }

    // MARK: Passages and checks

    func testTheOpeningPassagesMixCalmQuestionAndExclamation() {
        var generator = SeededTrainingGenerator(seed: 3)
        for _ in 0..<20 {
            let picks = OwnVoiceEnrollment.startingPassages(using: &generator)
            XCTAssertEqual(picks.count, OwnVoiceEnrollment.startingTakes)
            XCTAssertEqual(Set(picks).count, picks.count, "no passage twice")
            XCTAssertTrue(picks.contains { $0.kind == .question && $0.text.hasSuffix("?") })
            XCTAssertTrue(picks.contains { $0.kind == .exclamation && $0.text.contains("!") })
            XCTAssertTrue(picks.allSatisfy(OwnVoiceEnrollment.bank.contains))
        }
        var first = SeededTrainingGenerator(seed: 1), second = SeededTrainingGenerator(seed: 2)
        XCTAssertNotEqual(OwnVoiceEnrollment.startingPassages(using: &first), OwnVoiceEnrollment.startingPassages(using: &second), "chosen at random")
    }

    func testEveryPassageIsAboutEightSeconds() {
        for passage in OwnVoiceEnrollment.bank {
            let words = OwnVoiceEnrollment.words(passage.text).count
            XCTAssertTrue((16...24).contains(words), "\(words) words: \(passage.text)")
        }
        XCTAssertGreaterThanOrEqual(OwnVoiceEnrollment.bank.filter { $0.kind == .question }.count, 4)
        XCTAssertGreaterThanOrEqual(OwnVoiceEnrollment.bank.filter { $0.kind == .exclamation }.count, 4)
    }

    func testRecordMorePicksAnUnusedPassageOfTheLeastUsedKind() {
        var generator = SeededTrainingGenerator(seed: 11)
        let used = OwnVoiceEnrollment.bank.filter { $0.kind == .calm }.prefix(3) + OwnVoiceEnrollment.bank.filter { $0.kind == .question }.prefix(1)
        let next = OwnVoiceEnrollment.nextPassage(after: Array(used), using: &generator)
        XCTAssertEqual(next?.kind, .exclamation)
        XCTAssertFalse(used.contains(next!))
        XCTAssertNil(OwnVoiceEnrollment.nextPassage(after: OwnVoiceEnrollment.bank, using: &generator), "nothing left")
    }

    func testEachTakeIsCheckedAgainstItsOwnLine() throws {
        let passage = try XCTUnwrap(OwnVoiceEnrollment.bank.first { $0.kind == .question })
        XCTAssertTrue(OwnVoiceEnrollment.matches(heard: passage.text.lowercased().replacingOccurrences(of: "?", with: ""), expected: passage.text))
        XCTAssertFalse(OwnVoiceEnrollment.matches(heard: OwnVoiceEnrollment.bank[0].text, expected: passage.text))
    }

    // MARK: The session

    private func good(_ seconds: Double = 8) -> OwnVoiceAudio.TakeReport {
        .init(seconds: seconds, speechDecibels: -22, peak: 0.5, clipped: false, signalToNoise: 35)
    }
    private func passed(_ session: inout OwnVoiceSession, _ id: Int) {
        XCTAssertTrue(session.beginTake(id))
        session.takeRecorded(id, report: good())
        session.takeChecked(id, heard: session.takes[id].passage.text)
    }
    private func starting() -> OwnVoiceSession {
        var generator = SeededTrainingGenerator(seed: 5)
        return OwnVoiceSession(passages: OwnVoiceEnrollment.startingPassages(using: &generator))
    }

    func testANoisyRoomSaysSoAndCanBeContinuedAnyway() {
        var session = starting()
        XCTAssertEqual(session.stage, .roomCheck)
        session.beginRoomCheck()
        XCTAssertTrue(session.isRecording)
        session.roomMeasured(.init(decibels: -35))
        XCTAssertTrue(session.isNoisy)
        XCTAssertEqual(session.stage, .roomCheck, "waits for the person")
        XCTAssertFalse(session.beginTake(0))
        session.continueInNoisyRoom()
        XCTAssertEqual(session.stage, .takes)
        var quiet = starting()
        quiet.beginRoomCheck(); quiet.roomMeasured(.init(decibels: -70))
        XCTAssertEqual(quiet.stage, .takes, "a quiet room goes straight on")
    }

    func testBadTakesComeBackForARedoAndGoodOnesAreAccepted() {
        var session = starting()
        session.beginRoomCheck(); session.roomMeasured(.init(decibels: -70))
        XCTAssertFalse(session.beginTake(2), "one at a time, in order")
        XCTAssertTrue(session.beginTake(0))
        XCTAssertFalse(session.beginTake(0), "not while recording")
        session.takeRecorded(0, report: .init(seconds: 8, speechDecibels: -10, peak: 1, clipped: true, signalToNoise: 40))
        XCTAssertEqual(session.takes[0].status, .redo(OwnVoiceAudio.TakeProblem.clipped.message))
        XCTAssertTrue(session.beginTake(0))
        session.takeRecorded(0, report: good(2))
        XCTAssertEqual(session.takes[0].status, .redo(OwnVoiceAudio.TakeProblem.tooShort.message))
        XCTAssertTrue(session.beginTake(0))
        session.takeRecorded(0, report: good())
        XCTAssertEqual(session.takes[0].status, .checking)
        session.takeChecked(0, heard: "something else entirely")
        XCTAssertEqual(session.takes[0].status, .redo("That didn't match the line on screen. Read it as shown."))
        passed(&session, 0)
        XCTAssertEqual(session.takes[0].status, .accepted)
        XCTAssertEqual(session.currentTake?.id, 1)
    }

    func testConsentBuildAndPreviewFollowTheTakes() {
        var session = starting()
        session.beginRoomCheck(); session.roomMeasured(.init(decibels: -70))
        for id in session.takes.map(\.id) { passed(&session, id) }
        XCTAssertEqual(session.stage, .consent)
        XCTAssertTrue(session.beginConsent())
        session.consentRecorded(seconds: 4)
        session.consentChecked(heard: "this is my voice")
        XCTAssertEqual(session.stage, .consent, "the whole line, or it's asked again")
        XCTAssertTrue(session.beginConsent())
        session.consentRecorded(seconds: 4)
        session.consentChecked(heard: "This is my voice and I'm creating a voice for my own Kemo Sabe")
        XCTAssertEqual(session.stage, .building)
        session.built(revision: session.revision - 1)
        XCTAssertEqual(session.stage, .building, "a stale build is never used")
        session.built(revision: session.revision)
        XCTAssertEqual(session.stage, .preview)
    }

    func testRedoAndRecordMoreRebuildTheVoice() throws {
        var session = starting()
        session.beginRoomCheck(); session.roomMeasured(.init(decibels: -70))
        for id in session.takes.map(\.id) { passed(&session, id) }
        XCTAssertTrue(session.beginConsent()); session.consentRecorded(seconds: 4); session.consentChecked(heard: OwnVoiceEnrollment.consentLine)
        session.built(revision: session.revision)
        XCTAssertEqual(session.stage, .preview)
        XCTAssertTrue(session.canRecordMore)

        // Redo one take: back to reading it, then a rebuild. Consent is kept for the session.
        session.redo(1)
        XCTAssertEqual(session.stage, .takes)
        XCTAssertEqual(session.currentTake?.id, 1)
        passed(&session, 1)
        XCTAssertEqual(session.stage, .building)
        session.built(revision: session.revision)

        // Record more adds a fifth passage, then rebuilds; five is the most.
        var generator = SeededTrainingGenerator(seed: 8)
        let extra = try XCTUnwrap(OwnVoiceEnrollment.nextPassage(after: session.takes.map(\.passage), using: &generator))
        session.recordMore(extra)
        XCTAssertEqual(session.takes.count, 5)
        XCTAssertEqual(session.stage, .takes)
        XCTAssertEqual(session.currentTake?.passage, extra)
        passed(&session, 4)
        XCTAssertEqual(session.stage, .building)
        session.built(revision: session.revision)
        XCTAssertFalse(session.canRecordMore, "five takes is the most")
        session.recordMore(extra)
        XCTAssertEqual(session.takes.count, 5)
    }

    // MARK: A whole session through the trainer

    @MainActor func testAWholeSessionBuildsAVoiceThatCanBeSaved() async throws {
        let capture = FakeCapture()
        var generator = SeededTrainingGenerator(seed: 21)
        let trainer = OwnVoiceTrainer(capture: capture, checker: EchoChecker(), passages: OwnVoiceEnrollment.startingPassages(using: &generator),
                                      length: .init(target: 20, maximum: 30))
        capture.next = noise(3.2, amplitude: 0.0003)
        await trainer.checkRoom()
        XCTAssertEqual(trainer.session.stage, .takes, "the room check stops itself after three seconds")
        for take in trainer.session.takes {
            capture.next = silence(0.3) + voice(7, amplitude: 0.08) + silence(0.3)
            await trainer.record(take.id)
            XCTAssertTrue(trainer.isRecording)
            XCTAssertEqual(trainer.feedback, .good)
            trainer.stop()
            try await waitUntil { trainer.session.takes.first { $0.id == take.id }?.status == .accepted }
        }
        XCTAssertEqual(trainer.session.stage, .consent)
        capture.next = voice(3.5, amplitude: 0.08)
        await trainer.recordConsent()
        trainer.stop()
        try await waitUntil { trainer.session.stage == .preview }
        let reference = try XCTUnwrap(trainer.reference)
        XCTAssertGreaterThanOrEqual(reference.seconds, 20)
        XCTAssertEqual(OwnVoiceAudio.speechLevel(reference.samples), OwnVoiceAudio.targetLevel, accuracy: 1)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("own-voice-training-" + UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let store = OwnVoiceStore(folder: { folder })
        let take = try XCTUnwrap(try trainer.finishedTake(model: "test"))
        try store.save(take)
        let record = try XCTUnwrap(store.record)
        XCTAssertEqual(record.passages?.count, 4)
        XCTAssertEqual(record.takeCount, 4)
        XCTAssertEqual(record.heardPassages, trainer.session.takes.map(\.passage.text))
        XCTAssertEqual(record.reference?.count, reference.segments.count)
        XCTAssertEqual(record.consentLine, OwnVoiceEnrollment.consentLine)
        XCTAssertEqual(record.sampleSeconds, reference.seconds, accuracy: 0.01)
        XCTAssertFalse(FileManager.default.fileExists(atPath: take.sampleFile.path), "the temporary files are gone")

        // Record more and Start over.
        trainer.recordMore()
        XCTAssertEqual(trainer.session.takes.count, 5)
        XCTAssertEqual(trainer.session.stage, .takes)
        trainer.startOver()
        XCTAssertEqual(trainer.session.stage, .roomCheck)
        XCTAssertNil(trainer.reference)
        XCTAssertNil(try trainer.finishedTake(model: "test"), "nothing to save after Start over")
        await store.delete()
    }

    @MainActor func testAClippedTakeIsRejectedLive() async throws {
        let capture = FakeCapture()
        let trainer = OwnVoiceTrainer(capture: capture, checker: EchoChecker())
        capture.next = noise(3.2, amplitude: 0.0003)
        await trainer.checkRoom()
        let id = try XCTUnwrap(trainer.session.currentTake?.id)
        capture.next = tone(200, seconds: 6, amplitude: 1.5).map { max(-1, min(1, $0)) }
        await trainer.record(id)
        XCTAssertTrue(trainer.clipping)
        XCTAssertEqual(trainer.feedback, .tooLoud)
        trainer.stop()
        XCTAssertEqual(trainer.session.takes.first?.status, .redo(OwnVoiceAudio.TakeProblem.clipped.message))
    }

    @MainActor func testWithoutTheMicrophoneItSaysSoAndNothingStarts() async {
        let capture = FakeCapture()
        capture.fails = true
        let trainer = OwnVoiceTrainer(capture: capture, checker: EchoChecker())
        await trainer.checkRoom()
        XCTAssertEqual(trainer.problem, OwnVoiceTrainer.Failure.microphone.errorDescription)
        XCTAssertEqual(trainer.session.room, .notStarted)
        XCTAssertFalse(trainer.isRecording)
    }

    func testAVoiceMadeBeforeTheMultiTakeFlowStillLoads() throws {
        let old = #"{"consentLine":"c","createdAt":"2026-09-25T10:00:00Z","heardConsent":"h","heardPassage":"p","model":"m","passage":"p","sampleSeconds":9.5}"#
        let record = try JSONDecoder.ownVoice.decode(OwnVoiceRecord.self, from: Data(old.utf8))
        XCTAssertEqual(record.takeCount, 1)
        XCTAssertNil(record.reference)
    }

    // MARK: Helpers

    @MainActor private func waitUntil(_ condition: @MainActor () -> Bool, timeout: TimeInterval = 20) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// Delivers the samples it's given, all at once, like a microphone that's very fast.
@MainActor private final class FakeCapture: OwnVoiceCapture {
    var next: [Float] = []
    var fails = false
    func start(_ deliver: @escaping @MainActor ([Float]) -> Void) async throws {
        if fails { throw OwnVoiceTrainer.Failure.microphone }
        let samples = next
        for start in stride(from: 0, to: samples.count, by: 2_400) { deliver(Array(samples[start..<min(samples.count, start + 2_400)])) }
    }
    func stop() {}
}

/// Hears exactly what was on screen.
private struct EchoChecker: OwnVoiceChecking {
    func transcript(of _: [Float], expected: String) async throws -> String { expected }
}

private struct SeededTrainingGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

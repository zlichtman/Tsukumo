import AVFoundation
import XCTest
@testable import KemoSabeMac

/// Real on-device synthesis with the pinned models, on this Mac's GPU. It downloads about
/// 580 MB the first time into a temporary folder (`$TMPDIR/KemoSabeVoiceModelTests`, reused
/// until the system clears it), so it runs only when asked:
/// `TEST_RUNNER_KEMO_VOICE_INTEGRATION=1 xcodebuild test …`.
final class NeuralVoiceIntegrationTests: XCTestCase {
    private var cache: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("KemoSabeVoiceModelTests", isDirectory: true)
    }
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KEMO_VOICE_INTEGRATION"] == "1",
                          "Set TEST_RUNNER_KEMO_VOICE_INTEGRATION=1 to download the models and synthesize on this Mac.")
        try XCTSkipUnless(NeuralSpeechRuntime.isSupported, "Needs a Metal GPU")
    }

    @MainActor private func installed(_ pack: VoiceModelPack) async throws -> VoiceModelStore {
        let store = VoiceModelStore(pack: pack, root: cache)
        store.wifiOnly = false
        if !store.isInstalled { store.download(); await store.waitUntilDone() }
        XCTAssertEqual(store.state, .installed, "\(pack.id): \(store.state)")
        return store
    }

    @MainActor func testKokoroSpeaksOnThisMac() async throws {
        let store = try await installed(.kokoro)
        let engine = KokoroSpeechEngine(store: store)
        XCTAssertTrue(engine.isAvailable)
        XCTAssertNil(engine.destination)
        let started = Date()
        let audio = try await engine.synthesize("Hello! I'm Kemo, speaking with Kokoro on this Mac. Nothing left the device.", voice: "af_heart")
        let seconds = Date().timeIntervalSince(started)
        // Warm: the model is loaded, so this is the per-sentence latency a reply sees.
        let warmStart = Date()
        let warm = try await engine.synthesize("What would make today a good day?", voice: "af_heart")
        let warmSeconds = Date().timeIntervalSince(warmStart)
        XCTAssertGreaterThan(warm.duration, 0.8)
        guard case .pcm(let samples, let rate) = audio.payload else { return XCTFail("expected PCM") }
        XCTAssertEqual(rate, 24_000)
        XCTAssertGreaterThan(audio.duration, 2, "a sentence of speech")
        XCTAssertLessThan(audio.duration, 15)
        XCTAssertGreaterThan(Self.rms(samples), 0.01, "not silence")
        XCTAssertTrue(samples.allSatisfy(\.isFinite))
        let out = cache.appendingPathComponent("kokoro-af_heart.wav")
        try audio.playableData().write(to: out)
        print("KOKORO-TIMING cold: \(String(format: "%.2f", audio.duration)) s of audio in \(String(format: "%.2f", seconds)) s (includes loading); warm: \(String(format: "%.2f", warm.duration)) s of audio in \(String(format: "%.2f", warmSeconds)) s → \(out.path)")

        // A second voice from the same loaded model.
        let other = try await engine.synthesize("And this is Puck.", voice: "am_puck")
        XCTAssertGreaterThan(Self.rms(other.pcmSamples), 0.01)
        try other.playableData().write(to: cache.appendingPathComponent("kokoro-am_puck.wav"))
    }

    /// The own-voice pipeline end to end. The reference here is Kokoro's synthetic voice, not a
    /// person; in the app only a live recording with spoken consent can be the reference.
    @MainActor func testOwnVoicePipelineClonesFromAReferenceOnThisMac() async throws {
        let kokoro = try await installed(.kokoro)
        let pocket = try await installed(.pocketTTS)
        let passage = try XCTUnwrap(OwnVoiceEnrollment.passages.first)
        let reference = try await KokoroSpeechEngine(store: kokoro).synthesize(passage, voice: "am_michael")
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("own-voice-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let sample = scratch.appendingPathComponent("take.wav"), consent = scratch.appendingPathComponent("consent.wav")
        try reference.playableData().write(to: sample)
        try reference.playableData().write(to: consent)
        let own = OwnVoiceStore(folder: { scratch.appendingPathComponent("Voice") })
        try own.save(.forTesting(sampleFile: sample, consentFile: consent, record: .init(
            createdAt: .now, passage: passage, consentLine: OwnVoiceEnrollment.consentLine,
            heardPassage: "", heardConsent: "", sampleSeconds: reference.duration, model: "test")))
        let engine = OwnVoiceSpeechEngine(store: pocket, voice: own)
        XCTAssertTrue(engine.isAvailable)
        let started = Date()
        let audio = try await engine.synthesize("This is how your Kemo will sound when it reads a reply.", voice: nil)
        XCTAssertGreaterThan(audio.duration, 1.5)
        XCTAssertGreaterThan(Self.rms(audio.pcmSamples), 0.01)
        try audio.playableData().write(to: cache.appendingPathComponent("own-voice-from-kokoro.wav"))
        print("POCKET-TIMING: \(String(format: "%.2f", audio.duration)) s of audio in \(String(format: "%.2f", Date().timeIntervalSince(started))) s (includes loading)")
        await own.delete()
        XCTAssertFalse(own.isEnrolled)
    }

    /// The clone follows whoever recorded the sample: a higher reference voice gives a higher
    /// cloned voice. (Kokoro's Heart and Michael stand in for two people.)
    @MainActor func testTheCloneFollowsTheRecordedVoice() async throws {
        let kokoro = try await installed(.kokoro)
        let pocket = try await installed(.pocketTTS)
        let passage = try XCTUnwrap(OwnVoiceEnrollment.passages.dropFirst().first)
        let higher = try await KokoroSpeechEngine(store: kokoro).synthesize(passage, voice: "af_heart")
        let lower = try await KokoroSpeechEngine(store: kokoro).synthesize(passage, voice: "am_michael")
        var pitches: [Float] = []
        for reference in [higher, lower] {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("own-voice-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let sample = scratch.appendingPathComponent("take.wav"), consent = scratch.appendingPathComponent("consent.wav")
            try reference.playableData().write(to: sample)
            try reference.playableData().write(to: consent)
            let own = OwnVoiceStore(folder: { scratch.appendingPathComponent("Voice") })
            try own.save(.forTesting(sampleFile: sample, consentFile: consent, record: .init(
                createdAt: .now, passage: passage, consentLine: OwnVoiceEnrollment.consentLine,
                heardPassage: "", heardConsent: "", sampleSeconds: reference.duration, model: "test")))
            let clone = try await OwnVoiceSpeechEngine(store: pocket, voice: own)
                .synthesize("Here's what I found, and one thing we could do next.", voice: nil)
            let pitch = try XCTUnwrap(Self.medianPitch(clone.pcmSamples, sampleRate: 24_000), "no voiced frames")
            pitches.append(pitch)
            await own.delete()
        }
        let high = try XCTUnwrap(pitches.first), low = try XCTUnwrap(pitches.last)
        print("CLONE-PITCH from Heart: \(Int(high)) Hz, from Michael: \(Int(low)) Hz")
        XCTAssertGreaterThan(high, low + 30, "the clone should follow the recorded voice")
    }

    /// Median fundamental frequency of the voiced 40 ms frames, by autocorrelation (70–400 Hz).
    private static func medianPitch(_ samples: [Float], sampleRate: Int) -> Float? {
        let frame = sampleRate / 25, hop = sampleRate / 100
        let shortest = sampleRate / 400, longest = sampleRate / 70
        guard samples.count > frame, longest < frame else { return nil }
        var found: [Float] = []
        var start = 0
        while start + frame <= samples.count {
            let window = Array(samples[start..<(start + frame)])
            start += hop
            let mean = window.reduce(0, +) / Float(frame)
            let centered = window.map { $0 - mean }
            let energy = centered.reduce(0) { $0 + $1 * $1 }
            guard (energy / Float(frame)).squareRoot() > 0.02 else { continue }
            var bestLag = 0, best: Float = 0
            for lag in shortest...longest {
                var sum: Float = 0
                for index in 0..<(frame - lag) { sum += centered[index] * centered[index + lag] }
                if sum > best { best = sum; bestLag = lag }
            }
            if bestLag > 0, best > 0.4 * energy { found.append(Float(sampleRate) / Float(bestLag)) }
        }
        guard !found.isEmpty else { return nil }
        return found.sorted()[found.count / 2]
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }
}

private extension SpeechAudio {
    var pcmSamples: [Float] { if case .pcm(let samples, _) = payload { return samples }; return [] }
}

import AVFoundation
import XCTest
@testable import KemoSabe

final class LocalSpeechRecognitionTests: XCTestCase {
    func testFinalizedRequestPrefixSurvivesLatePartialAndFollowingPhrase() {
        var transcript = LocalTranscript()
        _ = transcript.replace(start: 0, end: 2, text: "Can you please", final: true)
        XCTAssertEqual(transcript.replace(start: 0, end: 2, text: "please"), "Can you please")
        _ = transcript.replace(start: 2, end: 3, text: "do your")
        XCTAssertEqual(transcript.replace(start: 2, end: 4, text: "do your animation", final: true), "Can you please do your animation")
        XCTAssertEqual(VoiceCommand.parse(transcript.rendered), .perform(.dance))
    }
    func testPartialRangesReplaceInsteadOfRepeating() {
        var transcript = LocalTranscript()
        XCTAssertEqual(transcript.replace(start: 0, end: 1, text: " Turn on"), "Turn on")
        XCTAssertEqual(transcript.replace(start: 0, end: 2, text: "Turn on the music."), "Turn on the music.")
        XCTAssertEqual(transcript.replace(start: 2, end: 3, text: " Please."), "Turn on the music. Please.")
        XCTAssertEqual(transcript.replace(start: 2, end: 3.5, text: "Actually, jazz."), "Turn on the music. Actually, jazz.")
    }

    func testInvalidAndRepeatedResultsCannotDuplicateTranscript() {
        var transcript = LocalTranscript()
        _ = transcript.replace(start: 0, end: 1, text: "Hello.")
        XCTAssertEqual(transcript.replace(start: 0, end: 1, text: "Hello."), "Hello.")
        XCTAssertEqual(transcript.replace(start: .nan, end: 2, text: "bad"), "Hello.")
        XCTAssertEqual(transcript.replace(start: 3, end: 2, text: "bad"), "Hello.")
        XCTAssertEqual(transcript.replace(start: 0, end: 4, text: String(repeating: "a", count: 5000)).count, 4000)
    }

    func testAudioPacketOwnsCopyNotRecycledTapMemory() throws {
        let original = try buffer(rate: 48_000, channels: 2)
        original.floatChannelData![0][0] = 0.25
        original.floatChannelData![1][0] = 0.5
        let packet = try SpeechAudioPacket(copying: original)
        original.floatChannelData![0][0] = 1
        original.floatChannelData![1][0] = 1
        XCTAssertEqual(packet.buffer.frameLength, original.frameLength)
        XCTAssertEqual(packet.buffer.floatChannelData![0][0], 0.25)
        XCTAssertEqual(packet.buffer.floatChannelData![1][0], 0.5)
    }

    func testEmptyAudioIsRejectedWithoutCrashing() throws {
        let empty = try buffer(rate: 48_000, channels: 1)
        empty.frameLength = 0
        XCTAssertThrowsError(try SpeechAudioPacket(copying: empty))
    }

    func testResamplingHardwareAudioToAnalyzerFormat() throws {
        let output = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let converter = SpeechPCMConverter(outputFormat: output)
        for rate in [48_000.0, 44_100.0] {
            let input = try buffer(rate: rate, channels: 2)
            let converted = try converter.convert(input)
            XCTAssertEqual(converted.format, output)
            XCTAssertGreaterThan(converted.frameLength, 0)
            XCTAssertLessThanOrEqual(converted.frameLength, 1_650)
        }
    }

    func testMatchingFormatNeedsNoAdditionalConversion() throws {
        let original = try buffer(rate: 16_000, channels: 1)
        let converter = SpeechPCMConverter(outputFormat: original.format)
        XCTAssertTrue(try converter.convert(original) === original)
    }

    func testDisconnectFinishesStreamAndDoesNotDeliverLaterAudio() async throws {
        let bridge = SpeechAudioBridge(), stream = bridge.connect()
        let input = try buffer(rate: 16_000, channels: 1)
        bridge.append(input); bridge.disconnect(); bridge.append(input)
        var count = 0
        for try await _ in stream { count += 1 }
        XCTAssertEqual(count, 1)
    }

    func testSlowConsumerFailsRatherThanDroppingWordsSilently() async throws {
        let bridge = SpeechAudioBridge(), stream = bridge.connect()
        let input = try buffer(rate: 16_000, channels: 1)
        for _ in 0..<20 { bridge.append(input) }
        var count = 0
        do {
            for try await _ in stream { count += 1 }
            XCTFail("Overflow must abort recognition")
        } catch { XCTAssertTrue(error is LocalSpeechError) }
        XCTAssertEqual(count, 12)
    }

    func testConnectingNewCycleRetiresOldStream() async throws {
        let bridge = SpeechAudioBridge(), old = bridge.connect(), new = bridge.connect()
        bridge.append(try buffer(rate: 16_000, channels: 1)); bridge.disconnect()
        var oldCount = 0, newCount = 0
        for try await _ in old { oldCount += 1 }
        for try await _ in new { newCount += 1 }
        XCTAssertEqual(oldCount, 0); XCTAssertEqual(newCount, 1)
    }

    private func buffer(rate: Double, channels: AVAudioChannelCount) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate / 10)))
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<Int(channels) {
            buffer.floatChannelData![channel].initialize(repeating: 0, count: Int(buffer.frameLength))
        }
        return buffer
    }
}

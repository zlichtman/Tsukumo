import XCTest
@testable import KemoSabe

final class WatchLinkTests: XCTestCase {
    func testMessagesRoundTrip() throws {
        let ask = WatchLink.Ask(text: "What's next today?")
        XCTAssertEqual(try WatchLink.decode(WatchLink.Ask.self, from: WatchLink.encode(ask)), ask)
        let clip = WatchLink.Ask(audio: Data(repeating: 7, count: 1_000))
        XCTAssertEqual(try WatchLink.decode(WatchLink.Ask.self, from: WatchLink.encode(clip)), clip)
        let reply = WatchLink.Reply(id: ask.id, status: .answered, text: "Standup at 10.", heard: "what's next today", model: "Apple on-device")
        XCTAssertEqual(try WatchLink.decode(WatchLink.Reply.self, from: WatchLink.encode(reply)), reply)
        let status = WatchLink.Status(model: "Work model", ready: true, destination: "models.example.com")
        XCTAssertEqual(try WatchLink.decode(WatchLink.Status.self, from: WatchLink.encode(status)), status)
    }
    func testStatusCarriesTheIPhoneLookAndVoice() throws {
        let status = WatchLink.Status(model: "Apple on-device", ready: true,
            palette: .init(BotTheme.presets[2]), theme: .init(background: "111111", foreground: "FCFCFC", accent: "0169CC"),
            voice: .init(identifier: "com.apple.voice.compact.en-US.Samantha", language: "en-US", name: "Samantha", rate: 0.48))
        XCTAssertEqual(try WatchLink.decode(WatchLink.Status.self, from: WatchLink.encode(status)), status)
        XCTAssertEqual(status.palette, .init(id: "lavender", name: "Lavender", body: "E2D9F5", accent: "8563BD", tinted: true))
        let reply = WatchLink.Reply(id: UUID(), status: .answered, text: "See **this**.", spoken: "See this.", review: true)
        XCTAssertEqual(try WatchLink.decode(WatchLink.Reply.self, from: WatchLink.encode(reply)), reply)
    }
    /// The iPhone and watch apps update separately, so each must read the other's build 33 messages.
    func testBuild33MessagesStillDecode() throws {
        struct Build33Status: Codable { var model: String; var ready: Bool; var note: String; var destination: String? }
        struct Build33Reply: Codable { var id: UUID; var status: WatchLink.Reply.Status; var text: String; var heard: String?; var model: String }
        let status = try WatchLink.decode(WatchLink.Status.self, from: WatchLink.encode(Build33Status(model: "Apple on-device", ready: true, note: "", destination: nil)))
        XCTAssertEqual(status, WatchLink.Status(model: "Apple on-device", ready: true))
        XCTAssertNil(status.palette); XCTAssertNil(status.theme); XCTAssertNil(status.voice)
        let id = UUID()
        let reply = try WatchLink.decode(WatchLink.Reply.self, from: WatchLink.encode(Build33Reply(id: id, status: .answered, text: "Hi", heard: nil, model: "Apple on-device")))
        XCTAssertEqual(reply, WatchLink.Reply(id: id, status: .answered, text: "Hi", model: "Apple on-device"))
        // And a build 33 app ignores the new fields.
        let current = WatchLink.Status(model: "M", ready: false, note: "n", palette: .init(BotTheme.presets[1]))
        XCTAssertEqual(try WatchLink.decode(Build33Status.self, from: WatchLink.encode(current)).note, "n")
        let answered = WatchLink.Reply(id: id, status: .answered, text: "Hi", spoken: "Hi", review: true)
        XCTAssertEqual(try WatchLink.decode(Build33Reply.self, from: WatchLink.encode(answered)).text, "Hi")
    }
    func testLimitsRejectEmptyAndOversizedRequests() {
        XCTAssertNil(WatchLink.problem(with: .init(text: "Hi Kemo")))
        XCTAssertNotNil(WatchLink.problem(with: .init(text: "  \n ")))
        XCTAssertNotNil(WatchLink.problem(with: .init(text: String(repeating: "a", count: WatchLink.maxTextLength + 1))))
        XCTAssertNil(WatchLink.problem(with: .init(audio: Data(count: WatchLink.maxAudioBytes))))
        XCTAssertNotNil(WatchLink.problem(with: .init(audio: Data())))
        XCTAssertNotNil(WatchLink.problem(with: .init(audio: Data(count: WatchLink.maxAudioBytes + 1))))
    }
    func testFullLengthClipFitsOneMessage() throws {
        // 20 s at 12 kbps is about 30 KB of audio before container overhead.
        let bytes = Int(WatchLink.maxRecordingSeconds * 12_000 / 8)
        XCTAssertLessThan(bytes * 3 / 2, WatchLink.maxAudioBytes)
        let encoded = try WatchLink.encode(WatchLink.Ask(audio: Data(count: WatchLink.maxAudioBytes)))
        XCTAssertLessThan(encoded.count, 64 * 1024)
    }
    func testLongRepliesAreTrimmedForTheWatch() {
        XCTAssertEqual(WatchLink.trimmed("Short"), "Short")
        let long = String(repeating: "b", count: WatchLink.maxReplyLength + 50)
        let trimmed = WatchLink.trimmed(long)
        XCTAssertEqual(trimmed.count, WatchLink.maxReplyLength)
        XCTAssertTrue(trimmed.hasSuffix("…"))
    }
}

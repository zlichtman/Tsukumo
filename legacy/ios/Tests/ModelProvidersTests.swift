import XCTest
@testable import KemoSabe

/// Claude's native format and the provider presets: requests are built from the same approved
/// packet, streams are read safely, and model lists offer chat models only.
final class ModelProvidersTests: XCTestCase {
    func testClaudeProfilesUseTheMessagesEndpoint() throws {
        let claude = try APIModelProfile.validated(name: "Claude", endpoint: APIModelPreset.claude.endpoint, model: "claude-opus-5", format: .anthropic)
        XCTAssertEqual(claude.wire, .anthropic)
        XCTAssertThrowsError(try APIModelProfile.validated(name: "Claude", endpoint: "https://api.anthropic.com/v1/chat/completions", model: "claude-opus-5", format: .anthropic))
        let openAI = try APIModelProfile.validated(name: "OpenAI", endpoint: APIModelPreset.openAI.endpoint, model: "gpt-5")
        XCTAssertNil(openAI.format, "OpenAI-compatible profiles stay readable by older builds")
        XCTAssertEqual(openAI.wire, .openAICompatible)
    }
    func testClaudeRequestSeparatesTheSystemAndAlternatesTurns() throws {
        let packet = try ExternalConversationPacket.make(message: "And tomorrow?", history: [
            ChatMessage(role: "KemoSabe", text: "Hi! What should I call you?"),
            ChatMessage(role: "You", text: "What's the weather like?"), ChatMessage(role: "You", text: "In Austin"),
            ChatMessage(role: "KemoSabe", text: "Sunny.")])
        let body = AnthropicMessagesBody(packet: packet, model: "claude-opus-5", stream: true)
        XCTAssertFalse(body.system.isEmpty)
        XCTAssertEqual(body.messages.map(\.role), ["user", "assistant", "user"], "Leading assistant turns dropped, repeated roles merged")
        XCTAssertEqual(body.messages.first?.content.count, 2)
        XCTAssertEqual(body.fallbacks, "default")
        XCTAssertNil(AnthropicMessagesBody(packet: packet, model: "claude-haiku-4-5", stream: true).fallbacks)
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(body), encoding: .utf8))
        XCTAssertTrue(json.contains("\"max_tokens\""))
        XCTAssertFalse(json.contains("\"role\":\"system\""))
    }
    func testClaudeStreamKeepsTextSkipsThinkingAndRejectsRefusals() throws {
        var decoder = AnthropicStreamDecoder()
        for line in [
            #"data: {"type":"message_start","message":{}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hello"}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":" there"}}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}"#,
            #"data: {"type":"message_stop"}"#] { try decoder.consume(line) }
        XCTAssertTrue(decoder.done)
        XCTAssertEqual(try decoder.completed(), "Hello there")
        var refused = AnthropicStreamDecoder()
        XCTAssertThrowsError(try refused.consume(#"data: {"type":"message_delta","delta":{"stop_reason":"refusal"}}"#)) {
            XCTAssertEqual($0 as? APIModelError, .refused)
        }
        XCTAssertEqual(try AnthropicStreamDecoder.jsonAnswer(Data(#"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"Hi"}],"stop_reason":"end_turn"}"#.utf8)), "Hi")
    }
    func testAPastedKeyIsRecognizedByItsPrefix() {
        XCTAssertEqual(APIModelPreset.detect(key: " sk-ant-api03-abc "), .claude)
        XCTAssertEqual(APIModelPreset.detect(key: "sk-proj-abc"), .openAI)
        XCTAssertNil(APIModelPreset.detect(key: "gsk_something"))
    }
    func testModelListsOfferChatModelsNewestFirst() throws {
        let openAI = Data(#"{"data":[{"id":"gpt-4o","created":100},{"id":"text-embedding-3-large","created":300},{"id":"gpt-5-codex","created":200},{"id":"whisper-1","created":50}]}"#.utf8)
        XCTAssertEqual(try APIModelCatalog.chatModels(in: openAI, preset: .openAI), ["gpt-5-codex", "gpt-4o"])
        let claude = Data(#"{"data":[{"id":"claude-opus-5","created_at":"2026-04-01T00:00:00Z"},{"id":"claude-sonnet-5","created_at":"2026-03-01T00:00:00Z"}]}"#.utf8)
        XCTAssertEqual(try APIModelCatalog.chatModels(in: claude, preset: .claude), ["claude-opus-5", "claude-sonnet-5"])
    }
    func testWatchSettingChangesSurviveTheWire() throws {
        for setting in [WatchLink.Setting.model(WatchLink.ModelChoice.onDevice), .palette("matcha"), .personality("calm"), .personality(nil)] {
            let data = try WatchLink.encode(WatchLink.Request.change(setting))
            XCTAssertEqual(try WatchLink.decode(WatchLink.Request.self, from: data), .change(setting))
        }
    }
}

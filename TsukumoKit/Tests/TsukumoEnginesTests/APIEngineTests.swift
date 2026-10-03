import Foundation
import Testing
import TsukumoCore
import TsukumoPolicy
import TsukumoContext
@testable import TsukumoEngines

/// API engines against stubbed URL loading (porting `APIModelTests`): both wire formats, streamed
/// and whole, tool calls, efforts, and status mapping. No network, no real keys.
struct APIEngineTests {
    let anthropic = try! APIConnection.validated(name: "Claude", endpoint: APIConnection.anthropicEndpoint, model: "claude-opus-4-5", wire: .anthropic)
    let openAI = try! APIConnection.validated(name: "OpenAI", endpoint: APIConnection.openAIEndpoint, model: "gpt-5.2", wire: .openAICompatible)

    func bot(_ connection: APIConnection, effort: Effort? = nil) -> BotSpec {
        BotSpec(name: "Pip", engine: .api(profile: connection.id), effort: effort, role: "Plans dates", look: .kemoSabe)
    }
    func engine(_ connection: APIConnection, _ handler: @escaping StubURLProtocol.Handler) -> (APIEngine, String) {
        let (session, id) = StubURLProtocol.session(handler)
        return (APIEngine(connection: connection, keys: MemoryAPIKeys([connection.id: "test-key-not-real"]), session: session), id)
    }
    func body(_ request: URLRequest) throws -> JSONValue { try TsukumoJSON.decoder.decode(JSONValue.self, from: request.httpBody ?? Data()) }
    func sse(_ events: [String]) -> Data { Data(events.map { "data: " + $0 + "\n\n" }.joined().utf8) }

    @Test func anthropicStreamsTextAndSendsTheDocumentedRequest() async throws {
        let stream = sse([#"{"type":"message_start"}"#,
                          #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
                          #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Osteria Lucia "}}"#,
                          #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"at 7:30"}}"#,
                          #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
                          #"{"type":"message_stop"}"#])
        let (engine, id) = engine(anthropic) { _ in (200, stream) }
        var deltas: [String] = []
        var reply: EngineReply?
        for try await event in engine.run(EngineTurn(bot: bot(anthropic, effort: "high"), message: "date spot tonight")) {
            if case .text(let delta) = event { deltas.append(delta) }
            if case .done(let done) = event { reply = done }
        }
        #expect(deltas == ["Osteria Lucia ", "at 7:30"])
        #expect(reply?.text == "Osteria Lucia at 7:30")
        let request = try #require(StubURLProtocol.requests(id).first)
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "test-key-not-real")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let sent = try body(request)
        #expect(sent["model"]?.stringValue == "claude-opus-4-5")
        #expect(sent["output_config"]?["effort"]?.stringValue == "high")
        #expect(sent["system"]?.stringValue?.contains("You are Pip") == true)
        #expect(sent["tools"] == nil, "No tools without a runner")
    }

    @Test func anEffortTheModelDoesntTakeIsNeverSent() async throws {
        let stream = sse([#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}"#,
                          #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#, #"{"type":"message_stop"}"#])
        let (engine, id) = engine(anthropic) { _ in (200, stream) }
        _ = try await engine.reply(EngineTurn(bot: bot(anthropic, effort: "max"), message: "hi"))
        #expect(try body(try #require(StubURLProtocol.requests(id).first))["output_config"] == nil)
    }

    @Test func openAIToolCallsReadReferencesThroughThePolicy() async throws {
        let store = try ArtifactStore()
        let menu = try await store.put(ArtifactDraft(kind: .note, level: .open, owner: .owner, summaryLine: "Restaurants", content: "Osteria Lucia, Valencia St"))
        _ = try await store.put(ArtifactDraft(kind: .note, level: .deviceOnly, owner: .owner, summaryLine: "Door code", content: "4417"))
        let recipient = RecipientID.apiModel(profile: openAI.id, host: "api.openai.com")
        let tools = TurnTools(store: store, recipient: recipient)
        let first = sse([#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"read_reference","arguments":"{\"id\":\"\#(menu.id)\","}}]}}]}"#,
                         #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"revision\":\"1\"}"}}]},"finish_reason":"tool_calls"}]}"#])
        let second = sse([#"{"choices":[{"index":0,"delta":{"content":"Try Osteria Lucia."},"finish_reason":"stop"}]}"#, "[DONE]"])
        let counter = Counter()
        let (engine, id) = engine(openAI) { _ in counter.next() == 0 ? (200, first) : (200, second) }
        let manifest = await store.manifest(for: recipient)
        let turn = EngineTurn(bot: bot(openAI, effort: "high"), message: "date spot", manifest: manifest, tools: tools.definitions,
                              runTool: { await tools.run($0) })
        var events: [EngineEvent] = []
        for try await event in engine.run(turn) { events.append(event) }
        guard case .done(let reply)? = events.last else { Issue.record("no reply"); return }
        #expect(reply.text == "Try Osteria Lucia." && reply.toolCalls.map(\.name) == ["read_reference"])
        let result = events.compactMap { if case .toolResult(_, let text) = $0 { text } else { nil } }.first
        #expect(result?.contains("Osteria Lucia, Valencia St") == true)

        let requests = StubURLProtocol.requests(id)
        #expect(requests.count == 2)
        let firstBody = try body(requests[0])
        #expect(firstBody["reasoning_effort"]?.stringValue == "high")
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer test-key-not-real")
        let system = try #require(firstBody["messages"].flatMap { if case .array(let m) = $0 { m.first?["content"]?.stringValue } else { nil } })
        #expect(system.contains("Restaurants") && !system.contains("Door code") && !system.contains("4417"))
        let replayed = String(decoding: requests[1].httpBody ?? Data(), as: UTF8.self)
        #expect(replayed.contains("call_1") && replayed.contains("\"role\":\"tool\""))
    }

    @Test func anthropicToolUseAsksKemoSabe() async throws {
        let asked = Recorder()
        let toolUse = Data(#"{"content":[{"type":"text","text":"Let me check."},{"type":"tool_use","id":"tu_1","name":"ask_kemosabe","input":{"question":"What time is Sarah free tonight?","purpose":"planning a date"}}],"stop_reason":"tool_use"}"#.utf8)
        let answer = Data(#"{"content":[{"type":"text","text":"Osteria Lucia at 7:30."}],"stop_reason":"end_turn"}"#.utf8)
        var connection = anthropic
        connection.streaming = false
        let counter = Counter()
        let (engine, id) = engine(connection) { _ in counter.next() == 0 ? (200, toolUse) : (200, answer) }
        let tools = TurnTools(store: try ArtifactStore(), recipient: .apiModel(profile: connection.id, host: "api.anthropic.com")) { question, purpose in
            asked.add(question + " | " + purpose)
            return "After 7 tonight"
        }
        let reply = try await engine.reply(EngineTurn(bot: bot(connection), message: "date spot", tools: tools.definitions, runTool: { await tools.run($0) }))
        #expect(reply.text == "Osteria Lucia at 7:30.")
        #expect(asked.all == ["What time is Sarah free tonight? | planning a date"])
        let replayed = try body(StubURLProtocol.requests(id)[1])
        let rendered = String(decoding: try TsukumoJSON.encoder.encode(replayed), as: UTF8.self)
        #expect(rendered.contains("tool_result") && rendered.contains("After 7 tonight") && rendered.contains("tu_1"))
        #expect(replayed["system"]?.stringValue?.contains("ask_kemosabe") == true)
    }

    @Test func statusesMapToWordsTheOwnerCanActOn() async {
        for (status, expected) in [(401, EngineError.denied), (403, .denied), (429, .limited), (529, .limited), (500, .unavailable)] {
            let (engine, _) = engine(anthropic) { _ in (status, Data()) }
            await #expect(throws: expected) { try await engine.reply(EngineTurn(bot: bot(anthropic), message: "hi")) }
        }
        let keyless = APIEngine(connection: anthropic, keys: MemoryAPIKeys(), session: StubURLProtocol.session { _ in (200, Data()) }.0)
        await #expect(throws: EngineError.missingKey) { try await keyless.reply(EngineTurn(bot: bot(anthropic), message: "hi")) }
    }

    @Test func refusalsAndBrokenStreamsAreNotAnswers() async {
        let refusal = sse([#"{"type":"message_delta","delta":{"stop_reason":"refusal"}}"#])
        let (refusing, _) = engine(anthropic) { _ in (200, refusal) }
        await #expect(throws: EngineError.refused) { try await refusing.reply(EngineTurn(bot: bot(anthropic), message: "hi")) }
        let cut = sse([#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"half"}}"#])
        let (cutting, _) = engine(anthropic) { _ in (200, cut) }
        await #expect(throws: EngineError.incomplete) { try await cutting.reply(EngineTurn(bot: bot(anthropic), message: "hi")) }
        let garbage = Data("data: {not json\n\n".utf8)
        let (broken, _) = engine(openAI) { _ in (200, garbage) }
        await #expect(throws: EngineError.incomplete) { try await broken.reply(EngineTurn(bot: bot(openAI), message: "hi")) }
    }

    @Test func connectionsAreValidated() {
        #expect(throws: EngineError.configuration) { try APIConnection.validated(name: "x", endpoint: "http://example.com/v1/chat/completions", model: "m", wire: .openAICompatible) }
        #expect(throws: EngineError.configuration) { try APIConnection.validated(name: "x", endpoint: "https://api.anthropic.com/v1/complete", model: "m", wire: .anthropic) }
        #expect(throws: EngineError.configuration) { try APIConnection.validated(name: "x", endpoint: "https://u:p@example.com/v1/chat/completions", model: "m", wire: .openAICompatible) }
        #expect((try? APIConnection.validated(name: "Local", endpoint: "http://localhost:11434/v1/chat/completions", model: "llama", wire: .openAICompatible)) != nil)
        let compatible = try? APIConnection.validated(name: "Other", endpoint: "https://example.com/v1/chat/completions", model: "o3", wire: .openAICompatible)
        #expect(compatible?.effortWire == .openAICompatible)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { defer { value += 1 }; return value } }
}

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ value: String) { lock.withLock { values.append(value) } }
    var all: [String] { lock.withLock { values } }
}

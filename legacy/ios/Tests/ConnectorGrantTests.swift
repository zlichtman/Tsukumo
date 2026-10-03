import XCTest
@testable import KemoSabe

/// Connected API models are separate recipients: each reads a connection only with its own grant,
/// through the same gate as every other read (`ToolRegistry`, `ActionGate`, and the day planner's
/// routine tools). No real permission, network, or paid model is used.
final class ConnectorGrantTests: XCTestCase {
    private let host = "grants.invalid"

    // MARK: Grant storage

    func testGrantsAreStoredPerModel() throws {
        var state = SavedState()
        let first = UUID(), second = UUID()
        state.setAPIGrant(.calendar, profile: first, allowed: true)
        state.setAPIGrant(.gmail, profile: first, allowed: true)
        XCTAssertEqual(state.apiGrants(first), [.calendar], "Only native connections can be granted")
        XCTAssertTrue(state.apiGrants(second).isEmpty, "A grant for one model never covers another")
        let decoded = try JSONDecoder().decode(SavedState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.apiGrants(first), [.calendar])
        state.setAPIGrant(.contacts, profile: first, allowed: true)
        XCTAssertEqual(state.apiGrants(first), [.calendar, .contacts])
        state.setAPIGrant(.calendar, profile: first, allowed: false)
        state.setAPIGrant(.contacts, profile: first, allowed: false)
        XCTAssertNil(state.apiConnectorGrants, "Nothing left behind once every grant is off")
        XCTAssertNil(state.recipientGrants, "Nothing left behind once every grant is off")
    }
    @MainActor func testRemovingAModelRemovesItsGrants() throws {
        let (store, folder, _) = try makeAPIStore(); defer { try? FileManager.default.removeItem(at: folder) }
        let profile = try XCTUnwrap(store.activeAPIProfile)
        store.setConnectorGrant(.calendar, for: profile, allowed: true)
        XCTAssertEqual(store.state.apiGrants(profile.id), [.calendar])
        try store.removeAPIProfile(profile)
        XCTAssertNil(store.state.apiConnectorGrants)
        XCTAssertNil(store.state.recipientGrants, "Its grants went with it")
    }

    // MARK: The gate

    @MainActor func testToolReadIsRefusedForAnUngrantedModelAndAllowedAfterAGrant() async throws {
        let profile = UUID()
        let counter = ReadCounter()
        func registry(_ recipient: ToolRecipient) -> ToolRegistry {
            ToolRegistry(deadline: Date().addingTimeInterval(30), lookup: { _ in [] }, read: { id, _ in
                counter.reads += 1
                return ConnectorReadResult(connector: id, fetchedAt: Date(), records: [.init(fields: ["title": "Standup"])], totalCount: 1)
            }, isCurrent: { true }, recipient: recipient)
        }
        let ungranted = registry(.apiModel(profile: profile, name: "Claude", host: host, granted: []))
        do {
            _ = try await ungranted.connector(.calendar, query: nil)
            XCTFail("An ungranted model must not read the calendar")
        } catch let error as ConnectorGrantRequired {
            XCTAssertEqual(error, ConnectorGrantRequired(connector: .calendar, profile: profile, modelName: "Claude", host: host))
            XCTAssertEqual(error.question, "Let Claude read your Calendar? Results are sent to grants.invalid.")
            XCTAssertTrue(error.localizedDescription.contains("Settings → Models"), "Says how to allow it")
        }
        XCTAssertEqual(counter.reads, 0)
        // The model's tool call takes the same path.
        do {
            _ = try await ungranted.run(ModelToolCall.make(id: "c1", index: 0, name: "find_contact", json: #"{"name":"Alex"}"#))
            XCTFail("An ungranted model must not look up contacts")
        } catch { XCTAssertTrue(error is ConnectorGrantRequired) }
        XCTAssertEqual(counter.reads, 0)

        let granted = registry(.apiModel(profile: profile, name: "Claude", host: host, granted: [.calendar]))
        let text = try await granted.connector(.calendar, query: nil)
        XCTAssertTrue(text.contains("Standup")); XCTAssertEqual(counter.reads, 1)
        do { _ = try await granted.connector(.reminders, query: nil); XCTFail("Granting Calendar doesn't grant Reminders") }
        catch { XCTAssertTrue(error is ConnectorGrantRequired) }
        _ = try await registry(.onDevice).connector(.reminders, query: nil)
        XCTAssertEqual(counter.reads, 2, "The on-device model needs no grant")

        XCTAssertThrowsError(try ActionGate.requireNativeRead(.calendar, enabled: [.calendar], permission: .allowed,
                                                               recipient: .apiModel(profile: profile, name: "Claude", host: host, granted: [])))
        XCTAssertNoThrow(try ActionGate.requireNativeRead(.calendar, enabled: [.calendar], permission: .allowed,
                                                           recipient: .apiModel(profile: profile, name: "Claude", host: host, granted: [.calendar])))
        XCTAssertThrowsError(try ActionGate.requireNativeRead(.calendar, enabled: [], permission: .allowed,
                                                               recipient: .apiModel(profile: profile, name: "Claude", host: host, granted: [.calendar]))) {
            XCTAssertEqual($0 as? ToolFailure, .missingPermission, "A grant never overrides a disconnected connection")
        }
        XCTAssertThrowsError(try ActionGate.requireNativeRead(.calendar, enabled: [.calendar], permission: .writeOnly))
    }
    @MainActor func testModelToolCallsAreBoundedBeforeReading() async throws {
        let counter = ReadCounter()
        let registry = ToolRegistry(deadline: Date().addingTimeInterval(30), lookup: { _ in [] }, read: { id, query in
            counter.reads += 1; counter.queries.append(query)
            return ConnectorReadResult(connector: id, fetchedAt: Date(), records: [], totalCount: 0)
        }, isCurrent: { true }, recipient: .apiModel(profile: UUID(), name: "M", host: host, granted: [.calendar, .contacts]))
        XCTAssertThrowsError(try ModelToolCall.make(id: "c", index: 0, name: "delete_everything", json: "{}"))
        XCTAssertThrowsError(try ModelToolCall.make(id: "c", index: 0, name: "find_contact", json: #"{"name":{"nested":true}}"#))
        let badDay = try await registry.run(ModelToolCall.make(id: "c", index: 0, name: "read_calendar", json: #"{"day":"next year"}"#))
        XCTAssertTrue(badDay.hasPrefix("Nothing was read")); XCTAssertEqual(counter.reads, 0)
        _ = try await registry.run(ModelToolCall.make(id: "c", index: 0, name: "read_calendar", json: #"{"day":"tomorrow"}"#))
        _ = try await registry.run(ModelToolCall.make(id: nil, index: 1, name: "find_contact", json: #"{"name":"Alex"}"#))
        XCTAssertEqual(counter.queries, ["tomorrow", "Alex"])
        XCTAssertEqual(ConnectorSource.calendarDayOffset("Tomorrow"), 1); XCTAssertEqual(ConnectorSource.calendarDayOffset(nil), 0)
    }
    /// The day planner's calendar and reminders tools pass the same gate as every other read.
    @MainActor func testRoutineToolsFollowTheSameGate() {
        let tools = AppleRoutineTools()
        tools.enabled = { [.calendar] }
        tools.permission = { _ in .allowed }
        XCTAssertNoThrow(try tools.require(false))
        tools.recipient = { .apiModel(profile: UUID(), name: "Claude", host: "api.anthropic.com", granted: []) }
        XCTAssertThrowsError(try tools.require(false)) { XCTAssertTrue($0 is ConnectorGrantRequired) }
        tools.recipient = { .apiModel(profile: UUID(), name: "Claude", host: "api.anthropic.com", granted: [.calendar]) }
        XCTAssertNoThrow(try tools.require(false))
        tools.recipient = { .onDevice }
        XCTAssertThrowsError(try tools.require(true)) { XCTAssertEqual($0 as? ToolFailure, .missingPermission, "Reminders isn't on") }
        tools.enabled = { [] }
        XCTAssertThrowsError(try tools.require(false)) { XCTAssertEqual($0 as? ToolFailure, .missingPermission) }
        tools.enabled = { [.calendar] }; tools.permission = { _ in .writeOnly }
        XCTAssertThrowsError(try tools.require(false)) { XCTAssertEqual($0 as? ToolFailure, .missingPermission, "Add events only can't plan") }
    }
    @MainActor func testRoutineToolsUseTheSameConnectedState() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = AppStore(repository: .init(url: folder.appendingPathComponent("state.json")), provider: DelayedProvider(),
                             nativeConnections: MockConnectionClient(permission: .allowed))
        XCTAssertNoThrow(try store.dailyAssistant.native.require(false), "Permission granted anywhere counts")
        store.state.markDisconnected(.calendar)
        XCTAssertThrowsError(try store.dailyAssistant.native.require(false))
    }

    // MARK: A connected model, end to end

    @MainActor func testAConnectedModelAsksBeforeReadingAndAnswersAfterAllow() async throws {
        let (store, folder, client) = try makeAPIStore(); defer { try? FileManager.default.removeItem(at: folder) }
        let profile = try XCTUnwrap(store.activeAPIProfile)

        store.send("What's on my calendar today?")
        try await waitUntil { !store.isThinking }
        XCTAssertEqual(client.reads, 0, "Nothing is read without this model's grant")
        XCTAssertEqual(GrantFixture.bodies.count, 1, "Nothing more is sent after the refused call")
        let pending = try XCTUnwrap(store.pendingConnectorGrant)
        XCTAssertEqual(pending.connector, .calendar)
        XCTAssertEqual(pending.required.question, "Let Claude read your Calendar? Results are sent to grants.invalid.")
        let note = try XCTUnwrap(store.conversationMessages.last)
        XCTAssertEqual(note.role, "KemoSabe")
        XCTAssertTrue(note.text.contains("Claude") && note.text.contains("Calendar") && note.text.contains("Settings → Models"), note.text)
        XCTAssertNil(store.error, "A plain answer, not a generic failure")
        let first = try XCTUnwrap(GrantFixture.bodies.first)
        XCTAssertEqual((first["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }, ["read_calendar", "read_reminders", "find_contact"])
        XCTAssertNil(first["tool_choice"])

        // Allow once: the same message is answered again, with the read, and nothing is saved.
        store.resolveConnectorGrant(.once)
        try await waitUntil { !store.isThinking }
        XCTAssertEqual(client.reads, 1)
        XCTAssertEqual(store.conversationMessages.last?.text, "You have standup at nine.")
        XCTAssertEqual(store.conversationMessages.filter { $0.role == "You" }.count, 1, "The question isn't repeated")
        XCTAssertFalse(store.conversationMessages.contains { $0.id == pending.noteID }, "The permission note is replaced by the answer")
        XCTAssertTrue(store.state.apiGrants(profile.id).isEmpty, "Allow once isn't remembered")
        let answered = try XCTUnwrap(GrantFixture.bodies.last)
        let results = try XCTUnwrap(answered["messages"] as? [[String: Any]]).flatMap { ($0["content"] as? [[String: Any]]) ?? [] }
            .filter { $0["type"] as? String == "tool_result" }
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue((results.first?["content"] as? String)?.contains("A sourced result.") == true, "Only what the tool returned is sent")
        XCTAssertNil(store.pendingConnectorGrant)

        // The next request asks again; Always remembers it for this model only.
        store.send("Anything else today?")
        try await waitUntil { !store.isThinking }
        XCTAssertEqual(client.reads, 1); XCTAssertNotNil(store.pendingConnectorGrant)
        store.resolveConnectorGrant(.always)
        try await waitUntil { !store.isThinking }
        XCTAssertEqual(client.reads, 2)
        XCTAssertEqual(store.state.apiGrants(profile.id), [.calendar])
        store.send("And now?")
        try await waitUntil { !store.isThinking }
        XCTAssertEqual(client.reads, 3); XCTAssertNil(store.pendingConnectorGrant, "No prompt once allowed")

        // Recorded like on-device reads: content-free, with where the result went.
        let runs = try await store.contextJournal.snapshot()
        XCTAssertTrue(runs.contains { $0.tools?.contains { $0.name == "calendar" && $0.sentTo == host } == true })

        // Don't allow leaves the plain answer and reads nothing.
        store.setConnectorGrant(.calendar, for: profile, allowed: false)
        store.send("One more time?")
        try await waitUntil { !store.isThinking }
        store.resolveConnectorGrant(.deny)
        XCTAssertEqual(client.reads, 3); XCTAssertNil(store.pendingConnectorGrant)
        XCTAssertTrue(store.conversationMessages.last?.text.contains("isn’t allowed") == true)
    }
    @MainActor func testAnotherModelDoesNotInheritAGrant() throws {
        let (store, folder, _) = try makeAPIStore(); defer { try? FileManager.default.removeItem(at: folder) }
        let first = try XCTUnwrap(store.activeAPIProfile)
        store.setConnectorGrant(.calendar, for: first, allowed: true)
        let other = try APIModelProfile.validated(name: "Local", endpoint: "http://localhost:11434/v1/chat/completions", model: "llama")
        try store.addAPIProfile(other, key: "local-key"); try store.selectAPIProfile(other)
        XCTAssertTrue(store.state.apiGrants(other.id).isEmpty)
        XCTAssertFalse(store.offersConnectorTools(other), "A local server without grants stays a plain chat")
        XCTAssertTrue(store.offersConnectorTools(first))
        store.setConnectorGrant(.reminders, for: other, allowed: true)
        XCTAssertTrue(store.offersConnectorTools(other))
        XCTAssertEqual(store.state.apiGrants(first.id), [.calendar])
    }
    @MainActor func testToolsForOneModelAreRefusedByAnother() async throws {
        let profile = try APIModelProfile.validated(name: "A", endpoint: "https://a.invalid/v1/messages", model: "m", format: .anthropic)
        let model = CompatibleAPIModel(profile: profile, key: "k")
        let foreign = ToolRegistry(deadline: Date().addingTimeInterval(30), lookup: { _ in [] }, read: { _, _ in throw ToolFailure.unavailable },
                                   isCurrent: { true }, recipient: .apiModel(profile: UUID(), name: "B", host: "b.invalid", granted: [.calendar]))
        let local = ToolRegistry(deadline: Date().addingTimeInterval(30), lookup: { _ in [] }, read: { _, _ in throw ToolFailure.unavailable }, isCurrent: { true },
                                 recipient: .onDevice)
        for tools in [foreign, local] {
            do { _ = try await model.streamImages(to: "Hi", history: [], images: [], tools: tools, onSnapshot: { _ in }); XCTFail("Wrong recipient") }
            catch { XCTAssertEqual(error as? APIModelError, .disclosure) }
        }
    }

    // MARK: Each provider's tool calling

    func testOpenAIStreamedToolCallsAreCollected() throws {
        var decoder = CompatibleStreamDecoder(acceptsTools: true)
        for line in [
            #"data: {"choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"find_contact","arguments":""}}]},"finish_reason":null}]}"#,
            #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"name\":"}}]},"finish_reason":null}]}"#,
            #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"Alex\"}"}}]},"finish_reason":null}]}"#,
            #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#, "data: [DONE]"] { try decoder.consume(line) }
        guard case let .tools(calls, text) = try decoder.completedTurn() else { return XCTFail("Expected a tool call") }
        XCTAssertEqual(text, "")
        XCTAssertEqual(calls, [ModelToolCall(id: "call_1", name: "find_contact", arguments: ["name": "Alex"], rawArguments: #"{"name":"Alex"}"#)])
        var plain = CompatibleStreamDecoder()
        XCTAssertThrowsError(try plain.consume(#"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"x"}]},"finish_reason":null}]}"#),
                             "Tool calls stay refused when none were offered")
        let json = Data(#"{"choices":[{"message":{"content":null,"tool_calls":[{"id":"call_2","type":"function","function":{"name":"read_reminders","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#.utf8)
        XCTAssertEqual(try CompatibleStreamDecoder.jsonTurn(json, acceptsTools: true),
                       .tools([ModelToolCall(id: "call_2", name: "read_reminders", arguments: [:], rawArguments: "{}")], text: ""))
        XCTAssertThrowsError(try CompatibleStreamDecoder.jsonTurn(json, acceptsTools: false))
    }
    func testClaudeStreamedToolUseIsCollected() throws {
        var decoder = AnthropicStreamDecoder(acceptsTools: true)
        for line in [
            #"data: {"type":"message_start","message":{}}"#,
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Checking."}}"#,
            #"data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"read_calendar","input":{}}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"day\": \"tom"}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"orrow\"}"}}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#,
            #"data: {"type":"message_stop"}"#] { try decoder.consume(line) }
        guard case let .tools(calls, text) = try decoder.completedTurn() else { return XCTFail("Expected a tool call") }
        XCTAssertEqual(text, "Checking.")
        XCTAssertEqual(calls.map(\.name), ["read_calendar"]); XCTAssertEqual(calls.first?.arguments, ["day": "tomorrow"])
        XCTAssertEqual(calls.first?.id, "toolu_1")
        var plain = AnthropicStreamDecoder()
        XCTAssertThrowsError(try plain.consume(#"data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"t","name":"read_calendar","input":{}}}"#))
        XCTAssertThrowsError(try plain.consume(#"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#))
    }
    func testToolRoundsAreReplayedInEachProvidersFormat() throws {
        let packet = try ExternalConversationPacket.make(message: "Who is Alex?", history: [], connectorTools: true)
        XCTAssertTrue(packet.messages.first?.content.contains("read_calendar") == true)
        XCTAssertTrue(try ExternalConversationPacket.make(message: "Hi", history: []).messages.first?.content.contains("No tools") == true)
        let call = try ModelToolCall.make(id: "call_1", index: 0, name: "find_contact", json: #"{"name":"Alex"}"#)
        let exchange = ModelToolExchange(text: "", calls: [call], results: [#"{"records":[]}"#])

        let openAI = try jsonObject(OpenAIChatBody(model: "gpt", packet: packet, exchanges: [exchange], stream: false, tools: true, allowCalls: false))
        let messages = try XCTUnwrap(openAI["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.compactMap { $0["role"] as? String }, ["system", "user", "assistant", "tool"])
        XCTAssertEqual(messages[3]["tool_call_id"] as? String, "call_1")
        XCTAssertEqual(((messages[2]["tool_calls"] as? [[String: Any]])?.first?["function"] as? [String: Any])?["arguments"] as? String, #"{"name":"Alex"}"#)
        XCTAssertEqual((openAI["tools"] as? [[String: Any]])?.first?["type"] as? String, "function")
        XCTAssertEqual(openAI["tool_choice"] as? String, "none", "The last round must answer")
        XCTAssertNil(try jsonObject(OpenAIChatBody(model: "gpt", packet: packet, stream: false))["tools"])

        let claude = try jsonObject(AnthropicMessagesBody(packet: packet, model: "claude", stream: false, exchanges: [exchange], tools: true, allowCalls: true))
        let turns = try XCTUnwrap(claude["messages"] as? [[String: Any]])
        XCTAssertEqual(turns.compactMap { $0["role"] as? String }, ["user", "assistant", "user"])
        let use = try XCTUnwrap((turns[1]["content"] as? [[String: Any]])?.first)
        XCTAssertEqual(use["type"] as? String, "tool_use"); XCTAssertEqual(use["input"] as? [String: String], ["name": "Alex"])
        XCTAssertEqual((turns[2]["content"] as? [[String: Any]])?.first?["tool_use_id"] as? String, "call_1")
        XCTAssertNotNil((claude["tools"] as? [[String: Any]])?.first?["input_schema"])
        XCTAssertNil(claude["tool_choice"])
    }

    // MARK: Helpers

    private func jsonObject(_ value: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }
    @MainActor private func makeAPIStore() throws -> (AppStore, URL, MockConnectionClient) {
        GrantFixture.reset()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let client = MockConnectionClient(permission: .allowed)
        let store = AppStore(repository: .init(url: folder.appendingPathComponent("state.json")), provider: APIUnavailableLocal(),
                             nativeConnections: client, apiKeys: MemoryAPIKeys())
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GrantFixture.self]
        store.apiSession = URLSession(configuration: configuration)
        let profile = try APIModelProfile.validated(name: "Claude", endpoint: "https://\(host)/v1/messages", model: "claude-test",
                                                    streaming: false, format: .anthropic)
        try store.addAPIProfile(profile, key: "sk-ant-fixture")
        try store.selectAPIProfile(profile)
        return (store, folder, client)
    }
    @MainActor private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out waiting") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor private final class ReadCounter {
    var reads = 0
    var queries: [String?] = []
}

/// Stands in for Claude's Messages API: a question gets a `read_calendar` call; once the tool result
/// comes back, an answer. Records every body it was sent.
private final class GrantFixture: URLProtocol {
    nonisolated(unsafe) private static var recorded: [[String: Any]] = []
    private static let lock = NSLock()
    static var bodies: [[String: Any]] { lock.withLock { recorded } }
    static func reset() { lock.withLock { recorded = [] } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "grants.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let size = stream.read(&buffer, maxLength: buffer.count)
                if size <= 0 { break }
                body.append(contentsOf: buffer.prefix(size))
            }
        }
        guard let url = request.url, request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-fixture",
              let decoded = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        Self.lock.withLock { Self.recorded.append(decoded) }
        let answered = String(decoding: body, as: UTF8.self).contains("tool_result")
        let reply = answered
            ? #"{"content":[{"type":"text","text":"You have standup at nine."}],"stop_reason":"end_turn"}"#
            : #"{"content":[{"type":"text","text":"Let me look."},{"type":"tool_use","id":"toolu_1","name":"read_calendar","input":{"day":"today"}}],"stop_reason":"tool_use"}"#
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

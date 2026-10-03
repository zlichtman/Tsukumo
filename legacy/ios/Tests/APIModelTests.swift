import XCTest
#if os(macOS)
@testable import KemoSabeMac
#else
@testable import KemoSabe
#endif

final class APIModelTests: XCTestCase {
    func testEndpointPolicyOnlyAllowsHTTPSOrActualLoopback() throws {
        for endpoint in ["https://provider.example/v1/chat/completions", "http://localhost:11434/v1/chat/completions", "http://127.0.0.1:1234/v1/chat/completions", "http://[::1]:1234/v1/chat/completions"] {
            XCTAssertNoThrow(try APIModelProfile.validated(name: "My model", endpoint: endpoint, model: "model-name"))
        }
        for endpoint in ["http://provider.example/v1/chat/completions", "http://192.168.1.3/v1/chat/completions", "https://user:key@provider.example/v1/chat/completions", "https://provider.example/v1/chat/completions?key=secret", "https://provider.example/v1/chat/completions#key", "http://localhost.evil.example/v1/chat/completions", "file:///v1/chat/completions", "https://provider.example/v1/reply"] {
            XCTAssertThrowsError(try APIModelProfile.validated(name: "My model", endpoint: endpoint, model: "model-name"))
        }
    }
    func testPacketPreservesWholeAuthorizedConversationAndRejectsOversize() throws {
        let text = String(repeating: "A", count: 2300)
        let history = (0..<9).map { ChatMessage(role: $0 % 2 == 0 ? "You" : "KemoSabe", text: "\($0):" + text) }
        let packet = try ExternalConversationPacket.make(message: "Continue", history: history)
        XCTAssertEqual(packet.messages.count, 11)
        XCTAssertEqual(packet.messages[1].content, history[0].text)
        XCTAssertEqual(packet.messages[9].content, history[8].text)
        XCTAssertThrowsError(try ExternalConversationPacket.make(message: "Continue", history: history + history))
    }
    func testStreamingRequiresExplicitSuccessfulFinish() throws {
        var decoder = CompatibleStreamDecoder()
        try decoder.consume("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hello 🌱\"},\"finish_reason\":null}]}")
        XCTAssertEqual(decoder.text, "Hello 🌱")
        XCTAssertThrowsError(try decoder.completed())
        try decoder.consume("data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}")
        try decoder.consume("data: [DONE]")
        XCTAssertEqual(try decoder.completed(), "Hello 🌱")
    }
    func testTruncatedOrToolCallingRepliesNeverBecomeCompletedAnswers() {
        for line in [
            "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"},\"finish_reason\":\"length\"}]}",
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{}]},\"finish_reason\":null}]}",
            "data: {\"choices\":[{\"index\":1,\"delta\":{\"content\":\"second choice\"}}]}",
            "data: invalid JSON"
        ] {
            var decoder = CompatibleStreamDecoder()
            XCTAssertThrowsError(try decoder.consume(line))
        }
        var doneOnly = CompatibleStreamDecoder()
        try? doneOnly.consume("data: [DONE]")
        XCTAssertThrowsError(try doneOnly.completed())
    }
    func testJSONFinishIsValidated() throws {
        let valid = Data(#"{"choices":[{"message":{"content":"Complete"},"finish_reason":"stop"}]}"#.utf8)
        XCTAssertEqual(try CompatibleStreamDecoder.jsonAnswer(valid), "Complete")
        let partial = Data(#"{"choices":[{"message":{"content":"Partial"},"finish_reason":"length"}]}"#.utf8)
        XCTAssertThrowsError(try CompatibleStreamDecoder.jsonAnswer(partial))
    }
    @MainActor func testAdapterRejectsAmbientPrivateContextBeforeNetworking() async throws {
        let profile = try APIModelProfile.validated(name: "Never contacted", endpoint: "https://example.invalid/v1/chat/completions", model: "test")
        let model = CompatibleAPIModel(profile: profile, key: "")
        do {
            _ = try await model.reply(to: "Hello", history: [], memories: [.init(text: "Private")], standupFormat: "")
            XCTFail("Private notes must not reach the adapter")
        } catch { XCTAssertEqual(error as? APIModelError, .disclosure) }
        var request = PlanningRequest(message: "Hello", history: [], memories: [], standupFormat: "")
        request.routineFacts = ["Private bedtime"]
        let tools = ToolRegistry(deadline: request.deadline, lookup: { _ in [] }, read: { _, _ in throw ToolFailure.unavailable }, isCurrent: { true }, recipient: .onDevice)
        do { _ = try await model.respond(request, tools: tools, onSnapshot: { _ in }); XCTFail("Private routine must not reach the adapter") }
        catch { XCTAssertEqual(error as? APIModelError, .disclosure) }
    }
    @MainActor func testSwappingModelsSeparatesHistoriesAndArchivesWithoutChangingMemories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(repository: .init(url: root.appendingPathComponent("state.json")), provider: APIUnavailableLocal(), apiKeys: MemoryAPIKeys())
        let memory = MemoryNote(text: "Private local preference")
        store.state.memories = [memory]
        store.state.messages = [.init(role: "You", text: "Private local chat")]
        let first = try APIModelProfile.validated(name: "A", endpoint: "https://one.example/v1/chat/completions", model: "A")
        let second = try APIModelProfile.validated(name: "B", endpoint: "https://two.example/v1/chat/completions", model: "B")
        try store.addAPIProfile(first, key: "test-key"); try store.addAPIProfile(second, key: "other-key")
        XCTAssertEqual(store.modelRoute, .onDevice, "Saving is not permission to switch or send")
        try store.selectAPIProfile(first)
        XCTAssertTrue(store.conversationMessages.isEmpty)
        store.appendVisibleMessage(role: "You", text: "A-only conversation")
        try store.selectAPIProfile(second)
        XCTAssertTrue(store.conversationMessages.isEmpty)
        try store.selectAPIProfile(first)
        XCTAssertEqual(store.conversationMessages.first?.text, "A-only conversation")
        store.newConversation()
        XCTAssertTrue(store.conversationMessages.isEmpty)
        XCTAssertEqual(store.state.conversationArchives?.last?.messages.first?.text, "A-only conversation")
        XCTAssertEqual(store.state.messages.first?.text, "Private local chat")
        XCTAssertEqual(store.state.memories, [memory])
        let data = String(decoding: try JSONEncoder().encode(store.state), as: UTF8.self)
        XCTAssertFalse(data.contains("test-key")); XCTAssertFalse(data.contains("other-key"))
        store.clearConversation()
        XCTAssertTrue(store.state.conversationArchives?.isEmpty == true)
        XCTAssertEqual(store.state.memories, [memory])
    }
    @MainActor func testRemovingOneAccountDoesNotDeleteAnotherAccountsArchive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(repository: .init(url: root.appendingPathComponent("state.json")), provider: APIUnavailableLocal(), apiKeys: MemoryAPIKeys())
        let first = try APIModelProfile.validated(name: "First account", endpoint: "https://same.example/v1/chat/completions", model: "same-model")
        let second = try APIModelProfile.validated(name: "Second account", endpoint: "https://same.example/v1/chat/completions", model: "same-model")
        try store.addAPIProfile(first, key: "first-key"); try store.addAPIProfile(second, key: "second-key")
        for profile in [first, second] {
            try store.selectAPIProfile(profile); store.appendVisibleMessage(role: "You", text: profile.name); store.newConversation()
        }
        try store.removeAPIProfile(first)
        XCTAssertEqual(store.state.conversationArchives?.count, 1)
        XCTAssertEqual(store.state.conversationArchives?.first?.apiProfileID, second.id)
        XCTAssertEqual(store.state.conversationArchives?.first?.messages.first?.text, "Second account")
    }
    @MainActor func testContinuingASavedConversationStaysWithItsModel() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(repository: .init(url: root.appendingPathComponent("state.json")), provider: APIUnavailableLocal(), apiKeys: MemoryAPIKeys())
        store.appendVisibleMessage(role: "You", text: "Plan the Tahoe trip")
        store.newConversation()
        store.appendVisibleMessage(role: "You", text: "Recipe for dinner")
        let tahoe = try XCTUnwrap(store.state.conversationArchives?.first)
        XCTAssertTrue(store.canResume(tahoe))
        store.resumeArchivedConversation(tahoe.id)
        XCTAssertEqual(store.conversationMessages.map(\.text), ["Plan the Tahoe trip"])
        // The on-device model reads the continued conversation as current history.
        XCTAssertTrue(store.state.messages.allSatisfy { $0.contextRevision == (store.state.contextRevision ?? 0) })
        // The conversation it replaced is saved, not lost.
        XCTAssertEqual(store.state.conversationArchives?.map { $0.messages.first?.text }, ["Recipe for dinner"])
        // A connected model can't continue an on-device conversation, or another account's.
        let profile = try APIModelProfile.validated(name: "A", endpoint: "https://one.example/v1/chat/completions", model: "A")
        let other = try APIModelProfile.validated(name: "B", endpoint: "https://one.example/v1/chat/completions", model: "A")
        try store.addAPIProfile(profile, key: "k"); try store.addAPIProfile(other, key: "k2")
        try store.selectAPIProfile(profile)
        let dinner = try XCTUnwrap(store.state.conversationArchives?.first)
        XCTAssertFalse(store.canResume(dinner))
        store.resumeArchivedConversation(dinner.id)
        XCTAssertTrue(store.conversationMessages.isEmpty)
        store.appendVisibleMessage(role: "You", text: "A conversation"); store.newConversation()
        let aArchive = try XCTUnwrap(store.state.conversationArchives?.last)
        XCTAssertTrue(store.canResume(aArchive))
        try store.selectAPIProfile(other)
        XCTAssertFalse(store.canResume(aArchive))
    }
    func testNativeReadCommandsRequireLocalConversation() {
        for text in ["Read my calendar", "Read my reminders", "Find contact Alex", "Good morning"] {
            XCTAssertTrue(VoiceCommand.parse(text)?.requiresPrivateContext == true)
        }
        XCTAssertFalse(VoiceCommand.parse("Dance")!.requiresPrivateContext)
    }
    @MainActor func testTransportSendsOnlyAuthorizedTextAndKeepsKeyOutOfBody() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APITransportFixture.self]
        let profile = try APIModelProfile.validated(name: "Fixture", endpoint: "https://fixture.invalid/v1/chat/completions", model: "fixture-model", streaming: false)
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let model = CompatibleAPIModel(profile: profile, key: "fixture-secret", session: session)
        let answer = try await model.reply(to: "Current question", history: [.init(role: "You", text: "Allowed prior question")], memories: [], standupFormat: "")
        XCTAssertEqual(answer, "Transport verified")
    }
}

/// No real network, provider credential, or paid model is used by this test.
private final class APITransportFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let size = stream.read(&buffer, maxLength: buffer.count)
                    guard size >= 0 else { throw APIModelError.incomplete }
                    if size == 0 { break }; body.append(contentsOf: buffer.prefix(size))
                }
            }
            let decoded = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            let messages = decoded?["messages"] as? [[String: String]]
            guard request.httpMethod == "POST", request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-secret",
                  decoded?["model"] as? String == "fixture-model", decoded?["stream"] as? Bool == false,
                  decoded?["tools"] == nil, messages?.count == 3,
                  messages?[1]["content"] == "Allowed prior question", messages?[2]["content"] == "Current question",
                  !String(decoding: body, as: UTF8.self).contains("fixture-secret") else { throw APIModelError.disclosure }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"choices":[{"message":{"content":"Transport verified"},"finish_reason":"stop"}]}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class MemoryAPIKeys: APIKeyStoring {
    var keys: [UUID: String] = [:]
    func read(_ id: UUID) throws -> String { guard let value = keys[id] else { throw APIModelError.keychain }; return value }
    func save(_ key: String, for id: UUID) throws { keys[id] = key }
    func remove(_ id: UUID) throws { keys.removeValue(forKey: id) }
}
struct APIUnavailableLocal: AssistantProvider {
    var runsLocally: Bool { true }; var isAvailable: Bool { false }; var availabilityDescription: String { "Test only" }
    func reply(to message: String, history: [ChatMessage], memories: [MemoryNote], standupFormat: String) async throws -> String { throw PlanningError.unavailable }
}

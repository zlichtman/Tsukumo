import XCTest
import FoundationModels
#if os(macOS)
@testable import KemoSabeMac
#else
@testable import KemoSabe
#endif

/// The chat model chip's effort (the owner's instruction, September 26, 2026): only models that
/// really take an effort get the slider; the effort is saved per model profile and sent only to
/// that model, in its provider's own field. No real network or provider key is used.
@MainActor final class ModelEffortTests: XCTestCase {
    private var folder: URL!
    override func setUp() { folder = FileManager.default.temporaryDirectory.appendingPathComponent("ModelEffortTests-" + UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: folder); EffortFixture.reset() }

    private func claude(_ model: String = "claude-opus-5", host: String = "api.anthropic.com") throws -> APIModelProfile {
        try APIModelProfile.validated(name: "Claude", endpoint: "https://\(host)/v1/messages", model: model, streaming: false, format: .anthropic)
    }
    private func openAI(_ model: String, host: String = "api.openai.com") throws -> APIModelProfile {
        try APIModelProfile.validated(name: "OpenAI", endpoint: "https://\(host)/v1/chat/completions", model: model, streaming: false)
    }

    // MARK: Which models take an effort

    func testClaudeEffortsFollowTheModelsThatDocumentThem() throws {
        let full = ["low", "medium", "high", "xhigh", "max"]
        for model in ["claude-opus-5", "claude-opus-5-5", "claude-opus-4-8", "claude-opus-4-7", "claude-sonnet-5", "claude-fable-5-1", "claude-fable-5"] {
            XCTAssertEqual(ModelEffortCatalog.claude(model), full, model)
        }
        XCTAssertEqual(ModelEffortCatalog.claude("claude-opus-4-6"), ["low", "medium", "high", "max"])
        XCTAssertEqual(ModelEffortCatalog.claude("claude-sonnet-4-6"), ["low", "medium", "high", "max"])
        XCTAssertEqual(ModelEffortCatalog.claude("claude-opus-4-5-20251101"), ["low", "medium", "high"], "A date suffix isn't a minor version")
        for model in ["claude-haiku-4-5", "claude-sonnet-4-5", "claude-sonnet-4-20250514", "claude-3-7-sonnet-latest", "gpt-5"] {
            XCTAssertEqual(ModelEffortCatalog.claude(model), [], model)
        }
        XCTAssertEqual(ModelEffortCatalog.defaultEffort(for: try claude()), "high")
        XCTAssertEqual(ModelEffortCatalog.defaultEffort(for: try claude("claude-opus-5-5")), "medium")
        XCTAssertNil(ModelEffortCatalog.defaultEffort(for: try claude("claude-haiku-4-5")))
    }
    func testOpenAIEffortsOnlyForReasoningModelsAtOpenAI() throws {
        XCTAssertEqual(ModelEffortCatalog.efforts(for: try openAI("o3")), ["low", "medium", "high"])
        XCTAssertEqual(ModelEffortCatalog.efforts(for: try openAI("o4-mini")), ["low", "medium", "high"])
        XCTAssertEqual(ModelEffortCatalog.efforts(for: try openAI("gpt-5")), ["minimal", "low", "medium", "high"])
        XCTAssertEqual(ModelEffortCatalog.efforts(for: try openAI("gpt-5-mini-2025-08-07")), ["minimal", "low", "medium", "high"])
        XCTAssertEqual(ModelEffortCatalog.efforts(for: try openAI("gpt-5.1")), ["none", "low", "medium", "high"])
        XCTAssertEqual(ModelEffortCatalog.efforts(for: try openAI("gpt-5.2")), ["none", "low", "medium", "high", "xhigh"])
        for model in ["gpt-4o", "gpt-4.1-mini", "gpt-5-chat-latest", "o1-mini"] {
            XCTAssertEqual(ModelEffortCatalog.efforts(for: try openAI(model)), [], model)
        }
        // The same model name on another OpenAI-compatible server gets nothing: it may not take the field.
        XCTAssertEqual(ModelEffortCatalog.efforts(for: try openAI("gpt-5", host: "proxy.example")), [])
        XCTAssertEqual(ModelEffortCatalog.efforts(for: try APIModelProfile.validated(name: "Ollama", endpoint: "http://localhost:11434/v1/chat/completions", model: "o3")), [])
        XCTAssertEqual(ModelEffortCatalog.defaultEffort(for: try openAI("gpt-5")), "medium")
        XCTAssertEqual(ModelEffortCatalog.defaultEffort(for: try openAI("gpt-5.1")), "none")
    }

    // MARK: Request bodies, with and without effort

    private func json(_ value: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }
    func testClaudeBodyCarriesOutputConfigEffortOnlyWhenChosen() throws {
        let packet = try ExternalConversationPacket.make(message: "Hi", history: [])
        let with = try json(AnthropicMessagesBody(packet: packet, model: "claude-opus-5", stream: true, effort: "xhigh"))
        XCTAssertEqual((with["output_config"] as? [String: Any])?["effort"] as? String, "xhigh")
        XCTAssertNil(with["reasoning_effort"], "Never OpenAI's field")
        XCTAssertNil(with["thinking"], "Effort alone; the thinking setting is unchanged")
        let without = try json(AnthropicMessagesBody(packet: packet, model: "claude-opus-5", stream: true))
        XCTAssertNil(without["output_config"])
    }
    func testOpenAIBodyCarriesReasoningEffortOnlyWhenChosen() throws {
        let packet = try ExternalConversationPacket.make(message: "Hi", history: [])
        let with = try json(OpenAIChatBody(model: "gpt-5", packet: packet, stream: false, effort: "minimal"))
        XCTAssertEqual(with["reasoning_effort"] as? String, "minimal")
        XCTAssertNil(with["output_config"], "Never Claude's field")
        let without = try json(OpenAIChatBody(model: "gpt-5", packet: packet, stream: false))
        XCTAssertNil(without["reasoning_effort"])
    }
    func testTheWireSendsOnlyAnEffortTheModelAccepts() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EffortFixture.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        // Claude with an effort it takes, and with one it doesn't (Haiku takes none).
        _ = try await CompatibleAPIModel(profile: try claude(), key: "sk-ant-fixture", effort: "max", session: session).reply(to: "Hi", history: [], memories: [], standupFormat: "")
        _ = try await CompatibleAPIModel(profile: try claude("claude-haiku-4-5"), key: "sk-ant-fixture", effort: "max", session: session).reply(to: "Hi", history: [], memories: [], standupFormat: "")
        _ = try await CompatibleAPIModel(profile: try claude(), key: "sk-ant-fixture", session: session).reply(to: "Hi", history: [], memories: [], standupFormat: "")
        // OpenAI: a reasoning model, an effort from another model's list, and a non-reasoning model.
        _ = try await CompatibleAPIModel(profile: try openAI("o3"), key: "sk-fixture", effort: "high", session: session).reply(to: "Hi", history: [], memories: [], standupFormat: "")
        _ = try await CompatibleAPIModel(profile: try openAI("o3"), key: "sk-fixture", effort: "xhigh", session: session).reply(to: "Hi", history: [], memories: [], standupFormat: "")
        _ = try await CompatibleAPIModel(profile: try openAI("gpt-4o"), key: "sk-fixture", effort: "high", session: session).reply(to: "Hi", history: [], memories: [], standupFormat: "")
        let bodies = EffortFixture.bodies
        XCTAssertEqual(bodies.count, 6)
        XCTAssertEqual((bodies[0]["output_config"] as? [String: Any])?["effort"] as? String, "max")
        XCTAssertNil(bodies[1]["output_config"], "Haiku takes no effort, so none is sent")
        XCTAssertNil(bodies[2]["output_config"], "No effort chosen: the model's default")
        XCTAssertEqual(bodies[3]["reasoning_effort"] as? String, "high")
        XCTAssertNil(bodies[4]["reasoning_effort"], "o3 doesn't list xhigh")
        XCTAssertNil(bodies[5]["reasoning_effort"], "gpt-4o isn't a reasoning model")
        XCTAssertTrue(bodies.allSatisfy { $0["thinking"] == nil })
    }

    func testAppleReasoningLevelsBecomeContextOptions() throws {
        guard #available(iOS 27, macOS 27, *) else { throw XCTSkip("Reasoning levels arrive with iOS and macOS 27") }
        XCTAssertEqual(AppleReasoning.options("light"), ContextOptions(reasoningLevel: .light))
        XCTAssertEqual(AppleReasoning.options("moderate"), ContextOptions(reasoningLevel: .moderate))
        XCTAssertEqual(AppleReasoning.options("deep"), ContextOptions(reasoningLevel: .deep))
        XCTAssertEqual(AppleReasoning.options(nil), ContextOptions(), "Without a level, the model's own default")
        XCTAssertEqual(AppleReasoning.options("max"), ContextOptions(), "Another provider's effort is never an Apple level")
    }

    // MARK: Saved per model profile

    private func store() -> AppStore {
        AppStore(repository: .init(url: folder.appendingPathComponent("state.json")), provider: EffortTurns(), apiKeys: MemoryAPIKeys(),
                 privateCloud: EffortCloud())
    }
    func testEffortIsSavedPerModelAndOnlyWhenTheModelTakesOne() throws {
        let store = store()
        store.setAppleReasoning([])
        XCTAssertEqual(store.currentEfforts, [], "On-device without reasoning: the model list only")
        store.setCurrentEffort("deep")
        XCTAssertNil(store.state.modelEfforts, "Nothing is saved for a model without efforts")
        store.setAppleReasoning([.onDevice])
        XCTAssertEqual(store.currentEfforts, AppleReasoning.levels)
        store.setCurrentEffort("deep")
        XCTAssertEqual(store.currentEffort, "deep")
        XCTAssertEqual(store.appleReasoningLevel(for: .onDevice), "deep")
        XCTAssertNil(store.appleReasoningLevel(for: .privateCloud), "Private Cloud has its own level")
        store.setCurrentEffort("max")
        XCTAssertEqual(store.currentEffort, "deep", "An effort the model doesn't take is never saved")

        let opus = try claude(), haiku = try claude("claude-haiku-4-5")
        try store.addAPIProfile(opus, key: "sk-ant-fixture"); try store.addAPIProfile(haiku, key: "sk-ant-fixture")
        try store.selectAPIProfile(opus)
        XCTAssertEqual(store.currentEfforts, ModelEffortCatalog.claudeFull)
        XCTAssertNil(store.currentEffort, "Each model starts at its own default")
        store.setCurrentEffort("xhigh")
        try store.selectAPIProfile(haiku)
        XCTAssertEqual(store.currentEfforts, [])
        XCTAssertNil(store.currentEffort)
        try store.selectAPIProfile(opus)
        XCTAssertEqual(store.currentEffort, "xhigh", "Kept for its own profile")
        store.selectAppleModel(.onDevice)
        XCTAssertEqual(store.currentEffort, "deep")
        // Reloaded from disk, the choices are still per model.
        let reloaded = AppStore(repository: .init(url: folder.appendingPathComponent("state.json")), provider: EffortTurns(), apiKeys: MemoryAPIKeys(), privateCloud: EffortCloud())
        XCTAssertEqual(reloaded.state.modelEfforts?[ModelEffortKey.api(opus.id)], "xhigh")
        XCTAssertEqual(reloaded.state.modelEfforts?[ModelEffortKey.apple(.onDevice)], "deep")
        // Removing a connection removes its effort.
        try store.removeAPIProfile(opus)
        XCTAssertNil(store.state.modelEfforts?[ModelEffortKey.api(opus.id)])
        store.setCurrentEffort(nil)
        XCTAssertNil(store.state.modelEfforts, "Back to defaults leaves nothing saved")
    }
    func testAppleTurnCarriesItsOwnModelsLevel() async {
        let turns = EffortTurns()
        let store = AppStore(repository: .init(url: folder.appendingPathComponent("state.json")), provider: turns, apiKeys: MemoryAPIKeys(), privateCloud: EffortCloud())
        store.setAppleReasoning([.onDevice])
        store.setCurrentEffort("light")
        let done = expectation(description: "reply")
        store.send("What's a good name for a cat?", completion: { _ in done.fulfill() })
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(turns.levels, ["light"])
        store.setAppleReasoning([])
        let again = expectation(description: "reply")
        store.send("And for a dog?", completion: { _ in again.fulfill() })
        await fulfillment(of: [again], timeout: 5)
        XCTAssertEqual(turns.levels, ["light", nil], "A model that can't reason is sent no level")
    }
}

private struct EffortCloud: PrivateCloudProbing { var status = PrivateCloudStatus(availability: .available, quota: nil) }

private final class EffortTurns: ModelProvider {
    let runsLocally = true
    let isAvailable = true
    let availabilityDescription = "Test"
    var levels: [String?] = []
    func reply(to: String, history: [ChatMessage], memories: [MemoryNote], standupFormat: String) async throws -> String { "" }
    func respond(_ request: PlanningRequest, tools: ToolRegistry, onSnapshot: @escaping @MainActor (String) -> Void) async throws -> CompanionPlan {
        levels.append(request.appleReasoning)
        return .init(answer: "answer")
    }
}

/// Records each body and answers in the provider's own format. Nothing leaves the process.
private final class EffortFixture: URLProtocol {
    nonisolated(unsafe) private static var recorded: [[String: Any]] = []
    private static let lock = NSLock()
    static var bodies: [[String: Any]] { lock.withLock { recorded } }
    static func reset() { lock.withLock { recorded = [] } }
    override class func canInit(with request: URLRequest) -> Bool { ["api.anthropic.com", "api.openai.com"].contains(request.url?.host ?? "") }
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
        guard let url = request.url, let decoded = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        Self.lock.withLock { Self.recorded.append(decoded) }
        let reply = url.host == "api.anthropic.com"
            ? #"{"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}"#
            : #"{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}"#
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

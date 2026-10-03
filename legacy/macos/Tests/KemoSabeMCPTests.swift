import XCTest
@testable import KemoSabeMac

/// The KemoSabe MCP server end to end (design/CONTEXT-HARNESS.md#agents-asking-kemosabe): the real
/// `kemosabe-mcp` helper from this build's Tsukumo.app, spoken to over stdio as Claude Code, Codex,
/// or Muse would, relaying over the real bridge to an app-side listener whose desk uses a fake
/// on-device model and a throwaway account. Also the one-click config writers, on temporary homes.
@MainActor final class KemoSabeMCPTests: XCTestCase {
    private var cleanup: [URL] = []
    override func tearDown() async throws {
        KemoSabeMCP.launchOverride = nil
        for url in cleanup { try? FileManager.default.removeItem(at: url) }
        cleanup = []
    }

    // MARK: End to end

    func testAnAgentAsksOverMCPAndGetsOnlyTheAnswer() async throws {
        let helper = try XCTUnwrap(KemoSabeMCP.bundledHelper, "Tsukumo.app/Contents/Helpers/kemosabe-mcp is built into the app")
        let folder = shortFolder()
        let (store, model) = makeStore()
        let server = KemoSabeBridgeServer(folder: folder) { request in await KemoSabeBridgeAnswers.respond(request, store: store) }
        try server.start()
        defer { server.stop() }
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("secret").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600, "Only this user can read the secret")
        let socketMode = try FileManager.default.attributesOfItem(atPath: server.socketPath)[.posixPermissions] as? NSNumber
        XCTAssertEqual(socketMode?.intValue, 0o600)

        // Muse, configured by hand: no --agent, so its clientInfo names it.
        let client = try MCPStdioClient(helper: helper, arguments: [], environment: [KemoSabeBridgeWire.folderEnvironment: folder.path])
        defer { client.close() }
        let initialize = try await client.request("initialize", ["protocolVersion": "2025-06-18", "capabilities": [:],
                                                                 "clientInfo": ["name": "muse-code", "title": "Muse", "version": "1.4.0"]])
        XCTAssertEqual(initialize["protocolVersion"] as? String, "2025-06-18")
        XCTAssertEqual((initialize["serverInfo"] as? [String: Any])?["name"] as? String, "kemosabe")
        XCTAssertNotNil((initialize["capabilities"] as? [String: Any])?["tools"])
        try client.notify("notifications/initialized")
        let list = try await client.request("tools/list", [:])
        let tools = try XCTUnwrap(list["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.map { $0["name"] as? String }, ["ask_kemosabe"])
        XCTAssertEqual((tools[0]["inputSchema"] as? [String: Any])?["required"] as? [String], ["question", "purpose"])

        // The first call waits on the owner's prompt.
        let arguments: [String: Any] = ["name": "ask_kemosabe", "arguments": ["question": "What time did she say she was free?", "purpose": "planning dinner"]]
        async let first = client.request("tools/call", arguments)
        try await waitUntil { store.agentQuestions.consent != nil }
        XCTAssertEqual(store.agentQuestions.consent?.requester.name, "Muse")
        XCTAssertEqual(store.agentQuestions.consent?.requester.recipient, .externalAgent("com.meta.muse"))
        store.agentQuestions.decide(.always)
        let answered = try await first
        XCTAssertEqual(Self.text(answered), "Friday after 7")
        XCTAssertEqual(answered["isError"] as? Bool, false)
        XCTAssertEqual((answered["structuredContent"] as? [String: Any])?["status"] as? String, "answered")

        // Allowed always: no prompt this time.
        let second = try await client.request("tools/call", arguments)
        XCTAssertEqual(Self.text(second), "Friday after 7")
        XCTAssertNil(store.agentQuestions.consent)
        XCTAssertEqual(model.calls.value, 2)

        let journal = try await store.agentRequests.journal.snapshot()
        XCTAssertEqual(journal.count, 2)
        XCTAssertEqual(journal.last?.requester, "Muse"); XCTAssertEqual(journal.last?.channel, "mcp")
        XCTAssertEqual(journal.last?.lookingFor, "What time did she say she was free?"); XCTAssertEqual(journal.last?.purpose, "planning dinner")
        XCTAssertEqual(journal.last?.shared, "Friday after 7"); XCTAssertEqual(journal.last?.outcome, .shared)

        // Unknown tools and methods are errors, not crashes.
        let unknown = try await client.raw("tools/call", ["name": "read_everything", "arguments": [:]])
        XCTAssertNotNil(unknown["error"])

        // With Tsukumo gone, the agent hears so.
        server.stop()
        let closed = try await client.request("tools/call", arguments)
        XCTAssertEqual(closed["isError"] as? Bool, true)
        XCTAssertTrue(Self.text(closed).contains("isn't running"), Self.text(closed))
    }

    func testTheConfigsNameDecidesWhoIsAskingAndDontAllowIsHonored() async throws {
        let helper = try XCTUnwrap(KemoSabeMCP.bundledHelper)
        let folder = shortFolder()
        let (store, model) = makeStore()
        let server = KemoSabeBridgeServer(folder: folder) { request in await KemoSabeBridgeAnswers.respond(request, store: store) }
        try server.start()
        defer { server.stop() }
        let client = try MCPStdioClient(helper: helper, arguments: ["--agent", "claude-code"], environment: [KemoSabeBridgeWire.folderEnvironment: folder.path])
        defer { client.close() }
        _ = try await client.request("initialize", ["protocolVersion": "2025-03-26", "capabilities": [:], "clientInfo": ["name": "some-client", "version": "1"]])
        async let call = client.request("tools/call", ["name": "ask_kemosabe", "arguments": ["question": "What time did she say she was free?", "purpose": "plans"]])
        try await waitUntil { store.agentQuestions.consent != nil }
        XCTAssertEqual(store.agentQuestions.consent?.requester.recipient, .codingAgent("claude-code"))
        store.agentQuestions.decide(.deny)
        let declined = try await call
        XCTAssertEqual(declined["isError"] as? Bool, true)
        XCTAssertEqual((declined["structuredContent"] as? [String: Any])?["status"] as? String, "declined")
        XCTAssertEqual((declined["structuredContent"] as? [String: Any])?["answer"] as? String, "")
        XCTAssertEqual(model.calls.value, 0)
        let journal = try await store.agentRequests.journal.snapshot()
        XCTAssertEqual(journal.last?.requester, "Claude Code"); XCTAssertEqual(journal.last?.outcome, .declined)
    }

    func testTheBridgeRefusesAWrongSecret() async throws {
        let folder = shortFolder()
        let (store, _) = makeStore()
        let server = KemoSabeBridgeServer(folder: folder) { request in await KemoSabeBridgeAnswers.respond(request, store: store) }
        try server.start()
        defer { server.stop() }
        let response = await Task.detached {
            KemoSabeBridgeWire.send(.init(secret: String(repeating: "0", count: 64), agent: "muse", question: "What time?", purpose: "x"), folder: folder, timeout: 5)
        }.value
        XCTAssertEqual(response.status, "refused")
        XCTAssertNil(store.agentQuestions.consent, "Nothing reached the owner")
        XCTAssertThrowsError(try KemoSabeBridgeServer(folder: folder) { _ in .init(status: "x", text: "") }.start(), "A second server leaves the first alone")
        XCTAssertTrue(KemoSabeBridgeWire.constantTimeEqual("abc", "abc"))
        XCTAssertFalse(KemoSabeBridgeWire.constantTimeEqual("abc", "abd"))
        XCTAssertFalse(KemoSabeBridgeWire.constantTimeEqual("", ""))
    }

    // MARK: Sessions Tsukumo launches

    func testLaunchedSessionsGetTheServer() throws {
        XCTAssertTrue(KemoSabeMCP.claudeLaunchArguments().isEmpty, "The test host leaves sessions unchanged")
        KemoSabeMCP.launchOverride = URL(fileURLWithPath: "/Applications/Tsukumo.app/Contents/Helpers/kemosabe-mcp")
        let task = CodingTaskRecord(projectID: UUID(), ownerID: "local-test", title: "T", provider: .claude, model: "", access: .edit,
                                    projectPath: "/tmp", directory: "/tmp", isolated: false)
        let args = CodingAgentSession.claudeArguments(for: task, resume: nil)
        let index = try XCTUnwrap(args.firstIndex(of: "--mcp-config"))
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(args[index + 1].utf8)) as? [String: Any])
        let server = try XCTUnwrap((config["mcpServers"] as? [String: Any])?["kemosabe"] as? [String: Any])
        XCTAssertEqual(server["command"] as? String, "/Applications/Tsukumo.app/Contents/Helpers/kemosabe-mcp")
        XCTAssertEqual(server["args"] as? [String], ["--agent", "claude-code"])
        XCTAssertEqual(KemoSabeMCP.codexLaunchArguments(), ["-c", "mcp_servers.kemosabe.command=\"/Applications/Tsukumo.app/Contents/Helpers/kemosabe-mcp\"",
                                                           "-c", "mcp_servers.kemosabe.args=[\"--agent\", \"codex\"]", "-c", "mcp_servers.kemosabe.tool_timeout_sec=180"])
        let acp = KemoSabeMCP.acpServers(agent: "cursor-agent")
        XCTAssertEqual(acp.first?["name"] as? String, "kemosabe"); XCTAssertEqual(acp.first?["args"] as? [String], ["--agent", "cursor-agent"])
        XCTAssertNotNil(acp.first?["env"] as? [Any], "ACP requires env")
        let muse = try XCTUnwrap((KemoSabeMCP.museSessionConfig()?["mcpServers"] as? [String: Any])?["kemosabe"] as? [String: Any])
        XCTAssertEqual(muse["transport"] as? String, "stdio"); XCTAssertEqual(muse["mode"] as? String, "optional")
    }

    // MARK: One-click setup

    func testClaudeConfigKeepsEverythingElseAndIsBackedUp() throws {
        let home = tempHome()
        let file = home.appendingPathComponent(".claude.json")
        let original: [String: Any] = ["numStartups": 42, "projects": ["/x": ["allowedTools": ["Bash"]]], "mcpServers": ["github": ["type": "stdio", "command": "gh-mcp"]]]
        let originalData = try JSONSerialization.data(withJSONObject: original)
        try originalData.write(to: file)
        chmod(file.path, 0o600)
        let setup = KemoSabeMCPSetup(home: home, environment: [:], helper: "/Applications/Tsukumo.app/Contents/Helpers/kemosabe-mcp")
        XCTAssertEqual(setup.status(.claude), .notConnected)
        XCTAssertTrue(setup.preview(.claude).contains("\"--agent\""))
        let backup = try XCTUnwrap(try setup.connect(.claude, now: Date(timeIntervalSince1970: 1_900_000_000)))
        XCTAssertTrue(backup.lastPathComponent.hasPrefix(".claude.json.before-kemosabe-"))
        XCTAssertEqual(try Data(contentsOf: backup), originalData, "The copy is the file as it was")
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(written["numStartups"] as? Int, 42)
        XCTAssertNotNil((written["projects"] as? [String: Any])?["/x"])
        let servers = try XCTUnwrap(written["mcpServers"] as? [String: Any])
        XCTAssertEqual((servers["github"] as? [String: Any])?["command"] as? String, "gh-mcp", "Other servers untouched")
        XCTAssertEqual((servers["kemosabe"] as? [String: Any])?["args"] as? [String], ["--agent", "claude-code"])
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600, "Permissions kept")
        XCTAssertEqual(setup.status(.claude), .connected)
        XCTAssertEqual(KemoSabeMCPSetup(home: home, environment: [:], helper: "/elsewhere/kemosabe-mcp").status(.claude), .otherHelper("/Applications/Tsukumo.app/Contents/Helpers/kemosabe-mcp"))
        try setup.disconnect(.claude)
        let after = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual((after["mcpServers"] as? [String: Any])?.keys.sorted(), ["github"])
        XCTAssertEqual(setup.status(.claude), .notConnected)
        // CLAUDE_CONFIG_DIR moves the file.
        XCTAssertEqual(KemoSabeMCPSetup(home: home, environment: ["CLAUDE_CONFIG_DIR": "/tmp/c"], helper: "h").file(.claude).path, "/tmp/c/.claude.json")
    }

    func testCodexConfigAddsOneTableAndLeavesTheRest() throws {
        let home = tempHome()
        let file = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = """
            model = "gpt-5-codex"

            [mcp_servers.github]
            command = "gh-mcp"
            args = ["serve"]

            [projects."/Users/me/app"]
            trust_level = "trusted"
            """
        try Data(original.utf8).write(to: file)
        let setup = KemoSabeMCPSetup(home: home, environment: [:], helper: "/Applications/Tsukumo.app/Contents/Helpers/kemosabe-mcp")
        try setup.connect(.codex)
        var text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix(original), "Everything before stays as it was")
        XCTAssertTrue(text.contains("[mcp_servers.kemosabe]\ncommand = \"/Applications/Tsukumo.app/Contents/Helpers/kemosabe-mcp\"\nargs = [\"--agent\", \"codex\"]\ntool_timeout_sec = 180\n"))
        XCTAssertEqual(setup.status(.codex), .connected)
        // Connecting again replaces its own table, never adds a second.
        try setup.connect(.codex)
        text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "[mcp_servers.kemosabe]").count, 2)
        try setup.disconnect(.codex)
        text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("kemosabe"))
        XCTAssertTrue(text.contains("[mcp_servers.github]") && text.contains("trust_level = \"trusted\""))
        // A form it doesn't edit is left for the person.
        try Data((original + "\n\n[mcp_servers]\nkemosabe = { command = \"x\" }\n").utf8).write(to: file)
        XCTAssertThrowsError(try setup.connect(.codex))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original + "\n\n[mcp_servers]\nkemosabe = { command = \"x\" }\n", "Unchanged when refused")
    }

    func testMuseConfigIsCreatedOrMergedWithTheLegacyKeyRenamed() throws {
        let home = tempHome()
        let setup = KemoSabeMCPSetup(home: home, environment: [:], helper: "/Applications/Tsukumo.app/Contents/Helpers/kemosabe-mcp")
        XCTAssertNil(try setup.connect(.muse), "A new file has nothing to back up")
        let file = home.appendingPathComponent(".config/muse/settings.json")
        var written = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(written["schema_version"] as? Int, 1)
        let ours = try XCTUnwrap((written["mcpServers"] as? [String: Any])?["kemosabe"] as? [String: Any])
        XCTAssertEqual(ours["type"] as? String, "stdio"); XCTAssertEqual(ours["mode"] as? String, "optional")
        XCTAssertEqual(ours["args"] as? [String], ["--agent", "muse"])

        try JSONSerialization.data(withJSONObject: ["schema_version": 1, "theme": "dark", "mcp_servers": ["docs": ["type": "streamable-http", "url": "https://example/mcp"]]])
            .write(to: file)
        try setup.connect(.muse)
        written = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertNil(written["mcp_servers"], "Muse drops both keys when both are present, so the legacy one is folded in")
        XCTAssertEqual((written["mcpServers"] as? [String: Any])?.keys.sorted(), ["docs", "kemosabe"])
        XCTAssertEqual(written["theme"] as? String, "dark")
        XCTAssertEqual(KemoSabeMCPSetup(home: home, environment: ["XDG_CONFIG_HOME": "/tmp/x"], helper: "h").file(.muse).path, "/tmp/x/muse/settings.json")
        // A file that isn't JSON is never overwritten.
        try Data("{ not json".utf8).write(to: file)
        XCTAssertThrowsError(try setup.connect(.muse))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "{ not json")
    }

    // MARK: Helpers

    private static func text(_ result: [String: Any]) -> String {
        ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    }
    /// A short temporary folder: a socket path must fit in 104 bytes.
    private func shortFolder() -> URL {
        let url = URL(fileURLWithPath: "/tmp/kmcp-" + UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
        cleanup.append(url)
        return url
    }
    private func tempHome() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kemosabe-home-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        cleanup.append(url)
        return url
    }
    private func makeStore() -> (AppStore, QuestionFakeModel) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        cleanup.append(folder)
        let store = AppStore(repository: .init(url: folder.appendingPathComponent("state.json")), provider: APIUnavailableLocal(), apiKeys: MemoryAPIKeys())
        let model = QuestionFakeModel()
        store.agentQuestions.model = model
        store.agentQuestions.sources = StoreAgentQuestionSources(store: store, docs: nil, includeCalendar: false)
        store.agentQuestions.isLocked = { false }
        store.state.conversationArchives = [ConversationArchive(model: "Messages", recipient: nil, messages: [
            ChatMessage(role: "Sarah", text: "The hike was unreal."),
            ChatMessage(role: "Sarah", text: "I'm free Friday after 7, want to do dinner?"),
            ChatMessage(role: "You", text: "Perfect, I'll find a place."),
        ])]
        store.save()
        return (store, model)
    }
    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < end else { return XCTFail("Timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// Speaks MCP over a child's stdio, newline-delimited JSON-RPC, as an MCP client does.
final class MCPStdioClient: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var responses: [Int: [String: Any]] = [:]
    private var nextID = 0

    init(helper: URL, arguments: [String], environment: [String: String]) throws {
        process.executableURL = helper
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.received(handle.availableData) }
        try process.run()
    }
    func close() {
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
    private func received(_ data: Data) {
        lock.withLock {
            buffer.append(data)
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = object["id"] as? Int { responses[id] = object }
            }
        }
    }
    private func write(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try input.fileHandleForWriting.write(contentsOf: data + Data([UInt8(ascii: "\n")]))
    }
    func notify(_ method: String) throws { try write(["jsonrpc": "2.0", "method": method]) }
    /// The whole response object.
    func raw(_ method: String, _ params: [String: Any], timeout: TimeInterval = 20) async throws -> [String: Any] {
        let id = lock.withLock { nextID += 1; return nextID }
        try write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let response = lock.withLock({ responses.removeValue(forKey: id) }) { return response }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "MCPStdioClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "No answer to \(method)"])
    }
    /// The result, or a failure for an error response.
    func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let response = try await raw(method, params)
        guard let result = response["result"] as? [String: Any] else {
            throw NSError(domain: "MCPStdioClient", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(method) failed: \(response)"])
        }
        return result
    }
}

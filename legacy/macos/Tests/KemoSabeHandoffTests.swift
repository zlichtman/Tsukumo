import XCTest
@testable import KemoSabeMac

/// Chatting with an agent in the KemoSabe chat (design/CONTEXT-HARNESS.md#chatting-with-an-agent): the
/// DEBUG fixture's chat through the real runner, with a fake Claude and a fake extractor, on a
/// throwaway account; the same with Codex; an ACP agent through the real ACP session, whose requests
/// other than asking KemoSabe are declined; the model chip's agents; and the flags each agent really gets.
@MainActor final class KemoSabeHandoffTests: XCTestCase {
    private var folder: URL?
    override func tearDown() async throws {
        KemoSabeHandoff.shared.makeSession = KemoSabeHandoff.claudeSession
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    func testACodexChatAsksKemoSabeAndContinuesWithCodex() async throws {
        let store = makeStore()
        ChatHandoffFixture.seed(store)
        let codex = AgentRequester(recipient: .codingAgent("codex"), name: "Codex")
        store.state.allowAgentQuestions(codex.recipient, once: false)
        store.selectChatAgent(ChatAgents.codex.id)
        store.agentQuestions.model = ChatHandoffFixture.FakeExtraction(delay: 0.05)
        var records: [CodingTaskRecord] = []
        var fakes: [KemoSabeHandoffFixture.FakeClaude] = []
        KemoSabeHandoff.shared.makeSession = { [weak store] record, id in
            records.append(record)
            let fake = KemoSabeHandoffFixture.FakeClaude(chat: id, desk: store?.agentQuestions, pace: 0.03, requester: codex)
            fakes.append(fake)
            return fake
        }
        let id = KemoSabeHandoff.shared.send(ChatHandoffFixture.task, store: store)
        XCTAssertEqual(store.handoffWorking, "Codex", "Codex's row works while it answers")
        XCTAssertEqual(records.first?.provider, .codex)
        XCTAssertEqual(records.first?.access, .readOnly, "Codex's read-only sandbox")
        XCTAssertEqual(records.first?.directory, KemoSabeHandoff.folder(for: id).path)
        let first = try XCTUnwrap(fakes.first?.sent.first)
        XCTAssertTrue(first.hasPrefix("(From KemoSabe, about this chat) " + KemoSabeHandoff.systemPrompt), "Codex has no system prompt flag: the words come first")
        XCTAssertTrue(first.hasSuffix("\n\n" + ChatHandoffFixture.task))

        try await waitUntil { !KemoSabeHandoff.shared.running.contains(id) }
        let marked = store.conversationMessages.filter { $0.handoff != nil }
        XCTAssertEqual(marked.compactMap(\.handoff?.part), [.task, .answer, .result])
        XCTAssertEqual(marked.map(\.role), ["You", "KemoSabe", "Codex"])
        XCTAssertEqual(marked.map(\.text), [ChatHandoffFixture.task, "After 7 tonight", ChatHandoffFixture.result], "The chat shows your message, not the words ahead of it")
        XCTAssertEqual(Set(marked.compactMap(\.handoff?.agentID)), [ChatAgents.codex.id])
        XCTAssertEqual(marked[1].handoff?.shared, "After 7 tonight", "Exactly what went to Codex")
        let journal = try await store.agentRequests.journal.snapshot()
        XCTAssertEqual(journal.last?.requester, "Codex")

        // The next message continues Codex's session with only your message.
        KemoSabeHandoff.shared.send("and a table for two", store: store)
        XCTAssertEqual(records.last?.sessionID, "fixture-session"); XCTAssertEqual(records.last?.provider, .codex)
        XCTAssertEqual(fakes.last?.sent, ["and a table for two"])
        try await waitUntil { !KemoSabeHandoff.shared.running.contains(id) }

        // Reopened from the list, the chat continues with Codex.
        let conversation = store.conversationID(for: store.currentConversationSlot)
        store.newConversation()
        store.selectChatAgent(nil)
        store.resumeArchivedConversation(conversation)
        XCTAssertEqual(store.state.chatAgent, ChatAgents.codex.id)
        XCTAssertEqual(AppStore.chatAgent(in: [ChatMessage(handoff: .init(id: UUID(), part: .task, agent: "Claude"), text: "old")]), ChatHandoff.claudeAgentID,
                       "A chat from before the other agents is with Claude")
    }

    func testAnACPAgentMayAskKemoSabeAndEverythingElseIsDeclined() async throws {
        KemoSabeMCP.launchOverride = URL(fileURLWithPath: "/Applications/Tsukumo.app/Contents/Helpers/kemosabe-mcp")
        defer { KemoSabeMCP.launchOverride = nil }
        let store = makeStore()
        store.selectChatAgent(ChatAgents.cursor.id)
        let scripts = try XCTUnwrap(folder).appendingPathComponent("agents", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let agent = scripts.appendingPathComponent("chat-acp")
        try Self.acpAgent.write(to: agent, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: agent.path)
        var records: [CodingTaskRecord] = []
        KemoSabeHandoff.shared.makeSession = { record, id in
            records.append(record)
            let session = CodingACPSession(task: record, launch: .init(command: agent.path, arguments: [], environment: .inherit, name: "Cursor Agent"),
                                           interruptGrace: 1, terminationGrace: 1)
            session.handoff = id.uuidString
            return session
        }
        let id = KemoSabeHandoff.shared.send("find a date spot", store: store)
        XCTAssertEqual(store.handoffWorking, "Cursor Agent")
        XCTAssertEqual(records.first?.provider, .cursor); XCTAssertEqual(records.first?.access, .edit, "It asks, and the chat answers")
        try await waitUntil(timeout: 20) { !KemoSabeHandoff.shared.running.contains(id) }
        XCTAssertEqual(store.conversationMessages.last?.handoff?.part, .result, store.conversationMessages.last?.text ?? "")
        XCTAssertEqual(store.conversationMessages.last?.text, "Osteria Lucia at 7:30")
        XCTAssertEqual(store.conversationMessages.last?.role, "Cursor Agent")
        XCTAssertEqual(store.conversationMessages.last?.handoff?.session, "s-chat")

        let log = try String(contentsOf: scripts.appendingPathComponent("acp-log"), encoding: .utf8).split(separator: "\n").map(String.init)
        let servers = try XCTUnwrap(log.first { $0.hasPrefix("mcp ") })
        XCTAssertTrue(servers.contains("\"--handoff\", \"\(id.uuidString)\""), "The KemoSabe server knows which chat asked: \(servers)")
        XCTAssertTrue(log.contains { $0.hasPrefix("prompt (From KemoSabe, about this chat) ") && $0.hasSuffix("find a date spot") })
        XCTAssertTrue(log.contains("ask selected allow-once"), "Asking KemoSabe is allowed: \(log)")
        XCTAssertTrue(log.contains("command selected reject-once"), "A command is declined: \(log)")
        XCTAssertTrue(log.contains("edit selected reject-once"), "An edit is declined: \(log)")
        XCTAssertTrue(log.contains("read error"), "A file outside its folder isn't read: \(log)")
        XCTAssertTrue(log.contains("write error")); XCTAssertTrue(log.contains("terminal error"))
        XCTAssertTrue(log.contains("fetch selected allow-once"), "Reading the web needs no one: \(log)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: KemoSabeHandoff.folder(for: id).appendingPathComponent("x.txt").path))
    }

    func testTheModelChipListsEachInstalledAgentWithItsMark() throws {
        let suite = "kemo-handoff-agents-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let registry = CodingAgentRegistry(defaults: defaults)
        let goose = CodingCustomAgent(name: "Goose", command: "/bin/cat")
        registry.save(goose)
        let options = KemoSabeHandoff.options(registry: registry, desktop: DesktopNavigation(defaults: defaults))
        XCTAssertEqual(options.first?.id, ChatHandoff.claudeAgentID, "Claude first, even when it isn't installed")
        let expected = registry.adapters.filter { registry.isInstalled($0.provider) || $0.provider == .claude }.map { KemoSabeHandoff.agentID(for: $0.provider) }
        XCTAssertEqual(options.map(\.id), expected, "Claude, then each installed agent, in Tsukumo's order")
        XCTAssertTrue(options.map(\.id).contains("acp:" + goose.id.uuidString.lowercased()), "An added ACP agent too")
        for option in options {
            if let kind = ChatAgents.kind(option.id) {
                XCTAssertEqual(option.logo, kind.logo, "Its official mark"); XCTAssertEqual(option.title, kind.title)
            }
            XCTAssertEqual(option.available, registry.isInstalled(KemoSabeHandoff.provider(for: option.id)!))
            XCTAssertFalse(option.detail.contains("—"))
        }
        let added = try XCTUnwrap(options.last)
        XCTAssertEqual(added.title, "Goose"); XCTAssertEqual(added.logo, "", "Initials, never another company's mark")
        XCTAssertEqual(added.detail, "Goose · your own sign-in"); XCTAssertNil(added.signIn)
        XCTAssertEqual(KemoSabeHandoff.provider(for: added.id), goose.provider)
        XCTAssertEqual(KemoSabeHandoff.title(for: added.id), "Goose")
    }

    func testWhatEachAgentMayDoAndTheFlagsItGets() throws {
        func approval(_ title: String, kind: CodingApproval.Kind = .command, command: String? = nil, tool: String? = nil) -> CodingApproval {
            .init(id: "a", title: title, detail: "", kind: kind, command: command, tool: tool)
        }
        XCTAssertEqual(KemoSabeHandoff.decision(for: approval("kemosabe: ask_kemosabe")), .allowOnce)
        XCTAssertEqual(KemoSabeHandoff.decision(for: approval("Ask KemoSabe", tool: "mcp__kemosabe__ask_kemosabe")), .allowOnce)
        XCTAssertEqual(KemoSabeHandoff.decision(for: approval("Search the web", tool: "web_search")), .allowOnce)
        XCTAssertEqual(KemoSabeHandoff.decision(for: approval("rm -rf ~", command: "rm -rf ~")), .deny(note: KemoSabeHandoff.declineNote))
        XCTAssertEqual(KemoSabeHandoff.decision(for: approval("a.txt", kind: .files, tool: "web_search")), .deny(note: KemoSabeHandoff.declineNote))
        XCTAssertEqual(KemoSabeHandoff.decision(for: approval("curl x", command: "curl x", tool: "web_fetch")), .deny(note: KemoSabeHandoff.declineNote))
        XCTAssertEqual(KemoSabeHandoff.access(for: .codex), .readOnly)
        XCTAssertEqual([CodingProvider.claude, .muse, .cursor].map(KemoSabeHandoff.access), [.edit, .edit, .edit])
        XCTAssertEqual(KemoSabeHandoff.museFlags, ["--disable-write", "--disable-shell"])
        for id in ["claude-code", "codex", "muse", "cursor-agent"] {
            XCTAssertEqual(KemoSabeHandoff.agentID(for: try XCTUnwrap(KemoSabeHandoff.provider(for: id))), id)
        }
        XCTAssertNil(KemoSabeHandoff.provider(for: "gemini"))

        KemoSabeMCP.launchOverride = URL(fileURLWithPath: "/Applications/Tsukumo.app/Contents/Helpers/kemosabe-mcp")
        defer { KemoSabeMCP.launchOverride = nil }
        let codex = CodingAgentSession.codexArguments(handoff: "H1", extra: KemoSabeHandoff.codexFlags)
        XCTAssertEqual(Array(codex.prefix(3)), ["app-server", "--listen", "stdio://"])
        XCTAssertTrue(codex.contains(#"mcp_servers.kemosabe.args=["--agent", "codex", "--handoff", "H1"]"#), codex.joined(separator: " "))
        XCTAssertTrue(codex.contains(#"mcp_servers.kemosabe.default_tools_approval_mode="approve""#), "Asking KemoSabe needs no approval")
        for feature in ["shell_tool", "unified_exec", "computer_use", "browser_use", "apps"] { XCTAssertTrue(codex.contains("features.\(feature)=false"), feature) }
        let task = CodingAgentSession.codexArguments()
        XCTAssertTrue(task.contains(#"mcp_servers.kemosabe.args=["--agent", "codex"]"#))
        XCTAssertFalse(task.joined().contains("approval_mode"), "Tsukumo's own Codex tasks ask as before")
        XCTAssertEqual(KemoSabeMCP.acpServers(agent: "cursor-agent", handoff: "H2").first?["args"] as? [String], ["--agent", "cursor-agent", "--handoff", "H2"])
        XCTAssertEqual(KemoSabeMCP.acpServers(agent: "cursor-agent").first?["args"] as? [String], ["--agent", "cursor-agent"])
        let muse = try XCTUnwrap((KemoSabeMCP.museSessionConfig(handoff: "H3")?["mcpServers"] as? [String: Any])?["kemosabe"] as? [String: Any])
        XCTAssertEqual(muse["args"] as? [String], ["--agent", "muse", "--handoff", "H3"])
    }

    func testTheChatShowsYourMessageKemosCardAndClaudesReply() async throws {
        let store = makeStore()
        ChatHandoffFixture.seed(store)
        XCTAssertEqual(store.state.chatAgent, ChatHandoff.claudeAgentID)
        store.agentQuestions.model = ChatHandoffFixture.FakeExtraction(delay: 0.1)
        KemoSabeHandoff.shared.makeSession = { [weak store] _, id in KemoSabeHandoffFixture.FakeClaude(chat: id, desk: store?.agentQuestions, pace: 0.03) }
        let id = KemoSabeHandoff.shared.send(ChatHandoffFixture.task, store: store)
        XCTAssertTrue(KemoSabeHandoff.shared.isRunning(store))
        XCTAssertEqual(store.handoffWorking, ChatHandoff.claude, "Claude's row works while it answers")

        // Claude asks: Kemo's card shows the question, and Kemo reads this Mac.
        try await waitUntil { store.localLookup != nil }
        let card = try XCTUnwrap(store.conversationMessages.last)
        XCTAssertEqual(card.handoff?.part, .question); XCTAssertEqual(card.text, ChatHandoffFixture.question)
        XCTAssertEqual(TaskActivity.live("idle", store: store), ArtworkPerformance.research.rawValue, "Kemo acts out searching")

        try await waitUntil { !KemoSabeHandoff.shared.running.contains(id) }
        XCTAssertNil(store.localLookup); XCTAssertNil(store.handoffWorking)
        let parts = store.conversationMessages.compactMap { message in message.handoff.map { ($0.part, message.role, message.text, $0) } }
        XCTAssertEqual(parts.map(\.0), [.task, .answer, .result], "The question card became Kemo's answer")
        XCTAssertEqual(parts[0].1, "You"); XCTAssertEqual(parts[0].2, "find a date spot for Sarah and I tonight")
        let answer = parts[1].3
        XCTAssertEqual(parts[1].1, "KemoSabe"); XCTAssertEqual(parts[1].2, "After 7 tonight")
        XCTAssertEqual(store.conversationMessages[1].id, card.id, "One card, updated in place")
        XCTAssertEqual(answer.question, ChatHandoffFixture.question)
        XCTAssertEqual(answer.shared, "After 7 tonight", "Exactly what went to Claude")
        XCTAssertEqual(answer.stayedLine, "Stayed on this Mac: 4 messages, 2 chats", "Counted, never shown")
        XCTAssertEqual(answer.detail, "Not read: 1 Device only chat.")
        XCTAssertEqual(answer.localCaption, "On this Mac · Apple on-device")
        XCTAssertFalse([answer.detail, answer.stayed, answer.shared].compactMap { $0 }.joined().contains("4411"))
        XCTAssertEqual(parts[2].1, "Claude"); XCTAssertEqual(parts[2].2, ChatHandoffFixture.result)
        XCTAssertEqual(store.agentChat.session, "fixture-session", "The next message continues Claude's session")
        XCTAssertNil(store.agentQuestions.handoffObservers[id], "The turn stops listening once it's done")

        let journal = try await store.agentRequests.journal.snapshot()
        XCTAssertEqual(journal.last?.requester, "Claude"); XCTAssertEqual(journal.last?.shared, "After 7 tonight")
        XCTAssertEqual(journal.last?.lookingFor, ChatHandoffFixture.question)
        XCTAssertNil(ConversationArchive(model: "Apple", recipient: nil, messages: store.conversationMessages).counterpart)
    }

    func testTheFirstQuestionAsksOnKemosCard() async throws {
        let store = makeStore()
        ChatHandoffFixture.seed(store)
        store.state.revokeAgentQuestions(ChatHandoffFixture.claude.recipient.key)
        store.agentQuestions.model = ChatHandoffFixture.FakeExtraction(delay: 0.05)
        KemoSabeHandoff.shared.makeSession = { [weak store] _, id in KemoSabeHandoffFixture.FakeClaude(chat: id, desk: store?.agentQuestions, pace: 0.03) }
        let id = KemoSabeHandoff.shared.send(ChatHandoffFixture.task, store: store)
        try await waitUntil { store.agentQuestions.consent != nil }
        XCTAssertEqual(store.agentQuestions.consent?.inChat, true, "Asked on Kemo's card in the chat, not an alert")
        XCTAssertEqual(store.conversationMessages.last?.handoff?.part, .question)
        store.agentQuestions.decide(.always)
        try await waitUntil { !KemoSabeHandoff.shared.running.contains(id) }
        XCTAssertEqual(store.conversationMessages.compactMap(\.handoff?.part), [.task, .answer, .result])
        XCTAssertFalse(store.state.agentQuestionGrants(for: ChatHandoffFixture.claude.recipient).isEmpty, "Allowed always from now on")
    }

    func testClaudeGetsOnlyYourMessageAndAnythingElseItAsksToDoIsDeclined() async throws {
        let store = makeStore()
        store.selectChatAgent(ChatHandoff.claudeAgentID)
        let session = RecordingSession()
        var records: [CodingTaskRecord] = []
        KemoSabeHandoff.shared.makeSession = { record, _ in records.append(record); return session }
        let id = KemoSabeHandoff.shared.send("book it", store: store)
        XCTAssertEqual(session.sent, ["book it"], "Only your message goes to Claude")
        XCTAssertEqual(records.first?.directory, KemoSabeHandoff.folder(for: id).path, "A neutral folder for this chat, never a project")
        XCTAssertNil(records.first?.sessionID)
        session.onApproval?(.init(id: "a1", title: "rm -rf ~", detail: ""))
        XCTAssertEqual(session.responses.map(\.0), ["a1"]); XCTAssertEqual(session.responses.first?.1, false)
        session.onSession?("s-42")
        session.onEvent?(.init(id: "r1", kind: .assistant, text: "Booked"), false)
        XCTAssertEqual(store.handoffStreaming, "Booked", "The reply streams in")
        session.onState?(.review)
        XCTAssertFalse(KemoSabeHandoff.shared.running.contains(id)); XCTAssertTrue(session.stopped)
        XCTAssertEqual(store.conversationMessages.last?.handoff?.session, "s-42")

        // The next message resumes Claude's session in the same folder.
        KemoSabeHandoff.shared.send("and a table for two", store: store)
        XCTAssertEqual(records.last?.sessionID, "s-42"); XCTAssertEqual(records.last?.directory, records.first?.directory)
        session.onState?(.failed)
        XCTAssertEqual(store.conversationMessages.last?.handoff?.part, .status)
    }

    func testAReplyLandsInItsOwnChatAfterYouSwitchChats() throws {
        let store = makeStore()
        store.selectChatAgent(ChatHandoff.claudeAgentID)
        var sessions: [UUID: RecordingSession] = [:]
        KemoSabeHandoff.shared.makeSession = { _, id in let session = RecordingSession(); sessions[id] = session; return session }
        let first = KemoSabeHandoff.shared.send("find a date spot", store: store)
        let firstConversation = store.conversationID(for: store.currentConversationSlot)
        sessions[first]?.onEvent?(.init(id: "r1", kind: .assistant, text: "Look"), false)
        XCTAssertEqual(store.handoffStreaming, "Look")

        // A new chat while Claude still works in the first: nothing of the first shows here.
        store.newConversation()
        XCTAssertEqual(store.state.chatAgent, ChatHandoff.claudeAgentID)
        XCTAssertTrue(store.conversationMessages.isEmpty)
        XCTAssertNil(store.handoffWorking, "The working row stays with its chat")
        XCTAssertEqual(store.handoffStreaming, "")
        XCTAssertFalse(KemoSabeHandoff.shared.isRunning(store))

        // The new chat's own turn runs alongside.
        let second = KemoSabeHandoff.shared.send("and a gift idea", store: store)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(store.handoffWorking, ChatHandoff.claude)
        sessions[first]?.onEvent?(.init(id: "r1", kind: .assistant, text: "Looking at places"), false)
        XCTAssertEqual(store.handoffStreaming, "", "The first chat's stream never shows in this one")

        // The first chat's reply lands in the first chat, saved in the list.
        sessions[first]?.onSession?("s-first")
        sessions[first]?.onEvent?(.init(id: "r1", kind: .assistant, text: "Osteria Lucia at 7:30"), false)
        sessions[first]?.onState?(.review)
        XCTAssertEqual(store.conversationMessages.map(\.text), ["and a gift idea"], "Nothing from the first chat lands here")
        XCTAssertEqual(store.handoffWorking, ChatHandoff.claude, "This chat's turn is still working")
        let saved = try XCTUnwrap(store.state.conversationArchives?.first { $0.id == firstConversation })
        XCTAssertEqual(saved.messages.map(\.text), ["find a date spot", "Osteria Lucia at 7:30"])
        XCTAssertEqual(saved.messages.last?.handoff?.part, .result)
        XCTAssertEqual(saved.messages.last?.handoff?.session, "s-first")

        // This chat's reply is its own.
        sessions[second]?.onEvent?(.init(id: "r2", kind: .assistant, text: "A book"), false)
        sessions[second]?.onState?(.review)
        XCTAssertEqual(store.conversationMessages.map(\.text), ["and a gift idea", "A book"])
        XCTAssertNil(store.handoffWorking)

        // Back in the first chat, it continues Claude's session there.
        store.resumeArchivedConversation(firstConversation)
        XCTAssertEqual(store.agentChat.id, first)
        XCTAssertEqual(store.agentChat.session, "s-first")
        XCTAssertEqual(store.conversationMessages.map(\.text), ["find a date spot", "Osteria Lucia at 7:30"])
        // A saved copy on disk has them in the right chats too.
        let reopened = AppStore(repository: .init(url: try XCTUnwrap(folder).appendingPathComponent("state.json")), provider: APIUnavailableLocal(), apiKeys: MemoryAPIKeys())
        XCTAssertEqual(reopened.conversationMessages.map(\.text), ["find a date spot", "Osteria Lucia at 7:30"])
        XCTAssertEqual(reopened.state.conversationArchives?.first { $0.messages.first?.handoff?.id == second }?.messages.map(\.text), ["and a gift idea", "A book"])
    }

    func testAStopOrFailureAfterSwitchingIsItsOwnChatsStatus() throws {
        let store = makeStore()
        store.selectChatAgent(ChatHandoff.claudeAgentID)
        var sessions: [UUID: RecordingSession] = [:]
        KemoSabeHandoff.shared.makeSession = { _, id in let session = RecordingSession(); sessions[id] = session; return session }
        let first = KemoSabeHandoff.shared.send("book it", store: store)
        store.newConversation()
        store.selectChatAgent(nil)
        store.appendVisibleMessage(role: "You", text: "hello Kemo")
        KemoSabeHandoff.shared.stopTurn(first)
        XCTAssertEqual(store.conversationMessages.map(\.text), ["hello Kemo"])
        let saved = try XCTUnwrap(store.state.conversationArchives?.first { $0.messages.first?.handoff?.id == first })
        XCTAssertEqual(saved.messages.last?.handoff?.part, .status)
        XCTAssertEqual(saved.messages.last?.text, "Claude stopped.")
        XCTAssertTrue(store.handoffTurns.isEmpty)
    }

    func testClaudesFlags() throws {
        XCTAssertTrue(KemoSabeHandoff.claudeFlags.contains("--strict-mcp-config"), "Only the KemoSabe server, none of the owner's others")
        XCTAssertTrue(KemoSabeHandoff.claudeFlags.contains("mcp__kemosabe__ask_kemosabe,WebSearch,WebFetch"))
        KemoSabeMCP.launchOverride = URL(fileURLWithPath: "/Applications/Tsukumo.app/Contents/Helpers/kemosabe-mcp")
        defer { KemoSabeMCP.launchOverride = nil }
        var task = CodingTaskRecord(projectID: UUID(), ownerID: "kemosabe-chat", title: "T", provider: .claude, model: "", access: .edit,
                                    projectPath: "/tmp", directory: "/tmp", isolated: false)
        task.sessionID = "s-1"
        let args = CodingAgentSession.claudeArguments(for: task, resume: task.sessionID, handoff: "H1")
        let config = try XCTUnwrap(args.firstIndex(of: "--mcp-config").map { args[$0 + 1] })
        XCTAssertTrue(config.contains("\"--handoff\",\"H1\""), config)
        XCTAssertEqual(args.firstIndex(of: "--resume").map { args[$0 + 1] }, "s-1")
        XCTAssertEqual(KemoSabeHandoff.options(registry: CodingAgentRegistry.shared, desktop: DesktopNavigation(defaults: UserDefaults(suiteName: "kemo-handoff-tests")!)).first?.logo,
                       "AgentLogoClaude", "Claude's official mark")
    }

    // MARK: Helpers

    /// An ACP agent (protocol v1, Cursor Agent's modes and choices) whose one turn asks to use the
    /// KemoSabe tool, then to run a command, edit a file, read one outside its folder, write one, open a
    /// terminal, and fetch a page, logging what it was told; then it replies.
    static let acpAgent = #"""
    #!/usr/bin/python3
    import json, sys, os
    log = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "acp-log"), "a")
    def L(s): log.write(s + "\n"); log.flush()
    def emit(x): sys.stdout.write(json.dumps(x) + "\n"); sys.stdout.flush()
    def read():
        line = sys.stdin.readline()
        if not line: sys.exit(0)
        return json.loads(line)
    nid = [1000]
    def ask(method, params):
        nid[0] += 1; rid = nid[0]
        emit({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        while True:
            x = read()
            if x.get("id") == rid and "method" not in x: return x
            L("unexpected " + json.dumps(x))
    def outcome(r):
        o = r["result"]["outcome"]
        return o["outcome"] + (" " + o["optionId"] if "optionId" in o else "")
    opts = [{"optionId": "allow-once", "name": "Allow", "kind": "allow_once"}, {"optionId": "allow-always", "name": "Always allow", "kind": "allow_always"}, {"optionId": "reject-once", "name": "Reject", "kind": "reject_once"}]
    modes = [{"id": "agent", "name": "Agent"}, {"id": "plan", "name": "Plan"}, {"id": "ask", "name": "Ask"}]
    while True:
        x = read(); m = x.get("method"); p = x.get("params", {})
        if m == "initialize":
            emit({"jsonrpc": "2.0", "id": x["id"], "result": {"protocolVersion": 1, "agentCapabilities": {"loadSession": True}}})
        elif m == "session/new":
            L("mcp " + json.dumps(p["mcpServers"]))
            emit({"jsonrpc": "2.0", "id": x["id"], "result": {"sessionId": "s-chat", "modes": {"currentModeId": "agent", "availableModes": modes}}})
        elif m == "session/set_mode": L("mode " + p["modeId"]); emit({"jsonrpc": "2.0", "id": x["id"], "result": {}})
        elif m == "session/prompt":
            sid = p["sessionId"]; cwd = os.getcwd()
            L("prompt " + p["prompt"][0]["text"].replace("\n", " "))
            L("ask " + outcome(ask("session/request_permission", {"sessionId": sid, "toolCall": {"toolCallId": "k1", "title": "kemosabe: ask_kemosabe", "kind": "other", "rawInput": {"question": "When is Sarah free?", "purpose": "a date"}}, "options": opts})))
            L("command " + outcome(ask("session/request_permission", {"sessionId": sid, "toolCall": {"toolCallId": "c1", "title": "rm -rf ~", "kind": "execute", "rawInput": {"command": "rm -rf ~"}}, "options": opts})))
            L("edit " + outcome(ask("session/request_permission", {"sessionId": sid, "toolCall": {"toolCallId": "e1", "title": "Edit x.txt", "kind": "edit", "locations": [{"path": cwd + "/x.txt"}]}, "options": opts})))
            r = ask("fs/read_text_file", {"sessionId": sid, "path": "/etc/hosts"}); L("read " + ("ok" if "result" in r else "error"))
            r = ask("fs/write_text_file", {"sessionId": sid, "path": cwd + "/x.txt", "content": "x"}); L("write " + ("ok" if "result" in r else "error"))
            r = ask("terminal/create", {"sessionId": sid, "command": "/bin/echo", "args": ["hi"]}); L("terminal " + ("ok" if "result" in r else "error"))
            L("fetch " + outcome(ask("session/request_permission", {"sessionId": sid, "toolCall": {"toolCallId": "f1", "title": "Fetch a page", "kind": "fetch", "rawInput": {"url": "https://example.com"}}, "options": opts})))
            emit({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Osteria Lucia "}}}})
            emit({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "at 7:30"}}}})
            emit({"jsonrpc": "2.0", "id": x["id"], "result": {"stopReason": "end_turn"}})
        elif m == "session/cancel": L("cancel")
        else: L("unexpected " + json.dumps(x))
    """#

    private func makeStore() -> AppStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        self.folder = folder
        return AppStore(repository: .init(url: folder.appendingPathComponent("state.json")), provider: APIUnavailableLocal(), apiKeys: MemoryAPIKeys())
    }
    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < end else { return XCTFail("Timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor private final class RecordingSession: AgentSession {
    var onEvent: ((CodingEvent, Bool) -> Void)?
    var onState: ((CodingTaskStatus) -> Void)?
    var onSession: ((String) -> Void)?
    var onApproval: ((CodingApproval?) -> Void)?
    var sent: [String] = []
    var responses: [(String, Bool)] = []
    var stopped = false
    func send(_ text: String) throws { sent.append(text) }
    func respond(_ id: String, allow: Bool, answers: String) throws { responses.append((id, allow)) }
    func stop() { stopped = true }
}

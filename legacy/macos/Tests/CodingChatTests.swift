import XCTest
@testable import KemoSabeMac

/// The agent chat: Markdown blocks, syntax colors, tool cards built from each agent's stream,
/// mention search, slash commands, session resume and fork arguments, and the store's queue,
/// pins, unread marks, settings, forks, and commits. Fixtures and mock executables only.
@MainActor final class CodingChatTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("CodingChatTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let folder { try? FileManager.default.removeItem(at: folder) } }
    /// XCTUnwrap for awaited values (its autoclosure can't await).
    private func unwrap<T>(_ value: T?, _ message: String = "") throws -> T {
        guard let value else { XCTFail("Unexpected nil. " + message); throw CodingFailure("nil") }
        return value
    }
    private func record(_ provider: CodingProvider = .codex, directory: String? = nil) -> CodingTaskRecord {
        .init(projectID: UUID(), ownerID: "local-test", title: "Test task", provider: provider, model: "", access: .edit, projectPath: folder.path, directory: directory ?? folder.path, isolated: false)
    }

    // MARK: Markdown

    func testMarkdownBlocks() {
        let text = """
        # Title
        Some **bold** text
        continues here.

        - one
          - nested
        - [x] done
        1. first
        2) second

        > quoted
        > more

        | Name | Count |
        |:-----|------:|
        | a \\| b | 2 |
        | c |

        ---
        ```swift
        let x = 1
        ```
        """
        let blocks = CodingMarkdown.parse(text)
        XCTAssertEqual(blocks[0], .heading(level: 1, text: "Title"))
        XCTAssertEqual(blocks[1], .paragraph("Some **bold** text\ncontinues here."))
        guard case .list(let items) = blocks[2] else { return XCTFail("list") }
        XCTAssertEqual(items.map(\.text), ["one", "nested", "done", "first", "second"])
        XCTAssertEqual(items.map(\.depth), [0, 1, 0, 0, 0])
        XCTAssertEqual(items[2].checked, true); XCTAssertEqual(items[3].marker, "1."); XCTAssertEqual(items[4].marker, "2.")
        XCTAssertEqual(blocks[3], .quote([.paragraph("quoted\nmore")]))
        XCTAssertEqual(blocks[4], .table(header: ["Name", "Count"], alignments: [.leading, .trailing], rows: [["a | b", "2"], ["c", ""]]))
        XCTAssertEqual(blocks[5], .rule)
        XCTAssertEqual(blocks[6], .code(language: "swift", text: "let x = 1", closed: true))
        XCTAssertEqual(blocks.count, 7)
    }
    func testMarkdownWhileStreaming() {
        // An unclosed fence is code to the end; a table without its separator yet is a paragraph.
        XCTAssertEqual(CodingMarkdown.parse("Run:\n```sh\nnpm test\nnpm run"), [.paragraph("Run:"), .code(language: "sh", text: "npm test\nnpm run", closed: false)])
        XCTAssertEqual(CodingMarkdown.parse("| a | b |"), [.paragraph("| a | b |")])
        XCTAssertEqual(CodingMarkdown.parse("#hashtag is not a heading"), [.paragraph("#hashtag is not a heading")])
        XCTAssertEqual(CodingMarkdown.parse("- a\n\n- b"), [.list([.init(depth: 0, marker: "•", text: "a"), .init(depth: 0, marker: "•", text: "b")])])
        XCTAssertEqual(CodingMarkdown.cells("| x | `y` |"), ["x", "`y`"])
    }
    func testSyntaxColors() {
        let swift = CodingSyntax.segments("let name = \"Kemo\" // hi\nstruct Pet {}", language: "swift")
        XCTAssertTrue(swift.contains(.init(text: "let", kind: .keyword)))
        XCTAssertTrue(swift.contains(.init(text: "\"Kemo\"", kind: .string)))
        XCTAssertTrue(swift.contains(.init(text: "// hi", kind: .comment)))
        XCTAssertTrue(swift.contains(.init(text: "Pet", kind: .type)))
        XCTAssertEqual(swift.map(\.text).joined(), "let name = \"Kemo\" // hi\nstruct Pet {}", "Highlighting never changes the text")
        let python = CodingSyntax.segments("def f(): return 42  # answer", language: "py")
        XCTAssertTrue(python.contains(.init(text: "def", kind: .keyword))); XCTAssertTrue(python.contains(.init(text: "42", kind: .number)))
        XCTAssertTrue(python.contains(.init(text: "# answer", kind: .comment)))
        XCTAssertEqual(CodingSyntax.segments("+added\n-removed", language: "diff").filter { $0.text != "\n" }.map(\.kind), [.string, .keyword])
    }

    // MARK: Tool cards from each agent's stream

    func testClaudeToolEventsBecomeCards() {
        let dir = "/work/project"
        let bash = CodingChatEvents.claudeTool(name: "Bash", input: ["command": "swift test", "description": "Run tests"], id: "t1", directory: dir)
        XCTAssertEqual(bash.kind, .command); XCTAssertEqual(bash.text, "swift test"); XCTAssertEqual(bash.status, "running")
        let edit = CodingChatEvents.claudeTool(name: "Edit", input: ["file_path": dir + "/Sources/App.swift", "old_string": "a\nb", "new_string": "a\nc\nd"], id: "t2", directory: dir)
        XCTAssertEqual(edit.kind, .file); XCTAssertEqual(edit.text, "Sources/App.swift")
        let files = CodingDiff.parse(edit.detail)
        XCTAssertEqual(files.map(\.path), ["Sources/App.swift"]); XCTAssertEqual(files[0].additions, 3); XCTAssertEqual(files[0].deletions, 2)
        let write = CodingChatEvents.claudeTool(name: "Write", input: ["file_path": dir + "/new.txt", "content": "x\ny\n"], id: "t3", directory: dir)
        XCTAssertEqual(CodingDiff.parse(write.detail).first?.change, .added); XCTAssertEqual(CodingDiff.parse(write.detail).first?.additions, 2)
        let todo = CodingChatEvents.claudeTool(name: "TodoWrite", input: ["todos": [["content": "Read code", "status": "completed"], ["content": "Fix", "status": "in_progress"], ["content": "Test", "status": "pending"]]], id: "t4", directory: dir)
        XCTAssertEqual(todo.kind, .plan); XCTAssertEqual(CodingPlanStep.parse(todo.detail).map(\.state), [.done, .active, .pending])
        XCTAssertEqual(CodingChatEvents.claudeTool(name: "Read", input: ["file_path": dir + "/README.md"], id: "t5", directory: dir).text, "Read README.md")
        XCTAssertEqual(CodingChatEvents.claudeTool(name: "Grep", input: ["pattern": "TODO"], id: "t6", directory: dir).text, "Search “TODO”")
    }
    func testAToolResultFillsItsCardWithoutErasingIt() {
        var task = record(.claude)
        CodingTranscript.apply(CodingChatEvents.claudeTool(name: "Edit", input: ["file_path": folder.path + "/a.txt", "old_string": "a", "new_string": "b"], id: "t1", directory: folder.path), delta: false, to: &task)
        var result = CodingEvent(id: "t1", kind: .command, text: "", status: "completed"); result.output = "The file has been updated."; result.duration = 0.4
        CodingTranscript.apply(result, delta: false, to: &task)
        XCTAssertEqual(task.events.count, 1)
        XCTAssertEqual(task.events[0].kind, .file, "The result keeps the card's kind")
        XCTAssertEqual(task.events[0].text, "a.txt"); XCTAssertFalse(task.events[0].detail.isEmpty, "The diff stays")
        XCTAssertEqual(task.events[0].output, "The file has been updated."); XCTAssertEqual(task.events[0].status, "completed"); XCTAssertEqual(task.events[0].duration, 0.4)
    }
    func testCodexStreamBecomesReasoningCardsAndDiffs() async throws {
        let script = folder.appendingPathComponent("fake-codex")
        try #"""
        #!/usr/bin/python3
        import json, sys
        def emit(x): print(json.dumps(x), flush=True)
        T = "fixture-thread"
        for line in sys.stdin:
            x = json.loads(line); m = x.get("method")
            if m == "initialize": emit({"id": x["id"], "result": {}})
            elif m == "thread/start": emit({"id": x["id"], "result": {"thread": {"id": T}}})
            elif m == "turn/start":
                emit({"id": x["id"], "result": {"turn": {"id": "turn-1"}}})
                emit({"method": "turn/started", "params": {"threadId": T, "turn": {"id": "turn-1"}}})
                emit({"method": "item/reasoning/summaryTextDelta", "params": {"threadId": T, "turnId": "turn-1", "itemId": "r1", "summaryIndex": 0, "delta": "**Looking**"}})
                emit({"method": "item/started", "params": {"threadId": T, "item": {"type": "commandExecution", "id": "c1", "command": "/bin/zsh -lc 'ls -la'", "status": "inProgress", "commandActions": []}}})
                emit({"method": "item/commandExecution/outputDelta", "params": {"threadId": T, "itemId": "c1", "delta": "a.txt\n"}})
                emit({"method": "item/completed", "params": {"threadId": T, "item": {"type": "commandExecution", "id": "c1", "command": "/bin/zsh -lc 'ls -la'", "status": "completed", "exitCode": 0, "durationMs": 1250, "aggregatedOutput": "", "commandActions": []}}})
                emit({"method": "item/completed", "params": {"threadId": T, "item": {"type": "fileChange", "id": "f1", "status": "completed", "changes": [{"path": sys.argv[0].rsplit("/", 1)[0] + "/new.swift", "kind": {"type": "add"}, "diff": "let a = 1\nlet b = 2\n"}, {"path": "old.swift", "kind": {"type": "update"}, "diff": "@@ -1,2 +1,2 @@\n-x\n+y\n z\n"}]}}})
                emit({"method": "item/agentMessage/delta", "params": {"threadId": T, "itemId": "m1", "delta": "Done."}})
                emit({"method": "turn/completed", "params": {"threadId": T, "turn": {"id": "turn-1", "status": "completed"}}})
        """#.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let session = CodingAgentSession(task: record(), executableOverride: script)
        var task = record()
        let finished = expectation(description: "turn completed")
        session.onEvent = { event, delta in CodingTranscript.apply(event, delta: delta, to: &task) }
        session.onState = { if $0 == .review { finished.fulfill() } }
        try session.send("Fixture only")
        await fulfillment(of: [finished], timeout: 10); session.stop()
        let items = CodingTranscriptItem.build(task.events)
        guard case .reasoning(let reasoning) = items.first else { return XCTFail("reasoning first: \(items)") }
        XCTAssertEqual(reasoning.text, "**Looking**")
        guard case .tools(let cards) = items[1] else { return XCTFail("tool card") }
        XCTAssertEqual(cards[0].title, "ls -la", "The login-shell wrapper is hidden")
        XCTAssertEqual(cards[0].output, "a.txt\n", "Streamed output is kept when the completion's is empty")
        XCTAssertEqual(cards[0].exitCode, 0); XCTAssertEqual(cards[0].duration, 1.25); XCTAssertTrue(cards[0].shell)
        guard case .file(let file) = items[2] else { return XCTFail("file card") }
        let files = CodingDiff.parse(file.detail)
        XCTAssertEqual(files.map(\.path), ["new.swift", "old.swift"], "Paths inside the task folder are shown relative")
        XCTAssertEqual(files[0].change, .added); XCTAssertEqual(files[0].additions, 2); XCTAssertEqual(files[1].additions, 1); XCTAssertEqual(files[1].deletions, 1)
        guard case .assistant(let message) = items[3] else { return XCTFail("message") }
        XCTAssertEqual(message.text, "Done."); XCTAssertEqual(message.ref, "turn-1", "Messages carry their turn for forking")
    }
    func testClaudeStreamThinkingToolAndResult() async throws {
        let script = folder.appendingPathComponent("fake-claude")
        try #"""
        #!/usr/bin/python3
        import json, sys
        def emit(x): print(json.dumps(x), flush=True)
        for line in sys.stdin:
            x = json.loads(line)
            if x.get("type") == "user":
                emit({"type": "system", "subtype": "init", "session_id": "s1", "slash_commands": ["compact", "review", "my-command"], "model": "sonnet"})
                emit({"type": "stream_event", "event": {"type": "message_start", "message": {"id": "m1"}}})
                emit({"type": "stream_event", "event": {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "Plan it"}}})
                emit({"type": "stream_event", "event": {"type": "content_block_start", "index": 1, "content_block": {"type": "text", "text": ""}}})
                emit({"type": "stream_event", "event": {"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": "Let me "}}})
                emit({"type": "stream_event", "event": {"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": "check."}}})
                # One complete message per block, as Claude Code sends them.
                emit({"type": "assistant", "uuid": "u0", "message": {"id": "m1", "content": [{"type": "thinking", "thinking": "Plan it"}]}})
                emit({"type": "assistant", "uuid": "u1", "message": {"id": "m1", "content": [{"type": "text", "text": "Let me check."}]}})
                emit({"type": "assistant", "uuid": "u1b", "message": {"id": "m1", "content": [{"type": "tool_use", "id": "tool-1", "name": "Bash", "input": {"command": "echo hi"}}]}})
                emit({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "tool-1", "content": [{"type": "text", "text": "hi"}], "is_error": False}]}})
                emit({"type": "assistant", "uuid": "u2", "message": {"id": "m2", "content": [{"type": "text", "text": "All set."}]}})
                emit({"type": "result", "subtype": "success", "is_error": False, "duration_ms": 1500})
        """#.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let session = CodingAgentSession(task: record(.claude), executableOverride: script)
        var task = record(.claude), report = CodingAgentReport()
        let finished = expectation(description: "turn completed")
        session.onEvent = { event, delta in CodingTranscript.apply(event, delta: delta, to: &task) }
        session.onReport = { report = $0 }
        session.onState = { if $0 == .review { finished.fulfill() } }
        try session.send("Fixture only")
        await fulfillment(of: [finished], timeout: 10); session.stop()
        XCTAssertEqual(report.commands, ["compact", "review", "my-command"]); XCTAssertEqual(report.model, "sonnet")
        let items = CodingTranscriptItem.build(task.events)
        guard case .reasoning(let thinking) = items[0] else { return XCTFail("thinking") }
        XCTAssertEqual(thinking.text, "Plan it", "The streamed and complete thinking are one item")
        guard case .assistant(let first) = items[1] else { return XCTFail("text") }
        XCTAssertEqual(first.text, "Let me check.", "The streamed and complete text are one item, apart from the thinking"); XCTAssertEqual(first.ref, "u1")
        guard case .tools(let cards) = items[2] else { return XCTFail("tools") }
        XCTAssertEqual(cards[0].title, "echo hi"); XCTAssertEqual(cards[0].output, "hi"); XCTAssertEqual(cards[0].status, "completed"); XCTAssertNotNil(cards[0].duration)
        guard case .assistant(let reply) = items[3] else { return XCTFail("reply") }
        XCTAssertEqual(reply.text, "All set."); XCTAssertEqual(reply.ref, "u2", "Claude messages carry their UUID for forking")
    }
    func testOutputPreviewKeepsHeadAndTail() {
        let text = (1...30).map { "line \($0)" }.joined(separator: "\n") + "\n\n"
        let preview = CodingOutputPreview(text, head: 3, tail: 2)
        XCTAssertEqual(preview.head, ["line 1", "line 2", "line 3"]); XCTAssertEqual(preview.tail, ["line 29", "line 30"]); XCTAssertEqual(preview.omitted, 25)
        XCTAssertEqual(CodingOutputPreview("a\nb", head: 3, tail: 2).omitted, 0)
        XCTAssertEqual(CodingChatEvents.displayCommand("/bin/zsh -lc 'echo '\\''hi'\\'''"), "echo 'hi'")
        XCTAssertEqual(CodingChatEvents.displayCommand("git status"), "git status")
        XCTAssertEqual(CodingTranscriptItem.summary([CodingToolCard(.init(kind: .command, text: "ls", tool: "Bash")), CodingToolCard(.init(kind: .command, text: "Read a", tool: "Read"))]), "Ran 1 command, used 1 tool")
    }

    // MARK: Mentions and slash commands

    func testMentionSearch() {
        let paths = ["README.md", "Sources/App/AppDelegate.swift", "Sources/App/Views/ContentView.swift", "Tests/AppTests.swift", "docs/app-notes.md"]
        XCTAssertEqual(CodingMentionSearch.rank("appdel", in: paths).first, "Sources/App/AppDelegate.swift")
        XCTAssertEqual(CodingMentionSearch.rank("cv", in: paths).first, "Sources/App/Views/ContentView.swift", "Word starts count")
        XCTAssertEqual(CodingMentionSearch.rank("readme", in: paths), ["README.md"])
        XCTAssertTrue(CodingMentionSearch.rank("zzz", in: paths).isEmpty)
        XCTAssertEqual(CodingMentionSearch.activeQuery("fix @src/ap"), "src/ap")
        XCTAssertEqual(CodingMentionSearch.activeQuery("mail me@example"), nil, "An @ inside a word isn't a mention")
        XCTAssertNil(CodingMentionSearch.activeQuery("@done then more"))
        XCTAssertEqual(CodingMentionSearch.complete("fix @ap", with: "Sources/App/AppDelegate.swift"), "fix @Sources/App/AppDelegate.swift ")
    }
    func testSlashCommands() {
        XCTAssertEqual(CodingSlashCommand.parse("/new")?.action, .newTask)
        XCTAssertEqual(CodingSlashCommand.parse("/model gpt-5-codex")?.action, .model("gpt-5-codex"))
        XCTAssertEqual(CodingSlashCommand.parse("/model")?.action, .model(""))
        XCTAssertEqual(CodingSlashCommand.parse("/effort HIGH")?.action, .effort("high"))
        XCTAssertEqual(CodingSlashCommand.parse(" /compact ")?.action, .compact)
        XCTAssertEqual(CodingSlashCommand.parse("/review")?.action, .review)
        XCTAssertEqual(CodingSlashCommand.parse("/clear")?.action, .clear)
        XCTAssertEqual(CodingSlashCommand.parse("/my-command some args", agentCommands: ["my-command"])?.action, .agent("/my-command some args"))
        XCTAssertNil(CodingSlashCommand.parse("/usr/bin/env is missing"), "A path is a message, not a command")
        XCTAssertNil(CodingSlashCommand.parse("/"))
        XCTAssertEqual(CodingSlashCommand.suggestions("/c", agentCommands: ["cost", "compact"]).map(\.name), ["compact", "clear", "cost"])
        XCTAssertTrue(CodingSlashCommand.suggestions("/compact now", agentCommands: []).isEmpty)
    }

    // MARK: Session arguments

    func testResumeForkAndAccessArguments() {
        func value(_ args: [String], _ flag: String) -> String? { args.firstIndex(of: flag).map { args[$0 + 1] } }
        var task = record(.claude)
        task.access = .autoEdit; task.effort = "high"
        var args = CodingAgentSession.claudeArguments(for: task, resume: "session-1")
        XCTAssertEqual(value(args, "--permission-mode"), "acceptEdits"); XCTAssertEqual(value(args, "--effort"), "high")
        XCTAssertEqual(value(args, "--resume"), "session-1"); XCTAssertFalse(args.contains("--fork-session"))
        task.fork = .init(sessionID: "source", ref: "message-uuid")
        args = CodingAgentSession.claudeArguments(for: task, resume: nil)
        XCTAssertEqual(value(args, "--resume"), "source"); XCTAssertTrue(args.contains("--fork-session")); XCTAssertEqual(value(args, "--resume-session-at"), "message-uuid")
        args = CodingAgentSession.claudeArguments(for: task, resume: "own-session")
        XCTAssertEqual(value(args, "--resume"), "own-session", "Once the fork has its own session it resumes that"); XCTAssertFalse(args.contains("--fork-session"))

        var codex = record(.codex); codex.model = "gpt-5-codex"
        var start = CodingAgentSession.codexThreadRequest(for: codex, sessionID: nil)
        XCTAssertEqual(start.method, "thread/start"); XCTAssertEqual(start.params["approvalPolicy"] as? String, "untrusted"); XCTAssertEqual(start.params["sandbox"] as? String, "workspace-write")
        XCTAssertEqual(start.params["model"] as? String, "gpt-5-codex")
        start = CodingAgentSession.codexThreadRequest(for: codex, sessionID: "thread-1")
        XCTAssertEqual(start.method, "thread/resume"); XCTAssertEqual(start.params["threadId"] as? String, "thread-1")
        codex.fork = .init(sessionID: "source-thread", ref: "turn-3")
        start = CodingAgentSession.codexThreadRequest(for: codex, sessionID: nil)
        XCTAssertEqual(start.method, "thread/fork"); XCTAssertEqual(start.params["threadId"] as? String, "source-thread"); XCTAssertEqual(start.params["lastTurnId"] as? String, "turn-3")
        XCTAssertEqual(start.params["cwd"] as? String, codex.directory)
        XCTAssertTrue(CodingAgentSession.codexPolicy(.readOnly) == ("read-only", "on-request"))
        XCTAssertTrue(CodingAgentSession.codexPolicy(.autoEdit) == ("workspace-write", "on-request"))
        XCTAssertTrue(CodingAgentSession.codexPolicy(.full) == ("danger-full-access", "never"))
    }
    func testImagesGoToEachAgentInItsOwnForm() throws {
        let image = folder.appendingPathComponent("shot.png"); try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
        let input = CodingTurnInput(text: "What's wrong here?", images: [image])
        let codex = CodingAgentSession.codexInput(input)
        XCTAssertEqual(codex.count, 2); XCTAssertEqual(codex[1]["type"] as? String, "localImage"); XCTAssertEqual(codex[1]["path"] as? String, image.path)
        let claude = CodingAgentSession.claudeMessage(input, sessionID: "s1")
        let blocks = try XCTUnwrap((claude["message"] as? [String: Any])?["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.first?["type"] as? String, "image"); XCTAssertEqual(blocks.last?["text"] as? String, "What's wrong here?")
        XCTAssertEqual((blocks.first?["source"] as? [String: Any])?["media_type"] as? String, "image/png")
        XCTAssertEqual((blocks.first?["source"] as? [String: Any])?["data"] as? String, Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString())
        XCTAssertEqual((CodingAgentSession.claudeMessage(.init(text: "plain"), sessionID: nil)["message"] as? [String: Any])?["content"] as? String, "plain")
    }
    func testCatalogReadsWhatEachAgentReports() {
        let codex = CodingAgentCatalog.codexModels(["data": [
            ["id": "a", "model": "gpt-5-codex", "displayName": "GPT-5 Codex", "description": "Coding", "hidden": false, "isDefault": true, "defaultReasoningEffort": "medium",
             "supportedReasoningEfforts": [["reasoningEffort": "low", "description": ""], ["reasoningEffort": "high", "description": ""]]],
            ["id": "b", "model": "secret", "displayName": "Hidden", "description": "", "hidden": true, "isDefault": false, "defaultReasoningEffort": "low", "supportedReasoningEfforts": []],
        ]])
        XCTAssertEqual(codex.map(\.id), ["gpt-5-codex"]); XCTAssertEqual(codex[0].efforts, ["low", "high"]); XCTAssertTrue(codex[0].isDefault)
        let response: [String: Any] = ["models": [["value": "default", "displayName": "Default", "description": "Recommended"], ["value": "opus", "displayName": "Opus", "description": "", "supportedEffortLevels": ["low", "max"]]],
                                       "commands": [["name": "compact", "description": ""], "/review", ["name": "custom"]]]
        XCTAssertEqual(CodingAgentCatalog.claudeModels(response).map(\.id), ["default", "opus"])
        XCTAssertEqual(CodingAgentCatalog.claudeModels(response)[1].efforts, ["low", "max"])
        XCTAssertEqual(CodingAgentCatalog.claudeCommands(response), ["compact", "review", "custom"])
    }

    // MARK: Store

    func testQueuedMessagesSendWhenTheTurnEnds() async throws {
        let fake = ChatFakeSession()
        let store = CodingWorkspaceStore(storage: .init(directory: folder, ownerID: "local-test"), sessionFactory: { _ in fake })
        let project = DesktopProject(name: "Fixture", bookmark: Data())
        let id = try unwrap(await store.create(project: project, root: folder, provider: .codex, model: "", access: .edit, isolated: false, prompt: "First"))
        XCTAssertEqual(fake.sent, ["First"]); XCTAssertEqual(store.task(id)?.status, .working)
        store.enqueue(id, .init(text: "Second")); store.enqueue(id, .init(text: "Third"))
        XCTAssertEqual(store.task(id)?.queued?.map(\.text), ["Second", "Third"])
        XCTAssertFalse(store.steer(id, .init(text: "Steer")), "This agent can't steer")
        fake.onState?(.review)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(fake.sent, ["First", "Second"]); XCTAssertEqual(store.task(id)?.queued?.map(\.text), ["Third"])
        // Interrupt and send: the message goes first, after the turn is interrupted.
        store.interruptAndSend(id, .init(text: "Now"))
        XCTAssertEqual(fake.interrupts, 1)
        fake.onState?(.interrupted)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(fake.sent.last, "Now"); XCTAssertEqual(store.task(id)?.queued?.map(\.text), ["Third"])
        // A failed turn keeps the queue for you to decide.
        fake.onState?(.failed)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(fake.sent.count, 3)
        let saved = CodingWorkspaceStore(storage: .init(directory: folder, ownerID: "local-test"))
        XCTAssertEqual(saved.task(id)?.queued?.map(\.text), ["Third"], "The queue survives a relaunch")
    }
    func testPinsUnreadRenameAndSettings() async throws {
        let fake = ChatFakeSession()
        let store = CodingWorkspaceStore(storage: .init(directory: folder, ownerID: "local-test"), sessionFactory: { _ in fake })
        let project = DesktopProject(name: "Fixture", bookmark: Data())
        let first = try unwrap(await store.create(project: project, root: folder, provider: .codex, model: "", access: .edit, isolated: false, prompt: "One"))
        fake.onState?(.review)
        let other = folder.appendingPathComponent("other"); try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let second = try unwrap(await store.create(project: project, root: other, provider: .claude, model: "", access: .edit, isolated: false, prompt: "Two"))
        XCTAssertEqual(store.sidebarOrder(project: project.id).map(\.id), [second, first])
        store.setPinned(first, true)
        XCTAssertEqual(store.sidebarOrder(project: project.id).map(\.id), [first, second], "Pinned first")
        store.select(first)
        store.noteActivity(second)
        XCTAssertEqual(store.task(second)?.unread, true)
        store.select(second); XCTAssertNil(store.task(second)?.unread)
        store.rename(first, "  Better name  "); XCTAssertEqual(store.task(first)?.title, "Better name")
        XCTAssertTrue(CodingWorkspaceStore.matches(store.task(first)!, "better")); XCTAssertFalse(CodingWorkspaceStore.matches(store.task(first)!, "zzz"))
        // A new model ends the idle session, so the next message resumes with it.
        let stopsBefore = fake.stops
        store.setModel(first, model: "gpt-5-codex", effort: "high")
        XCTAssertEqual(store.task(first)?.model, "gpt-5-codex"); XCTAssertEqual(store.task(first)?.effort, "high"); XCTAssertEqual(fake.stops, stopsBefore + 1)
        store.setAccess(first, .full); XCTAssertEqual(store.task(first)?.access, .full)
        let reloaded = CodingWorkspaceStore(storage: .init(directory: folder, ownerID: "local-test"))
        XCTAssertEqual(reloaded.task(first)?.pinned, true); XCTAssertEqual(reloaded.task(first)?.effort, "high")
    }
    func testForkCopiesTheConversationPointAndTheFiles() async throws {
        let repo = folder.appendingPathComponent("repo"); try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        for args in [["init", "-b", "main"], ["config", "user.email", "t@example.com"], ["config", "user.name", "T"]] { _ = try await CodingCommand.git(args, at: repo) }
        try "one\n".write(to: repo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        _ = try await CodingCommand.git(["add", "."], at: repo); _ = try await CodingCommand.git(["commit", "-m", "init"], at: repo)
        let fake = ChatFakeSession()
        let store = CodingWorkspaceStore(storage: .init(directory: folder.appendingPathComponent("Coding"), ownerID: "local-test"), sessionFactory: { _ in fake })
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Coding"), withIntermediateDirectories: true)
        let project = DesktopProject(name: "Repo", bookmark: Data())
        let source = try unwrap(await store.create(project: project, root: repo, provider: .claude, model: "sonnet", access: .autoEdit, isolated: true, prompt: "Change it"))
        fake.onSession?("claude-session")
        var reply = CodingEvent(id: "reply-1", kind: .assistant, text: "Changed."); reply.ref = "uuid-1"
        fake.onEvent?(reply, false)
        fake.onState?(.review)
        let work = URL(fileURLWithPath: try XCTUnwrap(store.task(source)?.directory))
        try "two\n".write(to: work.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        let forked = try unwrap(await store.fork(source, at: "reply-1"), store.notice)
        let fork = try XCTUnwrap(store.task(forked))
        XCTAssertEqual(fork.fork, CodingForkPoint(sessionID: "claude-session", ref: "uuid-1"))
        XCTAssertEqual(fork.provider, .claude); XCTAssertEqual(fork.model, "sonnet"); XCTAssertEqual(fork.access, .autoEdit)
        XCTAssertEqual(fork.baseCommit, store.task(source)?.baseCommit, "Its changes are reviewed against the same base")
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: fork.directory).appendingPathComponent("file.txt"), encoding: .utf8), "two\n", "The fork starts with the source's files")
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("file.txt"), encoding: .utf8), "one\n", "The project is untouched")
        XCTAssertEqual(store.selected, forked)
        // Its own session replaces the fork point.
        fake.sent = []
        store.send(forked, "Continue")
        fake.onSession?("new-session")
        XCTAssertNil(store.task(forked)?.fork); XCTAssertEqual(store.task(forked)?.sessionID, "new-session")
    }
    func testCommitMessageAndCommitOnTheBranch() async throws {
        let files = CodingDiff.parse("diff --git a/a.swift b/a.swift\nnew file mode 100644\n@@ -0,0 +1,2 @@\n+x\n+y\ndiff --git a/b.swift b/b.swift\n@@ -1 +1 @@\n-a\n+b\n")
        XCTAssertEqual(CodingCommitMessage.generate(title: "fix the login flow.", files: files), "Fix the login flow\n\n- Add a.swift (+2 −0)\n- Update b.swift (+1 −1)")
        let repo = folder.appendingPathComponent("repo"); try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        for args in [["init", "-b", "main"], ["config", "user.email", "t@example.com"], ["config", "user.name", "T"]] { _ = try await CodingCommand.git(args, at: repo) }
        try "one\n".write(to: repo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        _ = try await CodingCommand.git(["add", "."], at: repo); _ = try await CodingCommand.git(["commit", "-m", "init"], at: repo)
        let fake = ChatFakeSession()
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Coding"), withIntermediateDirectories: true)
        let store = CodingWorkspaceStore(storage: .init(directory: folder.appendingPathComponent("Coding"), ownerID: "local-test"), sessionFactory: { _ in fake })
        let id = try unwrap(await store.create(project: DesktopProject(name: "Repo", bookmark: Data()), root: repo, provider: .codex, model: "", access: .edit, isolated: true, prompt: "Work"))
        fake.onState?(.review)
        let work = URL(fileURLWithPath: try XCTUnwrap(store.task(id)?.directory))
        try "two\n".write(to: work.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        let review = try await store.review(id)
        let sha = try await store.commit(id, review: review, message: "Change file")
        let subject = try await CodingCommand.git(["log", "-1", "--format=%s"], at: work)
        let head = try await CodingCommand.git(["rev-parse", "HEAD"], at: work)
        let status = try await CodingCommand.git(["status", "--porcelain"], at: work)
        let main = try await CodingCommand.git(["rev-parse", "main"], at: repo), parent = try await CodingCommand.git(["rev-parse", "HEAD~1"], at: work)
        XCTAssertEqual(subject, "Change file"); XCTAssertEqual(head, sha)
        XCTAssertEqual(status, "", "The worktree's index follows the commit")
        XCTAssertEqual(main, parent, "Nothing is merged")
        do { _ = try await store.commit(id, review: review, message: "Again"); XCTFail("A stale review is refused") } catch {}
    }
}

@MainActor private final class ChatFakeSession: AgentSession {
    var onEvent: ((CodingEvent, Bool) -> Void)?
    var onState: ((CodingTaskStatus) -> Void)?
    var onSession: ((String) -> Void)?
    var onApproval: ((CodingApproval?) -> Void)?
    var sent: [String] = []
    var stops = 0
    var interrupts = 0
    func send(_ text: String) throws { sent.append(text); onState?(.working) }
    func respond(_ id: String, allow: Bool, answers: String) throws {}
    func interrupt() { interrupts += 1 }
    func stop() { stops += 1 }
}

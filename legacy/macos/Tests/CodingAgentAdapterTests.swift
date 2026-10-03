import XCTest
import SwiftUI
@testable import KemoSabeMac

/// The universal agent layer (September 27): the ACP client, the Muse Code (MSP) adapter, Cursor
/// Agent through ACP, access gates, grants, Run with…, and the adapter registry. Fixtures and
/// mock executables only; the real `muse` runs only in the gated test below (echo provider,
/// isolated folders, no sign-in).
@MainActor final class CodingAgentAdapterTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("CodingAgentAdapterTests-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let folder { try? FileManager.default.removeItem(at: folder) } }
    private func record(_ provider: CodingProvider, access: CodingAccess = .edit, model: String = "", effort: String? = nil, session: String? = nil) -> CodingTaskRecord {
        var task = CodingTaskRecord(projectID: UUID(), ownerID: "local-test", title: "Test task", provider: provider, model: model, access: access, projectPath: folder.path, directory: folder.path, isolated: false)
        task.effort = effort; task.sessionID = session
        return task
    }
    private func script(_ name: String, _ source: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try source.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
    private func log(_ name: String) throws -> [String] {
        try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8).split(separator: "\n").map(String.init)
    }
    /// Collects a session's events the way the store does, into a task record.
    private final class Recorder {
        var task: CodingTaskRecord
        var states: [CodingTaskStatus] = []
        var approvals: [CodingApproval] = []
        var reports: [CodingAgentReport] = []
        var sessions: [String] = []
        init(_ task: CodingTaskRecord) { self.task = task }
        func events(_ kind: CodingEvent.Kind) -> [CodingEvent] { task.events.filter { $0.kind == kind } }
    }
    private func attach(_ session: any AgentSession, _ recorder: Recorder, done: XCTestExpectation? = nil, doneOn: Set<CodingTaskStatus> = [.review],
                        answer: ((CodingApproval) -> Void)? = nil) {
        session.onEvent = { event, delta in CodingTranscript.apply(event, delta: delta, to: &recorder.task) }
        session.onState = { state in recorder.states.append(state); if doneOn.contains(state) { done?.fulfill() } }
        session.onApproval = { approval in guard let approval else { return }; recorder.approvals.append(approval); answer?(approval) }
        session.onReport = { recorder.reports.append($0) }
        session.onSession = { recorder.sessions.append($0) }
    }

    // MARK: ACP fixture

    /// An ACP agent following the v1 schema: `initialize`, `session/new|load|resume`, modes and
    /// config options, `session/prompt` with streamed updates, permission requests, client file
    /// and terminal calls, and `session/cancel`. Its first argument picks a profile.
    private func acpAgent() throws -> URL {
        try script("fixture-acp", #"""
        #!/usr/bin/python3
        import json, sys, os
        profile = sys.argv[1] if len(sys.argv) > 1 else "plain"
        log = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "acp-log"), "a")
        def L(s): log.write(s + "\n"); log.flush()
        def emit(x): sys.stdout.write(json.dumps(x) + "\n"); sys.stdout.flush()
        def read():
            line = sys.stdin.readline()
            if not line: sys.exit(0)
            return json.loads(line)
        def upd(sid, u): emit({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": u}})
        nid = [1000]
        def ask(method, params):
            nid[0] += 1; rid = nid[0]
            emit({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
            while True:
                x = read()
                if x.get("id") == rid and "method" not in x: return x
                if x.get("method") == "session/cancel": L("cancel")
                else: L("unexpected " + json.dumps(x))
        def outcome(r):
            o = r["result"]["outcome"]
            return o["outcome"] + (" " + o["optionId"] if "optionId" in o else "")
        if profile == "cursor":
            modes = [{"id": "agent", "name": "Agent"}, {"id": "plan", "name": "Plan"}, {"id": "ask", "name": "Ask"}]
            opts = [{"optionId": "allow-once", "name": "Allow", "kind": "allow_once"}, {"optionId": "allow-always", "name": "Always allow", "kind": "allow_always"}, {"optionId": "reject-once", "name": "Reject", "kind": "reject_once"}]
            current = "agent"
        else:
            modes = [{"id": "default", "name": "Default"}, {"id": "acceptEdits", "name": "Accept edits"}, {"id": "plan", "name": "Plan"}, {"id": "bypassPermissions", "name": "Bypass"}]
            opts = [{"optionId": "once", "name": "Allow once", "kind": "allow_once"}, {"optionId": "always", "name": "Always", "kind": "allow_always"}, {"optionId": "no", "name": "Reject", "kind": "reject_once"}]
            current = "default"
        config = [
            {"id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": "m1", "options": [{"value": "m1", "name": "Model One"}, {"value": "m2", "name": "Model Two"}]},
            {"id": "effort", "name": "Thinking", "category": "thought_level", "type": "select", "currentValue": "medium", "options": [{"value": "low", "name": "Low"}, {"value": "medium", "name": "Medium"}, {"value": "high", "name": "High"}]}]
        cwd = os.getcwd()
        def prompt(x):
            p = x["params"]; sid = p["sessionId"]; text = p["prompt"][0]["text"]
            L("prompt " + text.replace("\n", " | ")); L("blocks %d" % len(p["prompt"]))
            if "SCENARIO:full" in text:
                upd(sid, {"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": "Let me look."}})
                upd(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Hello "}})
                upd(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "world"}})
                upd(sid, {"sessionUpdate": "plan", "entries": [{"content": "Read", "priority": "high", "status": "completed"}, {"content": "Fix", "priority": "medium", "status": "in_progress"}]})
                upd(sid, {"sessionUpdate": "available_commands_update", "availableCommands": [{"name": "init", "description": "Init"}]})
                tool = {"toolCallId": "t1", "title": "Run tests", "kind": "execute", "status": "pending", "rawInput": {"command": "swift", "args": ["test"]}}
                upd(sid, dict(tool, sessionUpdate="tool_call"))
                L("perm1 " + outcome(ask("session/request_permission", {"sessionId": sid, "toolCall": tool, "options": opts})))
                upd(sid, {"sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "completed", "content": [{"type": "content", "content": {"type": "text", "text": "All tests passed"}}]})
                edit = {"toolCallId": "e1", "title": "Edit a.txt", "kind": "edit", "locations": [{"path": cwd + "/a.txt"}], "content": [{"type": "diff", "path": cwd + "/a.txt", "oldText": "line2\n", "newText": "LINE2\n"}]}
                L("perm2 " + outcome(ask("session/request_permission", {"sessionId": sid, "toolCall": edit, "options": opts})))
                r = ask("fs/read_text_file", {"sessionId": sid, "path": cwd + "/a.txt", "line": 2, "limit": 1}); L("read " + json.dumps(r.get("result")))
                r = ask("fs/write_text_file", {"sessionId": sid, "path": cwd + "/b.txt", "content": "written\n"}); L("write " + ("ok" if "result" in r else "error"))
                r = ask("terminal/create", {"sessionId": sid, "command": "/bin/echo", "args": ["hi there"], "outputByteLimit": 1000})
                if "result" in r:
                    tid = r["result"]["terminalId"]
                    upd(sid, {"sessionUpdate": "tool_call", "toolCallId": "t2", "title": "echo", "kind": "execute", "status": "in_progress", "content": [{"type": "terminal", "terminalId": tid}]})
                    w = ask("terminal/wait_for_exit", {"sessionId": sid, "terminalId": tid}); L("exit %s" % w["result"].get("exitCode"))
                    o = ask("terminal/output", {"sessionId": sid, "terminalId": tid}); L("output " + o["result"]["output"].strip())
                    ask("terminal/release", {"sessionId": sid, "terminalId": tid})
                else: L("terminal error")
                emit({"jsonrpc": "2.0", "id": x["id"], "result": {"stopReason": "end_turn"}})
            elif "SCENARIO:cancel" in text:
                upd(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "working"}})
                L("perm " + outcome(ask("session/request_permission", {"sessionId": sid, "toolCall": {"toolCallId": "s1", "title": "sleep", "kind": "execute", "rawInput": {"command": "sleep 100"}}, "options": opts})))
                emit({"jsonrpc": "2.0", "id": x["id"], "result": {"stopReason": "cancelled"}})
            elif "SCENARIO:readonly" in text:
                r = ask("fs/write_text_file", {"sessionId": sid, "path": cwd + "/c.txt", "content": "x"}); L("write " + ("ok" if "result" in r else "error"))
                r = ask("terminal/create", {"sessionId": sid, "command": "/bin/echo", "args": ["x"]}); L("terminal " + ("ok" if "result" in r else "error"))
                L("editperm " + outcome(ask("session/request_permission", {"sessionId": sid, "toolCall": {"toolCallId": "e9", "title": "Edit", "kind": "edit", "locations": [{"path": cwd + "/a.txt"}]}, "options": opts})))
                L("readperm " + outcome(ask("session/request_permission", {"sessionId": sid, "toolCall": {"toolCallId": "r9", "title": "Read", "kind": "read", "locations": [{"path": cwd + "/a.txt"}]}, "options": opts})))
                emit({"jsonrpc": "2.0", "id": x["id"], "result": {"stopReason": "end_turn"}})
            else:
                upd(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "new reply"}})
                emit({"jsonrpc": "2.0", "id": x["id"], "result": {"stopReason": "end_turn"}})
        while True:
            x = read(); m = x.get("method"); p = x.get("params", {})
            if m == "initialize":
                L("initialize %s %s" % (p.get("protocolVersion"), json.dumps(p.get("clientCapabilities"), sort_keys=True)))
                caps = {"loadSession": profile != "resume", "promptCapabilities": {"image": True}}
                if profile == "resume": caps["sessionCapabilities"] = {"resume": {}}
                emit({"jsonrpc": "2.0", "id": x["id"], "result": {"protocolVersion": 1, "agentCapabilities": caps, "agentInfo": {"name": "fixture-acp", "version": "0.1"}, "authMethods": [{"id": "login", "name": "Log in"}]}})
            elif m == "session/new":
                L("new " + p["cwd"] + " mcp=%d" % len(p["mcpServers"]))
                emit({"jsonrpc": "2.0", "id": x["id"], "result": {"sessionId": "s-1", "modes": {"currentModeId": current, "availableModes": modes}, "configOptions": config}})
            elif m == "session/load":
                L("load " + p["sessionId"])
                upd(p["sessionId"], {"sessionUpdate": "user_message_chunk", "content": {"type": "text", "text": "old question"}})
                upd(p["sessionId"], {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "old reply"}})
                emit({"jsonrpc": "2.0", "id": x["id"], "result": {"modes": {"currentModeId": current, "availableModes": modes}}})
            elif m == "session/resume":
                L("resume " + p["sessionId"])
                emit({"jsonrpc": "2.0", "id": x["id"], "result": {}})
            elif m == "session/set_mode": L("mode " + p["modeId"]); emit({"jsonrpc": "2.0", "id": x["id"], "result": {}})
            elif m == "session/set_config_option": L("config %s=%s" % (p["configId"], p["value"])); emit({"jsonrpc": "2.0", "id": x["id"], "result": {}})
            elif m == "session/prompt": prompt(x)
            elif m == "session/cancel": L("cancel")
            else: L("unexpected " + json.dumps(x))
        """#)
    }
    private func acp(_ task: CodingTaskRecord, profile: String = "plain") throws -> CodingACPSession {
        CodingACPSession(task: task, launch: .init(command: try acpAgent().path, arguments: [profile], environment: .inherit, name: "Fixture agent"), interruptGrace: 1, terminationGrace: 1)
    }

    func testACPHandshakeStreamingPermissionsFilesAndTerminal() async throws {
        try "line1\nline2\nline3\n".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let recorder = Recorder(record(.custom(UUID()), access: .edit, model: "m2", effort: "high"))
        let session = try acp(recorder.task)
        let done = expectation(description: "turn done")
        attach(session, recorder, done: done) { approval in
            switch approval.kind {
            case .command where approval.command == "swift test": try? session.respond(approval.id, decision: .allowSession, answers: "")
            case .files where approval.title == "a.txt": try? session.respond(approval.id, decision: .deny(note: "Keep the old line"), answers: "")
            case .files where approval.title == "b.txt": try? session.respond(approval.id, decision: .allowOnce, answers: "")
            case .command where approval.command == "/bin/echo 'hi there'": try? session.respond(approval.id, decision: .allowOnce, answers: "")
            default: XCTFail("Unexpected approval \(approval.title)")
            }
        }
        try session.send("SCENARIO:full")
        await fulfillment(of: [done], timeout: 20)
        let lines = try log("acp-log")
        XCTAssertTrue(lines[0].hasPrefix("initialize 1 "), "Speaks ACP version 1")
        XCTAssertTrue(lines[0].contains("\"readTextFile\": true") && lines[0].contains("\"terminal\": true"), "Offers the fs and terminal capabilities")
        XCTAssertTrue(lines.contains("new \(folder.path) mcp=0"), "No MCP servers are handed to the agent")
        XCTAssertFalse(lines.contains { $0.hasPrefix("mode ") }, "Ask first is the agent's default mode, which it's already in")
        XCTAssertTrue(lines.contains("config model=m2") && lines.contains("config effort=high"), "Model and effort go through config options")
        XCTAssertTrue(lines.contains("perm1 selected always"), "Allow for this session selects allow_always")
        XCTAssertTrue(lines.contains("perm2 selected no"), "Deny selects reject_once")
        XCTAssertTrue(lines.contains("read {\"content\": \"line2\"}"), "Reads inside the folder are served, sliced by line and limit")
        XCTAssertTrue(lines.contains("write ok"))
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("b.txt"), encoding: .utf8), "written\n")
        XCTAssertTrue(lines.contains("exit 0") && lines.contains("output hi there"), "The terminal ran and reported its output")
        XCTAssertEqual(recorder.approvals.count, 4, "Two tool permissions, one write, one command asked; the read inside the folder didn't")
        XCTAssertEqual(recorder.events(.assistant).first?.text, "Hello world")
        XCTAssertEqual(recorder.events(.reasoning).first?.text, "Let me look.")
        XCTAssertEqual(recorder.events(.plan).first?.detail, "completed · Read\ninProgress · Fix")
        let tool = try XCTUnwrap(recorder.task.events.first { $0.id == "t1" })
        XCTAssertEqual(tool.text, "swift test"); XCTAssertEqual(tool.status, "completed"); XCTAssertEqual(tool.output, "All tests passed")
        let edit = try XCTUnwrap(recorder.task.events.first { $0.id == "e1" })
        XCTAssertEqual(edit.kind, .file); XCTAssertEqual(edit.text, "a.txt"); XCTAssertTrue(edit.detail.contains("-line2\n+LINE2"))
        XCTAssertTrue(recorder.task.events.first { $0.id == "t2" }?.detail.contains("hi there") == true, "Terminal output streams into its card")
        XCTAssertTrue(recorder.reports.contains { $0.models?.map(\.id) == ["m1", "m2"] && $0.models?.first?.efforts == ["low", "medium", "high"] }, "Models and efforts come from the agent")
        XCTAssertTrue(recorder.reports.contains { $0.commands == ["init"] })
        XCTAssertEqual(recorder.sessions, ["s-1"])
        // The denial's note goes with the next message.
        let second = expectation(description: "second turn")
        session.onState = { if $0 == .review { second.fulfill() } }
        try session.send("next")
        await fulfillment(of: [second], timeout: 10); session.stop()
        XCTAssertTrue(try log("acp-log").contains { $0.hasPrefix("prompt ") && $0.contains("I denied it: Keep the old line") && $0.hasSuffix("next") })
    }

    func testACPCancelAnswersOpenPermissionsCancelled() async throws {
        let recorder = Recorder(record(.custom(UUID())))
        let session = try acp(recorder.task)
        let done = expectation(description: "interrupted")
        attach(session, recorder, done: done, doneOn: [.interrupted]) { _ in session.interrupt() }
        try session.send("SCENARIO:cancel")
        await fulfillment(of: [done], timeout: 15); session.stop()
        let lines = try log("acp-log")
        XCTAssertTrue(lines.contains("cancel"), "session/cancel was sent")
        XCTAssertTrue(lines.contains("perm cancelled"), "The open permission request was answered cancelled")
        XCTAssertEqual(recorder.states.last, .interrupted)
    }

    func testACPLoadSkipsTheReplayAndResumeIsPreferred() async throws {
        let loaded = Recorder(record(.custom(UUID()), session: "s-old"))
        let session = try acp(loaded.task, profile: "plain")
        let done = expectation(description: "loaded turn")
        attach(session, loaded, done: done)
        try session.send("again")
        await fulfillment(of: [done], timeout: 10); session.stop()
        XCTAssertTrue(try log("acp-log").contains("load s-old"))
        XCTAssertEqual(loaded.events(.assistant).map(\.text), ["new reply"], "The replayed history isn't added again")

        try FileManager.default.removeItem(at: folder.appendingPathComponent("acp-log"))
        let resumed = Recorder(record(.custom(UUID()), session: "s-old"))
        let second = try acp(resumed.task, profile: "resume")
        let finished = expectation(description: "resumed turn")
        attach(second, resumed, done: finished)
        try second.send("again")
        await fulfillment(of: [finished], timeout: 10); second.stop()
        let lines = try log("acp-log")
        XCTAssertTrue(lines.contains("resume s-old") && !lines.contains { $0.hasPrefix("load ") }, "session/resume when the agent offers it")
    }

    func testACPReadOnlyRefusesWritesAndCommandsWithoutAsking() async throws {
        try "x\n".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let recorder = Recorder(record(.custom(UUID()), access: .readOnly))
        let session = try acp(recorder.task)
        let done = expectation(description: "done")
        attach(session, recorder, done: done) { XCTFail("Read only never asks: \($0.title)") }
        try session.send("SCENARIO:readonly")
        await fulfillment(of: [done], timeout: 10); session.stop()
        let lines = try log("acp-log")
        XCTAssertTrue(lines.contains("mode plan"), "Read only maps to plan mode")
        XCTAssertTrue(lines.contains("write error") && lines.contains("terminal error"))
        XCTAssertTrue(lines.contains("editperm selected no") && lines.contains("readperm selected once"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("c.txt").path))
    }

    /// Cursor Agent speaks ACP (`cursor-agent acp`, found in its installed bundle) with modes
    /// agent/plan/ask and allow-once/allow-always/reject-once options; this fixture has that shape.
    func testCursorAgentThroughACP() async throws {
        let adapter = CursorAgentAdapter()
        XCTAssertEqual(adapter.launch.command, "cursor-agent"); XCTAssertEqual(adapter.launch.arguments, ["acp"])
        XCTAssertEqual(adapter.transport, .acp); XCTAssertEqual(adapter.signInCommand, "cursor-agent login")
        XCTAssertNil(adapter.removalPhrase(record(.cursor)), "Cursor's ACP server can't delete sessions; Delete says so")
        let recorder = Recorder(record(.cursor, access: .readOnly))
        let session = CodingACPSession(task: recorder.task, launch: .init(command: try acpAgent().path, arguments: ["cursor"], environment: .inherit, name: "Cursor Agent"), interruptGrace: 1, terminationGrace: 1)
        let done = expectation(description: "done")
        attach(session, recorder, done: done)
        try session.send("hello")
        await fulfillment(of: [done], timeout: 10); session.stop()
        XCTAssertTrue(try log("acp-log").contains("mode plan"), "Read only is Cursor's plan mode")
        XCTAssertEqual(CodingACP.modeID(for: .edit, available: ["agent", "plan", "ask"]), "agent")
        XCTAssertEqual(CodingACP.modeID(for: .full, available: ["agent", "plan", "ask"]), "agent")
        XCTAssertEqual(CodingACP.option(for: .allowSession, in: [["optionId": "allow-once", "kind": "allow_once"], ["optionId": "allow-always", "kind": "allow_always"]]), "allow-always")
        XCTAssertEqual(recorder.events(.assistant).map(\.text), ["new reply"])
    }

    func testACPConnectionTestRunsInitializeOnly() async throws {
        let launch = CodingACPLaunch(command: try acpAgent().path, arguments: ["plain"], environment: .allowList([]), name: "Fixture")
        let result = try await CodingACPConnectionTest(launch: launch).run().get()
        XCTAssertEqual(result.agent, "fixture-acp"); XCTAssertEqual(result.protocolVersion, 1); XCTAssertTrue(result.loadSession)
        XCTAssertEqual(result.authMethods, ["Log in"])
        XCTAssertFalse(try log("acp-log").contains { $0.hasPrefix("new ") || $0.hasPrefix("prompt") }, "No session and no prompt")
        let missing = await CodingACPConnectionTest(launch: .init(command: "no-such-agent-\(UUID().uuidString)", arguments: [], environment: .inherit, name: "Nope")).run()
        if case .success = missing { XCTFail("A missing command fails") }
    }

    func testACPMappingAndGates() throws {
        let dir = folder.path
        let execute = CodingACP.toolEvent(["toolCallId": "1", "title": "Run", "kind": "execute", "status": "in_progress", "rawInput": ["command": ["git", "commit", "-m", "a b"]]], directory: dir)
        XCTAssertEqual(execute.text, "git commit -m 'a b'"); XCTAssertEqual(execute.status, "running"); XCTAssertEqual(execute.tool, "commandExecution")
        let created = CodingACP.toolEvent(["toolCallId": "2", "title": "Write", "kind": "edit", "content": [["type": "diff", "path": dir + "/new.swift", "newText": "let a = 1\n"]]], directory: dir)
        XCTAssertEqual(created.text, "new.swift"); XCTAssertTrue(created.detail.contains("new file mode") && created.detail.contains("+let a = 1"))
        let read = CodingACP.toolEvent(["toolCallId": "3", "title": "Read file", "kind": "read"], directory: dir)
        XCTAssertEqual(read.tool, "Read")
        let update = CodingACP.toolEvent(["toolCallId": "1", "status": "failed"], directory: dir)
        XCTAssertEqual(update.merged(into: execute).kind, .command); XCTAssertEqual(update.merged(into: execute).text, execute.text)
        XCTAssertEqual(CodingACP.slice("a\nb\nc", line: 2, limit: 5), "b\nc")
        let (tail, cut) = CodingACP.truncate(Data("ééé".utf8), limit: 3)
        XCTAssertTrue(cut); XCTAssertEqual(String(decoding: tail, as: UTF8.self), "é", "Truncation keeps a character boundary")
        XCTAssertEqual(CodingAgentArguments.split("--acp --name \"two words\" 'x y'"), ["--acp", "--name", "two words", "x y"])
        XCTAssertEqual(CodingAgentArguments.split(CodingAgentArguments.join(["a b", "c"])), ["a b", "c"])
        // Gates: the same four modes as the other agents.
        let inside = dir + "/a.txt", outside = "/etc/hosts"
        XCTAssertEqual(CodingAccessGate.decide(.read(path: inside), access: .readOnly, directory: dir), .allow)
        XCTAssertEqual(CodingAccessGate.decide(.read(path: outside), access: .autoEdit, directory: dir), .ask)
        XCTAssertEqual(CodingAccessGate.decide(.read(path: dir + "/../x"), access: .edit, directory: dir), .ask, "`..` can't escape the folder")
        if case .deny = CodingAccessGate.decide(.write(path: inside), access: .readOnly, directory: dir) {} else { XCTFail("Read only refuses writes") }
        XCTAssertEqual(CodingAccessGate.decide(.write(path: inside), access: .edit, directory: dir), .ask)
        XCTAssertEqual(CodingAccessGate.decide(.write(path: inside), access: .autoEdit, directory: dir), .allow)
        XCTAssertEqual(CodingAccessGate.decide(.write(path: outside), access: .autoEdit, directory: dir), .ask)
        XCTAssertEqual(CodingAccessGate.decide(.command("rm -rf /"), access: .autoEdit, directory: dir), .ask)
        XCTAssertEqual(CodingAccessGate.decide(.command("ls"), access: .full, directory: dir), .allow)
        XCTAssertEqual(CodingAccessGate.decide(.tool(kind: "edit", paths: [inside]), access: .autoEdit, directory: dir), .allow)
        // A risky command asked through ACP still has no default key.
        let risky = CodingACP.approval(key: "k", toolCall: ["kind": "execute", "title": "Clean", "rawInput": ["command": "rm -rf build"]], directory: dir, pending: 1)
        XCTAssertTrue(risky.risk.dangerous)
        // An added agent sees only the basics and its allow-list.
        let environment = CodingAgentEnvironment.allowList(["GEMINI_API_KEY"]).build(["PATH": "/bin", "HOME": "/Users/x", "GEMINI_API_KEY": "k", "OPENAI_API_KEY": "secret"])
        XCTAssertEqual(environment["GEMINI_API_KEY"], "k"); XCTAssertNil(environment["OPENAI_API_KEY"]); XCTAssertEqual(environment["PATH"], "/bin")
        XCTAssertFalse(CodingAgentEnvironment.validName("1BAD")); XCTAssertFalse(CodingAgentEnvironment.validName("A-B")); XCTAssertTrue(CodingAgentEnvironment.validName("GOOGLE_CLOUD_PROJECT"))
    }

    // MARK: Muse Code (MSP) fixture

    /// A `muse serve` host following the exported MSP v1 schema (muse 1.4.0): `initialize`,
    /// `session/start|resume|fork`, `skill/list`, `turn/start` streaming `item/*` and
    /// `session/todoListChanged`, `approval/request` → receipt → `approval/decide`,
    /// `userInput/request` → `userInput/answer`, `turn/interrupt`, and `turn/completed`.
    private func museHost() throws -> URL {
        try script("fixture-muse", #"""
        #!/usr/bin/python3
        import json, sys, os
        log = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "muse-log"), "a")
        def L(s): log.write(s + "\n"); log.flush()
        L("argv " + " ".join(sys.argv[1:]))
        def emit(x): sys.stdout.write(json.dumps(x) + "\n"); sys.stdout.flush()
        def note(m, p): emit({"jsonrpc": "2.0", "method": m, "params": p})
        def read():
            line = sys.stdin.readline()
            if not line: sys.exit(0)
            return json.loads(line)
        def session(sid, fork=None):
            return {"sessionId": sid, "path": "", "status": "idle", "activeTurnId": None, "createdAt": "2026-09-27T00:00:00Z", "updatedAt": "2026-09-27T00:00:00Z", "workspaceRoot": "/w", "providerId": "meta", "modelId": None, "turnCount": 0, "forkedFrom": fork}
        SID = "ms-1"
        def item(kind, iid, status, **extra):
            d = {"itemId": iid, "kind": kind, "revision": 1, "status": status, "turnId": "t-1"}; d.update(extra); return d
        pending = []
        def wait(pred):
            while True:
                x = read()
                if pred(x): return x
                pending.append(x)
        while True:
            x = pending.pop(0) if pending else read()
            m = x.get("method"); p = x.get("params", {})
            if m == "initialize":
                L("initialize " + p["clientInfo"]["name"])
                emit({"jsonrpc": "2.0", "id": x["id"], "result": {"serverInfo": {"name": "muse", "version": "1.4.0"}, "userAgent": "fixture", "museHome": "/tmp", "platformFamily": "unix", "platformOs": "macos", "schema": {"version": 1, "fingerprint": "sha256:fixture"}, "grantedCapabilities": [], "experimentalApi": False, "sessionDurability": "durable"}})
            elif m == "initialized": L("initialized")
            elif m == "session/start":
                L("start %s %s %s" % (p["approvalMode"], p["workspaceRoot"], p.get("modelId", "-")))
                emit({"jsonrpc": "2.0", "id": x["id"], "result": {"session": session(SID), "viewCursor": "v:1"}})
            elif m == "session/resume":
                L("resume %s excludeItems=%s" % (p["sessionId"], p.get("excludeItems")))
                emit({"jsonrpc": "2.0", "id": x["id"], "result": {"session": session(p["sessionId"]), "viewCursor": "v:9", "history": {"mode": "none", "items": None, "snapshot": None, "noneReason": "excluded"}, "pendingRequests": []}})
            elif m == "session/fork":
                L("fork %s through %s" % (p["sessionId"], p["cutPoint"]["lastTurnId"]))
                emit({"jsonrpc": "2.0", "id": x["id"], "result": {"session": session("ms-fork", {"sessionId": p["sessionId"]}), "viewCursor": "", "history": {"mode": "none", "items": None, "snapshot": None}, "pendingRequests": []}})
            elif m == "session/setApprovalMode": L("approvalMode " + p["mode"]); emit({"jsonrpc": "2.0", "id": x["id"], "result": {"commandId": p["commandId"], "status": "accepted", "applyOutcome": "completed", "effectiveMode": {"mode": p["mode"], "source": "approvalReconfigure", "lastCommandId": p["commandId"]}}})
            elif m == "session/setModel": L("model " + p["model"]["modelId"]); emit({"jsonrpc": "2.0", "id": x["id"], "result": {"commandId": p["commandId"], "status": "accepted"}})
            elif m == "skill/list": emit({"jsonrpc": "2.0", "id": x["id"], "result": {"skills": [{"selector": "review-pr", "displayName": "review-pr", "description": "Review", "source": "bundled"}]}})
            elif m == "turn/start":
                SID = p["sessionId"]
                text = " ".join(part.get("text", "") or ("skill:" + part.get("selector", "") + " " + part.get("arguments", "")) for part in p["input"])
                L("turn %s effort=%s ifBusy=%s cmd=%d" % (text, p.get("reasoningEffort", "-"), p.get("ifBusy"), len(p["commandId"])))
                emit({"jsonrpc": "2.0", "id": x["id"], "result": {"commandId": p["commandId"], "status": "accepted", "turnId": "t-1", "disposition": "started", "startedNewTurn": True}})
                note("turn/started", {"sessionId": SID, "turnId": "t-1", "commandId": p["commandId"], "viewCursor": "v:2"})
                if "SCENARIO:auth" in text:
                    note("turn/completed", {"sessionId": SID, "turnId": "t-1", "terminal": "failed", "error": {"kind": "authRequired", "message": "not logged in: run /login to add an API key", "retryable": False}, "viewCursor": "v:3"})
                    continue
                if "SCENARIO:wait" in text:
                    x2 = wait(lambda y: y.get("method") == "turn/interrupt")
                    L("interrupt " + x2["params"]["turnId"])
                    emit({"jsonrpc": "2.0", "id": x2["id"], "result": {"commandId": x2["params"]["commandId"], "status": "accepted", "turnId": "t-1"}})
                    note("turn/completed", {"sessionId": SID, "turnId": "t-1", "terminal": "cancelled", "viewCursor": "v:4"})
                    continue
                note("item/started", {"sessionId": SID, "viewCursor": "v:3", "item": item("userMessage", "u1", "completed", text=text)})
                note("item/started", {"sessionId": SID, "viewCursor": "v:4", "item": item("reasoning", "r1", "inProgress", summary=[])})
                note("item/delta", {"sessionId": SID, "itemId": "r1", "field": "summary.0", "delta": "Looking", "viewCursor": "v:5"})
                note("item/delta", {"sessionId": SID, "itemId": "r1", "field": "summary.1", "delta": "Found it", "viewCursor": "v:6"})
                note("item/started", {"sessionId": SID, "viewCursor": "v:7", "item": item("agentMessage", "a1", "inProgress", text="")})
                note("item/delta", {"sessionId": SID, "itemId": "a1", "delta": "Hello ", "viewCursor": "v:8"})
                note("item/delta", {"sessionId": SID, "itemId": "a1", "delta": "Muse", "viewCursor": "v:9"})
                note("item/started", {"sessionId": SID, "viewCursor": "v:10", "item": item("toolCall", "k1", "inProgress", tool="bash", args="{\"command\": \"swift test\"}")})
                note("item/delta", {"sessionId": SID, "itemId": "k1", "field": "output", "delta": "Tests passed", "viewCursor": "v:11"})
                note("item/completed", {"sessionId": SID, "viewCursor": "v:12", "item": item("toolCall", "k1", "completed", tool="bash", args="{\"command\": \"swift test\"}", visibleOutput="Tests passed")})
                note("item/completed", {"sessionId": SID, "viewCursor": "v:13", "item": item("toolCall", "k2", "completed", tool="edit_file", args="{\"path\": \"/w/a.swift\", \"old_string\": \"a\", \"new_string\": \"b\"}", patchSummary={"files": 1, "added": 1, "removed": 1})})
                note("session/todoListChanged", {"sessionId": SID, "items": [{"text": "Write tests", "status": "completed"}, {"text": "Fix bug", "status": "inProgress"}], "revision": 1, "sourceTool": "write_todos", "viewCursor": "v:14"})
                choices = [{"choiceId": "c-once", "decision": "approved", "label": "Allow once", "scope": "once"},
                           {"choiceId": "c-session", "decision": "approvedForSession", "label": "Allow for session", "scope": "session"},
                           {"choiceId": "c-persist", "decision": "approvedPolicyAmendment", "label": "Always", "scope": "localPersistent"},
                           {"choiceId": "c-deny", "decision": "denied", "label": "Deny", "scope": "once", "acceptsFeedback": True}]
                emit({"jsonrpc": "2.0", "id": 100, "method": "approval/request", "params": {"approvalId": "ap-1", "availableChoices": choices, "currentRequirementId": {"approvalId": "ap-1", "sourceIndex": 0}, "itemId": "k3", "judgeEscalated": False, "protectedWrite": False, "rawArgs": "{\"command\": \"rm -rf build\"}", "sessionId": SID, "subject": {"kind": "shell", "command": "rm -rf build"}, "taskId": "k3", "toolCallId": "call_1", "toolName": "bash", "turnId": "t-1", "viewCursor": "v:15", "sourceRange": {}}})
                receipt = wait(lambda y: y.get("id") == 100 and "method" not in y); L("receipt " + json.dumps(receipt.get("result")))
                decide = wait(lambda y: y.get("method") == "approval/decide")
                L("decide %s feedback=%s requirement=%s" % (decide["params"]["choiceId"], decide["params"].get("feedback"), decide["params"]["requirementId"]["approvalId"]))
                emit({"jsonrpc": "2.0", "id": decide["id"], "result": {"approvalId": "ap-1", "commandId": decide["params"]["commandId"], "status": "accepted", "terminal": True}})
                note("approval/resolved", {"sessionId": SID, "approvalId": "ap-1", "decision": "denied", "itemId": "k3", "policyResult": "deny", "resolvedBy": "user", "stageEvidence": [], "turnId": "t-1", "viewCursor": "v:16", "sourceRange": {}})
                emit({"jsonrpc": "2.0", "id": 101, "method": "userInput/request", "params": {"userInputId": "ui-1", "itemId": "k4", "questions": [{"id": "q1", "header": "Deploy", "question": "Deploy now?", "options": [{"label": "Yes"}, {"label": "No"}], "selection": {"mode": "single"}}], "sessionId": SID, "toolCallId": "call_2", "toolName": "request_user_input", "turnId": "t-1", "viewCursor": "v:17"}})
                wait(lambda y: y.get("id") == 101 and "method" not in y)
                answer = wait(lambda y: y.get("method") == "userInput/answer")
                L("answer " + json.dumps(answer["params"]["answers"], sort_keys=True))
                emit({"jsonrpc": "2.0", "id": answer["id"], "result": {"commandId": answer["params"]["commandId"], "status": "accepted", "userInputId": "ui-1"}})
                note("item/completed", {"sessionId": SID, "viewCursor": "v:18", "item": item("agentMessage", "a1", "completed", text="Hello Muse")})
                note("turn/completed", {"sessionId": SID, "turnId": "t-1", "terminal": "completed", "durationMs": 10, "viewCursor": "v:19"})
            elif m == "session/delete":
                L("delete " + p["sessionId"])
                emit({"jsonrpc": "2.0", "id": x["id"], "result": {"commandId": p["commandId"], "status": "accepted"}})
                note("session/deleteCompleted", {"commandId": p["commandId"], "sessionId": p["sessionId"], "outcome": "completed"})
            elif m == "model/list":
                emit({"jsonrpc": "2.0", "id": x["id"], "result": {"providerId": "meta", "profileId": None, "source": "providerCatalog", "models": [{"modelId": "muse-spark-1.2", "displayLabel": "Muse Spark 1.2", "description": "Default", "isActive": False, "isDefault": True, "contextLimit": None, "cost": None, "outputLimit": None, "profileId": None, "providerId": "meta", "releaseDate": None, "variants": ["low", "medium", "high", "max"]}]}})
            else: L("unexpected " + json.dumps(x))
        """#)
    }

    func testMuseStreamsApprovesAndAnswersThroughMSP() async throws {
        let recorder = Recorder(record(.muse, access: .edit, effort: "xhigh"))
        let session = CodingMuseSession(task: recorder.task, executableOverride: try museHost(), environment: CodingChild.environment(), interruptGrace: 1, terminationGrace: 1)
        let done = expectation(description: "turn done")
        attach(session, recorder, done: done) { approval in
            if approval.kind == .question { try? session.respond(approval.id, decision: .allowOnce, answers: "yes") }
            else { try? session.respond(approval.id, decision: .deny(note: "Keep the build folder"), answers: "") }
        }
        try session.send("Fix it")
        await fulfillment(of: [done], timeout: 20)
        let lines = try log("muse-log")
        XCTAssertEqual(lines.first, "argv serve --trust-workspace", "Ask first runs the host with its sandbox on")
        XCTAssertTrue(lines.contains("initialize tsukumo") && lines.contains("initialized"))
        XCTAssertTrue(lines.contains("start promptUnmatched \(folder.path) -"), "Ask first is MSP's promptUnmatched, in the task's folder")
        XCTAssertTrue(lines.contains("turn Fix it effort=xhigh ifBusy=queue cmd=36"), "Effort per turn, a UUIDv7 command ID")
        XCTAssertTrue(lines.contains("receipt {}"), "approval/request gets a presentation receipt")
        XCTAssertTrue(lines.contains("decide c-deny feedback=Keep the build folder requirement=ap-1"), "Deny with a note uses the choice that takes feedback")
        XCTAssertTrue(lines.contains("answer [{\"questionId\": \"q1\", \"selectedLabel\": \"Yes\"}]"), "An answer naming an option selects it")
        let risky = try XCTUnwrap(recorder.approvals.first { $0.kind == .command })
        XCTAssertEqual(risky.command, "rm -rf build"); XCTAssertTrue(risky.risk.dangerous, "A risky command has no default")
        XCTAssertEqual(recorder.events(.assistant).map(\.text), ["Hello Muse"])
        XCTAssertEqual(recorder.events(.assistant).first?.ref, "t-1", "Replies carry their turn, for forking")
        XCTAssertEqual(recorder.events(.reasoning).first?.text, "Looking\n\nFound it")
        let tool = try XCTUnwrap(recorder.task.events.first { $0.id == "k1" })
        XCTAssertEqual(tool.text, "swift test"); XCTAssertEqual(tool.status, "completed"); XCTAssertEqual(tool.tool, "commandExecution")
        let edit = try XCTUnwrap(recorder.task.events.first { $0.id == "k2" })
        XCTAssertEqual(edit.kind, .file); XCTAssertTrue(edit.detail.contains("-a\n+b")); XCTAssertEqual(edit.output, "+1 −1 in 1 file")
        XCTAssertEqual(recorder.events(.plan).first?.detail, "completed · Write tests\ninProgress · Fix bug")
        XCTAssertEqual(recorder.sessions, ["ms-1"])
        XCTAssertTrue(recorder.reports.contains { $0.commands == ["review-pr"] })
        XCTAssertTrue(recorder.reports.contains { $0.signedIn == true })
        // A second message that names a skill goes as a skill part.
        let second = expectation(description: "second")
        session.onState = { if $0 == .review { second.fulfill() } }
        session.onApproval = { approval in
            guard let approval else { return }
            try? session.respond(approval.id, decision: approval.kind == .question ? .allowOnce : .allowOnce, answers: "No")
        }
        try session.send("/review-pr 42")
        await fulfillment(of: [second], timeout: 20); session.stop()
        let after = try log("muse-log")
        XCTAssertTrue(after.contains { $0.hasPrefix("turn skill:review-pr 42") }, "A /skill message is a skill part")
        XCTAssertTrue(after.contains("decide c-once feedback=None requirement=ap-1"), "Allow once picks the one-time choice")
    }

    func testMuseResumesForksInterruptsAndReportsSignIn() async throws {
        // Resume: the saved session, then its approval mode and model.
        let resumed = Recorder(record(.muse, access: .autoEdit, model: "muse-spark-1.2", session: "ms-old"))
        let host = try museHost()
        let first = CodingMuseSession(task: resumed.task, executableOverride: host, environment: CodingChild.environment(), interruptGrace: 1, terminationGrace: 1)
        let interrupted = expectation(description: "interrupted")
        attach(first, resumed, done: interrupted, doneOn: [.interrupted])
        try first.send("SCENARIO:wait")
        try await Task.sleep(for: .milliseconds(600))
        first.interrupt()
        await fulfillment(of: [interrupted], timeout: 10); first.stop()
        var lines = try log("muse-log")
        XCTAssertTrue(lines.contains("resume ms-old excludeItems=True"))
        XCTAssertTrue(lines.contains("approvalMode onRequest") && lines.contains("model muse-spark-1.2"), "A reopened session gets the task's access and model")
        XCTAssertTrue(lines.contains("interrupt t-1"), "Esc is turn/interrupt for the running turn")

        // Fork from a reply's turn.
        try FileManager.default.removeItem(at: folder.appendingPathComponent("muse-log"))
        var forkTask = record(.muse, access: .full)
        forkTask.fork = .init(sessionID: "ms-1", ref: "t-7")
        let forked = Recorder(forkTask)
        let second = CodingMuseSession(task: forkTask, executableOverride: host, environment: CodingChild.environment(), interruptGrace: 1, terminationGrace: 1)
        let authFailed = expectation(description: "failed")
        attach(second, forked, done: authFailed, doneOn: [.failed])
        try second.send("SCENARIO:auth")
        await fulfillment(of: [authFailed], timeout: 10); second.stop()
        lines = try log("muse-log")
        XCTAssertEqual(lines.first, "argv serve --trust-workspace --disable-sandbox", "Full access turns the host's sandbox off")
        XCTAssertTrue(lines.contains("fork ms-1 through t-7") && lines.contains("approvalMode allowAll"))
        XCTAssertEqual(forked.sessions, ["ms-fork"])
        XCTAssertTrue(forked.reports.contains { $0.signedIn == false }, "authRequired marks Muse Code signed out")
        XCTAssertTrue(forked.events(.system).contains { $0.text == "Sign in to Muse Code" })
    }

    func testMuseCatalogAndDeletion() async throws {
        let host = try museHost()
        let probe = CodingMuseCatalogProbe(executableOverride: host, environment: CodingChild.environment())
        let listed = expectation(description: "listed")
        var models: [CodingAgentModel] = []
        probe.run { result in models = (try? result.get().models) ?? []; listed.fulfill() }
        await fulfillment(of: [listed], timeout: 10)
        XCTAssertEqual(models.map(\.id), ["muse-spark-1.2"]); XCTAssertEqual(models.first?.efforts, ["low", "medium", "high", "max"]); XCTAssertEqual(models.first?.isDefault, true)
        let problem = await CodingMuseSessionDeletion(sessionID: "ms-9", executableOverride: host, environment: CodingChild.environment()).run()
        XCTAssertNil(problem)
        XCTAssertTrue(try log("muse-log").contains("delete ms-9"))
    }

    func testMuseExecFallbackStreamsRecords() async throws {
        let exec = try script("fixture-muse-exec", #"""
        #!/usr/bin/python3
        import json, sys
        open("exec-args", "w").write(" ".join(sys.argv[1:]))
        prompt = open(sys.argv[sys.argv.index("--prompt-file") + 1]).read()
        def rec(seq, ptype, payload): print(json.dumps({"schema_version": 1, "stream": {"kind": "session", "id": "ex-1"}, "sequence": seq, "payload_type": ptype, "payload": payload}), flush=True)
        rec(1, "runtime.command.accepted", {"kind": "command_accepted"})
        rec(2, "run.output.delta", {"kind": "run_output_delta", "text": "echo: "})
        rec(3, "run.output.delta", {"kind": "run_output_delta", "text": prompt})
        rec(4, "run.terminal.completed", {"kind": "run_terminal", "terminal": "completed", "text": "echo: " + prompt, "reason": None})
        """#)
        let recorder = Recorder(record(.muse, access: .readOnly, effort: "low"))
        let session = CodingMuseExecSession(task: recorder.task, executableOverride: exec, environment: CodingChild.environment(), extraArguments: ["--provider", "echo"])
        let done = expectation(description: "done")
        attach(session, recorder, done: done)
        try session.send("hello")
        await fulfillment(of: [done], timeout: 10); session.stop()
        XCTAssertEqual(recorder.events(.assistant).map(\.text), ["echo: hello"])
        XCTAssertEqual(recorder.sessions, ["ex-1"])
        let args = try String(contentsOf: folder.appendingPathComponent("exec-args"), encoding: .utf8)
        XCTAssertTrue(args.hasPrefix("exec --provider echo --json --prompt-file "))
        XCTAssertTrue(args.contains("--disable-write --disable-shell") && args.contains("--reasoning-effort low"))
    }

    func testMusePureMapping() {
        XCTAssertEqual(CodingMuse.serveArguments(.readOnly), ["serve", "--trust-workspace", "--disable-write", "--disable-shell"])
        XCTAssertEqual(CodingMuse.serveArguments(.autoEdit), ["serve", "--trust-workspace"])
        XCTAssertEqual([CodingAccess.readOnly, .edit, .autoEdit, .full].map(CodingMuse.approvalMode), ["denyUnmatched", "promptUnmatched", "onRequest", "allowAll"])
        let id = CodingMuse.uuid7()
        XCTAssertNotNil(UUID(uuidString: id)); XCTAssertEqual(Array(id)[14], "7", "Version 7")
        XCTAssertTrue(["8", "9", "a", "b"].contains(Array(id)[19]), "RFC 4122 variant")
        let choices: [[String: Any]] = [["choiceId": "p", "decision": "approvedPolicyAmendment", "scope": "localPersistent"], ["choiceId": "s", "decision": "approvedForSession", "scope": "session"], ["choiceId": "o", "decision": "approved", "scope": "once"], ["choiceId": "d", "decision": "denied", "scope": "once"]]
        XCTAssertEqual(CodingMuse.choice(for: .allowSession, in: choices)?["choiceId"] as? String, "s", "Never a persistent rule")
        XCTAssertEqual(CodingMuse.choice(for: .allowOnce, in: choices)?["choiceId"] as? String, "o")
        XCTAssertEqual(CodingMuse.choice(for: .deny(note: "x"), in: choices)?["choiceId"] as? String, "d")
        let patch = CodingMuse.applyPatchDiff("*** Begin Patch\n*** Update File: /w/a.txt\n@@\n-old\n+new\n*** Add File: b.txt\n+hello\n*** End Patch", directory: "/w")
        XCTAssertEqual(CodingDiff.parse(patch).map(\.path), ["a.txt", "b.txt"])
        XCTAssertEqual(CodingMuse.input(.init(text: "/review-pr 42"), skills: ["review-pr"]).first?["type"] as? String, "skill")
        XCTAssertEqual(CodingMuse.input(.init(text: "/usr/bin is a path"), skills: ["review-pr"]).first?["type"] as? String, "text")
        XCTAssertNil(CodingMuse.itemEvent(["itemId": "u", "kind": "userMessage", "status": "completed", "revision": 1], directory: "/w"))
        XCTAssertEqual(CodingMuse.itemEvent(["itemId": "x", "kind": "someFutureKind", "status": "completed", "revision": 1, "fallbackText": "Did a new thing"], directory: "/w")?.text, "Did a new thing")
    }

    // MARK: Registry, grants, delete, and Run with…

    func testRegistryAdaptersGrantsAndPlanNames() throws {
        let defaults = UserDefaults(suiteName: "CodingAgentAdapterTests-" + UUID().uuidString)!
        let registry = CodingAgentRegistry(defaults: defaults)
        XCTAssertEqual(registry.adapters.map(\.provider), [.claude, .codex, .muse, .cursor])
        XCTAssertEqual(registry.adapter(for: .claude).transport, .claudeStreamJSON)
        XCTAssertEqual(registry.adapter(for: .codex).transport, .codexAppServer)
        XCTAssertEqual(registry.adapter(for: .muse).transport, .msp)
        XCTAssertTrue(registry.adapter(for: .claude).makeSession(record(.claude)) is CodingAgentSession, "Claude Code keeps its driver")
        XCTAssertTrue(registry.adapter(for: .codex).makeSession(record(.codex)) is CodingAgentSession, "Codex keeps its driver")
        XCTAssertTrue(registry.adapter(for: .muse).makeSession(record(.muse)) is CodingMuseSession)
        XCTAssertTrue(registry.adapter(for: .cursor).makeSession(record(.cursor)) is CodingACPSession)
        let gemini = CodingCustomAgent(name: "Gemini CLI", command: "gemini", arguments: ["--experimental-acp"], environment: ["GEMINI_API_KEY", "bad-name"])
        registry.save(gemini)
        XCTAssertEqual(registry.custom.first?.environment, ["GEMINI_API_KEY"], "Only valid variable names are kept")
        XCTAssertEqual(gemini.provider.title, "Gemini CLI")
        XCTAssertEqual(registry.grant(for: gemini.provider), .autoEdit, "An added agent starts below Full access")
        XCTAssertEqual(registry.clamp(.full, for: gemini.provider), .autoEdit)
        XCTAssertEqual(registry.grant(for: .claude), .full)
        registry.setGrant(.edit, for: .muse)
        XCTAssertEqual(CodingAgentRegistry(defaults: defaults).grant(for: .muse), .edit, "Grants are remembered")
        XCTAssertEqual(CodingAgentRegistry(defaults: defaults).custom.map(\.name), ["Gemini CLI"], "Added agents are remembered")
        // Plans name any adapter.
        XCTAssertEqual(CodingProvider(planName: "muse"), .muse)
        XCTAssertEqual(CodingProvider(planName: "Cursor Agent"), .cursor)
        XCTAssertEqual(CodingProvider(planName: "gemini-cli"), gemini.provider)
        XCTAssertEqual(gemini.provider.planName, "gemini-cli")
        let reply = "Plan:\n```json\n{\"version\": 1, \"summary\": \"s\", \"subtasks\": [{\"id\": \"a\", \"title\": \"A\", \"brief\": \"b\", \"files\": [], \"areas\": [], \"depends_on\": [], \"agent\": \"muse\"}, {\"id\": \"b\", \"title\": \"B\", \"brief\": \"b\", \"files\": [], \"areas\": [], \"depends_on\": [\"a\"], \"agent\": \"gemini-cli\"}]}\n```"
        let plan = try OrchestratorPlanner.parse(reply)
        XCTAssertEqual(plan.subtasks.map(\.agent), [.muse, gemini.provider])
        // Saved tasks still decode their agent.
        let data = try JSONEncoder().encode(record(.codex))
        XCTAssertEqual(try JSONDecoder().decode(CodingTaskRecord.self, from: data).provider, .codex)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"provider\":\"codex\""), "Stored as the same string as before")
        registry.remove(gemini)
        XCTAssertTrue(registry.custom.isEmpty)
        XCTAssertEqual(registry.adapter(for: gemini.provider).command, "missing-agent", "A removed agent's old tasks still open")
    }

    func testDeleteSummaryNamesEachAgentsSession() {
        var muse = record(.muse); muse.sessionID = "ms-1"
        XCTAssertTrue(CodingAgentSessionRemoval.summary(muse).contains("Muse Code's saved session"))
        var cursor = record(.cursor); cursor.sessionID = "c-1"
        XCTAssertTrue(CodingAgentSessionRemoval.summary(cursor).contains("Cursor Agent keeps its own copy"))
        var codex = record(.codex); codex.sessionID = "t"
        XCTAssertTrue(CodingAgentSessionRemoval.summary(codex).contains("Codex thread"))
    }

    func testRunWithStartsEachChosenAgentInItsOwnWorktree() async throws {
        let repo = folder.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["-c", "user.email=t@t", "-c", "user.name=T", "-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty", "-m", "init"]] {
            _ = try await CodingCommand.git(args, at: repo)
        }
        let storage = CodingStorage(directory: folder.appendingPathComponent("Coding"), ownerID: "local-test")
        try FileManager.default.createDirectory(at: storage.directory, withIntermediateDirectories: true)
        var made: [CodingProvider] = []
        let store = CodingWorkspaceStore(storage: storage, sessionFactory: { task in made.append(task.provider); return RunWithFakeSession() })
        await store.runWith([.claude, .muse, .cursor], project: DesktopProject(name: "P", bookmark: Data()), root: repo, prompt: "Do it", access: .edit, images: [])
        XCTAssertEqual(made, [.claude, .muse, .cursor])
        let group = try XCTUnwrap(store.tasks.first?.group)
        XCTAssertEqual(store.group(group).count, 3); XCTAssertTrue(store.group(group).allSatisfy(\.isolated))
        XCTAssertEqual(store.selected, store.tasks.first { $0.provider == .claude }?.id, "The first agent opens")
        await store.runWith([.claude], project: DesktopProject(name: "P", bookmark: Data()), root: repo, prompt: "x", access: .edit, images: [])
        XCTAssertEqual(store.notice, "Choose two or three agents to compare.")
        for task in store.tasks { store.stop(task.id) }
    }

    // MARK: Gated: the real Muse Code (echo provider, isolated folders, no sign-in)

    /// Runs only with `TSUKUMO_MUSE_LIVE=1` (pass `TEST_RUNNER_TSUKUMO_MUSE_LIVE=1` to
    /// xcodebuild). Drives the installed `muse` through Tsukumo's classes: a whole turn through
    /// `muse exec --provider echo` (deterministic, offline), and `muse serve` for the handshake,
    /// `model/list`, and `session/delete`. The default Meta provider is never given a prompt, the
    /// launcher never updates or signs in, and every Muse folder is a temporary one.
    func testLiveMuseCodeWithTheEchoProvider() async throws {
        guard ProcessInfo.processInfo.environment["TSUKUMO_MUSE_LIVE"] == "1" else { throw XCTSkip("Set TSUKUMO_MUSE_LIVE=1 to drive the installed muse") }
        let muse = URL(fileURLWithPath: NSHomeDirectory() + "/.local/bin/muse")
        guard FileManager.default.isExecutableFile(atPath: muse.path) else { throw XCTSkip("muse isn't installed") }
        var environment = CodingChild.environment(["MUSE_NO_AUTO_UPDATE": "1", "MUSE_LOGIN": "0"])
        for name in ["XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_STATE_HOME"] {
            let dir = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); environment[name] = dir.path
        }
        environment["MUSE_AUTH_PATH"] = folder.appendingPathComponent("no-auth.json").path
        // A whole turn, headless, with the echo provider.
        let recorder = Recorder(record(.muse, access: .readOnly))
        let exec = CodingMuseExecSession(task: recorder.task, executableOverride: muse, environment: environment, extraArguments: ["--provider", "echo"])
        let done = expectation(description: "echo turn")
        attach(exec, recorder, done: done, doneOn: [.review, .failed])
        try exec.send("hello from Tsukumo")
        await fulfillment(of: [done], timeout: 90); exec.stop()
        XCTAssertEqual(recorder.states.last, .review, recorder.task.events.map { $0.text + " " + $0.detail }.joined(separator: "\n"))
        XCTAssertEqual(recorder.events(.assistant).last?.text, "echo: hello from Tsukumo")
        // `muse serve`: initialize, initialized, model/list (no session, no prompt).
        let listed = expectation(description: "catalog")
        var answer: Result<CodingCatalogProbe.Answer, Error>?
        CodingMuseCatalogProbe(executableOverride: muse, environment: environment).run { answer = $0; listed.fulfill() }
        await fulfillment(of: [listed], timeout: 60)
        XCTAssertNoThrow(try answer?.get(), "muse serve answered initialize and model/list")
        // MSP end to end without a prompt: initialize, session/start, skill/list, and
        // session/compact (a new session has nothing to compact, so no model is called).
        let msp = Recorder(record(.muse, access: .edit))
        let host = CodingMuseSession(task: msp.task, executableOverride: muse, environment: environment, interruptGrace: 1, terminationGrace: 2)
        let compacted = expectation(description: "compact")
        attach(host, msp, done: compacted, doneOn: [.review, .failed])
        try host.compact()
        await fulfillment(of: [compacted], timeout: 60); host.stop()
        XCTAssertEqual(msp.states.last, .review, msp.task.events.map { $0.text + " " + $0.detail }.joined(separator: "\n"))
        XCTAssertEqual(msp.sessions.count, 1, "session/start returned a session")
        XCTAssertTrue(msp.reports.contains { !$0.commands.isEmpty }, "skill/list reported Muse's skills")
        // session/delete through a fresh host: Muse 1.4.0 lets only the host that started a
        // session delete it, and Tsukumo says so instead of claiming it's gone.
        let session = try XCTUnwrap(recorder.sessions.first)
        let problem = await CodingMuseSessionDeletion(sessionID: session, executableOverride: muse, environment: environment).run()
        XCTAssertTrue(problem == nil || problem!.contains("ownershipUnavailable"), problem ?? "")
    }

    // MARK: Screenshots (offscreen), for the owner

    /// Writes Settings → Agents and the agent chooser as PNGs when `TSUKUMO_SCREENSHOTS_DIR` is set.
    func testRenderAgentScreens() throws {
        guard let dir = ProcessInfo.processInfo.environment["TSUKUMO_SCREENSHOTS_DIR"], !dir.isEmpty else { throw XCTSkip("Set TSUKUMO_SCREENSHOTS_DIR to write screenshots") }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let registry = CodingAgentRegistry(defaults: UserDefaults(suiteName: "CodingAgentAdapterTests-shots-" + UUID().uuidString)!)
        registry.save(CodingCustomAgent(name: "Gemini CLI", command: "gemini", arguments: ["--experimental-acp"], environment: ["GEMINI_API_KEY"]))
        registry.refresh()
        let rows = registry.rows()
        let preferences = DesktopPreferences(defaults: UserDefaults(suiteName: "CodingAgentAdapterTests-prefs-" + UUID().uuidString)!)
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            try render(CodingAgentsPageContent(rows: rows, signIn: { _ in }, setGrant: { _, _ in }, edit: { _ in }, remove: { _ in }, add: {})
                        .padding(28).frame(width: 760), scheme: scheme, preferences: preferences, to: out.appendingPathComponent("settings-agents-\(suffix).png"))
            try render(CodingAgentChooser(rows: rows, selection: .muse, choose: { _ in }, addAgent: {}), scheme: scheme, preferences: preferences,
                       to: out.appendingPathComponent("agent-chooser-\(suffix).png"))
            try render(CodingRunWithPicker(rows: rows, chosen: [.claude, .muse], start: { _ in }), scheme: scheme, preferences: preferences,
                       to: out.appendingPathComponent("run-with-\(suffix).png"))
            try render(CodingAddAgentSheet(agent: CodingCustomAgent(name: "Gemini CLI", command: "gemini", arguments: ["--experimental-acp"], environment: ["GEMINI_API_KEY"]), isNew: true, save: { _ in }),
                       scheme: scheme, preferences: preferences, to: out.appendingPathComponent("add-agent-\(suffix).png"))
        }
    }
    private func render<V: View>(_ view: V, scheme: ColorScheme, preferences: DesktopPreferences, to url: URL) throws {
        let background = scheme == .dark ? Color(white: 0.12) : Color(white: 0.97)
        let hosting = NSHostingView(rootView: view.environment(preferences).environment(\.colorScheme, scheme).background(background).fixedSize())
        hosting.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}

@MainActor private final class RunWithFakeSession: AgentSession {
    var onEvent: ((CodingEvent, Bool) -> Void)?
    var onState: ((CodingTaskStatus) -> Void)?
    var onSession: ((String) -> Void)?
    var onApproval: ((CodingApproval?) -> Void)?
    func send(_ text: String) throws { onState?(.working) }
    func respond(_ id: String, allow: Bool, answers: String) throws {}
    func stop() {}
}

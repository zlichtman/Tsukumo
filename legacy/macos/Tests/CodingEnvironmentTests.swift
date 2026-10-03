import XCTest
@testable import KemoSabeMac

@MainActor final class CodingEnvironmentTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("CodingTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let folder { try? FileManager.default.removeItem(at: folder) } }
    private func record() -> CodingTaskRecord {
        .init(projectID: UUID(), ownerID: "local-test", title: "Test task", provider: .codex, model: "", access: .edit, projectPath: folder.path, directory: folder.path, isolated: false)
    }
    func testStorageRefusesForeignOwnerAndNewerSchemaWithoutOverwrite() throws {
        let storage = CodingStorage(directory: folder, ownerID: "local-test")
        try storage.save([record()])
        let original = try Data(contentsOf: storage.url)
        let foreign = CodingStorage(directory: folder, ownerID: "other")
        XCTAssertThrowsError(try foreign.read()); XCTAssertThrowsError(try foreign.save([]))
        XCTAssertEqual(try Data(contentsOf: storage.url), original)
        let future = try JSONEncoder().encode(CodingArchive(schema: 3, ownerID: "local-test", tasks: []))
        try future.write(to: storage.url)
        XCTAssertThrowsError(try storage.save([])); XCTAssertEqual(try Data(contentsOf: storage.url), future)
    }
    func testTasksOfAnAdoptedLocalAccountOpenAsTheAppleAccountsAndOthersStayRefused() throws {
        try CodingStorage(directory: folder, ownerID: "local-test").save([record()])
        let apple = CodingStorage(directory: folder, ownerID: "apple-abc", formerOwners: ["local-test"])
        let tasks = try apple.read()
        XCTAssertEqual(tasks.map(\.ownerID), ["apple-abc"])
        try apple.save(tasks)
        XCTAssertEqual(try CodingStorage(directory: folder, ownerID: "apple-abc").read().count, 1)
        XCTAssertThrowsError(try CodingStorage(directory: folder, ownerID: "apple-other", formerOwners: ["local-else"]).read())
    }
    func testRestartMarksWorkingAndApprovalTasksInterrupted() throws {
        let storage = CodingStorage(directory: folder, ownerID: "local-test")
        var one = record(), two = record(); one.status = .working; two.status = .needsInput
        one.sessionID = "provider-thread"
        try storage.save([one, two])
        let store = CodingWorkspaceStore(storage: storage)
        XCTAssertEqual(store.tasks.map(\.status), [.interrupted, .interrupted])
        XCTAssertEqual(store.task(one.id)?.sessionID, "provider-thread")
        XCTAssertTrue(store.approvals.isEmpty)
    }
    func testCorruptStorageIsNotReplacedWithEmptyTasks() throws {
        let storage = CodingStorage(directory: folder, ownerID: "local-test")
        let bad = Data("not json".utf8); try bad.write(to: storage.url)
        let store = CodingWorkspaceStore(storage: storage)
        XCTAssertTrue(store.storageFailed); XCTAssertEqual(try Data(contentsOf: storage.url), bad)
    }
    func testOverlapKeepsChangedFilesAfterClaimReassignment() {
        var one = record(), two = record(), done = record()
        one.changes = [.init(path: "src/a.swift", status: "M")]
        two.claims = ["src/a.swift"]; done.claims = ["src/other.swift"]; done.status = .done
        let overlap = CodingOverlap.find([one, two, done])
        XCTAssertEqual(overlap.map(\.path), ["src/a.swift"])
        XCTAssertEqual(Set(overlap[0].tasks), [one.id, two.id])
    }
    func testGitPathsKeepSpacesTabsAndRenames() {
        let result = CodingWorkspaceStore.parseChanges("M\0space name.swift\0R100\0old\tname\0new name\0")
        XCTAssertEqual(result.map(\.path), ["space name.swift", "old\tname", "new name"])
        XCTAssertEqual(result.map(\.status), ["M", "D", "A"])
    }
    func testEditorRejectsExternalChangesAndSymlinks() throws {
        let url = folder.appendingPathComponent("file.swift")
        try Data("original".utf8).write(to: url)
        let reference = ProjectReference(relativePath: "file.swift", byteCount: 8, kind: .document)
        try CodingEditorIO.save(file: reference, root: folder, original: "original", replacement: "mine")
        try Data("agent edit".utf8).write(to: url)
        XCTAssertThrowsError(try CodingEditorIO.save(file: reference, root: folder, original: "mine", replacement: "would overwrite"))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "agent edit")
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("link.swift").path, withDestinationPath: url.path)
        XCTAssertThrowsError(try CodingEditorIO.save(file: .init(relativePath: "link.swift", byteCount: 10, kind: .document), root: folder, original: "agent edit", replacement: "bad"))
    }
    func testWorktreeTaskReviewRejectsStaleDiffThenAcceptsAndRetainsRestorePoint() async throws {
        _ = try await CodingCommand.git(["init", "-b", "main"], at: folder)
        _ = try await CodingCommand.git(["config", "user.email", "fixture@example.invalid"], at: folder)
        _ = try await CodingCommand.git(["config", "user.name", "Fixture"], at: folder)
        _ = try await CodingCommand.git(["config", "commit.gpgsign", "false"], at: folder)
        try Data("initial\n".utf8).write(to: folder.appendingPathComponent("file.txt"))
        _ = try await CodingCommand.git(["add", "."], at: folder)
        _ = try await CodingCommand.git(["commit", "-m", "initial"], at: folder)
        let storageFolder = FileManager.default.temporaryDirectory.appendingPathComponent("CodingStorageTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: storageFolder) }
        let fake = FakeCodingSession()
        let store = CodingWorkspaceStore(storage: .init(directory: storageFolder, ownerID: "local-test"), sessionFactory: { _ in fake })
        let project = DesktopProject(name: "Fixture", bookmark: Data())
        let created = await store.create(project: project, root: folder, provider: .codex, model: "", access: .edit, isolated: true, prompt: "Change one file")
        let id = try XCTUnwrap(created), task = try XCTUnwrap(store.task(id))
        XCTAssertNotEqual(task.directory, folder.path); XCTAssertEqual(fake.sent, ["Change one file"])
        fake.onState?(.review)
        let file = URL(fileURLWithPath: task.directory).appendingPathComponent("file.txt")
        try Data("first\n".utf8).write(to: file)
        let stale = try await store.review(id)
        try Data("second\n".utf8).write(to: file)
        await store.accept(id, review: stale)
        XCTAssertNotEqual(store.task(id)?.status, .done)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("file.txt"), encoding: .utf8), "initial\n")
        let current = try await store.review(id)
        await store.accept(id, review: current)
        XCTAssertEqual(store.task(id)?.status, .done, store.notice)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("file.txt"), encoding: .utf8), "second\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: task.directory))
        let restored = CodingWorkspaceStore(storage: .init(directory: storageFolder, ownerID: "local-test"))
        XCTAssertEqual(restored.task(id)?.status, .done)
    }
    func testCodexProtocolStreamsRequestsApprovalAndCompletes() async throws {
        let script = folder.appendingPathComponent("fake-codex")
        let source = #"""
        #!/usr/bin/python3
        import json, sys
        def emit(x): print(json.dumps(x), flush=True)
        for line in sys.stdin:
            x=json.loads(line); m=x.get("method")
            if m == "initialize": emit({"id":x["id"],"result":{}})
            elif m == "thread/start": emit({"id":x["id"],"result":{"thread":{"id":"fixture-thread"}}})
            elif m == "turn/start":
                emit({"id":x["id"],"result":{"turn":{"id":"turn-1"}}})
                emit({"method":"item/agentMessage/delta","params":{"threadId":"fixture-thread","itemId":"message-1","delta":"Hello"}})
                emit({"id":42,"method":"item/commandExecution/requestApproval","params":{"threadId":"fixture-thread","command":"echo fixture"}})
            elif x.get("id") == 42:
                assert x["result"]["decision"] == "decline"
                emit({"method":"turn/completed","params":{"threadId":"fixture-thread","turn":{"id":"turn-1","status":"completed"}}})
        """#
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let session = CodingAgentSession(task: record(), executableOverride: script)
        let finished = expectation(description: "turn completed")
        var transcript = "", handle = "", requested = false
        session.onSession = { handle = $0 }
        session.onEvent = { event, _ in if event.kind == .assistant { transcript += event.text } }
        session.onApproval = { approval in
            guard let approval else { return }; requested = true
            do { try session.respond(approval.id, allow: false) } catch { XCTFail(error.localizedDescription) }
        }
        session.onState = { if $0 == .review { finished.fulfill() } }
        try session.send("Fixture only")
        await fulfillment(of: [finished], timeout: 10)
        session.stop()
        XCTAssertEqual(handle, "fixture-thread"); XCTAssertEqual(transcript, "Hello"); XCTAssertTrue(requested)
    }
    func testClaudeProtocolStreamsAndBindsSession() async throws {
        let script = folder.appendingPathComponent("fake-claude")
        let source = #"""
        #!/usr/bin/python3
        import json, sys
        def emit(x): print(json.dumps(x), flush=True)
        for line in sys.stdin:
            x=json.loads(line)
            if x.get("type") == "user":
                emit({"type":"system","subtype":"init","session_id":"fixture-claude"})
                emit({"type":"stream_event","event":{"type":"message_start","message":{"id":"m1"}}})
                emit({"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Working"}}})
                emit({"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"Working"}]}})
                emit({"type":"result","subtype":"success","is_error":False})
        """#
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        var task = record(); task.provider = .claude
        let session = CodingAgentSession(task: task, executableOverride: script)
        let done = expectation(description: "Claude complete")
        var handle = "", deltaID = "", finalID = ""
        session.onSession = { handle = $0 }
        session.onEvent = { event, delta in if event.kind == .assistant { if delta { deltaID = event.id } else { finalID = event.id } } }
        session.onState = { if $0 == .review { done.fulfill() } }
        try session.send("Fixture only")
        await fulfillment(of: [done], timeout: 10); session.stop()
        XCTAssertEqual(handle, "fixture-claude"); XCTAssertEqual(deltaID, finalID); XCTAssertFalse(deltaID.isEmpty)
    }
}
@MainActor private final class FakeCodingSession: AgentSession {
    var onEvent: ((CodingEvent, Bool) -> Void)?
    var onState: ((CodingTaskStatus) -> Void)?
    var onSession: ((String) -> Void)?
    var onApproval: ((CodingApproval?) -> Void)?
    var sent: [String] = []
    var stops = 0
    func send(_ text: String) throws { sent.append(text); onSession?("fixture-session"); onState?(.working) }
    func respond(_ id: String, allow: Bool, answers: String) throws { onApproval?(nil); onState?(.working) }
    func stop() { stops += 1; onState?(.interrupted) }
}

/// Persistence: streamed events are appended to a per-task log instead of rewriting every task,
/// the snapshot is debounced, and loading replays the log, surviving a torn last line.
@MainActor final class CodingPersistenceTests: XCTestCase {
    private var folder: URL!, work: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("CodingPersistence-" + UUID().uuidString)
        work = folder.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let folder { try? FileManager.default.removeItem(at: folder) } }
    private var storage: CodingStorage { .init(directory: folder.appendingPathComponent("Coding", isDirectory: true), ownerID: "local-test") }
    /// A working task whose fake agent the test drives, with snapshots held back for an hour.
    private func streamingTask() async throws -> (CodingWorkspaceStore, UUID, FakeCodingSession) {
        let fake = FakeCodingSession()
        let store = CodingWorkspaceStore(storage: storage, sessionFactory: { _ in fake }, snapshotDelay: .seconds(3600))
        let created = await store.create(project: DesktopProject(name: "Fixture", bookmark: Data()), root: work, provider: .codex, model: "", access: .edit, isolated: false, prompt: "Stream")
        return (store, try XCTUnwrap(created), fake)
    }

    func testStreamedEventsAppendToTheLogWithoutRewritingTheSnapshot() async throws {
        let (store, id, fake) = try await streamingTask()
        let snapshot = try Data(contentsOf: storage.url)
        for index in 0..<300 { fake.onEvent?(.init(id: "reply", kind: .assistant, text: "\(index) "), true) }
        XCTAssertEqual(try Data(contentsOf: storage.url), snapshot, "300 streamed deltas don't rewrite tasks.json")
        let expected = (0..<300).map { "\($0) " }.joined()
        XCTAssertEqual(store.task(id)?.events.last?.text, expected)
        let log = try storage.readLog(id)
        XCTAssertEqual(log.filter { $0.event.id == "reply" }.count, 300)
        XCTAssertEqual(log.map(\.seq), Array(1...log.count), "One ordered line per event")
        // A crash now (no snapshot since the deltas) loses nothing: the log is replayed.
        let reloaded = CodingWorkspaceStore(storage: storage)
        XCTAssertEqual(reloaded.task(id)?.events.first { $0.id == "reply" }?.text, expected)
        XCTAssertEqual(reloaded.task(id)?.status, .interrupted)
        XCTAssertEqual(reloaded.task(id)?.events.last?.text, "App restarted. Send a message to resume the saved agent session.")
        // A status change writes the snapshot at once; flush writes a pending one.
        store.flush()
        XCTAssertNotEqual(try Data(contentsOf: storage.url), snapshot)
    }
    func testATornLastLineIsCutAndEverythingBeforeItRecovers() async throws {
        let (store, id, fake) = try await streamingTask()
        fake.onEvent?(.init(id: "reply", kind: .assistant, text: "Hello"), true)
        fake.onEvent?(.init(id: "reply", kind: .assistant, text: ", world"), true)
        fake.onEvent?(.init(id: "cmd", kind: .command, text: "swift test", status: "completed"), false)
        // No snapshot since these events (it is held back an hour): recovery must come from the log.
        _ = store
        let complete = try Data(contentsOf: storage.logURL(id))
        // The app died partway through writing the next line.
        let handle = try FileHandle(forWritingTo: storage.logURL(id))
        try handle.seekToEnd(); try handle.write(contentsOf: Data(#"{"seq":99,"delta":true,"event":{"id":"reply","kind":"assis"#.utf8)); try handle.close()

        let recovered = try storage.read()
        let task = try XCTUnwrap(recovered.first { $0.id == id })
        XCTAssertEqual(task.events.first { $0.id == "reply" }?.text, "Hello, world")
        XCTAssertEqual(task.events.first { $0.id == "cmd" }?.status, "completed")
        XCTAssertEqual(try Data(contentsOf: storage.logURL(id)), complete, "The torn fragment is cut at the last complete line")
        // New events start on a clean line and are read back.
        let next = (task.logged ?? 0) + 1
        try storage.appendLog(.init(seq: next, event: .init(id: "after", kind: .system, text: "After recovery"), delta: false), task: id)
        XCTAssertEqual(try storage.readLog(id).last?.event.text, "After recovery")
        XCTAssertEqual(try storage.read().first { $0.id == id }?.events.last?.text, "After recovery")
    }
    func testTheViewIsCappedButTheLogKeepsTheFullText() async throws {
        let (store, id, fake) = try await streamingTask()
        let long = String(repeating: "a", count: 60_000) + "END"
        fake.onEvent?(.init(id: "out", kind: .command, text: "build", detail: long), false)
        for _ in 0..<3 { fake.onEvent?(.init(id: "out", kind: .command, text: "", detail: String(repeating: "b", count: 20_000)), true) }
        fake.onEvent?(.init(id: "out", kind: .command, text: "", detail: "LATEST"), true)
        let shown = try XCTUnwrap(store.task(id)?.events.first { $0.id == "out" })
        XCTAssertLessThan(shown.detail.count, 2 * CodingTranscript.keep + CodingTranscript.marker.count + 1)
        XCTAssertTrue(shown.detail.hasPrefix("aaaa")); XCTAssertTrue(shown.detail.hasSuffix("bbbLATEST")); XCTAssertTrue(shown.detail.contains(CodingTranscript.marker))
        let logged = try storage.readLog(id).filter { $0.event.id == "out" }
        XCTAssertEqual(logged.first?.event.detail, long, "The audit trail keeps every byte")
        XCTAssertEqual(logged.map(\.event.detail).joined().count, long.count + 60_000 + 6)
        // Old events fall out of the view, not out of the log.
        for index in 0..<(CodingTranscript.maximumEvents + 10) { fake.onEvent?(.init(id: "e\(index)", kind: .system, text: "\(index)"), false) }
        XCTAssertEqual(store.task(id)?.events.count, CodingTranscript.maximumEvents)
        XCTAssertGreaterThan(store.task(id)?.omittedEvents ?? 0, 10)
        XCTAssertEqual(try storage.readLog(id).count, store.task(id)?.logged)
        store.stopAll()
    }
    func testSchemaOneSnapshotsStillLoad() throws {
        var old = CodingTaskRecord(projectID: UUID(), ownerID: "local-test", title: "Old", provider: .codex, model: "", access: .edit, projectPath: work.path, directory: work.path, isolated: false)
        old.events = [.init(kind: .user, text: "From before logs")]; old.status = .review
        try FileManager.default.createDirectory(at: storage.directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(CodingArchive(schema: 1, ownerID: "local-test", tasks: [old])).write(to: storage.url)
        let store = CodingWorkspaceStore(storage: storage)
        XCTAssertEqual(store.task(old.id)?.events.map(\.text), ["From before logs"])
        store.markDone(old.id)
        let saved = try JSONDecoder().decode(CodingArchive.self, from: Data(contentsOf: storage.url))
        XCTAssertEqual(saved.schema, 2); XCTAssertEqual(saved.tasks.first?.events.first?.text, "From before logs")
    }
}

/// Cancellation: a stop interrupts the provider gracefully, then ends its whole process group, so
/// no command the agent started is orphaned; nothing is reported after the stop.
@MainActor final class CodingCancellationTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("CodingCancel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        // Never leave a fixture process behind, even when a test fails.
        for name in ["agent.pid", "child.pid"] {
            if let text = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8), let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) { kill(pid, SIGKILL) }
        }
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }
    private func script(_ name: String, _ source: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try source.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
    private func pid(_ name: String, timeout: TimeInterval = 10) async throws -> pid_t {
        let url = folder.appendingPathComponent(name), end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let text = try? String(contentsOf: url, encoding: .utf8), text.hasSuffix("\n"), let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return pid }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw CodingFailure("Fixture never wrote " + name)
    }
    private func gone(_ pid: pid_t, within timeout: TimeInterval = 10) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if kill(pid, 0) == -1, errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
    private func record(_ provider: CodingProvider) -> CodingTaskRecord {
        .init(projectID: UUID(), ownerID: "local-test", title: "Fixture", provider: provider, model: "", access: .edit, projectPath: folder.path, directory: folder.path, isolated: false)
    }
    private func fileText(_ name: String) -> String { (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)) ?? "" }

    func testCodexStopInterruptsTheTurnThenEndsTheAgentAndItsCommands() async throws {
        let agent = try script("fake-codex", #"""
        #!/usr/bin/python3
        import json, os, subprocess, sys
        def emit(x): print(json.dumps(x), flush=True)
        open("agent.pid", "w").write("%d\n" % os.getpid())
        for line in sys.stdin:
            x = json.loads(line); m = x.get("method")
            if m == "initialize": emit({"id": x["id"], "result": {}})
            elif m == "thread/start": emit({"id": x["id"], "result": {"thread": {"id": "fixture-thread"}}})
            elif m == "turn/start":
                child = subprocess.Popen(["/bin/sleep", "300"])
                open("child.pid", "w").write("%d\n" % child.pid)
                emit({"id": x["id"], "result": {"turn": {"id": "turn-1"}}})
                emit({"method": "item/agentMessage/delta", "params": {"threadId": "fixture-thread", "itemId": "m1", "delta": "Working"}})
            elif m == "turn/interrupt":
                open("interrupts", "a").write("%s %s\n" % (x["params"]["threadId"], x["params"]["turnId"]))
                emit({"method": "item/agentMessage/delta", "params": {"threadId": "fixture-thread", "itemId": "m1", "delta": " late"}})
                emit({"id": x["id"], "result": {}})
                emit({"method": "turn/completed", "params": {"threadId": "fixture-thread", "turn": {"id": "turn-1", "status": "interrupted"}}})
        # Input closed: exit, leaving the command it started running, as a crashed agent would.
        """#)
        let session = CodingAgentSession(task: record(.codex), executableOverride: agent, interruptGrace: 5, terminationGrace: 1)
        var transcript = "", reportsAfterStop = 0, stopped = false
        let working = expectation(description: "streaming")
        session.onEvent = { event, _ in
            if stopped { reportsAfterStop += 1 }
            if event.kind == .assistant { transcript += event.text; if transcript == "Working" { working.fulfill() } }
        }
        session.onState = { _ in if stopped { reportsAfterStop += 1 } }
        session.onApproval = { _ in if stopped { reportsAfterStop += 1 } }
        try session.send("Fixture only")
        await fulfillment(of: [working], timeout: 10)
        let agentPID = try await pid("agent.pid"), childPID = try await pid("child.pid")
        stopped = true; session.stop()
        let agentGone = await gone(agentPID), childGone = await gone(childPID)
        XCTAssertTrue(agentGone, "The agent exits"); XCTAssertTrue(childGone, "The command it started is not orphaned")
        XCTAssertEqual(fileText("interrupts"), "fixture-thread turn-1\n", "Codex is interrupted through turn/interrupt first")
        XCTAssertEqual(transcript, "Working"); XCTAssertEqual(reportsAfterStop, 0, "Nothing is reported after a stop")
        XCTAssertThrowsError(try session.send("Again"))
    }
    func testClaudeStopSendsInterruptThenForcesAStubbornProcessGroup() async throws {
        let agent = try script("fake-claude", #"""
        #!/usr/bin/python3
        import json, os, signal, subprocess, sys, time
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        def emit(x): print(json.dumps(x), flush=True)
        open("agent.pid", "w").write("%d\n" % os.getpid())
        for line in sys.stdin:
            x = json.loads(line)
            if x.get("type") == "user":
                child = subprocess.Popen(["/usr/bin/python3", "-c", "import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(300)"])
                open("child.pid", "w").write("%d\n" % child.pid)
                emit({"type": "system", "subtype": "init", "session_id": "fixture-claude"})
                emit({"type": "stream_event", "event": {"type": "message_start", "message": {"id": "m1"}}})
                emit({"type": "stream_event", "event": {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "Working"}}})
            elif x.get("type") == "control_request":
                open("interrupts", "a").write(x["request"]["subtype"] + "\n")
                # Never answers and ignores SIGTERM: only SIGKILL to the group ends it.
        time.sleep(300)
        """#)
        let session = CodingAgentSession(task: record(.claude), executableOverride: agent, interruptGrace: 0.5, terminationGrace: 0.5)
        var reportsAfterStop = 0, stopped = false, text = ""
        let working = expectation(description: "streaming")
        session.onEvent = { event, _ in if stopped { reportsAfterStop += 1 }; if event.kind == .assistant { text += event.text; if text == "Working" { working.fulfill() } } }
        session.onState = { _ in if stopped { reportsAfterStop += 1 } }
        try session.send("Fixture only")
        await fulfillment(of: [working], timeout: 10)
        let agentPID = try await pid("agent.pid"), childPID = try await pid("child.pid")
        stopped = true; session.stop()
        let agentGone = await gone(agentPID), childGone = await gone(childPID)
        XCTAssertTrue(agentGone); XCTAssertTrue(childGone, "A descendant that ignores SIGTERM is killed with the group")
        XCTAssertEqual(fileText("interrupts"), "interrupt\n", "Claude Code gets its interrupt control request first")
        XCTAssertEqual(reportsAfterStop, 0)
    }
    func testReleasingARunningSessionStillEndsItsProcessGroup() async throws {
        let agent = try script("fake-claude", #"""
        #!/usr/bin/python3
        import os, subprocess, time
        open("agent.pid", "w").write("%d\n" % os.getpid())
        child = subprocess.Popen(["/bin/sleep", "300"])
        open("child.pid", "w").write("%d\n" % child.pid)
        time.sleep(300)
        """#)
        var session: CodingAgentSession? = CodingAgentSession(task: record(.claude), executableOverride: agent, interruptGrace: 0.2, terminationGrace: 0.2)
        try session?.send("Fixture only")
        let agentPID = try await pid("agent.pid"), childPID = try await pid("child.pid")
        session = nil
        let agentGone = await gone(agentPID), childGone = await gone(childPID)
        XCTAssertTrue(agentGone); XCTAssertTrue(childGone)
    }
    func testCommandsEndEverythingTheyStartOnTimeoutAndOnExit() async throws {
        // Timeout: the shell and its background command both end, and the call returns.
        let started = Date()
        let timedOut = try await CodingCommand.run("/bin/sh", ["-c", "sleep 300 & echo $! > child.pid; wait"], at: folder, timeout: 1)
        XCTAssertNotEqual(timedOut.code, 0); XCTAssertLessThan(Date().timeIntervalSince(started), 20)
        let first = try await pid("child.pid")
        let firstGone = await gone(first); XCTAssertTrue(firstGone)
        // Exit: a check that leaves a background command holding its output doesn't hang or orphan it.
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("child.pid"))
        let quick = Date()
        let result = try await CodingCommand.run("/bin/sh", ["-c", "sleep 300 & echo $! > child.pid; echo done"], at: folder, timeout: 60)
        XCTAssertEqual(result.code, 0); XCTAssertEqual(result.output, "done\n"); XCTAssertLessThan(Date().timeIntervalSince(quick), 20)
        let second = try await pid("child.pid")
        let secondGone = await gone(second); XCTAssertTrue(secondGone)
    }
}

/// Review is a transaction: Accept commits the exact tree that was reviewed, and a check result
/// counts only for the tree it ran against.
@MainActor final class CodingReviewTransactionTests: XCTestCase {
    private var folder: URL!, storageFolder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("CodingReviewRepo-" + UUID().uuidString)
        storageFolder = FileManager.default.temporaryDirectory.appendingPathComponent("CodingReviewStorage-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        for url in [folder, storageFolder].compactMap({ $0 }) { try? FileManager.default.removeItem(at: url) }
    }
    /// A throwaway repository with one commit, and an isolated task in its own worktree.
    private func makeTask() async throws -> (CodingWorkspaceStore, UUID, URL) {
        for arguments in [["init", "-b", "main"], ["config", "user.email", "fixture@example.invalid"], ["config", "user.name", "Fixture"], ["config", "commit.gpgsign", "false"]] {
            _ = try await CodingCommand.git(arguments, at: folder)
        }
        try Data("initial\n".utf8).write(to: folder.appendingPathComponent("file.txt"))
        try Data("ignored.log\n".utf8).write(to: folder.appendingPathComponent(".gitignore"))
        _ = try await CodingCommand.git(["add", "."], at: folder)
        _ = try await CodingCommand.git(["commit", "-m", "initial"], at: folder)
        let fake = FakeCodingSession()
        let store = CodingWorkspaceStore(storage: .init(directory: storageFolder, ownerID: "local-test"), sessionFactory: { _ in fake })
        let created = await store.create(project: DesktopProject(name: "Fixture", bookmark: Data()), root: folder, provider: .codex, model: "", access: .edit, isolated: true, prompt: "Change files")
        let id = try XCTUnwrap(created)
        fake.onState?(.review)
        return (store, id, URL(fileURLWithPath: try XCTUnwrap(store.task(id)).directory))
    }
    private func read(_ name: String) throws -> String { try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) }

    func testAcceptCommitsExactlyTheReviewedTreeIncludingNewFiles() async throws {
        let (store, id, work) = try await makeTask()
        try Data("reviewed\n".utf8).write(to: work.appendingPathComponent("file.txt"))
        try Data("new\n".utf8).write(to: work.appendingPathComponent("new.txt"))
        try Data("noise\n".utf8).write(to: work.appendingPathComponent("ignored.log"))
        let review = try await store.review(id)
        XCTAssertTrue(review.diff.contains("+reviewed")); XCTAssertTrue(review.diff.contains("new.txt")); XCTAssertFalse(review.diff.contains("ignored.log"))
        // Reviewing touches neither the task's index nor its files.
        let staged = try await CodingCommand.git(["diff", "--cached", "--name-only"], at: work)
        XCTAssertEqual(staged, "")
        await store.accept(id, review: review)
        XCTAssertEqual(store.task(id)?.status, .done, store.notice)
        XCTAssertEqual(try read("file.txt"), "reviewed\n"); XCTAssertEqual(try read("new.txt"), "new\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("ignored.log").path))
        let projectTree = try await CodingCommand.git(["rev-parse", "HEAD^{tree}"], at: folder)
        XCTAssertEqual(projectTree, review.tree)
        let status = try await CodingCommand.git(["status", "--porcelain"], at: work)
        XCTAssertEqual(status, "", "The worktree's index follows its accepted branch")
    }
    func testAcceptRefusesAfterAnyEditOrBranchMoveSinceReview() async throws {
        let (store, id, work) = try await makeTask()
        let file = work.appendingPathComponent("file.txt")
        try Data("reviewed\n".utf8).write(to: file)
        let review = try await store.review(id)
        // A new file after review is refused, and nothing reaches the project.
        try Data("sneaky\n".utf8).write(to: work.appendingPathComponent("late.txt"))
        await store.accept(id, review: review)
        XCTAssertNotEqual(store.task(id)?.status, .done); XCTAssertEqual(try read("file.txt"), "initial\n")
        try FileManager.default.removeItem(at: work.appendingPathComponent("late.txt"))
        // The agent committing the same content moves the branch: the diff text against the base
        // would be identical, but the reviewed head no longer is, so it must be reviewed again.
        _ = try await CodingCommand.git(["commit", "-am", "agent commit"], at: work)
        let again = try await store.review(id)
        XCTAssertEqual(again.diff, review.diff); XCTAssertNotEqual(again.head, review.head)
        await store.accept(id, review: review)
        XCTAssertNotEqual(store.task(id)?.status, .done); XCTAssertEqual(try read("file.txt"), "initial\n")
        XCTAssertTrue(store.task(id)?.events.last?.detail.contains("moved since review") == true)
        await store.accept(id, review: again)
        XCTAssertEqual(store.task(id)?.status, .done, store.notice); XCTAssertEqual(try read("file.txt"), "reviewed\n")
    }
    func testCheckResultsCountOnlyForTheTreeTheyRanOn() async throws {
        let (store, id, work) = try await makeTask()
        try Data("first\n".utf8).write(to: work.appendingPathComponent("file.txt"))
        await store.check(id, command: "test -f file.txt")
        let first = try await store.review(id)
        XCTAssertEqual(store.checks(for: first).map(\.status), ["passed"])
        XCTAssertEqual(store.checks(for: first).first?.tree, first.tree)
        // Newer edits: the old pass doesn't vouch for them.
        try Data("second\n".utf8).write(to: work.appendingPathComponent("file.txt"))
        let second = try await store.review(id)
        XCTAssertTrue(store.checks(for: second).isEmpty)
        // A check that changes files vouches for no version at all.
        await store.check(id, command: "echo formatted >> file.txt")
        let changing = try XCTUnwrap(store.task(id)?.events.last { $0.kind == .check })
        XCTAssertEqual(changing.status, "passed"); XCTAssertNil(changing.tree)
        let third = try await store.review(id)
        XCTAssertTrue(store.checks(for: third).isEmpty)
        // The accept record names the reviewed tree and the checks that ran on it.
        await store.check(id, command: "true")
        let fourth = try await store.review(id)
        XCTAssertEqual(third.tree, fourth.tree); XCTAssertEqual(store.checks(for: fourth).count, 1)
        await store.accept(id, review: fourth)
        XCTAssertEqual(store.task(id)?.status, .done, store.notice)
        let accepted = try XCTUnwrap(store.task(id)?.events.last)
        XCTAssertTrue(accepted.detail.contains(fourth.tree)); XCTAssertTrue(accepted.detail.contains("Checks passed on this version: true"))
    }
}

/// Account lifecycle: a sign-out or another account stops agents, drops their late reports,
/// and swaps in that account's own tasks and drafts.
@MainActor final class CodingAccountLifecycleTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("CodingAccountTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let folder { try? FileManager.default.removeItem(at: folder) } }

    func testAccountSwitchStopsAgentsIgnoresLateCallbacksAndLoadsTheOtherAccount() async throws {
        let base = folder.appendingPathComponent("Base", isDirectory: true)
        let work = folder.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let alice = AccountIdentity(id: "local-alice", kind: .local), bob = AccountIdentity(id: "local-bob", kind: .local)
        var bobTask = CodingTaskRecord(projectID: UUID(), ownerID: bob.id, title: "Bob's task", provider: .claude, model: "", access: .edit, projectPath: work.path, directory: work.path, isolated: false)
        bobTask.status = .review
        try CodingStorage.forAccount(bob, base: base).save([bobTask])

        var made: [FakeCodingSession] = []
        let store = CodingWorkspaceStore(storage: .forAccount(alice, base: base), sessionFactory: { _ in let session = FakeCodingSession(); made.append(session); return session })
        let created = await store.create(project: DesktopProject(name: "Fixture", bookmark: Data()), root: work, provider: .codex, model: "", access: .edit, isolated: false, prompt: "Alice's work")
        let id = try XCTUnwrap(created), old = try XCTUnwrap(made.first)
        old.onApproval?(.init(id: "request-1", title: "Run tests", detail: ""))
        XCTAssertEqual(store.task(id)?.status, .working); XCTAssertNotNil(store.approvals[id])
        store.selected = id

        store.follow(bob, base: base)
        XCTAssertEqual(old.stops, 1, "The old account's agent process is stopped")
        XCTAssertEqual(store.accountID, bob.id)
        XCTAssertEqual(store.tasks.map(\.id), [bobTask.id]); XCTAssertNil(store.selected); XCTAssertTrue(store.approvals.isEmpty)
        XCTAssertEqual(store.draftsFolder, CodingStorage.forAccount(bob, base: base).directory.appendingPathComponent("Drafts", isDirectory: true))
        let aliceURL = CodingStorage.forAccount(alice, base: base).url
        let aliceSaved = try CodingStorage.forAccount(alice, base: base).read()
        XCTAssertEqual(aliceSaved.first?.status, .interrupted, "The stop is recorded in the old account's task")
        let aliceBytes = try Data(contentsOf: aliceURL), bobBytes = try Data(contentsOf: CodingStorage.forAccount(bob, base: base).url)

        // Whatever the old session still reports lands nowhere.
        old.onEvent?(.init(kind: .assistant, text: "late reply"), false)
        old.onState?(.review); old.onSession?("late-thread"); old.onApproval?(.init(id: "request-2", title: "Late", detail: ""))
        XCTAssertTrue(store.approvals.isEmpty)
        XCTAssertEqual(store.tasks.map(\.id), [bobTask.id]); XCTAssertEqual(store.tasks[0].status, .review)
        XCTAssertFalse(store.tasks[0].events.contains { $0.text == "late reply" })
        XCTAssertEqual(try Data(contentsOf: aliceURL), aliceBytes); XCTAssertEqual(try Data(contentsOf: CodingStorage.forAccount(bob, base: base).url), bobBytes)

        // Signed out: nothing is shown, created, or kept.
        store.follow(nil)
        XCTAssertFalse(store.signedIn); XCTAssertTrue(store.tasks.isEmpty); XCTAssertNil(store.draftsFolder)
        let refused = await store.create(project: DesktopProject(name: "Fixture", bookmark: Data()), root: work, provider: .codex, model: "", access: .edit, isolated: false, prompt: "While signed out")
        XCTAssertNil(refused)

        // Back to Alice: her task is there, interrupted, and a new message gets a new session.
        store.follow(alice, base: base)
        XCTAssertEqual(store.task(id)?.status, .interrupted)
        store.send(id, "Resume")
        XCTAssertEqual(made.count, 2); XCTAssertEqual(made[1].sent, ["Resume"]); XCTAssertEqual(store.task(id)?.status, .working)
        store.stopAll()
    }
    func testEditorDraftsBelongToTheAccountThatWroteThem() throws {
        let aliceDrafts = folder.appendingPathComponent("alice/Drafts"), bobDrafts = folder.appendingPathComponent("bob/Drafts")
        try CodingEditorDraft(text: "mine", original: "file").save(folder: aliceDrafts, root: folder, path: "a.swift")
        XCTAssertEqual(try CodingEditorDraft.load(folder: aliceDrafts, root: folder, path: "a.swift")?.text, "mine")
        XCTAssertNil(try CodingEditorDraft.load(folder: bobDrafts, root: folder, path: "a.swift"))
        XCTAssertNil(try CodingEditorDraft.load(folder: nil, root: folder, path: "a.swift"), "Signed out reads no drafts")
        XCTAssertThrowsError(try CodingEditorDraft(text: "x", original: "y").save(folder: nil, root: folder, path: "a.swift"))
    }
}

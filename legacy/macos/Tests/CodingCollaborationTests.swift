import XCTest
@testable import KemoSabeMac

/// Collaborative agents: the lead's plan (parsing, strict validation, the one-task fallback),
/// dependency scheduling, overlaps from real diffs down to functions, handoffs, merging in
/// dependency order with conflict detection and resolution, tests, Accept, messages, and the
/// shared board's sync records. Agents are fakes and repositories are temporary.
@MainActor final class CodingCollaborationTests: XCTestCase {
    private var folder: URL!
    private var repo: URL!
    private var sessions: [CollabFakeSession] = []
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("Collaboration-" + UUID().uuidString)
        repo = folder.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        sessions = []
    }
    override func tearDownWithError() throws { if let folder { try? FileManager.default.removeItem(at: folder) } }

    // MARK: Plans

    private let validReply = """
    I'll split this into an API change and the screen that uses it.

    ```json
    {"version": 1, "summary": "API first, then the screen.",
     "subtasks": [
      {"id": "api", "title": "Add the endpoint", "brief": "Add GET /status.", "files": ["src/api.ts", "./src/types/"], "areas": ["server"], "depends_on": [], "agent": "codex"},
      {"id": "ui", "title": "Show the status", "brief": "Render it.", "files": ["src/ui.tsx"], "depends_on": ["api"], "agent": "Claude Code"}
     ]}
    ```
    """
    func testPlanParsesTheLastFencedBlockAndNormalizesPaths() throws {
        let plan = try OrchestratorPlanner.parse("```json\n{\"subtasks\": []}\n```\n" + validReply)
        XCTAssertEqual(plan.subtasks.map(\.id), ["api", "ui"])
        XCTAssertEqual(plan.subtasks[0].files, ["src/api.ts", "src/types"])
        XCTAssertEqual(plan.subtasks[1].agent, .claude)
        XCTAssertEqual(plan.subtasks[1].dependsOn, ["api"])
        XCTAssertEqual(plan.summary, "API first, then the screen.")
    }
    func testPlanValidationIsStrict() {
        func reply(_ body: String) -> String { "```json\n" + body + "\n```" }
        let one = #"{"id": "a", "title": "T", "brief": "B", "agent": "codex"}"#
        let cases: [(String, OrchestratorPlanError)] = [
            ("No plan here.", .noPlan),
            (reply(#"{"version": 1, "subtasks": [ "#), .notJSON),
            (reply(#"{"version": 2, "subtasks": [\#(one)]}"#), .version),
            (reply(#"{"version": true, "subtasks": [\#(one)]}"#), .version),
            (reply(#"{"version": 1, "subtasks": [\#(one)], "extra": 1}"#), .unknownKey("extra")),
            (reply(#"{"version": 1, "subtasks": [{"id": "a", "title": "T", "brief": "B"}]}"#), .missing("agent")),
            (reply(#"{"version": 1, "subtasks": [{"id": "a", "title": "T", "brief": "B", "agent": "gemini"}]}"#), .unknownAgent("gemini")),
            (reply(#"{"version": 1, "subtasks": [{"id": "a", "title": "T", "brief": "B", "agent": "codex", "priority": 1}]}"#), .unknownKey("priority")),
            (reply(#"{"version": 1, "subtasks": []}"#), .count(0)),
            (reply(#"{"version": 1, "subtasks": [\#(one), \#(one)]}"#), .duplicateID("a")),
            (reply(#"{"version": 1, "subtasks": [{"id": "A b", "title": "T", "brief": "B", "agent": "codex"}]}"#), .badID("A b")),
            (reply(#"{"version": 1, "subtasks": [{"id": "a", "title": "T", "brief": "B", "agent": "codex", "files": ["../secret"]}]}"#), .badPath("../secret")),
            (reply(#"{"version": 1, "subtasks": [{"id": "a", "title": "T", "brief": "B", "agent": "codex", "files": ["/etc/hosts"]}]}"#), .badPath("/etc/hosts")),
            (reply(#"{"version": 1, "subtasks": [{"id": "a", "title": "T", "brief": "B", "agent": "codex", "files": "src"}]}"#), .wrongType("files")),
            (reply(#"{"version": 1, "subtasks": [{"id": "a", "title": "T", "brief": "B", "agent": "codex", "depends_on": ["z"]}]}"#), .unknownDependency("a", "z")),
            (reply(#"{"version": 1, "subtasks": [{"id": "a", "title": "T", "brief": "B", "agent": "codex", "depends_on": ["b"]}, {"id": "b", "title": "T", "brief": "B", "agent": "codex", "depends_on": ["a"]}]}"#), .cycle(["a", "b", "a"])),
            (reply(#"{"version": 1, "subtasks": [{"id": "a", "title": "", "brief": "B", "agent": "codex"}]}"#), .badText("title"))
        ]
        for (text, expected) in cases {
            XCTAssertThrowsError(try OrchestratorPlanner.parse(text), text) { XCTAssertEqual($0 as? OrchestratorPlanError, expected, text) }
        }
        let nine = (1...9).map { #"{"id": "s\#($0)", "title": "T", "brief": "B", "agent": "codex"}"# }.joined(separator: ",")
        XCTAssertThrowsError(try OrchestratorPlanner.parse(reply(#"{"version": 1, "subtasks": [\#(nine)]}"#))) { XCTAssertEqual($0 as? OrchestratorPlanError, .count(9)) }
    }
    func testUnreadablePlanFallsBackToOneTaskWithTheReason() {
        let (plan, note) = OrchestratorPlanner.plan(from: "Sure! Here's my plan: do it all at once.", goal: "Fix the login bug\nIt fails on Safari.", lead: .claude)
        XCTAssertEqual(plan.subtasks.count, 1)
        XCTAssertEqual(plan.subtasks[0].title, "Fix the login bug")
        XCTAssertEqual(plan.subtasks[0].brief, "Fix the login bug\nIt fails on Safari.")
        XCTAssertEqual(plan.subtasks[0].agent, .claude)
        XCTAssertEqual(note, OrchestratorPlanError.noPlan.errorDescription)
        XCTAssertNoThrow(try OrchestratorPlanner.validate(plan))
        XCTAssertNil(OrchestratorPlanner.plan(from: validReply, goal: "x", lead: .codex).1)
    }

    // MARK: Scheduling

    private func subtask(_ id: String, after: [String] = []) -> OrchestratorSubtask { .init(id: id, title: id, brief: id, dependsOn: after, agent: .codex) }
    func testSchedulingRespectsDependenciesAndTheLimit() {
        let plan = [subtask("ui", after: ["api", "db"]), subtask("api", after: ["db"]), subtask("db"), subtask("docs"), subtask("lint")]
        XCTAssertEqual(OrchestratorSchedule.order(plan), ["db", "api", "ui", "docs", "lint"])
        XCTAssertEqual(OrchestratorSchedule.ready(plan, states: [:], limit: 4), ["db", "docs", "lint"])
        XCTAssertEqual(OrchestratorSchedule.ready(plan, states: [:], limit: 2), ["db", "docs"])
        XCTAssertEqual(OrchestratorSchedule.ready(plan, states: ["db": .running, "docs": .running], limit: 3), ["lint"])
        XCTAssertEqual(OrchestratorSchedule.ready(plan, states: ["db": .finished, "docs": .running, "lint": .finished]), ["api"])
        XCTAssertEqual(OrchestratorSchedule.ready(plan, states: ["db": .finished, "api": .finished, "docs": .finished, "lint": .finished]), ["ui"])
        // A failed dependency blocks what waits on it, directly or not.
        XCTAssertEqual(OrchestratorSchedule.blocked(plan, states: ["db": .failed]), ["api", "ui"])
        XCTAssertEqual(OrchestratorSchedule.ready(plan, states: ["db": .failed, "docs": .finished, "lint": .finished]), [])
        XCTAssertEqual(OrchestratorSchedule.cycle([subtask("a", after: ["b"]), subtask("b", after: ["c"]), subtask("c", after: ["a"])]), ["a", "b", "c", "a"])
    }

    // MARK: Git fixtures

    private func git(_ arguments: [String], at directory: URL? = nil) async throws {
        _ = try await CodingCommand.git(arguments, at: directory ?? repo)
    }
    private func write(_ text: String, _ path: String, in directory: URL? = nil) throws {
        let url = (directory ?? repo).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    private func read(_ path: String, in directory: URL? = nil) throws -> String { try String(contentsOf: (directory ?? repo).appendingPathComponent(path), encoding: .utf8) }
    private func makeRepo(_ files: [String: String]) async throws {
        for arguments in [["init", "-b", "main"], ["config", "user.email", "fixture@example.invalid"], ["config", "user.name", "Fixture"], ["config", "commit.gpgsign", "false"]] { try await git(arguments) }
        for (path, text) in files { try write(text, path) }
        try await git(["add", "."]); try await git(["commit", "-m", "initial"])
    }
    private func makeStore() -> CodingWorkspaceStore {
        let store = CodingWorkspaceStore(storage: .init(directory: folder.appendingPathComponent("Coding", isDirectory: true), ownerID: "local-test"),
                                         sessionFactory: { [unowned self] record in let session = CollabFakeSession(title: record.title); sessions.append(session); return session },
                                         snapshotDelay: .seconds(3600))
        store.orchestrator.autoCoordinate = false
        return store
    }
    private func session(_ title: String) throws -> CollabFakeSession { try XCTUnwrap(sessions.last { $0.title == title }, "No session for \(title)") }
    private func until(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { XCTFail("Timed out waiting for \(what)"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    private func task(_ store: CodingWorkspaceStore, _ prompt: String, _ provider: CodingProvider) async throws -> UUID {
        let created = await store.create(project: project, root: repo, provider: provider, model: "", access: .edit, isolated: true, prompt: prompt)
        return try XCTUnwrap(created)
    }
    private func plan(_ orchestrator: CodingOrchestrator, goal: String, project: DesktopProject, root: URL, lead: CodingProvider, access: CodingAccess) async throws -> UUID {
        let created = await orchestrator.plan(goal: goal, project: project, root: root, lead: lead, access: access)
        return try XCTUnwrap(created)
    }
    private func directory(_ store: CodingWorkspaceStore, _ id: UUID?) throws -> URL { URL(fileURLWithPath: try XCTUnwrap(store.task(id)).directory) }
    private var project: DesktopProject { DesktopProject(id: UUID(uuidString: "00000000-0000-0000-0000-00000000C011")!, name: "Fixture", bookmark: Data()) }

    // MARK: Overlaps from diffs

    func testOverlapsFromRealDiffsAreFunctionLevelAndWarnedOnceInBothTasks() async throws {
        let source = """
        import Foundation

        struct Store {
            func save() {
                print("save")
            }
            func load() {
                print("load")
            }
        }
        """
        try await makeRepo(["Store.swift": source, "README.md": "hello\n"])
        let store = makeStore()
        let a = try await task(store, "A", .codex)
        let b = try await task(store, "B", .claude)
        // Different functions of one file: no overlap.
        try write(source.replacingOccurrences(of: "print(\"save\")", with: "print(\"saved\")"), "Store.swift", in: try directory(store, a))
        try write(source.replacingOccurrences(of: "print(\"load\")", with: "print(\"loaded\")"), "Store.swift", in: try directory(store, b))
        await store.orchestrator.coordinate()
        XCTAssertEqual(store.orchestrator.touches[a]?.map(\.symbol), ["Store.save"])
        XCTAssertEqual(store.orchestrator.touches[b]?.map(\.symbol), ["Store.load"])
        XCTAssertTrue(store.orchestrator.board(for: project.id).overlaps.isEmpty)
        // The same function: an overlap, noted in both tasks and the timeline, once.
        try write(source.replacingOccurrences(of: "print(\"load\")", with: "print(\"loaded\")").replacingOccurrences(of: "print(\"save\")", with: "print(\"stored\")"), "Store.swift", in: try directory(store, b))
        await store.orchestrator.coordinate()
        let overlaps = store.orchestrator.board(for: project.id).overlaps
        XCTAssertEqual(overlaps.map(\.symbol), ["Store.save"])
        XCTAssertEqual(Set(overlaps[0].tasks.map(\.id)), [a.uuidString, b.uuidString])
        await store.orchestrator.coordinate()
        for id in [a, b] {
            let notes = store.task(id)?.events.filter { $0.kind == .collaboration && $0.text.hasPrefix("Overlap") } ?? []
            XCTAssertEqual(notes.count, 1, "Warned once per task")
            XCTAssertTrue(notes[0].text.contains("Store.swift (Store.save)"))
        }
        XCTAssertEqual(store.orchestrator.timeline(project.id).filter { $0.kind == .overlap }.count, 1)
        XCTAssertTrue(sessions.allSatisfy { $0.sent.count == 1 }, "A warning never messages an agent by itself")
        // Handing it off records the owner and messages the other task (queued while it works).
        let overlap = try XCTUnwrap(store.orchestrator.board(for: project.id).overlaps.first)
        let owner = try XCTUnwrap(overlap.tasks.first { $0.id == a.uuidString })
        store.orchestrator.handOff(overlap, to: owner, project: project.id)
        XCTAssertTrue(store.orchestrator.board(for: project.id).overlaps.allSatisfy(\.resolved))
        XCTAssertEqual(store.orchestrator.queued(b).count, 1)
        try session(store.task(b)!.title).onState?(.review)
        try await until("the queued message to arrive") { (try? session(store.task(b)!.title).sent.count) == 2 }
        XCTAssertTrue(try session(store.task(b)!.title).sent[1].contains("now owns Store.swift (Store.save)"))
        XCTAssertTrue(store.orchestrator.queued(b).isEmpty)
    }
    func testTheLiveBoardHasTheTaskFilesClaimsAndThePersonsOwnEdits() async throws {
        try await makeRepo(["a.txt": "a\n", "b.txt": "b\n"])
        let store = makeStore()
        let a = try await task(store, "A", .codex)
        try write("A\n", "a.txt", in: try directory(store, a))
        try write("new\n", "notes/new.md", in: try directory(store, a))
        store.claim("b.txt", for: a)
        try write("mine\n", "a.txt")
        await store.orchestrator.coordinate()
        let board = store.orchestrator.board(for: project.id)
        let task = try XCTUnwrap(board.tasks.first { $0.id == a.uuidString })
        XCTAssertEqual(Set(task.files.map(\.path)), ["a.txt", "notes/new.md", "b.txt"])
        XCTAssertEqual(task.files.first { $0.path == "b.txt" }?.kind, .claimed)
        XCTAssertTrue(task.files.allSatisfy { !$0.path.hasPrefix("/") }, "Paths on the board are relative")
        let person = try XCTUnwrap(board.tasks.first { $0.agent == nil })
        XCTAssertEqual(person.files.map(\.path), ["a.txt"])
        XCTAssertEqual(board.overlaps.map(\.path), ["a.txt"], "The person's hand edits overlap the agent's")
    }
    func testReportedToolPathsAreMadeRelativeAndOutsidePathsDropped() {
        var task = CodingTaskRecord(projectID: UUID(), ownerID: "local-test", title: "T", provider: .claude, model: "", access: .edit, projectPath: "/p", directory: "/w/task", isolated: true)
        task.status = .working
        task.events = [
            .init(kind: .command, text: "Edit", detail: #"["file_path": "/w/old/before.swift"]"#),
            .init(kind: .user, text: "go"),
            .init(kind: .command, text: "Edit", detail: #"["file_path": "/w/task/Sources/App.swift", "old_string": "a"]"#),
            .init(kind: .command, text: "Write", detail: #"["file_path": "/etc/passwd"]"#),
            .init(kind: .file, text: "File changes", detail: "/w/task/README.md\nrelative/ok.txt\n../escape")
        ]
        XCTAssertEqual(CodingOrchestrator.reportedPaths(task), ["Sources/App.swift", "README.md", "relative/ok.txt"])
    }

    // MARK: A whole plan

    func testPlanHandsOffInDependencyOrderIntegratesTestsAndAccepts() async throws {
        try await makeRepo(["README.md": "hello\n"])
        let store = makeStore(); let orchestrator: CodingOrchestrator = store.orchestrator
        let runID = try await plan(orchestrator, goal: "Status page", project: project, root: repo, lead: .claude, access: .edit)
        XCTAssertEqual(orchestrator.run(runID)?.phase, .planning)
        let lead = try session("Plan: Status page")
        XCTAssertTrue(lead.sent[0].contains("```json"), "The lead is asked for the plan schema")
        XCTAssertEqual(store.task(orchestrator.run(runID)?.leadTask)?.access, .readOnly)
        lead.reply("""
        ```json
        {"version": 1, "summary": "API, then UI.", "subtasks": [
          {"id": "api", "title": "Add the API", "brief": "Write api.txt.", "files": ["api.txt"], "agent": "codex"},
          {"id": "ui", "title": "Add the UI", "brief": "Write ui.txt using api.txt.", "files": ["ui.txt"], "depends_on": ["api"], "agent": "claude"}
        ]}
        ```
        """)
        try await until("the plan") { orchestrator.run(runID)?.phase == .reviewing }
        XCTAssertNil(orchestrator.run(runID)?.planNote)
        XCTAssertEqual(orchestrator.run(runID)?.plan?.subtasks.map(\.id), ["api", "ui"])
        XCTAssertEqual(sessions.count, 1, "Nothing starts before the person does")

        await orchestrator.start(runID)
        let apiID = try XCTUnwrap(orchestrator.run(runID)?.tasks["api"])
        XCTAssertNil(orchestrator.run(runID)?.tasks["ui"], "The UI waits for the API")
        XCTAssertTrue(try session("Add the API").sent[0].contains("Add the UI (Claude Code): ui.txt"), "Each agent hears what the others are doing")
        try write("GET /status\n", "api.txt", in: try directory(store, apiID))
        try session("Add the API").reply("Added GET /status in api.txt.")
        try await until("the UI to start") { orchestrator.run(runID)?.tasks["ui"] != nil }
        let uiID = try XCTUnwrap(orchestrator.run(runID)?.tasks["ui"])
        // The dependent starts from the dependency's result, with its summary and notes.
        XCTAssertEqual(try read("api.txt", in: try directory(store, uiID)), "GET /status\n")
        let uiPrompt = try session("Add the UI").sent[0]
        XCTAssertTrue(uiPrompt.contains("api.txt (+1 −0)")); XCTAssertTrue(uiPrompt.contains("Added GET /status in api.txt."))
        XCTAssertTrue(store.task(uiID)?.events.contains { $0.kind == .collaboration && $0.text == "Starting from “Add the API”" } == true)
        XCTAssertEqual(orchestrator.timeline(project.id).filter { $0.kind == .handoff }.count, 1)
        try write("status: ok\n", "ui.txt", in: try directory(store, uiID))
        try session("Add the UI").reply("Shows the status.")
        try await until("every subtask to finish") { orchestrator.states(orchestrator.run(runID)!).values.allSatisfy { $0 == .finished } }

        try write("#!/bin/sh\ntest -f api.txt && test -f ui.txt\n", "check.sh")
        try await git(["add", "."]); try await git(["commit", "-m", "check script"])
        // The project moved (a commit on main): integration starts from the plan's base, so Accept must refuse to fast-forward.
        await orchestrator.integrate(runID)
        var integration = try XCTUnwrap(orchestrator.run(runID)?.integration)
        XCTAssertEqual(integration.merged, ["api", "ui"])
        XCTAssertNil(integration.conflict)
        await orchestrator.runTests(runID, command: "test -f api.txt && test -f ui.txt")
        integration = try XCTUnwrap(orchestrator.run(runID)?.integration)
        XCTAssertEqual(integration.test?.passed, true); XCTAssertNotNil(integration.test?.tree)
        let review = try await orchestrator.reviewIntegration(runID)
        XCTAssertEqual(Set(CodingDiff.parse(review.diff).map(\.path)), ["api.txt", "ui.txt"])
        await orchestrator.accept(runID, review: review)
        XCTAssertNotEqual(orchestrator.run(runID)?.phase, .accepted, "main moved, so it can't fast-forward")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("api.txt").path))
        // Back to the plan's base: now Accept fast-forwards to exactly the reviewed tree.
        try await git(["reset", "--hard", "HEAD~1"])
        await orchestrator.accept(runID, review: review)
        XCTAssertEqual(orchestrator.run(runID)?.phase, .accepted, orchestrator.notice)
        XCTAssertEqual(try read("api.txt"), "GET /status\n"); XCTAssertEqual(try read("ui.txt"), "status: ok\n")
        XCTAssertEqual(store.task(apiID)?.status, .done); XCTAssertEqual(store.task(uiID)?.status, .done)
        // Everything survives a restart.
        let reopened = CodingWorkspaceStore(storage: .init(directory: folder.appendingPathComponent("Coding", isDirectory: true), ownerID: "local-test"))
        XCTAssertEqual(reopened.orchestrator.run(runID)?.phase, .accepted)
        XCTAssertFalse(reopened.orchestrator.timeline(project.id).isEmpty)
    }
    func testIntegrationFindsAConflictAndAnAgentResolvesIt() async throws {
        try await makeRepo(["shared.txt": "one\n"])
        let store = makeStore(); let orchestrator: CodingOrchestrator = store.orchestrator
        let runID = try await plan(orchestrator, goal: "Two edits", project: project, root: repo, lead: .codex, access: .edit)
        try session("Plan: Two edits").reply("""
        ```json
        {"version": 1, "subtasks": [
          {"id": "left", "title": "Left", "brief": "Edit shared.txt.", "files": ["shared.txt"], "agent": "codex"},
          {"id": "right", "title": "Right", "brief": "Edit shared.txt too.", "files": ["shared.txt"], "agent": "claude"}
        ]}
        ```
        """)
        try await until("the plan") { orchestrator.run(runID)?.phase == .reviewing }
        await orchestrator.start(runID)
        let left = try XCTUnwrap(orchestrator.run(runID)?.tasks["left"]), right = try XCTUnwrap(orchestrator.run(runID)?.tasks["right"])
        // The plan itself shows the collision before anyone writes a line.
        XCTAssertEqual(orchestrator.board(for: project.id).overlaps.map(\.path), ["shared.txt"])
        try write("left\n", "shared.txt", in: try directory(store, left)); try session("Left").reply("Left done.")
        try write("right\n", "shared.txt", in: try directory(store, right)); try session("Right").reply("Right done.")
        try await until("both to finish") { orchestrator.states(orchestrator.run(runID)!).values.allSatisfy { $0 == .finished } }
        await orchestrator.integrate(runID)
        var integration = try XCTUnwrap(orchestrator.run(runID)?.integration)
        XCTAssertEqual(integration.merged, ["left"])
        XCTAssertEqual(integration.conflict?.subtask, "right"); XCTAssertEqual(integration.conflict?.files, ["shared.txt"])
        let integrationFolder = URL(fileURLWithPath: integration.directory)
        XCTAssertEqual(try read("shared.txt", in: integrationFolder), "left\n", "A conflicting merge is aborted, not left half-done")

        await orchestrator.resolveConflict(runID, agent: .claude)
        let resolveID = try XCTUnwrap(orchestrator.run(runID)?.integration?.resolveTask)
        let resolveFolder = try directory(store, resolveID)
        XCTAssertTrue(try read("shared.txt", in: resolveFolder).contains("<<<<<<< "), "The resolver starts inside the open merge")
        try session("Resolve conflicts: Right").reply("Kept both.")
        await orchestrator.continueIntegration(runID)
        XCTAssertNotNil(orchestrator.run(runID)?.integration?.conflict, "Markers left in the file stop it")
        XCTAssertTrue(orchestrator.notice.contains("Conflict markers remain"))
        try write("left\nright\n", "shared.txt", in: resolveFolder)
        await orchestrator.continueIntegration(runID)
        integration = try XCTUnwrap(orchestrator.run(runID)?.integration)
        XCTAssertNil(integration.conflict); XCTAssertEqual(integration.merged, ["left", "right"])
        XCTAssertEqual(try read("shared.txt", in: integrationFolder), "left\nright\n")
        let parents = try await CodingCommand.git(["rev-list", "--parents", "-n", "1", "HEAD"], at: integrationFolder).split(separator: " ")
        XCTAssertEqual(parents.count, 3, "The resolution is the merge commit, with both sides as parents")
        XCTAssertEqual(store.task(resolveID)?.status, .done)
        let review = try await orchestrator.reviewIntegration(runID)
        await orchestrator.accept(runID, review: review)
        XCTAssertEqual(try read("shared.txt"), "left\nright\n")
    }
    func testASecondDependencyIsCombinedIntoTheStartingPoint() async throws {
        try await makeRepo(["base.txt": "base\n"])
        let store = makeStore()
        let a = try await task(store, "A", .codex)
        let b = try await task(store, "B", .codex)
        try write("a\n", "a.txt", in: try directory(store, a)); try write("b\n", "b.txt", in: try directory(store, b))
        let ca = try await CodingIntegration.checkpoint(try directory(store, a), message: "a")
        let cb = try await CodingIntegration.checkpoint(try directory(store, b), message: "b")
        let (combined, conflicts) = try await CodingIntegration.combine([ca, cb], at: repo)
        XCTAssertTrue(conflicts.isEmpty)
        let files = try await CodingCommand.git(["ls-tree", "--name-only", combined], at: repo)
        XCTAssertEqual(files.split(separator: "\n"), ["a.txt", "b.txt", "base.txt"])
        // A conflicting one is left out and named.
        let c = try await task(store, "C", .codex)
        try write("c\n", "a.txt", in: try directory(store, c))
        let cc = try await CodingIntegration.checkpoint(try directory(store, c), message: "c")
        let (kept, clash) = try await CodingIntegration.combine([ca, cc], at: repo)
        XCTAssertEqual(kept, ca); XCTAssertEqual(clash, ["a.txt"])
    }
    func testAMessageToAnIdleAgentIsSentAndARunningOneWaits() async throws {
        try await makeRepo(["x.txt": "x\n"])
        let store = makeStore()
        let id = try await task(store, "Work", .codex)
        store.orchestrator.message(id, "Please also update the docs.")
        XCTAssertEqual(try session("Work").sent.count, 1, "It's working, so the message waits")
        XCTAssertTrue(store.task(id)?.events.contains { $0.kind == .collaboration && $0.text == "Message waiting for this turn to end" } == true)
        try session("Work").reply("Done.")
        try await until("delivery") { (try? session("Work").sent.count) == 2 }
        XCTAssertEqual(try session("Work").sent[1], "Please also update the docs.")
        XCTAssertEqual(store.task(id)?.events.last { $0.kind == .user }?.text, "Please also update the docs.", "It shows in the conversation as the person's message")
    }
    func testTestCommandDetection() throws {
        XCTAssertNil(CodingIntegration.detectTestCommand(at: repo))
        try write(#"{"scripts": {"test": "echo \"Error: no test specified\" && exit 1"}}"#, "package.json")
        XCTAssertNil(CodingIntegration.detectTestCommand(at: repo))
        try write(#"{"scripts": {"test": "vitest"}}"#, "package.json")
        XCTAssertEqual(CodingIntegration.detectTestCommand(at: repo), "npm test")
        try write("", "pnpm-lock.yaml")
        XCTAssertEqual(CodingIntegration.detectTestCommand(at: repo), "pnpm test")
        try write("// swift-tools-version:5.9\n", "Package.swift")
        XCTAssertEqual(CodingIntegration.detectTestCommand(at: repo), "swift test")
        try write("build:\n\tcc x.c\ntest: build\n\t./x\n", "Makefile")
        XCTAssertEqual(CodingIntegration.detectTestCommand(at: repo), "make test")
    }

    // MARK: Sharing

    func testTheSharedBoardRoundTripsThroughSyncWithRelativePathsOnly() async throws {
        try await makeRepo(["Store.swift": "struct Store {\n    func save() {\n    }\n}\n"])
        let store = makeStore()
        let id = try await task(store, "Save faster", .codex)
        try write("struct Store {\n    func save() {\n        fast()\n    }\n}\n", "Store.swift", in: try directory(store, id))
        await store.orchestrator.coordinate()
        let transport = MemorySyncTransport()
        let mine = SyncEngine(transport: transport, device: "mac-a"), theirs = SyncEngine(transport: transport, device: "mac-b")
        let shared = try XCTUnwrap(CollabProject.id(remote: "git@github.com:zach/kemosabe.git"))
        store.orchestrator.attach(CollabShare(engine: mine, project: shared, me: "local-test"), to: project.id)
        store.orchestrator.message(id, "Keep it small.")
        await store.orchestrator.publishShared()
        XCTAssertTrue(mine.state.outbox.isEmpty, "Synced")
        XCTAssertTrue(mine.state.records.values.allSatisfy { $0.zone == .shared(project: shared) && SyncType.shareable.contains($0.type) })
        try await theirs.sync()
        let seen = CollabShare(engine: theirs, project: shared, me: "someone-else").others()
        let task = try XCTUnwrap(seen.tasks.first { $0.id == id.uuidString })
        XCTAssertEqual(task.agent, "Codex"); XCTAssertEqual(task.project, shared)
        XCTAssertEqual(task.files.map(\.path), ["Store.swift"]); XCTAssertEqual(task.files.map(\.symbol), ["Store.save"])
        XCTAssertEqual(seen.presence.map(\.person), ["local-test"])
        XCTAssertTrue(seen.messages.contains { $0.text == "Keep it small." })
        let payloads = mine.state.records.values.map { String(decoding: $0.payload, as: UTF8.self) }
        XCTAssertFalse(payloads.contains { $0.contains(folder.path) || $0.contains(repo.path) }, "No absolute paths leave the Mac")
        // Nothing changed: nothing is written again.
        // (Presence is refreshed each minute, so a minute boundary may rewrite it.)
        let before = mine.state.records.filter { $0.value.type != SyncType.collabPresence }
        await store.orchestrator.publishShared()
        XCTAssertEqual(mine.state.records.filter { $0.value.type != SyncType.collabPresence }, before)
    }
}

/// A fake agent: records what it's sent and replies when the test says so.
@MainActor final class CollabFakeSession: AgentSession {
    var onEvent: ((CodingEvent, Bool) -> Void)?
    var onState: ((CodingTaskStatus) -> Void)?
    var onSession: ((String) -> Void)?
    var onApproval: ((CodingApproval?) -> Void)?
    let title: String
    var sent: [String] = []
    init(title: String) { self.title = title }
    func send(_ text: String) throws { sent.append(text); onState?(.working) }
    func respond(_ id: String, allow: Bool, answers: String) throws {}
    func stop() {}
    /// The agent's final message, then its turn ends ready for review.
    func reply(_ text: String) {
        onEvent?(.init(kind: .assistant, text: text), false)
        onState?(.review)
    }
}

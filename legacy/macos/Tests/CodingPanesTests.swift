import XCTest
@testable import KemoSabeMac

/// The pure parts of a task's panes: layout toggling, diff parsing (including untracked files in a
/// real review), dev-server detection, browser address rules, simctl parsing, simulator builds,
/// the Claude Code flags, and archiving.
@MainActor final class CodingPanesTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("CodingPanes-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let folder { try? FileManager.default.removeItem(at: folder) } }

    // MARK: Panes

    func testOneSidePaneAtATimeAndTheTerminalToggleOnItsOwn() {
        var state = CodingPaneState()
        XCTAssertEqual(state.side, .changes, "Changes is open by default")
        XCTAssertFalse(state.terminal)
        state.toggle(.browser)
        XCTAssertEqual(state.side, .browser, "Opening another side pane replaces the open one")
        XCTAssertFalse(state.isOpen(.changes))
        state.toggleTerminal()
        XCTAssertTrue(state.terminal); XCTAssertEqual(state.side, .browser, "The terminal doesn't close the side pane")
        state.toggle(.browser)
        XCTAssertNil(state.side, "A pane's own button closes it")
        state.toggle(.device); XCTAssertEqual(state.side, .device)
        state.toggleTerminal(); XCTAssertFalse(state.terminal)
        XCTAssertEqual(CodingPane.allCases.map(\.symbol), ["plus.forwardslash.minus", "globe", "iphone"])
    }

    // MARK: Diff

    func testDiffParsesFilesHunksCountsAndLineNumbers() {
        let diff = """
        diff --git a/Sources/App.swift b/Sources/App.swift
        index 1111111111111111111111111111111111111111..2222222222222222222222222222222222222222 100644
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -1,4 +1,5 @@ struct App
         import SwiftUI
        -let old = 1
        +let new = 2
        +let more = 3
         struct App {}
        -- a removed line that looks like a header
        @@ -20,2 +21,2 @@
         context
        -before
        +after
        \\ No newline at end of file
        diff --git a/notes/new file.md b/notes/new file.md
        new file mode 100644
        index 0000000000000000000000000000000000000000..3333333333333333333333333333333333333333
        --- /dev/null
        +++ b/notes/new file.md
        @@ -0,0 +1,2 @@
        +# Title
        +Body
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        index 4444444444444444444444444444444444444444..0000000000000000000000000000000000000000
        --- a/gone.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -bye
        """
        let files = CodingDiff.parse(diff)
        XCTAssertEqual(files.map(\.path), ["Sources/App.swift", "notes/new file.md", "gone.txt"])
        let app = files[0]
        XCTAssertEqual(app.change, .modified); XCTAssertNil(app.oldPath)
        XCTAssertEqual(app.hunks.count, 2)
        XCTAssertEqual(app.additions, 3); XCTAssertEqual(app.deletions, 3)
        XCTAssertEqual(app.hunks[0].lines.last, .init(kind: .removed, text: "- a removed line that looks like a header", old: 4, new: nil),
                       "A removed line starting with -- stays a line, not a header")
        XCTAssertEqual(app.hunks[0].lines[2], .init(kind: .added, text: "let new = 2", old: nil, new: 2))
        XCTAssertEqual(app.hunks[1].oldStart, 20); XCTAssertEqual(app.hunks[1].newStart, 21)
        XCTAssertEqual(app.hunks[1].lines.last?.kind, .note)
        XCTAssertEqual(files[1].change, .added); XCTAssertEqual(files[1].additions, 2); XCTAssertEqual(files[1].deletions, 0)
        XCTAssertEqual(files[2].change, .deleted); XCTAssertEqual(files[2].path, "gone.txt"); XCTAssertEqual(files[2].deletions, 1)
    }

    func testDiffHandlesRenamesQuotedPathsAndBinaryPatches() {
        let diff = """
        diff --git a/old name.txt b/new name.txt
        similarity index 90%
        rename from old name.txt
        rename to new name.txt
        index 5555555..6666666 100644
        --- a/old name.txt
        +++ b/new name.txt
        @@ -1 +1 @@
        -one
        +two
        diff --git "a/caf\\303\\251.txt" "b/caf\\303\\251.txt"
        index 7777777..8888888 100644
        --- "a/caf\\303\\251.txt"
        +++ "b/caf\\303\\251.txt"
        @@ -1 +1,2 @@
         a
        +b
        diff --git a/logo.png b/logo.png
        new file mode 100644
        index 0000000..9999999
        GIT binary patch
        literal 12
        TcmZ?wbhEHbWMp7qU|<0N
        +++ b/looks-like-a-header-inside-binary-data
        literal 0
        HcmV?d00001

        diff --git a/after.txt b/after.txt
        index 1234567..7654321 100644
        --- a/after.txt
        +++ b/after.txt
        @@ -1 +1 @@
        -x
        +y
        """
        let files = CodingDiff.parse(diff)
        XCTAssertEqual(files.map(\.path), ["new name.txt", "café.txt", "logo.png", "after.txt"])
        XCTAssertEqual(files[0].change, .renamed); XCTAssertEqual(files[0].oldPath, "old name.txt")
        XCTAssertEqual(files[1].additions, 1)
        XCTAssertTrue(files[2].binary); XCTAssertEqual(files[2].change, .added); XCTAssertTrue(files[2].hunks.isEmpty, "Binary data isn't read as lines")
        XCTAssertEqual(files[3].additions, 1); XCTAssertEqual(files[3].deletions, 1)
        XCTAssertEqual(CodingDiff.unquote(#""tab\there""#), "tab\there")
    }

    func testSplitRowsPairRemovedWithAddedLines() {
        let hunk = CodingDiffHunk(id: 0, header: "@@", lines: [
            .init(kind: .context, text: "a", old: 1, new: 1),
            .init(kind: .removed, text: "b", old: 2, new: nil),
            .init(kind: .removed, text: "c", old: 3, new: nil),
            .init(kind: .added, text: "B", old: nil, new: 2),
            .init(kind: .context, text: "d", old: 4, new: 3),
            .init(kind: .added, text: "e", old: nil, new: 4)
        ])
        let rows = hunk.rows
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows[0].left?.text, "a"); XCTAssertEqual(rows[0].right?.text, "a")
        XCTAssertEqual(rows[1].left?.text, "b"); XCTAssertEqual(rows[1].right?.text, "B")
        XCTAssertEqual(rows[2].left?.text, "c"); XCTAssertNil(rows[2].right, "An unmatched removal has nothing beside it")
        XCTAssertEqual(rows[4].left, nil); XCTAssertEqual(rows[4].right?.text, "e")
    }

    /// The Changes pane reads the store's review: modified tracked files and untracked new ones
    /// both appear, ignored files don't.
    func testReviewDiffIncludesUntrackedFiles() async throws {
        let repo = folder.appendingPathComponent("repo"), storage = folder.appendingPathComponent("storage")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        for arguments in [["init", "-b", "main"], ["config", "user.email", "fixture@example.invalid"], ["config", "user.name", "Fixture"], ["config", "commit.gpgsign", "false"]] {
            _ = try await CodingCommand.git(arguments, at: repo)
        }
        try Data("one\ntwo\n".utf8).write(to: repo.appendingPathComponent("tracked.txt"))
        try Data("*.log\n".utf8).write(to: repo.appendingPathComponent(".gitignore"))
        _ = try await CodingCommand.git(["add", "."], at: repo)
        _ = try await CodingCommand.git(["commit", "-m", "initial"], at: repo)
        let fake = PaneFakeSession()
        let store = CodingWorkspaceStore(storage: .init(directory: storage, ownerID: "local-test"), sessionFactory: { _ in fake })
        let created = await store.create(project: DesktopProject(name: "Fixture", bookmark: Data()), root: repo, provider: .codex, model: "", access: .edit, isolated: true, prompt: "Edit")
        let id = try XCTUnwrap(created)
        fake.onState?(.review)
        let work = URL(fileURLWithPath: try XCTUnwrap(store.task(id)).directory)
        try Data("one\n2\n".utf8).write(to: work.appendingPathComponent("tracked.txt"))
        try FileManager.default.createDirectory(at: work.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("print(1)\nprint(2)\n".utf8).write(to: work.appendingPathComponent("src/untracked.swift"))
        try Data("noise\n".utf8).write(to: work.appendingPathComponent("debug.log"))
        let files = CodingDiff.parse(try await store.review(id).diff)
        XCTAssertEqual(files.map(\.path), ["src/untracked.swift", "tracked.txt"])
        XCTAssertEqual(files[0].change, .added); XCTAssertEqual(files[0].additions, 2)
        XCTAssertEqual(files[1].change, .modified); XCTAssertEqual(files[1].additions, 1); XCTAssertEqual(files[1].deletions, 1)
    }

    // MARK: Browser

    func testDevServerURLsAreFoundInCommandAndTerminalOutput() {
        let vite = "\u{1B}[32m  ➜  \u{1B}[1mLocal\u{1B}[22m:   \u{1B}[36mhttp://localhost:\u{1B}[1m5173\u{1B}[22m/\u{1B}[39m\n  ➜  Network: use --host to expose"
        XCTAssertEqual(DevServerDetector.urls(in: vite).map(\.absoluteString), ["http://localhost:5173/"], "Colour codes inside the address are stripped")
        XCTAssertEqual(DevServerDetector.urls(in: "Uvicorn running on http://0.0.0.0:8000 (Press CTRL+C to quit)").first?.absoluteString, "http://localhost:8000/",
                       "Every-interface addresses open through localhost")
        XCTAssertEqual(DevServerDetector.urls(in: "Server listening on 127.0.0.1:3000.").first?.absoluteString, "http://127.0.0.1:3000/", "No scheme, trailing period")
        XCTAssertEqual(DevServerDetector.urls(in: "open https://localhost:8443/app/index.html, then").first?.absoluteString, "https://localhost:8443/app/index.html")
        XCTAssertEqual(DevServerDetector.urls(in: "ready on [::1]:4000").first?.absoluteString, "http://[::1]:4000/")
        XCTAssertTrue(DevServerDetector.urls(in: "mylocalhost:1234 example.com:80 http://192.168.1.4:3000 localhost:99999").isEmpty,
                      "Only loopback hosts on real ports count")
        XCTAssertEqual(DevServerDetector.latest(in: ["started localhost:3000", "restarted on localhost:3001\nnothing else", "no servers here"])?.absoluteString,
                       "http://localhost:3001/", "The most recent mention wins")
        XCTAssertNil(DevServerDetector.latest(in: ["npm test", ""]))
    }

    func testBrowserLoadsOnlyWebAddresses() {
        XCTAssertEqual(BrowserAddress.normalize("localhost:3000")?.absoluteString, "http://localhost:3000")
        XCTAssertEqual(BrowserAddress.normalize(" 127.0.0.1:8080/docs ")?.absoluteString, "http://127.0.0.1:8080/docs")
        XCTAssertEqual(BrowserAddress.normalize("[::1]:5000")?.absoluteString, "http://[::1]:5000")
        XCTAssertEqual(BrowserAddress.normalize("example.com/path")?.absoluteString, "https://example.com/path")
        XCTAssertEqual(BrowserAddress.normalize("http://example.com")?.absoluteString, "http://example.com")
        for refused in ["", "javascript:alert(1)", "file:///etc/passwd", "about:blank", "data:text/html,hi", "vscode://open", "localhost:", "two words", "://missing"] {
            XCTAssertNil(BrowserAddress.normalize(refused), refused)
        }
        let page = URL(string: "http://localhost:5173/")!
        XCTAssertFalse(BrowserAddress.isExternal(URL(string: "http://localhost:5173/about")!, from: page))
        XCTAssertFalse(BrowserAddress.isExternal(URL(string: "http://127.0.0.1:9000/api")!, from: page), "Other local servers stay in the pane")
        XCTAssertTrue(BrowserAddress.isExternal(URL(string: "https://github.com/x")!, from: page))
        XCTAssertFalse(BrowserAddress.isExternal(URL(string: "https://docs.example.com/b")!, from: URL(string: "https://docs.example.com/a")))
    }

    // MARK: Device

    func testSimctlDevicesAreParsedAndSorted() throws {
        let json = """
        {"devices": {
          "com.apple.CoreSimulator.SimRuntime.iOS-26-2": [
            {"udid": "A", "name": "iPhone 17", "state": "Shutdown", "isAvailable": true},
            {"udid": "B", "name": "iPad Air", "state": "Shutdown", "isAvailable": true},
            {"udid": "X", "name": "Broken", "state": "Shutdown", "isAvailable": false}
          ],
          "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
            {"udid": "C", "name": "iPhone 18", "state": "Shutdown", "isAvailable": true},
            {"udid": "D", "name": "iPhone SE", "state": "Booted", "isAvailable": true}
          ],
          "com.apple.CoreSimulator.SimRuntime.watchOS-27-0": [
            {"udid": "W", "name": "Apple Watch", "state": "Booted", "isAvailable": true}
          ],
          "com.apple.CoreSimulator.SimRuntime.iOS-18-6": []
        }}
        """
        let devices = try SimulatorList.parse(Data(json.utf8))
        XCTAssertEqual(devices.map(\.udid), ["D", "C", "B", "A"], "Booted first, then the newest runtime, then by name; watches and unavailable devices left out")
        XCTAssertEqual(devices.first?.runtime, "iOS 27.0"); XCTAssertTrue(devices[0].booted)
        XCTAssertEqual(devices.last?.runtime, "iOS 26.2")
        XCTAssertThrowsError(try SimulatorList.parse(Data("not json".utf8)))
        XCTAssertNil(SimulatorList.runtimeVersion("com.apple.CoreSimulator.SimRuntime.iOS"))
    }

    func testTheNewestSimulatorBuildOfThisProjectIsFound() throws {
        let derived = folder.appendingPathComponent("DerivedData"), project = folder.appendingPathComponent("Project")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("MyApp.xcodeproj"), withIntermediateDirectories: true)
        XCTAssertTrue(SimulatorBuilds.isAppleProject(project))
        XCTAssertFalse(SimulatorBuilds.isAppleProject(derived))
        XCTAssertEqual(SimulatorBuilds.projectNames(in: project), ["MyApp"])
        func app(_ path: String, bundle: String, age: TimeInterval) throws -> URL {
            let url = derived.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": bundle], format: .xml, options: 0)
            try plist.write(to: url.appendingPathComponent("Info.plist"))
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
            return url
        }
        _ = try app("MyApp-abc/Build/Products/Debug-iphonesimulator/MyApp.app", bundle: "com.example.old", age: 600)
        let newest = try app("MyApp-abc/Build/Products/Release-iphonesimulator/MyApp.app", bundle: "com.example.app", age: 10)
        _ = try app("MyApp-abc/Build/Products/Debug/MyApp.app", bundle: "com.example.mac", age: 0)
        _ = try app("Other-def/Build/Products/Debug-iphonesimulator/Other.app", bundle: "com.example.other", age: 0)
        let found = SimulatorBuilds.latestApp(projectNames: ["MyApp"], derivedData: derived)
        XCTAssertEqual(found?.standardizedFileURL, newest.standardizedFileURL, "Simulator builds of this project only, newest first")
        XCTAssertEqual(found.flatMap(SimulatorBuilds.bundleID), "com.example.app")
        XCTAssertNil(SimulatorBuilds.latestApp(projectNames: [], derivedData: derived))
    }

    // MARK: Claude Code flags

    func testClaudeCodeRoutesPermissionPromptsToTsukumo() {
        var task = CodingTaskRecord(projectID: UUID(), ownerID: "local-test", title: "T", provider: .claude, model: "", access: .edit, projectPath: folder.path, directory: folder.path, isolated: false)
        func value(_ args: [String], _ flag: String) -> String? { args.firstIndex(of: flag).map { args[$0 + 1] } }
        var args = CodingAgentSession.claudeArguments(for: task, resume: nil)
        XCTAssertEqual(value(args, "--permission-prompt-tool"), "stdio", "Prompts reach the app as can_use_tool control requests")
        XCTAssertEqual(value(args, "--permission-prompts"), "host")
        XCTAssertEqual(value(args, "--permission-mode"), "manual")
        XCTAssertEqual(value(args, "--input-format"), "stream-json"); XCTAssertEqual(value(args, "--output-format"), "stream-json")
        XCTAssertFalse(args.contains("--resume")); XCTAssertFalse(args.contains("--allow-dangerously-skip-permissions"))
        task.access = .readOnly; task.model = "sonnet"
        args = CodingAgentSession.claudeArguments(for: task, resume: "session-1")
        XCTAssertEqual(value(args, "--permission-mode"), "plan"); XCTAssertEqual(value(args, "--tools"), "Read,Grep,Glob")
        XCTAssertEqual(value(args, "--model"), "sonnet"); XCTAssertEqual(value(args, "--resume"), "session-1")
        task.access = .full
        args = CodingAgentSession.claudeArguments(for: task, resume: nil)
        XCTAssertEqual(value(args, "--permission-mode"), "bypassPermissions"); XCTAssertTrue(args.contains("--allow-dangerously-skip-permissions"))
    }

    // MARK: Archive

    func testArchiveStopsTheAgentHidesTheTaskAndKeepsItsWork() async throws {
        let work = folder.appendingPathComponent("work"), storage = CodingStorage(directory: folder.appendingPathComponent("Coding"), ownerID: "local-test")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let fake = PaneFakeSession()
        let store = CodingWorkspaceStore(storage: storage, sessionFactory: { _ in fake })
        let project = DesktopProject(name: "Fixture", bookmark: Data())
        let created = await store.create(project: project, root: work, provider: .codex, model: "", access: .edit, isolated: false, prompt: "Work")
        let id = try XCTUnwrap(created)
        XCTAssertEqual(store.task(id)?.status, .working)
        store.archive(id)
        XCTAssertEqual(fake.stops, 1, "A running agent is stopped first")
        XCTAssertNil(store.selected)
        XCTAssertTrue(store.forProject(project.id).isEmpty)
        XCTAssertEqual(store.forProject(project.id, archived: true).map(\.id), [id])
        XCTAssertEqual(CodingWorkspaceStore(storage: storage).forProject(project.id, archived: true).map(\.id), [id], "Archiving is saved")
        store.unarchive(id)
        XCTAssertEqual(store.forProject(project.id).map(\.id), [id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: work.path))
    }

    func testDeleteRemovesTheTaskItsWorktreeAndBranchButNotTheProject() async throws {
        let repo = folder.appendingPathComponent("repo"), storage = CodingStorage(directory: folder.appendingPathComponent("Coding"), ownerID: "local-test")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = try await CodingCommand.git(["init", "-q", "-b", "main"], at: repo)
        try "hi".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await CodingCommand.git(["add", "."], at: repo)
        _ = try await CodingCommand.git(["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-qm", "init"], at: repo)
        let fake = PaneFakeSession()
        let store = CodingWorkspaceStore(storage: storage, sessionFactory: { _ in fake })
        let project = DesktopProject(name: "Fixture", bookmark: Data())
        let created = await store.create(project: project, root: repo, provider: .codex, model: "", access: .edit, isolated: true, prompt: "u")
        let id = try XCTUnwrap(created)
        let worktree = try XCTUnwrap(store.task(id)?.directory), branch = try XCTUnwrap(store.task(id)?.branch)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree))
        XCTAssertEqual(store.orphans(keeping: []).map(\.id), [id], "A task whose project is gone is listed so it can be deleted")
        XCTAssertTrue(store.orphans(keeping: [project.id]).isEmpty)
        await store.delete(id)
        XCTAssertEqual(fake.stops, 1, "A running agent is stopped first")
        XCTAssertNil(store.task(id)); XCTAssertNil(store.selected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.logURL(id).path))
        let branches = try await CodingCommand.git(["branch", "--list", branch], at: repo)
        XCTAssertTrue(branches.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Tsukumo's branch for the task is deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent("a.txt").path), "The project folder is untouched")
        XCTAssertTrue(CodingWorkspaceStore(storage: storage).tasks.isEmpty, "Deleting is saved")
    }
}

@MainActor private final class PaneFakeSession: AgentSession {
    var onEvent: ((CodingEvent, Bool) -> Void)?
    var onState: ((CodingTaskStatus) -> Void)?
    var onSession: ((String) -> Void)?
    var onApproval: ((CodingApproval?) -> Void)?
    var stops = 0
    func send(_ text: String) throws { onState?(.working) }
    func respond(_ id: String, allow: Bool, answers: String) throws {}
    func stop() { stops += 1 }
}

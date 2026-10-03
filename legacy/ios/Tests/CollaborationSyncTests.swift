import XCTest
@testable import KemoSabe

/// The shared collaboration model: what a diff touches (files and the functions around changed
/// lines), relative paths only, a project's shared name from its Git remote, and the board's
/// records round-tripping through `SyncEngine` in a project's shared zone.
final class CollaborationSyncTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testDiffParsingPlacesAddedAndRemovedLines() {
        let diff = """
        diff --git a/src/app.ts b/src/app.ts
        index 1111111..2222222 100644
        --- a/src/app.ts
        +++ b/src/app.ts
        @@ -3 +3 @@ export class App {
        -    return 1
        +    return 2
        @@ -10,2 +9,0 @@ export class App {
        -  gone()
        -  gone()
        diff --git "a/docs/caf\\303\\251 notes.md" "b/docs/caf\\303\\251 notes.md"
        --- "a/docs/caf\\303\\251 notes.md"
        +++ "b/docs/caf\\303\\251 notes.md"
        @@ -0,0 +1,2 @@
        +# Notes
        +--- a line that looks like a header
        diff --git a/old.txt b/old.txt
        deleted file mode 100644
        --- a/old.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -bye
        diff --git a/logo.png b/logo.png
        Binary files a/logo.png and b/logo.png differ
        """
        let files = CollabDiff.parse(diff)
        XCTAssertEqual(files.map(\.path), ["src/app.ts", "docs/café notes.md", "old.txt", "logo.png"])
        XCTAssertEqual(files[0].added, [3]); XCTAssertEqual(files[0].removedAt, [3, 10, 10])
        XCTAssertEqual(files[1].added, [1, 2], "A content line starting with --- stays in its hunk")
        XCTAssertTrue(files[2].deleted); XCTAssertTrue(files[3].binary)
    }
    func testChangedLinesAreAttributedToTheirEnclosingDeclarations() {
        let swift = """
        import Foundation

        struct Store {
            var count = 0
            func save() {
                if true {
                    write()
                }
            }
        }
        extension Other {
            func save() {
                write()
            }
        }
        let top = 1
        """
        let lines = swift.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(CollabSymbols.enclosing(line: 7, in: lines, language: "swift"), "Store.save")
        XCTAssertEqual(CollabSymbols.enclosing(line: 13, in: lines, language: "swift"), "Other.save", "Same-named methods of two types stay apart")
        XCTAssertEqual(CollabSymbols.enclosing(line: 4, in: lines, language: "swift"), "Store")
        XCTAssertEqual(CollabSymbols.enclosing(line: 5, in: lines, language: "swift"), "Store.save")
        XCTAssertNil(CollabSymbols.enclosing(line: 16, in: lines, language: "swift"))
        let python = "class Cart:\n    def total(self):\n        return 1\n"
        XCTAssertEqual(CollabSymbols.enclosing(line: 3, in: python.split(separator: "\n", omittingEmptySubsequences: false), language: "py"), "Cart.total")
        let ts = "export class Api {\n  async fetchUser(id: string): Promise<User> {\n    return get(id)\n  }\n}\nexport const render = (x) => {\n  if (x) {\n    draw()\n  }\n}\n"
        let tsLines = ts.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(CollabSymbols.enclosing(line: 3, in: tsLines, language: "ts"), "Api.fetchUser")
        XCTAssertEqual(CollabSymbols.enclosing(line: 8, in: tsLines, language: "ts"), "render", "An if block isn't a method")
        XCTAssertEqual(CollabSymbols.declared("    var body: some View {", language: "swift"), "body")
        XCTAssertNil(CollabSymbols.declared("    Button(\"Save\") {", language: "swift"), "A trailing closure isn't a declaration in Swift")
    }
    func testTouchesFromADiffAreFunctionLevelWithAFileLevelFallback() {
        let text = "import A\n\nstruct S {\n    func a() {\n        one()\n    }\n    func b() {\n        two()\n    }\n}\nlet loose = 1\n"
        let diff = """
        diff --git a/S.swift b/S.swift
        --- a/S.swift
        +++ b/S.swift
        @@ -1,0 +2 @@
        +
        @@ -5 +5 @@
        -        old()
        +        one()
        @@ -8,0 +8 @@
        +        two()
        """
        let touches = CollabDiff.touches(diff: diff) { $0 == "S.swift" ? text : nil }
        XCTAssertEqual(touches.map(\.symbol), ["S.a", "S.b"], "A blank line doesn't make the change file-wide")
        XCTAssertEqual(touches.first { $0.symbol == "S.a" }.map { [$0.added, $0.removed] }, [1, 1])
        let loose = CollabDiff.touches(diff: "diff --git a/S.swift b/S.swift\n--- a/S.swift\n+++ b/S.swift\n@@ -11 +11 @@\n-let loose = 0\n+let loose = 1\n") { _ in text }
        XCTAssertEqual(loose.map(\.symbol), [nil], "A change outside every declaration touches the whole file")
        let unreadable = CollabDiff.touches(diff: diff) { _ in nil }
        XCTAssertEqual(unreadable.count, 1); XCTAssertNil(unreadable[0].symbol); XCTAssertEqual([unreadable[0].added, unreadable[0].removed], [3, 1])
        // Two tasks in different functions don't overlap; the file-wide one overlaps both.
        let board = CollabBoard(tasks: [
            .init(id: "a", project: "p", owner: "z", ownerName: "Z", agent: "Codex", title: "a", state: .working, files: [touches[0]], updated: now),
            .init(id: "b", project: "p", owner: "z", ownerName: "Z", agent: "Claude Code", title: "b", state: .working, files: [touches[1]], updated: now)
        ])
        XCTAssertTrue(board.overlaps.isEmpty)
        var wide = board; wide.tasks.append(.init(id: "c", project: "p", owner: "z", ownerName: "Z", agent: nil, title: "c", state: .working, files: loose, updated: now))
        XCTAssertEqual(wide.overlaps.count, 1); XCTAssertEqual(wide.overlaps[0].tasks.count, 3)
    }
    func testPathsStayInsideTheProject() {
        XCTAssertTrue(CollabPaths.valid("src/a.swift"))
        for bad in ["", "/etc/hosts", "../x", "a/../b", "a//b", "a\\b"] { XCTAssertFalse(CollabPaths.valid(bad), bad) }
        XCTAssertEqual(CollabPaths.relative("/w/task/src/a.swift", to: "/w/task"), "src/a.swift")
        XCTAssertNil(CollabPaths.relative("/w/other/a.swift", to: "/w/task"))
        XCTAssertNil(CollabPaths.relative("/w/task", to: "/w/task"))
    }
    func testAProjectsSharedNameComesFromItsRemote() {
        let forms = ["git@github.com:Zach/KemoSabe.git", "https://github.com/Zach/KemoSabe", "https://user@GitHub.com:443/Zach/KemoSabe.git/", "ssh://git@github.com/Zach/KemoSabe.git"]
        XCTAssertEqual(Set(forms.map(CollabProject.normalizedRemote)), ["github.com/Zach/KemoSabe"])
        XCTAssertEqual(Set(forms.map(CollabProject.id)).count, 1)
        XCTAssertEqual(CollabProject.id(remote: forms[0])?.count, 32)
        XCTAssertNotEqual(CollabProject.id(remote: "git@github.com:Zach/Other.git"), CollabProject.id(remote: forms[0]))
        XCTAssertNil(CollabProject.id(remote: "")); XCTAssertNil(CollabProject.id(remote: "not a remote"))
    }

    @MainActor func testTwoPeoplesBoardsMeetInTheSharedZone() async throws {
        let transport = MemorySyncTransport()
        let zach = CollabShare(engine: SyncEngine(transport: transport, device: "mac-z"), project: "p1", me: "zach")
        let maya = CollabShare(engine: SyncEngine(transport: transport, device: "mac-m"), project: "p1", me: "maya")
        let task = CollabTask(id: "t1", project: "p1", owner: "zach", ownerName: "Zach", agent: "Codex", title: "Presence", state: .working,
                              files: [.init(path: "src/presence.ts", kind: .changed, symbol: "update", added: 3), .init(path: "/Users/zach/secret", kind: .changed)], updated: now, plan: "r1", subtask: "api", dependsOn: [])
        let board = CollabBoard(tasks: [task, .init(id: "m1", project: "p1", owner: "maya", ownerName: "Maya", agent: "Codex", title: "Not mine", state: .working, updated: now)],
                                presence: [.init(person: "zach", name: "Zach", project: "p1", device: "mac-z", lastSeen: now)],
                                messages: [.init(id: "x", project: "p1", from: "zach", fromName: "Zach", to: "t1", text: "Hi", date: now, kind: .message)],
                                ownership: [.init(project: "p1", path: "src/presence.ts", task: "t1", decidedBy: "zach", date: now)])
        try zach.publish(board, at: now)
        XCTAssertEqual(zach.engine.state.outbox.count, 4, "Only Zach's own task, presence, message, and decision")
        try await zach.engine.sync(); try await maya.engine.sync()
        let seen = maya.others()
        XCTAssertEqual(seen.tasks.map(\.id), ["t1"])
        XCTAssertEqual(seen.tasks[0].files.map(\.path), ["src/presence.ts"], "Absolute paths never go into a shared zone")
        XCTAssertEqual(seen.tasks[0].subtask, "api")
        XCTAssertEqual(seen.presence.map(\.person), ["zach"]); XCTAssertEqual(seen.messages.map(\.text), ["Hi"]); XCTAssertEqual(seen.ownership.count, 1)
        // Unchanged: nothing queued. Gone: a tombstone reaches Maya.
        try zach.publish(board, at: now + 5)
        XCTAssertTrue(zach.engine.state.outbox.isEmpty)
        try zach.publish(CollabBoard(), at: now + 10)
        try await zach.engine.sync(); try await maya.engine.sync()
        XCTAssertTrue(maya.others().tasks.isEmpty)
        // Merging keeps this board's own copy and adds the others'.
        let mine = CollabBoard(tasks: [.init(id: "m2", project: "p1", owner: "maya", ownerName: "Maya", agent: nil, title: "By hand", state: .working, updated: now)])
        XCTAssertEqual(mine.merged(with: seen).tasks.map(\.id), ["m2", "t1"])
    }
    func testOlderRecordsWithoutTheNewFieldsStillDecode() throws {
        let old = #"{"id":"t","project":"p","owner":"o","ownerName":"O","title":"T","state":"working","files":[],"updated":0}"#
        let task = try JSONDecoder().decode(CollabTask.self, from: Data(old.utf8))
        XCTAssertNil(task.plan); XCTAssertNil(task.dependsOn)
        let message = try JSONDecoder().decode(CollabMessage.self, from: Data(#"{"id":"m","project":"p","from":"a","fromName":"A","to":"b","text":"x","date":0}"#.utf8))
        XCTAssertNil(message.kind)
        XCTAssertTrue(CollabState.paused.active)
    }
}

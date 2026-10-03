import XCTest
@testable import KemoSabe

final class AccountSyncTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    struct Note: Codable, Equatable { var text: String }

    @MainActor func testTwoDevicesConvergeThroughTheTransport() async throws {
        let transport = MemorySyncTransport()
        let mac = SyncEngine(transport: transport, device: "mac"), phone = SyncEngine(transport: transport, device: "phone")
        try mac.put(Note(text: "Prefers short replies"), id: "m1", type: SyncType.memory, zone: .personal, at: t0)
        try await mac.sync(); try await phone.sync()
        XCTAssertEqual(phone.values(SyncType.memory, in: .personal, as: Note.self), [Note(text: "Prefers short replies")])
        try phone.delete(id: "m1", type: SyncType.memory, zone: .personal, at: t0 + 5)
        try await phone.sync(); try await mac.sync()
        XCTAssertTrue(mac.values(SyncType.memory, in: .personal, as: Note.self).isEmpty)
    }
    @MainActor func testNewerEditWinsAndAnUnpushedNewerLocalEditSurvives() async throws {
        let transport = MemorySyncTransport()
        let mac = SyncEngine(transport: transport, device: "mac"), phone = SyncEngine(transport: transport, device: "phone")
        try phone.put(Note(text: "old"), id: "n", type: SyncType.memory, zone: .personal, at: t0)
        try await phone.sync()
        try mac.put(Note(text: "newer, not pushed yet"), id: "n", type: SyncType.memory, zone: .personal, at: t0 + 10)
        mac.merge(SyncRecord(id: "n", type: SyncType.memory, zone: .personal, modified: t0 + 1, device: "phone", payload: try JSONEncoder().encode(Note(text: "stale"))))
        XCTAssertEqual(mac.values(SyncType.memory, in: .personal, as: Note.self), [Note(text: "newer, not pushed yet")])
        XCTAssertEqual(mac.state.outbox.count, 1)
        try await mac.sync(); try await phone.sync()
        XCTAssertEqual(phone.values(SyncType.memory, in: .personal, as: Note.self), [Note(text: "newer, not pushed yet")])
    }
    @MainActor func testPrivateRecordsNeverEnterASharedZone() throws {
        let engine = SyncEngine(transport: MemorySyncTransport(), device: "mac")
        for type in [SyncType.conversation, SyncType.memory, SyncType.peopleNote, SyncType.companion] {
            XCTAssertThrowsError(try engine.put(Note(text: "x"), id: "x", type: type, zone: .shared(project: "p"))) { error in
                XCTAssertEqual(error as? SyncError, .privateInSharedZone(type))
            }
        }
        XCTAssertThrowsError(try engine.put(Note(text: "x"), id: "x", type: "something.new", zone: .shared(project: "p")))
        XCTAssertNoThrow(try engine.put(Note(text: "x"), id: "t", type: SyncType.collabTask, zone: .shared(project: "p")))
        // A shared record arriving with a private type is dropped, not stored.
        engine.merge(SyncRecord(id: "leak", type: SyncType.memory, zone: .shared(project: "p"), modified: t0, device: "x", payload: Data()))
        XCTAssertNil(engine.state.records["project-p/leak"])
    }
    @MainActor func testStateSurvivesRelaunch() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("sync.json")
        let transport = MemorySyncTransport()
        let engine = SyncEngine(transport: transport, device: "mac", url: url)
        try engine.put(Note(text: "kept"), id: "k", type: SyncType.memory, zone: .personal, at: t0)
        let reopened = SyncEngine(transport: transport, device: "mac", url: url)
        XCTAssertEqual(reopened.values(SyncType.memory, in: .personal, as: Note.self), [Note(text: "kept")])
        XCTAssertEqual(reopened.state.outbox.count, 1, "An unpushed change is still queued after a relaunch")
    }
    func testAppleAccountIDIsStableAndFolderSafe() {
        let a = AccountIdentity.apple(userIdentifier: "001234.abcdef0123456789.0456")
        XCTAssertEqual(a, AccountIdentity.apple(userIdentifier: "001234.abcdef0123456789.0456"))
        XCTAssertNotEqual(a, AccountIdentity.apple(userIdentifier: "001234.other.0456"))
        XCTAssertEqual(a.kind, .apple)
        XCTAssertTrue(a.id.hasPrefix("apple-"))
        XCTAssertTrue(a.id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
    }
}

final class CollaborationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private func task(_ id: String, _ files: [CollabFileTouch], state: CollabState = .working, age: TimeInterval = 0) -> CollabTask {
        .init(id: id, project: "p", owner: "person-" + id, ownerName: id, agent: "Codex", title: id, state: state, files: files, updated: now - age)
    }
    func testTwoActiveTasksOnOneFileOverlap() {
        let board = CollabBoard(tasks: [
            task("zach", [.init(path: "src/presence.ts", kind: .changed, added: 12, removed: 2)]),
            task("maya", [.init(path: "src/presence.ts", kind: .claimed), .init(path: "src/heartbeat.ts", kind: .changed, added: 3)]),
            task("leo", [.init(path: "src/presence.ts", kind: .changed)], state: .done)
        ])
        XCTAssertEqual(board.overlaps.map(\.path), ["src/presence.ts"])
        XCTAssertEqual(Set(board.overlaps[0].tasks.map(\.id)), ["zach", "maya"], "Finished tasks don't overlap")
        XCTAssertEqual(board.overlaps[0].suggestedOwner?.id, "zach", "The task that changed the most owns it")
        XCTAssertEqual(board.needsAttention, 1)
        XCTAssertEqual(Set(board.touching("src/presence.ts").map(\.id)), ["zach", "maya"])
    }
    func testDifferentFunctionsInOneFileDontOverlapButAFileLevelTouchDoes() {
        let apart = CollabBoard(tasks: [
            task("a", [.init(path: "lib.ts", kind: .changed, symbol: "updatePresence")]),
            task("b", [.init(path: "lib.ts", kind: .changed, symbol: "expireMembers")])
        ])
        XCTAssertTrue(apart.overlaps.isEmpty)
        let same = CollabBoard(tasks: [
            task("a", [.init(path: "lib.ts", kind: .changed, symbol: "updatePresence")]),
            task("b", [.init(path: "lib.ts", kind: .claimed, symbol: "updatePresence")])
        ])
        XCTAssertEqual(same.overlaps.map(\.symbol), ["updatePresence"])
        let wide = CollabBoard(tasks: [
            task("a", [.init(path: "lib.ts", kind: .changed, symbol: "updatePresence")]),
            task("b", [.init(path: "lib.ts", kind: .changed)])
        ])
        XCTAssertEqual(wide.overlaps.count, 1); XCTAssertNil(wide.overlaps[0].symbol)
    }
    func testOwnershipResolvesAnOverlapAndSortsItLast() {
        var board = CollabBoard(tasks: [
            task("a", [.init(path: "x.ts", kind: .changed), .init(path: "y.ts", kind: .changed)]),
            task("b", [.init(path: "x.ts", kind: .changed), .init(path: "y.ts", kind: .changed)])
        ])
        board.ownership = [.init(project: "p", path: "x.ts", task: "a", decidedBy: "zach", date: now)]
        XCTAssertEqual(board.overlaps.map(\.path), ["y.ts", "x.ts"])
        XCTAssertTrue(board.overlaps[1].resolved)
        XCTAssertEqual(board.needsAttention, 1)
    }
    func testPresenceExpiresAfterTwoMinutes() {
        let board = CollabBoard(presence: [
            .init(person: "zach", name: "Zach", project: "p", device: "mac", lastSeen: now - 30),
            .init(person: "maya", name: "Maya", project: "p", device: "mac", lastSeen: now - 600)
        ])
        XCTAssertEqual(board.present(at: now).map(\.person), ["zach"])
    }
}

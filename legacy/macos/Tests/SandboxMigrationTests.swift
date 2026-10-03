import XCTest
@testable import KemoSabeMac

final class SandboxMigrationTests: XCTestCase {
    private var home: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    override func setUp() {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        suite = "SandboxMigrationTests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
        UserDefaults().removePersistentDomain(forName: suite)
    }
    private var source: URL { home.appendingPathComponent("Library/Containers/com.zlichtman.kemosabe.mac/Data/Library/Application Support/KemoSabe") }
    private var destination: URL { home.appendingPathComponent("Library/Application Support/KemoSabe") }

    func testCopiesTheContainerOnceAndLeavesTheOriginal() throws {
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("state".utf8).write(to: source.appendingPathComponent("state.json"))
        XCTAssertEqual(SandboxMigration.run(home: home, defaults: defaults), .moved)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("state.json")), Data("state".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("state.json").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), ["state.json"], "No staging folder is left behind")
        XCTAssertEqual(SandboxMigration.run(home: home, defaults: defaults), .alreadyDone)
    }
    func testAFailedCopyIsNotMarkedDoneAndIsRetried() throws {
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let unreadable = source.appendingPathComponent("state.json")
        try Data("state".utf8).write(to: unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        XCTAssertEqual(SandboxMigration.run(home: home, defaults: defaults), .failed)
        XCTAssertFalse(defaults.bool(forKey: SandboxMigration.doneKey))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("state.json").path), "Nothing half-copied under the real name")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path)
        XCTAssertEqual(SandboxMigration.run(home: home, defaults: defaults), .moved)
        XCTAssertTrue(defaults.bool(forKey: SandboxMigration.doneKey))
    }
    func testAnItemAlreadyAtTheDestinationIsKeptBesideTheContainersCopy() throws {
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: source.appendingPathComponent("routines.json"))
        try Data("new".utf8).write(to: destination.appendingPathComponent("routines.json"))
        XCTAssertEqual(SandboxMigration.run(home: home, defaults: defaults), .moved)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("routines.json")), Data("new".utf8))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("from-sandbox-routines.json")), Data("old".utf8))
    }
    func testNoContainerIsNothingToMove() {
        XCTAssertEqual(SandboxMigration.run(home: home, defaults: defaults), .nothingToMove)
    }
}

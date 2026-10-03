import XCTest
@testable import KemoSabeMac

/// Startup: while earlier data (the sandbox copy) is still on its way, nothing opens account
/// storage for writing, and a damaged account record never silently becomes a new account.
@MainActor final class StartupTests: XCTestCase {
    private var base: URL!, suite: String!, defaults: UserDefaults!
    override func setUp() {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("StartupTests-" + UUID().uuidString, isDirectory: true)
        suite = "StartupTests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }
    override func tearDown() {
        AccountDirectory.holdLegacyMigration = false
        _ = AccountDirectory.retryMigration()
        try? FileManager.default.removeItem(at: base)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    func testAccountStorageHoldsFromTheFirstLineWhileEarlierDataIsOnItsWay() throws {
        AccountDirectory.holdLegacyMigration = true
        XCTAssertFalse(AccountDirectory.retryMigration(), "Nothing is moved into the account while held")
        XCTAssertTrue(AccountDirectory.migrationFailed)
        // The account store opens held: it never writes a fresh state over data still on its way.
        let repository = LocalRepository.standard
        let before = FileManager.default.fileExists(atPath: repository.url.path) ? try Data(contentsOf: repository.url) : nil
        let store = AppStore(repository: repository, provider: APIUnavailableLocal(), apiKeys: MemoryAPIKeys())
        XCTAssertNotNil(store.storageError)
        store.save()
        let after = FileManager.default.fileExists(atPath: repository.url.path) ? try Data(contentsOf: repository.url) : nil
        XCTAssertEqual(before, after)
        // Once the data has arrived, releasing the hold moves it in and saving resumes on retry.
        XCTAssertTrue(AccountDirectory.releaseLegacyHold())
        XCTAssertFalse(AccountDirectory.holdLegacyMigration); XCTAssertFalse(AccountDirectory.migrationFailed)
        store.retrySave()
        XCTAssertNil(store.storageError)
    }
    func testADamagedAccountRecordRecoversTheAccountOnThisMac() throws {
        let alice = AccountIdentity(id: "local-alice", kind: .local)
        try FileManager.default.createDirectory(at: AccountDirectory.folder(for: alice, base: base).appendingPathComponent("Coding"), withIntermediateDirectories: true)
        defaults.set(Data("not an account".utf8), forKey: AccountDirectory.currentKey)
        XCTAssertEqual(AccountDirectory.current(defaults, base: base), alice)
        XCTAssertEqual(defaults.data(forKey: AccountDirectory.unreadableKey), Data("not an account".utf8))
    }
    func testRecoveringAnEmptyRoutineLedgerCreatesNothing() async throws {
        let url = base.appendingPathComponent("routines.json")
        try await RoutineLedger(url: url).recover(now: Date())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

import XCTest
@testable import KemoSabe

/// Personal data lives in the account's own folder; data from before accounts moves in once,
/// safely; and one account's saved state never opens as another's.
final class AccountDirectoryTests: XCTestCase {
    private var base: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    override func setUp() {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        suite = "AccountDirectoryTests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    func testTheLocalAccountIsCreatedOnceAndStaysTheSame() {
        let first = AccountDirectory.current(defaults)
        XCTAssertEqual(first.kind, .local)
        XCTAssertTrue(first.id.hasPrefix("local-"))
        XCTAssertEqual(AccountDirectory.current(defaults), first)
    }
    func testAnUnreadableAccountRecordIsKeptAndItsAccountRecovered() throws {
        let alice = AccountIdentity(id: "local-alice", kind: .local)
        let folder = AccountDirectory.folder(for: alice, base: base)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("state".utf8).write(to: folder.appendingPathComponent("state.json"))
        let damaged = Data("{\"id\": \"local-al".utf8)
        defaults.set(damaged, forKey: AccountDirectory.currentKey)
        XCTAssertNil(AccountDirectory.saved(defaults))
        let current = AccountDirectory.current(defaults, base: base)
        XCTAssertEqual(current, alice, "The account whose data is on this device, not a new empty one")
        XCTAssertEqual(defaults.data(forKey: AccountDirectory.unreadableKey), damaged, "The damaged record is kept")
        XCTAssertEqual(defaults.string(forKey: AccountDirectory.recoveredKey), alice.id)
        XCTAssertEqual(AccountDirectory.saved(defaults), alice, "The repaired record reads back")
        XCTAssertEqual(AccountDirectory.current(defaults, base: base), alice)
    }
    func testRecoveryPrefersTheMostRecentlyUsedAccountAndIgnoresStrayFolders() throws {
        let older = AccountDirectory.folder(for: AccountIdentity(id: "local-older", kind: .local), base: base)
        let newer = AccountDirectory.folder(for: AccountIdentity(id: "apple-0123abcd", kind: .apple), base: base)
        for folder in [older, newer] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try FileManager.default.createDirectory(at: base.appendingPathComponent("Accounts/not an account"), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: older.appendingPathComponent("state.json"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86_400)], ofItemAtPath: older.appendingPathComponent("state.json").path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86_400)], ofItemAtPath: older.path)
        try Data("new".utf8).write(to: newer.appendingPathComponent("state.json"))
        defaults.set(Data([0xFF, 0x00]), forKey: AccountDirectory.currentKey)
        XCTAssertEqual(AccountDirectory.current(defaults, base: base), AccountIdentity(id: "apple-0123abcd", kind: .apple))
    }
    func testAnUnreadableRecordWithNoAccountOnTheDeviceStartsFreshButIsKept() {
        let damaged = Data("garbage".utf8)
        defaults.set(damaged, forKey: AccountDirectory.currentKey)
        let fresh = AccountDirectory.current(defaults, base: base)
        XCTAssertEqual(fresh.kind, .local)
        XCTAssertEqual(defaults.data(forKey: AccountDirectory.unreadableKey), damaged)
        // A second damage never replaces the first kept copy.
        defaults.set(Data("again".utf8), forKey: AccountDirectory.currentKey)
        _ = AccountDirectory.current(defaults, base: base)
        XCTAssertEqual(defaults.data(forKey: AccountDirectory.unreadableKey), damaged)
    }
    func testDataFromBeforeAccountsMovesIntoTheAccountOnce() throws {
        let files = FileManager.default
        try Data("state".utf8).write(to: base.appendingPathComponent("state.json"))
        try Data("routines".utf8).write(to: base.appendingPathComponent("routines.json"))
        try files.createDirectory(at: base.appendingPathComponent("Profile"), withIntermediateDirectories: true)
        try Data("profile".utf8).write(to: base.appendingPathComponent("Profile/profile.json"))
        try Data("device".utf8).write(to: base.appendingPathComponent("device-only.json"))
        let account = AccountDirectory.current(defaults)
        try AccountDirectory.migrateLegacy(base: base, account: account, defaults: defaults)
        let folder = AccountDirectory.folder(for: account, base: base)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("state.json")), Data("state".utf8))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("Profile/profile.json")), Data("profile".utf8))
        XCTAssertFalse(files.fileExists(atPath: base.appendingPathComponent("state.json").path))
        XCTAssertTrue(files.fileExists(atPath: base.appendingPathComponent("device-only.json").path), "Only personal items move")
        // It's done once: a later stray file isn't swept in.
        try Data("later".utf8).write(to: base.appendingPathComponent("state.json"))
        try AccountDirectory.migrateLegacy(base: base, account: account, defaults: defaults)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("state.json")), Data("state".utf8))
    }
    func testAnItemAlreadyInTheAccountIsKeptBesideTheOlderOne() throws {
        let account = AccountDirectory.current(defaults)
        let folder = AccountDirectory.folder(for: account, base: base)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("newer".utf8).write(to: folder.appendingPathComponent("state.json"))
        try Data("older".utf8).write(to: base.appendingPathComponent("state.json"))
        try AccountDirectory.migrateLegacy(base: base, account: account, defaults: defaults)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("state.json")), Data("newer".utf8))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("from-before-accounts-state.json")), Data("older".utf8))
    }
    @MainActor func testAnotherAccountsStateIsNeverOpenedOrOverwritten() throws {
        let url = base.appendingPathComponent("state.json")
        try LocalRepository(url: url, owner: "local-alice").save(SavedState())
        XCTAssertEqual(try LocalRepository(url: url, owner: "local-alice").read().ownerAccountID, "local-alice")
        XCTAssertThrowsError(try LocalRepository(url: url, owner: "local-bob").read()) { XCTAssertEqual($0 as? LocalRepositoryError, .otherAccount) }
        let before = try Data(contentsOf: url)
        let store = AppStore(repository: LocalRepository(url: url, owner: "local-bob"), provider: APIUnavailableLocal(), apiKeys: MemoryAPIKeys())
        XCTAssertEqual(store.storageError, AppStore.otherAccountMessage)
        store.save()
        XCTAssertEqual(try Data(contentsOf: url), before)
    }
    func testTestsNeverUseTheRealAppFolder() {
        XCTAssertTrue(AccountDirectory.isTestHost)
        XCTAssertTrue(AccountDirectory.base.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }
    func testAccountSettingsMoveOffTheDeviceOnceAndDeviceSettingsStay() {
        let deviceSuite = suite + ".device"
        let device = UserDefaults(suiteName: deviceSuite)!
        defer { UserDefaults().removePersistentDomain(forName: deviceSuite) }
        device.set("Mochi", forKey: CompanionIdentity.key)
        device.set("playful", forKey: CompanionIdentity.personalityKey)
        device.set(true, forKey: "kemo.navigation.showNames")
        AccountDirectory.moveAccountSettings(from: device, to: defaults)
        XCTAssertEqual(defaults.string(forKey: CompanionIdentity.key), "Mochi")
        XCTAssertEqual(defaults.string(forKey: CompanionIdentity.personalityKey), "playful")
        XCTAssertNil(device.object(forKey: CompanionIdentity.key), "No copy of the account's settings stays on the device")
        XCTAssertTrue(device.bool(forKey: "kemo.navigation.showNames"), "Device settings stay")
        // Once only: a later device value doesn't overwrite the account.
        device.set("Other", forKey: CompanionIdentity.key)
        AccountDirectory.moveAccountSettings(from: device, to: defaults)
        XCTAssertEqual(defaults.string(forKey: CompanionIdentity.key), "Mochi")
    }
}

import XCTest
@testable import KemoSabe

/// Signing in or out finishes while the app runs: the old account's stores are closed and flushed,
/// the switch is made behind the write fence, and everything reopens on the new account's folder
/// and settings. Nothing writes into the old account after the switch starts, and a switch that
/// fails leaves the device on the old account with the switch still waiting for the next launch.
///
/// These run against the test host's own account folder and settings (`AccountDirectory.base` and
/// `.settings`, both throwaway for tests), because the fence guards exactly those.
@MainActor final class LiveAccountSwitchTests: XCTestCase {
    private let appleUser = "001234.fedcba9876543210fedcba9876543210.0077"
    private var savedKeys: [String: Any] = [:]
    private var opened: [AccountIdentity] = []
    private static let keys = [AccountDirectory.currentKey, AccountSwitch.pendingKey, AccountSwitch.outcomeKey,
                               AccountSwitch.signedOutLocalKey, AppleAccountSession.scopesRequestedKey]
    private var settings: UserDefaults { AccountDirectory.settings }

    override func setUp() async throws {
        AccountDirectory.prepare()
        for key in Self.keys { if let value = settings.object(forKey: key) { savedKeys[key] = value } }
        for key in Self.keys where key != AccountDirectory.currentKey { settings.removeObject(forKey: key) }
    }
    override func tearDown() async throws {
        for key in Self.keys { settings.removeObject(forKey: key) }
        for (key, value) in savedKeys { settings.set(value, forKey: key) }
        for account in opened {
            try? FileManager.default.removeItem(at: AccountDirectory.folder(for: account))
            UserDefaults().removePersistentDomain(forName: AccountDirectory.settingsSuite(for: account))
        }
        AccountDirectory.switchFailed = false
        AccountDirectory.endSwitch()
        LiveAccountSwitch.reopenSharedStores()
    }

    /// Opens a fresh local account as the device's current one.
    private func openLocal() throws -> AccountIdentity {
        let local = AccountIdentity.newLocal()
        opened.append(local)
        settings.set(try JSONEncoder().encode(local), forKey: AccountDirectory.currentKey)
        LiveAccountSwitch.reopenSharedStores()
        return local
    }
    private func folder(_ account: AccountIdentity) -> URL { AccountDirectory.folder(for: account) }
    private func snapshot(_ account: AccountIdentity) throws -> [String: String] { try AccountSwitch.inventory(folder(account), files: .default) }

    /// The app's own stores, as the iPhone and Mac apps hold them.
    @MainActor private final class App {
        var store: AppStore
        var closed: [AppStore] = []
        var reopened = 0
        init() { store = AppStore(repository: .standard, provider: APIUnavailableLocal(), apiKeys: MemoryAPIKeys()) }
        var hooks: LiveAccountSwitch.Hooks {
            .init(quiesce: { [self] in store.closeForAccountSwitch(); closed.append(store) },
                  reopen: { [self] in store = AppStore(repository: .standard, provider: APIUnavailableLocal(), apiKeys: MemoryAPIKeys()); reopened += 1 })
        }
    }

    func testSigningInFinishesInPlaceAndReopensEveryStoreOnTheAppleAccount() throws {
        let local = try openLocal()
        let apple = AccountIdentity.apple(userIdentifier: appleUser)
        opened.append(apple)
        let app = App()
        app.store.state.standupFormat = "Mochi format"; app.store.save()
        AccountDirectory.accountSettings.set("Mochi", forKey: CompanionIdentity.key)
        let oldLedger = RoutineLedger.shared

        let identifiers = MemoryAppleUserID()
        let session = AppleAccountSession(active: local, defaults: settings, identifiers: identifiers, credentials: AlwaysAuthorized(),
                                          observesRevocation: false, switchFailed: false,
                                          finishNow: { [app] in LiveAccountSwitch.finish(defaults: AccountDirectory.settings, hooks: app.hooks) })
        var name = PersonNameComponents(); name.givenName = "Zach"; name.familyName = "Tester"
        try session.completeSignIn(userIdentifier: appleUser, fullName: name, email: "hidden@privaterelay.appleid.com", account: AccountStore.shared)

        // Finished at once: no pending switch, no reopen instruction, and the one-time note.
        XCTAssertEqual(AccountDirectory.current(), apple)
        XCTAssertNil(AccountSwitch.pending(settings))
        XCTAssertEqual(session.active, apple)
        XCTAssertEqual(session.status, .linked)
        XCTAssertEqual(session.statusTitle, "Linked")
        XCTAssertEqual(session.lastSwitch, .adopted)
        XCTAssertNotNil(session.lastSwitchNote)
        XCTAssertFalse(session.statusDetail.contains("open it again"))
        XCTAssertNil(session.notice)

        // Every store reopened on the Apple account: the app's store, the shared ones, and settings.
        XCTAssertEqual(app.reopened, 1)
        XCTAssertTrue(app.closed.first?.closed == true)
        XCTAssertEqual(LocalRepository.standard.url, folder(apple).appendingPathComponent("state.json"))
        XCTAssertEqual(app.store.state.standupFormat, "Mochi format", "The new store opens the adopted data")
        XCTAssertNil(app.store.storageError)
        XCTAssertEqual(AccountDirectory.accountSettings.string(forKey: CompanionIdentity.key), "Mochi")
        XCTAssertEqual(AccountStore.shared.account.name, "Zach Tester", "The name from Apple carries into the Apple account")
        XCTAssertEqual(AccountStore.shared.account.email, "hidden@privaterelay.appleid.com")
        XCTAssertFalse(RoutineLedger.shared === oldLedger)
        app.store.state.standupFormat = "After"; app.store.save()
        XCTAssertEqual(try LocalRepository.standard.read().standupFormat, "After")
        XCTAssertEqual(try read(folder(local).appendingPathComponent("state.json")).standupFormat, "Mochi format", "The local original is kept")
    }

    func testTheOldAccountReceivesNoWritesOnceTheSwitchStarts() async throws {
        let local = try openLocal()
        let apple = AccountIdentity.apple(userIdentifier: appleUser)
        opened.append(apple)
        let app = App()
        app.store.state.standupFormat = "Before"; app.store.save()
        let oldStore = app.store
        let oldAccount = AccountStore.shared
        let oldLedger = RoutineLedger.shared
        _ = try await oldLedger.snapshot()
        let oldRecords = SyncEngine(transport: MemorySyncTransport(), device: "old", url: folder(local).appendingPathComponent("Sync/records.json"))
        let before = try snapshot(local)
        var duringSwitch: [Bool] = []

        AccountSwitch.request(apple, reason: .signIn, active: local, defaults: settings)
        let result = LiveAccountSwitch.finish(defaults: settings, hooks: app.hooks) {
            // Inside the fence: even the old account's own folder refuses writes.
            duringSwitch.append(AccountDirectory.permitsWrite(to: self.folder(local).appendingPathComponent("state.json")))
            duringSwitch.append(AccountDirectory.permitsWrite(to: self.folder(apple).appendingPathComponent("state.json")))
            XCTAssertThrowsError(try LocalRepository(url: self.folder(local).appendingPathComponent("state.json"), owner: local.id).save(SavedState()))
            return try AccountSwitch.finishPending()
        }
        XCTAssertEqual(result, .finished(.adopted))
        XCTAssertEqual(duringSwitch, [false, false])

        // Everything still holding the old account is refused, and its folder is byte-for-byte unchanged.
        oldStore.state.standupFormat = "Late reply"; oldStore.save()
        XCTAssertThrowsError(try LocalRepository(url: folder(local).appendingPathComponent("state.json"), owner: local.id).save(SavedState()))
        do { try await oldLedger.setEnabled(true); XCTFail("The old ledger wrote after the switch") } catch {}
        XCTAssertThrowsError(try oldRecords.put("x", id: "account", type: SyncType.account, zone: .personal))
        oldAccount.update { $0.name = "Written late" }
        XCTAssertThrowsError(try oldAccount.setPhoto(Data([1, 2, 3])))
        XCTAssertEqual(try snapshot(local), before)
        XCTAssertNotEqual(UserDefaults(suiteName: AccountDirectory.settingsSuite(for: local))?.data(forKey: AccountStore.key)
                            .flatMap { try? JSONDecoder().decode(KemoAccount.self, from: $0) }?.name, "Written late")

        // The account now open writes normally.
        XCTAssertTrue(AccountDirectory.permitsWrite(to: folder(apple).appendingPathComponent("state.json")))
        app.store.save()
        XCTAssertNil(app.store.storageError)
    }

    func testAFailedSwitchStaysOnTheOldAccountAndKeepsTheSwitchForNextLaunch() throws {
        struct CopyFailed: Error {}
        let local = try openLocal()
        let apple = AccountIdentity.apple(userIdentifier: appleUser)
        opened.append(apple)
        let app = App()
        app.store.state.standupFormat = "Kept"; app.store.save()

        let session = AppleAccountSession(active: local, defaults: settings, identifiers: MemoryAppleUserID(), credentials: AlwaysAuthorized(),
                                          observesRevocation: false, switchFailed: false,
                                          finishNow: { [app] in LiveAccountSwitch.finish(defaults: AccountDirectory.settings, hooks: app.hooks) { throw CopyFailed() } })
        try session.completeSignIn(userIdentifier: appleUser, fullName: nil, email: nil, account: AccountStore.shared)

        XCTAssertEqual(AccountDirectory.current(), local, "Nothing switched")
        XCTAssertEqual(AccountSwitch.pending(settings)?.target, apple, "The switch still waits for the next launch")
        XCTAssertTrue(AccountDirectory.switchFailed)
        XCTAssertFalse(AccountDirectory.isSwitching)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder(apple).path))
        XCTAssertEqual(session.active, local)
        XCTAssertEqual(session.status, .finishingSignIn)
        XCTAssertEqual(session.notice, AppleAccountSession.failedNotice)
        XCTAssertTrue(session.statusDetail.contains("nothing was changed"))

        // Reopened on the old account, which keeps working.
        XCTAssertEqual(app.reopened, 1)
        XCTAssertEqual(app.store.state.standupFormat, "Kept")
        app.store.state.standupFormat = "Still local"; app.store.save()
        XCTAssertNil(app.store.storageError)
        XCTAssertEqual(try read(folder(local).appendingPathComponent("state.json")).standupFormat, "Still local")

        // The next launch (or Try again) finishes it.
        XCTAssertEqual(try AccountSwitch.finishPending(), .adopted)
        XCTAssertEqual(AccountDirectory.current(), apple)
        XCTAssertEqual(try read(folder(apple).appendingPathComponent("state.json"), owner: apple).standupFormat, "Still local")
    }

    func testSigningOutFinishesInPlaceAndDeletesNothing() throws {
        let apple = AccountIdentity.apple(userIdentifier: appleUser)
        opened.append(apple)
        settings.set(try JSONEncoder().encode(apple), forKey: AccountDirectory.currentKey)
        LiveAccountSwitch.reopenSharedStores()
        let app = App()
        app.store.state.standupFormat = "Apple data"; app.store.save()
        let identifiers = MemoryAppleUserID(appleUser)
        let session = AppleAccountSession(active: apple, defaults: settings, identifiers: identifiers, credentials: AlwaysAuthorized(),
                                          observesRevocation: false, switchFailed: false,
                                          finishNow: { [app] in LiveAccountSwitch.finish(defaults: AccountDirectory.settings, hooks: app.hooks) })
        XCTAssertEqual(session.status, .linked)

        XCTAssertEqual(session.signOut(), .finished(.signedOut(revoked: false)))
        let local = AccountDirectory.current()
        opened.append(local)
        XCTAssertEqual(local.kind, .local)
        XCTAssertEqual(session.status, .local)
        XCTAssertEqual(session.lastSwitch, .signedOut(revoked: false))
        XCTAssertNil(AccountSwitch.pending(settings))
        XCTAssertNotEqual(app.store.state.standupFormat, "Apple data", "The local account opens with its own data")
        XCTAssertEqual(try read(folder(apple).appendingPathComponent("state.json"), owner: apple).standupFormat, "Apple data", "Signing out deletes nothing")
    }

    func testWithoutRegisteredStoresTheSwitchWaitsForTheNextLaunch() throws {
        let local = try openLocal()
        let apple = AccountIdentity.apple(userIdentifier: appleUser)
        AccountSwitch.request(apple, reason: .signIn, active: local, defaults: settings)
        XCTAssertEqual(LiveAccountSwitch.finish(defaults: settings, hooks: nil), .deferred)
        XCTAssertEqual(AccountDirectory.current(), local)
        XCTAssertNotNil(AccountSwitch.pending(settings))
        AccountSwitch.cancel(settings)
        XCTAssertEqual(LiveAccountSwitch.finish(defaults: settings, hooks: nil), .nothingPending)
    }

    func testTheFenceOnlyGuardsAccountFolders() throws {
        let local = try openLocal()
        let other = AccountIdentity.newLocal()
        XCTAssertTrue(AccountDirectory.permitsWrite(to: folder(local).appendingPathComponent("Profile/profile.json")))
        XCTAssertFalse(AccountDirectory.permitsWrite(to: folder(other).appendingPathComponent("state.json")))
        XCTAssertTrue(AccountDirectory.permitsWrite(to: FileManager.default.temporaryDirectory.appendingPathComponent("elsewhere.json")))
        XCTAssertTrue(AccountDirectory.permitsWrite(to: AccountDirectory.base.appendingPathComponent("window.json")))
        AccountDirectory.beginSwitch()
        XCTAssertFalse(AccountDirectory.permitsWrite(to: folder(local).appendingPathComponent("state.json")))
        XCTAssertFalse(AccountDirectory.permitsSettingsWrite(for: local.id))
        XCTAssertTrue(AccountDirectory.permitsWrite(to: FileManager.default.temporaryDirectory.appendingPathComponent("elsewhere.json")))
        AccountDirectory.endSwitch()
        XCTAssertTrue(AccountDirectory.permitsSettingsWrite(for: local.id))
        XCTAssertFalse(AccountDirectory.permitsSettingsWrite(for: other.id))
    }

    private func read(_ url: URL, owner: AccountIdentity? = nil) throws -> SavedState {
        try LocalRepository(url: url, owner: owner?.id, formerOwners: owner.map { AccountDirectory.formerOwners(of: folder($0)) } ?? []).read()
    }
}

private struct AlwaysAuthorized: AppleCredentialChecking {
    func state(for userIdentifier: String) async throws -> AppleCredentialState { .authorized }
}

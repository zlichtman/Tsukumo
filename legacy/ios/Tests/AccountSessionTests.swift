import XCTest
@testable import KemoSabe

/// Sign in with Apple moves this device from its local account to the Apple account safely:
/// copied and checked before switching, never overwriting an Apple account already here, never
/// deleting anything on sign-out, and signing out when Apple says the sign-in was revoked.
@MainActor final class AccountSessionTests: XCTestCase {
    private var base: URL!
    private var token: String!
    private var defaults: UserDefaults!
    private var suites: Set<String> = []
    private let appleUser = "001234.abcdef0123456789abcdef0123456789.0042"

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        token = "AccountSessionTests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: token)
        suites = [token]
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
    }
    private func suite(_ account: AccountIdentity) -> String {
        let name = token + "." + account.id
        suites.insert(name)
        return name
    }
    private func settings(_ account: AccountIdentity) -> UserDefaults { UserDefaults(suiteName: suite(account))! }
    private func folder(_ account: AccountIdentity) -> URL { AccountDirectory.folder(for: account, base: base) }
    @discardableResult private func finish() throws -> AccountSwitch.Outcome? {
        try AccountSwitch.finishPending(base: base, defaults: defaults, suite: suite)
    }
    private func session(active: AccountIdentity, identifiers: AppleUserIDStoring = MemoryAppleUserID(),
                         credentials: AppleCredentialChecking = FixedCredentials(.authorized)) -> AppleAccountSession {
        AppleAccountSession(active: active, defaults: defaults, identifiers: identifiers, credentials: credentials, observesRevocation: false, switchFailed: false)
    }
    private func write(_ text: String, _ path: String, in folder: URL) throws {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    private func read(_ path: String, in folder: URL) throws -> String {
        String(decoding: try Data(contentsOf: folder.appendingPathComponent(path)), as: UTF8.self)
    }

    func testSigningInCopiesTheLocalAccountIntoTheAppleAccountAndKeepsTheOriginal() throws {
        let local = AccountDirectory.stored(defaults)
        XCTAssertEqual(local.kind, .local)
        var state = SavedState(); state.standupFormat = "Mochi format"
        try LocalRepository(url: folder(local).appendingPathComponent("state.json"), owner: local.id).save(state)
        try write("profile", "Profile/profile.json", in: folder(local))
        try write(String(repeating: "v", count: 5_000_000), "Profile/video.mov", in: folder(local))
        settings(local).set("Mochi", forKey: CompanionIdentity.key)

        let apple = AccountIdentity.apple(userIdentifier: appleUser)
        let session = session(active: local)
        try session.completeSignIn(userIdentifier: appleUser, fullName: nil, email: nil, account: AccountStore(defaults: settings(local), cloud: nil))
        XCTAssertEqual(session.status, .finishingSignIn)
        XCTAssertEqual(AccountDirectory.stored(defaults), local, "Nothing switches until the next launch")

        XCTAssertEqual(try finish(), .adopted)
        XCTAssertEqual(AccountDirectory.stored(defaults), apple)
        XCTAssertNil(AccountSwitch.pending(defaults))
        XCTAssertEqual(try read("Profile/profile.json", in: folder(apple)), "profile")
        XCTAssertEqual(try AccountSwitch.inventory(folder(local), files: .default).count, 3)
        XCTAssertEqual(try read("Profile/profile.json", in: folder(local)), "profile", "The local original is never deleted")
        XCTAssertEqual(settings(apple).string(forKey: CompanionIdentity.key), "Mochi")
        XCTAssertEqual(AccountDirectory.formerOwners(of: folder(apple)), [local.id])

        // The adopted state opens as the Apple account's and is saved as its own from then on.
        let stateURL = folder(apple).appendingPathComponent("state.json")
        XCTAssertThrowsError(try LocalRepository(url: stateURL, owner: apple.id).read()) { XCTAssertEqual($0 as? LocalRepositoryError, .otherAccount) }
        let repository = LocalRepository(url: stateURL, owner: apple.id, formerOwners: AccountDirectory.formerOwners(of: folder(apple)))
        XCTAssertEqual(try repository.read().standupFormat, "Mochi format")
        try repository.save(try repository.read())
        XCTAssertEqual(try LocalRepository(url: stateURL, owner: apple.id).read().ownerAccountID, apple.id)
        XCTAssertEqual(AccountSwitch.lastOutcome(defaults), .adopted)
    }

    func testAnAppleAccountAlreadyOnThisDeviceIsNeverOverwritten() throws {
        let local = AccountDirectory.stored(defaults)
        let apple = AccountIdentity.apple(userIdentifier: appleUser)
        try write("apple data", "state.json", in: folder(apple))
        settings(apple).set("Apple's Kemo", forKey: CompanionIdentity.key)
        try write("local data", "state.json", in: folder(local))
        settings(local).set("Local Kemo", forKey: CompanionIdentity.key)

        try session(active: local).completeSignIn(userIdentifier: appleUser, fullName: nil, email: nil, account: AccountStore(defaults: settings(local), cloud: nil))
        XCTAssertEqual(try finish(), .openedExisting(keptLocalData: true))
        XCTAssertEqual(AccountDirectory.stored(defaults), apple)
        XCTAssertEqual(try read("state.json", in: folder(apple)), "apple data")
        XCTAssertEqual(try read("state.json", in: folder(local)), "local data", "The local account is kept apart")
        XCTAssertEqual(settings(apple).string(forKey: CompanionIdentity.key), "Apple's Kemo")
        XCTAssertEqual(settings(local).string(forKey: CompanionIdentity.key), "Local Kemo")
        XCTAssertTrue(AccountDirectory.formerOwners(of: folder(apple)).isEmpty, "Nothing was adopted")
    }

    func testAnInterruptedSwitchFinishesWithoutTouchingTheOriginal() throws {
        let local = AccountDirectory.stored(defaults)
        let apple = AccountIdentity.apple(userIdentifier: appleUser)
        try write("local data", "state.json", in: folder(local))
        // A copy left half-made by an earlier launch.
        let staging = folder(apple).deletingLastPathComponent().appendingPathComponent(".incoming-" + apple.id)
        try write("partial", "state.json", in: staging)
        AccountSwitch.request(apple, reason: .signIn, active: local, defaults: defaults)
        XCTAssertEqual(try finish(), .adopted)
        XCTAssertEqual(try read("state.json", in: folder(apple)), "local data")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertEqual(try read("state.json", in: folder(local)), "local data")

        // Stopped after the folder moved into place but before switching: it's recognized as adopted.
        defaults.set(try JSONEncoder().encode(local), forKey: AccountDirectory.currentKey)
        AccountSwitch.request(apple, reason: .signIn, active: local, defaults: defaults)
        XCTAssertEqual(try finish(), .adopted)
        XCTAssertEqual(AccountDirectory.stored(defaults), apple)
    }

    func testSigningOutKeepsEverythingAndSigningBackInReturnsIt() throws {
        let apple = AccountIdentity.apple(userIdentifier: appleUser)
        defaults.set(try JSONEncoder().encode(apple), forKey: AccountDirectory.currentKey)
        try write("apple data", "state.json", in: folder(apple))
        let identifiers = MemoryAppleUserID(appleUser)
        let signedIn = session(active: apple, identifiers: identifiers)
        XCTAssertEqual(signedIn.status, .linked)

        signedIn.signOut()
        XCTAssertEqual(signedIn.status, .finishingSignOut)
        XCTAssertNil(identifiers.read(), "The sign-in is forgotten on this device")
        XCTAssertEqual(try finish(), .signedOut(revoked: false))
        let local = AccountDirectory.stored(defaults)
        XCTAssertEqual(local.kind, .local)
        XCTAssertEqual(try read("state.json", in: folder(apple)), "apple data", "Signing out deletes nothing")

        // Signed out, then signed in again with the same Apple Account: its data is opened as it was.
        try write("while signed out", "state.json", in: folder(local))
        try session(active: local, identifiers: identifiers).completeSignIn(userIdentifier: appleUser, fullName: nil, email: nil, account: AccountStore(defaults: settings(local), cloud: nil))
        XCTAssertEqual(try finish(), .openedExisting(keptLocalData: true))
        XCTAssertEqual(AccountDirectory.stored(defaults), apple)
        XCTAssertEqual(try read("state.json", in: folder(apple)), "apple data")

        // The next sign-out returns to the same local account, with what was done while signed out.
        session(active: apple, identifiers: identifiers).signOut()
        try finish()
        XCTAssertEqual(AccountDirectory.stored(defaults), local)
        XCTAssertEqual(try read("state.json", in: folder(local)), "while signed out")
    }

    func testARevokedSignInSignsOutAndBeingOfflineDoesNot() async throws {
        let apple = AccountIdentity.apple(userIdentifier: appleUser)
        let identifiers = MemoryAppleUserID(appleUser)

        let offline = session(active: apple, identifiers: identifiers, credentials: FixedCredentials(nil))
        await offline.verify()
        XCTAssertEqual(offline.status, .linked, "An unreachable check changes nothing")
        let authorized = session(active: apple, identifiers: identifiers, credentials: FixedCredentials(.authorized))
        await authorized.verify()
        XCTAssertEqual(authorized.status, .linked)
        XCTAssertNil(AccountSwitch.pending(defaults))

        let revoked = session(active: apple, identifiers: identifiers, credentials: FixedCredentials(.revoked))
        await revoked.verify()
        XCTAssertEqual(revoked.status, .finishingSignOut)
        XCTAssertEqual(AccountSwitch.pending(defaults)?.reason, .revoked)
        XCTAssertNil(identifiers.read())
        XCTAssertNotNil(revoked.notice)
        defaults.set(try JSONEncoder().encode(apple), forKey: AccountDirectory.currentKey)
        XCTAssertEqual(try finish(), .signedOut(revoked: true))
        XCTAssertEqual(AccountDirectory.stored(defaults).kind, .local)

        // Apple no longer knowing the sign-in counts as signed out too.
        AccountSwitch.cancel(defaults)
        try identifiers.save(appleUser)
        let unknown = session(active: apple, identifiers: identifiers, credentials: FixedCredentials(.notFound))
        await unknown.verify()
        XCTAssertEqual(unknown.status, .finishingSignOut)
    }

    func testASignInThisDeviceDoesntHoldNeedsConfirming() {
        let apple = AccountIdentity.apple(userIdentifier: appleUser)
        XCTAssertEqual(session(active: apple, identifiers: MemoryAppleUserID()).status, .needsConfirmation)
        XCTAssertEqual(session(active: apple, identifiers: MemoryAppleUserID("another.user")).status, .needsConfirmation)
    }

    func testNameAndEmailAreAskedForOnceAndKeptOnlyInTheAccountRecord() throws {
        let local = AccountDirectory.stored(defaults)
        let engine = SyncEngine(transport: MemorySyncTransport(), device: "test")
        try engine.markJoined()   // a device that has joined its account queues edits at once
        let account = AccountStore(defaults: settings(local), cloud: nil, records: AccountRecords(engine: engine))
        let session = session(active: local)
        XCTAssertTrue(session.requestsNameAndEmail)
        var name = PersonNameComponents(); name.givenName = "Zach"; name.familyName = "Tester"
        try session.completeSignIn(userIdentifier: appleUser, fullName: name, email: "hidden@privaterelay.appleid.com", account: account)
        XCTAssertFalse(session.requestsNameAndEmail, "Apple returns them once, so they're asked for once")
        XCTAssertEqual(account.account.name, "Zach Tester")
        XCTAssertEqual(account.account.email, "hidden@privaterelay.appleid.com")
        let records = engine.state.records.values
        XCTAssertTrue(records.contains { $0.type == SyncType.account && $0.zone == .personal })
        XCTAssertFalse(records.contains { String(decoding: $0.payload, as: UTF8.self).contains("privaterelay") }, "The email never syncs")
        XCTAssertNil(settings(local).string(forKey: "kemo.appleSignIn.user"))
        XCTAssertFalse(String(decoding: defaults.data(forKey: AccountSwitch.pendingKey) ?? Data(), as: UTF8.self).contains(appleUser),
                       "Settings hold only the hashed account ID, never the Apple user identifier")

        // A name already set isn't replaced by Apple's.
        let named = AccountStore(defaults: UserDefaults(suiteName: suite(.newLocal()))!, cloud: nil)
        named.update { $0.name = "Chosen Name" }
        try self.session(active: local).completeSignIn(userIdentifier: appleUser, fullName: name, email: nil, account: named)
        XCTAssertEqual(named.account.name, "Chosen Name")
    }

    func testAccountCompanionAndProfileQueueInThePersonalZoneOnly() async throws {
        let engine = SyncEngine(transport: MemorySyncTransport(), device: "phone")
        try engine.markJoined()   // before joining, nothing is queued (`AccountRecords.put`)
        let records = AccountRecords(engine: engine)
        let account = AccountStore(defaults: settings(.newLocal()), cloud: nil, records: records)
        account.update { $0.name = "Zach"; $0.handle = "zach" }
        let queued = engine.state.outbox.count
        XCTAssertGreaterThanOrEqual(queued, 2, "Account and companion are queued")
        account.push()
        XCTAssertEqual(engine.state.outbox.count, queued, "An unchanged value isn't queued again")
        XCTAssertEqual(engine.values(SyncType.account, in: .personal, as: AccountRecords.Account.self), [.init(name: "Zach", handle: "zach")])

        let profiles = ProfileStore(folder: base.appendingPathComponent("Profile"), account: account, records: records)
        profiles.update { $0.bio = "Builds Kemo" }
        XCTAssertEqual(engine.values(SyncType.profile, in: .personal, as: ProfileStore.Synced.self).first?.bio, "Builds Kemo")
        XCTAssertTrue(engine.state.records.values.allSatisfy { $0.zone == .personal })
        XCTAssertThrowsError(try engine.put(AccountRecords.Account(name: "x", handle: "x"), id: "a", type: SyncType.account, zone: .shared(project: "p")))

        // Until iCloud is set up, the transport carries nothing and says so.
        let pending = SyncEngine(transport: UnavailableSyncTransport(), device: "phone")
        try pending.put(AccountRecords.Account(name: "Zach", handle: "zach"), id: AccountRecords.accountID, type: SyncType.account, zone: .personal)
        do { try await pending.sync(); XCTFail("Sync must not claim to work") } catch { XCTAssertEqual(error as? SyncError, .unavailable(UnavailableSyncTransport.reason)) }
        XCTAssertEqual(pending.state.outbox.count, 1, "The change stays queued")
    }

    func testALocalAccountHasNoSyncRecords() {
        XCTAssertNil(AccountRecords.forCurrentAccount().engine, "Tests run on a local account, which never links to other devices")
    }
}

private struct FixedCredentials: AppleCredentialChecking {
    struct Offline: Error {}
    let state: AppleCredentialState?
    init(_ state: AppleCredentialState?) { self.state = state }
    func state(for userIdentifier: String) async throws -> AppleCredentialState {
        guard let state else { throw Offline() }
        return state
    }
}

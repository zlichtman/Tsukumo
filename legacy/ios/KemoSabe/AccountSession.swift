import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import Security

/// Moving this device from one account to another: signing in with Apple, and signing out.
///
/// Signing in or out records a pending switch, and `LiveAccountSwitch` finishes it right away while
/// the app runs: every store bound to the old account is stopped and flushed, the switch is made
/// behind a write fence, and every store and the UI are opened again on the new account. If that
/// can't be done (the app hasn't registered its stores, or the copy fails), the switch stays
/// pending and the next launch finishes it before anything opens account data
/// (`AccountDirectory.current`).
///
/// Finishing a sign-in from a local account copies the local folder and settings into the Apple
/// account, verifies the copy, and only then switches; the local original is never deleted. If the
/// Apple account already has a folder on this device, it's opened as it is and the local account is
/// kept apart, untouched. Signing out goes to a local account and deletes nothing.
enum AccountSwitch {
    static let pendingKey = "kemo.account.pending"
    static let outcomeKey = "kemo.account.switchOutcome"
    /// The local account used while signed out, reused by the next sign-out so its data comes back.
    static let signedOutLocalKey = "kemo.account.signedOutLocal"

    struct Pending: Codable, Equatable {
        enum Reason: String, Codable { case signIn, signOut, revoked }
        var target: AccountIdentity
        var reason: Reason
    }
    enum Outcome: Codable, Equatable {
        /// This device's local data now lives in the Apple account. The local copy is kept.
        case adopted
        /// The Apple account already had data on this device, so it was opened as it is; the local
        /// account's data (if any) was kept apart and not merged.
        case openedExisting(keptLocalData: Bool)
        /// Moved from one Apple account to another; nothing was carried over.
        case switched
        /// Signed out to a local account; the Apple account's data stays on this device.
        case signedOut(revoked: Bool)
    }
    enum Failure: Error, Equatable {
        case copyMismatch
        case settingsNotCopied
        case settingsUnavailable
    }

    static func pending(_ defaults: UserDefaults) -> Pending? {
        defaults.data(forKey: pendingKey).flatMap { try? JSONDecoder().decode(Pending.self, from: $0) }
    }
    /// Records a switch for the next launch. A switch to the account already open cancels one.
    static func request(_ target: AccountIdentity, reason: Pending.Reason, active: AccountIdentity, defaults: UserDefaults) {
        guard target != active else { return cancel(defaults) }
        defaults.set(try? JSONEncoder().encode(Pending(target: target, reason: reason)), forKey: pendingKey)
    }
    static func cancel(_ defaults: UserDefaults) { defaults.removeObject(forKey: pendingKey) }
    static func lastOutcome(_ defaults: UserDefaults) -> Outcome? {
        defaults.data(forKey: outcomeKey).flatMap { try? JSONDecoder().decode(Outcome.self, from: $0) }
    }
    /// The local account to return to on sign-out: the one used last time you were signed out, or a new one.
    static func signedOutLocal(_ defaults: UserDefaults) -> AccountIdentity {
        if let data = defaults.data(forKey: signedOutLocalKey), let saved = try? JSONDecoder().decode(AccountIdentity.self, from: data), saved.kind == .local { return saved }
        let created = AccountIdentity.newLocal()
        defaults.set(try? JSONEncoder().encode(created), forKey: signedOutLocalKey)
        return created
    }

    /// Finishes a waiting switch: at launch before any account data is opened, or while the app
    /// runs behind `LiveAccountSwitch`'s write fence. Throws, leaving the device on its current
    /// account and the switch waiting, if anything can't be copied and checked.
    @discardableResult
    static func finishPending(base: URL = AccountDirectory.base, defaults: UserDefaults = AccountDirectory.settings,
                              files: FileManager = .default,
                              suite: (AccountIdentity) -> String = AccountDirectory.settingsSuite(for:)) throws -> Outcome? {
        guard let pending = pending(defaults) else { return nil }
        let source = AccountDirectory.stored(defaults)
        guard pending.target != source else { cancel(defaults); return nil }
        let outcome: Outcome
        if pending.target.kind == .apple {
            outcome = source.kind == .local
                ? try adopt(source, into: pending.target, base: base, files: files, suite: suite)
                : .switched
            // The local account that was just adopted isn't the one to return to on sign-out.
            if outcome == .adopted, defaults.data(forKey: signedOutLocalKey).flatMap({ try? JSONDecoder().decode(AccountIdentity.self, from: $0) }) == source {
                defaults.removeObject(forKey: signedOutLocalKey)
            }
        } else {
            outcome = .signedOut(revoked: pending.reason == .revoked)
        }
        defaults.set(try JSONEncoder().encode(pending.target), forKey: AccountDirectory.currentKey)
        cancel(defaults)
        defaults.set(try? JSONEncoder().encode(outcome), forKey: outcomeKey)
        return outcome
    }

    /// Copies a local account into an Apple account that has no folder here yet: copy to a staging
    /// folder, check every file arrived, record the adoption, copy the account's settings, then move
    /// the staging folder into place in one rename. The local original is left as it was.
    static func adopt(_ source: AccountIdentity, into target: AccountIdentity, base: URL, files: FileManager,
                      suite: (AccountIdentity) -> String) throws -> Outcome {
        let from = AccountDirectory.folder(for: source, base: base), to = AccountDirectory.folder(for: target, base: base)
        if files.fileExists(atPath: to.path) {
            // An earlier launch moved the folder into place but stopped before switching.
            if AccountDirectory.formerOwners(of: to).contains(source.id) {
                try copySettings(from: suite(source), to: suite(target))
                return .adopted
            }
            return .openedExisting(keptLocalData: hasData(from, files: files) || hasSettings(suite(source)))
        }
        let staging = to.deletingLastPathComponent().appendingPathComponent(".incoming-" + target.id, isDirectory: true)
        // A staging folder left by an interrupted try is only ever a copy; the original is untouched.
        if files.fileExists(atPath: staging.path) { try files.removeItem(at: staging) }
        try files.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        if files.fileExists(atPath: from.path) {
            try files.copyItem(at: from, to: staging)
            guard try inventory(from, files: files) == inventory(staging, files: files) else {
                try? files.removeItem(at: staging)
                throw Failure.copyMismatch
            }
        } else {
            try files.createDirectory(at: staging, withIntermediateDirectories: true)
        }
        let earlier = AccountDirectory.formerOwners(of: staging)
        let adoption = AccountDirectory.Adoption(from: Array(earlier.union([source.id])).sorted())
        try JSONEncoder().encode(adoption).write(to: staging.appendingPathComponent(AccountDirectory.adoptedFile), options: .atomic)
        try copySettings(from: suite(source), to: suite(target))
        try files.moveItem(at: staging, to: to)
        return .adopted
    }

    /// Every regular file's relative path and size, plus a digest for files up to 4 MB (the state,
    /// settings, and records); large media is checked by size, as APFS copies it by cloning.
    static func inventory(_ folder: URL, files: FileManager) throws -> [String: String] {
        var result: [String: String] = [:]
        for path in try files.subpathsOfDirectory(atPath: folder.path) {
            let url = folder.appendingPathComponent(path)
            let attributes = try files.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { continue }
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            var entry = String(size)
            if size <= 4_000_000 { entry += ":" + SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() }
            result[path] = entry
        }
        return result
    }
    /// Copies the account's own settings (companion, account record, intro) into the new account's
    /// suite, never replacing a value it already has, and checks each one arrived.
    static func copySettings(from: String, to: String) throws {
        guard let source = UserDefaults(suiteName: from), let target = UserDefaults(suiteName: to) else { throw Failure.settingsUnavailable }
        let values = source.persistentDomain(forName: from) ?? [:]
        for (key, value) in values where target.object(forKey: key) == nil { target.set(value, forKey: key) }
        for key in values.keys where target.object(forKey: key) == nil { throw Failure.settingsNotCopied }
    }
    private static func hasData(_ folder: URL, files: FileManager) -> Bool {
        ((try? files.subpathsOfDirectory(atPath: folder.path)) ?? []).contains { !$0.hasPrefix(".") }
    }
    private static func hasSettings(_ suite: String) -> Bool {
        let values = UserDefaults(suiteName: suite)?.persistentDomain(forName: suite) ?? [:]
        return values.keys.contains { $0 != "kemo.accounts.settingsMoved" }
    }
}

// MARK: Finishing while the app runs

/// Finishes a waiting sign-in or sign-out while the app runs, so nobody has to reopen the app.
///
/// 1. `quiesce`: the app stops everything bound to the open account (replies, voice, the Mac's
///    coding agents) and writes whatever is pending, while that account is still the open one.
/// 2. The write fence closes (`AccountDirectory.beginSwitch`): from here on nothing writes into any
///    account's folder, and a store still holding the old account's paths never can again.
/// 3. `AccountSwitch.finishPending` copies, verifies, and switches (an Apple account that already
///    has a folder here opens as it is; the local original is never deleted).
/// 4. The fence opens for the account now current. Every shared store (`AccountRecords`,
///    `AccountStore`, `RoutineLedger`) is opened again for it, and `reopen` has the app open its own
///    stores and rebuild its UI (`.id` on the account), whose `@AppStorage` then reads the new
///    account's settings.
///
/// If step 3 fails, the device stays on the old account, the switch stays waiting for a retry or
/// the next launch, and everything reopens on the old account.
@MainActor enum LiveAccountSwitch {
    enum Result: Equatable {
        case nothingPending
        /// The app can't switch while it runs (no stores registered); the next launch finishes it.
        case deferred
        case finished(AccountSwitch.Outcome?)
        /// Nothing changed; the switch waits for a retry or the next launch.
        case failed
    }
    struct Hooks {
        var quiesce: @MainActor () -> Void
        var reopen: @MainActor () -> Void
    }
    /// Registered by the app once its account-bound stores exist.
    static var hooks: Hooks?

    /// Finishes the app's waiting switch with the app's registered stores.
    @discardableResult
    static func finish() -> Result { finish(defaults: AccountDirectory.settings, hooks: hooks) }

    @discardableResult
    static func finish(defaults: UserDefaults, hooks: Hooks?,
                       finishPending: () throws -> AccountSwitch.Outcome? = { try AccountSwitch.finishPending() }) -> Result {
        guard AccountSwitch.pending(defaults) != nil else { return .nothingPending }
        guard let hooks, !AccountDirectory.migrationFailed else { return .deferred }
        hooks.quiesce()
        AccountDirectory.beginSwitch()
        let result: Result
        do { result = .finished(try finishPending()) } catch { result = .failed }
        AccountDirectory.switchFailed = result == .failed
        AccountDirectory.endSwitch()
        reopenSharedStores()
        hooks.reopen()
        return result
    }
    /// Opens the shared account-bound stores again for the account now current.
    static func reopenSharedStores() {
        AccountRecords.reopen()
        AccountSyncService.shared.reopen()
        AccountStore.reopen()
        RoutineLedger.reopen()
    }
}

// MARK: Sign in with Apple

enum AppleCredentialState: String, Sendable { case authorized, revoked, notFound, transferred, unknown }

/// Asks Apple whether a Sign in with Apple user is still signed in to this app. Injected so the
/// session can be tested without Apple's servers.
protocol AppleCredentialChecking: Sendable {
    func state(for userIdentifier: String) async throws -> AppleCredentialState
}
struct AppleIDCredentialChecker: AppleCredentialChecking {
    func state(for userIdentifier: String) async throws -> AppleCredentialState {
        switch try await ASAuthorizationAppleIDProvider().credentialState(forUserID: userIdentifier) {
        case .authorized: .authorized
        case .revoked: .revoked
        case .notFound: .notFound
        case .transferred: .transferred
        @unknown default: .unknown
        }
    }
}

/// Where the Apple user identifier is kept: the Keychain, on this device only. It is never logged,
/// synced, or written to settings; folders and settings use its hash (`AccountIdentity.apple`).
protocol AppleUserIDStoring: Sendable {
    func read() -> String?
    func save(_ userIdentifier: String) throws
    func remove() throws
}
struct KeychainAppleUserID: AppleUserIDStoring {
    struct Failure: Error {}
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.zlichtman.kemosabe.sign-in-with-apple",
         kSecAttrAccount as String: "user"]
    }
    func read() -> String? {
        var query = query; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    func save(_ userIdentifier: String) throws {
        let fields: [String: Any] = [kSecValueData as String: Data(userIdentifier.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, fields as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(fields) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw Failure() }
        } else if status != errSecSuccess { throw Failure() }
    }
    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure() }
    }
}
/// For tests and previews.
final class MemoryAppleUserID: AppleUserIDStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    init(_ value: String? = nil) { self.value = value }
    func read() -> String? { lock.withLock { value } }
    func save(_ userIdentifier: String) throws { lock.withLock { value = userIdentifier } }
    func remove() throws { lock.withLock { value = nil } }
}

/// This device's Sign in with Apple state, and what the Account page shows.
@MainActor @Observable final class AppleAccountSession {
    static let shared = AppleAccountSession(finishNow: { LiveAccountSwitch.finish() })
    /// Whether this build carries the Sign in with Apple entitlement (the `KemoSignInWithApple`
    /// Info.plist switch, set from the `KEMO_SIGN_IN_WITH_APPLE` build setting). Without it Apple
    /// refuses the request, so the Account page says it's coming instead of showing the button.
    nonisolated static var availableInBuild: Bool {
        let value = Bundle.main.object(forInfoDictionaryKey: "KemoSignInWithApple")
        return (value as? Bool) == true || (value as? String)?.uppercased() == "YES"
    }
    static let scopesRequestedKey = "kemo.appleSignIn.scopesRequested"
    /// Where this build keeps the Apple user identifier. A build without Sign in with Apple never
    /// opens the Keychain item, so macOS doesn't ask to unlock another signature's sign-in.
    nonisolated static func storedUserID() -> AppleUserIDStoring { availableInBuild ? KeychainAppleUserID() : MemoryAppleUserID() }

    enum Status: Equatable {
        /// A local account; nothing links this device to others.
        case local
        /// Signed in, but moving to the Apple account hasn't finished yet (it couldn't be done
        /// while the app ran); it can be retried, and the next launch finishes it.
        case finishingSignIn
        /// Using the Apple account, and its sign-in is on this device.
        case linked
        /// Using the Apple account, but this device doesn't hold its sign-in (for example after a
        /// restore); signing in again confirms it.
        case needsConfirmation
        /// Signed out, but moving to a local account hasn't finished yet; as for `finishingSignIn`.
        case finishingSignOut
    }
    private(set) var status: Status = .local
    /// Something to tell the person, such as a revoked sign-in or a failed attempt.
    var notice: String?
    /// What the last launch's switch did, until the person dismisses it.
    private(set) var lastSwitch: AccountSwitch.Outcome?

    /// The account open now. It changes when a switch finishes while the app runs.
    private(set) var active: AccountIdentity
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let identifiers: AppleUserIDStoring
    @ObservationIgnored private let credentials: AppleCredentialChecking
    @ObservationIgnored private var revokedObserver: NSObjectProtocol?
    /// Finishes a requested switch while the app runs (`LiveAccountSwitch.finish`); nil leaves it
    /// for the next launch.
    @ObservationIgnored private let finishNow: (@MainActor () -> LiveAccountSwitch.Result)?

    init(active: AccountIdentity = AccountDirectory.current(), defaults: UserDefaults = AccountDirectory.settings,
         identifiers: AppleUserIDStoring = AppleAccountSession.storedUserID(), credentials: AppleCredentialChecking = AppleIDCredentialChecker(),
         observesRevocation: Bool = true, switchFailed: Bool = AccountDirectory.switchFailed,
         finishNow: (@MainActor () -> LiveAccountSwitch.Result)? = nil) {
        self.active = active; self.defaults = defaults; self.identifiers = identifiers; self.credentials = credentials
        self.finishNow = finishNow
        lastSwitch = AccountSwitch.lastOutcome(defaults)
        refresh()
        if switchFailed, AccountSwitch.pending(defaults) != nil { notice = Self.failedNotice }
        if observesRevocation {
            revokedObserver = NotificationCenter.default.addObserver(forName: ASAuthorizationAppleIDProvider.credentialRevokedNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.verify() }
            }
        }
    }

    func refresh() {
        let pending = AccountSwitch.pending(defaults)
        if active.kind == .apple {
            if let pending { status = pending.target.kind == .apple ? .finishingSignIn : .finishingSignOut; return }
            status = identifiers.read().map(AccountIdentity.apple(userIdentifier:)) == active ? .linked : .needsConfirmation
        } else {
            status = pending?.target.kind == .apple ? .finishingSignIn : .local
        }
    }
    /// Apple returns name and email only on the first authorization, so they're asked for only then.
    var requestsNameAndEmail: Bool { !defaults.bool(forKey: Self.scopesRequestedKey) }
    func prepare(_ request: ASAuthorizationAppleIDRequest) {
        request.requestedScopes = requestsNameAndEmail ? [.fullName, .email] : []
    }

    /// Handles the Sign in with Apple button's result.
    func handle(_ result: Result<ASAuthorization, Error>, account: AccountStore) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                notice = "That sign-in wasn't an Apple Account. Nothing changed."; return
            }
            do { try completeSignIn(userIdentifier: credential.user, fullName: credential.fullName, email: credential.email, account: account) }
            catch { notice = "Your sign-in couldn't be saved on this \(Self.device). Nothing changed. Try again." }
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            notice = "Sign in with Apple didn't finish. Nothing changed. Try again."
        }
    }

    /// Keeps the sign-in and schedules the switch. Name and email go only into the account record,
    /// and only when this device's own data is moving into the Apple account.
    func completeSignIn(userIdentifier: String, fullName: PersonNameComponents?, email: String?, account: AccountStore) throws {
        let target = AccountIdentity.apple(userIdentifier: userIdentifier)
        try identifiers.save(userIdentifier)
        defaults.set(true, forKey: Self.scopesRequestedKey)
        if active.kind == .local || target == active {
            let name = fullName.map { PersonNameComponentsFormatter.localizedString(from: $0, style: .default) }?.trimmingCharacters(in: .whitespacesAndNewlines)
            let email = email?.trimmingCharacters(in: .whitespacesAndNewlines)
            account.update { record in
                if record.name.isEmpty, let name, !name.isEmpty { record.name = name }
                if let email, !email.isEmpty { record.email = email }
            }
        }
        AccountSwitch.request(target, reason: .signIn, active: active, defaults: defaults)
        notice = nil
        finishRequested()
    }

    /// Signs out: forgets the sign-in on this device and returns to a local account, right away
    /// when the app can (otherwise at the next launch). Nothing is deleted; the Apple account's
    /// data stays here for the next sign-in.
    @discardableResult
    func signOut(revoked: Bool = false) -> LiveAccountSwitch.Result? {
        try? identifiers.remove()
        if active.kind == .apple {
            AccountSwitch.request(AccountSwitch.signedOutLocal(defaults), reason: revoked ? .revoked : .signOut, active: active, defaults: defaults)
            return finishRequested()
        }
        AccountSwitch.cancel(defaults)
        refresh()
        return nil
    }

    /// Whether this app finishes a switch in place (the iPhone and Mac apps) rather than only at
    /// the next launch.
    var finishesInPlace: Bool { finishNow != nil }
    /// Finishes the requested switch now when the app can. On failure nothing changed, the switch
    /// waits (for `retrySwitch` or the next launch), and the notice says so.
    @discardableResult
    private func finishRequested() -> LiveAccountSwitch.Result? {
        refresh()
        guard let finishNow, AccountSwitch.pending(defaults) != nil else { return nil }
        let result = finishNow()
        active = AccountDirectory.stored(defaults)
        lastSwitch = AccountSwitch.lastOutcome(defaults)
        if result == .failed { notice = Self.failedNotice }
        refresh()
        return result
    }
    /// Tries a switch that couldn't finish again, without reopening the app.
    func retrySwitch() {
        notice = nil
        finishRequested()
    }

    /// Checks with Apple that the sign-in still stands (at launch, and when Apple says it was
    /// revoked). Revoked or unknown to Apple signs this device out; being offline changes nothing.
    func verify() async {
        refresh()
        guard status == .linked, let userIdentifier = identifiers.read() else { return }
        guard let state = try? await credentials.state(for: userIdentifier) else { return }
        guard status == .linked, state == .revoked || state == .notFound else { return }
        if case .finished? = signOut(revoked: true) {
            notice = "Sign in with Apple was turned off for \(Self.appName), so this \(Self.device) signed out. Your data stays here."
        } else {
            notice = "Sign in with Apple was turned off for \(Self.appName), so this \(Self.device) is signing out. Your data stays here. \(Self.finishHint)"
        }
    }

    func dismissLastSwitch() {
        defaults.removeObject(forKey: AccountSwitch.outcomeKey)
        lastSwitch = nil
    }

    // MARK: Words

    nonisolated static var appName: String {
        #if os(macOS)
        "Tsukumo"
        #else
        "KemoSabe"
        #endif
    }
    nonisolated static var device: String {
        #if os(macOS)
        "Mac"
        #else
        "iPhone"
        #endif
    }
    /// The fallback when a switch couldn't finish while the app ran.
    nonisolated static var finishHint: String {
        #if os(macOS)
        "Try again, or restart Tsukumo to finish."
        #else
        "Try again, or close KemoSabe from the app switcher and open it again to finish."
        #endif
    }
    nonisolated static var failedNotice: String {
        "Your account couldn't be switched on this \(device) yet, so nothing was changed. \(finishHint)"
    }
    /// Never claims sync is running in a build that can't sync (before the iCloud container exists).
    static var linkedNote: String {
        AccountSyncService.availableInBuild
            ? "Linked to your KemoSabe account. Your iPhone, Mac, and Apple Watch share it: one account and one profile."
            : "Linked to your KemoSabe account. Syncing between devices starts once iCloud is set up."
    }
    /// The other device people sign in on: the Mac from iPhone, and the iPhone from the Mac.
    nonisolated static var otherDevice: String {
        #if os(macOS)
        "iPhone"
        #else
        "Mac"
        #endif
    }
    /// One account everywhere (the owner, September 25, 2026): signing in on a second device joins
    /// the same account, never a new one. Apple's user identifier is the same for every app in the
    /// team, so the same Apple Account opens the same KemoSabe account on iPhone and Mac.
    nonisolated static var oneAccountNote: String {
        "Sign in with the same Apple Account you use on your \(otherDevice). It's one KemoSabe account for iPhone, Mac, and Apple Watch."
    }
    var statusTitle: String {
        switch status {
        case .local: "Not signed in"
        case .finishingSignIn: "Sign-in not finished"
        case .linked: "Linked"
        case .needsConfirmation: "Confirm your sign-in"
        case .finishingSignOut: "Sign-out not finished"
        }
    }
    var statusDetail: String {
        switch status {
        case .local:
            "\(Self.oneAccountNote) \(Self.appName) gets a private ID from Apple (and your name and email the first time), never your password."
        case .finishingSignIn:
            "This \(Self.device) is still on its earlier account; nothing was changed. \(Self.finishHint) Your data on this \(Self.device) moves into your Apple Account then; nothing is deleted."
        case .linked:
            Self.linkedNote
        case .needsConfirmation:
            "This \(Self.device) is using your Apple Account's data but doesn't have its sign-in. Sign in with Apple again to confirm it."
        case .finishingSignOut:
            "This \(Self.device) is still on your Apple Account. \(Self.finishHint) Your Apple Account's data stays on this \(Self.device) and comes back when you sign in again."
        }
    }
    var lastSwitchNote: String? {
        switch lastSwitch {
        case nil: nil
        case .adopted?: "Your data on this \(Self.device) is now part of your Apple Account. The earlier local copy is kept on this \(Self.device) as it was."
        case .openedExisting(let kept)?:
            "This \(Self.device) already had data for your Apple Account, so \(Self.appName) opened it." + (kept ? " What you did while signed out is kept separately on this \(Self.device) and wasn't merged; signing out brings it back." : "")
        case .switched?: "Switched Apple Accounts. The other account's data stays on this \(Self.device), unchanged."
        case .signedOut(let revoked)?:
            (revoked ? "Sign in with Apple was turned off, so this \(Self.device) signed out. " : "Signed out. ")
                + "Your Apple Account's data stays on this \(Self.device) and comes back when you sign in again."
        }
    }
}

extension AppleAccountSession {
    /// KemoSabe and Tsukumo need an account (the owner, September 25, 2026: "Sign out takes you back
    /// to login, must have account to use"). Builds without Sign in with Apple, unit test hosts, and
    /// UI tests (unless they pass --require-account) keep working on a local account.
    nonisolated static var accountRequired: Bool {
        guard availableInBuild, !AccountDirectory.isTestHost else { return false }
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing"), !arguments.contains("--require-account") { return false }
        #endif
        return true
    }
    /// On a local account (a new install, or just signed out) or an Apple account whose sign-in
    /// isn't on this device: the sign-in screen covers the app until you sign in.
    var needsSignIn: Bool { Self.accountRequired && (status == .local || status == .needsConfirmation) }
}

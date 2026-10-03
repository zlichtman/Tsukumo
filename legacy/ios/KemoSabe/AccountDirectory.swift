import Foundation
import CryptoKit

/// Who owns the personal data on this device. Every durable personal record lives in the
/// current account's folder, so a different account never opens, merges, or overwrites it.
///
/// A device starts with a local account, created once. Signing in with Apple moves the device
/// to the Apple account (`AccountSwitch`): the first time, the local folder is copied into the
/// Apple account's folder; an Apple account that already has a folder here is opened as it is.
struct AccountIdentity: Codable, Equatable, Hashable, Sendable {
    /// `apple` is the account everything syncs and shares under: the Sign in with Apple user,
    /// which CloudKit and any future server can both verify, so moving off CloudKit never
    /// re-links anyone. `iCloud` is kept for data written before that decision.
    enum Kind: String, Codable, Sendable { case local, iCloud, apple }
    /// Stable and folder-safe: letters, digits, and hyphens.
    let id: String
    let kind: Kind
    static func newLocal() -> AccountIdentity { .init(id: "local-" + UUID().uuidString.lowercased(), kind: .local) }
    /// The account for a Sign in with Apple user identifier (which contains dots, so it's hashed
    /// into a folder-safe ID). The same Apple user gets the same ID on every device.
    static func apple(userIdentifier: String) -> AccountIdentity {
        let digest = SHA256.hash(data: Data(userIdentifier.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return .init(id: "apple-" + digest, kind: .apple)
    }
}

enum AccountDirectory {
    static let currentKey = "kemo.account.current"
    static let migratedKey = "kemo.accounts.migrated"
    /// Personal items that lived directly in the app's folder before accounts; they move into
    /// the account's folder once. Device settings (appearance, window, projects) stay per device.
    static let personalItems = ["state.json", "state.before-v1.json", "routines.json", "context-runs.json",
                                "private-preferences.json", "Profile", "Account"]

    /// Tests (the Mac's run inside the real, unsandboxed app) get their own folder and settings,
    /// so they never move, read, or write the person's data.
    static let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    static let base: URL = isTestHost
        ? FileManager.default.temporaryDirectory.appendingPathComponent("KemoSabeTestAccounts-" + UUID().uuidString, isDirectory: true)
        : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("KemoSabe", isDirectory: true)
    static let settings: UserDefaults = isTestHost ? (UserDefaults(suiteName: "kemo.accounts.tests") ?? .standard) : .standard
    static func folder(for account: AccountIdentity, base: URL = AccountDirectory.base) -> URL {
        base.appendingPathComponent("Accounts", isDirectory: true).appendingPathComponent(account.id, isDirectory: true)
    }

    /// The saved signed-in account, without creating one: nil when none is saved (signed out) or
    /// the record can't be read. Observers use it to follow sign-in, sign-out, and switches.
    static func saved(_ defaults: UserDefaults = AccountDirectory.settings) -> AccountIdentity? {
        guard let data = defaults.data(forKey: currentKey), let saved = try? JSONDecoder().decode(AccountIdentity.self, from: data),
              validID(saved.id) else { return nil }
        return saved
    }
    static func validID(_ id: String) -> Bool { !id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }

    /// Where an unreadable current-account record is kept, untouched, for recovery or support.
    static let unreadableKey = "kemo.account.current.unreadable"
    /// The account adopted from its folder when the record couldn't be read (for diagnostics).
    static let recoveredKey = "kemo.account.current.recovered"

    /// The account this device is signed in to, created as a local account the first time.
    /// For the app's own settings, a sign-in or sign-out waiting from the last launch is
    /// finished first, so every caller in this process sees the same account.
    static func current(_ defaults: UserDefaults = AccountDirectory.settings, base: URL = AccountDirectory.base) -> AccountIdentity {
        if defaults === settings { _ = preparation }
        return stored(defaults, base: base)
    }
    /// The saved account, without finishing a waiting switch.
    ///
    /// A record that exists but can't be read is never silently replaced by a new, empty
    /// account: its bytes are set aside under `unreadableKey`, and the account whose folder is on
    /// this device is adopted again (the most recently used one if there are several). Only
    /// when no account folder exists is a new local account created.
    static func stored(_ defaults: UserDefaults, base: URL = AccountDirectory.base) -> AccountIdentity {
        if let saved = saved(defaults) { return saved }
        let account: AccountIdentity
        if let damaged = defaults.data(forKey: currentKey) {
            if defaults.data(forKey: unreadableKey) == nil { defaults.set(damaged, forKey: unreadableKey) }
            if let recovered = recoverFromFolders(base: base) {
                account = recovered
                defaults.set(recovered.id, forKey: recoveredKey)
            } else { account = .newLocal() }
        } else { account = .newLocal() }
        defaults.set(try? JSONEncoder().encode(account), forKey: currentKey)
        return account
    }
    /// The account folders on this device, most recently used first. Only IDs this app creates
    /// (`local-…`, `apple-…`) count; the folder name is the ID.
    static func recoverFromFolders(base: URL = AccountDirectory.base, files: FileManager = .default) -> AccountIdentity? {
        let accounts = base.appendingPathComponent("Accounts", isDirectory: true)
        guard let names = try? files.contentsOfDirectory(atPath: accounts.path) else { return nil }
        func lastUsed(_ folder: URL) -> Date {
            let items = [folder] + ((try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            return items.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max() ?? .distantPast
        }
        let candidates: [(AccountIdentity, Date)] = names.compactMap { name in
            guard validID(name) else { return nil }
            let kind: AccountIdentity.Kind
            if name.hasPrefix("local-") { kind = .local } else if name.hasPrefix("apple-") { kind = .apple } else { return nil }
            var isFolder: ObjCBool = false
            let folder = accounts.appendingPathComponent(name, isDirectory: true)
            guard files.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else { return nil }
            return (AccountIdentity(id: name, kind: kind), lastUsed(folder))
        }
        return candidates.max { $0.1 < $1.1 }?.0
    }

    /// Settings that belong to the person rather than the device: the companion's name,
    /// personality, and characters, the account record, and intro progress. Kept in the
    /// account's own settings file; appearance, windows, and developer switches stay per device.
    static let accountKeys = ["kemo.companion.name", "kemo.companion.named", "kemo.companion.personality", "kemo.companion.characters",
                              "kemo.intro.step", "kemo.account", "kemo.account.companionUpdated", "kemo.account.unreadable",
                              "kemo.profile.name", "kemo.profile.bio"]
    static func settingsSuite(for account: AccountIdentity) -> String {
        (isTestHost ? "kemo.tests.account." : "kemo.account.") + account.id
    }
    /// The current account's own settings. It follows the account: once a sign-in or sign-out
    /// finishes while the app runs (`LiveAccountSwitch`), the next read returns the new account's.
    static var accountSettings: UserDefaults {
        let account = current()
        return fence.withLock {
            if let open = openSettings, open.id == account.id { return open.store }
            guard let store = UserDefaults(suiteName: settingsSuite(for: account)) else { return .standard }
            // Settings saved before accounts move into the first account opened in this process.
            // While earlier settings may still be on their way (see `holdLegacyMigration`), the move
            // waits; `releaseLegacyHold()` does it once they've arrived.
            if openSettings == nil, !isTestHost, !holdLegacyMigration { moveAccountSettings(from: .standard, to: store) }
            openSettings = (account.id, store)
            return store
        }
    }
    private static var openSettings: (id: String, store: UserDefaults)?
    /// Moves account settings saved before accounts into the account's settings, once.
    static func moveAccountSettings(from device: UserDefaults, to account: UserDefaults) {
        guard !account.bool(forKey: "kemo.accounts.settingsMoved") else { return }
        for key in accountKeys {
            guard let value = device.object(forKey: key) else { continue }
            if account.object(forKey: key) == nil { account.set(value, forKey: key) }
        }
        account.set(true, forKey: "kemo.accounts.settingsMoved")
        // Only after every value is in the account's settings are the device copies removed.
        for key in accountKeys { device.removeObject(forKey: key) }
    }

    /// The current account's folder, after moving pre-account data into it (once per launch).
    static var currentFolder: URL {
        _ = preparation
        return folder(for: current())
    }
    /// Whether this launch's move of pre-account data failed; the app then saves nothing
    /// until a retry succeeds, so an empty store can't replace data still waiting to move.
    private(set) static var migrationFailed = false
    /// What finishing a waiting sign-in or sign-out did at this launch, if one was waiting.
    private(set) static var launchSwitch: AccountSwitch.Outcome?
    /// Set when a waiting switch couldn't finish, at launch or while the app ran; the device stays
    /// on its current account and tries again (live on request, and at the next launch).
    static var switchFailed: Bool {
        get { fence.withLock { failedSwitch } }
        set { fence.withLock { failedSwitch = newValue } }
    }
    private static var failedSwitch = false
    /// Set, before anything opens account storage, when earlier data is still on its way into
    /// `base` (the Mac's copy out of its old sandbox container failed this launch). While set,
    /// nothing is moved into the account and `migrationFailed` holds saving off; moving a
    /// partial set now and marking the move done would strand whatever arrives later.
    static var holdLegacyMigration = false
    private static let preparation: Void = {
        migrationFailed = holdLegacyMigration || (try? migrateLegacy()) == nil
        // A switch left waiting (one that couldn't finish while the app ran) finishes here, before
        // anything opens account data. While the app runs, `LiveAccountSwitch` does it instead.
        guard !migrationFailed, !isTestHost else { return }
        do { launchSwitch = try AccountSwitch.finishPending() } catch { switchFailed = true }
    }()
    /// Opens account storage for this process (see `preparation`), once.
    static func prepare() { _ = preparation }
    /// Retries the move after a failure (see `AppStore.holdStorage`).
    static func retryMigration() -> Bool {
        guard !holdLegacyMigration else { migrationFailed = true; return false }
        migrationFailed = (try? migrateLegacy()) == nil
        return !migrationFailed
    }
    /// Ends the hold once the earlier data has arrived: brings over the settings held back with
    /// it, then moves pre-account items into the account. Returns whether that move succeeded.
    static func releaseLegacyHold() -> Bool {
        holdLegacyMigration = false
        if !isTestHost { moveAccountSettings(from: .standard, to: accountSettings) }
        return retryMigration()
    }

    /// Moves each pre-account item into the account's folder. A move on the same volume is a
    /// rename, so each item is either fully moved or untouched; an interrupted run finishes the
    /// rest next time. An item already in the account folder is kept, with the older one beside it.
    static func migrateLegacy(base: URL = AccountDirectory.base, account: AccountIdentity? = nil,
                              defaults: UserDefaults = AccountDirectory.settings, files: FileManager = .default) throws {
        guard !defaults.bool(forKey: migratedKey) else { return }
        let account = account ?? stored(defaults)
        let destination = folder(for: account, base: base)
        let pending = personalItems.filter { files.fileExists(atPath: base.appendingPathComponent($0).path) }
        if !pending.isEmpty {
            try files.createDirectory(at: destination, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var accounts = base.appendingPathComponent("Accounts", isDirectory: true)
            try? accounts.setResourceValues(values)
            for name in pending {
                var target = destination.appendingPathComponent(name)
                if files.fileExists(atPath: target.path) { target = destination.appendingPathComponent("from-before-accounts-" + name) }
                guard !files.fileExists(atPath: target.path) else { continue }
                try files.moveItem(at: base.appendingPathComponent(name), to: target)
            }
        }
        defaults.set(true, forKey: migratedKey)
    }

    // MARK: Write fence

    /// Guards the moment this device moves from one account to another while the app runs
    /// (`LiveAccountSwitch`). While a switch is under way nothing may write into any account's
    /// folder, and afterwards only the account now open may be written: a store, task, or late
    /// callback still holding the old account's paths is refused instead of changing its data.
    private static let fence = NSLock()
    private static var switching = false
    struct WriteRefused: LocalizedError {
        var errorDescription: String? { "Your account is changing, so this wasn't saved." }
    }
    static var isSwitching: Bool { fence.withLock { switching } }
    static func beginSwitch() { fence.withLock { switching = true } }
    static func endSwitch() { fence.withLock { switching = false } }
    /// The account whose folder holds `url`, when it's inside this device's account folders.
    static func owner(of url: URL, base: URL = AccountDirectory.base) -> String? {
        let accounts = base.appendingPathComponent("Accounts", isDirectory: true).standardizedFileURL.pathComponents
        let path = url.standardizedFileURL.pathComponents
        guard path.count > accounts.count, Array(path.prefix(accounts.count)) == accounts else { return nil }
        return path[accounts.count]
    }
    /// Whether `url` may be written now: anything outside the account folders may; inside them,
    /// only the open account's folder, and nothing while a switch is under way.
    static func permitsWrite(to url: URL, base: URL = AccountDirectory.base, defaults: UserDefaults = AccountDirectory.settings) -> Bool {
        guard let owner = owner(of: url, base: base) else { return true }
        if isSwitching { return false }
        guard let open = saved(defaults) else { return true }
        return owner == open.id
    }
    static func checkWrite(to url: URL) throws {
        guard permitsWrite(to: url) else { throw WriteRefused() }
    }
    /// Whether settings opened for `accountID` may still be written (see `permitsWrite`).
    static func permitsSettingsWrite(for accountID: String, defaults: UserDefaults = AccountDirectory.settings) -> Bool {
        if isSwitching { return false }
        return saved(defaults).map { $0.id == accountID } ?? true
    }

    // MARK: Former owners

    /// A folder adopted from a local account records that account's ID, so what it saved still
    /// opens under the Apple account, and is saved as the Apple account's from then on.
    static let adoptedFile = "adopted.json"
    struct Adoption: Codable, Equatable { var from: [String] }
    static func formerOwners(of folder: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(adoptedFile)),
              let adoption = try? JSONDecoder().decode(Adoption.self, from: data) else { return [] }
        return Set(adoption.from)
    }
    /// The current account's former owners, for the owner checks on its files.
    static var currentFormerOwners: Set<String> { formerOwners(of: currentFolder) }
}

import Foundation
import Observation

/// Your account: who you are and who your companion is, the same on iPhone, Mac,
/// and watch. It holds only what every device shows — your name, handle, and
/// photo, and the companion's name, personality, and look.
///
/// Signed in with Apple, the account and companion are sync records (`AccountRecords`,
/// `AccountSyncAdapter`) that account sync carries between devices (`AccountSyncService`). The
/// older iCloud key-value path (`cloudEnabled`) stays off.
/// Friends and shared profiles arrive with CloudKit (design/ACCOUNTS-AND-PROFILES.md).
struct KemoAccount: Codable, Equatable {
    var name = ""
    var handle = ""
    /// The account photo, as a file next to the account record; nil shows your companion.
    var photoFile: String?
    /// The email Apple shared at the first Sign in with Apple (possibly a private relay address).
    /// It stays in this record only: never logged, and not part of what syncs.
    var email: String?
    /// When any synced field last changed, to settle which device's edit wins.
    var updated = Date.distantPast

    var firstName: String? { name.split(separator: " ").first.map(String.init) }
}

@MainActor @Observable final class AccountStore {
    /// The open account's store; replaced when the account changes while the app runs.
    private(set) static var shared = AccountStore.forCurrentAccount()
    static func forCurrentAccount() -> AccountStore {
        AccountStore(defaults: AccountDirectory.accountSettings, records: .shared, openedFor: AccountDirectory.current().id)
    }
    static func reopen() { shared.close(); shared = forCurrentAccount() }
    private(set) var account = KemoAccount()
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let cloud: NSUbiquitousKeyValueStore?
    /// The account's sync records, where the account and companion are queued for other devices.
    @ObservationIgnored private let records: AccountRecords?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var companionObserver: NSObjectProtocol?
    /// True while another device's edits are applied, so they aren't sent straight back.
    @ObservationIgnored private var applyingRemote = false
    /// The account this store was opened for; its settings are written only while that account is
    /// open (nil for stores not bound to an account, as in tests).
    @ObservationIgnored private let openedFor: String?
    /// Set once the account changed; nothing more is saved or queued.
    @ObservationIgnored private var closed = false
    static let key = "kemo.account"
    static let unreadableKey = "kemo.account.unreadable"
    private static let cloudKey = "account"

    /// iCloud sync turns on with the `KemoCloudSync` Info.plist switch, added together with the
    /// iCloud key-value entitlement; without the entitlement the store would do nothing.
    nonisolated static var cloudEnabled: Bool { Bundle.main.object(forInfoDictionaryKey: "KemoCloudSync") as? Bool == true }

    init(defaults: UserDefaults = .standard, cloud: NSUbiquitousKeyValueStore? = AccountStore.cloudEnabled ? .default : nil, records: AccountRecords? = nil,
         openedFor: String? = nil, photoFolder: URL? = nil) {
        self.defaults = defaults
        self.openedFor = openedFor
        self.fixedPhotoFolder = photoFolder
        self.cloud = cloud
        self.records = records
        if let data = defaults.data(forKey: Self.key) {
            if let saved = try? JSONDecoder().decode(KemoAccount.self, from: data) { account = saved }
            // An unreadable record is set aside, never overwritten, before a fresh one is used.
            else if defaults.data(forKey: Self.unreadableKey) == nil { defaults.set(data, forKey: Self.unreadableKey) }
        }
        observer = NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: cloud, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pull() }
        }
        companionObserver = NotificationCenter.default.addObserver(forName: CompanionIdentity.changed, object: nil, queue: nil) { [weak self] _ in
            guard Thread.isMainThread else { return DispatchQueue.main.async { MainActor.assumeIsolated { self?.companionChanged() } } }
            MainActor.assumeIsolated { if self?.applyingRemote == false { self?.companionChanged() } }
        }
    }

    /// Your name for greetings and the account row, falling back to the device owner's name.
    var displayName: String {
        if !account.name.isEmpty { return account.name }
        #if os(macOS)
        return NSFullUserName()
        #else
        return ""
        #endif
    }
    var firstName: String { displayName.split(separator: " ").first.map(String.init) ?? "You" }
    /// Stops observing and saving: the device moved to another account.
    func close() {
        closed = true
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let companionObserver { NotificationCenter.default.removeObserver(companionObserver) }
        observer = nil; companionObserver = nil
    }
    /// Whether this store may still write its account's settings.
    private var writable: Bool { !closed && (openedFor.map { AccountDirectory.permitsSettingsWrite(for: $0) } ?? true) }

    func update(_ change: (inout KemoAccount) -> Void) {
        var next = account
        change(&next)
        next.name = String(next.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        next.handle = String(next.handle.lowercased().filter { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "." || $0 == "_" }.prefix(30))
        next.email = next.email.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(320)) }.flatMap { $0.isEmpty ? nil : $0 }
        guard next != account else { return }
        next.updated = Date()
        account = next
        save()
        push()
    }

    // MARK: Photo

    static var folder: URL {
        AccountDirectory.currentFolder.appendingPathComponent("Account", isDirectory: true)
    }
    /// Where the photo is kept: the open account's folder, or one given for tests.
    @ObservationIgnored private let fixedPhotoFolder: URL?
    var photoFolder: URL { fixedPhotoFolder ?? Self.folder }
    var photoURL: URL? { account.photoFile.map { photoFolder.appendingPathComponent($0) } }
    /// Called after the photo changes on this device, so a sync can follow soon.
    @ObservationIgnored var onPhotoChanged: (@MainActor () -> Void)?
    /// Stores a new account photo (already-encoded JPEG or PNG data), replacing the old one.
    func setPhoto(_ data: Data?) throws {
        let old = photoURL
        var file: String?
        if let data { file = try writePhoto(data) }
        update { $0.photoFile = file }
        if let old, old != photoURL { try? FileManager.default.removeItem(at: old) }
        onPhotoChanged?()
    }
    private func writePhoto(_ data: Data) throws -> String {
        guard writable else { throw AccountDirectory.WriteRefused() }
        try AccountDirectory.checkWrite(to: photoFolder)
        try FileManager.default.createDirectory(at: photoFolder, withIntermediateDirectories: true)
        let name = UUID().uuidString + ".jpg"
        try data.write(to: photoFolder.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return name
    }
    /// The photo file as it is now, for sync (`ProfileImageSyncAdapter`): `.some(nil)` when there's
    /// no photo, nil when its file can't be read now.
    func syncedPhoto() -> Data?? {
        guard let url = photoURL, FileManager.default.fileExists(atPath: url.path) else { return .some(nil) }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return .some(data)
    }
    /// Takes the picture another device set (nil removes it), as it came. The photo isn't part of
    /// the account record, so this doesn't make the name look newly edited.
    func applySyncedPhoto(_ data: Data?) -> Bool {
        guard writable else { return false }
        let old = photoURL
        var file: String?
        if let data {
            do { file = try writePhoto(data) } catch { return false }
        }
        account.photoFile = file
        save()
        if let old, old != photoURL { try? FileManager.default.removeItem(at: old) }
        return true
    }

    // MARK: Sync

    /// What travels between your devices: the account text and the companion's identity.
    struct Synced: Codable, Equatable {
        var name: String
        var handle: String
        var companionName: String
        var personality: String?
        var paletteID: String?
        var updated: Date
    }
    /// The palette to show on other devices; set by the app that owns the theme.
    @ObservationIgnored var currentPaletteID: () -> String? = { nil }
    @ObservationIgnored var applyPalette: (String) -> Void = { _ in }

    func push() {
        guard writable else { return }
        record()
        guard let cloud else { return }
        let synced = Synced(name: account.name, handle: account.handle, companionName: CompanionIdentity.name,
                            personality: CompanionIdentity.personality?.rawValue, paletteID: currentPaletteID(), updated: max(account.updated, companionUpdated))
        guard let data = try? JSONEncoder().encode(synced) else { return }
        cloud.set(data, forKey: Self.cloudKey)
        cloud.synchronize()
    }
    /// Takes another device's newer edits.
    func pull() {
        guard writable, let cloud, let data = cloud.data(forKey: Self.cloudKey), let synced = try? JSONDecoder().decode(Synced.self, from: data) else { return }
        guard synced.updated > max(account.updated, companionUpdated) else { return }
        applyingRemote = true
        defer { applyingRemote = false }
        account.name = synced.name; account.handle = synced.handle; account.updated = synced.updated
        save()
        CompanionIdentity.set(synced.companionName)
        CompanionIdentity.setPersonality(synced.personality.flatMap(CompanionPersonality.init(rawValue:)))
        companionUpdated = synced.updated
        if let palette = synced.paletteID { applyPalette(palette) }
    }
    /// Call after the companion's name, personality, or look changes on this device.
    func companionChanged() { companionUpdated = Date(); push() }
    private var companionUpdated: Date {
        get { defaults.object(forKey: "kemo.account.companionUpdated") as? Date ?? .distantPast }
        set { defaults.set(newValue, forKey: "kemo.account.companionUpdated") }
    }
    func sync() { cloud?.synchronize(); pull(); push() }
    /// Queues the account and companion in the account's personal sync zone, for a transport to
    /// carry to your other devices once iCloud is set up. The email isn't part of it.
    func record() {
        guard writable, let records else { return }
        records.put(AccountRecords.Account(name: account.name, handle: account.handle), id: AccountRecords.accountID, type: SyncType.account)
        records.put(AccountRecords.Companion(name: CompanionIdentity.name, personality: CompanionIdentity.personality?.rawValue, paletteID: currentPaletteID()),
                    id: AccountRecords.companionID, type: SyncType.companion)
    }

    private func save() {
        guard writable else { return }
        defaults.set(try? JSONEncoder().encode(account), forKey: Self.key)
    }

    // MARK: Account sync (AccountSyncAdapter)

    /// Whether the store is still open for its account, so sync may read and apply.
    var syncable: Bool { writable }
    /// What syncs: the account (never the email or photo file) and the companion.
    var syncedValues: (account: AccountRecords.Account, companion: AccountRecords.Companion)? {
        guard writable else { return nil }
        return (.init(name: account.name, handle: account.handle),
                .init(name: CompanionIdentity.name, personality: CompanionIdentity.personality?.rawValue, paletteID: currentPaletteID()))
    }
    /// Takes another device's name and handle.
    func applySynced(_ remote: AccountRecords.Account) -> Bool {
        guard writable else { return false }
        guard remote.name != account.name || remote.handle != account.handle else { return true }
        account.name = remote.name; account.handle = remote.handle; account.updated = Date()
        save()
        return true
    }
    /// Takes another device's companion: its name, personality, and palette.
    func applySynced(_ remote: AccountRecords.Companion) -> Bool {
        guard writable else { return false }
        applyingRemote = true
        defer { applyingRemote = false }
        if remote.name != CompanionIdentity.name { CompanionIdentity.set(remote.name, defaults: defaults) }
        if remote.personality != CompanionIdentity.personality?.rawValue {
            CompanionIdentity.setPersonality(remote.personality.flatMap(CompanionPersonality.init(rawValue:)), defaults: defaults)
        }
        if let palette = remote.paletteID, palette != currentPaletteID() { applyPalette(palette) }
        companionUpdated = Date()
        return true
    }
}

/// The account's plan, shown under your name as Codex shows its plan. A placeholder: there are
/// no paid plans yet, so everyone is on Free.
enum AccountPlan {
    static let current = "Free"
}

extension ProfileImageSyncAdapter {
    /// The account photo, which the Mac shows as your picture: the same record as the iPhone's
    /// profile picture. The Mac has no cover, so it leaves the cover's record alone.
    static func forAccountPhoto(_ account: AccountStore) -> ProfileImageSyncAdapter {
        ProfileImageSyncAdapter(slots: [
            .init(id: pictureID, type: SyncType.profilePicture, maxSide: pictureSide, read: { account.syncedPhoto() }, write: { account.applySyncedPhoto($0) })
        ], isOpen: { account.syncable })
    }
    /// The open account's photo, with a change starting a sync.
    static func forSharedAccountPhoto() -> ProfileImageSyncAdapter {
        AccountStore.shared.onPhotoChanged = { AccountSyncService.shared.localChanged() }
        return forAccountPhoto(.shared)
    }
}

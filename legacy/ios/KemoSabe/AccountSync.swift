import Foundation

/// Sync for one account, behind a transport boundary. Everything that syncs is a
/// `SyncRecord`: a stable ID, a type, a zone, a modification time, and a JSON payload. The
/// transport only moves records; merging, privacy rules, and storage live here. CloudKit is
/// the first transport (a private database for the account, one shared zone per shared
/// project); a server can replace it later without touching the app's data or UI.
/// See design/ACCOUNTS-AND-PROFILES.md and design/TSUKUMO-BUILD-ENVIRONMENT.md.
struct SyncRecord: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var type: String
    var zone: SyncZone
    var modified: Date
    /// The device that made this version; breaks ties between equal times.
    var device: String
    var payload: Data
    var deleted = false

    /// Two records are the same thing when their zone and ID match.
    var key: String { zone.name + "/" + id }
}

enum SyncZone: Codable, Hashable, Sendable {
    /// The account's own data, never visible to anyone else.
    case personal
    /// A project shared with other people (presence, tasks, claims, messages).
    case shared(project: String)
    /// Your profile as one person you share it with may see it: a projection holding only the
    /// blocks they're allowed, read-only for them (`ProfileSharingStore`, one zone per person).
    case profileShare(String)
    var name: String {
        switch self {
        case .personal: "personal"
        case .shared(let project): "project-" + project
        case .profileShare(let person): "profile-" + person
        }
    }
    /// Whether anyone but you can read the zone.
    var isShared: Bool { self != .personal }
}

/// Record types. Private ones can never be written to a shared zone, whatever the caller does.
enum SyncType {
    static let companion = "companion", conversation = "conversation", memory = "memory", project = "project"
    static let peopleNote = "people.note", profile = "profile", account = "account"
    /// A Library draft, a conversation folder, and one of the person's own settings.
    static let draft = "draft", chatProject = "chat.project", setting = "setting"
    /// A model connection without its key (keys stay in each device's Keychain), one custom palette,
    /// and the preferences kept in the app's store: the default model, efforts, and voice pace and
    /// conversation switches (`AppStoreSyncAdapter`).
    static let modelConnection = "model.connection", palette = "palette", preferences = "preferences"
    static let collabTask = "collab.task", collabPresence = "collab.presence", collabMessage = "collab.message", collabOwner = "collab.owner"
    /// One device's short-lived notices for the person's other devices (`NoticeBoard`): no message text.
    static let notice = "notice"
    /// A Docs page, a journal entry, and an image either one uses (`DocsSyncAdapter`).
    static let docPage = "doc.page", journalEntry = "journal.entry", docAsset = "doc.asset"
    /// Your own profile picture and cover, for your other devices (`ProfileImageSyncAdapter`). What
    /// people you share your profile with see is a separate, smaller copy (`sharedImage`).
    static let profilePicture = "profile.picture", profileCover = "profile.cover"
    /// Chats, memories, drafts, private People notes, the companion, the account record, the
    /// person's settings, device notices, Docs, Journal, and your profile picture and cover stay in
    /// the account's personal zone.
    static let personalOnly: Set<String> = [conversation, memory, peopleNote, companion, account, draft, chatProject, setting, notice, docPage, journalEntry, docAsset,
                                            profilePicture, profileCover, modelConnection, palette, preferences]
    static let shareable: Set<String> = [collabTask, collabPresence, collabMessage, collabOwner, profile]
    /// What a profile share may hold, and nothing else: the header (name, picture, headline), one
    /// record per block the person may see, and the images those use (`ProfileProjection`). Your
    /// whole profile record (`profile`) isn't among them, since it holds every block.
    static let sharedHeader = "shared.header", sharedBlock = "shared.block", sharedImage = "shared.image"
    static let profileShareable: Set<String> = [sharedHeader, sharedBlock, sharedImage]
}

enum SyncError: Error, Equatable {
    case privateInSharedZone(String)
    case notShareable(String)
    case unavailable(String)
    /// Offline, or iCloud asked us to wait; nothing was lost and the next sync retries.
    case network(String)
    /// The person's iCloud storage is full.
    case quotaExceeded
    /// This device isn't signed in to iCloud, or iCloud is restricted.
    case iCloudUnavailable(String)
    /// The device's iCloud account isn't the one this app account synced with before, so syncing
    /// stops rather than mixing two people's data.
    case iCloudAccountMismatch
    /// The account's zone is gone from iCloud (for example, its data was deleted in Settings):
    /// everything on this device has to be sent again.
    case resetRequired
    /// The saved sync state couldn't be read (for example, while the device is locked). Nothing
    /// is written or sent until it opens.
    case stateUnreadable
}

/// Moves records between this device and the account's store. `pull` returns everything
/// changed since `token` and a new token to pass next time.
protocol SyncTransport: Sendable {
    func push(_ records: [SyncRecord]) async throws
    func pull(since token: Data?) async throws -> (records: [SyncRecord], token: Data?)
    /// Whether this transport carries a zone's records; others stay queued until one does.
    func supports(_ zone: SyncZone) -> Bool
}
extension SyncTransport {
    func supports(_ zone: SyncZone) -> Bool { true }
}

/// The local copy of an account's synced records plus the changes not yet pushed.
struct SyncState: Codable, Equatable {
    var schema = 1
    var records: [String: SyncRecord] = [:]
    var outbox: [String: SyncRecord] = [:]
    var token: Data?
    /// For each record a store holds, a digest of the value it had when it last matched the
    /// synced copy (see `SyncEngine.reconcile`). Missing in state saved before stores synced.
    var bases: [String: String]?
    /// Set once this device has pulled everything the account already had, before sending its own.
    var joined: Bool?
    /// When a sync last finished.
    var lastSynced: Date?
}

/// Keeps the local copy, queues changes, and merges what the transport returns.
/// The newer modification wins (ties go to the higher device ID); deletions are tombstones.
@MainActor final class SyncEngine {
    private(set) var state: SyncState
    let device: String
    let transport: SyncTransport
    private let url: URL?
    /// Set when the saved state exists but couldn't be read: nothing is saved or synced until it
    /// opens, so an empty copy never replaces it.
    private(set) var unreadable = false
    /// Called after every local change is queued, so a sync can follow soon.
    var onLocalChange: (() -> Void)?
    private var batching = 0
    init(transport: SyncTransport, device: String, url: URL? = nil) {
        self.transport = transport; self.device = device; self.url = url
        state = SyncState()
        load()
    }
    private func load() {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { unreadable = false; return }
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(SyncState.self, from: data) {
            state = saved; unreadable = false
        } else { unreadable = true }
    }
    /// Tries once more to open saved state that couldn't be read.
    private func ensureReadable() throws {
        if unreadable { load() }
        if unreadable { throw SyncError.stateUnreadable }
    }
    /// Encodes payloads the same way everywhere, so equal values give equal bytes.
    nonisolated static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    /// Saves a value locally and queues it for the next sync.
    func put<Value: Encodable>(_ value: Value, id: String, type: String, zone: SyncZone, at date: Date = Date()) throws {
        try putPayload(try Self.encode(value), id: id, type: type, zone: zone, at: date)
    }
    /// Queues an already-encoded payload.
    func putPayload(_ payload: Data, id: String, type: String, zone: SyncZone, at date: Date = Date()) throws {
        try ensureReadable()
        try Self.check(type: type, zone: zone)
        let record = SyncRecord(id: id, type: type, zone: zone, modified: date, device: device, payload: payload)
        state.records[record.key] = record; state.outbox[record.key] = record
        try persist()
        onLocalChange?()
    }
    func delete(id: String, type: String, zone: SyncZone, at date: Date = Date()) throws {
        try ensureReadable()
        try Self.check(type: type, zone: zone)
        let record = SyncRecord(id: id, type: type, zone: zone, modified: date, device: device, payload: Data(), deleted: true)
        state.records[record.key] = record; state.outbox[record.key] = record
        try persist()
        onLocalChange?()
    }
    func values<Value: Decodable>(_ type: String, in zone: SyncZone, as: Value.Type) -> [Value] {
        state.records.values.filter { $0.type == type && $0.zone == zone && !$0.deleted }
            .sorted { $0.modified < $1.modified }
            .compactMap { try? JSONDecoder().decode(Value.self, from: $0.payload) }
    }
    /// Makes several changes and saves the state once, rather than after each.
    func batch(_ changes: () throws -> Void) throws {
        batching += 1
        do { try changes() } catch { batching -= 1; try? persist(); throw error }
        batching -= 1
        try persist()
    }

    /// Pushes queued changes, then pulls and merges everyone else's. Returns the records that
    /// arrived and replaced the local copy, for the stores to take in.
    @discardableResult
    func sync() async throws -> [SyncRecord] {
        try ensureReadable()
        let pending = Array(state.outbox.values).filter { transport.supports($0.zone) }
        if !pending.isEmpty {
            do { try await transport.push(pending) }
            catch SyncError.resetRequired { requeueAll(); throw SyncError.resetRequired }
            for record in pending where state.outbox[record.key] == record { state.outbox.removeValue(forKey: record.key) }
            try persist()
        }
        let changed = try await pull()
        state.lastSynced = Date()
        try persist()
        return changed
    }
    /// Pulls and merges everyone else's changes without sending this device's.
    @discardableResult
    func pull() async throws -> [SyncRecord] {
        try ensureReadable()
        let incoming: [SyncRecord], token: Data?
        do { (incoming, token) = try await transport.pull(since: state.token) }
        catch SyncError.resetRequired { requeueAll(); throw SyncError.resetRequired }
        var changed: [SyncRecord] = []
        for record in incoming where merge(record) { changed.append(record) }
        state.token = token
        try persist()
        return changed
    }
    /// A remote record replaces the local one only if it is newer, and never a newer unpushed local edit.
    @discardableResult
    func merge(_ remote: SyncRecord) -> Bool {
        guard (try? Self.check(type: remote.type, zone: remote.zone)) != nil else { return false }
        if let local = state.records[remote.key], !Self.wins(remote, over: local) { return false }
        state.records[remote.key] = remote
        if let queued = state.outbox[remote.key], !Self.wins(queued, over: remote) { state.outbox.removeValue(forKey: remote.key) }
        return true
    }
    /// The account's copy in the cloud is gone: queue everything again (tombstones too, so a
    /// deletion isn't undone by a device that still has the record) and pull from the start.
    func requeueAll() {
        for (key, record) in state.records where transport.supports(record.zone) { state.outbox[key] = record }
        state.token = nil
        try? persist()
    }
    /// Takes in records another device handed over the relay (`MacRelaySync`): each merges by the usual
    /// rule (the newer change wins) and, when it wins, is queued for this device's own transport
    /// (iCloud) too, so it reaches the account. Returns how many were taken.
    @discardableResult
    func acceptRelayed(_ records: [SyncRecord]) throws -> Int {
        try ensureReadable()
        var taken = 0
        for record in records where record.zone == .personal && merge(record) {
            if transport.supports(record.zone) { state.outbox[record.key] = record }
            taken += 1
        }
        guard taken > 0 else { return 0 }
        try persist()
        return taken
    }
    /// Marks this device as having taken in everything the account already had.
    func markJoined() throws { state.joined = true; try persist() }
    func base(_ key: String) -> String? { state.bases?[key] }
    func setBase(_ digest: String?, for key: String) {
        var bases = state.bases ?? [:]
        bases[key] = digest
        state.bases = bases
    }
    /// Forgets which values the stores last held, so the next sync joins the account again and
    /// keeps what it already has (used when this device turns sync back on).
    func rejoin() throws { state.bases = nil; state.joined = nil; try persist() }
    func persistNow() throws { try persist() }
    /// Drops everything kept for a zone that no longer exists (a profile share you removed).
    func forget(zone: SyncZone) throws {
        try ensureReadable()
        let prefix = zone.name + "/"
        state.records = state.records.filter { $0.value.zone != zone }
        state.outbox = state.outbox.filter { $0.value.zone != zone }
        state.bases = state.bases?.filter { !$0.key.hasPrefix(prefix) }
        try persist()
    }
    nonisolated static func wins(_ a: SyncRecord, over b: SyncRecord) -> Bool {
        a.modified != b.modified ? a.modified > b.modified : a.device > b.device
    }
    /// The allow-list, checked for every record put, deleted, or merged: private types never enter
    /// a zone anyone else can read, and each kind of shared zone takes only its own types.
    nonisolated static func check(type: String, zone: SyncZone) throws {
        guard zone.isShared else { return }
        if SyncType.personalOnly.contains(type) { throw SyncError.privateInSharedZone(type) }
        switch zone {
        case .personal: return
        case .shared: if !SyncType.shareable.contains(type) { throw SyncError.notShareable(type) }
        case .profileShare: if !SyncType.profileShareable.contains(type) { throw SyncError.notShareable(type) }
        }
    }
    private func persist() throws {
        guard let url, batching == 0 else { return }
        guard !unreadable else { throw SyncError.stateUnreadable }
        // Never into an account that's no longer open (see `AccountDirectory.permitsWrite`).
        try AccountDirectory.checkWrite(to: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The synced copy holds chats and memories, so it gets the same protection as state.json.
        try JSONEncoder().encode(state).write(to: url, options: [.atomic, .completeFileProtection])
    }
}

/// The transport until the iCloud container exists: it carries nothing and says so, so nothing
/// can mistake queued records for synced ones.
struct UnavailableSyncTransport: SyncTransport {
    static let reason = "Syncing between devices starts once iCloud is set up."
    func push(_ records: [SyncRecord]) async throws { throw SyncError.unavailable(Self.reason) }
    func pull(since token: Data?) async throws -> (records: [SyncRecord], token: Data?) { throw SyncError.unavailable(Self.reason) }
}

/// The account-wide values every device shows (account, companion, profile), kept as records in
/// the Apple account's personal zone. Only an Apple account has records: a local account never
/// links to other devices. The engine's transport is CloudKit when this build syncs
/// (`AccountSyncService.availableInBuild`), and otherwise `UnavailableSyncTransport`, which
/// carries nothing.
@MainActor final class AccountRecords {
    /// The open account's records; replaced when the account changes while the app runs.
    private(set) static var shared = AccountRecords.forCurrentAccount()
    static func reopen() { shared = forCurrentAccount() }
    static let accountID = "account", companionID = "companion", profileID = "profile"
    struct Account: Codable, Equatable { var name: String; var handle: String }
    struct Companion: Codable, Equatable { var name: String; var personality: String?; var paletteID: String? }

    let engine: SyncEngine?
    init(engine: SyncEngine?) { self.engine = engine }
    static func forCurrentAccount() -> AccountRecords {
        let account = AccountDirectory.current()
        // An Apple account syncs through iCloud; on a Mac without iCloud, any account syncs through the
        // paired iPhone (`MacRelaySync`), which carries the records to the same iCloud account.
        guard account.kind == .apple || MacRelaySync.usesRelay, !AccountDirectory.isTestHost else { return .init(engine: nil) }
        let folder = AccountDirectory.currentFolder.appendingPathComponent("Sync", isDirectory: true)
        return .init(engine: SyncEngine(transport: AccountSyncService.transport(for: account, folder: folder), device: deviceID(),
                                        url: folder.appendingPathComponent("records.json")))
    }
    /// A random ID for this device, kept in device settings; it only breaks ties between edits.
    static func deviceID(_ defaults: UserDefaults = AccountDirectory.settings) -> String {
        if let saved = defaults.string(forKey: "kemo.sync.device") { return saved }
        let created = UUID().uuidString.lowercased()
        defaults.set(created, forKey: "kemo.sync.device")
        return created
    }
    /// Queues a value in the personal zone as a change made now, unless the record already holds
    /// exactly this value, so reopening the app doesn't make an unchanged value look newer than
    /// another device's edit.
    ///
    /// Nothing is queued before this device has joined the account (`SyncState.joined`): the join's
    /// reconcile decides between this device's value and the account's, and the account's wins. A
    /// value queued here first would carry a newer time than the account's copy, so the join would
    /// keep it and send it over the other devices' (a new Mac's empty name replaced the iPhone's).
    /// The time is when it's queued, never an older edit time: a record stamped older than the one
    /// another device already holds is never taken there (`SyncEngine.merge`).
    func put<Value: Codable & Equatable>(_ value: Value, id: String, type: String) {
        guard let engine, engine.state.joined == true else { return }
        if let existing = engine.state.records[SyncZone.personal.name + "/" + id], !existing.deleted,
           (try? JSONDecoder().decode(Value.self, from: existing.payload)) == value { return }
        try? engine.put(value, id: id, type: type, zone: .personal, at: Date())
    }
}

/// A transport that keeps records in memory: for tests, and for trying sync between two
/// engines in one process before CloudKit is available.
actor MemorySyncTransport: SyncTransport {
    private var log: [SyncRecord] = []
    func push(_ records: [SyncRecord]) async throws { log.append(contentsOf: records) }
    func pull(since token: Data?) async throws -> (records: [SyncRecord], token: Data?) {
        let start = token.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        return (Array(log.dropFirst(start)), Data(String(log.count).utf8))
    }
}

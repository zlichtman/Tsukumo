import Foundation

// Sync through your paired iPhone (September 30, 2026; design/ACCOUNTS-AND-PROFILES.md#what-syncs). The
// Homebrew and website builds of Tsukumo have no iCloud entitlement (DEVELOPMENT.md known issue 16), so
// CloudKit can't reach the Mac. When the iPhone paired in Agents on your Mac syncs with iCloud, the Mac
// syncs the same records with it instead, over the relay's connection (Bonjour on the same Wi‑Fi, TLS
// with the pairing's pre-shared key): the Mac's `SyncEngine` uses `RelaySyncTransport`, and the iPhone
// answers from its own engine (`RelaySyncHub`), passing the Mac's changes on to iCloud with its own.
// Same records, same merge (the newer change wins, deletions are tombstones), same join rule (a Mac
// joining takes what the account already has). Only the personal zone travels; shared projects and
// profile shares stay with iCloud. Nothing goes anywhere else: the records never leave the two devices
// and the owner's private iCloud database.

enum MacRelaySync {
    /// What `hello.sync` says when the phone can carry the account's records.
    static let hub = "hub"
    /// The most payload bytes in one page or push, so a frame stays well under `MacRelay.maxFrame`
    /// (base64 makes the JSON about a third larger).
    static let pageBytes = 3 * 1024 * 1024
    /// A single record larger than this isn't carried over the relay (it waits for iCloud).
    static let maxRecordBytes = 5 * 1024 * 1024
    /// How long the Mac waits for the phone's answer.
    static let timeout: Duration = .seconds(45)

    /// A Mac build without iCloud syncs through the paired iPhone instead (the Homebrew and website builds).
    nonisolated static var usesRelay: Bool {
        #if os(macOS)
        return !AccountSyncService.availableInBuild
        #else
        return false
        #endif
    }
    /// The Mac's connected iPhone that can carry the account's records, set by the relay (`KemoSabeRelay`).
    @MainActor static var macLink: (() -> Result<RelaySyncLink, SyncError>)?
    static let waiting = "Waiting for your iPhone on this Wi‑Fi. Open KemoSabe on it to sync."
    static let notPaired = "Pair your iPhone in Settings → Models → Agents on your Mac to sync with it."
    static let noHub = "Your iPhone isn't syncing with iCloud, so there's nothing to sync with yet. On your iPhone, sign in with Apple in Settings → Account."

    /// Records split into pushes of at most `pageBytes` each; a record too large to carry is left out.
    static func chunks(_ records: [SyncRecord], limit: Int = pageBytes) -> [[SyncRecord]] {
        var chunks: [[SyncRecord]] = [], current: [SyncRecord] = [], size = 0
        for record in records where record.payload.count <= maxRecordBytes {
            if !current.isEmpty, size + record.payload.count > limit { chunks.append(current); current = []; size = 0 }
            current.append(record); size += record.payload.count
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

/// The Mac's way to reach its connected iPhone's records: one request, one answer.
@MainActor protocol RelaySyncLink: AnyObject {
    /// The next page of records the phone has after `token` (nil: from the start).
    func pull(token: String?) async throws -> (records: [SyncRecord], token: String?, more: Bool)
    /// Hands the phone this Mac's changes.
    func push(_ records: [SyncRecord]) async throws
}

/// The Mac's transport when it has no iCloud: the paired iPhone, while it's connected. Without one it
/// throws `SyncError.unavailable` with a line the Account page shows as waiting, not as a failure.
final class RelaySyncTransport: SyncTransport, @unchecked Sendable {
    /// The connected phone that can carry the account's records, or why there's none.
    let link: @MainActor () -> Result<RelaySyncLink, SyncError>
    init(link: @escaping @MainActor () -> Result<RelaySyncLink, SyncError>) { self.link = link }

    func push(_ records: [SyncRecord]) async throws {
        let link = try await MainActor.run { try self.link().get() }
        for chunk in MacRelaySync.chunks(records.filter { $0.zone == .personal }) { try await link.push(chunk) }
    }
    func pull(since token: Data?) async throws -> (records: [SyncRecord], token: Data?) {
        let link = try await MainActor.run { try self.link().get() }
        var all: [SyncRecord] = [], current = token.map { String(decoding: $0, as: UTF8.self) }
        for _ in 0..<10_000 {
            let page = try await link.pull(token: current)
            all += page.records.filter { $0.zone == .personal }
            current = page.token ?? current
            if !page.more { break }
        }
        return (all, current.map { Data($0.utf8) })
    }
    func supports(_ zone: SyncZone) -> Bool { zone == .personal }
}

/// The phone's side: answers the Mac's pulls from this device's synced copy and takes in its pushes,
/// which then go on to iCloud with this device's own changes. Each record's version gets a sequence
/// number the first time the phone hands it out (`RelaySyncLog`), so the Mac only gets what changed
/// since its last pull, whenever and however it changed here (a local edit, iCloud, or the Mac itself).
@MainActor final class RelaySyncHub {
    let engine: () -> SyncEngine?
    /// Brings this device's stores and its synced copy together, both ways, before a pull and after a push.
    let reconcile: () throws -> Void
    /// Something the Mac sent was taken in: pass it on to iCloud soon.
    let changed: () -> Void
    /// Where the open account's log is kept (it follows an account switch).
    let logURL: () -> URL?

    init(engine: @escaping () -> SyncEngine?, logURL: @escaping () -> URL?, reconcile: @escaping () throws -> Void, changed: @escaping () -> Void) {
        self.engine = engine; self.logURL = logURL; self.reconcile = reconcile; self.changed = changed
    }
    /// This phone's hub: its account's synced copy, when it syncs with iCloud itself.
    static let phone = RelaySyncHub(
        engine: {
            let sync = AccountSyncService.shared
            return sync.canSync && sync.enabled && !sync.usesRelay ? AccountRecords.shared.engine : nil
        },
        logURL: { AccountDirectory.currentFolder.appendingPathComponent("Sync", isDirectory: true).appendingPathComponent("relay-log.json") },
        reconcile: { try AccountSyncService.shared.reconcileNow() },
        changed: { AccountSyncService.shared.syncSoon(after: .seconds(2)) })
    /// Whether this device can carry the account's records now.
    var isAvailable: Bool { engine() != nil }

    func pull(token: String?, pageBytes: Int = MacRelaySync.pageBytes) throws -> (records: [SyncRecord], token: String, more: Bool) {
        guard let engine = engine() else { throw SyncError.unavailable(MacRelaySync.noHub) }
        try? reconcile()
        return try RelaySyncLog(url: logURL()).page(of: engine.state, after: token, pageBytes: pageBytes)
    }
    func push(_ records: [SyncRecord]) throws {
        guard let engine = engine() else { throw SyncError.unavailable(MacRelaySync.noHub) }
        let taken = try engine.acceptRelayed(records.filter { $0.zone == .personal })
        guard taken > 0 else { return }
        try? reconcile()
        changed()
    }
}

/// Which version of each record the phone has handed out, in order: a sequence number per record key,
/// bumped whenever that record's version (time, device, deleted) changes. Kept beside the account's
/// synced copy, never synced. A new log (or one that couldn't be read) has a new epoch, so the Mac's
/// old token starts it from the beginning rather than missing anything.
final class RelaySyncLog {
    struct Entry: Codable, Equatable { var version: String; var seq: Int }
    struct Document: Codable, Equatable {
        var epoch = UUID()
        var seq = 0
        var entries: [String: Entry] = [:]
    }
    let url: URL?
    private(set) var document: Document
    init(url: URL?) {
        self.url = url
        document = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(Document.self, from: $0) } ?? Document()
    }
    static func version(_ record: SyncRecord) -> String {
        "\(record.modified.timeIntervalSinceReferenceDate)|\(record.device)|\(record.deleted)|\(record.payload.count)"
    }
    /// Numbers any record whose version is new since the last call, then returns the records after
    /// `token` in order, up to about `pageBytes`, with the token to ask from next.
    func page(of state: SyncState, after token: String?, pageBytes: Int) throws -> (records: [SyncRecord], token: String, more: Bool) {
        var changed = false
        for (key, record) in state.records.sorted(by: { $0.key < $1.key }) where record.zone == .personal {
            let version = Self.version(record)
            if document.entries[key]?.version != version {
                document.seq += 1; document.entries[key] = Entry(version: version, seq: document.seq); changed = true
            }
        }
        if changed { try save() }
        let since = Self.position(token, epoch: document.epoch)
        let pending = document.entries.filter { $0.value.seq > since }.sorted { $0.value.seq < $1.value.seq }
        var records: [SyncRecord] = [], size = 0, last = since
        for (key, entry) in pending {
            guard let record = state.records[key] else { last = entry.seq; continue }
            if record.payload.count > MacRelaySync.maxRecordBytes { last = entry.seq; continue }
            if !records.isEmpty, size + record.payload.count > pageBytes { break }
            records.append(record); size += record.payload.count; last = entry.seq
        }
        let more = pending.last.map { $0.value.seq > last } ?? false
        return (records, "\(document.epoch.uuidString):\(max(last, since))", more)
    }
    /// A token's position in this log: 0 when it's from another log (or none).
    static func position(_ token: String?, epoch: UUID) -> Int {
        guard let token, let colon = token.firstIndex(of: ":"), UUID(uuidString: String(token[..<colon])) == epoch,
              let seq = Int(token[token.index(after: colon)...]) else { return 0 }
        return seq
    }
    private func save() throws {
        guard let url else { return }
        try AccountDirectory.checkWrite(to: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(document).write(to: url, options: [.atomic, .completeFileProtection])
    }
}

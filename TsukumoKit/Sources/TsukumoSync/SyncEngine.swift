import Foundation
import TsukumoCore
import TsukumoPolicy
import TsukumoContext

/// What a synced record holds.
public enum SyncType: String, Codable, CaseIterable, Sendable {
    /// A `BotSpec` (it holds no secrets), with its look, so a bot looks the same everywhere.
    case bot
    /// A `ChatThread` at its level.
    case thread
    /// An artifact revision: its metadata and content, at its effective level.
    case artifact
    /// An `APIConnection`, never its key (keys stay in this device's Keychain).
    case connection
    /// A setting that follows the owner (the default model). An older build skips it.
    case setting
}

/// One item to sync, labeled so the policy can decide it.
public struct SyncItem: Hashable, Sendable {
    public let id: String
    public let type: SyncType
    public let label: TypeLabel
    public let modified: Date
    public let deleted: Bool
    public let payload: Data

    public init(id: String, type: SyncType, label: TypeLabel, modified: Date, deleted: Bool = false, payload: Data) {
        self.id = id; self.type = type; self.label = label; self.modified = modified; self.deleted = deleted; self.payload = payload
    }

    public static func bot(_ bot: BotSpec, modified: Date) throws -> SyncItem {
        SyncItem(id: "bot:" + bot.id.uuidString, type: .bot, label: TypeLabel(kind: "bot", level: .open), modified: modified,
                 payload: try TsukumoJSON.encoder.encode(bot))
    }
    /// A thread at its level (Personal unless the owner chose another).
    public static func thread(_ thread: ChatThread, level: PrivacyLevel = .personal, modified: Date) throws -> SyncItem {
        SyncItem(id: "thread:" + thread.id.uuidString, type: .thread, label: TypeLabel(kind: .turn, level: level), modified: modified,
                 payload: try TsukumoJSON.encoder.encode(thread))
    }
    public static func connection(_ connection: APIConnectionRecord, modified: Date) throws -> SyncItem {
        SyncItem(id: "connection:" + connection.id.uuidString, type: .connection, label: TypeLabel(kind: "connection", level: .personal),
                 modified: modified, payload: try TsukumoJSON.encoder.encode(connection))
    }
    /// The current revision of an artifact, at its effective level, read on this device.
    public static func artifact(_ ref: ArtifactRef, from store: ArtifactStore) async throws -> SyncItem {
        guard let artifact = await store.artifact(ref), let label = await store.effectiveLabel(of: ref) else { throw ArtifactStoreError.notFound }
        let page = try await store.read(ref, for: .appleOnDevice, purpose: .sync, byteBudget: ArtifactStore.maxReadBudget)
        let snapshot = ArtifactSnapshot(ref: ref, kind: artifact.kind, label: label, owner: artifact.owner, summaryLine: artifact.summaryLine,
                                        source: artifact.source, lineage: artifact.lineage, content: page.text)
        return SyncItem(id: "artifact:" + ref.id.description, type: .artifact, label: label, modified: artifact.createdAt,
                        payload: try TsukumoJSON.encoder.encode(snapshot))
    }
}

/// An API connection as it syncs: where it points and which model, never its key.
public struct APIConnectionRecord: Codable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let endpoint: URL
    public let model: String
    public let wire: String
    public init(id: UUID, name: String, endpoint: URL, model: String, wire: String) {
        self.id = id; self.name = name; self.endpoint = endpoint; self.model = model; self.wire = wire
    }
}

/// An artifact revision as it syncs.
public struct ArtifactSnapshot: Codable, Hashable, Sendable {
    public let ref: ArtifactRef
    public let kind: ArtifactKind
    public let label: TypeLabel
    public let owner: Author
    public let summaryLine: String
    public let source: String?
    public let lineage: [ArtifactRef]
    public let content: String
}

public enum SyncError: Error, Hashable, Sendable {
    case iCloudUnavailable(String)
    /// This device's iCloud user isn't the one this account first synced with.
    case iCloudAccountMismatch
    case quotaExceeded
    case network(String)
    /// The zone was lost; the next sync sends everything again.
    case resetRequired
}

/// What one sync did.
public struct SyncReport: Sendable {
    public var pushed: [String] = []
    /// Items from other devices (or the server's newer versions) for this device to apply.
    public var received: [SyncItem] = []
    /// Staged items the policy kept on this device (Device only, Secret, or a kind that never syncs).
    public var refused: [String] = []
    /// Conflicts where this device's newer edit was saved over the server's.
    public var keptLocal = 0
    /// Conflicts where the server's newer edit stays (and is in `received`).
    public var keptServer = 0
}

/// Syncs this account's items through the owner's private iCloud database (ported from the app's
/// `CloudKitSyncTransport` and `SyncEngine`). Every outbound item first passes the policy for
/// recipient `iCloudSync`: Device only and Secret items, and anything derived from them, never
/// leave; KemoSabe's answers and personal-source items never sync. Conflicts: the newer edit wins.
public actor SyncEngine {
    /// Kinds that never sync, whatever their level.
    public static let neverSyncedKinds: Set<ItemKind> = [.personalAnswer, .credential, .textMessage, .location, .contact,
                                                         .calendarEvent, .reminder, .health]
    public static let chunk = 200

    private let database: any CloudDatabase
    private let zone: String
    private let device: String
    private let clock: @Sendable () -> Date
    private var staged: [String: SyncItem] = [:]
    private var tags: [String: Data] = [:]
    private var token: Data?
    private var boundUser: String?
    private var prepared = false

    public init(database: any CloudDatabase, zone: String, device: String, boundUser: String? = nil, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.database = database; self.zone = zone; self.device = device; self.boundUser = boundUser; self.clock = clock
    }

    /// The iCloud user this account is bound to, once it has synced (save it with the account).
    public var iCloudUser: String? { boundUser }

    /// Whether the policy lets this item sync at all.
    public static func mayLeave(_ item: SyncItem) -> Bool {
        guard !neverSyncedKinds.contains(item.label.kind) else { return false }
        return ContextPolicy.allows(PolicyItem(id: item.id, label: item.label), to: .iCloudSync, purpose: .sync)
    }

    /// Queues an item for the next sync. Returns false (and queues nothing) when it must stay here.
    @discardableResult
    public func stage(_ item: SyncItem) -> Bool {
        guard Self.mayLeave(item) else { staged[item.id] = nil; return false }
        if let current = staged[item.id], current.modified > item.modified { return true }
        staged[item.id] = item
        return true
    }
    public var pending: [String] { staged.keys.sorted() }

    /// Pushes what's staged, then pulls what changed elsewhere.
    public func sync() async throws -> SyncReport {
        var report = SyncReport()
        try await prepare()
        let outbound = staged.values.sorted { $0.id < $1.id }
        for item in outbound where !Self.mayLeave(item) {
            // Checked again at send time: a label may have been raised since it was staged.
            report.refused.append(item.id)
            staged[item.id] = nil
        }
        let sendable = outbound.filter(Self.mayLeave)
        var start = 0
        while start < sendable.count {
            let slice = Array(sendable[start..<min(start + Self.chunk, sendable.count)])
            try await save(slice.map(cloudRecord), report: &report)
            for item in slice { staged[item.id] = nil }
            start += slice.count
        }
        try await pull(into: &report)
        return report
    }

    private func prepare() async throws {
        if prepared { return }
        let status: CloudAccountStatus
        do { status = try await database.accountStatus() } catch let failure as CloudFailure { throw Self.error(failure) }
        guard status == .available else { throw SyncError.iCloudUnavailable("Sign in to iCloud in Settings to sync.") }
        let user: String
        do { user = try await database.userRecordName() } catch let failure as CloudFailure { throw Self.error(failure) }
        if let boundUser, boundUser != user { throw SyncError.iCloudAccountMismatch }
        boundUser = user
        do { try await database.ensureZone(zone) } catch let failure as CloudFailure { throw Self.error(failure) }
        prepared = true
    }

    private func save(_ records: [CloudRecord], report: inout SyncReport, attempt: Int = 0) async throws {
        guard !records.isEmpty else { return }
        let results: [String: CloudSaveResult]
        do { results = try await database.save(records, zone: zone) }
        catch CloudFailure.tooLarge where records.count > 1 {
            let half = records.count / 2
            try await save(Array(records[..<half]), report: &report, attempt: attempt)
            try await save(Array(records[half...]), report: &report, attempt: attempt)
            return
        } catch let failure as CloudFailure { throw failure == .zoneNotFound ? lostZone() : Self.error(failure) }
        var retry: [CloudRecord] = []
        var failure: CloudFailure?
        for record in records {
            switch results[record.name] {
            case .saved(let saved)?:
                tags[record.name] = saved.tag
                report.pushed.append(record.name)
            case .conflict(let server)?:
                tags[record.name] = server.tag
                if Self.wins(record, over: server) {
                    var again = record
                    again.tag = server.tag
                    retry.append(again)
                    report.keptLocal += 1
                } else if let item = Self.item(server) {
                    report.received.append(item)
                    report.keptServer += 1
                }
            case .failed(let error)?: failure = failure ?? error
            case nil: failure = failure ?? .other("iCloud didn't confirm a record.")
            }
        }
        if let failure { throw failure == .zoneNotFound ? lostZone() : Self.error(failure) }
        if !retry.isEmpty {
            guard attempt < 3 else { throw SyncError.network("Another device kept changing the same item. Try again.") }
            try await save(retry, report: &report, attempt: attempt + 1)
        }
    }

    private func pull(into report: inout SyncReport) async throws {
        var restarted = false
        while true {
            let changes: CloudChanges
            do { changes = try await database.changes(zone: zone, since: token) }
            catch CloudFailure.tokenExpired where !restarted {
                // Too old to continue from: fetch the whole zone again; merging is idempotent.
                token = nil; restarted = true; continue
            } catch let failure as CloudFailure { throw failure == .zoneNotFound ? lostZone() : Self.error(failure) }
            for record in changes.records {
                tags[record.name] = record.tag
                // This device's own writes come back too; only others' are news.
                guard record.device != device, let item = Self.item(record) else { continue }
                if !report.received.contains(item) { report.received.append(item) }
            }
            token = changes.token
            if !changes.moreComing { break }
        }
    }

    private func lostZone() -> SyncError { prepared = false; tags = [:]; token = nil; return .resetRequired }

    private func cloudRecord(_ item: SyncItem) -> CloudRecord {
        let envelope = Envelope(kind: item.label.kind, level: item.label.level, payload: item.payload)
        return CloudRecord(name: item.id, type: item.type.rawValue, modified: item.modified, device: device, deleted: item.deleted,
                           payload: (try? TsukumoJSON.encoder.encode(envelope)) ?? Data(), tag: tags[item.id])
    }
    private struct Envelope: Codable { let kind: ItemKind; let level: PrivacyLevel; let payload: Data }
    static func item(_ record: CloudRecord) -> SyncItem? {
        guard let type = SyncType(rawValue: record.type), let envelope = try? TsukumoJSON.decoder.decode(Envelope.self, from: record.payload) else { return nil }
        return SyncItem(id: record.name, type: type, label: TypeLabel(kind: envelope.kind, level: envelope.level), modified: record.modified,
                        deleted: record.deleted, payload: envelope.payload)
    }
    /// The newer edit wins; on a tie, the device name decides, so every device agrees.
    static func wins(_ local: CloudRecord, over server: CloudRecord) -> Bool {
        local.modified != server.modified ? local.modified > server.modified : local.device > server.device
    }
    static func error(_ failure: CloudFailure) -> SyncError {
        switch failure {
        case .network: .network("Couldn't reach iCloud. Sync will try again.")
        case .quotaExceeded: .quotaExceeded
        case .zoneNotFound: .resetRequired
        case .tokenExpired: .network("iCloud asked to start over. Sync will try again.")
        case .notAuthenticated: .iCloudUnavailable("Sign in to iCloud in Settings to sync.")
        case .tooLarge: .network("An item was too large to sync.")
        case .other(let message): .network(message)
        }
    }
}

/// One line about sync for Settings (ported from the app's `SyncService` status text).
public enum SyncStatus: Hashable, Sendable {
    case off, syncing, upToDate(Date), failed(SyncError)
    public var text: String {
        switch self {
        case .off: "Sync is off."
        case .syncing: "Syncing…"
        case .upToDate(let date): "Up to date as of " + date.formatted(date: .omitted, time: .shortened) + "."
        case .failed(.iCloudUnavailable(let message)): message
        case .failed(.iCloudAccountMismatch): "This device is signed in to a different iCloud account than this account syncs with."
        case .failed(.quotaExceeded): "Your iCloud storage is full, so sync has paused."
        case .failed(.network(let message)): message
        case .failed(.resetRequired): "Sync is starting over with iCloud."
        }
    }
}

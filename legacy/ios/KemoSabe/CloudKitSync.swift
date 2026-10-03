import CloudKit
import Foundation

// MARK: The cloud database, behind a protocol

/// One synced record as the cloud database holds it.
struct CloudRecord: Equatable, Sendable {
    var name: String
    var type: String
    var modified: Date
    var device: String
    var deleted: Bool
    var payload: Data
    /// The server's version of the record (CloudKit's archived system fields), so a save can be
    /// made conditional on it; nil for a record this device hasn't seen from the server.
    var tag: Data?
    /// A file that travels with the record as its asset (a shared profile's image), beside a small
    /// payload. Nil for everything the personal zone syncs.
    var attachment: Data? = nil
}
enum CloudAccountStatus: Equatable, Sendable { case available, noAccount, restricted, temporarilyUnavailable, couldNotDetermine }
enum CloudSaveResult: Equatable, Sendable {
    case saved(CloudRecord)
    /// The server has a version this save didn't start from.
    case conflict(server: CloudRecord)
    case failed(CloudFailure)
}
enum CloudFailure: Error, Equatable, Sendable {
    case network(retryAfter: Double?)
    case quotaExceeded
    case zoneNotFound
    case tokenExpired
    case notAuthenticated
    /// The request was too large; send fewer records at once.
    case tooLarge
    case other(String)
}
struct CloudChanges: Equatable, Sendable {
    var records: [CloudRecord]
    /// Records removed from the zone outright. KemoSabe never removes records (deletions are
    /// tombstones), so these come only from outside the app and are ignored.
    var deleted: [String]
    var token: Data?
    var moreComing: Bool
}

/// The few things sync needs from a cloud database. `CKCloudDatabase` is CloudKit; tests use a
/// fake, so conflicts, account changes, quota, and lost zones can be checked without iCloud.
protocol CloudDatabase: Sendable {
    func accountStatus() async throws -> CloudAccountStatus
    /// The iCloud user this device is signed in as (an app-scoped ID, never an email or name).
    func userRecordName() async throws -> String
    func ensureZone(_ zone: String) async throws
    /// Saves each record only if the server still has the version its `tag` names (or has none).
    func save(_ records: [CloudRecord], zone: String) async throws -> [String: CloudSaveResult]
    func changes(zone: String, since token: Data?) async throws -> CloudChanges
    /// Asks for a silent push when the zone changes.
    func subscribe(zone: String) async throws
}

// MARK: The transport

/// Carries the account's personal zone through the person's private iCloud database. Each app
/// account has its own zone (`personal-<account ID>`), so two KemoSabe accounts that share one
/// iCloud account never mix. The first sync records which iCloud user backs the app account
/// (`icloud.json` in the account's Sync folder); if the device's iCloud user later differs, the
/// transport refuses to sync (`SyncError.iCloudAccountMismatch`) until the person chooses.
///
/// Conflicts: a save names the server version it started from. If the server moved on, the
/// newer edit wins (the same rule as `SyncEngine.wins`): the local one is saved again on top,
/// or dropped so the next pull brings the server's.
actor CloudKitSyncTransport: SyncTransport {
    struct Binding: Codable, Equatable {
        var userRecordName: String
        var zone: String
        var subscribed: Bool?
    }
    let database: CloudDatabase
    let zone: String
    private let bindingURL: URL?
    private let subscribes: Bool
    private var prepared = false
    /// The server version of each record this device has seen, for conditional saves.
    private var tags: [String: Data] = [:]
    /// How many records go in one request; halved when iCloud says a request is too large.
    static let chunk = 100

    init(database: CloudDatabase, accountID: String, bindingURL: URL?, subscribes: Bool) {
        self.database = database; self.zone = "personal-" + accountID
        self.bindingURL = bindingURL; self.subscribes = subscribes
    }
    nonisolated func supports(_ zone: SyncZone) -> Bool { zone == .personal }

    /// The device's iCloud account changed (or its status did): check again before the next sync.
    func accountChanged() { prepared = false; tags = [:] }
    /// The person chose to sync this app account with the iCloud account now on the device. The
    /// caller queues everything again, since the new account's database doesn't have it.
    func forgetBinding() throws {
        prepared = false; tags = [:]
        guard let bindingURL, FileManager.default.fileExists(atPath: bindingURL.path) else { return }
        try AccountDirectory.checkWrite(to: bindingURL)
        try FileManager.default.removeItem(at: bindingURL)
    }
    func binding() throws -> Binding? {
        guard let bindingURL, FileManager.default.fileExists(atPath: bindingURL.path) else { return nil }
        guard let data = try? Data(contentsOf: bindingURL), let binding = try? JSONDecoder().decode(Binding.self, from: data) else {
            throw SyncError.stateUnreadable
        }
        return binding
    }
    private func save(_ binding: Binding) throws {
        guard let bindingURL else { return }
        try AccountDirectory.checkWrite(to: bindingURL)
        try FileManager.default.createDirectory(at: bindingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(binding).write(to: bindingURL, options: [.atomic, .completeFileProtection])
    }

    /// Checks the iCloud account, binds or verifies it, and makes sure the zone exists.
    func prepare() async throws {
        guard !prepared else { return }
        let status: CloudAccountStatus
        do { status = try await database.accountStatus() } catch let failure as CloudFailure { throw Self.error(failure) }
        switch status {
        case .available: break
        case .noAccount: throw SyncError.iCloudUnavailable("Sign in to iCloud in Settings to sync.")
        case .restricted: throw SyncError.iCloudUnavailable("iCloud is restricted on this device.")
        case .temporarilyUnavailable: throw SyncError.iCloudUnavailable("iCloud is temporarily unavailable. Check Settings → Apple Account.")
        case .couldNotDetermine: throw SyncError.network("iCloud couldn't be reached.")
        }
        let user: String
        do { user = try await database.userRecordName() } catch let failure as CloudFailure { throw Self.error(failure) }
        let existing = try binding()
        if let existing, existing.userRecordName != user { throw SyncError.iCloudAccountMismatch }
        do { try await database.ensureZone(zone) } catch let failure as CloudFailure { throw Self.error(failure) }
        var bound = existing ?? Binding(userRecordName: user, zone: zone)
        if existing == nil { try save(bound) }
        if subscribes, bound.subscribed != true, (try? await database.subscribe(zone: zone)) != nil {
            bound.subscribed = true
            try? save(bound)
        }
        prepared = true
    }

    func push(_ records: [SyncRecord]) async throws {
        try await prepare()
        let personal = records.filter { $0.zone == .personal }
        var start = 0
        while start < personal.count {
            let slice = Array(personal[start..<min(start + Self.chunk, personal.count)])
            try await save(slice.map(cloudRecord))
            start += slice.count
        }
    }
    /// Saves records, splitting a request iCloud finds too large, and settles conflicts.
    private func save(_ records: [CloudRecord], attempt: Int = 0) async throws {
        guard !records.isEmpty else { return }
        let results: [String: CloudSaveResult]
        do { results = try await database.save(records, zone: zone) }
        catch CloudFailure.tooLarge where records.count > 1 {
            let half = records.count / 2
            try await save(Array(records[..<half]), attempt: attempt)
            try await save(Array(records[half...]), attempt: attempt)
            return
        } catch let failure as CloudFailure { throw failure == .zoneNotFound ? lostZone() : Self.error(failure) }
        var retry: [CloudRecord] = []
        var failure: CloudFailure?
        for record in records {
            switch results[record.name] {
            case .saved(let saved)?: tags[record.name] = saved.tag
            case .conflict(let server)?:
                tags[record.name] = server.tag
                // Ours is newer: save it again on top of the server's version. Otherwise the
                // server's stays, and the next pull brings it to this device.
                if SyncEngine.wins(Self.syncRecord(record), over: Self.syncRecord(server)) {
                    var again = record; again.tag = server.tag; retry.append(again)
                }
            case .failed(let error)?: failure = failure ?? error
            case nil: failure = failure ?? .other("iCloud didn't confirm a record.")
            }
        }
        if let failure { throw failure == .zoneNotFound ? lostZone() : Self.error(failure) }
        if !retry.isEmpty {
            guard attempt < 3 else { throw SyncError.network("Another device kept changing the same item. Try again.") }
            try await save(retry, attempt: attempt + 1)
        }
    }

    func pull(since token: Data?) async throws -> (records: [SyncRecord], token: Data?) {
        try await prepare()
        var token = token, restarted = false
        var records: [SyncRecord] = []
        while true {
            let changes: CloudChanges
            do { changes = try await database.changes(zone: zone, since: token) }
            catch CloudFailure.tokenExpired where !restarted {
                // Too old to continue from: fetch the whole zone again; merging is idempotent.
                token = nil; restarted = true; records = []; continue
            } catch let failure as CloudFailure { throw failure == .zoneNotFound ? lostZone() : Self.error(failure) }
            for record in changes.records {
                tags[record.name] = record.tag
                records.append(Self.syncRecord(record))
            }
            token = changes.token
            if !changes.moreComing { break }
        }
        return (records, token)
    }

    /// The zone is gone (deleted from Settings, or reset): it's created again on the next sync, and
    /// the engine sends everything again.
    private func lostZone() -> SyncError { prepared = false; tags = [:]; return .resetRequired }
    private func cloudRecord(_ record: SyncRecord) -> CloudRecord {
        .init(name: record.id, type: record.type, modified: record.modified, device: record.device, deleted: record.deleted,
              payload: record.payload, tag: tags[record.id])
    }
    static func syncRecord(_ record: CloudRecord) -> SyncRecord {
        .init(id: record.name, type: record.type, zone: .personal, modified: record.modified, device: record.device,
              payload: record.payload, deleted: record.deleted)
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

// MARK: CloudKit

/// The person's private iCloud database in the container `iCloud.com.zlichtman.kemosabe`. Every
/// field is in `encryptedValues` (end-to-end encrypted with Advanced Data Protection, and
/// encrypted at rest otherwise); a payload too large for a record's field goes in an asset,
/// which CloudKit also encrypts.
struct CKCloudDatabase: CloudDatabase {
    static let containerID = "iCloud.com.zlichtman.kemosabe"
    static let recordType = "SyncRecord"
    /// Payloads above this go in an asset (a record's fields can hold about 1 MB in all).
    static let inlineLimit = 600_000
    /// Created only when used: a build without the iCloud entitlement must never touch CloudKit.
    private var container: CKContainer { CKContainer(identifier: Self.containerID) }
    private var database: CKDatabase { container.privateCloudDatabase }
    static func zoneID(_ name: String) -> CKRecordZone.ID { .init(zoneName: name, ownerName: CKCurrentUserDefaultName) }

    func accountStatus() async throws -> CloudAccountStatus {
        let status: CKAccountStatus
        do { status = try await container.accountStatus() } catch { throw Self.failure(error) }
        switch status {
        case .available: return .available
        case .noAccount: return .noAccount
        case .restricted: return .restricted
        case .temporarilyUnavailable: return .temporarilyUnavailable
        default: return .couldNotDetermine
        }
    }
    func userRecordName() async throws -> String {
        do { return try await container.userRecordID().recordName } catch { throw Self.failure(error) }
    }
    func ensureZone(_ zone: String) async throws {
        do { _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: Self.zoneID(zone))], deleting: []) }
        catch { throw Self.failure(error) }
    }
    func subscribe(zone: String) async throws {
        let subscription = CKRecordZoneSubscription(zoneID: Self.zoneID(zone), subscriptionID: "changes-" + zone)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        do { _ = try await database.modifySubscriptions(saving: [subscription], deleting: []) } catch { throw Self.failure(error) }
    }
    func save(_ records: [CloudRecord], zone: String) async throws -> [String: CloudSaveResult] {
        var files: [URL] = []
        defer { for file in files { try? FileManager.default.removeItem(at: file) } }
        let zoneID = Self.zoneID(zone)
        let prepared = try records.map { try Self.makeRecord($0, zone: zoneID, files: &files) }
        let saved: [CKRecord.ID: Result<CKRecord, Error>]
        do { saved = try await database.modifyRecords(saving: prepared, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false).saveResults }
        catch { throw Self.failure(error) }
        var results: [String: CloudSaveResult] = [:]
        for (id, result) in saved {
            switch result {
            case .success(let record):
                results[id.recordName] = (try? Self.cloudRecord(record)).map(CloudSaveResult.saved) ?? .failed(.other("iCloud returned a record that couldn't be read."))
            case .failure(let error):
                if let error = error as? CKError, error.code == .serverRecordChanged, let server = error.serverRecord, let record = try? Self.cloudRecord(server) {
                    results[id.recordName] = .conflict(server: record)
                } else { results[id.recordName] = .failed(Self.failure(error)) }
            }
        }
        return results
    }
    func changes(zone: String, since token: Data?) async throws -> CloudChanges {
        let serverToken = token.flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0) }
        do {
            let result = try await database.recordZoneChanges(inZoneWith: Self.zoneID(zone), since: serverToken)
            let records = result.modificationResultsByID.values.compactMap { try? $0.get().record }.compactMap { try? Self.cloudRecord($0) }
            let next = try? NSKeyedArchiver.archivedData(withRootObject: result.changeToken, requiringSecureCoding: true)
            return CloudChanges(records: records, deleted: result.deletions.map(\.recordID.recordName), token: next, moreComing: result.moreComing)
        } catch { throw Self.failure(error) }
    }

    /// A CloudKit record for a synced one: every field encrypted, a large payload as an asset.
    static func makeRecord(_ source: CloudRecord, zone: CKRecordZone.ID, files: inout [URL]) throws -> CKRecord {
        let record = source.tag.flatMap(restore) ?? CKRecord(recordType: recordType, recordID: .init(recordName: source.name, zoneID: zone))
        record.encryptedValues["type"] = source.type
        record.encryptedValues["device"] = source.device
        record.encryptedValues["modified"] = source.modified
        record.encryptedValues["deleted"] = Int64(source.deleted ? 1 : 0)
        if let attachment = source.attachment {
            // An image always goes as an asset, which CloudKit encrypts, beside its small payload.
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("sync-" + UUID().uuidString)
            try attachment.write(to: file, options: [.atomic, .completeFileProtection])
            files.append(file)
            record.encryptedValues["payload"] = source.payload
            record["payloadAsset"] = CKAsset(fileURL: file)
        } else if source.payload.count <= inlineLimit {
            record.encryptedValues["payload"] = source.payload
            record["payloadAsset"] = nil
        } else {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("sync-" + UUID().uuidString)
            try source.payload.write(to: file, options: [.atomic, .completeFileProtection])
            files.append(file)
            record.encryptedValues["payload"] = nil
            record["payloadAsset"] = CKAsset(fileURL: file)
        }
        return record
    }
    static func cloudRecord(_ record: CKRecord) throws -> CloudRecord {
        guard let type = record.encryptedValues["type"] as? String, let device = record.encryptedValues["device"] as? String,
              let modified = record.encryptedValues["modified"] as? Date else { throw CloudFailure.other("Not a KemoSabe record.") }
        let payload: Data
        var attachment: Data?
        let asset = (record["payloadAsset"] as? CKAsset)?.fileURL
        if let inline = record.encryptedValues["payload"] as? Data {
            payload = inline
            // Both: a small payload with its file (a shared profile's image).
            if let asset { attachment = try Data(contentsOf: asset) }
        } else if let asset { payload = try Data(contentsOf: asset) }
        else { payload = Data() }
        return CloudRecord(name: record.recordID.recordName, type: type, modified: modified, device: device,
                           deleted: (record.encryptedValues["deleted"] as? Int64 ?? 0) != 0, payload: payload, tag: systemFields(record),
                           attachment: attachment)
    }
    static func systemFields(_ record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }
    private static func restore(_ tag: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: tag) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }
    static func failure(_ error: Error) -> CloudFailure {
        if let failure = error as? CloudFailure { return failure }
        guard let error = error as? CKError else { return .other(error.localizedDescription) }
        switch error.code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy, .serverResponseLost:
            return .network(retryAfter: error.retryAfterSeconds)
        case .quotaExceeded: return .quotaExceeded
        case .zoneNotFound, .userDeletedZone: return .zoneNotFound
        case .changeTokenExpired: return .tokenExpired
        case .notAuthenticated, .accountTemporarilyUnavailable: return .notAuthenticated
        case .limitExceeded: return .tooLarge
        case .partialFailure:
            if let first = error.partialErrorsByItemID?.values.first { return failure(first) }
            return .other(error.localizedDescription)
        default: return .other(error.localizedDescription)
        }
    }
}

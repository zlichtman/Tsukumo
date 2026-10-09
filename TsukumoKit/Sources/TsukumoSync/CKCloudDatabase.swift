#if canImport(CloudKit)
import CloudKit
import Foundation

/// The owner's private iCloud database. Every field is in `encryptedValues` (end-to-end encrypted
/// with Advanced Data Protection, encrypted at rest otherwise); a payload too large for a record's
/// fields goes in an asset, which CloudKit also encrypts.
///
/// Nothing here turns iCloud on: the app needs the iCloud entitlement and a container registered
/// in the developer portal (an owner step), and the container is touched only when a call is made.
public struct CKCloudDatabase: CloudDatabase {
    public static let recordType = "SyncRecord"
    /// Payloads above this go in an asset (a record's fields hold about 1 MB in all).
    public static let inlineLimit = 600_000
    public let containerID: String

    public init(containerID: String) { self.containerID = containerID }

    private var container: CKContainer { CKContainer(identifier: containerID) }
    private var database: CKDatabase { container.privateCloudDatabase }
    static func zoneID(_ name: String) -> CKRecordZone.ID { CKRecordZone.ID(zoneName: name, ownerName: CKCurrentUserDefaultName) }

    public func accountStatus() async throws -> CloudAccountStatus {
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
    public func userRecordName() async throws -> String {
        do { return try await container.userRecordID().recordName } catch { throw Self.failure(error) }
    }
    public func ensureZone(_ zone: String) async throws {
        do { _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: Self.zoneID(zone))], deleting: []) }
        catch { throw Self.failure(error) }
    }
    public func save(_ records: [CloudRecord], zone: String) async throws -> [String: CloudSaveResult] {
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
                } else {
                    results[id.recordName] = .failed(Self.failure(error))
                }
            }
        }
        return results
    }
    public func changes(zone: String, since token: Data?) async throws -> CloudChanges {
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
        let record = source.tag.flatMap(restore) ?? CKRecord(recordType: recordType, recordID: CKRecord.ID(recordName: source.name, zoneID: zone))
        record.encryptedValues["type"] = source.type
        record.encryptedValues["device"] = source.device
        record.encryptedValues["modified"] = source.modified
        record.encryptedValues["deleted"] = Int64(source.deleted ? 1 : 0)
        if source.payload.count <= inlineLimit {
            record.encryptedValues["payload"] = source.payload
            record["payloadAsset"] = nil
        } else {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("sync-" + UUID().uuidString)
            #if os(iOS)
            try source.payload.write(to: file, options: [.atomic, .completeFileProtection])
            #else
            try source.payload.write(to: file, options: [.atomic])
            #endif
            files.append(file)
            record.encryptedValues["payload"] = nil
            record["payloadAsset"] = CKAsset(fileURL: file)
        }
        return record
    }
    static func cloudRecord(_ record: CKRecord) throws -> CloudRecord {
        guard let type = record.encryptedValues["type"] as? String, let device = record.encryptedValues["device"] as? String,
              let modified = record.encryptedValues["modified"] as? Date else { throw CloudFailure.other("Not a Tsukumo record.") }
        let payload: Data
        if let inline = record.encryptedValues["payload"] as? Data { payload = inline }
        else if let asset = (record["payloadAsset"] as? CKAsset)?.fileURL { payload = try Data(contentsOf: asset) }
        else { payload = Data() }
        return CloudRecord(name: record.recordID.recordName, type: type, modified: modified, device: device,
                           deleted: (record.encryptedValues["deleted"] as? Int64 ?? 0) != 0, payload: payload, tag: systemFields(record))
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
#endif

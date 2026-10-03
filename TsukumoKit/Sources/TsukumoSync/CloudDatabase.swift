import Foundation

// The cloud database, behind a protocol (ported from the app's `CloudKitSync.swift`). CloudKit is
// one implementation (`CKCloudDatabase`); tests and previews use `InMemoryCloudDatabase`, so
// conflicts, account changes, quota, and lost zones are checked without iCloud.

/// One synced record as the cloud database holds it.
public struct CloudRecord: Hashable, Sendable {
    public var name: String
    public var type: String
    public var modified: Date
    public var device: String
    public var deleted: Bool
    public var payload: Data
    /// The server's version of the record, so a save can be made conditional on it; nil for a
    /// record this device hasn't seen from the server.
    public var tag: Data?
    public init(name: String, type: String, modified: Date, device: String, deleted: Bool, payload: Data, tag: Data? = nil) {
        self.name = name; self.type = type; self.modified = modified; self.device = device
        self.deleted = deleted; self.payload = payload; self.tag = tag
    }
}

public enum CloudAccountStatus: Hashable, Sendable { case available, noAccount, restricted, temporarilyUnavailable, couldNotDetermine }

public enum CloudSaveResult: Hashable, Sendable {
    case saved(CloudRecord)
    /// The server has a version this save didn't start from.
    case conflict(server: CloudRecord)
    case failed(CloudFailure)
}

public enum CloudFailure: Error, Hashable, Sendable {
    case network(retryAfter: Double?)
    case quotaExceeded
    case zoneNotFound
    case tokenExpired
    case notAuthenticated
    /// The request was too large; send fewer records at once.
    case tooLarge
    case other(String)
}

public struct CloudChanges: Hashable, Sendable {
    public var records: [CloudRecord]
    /// Records removed outright (deletions are tombstones, so these come only from outside).
    public var deleted: [String]
    public var token: Data?
    public var moreComing: Bool
    public init(records: [CloudRecord], deleted: [String], token: Data?, moreComing: Bool) {
        self.records = records; self.deleted = deleted; self.token = token; self.moreComing = moreComing
    }
}

/// The few things sync needs from a cloud database.
public protocol CloudDatabase: Sendable {
    func accountStatus() async throws -> CloudAccountStatus
    /// The iCloud user this device is signed in as (an app-scoped ID, never an email or name).
    func userRecordName() async throws -> String
    func ensureZone(_ zone: String) async throws
    /// Saves each record only if the server still has the version its `tag` names (or has none).
    func save(_ records: [CloudRecord], zone: String) async throws -> [String: CloudSaveResult]
    func changes(zone: String, since token: Data?) async throws -> CloudChanges
}

/// A cloud database in memory, with CloudKit's rules: conditional saves, change tokens, zones.
/// Tests can play another device, fail the next call, or lose the zone.
public actor InMemoryCloudDatabase: CloudDatabase {
    private struct Stored { var record: CloudRecord; var version: Int; var change: Int }
    private var zones: [String: [String: Stored]] = [:]
    private var changeCounter = 0
    public var status: CloudAccountStatus = .available
    public var user = "_test-user"
    /// The next call (any kind) fails with this, once.
    public var nextFailure: CloudFailure?
    /// The most records one save accepts before failing with `.tooLarge`.
    public var maxBatch = 400
    /// Every record name saved, in order (to check what left the device).
    public private(set) var savedNames: [String] = []
    public private(set) var savedPayloads: [Data] = []

    public init() {}

    public func setStatus(_ status: CloudAccountStatus) { self.status = status }
    public func setUser(_ user: String) { self.user = user }
    public func failNext(_ failure: CloudFailure) { nextFailure = failure }
    public func setMaxBatch(_ count: Int) { maxBatch = count }
    /// Removes a zone, as deleting iCloud data from Settings does.
    public func dropZone(_ zone: String) { zones[zone] = nil }

    private func check() throws { if let failure = nextFailure { nextFailure = nil; throw failure } }

    public func accountStatus() async throws -> CloudAccountStatus { try check(); return status }
    public func userRecordName() async throws -> String { try check(); return user }
    public func ensureZone(_ zone: String) async throws { try check(); if zones[zone] == nil { zones[zone] = [:] } }

    public func save(_ records: [CloudRecord], zone: String) async throws -> [String: CloudSaveResult] {
        try check()
        guard zones[zone] != nil else { throw CloudFailure.zoneNotFound }
        guard records.count <= maxBatch else { throw CloudFailure.tooLarge }
        var results: [String: CloudSaveResult] = [:]
        for record in records {
            let existing = zones[zone]?[record.name]
            if let existing, record.tag != Self.tag(existing.version) {
                results[record.name] = .conflict(server: existing.record)
                continue
            }
            changeCounter += 1
            let version = (existing?.version ?? 0) + 1
            var saved = record
            saved.tag = Self.tag(version)
            zones[zone]?[record.name] = Stored(record: saved, version: version, change: changeCounter)
            savedNames.append(record.name)
            savedPayloads.append(record.payload)
            results[record.name] = .saved(saved)
        }
        return results
    }

    public func changes(zone: String, since token: Data?) async throws -> CloudChanges {
        try check()
        guard let stored = zones[zone] else { throw CloudFailure.zoneNotFound }
        let after = token.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        let changed = stored.values.filter { $0.change > after }.sorted { $0.change < $1.change }.map(\.record)
        return CloudChanges(records: changed, deleted: [], token: Data(String(changeCounter).utf8), moreComing: false)
    }

    /// Writes a record as another device would (an unconditional save).
    public func write(asAnotherDevice record: CloudRecord, zone: String) {
        changeCounter += 1
        let version = (zones[zone]?[record.name]?.version ?? 0) + 1
        var saved = record
        saved.tag = Self.tag(version)
        if zones[zone] == nil { zones[zone] = [:] }
        zones[zone]?[record.name] = Stored(record: saved, version: version, change: changeCounter)
    }
    public func record(_ name: String, zone: String) -> CloudRecord? { zones[zone]?[name]?.record }

    static func tag(_ version: Int) -> Data { Data("v\(version)".utf8) }
}

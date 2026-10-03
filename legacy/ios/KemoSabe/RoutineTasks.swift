import Foundation
import CryptoKit

enum RoutineOperation: String, Codable, CaseIterable, Sendable { case createBlock, moveBlock, createReminder, rescheduleReminder }
struct RoutineDestination: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let sourceID: String
    let name: String
    let sourceName: String
    let reminders: Bool
    let maySync: Bool
}
struct StandingGrant: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let destination: RoutineDestination
    let operations: Set<RoutineOperation>
    let earliestHour: Int
    let latestHour: Int
    let maximumMinutes: Int
    let expiresAt: Date
    var revokedAt: Date?
    func permits(_ write: RoutineWrite, now: Date) -> Bool {
        guard revokedAt == nil, expiresAt > now, destination == write.destination,
              operations.contains(write.operation), (0...23).contains(earliestHour),
              (1...24).contains(latestHour), earliestHour < latestHour,
              write.start > now, write.end > write.start,
              write.end.timeIntervalSince(write.start) <= Double(maximumMinutes * 60) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        guard let zone = TimeZone(identifier: write.timeZone) else { return false }
        calendar.timeZone = zone
        let day = calendar.startOfDay(for: write.start)
        guard let lower = calendar.date(bySettingHour: earliestHour, minute: 0, second: 0, of: day),
              let upper = latestHour == 24 ? calendar.date(byAdding: .day, value: 1, to: day) : calendar.date(bySettingHour: latestHour, minute: 0, second: 0, of: day) else { return false }
        return write.start >= lower && write.end <= upper
    }
}
struct RoutineWrite: Codable, Equatable, Sendable {
    let operationID: UUID
    let operation: RoutineOperation
    let destination: RoutineDestination
    let start: Date
    let end: Date
    let timeZone: String
    let calendarDigest: String
    let targetID: String?
    let targetDigest: String?
    // Only neutral labels cross a possibly synced destination. Task details and
    // inferred reasons remain in the protected proposal, opened through its URL.
    var externalTitle: String { destination.reminders ? "KemoSabe reminder" : "KemoSabe focus" }
    var marker: URL { URL(string: "kemosabe://routine/\(operationID.uuidString)")! }
    func validate(now: Date) throws {
        guard !destination.id.isEmpty, !destination.sourceID.isEmpty,
              start > now, end > start, end.timeIntervalSince(start) <= 4*3600,
              start < now.addingTimeInterval(7*86400), TimeZone(identifier: timeZone) != nil,
              destination.reminders == [.createReminder, .rescheduleReminder].contains(operation),
              ([.moveBlock,.rescheduleReminder].contains(operation) ? (targetID != nil && targetDigest != nil) : (targetID == nil && targetDigest == nil)) else { throw RoutineError.unavailable }
    }
}
struct RoutineBusyInterval: Codable, Equatable, Sendable {
    let id: String
    let start: Date
    let end: Date
    let fingerprint: String
}
struct RoutineDaySnapshot: Codable, Sendable {
    let date: Date
    let busy: [RoutineBusyInterval]
    var digest: String { RoutineHash.of(busy.sorted { $0.id < $1.id }) }
    func conflicts(start: Date, end: Date, excluding: String? = nil) -> Bool {
        busy.contains { $0.id != excluding && $0.start < end && $0.end > start }
    }
}
enum RoutineHash {
    static func of<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return "invalid" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
struct RoutineWriteReceipt: Codable, Equatable, Sendable {
    let operationID: UUID
    let itemID: String
    let fingerprint: String
    let verifiedAt: Date
}
@MainActor protocol RoutineNativeTools {
    func destinations(reminders: Bool) throws -> [RoutineDestination]
    func day(_ date: Date) throws -> RoutineDaySnapshot
    func validate(_ write: RoutineWrite, owned: [RoutineWriteReceipt]) throws
    func execute(_ write: RoutineWrite) throws -> RoutineWriteReceipt
    func reconcile(_ write: RoutineWrite) async throws -> RoutineWriteReceipt?
}

/// Resumable execution uses the existing approval ledger as its only journal.
/// Recovery reconciles writes; it never blindly replays an uncertain operation.
@MainActor final class TaskRunner {
    let ledger: RoutineLedger
    let native: any RoutineNativeTools
    private var running = Set<UUID>()
    init(ledger: RoutineLedger, native: any RoutineNativeTools) { self.ledger = ledger; self.native = native }
    func run(id: UUID, reviewedDigest: String? = nil, now: Date = Date(),
             current: @escaping @MainActor () -> Bool = { true }) async throws -> RoutineWriteReceipt {
        guard !running.contains(id), current() else { throw RoutineError.stale }
        running.insert(id); defer { running.remove(id) }
        try Task.checkCancellation()
        let state = try await ledger.snapshot()
        guard let proposal = state.proposals.first(where: { $0.id == id }), let write = proposal.routineWrite else { throw RoutineError.stale }
        if proposal.status == .completed, let receipt = proposal.nativeReceipt { return receipt }
        if [.executing,.uncertain].contains(proposal.status) {
            guard let receipt = try await native.reconcile(write) else { throw RoutineError.stale }
            try await ledger.reconcileNative(id: id, receipt: receipt, now: Date())
            return receipt
        }
        // An expired proposal cannot start a write, but an already attempted
        // write must remain reconcilable after suspension or a process restart.
        guard proposal.expiresAt > now else { throw RoutineError.stale }
        try write.validate(now: now)
        let owned = state.proposals.compactMap(\.nativeReceipt)
        try native.validate(write, owned: owned)
        guard current() else { throw CancellationError() }
        // Atomic authorization + claim: a model cannot manufacture a grant ID.
        let claimed = try await ledger.claimNative(id: id, digest: proposal.digest, reviewedDigest: reviewedDigest, now: Date())
        do {
            try Task.checkCancellation()
            guard current(), claimed.routineWrite == write else { throw RoutineError.stale }
            try native.validate(write, owned: owned)
            let receipt = try native.execute(write)
            try await ledger.finishNative(id: id, receipt: receipt, now: Date())
            return receipt
        } catch {
            try? await ledger.finish(id: id, receipt: nil, now: Date())
            throw error
        }
    }
}

extension RoutineLedger {
    func setDestination(_ destination: RoutineDestination) throws {
        var state = try snapshot()
        var destinations = state.routineDestinations ?? []
        destinations.removeAll { $0.reminders == destination.reminders }; destinations.append(destination)
        // Changing the destination never transfers an old permission to it.
        state.routineDestinations = destinations
        for i in (state.standingGrants ?? []).indices where state.standingGrants![i].destination.reminders == destination.reminders {
            state.standingGrants![i].revokedAt = Date()
        }
        try commit(state)
    }
    func grant(_ grant: StandingGrant, now: Date = Date()) throws {
        var state = try snapshot()
        guard state.routineDestinations?.contains(grant.destination) == true,
              grant.expiresAt > now, grant.expiresAt <= now.addingTimeInterval(31*86400),
              !grant.operations.isEmpty, grant.revokedAt == nil,
              (0...23).contains(grant.earliestHour), (1...24).contains(grant.latestHour),
              grant.earliestHour < grant.latestHour, (1...240).contains(grant.maximumMinutes) else { throw RoutineError.unavailable }
        var grants = state.standingGrants ?? []
        grants.removeAll { $0.destination.reminders == grant.destination.reminders }
        grants.append(grant); state.standingGrants = grants; try commit(state)
    }
    func revokeGrant(id: UUID, now: Date = Date()) throws {
        var state = try snapshot()
        guard let index = state.standingGrants?.firstIndex(where: { $0.id == id }) else { throw RoutineError.stale }
        state.standingGrants![index].revokedAt = now; try commit(state)
    }
    func claimNative(id: UUID, digest: String, reviewedDigest: String?, now: Date) throws -> RoutineProposal {
        var state = try snapshot()
        guard let index = state.proposals.firstIndex(where: { $0.id == id }),
              state.proposals[index].status == .needsReview, state.proposals[index].digest == digest,
              state.proposals[index].expiresAt > now, let write = state.proposals[index].routineWrite,
              state.routineDestinations?.contains(write.destination) == true else { throw RoutineError.stale }
        try write.validate(now: now)
        guard reviewedDigest == digest || (state.standingGrants ?? []).contains(where: { $0.permits(write, now: now) }) else { throw ToolFailure.missingPermission }
        state.proposals[index].approvedDigest = digest; state.proposals[index].status = .executing
        try commit(state); return state.proposals[index]
    }
    func finishNative(id: UUID, receipt: RoutineWriteReceipt, now: Date) throws {
        var state = try snapshot()
        guard let index = state.proposals.firstIndex(where: { $0.id == id }), state.proposals[index].status == .executing,
              state.proposals[index].routineWrite?.operationID == receipt.operationID else { throw RoutineError.stale }
        state.proposals[index].nativeReceipt = receipt; state.proposals[index].status = .completed
        state.proposals[index].receipt = "Verified in \(state.proposals[index].routineWrite!.destination.name)"
        try commit(state)
    }
    func reconcileNative(id: UUID, receipt: RoutineWriteReceipt, now: Date) throws {
        var state = try snapshot()
        guard let index = state.proposals.firstIndex(where: { $0.id == id }), [.executing,.uncertain].contains(state.proposals[index].status),
              state.proposals[index].routineWrite?.operationID == receipt.operationID else { throw RoutineError.stale }
        state.proposals[index].nativeReceipt = receipt; state.proposals[index].status = .completed
        state.proposals[index].receipt = "Rechecked and verified in \(state.proposals[index].routineWrite!.destination.name)"
        try commit(state)
    }
}

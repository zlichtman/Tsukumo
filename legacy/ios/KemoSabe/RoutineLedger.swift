import Foundation
import CryptoKit

struct RoutineProposal: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case morningBrief, alarm, emailDraft, scheduleChange, music, draft, memory }
    enum Status: String, Codable {
        case needsReview, approved, executing, completed, rejected, expired, uncertain
        var label: String {
            switch self {
            case .needsReview: "Waiting for your approval"
            case .approved: "Approved"
            case .executing: "In progress"
            case .completed: "Completed"
            case .rejected: "Dismissed"
            case .expired: "Expired"
            case .uncertain: "Needs checking"
            }
        }
    }
    var id = UUID()
    let key: String
    let kind: Kind
    var title: String
    var body: String
    var scheduledAt: Date?
    let createdAt: Date
    var expiresAt: Date
    var revision = 1
    var status: Status = .needsReview
    var approvedDigest: String?
    var receipt: String?
    var origin: PlanningOrigin?
    var memoryScope: String?
    var routineWrite: RoutineWrite?
    var nativeReceipt: RoutineWriteReceipt?
    var preferenceFeatures: [Double]?
    var digest: String {
        var payload = "\(id)|\(revision)|\(kind.rawValue)|\(title)|\(body)|\(scheduledAt?.timeIntervalSince1970 ?? 0)"
        if let origin {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            payload += "|\(String(decoding: (try? encoder.encode(origin)) ?? Data(), as: UTF8.self))|\(memoryScope ?? "")|\(expiresAt.timeIntervalSince1970)"
        }
        if let routineWrite { payload += "|routine:" + RoutineHash.of(routineWrite) + "|expiry:\(expiresAt.timeIntervalSince1970)" }
        return SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
struct RoutineDocument: Codable {
    var version = 1
    var enabled = false
    var bedtime: Date?
    var wokeAt: Date?
    var proposals: [RoutineProposal] = []
    var audit: [String] = []
    // Optional for migration from build 12; observations start with this release.
    var context: ContinuousContext?
    var routineDestinations: [RoutineDestination]?
    var standingGrants: [StandingGrant]?
}
enum RoutineError: Error { case full, stale, unavailable, corrupt }

/// One serialized writer, atomic checkpoints, bounded storage. Models can propose;
/// only an exact, unexpired approval can enter an executor. No network in this actor.
actor RoutineLedger {
    /// The open account's ledger; replaced when the account changes while the app runs.
    static var shared: RoutineLedger { sharedLock.withLock { current } }
    static func reopen() { sharedLock.withLock { current = forCurrentAccount() } }
    private static func forCurrentAccount() -> RoutineLedger {
        RoutineLedger(url: LocalRepository.standard.url.deletingLastPathComponent().appendingPathComponent("routines.json"))
    }
    private static let sharedLock = NSLock()
    private static var current = forCurrentAccount()
    private let url: URL
    private var document: RoutineDocument?
    init(url: URL) { self.url = url }
    func snapshot() throws -> RoutineDocument {
        if let document { return document }
        let loaded = FileManager.default.fileExists(atPath: url.path)
            ? try JSONDecoder().decode(RoutineDocument.self, from: Data(contentsOf: url)) : RoutineDocument()
        guard loaded.version == 1 else { throw RoutineError.corrupt }
        document = loaded; return loaded
    }
    func commit(_ value: RoutineDocument) throws {
        var next = value
        next.audit = Array(next.audit.suffix(128))
        // A ledger left from an account that's no longer open never writes (see `AccountDirectory.permitsWrite`).
        try AccountDirectory.checkWrite(to: url)
        var folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        try JSONEncoder().encode(next).write(to: url, options: [.atomic, .completeFileProtection])
        document = next // Never publish a mutation before it is durable.
    }
    func setEnabled(_ enabled: Bool) throws {
        var next = try snapshot(); next.enabled = enabled; try commit(next)
    }
    func recordBedtime(_ now: Date) throws {
        var next = try snapshot()
        guard next.context?.learning != false else { return }
        next.bedtime = now; next.wokeAt = nil
        var context = next.context ?? ContinuousContext()
        context.observe(kind: .reportedBedtime, text: "User said they are going to bed", at: now)
        next.context = context
        next.audit.append("\(now): user reported going to bed"); try commit(next)
    }
    func recordWake(_ now: Date) throws {
        var next = try snapshot()
        guard next.context?.learning != false else { return }
        next.wokeAt = now
        var context = next.context ?? ContinuousContext()
        context.observe(kind: .reportedWake, text: "User said they are awake", at: now)
        next.context = context
        next.audit.append("\(now): user reported waking"); try commit(next)
    }
    func observeConversation(id: UUID, text: String, now: Date) throws {
        try Task.checkCancellation()
        var next = try snapshot(), context = nextContext()
        context.observe(id: id, kind: .conversation, text: text, at: now)
        next.context = context; try commit(next)
    }
    /// Removes notes taken from deleted conversations (see `ContextForgetting`).
    func forgetConversations(_ digests: Set<String>) throws {
        guard !digests.isEmpty else { return }
        var next = try snapshot(), context = nextContext()
        context.observations.removeAll { $0.kind == .conversation && (digests.contains(ContextForgetting.everything) || digests.contains(ContextForgetting.digest($0.text))) }
        next.context = context; try commit(next)
    }
    private func nextContext() -> ContinuousContext { document?.context ?? ContinuousContext() }
    func refreshContext(now: Date) throws {
        try Task.checkCancellation()
        var next = try snapshot(), context = nextContext()
        context.compact(now: now); next.context = context; try commit(next)
    }
    func setLearning(_ value: Bool) throws {
        var next = try snapshot(), context = nextContext()
        context.learning = value; next.context = context; try commit(next)
    }
    func clearContext() throws {
        var next = try snapshot(); var context = ContinuousContext()
        context.learning = next.context?.learning ?? true
        next.context = context; next.bedtime = nil; next.wokeAt = nil
        next.audit.removeAll { $0.contains("user reported going to bed") || $0.contains("user reported waking") }
        try commit(next)
    }
    @discardableResult func propose(_ proposal: RoutineProposal) throws -> RoutineProposal {
        var next = try snapshot()
        if let existing = next.proposals.first(where: { $0.key == proposal.key }) { return existing }
        Self.makeRoom(for: 1, in: &next, now: proposal.createdAt)
        guard next.proposals.count < Self.capacity else { throw RoutineError.full }
        var safe = proposal; safe.status = .needsReview; safe.approvedDigest = nil; safe.receipt = nil
        guard safe.body.count <= 8000, safe.title.count <= 160, safe.expiresAt > safe.createdAt else { throw RoutineError.unavailable }
        next.proposals.append(safe); try commit(next); return safe
    }
    /// Commit a whole validated plan or nothing. Request keys provide idempotence;
    /// a retry with changed content cannot replace an already reviewed proposal.
    func enqueuePlan(_ proposals: [RoutineProposal]) throws {
        try Task.checkCancellation()
        guard !proposals.isEmpty, proposals.count <= 3,
              Set(proposals.map(\.key)).count == proposals.count,
              Set(proposals.compactMap { $0.origin?.requestID }).count == 1,
              proposals.allSatisfy({ $0.origin != nil && $0.status == .needsReview && $0.approvedDigest == nil && $0.receipt == nil }) else { throw RoutineError.unavailable }
        var next = try snapshot()
        Self.makeRoom(for: proposals.count, in: &next, now: proposals.map(\.createdAt).max()!)
        for proposal in proposals {
            guard proposal.body.count <= 4000, !proposal.body.isEmpty, proposal.title.count <= 100,
                  proposal.expiresAt > proposal.createdAt else { throw RoutineError.unavailable }
            if let existing = next.proposals.first(where: { $0.key == proposal.key }) {
                guard existing.digest == proposal.digest else { throw RoutineError.stale }
            } else { next.proposals.append(proposal) }
        }
        guard next.proposals.count <= Self.capacity else { throw RoutineError.full }
        try Task.checkCancellation()
        try commit(next)
    }
    func removePrepared(id: UUID) throws {
        var next = try snapshot()
        guard let item = next.proposals.first(where: { $0.id == id }),
              item.kind == .draft || item.kind == .memory,
              ![.approved, .executing, .uncertain].contains(item.status) else { throw RoutineError.unavailable }
        next.proposals.removeAll { $0.id == id }; try commit(next)
    }
    func prepareMorning(now: Date, calendar: Calendar = .current) throws {
        // Compatibility entry point: no scripted morning question. The next
        // model turn reads refreshed context and decides what is relevant.
        try refreshContext(now: now)
    }
    func approve(id: UUID, digest: String, now: Date) throws {
        var next = try snapshot()
        guard let i = next.proposals.firstIndex(where: { $0.id == id }), next.proposals[i].status == .needsReview,
              next.proposals[i].digest == digest, next.proposals[i].expiresAt > now else { throw RoutineError.stale }
        next.proposals[i].approvedDigest = digest; next.proposals[i].status = .approved
        next.audit.append("\(now): approved \(id) revision \(next.proposals[i].revision)"); try commit(next)
    }
    func reject(id: UUID) throws {
        var next = try snapshot()
        guard let i = next.proposals.firstIndex(where: { $0.id == id }), [.needsReview,.approved].contains(next.proposals[i].status) else { throw RoutineError.stale }
        next.proposals[i].status = .rejected; next.proposals[i].approvedDigest = nil; try commit(next)
    }
    /// The person dismisses a proposal whose result couldn't be confirmed (the app stopped
    /// mid-write, or a recheck found nothing). It moves to history; nothing is retried.
    func dismissUncertain(id: UUID, now: Date) throws {
        var next = try snapshot()
        guard let i = next.proposals.firstIndex(where: { $0.id == id }), next.proposals[i].status == .uncertain else { throw RoutineError.stale }
        next.proposals[i].status = .rejected; next.proposals[i].approvedDigest = nil
        next.proposals[i].receipt = "Dismissed · result unknown"
        next.audit.append("\(now): dismissed uncertain \(id)"); try commit(next)
    }
    func claim(id: UUID, now: Date) throws -> RoutineProposal {
        var next = try snapshot()
        guard let i = next.proposals.firstIndex(where: { $0.id == id }), next.proposals[i].status == .approved,
              next.proposals[i].approvedDigest == next.proposals[i].digest, next.proposals[i].expiresAt > now else { throw RoutineError.stale }
        next.proposals[i].status = .executing; try commit(next); return next.proposals[i]
    }
    func finish(id: UUID, receipt: String?, now: Date) throws {
        var next = try snapshot()
        guard let i = next.proposals.firstIndex(where: { $0.id == id }), next.proposals[i].status == .executing else { throw RoutineError.stale }
        next.proposals[i].status = receipt == nil ? .uncertain : .completed
        next.proposals[i].receipt = receipt
        next.audit.append("\(now): \(id) \(next.proposals[i].status.rawValue)"); try commit(next)
    }
    func recover(now: Date) throws {
        // Nothing saved means nothing to recover. Not creating an empty ledger here also keeps a
        // launch-time write from landing in an account whose earlier ledger hasn't moved in yet.
        guard document != nil || FileManager.default.fileExists(atPath: url.path) else { return }
        var next = try snapshot()
        for i in next.proposals.indices {
            if next.proposals[i].status == .executing { next.proposals[i].status = .uncertain }
            else if [.needsReview,.approved].contains(next.proposals[i].status), next.proposals[i].expiresAt <= now { next.proposals[i].status = .expired }
        }
        try commit(next)
    }
    static let capacity = 64
    /// Backpressure without dropping pending work: proposals past their deadline expire, and
    /// finished history (oldest first) gives way when new proposals need the room. Pending,
    /// approved, executing, and uncertain proposals are never removed here.
    static func makeRoom(for incoming: Int, in document: inout RoutineDocument, now: Date) {
        for i in document.proposals.indices where [.needsReview, .approved].contains(document.proposals[i].status) && document.proposals[i].expiresAt <= now {
            document.proposals[i].status = .expired; document.proposals[i].approvedDigest = nil
        }
        let excess = document.proposals.count + incoming - capacity
        guard excess > 0 else { return }
        let finished = document.proposals.filter { [.completed, .rejected, .expired].contains($0.status) }
            .sorted { $0.createdAt < $1.createdAt }.prefix(excess).map(\.id)
        document.proposals.removeAll { finished.contains($0.id) }
    }
    /// Clears Day's recent activity: finished proposals (done, rejected, expired) and their source
    /// excerpts. An alarm that's set and still ahead stays, so it can still be cancelled here.
    @discardableResult func clearHistory(now: Date) throws -> Int {
        var next = try snapshot()
        let before = next.proposals.count
        next.proposals.removeAll { Self.clearable($0, now: now) }
        let removed = before - next.proposals.count
        guard removed > 0 else { return 0 }
        next.audit.append("\(now): cleared \(removed) from recent activity"); try commit(next)
        return removed
    }
    static func clearable(_ proposal: RoutineProposal, now: Date) -> Bool {
        guard [.completed, .rejected, .expired].contains(proposal.status) else { return false }
        return !(proposal.kind == .alarm && proposal.status == .completed && (proposal.scheduledAt ?? .distantPast) > now)
    }
    func recordAlarmCancellation(id: UUID) throws {
        var next = try snapshot()
        guard let i = next.proposals.firstIndex(where: { $0.id == id }), next.proposals[i].kind == .alarm else { throw RoutineError.unavailable }
        next.proposals[i].status = .rejected; next.proposals[i].receipt = "Alarm cancelled"
        next.proposals[i].approvedDigest = nil; try commit(next)
    }
}

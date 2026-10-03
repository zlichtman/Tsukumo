import Foundation

/// Content-free execution evidence. No prompts, excerpts, embeddings, queries,
/// raw audio or model reasoning are duplicated here. This is not a work queue.
struct ContextRun: Codable, Equatable, Identifiable {
    enum Status: String, Codable { case running, answered, planned, failed, interrupted }
    struct Read: Codable, Equatable { let window: ContextWindow; let records: Int }
    let id: UUID
    let startedAt: Date
    var status: Status = .running
    var reads: [Read] = []
    struct ToolUse: Codable, Equatable {
        let name: String; let records: Int
        /// The connected model's host the result went to; nil when it stayed on this device.
        var sentTo: String? = nil
    }
    var tools: [ToolUse]?
}
actor ContextRunJournal {
    private struct Document: Codable { var version = 1; var runs: [ContextRun] = [] }
    private let url: URL
    private var document: Document?
    init(url: URL) { self.url = url }
    private func load() throws -> Document {
        if let document { return document }
        var next = FileManager.default.fileExists(atPath: url.path)
            ? try JSONDecoder().decode(Document.self, from: Data(contentsOf: url)) : Document()
        guard next.version == 1, next.runs.count <= 32, next.runs.allSatisfy({ $0.reads.count <= 4 }) else { throw RoutineError.corrupt }
        // An interrupted read-only inference can be restarted by a new user turn;
        // it must never replay an external write or masquerade as completed work.
        for i in next.runs.indices where next.runs[i].status == .running { next.runs[i].status = .interrupted }
        document = next; return next
    }
    private func commit(_ next: Document) throws {
        try AccountDirectory.checkWrite(to: url)
        var folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        try JSONEncoder().encode(next).write(to: url, options: [.atomic, .completeFileProtection])
        document = next
    }
    func snapshot() throws -> [ContextRun] { try load().runs }
    func begin(_ id: UUID, at: Date) throws {
        var next = try load()
        guard !next.runs.contains(where: { $0.id == id }), !next.runs.contains(where: { $0.status == .running }) else { throw PlanningError.busy }
        next.runs = Array(next.runs.suffix(31)); next.runs.append(.init(id: id, startedAt: at))
        try commit(next)
    }
    func read(_ id: UUID, window: ContextWindow, count: Int) throws {
        var next = try load()
        guard let i = next.runs.firstIndex(where: { $0.id == id }), next.runs[i].status == .running,
              next.runs[i].reads.count < 4, (0...4).contains(count) else { throw PlanningError.invalid }
        next.runs[i].reads.append(.init(window: window, records: count)); try commit(next)
    }
    func finish(_ id: UUID, status: ContextRun.Status) throws {
        var next = try load()
        guard status != .running, let i = next.runs.firstIndex(where: { $0.id == id }), next.runs[i].status == .running else { throw PlanningError.invalid }
        next.runs[i].status = status; try commit(next)
    }
    func tool(_ id: UUID, name: String, records: Int, sentTo: String? = nil) throws {
        var next = try load()
        guard let i = next.runs.firstIndex(where: { $0.id == id }), next.runs[i].status == .running,
              (next.runs[i].tools?.count ?? 0) < 6, (0...20).contains(records), (sentTo?.count ?? 0) <= 255,
              ["context", "calculate", "sequence", "text", "proposal", "calendar", "contacts", "reminders", "attachment"].contains(name) else { throw PlanningError.invalid }
        next.runs[i].tools = (next.runs[i].tools ?? []) + [.init(name: name, records: records, sentTo: sentTo)]
        try commit(next)
    }
    func abandon(_ id: UUID) {
        // Logging may fail while file protection is active. Release only the
        // in-process liveness flag after work ended; the next successful commit
        // persists recovery, or a new process recovers disk's running entry.
        if let i = document?.runs.firstIndex(where: { $0.id == id }), document?.runs[i].status == .running {
            document?.runs[i].status = .interrupted
        }
    }
}

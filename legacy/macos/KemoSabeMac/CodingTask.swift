import Foundation

// `CodingProvider` (which agent a task talks to) is in CodingAgentAdapters.swift.

/// How much an agent may do without asking. `edit` is the saved name of "Ask first" (it asked
/// before edits and commands from the start); `autoEdit` was added later. Each maps onto the
/// agent's own modes in `CodingAgentSession` (Claude Code permission modes, Codex sandbox and
/// approval policy).
enum CodingAccess: String, Codable, CaseIterable, Identifiable {
    case readOnly, edit, autoEdit, full
    var id: String { rawValue }
    var title: String { switch self { case .readOnly: "Read only"; case .edit: "Ask first"; case .autoEdit: "Auto-edit"; case .full: "Full access" } }
    var detail: String {
        switch self {
        case .readOnly: "Reads and plans; changes nothing."
        case .edit: "Asks before editing files or running commands."
        case .autoEdit: "Edits files in its folder; asks before other commands."
        case .full: "Runs any command with your Mac account's access, without asking."
        }
    }
    var symbol: String { switch self { case .readOnly: "eye"; case .edit: "hand.raised"; case .autoEdit: "pencil"; case .full: "exclamationmark.shield" } }
}
enum CodingTaskStatus: String, Codable {
    case preparing, ready, working, needsInput, review, interrupted, failed, done
    var title: String {
        switch self { case .preparing: "Preparing"; case .ready: "Ready"; case .working: "Working"; case .needsInput: "Needs you"; case .review: "Review"; case .interrupted: "Interrupted"; case .failed: "Failed"; case .done: "Done" }
    }
    var running: Bool { self == .working || self == .needsInput || self == .preparing }
}
struct CodingEvent: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case user, assistant, command, file, plan, approval, system, check, collaboration, reasoning }
    var id: String = UUID().uuidString
    var date = Date()
    var kind: Kind
    var text: String
    var detail: String = ""
    var status: String = ""
    var exitCode: Int?
    /// For checks: the Git tree of the task folder the check ran against, recorded only when the
    /// folder was the same before and after the run. A result vouches for that tree and no other.
    var tree: String?
    /// The provider's tool name (Bash, Edit, Read, commandExecution, …), for tool cards.
    var tool: String?
    /// A tool's result, when it isn't the card's main text (a file edit's "updated" note).
    var output: String?
    /// How long a command or tool ran, in seconds.
    var duration: Double?
    /// The provider's handle for forking here: Claude Code's message UUID, Codex's turn ID.
    var ref: String?
    /// Images attached to a user message (paths in the account's attachments folder).
    var images: [String]?
    /// Merges a later report of the same item: empty text and missing values keep what was there,
    /// so a tool's result doesn't erase its command, and a completion doesn't drop streamed text.
    func merged(into old: CodingEvent) -> CodingEvent {
        var next = self
        // The same item keeps its kind: a tool's result arrives without knowing its card.
        next.kind = old.kind
        if next.text.isEmpty { next.text = old.text }
        if next.detail.isEmpty { next.detail = old.detail }
        if next.status.isEmpty { next.status = old.status }
        next.exitCode = next.exitCode ?? old.exitCode; next.tree = next.tree ?? old.tree
        next.tool = next.tool ?? old.tool; next.output = next.output ?? old.output
        next.duration = next.duration ?? old.duration; next.ref = next.ref ?? old.ref; next.images = next.images ?? old.images
        next.date = old.date
        return next
    }
}
struct CodingChange: Codable, Identifiable, Equatable {
    var path: String
    var status: String
    var id: String { path }
}
struct CodingTaskRecord: Codable, Identifiable {
    var id = UUID()
    var projectID: UUID
    var ownerID: String
    var title: String
    var provider: CodingProvider
    var model: String
    var access: CodingAccess
    var projectPath: String
    var directory: String
    var isolated: Bool
    var branch: String?
    var baseCommit: String?
    var baseBranch: String?
    var sessionID: String?
    var status: CodingTaskStatus = .preparing
    var events: [CodingEvent] = []
    var changes: [CodingChange] = []
    var claims: [String] = []
    var updated = Date()
    var created = Date()
    /// The last entry of the task's event log that `events` includes; later entries are replayed on load.
    var logged: Int?
    /// Events that fell off the front of the in-memory view; they remain in the task's log.
    var omittedEvents: Int?
    /// Archived tasks leave the sidebar; their worktree, branch, and log are kept.
    var archived: Bool?
    /// Reasoning effort chosen for the task, from what the agent reports (nil: the model's default).
    var effort: String?
    /// Pinned tasks sort first in the sidebar.
    var pinned: Bool?
    /// Something happened in the task since it was last open.
    var unread: Bool?
    /// Messages written while the agent was working, sent in order when its turn ends.
    var queued: [CodingQueuedMessage]?
    /// Set on a forked task until its agent session starts: the conversation it continues.
    var fork: CodingForkPoint?
    /// Tasks started together by Run with both share a group, for comparing their diffs.
    var group: UUID?
    /// Context packets handed to this task from KemoSabe (`ContextPacket.id`), oldest first: its
    /// lineage. What each carried is in the task's notes and in Library → Requests.
    var contextPackets: [UUID]?
}
struct CodingQueuedMessage: Codable, Equatable, Identifiable {
    var id = UUID()
    var text: String
    var images: [String] = []
}
/// Where a fork branches off: the source task's agent session and the provider's handle for the
/// last message kept (Claude Code: a message UUID; Codex: a turn ID).
struct CodingForkPoint: Codable, Equatable {
    var sessionID: String
    var ref: String
}
/// One line of a task's append-only event log. Deltas are logged as the chunk that arrived, so
/// the log is the complete, uncapped audit trail; the in-memory view is rebuilt from it.
struct CodingLogEntry: Codable, Equatable {
    var seq: Int
    var event: CodingEvent
    var delta: Bool
}
/// The in-memory (and snapshot) view of a task's events: each text field keeps its beginning and
/// its latest part, and only the most recent events are kept. The log keeps everything.
enum CodingTranscript {
    static let keep = 16_000
    static let maximumEvents = 2_000
    static let marker = "\n… (shortened here; the full text is in the task's log) …\n"
    static func cap(_ text: String) -> String {
        guard text.utf8.count > 2 * keep + marker.utf8.count, text.count > 2 * keep + marker.count else { return text }
        return String(text.prefix(keep)) + marker + String(text.suffix(keep))
    }
    static func apply(_ event: CodingEvent, delta: Bool, to record: inout CodingTaskRecord) {
        if let index = record.events.lastIndex(where: { $0.id == event.id }) {
            if delta {
                record.events[index].text = cap(record.events[index].text + event.text)
                record.events[index].detail = cap(record.events[index].detail + event.detail)
                if let output = event.output { record.events[index].output = cap((record.events[index].output ?? "") + output) }
            } else { record.events[index] = capped(event.merged(into: record.events[index])) }
        } else {
            record.events.append(capped(event))
            if record.events.count > maximumEvents {
                let extra = record.events.count - maximumEvents
                record.events.removeFirst(extra); record.omittedEvents = (record.omittedEvents ?? 0) + extra
            }
        }
    }
    private static func capped(_ event: CodingEvent) -> CodingEvent {
        var event = event; event.text = cap(event.text); event.detail = cap(event.detail); event.output = event.output.map(cap); return event
    }
}
struct CodingArchive: Codable {
    /// 2 added per-task event logs (`logged`); 1 kept every event inline. Both are read.
    var schema = 2
    var ownerID: String
    var tasks: [CodingTaskRecord]
}
/// Tasks are kept as a snapshot (`tasks.json`, rewritten rarely and debounced while agents stream)
/// plus one append-only event log per task (`Logs/<task>.jsonl`). Loading replays log entries newer
/// than the snapshot, so a crash between snapshots loses nothing that was logged.
struct CodingStorage {
    var directory: URL
    var ownerID: String
    /// Local accounts this account adopted at Sign in with Apple; their tasks open as this account's.
    var formerOwners: Set<String> = []
    var url: URL { directory.appendingPathComponent("tasks.json") }
    var logs: URL { directory.appendingPathComponent("Logs", isDirectory: true) }
    func logURL(_ task: UUID) -> URL { logs.appendingPathComponent(task.uuidString + ".jsonl") }
    /// An account's coding data: its own folder, checked against its ID on every read and write.
    /// The account's coding store. Tasks written before this device adopted the account (a local
    /// account moved into an Apple account) still open under it.
    static func forAccount(_ account: AccountIdentity, base: URL = AccountDirectory.base) -> CodingStorage {
        let folder = AccountDirectory.folder(for: account, base: base)
        return .init(directory: folder.appendingPathComponent("Coding", isDirectory: true), ownerID: account.id,
                     formerOwners: AccountDirectory.formerOwners(of: folder))
    }
    /// The snapshot alone, after checking that it belongs to this account and a known format.
    func readSnapshot() throws -> [CodingTaskRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let saved = try JSONDecoder().decode(CodingArchive.self, from: Data(contentsOf: url))
        let owners = formerOwners.union([ownerID])
        guard (1...2).contains(saved.schema), owners.contains(saved.ownerID), saved.tasks.allSatisfy({ owners.contains($0.ownerID) }) else {
            throw CodingFailure("Coding data belongs to another account or a newer version. It has not been overwritten.")
        }
        return saved.tasks.map { var task = $0; task.ownerID = ownerID; return task }
    }
    /// The snapshot with every newer logged event replayed. A torn last line (a write cut off
    /// by a crash or power loss) is cut from the log so later appends start on a clean line.
    func read() throws -> [CodingTaskRecord] {
        var tasks = try readSnapshot()
        for index in tasks.indices {
            let entries = try readLog(tasks[index].id, repair: true)
            let seen = tasks[index].logged ?? 0
            for entry in entries where entry.seq > seen { CodingTranscript.apply(entry.event, delta: entry.delta, to: &tasks[index]) }
            tasks[index].logged = max(seen, entries.last?.seq ?? 0)
        }
        return tasks
    }
    /// Every complete entry in a task's log, in order. Lines that don't decode are skipped, not dropped from the file.
    func readLog(_ task: UUID, repair: Bool = false) throws -> [CodingLogEntry] {
        let url = logURL(task)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let complete = data.lastIndex(of: 10).map { data.index(after: $0) } ?? data.startIndex
        if repair, complete < data.endIndex {
            let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(data.distance(from: data.startIndex, to: complete)))
            try handle.synchronize()
        }
        let decoder = JSONDecoder()
        return data[..<complete].split(separator: 10).compactMap { try? decoder.decode(CodingLogEntry.self, from: Data($0)) }
            .sorted { $0.seq < $1.seq }
    }
    func appendLog(_ entry: CodingLogEntry, task: UUID) throws {
        try AccountDirectory.checkWrite(to: directory)
        guard FileManager.default.fileExists(atPath: directory.path) else { throw CodingFailure("Coding storage is missing; the event was not recorded.") }
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = logURL(task)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CodingFailure("Could not create the task's event log.") }
        }
        var line = try JSONEncoder().encode(entry); line.append(10)
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: line)
    }
    func save(_ tasks: [CodingTaskRecord]) throws {
        guard tasks.allSatisfy({ $0.ownerID == ownerID }) else { throw CodingFailure("Account changed; coding data was not saved.") }
        guard AccountDirectory.permitsWrite(to: directory) else { throw CodingFailure("Account changed; coding data was not saved.") }
        // Recheck the on-disk envelope before every write, including after a failed load.
        _ = try readSnapshot()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(CodingArchive(ownerID: ownerID, tasks: tasks))
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
/// What the person reviewed: the immutable Git tree of the task folder at that moment, the
/// branch head it sits on, and the diff shown for it. Accept commits exactly this tree, and
/// refuses if the folder or branch no longer matches it.
struct CodingReview: Equatable, Sendable {
    var taskID: UUID
    var base: String
    var head: String
    var tree: String
    var diff: String
}
struct CodingFailure: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
struct CodingOverlap: Identifiable {
    var path: String
    var tasks: [UUID]
    var id: String { path }
    static func find(_ tasks: [CodingTaskRecord]) -> [Self] {
        var owners: [String: Set<UUID>] = [:]
        for task in tasks where task.status != .done {
            for path in Set(task.changes.map(\.path) + task.claims) { owners[path, default: []].insert(task.id) }
        }
        return owners.filter { $0.value.count > 1 }.map { .init(path: $0.key, tasks: Array($0.value)) }.sorted { $0.path < $1.path }
    }
}

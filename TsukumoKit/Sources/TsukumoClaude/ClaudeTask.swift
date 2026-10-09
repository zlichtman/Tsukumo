#if os(macOS)
import Foundation
import TsukumoCore
import TsukumoContext

// The Claude bot's tasks as they're kept: a goal, optional instructions, an optional schedule, a status, and each
// run with its transcript, result, and files. Saved in the app's folder on this Mac (`claude-bot.json`), never in
// iCloud, and never inside Claude's own working folder (so a task can't read the others' transcripts as files).

/// When a task runs.
public enum ClaudeSchedule: Hashable, Sendable, Codable {
    /// Once, as soon as a slot is free.
    case now
    /// Once, at a time.
    case once(at: Date)
    /// Every day at a time of day, in the owner's time zone.
    case daily(hour: Int, minute: Int)
    /// Every so many hours (1 to 168), the first time as soon as it's made.
    case every(hours: Int)

    public var repeats: Bool {
        switch self {
        case .now, .once: false
        case .daily, .every: true
        }
    }

    /// When a task made at `created` first runs.
    public func firstRun(created: Date, calendar: Calendar) -> Date {
        switch self {
        case .now, .every: created
        case .once(let at): at
        case .daily(let hour, let minute): Self.nextDaily(hour: hour, minute: minute, onOrAfter: created, calendar: calendar)
        }
    }

    /// When a repeating task runs again after a run that started at `start`; nil for one that doesn't repeat.
    public func nextRun(after start: Date, calendar: Calendar) -> Date? {
        switch self {
        case .now, .once: nil
        case .daily(let hour, let minute): Self.nextDaily(hour: hour, minute: minute, onOrAfter: start.addingTimeInterval(1), calendar: calendar)
        case .every(let hours): start.addingTimeInterval(TimeInterval(Self.clampHours(hours)) * 3_600)
        }
    }

    static func clampHours(_ hours: Int) -> Int { min(max(hours, 1), 168) }

    static func nextDaily(hour: Int, minute: Int, onOrAfter date: Date, calendar: Calendar) -> Date {
        let parts = DateComponents(hour: min(max(hour, 0), 23), minute: min(max(minute, 0), 59), second: 0)
        if let today = calendar.date(bySettingHour: parts.hour!, minute: parts.minute!, second: 0, of: date), today >= date { return today }
        return calendar.nextDate(after: date, matching: parts, matchingPolicy: .nextTime) ?? date.addingTimeInterval(86_400)
    }

    /// "Once", "Once, Oct 8 at 9:00 AM", "Daily at 9:00 AM", "Every 3 hours".
    public func summary(calendar: Calendar = .current) -> String {
        switch self {
        case .now: return "Once"
        case .once(let at): return "Once, " + Self.when(at, calendar: calendar)
        case .daily(let hour, let minute):
            let date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
            var style = Date.FormatStyle(date: .omitted, time: .shortened)
            style.timeZone = calendar.timeZone
            return "Daily at " + date.formatted(style)
        case .every(let hours):
            let hours = Self.clampHours(hours)
            return hours == 1 ? "Every hour" : "Every \(hours) hours"
        }
    }

    /// "Oct 8 at 9:00 AM", in the calendar's time zone.
    public static func when(_ date: Date, calendar: Calendar) -> String {
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day().hour().minute()
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    private enum CodingKeys: String, CodingKey { case kind, at, hour, minute, hours }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decodeIfPresent(String.self, forKey: .kind) {
        case "once": self = .once(at: try c.decode(Date.self, forKey: .at))
        case "daily": self = .daily(hour: try c.decode(Int.self, forKey: .hour), minute: try c.decode(Int.self, forKey: .minute))
        case "every": self = .every(hours: try c.decode(Int.self, forKey: .hours))
        // "now", or a kind a newer build added: once.
        default: self = .now
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .now: try c.encode("now", forKey: .kind)
        case .once(let at): try c.encode("once", forKey: .kind); try c.encode(at, forKey: .at)
        case .daily(let hour, let minute): try c.encode("daily", forKey: .kind); try c.encode(hour, forKey: .hour); try c.encode(minute, forKey: .minute)
        case .every(let hours): try c.encode("every", forKey: .kind); try c.encode(hours, forKey: .hours)
        }
    }
}

/// Where a task stands.
public enum ClaudeTaskStatus: String, Codable, Hashable, Sendable, CaseIterable {
    /// Waiting for its time or for a free slot.
    case queued
    case running
    /// Waiting on the owner: an approval, or KemoSabe's card.
    case needsYou
    case done
    case failed

    public init(from decoder: Decoder) throws { self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .queued }

    public var title: String {
        switch self {
        case .queued: "Queued"
        case .running: "Running"
        case .needsYou: "Needs you"
        case .done: "Done"
        case .failed: "Failed"
        }
    }
}

/// One line of a run's transcript.
public struct ClaudeTranscriptEntry: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        /// What Claude was asked.
        case goal
        /// Claude's words.
        case claude
        /// A tool it used ("Read notes.md", "Asked KemoSabe").
        case tool
        /// KemoSabe's part: what was asked and what came back (or didn't).
        case kemoSabe
        /// An approval and the owner's answer.
        case approval
        /// A line from Tsukumo ("Started on Claude Code", "Tsukumo quit while this ran").
        case note
        case error

        public init(from decoder: Decoder) throws { self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .note }
    }
    public var id: UUID
    public var at: Date
    public var kind: Kind
    public var text: String
    public init(id: UUID = UUID(), at: Date, kind: Kind, text: String) { self.id = id; self.at = at; self.kind = kind; self.text = text }
}

/// A file a run left in its folder, delivered to the gateway's Inbox (quarantined, never opened).
public struct ClaudeResultFile: Codable, Hashable, Identifiable, Sendable {
    /// The Inbox item.
    public var id: UUID
    public var name: String
    public var bytes: Int
    public var sha256: String
    public init(id: UUID, name: String, bytes: Int, sha256: String) { self.id = id; self.name = name; self.bytes = bytes; self.sha256 = sha256 }
}

/// One time a task ran.
public struct ClaudeRun: Codable, Hashable, Identifiable, Sendable {
    public enum Outcome: String, Codable, Hashable, Sendable {
        case done, failed, stopped
        /// Tsukumo quit while it ran.
        case interrupted
        public init(from decoder: Decoder) throws { self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .failed }
    }
    public var id: UUID
    public var startedAt: Date
    public var endedAt: Date?
    /// What it ran on, in words ("Claude Code 2.1.289", "Your API key: claude-opus-5-5").
    public var engine: String
    public var engineKind: ClaudeEngineKind?
    public var outcome: Outcome?
    public var transcript: [ClaudeTranscriptEntry]
    /// Claude's final answer.
    public var result: String?
    /// Why it failed, in words to show.
    public var failure: String?
    public var files: [ClaudeResultFile]
    /// The result as an artifact, so later tasks and the chat can refer back to it by reference.
    public var memory: ArtifactRef?
    /// Claude Code's session, to continue after a relaunch.
    public var session: String?
    /// This run continued (or started over) one that Tsukumo's quitting interrupted.
    public var resumedAfterQuit: Bool
    /// KemoSabe shared something with Claude during this run (a one-time disclosure).
    public var usedPersonal: Bool
    /// The result wasn't kept as memory because it used what KemoSabe shared; the owner can keep it.
    public var memoryHeld: Bool
    /// The owner kept a result that used what KemoSabe shared (so revoking Claude takes it back).
    public var memoryFromPersonal: Bool
    /// Its memory was taken back (Claude was revoked in the gateway).
    public var memoryRevoked: Bool
    /// Claude's earlier results this run read: its own result's lineage.
    public var sources: [ArtifactRef]

    public init(id: UUID = UUID(), startedAt: Date, engine: String, engineKind: ClaudeEngineKind?, resumedAfterQuit: Bool = false) {
        self.id = id; self.startedAt = startedAt; self.engine = engine; self.engineKind = engineKind
        transcript = []; files = []; self.resumedAfterQuit = resumedAfterQuit
        usedPersonal = false; memoryHeld = false; memoryFromPersonal = false; memoryRevoked = false; sources = []
    }

    /// At most this many transcript lines are kept per run, and this many characters per line.
    public static let maxEntries = 400, maxEntryCharacters = 20_000

    mutating func add(_ kind: ClaudeTranscriptEntry.Kind, _ text: String, at date: Date) {
        transcript.append(ClaudeTranscriptEntry(at: date, kind: kind, text: String(text.prefix(Self.maxEntryCharacters))))
        if transcript.count > Self.maxEntries { transcript.removeFirst(transcript.count - Self.maxEntries) }
    }
    /// Claude's streamed words join its last line, until something else happens.
    mutating func stream(_ delta: String, at date: Date) {
        if let last = transcript.last, last.kind == .claude, last.text.count < Self.maxEntryCharacters {
            transcript[transcript.count - 1].text += delta
        } else {
            add(.claude, delta, at: date)
        }
    }
}

/// A file the owner staged into a task's folder for Claude to read.
public struct ClaudeInputFile: Codable, Hashable, Sendable {
    public var name: String
    public var sha256: String
    public init(name: String, sha256: String) { self.name = name; self.sha256 = sha256 }
}

/// A goal the owner gave Claude.
public struct ClaudeTask: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var goal: String
    public var instructions: String
    public var schedule: ClaudeSchedule
    /// A folder the owner picked; nil works in the task's own folder inside Claude's.
    public var project: String?
    /// What Claude may do there, through `CodingAccessGate.decideSealed` (read only unless the owner chose more).
    public var access: BotPermissions.Access
    /// Secret-looking files in the project the owner named, so Claude may read them (otherwise refused).
    public var allowedSecrets: [String]
    /// Files the owner staged into the task's own folder.
    public var inputs: [ClaudeInputFile]
    public var createdAt: Date
    public var status: ClaudeTaskStatus
    /// When it next starts; nil when it won't again.
    public var nextRunAt: Date?
    /// The newest last; at most `maxRuns`.
    public var runs: [ClaudeRun]
    /// The owner has looked at its last result.
    public var seen: Bool

    public static let maxGoal = 2_000, maxInstructions = 4_000, maxRuns = 20

    public init(id: UUID = UUID(), goal: String, instructions: String = "", schedule: ClaudeSchedule = .now, project: String? = nil,
                access: BotPermissions.Access = .readOnly, allowedSecrets: [String] = [], createdAt: Date, calendar: Calendar = .current) {
        self.id = id
        self.allowedSecrets = allowedSecrets.compactMap(Self.relativePath)
        inputs = []
        self.goal = String(goal.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxGoal))
        self.instructions = String(instructions.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxInstructions))
        self.schedule = schedule; self.project = project; self.access = access; self.createdAt = createdAt
        status = .queued
        nextRunAt = schedule.firstRun(created: createdAt, calendar: calendar)
        runs = []; seen = true
    }

    public var lastRun: ClaudeRun? { runs.last }

    /// A path inside a project as the owner typed it, kept whole ("config/.env.example"): no absolute paths, no "." or
    /// ".." parts, no empty parts; nil when it isn't one.
    public static func relativePath(_ raw: String) -> String? {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while path.hasPrefix("./") { path.removeFirst(2) }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        return path
    }
    /// One line for lists.
    public var title: String { goal.split(whereSeparator: \.isNewline).first.map { String($0.prefix(120)) } ?? "Task" }
}

/// What the owner set for the Claude bot.
public struct ClaudeBotSettings: Codable, Hashable, Sendable {
    public var engine: ClaudeEnginePreference
    /// The model on an API key (from the connection's list, `ModelCatalog`).
    public var apiModel: String
    /// Claude Code's model ("opus", "sonnet", a full ID); nil is Claude Code's own default.
    public var codeModel: String?
    /// How many tasks run at once (1 to 3).
    public var maxConcurrent: Int
    /// Claude may ask KemoSabe (through the gateway, as its own caller). Revoke in Settings, Gateway turns it off.
    public var mayAskKemoSabe: Bool

    public static let defaultAPIModel = "claude-opus-5-5"

    public init(engine: ClaudeEnginePreference = .automatic, apiModel: String = Self.defaultAPIModel, codeModel: String? = nil,
                maxConcurrent: Int = 1, mayAskKemoSabe: Bool = true) {
        self.engine = engine; self.apiModel = apiModel; self.codeModel = codeModel
        self.maxConcurrent = min(max(maxConcurrent, 1), 3); self.mayAskKemoSabe = mayAskKemoSabe
    }

    private enum CodingKeys: String, CodingKey { case engine, apiModel, codeModel, maxConcurrent, mayAskKemoSabe }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        engine = (try? c.decodeIfPresent(ClaudeEnginePreference.self, forKey: .engine)) ?? .automatic
        apiModel = (try? c.decodeIfPresent(String.self, forKey: .apiModel)) ?? Self.defaultAPIModel
        codeModel = try? c.decodeIfPresent(String.self, forKey: .codeModel)
        maxConcurrent = min(max((try? c.decodeIfPresent(Int.self, forKey: .maxConcurrent)) ?? 1, 1), 3)
        mayAskKemoSabe = (try? c.decodeIfPresent(Bool.self, forKey: .mayAskKemoSabe)) ?? true
    }
}

/// One memory artifact the bot made: its task, and whether it carries what KemoSabe shared.
public struct ClaudeMemoryRecord: Codable, Hashable, Sendable {
    public var artifact: UUID
    public var task: UUID
    public var personal: Bool
    public init(artifact: UUID, task: UUID, personal: Bool) { self.artifact = artifact; self.task = task; self.personal = personal }
}

/// Everything the Claude bot keeps on this Mac.
public struct ClaudeBotState: Codable, Hashable, Sendable {
    public var version: Int
    /// Bumped by every save, so two copies of Tsukumo never overwrite each other's changes unseen.
    public var generation: Int
    public var settings: ClaudeBotSettings
    public var tasks: [ClaudeTask]
    /// The chat tab's conversation.
    public var chat: ChatThread?
    /// The chat's Claude Code sessions (`AgentSessionKey.raw`).
    public var sessions: [String: String]
    /// Every memory artifact the bot ever made, whatever the per-task run limit drops: what deleting a task and revoking
    /// Claude revoke.
    public var memories: [ClaudeMemoryRecord]

    public init(settings: ClaudeBotSettings = ClaudeBotSettings(), tasks: [ClaudeTask] = [], chat: ChatThread? = nil, sessions: [String: String] = [:]) {
        version = Self.currentVersion; generation = 0; self.settings = settings; self.tasks = tasks; self.chat = chat; self.sessions = sessions
        memories = []
    }
    private enum CodingKeys: String, CodingKey { case version, generation, settings, tasks, chat, sessions, memories }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        generation = try c.decodeIfPresent(Int.self, forKey: .generation) ?? 0
        settings = try c.decode(ClaudeBotSettings.self, forKey: .settings)
        tasks = try c.decode([ClaudeTask].self, forKey: .tasks)
        chat = try c.decodeIfPresent(ChatThread.self, forKey: .chat)
        sessions = try c.decode([String: String].self, forKey: .sessions)
        memories = try c.decodeIfPresent([ClaudeMemoryRecord].self, forKey: .memories) ?? []
    }
    /// The format this build writes and reads; a newer one is never read (or overwritten) by it.
    public static let currentVersion = 1
}

/// The file: read once, written whole and atomically, readable by the owner only. Every load and save holds an
/// exclusive `flock` on `claude-bot.json.lock` beside it, shared by every copy of Tsukumo and every thread, and a save
/// first checks that the file's generation is still the one this copy loaded or wrote: if another copy saved since, it
/// refuses (and says so) rather than overwrite. A file this build can't read (damaged, or from a newer build) is never
/// overwritten: it's set aside beside itself, the problem is surfaced, and Claude starts with nothing.
public final class ClaudeBotFile: @unchecked Sendable {
    public let url: URL?
    private let lock = NSLock()
    /// Saving is refused (a file that couldn't be set aside must not be overwritten).
    private var refuseSaves = false
    /// The generation this copy last loaded or wrote.
    private var known = 0

    public init(url: URL?) { self.url = url }

    public struct Loaded: Sendable {
        public var state: ClaudeBotState
        /// Why the saved tasks couldn't be used, in words to show; nil when they could.
        public var problem: String?
    }

    /// Runs `body` holding the lock file's exclusive lock (and this object's lock for its own threads). `body` learns
    /// whether the lock was taken: without it, nothing may be written.
    private func locked<T>(_ body: (_ held: Bool) throws -> T) rethrows -> T {
        try lock.withLock {
            guard let url else { return try body(true) }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let fd = open(url.path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
            var held = false
            if fd >= 0 {
                var result: Int32
                repeat { result = flock(fd, LOCK_EX) } while result == -1 && errno == EINTR
                held = result == 0
            }
            defer { if fd >= 0 { if held { flock(fd, LOCK_UN) }; close(fd) } }
            return try body(held)
        }
    }

    public func load() -> Loaded {
        locked { held in
            guard let url, FileManager.default.fileExists(atPath: url.path) else { known = 0; return Loaded(state: ClaudeBotState(), problem: nil) }
            let why: String
            if let data = try? Data(contentsOf: url) {
                if let state = try? TsukumoJSON.decoder.decode(ClaudeBotState.self, from: data) {
                    if state.version <= ClaudeBotState.currentVersion { known = state.generation; return Loaded(state: state, problem: nil) }
                    why = "they were saved by a newer Tsukumo"
                } else {
                    why = "the file is damaged"
                }
            } else {
                why = "the file can't be read"
            }
            // Without the lock, the file is only read, never moved.
            guard held else {
                refuseSaves = true
                return Loaded(state: ClaudeBotState(), problem: "Claude’s saved tasks couldn’t be opened (\(why)), and Tsukumo couldn’t lock the task list to set them aside, so nothing new is saved.")
            }
            let aside = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".unreadable-" + Self.stamp())
            do {
                try FileManager.default.moveItem(at: url, to: aside)
                known = 0
                return Loaded(state: ClaudeBotState(), problem: "Claude’s saved tasks couldn’t be opened (\(why)), so they were set aside as \(aside.lastPathComponent) and Claude started fresh.")
            } catch {
                refuseSaves = true
                return Loaded(state: ClaudeBotState(), problem: "Claude’s saved tasks couldn’t be opened (\(why)) or set aside, so nothing new is saved until the file is moved.")
            }
        }
    }

    public enum SaveError: Error, LocalizedError {
        case refused, conflict, unlocked, failed(String)
        public var errorDescription: String? {
            switch self {
            case .refused: "Claude’s tasks aren’t being saved: the file from before couldn’t be set aside."
            case .conflict: "Claude’s tasks aren’t being saved here: another copy of Tsukumo changed them. Quit one copy and open Tsukumo again."
            case .unlocked: "Claude’s tasks aren’t being saved: Tsukumo couldn’t lock the task list."
            case .failed(let why): "Claude’s tasks couldn’t be saved: " + why
            }
        }
    }

    public func save(_ state: ClaudeBotState) throws {
        try locked { held in
            guard let url else { return }
            guard !refuseSaves else { throw SaveError.refused }
            guard held else { throw SaveError.unlocked }
            // Another copy saved since this one loaded or wrote: never overwrite its changes.
            if FileManager.default.fileExists(atPath: url.path) {
                let onDisk = (try? Data(contentsOf: url)).flatMap { try? TsukumoJSON.decoder.decode(ClaudeBotState.self, from: $0) }?.generation
                guard onDisk == known else { throw SaveError.conflict }
            }
            var next = state
            next.generation = known + 1
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try TsukumoJSON.encoder.encode(next).write(to: url, options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                known = next.generation
            } catch {
                throw SaveError.failed(error.localizedDescription)
            }
        }
    }

    static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date()) + "-" + String(UUID().uuidString.prefix(4))
    }
}
#endif

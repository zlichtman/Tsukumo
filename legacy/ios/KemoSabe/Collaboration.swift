import Foundation

/// Who is working on a shared project and on what: people, their agents' tasks, the files each
/// task changed or claimed, messages, and ownership decisions. These are the records a shared
/// project zone carries (`SyncType.collab*`); code itself moves through git branches. The same
/// board drives the collaboration page, explorer badges, and editor gutter markers.
enum CollabState: String, Codable, Sendable, CaseIterable {
    case planning, working, needsYou, review, done, failed
    /// Stopped by a person (Pause) or by a restart; its changes are still in play.
    case paused
    var active: Bool { self != .done && self != .failed }
    var title: String {
        switch self { case .planning: "Planning"; case .working: "Working"; case .needsYou: "Needs you"; case .review: "Ready to review"; case .done: "Done"; case .failed: "Failed"; case .paused: "Paused" }
    }
}

struct CollabFileTouch: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case changed, claimed }
    var path: String
    var kind: Kind
    /// A function or type within the file, when the agent or a parser named one.
    var symbol: String?
    var added = 0
    var removed = 0
}

struct CollabTask: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var project: String
    var owner: String
    var ownerName: String
    /// The agent doing the work ("Codex", "Claude Code", …), or nil for a person working by hand.
    var agent: String?
    var title: String
    var state: CollabState
    var branch: String?
    var files: [CollabFileTouch] = []
    var updated: Date
    /// The orchestrated plan this task belongs to, its subtask ID there, and the subtasks it waits for.
    var plan: String?
    var subtask: String?
    var dependsOn: [String]?
}

struct CollabPresence: Codable, Identifiable, Equatable, Sendable {
    var id: String { person + "@" + device }
    var person: String
    var name: String
    var project: String
    var device: String
    /// The file the person has open, for "viewing" markers.
    var focus: String?
    var lastSeen: Date
    /// Present means seen in the last two minutes.
    func isPresent(at now: Date) -> Bool { now.timeIntervalSince(lastSeen) < 120 }
}

/// What a timeline entry records. Older records without a kind are messages.
enum CollabMessageKind: String, Codable, Sendable {
    /// A note to a task's agent or a person.
    case message
    /// One task's result passed on as context for a task that depends on it.
    case handoff
    /// Two tasks started touching the same file or function.
    case overlap
    /// A plan was proposed, edited, or started; subtasks started or finished.
    case plan
    /// Worktrees merged, conflicts found, tests run, or the result accepted.
    case integration
}

struct CollabMessage: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var project: String
    var from: String
    var fromName: String
    /// A task ID (delivered to its agent as a turn) or a person ID.
    var to: String
    var text: String
    var date: Date
    var kind: CollabMessageKind?
    /// Other participants the entry concerns (the second task of an overlap, a handoff's source).
    var about: [String]?
}

/// "This task owns this file (or function)": a person's decision that resolves an overlap.
struct CollabOwnership: Codable, Identifiable, Equatable, Sendable {
    var id: String { path + "#" + (symbol ?? "") }
    var project: String
    var path: String
    var symbol: String?
    var task: String
    var decidedBy: String
    var date: Date
}

struct CollabOverlap: Identifiable, Equatable, Sendable {
    var path: String
    var symbol: String?
    var tasks: [CollabTask]
    var owner: CollabOwnership?
    var id: String { path + "#" + (symbol ?? "") }
    var resolved: Bool { owner != nil }
    /// The task that should own it: the one that has changed the most there, then the one that claimed it first.
    var suggestedOwner: CollabTask? {
        tasks.max { a, b in
            let (sa, sb) = (weight(a), weight(b))
            return sa != sb ? sa < sb : a.updated > b.updated
        }
    }
    private func weight(_ task: CollabTask) -> Int {
        task.files.filter { $0.path == path && (symbol == nil || $0.symbol == symbol) }.reduce(0) { $0 + $1.added + $1.removed + ($1.kind == .changed ? 1 : 0) }
    }
}

struct CollabBoard: Equatable, Sendable {
    var tasks: [CollabTask] = []
    var presence: [CollabPresence] = []
    var messages: [CollabMessage] = []
    var ownership: [CollabOwnership] = []

    var active: [CollabTask] { tasks.filter { $0.state.active }.sorted { $0.updated > $1.updated } }
    func present(at now: Date) -> [CollabPresence] { presence.filter { $0.isPresent(at: now) } }

    /// Files (or functions, when both tasks name one) that two or more active tasks changed or claimed.
    /// A file-level touch overlaps every symbol in that file.
    var overlaps: [CollabOverlap] {
        var byPath: [String: [CollabTask]] = [:]
        for task in active {
            for path in Set(task.files.map(\.path)) { byPath[path, default: []].append(task) }
        }
        return byPath.filter { $0.value.count > 1 }.flatMap { path, tasks -> [CollabOverlap] in
            let symbolSets = tasks.map { task in Set(task.files.filter { $0.path == path }.compactMap(\.symbol)) }
            let everySymbolNamed = zip(tasks, symbolSets).allSatisfy { task, symbols in
                !symbols.isEmpty && !task.files.contains { $0.path == path && $0.symbol == nil }
            }
            if everySymbolNamed {
                // Only the functions two tasks share collide.
                let shared = symbolSets.reduce(into: [String: Int]()) { counts, set in set.forEach { counts[$0, default: 0] += 1 } }.filter { $0.value > 1 }.keys
                return shared.sorted().map { symbol in
                    let involved = tasks.filter { $0.files.contains { $0.path == path && $0.symbol == symbol } }
                    return CollabOverlap(path: path, symbol: symbol, tasks: involved, owner: owner(path, symbol))
                }
            }
            return [CollabOverlap(path: path, symbol: nil, tasks: tasks, owner: owner(path, nil))]
        }.sorted { ($0.resolved ? 1 : 0, $0.path) < ($1.resolved ? 1 : 0, $1.path) }
    }
    func owner(_ path: String, _ symbol: String?) -> CollabOwnership? {
        ownership.last { $0.path == path && ($0.symbol == symbol || $0.symbol == nil) }
    }
    /// Who is touching a file: for badges in the explorer.
    func touching(_ path: String) -> [CollabTask] { active.filter { $0.files.contains { $0.path == path } } }
    var needsAttention: Int { overlaps.filter { !$0.resolved }.count + active.filter { $0.state == .needsYou }.count }
    /// How much a task is doing, for sizing it on the collaboration page: lines changed, plus
    /// a little for each file it has touched or claimed.
    func activity(of task: CollabTask) -> Int {
        task.files.reduce(0) { $0 + $1.added + $1.removed + ($1.kind == .changed ? 4 : 2) }
    }
    /// Overlaps between two particular tasks, for drawing them as merged regions.
    func overlaps(between a: String, and b: String) -> [CollabOverlap] {
        overlaps.filter { overlap in overlap.tasks.contains { $0.id == a } && overlap.tasks.contains { $0.id == b } }
    }
    /// Another board's records added to this one (other people's tasks, presence, messages, and
    /// decisions), keeping this board's own copy where both have one.
    func merged(with other: CollabBoard) -> CollabBoard {
        var result = self
        let taskIDs = Set(tasks.map(\.id)), presenceIDs = Set(presence.map(\.id)), messageIDs = Set(messages.map(\.id)), ownerIDs = Set(ownership.map(\.id))
        result.tasks += other.tasks.filter { !taskIDs.contains($0.id) }
        result.presence += other.presence.filter { !presenceIDs.contains($0.id) }
        result.messages = (messages + other.messages.filter { !messageIDs.contains($0.id) }).sorted { $0.date < $1.date }
        // A decision here wins over one elsewhere on the same file; the latest one elsewhere counts otherwise.
        result.ownership = (other.ownership.filter { !ownerIDs.contains($0.id) } + ownership)
        return result
    }
}

// MARK: - What a diff touches

/// The changed lines of one file in a unified diff (`git diff -U0`), placed by line number in
/// the file's new version: added lines where they are, removed lines where they used to be.
struct CollabDiffFile: Equatable, Sendable {
    var path: String
    var deleted = false
    var binary = false
    var added: [Int] = []
    var removedAt: [Int] = []
}

/// Turns diffs into touches for the board: one per file, or one per function or type when the
/// changed lines sit inside declarations. Only relative paths ever come out.
enum CollabDiff {
    static func parse(_ diff: String) -> [CollabDiffFile] {
        var files: [CollabDiffFile] = []
        var current: CollabDiffFile?
        var oldPath: String?
        var newLine = 0, oldLeft = 0, newLeft = 0
        func finish() { if let file = current, !file.path.isEmpty { files.append(file) }; current = nil; oldPath = nil }
        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if oldLeft > 0 || newLeft > 0 {
                // Inside a hunk: every line belongs to it until both counts run out.
                if line.hasPrefix("+") { current?.added.append(newLine); newLine += 1; newLeft -= 1; continue }
                if line.hasPrefix("-") { current?.removedAt.append(newLine); oldLeft -= 1; continue }
                if line.hasPrefix(" ") { newLine += 1; oldLeft -= 1; newLeft -= 1; continue }
                if line.hasPrefix("\\") { continue }
                oldLeft = 0; newLeft = 0
            }
            if line.hasPrefix("diff --git ") {
                finish(); current = CollabDiffFile(path: "")
                // A path for binary and mode-only changes, which have no ---/+++ lines.
                if let b = line.range(of: " b/", options: .backwards) { current?.path = String(line[b.upperBound...]) }
            } else if line.hasPrefix("--- ") {
                oldPath = strip(String(line.dropFirst(4)), prefix: "a/")
            } else if line.hasPrefix("+++ ") {
                let path = String(line.dropFirst(4))
                if path == "/dev/null" { current?.deleted = true; if let oldPath { current?.path = oldPath } }
                else if let stripped = strip(path, prefix: "b/") { current?.path = stripped }
            } else if line.hasPrefix("deleted file mode") {
                current?.deleted = true
            } else if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                current?.binary = true
            } else if line.hasPrefix("@@ ") {
                let (oldCount, newStart, newCount) = hunkHeader(line)
                // With no context, a pure removal names the line before the gap; point at the one after it.
                newLine = newCount == 0 ? newStart + 1 : max(newStart, 1)
                oldLeft = oldCount; newLeft = newCount
            }
        }
        finish()
        return files.filter { !$0.path.isEmpty }
    }
    /// `@@ -a,b +c,d @@ context` → (b, c, d); a missing count is 1.
    private static func hunkHeader(_ line: String) -> (Int, Int, Int) {
        let parts = line.split(separator: " ")
        func pair(_ text: Substring) -> (Int, Int) {
            let numbers = text.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            return (Int(numbers.first ?? "") ?? 0, numbers.count > 1 ? Int(numbers[1]) ?? 0 : 1)
        }
        guard parts.count >= 3 else { return (0, 0, 0) }
        let (_, b) = pair(parts[1]), (c, d) = pair(parts[2])
        return (b, c, d)
    }
    /// Removes Git's a/ or b/ prefix and undoes C-style quoting ("path with \t tab").
    static func strip(_ path: String, prefix: String) -> String? {
        var path = path
        if let tab = path.firstIndex(of: "\t"), !path.hasPrefix("\"") { path = String(path[..<tab]) }
        if path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 { path = unquote(String(path.dropFirst().dropLast())) }
        guard path != "/dev/null" else { return nil }
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
    private static func unquote(_ text: String) -> String {
        let chars = Array(text.utf8), digits = UInt8(ascii: "0")...UInt8(ascii: "7")
        var bytes: [UInt8] = [], index = 0
        while index < chars.count {
            let c = chars[index]
            guard c == UInt8(ascii: "\\"), index + 1 < chars.count else { bytes.append(c); index += 1; continue }
            let next = chars[index + 1]
            if next == UInt8(ascii: "n") { bytes.append(10); index += 2 }
            else if next == UInt8(ascii: "t") { bytes.append(9); index += 2 }
            else if digits.contains(next) {
                var value = 0, count = 0
                while count < 3, index + 1 + count < chars.count, digits.contains(chars[index + 1 + count]) {
                    value = value * 8 + Int(chars[index + 1 + count] - digits.lowerBound); count += 1
                }
                bytes.append(UInt8(truncatingIfNeeded: value)); index += 1 + count
            } else { bytes.append(next); index += 2 }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Touches for a diff. `contents` returns a file's new text (nil when it's gone or unreadable),
    /// which places each changed line inside its function or type.
    static func touches(diff: String, contents: (String) -> String?) -> [CollabFileTouch] {
        touches(parse(diff), contents: contents)
    }
    static func touches(_ files: [CollabDiffFile], contents: (String) -> String?) -> [CollabFileTouch] {
        var result: [CollabFileTouch] = []
        for file in files where CollabPaths.valid(file.path) {
            let total = CollabFileTouch(path: file.path, kind: .changed, symbol: nil, added: file.added.count, removed: file.removedAt.count)
            guard !file.binary, !file.deleted, let text = contents(file.path) else { result.append(total); continue }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let language = (file.path as NSString).pathExtension.lowercased()
            var counts: [String: (added: Int, removed: Int)] = [:]
            var outside = (added: 0, removed: 0), placed = false
            func place(_ number: Int, added: Bool) {
                let index = min(max(number, 1), max(lines.count, 1))
                let line = index <= lines.count ? lines[index - 1] : ""
                // Blank lines and imports don't say where a change is.
                if added, CollabSymbols.neutral(line) { return }
                placed = true
                if let symbol = lines.isEmpty ? nil : CollabSymbols.enclosing(line: index, in: lines, language: language) {
                    var value = counts[symbol] ?? (0, 0)
                    if added { value.added += 1 } else { value.removed += 1 }
                    counts[symbol] = value
                } else if added { outside.added += 1 } else { outside.removed += 1 }
            }
            file.added.forEach { place($0, added: true) }
            file.removedAt.forEach { place($0, added: false) }
            // A change outside every declaration touches the whole file.
            if !placed || outside.added + outside.removed > 0 {
                result.append(placed ? .init(path: file.path, kind: .changed, added: outside.added, removed: outside.removed) : total)
            }
            for (symbol, value) in counts.sorted(by: { $0.key < $1.key }) {
                result.append(.init(path: file.path, kind: .changed, symbol: symbol, added: value.added, removed: value.removed))
            }
        }
        return result
    }
}

/// Finds the function or type a line sits in, by declarations and indentation. Nested ones are
/// joined with dots ("Store.save"), so two types' same-named methods stay apart.
enum CollabSymbols {
    private static let modifiers = #"(?:(?:public|private|fileprivate|internal|open|package|static|final|override|class|async|export|default|abstract|protected|mutating|nonmutating|nonisolated|convenience|required|indirect|unsafe|extern|virtual|inline|lazy|pub(?:\([^)]*\))?)\s+)*"#
    private static let attributes = #"(?:@[\w.]+(?:\([^)]*\))?\s+)*"#
    private static let declaration = try! NSRegularExpression(pattern: #"^\s*"# + attributes + modifiers + #"(func|def|function\*?|class|struct|enum|protocol|extension|actor|interface|impl|trait|fn|init|deinit|subscript|module|object|namespace|type)\b[\s*]*(?:<[^>]*>\s*)?(?:\([^)]*\)\s*)?([A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*)?"#)
    /// `const name = (…) =>`, `let name = async function`.
    private static let arrow = try! NSRegularExpression(pattern: #"^\s*(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*(?::[^=]+)?=\s*(?:async\s+)?(?:function\b|\([^)]*\)\s*(?::[^=]+)?=>|[A-Za-z_$][\w$]*\s*=>)"#)
    /// Swift computed properties: `var body: some View {`.
    private static let computed = try! NSRegularExpression(pattern: #"^\s*"# + attributes + modifiers + #"var\s+([A-Za-z_][\w]*)\s*:[^=]*\{\s*$"#)
    /// Methods in C-family class bodies: `  save(item) {`.
    private static let method = try! NSRegularExpression(pattern: #"^\s*(?:(?:public|private|protected|static|async|get|set|override|virtual|final|synchronized)\s+)*(?:[\w<>\[\],.?]+\s+)?([A-Za-z_$][\w$]*)\s*\([^;{}]*\)\s*(?:[\w\s,.<>:]*)\{\s*$"#)
    private static let methodLanguages: Set<String> = ["js", "jsx", "ts", "tsx", "mjs", "cjs", "java", "kt", "cs", "c", "cc", "cpp", "h", "hpp", "m", "mm", "php", "dart", "scala"]
    private static let notMethods: Set<String> = ["if", "for", "while", "switch", "catch", "with", "return", "function", "else", "do", "try", "synchronized", "foreach", "using", "lock"]

    /// The declared name, if this line declares a function or type.
    static func declared(_ line: Substring, language: String = "") -> String? {
        let text = String(line), range = NSRange(text.startIndex..., in: text)
        if let match = declaration.firstMatch(in: text, range: range) {
            let keyword = Range(match.range(at: 1), in: text).map { String(text[$0]) } ?? ""
            let typeAllowed = keyword != "type" || ["go", "ts", "tsx"].contains(language)
            if typeAllowed, let name = Range(match.range(at: 2), in: text).map({ String(text[$0]) }), !name.isEmpty { return name }
            if ["init", "deinit", "subscript"].contains(keyword) { return keyword }
        }
        for regex in [arrow, computed] {
            if let match = regex.firstMatch(in: text, range: range), let name = Range(match.range(at: 1), in: text) { return String(text[name]) }
        }
        if methodLanguages.contains(language), let match = method.firstMatch(in: text, range: range), let name = Range(match.range(at: 1), in: text) {
            let word = String(text[name])
            if !notMethods.contains(word) { return word }
        }
        return nil
    }
    /// Blank lines and imports, which don't place a change anywhere.
    static func neutral(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasPrefix("import ") || trimmed.hasPrefix("#include") || trimmed.hasPrefix("#import")
            || trimmed.hasPrefix("use ") || (trimmed.hasPrefix("from ") && trimmed.contains(" import "))
    }
    static func indent(_ line: Substring) -> Int {
        var width = 0
        for character in line { if character == " " { width += 1 } else if character == "\t" { width += 4 } else { break } }
        return width
    }
    /// The dotted name of the declarations around `line` (1-based), innermost last.
    static func enclosing(line: Int, in lines: [Substring], language: String = "") -> String? {
        guard line >= 1, line <= lines.count else { return nil }
        var names: [String] = []
        let target = lines[line - 1]
        var threshold = indent(target)
        if let name = declared(target, language: language) { names = [name] }
        var index = line - 2
        while index >= 0, threshold > 0 {
            let candidate = lines[index]; index -= 1
            guard !candidate.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let width = indent(candidate)
            guard width < threshold, let name = declared(candidate, language: language) else { continue }
            names.insert(name, at: 0); threshold = width
        }
        return names.isEmpty ? nil : names.joined(separator: ".")
    }
}

enum CollabPaths {
    /// A path inside the project: relative, no `..`, no empty parts. Absolute paths never go on the board.
    static func valid(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && path.count <= 500 && !path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0") && !parts.contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }
    /// A path an agent reported, made relative to the task's folder; nil if it's outside it.
    static func relative(_ path: String, to root: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.hasPrefix("/") { return valid(trimmed) ? trimmed : nil }
        let base = root.hasSuffix("/") ? root : root + "/"
        guard trimmed.hasPrefix(base) else { return nil }
        let relative = String(trimmed.dropFirst(base.count))
        return valid(relative) ? relative : nil
    }
}

// MARK: - Sharing a project's board

/// A shared project is named by its Git remote, so everyone's Tsukumo lands in the same zone
/// without exchanging IDs. The zone's name is a hash, so the remote itself isn't in it.
enum CollabProject {
    static func normalizedRemote(_ remote: String) -> String? {
        var text = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
        else if let colon = text.firstIndex(of: ":"), !text[..<colon].contains("/") {
            // scp style: git@host:owner/repo
            text = String(text[..<colon]) + "/" + String(text[text.index(after: colon)...])
        }
        if let at = text.firstIndex(of: "@"), let slash = text.firstIndex(of: "/"), at < slash { text = String(text[text.index(after: at)...]) }
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix(".git") { text.removeLast(4) }
        guard let slash = text.firstIndex(of: "/"), slash != text.startIndex else { return nil }
        var host = text[..<slash].lowercased()
        if let port = host.firstIndex(of: ":") { host = String(host[..<port]) }
        return host + text[slash...]
    }
    static func id(remote: String) -> String? {
        guard let normalized = normalizedRemote(remote) else { return nil }
        // FNV-1a with two seeds: stable across devices and launches (it's a name, not a secret).
        func fnv(_ seed: UInt64) -> UInt64 { normalized.utf8.reduce(seed) { ($0 ^ UInt64($1)) &* 0x100000001b3 } }
        return String(format: "%016llx%016llx", fnv(0xcbf29ce484222325), fnv(0x84222325cbf29ce4))
    }
}

/// Publishes this person's part of a project's board as records in the project's shared zone,
/// and reads everyone's back. Only collaboration records are written (the engine refuses anything
/// else in a shared zone), paths stay relative, and nothing is queued unless the value changed.
@MainActor struct CollabShare {
    let engine: SyncEngine
    let project: String
    /// This person's account ID.
    let me: String
    var zone: SyncZone { .shared(project: project) }

    static func recordID(task: CollabTask) -> String { "task-" + task.id }
    static func recordID(presence: CollabPresence) -> String { "presence-" + presence.id }
    static func recordID(message: CollabMessage) -> String { "message-" + message.id }
    static func recordID(owner: CollabOwnership) -> String { "owner-" + owner.id }

    /// Writes what this person owns: their tasks, presence, messages, and decisions. Their tasks
    /// that are gone from `board` are deleted; other people's records are never written.
    func publish(_ board: CollabBoard, at date: Date = Date()) throws {
        let mine = board.tasks.filter { $0.owner == me && $0.project == project }
        for var task in mine {
            task.files = task.files.filter { CollabPaths.valid($0.path) }
            try put(task, id: Self.recordID(task: task), type: SyncType.collabTask, at: date)
        }
        let kept = Set(mine.map(Self.recordID(task:)))
        let gone = engine.state.records.values.filter { record in
            record.zone == zone && record.type == SyncType.collabTask && !record.deleted && !kept.contains(record.id)
                && (try? JSONDecoder().decode(CollabTask.self, from: record.payload))?.owner == me
        }
        for record in gone { try engine.delete(id: record.id, type: SyncType.collabTask, zone: zone, at: date) }
        for presence in board.presence where presence.person == me && presence.project == project {
            try put(presence, id: Self.recordID(presence: presence), type: SyncType.collabPresence, at: date)
        }
        let myTasks = Set(mine.map(\.id))
        for message in board.messages where message.project == project && (message.from == me || myTasks.contains(message.from)) {
            try put(message, id: Self.recordID(message: message), type: SyncType.collabMessage, at: date)
        }
        for owner in board.ownership where owner.decidedBy == me && owner.project == project {
            try put(owner, id: Self.recordID(owner: owner), type: SyncType.collabOwner, at: date)
        }
    }
    private func put<Value: Codable & Equatable>(_ value: Value, id: String, type: String, at date: Date) throws {
        if let existing = engine.state.records[zone.name + "/" + id], !existing.deleted,
           (try? JSONDecoder().decode(Value.self, from: existing.payload)) == value { return }
        try engine.put(value, id: id, type: type, zone: zone, at: date)
    }
    /// Everyone's records in the zone, as a board.
    func board() -> CollabBoard {
        CollabBoard(tasks: engine.values(SyncType.collabTask, in: zone, as: CollabTask.self).filter { $0.project == project },
                    presence: engine.values(SyncType.collabPresence, in: zone, as: CollabPresence.self).filter { $0.project == project },
                    messages: engine.values(SyncType.collabMessage, in: zone, as: CollabMessage.self).filter { $0.project == project }.sorted { $0.date < $1.date },
                    ownership: engine.values(SyncType.collabOwner, in: zone, as: CollabOwnership.self).filter { $0.project == project })
    }
    /// Other people's part of the board, to show beside this person's own live one.
    func others() -> CollabBoard {
        let all = board()
        let myTasks = Set(all.tasks.filter { $0.owner == me }.map(\.id))
        return CollabBoard(tasks: all.tasks.filter { $0.owner != me }, presence: all.presence.filter { $0.person != me },
                           messages: all.messages.filter { $0.from != me && !myTasks.contains($0.from) },
                           ownership: all.ownership.filter { $0.decidedBy != me })
    }
}

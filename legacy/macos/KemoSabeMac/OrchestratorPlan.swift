import Foundation

/// One piece of an orchestrated goal: what it's for, the files and areas it expects to touch,
/// the subtasks whose results it needs, and the agent suggested to do it.
struct OrchestratorSubtask: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var brief: String
    var files: [String] = []
    var areas: [String] = []
    var dependsOn: [String] = []
    var agent: CodingProvider
}

/// A lead agent's proposal for a goal. The person reviews and edits it; nothing runs until they
/// start it. It comes from the lead's structured output (`OrchestratorPlanner.schema`).
struct OrchestratorPlan: Codable, Equatable, Sendable {
    static let version = 1
    static let maximumSubtasks = 8
    var summary: String
    var subtasks: [OrchestratorSubtask]
    func subtask(_ id: String) -> OrchestratorSubtask? { subtasks.first { $0.id == id } }
}

enum OrchestratorPlanError: Error, Equatable, LocalizedError {
    case noPlan
    case notJSON
    case version
    case unknownKey(String)
    case missing(String)
    case wrongType(String)
    case count(Int)
    case badID(String)
    case duplicateID(String)
    case badText(String)
    case badPath(String)
    case unknownAgent(String)
    case unknownDependency(String, String)
    case cycle([String])
    var errorDescription: String? {
        switch self {
        case .noPlan: "The lead agent's reply has no plan block."
        case .notJSON: "The plan block isn't valid JSON."
        case .version: "The plan isn't version \(OrchestratorPlan.version)."
        case .unknownKey(let key): "The plan has a field Tsukumo doesn't know: \(key)."
        case .missing(let key): "The plan is missing \(key)."
        case .wrongType(let key): "The plan's \(key) has the wrong type."
        case .count(let count): "The plan has \(count) subtasks; it needs 1 to \(OrchestratorPlan.maximumSubtasks)."
        case .badID(let id): "“\(id)” isn't a usable subtask ID (lowercase letters, digits, and hyphens)."
        case .duplicateID(let id): "Two subtasks are both “\(id)”."
        case .badText(let field): "A subtask's \(field) is empty or too long."
        case .badPath(let path): "“\(path)” isn't a path inside the project."
        case .unknownAgent(let agent): "“\(agent)” isn't an agent Tsukumo can run."
        case .unknownDependency(let id, let dependency): "“\(id)” depends on “\(dependency)”, which isn't in the plan."
        case .cycle(let ids): "These subtasks wait for each other: \(ids.joined(separator: " → "))."
        }
    }
}

/// Asks a lead agent for a plan, reads its answer strictly, and falls back to one task.
enum OrchestratorPlanner {
    /// What the lead is asked to reply with. Tsukumo only reads the last fenced `json` block.
    static let schema = """
    {
      "version": 1,
      "summary": "One or two sentences on the approach.",
      "subtasks": [
        {
          "id": "short-id",
          "title": "Imperative title, under 80 characters",
          "brief": "What to do and how to know it's done, for an agent who hasn't seen this conversation.",
          "files": ["relative/path/it/expects/to/change.swift"],
          "areas": ["a short name for each area it touches"],
          "depends_on": ["id of a subtask whose result it needs"],
          "agent": "one of the available agents, by the name listed"
        }
      ]
    }
    """
    static func prompt(goal: String, agents: [CodingProvider]) -> String {
        """
        You are the lead agent planning one goal for several coding agents who will work at the same time, each in its own Git worktree of this repository. Don't change any files: read what you need, then plan.

        Goal:
        \(goal.trimmingCharacters(in: .whitespacesAndNewlines))

        Split the goal into 1 to \(OrchestratorPlan.maximumSubtasks) subtasks that can run in parallel. Give each subtask the files it expects to change (paths relative to the repository root) and keep those sets apart wherever you can, so agents don't collide. Use depends_on only when a subtask needs another's finished result; it will start from that result. Available agents: \(agents.map(\.planName).joined(separator: ", ")). Suggest the one best suited to each subtask. If the goal is small, one subtask is right.

        Reply with a short explanation, then exactly one fenced ```json block in this shape, with no other fields:
        \(schema)
        """
    }

    /// The last fenced JSON block that looks like a plan (or a bare object starting with the version).
    static func extractJSON(from text: String) -> String? {
        var blocks: [String] = []
        var remainder = text[...]
        while let open = remainder.range(of: "```") {
            let afterFence = remainder[open.upperBound...]
            guard let newline = afterFence.firstIndex(of: "\n") else { break }
            let language = afterFence[..<newline].trimmingCharacters(in: .whitespaces).lowercased()
            let body = afterFence[afterFence.index(after: newline)...]
            guard let close = body.range(of: "```") else { break }
            if language.isEmpty || language == "json" { blocks.append(String(body[..<close.lowerBound])) }
            remainder = body[close.upperBound...]
        }
        if let block = blocks.last(where: { $0.contains("\"subtasks\"") }) { return block.trimmingCharacters(in: .whitespacesAndNewlines) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}"), trimmed.contains("\"subtasks\"") { return trimmed }
        return nil
    }

    /// Reads and validates a plan. Anything unexpected is an error, never guessed at.
    static func parse(_ text: String) throws -> OrchestratorPlan {
        guard let json = extractJSON(from: text) else { throw OrchestratorPlanError.noPlan }
        guard let data = json.data(using: .utf8), data.count <= 200_000,
              let object = try? JSONSerialization.jsonObject(with: data), let top = object as? [String: Any] else { throw OrchestratorPlanError.notJSON }
        try only(top, ["version", "summary", "subtasks"])
        guard let version = top["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version.intValue == OrchestratorPlan.version, version.doubleValue == 1 else { throw OrchestratorPlanError.version }
        let summary = try optionalString(top, "summary") ?? ""
        guard summary.count <= 2000 else { throw OrchestratorPlanError.badText("summary") }
        guard let raw = top["subtasks"] else { throw OrchestratorPlanError.missing("subtasks") }
        guard let list = raw as? [Any] else { throw OrchestratorPlanError.wrongType("subtasks") }
        var subtasks: [OrchestratorSubtask] = []
        for item in list {
            guard let entry = item as? [String: Any] else { throw OrchestratorPlanError.wrongType("subtask") }
            try only(entry, ["id", "title", "brief", "files", "areas", "depends_on", "agent"])
            guard let id = try optionalString(entry, "id") else { throw OrchestratorPlanError.missing("id") }
            guard let title = try optionalString(entry, "title") else { throw OrchestratorPlanError.missing("title") }
            guard let brief = try optionalString(entry, "brief") else { throw OrchestratorPlanError.missing("brief") }
            guard let agentName = try optionalString(entry, "agent") else { throw OrchestratorPlanError.missing("agent") }
            guard let agent = CodingProvider(planName: agentName) else { throw OrchestratorPlanError.unknownAgent(agentName) }
            subtasks.append(.init(id: id, title: title.trimmingCharacters(in: .whitespacesAndNewlines), brief: brief.trimmingCharacters(in: .whitespacesAndNewlines),
                                  files: try strings(entry, "files"), areas: try strings(entry, "areas"), dependsOn: try strings(entry, "depends_on"), agent: agent))
        }
        var plan = OrchestratorPlan(summary: summary.trimmingCharacters(in: .whitespacesAndNewlines), subtasks: subtasks)
        plan.subtasks = plan.subtasks.map { var subtask = $0; subtask.files = subtask.files.map(normalizedPath); return subtask }
        try validate(plan)
        return plan
    }
    private static func only(_ object: [String: Any], _ keys: Set<String>) throws {
        if let unknown = object.keys.sorted().first(where: { !keys.contains($0) }) { throw OrchestratorPlanError.unknownKey(unknown) }
    }
    private static func optionalString(_ object: [String: Any], _ key: String) throws -> String? {
        guard let value = object[key], !(value is NSNull) else { return nil }
        guard let text = value as? String else { throw OrchestratorPlanError.wrongType(key) }
        return text
    }
    private static func strings(_ object: [String: Any], _ key: String) throws -> [String] {
        guard let value = object[key], !(value is NSNull) else { return [] }
        guard let list = value as? [Any], list.allSatisfy({ $0 is String }) else { throw OrchestratorPlanError.wrongType(key) }
        return list.compactMap { $0 as? String }
    }
    /// A folder may be named with a trailing slash; it's kept as the folder's path.
    static func normalizedPath(_ path: String) -> String {
        var path = path.trimmingCharacters(in: .whitespaces)
        if path.hasPrefix("./") { path.removeFirst(2) }
        if path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// The rules a plan must meet, whether the lead wrote it or the person edited it.
    static func validate(_ plan: OrchestratorPlan) throws {
        guard (1...OrchestratorPlan.maximumSubtasks).contains(plan.subtasks.count) else { throw OrchestratorPlanError.count(plan.subtasks.count) }
        var seen: Set<String> = []
        for subtask in plan.subtasks {
            guard validID(subtask.id) else { throw OrchestratorPlanError.badID(subtask.id) }
            guard seen.insert(subtask.id).inserted else { throw OrchestratorPlanError.duplicateID(subtask.id) }
            guard (1...120).contains(subtask.title.count) else { throw OrchestratorPlanError.badText("title") }
            guard (1...4000).contains(subtask.brief.count) else { throw OrchestratorPlanError.badText("brief") }
            guard subtask.files.count <= 50, subtask.areas.count <= 12 else { throw OrchestratorPlanError.badText("files or areas") }
            if let path = subtask.files.first(where: { !CollabPaths.valid($0) }) { throw OrchestratorPlanError.badPath(path) }
            guard subtask.areas.allSatisfy({ (1...60).contains($0.count) }) else { throw OrchestratorPlanError.badText("area") }
        }
        for subtask in plan.subtasks {
            for dependency in subtask.dependsOn where !seen.contains(dependency) || dependency == subtask.id {
                if dependency == subtask.id { throw OrchestratorPlanError.cycle([subtask.id, subtask.id]) }
                throw OrchestratorPlanError.unknownDependency(subtask.id, dependency)
            }
        }
        if let cycle = OrchestratorSchedule.cycle(plan.subtasks) { throw OrchestratorPlanError.cycle(cycle) }
    }
    static func validID(_ id: String) -> Bool {
        guard (1...32).contains(id.count), let first = id.unicodeScalars.first, CharacterSet.lowercaseLetters.union(.decimalDigits).contains(first) else { return false }
        return id.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    /// The plan the lead proposed, or one task for the whole goal when its answer can't be used.
    /// The second value says why it fell back.
    static func plan(from reply: String, goal: String, lead: CodingProvider) -> (OrchestratorPlan, String?) {
        do { return (try parse(reply), nil) }
        catch { return (single(goal: goal, agent: lead), (error as? LocalizedError)?.errorDescription ?? error.localizedDescription) }
    }
    static func single(goal: String, agent: CodingProvider) -> OrchestratorPlan {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.split(separator: "\n").first.map { String($0.prefix(80)) } ?? "Goal"
        return .init(summary: "One task for the whole goal.", subtasks: [.init(id: "goal", title: title.isEmpty ? "Goal" : title, brief: String(trimmed.prefix(4000)), agent: agent)])
    }
}

extension CodingProvider {
    /// How the plan names each agent: short names for the built-ins, and an added agent's name
    /// in lowercase with hyphens. The lead and every subtask can be any adapter.
    var planName: String {
        switch self {
        case .codex: return "codex"
        case .claude: return "claude"
        case .muse: return "muse"
        case .cursor: return "cursor"
        default: return Self.slug(title)
        }
    }
    static func slug(_ name: String) -> String {
        name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "-")
    }
    init?(planName: String) {
        let name = planName.trimmingCharacters(in: .whitespaces).lowercased()
        switch name {
        case "codex", "openai codex", "codex cli": self = .codex
        case "claude", "claude code", "claude-code", "claude_code": self = .claude
        case "muse", "muse code", "muse-code", "muse_code", "meta muse code": self = .muse
        case "cursor", "cursor agent", "cursor-agent", "cursor_agent": self = .cursor
        default:
            guard let match = CodingAgentNames.all().first(where: { $0.0.customID != nil && ($0.0.planName == Self.slug(name) || $0.1.lowercased() == name) }) else { return nil }
            self = match.0
        }
    }
}

/// Which subtasks may start: those whose dependencies all finished, up to a limit at once.
enum OrchestratorSchedule {
    enum State: String, Codable, Equatable, Sendable {
        /// Not started yet.
        case waiting
        /// Its agent is working (or waiting for the person).
        case running
        /// Its agent finished; dependents may start from its result.
        case finished
        /// It failed or was stopped; dependents wait until the person resolves it.
        case failed
    }
    /// Subtasks in an order where every subtask comes after the ones it depends on; ties keep the plan's order.
    static func order(_ subtasks: [OrchestratorSubtask]) -> [String] {
        var placed: [String] = [], done: Set<String> = []
        var remaining = subtasks
        while !remaining.isEmpty {
            guard let next = remaining.firstIndex(where: { $0.dependsOn.allSatisfy(done.contains) }) else {
                // A cycle (a validated plan has none): keep the rest in plan order.
                return placed + remaining.map(\.id)
            }
            let subtask = remaining.remove(at: next)
            placed.append(subtask.id); done.insert(subtask.id)
        }
        return placed
    }
    static func ready(_ subtasks: [OrchestratorSubtask], states: [String: State], limit: Int = 4) -> [String] {
        let running = states.values.filter { $0 == .running }.count
        let candidates = order(subtasks).filter { id in
            guard (states[id] ?? .waiting) == .waiting, let subtask = subtasks.first(where: { $0.id == id }) else { return false }
            return subtask.dependsOn.allSatisfy { states[$0] == .finished }
        }
        return Array(candidates.prefix(max(0, limit - running)))
    }
    /// Waiting subtasks that can't start because something they need (directly or not) failed.
    static func blocked(_ subtasks: [OrchestratorSubtask], states: [String: State]) -> [String] {
        var failed = Set(states.filter { $0.value == .failed }.map(\.key))
        var changed = true
        while changed {
            changed = false
            for subtask in subtasks where (states[subtask.id] ?? .waiting) == .waiting && !failed.contains(subtask.id) && subtask.dependsOn.contains(where: failed.contains) {
                failed.insert(subtask.id); changed = true
            }
        }
        return order(subtasks).filter { failed.contains($0) && (states[$0] ?? .waiting) == .waiting }
    }
    /// A dependency loop, if there is one.
    static func cycle(_ subtasks: [OrchestratorSubtask]) -> [String]? {
        let byID = Dictionary(subtasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var state: [String: Int] = [:], stack: [String] = []
        func visit(_ id: String) -> [String]? {
            if state[id] == 1 { return Array(stack[(stack.firstIndex(of: id) ?? 0)...]) + [id] }
            if state[id] == 2 { return nil }
            state[id] = 1; stack.append(id)
            for dependency in byID[id]?.dependsOn ?? [] where byID[dependency] != nil {
                if let found = visit(dependency) { return found }
            }
            stack.removeLast(); state[id] = 2
            return nil
        }
        for subtask in subtasks { if let found = visit(subtask.id) { return found } }
        return nil
    }
}

/// A finished subtask's result passed on to a subtask that depends on it: what changed (from its
/// diff) and what its agent said at the end.
struct OrchestratorHandoff: Codable, Equatable, Sendable {
    struct File: Codable, Equatable, Sendable { var path: String; var added: Int; var removed: Int }
    var subtask: String
    var title: String
    var agent: String
    var commit: String
    var files: [File]
    var notes: String
    /// `git diff --numstat -z` output: "added\tremoved\tpath\0" (binary files show "-").
    static func files(numstat: String) -> [File] {
        numstat.split(separator: "\0").compactMap { entry in
            let parts = entry.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { return nil }
            let path = parts[2].trimmingCharacters(in: .newlines)
            guard CollabPaths.valid(path) else { return nil }
            return File(path: path, added: Int(parts[0]) ?? 0, removed: Int(parts[1]) ?? 0)
        }
    }
    var summary: String {
        let list = files.prefix(40).map { "- \($0.path) (+\($0.added) −\($0.removed))" }.joined(separator: "\n")
        let more = files.count > 40 ? "\n- …and \(files.count - 40) more" : ""
        let said = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        “\(title)” (\(agent)) finished at commit \(commit.prefix(12)). Your worktree starts from its result.
        Files it changed:
        \(files.isEmpty ? "- none" : list + more)
        \(said.isEmpty ? "" : "What it said at the end:\n" + String(said.prefix(2000)))
        """.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The prompt a subtask's agent starts with: the goal, its part, what the other agents are
    /// doing (so it stays in its lane), and the results it builds on.
    static func prompt(goal: String, subtask: OrchestratorSubtask, plan: OrchestratorPlan, handoffs: [OrchestratorHandoff], notes: [String] = []) -> String {
        let others = plan.subtasks.filter { $0.id != subtask.id }.map { other in
            "- \(other.title) (\(other.agent.title))" + (other.files.isEmpty ? "" : ": " + other.files.prefix(12).joined(separator: ", "))
        }
        var sections = [
            "You're one of several agents working on one goal at the same time, each in its own worktree. Tsukumo coordinates you and merges the results.",
            "Goal: " + goal.trimmingCharacters(in: .whitespacesAndNewlines),
            "Your part: " + subtask.title + "\n" + subtask.brief
        ]
        if !subtask.files.isEmpty { sections.append("Files you're expected to change: " + subtask.files.joined(separator: ", ") + ". Stay within them where you can.") }
        if !subtask.areas.isEmpty { sections.append("Areas: " + subtask.areas.joined(separator: ", ")) }
        if !others.isEmpty { sections.append("Other agents are working on:\n" + others.joined(separator: "\n") + "\nDon't change their files. If you must, say which and why in your final message.") }
        if !handoffs.isEmpty { sections.append("Results you build on:\n" + handoffs.map(\.summary).joined(separator: "\n\n")) }
        sections += notes
        sections.append("When you're done, end with a short note for whoever builds on your work: what changed and anything they should know.")
        return sections.joined(separator: "\n\n")
    }
}

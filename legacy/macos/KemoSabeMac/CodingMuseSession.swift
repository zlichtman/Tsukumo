import Foundation

// Meta's Muse Code in Tsukumo, through the Muse Session Protocol (MSP) that `muse serve` speaks
// over stdio. Muse Code has no ACP mode (none in its help or schema), so this is its own adapter.
//
// Verified against the installed Muse Code 1.4.0 (1.4.0-R4302.1) on September 27, 2026:
// - Its help (`muse --help`, `serve`, `exec`, `resume`, `schema`) and its exported stable wire
//   schema (`muse schema generate-json-schema` / `generate-ts`: MSP v1, envelope schema 1,
//   fingerprint sha256:99a7458c…a658). Every method and field used here is in that schema.
// - Live, with isolated XDG folders, no sign-in, and no prompt sent to Meta: `muse serve`
//   answers `initialize` (serverInfo, schema, sessionDurability), `session/start`,
//   `session/resume`, `session/fork`, `session/delete` (+ `session/deleteCompleted`),
//   `model/list`, and `skill/list`; a turn without a sign-in ends with `turn/completed`
//   terminal `failed`, error kind `authRequired`. `muse exec --provider echo --json` streams
//   raw log records (`run.output.delta`, `run.terminal.completed`); the gated integration test
//   drives both through these classes.
// Taken from the schema only (not seen live, because they need a signed-in model): streamed
// `item/*` items for replies, reasoning, and tool calls, `approval/request` with its choices and
// `approval/decide`, `userInput/request`, `turn/steer`, `turn/interrupt`, `session/compact`, and
// `session/todoListChanged`. Muse's own tool names (bash/shell/exec_command, apply_patch,
// edit_file, write_file, read_file, web_search, web_fetch) come from strings in the binary; their
// argument names are assumed (command, path, old/new text, content, patch) and every card falls
// back to the tool name and its raw arguments when they differ. `muse serve` has no provider
// flag (the echo provider is exec-only), so a full MSP turn wasn't run end to end.

enum CodingMuse {
    /// The MSP envelope schema version this client speaks (`initialize` → `schema.version`).
    static let schemaVersion = 1
    /// The stable-surface fingerprint of the binary this was built against. A different one is
    /// noted, not refused: MSP evolves additively.
    static let fingerprint = "sha256:99a7458c70a670dda3dda45512bdd1e270aba156f46a1324515de45dce95a658"
    /// `--reasoning-effort` tiers from `muse --help` (default high), the MSP `ReasoningEffort` vocabulary.
    static let efforts = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
    static let defaultModel = CodingAgentModel(id: "", name: "Default model", detail: "Muse Code's default", efforts: efforts, defaultEffort: "high", isDefault: true)
    static let shellTools: Set<String> = ["bash", "shell", "exec_command", "shell_command"]
    static let editTools: Set<String> = ["apply_patch", "edit_file", "write_file"]

    /// Whether Muse Code's sign-in file exists (the launcher's own path; the file isn't opened).
    static func signedIn(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        let path: String
        if let custom = environment["MUSE_AUTH_PATH"], !custom.isEmpty { path = custom }
        else if let config = environment["XDG_CONFIG_HOME"], !config.isEmpty { path = config + "/muse/auth.json" }
        else { path = NSHomeDirectory() + "/.config/muse/auth.json" }
        return FileManager.default.fileExists(atPath: path)
    }
    /// A UUIDv7 (MSP's `commandId`): 48 bits of Unix milliseconds, version 7, variant, random.
    static func uuid7(now: Date = Date()) -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        let ms = UInt64(max(0, now.timeIntervalSince1970 * 1000))
        for index in 0..<6 { bytes[index] = UInt8((ms >> (8 * (5 - index))) & 0xff) }
        bytes[6] = (bytes[6] & 0x0f) | 0x70
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return uuid.uuidString.lowercased()
    }
    /// `muse serve`'s host flags for an access level. Sandbox posture is fixed per host process
    /// (one per task); approval is chosen on the wire (`approvalMode`). The workspace is trusted
    /// so its own rules load, as Claude Code and Codex load theirs.
    static func serveArguments(_ access: CodingAccess) -> [String] {
        var args = ["serve", "--trust-workspace"]
        switch access {
        case .readOnly: args += ["--disable-write", "--disable-shell"]
        case .edit, .autoEdit: break
        case .full: args += ["--disable-sandbox"]
        }
        return args
    }
    /// MSP's approval modes: prompt for anything no rule allows (Ask first), the agent's own
    /// on-request default (Auto-edit), allow everything (Full access), deny what isn't allowed (Read only).
    static func approvalMode(_ access: CodingAccess) -> String {
        switch access { case .readOnly: "denyUnmatched"; case .edit: "promptUnmatched"; case .autoEdit: "onRequest"; case .full: "allowAll" }
    }
    /// `muse exec` (the fallback) for one prompt.
    static func execArguments(_ task: CodingTaskRecord, promptFile: String, images: [URL], extra: [String] = []) -> [String] {
        var args = ["exec"] + extra + ["--json", "--prompt-file", promptFile, "--workspace", task.directory, "--user-input-auto-resolve"]
        switch task.access {
        case .readOnly: args += ["--disable-write", "--disable-shell", "--approval-mode", "untrusted"]
        case .edit: args += ["--approval-mode", "untrusted", "--trust-workspace"]
        case .autoEdit: args += ["--approval-mode", "on-request", "--trust-workspace"]
        case .full: args += ["--yolo"]
        }
        if !task.model.isEmpty { args += ["--model", task.model] }
        if let effort = task.effort, efforts.contains(effort) { args += ["--reasoning-effort", effort] }
        for image in images { args += ["--image", image.path] }
        return args
    }
    /// A turn's input parts: `/skill args` becomes a `skill` part when it names one of the
    /// session's skills (from `skill/list`); otherwise text, then images as base64.
    static func input(_ input: CodingTurnInput, skills: Set<String>) -> [[String: Any]] {
        var parts: [[String: Any]] = []
        let trimmed = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") {
            let body = trimmed.dropFirst()
            let name = String(body.prefix { !$0.isWhitespace })
            if skills.contains(name) {
                var part: [String: Any] = ["type": "skill", "selector": name]
                let rest = body.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines)
                if !rest.isEmpty { part["arguments"] = rest }
                parts.append(part)
            }
        }
        if parts.isEmpty { parts.append(["type": "text", "text": input.text]) }
        for url in input.images {
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { continue }
            parts.append(["type": "image", "base64Data": data.base64EncodedString(), "mediaType": CodingACP.mediaType(url)])
        }
        return parts
    }
    static func status(_ status: String?) -> String {
        switch status {
        case "inProgress": "running"
        case "completed": "completed"
        case "rejected": "declined"
        case .none: ""
        default: "failed"
        }
    }
    /// One transcript item (`item/started`, `item/updated`, `item/completed`) as an event, or nil
    /// for items Tsukumo already shows (the person's own messages) or that are internal.
    static func itemEvent(_ item: [String: Any], directory: String) -> CodingEvent? {
        let id = item["itemId"] as? String ?? UUID().uuidString
        let status = item["status"] as? String
        var event: CodingEvent
        switch item["kind"] as? String ?? "" {
        case "userMessage", "reminderChild": return nil
        case "agentMessage":
            event = .init(id: id, kind: .assistant, text: item["text"] as? String ?? "")
            event.ref = item["turnId"] as? String
            return event
        case "reasoning":
            let summary = (item["summary"] as? [String] ?? []).joined(separator: "\n\n")
            let text = summary.isEmpty ? item["text"] as? String ?? "" : summary
            return text.isEmpty ? nil : .init(id: id, kind: .reasoning, text: text)
        case "toolCall":
            guard let card = toolEvent(item, directory: directory) else { return nil }
            event = card
        case "userShell":
            event = .init(id: id, kind: .command, text: item["commandText"] as? String ?? "Shell", detail: item["visibleOutput"] as? String ?? "", tool: "commandExecution")
            event.exitCode = item["exitCode"] as? Int
        case "subagent":
            let objective = item["objective"] as? String ?? item["role"] as? String ?? "Subagent"
            let summary = (item["result"] as? [String: Any])?["summary"] as? String ?? ""
            event = .init(id: id, kind: .collaboration, text: "Subagent: " + objective, detail: summary)
        case "workflow":
            event = .init(id: id, kind: .collaboration, text: "Workflow", detail: item["message"] as? String ?? item["fallbackText"] as? String ?? "")
        case "compaction":
            guard status != "inProgress" else { return nil }
            return .init(id: id, kind: .system, text: item["outcome"] as? String == "noop" ? "Nothing to compact" : "Context compacted",
                         detail: "Muse Code summarized the conversation so far to free up its context.")
        default:
            guard let fallback = item["fallbackText"] as? String, !fallback.isEmpty else { return nil }
            return .init(id: id, kind: .system, text: fallback)
        }
        event.status = Self.status(status)
        if let ms = item["durationMs"] as? Double { event.duration = ms / 1000 } else if let ms = item["durationMs"] as? Int { event.duration = Double(ms) / 1000 }
        return event
    }
    /// The model-authored arguments (verbatim JSON text) as a dictionary, when they parse.
    static func arguments(_ raw: Any?) -> [String: Any] {
        if let dictionary = raw as? [String: Any] { return dictionary }
        guard let text = raw as? String, let data = text.data(using: .utf8) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
    static func path(_ args: [String: Any]) -> String? {
        for key in ["path", "file_path", "filePath", "file", "target"] { if let value = args[key] as? String, !value.isEmpty { return value } }
        return nil
    }
    static func command(_ args: [String: Any]) -> String? {
        for key in ["command", "cmd", "script"] {
            if let text = args[key] as? String, !text.isEmpty { return text }
            if let argv = args[key] as? [String], !argv.isEmpty { return argv.map(CodingACP.shellQuote).joined(separator: " ") }
        }
        return nil
    }
    /// A tool call's card. Shell tools are commands; edit tools are file cards with a diff made
    /// from their arguments (old and new text, new content, or an apply_patch patch);
    /// `write_todos` is shown by `session/todoListChanged` instead; the rest are tool cards.
    static func toolEvent(_ item: [String: Any], directory: String) -> CodingEvent? {
        let id = item["itemId"] as? String ?? UUID().uuidString
        let tool = item["tool"] as? String ?? "tool"
        let args = arguments(item["args"])
        var event: CodingEvent
        if shellTools.contains(tool) {
            event = .init(id: id, kind: .command, text: command(args) ?? tool, detail: item["visibleOutput"] as? String ?? "", tool: "commandExecution")
        } else if editTools.contains(tool) {
            let path = CodingChatEvents.relative(self.path(args) ?? "", to: directory)
            var diff = ""
            if let patch = (args["patch"] as? String) ?? (args["input"] as? String), !patch.isEmpty { diff = applyPatchDiff(patch, directory: directory) }
            else if let old = (args["old_string"] as? String) ?? (args["old_text"] as? String) ?? (args["oldText"] as? String) ?? (args["old"] as? String) {
                let new = (args["new_string"] as? String) ?? (args["new_text"] as? String) ?? (args["newText"] as? String) ?? (args["new"] as? String) ?? ""
                diff = CodingChatEvents.unifiedDiff(path: path, hunks: [(old, new)])
            } else if let content = args["content"] as? String { diff = CodingChatEvents.unifiedDiff(path: path, hunks: [("", content)], added: tool == "write_file") }
            let paths = CodingDiff.parse(diff).map(\.path)
            event = .init(id: id, kind: .file, text: paths.count > 1 ? "\(paths.count) files" : paths.first ?? (path.isEmpty ? tool : path), detail: diff, tool: tool)
            if let summary = item["patchSummary"] as? [String: Any] {
                event.output = "+\(summary["added"] as? Int ?? 0) −\(summary["removed"] as? Int ?? 0) in \(summary["files"] as? Int ?? 1) file\((summary["files"] as? Int ?? 1) == 1 ? "" : "s")"
            }
        } else {
            switch tool {
            case "write_todos", "update_plan", "request_user_input": return nil
            case "read_file": event = .init(id: id, kind: .command, text: "Read " + CodingChatEvents.relative(path(args) ?? "", to: directory), tool: "Read")
            case "web_search": event = .init(id: id, kind: .command, text: "Search the web for “\(args["query"] as? String ?? "")”", tool: "WebSearch")
            case "web_fetch": event = .init(id: id, kind: .command, text: "Fetch " + (args["url"] as? String ?? ""), tool: "WebFetch")
            default: event = .init(id: id, kind: .command, text: CodingChatEvents.toolSummary(name: tool, input: args, directory: directory), tool: tool)
            }
            if let output = item["visibleOutput"] as? String, !output.isEmpty { event.output = output }
        }
        if let reason = item["failureReason"] as? String, !reason.isEmpty { event.output = [event.output ?? "", reason].filter { !$0.isEmpty }.joined(separator: "\n") }
        return event
    }
    /// An apply_patch patch (`*** Begin Patch`, `*** Update File: path`, `*** Add File:`,
    /// `*** Delete File:`, hunks of +, -, and context lines) as a unified diff. A patch that's
    /// already a unified diff is kept.
    static func applyPatchDiff(_ patch: String, directory: String) -> String {
        guard patch.contains("*** ") else { return patch.hasPrefix("diff --git") || patch.contains("\n@@") ? patch : "" }
        var out = "", path = "", adding = false, lines: [String] = []
        func flush() {
            guard !path.isEmpty else { return }
            let body = lines.filter { !$0.hasPrefix("@@") }
            let removed = body.filter { $0.hasPrefix("-") }.count, added = body.filter { $0.hasPrefix("+") }.count
            let context = body.filter { $0.hasPrefix(" ") }.count
            out += "diff --git a/\(path) b/\(path)\n" + (adding ? "new file mode 100644\n" : "")
            out += "@@ -\(removed + context == 0 ? 0 : 1),\(removed + context) +\(added + context == 0 ? 0 : 1),\(added + context) @@\n"
            out += body.map { $0 + "\n" }.joined()
            lines = []
        }
        for raw in patch.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if raw.hasPrefix("*** Update File: ") || raw.hasPrefix("*** Add File: ") || raw.hasPrefix("*** Delete File: ") {
                flush()
                adding = raw.hasPrefix("*** Add File: ")
                path = CodingChatEvents.relative(String(raw.split(separator: ":", maxSplits: 1).last ?? "").trimmingCharacters(in: .whitespaces), to: directory)
            } else if raw.hasPrefix("*** ") { continue }
            else if !path.isEmpty, let first = raw.first, "+- @".contains(first) { lines.append(raw) }
        }
        flush()
        return out
    }
    /// What the permission popup shows for an `approval/request`.
    static func approval(key: String, params: [String: Any], directory: String, pending: Int) -> CodingApproval {
        let subject = params["subject"] as? [String: Any] ?? [:]
        let raw = params["rawArgs"] as? String ?? ""
        let tool = params["toolName"] as? String ?? subject["toolName"] as? String ?? ""
        var detail = raw
        if params["protectedWrite"] as? Bool == true { detail = "A protected path. " + detail }
        switch subject["kind"] as? String ?? "" {
        case "shell":
            let stages = (subject["stages"] as? [[String: Any]] ?? []).compactMap { ($0["argv"] as? [String])?.map(CodingACP.shellQuote).joined(separator: " ") }
            let command = subject["command"] as? String ?? (stages.isEmpty ? command(arguments(raw)) ?? tool : stages.joined(separator: " | "))
            return .init(id: key, title: command, detail: detail, kind: .command, command: command, pending: pending)
        case "fileAccess":
            let path = CodingChatEvents.relative(subject["path"] as? String ?? "", to: directory)
            let access = subject["access"] as? String ?? "access"
            if editTools.contains(tool), let card = toolEvent(["itemId": key, "tool": tool, "args": raw], directory: directory), !card.detail.isEmpty {
                return .init(id: key, title: card.text, detail: detail, kind: .files, diff: card.detail, pending: pending)
            }
            let writes = access.lowercased().contains("write")
            return .init(id: key, title: (writes ? path : access.capitalized + " " + path), detail: detail, kind: writes ? .files : .command, pending: pending)
        case "network":
            let host = subject["host"] as? String ?? subject["target"] as? String ?? "the network"
            let port = (subject["port"] as? Int).map { ":\($0)" } ?? ""
            return .init(id: key, title: "Connect to " + host + port, detail: detail, kind: .command, pending: pending)
        default:
            if editTools.contains(tool), let card = toolEvent(["itemId": key, "tool": tool, "args": raw], directory: directory), !card.detail.isEmpty {
                return .init(id: key, title: card.text, detail: detail, kind: .files, diff: card.detail, pending: pending)
            }
            if shellTools.contains(tool), let command = command(arguments(raw)) {
                return .init(id: key, title: command, detail: detail, kind: .command, command: command, pending: pending)
            }
            return .init(id: key, title: tool.isEmpty ? (subject["kind"] as? String ?? "Use a tool") : tool, detail: detail, kind: .command, pending: pending, tool: tool.isEmpty ? nil : tool)
        }
    }
    /// The choice to send for a decision: one-time approval, approval for the session (never a
    /// persistent rule), or denial (the one that takes feedback when there's a note).
    static func choice(for decision: CodingApprovalDecision, in choices: [[String: Any]]) -> [String: Any]? {
        func kind(_ entry: [String: Any]) -> String { entry["decision"] as? String ?? "" }
        func scope(_ entry: [String: Any]) -> String { entry["scope"] as? String ?? "" }
        let once = choices.first { kind($0) == "approved" && scope($0) == "once" } ?? choices.first { kind($0) == "approved" && scope($0) != "localPersistent" }
        switch decision {
        case .allowOnce: return once
        case .allowSession: return choices.first { kind($0) == "approvedForSession" && scope($0) != "localPersistent" } ?? choices.first { kind($0).hasPrefix("approved") && scope($0) == "session" } ?? once
        case .deny(let note):
            let denials = choices.filter { (kind($0) == "denied" || kind($0) == "deniedPolicyAmendment") && scope($0) != "localPersistent" }
            if !note.isEmpty, let withFeedback = denials.first(where: { $0["acceptsFeedback"] as? Bool == true }) { return withFeedback }
            return denials.first { kind($0) == "denied" } ?? denials.first ?? choices.first { kind($0) == "abort" }
        }
    }
    /// `userInput/answer` answers: an option's label when the answer names one, otherwise free text.
    static func answers(_ questions: [[String: Any]], answer: String) -> [[String: Any]] {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        return questions.compactMap { question in
            guard let id = question["id"] as? String else { return nil }
            let labels = (question["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
            let multiple = (question["selection"] as? [String: Any])?["mode"] as? String == "multiple"
            if let match = labels.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                return multiple ? ["questionId": id, "selectedLabels": [match]] : ["questionId": id, "selectedLabel": match]
            }
            if multiple {
                let picked = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                let matched = picked.compactMap { pick in labels.first { $0.caseInsensitiveCompare(pick) == .orderedSame } }
                if !matched.isEmpty, matched.count == picked.count { return ["questionId": id, "selectedLabels": matched] }
            }
            return ["questionId": id, "freeText": String(trimmed.prefix(500))]
        }
    }
    /// `model/list` → models with their ordered efforts (`variants`; "unknown" means none known).
    static func models(_ result: [String: Any]) -> [CodingAgentModel] {
        (result["models"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let id = entry["modelId"] as? String else { return nil }
            return .init(id: id, name: entry["displayLabel"] as? String ?? id, detail: entry["description"] as? String ?? "",
                         efforts: entry["variants"] as? [String] ?? [], defaultEffort: nil, isDefault: entry["isDefault"] as? Bool == true)
        }
    }
    /// The plan from `session/todoListChanged`.
    static func todoEvent(_ items: [[String: Any]], id: String) -> CodingEvent {
        let lines = items.map { ($0["status"] as? String ?? "pending") + " · " + ($0["text"] as? String ?? "") }
        return .init(id: id, kind: .plan, text: "Plan", detail: lines.joined(separator: "\n"))
    }
    /// The environment `muse` starts with: the person's own, never a login prompt from the
    /// launcher (Tsukumo's Sign in opens `muse login` in a terminal instead).
    static func environment(_ extra: [String: String] = [:]) -> [String: String] {
        CodingChild.environment(["TERM_PROGRAM": "Tsukumo", "MUSE_LOGIN": "0"].merging(extra) { $1 })
    }
}

/// One `muse serve` host and one MSP session per task.
@MainActor final class CodingMuseSession: AgentSession {
    var onEvent: ((CodingEvent, Bool) -> Void)?
    var onState: ((CodingTaskStatus) -> Void)?
    var onSession: ((String) -> Void)?
    var onApproval: ((CodingApproval?) -> Void)?
    var onReport: ((CodingAgentReport) -> Void)?
    private let task: CodingTaskRecord
    private let executableOverride: URL?
    private let environment: [String: String]?
    private let transport: CodingProcess
    private let interruptGrace: TimeInterval
    private var sessionID: String?
    private var turnID: String?
    private var ready = false, starting = false, active = false, stopped = false, aborting = false, interrupting = false
    private var hostAnswered = false
    private var stderr = ""
    private var sequence = 0
    private var requests: [Int: String] = [:]
    private var configuring: Set<Int> = []
    private enum Pending { case turn(CodingTurnInput), compact, review }
    private var pending: Pending?
    private var deadline: Task<Void, Never>?
    private var skills: Set<String> = []
    /// The host granted `sessionMcp`, so sessions can carry the KemoSabe MCP server.
    private var sessionMcp = false
    /// A KemoSabe chat hand-off (`KemoSabeHandoff`): its ID goes to the KemoSabe MCP server, and its
    /// flags (no writes, no shell) follow `serve`'s own.
    var handoff: String?
    var extraServeArguments: [String] = []
    /// `session/compact` finishes with its compaction item (or a noop ack), not a turn.
    private var compacting = false
    private var kinds: [String: String] = [:]
    private var summaryPart: [String: Int] = [:]
    /// Approval and user-input requests waiting for the person, in order.
    private enum Waiting { case approval([String: Any]), userInput([String: Any]) }
    private var waiting: [String: Waiting] = [:]
    private var order: [String] = []
    /// After `serve` turned out to be missing: the exec fallback.
    private var fallback: CodingMuseExecSession?

    init(task: CodingTaskRecord, executableOverride: URL? = nil, environment: [String: String]? = nil, interruptGrace: TimeInterval = 3, terminationGrace: TimeInterval = 3) {
        self.task = task; self.executableOverride = executableOverride; self.environment = environment; self.interruptGrace = interruptGrace
        transport = CodingProcess(grace: terminationGrace)
        sessionID = task.sessionID
        transport.onJSON = { [weak self] in self?.receive($0) }
        transport.onError = { [weak self] text in
            guard let self, !stopped, !aborting else { return }
            stderr += text
            if hostAnswered { emit(.system, "Agent diagnostic", detail: String(text.prefix(4000))) }
        }
        transport.onExit = { [weak self] code in self?.exited(code) }
    }

    // MARK: AgentSession

    func send(_ text: String) throws { try send(input: .init(text: text)) }
    func send(input: CodingTurnInput) throws {
        if let fallback { try fallback.send(input: input); return }
        try begin(.turn(input))
    }
    func compact() throws { if let fallback { try fallback.send("/compact"); return }; try begin(.compact) }
    func review() throws { try send(CodingAgentSession.reviewPrompt) }
    func steer(_ input: CodingTurnInput) throws -> Bool {
        guard fallback == nil, !stopped, active, ready, let sessionID, let turnID else { return false }
        try request("turn/steer", ["commandId": CodingMuse.uuid7(), "sessionId": sessionID, "expectedTurnId": turnID, "input": CodingMuse.input(input, skills: skills)])
        return true
    }
    func interrupt() {
        if let fallback { fallback.interrupt(); return }
        guard !stopped, active, let sessionID, let turnID else { return }
        interrupting = true
        try? request("turn/interrupt", ["commandId": CodingMuse.uuid7(), "sessionId": sessionID, "turnId": turnID])
    }
    func respond(_ id: String, allow: Bool, answers: String) throws { try respond(id, decision: allow ? .allowOnce : .deny(note: ""), answers: answers) }
    func respond(_ id: String, decision: CodingApprovalDecision, answers: String) throws {
        guard let entry = waiting[id], let sessionID else { throw CodingFailure("This request is no longer active.") }
        waiting.removeValue(forKey: id); order.removeAll { $0 == id }
        var steerNote = false
        switch entry {
        case .approval(let params):
            let choices = params["availableChoices"] as? [[String: Any]] ?? []
            guard let choice = CodingMuse.choice(for: decision, in: choices), let choiceID = choice["choiceId"] as? String else {
                throw CodingFailure("Muse Code offered no choice for that answer.")
            }
            var decide: [String: Any] = ["approvalId": id, "choiceId": choiceID, "commandId": CodingMuse.uuid7(), "sessionId": sessionID,
                                         "requirementId": params["currentRequirementId"] ?? [String: Any]()]
            if !decision.note.isEmpty {
                if choice["acceptsFeedback"] as? Bool == true { decide["feedback"] = decision.note } else { steerNote = true }
            }
            try request("approval/decide", decide)
        case .userInput(let params):
            if decision.allows {
                try request("userInput/answer", ["commandId": CodingMuse.uuid7(), "sessionId": sessionID, "userInputId": id,
                                                 "answers": CodingMuse.answers(params["questions"] as? [[String: Any]] ?? [], answer: answers)])
            } else {
                var cancel: [String: Any] = ["commandId": CodingMuse.uuid7(), "sessionId": sessionID, "userInputId": id]
                if !decision.note.isEmpty { cancel["reason"] = decision.note }
                try request("userInput/cancel", cancel)
            }
        }
        emit(.approval, decision.summary, detail: decision.note.isEmpty ? id : "Note to the agent: " + decision.note)
        // A denial that takes no feedback: the note follows as a message added to the running turn.
        if steerNote, let turnID { try? request("turn/steer", ["commandId": CodingMuse.uuid7(), "sessionId": sessionID, "expectedTurnId": turnID, "input": [["type": "text", "text": decision.note]]]) }
        if order.isEmpty { onApproval?(nil); onState?(active ? .working : .review) } else { showFirst() }
    }
    func stop() {
        if let fallback { fallback.stop() }
        guard !stopped else { return }
        let wasActive = active
        if wasActive, ready, let sessionID, let turnID { try? request("turn/interrupt", ["commandId": CodingMuse.uuid7(), "sessionId": sessionID, "turnId": turnID]) }
        stopped = true
        deadline?.cancel(); pending = nil; starting = false; active = false; waiting.removeAll(); order.removeAll()
        onEvent = nil; onState = nil; onSession = nil; onApproval = nil; onReport = nil
        guard transport.running else { return }
        // Closing stdin ends `muse serve`, which closes its sessions in order ("hostShutdown").
        if wasActive { transport.shutdown(after: interruptGrace) } else { transport.stop() }
    }

    // MARK: Starting

    private func begin(_ action: Pending) throws {
        guard !stopped else { throw CodingFailure("This agent session was stopped.") }
        guard !aborting else { throw CodingFailure("The agent is still shutting down. Try again in a moment.") }
        guard !active, !starting else { throw CodingFailure("Wait for this turn or stop it before sending another message.") }
        active = true; interrupting = false; onState?(.working)
        do {
            if transport.running, ready, configuring.isEmpty { try perform(action); return }
            pending = action
            guard !transport.running else { return }
            starting = true; hostAnswered = false; stderr = ""
            let executable = try executableOverride ?? CodingProcess.executable("muse")
            try transport.start(executable: executable, arguments: CodingMuse.serveArguments(task.access) + extraServeArguments, directory: URL(fileURLWithPath: task.directory), environment: environment ?? CodingMuse.environment())
            // `sessionMcp` lets `session/start` add the KemoSabe MCP server for this session only.
            var capabilities: [String: Any] = ["userInputDialogs": true]
            if KemoSabeMCP.museSessionConfig() != nil { capabilities["requestedCapabilities"] = ["sessionMcp"] }
            try request("initialize", ["clientInfo": ["name": "tsukumo", "title": "Tsukumo", "version": "1.0.0"], "capabilities": capabilities])
            deadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(45))
                guard !Task.isCancelled, let self, self.starting, !self.stopped else { return }
                self.abort("Muse Code didn't start in time")
            }
        } catch {
            active = false; starting = false; onState?(.failed); aborting = transport.running; transport.stop()
            if (error as? CodingFailure)?.message.hasPrefix("Install muse") == true { throw CodingFailure("Muse Code isn't installed — install it from dev.meta.ai, then sign in from Settings → Agents.") }
            throw error
        }
    }
    private func perform(_ action: Pending) throws {
        guard let sessionID else { throw CodingFailure("Muse Code didn't return a session.") }
        switch action {
        case .turn(let input):
            var params: [String: Any] = ["commandId": CodingMuse.uuid7(), "sessionId": sessionID, "input": CodingMuse.input(input, skills: skills), "ifBusy": "queue"]
            if let effort = task.effort, CodingMuse.efforts.contains(effort) { params["reasoningEffort"] = effort }
            try request("turn/start", params)
        case .compact: compacting = true; try request("session/compact", ["commandId": CodingMuse.uuid7(), "sessionId": sessionID])
        case .review: try request("turn/start", ["commandId": CodingMuse.uuid7(), "sessionId": sessionID, "input": [["type": "text", "text": CodingAgentSession.reviewPrompt]], "ifBusy": "queue"])
        }
    }
    private func openSession() throws {
        if let sessionID {
            var params: [String: Any] = ["commandId": CodingMuse.uuid7(), "sessionId": sessionID, "excludeItems": true]
            if sessionMcp, let config = KemoSabeMCP.museSessionConfig(handoff: handoff) { params["config"] = config }
            try request("session/resume", params)
        } else if let fork = task.fork {
            try request("session/fork", ["commandId": CodingMuse.uuid7(), "sessionId": fork.sessionID, "cutPoint": ["lastTurnId": fork.ref], "excludeItems": true])
        } else {
            var params: [String: Any] = ["commandId": CodingMuse.uuid7(), "workspaceRoot": task.directory, "approvalMode": CodingMuse.approvalMode(task.access)]
            if !task.model.isEmpty { params["modelId"] = task.model }
            if sessionMcp, let config = KemoSabeMCP.museSessionConfig(handoff: handoff) { params["config"] = config }
            try request("session/start", params)
        }
    }
    /// A resumed or forked session gets the task's approval mode and model before the first turn.
    private func settle(reopened: Bool) throws {
        guard let sessionID else { return }
        if reopened {
            try configure("session/setApprovalMode", ["commandId": CodingMuse.uuid7(), "sessionId": sessionID, "mode": CodingMuse.approvalMode(task.access)])
            if !task.model.isEmpty { try configure("session/setModel", ["commandId": CodingMuse.uuid7(), "sessionId": sessionID, "model": ["modelId": task.model]]) }
        }
        // Before the first turn, so a `/skill` message is sent as a skill part.
        try configure("skill/list", ["sessionId": sessionID])
    }

    // MARK: Wire

    private func request(_ method: String, _ params: [String: Any]) throws {
        sequence += 1; requests[sequence] = method
        try transport.send(["jsonrpc": "2.0", "id": sequence, "method": method, "params": params])
    }
    private func configure(_ method: String, _ params: [String: Any]) throws { try request(method, params); configuring.insert(sequence) }
    private func emit(_ kind: CodingEvent.Kind, _ text: String, detail: String = "", id: String? = nil, append: Bool = false) {
        onEvent?(.init(id: id ?? UUID().uuidString, kind: kind, text: text, detail: detail), append)
    }
    private func abort(_ message: String, detail: String = "") {
        emit(.system, message, detail: detail)
        deadline?.cancel(); pending = nil; starting = false; active = false; interrupting = false; ready = false
        clearWaiting(); onState?(.failed)
        aborting = transport.running; transport.stop()
    }
    private func exited(_ code: Int32) {
        guard !stopped else { return }
        deadline?.cancel(); requests.removeAll(); configuring.removeAll(); ready = false; turnID = nil
        if aborting { aborting = false; return }
        // `serve` isn't in this Muse Code: the same task continues through `muse exec`.
        if !hostAnswered, case .turn(let input)? = pending, stderr.contains("serve") || stderr.lowercased().contains("unknown") {
            starting = false; active = false; pending = nil
            let exec = CodingMuseExecSession(task: task, executableOverride: executableOverride, environment: environment)
            exec.onEvent = onEvent; exec.onState = onState; exec.onSession = onSession; exec.onApproval = onApproval; exec.onReport = onReport
            fallback = exec
            emit(.system, "Using Muse Code's headless mode", detail: "This Muse Code has no `serve`, so each message runs `muse exec`: no approvals, steering, or resume.")
            try? exec.send(input: input)
            return
        }
        starting = false
        if active { onState?(code == 0 || interrupting ? .interrupted : .failed) }
        active = false; interrupting = false; clearWaiting()
        emit(.system, "Agent disconnected", detail: "Exit \(code)." + (stderr.isEmpty ? "" : " " + String(stderr.suffix(600))) + " Send a message to resume its saved session.")
    }
    private func receive(_ object: [String: Any]) {
        guard !stopped, !aborting else { return }
        do {
            if let method = object["method"] as? String {
                if let id = object["id"], !(id is NSNull) { try serverRequest(id: id, method: method, params: object["params"] as? [String: Any] ?? [:]) }
                else { notification(method, object["params"] as? [String: Any] ?? [:]) }
                return
            }
            guard let id = (object["id"] as? Int) ?? (object["id"] as? NSNumber)?.intValue, let method = requests.removeValue(forKey: id) else { return }
            configuring.remove(id)
            if let error = object["error"] as? [String: Any] { try failed(method, error) }
            else { try answered(method, object["result"] as? [String: Any] ?? [:]) }
            if ready, configuring.isEmpty, let action = pending { pending = nil; try perform(action) }
        } catch { abort("Muse Code protocol error", detail: error.localizedDescription) }
    }
    private func answered(_ method: String, _ result: [String: Any]) throws {
        switch method {
        case "initialize":
            hostAnswered = true
            let schema = result["schema"] as? [String: Any] ?? [:]
            if let version = schema["version"] as? Int, version != CodingMuse.schemaVersion {
                abort("Muse Code speaks MSP schema \(version)", detail: "Tsukumo speaks MSP schema \(CodingMuse.schemaVersion)."); return
            }
            sessionMcp = (result["grantedCapabilities"] as? [String] ?? []).contains("sessionMcp")
            try transport.send(["jsonrpc": "2.0", "method": "initialized"])
            try openSession()
        case "session/start", "session/resume", "session/fork":
            guard let session = result["session"] as? [String: Any], let id = session["sessionId"] as? String else { throw CodingFailure("Muse Code didn't return a session.") }
            if sessionID != id { sessionID = id; onSession?(id) }
            ready = true; starting = false; deadline?.cancel()
            try settle(reopened: method != "session/start")
        case "turn/start":
            turnID = result["turnId"] as? String ?? turnID
        case "skill/list":
            skills = Set((result["skills"] as? [[String: Any]] ?? []).compactMap { $0["selector"] as? String })
            if !skills.isEmpty { onReport?(.init(commands: skills.sorted())) }
        case "session/compact":
            if result["status"] as? String == "noop" { compacting = false; emit(.system, "Nothing to compact", detail: result["reason"] as? String ?? ""); finishTurn(.review) }
        default: break
        }
    }
    private func failed(_ method: String, _ error: [String: Any]) throws {
        let message = error["message"] as? String ?? "Muse Code refused \(method)."
        let kind = (error["data"] as? [String: Any])?["kind"] as? String ?? ""
        switch method {
        case "session/resume" where kind == "sessionNotFound" || kind == "notFound", "session/fork" where kind == "sessionNotFound" || kind == "forkBoundaryInvalid":
            emit(.system, "Muse Code couldn't reopen its session", detail: message + " It starts a new session; it doesn't see the conversation above.")
            sessionID = nil
            var params: [String: Any] = ["commandId": CodingMuse.uuid7(), "workspaceRoot": task.directory, "approvalMode": CodingMuse.approvalMode(task.access)]
            if !task.model.isEmpty { params["modelId"] = task.model }
            if sessionMcp, let config = KemoSabeMCP.museSessionConfig(handoff: handoff) { params["config"] = config }
            try request("session/start", params)
        case "turn/steer", "approval/decide", "userInput/answer", "userInput/cancel", "session/setModel", "session/setApprovalMode":
            emit(.system, "Muse Code didn't take that", detail: message)
        case "skill/list": break
        case "session/compact" where (error["data"] as? [String: Any])?["reason"] as? String == "missing_run" || message.contains("missing_run"):
            // Checked with Muse Code 1.4.0: a session without a turn yet has nothing to compact.
            compacting = false
            emit(.system, "Nothing to compact", detail: "Muse Code has no conversation to summarize yet."); finishTurn(.review)
        case "turn/start", "session/compact":
            compacting = false
            emit(.system, "Turn failed", detail: message); finishTurn(.failed)
        case "turn/interrupt": break
        default: throw CodingFailure(message)
        }
    }

    // MARK: Server requests and notifications

    private func serverRequest(id: Any, method: String, params: [String: Any]) throws {
        switch method {
        case "approval/request", "userInput/request":
            // A presentation receipt only; the decision goes as `approval/decide` / `userInput/answer`.
            try transport.send(["jsonrpc": "2.0", "id": id, "result": [String: Any]()])
            if method == "approval/request" { track(approval: params) } else { track(userInput: params) }
        default:
            try transport.send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Tsukumo doesn't support \(method)."]])
        }
    }
    private func track(approval params: [String: Any]) {
        guard let key = params["approvalId"] as? String else { return }
        if waiting[key] == nil { order.append(key) }
        waiting[key] = .approval(params)
        showFirst()
    }
    private func track(userInput params: [String: Any]) {
        guard let key = params["userInputId"] as? String else { return }
        if waiting[key] == nil { order.append(key) }
        waiting[key] = .userInput(params)
        showFirst()
    }
    private func showFirst() {
        guard let key = order.first, let entry = waiting[key] else { return }
        switch entry {
        case .approval(let params): onApproval?(CodingMuse.approval(key: key, params: params, directory: task.directory, pending: order.count))
        case .userInput(let params):
            let questions = (params["questions"] as? [[String: Any]] ?? []).compactMap { question -> (id: String, text: String)? in
                guard let id = question["id"] as? String, let text = question["question"] as? String else { return nil }
                let options = (question["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
                return (id, options.isEmpty ? text : text + " (" + options.joined(separator: " / ") + ")")
            }
            onApproval?(.init(id: key, title: "Muse Code needs your input", detail: params["toolName"] as? String ?? "", questions: questions, kind: .question, pending: order.count))
        }
        onState?(.needsInput)
    }
    private func resolved(_ key: String) {
        guard waiting.removeValue(forKey: key) != nil else { return }
        order.removeAll { $0 == key }
        if order.isEmpty { onApproval?(nil); onState?(active ? .working : .review) } else { showFirst() }
    }
    private func clearWaiting() {
        guard !order.isEmpty else { return }
        waiting.removeAll(); order.removeAll(); onApproval?(nil)
    }
    private func notification(_ method: String, _ params: [String: Any]) {
        if let session = params["sessionId"] as? String, let sessionID, session != sessionID { return }
        switch method {
        case "turn/started": turnID = params["turnId"] as? String ?? turnID
        case "item/started", "item/updated", "item/completed":
            guard let item = params["item"] as? [String: Any] else { return }
            if let id = item["itemId"] as? String, let kind = item["kind"] as? String { kinds[id] = kind }
            if let event = CodingMuse.itemEvent(item, directory: task.directory) {
                // An opening reply with no text yet waits for its first delta.
                if method == "item/started", event.kind == .assistant, event.text.isEmpty { return }
                onEvent?(event, false)
            }
            if compacting, method == "item/completed", item["kind"] as? String == "compaction" { compacting = false; finishTurn(.review) }
        case "item/delta":
            guard let id = params["itemId"] as? String, let delta = params["delta"] as? String else { return }
            let field = params["field"] as? String ?? "text"
            switch kinds[id] {
            case "agentMessage": emit(.assistant, delta, id: id, append: true)
            case "reasoning":
                let part = field.hasPrefix("summary.") ? Int(field.dropFirst("summary.".count)) ?? 0 : 0
                let lead = summaryPart[id].map { $0 != part } ?? false ? "\n\n" : ""
                summaryPart[id] = part
                emit(.reasoning, lead + delta, id: id, append: true)
            case "toolCall", "userShell": if field == "output" { onEvent?(.init(id: id, kind: .command, text: "", detail: delta), true) }
            default: break
            }
        case "session/todoListChanged":
            onEvent?(CodingMuse.todoEvent(params["items"] as? [[String: Any]] ?? [], id: "plan-" + (sessionID ?? "muse")), false)
        case "session/modelChanged":
            onReport?(.init(model: params["modelId"] as? String))
        case "approval/requested": track(approval: params)
        case "approval/updated":
            guard let key = params["approvalId"] as? String, case .approval(var current)? = waiting[key] else { return }
            for field in ["availableChoices", "currentRequirementId", "subject"] { if let value = params[field] { current[field] = value } }
            waiting[key] = .approval(current); showFirst()
        case "approval/resolved": if let key = params["approvalId"] as? String { resolved(key) }
        case "userInput/requested": track(userInput: params)
        case "userInput/settled": if let key = params["userInputId"] as? String { resolved(key) }
        case "turn/completed":
            if let id = params["turnId"] as? String, let turnID, id != turnID { return }
            let terminal = params["terminal"] as? String
            if let error = params["error"] as? [String: Any] {
                let message = error["message"] as? String ?? params["reason"] as? String ?? "Unknown failure"
                if error["kind"] as? String == "authRequired" {
                    onReport?(.init(signedIn: false))
                    emit(.system, "Sign in to Muse Code", detail: message + " Settings → Agents → Muse Code → Sign in opens `muse login` in a terminal.")
                } else { emit(.system, "Turn failed", detail: message) }
            } else if terminal == "completed" { onReport?(.init(signedIn: true)) }
            finishTurn(terminal == "completed" ? .review : terminal == "cancelled" ? .interrupted : .failed)
        case "session/closed":
            ready = false
            if active { emit(.system, "Muse Code closed the session", detail: params["reason"] as? String ?? ""); finishTurn(.interrupted) }
        default: break
        }
    }
    private func finishTurn(_ state: CodingTaskStatus) {
        active = false; turnID = nil
        let interrupted = interrupting; interrupting = false
        clearWaiting()
        onState?(interrupted && state != .review ? .interrupted : state)
    }
}

/// The fallback: each message runs `muse exec --json` in the task's folder and streams its
/// records. Headless mode has no approvals (its approval mode is set from the task's access, and
/// questions auto-resolve), no steering, and no resume.
@MainActor final class CodingMuseExecSession: AgentSession {
    var onEvent: ((CodingEvent, Bool) -> Void)?
    var onState: ((CodingTaskStatus) -> Void)?
    var onSession: ((String) -> Void)?
    var onApproval: ((CodingApproval?) -> Void)?
    var onReport: ((CodingAgentReport) -> Void)?
    private let task: CodingTaskRecord
    private let executableOverride: URL?
    private let environment: [String: String]?
    /// Arguments after `exec` (tests pass `--provider echo`).
    private let extraArguments: [String]
    private var transport: CodingProcess?
    private var active = false, stopped = false, interrupted = false, finished = false
    private var turn = 0
    private var promptFile: URL?
    init(task: CodingTaskRecord, executableOverride: URL? = nil, environment: [String: String]? = nil, extraArguments: [String] = []) {
        self.task = task; self.executableOverride = executableOverride; self.environment = environment; self.extraArguments = extraArguments
    }
    func send(_ text: String) throws { try send(input: .init(text: text)) }
    func send(input: CodingTurnInput) throws {
        guard !stopped else { throw CodingFailure("This agent session was stopped.") }
        guard !active else { throw CodingFailure("Wait for this turn or stop it before sending another message.") }
        let executable = try executableOverride ?? CodingProcess.executable("muse")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tsukumo-muse-\(UUID().uuidString).txt")
        try input.text.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        promptFile = file
        turn += 1; active = true; interrupted = false; finished = false
        let process = CodingProcess(grace: 2)
        let reply = "muse-exec-\(task.id.uuidString)-\(turn)"
        process.onJSON = { [weak self] in self?.record($0, reply: reply) }
        process.onError = { [weak self] text in
            guard let self, !text.hasPrefix("muse: workspace root"), !text.contains("Including your") else { return }
            self.onEvent?(.init(kind: .system, text: "Agent diagnostic", detail: String(text.prefix(2000))), false)
        }
        process.onExit = { [weak self] code in self?.exited(code) }
        transport = process
        onState?(.working)
        do {
            try process.start(executable: executable, arguments: CodingMuse.execArguments(task, promptFile: file.path, images: input.images, extra: extraArguments),
                              directory: URL(fileURLWithPath: task.directory), environment: environment ?? CodingMuse.environment())
            process.closeInput()
        } catch { active = false; onState?(.failed); cleanup(); throw error }
    }
    func respond(_ id: String, allow: Bool, answers: String) throws { throw CodingFailure("Muse Code's headless mode has no approvals.") }
    func interrupt() { guard active else { return }; interrupted = true; transport?.stop() }
    func stop() {
        guard !stopped else { return }
        stopped = true
        onEvent = nil; onState = nil; onSession = nil; onApproval = nil; onReport = nil
        transport?.stop(); cleanup()
    }
    /// One raw log record (`schema_version`, `payload_type`, `payload`).
    private func record(_ object: [String: Any], reply: String) {
        guard !stopped else { return }
        if let stream = object["stream"] as? [String: Any], stream["kind"] as? String == "session", let id = stream["id"] as? String, object["sequence"] as? Int == 1 { onSession?(id) }
        let payload = object["payload"] as? [String: Any] ?? [:]
        switch object["payload_type"] as? String ?? "" {
        case "run.output.delta":
            if let text = payload["text"] as? String { onEvent?(.init(id: reply, kind: .assistant, text: text), true) }
        case let type where type.hasPrefix("run.terminal."):
            finished = true
            let terminal = payload["terminal"] as? String ?? String(type.dropFirst("run.terminal.".count))
            if let text = payload["text"] as? String, !text.isEmpty { onEvent?(.init(id: reply, kind: .assistant, text: text), false) }
            if terminal != "completed", let reason = payload["reason"] as? String { onEvent?(.init(kind: .system, text: "Turn failed", detail: reason), false) }
            if terminal == "completed" { onReport?(.init(signedIn: true)) }
            else if (payload["reason"] as? String ?? "").contains("not logged in") { onReport?(.init(signedIn: false)) }
            active = false
            onState?(terminal == "completed" ? .review : terminal == "cancelled" || interrupted ? .interrupted : .failed)
        default: break
        }
    }
    private func exited(_ code: Int32) {
        cleanup(); transport = nil
        guard !stopped, active else { return }
        active = false
        onState?(interrupted ? .interrupted : .failed)
        if !finished { onEvent?(.init(kind: .system, text: "Muse Code exited", detail: "Exit \(code)."), false) }
    }
    private func cleanup() { if let promptFile { try? FileManager.default.removeItem(at: promptFile); self.promptFile = nil } }
}

/// Settings and the catalog: one short-lived `muse serve` that answers `model/list` (no session
/// is started, nothing is sent to a model).
@MainActor final class CodingMuseCatalogProbe {
    private let executableOverride: URL?
    private let environment: [String: String]?
    private let transport = CodingProcess(grace: 1)
    private var done: ((Result<CodingCatalogProbe.Answer, Error>) -> Void)?
    private var timeout: Task<Void, Never>?
    private var keepAlive: CodingMuseCatalogProbe?
    init(executableOverride: URL? = nil, environment: [String: String]? = nil) { self.executableOverride = executableOverride; self.environment = environment }
    func run(_ completion: @escaping (Result<CodingCatalogProbe.Answer, Error>) -> Void) {
        done = completion; keepAlive = self
        transport.onJSON = { [weak self] in self?.receive($0) }
        transport.onExit = { [weak self] code in self?.finish(.failure(CodingFailure("Muse Code exited (\(code)) before listing its models."))) }
        do {
            try transport.start(executable: executableOverride ?? CodingProcess.executable("muse"), arguments: ["serve"], directory: FileManager.default.homeDirectoryForCurrentUser, environment: environment ?? CodingMuse.environment())
            try transport.send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["clientInfo": ["name": "tsukumo", "title": "Tsukumo", "version": "1.0.0"]]])
        } catch { finish(.failure(error)); return }
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20)); guard !Task.isCancelled else { return }
            self?.finish(.failure(CodingFailure("Muse Code didn't list its models in time.")))
        }
    }
    private func receive(_ object: [String: Any]) {
        switch (object["id"] as? Int) ?? (object["id"] as? NSNumber)?.intValue {
        case 1:
            try? transport.send(["jsonrpc": "2.0", "method": "initialized"])
            try? transport.send(["jsonrpc": "2.0", "id": 2, "method": "model/list", "params": [String: Any]()])
        case 2:
            if let error = object["error"] as? [String: Any] { finish(.failure(CodingFailure(error["message"] as? String ?? "Muse Code couldn't list models."))); return }
            finish(.success(.init(models: CodingMuse.models(object["result"] as? [String: Any] ?? [:]))))
        default: break
        }
    }
    private func finish(_ result: Result<CodingCatalogProbe.Answer, Error>) {
        guard let done else { return }
        self.done = nil; timeout?.cancel()
        transport.onExit = nil; transport.stop()
        done(result); keepAlive = nil
    }
}

/// Delete: one short-lived `muse serve` sends `session/delete` and waits for its
/// `session/deleteCompleted`. No turn starts.
@MainActor final class CodingMuseSessionDeletion {
    private let sessionID: String
    private let executableOverride: URL?
    private let environment: [String: String]?
    private let transport = CodingProcess(grace: 1)
    private var command = ""
    private var done: CheckedContinuation<String?, Never>?
    private var timeout: Task<Void, Never>?
    init(sessionID: String, executableOverride: URL? = nil, environment: [String: String]? = nil) {
        self.sessionID = sessionID; self.executableOverride = executableOverride; self.environment = environment
    }
    func run() async -> String? {
        await withCheckedContinuation { continuation in
            done = continuation
            transport.onJSON = { [weak self] in self?.receive($0) }
            transport.onExit = { [weak self] code in self?.finish("Muse Code exited (\(code)) before removing its session.") }
            do {
                try transport.start(executable: executableOverride ?? CodingProcess.executable("muse"), arguments: ["serve"], directory: FileManager.default.homeDirectoryForCurrentUser, environment: environment ?? CodingMuse.environment())
                try transport.send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["clientInfo": ["name": "tsukumo", "title": "Tsukumo", "version": "1.0.0"]]])
            } catch { finish(error.localizedDescription); return }
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30)); guard !Task.isCancelled else { return }
                self?.finish("Muse Code didn't answer in time.")
            }
        }
    }
    private func receive(_ object: [String: Any]) {
        let id = (object["id"] as? Int) ?? (object["id"] as? NSNumber)?.intValue
        if id == 1 {
            try? transport.send(["jsonrpc": "2.0", "method": "initialized"])
            command = CodingMuse.uuid7()
            try? transport.send(["jsonrpc": "2.0", "id": 2, "method": "session/delete", "params": ["commandId": command, "sessionId": sessionID]])
        } else if id == 2, let error = object["error"] as? [String: Any] {
            let kind = (error["data"] as? [String: Any])?["kind"] as? String
            finish(kind == "sessionNotFound" || kind == "notFound" ? nil : "Muse Code couldn't remove its session: " + (error["message"] as? String ?? ""))
        } else if object["method"] as? String == "session/deleteCompleted", let params = object["params"] as? [String: Any], params["commandId"] as? String == command {
            switch params["outcome"] as? String {
            case "completed": finish(nil)
            default:
                let reason = params["reason"] as? String ?? "unknown"
                if params["physicalChange"] as? String == "confirmed" { finish(nil) }   // Removed; only Muse's own bookkeeping was left.
                else if reason == "ownershipUnavailable" {
                    // Checked with Muse Code 1.4.0: only the `muse serve` host that started a session may delete it.
                    finish("Muse Code kept its saved session: it lets only the Muse host that started a session delete it (ownershipUnavailable).")
                } else { finish("Muse Code couldn't remove its session (\(reason)).") }
            }
        }
    }
    private func finish(_ problem: String?) {
        guard let done else { return }
        self.done = nil; timeout?.cancel()
        transport.onExit = nil; transport.stop()
        done.resume(returning: problem.map { "The task was deleted. " + $0 })
    }
}

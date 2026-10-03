import Foundation

struct CodingApproval: Identifiable {
    var id: String
    var title: String
    var detail: String
    var questions: [(id: String, text: String)] = []
    /// What kind of request: a command to run, file changes, or questions for the person.
    var kind: Kind = .command
    enum Kind { case command, files, question }
    /// The shell command to run, when it is one (for the risk check and the popup).
    var command: String?
    /// The proposed edit as a unified diff, when the agent says what it will change.
    var diff: String = ""
    /// Requests still waiting behind this one, including it.
    var pending = 1
    /// The agent's own name for the tool, when it says ("mcp__kemosabe__ask_kemosabe", "web_search"),
    /// so a KemoSabe chat can tell asking KemoSabe from anything else (`KemoSabeHandoff.decision`).
    var tool: String? = nil
    /// Commands that can destroy work or reach outside the task: never allowed by a default key.
    var risk: CodingApprovalRisk { CodingApprovalRisk.assess(command: command, kind: kind) }
}
/// What one message to an agent carries: the text, and images attached to it (files on disk).
struct CodingTurnInput: Equatable {
    var text: String
    var images: [URL] = []
    /// Context the owner handed over from KemoSabe (`ContextPacket`): exactly what the policy allowed
    /// for this agent. It goes ahead of `text` to the agent; the transcript shows it as a note.
    var context: String? = nil
    /// Where `context` came from, for the note ("your chat “Dinner plans”").
    var contextOrigin: String? = nil
}
/// What each agent's protocol lets Tsukumo do, so the composer offers only what really works.
struct CodingAgentCapabilities: Equatable {
    /// Add a message to the turn that's running (Codex `turn/steer`).
    var steer: Bool
    var images: Bool
    /// The agent summarizes its own context on request (Codex `thread/compact/start`; Claude Code's `/compact`).
    var compact: Bool
    /// The agent reviews the task's uncommitted changes (Codex `review/start`; a prompt for Claude Code).
    var review: Bool
    var fork: Bool
    /// From the agent's adapter (Codex steers; Claude Code, ACP agents, and Muse's exec fallback don't).
    @MainActor static func of(_ provider: CodingProvider) -> Self { CodingAgentRegistry.shared.adapter(for: provider).capabilities }
}
/// What an agent reported about itself while running: its slash commands and current model, and,
/// for agents that only list models inside a session (ACP), its models and their efforts.
struct CodingAgentReport: Equatable {
    var commands: [String] = []
    var model: String?
    var models: [CodingAgentModel]?
    /// Whether it's signed in, when it said (an auth error, or a turn that worked).
    var signedIn: Bool?
}
@MainActor protocol AgentSession: AnyObject {
    var onEvent: ((CodingEvent, Bool) -> Void)? { get set }
    var onState: ((CodingTaskStatus) -> Void)? { get set }
    var onSession: ((String) -> Void)? { get set }
    var onApproval: ((CodingApproval?) -> Void)? { get set }
    var onReport: ((CodingAgentReport) -> Void)? { get set }
    func send(_ text: String) throws
    /// A message with attachments. Sessions that only take text send the text.
    func send(input: CodingTurnInput) throws
    /// Adds a message to the running turn, when the agent supports it; false when it doesn't.
    func steer(_ input: CodingTurnInput) throws -> Bool
    /// Ends the running turn through the agent's own protocol and keeps the session for the next message.
    func interrupt()
    /// Asks the agent to summarize its context.
    func compact() throws
    /// Asks the agent to review the task's uncommitted changes.
    func review() throws
    func respond(_ id: String, allow: Bool, answers: String) throws
    /// Allow once, allow for this session, or deny with an optional note to the agent.
    func respond(_ id: String, decision: CodingApprovalDecision, answers: String) throws
    func stop()
}
extension AgentSession {
    var onReport: ((CodingAgentReport) -> Void)? { get { nil } set {} }
    func send(input: CodingTurnInput) throws { try send(input.text) }
    func steer(_ input: CodingTurnInput) throws -> Bool { false }
    func interrupt() {}
    func compact() throws { try send("/compact") }
    func review() throws { try send(CodingAgentSession.reviewPrompt) }
    func respond(_ id: String, decision: CodingApprovalDecision, answers: String) throws { try respond(id, allow: decision.allows, answers: answers) }
}

/// One process and one recipient per task; provider handles never cross tasks.
@MainActor final class CodingAgentSession: AgentSession {
    var onEvent: ((CodingEvent, Bool) -> Void)?
    var onState: ((CodingTaskStatus) -> Void)?
    var onSession: ((String) -> Void)?
    var onApproval: ((CodingApproval?) -> Void)?
    var onReport: ((CodingAgentReport) -> Void)?
    private let task: CodingTaskRecord
    private let executableOverride: URL?
    private let transport: CodingProcess
    /// How long a provider gets to wind down after an interrupt before its process group is ended.
    private let interruptGrace: TimeInterval
    private var sessionID: String?
    private var turnID: String?
    private var initialized = false
    private var starting = false
    private var active = false
    /// Claude Code's live background tasks (subagents and commands it backgrounded), by task ID.
    /// They keep running, and keep asking for approval, after the turn that started them ends.
    private var background: [String: String] = [:]
    /// Set by `stop()`: the session is finished and reports nothing more.
    private var stopped = false
    /// An internal failure ended the process; its remaining output is dropped until it exits.
    private var aborting = false
    /// The interrupt request sent by `stop()`, whose answer means the provider has wound down.
    private var interruptID: String?
    /// `interrupt()` asked the running turn to end; its end is reported as interrupted.
    private var interrupting = false
    private var sequence = 0
    private var requests: [String: String] = [:]
    private var approvals: [String: [String: Any]] = [:]
    private var approvalOrder: [String] = []
    private var pending: Pending?
    private var claudeMessageID = ""
    /// Codex file-change items' diffs by item ID, for the approval that asks to apply them.
    private var fileDiffs: [String: String] = [:]
    /// The streamed message's blocks: stream index → event ID, and how many of each type started.
    private var streamBlocks: [Int: String] = [:]
    private var streamCounts: [String: Int] = [:]
    /// Complete blocks seen per message and type, for messages sent one block at a time.
    private var finalCounts: [String: Int] = [:]
    /// A streamed block's event ID: the message, the block's type, and its place among blocks of that type.
    private func streamBlock(_ index: Int, type: String) -> String {
        if let id = streamBlocks[index] { return id }
        let id = "\(claudeMessageID)-\(type)-\(streamCounts[type, default: 0])"
        streamCounts[type, default: 0] += 1; streamBlocks[index] = id
        return id
    }
    /// The same ID for a complete block, whether Claude Code sends a message's blocks together
    /// (their place among blocks of their type in it) or one message per block (counted as they come).
    static func claudeBlockID(message: String, type: String, blocks: Int, ordinal: inout [String: Int], seen: inout [String: Int]) -> String {
        let place: Int
        if blocks == 1 { place = seen[message + "|" + type, default: 0]; seen[message + "|" + type, default: 0] += 1 }
        else { place = ordinal[type, default: 0]; ordinal[type, default: 0] += 1 }
        return "\(message)-\(type)-\(place)"
    }
    /// When each tool call started, for its card's duration (Claude Code reports none).
    private var toolStarts: [String: Date] = [:]
    private var deadline: Task<Void, Never>?
    /// What starts once the agent's thread is ready.
    private enum Pending { case turn(CodingTurnInput), compact, review }
    /// A KemoSabe chat hand-off (`KemoSabeHandoff`): its ID goes to the KemoSabe MCP server, and its
    /// own flags (Claude Code's allowed tools and strict MCP config; Codex's features turned off)
    /// follow each agent's own.
    var handoff: String?
    var extraClaudeArguments: [String] = []
    var extraCodexArguments: [String] = []
    init(task: CodingTaskRecord, executableOverride: URL? = nil, interruptGrace: TimeInterval = 3, terminationGrace: TimeInterval = 3) {
        self.executableOverride = executableOverride
        self.interruptGrace = interruptGrace
        transport = CodingProcess(grace: terminationGrace)
        self.task = task; sessionID = task.sessionID
        transport.onJSON = { [weak self] in self?.receive($0) }
        transport.onError = { [weak self] text in
            guard let self, !stopped, !aborting else { return }
            emit(.system, "Agent diagnostic", detail: String(text.prefix(4000)))
        }
        transport.onExit = { [weak self] code in
            guard let self, !stopped else { return }
            deadline?.cancel(); initialized = false; starting = false; turnID = nil; requests.removeAll()
            if aborting { aborting = false; return }
            let lingering = !background.isEmpty || !approvals.isEmpty
            if active { onState?(code == 0 || interrupting ? .interrupted : .failed) } else if lingering { onState?(.interrupted) }
            active = false; interrupting = false; onApproval?(nil); approvals.removeAll(); approvalOrder.removeAll(); background.removeAll()
            emit(.system, "Agent disconnected", detail: "Exit \(code). Send a message to resume its saved session.")
        }
    }
    static let reviewPrompt = "Review the uncommitted changes in this folder against its base commit, as a careful code reviewer: list bugs, risks, and missing tests by file and line, most important first. Don't change any files."
    func send(_ text: String) throws { try send(input: .init(text: text)) }
    func send(input: CodingTurnInput) throws { try begin(.turn(input)) }
    func compact() throws {
        if task.provider == .claude { try begin(.turn(.init(text: "/compact"))) } else { try begin(.compact) }
    }
    func review() throws {
        if task.provider == .claude { try begin(.turn(.init(text: Self.reviewPrompt))) } else { try begin(.review) }
    }
    private func begin(_ action: Pending) throws {
        guard !stopped else { throw CodingFailure("This agent session was stopped.") }
        guard !aborting else { throw CodingFailure("The agent is still shutting down. Try again in a moment.") }
        guard !active, !starting else { throw CodingFailure("Wait for this turn or stop it before sending another message.") }
        active = true; interrupting = false; onState?(.working)
        do {
            if !transport.running {
                pending = action; starting = true
                if task.provider == .codex {
                    try transport.start(executable: (executableOverride ?? CodingProcess.executable("codex")), arguments: Self.codexArguments(handoff: handoff, extra: extraCodexArguments), directory: URL(fileURLWithPath: task.directory))
                    try request("initialize", ["clientInfo": ["name": "tsukumo", "version": "1.0.0"], "capabilities": ["experimentalApi": true]])
                } else {
                    try transport.start(executable: (executableOverride ?? CodingProcess.executable("claude")),
                                        arguments: Self.claudeArguments(for: task, resume: sessionID, handoff: handoff) + extraClaudeArguments,
                                        directory: URL(fileURLWithPath: task.directory))
                    starting = false; initialized = true; pending = nil
                    try perform(action)
                }
                deadline = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(45))
                    guard !Task.isCancelled, let self, self.starting, !self.stopped else { return }
                    abort("Agent handshake timed out")
                }
            } else { try perform(action) }
        } catch { active = false; starting = false; onState?(.failed); aborting = transport.running; transport.stop(); throw error }
    }
    private func perform(_ action: Pending) throws {
        switch action {
        case .turn(let input): if task.provider == .codex { try codexTurn(input) } else { try claudeTurn(input) }
        case .compact:
            guard let sessionID else { throw CodingFailure("Codex did not return a thread ID.") }
            try request("thread/compact/start", ["threadId": sessionID])
        case .review:
            guard let sessionID else { throw CodingFailure("Codex did not return a thread ID.") }
            try request("review/start", ["threadId": sessionID, "target": ["type": "uncommittedChanges"]])
        }
    }
    /// Claude Code's headless streaming mode, checked against the installed 2.1.282 on
    /// September 25, 2026 (`claude --help` and the CLI's own option handling):
    /// - `--permission-prompt-tool stdio` is what routes a prompt ("ask") to this app as a
    ///   `can_use_tool` control request on stdout, answered with a `control_response` on stdin. It's
    ///   the flag the Agent SDK passes, and it's hidden from `--help`. Without it, `-p` answers a
    ///   prompt only through PermissionRequest hooks and otherwise denies it, so approvals never
    ///   reached Tsukumo.
    /// - `--permission-prompts host` (listed in `--help`; "host" is the default, the other choice
    ///   is "none", which denies every prompt) is kept explicit so a changed default can't turn
    ///   approvals off.
    /// - `--permission-mode` choices are acceptEdits, auto, bypassPermissions, manual, dontAsk, and
    ///   plan; `manual` is the CLI's name for the SDK's `default` mode (asks before edits and
    ///   commands). Auto-edit is `acceptEdits`. Bypass also needs
    ///   `--allow-dangerously-skip-permissions`. Read only is plan mode with read tools only: the
    ///   provider's permissions, not an OS sandbox.
    /// - `--effort` takes low, medium, high, xhigh, or max (listed in `--help`).
    /// - A fork resumes the source session with `--fork-session` (a new session ID) and
    ///   `--resume-session-at <message UUID>` (hidden from `--help`; print mode only), which keeps
    ///   the conversation up to and including that message.
    /// - An `interrupt` control request on stdin is handled in this mode (see `stop()` and `interrupt()`).
    static func claudeArguments(for task: CodingTaskRecord, resume sessionID: String?, handoff: String? = nil) -> [String] {
        let mode: String
        switch task.access { case .readOnly: mode = "plan"; case .edit: mode = "manual"; case .autoEdit: mode = "acceptEdits"; case .full: mode = "bypassPermissions" }
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                    "--permission-mode", mode, "--permission-prompt-tool", "stdio", "--permission-prompts", "host"]
        if task.access == .full { args += ["--allow-dangerously-skip-permissions"] }
        if task.access == .readOnly { args += ["--tools", "Read,Grep,Glob"] }
        if !task.model.isEmpty { args += ["--model", task.model] }
        if let effort = task.effort, !effort.isEmpty { args += ["--effort", effort] }
        if let sessionID { args += ["--resume", sessionID] }
        else if let fork = task.fork { args += ["--resume", fork.sessionID, "--fork-session", "--resume-session-at", fork.ref] }
        // The KemoSabe MCP server, for this session only (design/CONTEXT-HARNESS.md#agents-asking-kemosabe).
        args += KemoSabeMCP.claudeLaunchArguments(handoff: handoff)
        return args
    }
    /// `codex app-server` over stdio, with the KemoSabe MCP server (named for a chat hand-off) and any
    /// extra config overrides after it.
    static func codexArguments(handoff: String? = nil, extra: [String] = []) -> [String] {
        ["app-server", "--listen", "stdio://"] + KemoSabeMCP.codexLaunchArguments(handoff: handoff) + extra
    }
    /// Codex app-server's thread settings for each access level: the sandbox it enforces and when it asks.
    static func codexPolicy(_ access: CodingAccess) -> (sandbox: String, approval: String) {
        switch access {
        case .readOnly: ("read-only", "on-request")
        case .edit: ("workspace-write", "untrusted")
        case .autoEdit: ("workspace-write", "on-request")
        case .full: ("danger-full-access", "never")
        }
    }
    /// What starts the task's Codex thread: a new thread, the saved one (after a relaunch), or a
    /// fork of another task's thread through the chosen turn.
    static func codexThreadRequest(for task: CodingTaskRecord, sessionID: String?) -> (method: String, params: [String: Any]) {
        let policy = codexPolicy(task.access)
        var params: [String: Any] = ["cwd": task.directory, "approvalPolicy": policy.approval, "sandbox": policy.sandbox]
        if !task.model.isEmpty { params["model"] = task.model }
        if let sessionID { params["threadId"] = sessionID; return ("thread/resume", params) }
        if let fork = task.fork { params["threadId"] = fork.sessionID; params["lastTurnId"] = fork.ref; return ("thread/fork", params) }
        return ("thread/start", params)
    }
    /// A Codex turn's input: the text, then each image by its path on disk.
    static func codexInput(_ input: CodingTurnInput) -> [[String: Any]] {
        [["type": "text", "text": input.text, "text_elements": [Any]()]] + input.images.map { ["type": "localImage", "path": $0.path] }
    }
    /// A Claude Code user message: plain text, or text and images as content blocks (base64, as the Messages API takes them).
    static func claudeMessage(_ input: CodingTurnInput, sessionID: String?) -> [String: Any] {
        var content: Any = input.text
        if !input.images.isEmpty {
            var blocks: [[String: Any]] = input.images.compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return ["type": "image", "source": ["type": "base64", "media_type": mediaType(url), "data": data.base64EncodedString()]]
            }
            blocks.append(["type": "text", "text": input.text])
            content = blocks
        }
        return ["type": "user", "message": ["role": "user", "content": content], "parent_tool_use_id": NSNull(), "session_id": sessionID ?? ""]
    }
    static func mediaType(_ url: URL) -> String {
        switch url.pathExtension.lowercased() { case "jpg", "jpeg": "image/jpeg"; case "gif": "image/gif"; case "webp": "image/webp"; default: "image/png" }
    }
    private func request(_ method: String, _ params: [String: Any]) throws {
        sequence += 1; let id = "tsukumo-\(sequence)"; requests[id] = method
        try transport.send(["id": id, "method": method, "params": params])
    }
    private func codexTurn(_ input: CodingTurnInput) throws {
        guard let sessionID else { throw CodingFailure("Codex did not return a thread ID.") }
        var params: [String: Any] = ["threadId": sessionID, "input": Self.codexInput(input)]
        if !task.model.isEmpty { params["model"] = task.model }
        if let effort = task.effort, !effort.isEmpty { params["effort"] = effort }
        try request("turn/start", params)
    }
    private func claudeTurn(_ input: CodingTurnInput) throws {
        try transport.send(Self.claudeMessage(input, sessionID: sessionID))
    }
    /// Codex adds the message to the running turn (`turn/steer`, which must name that turn).
    func steer(_ input: CodingTurnInput) throws -> Bool {
        guard task.provider == .codex, !stopped, active, initialized, let sessionID, let turnID else { return false }
        try request("turn/steer", ["threadId": sessionID, "expectedTurnId": turnID, "input": Self.codexInput(input)])
        return true
    }
    /// Ends the running turn and keeps the agent for the next message (Esc). Codex answers with
    /// `turn/completed` (interrupted); Claude Code with a `result`.
    func interrupt() {
        guard !stopped, !aborting, transport.running else { return }
        if !active, task.provider == .claude, !background.isEmpty {
            // The turn is over but its background agents still run: stop each of them.
            for id in background.keys {
                sequence += 1
                try? transport.send(["type": "control_request", "request_id": "tsukumo-stop-\(sequence)", "request": ["subtype": "stop_task", "task_id": id]])
            }
            return
        }
        guard active else { return }
        interrupting = true
        do {
            if task.provider == .codex {
                guard let sessionID, let turnID else { return }
                sequence += 1
                try transport.send(["id": "tsukumo-\(sequence)", "method": "turn/interrupt", "params": ["threadId": sessionID, "turnId": turnID]])
            } else {
                sequence += 1
                try transport.send(["type": "control_request", "request_id": "tsukumo-interrupt-\(sequence)", "request": ["subtype": "interrupt"]])
            }
        } catch { abort("Couldn't interrupt the agent", detail: error.localizedDescription) }
    }
    /// Stops for good. A running turn is interrupted through the provider's own protocol first
    /// (Codex `turn/interrupt`; Claude Code's stream-json `interrupt` control request), so it can
    /// save its session; then, once it answers or `interruptGrace` passes, the whole process
    /// group gets SIGTERM and, after the termination grace, SIGKILL. Nothing is reported after a
    /// stop: whoever stopped the session records that itself.
    func stop() {
        guard !stopped else { return }
        stopped = true
        deadline?.cancel(); pending = nil; starting = false; approvals.removeAll(); approvalOrder.removeAll()
        onEvent = nil; onState = nil; onSession = nil; onApproval = nil; onReport = nil
        guard transport.running else { return }
        let interrupted = active && !aborting && sendStopInterrupt()
        active = false
        if interrupted { transport.shutdown(after: interruptGrace) } else { transport.stop() }
    }
    private func sendStopInterrupt() -> Bool {
        do {
            if task.provider == .codex {
                guard initialized, let sessionID, let turnID else { return false }
                sequence += 1; let id = "tsukumo-\(sequence)"; interruptID = id
                try transport.send(["id": id, "method": "turn/interrupt", "params": ["threadId": sessionID, "turnId": turnID]])
            } else {
                sequence += 1; let id = "tsukumo-interrupt-\(sequence)"; interruptID = id
                try transport.send(["type": "control_request", "request_id": id, "request": ["subtype": "interrupt"]])
            }
            return true
        } catch { return false }
    }
    /// After a stop, output is read only to learn that the provider finished winding down.
    private func woundDown(_ object: [String: Any]) -> Bool {
        if let interruptID, object["id"] as? String == interruptID { return true }
        if let response = object["response"] as? [String: Any], let interruptID, response["request_id"] as? String == interruptID { return true }
        return object["method"] as? String == "turn/completed" || object["type"] as? String == "result"
    }
    /// An internal failure (protocol error, handshake timeout): reported once, then the process
    /// group is ended and its remaining output ignored. A later message starts a fresh process.
    private func abort(_ message: String, detail: String = "") {
        emit(.system, message, detail: detail)
        deadline?.cancel(); pending = nil; starting = false; active = false; interrupting = false
        approvals.removeAll(); approvalOrder.removeAll(); onApproval?(nil); onState?(.failed)
        aborting = transport.running; transport.stop()
    }
    func respond(_ id: String, allow: Bool, answers: String = "") throws {
        try respond(id, decision: allow ? .allowOnce : .deny(note: ""), answers: answers)
    }
    func respond(_ id: String, decision: CodingApprovalDecision, answers: String) throws {
        guard let entry = approvals[id] else { throw CodingFailure("This request is no longer active.") }
        if task.provider == .codex {
            let params = entry["params"] as? [String: Any] ?? [:]
            try transport.send(["id": entry["id"]!, "result": Self.codexApprovalResult(params: params, decision: decision, answers: answers)])
        } else {
            let request = entry["request"] as? [String: Any] ?? [:]
            try transport.send(["type": "control_response", "response": ["subtype": "success", "request_id": id, "response": Self.claudeApprovalResponse(request: request, decision: decision)]])
        }
        approvals.removeValue(forKey: id); approvalOrder.removeAll { $0 == id }
        if approvalOrder.isEmpty { onApproval?(nil); onState?(active || !background.isEmpty ? .working : .review) }
        emit(.approval, decision.summary, detail: decision.note.isEmpty ? id : "Note to the agent: " + decision.note)
        // Codex's decline has no message: the note follows as a message added to the running turn.
        if task.provider == .codex, !decision.note.isEmpty, let sessionID, let turnID {
            try? request("turn/steer", ["threadId": sessionID, "expectedTurnId": turnID, "input": Self.codexInput(.init(text: decision.note))])
        }
        showFirstApproval()
    }
    /// Codex's answer: `accept`, `acceptForSession`, or `decline`; questions get their answers.
    /// Claude Code's live background tasks after a system message: `background_tasks_changed`
    /// replaces the whole set; `task_started` (backgrounded) adds one; `task_notification` (the
    /// task completed, failed, or stopped) removes it.
    static func claudeBackground(_ current: [String: String], _ object: [String: Any]) -> [String: String] {
        var tasks = current
        switch object["subtype"] as? String {
        case "background_tasks_changed":
            tasks = [:]
            for task in object["tasks"] as? [[String: Any]] ?? [] {
                if let id = task["task_id"] as? String { tasks[id] = task["description"] as? String ?? "" }
            }
        case "task_started":
            if object["is_backgrounded"] as? Bool == true, let id = object["task_id"] as? String { tasks[id] = object["description"] as? String ?? "" }
        case "task_notification":
            if let id = object["task_id"] as? String { tasks.removeValue(forKey: id) }
        default: break
        }
        return tasks
    }
    static func codexApprovalResult(params: [String: Any], decision: CodingApprovalDecision, answers: String) -> [String: Any] {
        let questions = params["questions"] as? [[String: Any]] ?? []
        guard questions.isEmpty else {
            return ["answers": Dictionary(uniqueKeysWithValues: questions.compactMap { question -> (String, Any)? in
                guard let key = question["id"] as? String else { return nil }
                return (key, ["answers": [decision.allows ? answers : "Declined"]])
            })]
        }
        switch decision {
        case .allowOnce: return ["decision": "accept"]
        case .allowSession: return ["decision": "acceptForSession"]
        case .deny: return ["decision": "decline"]
        }
    }
    /// Claude Code's answer to `can_use_tool`. Allow for this session adds the CLI's own suggested
    /// rules with their destination set to `session`, so nothing is written to a settings file;
    /// without suggestions, a shell command is allowed only as that exact command. A denial
    /// carries your note, or a plain one.
    static func claudeApprovalResponse(request: [String: Any], decision: CodingApprovalDecision) -> [String: Any] {
        switch decision {
        case .deny(let note):
            return ["behavior": "deny", "message": note.isEmpty ? "Denied by the user in Tsukumo." : "Denied by the user in Tsukumo: " + note]
        case .allowOnce, .allowSession:
            var response: [String: Any] = ["behavior": "allow", "updatedInput": request["input"] ?? [String: Any]()]
            if decision == .allowSession { response["updatedPermissions"] = sessionPermissions(request) }
            return response
        }
    }
    static func sessionPermissions(_ request: [String: Any]) -> [[String: Any]] {
        let suggestions = (request["permission_suggestions"] as? [[String: Any]] ?? []).map { suggestion -> [String: Any] in
            var rule = suggestion; rule["destination"] = "session"; return rule
        }
        if !suggestions.isEmpty { return suggestions }
        let tool = request["tool_name"] as? String ?? ""
        var rule: [String: Any] = ["toolName": tool]
        if tool == "Bash", let command = (request["input"] as? [String: Any])?["command"] as? String { rule["ruleContent"] = command }
        return [["type": "addRules", "rules": [rule], "behavior": "allow", "destination": "session"]]
    }
    private func emit(_ kind: CodingEvent.Kind, _ text: String, detail: String = "", id: String? = nil, status: String = "", exit: Int? = nil, append: Bool = false) {
        // Full text: the task log keeps it all (frames are bounded by the transport); only the view is capped.
        onEvent?(.init(id: id ?? UUID().uuidString, kind: kind, text: text, detail: detail, status: status, exitCode: exit), append)
    }
    private func emit(_ event: CodingEvent, append: Bool = false) { onEvent?(event, append) }
    private func receive(_ object: [String: Any]) {
        if stopped { if woundDown(object) { transport.stop() }; return }
        guard !aborting else { return }
        do { if task.provider == .codex { try codex(object) } else { try claude(object) } }
        catch { abort("Agent protocol error", detail: error.localizedDescription) }
    }
    private func finishTurn(_ state: CodingTaskStatus) {
        active = false; turnID = nil
        let interrupted = interrupting; interrupting = false
        // Claude Code's background agents outlive the turn's `result` and keep asking for
        // approval; their requests stay answerable and the task keeps working until they end.
        if task.provider == .claude, state == .review, !interrupted, !approvals.isEmpty || !background.isEmpty {
            if approvals.isEmpty { onState?(.working) } else { showFirstApproval() }
            return
        }
        approvals.removeAll(); approvalOrder.removeAll(); onApproval?(nil)
        onState?(interrupted && state != .review ? .interrupted : state)
    }
    /// A background task started or ended. When the turn is over and nothing is left running or
    /// waiting, the task is ready for review.
    private func backgroundChanged() {
        guard !active, approvals.isEmpty else { return }
        onState?(background.isEmpty ? .review : .working)
    }
    private func codex(_ object: [String: Any]) throws {
        if let id = object["id"] as? String, let method = requests.removeValue(forKey: id) {
            if let error = object["error"] as? [String: Any] {
                // A steer that arrived as the turn ended is reported, not fatal.
                if method == "turn/steer" { emit(.system, "Couldn't add to the running turn", detail: error["message"] as? String ?? ""); return }
                throw CodingFailure(error["message"] as? String ?? "Codex request failed")
            }
            let result = object["result"] as? [String: Any] ?? [:]
            switch method {
            case "initialize":
                try transport.send(["method": "initialized"])
                let start = Self.codexThreadRequest(for: task, sessionID: sessionID)
                try request(start.method, start.params)
            case "thread/start", "thread/resume", "thread/fork":
                guard let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String else { throw CodingFailure("Missing Codex thread ID") }
                sessionID = id; onSession?(id); initialized = true; starting = false; deadline?.cancel()
                if let action = pending { pending = nil; try perform(action) }
            case "turn/start", "review/start": turnID = (result["turn"] as? [String: Any])?["id"] as? String ?? turnID
            default: break
            }
            return
        }
        guard let method = object["method"] as? String else { return }
        let params = object["params"] as? [String: Any] ?? [:]
        if let id = object["id"] {
            let key = String(describing: id)
            if method == "item/commandExecution/requestApproval" || method == "item/fileChange/requestApproval" || method == "item/tool/requestUserInput" {
                enqueueApproval(key, object)
            } else {
                try transport.send(["id": id, "error": ["code": -32601, "message": "Tsukumo does not support this request yet."]])
                emit(.system, "Unsupported agent request", detail: method)
            }
            return
        }
        // Subagent notifications are shown as collaboration events, not merged into the parent's conversation.
        if let thread = params["threadId"] as? String, let sessionID, thread != sessionID { return }
        switch method {
        case "turn/started": turnID = (params["turn"] as? [String: Any])?["id"] as? String ?? turnID
        case "item/agentMessage/delta":
            var event = CodingEvent(id: params["itemId"] as? String ?? UUID().uuidString, kind: .assistant, text: params["delta"] as? String ?? "")
            event.ref = turnID; emit(event, append: true)
        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
            emit(.reasoning, params["delta"] as? String ?? "", id: params["itemId"] as? String, append: true)
        case "item/reasoning/summaryPartAdded":
            emit(.reasoning, "\n\n", id: params["itemId"] as? String, append: true)
        case "item/commandExecution/outputDelta": emit(.command, "", detail: params["delta"] as? String ?? "", id: params["itemId"] as? String, append: true)
        case "item/started", "item/completed":
            if let item = params["item"] as? [String: Any] { codexItem(item) }
        case "turn/plan/updated":
            let steps = params["plan"] as? [[String: Any]] ?? []
            var event = CodingEvent(id: "plan-" + (turnID ?? "turn"), kind: .plan, text: "Plan", detail: steps.map { "\($0["status"] ?? "") · \($0["step"] ?? "")" }.joined(separator: "\n"))
            if let explanation = params["explanation"] as? String, !explanation.isEmpty { event.output = explanation }
            emit(event)
        case "thread/compacted": emit(.system, "Context compacted", detail: "Codex summarized the conversation so far to free up its context.")
        case "turn/completed":
            let turn = params["turn"] as? [String: Any] ?? [:]
            let status = turn["status"] as? String
            if let error = turn["error"] as? [String: Any] { emit(.system, "Turn failed", detail: error["message"] as? String ?? "Unknown failure") }
            finishTurn(status == "completed" ? .review : status == "interrupted" ? .interrupted : .failed)
        case "error": emit(.system, "Codex error", detail: String(describing: params["error"] ?? params))
        default: break
        }
    }
    private func codexItem(_ item: [String: Any]) {
        let id = item["id"] as? String ?? UUID().uuidString, type = item["type"] as? String ?? ""
        let status = item["status"] as? String ?? ""
        var event: CodingEvent
        switch type {
        case "agentMessage": event = .init(id: id, kind: .assistant, text: item["text"] as? String ?? ""); event.ref = turnID
        case "reasoning": event = .init(id: id, kind: .reasoning, text: CodingChatEvents.codexReasoning(item))
        case "commandExecution":
            event = .init(id: id, kind: .command, text: item["command"] as? String ?? "Command", detail: item["aggregatedOutput"] as? String ?? "", status: status, exitCode: item["exitCode"] as? Int, tool: "commandExecution")
            if let ms = item["durationMs"] as? Double { event.duration = ms / 1000 } else if let ms = item["durationMs"] as? Int { event.duration = Double(ms) / 1000 }
        case "fileChange":
            let changes = item["changes"] as? [[String: Any]] ?? []
            let paths = CodingChatEvents.codexPaths(changes, directory: task.directory)
            event = .init(id: id, kind: .file, text: paths.count == 1 ? paths[0] : "\(paths.count) files", detail: CodingChatEvents.codexFileDiff(changes, directory: task.directory), status: status, tool: "fileChange")
            if !event.detail.isEmpty { fileDiffs[id] = event.detail }
        case "plan": event = .init(id: id, kind: .plan, text: "Plan", detail: item["text"] as? String ?? "")
        case "collabAgentToolCall", "subAgentActivity":
            event = .init(id: id, kind: .collaboration, text: item["tool"] as? String ?? "Agent activity", detail: String(describing: item), status: status)
        case "mcpToolCall", "dynamicToolCall":
            event = .init(id: id, kind: .command, text: ((item["server"] as? String).map { $0 + " · " } ?? "") + (item["tool"] as? String ?? "Tool"), detail: String(describing: item["arguments"] ?? ""), status: status, tool: type)
            if let ms = item["durationMs"] as? Int { event.duration = Double(ms) / 1000 }
        case "webSearch": event = .init(id: id, kind: .command, text: "Search the web for “\(item["query"] as? String ?? "")”", status: status, tool: type)
        case "enteredReviewMode": event = .init(id: id, kind: .system, text: "Reviewing changes", detail: item["review"] as? String ?? "")
        case "exitedReviewMode": event = .init(id: id, kind: .assistant, text: item["review"] as? String ?? ""); event.ref = turnID
        case "contextCompaction": event = .init(id: id, kind: .system, text: "Context compacted")
        default: return
        }
        emit(event)
    }
    /// Requests wait in the order they came; the first is shown, with how many are waiting.
    private func enqueueApproval(_ key: String, _ object: [String: Any]) {
        approvals[key] = object
        if !approvalOrder.contains(key) { approvalOrder.append(key) }
        showFirstApproval()
    }
    private func showFirstApproval() {
        guard let key = approvalOrder.first, let object = approvals[key] else { return }
        presentApproval(key, object)
    }
    private func presentApproval(_ key: String, _ object: [String: Any]) {
        let params = object["params"] as? [String: Any] ?? object["request"] as? [String: Any] ?? [:]
        onApproval?(Self.approval(key: key, method: object["method"] as? String ?? "", params: params, directory: task.directory, fileDiffs: fileDiffs, pending: approvals.count))
        onState?(.needsInput)
    }
    /// What the popup shows for a request from either agent: the command, or the files with the
    /// diff (Claude Code's edit input; Codex's patch from the file-change item it belongs to).
    static func approval(key: String, method: String, params: [String: Any], directory: String, fileDiffs: [String: String] = [:], pending: Int = 1) -> CodingApproval {
        let questions = (params["questions"] as? [[String: Any]] ?? []).compactMap { q -> (String, String)? in
            guard let id = q["id"] as? String, let text = q["question"] as? String else { return nil }; return (id, text)
        }
        let tool = params["tool_name"] as? String
        let input = params["input"] as? [String: Any] ?? [:]
        var command = params["command"] as? String
        var title = command.map(CodingChatEvents.displayCommand) ?? tool ?? (questions.isEmpty ? "Approve file changes" : "Agent needs your input")
        var kind: CodingApproval.Kind = questions.isEmpty ? (method == "item/fileChange/requestApproval" ? .files : .command) : .question
        var diff = kind == .files ? fileDiffs[params["itemId"] as? String ?? ""] ?? "" : ""
        if kind == .files, !diff.isEmpty {
            let paths = CodingDiff.parse(diff).map(\.path)
            title = paths.count == 1 ? paths[0] : "\(paths.count) files"
        }
        if let tool {
            // Claude Code: show what the tool will do, not its raw input.
            if tool == "Bash", let text = input["command"] as? String { command = text; title = text }
            else if ["Edit", "MultiEdit", "Write", "NotebookEdit"].contains(tool) {
                kind = .files
                let card = CodingChatEvents.claudeTool(name: tool, input: input, id: key, directory: directory)
                title = card.text; diff = card.detail
            } else { title = CodingChatEvents.toolSummary(name: tool, input: input, directory: directory) }
        }
        let reason = params["reason"] as? String ?? params["decision_reason"] as? String
        let detail = reason ?? (input.isEmpty ? String(describing: params) : String(describing: input))
        return .init(id: key, title: title, detail: detail, questions: questions, kind: kind, command: command.map(CodingChatEvents.displayCommand), diff: diff, pending: max(1, pending), tool: tool)
    }
    private func claude(_ object: [String: Any]) throws {
        if let id = object["session_id"] as? String, !id.isEmpty, sessionID != id { sessionID = id; onSession?(id) }
        switch object["type"] as? String {
        case "system":
            if object["subtype"] as? String == "init" {
                onReport?(.init(commands: object["slash_commands"] as? [String] ?? [], model: object["model"] as? String))
            } else if let subtype = object["subtype"] as? String, ["background_tasks_changed", "task_started", "task_notification"].contains(subtype) {
                let before = background
                background = Self.claudeBackground(background, object)
                if background != before { backgroundChanged() }
            } else if object["subtype"] as? String == "compact_boundary" {
                emit(.system, "Context compacted", detail: "Claude Code summarized the conversation so far to free up its context.")
            }
        case "control_request":
            guard let id = object["request_id"] as? String, let request = object["request"] as? [String: Any] else { return }
            if request["subtype"] as? String == "can_use_tool" { enqueueApproval(id, object) }
            else { try transport.send(["type": "control_response", "response": ["subtype": "error", "request_id": id, "error": "Unsupported control request"]]) }
        case "stream_event":
            let event = object["event"] as? [String: Any] ?? [:]
            let index = event["index"] as? Int ?? 0
            switch event["type"] as? String {
            case "message_start":
                claudeMessageID = (event["message"] as? [String: Any])?["id"] as? String ?? UUID().uuidString
                streamBlocks = [:]; streamCounts = [:]
            case "content_block_start":
                if let type = (event["content_block"] as? [String: Any])?["type"] as? String { _ = streamBlock(index, type: type) }
            case "content_block_delta":
                guard let delta = event["delta"] as? [String: Any] else { break }
                if let text = delta["text"] as? String { emit(.assistant, text, id: streamBlock(index, type: "text"), append: true) }
                else if let thinking = delta["thinking"] as? String { emit(.reasoning, thinking, id: streamBlock(index, type: "thinking"), append: true) }
            default: break
            }
        case "assistant":
            let message = object["message"] as? [String: Any] ?? [:]
            let messageID = message["id"] as? String ?? UUID().uuidString
            let uuid = object["uuid"] as? String
            let blocks = message["content"] as? [[String: Any]] ?? []
            var ordinals: [String: Int] = [:]
            for block in blocks {
                let type = block["type"] as? String ?? ""
                let id = Self.claudeBlockID(message: messageID, type: type, blocks: blocks.count, ordinal: &ordinals, seen: &finalCounts)
                switch block["type"] as? String {
                case "text":
                    var event = CodingEvent(id: id, kind: .assistant, text: block["text"] as? String ?? ""); event.ref = uuid; emit(event)
                case "thinking":
                    let text = block["thinking"] as? String ?? ""
                    if !text.isEmpty { emit(.reasoning, text, id: id) }
                case "tool_use":
                    let toolID = block["id"] as? String ?? id
                    toolStarts[toolID] = Date()
                    var event = CodingChatEvents.claudeTool(name: block["name"] as? String ?? "Tool", input: block["input"] as? [String: Any] ?? [:], id: toolID, directory: task.directory)
                    event.ref = uuid; emit(event)
                default: break
                }
            }
        case "user":
            let message = object["message"] as? [String: Any] ?? [:]
            for block in message["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_result" {
                guard let toolID = block["tool_use_id"] as? String else { continue }
                let result = CodingChatEvents.claudeToolResult(block)
                var event = CodingEvent(id: toolID, kind: .command, text: "", status: result.failed ? "failed" : "completed")
                // Kind is kept from the tool's card by the merge; only the result fields are set here.
                event.output = result.text
                if let start = toolStarts.removeValue(forKey: toolID) { event.duration = Date().timeIntervalSince(start) }
                emit(event)
            }
        case "result":
            let failed = object["is_error"] as? Bool == true
            let interrupted = interrupting
            if !interrupted {
                var detail = failed ? String(describing: object["errors"] ?? object["result"] ?? "") : "Session saved by Claude Code."
                if !failed, let ms = object["duration_ms"] as? Double { detail = String(format: "%.1f s · ", ms / 1000) + detail }
                emit(.system, failed ? "Turn failed" : "Turn complete", detail: detail)
            } else { emit(.system, "Interrupted", detail: "The turn was stopped. Send a message to continue.") }
            finishTurn(failed ? .failed : .review)
        default: break
        }
    }
}

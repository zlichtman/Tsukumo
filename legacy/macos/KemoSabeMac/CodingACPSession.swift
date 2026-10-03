import Foundation
import Darwin

// The Agent Client Protocol (ACP) client: any agent that speaks ACP over stdio works in Tsukumo,
// with its messages, reasoning, tool cards, diffs, and plans in the task chat, and its
// permission requests in Tsukumo's permission popup.
//
// Pinned to protocol version 1, as published in the ACP repository's stable schema
// `schema/v1/schema.json` at tag `schema-v1.23.0` (September 18, 2026). Unstable methods
// (`session/fork`, elicitation, notices) aren't used. Implemented, agent side: `initialize`,
// `session/new`, `session/load` (history replay is skipped: the task already has it),
// `session/resume`, `session/prompt`, `session/cancel`, `session/set_mode`,
// `session/set_config_option` (models and thought levels), `session/delete`; client side:
// `session/update`, `session/request_permission`, `fs/read_text_file`, `fs/write_text_file`,
// and `terminal/create`, `terminal/output`, `terminal/wait_for_exit`, `terminal/kill`,
// `terminal/release`. File and terminal requests pass the same access gates as Tsukumo's other
// agents (`CodingAccessGate`): Read only refuses writes and commands, Ask first asks, Auto-edit
// writes inside the task's folder, Full access allows; a risky command never has a default.

enum CodingACP {
    /// The ACP protocol version this client speaks (the `initialize` handshake).
    static let protocolVersion = 1
    /// The schema release the implementation was checked against.
    static let schemaRelease = "schema-v1.23.0"

    // MARK: Pure mapping (tested against recorded shapes)

    /// A `tool_call` or `tool_call_update` as a card. Execute tools are shell commands; edit,
    /// delete, and move tools are file cards with a unified diff made from their `diff` content;
    /// everything else is a tool card with its title. An update without a kind keeps the card's
    /// kind (`CodingEvent.merged`).
    static func toolEvent(_ update: [String: Any], directory: String) -> CodingEvent {
        let id = update["toolCallId"] as? String ?? UUID().uuidString
        let kind = update["kind"] as? String
        let title = update["title"] as? String ?? ""
        let content = update["content"] as? [[String: Any]] ?? []
        let diffs = content.filter { $0["type"] as? String == "diff" }
        let text = content.compactMap { block -> String? in
            guard block["type"] as? String == "content", let inner = block["content"] as? [String: Any] else { return nil }
            return inner["text"] as? String
        }.joined(separator: "\n")
        var event: CodingEvent
        switch kind ?? "" {
        case "edit", "delete", "move":
            let paths = diffs.compactMap { $0["path"] as? String }.map { CodingChatEvents.relative($0, to: directory) }
            let located = (update["locations"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }.map { CodingChatEvents.relative($0, to: directory) }
            let all = paths.isEmpty ? located : paths
            let diff = diffs.map { entry -> String in
                let path = CodingChatEvents.relative(entry["path"] as? String ?? "", to: directory)
                let old = entry["oldText"] as? String
                return CodingChatEvents.unifiedDiff(path: path, hunks: [(old ?? "", entry["newText"] as? String ?? "")], added: old == nil)
            }.joined()
            event = .init(id: id, kind: .file, text: all.count == 1 ? all[0] : all.isEmpty ? title : "\(all.count) files", detail: diff, tool: "acp." + (kind ?? "edit"))
        case "execute":
            event = .init(id: id, kind: .command, text: command(update["rawInput"]) ?? title, tool: "commandExecution")
        case "":
            // An update: only what it carries.
            event = .init(id: id, kind: .command, text: title)
            if !diffs.isEmpty {
                event.detail = diffs.map { entry -> String in
                    let path = CodingChatEvents.relative(entry["path"] as? String ?? "", to: directory)
                    let old = entry["oldText"] as? String
                    return CodingChatEvents.unifiedDiff(path: path, hunks: [(old ?? "", entry["newText"] as? String ?? "")], added: old == nil)
                }.joined()
            }
        default:
            let tool = ["read": "Read", "search": "Grep", "fetch": "WebFetch"][kind ?? ""] ?? "acp." + (kind ?? "tool")
            event = .init(id: id, kind: .command, text: title, tool: tool)
        }
        if !text.isEmpty { event.output = text }
        event.status = status(update["status"] as? String)
        return event
    }
    static func status(_ acp: String?) -> String {
        switch acp { case "pending", "in_progress": "running"; case "completed": "completed"; case "failed": "failed"; default: "" }
    }
    /// A shell command from a tool's raw input: `command` as a string or an argv list (with `args`).
    static func command(_ raw: Any?) -> String? {
        guard let input = raw as? [String: Any] else { return nil }
        if let text = input["command"] as? String, !text.isEmpty {
            let args = input["args"] as? [String] ?? []
            return ([text] + args.map(shellQuote)).joined(separator: " ")
        }
        if let argv = (input["command"] as? [String]) ?? (input["argv"] as? [String]), !argv.isEmpty { return argv.map(shellQuote).joined(separator: " ") }
        if let cmd = input["cmd"] as? String, !cmd.isEmpty { return cmd }
        return nil
    }
    static func shellQuote(_ word: String) -> String {
        if word.isEmpty { return "''" }
        guard word.rangeOfCharacter(from: CharacterSet(charactersIn: " \t\n'\"\\$`*?![]{}()<>|&;#~")) != nil else { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    /// A `plan` update as the transcript's checklist ("status · step" per line).
    static func planEvent(_ entries: [[String: Any]], id: String) -> CodingEvent {
        let lines = entries.map { entry -> String in
            let status = entry["status"] as? String ?? "pending"
            return (status == "in_progress" ? "inProgress" : status) + " · " + (entry["content"] as? String ?? "")
        }
        return .init(id: id, kind: .plan, text: "Plan", detail: lines.joined(separator: "\n"))
    }
    /// The agent's mode for an access level, from the modes it offers (ids vary by agent:
    /// Cursor's agent/plan/ask, Claude Code's adapter's default/acceptEdits/bypassPermissions/plan,
    /// Gemini's default/autoEdit/yolo). Nil when none fits; the access gates still apply.
    static func modeID(for access: CodingAccess, available: [String]) -> String? {
        let preferences: [String]
        switch access {
        case .readOnly: preferences = ["plan", "read-only", "readonly", "read_only", "ask", "architect"]
        case .edit: preferences = ["default", "ask-first", "manual", "agent", "code"]
        case .autoEdit: preferences = ["acceptEdits", "auto-edit", "autoEdit", "auto_edit", "agent", "code", "default"]
        case .full: preferences = ["bypassPermissions", "yolo", "full-access", "full", "agent", "code", "default"]
        }
        let lowered = Dictionary(available.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        for preference in preferences { if let match = lowered[preference.lowercased()] { return match } }
        return nil
    }
    /// Session config options → the agent's models (a `model` select) and efforts (a
    /// `thought_level` select), with their option ids.
    struct Config: Equatable {
        var modelOption: String?
        var effortOption: String?
        var models: [CodingAgentModel] = []
        var currentModel: String?
        var currentEffort: String?
    }
    static func config(_ options: [[String: Any]]) -> Config {
        var config = Config()
        func values(_ option: [String: Any]) -> [(String, String)] {
            let raw = option["options"] as? [[String: Any]] ?? []
            let flat = raw.flatMap { entry -> [[String: Any]] in (entry["options"] as? [[String: Any]]).map { $0 } ?? [entry] }
            return flat.compactMap { entry in (entry["value"] as? String).map { ($0, entry["name"] as? String ?? $0) } }
        }
        var efforts: [String] = []
        for option in options where option["type"] as? String == "select" || option["options"] != nil {
            let category = option["category"] as? String
            let id = option["id"] as? String ?? ""
            if category == "model" || (category == nil && id.lowercased() == "model") {
                config.modelOption = id; config.currentModel = option["currentValue"] as? String
                config.models = values(option).map { .init(id: $0.0, name: $0.1) }
            } else if category == "thought_level" {
                config.effortOption = id; config.currentEffort = option["currentValue"] as? String
                efforts = values(option).map(\.0)
            }
        }
        if !efforts.isEmpty {
            if config.models.isEmpty { config.models = [.init(id: "", name: "Default", isDefault: true)] }
            config.models = config.models.map { var model = $0; model.efforts = efforts; model.defaultEffort = config.currentEffort; return model }
        }
        if let current = config.currentModel { config.models = config.models.map { var model = $0; model.isDefault = model.id == current; return model } }
        return config
    }
    /// The option to select for a decision: allow once, allow always (for the session), or
    /// reject. Nil means answer `cancelled`.
    static func option(for decision: CodingApprovalDecision, in options: [[String: Any]]) -> String? {
        func first(_ kinds: [String]) -> String? {
            for kind in kinds { if let match = options.first(where: { $0["kind"] as? String == kind })?["optionId"] as? String { return match } }
            return nil
        }
        switch decision {
        case .allowOnce: return first(["allow_once", "allow_always"])
        case .allowSession: return first(["allow_always", "allow_once"])
        case .deny: return first(["reject_once", "reject_always"])
        }
    }
    /// What the popup shows for a permission request.
    static func approval(key: String, toolCall: [String: Any], directory: String, pending: Int) -> CodingApproval {
        let card = toolEvent(toolCall, directory: directory)
        let kind = toolCall["kind"] as? String
        let raw = String(describing: toolCall["rawInput"] ?? "")
        switch kind {
        case "execute":
            let command = command(toolCall["rawInput"]) ?? (toolCall["title"] as? String ?? "")
            return .init(id: key, title: command, detail: raw, kind: .command, command: command, pending: pending)
        case "edit", "delete", "move":
            return .init(id: key, title: card.text.isEmpty ? (toolCall["title"] as? String ?? "Edit files") : card.text, detail: raw, kind: .files, diff: card.detail, pending: pending)
        default:
            return .init(id: key, title: toolCall["title"] as? String ?? "Use a tool", detail: raw, kind: .command, pending: pending,
                         tool: (toolCall["rawInput"] as? [String: Any])?["toolName"] as? String ?? toolCall["title"] as? String)
        }
    }
    /// A prompt's content blocks: the text, then images when the agent takes them.
    static func prompt(_ input: CodingTurnInput, images: Bool) -> [[String: Any]] {
        var blocks: [[String: Any]] = [["type": "text", "text": input.text]]
        guard images else { return blocks }
        for url in input.images {
            guard let data = try? Data(contentsOf: url) else { continue }
            blocks.append(["type": "image", "data": data.base64EncodedString(), "mimeType": CodingACP.mediaType(url)])
        }
        return blocks
    }
    static func mediaType(_ url: URL) -> String {
        switch url.pathExtension.lowercased() { case "jpg", "jpeg": "image/jpeg"; case "gif": "image/gif"; case "webp": "image/webp"; default: "image/png" }
    }
    /// `fs/read_text_file`'s `line` (1-based) and `limit`.
    static func slice(_ text: String, line: Int?, limit: Int?) -> String {
        guard line != nil || limit != nil else { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let start = max(0, (line ?? 1) - 1)
        guard start < lines.count else { return "" }
        let end = limit.map { min(lines.count, start + max(0, $0)) } ?? lines.count
        return lines[start..<end].joined(separator: "\n")
    }
    /// Keeps the last `limit` bytes, starting at a character boundary.
    static func truncate(_ data: Data, limit: Int) -> (Data, Bool) {
        guard data.count > limit else { return (data, false) }
        var tail = data.suffix(limit)
        while let first = tail.first, first & 0xC0 == 0x80 { tail = tail.dropFirst() }
        return (Data(tail), true)
    }
    /// Finds a program by name on the agent's PATH (or takes a path as given).
    static func resolve(_ command: String, environment: [String: String]) -> URL? {
        if command.contains("/") {
            let path = (command as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        for path in paths {
            let url = URL(fileURLWithPath: path).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }
}

/// How an ACP agent is started.
struct CodingACPLaunch: Equatable {
    var command: String
    var arguments: [String]
    var environment: CodingAgentEnvironment
    var name: String
    func executable(_ environment: [String: String]) throws -> URL {
        guard let url = CodingACP.resolve(command, environment: environment) else { throw CodingFailure("\(name) isn't installed: `\(command)` isn't on your PATH.") }
        return url
    }
}

/// One ACP agent process and one ACP session per task.
@MainActor final class CodingACPSession: AgentSession {
    var onEvent: ((CodingEvent, Bool) -> Void)?
    var onState: ((CodingTaskStatus) -> Void)?
    var onSession: ((String) -> Void)?
    var onApproval: ((CodingApproval?) -> Void)?
    var onReport: ((CodingAgentReport) -> Void)?
    private let task: CodingTaskRecord
    private let launch: CodingACPLaunch
    private let transport: CodingProcess
    private let interruptGrace: TimeInterval
    private var sessionID: String?
    private var starting = false, active = false, stopped = false, aborting = false, interrupting = false
    private var sequence = 0
    private var requests: [Int: String] = [:]
    /// Config requests sent before the first prompt; the prompt waits for their answers.
    private var configuring: Set<Int> = []
    private var pending: CodingTurnInput?
    private var deadline: Task<Void, Never>?
    // What the agent said it can do.
    private var canLoad = false, canResume = false, takesImages = false
    private var modes: [String] = []
    private var currentMode: String?
    private var config = CodingACP.Config()
    /// `session/load` replays the conversation; the task already has it, so it's skipped.
    private var replaying = false
    private var messageSeq = 0
    private var messageID = ""
    private var thoughtID = ""
    private var lastUpdate = ""
    /// Notes written when denying a request; ACP has no field for them, so they go with the next message.
    private var deniedNotes: [String] = []
    /// Requests waiting for the person, in order.
    private enum Waiting {
        case permission(id: Any, options: [[String: Any]])
        case read(id: Any, path: String, line: Int?, limit: Int?)
        case write(id: Any, path: String, content: String)
        case terminal(id: Any, params: [String: Any])
    }
    private var waiting: [String: (Waiting, CodingApproval)] = [:]
    private var order: [String] = []
    private var terminals: [String: CodingACPTerminal] = [:]
    /// Which tool card shows each terminal's output.
    private var terminalCards: [String: String] = [:]
    /// A KemoSabe chat hand-off (`KemoSabeHandoff`): its ID goes to the KemoSabe MCP server.
    var handoff: String?

    init(task: CodingTaskRecord, launch: CodingACPLaunch, interruptGrace: TimeInterval = 3, terminationGrace: TimeInterval = 3) {
        self.task = task; self.launch = launch; self.interruptGrace = interruptGrace
        transport = CodingProcess(grace: terminationGrace)
        sessionID = task.sessionID
        transport.onJSON = { [weak self] in self?.receive($0) }
        transport.onError = { [weak self] text in
            guard let self, !stopped, !aborting else { return }
            emit(.system, "Agent diagnostic", detail: String(text.prefix(4000)))
        }
        transport.onExit = { [weak self] code in
            guard let self, !stopped else { return }
            deadline?.cancel(); starting = false; requests.removeAll(); configuring.removeAll()
            endTerminals()
            if aborting { aborting = false; return }
            if active { onState?(code == 0 || interrupting ? .interrupted : .failed) }
            active = false; interrupting = false; clearWaiting()
            emit(.system, "Agent disconnected", detail: "Exit \(code). Send a message to continue.")
        }
    }

    // MARK: AgentSession

    func send(_ text: String) throws { try send(input: .init(text: text)) }
    func send(input: CodingTurnInput) throws {
        guard !stopped else { throw CodingFailure("This agent session was stopped.") }
        guard !aborting else { throw CodingFailure("The agent is still shutting down. Try again in a moment.") }
        guard !active, !starting else { throw CodingFailure("Wait for this turn or stop it before sending another message.") }
        active = true; interrupting = false; onState?(.working)
        do {
            if transport.running, sessionID != nil, configuring.isEmpty { try prompt(input); return }
            pending = input
            guard !transport.running else { return }
            starting = true
            let environment = launch.environment.build()
            try transport.start(executable: launch.executable(environment), arguments: launch.arguments, directory: URL(fileURLWithPath: task.directory), environment: environment)
            try request("initialize", ["protocolVersion": CodingACP.protocolVersion,
                                       "clientCapabilities": ["fs": ["readTextFile": true, "writeTextFile": true], "terminal": true],
                                       "clientInfo": ["name": "tsukumo", "title": "Tsukumo", "version": "1.0.0"]])
            deadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(45))
                guard !Task.isCancelled, let self, self.starting, !self.stopped else { return }
                self.abort("Agent handshake timed out")
            }
        } catch { active = false; starting = false; onState?(.failed); aborting = transport.running; transport.stop(); throw error }
    }
    func compact() throws { throw CodingFailure("\(launch.name) doesn't offer compacting through ACP.") }
    func review() throws { try send(CodingAgentSession.reviewPrompt) }
    /// `session/cancel`: the prompt ends with stop reason `cancelled`, and any permission
    /// request still open is answered `cancelled`, as the protocol requires.
    func interrupt() {
        guard !stopped, active, let sessionID else { return }
        interrupting = true
        try? notify("session/cancel", ["sessionId": sessionID])
        cancelWaitingPermissions()
    }
    func respond(_ id: String, allow: Bool, answers: String) throws { try respond(id, decision: allow ? .allowOnce : .deny(note: ""), answers: answers) }
    func respond(_ id: String, decision: CodingApprovalDecision, answers: String) throws {
        guard let pair = waiting[id] else { throw CodingFailure("This request is no longer active.") }
        let (entry, approval) = pair
        waiting.removeValue(forKey: id); order.removeAll { $0 == id }
        let refused = "Denied by the user in Tsukumo" + (decision.note.isEmpty ? "." : ": " + decision.note)
        switch entry {
        case .permission(let rpc, let options):
            if let option = CodingACP.option(for: decision, in: options) { try reply(rpc, ["outcome": ["outcome": "selected", "optionId": option]]) }
            else { try reply(rpc, ["outcome": ["outcome": "cancelled"]]) }
        case .read(let rpc, let path, let line, let limit):
            if decision.allows { serveRead(rpc, path: path, line: line, limit: limit) } else { try fail(rpc, refused) }
        case .write(let rpc, let path, let content):
            if decision.allows { serveWrite(rpc, path: path, content: content) } else { try fail(rpc, refused) }
        case .terminal(let rpc, let params):
            if decision.allows { serveTerminal(rpc, params) } else { try fail(rpc, refused) }
        }
        if !decision.note.isEmpty { deniedNotes.append("You asked to \(approval.title); I denied it: \(decision.note)") }
        emit(.approval, decision.summary, detail: decision.note.isEmpty ? approval.title : "Note to the agent (sent with your next message): " + decision.note)
        if order.isEmpty { onApproval?(nil); onState?(active ? .working : .review) } else { showFirst() }
    }
    func stop() {
        guard !stopped else { return }
        let wasActive = active
        if wasActive, let sessionID { try? notify("session/cancel", ["sessionId": sessionID]); cancelWaitingPermissions() }
        stopped = true
        deadline?.cancel(); pending = nil; starting = false; active = false; waiting.removeAll(); order.removeAll()
        onEvent = nil; onState = nil; onSession = nil; onApproval = nil; onReport = nil
        endTerminals()
        guard transport.running else { return }
        if wasActive { transport.shutdown(after: interruptGrace) } else { transport.stop() }
    }

    // MARK: Wire

    private func request(_ method: String, _ params: [String: Any]) throws {
        sequence += 1; requests[sequence] = method
        try transport.send(["jsonrpc": "2.0", "id": sequence, "method": method, "params": params])
    }
    @discardableResult private func configure(_ method: String, _ params: [String: Any]) throws -> Int {
        try request(method, params); configuring.insert(sequence); return sequence
    }
    private func notify(_ method: String, _ params: [String: Any]) throws { try transport.send(["jsonrpc": "2.0", "method": method, "params": params]) }
    private func reply(_ id: Any, _ result: Any) throws { try transport.send(["jsonrpc": "2.0", "id": id, "result": result]) }
    private func fail(_ id: Any, _ message: String, code: Int = -32603) throws {
        try transport.send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }
    private func emit(_ kind: CodingEvent.Kind, _ text: String, detail: String = "", id: String? = nil, append: Bool = false) {
        onEvent?(.init(id: id ?? UUID().uuidString, kind: kind, text: text, detail: detail), append)
    }
    private func abort(_ message: String, detail: String = "") {
        emit(.system, message, detail: detail)
        deadline?.cancel(); pending = nil; starting = false; active = false; interrupting = false
        clearWaiting(); onState?(.failed); endTerminals()
        aborting = transport.running; transport.stop()
    }
    private func receive(_ object: [String: Any]) {
        guard !stopped, !aborting else { return }
        do {
            if let method = object["method"] as? String {
                if let id = object["id"], !(id is NSNull) { try agentRequest(id: id, method: method, params: object["params"] as? [String: Any] ?? [:]) }
                else if method == "session/update" { update(object["params"] as? [String: Any] ?? [:]) }
                return
            }
            guard let id = (object["id"] as? Int) ?? (object["id"] as? NSNumber)?.intValue, let method = requests.removeValue(forKey: id) else { return }
            configuring.remove(id)
            if let error = object["error"] as? [String: Any] { try failed(method, error); if configuring.isEmpty { try startPending() }; return }
            try answered(method, object["result"] as? [String: Any] ?? [:])
            if configuring.isEmpty { try startPending() }
        } catch { abort("Agent protocol error", detail: error.localizedDescription) }
    }

    // MARK: Session setup

    private func answered(_ method: String, _ result: [String: Any]) throws {
        switch method {
        case "initialize":
            let version = result["protocolVersion"] as? Int ?? CodingACP.protocolVersion
            guard version == CodingACP.protocolVersion else {
                abort("\(launch.name) speaks ACP version \(version)", detail: "Tsukumo speaks ACP version \(CodingACP.protocolVersion) (\(CodingACP.schemaRelease)).")
                return
            }
            let capabilities = result["agentCapabilities"] as? [String: Any] ?? [:]
            canLoad = capabilities["loadSession"] as? Bool == true
            takesImages = (capabilities["promptCapabilities"] as? [String: Any])?["image"] as? Bool == true
            canResume = ((capabilities["sessionCapabilities"] as? [String: Any])?["resume"] as? [String: Any]) != nil
            try openSession()
        case "session/new", "session/load", "session/resume":
            replaying = false
            if method == "session/new" {
                guard let id = result["sessionId"] as? String else { throw CodingFailure("\(launch.name) didn't return a session ID.") }
                sessionID = id; onSession?(id)
            }
            starting = false; deadline?.cancel()
            settle(result)
        case "session/prompt":
            onReport?(.init(signedIn: true))
            switch result["stopReason"] as? String {
            case "cancelled": finishTurn(.interrupted)
            case "refusal": emit(.system, "\(launch.name) declined", detail: "It stopped with a refusal."); finishTurn(.review)
            case "max_tokens": emit(.system, "Turn cut short", detail: "\(launch.name) reached its token limit."); finishTurn(.review)
            case "max_turn_requests": emit(.system, "Turn cut short", detail: "\(launch.name) reached its limit of model requests."); finishTurn(.review)
            default: finishTurn(.review)
            }
        default: break
        }
    }
    private func openSession() throws {
        let base: [String: Any] = ["cwd": task.directory, "mcpServers": mcpServers]
        if let sessionID {
            if canResume { try request("session/resume", base.merging(["sessionId": sessionID]) { $1 }); return }
            if canLoad { replaying = true; try request("session/load", base.merging(["sessionId": sessionID]) { $1 }); return }
            emit(.system, "\(launch.name) can't resume sessions", detail: "It starts a new session; it doesn't see the conversation above.")
            self.sessionID = nil
        }
        try request("session/new", base)
    }
    /// The KemoSabe MCP server for this session, named for the agent (design/CONTEXT-HARNESS.md#agents-asking-kemosabe),
    /// and for the KemoSabe chat that started it, when one did.
    private var mcpServers: [[String: Any]] {
        KemoSabeMCP.acpServers(agent: launch.command.hasSuffix("cursor-agent") ? "cursor-agent" : "acp:" + AgentIdentity.slug(launch.name), handoff: handoff)
    }
    /// After a session opens: the agent's modes and config options, then the task's access,
    /// model, and effort, before the first prompt.
    private func settle(_ result: [String: Any]) {
        if let modeState = result["modes"] as? [String: Any] {
            modes = (modeState["availableModes"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            currentMode = modeState["currentModeId"] as? String
        }
        if let options = result["configOptions"] as? [[String: Any]] { config = CodingACP.config(options) }
        if !config.models.isEmpty { onReport?(.init(model: config.currentModel, models: config.models)) }
        guard let sessionID else { return }
        do {
            if let mode = CodingACP.modeID(for: task.access, available: modes), mode != currentMode {
                try configure("session/set_mode", ["sessionId": sessionID, "modeId": mode]); currentMode = mode
            }
            if let option = config.modelOption, !task.model.isEmpty, task.model != config.currentModel {
                try configure("session/set_config_option", ["sessionId": sessionID, "configId": option, "value": task.model])
            }
            if let option = config.effortOption, let effort = task.effort, !effort.isEmpty, effort != config.currentEffort {
                try configure("session/set_config_option", ["sessionId": sessionID, "configId": option, "value": effort])
            }
        } catch { emit(.system, "Couldn't apply the task's settings", detail: error.localizedDescription) }
    }
    private func failed(_ method: String, _ error: [String: Any]) throws {
        let message = error["message"] as? String ?? "\(launch.name) refused \(method)."
        let code = error["code"] as? Int ?? 0
        switch method {
        case "session/load", "session/resume":
            replaying = false
            emit(.system, "\(launch.name) couldn't reopen its session", detail: message + " It starts a new session; it doesn't see the conversation above.")
            sessionID = nil
            try request("session/new", ["cwd": task.directory, "mcpServers": mcpServers])
        case "session/set_mode", "session/set_config_option":
            emit(.system, "\(launch.name) didn't take a setting", detail: message)
        case "session/prompt":
            if code == -32000 || message.lowercased().contains("auth") { signInNeeded(message) }
            else { emit(.system, "Turn failed", detail: message) }
            finishTurn(.failed)
        default:
            if code == -32000 || message.lowercased().contains("auth") { signInNeeded(message); return }
            throw CodingFailure(message)
        }
    }
    private func signInNeeded(_ message: String) {
        onReport?(.init(signedIn: false))
        abort("Sign in to \(launch.name)", detail: message + " Settings → Agents → Sign in opens its own sign-in in a terminal.")
    }
    private func startPending() throws {
        guard let input = pending, sessionID != nil, !starting else { return }
        pending = nil
        try prompt(input)
    }
    private func prompt(_ input: CodingTurnInput) throws {
        guard let sessionID else { return }
        var input = input
        if !deniedNotes.isEmpty { input.text = deniedNotes.joined(separator: "\n") + "\n\n" + input.text; deniedNotes.removeAll() }
        messageSeq += 1; messageID = ""; thoughtID = ""; lastUpdate = ""
        if !input.images.isEmpty && !takesImages { emit(.system, "\(launch.name) doesn't take images", detail: "Only the text was sent.") }
        try request("session/prompt", ["sessionId": sessionID, "prompt": CodingACP.prompt(input, images: takesImages)])
    }

    // MARK: Updates

    private func update(_ params: [String: Any]) {
        guard !replaying, let update = params["update"] as? [String: Any], let kind = update["sessionUpdate"] as? String else { return }
        defer { lastUpdate = kind }
        switch kind {
        case "agent_message_chunk":
            guard let text = (update["content"] as? [String: Any])?["text"] as? String else { return }
            if lastUpdate != kind || messageID.isEmpty { messageID = (update["messageId"] as? String) ?? "acp-msg-\(messageSeq)-\(UUID().uuidString.prefix(8))" }
            emit(.assistant, text, id: messageID, append: true)
        case "agent_thought_chunk":
            guard let text = (update["content"] as? [String: Any])?["text"] as? String else { return }
            if lastUpdate != kind || thoughtID.isEmpty { thoughtID = "acp-thought-\(messageSeq)-\(UUID().uuidString.prefix(8))" }
            emit(.reasoning, text, id: thoughtID, append: true)
        case "tool_call", "tool_call_update":
            let event = CodingACP.toolEvent(update, directory: task.directory)
            for block in update["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "terminal" {
                if let terminal = block["terminalId"] as? String { terminalCards[terminal] = event.id }
            }
            onEvent?(event, false)
        case "plan":
            onEvent?(CodingACP.planEvent(update["entries"] as? [[String: Any]] ?? [], id: "plan-" + (sessionID ?? "acp")), false)
        case "available_commands_update":
            let names = (update["availableCommands"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            onReport?(.init(commands: names))
        case "current_mode_update":
            currentMode = update["currentModeId"] as? String
        case "config_option_update":
            config = CodingACP.config(update["configOptions"] as? [[String: Any]] ?? [])
            if !config.models.isEmpty { onReport?(.init(model: config.currentModel, models: config.models)) }
        default: break
        }
    }
    private func finishTurn(_ state: CodingTaskStatus) {
        active = false
        let interrupted = interrupting; interrupting = false
        clearWaiting()
        onState?(interrupted && state != .review ? .interrupted : state)
    }

    // MARK: Requests from the agent

    private func agentRequest(id: Any, method: String, params: [String: Any]) throws {
        switch method {
        case "session/request_permission":
            let toolCall = params["toolCall"] as? [String: Any] ?? [:]
            let options = params["options"] as? [[String: Any]] ?? []
            let paths = (toolCall["locations"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
                + (toolCall["content"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "diff" ? $0["path"] as? String : nil }
            onEvent?(CodingACP.toolEvent(toolCall, directory: task.directory), false)
            switch CodingAccessGate.decide(.tool(kind: toolCall["kind"] as? String ?? "other", paths: paths), access: task.access, directory: task.directory) {
            case .allow:
                if let option = CodingACP.option(for: .allowOnce, in: options) { try reply(id, ["outcome": ["outcome": "selected", "optionId": option]]) }
                else { try reply(id, ["outcome": ["outcome": "cancelled"]]) }
            case .deny(let reason):
                emit(.system, "Refused: " + (toolCall["title"] as? String ?? "a tool"), detail: reason)
                if let option = CodingACP.option(for: .deny(note: ""), in: options) { try reply(id, ["outcome": ["outcome": "selected", "optionId": option]]) }
                else { try reply(id, ["outcome": ["outcome": "cancelled"]]) }
            case .ask:
                enqueue(.permission(id: id, options: options)) { key, pending in CodingACP.approval(key: key, toolCall: toolCall, directory: self.task.directory, pending: pending) }
            }
        case "fs/read_text_file":
            let path = params["path"] as? String ?? ""
            let line = params["line"] as? Int, limit = params["limit"] as? Int
            switch CodingAccessGate.decide(.read(path: path), access: task.access, directory: task.directory) {
            case .allow: serveRead(id, path: path, line: line, limit: limit)
            case .deny(let reason): try fail(id, reason)
            case .ask:
                enqueue(.read(id: id, path: path, line: line, limit: limit)) { key, pending in
                    .init(id: key, title: "Read " + path, detail: "The file is outside this task's folder.", kind: .command, pending: pending)
                }
            }
        case "fs/write_text_file":
            let path = params["path"] as? String ?? "", content = params["content"] as? String ?? ""
            switch CodingAccessGate.decide(.write(path: path), access: task.access, directory: task.directory) {
            case .allow: serveWrite(id, path: path, content: content)
            case .deny(let reason): emit(.system, "Refused a write to " + CodingChatEvents.relative(path, to: task.directory), detail: reason); try fail(id, reason)
            case .ask:
                let relative = CodingChatEvents.relative(path, to: task.directory)
                let old = try? String(contentsOfFile: path, encoding: .utf8)
                let diff = CodingChatEvents.unifiedDiff(path: relative, hunks: [(old ?? "", content)], added: old == nil)
                enqueue(.write(id: id, path: path, content: content)) { key, pending in
                    .init(id: key, title: relative, detail: path, kind: .files, diff: diff, pending: pending)
                }
            }
        case "terminal/create":
            let line = ([params["command"] as? String ?? ""] + (params["args"] as? [String] ?? []).map(CodingACP.shellQuote)).joined(separator: " ")
            switch CodingAccessGate.decide(.command(line), access: task.access, directory: task.directory) {
            case .allow: serveTerminal(id, params)
            case .deny(let reason): emit(.system, "Refused to run " + line, detail: reason); try fail(id, reason)
            case .ask:
                enqueue(.terminal(id: id, params: params)) { key, pending in
                    .init(id: key, title: line, detail: (params["cwd"] as? String) ?? self.task.directory, kind: .command, command: line, pending: pending)
                }
            }
        case "terminal/output":
            guard let terminal = terminals[params["terminalId"] as? String ?? ""] else { try fail(id, "No such terminal.", code: -32602); return }
            let snapshot = terminal.snapshot()
            var result: [String: Any] = ["output": snapshot.output, "truncated": snapshot.truncated]
            if let exit = snapshot.exit { result["exitStatus"] = Self.exitStatus(exit) }
            try reply(id, result)
        case "terminal/wait_for_exit":
            guard let terminal = terminals[params["terminalId"] as? String ?? ""] else { try fail(id, "No such terminal.", code: -32602); return }
            terminal.wait { [weak self] exit in
                Task { @MainActor in try? self?.reply(id, Self.exitStatus(exit)) }
            }
        case "terminal/kill":
            terminals[params["terminalId"] as? String ?? ""]?.kill()
            try reply(id, [String: Any]())
        case "terminal/release":
            let key = params["terminalId"] as? String ?? ""
            terminals.removeValue(forKey: key)?.kill(); terminalCards.removeValue(forKey: key)
            try reply(id, [String: Any]())
        default:
            try fail(id, "Tsukumo doesn't support \(method) yet.", code: -32601)
        }
    }
    private static func exitStatus(_ exit: CodingACPTerminal.Exit) -> [String: Any] {
        var result: [String: Any] = [:]
        result["exitCode"] = exit.code.map { Int($0) } ?? NSNull()
        result["signal"] = exit.signal ?? NSNull()
        return result
    }
    private func enqueue(_ entry: Waiting, _ make: (String, Int) -> CodingApproval) {
        sequence += 1
        let key = "acp-\(sequence)"
        waiting[key] = (entry, make(key, waiting.count + 1))
        order.append(key)
        showFirst()
    }
    private func showFirst() {
        guard let key = order.first, var pair = waiting[key] else { return }
        pair.1.pending = order.count
        waiting[key] = pair
        onApproval?(pair.1); onState?(.needsInput)
    }
    private func clearWaiting() {
        guard !order.isEmpty else { return }
        for key in order {
            guard let pair = waiting[key] else { continue }
            switch pair.0 {
            case .permission(let id, _): try? reply(id, ["outcome": ["outcome": "cancelled"]])
            case .read(let id, _, _, _), .write(let id, _, _), .terminal(let id, _): try? fail(id, "The turn ended before this was answered.")
            }
        }
        waiting.removeAll(); order.removeAll(); onApproval?(nil)
    }
    private func cancelWaitingPermissions() { clearWaiting() }
    private func serveRead(_ id: Any, path: String, line: Int?, limit: Int?) {
        do {
            let text = try String(contentsOfFile: path, encoding: .utf8)
            try reply(id, ["content": CodingACP.slice(text, line: line, limit: limit)])
        } catch { try? fail(id, "Couldn't read \(path): \(error.localizedDescription)", code: -32002) }
    }
    private func serveWrite(_ id: Any, path: String, content: String) {
        do {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            try reply(id, [String: Any]())
        } catch { try? fail(id, "Couldn't write \(path): \(error.localizedDescription)") }
    }
    private func serveTerminal(_ id: Any, _ params: [String: Any]) {
        do {
            var environment = launch.environment.build()
            for variable in params["env"] as? [[String: Any]] ?? [] {
                if let name = variable["name"] as? String, let value = variable["value"] as? String { environment[name] = value }
            }
            let command = params["command"] as? String ?? ""
            guard let executable = CodingACP.resolve(command, environment: environment) else { try fail(id, "`\(command)` wasn't found."); return }
            let cwd = (params["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? task.directory
            sequence += 1
            let terminalID = "term-\(sequence)"
            let terminal = try CodingACPTerminal(id: terminalID, executable: executable, arguments: params["args"] as? [String] ?? [],
                                                 directory: URL(fileURLWithPath: cwd), environment: environment, limit: params["outputByteLimit"] as? Int)
            terminal.onOutput = { [weak self] chunk in
                guard let self, let card = self.terminalCards[terminalID] else { return }
                self.onEvent?(.init(id: card, kind: .command, text: "", detail: chunk), true)
            }
            terminals[terminalID] = terminal
            try reply(id, ["terminalId": terminalID])
        } catch { try? fail(id, "Couldn't start the command: \(error.localizedDescription)") }
    }
    private func endTerminals() {
        for terminal in terminals.values { terminal.kill() }
        terminals.removeAll(); terminalCards.removeAll()
    }
}

/// One command an ACP agent runs through `terminal/create`: its own process group, output kept up
/// to the agent's byte limit, and its exit status.
final class CodingACPTerminal: @unchecked Sendable {
    struct Exit { var code: Int32?; var signal: String? }
    let id: String
    private let child: CodingChild
    private let lock = NSLock()
    private var output = Data()
    private var truncated = false
    private let limit: Int?
    private var exit: Exit?
    private var waiters: [(Exit) -> Void] = []
    private var killed = false
    /// New output as it arrives, on the main thread.
    var onOutput: ((String) -> Void)?
    init(id: String, executable: URL, arguments: [String], directory: URL, environment: [String: String], limit: Int?) throws {
        self.id = id; self.limit = limit
        child = try CodingChild.spawn(executable, arguments, directory: directory, environment: environment, input: false, mergeErrors: true)
        let handle = child.output
        DispatchQueue.global(qos: .utility).async { [self] in
            while true {
                let bytes = handle.availableData
                if bytes.isEmpty { break }
                lock.lock()
                output.append(bytes)
                if let limit, output.count > limit { (output, _) = CodingACP.truncate(output, limit: limit); truncated = true }
                lock.unlock()
                let text = String(decoding: bytes, as: UTF8.self)
                DispatchQueue.main.async { [weak self] in self?.onOutput?(text) }
            }
        }
        DispatchQueue.global(qos: .utility).async { [self] in
            let status = child.waitAndReapGroup(grace: 2)
            lock.lock()
            let result = status > 128 ? Exit(code: nil, signal: Self.signalName(status - 128)) : Exit(code: status, signal: nil)
            exit = result
            let pending = waiters; waiters.removeAll()
            lock.unlock()
            for waiter in pending { waiter(result) }
        }
    }
    static func signalName(_ number: Int32) -> String {
        switch number { case SIGKILL: "SIGKILL"; case SIGTERM: "SIGTERM"; case SIGINT: "SIGINT"; case SIGHUP: "SIGHUP"; default: "SIG\(number)" }
    }
    func snapshot() -> (output: String, truncated: Bool, exit: Exit?) {
        lock.lock(); defer { lock.unlock() }
        return (String(decoding: output, as: UTF8.self), truncated, exit)
    }
    func wait(_ done: @escaping (Exit) -> Void) {
        lock.lock()
        if let exit { lock.unlock(); done(exit); return }
        waiters.append(done); lock.unlock()
    }
    func kill() {
        lock.lock(); let running = exit == nil; killed = true; lock.unlock()
        if running { child.terminate(grace: 2) }
    }
}

/// Deletes an ACP agent's saved session, when the agent says it can (`sessionCapabilities.delete`):
/// one short-lived process, `initialize`, then `session/delete`. No prompt is sent.
@MainActor final class CodingACPSessionDeletion {
    private let launch: CodingACPLaunch
    private let sessionID: String
    private let directory: String
    private let transport = CodingProcess(grace: 1)
    private var done: CheckedContinuation<String?, Never>?
    private var timeout: Task<Void, Never>?
    init(launch: CodingACPLaunch, sessionID: String, directory: String) { self.launch = launch; self.sessionID = sessionID; self.directory = directory }
    func run() async -> String? {
        await withCheckedContinuation { continuation in
            done = continuation
            transport.onJSON = { [weak self] in self?.receive($0) }
            transport.onExit = { [weak self] code in self?.finish("\(self?.launch.name ?? "The agent") exited (\(code)) before removing its session.") }
            do {
                let environment = launch.environment.build()
                try transport.start(executable: launch.executable(environment), arguments: launch.arguments, directory: URL(fileURLWithPath: directory), environment: environment)
                try transport.send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": CodingACP.protocolVersion, "clientCapabilities": [String: Any](), "clientInfo": ["name": "tsukumo", "version": "1.0.0"]]])
            } catch { finish(error.localizedDescription); return }
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(20)); guard !Task.isCancelled else { return }
                self?.finish("\(self?.launch.name ?? "The agent") didn't answer in time.")
            }
        }
    }
    private func receive(_ object: [String: Any]) {
        let id = (object["id"] as? Int) ?? (object["id"] as? NSNumber)?.intValue
        if id == 1 {
            let capabilities = ((object["result"] as? [String: Any])?["agentCapabilities"] as? [String: Any])?["sessionCapabilities"] as? [String: Any]
            guard capabilities?["delete"] != nil else { finish(nil); return }   // Nothing it can delete; the summary said it keeps it.
            try? transport.send(["jsonrpc": "2.0", "id": 2, "method": "session/delete", "params": ["sessionId": sessionID]])
        } else if id == 2 {
            finish(((object["error"] as? [String: Any])?["message"] as? String).map { "\(launch.name) couldn't remove its session: " + $0 })
        }
    }
    private func finish(_ problem: String?) {
        guard let done else { return }
        self.done = nil; timeout?.cancel()
        transport.onExit = nil; transport.stop()
        done.resume(returning: problem.map { "The task was deleted. " + $0 })
    }
}

/// Settings → Agents → Test connection: starts the agent, runs `initialize` only (no session, no
/// prompt), and reports who answered and what it supports.
@MainActor final class CodingACPConnectionTest {
    struct Result: Equatable {
        var agent: String
        var version: String
        var protocolVersion: Int
        var loadSession: Bool
        var images: Bool
        var authMethods: [String]
        var summary: String {
            var parts = ["\(agent)\(version.isEmpty ? "" : " " + version) answered (ACP \(protocolVersion))"]
            parts.append(loadSession ? "resumes sessions" : "doesn't resume sessions")
            parts.append(images ? "takes images" : "text only")
            if !authMethods.isEmpty { parts.append("sign-in: " + authMethods.joined(separator: ", ")) }
            return parts.joined(separator: " · ")
        }
    }
    private let launch: CodingACPLaunch
    private let transport = CodingProcess(grace: 1)
    private var done: CheckedContinuation<Swift.Result<Result, Error>, Never>?
    private var timeout: Task<Void, Never>?
    private var stderr = ""
    init(launch: CodingACPLaunch) { self.launch = launch }
    func run(seconds: Double = 15) async -> Swift.Result<Result, Error> {
        await withCheckedContinuation { continuation in
            done = continuation
            transport.onJSON = { [weak self] in self?.receive($0) }
            transport.onError = { [weak self] in self?.stderr += $0 }
            transport.onExit = { [weak self] code in
                guard let self else { return }
                self.finish(.failure(CodingFailure("\(self.launch.name) exited (\(code)) before answering." + (self.stderr.isEmpty ? "" : " " + String(self.stderr.prefix(300))))))
            }
            do {
                let environment = launch.environment.build()
                try transport.start(executable: launch.executable(environment), arguments: launch.arguments, directory: FileManager.default.homeDirectoryForCurrentUser, environment: environment)
                try transport.send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": CodingACP.protocolVersion,
                    "clientCapabilities": ["fs": ["readTextFile": true, "writeTextFile": true], "terminal": true], "clientInfo": ["name": "tsukumo", "title": "Tsukumo", "version": "1.0.0"]]])
            } catch { finish(.failure(error)); return }
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds)); guard !Task.isCancelled else { return }
                self?.finish(.failure(CodingFailure("No answer to `initialize` in \(Int(seconds)) seconds. Is it an ACP agent (some need a flag such as --acp)?")))
            }
        }
    }
    private func receive(_ object: [String: Any]) {
        guard (object["id"] as? Int) == 1 || (object["id"] as? NSNumber)?.intValue == 1 else { return }
        if let error = object["error"] as? [String: Any] { finish(.failure(CodingFailure(error["message"] as? String ?? "The agent refused `initialize`."))); return }
        let result = object["result"] as? [String: Any] ?? [:]
        let info = result["agentInfo"] as? [String: Any] ?? [:]
        let capabilities = result["agentCapabilities"] as? [String: Any] ?? [:]
        let methods = (result["authMethods"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        finish(.success(.init(agent: info["title"] as? String ?? info["name"] as? String ?? launch.name, version: info["version"] as? String ?? "",
                              protocolVersion: result["protocolVersion"] as? Int ?? 0, loadSession: capabilities["loadSession"] as? Bool == true,
                              images: (capabilities["promptCapabilities"] as? [String: Any])?["image"] as? Bool == true, authMethods: methods)))
    }
    private func finish(_ result: Swift.Result<Result, Error>) {
        guard let done else { return }
        self.done = nil; timeout?.cancel()
        transport.onExit = nil; transport.stop()
        done.resume(returning: result)
    }
}

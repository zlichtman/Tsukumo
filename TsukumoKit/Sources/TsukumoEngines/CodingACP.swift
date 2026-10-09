#if os(macOS)
import Foundation
import TsukumoCore

// The Agent Client Protocol (JSON-RPC 2.0 over stdio), for any agent that speaks it: Cursor Agent
// (`cursor-agent acp`), Gemini CLI, and others (ported from `CodingACPSession` in the old Tsukumo app,
// pinned to protocol version 1 as published in the ACP repository's `schema/v1/schema.json` at
// `schema-v1.23.0`). Agent side: `initialize`, `session/new`, `session/resume` or `session/load` (its
// replay is skipped: the chat already has it), `session/set_mode` for the bot's access,
// `session/set_config_option` for its model and effort, `session/prompt`, `session/cancel`. Client side:
// `session/update`, `session/request_permission`, `fs/read_text_file`, and `fs/write_text_file`, each
// through `CodingAccessGate`. Terminals aren't offered (`terminal: false`), so an agent runs commands with
// its own tools and asks permission first. Tsukumo's tools aren't offered over ACP yet: that takes a stdio
// MCP server the agent can start (`mcpServers` is empty).

/// The Agent Client Protocol's wire format.
public enum ACP {
    public static let protocolVersion = 1

    static func initialize(id: Int) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "method": "initialize",
         "params": ["protocolVersion": protocolVersion, "clientCapabilities": ["fs": ["readTextFile": true, "writeTextFile": true], "terminal": false],
                    "clientInfo": ["name": "tsukumo", "title": "Tsukumo", "version": "1.0.0"]]]
    }

    /// The agent's mode for an access level, from the ones it offers (Cursor's agent, plan, ask; Claude Code's
    /// adapter's default, acceptEdits, bypassPermissions, plan; Gemini's default, autoEdit, yolo). Nil when none
    /// fits; the access gate still applies.
    public static func mode(for access: BotPermissions.Access, available: [String]) -> String? {
        let preferences: [String]
        switch access {
        case .readOnly: preferences = ["plan", "read-only", "readonly", "read_only", "ask", "architect"]
        case .askFirst: preferences = ["default", "ask-first", "manual", "agent", "code"]
        case .autoEdit: preferences = ["acceptEdits", "auto-edit", "autoEdit", "auto_edit", "agent", "code", "default"]
        case .full: preferences = ["bypassPermissions", "yolo", "full-access", "full", "agent", "code", "default"]
        }
        let lowered = Dictionary(available.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        for preference in preferences { if let match = lowered[preference.lowercased()] { return match } }
        return nil
    }

    /// Session config options: the agent's models (a `model` select) and efforts (a `thought_level` select).
    public struct Config: Hashable, Sendable {
        public var modelOption: String?
        public var effortOption: String?
        public var models: [CodingAgentModel] = []
        public var currentModel: String?
        public var currentEffort: String?
    }
    public static func config(_ options: [[String: Any]]) -> Config {
        var config = Config()
        func values(_ option: [String: Any]) -> [(String, String)] {
            let flat = option.objects("options").flatMap { entry -> [[String: Any]] in (entry["options"] as? [[String: Any]]) ?? [entry] }
            return flat.compactMap { entry in entry.string("value").map { ($0, entry.string("name") ?? $0) } }
        }
        var efforts: [Effort] = []
        for option in options where option.string("type") == "select" || option["options"] != nil {
            let category = option.string("category"), id = option.string("id") ?? ""
            if category == "model" || (category == nil && id.lowercased() == "model") {
                config.modelOption = id; config.currentModel = option.string("currentValue")
                config.models = values(option).map { CodingAgentModel(id: $0.0, name: $0.1) }
            } else if category == "thought_level" {
                config.effortOption = id; config.currentEffort = option.string("currentValue")
                efforts = values(option).map { Effort($0.0) }
            }
        }
        config.models = config.models.map { model in
            var model = model
            model.efforts = efforts
            model.defaultEffort = config.currentEffort.map(Effort.init(rawValue:))
            model.isDefault = model.id == config.currentModel
            return model
        }
        return config
    }

    /// The option to pick for an answer: allow once (or always), reject once (or always). Nil: answer `cancelled`.
    static func option(allow: Bool, in options: [[String: Any]]) -> String? {
        let kinds = allow ? ["allow_once", "allow_always"] : ["reject_once", "reject_always"]
        for kind in kinds { if let match = options.first(where: { $0.string("kind") == kind })?.string("optionId") { return match } }
        return nil
    }
    /// The paths a tool call names: its locations and its diffs.
    static func paths(_ toolCall: [String: Any]) -> [String] {
        toolCall.objects("locations").compactMap { $0.string("path") }
            + toolCall.objects("content").compactMap { $0.string("type") == "diff" ? $0.string("path") : nil }
    }
    /// What a `tool_call` (or its update) shows about the agent's work.
    static func activity(_ update: [String: Any], started: Bool) -> [CodingActivity] {
        let id = update.string("toolCallId") ?? ""
        switch update.string("kind") {
        case "edit", "delete", "move":
            let diffs = update.objects("content").filter { $0.string("type") == "diff" }
            if !diffs.isEmpty {
                return diffs.compactMap { diff in
                    diff.string("path").map { .editing(path: $0, diff: ClaudeCode.patch(old: diff.string("oldText") ?? "", new: diff.string("newText") ?? "")) }
                }
            }
            return paths(update).map { .editing(path: $0, diff: nil) }
        case "read": return paths(update).prefix(1).map { .reading(path: $0) }
        case "execute": return started ? [.running(id: id, command: command(update["rawInput"]) ?? update.string("title") ?? "")] : []
        default:
            switch update.string("status") {
            case "completed": return [.ran(id: id, failed: false)]
            case "failed": return [.ran(id: id, failed: true)]
            default: return []
            }
        }
    }
    /// A shell command from a tool's raw input: `command` as a string or a list, or `cmd`.
    static func command(_ raw: Any?) -> String? {
        guard let input = raw as? [String: Any] else { return nil }
        if let text = input.string("command"), !text.isEmpty { return ([text] + (input["args"] as? [String] ?? [])).joined(separator: " ") }
        if let argv = (input["command"] as? [String]) ?? (input["argv"] as? [String]), !argv.isEmpty { return argv.joined(separator: " ") }
        return input.string("cmd")
    }
    static func plan(_ entries: [[String: Any]]) -> CodingActivity {
        .plan(entries.map { entry in
            let state: CodingActivity.PlanStep.State = switch entry.string("status") { case "completed": .done; case "in_progress": .active; default: .pending }
            return CodingActivity.PlanStep(title: entry.string("content") ?? "", state: state)
        })
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
}

/// An ACP agent on this Mac: one process per turn, continuing the chat's session when it can.
public struct ACPBackend: CodingAgentBackend {
    public let agentID: String
    /// Its name, for messages ("Cursor Agent").
    public let name: String
    public let launch: CodingLaunch
    /// What starts its ACP server (`["acp"]` for Cursor Agent).
    public let arguments: [String]
    public let interruptGrace: TimeInterval
    private let registry = CodingRunRegistry()

    public init(agentID: String, name: String, launch: CodingLaunch, arguments: [String], interruptGrace: TimeInterval = 3) {
        self.agentID = agentID; self.name = name; self.launch = launch; self.arguments = arguments; self.interruptGrace = interruptGrace
    }

    public func start(_ task: CodingTask) -> AsyncThrowingStream<CodingAgentEvent, Error> {
        ACPRun(task: task, launch: launch, name: name, interruptGrace: interruptGrace).stream(arguments: arguments, registry: registry)
    }
    public func respond(permission id: String, allow: Bool) async { registry.take(id)?.respond(permission: id, allow: allow) }
    public func respondTool(id: String, result: String) async { registry.take(id)?.respond(tool: id, result: result) }
}

final class ACPRun: CodingRun {
    private enum Waiting {
        case permission(rpc: Any, options: [[String: Any]])
        case read(rpc: Any, path: String, line: Int?, limit: Int?)
        case write(rpc: Any, path: String, content: String)
    }
    private var session: String?
    private var sequence = 0
    private var requests: [Int: String] = [:]
    /// Settings sent before the prompt; the prompt waits for their answers.
    private var configuring: Set<Int> = []
    private var prompted = false
    /// The session is open (new, resumed, or loaded).
    private var opened = false
    private var replaying = false
    private var canLoad = false, canResume = false
    private var waiting: [String: Waiting] = [:]
    private var lastMessage = ""
    private var textSoFar = ""
    private var started: Set<String> = []

    private func request(_ method: String, _ params: [String: Any]) throws -> Int {
        sequence += 1
        requests[sequence] = method
        try send(["jsonrpc": "2.0", "id": sequence, "method": method, "params": params])
        return sequence
    }
    private func reply(_ id: Any, _ result: Any) throws { try send(["jsonrpc": "2.0", "id": id, "result": result]) }
    private func refuse(_ id: Any, _ message: String, code: Int = -32603) throws {
        try send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    override func begin() throws {
        session = task.session
        sequence += 1
        requests[sequence] = "initialize"
        try send(ACP.initialize(id: sequence))
    }

    override func interrupt() -> Bool {
        guard let session else { return false }
        for (_, entry) in waiting { if case .permission(let rpc, _) = entry { try? reply(rpc, ["outcome": ["outcome": "cancelled"]]) } }
        waiting.removeAll()
        return (try? send(["jsonrpc": "2.0", "method": "session/cancel", "params": ["sessionId": session]])) != nil
    }

    override func receive(_ object: [String: Any]) throws {
        if let method = object.string("method") {
            if let id = object["id"], !(id is NSNull) { return try agentRequest(id: id, method: method, params: object.object("params")) }
            if method == "session/update" { update(object.object("params")) }
            return
        }
        guard let id = (object["id"] as? NSNumber)?.intValue, let method = requests.removeValue(forKey: id) else { return }
        configuring.remove(id)
        if let error = object["error"] as? [String: Any] { try failed(method, error) } else { try answered(method, object.object("result")) }
        if opened, configuring.isEmpty, !ended { try prompt() }
    }

    private var base: [String: Any] { ["cwd": task.directory, "mcpServers": [Any]()] }

    private func answered(_ method: String, _ result: [String: Any]) throws {
        switch method {
        case "initialize":
            let version = result["protocolVersion"] as? Int ?? ACP.protocolVersion
            guard version == ACP.protocolVersion else {
                throw CodingAgentFailure("\(name) speaks ACP version \(version); Tsukumo speaks version \(ACP.protocolVersion).")
            }
            let capabilities = result.object("agentCapabilities")
            canLoad = capabilities["loadSession"] as? Bool == true
            canResume = capabilities.object("sessionCapabilities")["resume"] != nil
            try openSession()
        case "session/new", "session/load", "session/resume":
            replaying = false
            if method == "session/new" {
                guard let id = result.string("sessionId") else { throw CodingAgentFailure("\(name) didn’t return a session.") }
                session = id
            }
            opened = true
            handshakeDone()
            settle(result)
        case "session/prompt":
            switch result.string("stopReason") {
            case "cancelled": fail(CancellationError())
            case "refusal": fail(CodingAgentFailure("\(name) declined."))
            default: finish(session: session)
            }
        default: break
        }
    }

    /// Opens the chat's session again when the agent can, else a new one.
    private func openSession() throws {
        if let session {
            if canResume { _ = try request("session/resume", base.merging(["sessionId": session]) { $1 }); return }
            if canLoad { replaying = true; _ = try request("session/load", base.merging(["sessionId": session]) { $1 }); return }
            return fail(EngineError.sessionGone)
        }
        _ = try request("session/new", base)
    }

    /// After a session opens: the bot's access as the agent's mode, then its model and effort, before the prompt.
    private func settle(_ result: [String: Any]) {
        guard let session else { return }
        let modes = result.object("modes").objects("availableModes").compactMap { $0.string("id") }
        let current = result.object("modes").string("currentModeId")
        let config = ACP.config(result.objects("configOptions"))
        do {
            if let mode = ACP.mode(for: task.access, available: modes), mode != current {
                configuring.insert(try request("session/set_mode", ["sessionId": session, "modeId": mode]))
            }
            if let option = config.modelOption, let model = task.model, !model.isEmpty, model != config.currentModel {
                configuring.insert(try request("session/set_config_option", ["sessionId": session, "configId": option, "value": model]))
            }
            if let option = config.effortOption, let effort = task.effort, effort.rawValue != config.currentEffort {
                configuring.insert(try request("session/set_config_option", ["sessionId": session, "configId": option, "value": effort.rawValue]))
            }
        } catch { fail(error) }
    }

    private func failed(_ method: String, _ error: [String: Any]) throws {
        let message = error.string("message") ?? "\(name) refused \(method)."
        switch method {
        case "session/load", "session/resume": fail(EngineError.sessionGone)
        case "session/set_mode", "session/set_config_option": break   // A setting it didn't take; the gate still applies.
        default:
            if (error["code"] as? Int) == -32000 || CodingRun.signInProblem(message) {
                throw CodingAgentFailure("Sign in to \(name) in its terminal, then try again. It said: " + String(message.prefix(300)))
            }
            throw CodingAgentFailure("\(name) couldn’t finish: " + String(message.prefix(400)))
        }
    }

    private func prompt() throws {
        guard let session, !prompted else { return }
        prompted = true
        _ = try request("session/prompt", ["sessionId": session, "prompt": [["type": "text", "text": task.prompt]]])
    }

    private func say(_ text: String, message: String) {
        guard !text.isEmpty else { return }
        if message != lastMessage, !textSoFar.isEmpty, !textSoFar.hasSuffix("\n") { yield(.text("\n\n")); textSoFar += "\n\n" }
        lastMessage = message
        textSoFar += text
        yield(.text(text))
    }

    private func update(_ params: [String: Any]) {
        guard !replaying else { return }
        let update = params.object("update")
        switch update.string("sessionUpdate") {
        case "agent_message_chunk":
            say(update.object("content").string("text") ?? "", message: update.string("messageId") ?? "acp")
        case "tool_call", "tool_call_update":
            let id = update.string("toolCallId") ?? ""
            let first = started.insert(id).inserted
            for activity in ACP.activity(update, started: first) { yield(.activity(activity)) }
            lastMessage = "tool-" + id
        case "plan": yield(.activity(ACP.plan(update.objects("entries"))))
        default: break
        }
    }

    private func agentRequest(id: Any, method: String, params: [String: Any]) throws {
        switch method {
        case "session/request_permission":
            let toolCall = params.object("toolCall")
            let ours = nextID("permission")
            waiting[ours] = .permission(rpc: id, options: params.objects("options"))
            yield(.permission(id: ours, request: .tool(kind: toolCall.string("kind") ?? "other", paths: ACP.paths(toolCall))))
        case "fs/read_text_file":
            let ours = nextID("permission"), path = params.string("path") ?? ""
            waiting[ours] = .read(rpc: id, path: path, line: params["line"] as? Int, limit: params["limit"] as? Int)
            yield(.permission(id: ours, request: .read(path: path)))
        case "fs/write_text_file":
            let ours = nextID("permission"), path = params.string("path") ?? ""
            waiting[ours] = .write(rpc: id, path: path, content: params.string("content") ?? "")
            yield(.activity(.editing(path: path, diff: nil)))
            yield(.permission(id: ours, request: .write(path: path)))
        default:
            try refuse(id, "Tsukumo doesn't support \(method).", code: -32601)
        }
    }

    override func answer(permission id: String, allow: Bool) throws {
        guard let entry = waiting.removeValue(forKey: id) else { return }
        let refused = "Not allowed: the owner's settings for this bot in Tsukumo don't allow it."
        switch entry {
        case .permission(let rpc, let options):
            if let option = ACP.option(allow: allow, in: options) { try reply(rpc, ["outcome": ["outcome": "selected", "optionId": option]]) }
            else { try reply(rpc, ["outcome": ["outcome": "cancelled"]]) }
        case .read(let rpc, let path, let line, let limit):
            guard allow else { return try refuse(rpc, refused) }
            do { try reply(rpc, ["content": ACP.slice(try String(contentsOfFile: path, encoding: .utf8), line: line, limit: limit)]) }
            catch { try refuse(rpc, "Couldn’t read \(path): \(error.localizedDescription)", code: -32002) }
        case .write(let rpc, let path, let content):
            guard allow else { return try refuse(rpc, refused) }
            do {
                let url = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try content.write(to: url, atomically: true, encoding: .utf8)
                try reply(rpc, [String: Any]())
            } catch { try refuse(rpc, "Couldn’t write \(path): \(error.localizedDescription)") }
        }
    }
}
#endif

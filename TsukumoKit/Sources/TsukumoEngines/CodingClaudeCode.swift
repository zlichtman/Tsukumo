#if os(macOS)
import Foundation
import TsukumoCore

// Claude Code, headless: `claude -p` with stream-json in and out (ported from `CodingAgentSession` in the
// old Tsukumo app, where it ran in production, and checked against the installed 2.1.287 on October 4,
// 2026). The flags, from that app's notes and `claude --help`:
// - `--permission-prompt-tool stdio` routes each prompt ("ask") here as a `can_use_tool` control request,
//   answered with a `control_response`; `--permission-prompts host` keeps that explicit.
// - `--permission-mode`: Read only is `plan` with only Read, Grep, and Glob; Ask first is `manual`; Auto-edit
//   is `acceptEdits`; Full access is `bypassPermissions` (with `--allow-dangerously-skip-permissions`).
//   These are the agent's own permissions, not an OS sandbox; every prompt still passes `CodingAccessGate`.
// - `--resume <session>` continues the chat's session; `--effort` takes low, medium, high, xhigh, max.
// - Tsukumo's tools are an SDK-hosted MCP server (`tsukumo`, named in `--mcp-config` as `{"type": "sdk"}`
//   and in the `initialize` control request's `sdkMcpServers`): the CLI sends each MCP message as an
//   `mcp_message` control request and the answer goes back under `mcp_response`, in this process, with no
//   helper program.
// - Sealed runs (the Claude bot, `CodingTask.sealed`) use the CLI's own isolation, checked against `claude --help`
//   of 2.1.290 on October 7, 2026: `--restricted` (no user, project, or local settings files; no command-running
//   tools or WebFetch unless `--tools` names them; file tools confined to the working folder; bypass refused),
//   `--safe-mode` (no CLAUDE.md or other memory files, skills, plugins, hooks, custom agents or commands),
//   `--disable-slash-commands` (no skills), `--setting-sources` with none, `--strict-mcp-config` (only Tsukumo's server), `--settings` with Tsukumo's own
//   (every hook off, no allow rules, deny rules for secret files, bypass disabled), an explicit `--tools` and
//   `--disallowedTools`, Tsukumo's permission mode (plan, or manual, never acceptEdits or bypass, so every write
//   reaches Tsukumo's callback), and an allow-listed environment (`CodingEnvironment.sealed`). The owner's sign-in
//   still works: OAuth lives in the login keychain and `~/.claude`, which HOME and USER reach. `--bare` would be
//   stricter, but it never reads OAuth, so it would need an API key.
// - An `interrupt` control request stops a turn and keeps the session.

/// Claude Code's wire format: arguments, messages, and how its events map to Tsukumo's.
public enum ClaudeCode {
    /// The SDK-hosted MCP server that serves Tsukumo's tools.
    public static let serverName = "tsukumo"
    /// The efforts `--effort` takes.
    public static let efforts: [Effort] = ["low", "medium", "high", "xhigh", "max"]
    /// Until Claude Code answers `initialize`: its documented aliases.
    public static let fallbackModels: [CodingAgentModel] = [
        CodingAgentModel(id: "opus", name: "Opus", efforts: efforts),
        CodingAgentModel(id: "sonnet", name: "Sonnet", efforts: efforts),
        CodingAgentModel(id: "haiku", name: "Haiku")
    ]

    public static func arguments(for task: CodingTask) -> [String] {
        if task.sealed { return sealedArguments(for: task) }
        let mode: String
        switch task.access {
        case .readOnly: mode = "plan"
        case .askFirst: mode = "manual"
        case .autoEdit: mode = "acceptEdits"
        case .full: mode = "bypassPermissions"
        }
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                    "--permission-mode", mode, "--permission-prompt-tool", "stdio", "--permission-prompts", "host"]
        if task.access == .full { args += ["--allow-dangerously-skip-permissions"] }
        if task.access == .readOnly { args += ["--tools", "Read,Grep,Glob"] }
        if let model = task.model, !model.isEmpty { args += ["--model", model] }
        if let effort = task.effort, efforts.contains(effort) { args += ["--effort", effort.rawValue] }
        if let session = task.session, !session.isEmpty { args += ["--resume", session] }
        if !task.tools.isEmpty {
            args += ["--mcp-config", #"{"mcpServers":{"\#(serverName)":{"type":"sdk","name":"\#(serverName)"}}}"#,
                     "--allowedTools", task.tools.map { toolName($0.name) }.joined(separator: ",")]
        }
        return args
    }
    /// Built-in tools a sealed run never has.
    public static let sealedDenied = ["Bash", "BashOutput", "KillShell", "PowerShell", "WebFetch", "WebSearch", "NotebookEdit", "Task", "Agent",
                                      "SlashCommand", "Skill", "ExitPlanMode"]

    /// A sealed run's arguments (see the header): only its file tools, Tsukumo's settings, nothing of the owner's setup.
    public static func sealedArguments(for task: CodingTask) -> [String] {
        let writes = task.access != .readOnly
        let mode = writes ? "manual" : "plan"
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                    "--permission-mode", mode, "--permission-prompt-tool", "stdio", "--permission-prompts", "host",
                    "--restricted", "--safe-mode", "--disable-slash-commands", "--setting-sources", "", "--strict-mcp-config",
                    "--settings", sealedSettings(mode: mode),
                    "--tools", writes ? "Read,Grep,Glob,Edit,Write" : "Read,Grep,Glob",
                    "--disallowedTools", sealedDenied.joined(separator: ",")]
        for folder in task.readable { args += ["--add-dir", folder] }
        if let model = task.model, !model.isEmpty { args += ["--model", model] }
        if let effort = task.effort, efforts.contains(effort) { args += ["--effort", effort.rawValue] }
        if let session = task.session, !session.isEmpty { args += ["--resume", session] }
        if task.tools.isEmpty {
            args += ["--mcp-config", #"{"mcpServers":{}}"#]
        } else {
            args += ["--mcp-config", #"{"mcpServers":{"\#(serverName)":{"type":"sdk","name":"\#(serverName)"}}}"#,
                     "--allowedTools", task.tools.map { toolName($0.name) }.joined(separator: ",")]
        }
        return args
    }

    /// Tsukumo's own settings for a sealed run: every hook off, no allow rules, the permission mode, bypass disabled, and
    /// deny rules for every secret-file glob, always (a file the owner wants read anyway reaches Claude as Tsukumo's copy
    /// under a name no glob matches, never by loosening a rule). Claude Code enforces them even for reads it allows on its own.
    public static func sealedSettings(mode: String) -> String {
        var deny: [String] = sealedDenied
        for name in CodingAccessGate.secretNames { deny += ["Read(**/\(name))", "Edit(**/\(name))"] }
        for folder in CodingAccessGate.secretFolders { deny += ["Read(**/\(folder)/**)", "Edit(**/\(folder)/**)"] }
        let settings: [String: Any] = ["disableAllHooks": true,
                                       "permissions": ["allow": [String](), "deny": deny, "defaultMode": mode, "disableBypassPermissionsMode": "disable"]]
        let data = (try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// How Claude Code names one of Tsukumo's tools.
    public static func toolName(_ name: String) -> String { "mcp__\(serverName)__\(name)" }

    /// The owner's message.
    static func userMessage(_ text: String, session: String?) -> [String: Any] {
        ["type": "user", "message": ["role": "user", "content": text], "parent_tool_use_id": NSNull(), "session_id": session ?? ""]
    }
    static func initialize(id: String, tools: Bool) -> [String: Any] {
        var request: [String: Any] = ["subtype": "initialize"]
        if tools { request["sdkMcpServers"] = [serverName] }
        return ["type": "control_request", "request_id": id, "request": request]
    }
    static func interrupt(id: String) -> [String: Any] {
        ["type": "control_request", "request_id": id, "request": ["subtype": "interrupt"]]
    }
    static func controlResponse(_ id: String, _ response: [String: Any]) -> [String: Any] {
        ["type": "control_response", "response": ["subtype": "success", "request_id": id, "response": response]]
    }
    static func controlError(_ id: String, _ message: String) -> [String: Any] {
        ["type": "control_response", "response": ["subtype": "error", "request_id": id, "error": message]]
    }
    /// The answer to `can_use_tool`: allowed with its input unchanged, or denied with a reason the agent reads.
    static func permissionAnswer(allow: Bool, input: [String: Any]) -> [String: Any] {
        allow ? ["behavior": "allow", "updatedInput": input]
            : ["behavior": "deny", "message": "Not allowed: the owner's settings for this bot in Tsukumo don't allow it."]
    }

    /// What a tool's permission prompt asks, for `CodingAccessGate`; nil for Tsukumo's own tools, which are
    /// always allowed (KemoSabe and the policy decide what they return).
    public static func request(tool: String, input: [String: Any], directory: String) -> CodingAccessGate.Request? {
        if tool.hasPrefix("mcp__\(serverName)__") { return nil }
        let path = input.string("file_path") ?? input.string("notebook_path") ?? input.string("path")
        switch tool {
        case "Bash": return .command(input.string("command") ?? "")
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return .write(path: path ?? "")
        case "Read": return .read(path: path ?? "")
        case "Grep", "Glob", "LS": return .read(path: path ?? directory)
        case "WebFetch", "WebSearch": return .tool(kind: "fetch", paths: [])
        case "TodoWrite", "Task", "Agent": return .tool(kind: "think", paths: [])
        default: return .tool(kind: tool.lowercased(), paths: path.map { [$0] } ?? [])
        }
    }

    /// What a tool call shows about the agent's work.
    public static func activity(tool: String, input: [String: Any], id: String) -> CodingActivity? {
        let path = input.string("file_path") ?? input.string("notebook_path")
        switch tool {
        case "Read": return path.map { .reading(path: $0) }
        case "Edit":
            return path.map { .editing(path: $0, diff: patch(old: input.string("old_string") ?? "", new: input.string("new_string") ?? "")) }
        case "MultiEdit":
            let edits = input.objects("edits")
            return path.map { .editing(path: $0, diff: edits.map { patch(old: $0.string("old_string") ?? "", new: $0.string("new_string") ?? "") }.joined()) }
        case "Write": return path.map { .editing(path: $0, diff: patch(old: "", new: input.string("content") ?? "")) }
        case "NotebookEdit": return path.map { .editing(path: $0, diff: nil) }
        case "Bash": return .running(id: id, command: input.string("command") ?? "")
        case "TodoWrite":
            return .plan(input.objects("todos").map { todo in
                let state: CodingActivity.PlanStep.State = switch todo.string("status") { case "completed": .done; case "in_progress": .active; default: .pending }
                return CodingActivity.PlanStep(title: todo.string("content") ?? todo.string("activeForm") ?? "", state: state)
            })
        default: return nil
        }
    }
    /// A minimal patch: the old lines removed, the new ones added.
    static func patch(old: String, new: String) -> String {
        func lines(_ text: String, _ mark: String) -> String {
            text.isEmpty ? "" : text.split(separator: "\n", omittingEmptySubsequences: false).map { mark + $0 }.joined(separator: "\n") + "\n"
        }
        return "@@\n" + lines(old, "-") + lines(new, "+")
    }

    /// Claude Code's models from its `initialize` answer (`value`, `displayName`, `supportedEffortLevels`).
    public static func models(_ response: [String: Any]) -> [CodingAgentModel] {
        response.objects("models").compactMap { entry in
            guard let id = entry.string("value") else { return nil }
            return CodingAgentModel(id: id, name: entry.string("displayName") ?? id,
                                    efforts: (entry["supportedEffortLevels"] as? [String] ?? []).map(Effort.init(rawValue:)),
                                    isDefault: id == "default")
        }
    }

    /// The MCP server's answer to one JSON-RPC message from Claude Code, except `tools/call` (which the run
    /// answers when the tool returns). A notification gets an empty result.
    static func mcpAnswer(_ message: [String: Any], tools: [ToolDefinition]) -> [String: Any] {
        let id = message["id"] ?? 0
        func result(_ result: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": result] }
        switch message.string("method") ?? "" {
        case "initialize":
            let asked = message.object("params").string("protocolVersion") ?? "2025-06-18"
            return result(["protocolVersion": asked, "capabilities": ["tools": ["listChanged": false]],
                           "serverInfo": ["name": serverName, "title": "Tsukumo", "version": "1.0.0"]])
        case "tools/list":
            return result(["tools": tools.map(mcpTool)])
        case "ping": return result([:])
        default:
            if message["id"] == nil { return ["jsonrpc": "2.0", "result": [String: Any]()] }
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]]
        }
    }
    /// A Tsukumo tool as MCP lists it.
    static func mcpTool(_ tool: ToolDefinition) -> [String: Any] {
        ["name": tool.name, "description": tool.description, "inputSchema": inputSchema(tool)]
    }
    /// A tool's arguments as JSON Schema (every parameter a string).
    public static func inputSchema(_ tool: ToolDefinition) -> [String: Any] {
        var properties: [String: Any] = [:]
        for parameter in tool.parameters { properties[parameter.name] = ["type": "string", "description": parameter.description] }
        return ["type": "object", "properties": properties, "required": tool.parameters.filter(\.required).map(\.name)]
    }
    /// A tool call's arguments as strings.
    static func arguments(_ raw: Any?) -> [String: String] {
        guard let raw = raw as? [String: Any] else { return [:] }
        return raw.mapValues { value in (value as? String) ?? (value as? NSNumber)?.stringValue ?? String(describing: value) }
    }

    /// Why a turn failed, from its `result`; nil when it didn't.
    static func failure(_ result: [String: Any]) -> Error? {
        guard result["is_error"] as? Bool == true || (result.string("subtype").map { $0.hasPrefix("error") } ?? false) else { return nil }
        let words = ([result.string("result")] + (result["errors"] as? [String] ?? [])).compactMap { $0 }.joined(separator: " ")
        if words.contains("No conversation found") { return EngineError.sessionGone }
        if CodingRun.signInProblem(words) { return CodingAgentFailure("Sign in to Claude Code in its terminal (run claude), then try again.") }
        return CodingAgentFailure("Claude Code couldn’t finish: " + (words.isEmpty ? (result.string("subtype") ?? "an error") : String(words.prefix(400))))
    }
}

/// Claude Code on this Mac: one `claude -p` process per turn, continuing the chat's session.
public struct ClaudeCodeBackend: CodingAgentBackend {
    public let agentID = "claude-code"
    public let launch: CodingLaunch
    /// How long a stopped turn gets to wind down before its process group is ended.
    public let interruptGrace: TimeInterval
    private let registry = CodingRunRegistry()

    public init(launch: CodingLaunch, interruptGrace: TimeInterval = 3) { self.launch = launch; self.interruptGrace = interruptGrace }

    public func start(_ task: CodingTask) -> AsyncThrowingStream<CodingAgentEvent, Error> {
        var launch = launch
        if task.sealed { launch.environment = CodingEnvironment.sealed(from: launch.environment) }
        return ClaudeCodeRun(task: task, launch: launch, name: "Claude Code", interruptGrace: interruptGrace)
            .stream(arguments: ClaudeCode.arguments(for: task), registry: registry)
    }
    public func waitUntilStopped(timeout: TimeInterval) async -> Bool { await registry.waitUntilStopped(timeout: timeout) }
    public func respond(permission id: String, allow: Bool) async { registry.take(id)?.respond(permission: id, allow: allow) }
    public func respondTool(id: String, result: String) async { registry.take(id)?.respond(tool: id, result: result) }
}

final class ClaudeCodeRun: CodingRun {
    private var session: String?
    private var sentMessage = false
    private var messageID = ""
    /// Messages whose text came as stream deltas, so their whole copy isn't added again.
    private var streamed: Set<String> = []
    private var textSoFar = ""
    private var lastTextMessage = ""
    /// Open permission prompts: our ID → the control request's ID and the tool's input.
    private var permissions: [String: (request: String, input: [String: Any])] = [:]
    /// Open tool calls: our ID → the control request's ID and the MCP message's ID.
    private var toolCalls: [String: (request: String, rpc: Any)] = [:]
    private var bashCalls: Set<String> = []

    override func begin() throws {
        session = task.session
        try send(ClaudeCode.initialize(id: "\(tag)-init", tools: !task.tools.isEmpty))
        // A build that doesn't answer `initialize` still gets the message.
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, !self.ended else { return }
            do { try self.sendMessage() } catch { self.fail(error) }
        }
    }

    override func interrupt() -> Bool {
        (try? send(ClaudeCode.interrupt(id: "\(tag)-interrupt"))) != nil
    }

    private func sendMessage() throws {
        guard !sentMessage else { return }
        sentMessage = true
        try send(ClaudeCode.userMessage(task.prompt, session: session))
    }

    private func say(_ text: String, message: String) {
        guard !text.isEmpty else { return }
        if message != lastTextMessage, !textSoFar.isEmpty, !textSoFar.hasSuffix("\n") { yield(.text("\n\n")); textSoFar += "\n\n" }
        lastTextMessage = message
        textSoFar += text
        yield(.text(text))
    }

    override func receive(_ object: [String: Any]) throws {
        if let id = object.string("session_id"), !id.isEmpty, id != session {
            session = id
            yield(.session(id))
        }
        if ["system", "stream_event", "assistant", "user", "result"].contains(object.string("type") ?? "") { handshakeDone() }
        switch object.string("type") {
        case "control_response":
            let response = object.object("response")
            if response.string("request_id") == "\(tag)-init" { try sendMessage() }
        case "control_request":
            guard let id = object.string("request_id") else { return }
            try control(id, object.object("request"))
        case "stream_event":
            let event = object.object("event")
            switch event.string("type") {
            case "message_start": messageID = event.object("message").string("id") ?? UUID().uuidString
            case "content_block_delta":
                if let text = event.object("delta").string("text") { streamed.insert(messageID); say(text, message: messageID) }
            default: break
            }
        case "assistant":
            let message = object.object("message")
            let id = message.string("id") ?? UUID().uuidString
            for block in message.objects("content") {
                switch block.string("type") {
                case "text": if !streamed.contains(id) { say(block.string("text") ?? "", message: id) }
                case "tool_use":
                    let name = block.string("name") ?? "", toolID = block.string("id") ?? UUID().uuidString
                    if name == "Bash" { bashCalls.insert(toolID) }
                    if let activity = ClaudeCode.activity(tool: name, input: block.object("input"), id: toolID) { yield(.activity(activity)) }
                default: break
                }
            }
        case "user":
            for block in object.object("message").objects("content") where block.string("type") == "tool_result" {
                if let id = block.string("tool_use_id"), bashCalls.remove(id) != nil {
                    yield(.activity(.ran(id: id, failed: block["is_error"] as? Bool == true)))
                }
            }
        case "result":
            if let failure = ClaudeCode.failure(object) { return fail(failure) }
            if textSoFar.isEmpty, let text = object.string("result") { say(text, message: "result") }
            finish(session: session)
        default: break
        }
    }

    private func control(_ id: String, _ request: [String: Any]) throws {
        switch request.string("subtype") {
        case "can_use_tool":
            let tool = request.string("tool_name") ?? "", input = request.object("input")
            guard let asked = ClaudeCode.request(tool: tool, input: input, directory: task.directory) else {
                return try send(ClaudeCode.controlResponse(id, ClaudeCode.permissionAnswer(allow: true, input: input)))
            }
            let ours = nextID("permission")
            permissions[ours] = (id, input)
            yield(.permission(id: ours, request: asked))
        case "mcp_message":
            let message = request.object("message")
            guard request.string("server_name") == ClaudeCode.serverName else {
                return try send(ClaudeCode.controlError(id, "Unknown MCP server"))
            }
            if message.string("method") == "tools/call" {
                let params = message.object("params")
                let name = params.string("name") ?? ""
                guard task.tools.contains(where: { $0.name == name }) else {
                    return try send(ClaudeCode.controlResponse(id, ["mcp_response": ["jsonrpc": "2.0", "id": message["id"] ?? 0,
                                                                                      "error": ["code": -32602, "message": "Unknown tool"]]]))
                }
                let ours = nextID("tool")
                toolCalls[ours] = (id, message["id"] ?? 0)
                yield(.toolCall(ToolCall(id: ours, name: name, arguments: ClaudeCode.arguments(params["arguments"]))))
            } else {
                try send(ClaudeCode.controlResponse(id, ["mcp_response": ClaudeCode.mcpAnswer(message, tools: task.tools)]))
            }
        default:
            try send(ClaudeCode.controlError(id, "Tsukumo doesn't support this request."))
        }
    }

    override func answer(permission id: String, allow: Bool) throws {
        guard let open = permissions.removeValue(forKey: id) else { return }
        try send(ClaudeCode.controlResponse(open.request, ClaudeCode.permissionAnswer(allow: allow, input: open.input)))
    }
    override func answer(tool id: String, result: String) throws {
        guard let open = toolCalls.removeValue(forKey: id) else { return }
        let answer: [String: Any] = ["jsonrpc": "2.0", "id": open.rpc, "result": ["content": [["type": "text", "text": result]], "isError": false]]
        try send(ClaudeCode.controlResponse(open.request, ["mcp_response": answer]))
    }
}
#endif

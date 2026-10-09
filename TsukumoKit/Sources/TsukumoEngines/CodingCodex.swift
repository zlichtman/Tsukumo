#if os(macOS)
import Foundation
import TsukumoCore

// Codex through `codex app-server` over stdio (ported from `CodingAgentSession` in the old Tsukumo app,
// where it ran in production; the protocol checked against the installed codex-cli 0.160.0's own schema,
// `codex app-server generate-ts --experimental`, on October 4, 2026). JSON-RPC without the "jsonrpc" field:
// `initialize` (with `experimentalApi`), `initialized`, then `thread/start` (or `thread/resume` with the
// chat's thread) with the folder, the sandbox and approval policy for the bot's access, and Tsukumo's tools
// as dynamic tools; then `turn/start`. Approvals arrive as `item/commandExecution/requestApproval` and
// `item/fileChange/requestApproval` (answered accept or decline), Tsukumo's tools as `item/tool/call`.

/// Codex app-server's wire format.
public enum Codex {
    public static let arguments = ["app-server", "--listen", "stdio://"]

    /// The sandbox Codex enforces and when it asks, for each access level.
    public static func policy(_ access: BotPermissions.Access) -> (sandbox: String, approval: String) {
        switch access {
        case .readOnly: ("read-only", "on-request")
        case .askFirst: ("workspace-write", "untrusted")
        case .autoEdit: ("workspace-write", "on-request")
        case .full: ("danger-full-access", "never")
        }
    }
    static func initialize(id: String) -> [String: Any] {
        ["id": id, "method": "initialize", "params": ["clientInfo": ["name": "tsukumo", "title": "Tsukumo", "version": "1.0.0"],
                                                      "capabilities": ["experimentalApi": true]]]
    }
    /// A new thread, or the chat's thread again.
    static func thread(id: String, task: CodingTask, resume: Bool) -> [String: Any] {
        let policy = policy(task.access)
        var params: [String: Any] = ["cwd": task.directory, "approvalPolicy": policy.approval, "sandbox": policy.sandbox]
        if let model = task.model, !model.isEmpty { params["model"] = model }
        if resume, let session = task.session {
            params["threadId"] = session
            return ["id": id, "method": "thread/resume", "params": params]
        }
        if !task.tools.isEmpty { params["dynamicTools"] = task.tools.map(dynamicTool) }
        return ["id": id, "method": "thread/start", "params": params]
    }
    static func dynamicTool(_ tool: ToolDefinition) -> [String: Any] {
        ["type": "function", "name": tool.name, "description": tool.description, "inputSchema": ClaudeCode.inputSchema(tool)]
    }
    static func turn(id: String, thread: String, task: CodingTask) -> [String: Any] {
        var params: [String: Any] = ["threadId": thread, "input": [["type": "text", "text": task.prompt, "text_elements": [Any]()]]]
        if let model = task.model, !model.isEmpty { params["model"] = model }
        if let effort = task.effort, !effort.rawValue.isEmpty { params["effort"] = effort.rawValue }
        return ["id": id, "method": "turn/start", "params": params]
    }

    /// Codex's models from `model/list` (hidden ones left out), with each model's efforts.
    public static func models(_ result: [String: Any]) -> [CodingAgentModel] {
        result.objects("data").compactMap { entry in
            guard let id = entry.string("model") ?? entry.string("id"), entry["hidden"] as? Bool != true else { return nil }
            let efforts = entry.objects("supportedReasoningEfforts").compactMap { $0.string("reasoningEffort") }.map(Effort.init(rawValue:))
            return CodingAgentModel(id: id, name: entry.string("displayName") ?? id, efforts: efforts,
                                    defaultEffort: entry.string("defaultReasoningEffort").map(Effort.init(rawValue:)),
                                    isDefault: entry["isDefault"] as? Bool == true)
        }
    }

    /// An item's work, when it shows some: a command starting or ending, or files changing.
    static func activity(_ item: [String: Any], completed: Bool) -> [CodingActivity] {
        let id = item.string("id") ?? ""
        switch item.string("type") {
        case "commandExecution":
            if completed {
                let failed = item.string("status") == "failed" || ((item["exitCode"] as? Int).map { $0 != 0 } ?? false)
                return [.ran(id: id, failed: failed)]
            }
            return [.running(id: id, command: item.string("command") ?? "")]
        case "fileChange" where !completed:
            return item.objects("changes").compactMap { change in change.string("path").map { .editing(path: $0, diff: change.string("diff")) } }
        default: return []
        }
    }
    /// The plan from `turn/plan/updated`.
    static func plan(_ params: [String: Any]) -> CodingActivity {
        .plan(params.objects("plan").map { step in
            let state: CodingActivity.PlanStep.State = switch step.string("status") { case "completed": .done; case "inProgress", "in_progress": .active; default: .pending }
            return CodingActivity.PlanStep(title: step.string("step") ?? "", state: state)
        })
    }
    static func failure(_ message: String) -> CodingAgentFailure {
        CodingRun.signInProblem(message) || message.contains("401")
            ? CodingAgentFailure("Sign in to Codex in its terminal (run codex login), then try again.")
            : CodingAgentFailure("Codex couldn’t finish: " + String(message.prefix(400)))
    }
}

/// Codex on this Mac: one `codex app-server` per turn, continuing the chat's thread.
public struct CodexBackend: CodingAgentBackend {
    public let agentID = "codex"
    public let launch: CodingLaunch
    public let interruptGrace: TimeInterval
    private let registry = CodingRunRegistry()

    public init(launch: CodingLaunch, interruptGrace: TimeInterval = 3) { self.launch = launch; self.interruptGrace = interruptGrace }

    public func start(_ task: CodingTask) -> AsyncThrowingStream<CodingAgentEvent, Error> {
        CodexRun(task: task, launch: launch, name: "Codex", interruptGrace: interruptGrace).stream(arguments: Codex.arguments, registry: registry)
    }
    public func waitUntilStopped(timeout: TimeInterval) async -> Bool { await registry.waitUntilStopped(timeout: timeout) }
    public func respond(permission id: String, allow: Bool) async { registry.take(id)?.respond(permission: id, allow: allow) }
    public func respondTool(id: String, result: String) async { registry.take(id)?.respond(tool: id, result: result) }
}

final class CodexRun: CodingRun {
    private var thread: String?
    private var turnID: String?
    private var requests: [String: String] = [:]
    private var sequence = 0
    /// Open server requests: our ID → the JSON-RPC ID.
    private var open: [String: Any] = [:]
    /// Each file change's paths, by item, for the approval that asks to apply it.
    private var changes: [String: [String]] = [:]
    private var deltaItems: Set<String> = []
    private var lastItem = ""
    private var textSoFar = ""

    private func request(_ build: (String) -> [String: Any]) throws {
        sequence += 1
        let id = "\(tag)-\(sequence)"
        let message = build(id)
        requests[id] = message.string("method") ?? ""
        try send(message)
    }

    override func begin() throws { try request { Codex.initialize(id: $0) } }

    override func interrupt() -> Bool {
        guard let thread, let turnID else { return false }
        return (try? send(["id": "\(tag)-interrupt", "method": "turn/interrupt", "params": ["threadId": thread, "turnId": turnID]])) != nil
    }

    private func say(_ text: String, item: String) {
        guard !text.isEmpty else { return }
        if item != lastItem, !textSoFar.isEmpty, !textSoFar.hasSuffix("\n") { yield(.text("\n\n")); textSoFar += "\n\n" }
        lastItem = item
        textSoFar += text
        yield(.text(text))
    }

    override func receive(_ object: [String: Any]) throws {
        if let id = object["id"].map({ String(describing: $0) }), let method = requests.removeValue(forKey: id) {
            return try answered(method, object)
        }
        guard let method = object.string("method") else { return }
        let params = object.object("params")
        if let id = object["id"] { return try serverRequest(id: id, method: method, params: params) }
        if let other = params.string("threadId"), let thread, other != thread { return }   // a subagent's thread
        switch method {
        case "turn/started": turnID = params.object("turn").string("id") ?? turnID
        case "item/agentMessage/delta":
            let item = params.string("itemId") ?? ""
            deltaItems.insert(item)
            say(params.string("delta") ?? "", item: item)
        case "item/started", "item/completed":
            let item = params.object("item")
            if item.string("type") == "fileChange", let id = item.string("id") {
                changes[id] = item.objects("changes").compactMap { $0.string("path") }
            }
            if method == "item/completed", item.string("type") == "agentMessage", let id = item.string("id"), !deltaItems.contains(id) {
                say(item.string("text") ?? "", item: id)
            }
            for activity in Codex.activity(item, completed: method == "item/completed") { yield(.activity(activity)) }
        case "turn/plan/updated": yield(.activity(Codex.plan(params)))
        case "turn/completed":
            let turn = params.object("turn")
            switch turn.string("status") {
            case "completed": finish(session: thread)
            case "interrupted": fail(CancellationError())
            default: fail(Codex.failure(turn.object("error").string("message") ?? "the turn failed"))
            }
        default: break
        }
    }

    private func answered(_ method: String, _ object: [String: Any]) throws {
        if let error = object["error"] as? [String: Any] {
            let message = error.string("message") ?? "Codex refused \(method)."
            // The chat's thread is gone: a new one starts, and the engine sends the conversation so far.
            if method == "thread/resume" { return fail(EngineError.sessionGone) }
            return fail(Codex.failure(message))
        }
        let result = object.object("result")
        switch method {
        case "initialize":
            try send(["method": "initialized"])
            try request { Codex.thread(id: $0, task: task, resume: task.session != nil) }
        case "thread/start", "thread/resume":
            guard let id = result.object("thread").string("id") else { throw CodingAgentFailure("Codex didn’t return a thread.") }
            thread = id
            handshakeDone()
            try request { Codex.turn(id: $0, thread: id, task: task) }
        case "turn/start": turnID = result.object("turn").string("id") ?? turnID
        default: break
        }
    }

    private func serverRequest(id: Any, method: String, params: [String: Any]) throws {
        switch method {
        case "item/commandExecution/requestApproval":
            let ours = nextID("permission")
            open[ours] = id
            yield(.permission(id: ours, request: .command(params.string("command") ?? "a command")))
        case "item/fileChange/requestApproval":
            let ours = nextID("permission")
            open[ours] = id
            let paths = changes[params.string("itemId") ?? ""] ?? []
            yield(.permission(id: ours, request: .tool(kind: "edit", paths: paths)))
        case "item/tool/call":
            let name = params.string("tool") ?? ""
            guard task.tools.contains(where: { $0.name == name }) else {
                return try send(["id": id, "result": ["contentItems": [["type": "inputText", "text": "Unknown tool."]], "success": false]])
            }
            let ours = nextID("tool")
            open[ours] = id
            yield(.toolCall(ToolCall(id: ours, name: name, arguments: ClaudeCode.arguments(params["arguments"]))))
        case "item/tool/requestUserInput":
            // Nobody is at a prompt in the dock: each question gets the same honest answer.
            var answers: [String: Any] = [:]
            for question in params.objects("questions") {
                if let key = question.string("id") { answers[key] = ["answers": ["The owner can’t answer questions here. Use your best judgment and say what you assumed."]] }
            }
            try send(["id": id, "result": ["answers": answers]])
        default:
            try send(["id": id, "error": ["code": -32601, "message": "Tsukumo doesn't support \(method)."]])
        }
    }

    override func answer(permission id: String, allow: Bool) throws {
        guard let rpc = open.removeValue(forKey: id) else { return }
        try send(["id": rpc, "result": ["decision": allow ? "accept" : "decline"]])
    }
    override func answer(tool id: String, result: String) throws {
        guard let rpc = open.removeValue(forKey: id) else { return }
        try send(["id": rpc, "result": ["contentItems": [["type": "inputText", "text": result]], "success": true]])
    }
}
#endif

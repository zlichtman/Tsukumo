#if os(macOS)
import Foundation
import TsukumoCore

/// What a coding agent's request gets under the bot's access (ported from the Mac app's
/// `CodingAccessGate`): allowed, asked of the owner, or refused. The same four modes as Claude
/// Code's and Codex's own.
public enum CodingAccessGate {
    public enum Decision: Hashable, Sendable { case allow, ask, deny(String) }
    public enum Request: Hashable, Sendable {
        case read(path: String)
        case write(path: String)
        case command(String)
        /// An agent's own tool asking permission: its kind ("edit", "execute") and the paths it names.
        case tool(kind: String, paths: [String])

        public var summary: String {
            switch self {
            case .read(let path): "Read \(path)"
            case .write(let path): "Edit \(path)"
            case .command(let command): "Run \(command)"
            case .tool(let kind, let paths): kind.capitalized + (paths.isEmpty ? "" : " " + paths.joined(separator: ", "))
            }
        }
    }

    public static func decide(_ request: Request, access: BotPermissions.Access, directory: String) -> Decision {
        func inside(_ path: String) -> Bool { CodingAccessGate.inside(path, directory) }
        switch (request, access) {
        case (_, .full): return .allow
        case (.read(let path), _): return inside(path) ? .allow : .ask
        case (.write, .readOnly): return .deny("Read only: this bot changes nothing.")
        case (.write, .askFirst): return .ask
        case (.write(let path), .autoEdit): return inside(path) ? .allow : .ask
        case (.command, .readOnly): return .deny("Read only: this bot doesn't run commands.")
        case (.command, _): return .ask
        case (.tool(let kind, let paths), _):
            switch kind {
            case "read", "search", "think", "fetch": return paths.allSatisfy(inside) ? .allow : .ask
            case "edit", "delete", "move":
                if access == .readOnly { return .deny("Read only: this bot changes nothing.") }
                if access == .autoEdit, !paths.isEmpty, paths.allSatisfy(inside) { return .allow }
                return .ask
            case "execute": return access == .readOnly ? .deny("Read only: this bot doesn't run commands.") : .ask
            default: return access == .readOnly ? .deny("Read only: this bot changes nothing.") : .ask
            }
        }
    }

    /// Whether a path is inside the bot's folder (after resolving `..` and links).
    public static func inside(_ path: String, _ directory: String) -> Bool {
        guard !path.isEmpty, !directory.isEmpty else { return false }
        let base = URL(fileURLWithPath: directory).standardizedFileURL.resolvingSymlinksInPath().path
        let target = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: directory, isDirectory: true)).standardizedFileURL
        let resolved = FileManager.default.fileExists(atPath: target.path) ? target.resolvingSymlinksInPath().path
            : target.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(target.lastPathComponent).path
        return resolved == base || resolved.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }
}

/// One task for a coding agent: the message, where it works, and how.
public struct CodingTask: Hashable, Sendable {
    public let prompt: String
    public let directory: String
    public let model: String?
    public let effort: Effort?
    /// The agent's own session to continue (`claude --resume`), when there is one.
    public let session: String?
}

/// What a coding agent CLI reports while it works.
public enum CodingAgentEvent: Hashable, Sendable {
    case text(String)
    /// It called a tool Tsukumo serves (`ask_kemosabe`, `read_reference`) over MCP.
    case toolCall(ToolCall)
    /// It wants to do something; answer with `respond(permission:allow:)`.
    case permission(id: String, request: CodingAccessGate.Request)
    /// Finished; its session handle to continue next time.
    case finished(session: String?)
}

/// A coding agent CLI on this Mac (Claude Code, Codex, Muse Code, Cursor Agent, any ACP agent),
/// running headless on the owner's own sign-in. Real adapters come later; tests use a fake.
public protocol CodingAgentBackend: Sendable {
    /// "claude-code", "codex", "acp:<id>".
    var agentID: String { get }
    func start(_ task: CodingTask) -> AsyncThrowingStream<CodingAgentEvent, Error>
    func respond(permission id: String, allow: Bool) async
    func respondTool(id: String, result: String) async
}

/// Runs a turn on a coding agent. Every permission the agent asks for goes through the bot's
/// access first (read only unless its permissions say otherwise); only an "ask" reaches the owner.
public struct CodingAgentEngine: Engine {
    public let backend: any CodingAgentBackend
    /// The bot's project folder, when it has none.
    public let defaultDirectory: String
    public var id: EngineID { .codingAgent(backend.agentID) }

    public init(backend: any CodingAgentBackend, defaultDirectory: String = NSTemporaryDirectory()) {
        self.backend = backend; self.defaultDirectory = defaultDirectory
    }

    public func run(_ turn: EngineTurn) -> AsyncThrowingStream<EngineEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let directory = turn.bot.contextScope.project ?? defaultDirectory
                let access = turn.bot.permissions.access
                let prompt = turn.systemPrompt + "\n\n" + turn.message
                var text = "", calls: [ToolCall] = []
                do {
                    for try await event in backend.start(CodingTask(prompt: prompt, directory: directory, model: turn.bot.model,
                                                                    effort: turn.bot.effort, session: nil)) {
                        try Task.checkCancellation()
                        switch event {
                        case .text(let delta):
                            text += delta
                            continuation.yield(.text(delta))
                        case .toolCall(let call):
                            calls.append(call)
                            continuation.yield(.toolCall(call))
                            let result = await turn.runTool?(call) ?? "That tool isn't available in this chat."
                            continuation.yield(.toolResult(id: call.id, text: result))
                            await backend.respondTool(id: call.id, result: result)
                        case .permission(let id, let request):
                            let allowed: Bool
                            switch CodingAccessGate.decide(request, access: access, directory: directory) {
                            case .allow: allowed = true
                            case .deny: allowed = false
                            case .ask:
                                let approval = ApprovalRequest(id: id, summary: request.summary)
                                continuation.yield(.approvalRequested(approval))
                                allowed = await turn.approve?(approval) ?? false
                            }
                            continuation.yield(.approvalDecided(id: id, allowed: allowed))
                            await backend.respond(permission: id, allow: allowed)
                        case .finished(let session):
                            continuation.yield(.done(EngineReply(text: text, toolCalls: calls, session: session)))
                            continuation.finish()
                            return
                        }
                    }
                    throw EngineError.incomplete
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif

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

    /// A sealed agent's requests (the Claude bot): nothing outside its folder (or the folders it may read, where the
    /// owner's own copies of files go), ever (refused, never offered to the owner on a card); no secret-named files in
    /// its folder, with no exceptions; no commands and no web; edits only inside its folder and only as its access allows.
    public static func decideSealed(_ request: Request, access: BotPermissions.Access, directory: String, readable: [String] = []) -> Decision {
        func inside(_ path: String) -> Bool { CodingAccessGate.inside(path, directory) }
        func secret(_ path: String) -> Bool { CodingAccessGate.isSecret(path) }
        func given(_ path: String) -> Bool { readable.contains { CodingAccessGate.inside(path, $0) } && !secret(path) }
        let outside = Decision.deny("Claude works only in its own folder.")
        let hidden = Decision.deny("That looks like a secret file (keys, passwords, credentials), so Claude doesn't open it.")
        func write(_ paths: [String]) -> Decision {
            guard !paths.isEmpty, paths.allSatisfy(inside) else { return outside }
            if paths.contains(where: secret) { return hidden }
            switch access {
            case .readOnly: return .deny("Read only: Claude changes nothing.")
            case .askFirst: return .ask
            case .autoEdit, .full: return .allow
            }
        }
        switch request {
        case .read(let path):
            if given(path) { return .allow }
            guard inside(path) else { return outside }
            return secret(path) ? hidden : .allow
        case .write(let path): return write([path])
        case .command: return .deny("Claude doesn't run commands.")
        case .tool(let kind, let paths):
            switch kind {
            case "read", "search":
                if !paths.isEmpty, paths.allSatisfy(given) { return .allow }
                guard paths.allSatisfy(inside) else { return outside }
                return paths.contains(where: secret) ? hidden : .allow
            case "think": return .allow
            case "edit", "delete", "move": return write(paths)
            default: return .deny("Claude can't use that here.")
            }
        }
    }

    /// File names that hold secrets (keys, passwords, credentials), as globs.
    public static let secretNames = [".env", ".env.*", "*.pem", "*.key", "*.p12", "*.pfx", "*.keychain", "*.keychain-db", "id_rsa*", "id_ed25519*",
                                     "id_ecdsa*", "id_dsa*", ".netrc", ".npmrc", ".pypirc", ".git-credentials", "credentials", "credentials.json",
                                     "*.kdbx", "*.ovpn"]
    /// Folders that hold secrets, anywhere along a path.
    public static let secretFolders = [".ssh", ".aws", ".gnupg", ".kube", ".docker", ".azure", "gcloud", "Keychains", ".password-store"]

    /// Whether a path looks like a secret file (by its name, or a folder along it).
    public static func isSecret(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        let parts = path.split(separator: "/").map(String.init)
        if parts.dropLast().contains(where: secretFolders.contains) || secretFolders.contains(name) { return true }
        return secretNames.contains { fnmatch($0, name, FNM_CASEFOLD) == 0 }
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
    /// The bot's access: the agent is started in the matching mode of its own, and every request it makes
    /// still goes through `CodingAccessGate`.
    public let access: BotPermissions.Access
    /// Tsukumo's tools it may call (`ask_kemosabe`, `read_reference`), served in this Mac app.
    public let tools: [ToolDefinition]
    /// Sealed (the Claude bot): the agent runs with none of the owner's own setup for it (settings, hooks, allow
    /// rules, plugins, memory files, MCP servers), a minimal environment, only its file tools, and Tsukumo's permission
    /// callback for everything else. Requests are decided by `CodingAccessGate.decideSealed`.
    public let sealed: Bool
    /// Folders a sealed agent may also read (never write): where Tsukumo puts copies of files the owner gave it.
    public let readable: [String]

    public init(prompt: String, directory: String, model: String? = nil, effort: Effort? = nil, session: String? = nil,
                access: BotPermissions.Access = .readOnly, tools: [ToolDefinition] = [], sealed: Bool = false, readable: [String] = []) {
        self.prompt = prompt; self.directory = directory; self.model = model; self.effort = effort; self.session = session
        self.access = access; self.tools = tools; self.sealed = sealed; self.readable = readable
    }
}

/// What a coding agent CLI reports while it works.
public enum CodingAgentEvent: Hashable, Sendable {
    case text(String)
    /// It called a tool Tsukumo serves (`ask_kemosabe`, `read_reference`); answer with `respondTool(id:result:)`.
    case toolCall(ToolCall)
    /// It wants to do something; answer with `respond(permission:allow:)`.
    case permission(id: String, request: CodingAccessGate.Request)
    /// What it's doing (files it reads or edits, commands, its plan).
    case activity(CodingActivity)
    /// Its session handle, as soon as it's known (so a host can keep it before the turn ends).
    case session(String)
    /// Finished; its session handle to continue next time.
    case finished(session: String?)
}

/// A coding agent CLI on this Mac (Claude Code, Codex, Cursor Agent, any ACP agent), running headless on
/// the owner's own sign-in: `ClaudeCodeBackend`, `CodexBackend`, `ACPBackend`. Tests use fakes.
public protocol CodingAgentBackend: Sendable {
    /// "claude-code", "codex", "cursor-agent", "acp:<id>".
    var agentID: String { get }
    func start(_ task: CodingTask) -> AsyncThrowingStream<CodingAgentEvent, Error>
    func respond(permission id: String, allow: Bool) async
    func respondTool(id: String, result: String) async
    /// Waits until every process this backend started has exited: at most `timeout`, then their process groups are
    /// killed (SIGKILL) and it waits a little longer for them to be reaped. False when one still hasn't exited.
    func waitUntilStopped(timeout: TimeInterval) async -> Bool
}

public extension CodingAgentBackend {
    func waitUntilStopped(timeout: TimeInterval) async -> Bool { true }
}

/// Runs a turn on a coding agent. Every permission the agent asks for goes through the bot's
/// access first (read only unless its permissions say otherwise); only an "ask" reaches the owner.
/// The agent's own session continues across turns in a chat (`EngineTurn.session`); when it can't be
/// found any more, a new one starts with the conversation so far.
public struct CodingAgentEngine: Engine {
    public let backend: any CodingAgentBackend
    /// The bot's folder when it has no project.
    public let defaultDirectory: String
    /// Sealed (the Claude bot): see `CodingTask.sealed`.
    public let sealed: Bool
    /// Folders a sealed agent may also read (`CodingTask.readable`).
    public let readable: [String]
    public var id: EngineID {
        backend.agentID.hasPrefix("acp:") ? .acp(String(backend.agentID.dropFirst(4))) : .codingAgent(backend.agentID)
    }

    public init(backend: any CodingAgentBackend, defaultDirectory: String = NSTemporaryDirectory(), sealed: Bool = false, readable: [String] = []) {
        self.backend = backend; self.defaultDirectory = defaultDirectory; self.sealed = sealed; self.readable = readable
    }

    /// What the agent is sent: the bot's identity and the conversation so far for a new session; only the
    /// message (with this turn's references) for a continued one, which already has the rest.
    public static func prompt(for turn: EngineTurn, continuing: Bool) -> String {
        if continuing { return [turn.referencePrompt, turn.message].compactMap { $0 }.joined(separator: "\n\n") }
        var parts = [turn.systemPrompt]
        if !turn.history.isEmpty {
            let lines = turn.history.map { ($0.role == .user ? "Owner: " : "You: ") + $0.text }
            parts.append("The conversation so far:\n" + lines.joined(separator: "\n\n"))
        }
        parts.append(turn.message)
        return parts.joined(separator: "\n\n")
    }

    public func run(_ turn: EngineTurn) -> AsyncThrowingStream<EngineEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let directory = turn.bot.contextScope.project ?? defaultDirectory
                var text = "", calls: [ToolCall] = []
                var session = turn.session
                do {
                    while true {
                        let codingTask = CodingTask(prompt: Self.prompt(for: turn, continuing: session != nil), directory: directory,
                                                    model: turn.bot.model, effort: turn.bot.effort, session: session,
                                                    access: turn.bot.permissions.access, tools: turn.runTool == nil ? [] : turn.tools,
                                                    sealed: sealed, readable: readable)
                        do {
                            let finished = try await perform(codingTask, turn: turn, directory: directory, text: &text, calls: &calls,
                                                             continuation: continuation)
                            continuation.yield(.done(EngineReply(text: text, toolCalls: calls, session: finished)))
                            continuation.finish()
                            return
                        } catch EngineError.sessionGone where session != nil && text.isEmpty {
                            session = nil   // Start over in a new session, with the conversation so far.
                        }
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func perform(_ codingTask: CodingTask, turn: EngineTurn, directory: String, text: inout String, calls: inout [ToolCall],
                         continuation: AsyncThrowingStream<EngineEvent, Error>.Continuation) async throws -> String? {
        let access = turn.bot.permissions.access
        for try await event in backend.start(codingTask) {
            try Task.checkCancellation()
            switch event {
            case .text(let delta):
                text += delta
                continuation.yield(.text(delta))
            case .activity(let activity):
                continuation.yield(.activity(activity))
            case .toolCall(let call):
                calls.append(call)
                continuation.yield(.toolCall(call))
                let result = await turn.runTool?(call) ?? "That tool isn't available in this chat."
                continuation.yield(.toolResult(id: call.id, text: result))
                await backend.respondTool(id: call.id, result: result)
            case .permission(let id, let request):
                let allowed: Bool
                let decision = sealed ? CodingAccessGate.decideSealed(request, access: access, directory: directory, readable: readable)
                    : CodingAccessGate.decide(request, access: access, directory: directory)
                switch decision {
                case .allow: allowed = true
                case .deny: allowed = false
                case .ask:
                    let approval = ApprovalRequest(id: id, summary: Self.summary(request, directory: directory))
                    continuation.yield(.approvalRequested(approval))
                    allowed = await turn.approve?(approval) ?? false
                }
                continuation.yield(.approvalDecided(id: id, allowed: allowed))
                await backend.respond(permission: id, allow: allowed)
            case .session(let session):
                turn.onSession?(session)
            case .finished(let session):
                return session
            }
        }
        try Task.checkCancellation()
        throw EngineError.incomplete
    }

    /// What the owner reads on an approval: paths inside the bot's folder are shown relative to it.
    static func summary(_ request: CodingAccessGate.Request, directory: String) -> String {
        func short(_ path: String) -> String {
            let base = directory.hasSuffix("/") ? directory : directory + "/"
            return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
        }
        switch request {
        case .read(let path): return "Read " + short(path)
        case .write(let path): return "Edit " + short(path)
        case .command(let command): return "Run " + command
        case .tool(let kind, let paths): return kind.capitalized + (paths.isEmpty ? "" : " " + paths.map(short).joined(separator: ", "))
        }
    }
}
#endif

import Foundation
import Observation
import SwiftUI

// Chatting with an agent in the KemoSabe chat (design/CONTEXT-HARNESS.md#chatting-with-an-agent). Each
// message you send in a chat with Claude Code, Codex, Muse Code, Cursor Agent, or an ACP agent added in
// Tsukumo runs one turn of that agent, headless, on your own sign-in, through the same session Tsukumo's
// adapter runs it with (`CodingAgentSession` for Claude Code and Codex, `CodingMuseSession`,
// `CodingACPSession`), continuing the chat's own session, in a neutral folder for this chat under
// Application Support, with the KemoSabe MCP server attached (`--handoff <chat>`). It may ask KemoSabe and
// search or read the web; anything else it asks to do (a command, an edit) is declined. When it asks
// `ask_kemosabe`, Kemo answers on this Mac with Apple's on-device model, on its card in the chat
// (`ChatHandoffTranscript`). Only your message goes to the agent; the chat's history stays with the
// agent's own session, and Kemo's data stays here. A chat on the owner's iPhone runs its turns here too
// (`KemoSabeRelay`, Settings → Models → Agents on your Mac) through `startTurn`; those never show in this
// Mac's chats, and the iPhone's own KemoSabe answers their questions.

@MainActor @Observable final class KemoSabeHandoff {
    static let shared = KemoSabeHandoff()
    /// Chats whose agent turn is still running.
    private(set) var running: Set<UUID> = []

    /// Each agent, headless, as Tsukumo's adapter runs it, with the chat's own flags and `--handoff`.
    static let agentSession: @MainActor (CodingTaskRecord, UUID) -> any AgentSession = { task, id in
        switch task.provider {
        case .claude:
            let session = CodingAgentSession(task: task)
            session.handoff = id.uuidString
            session.extraClaudeArguments = KemoSabeHandoff.claudeFlags
            return session
        case .codex:
            let session = CodingAgentSession(task: task)
            session.handoff = id.uuidString
            session.extraCodexArguments = KemoSabeHandoff.codexFlags
            return session
        case .muse:
            let session = CodingMuseSession(task: task)
            session.handoff = id.uuidString
            session.extraServeArguments = KemoSabeHandoff.museFlags
            return session
        default:
            let session = CodingACPSession(task: task, launch: KemoSabeHandoff.launch(task.provider))
            session.handoff = id.uuidString
            return session
        }
    }
    /// The same runner, by the name earlier builds and tests use.
    static let claudeSession = KemoSabeHandoff.agentSession
    /// Starts the agent for a turn. Its real CLI by default; the DEBUG fixture and tests play fakes.
    @ObservationIgnored var makeSession: @MainActor (CodingTaskRecord, UUID) -> any AgentSession = KemoSabeHandoff.agentSession

    // MARK: Each agent's flags

    /// Claude Code: only the KemoSabe server (none of the owner's other MCP servers), the tools a chat
    /// needs without asking, and what Claude should know about where it's talking. Anything else it
    /// asks to do is declined (`decision`).
    static let claudeFlags = ["--strict-mcp-config", "--allowedTools", "mcp__kemosabe__ask_kemosabe,WebSearch,WebFetch",
                              "--append-system-prompt", systemPrompt]
    /// Codex (app-server, in a read-only sandbox): no shell, no computer or browser use, and none of
    /// its connected apps, so it can only answer, search the web, and ask KemoSabe. The KemoSabe tool
    /// needs no approval (`KemoSabeMCP.codexLaunchArguments(handoff:)`).
    static let codexFlags = ["-c", "features.shell_tool=false", "-c", "features.unified_exec=false", "-c", "features.computer_use=false",
                             "-c", "features.browser_use=false", "-c", "features.apps=false"]
    /// Muse Code (`muse serve`): no writes and no shell for this host.
    static let museFlags = ["--disable-write", "--disable-shell"]
    static let systemPrompt = """
        You're chatting with the person in their KemoSabe app on their Mac. Their companion, KemoSabe, is in the chat \
        too. You can't see their private messages, notes, or calendar. When you need a personal fact (for example \
        when someone is free), call the ask_kemosabe tool with one specific question and a short purpose: KemoSabe \
        reads their data on their Mac and returns only the answer. Don't run commands or change files. Reply the \
        way a person would in a chat: short and direct; for a recommendation, one place, a time, and one line on why.
        """
    /// Agents without a system prompt flag get the same words ahead of a chat's first message; their
    /// own session keeps them.
    static func firstMessage(_ text: String) -> String { "(From KemoSabe, about this chat) " + systemPrompt + "\n\n" + text }
    /// How each agent runs a chat: Codex in its read-only sandbox (with no shell); the others asking
    /// before anything, so `decision` answers.
    static func access(for provider: CodingProvider) -> CodingAccess { provider == .codex ? .readOnly : .edit }
    /// An ACP agent's launch: Cursor Agent's, or one the owner added in Settings → Agents.
    static func launch(_ provider: CodingProvider) -> CodingACPLaunch {
        if provider == .cursor { return CursorAgentAdapter().launch }
        if let agent = CodingAgentRegistry.shared.custom.first(where: { $0.provider == provider }) { return CustomACPAdapter(agent: agent).launch }
        return .init(command: "missing-agent", arguments: [], environment: .allowList([]), name: provider.title)
    }

    /// What a chat's agent may do without you: ask KemoSabe, and search or read the web. Anything else
    /// it asks (a command, an edit, a file outside its empty folder) is declined with a note.
    static func decision(for approval: CodingApproval) -> CodingApprovalDecision {
        let names = [approval.tool, approval.title].compactMap { $0?.lowercased() }
        if names.contains(where: { $0.contains("ask_kemosabe") }) { return .allowOnce }
        if approval.kind == .command, approval.command == nil, let tool = approval.tool?.lowercased(), webTools.contains(tool) { return .allowOnce }
        return .deny(note: declineNote)
    }
    static let webTools: Set<String> = ["websearch", "webfetch", "web_search", "web_fetch", "search_web", "fetch_url"]
    static let declineNote = "In a KemoSabe chat you don't run commands or change files. Answer with what you have."

    // MARK: Agents by chat ID

    /// The coding agent for a chat's agent ID ("codex" → Codex); nil for one Tsukumo doesn't know.
    static func provider(for agent: String) -> CodingProvider? {
        switch agent {
        case ChatAgents.claude.id: .claude
        case ChatAgents.codex.id: .codex
        case ChatAgents.muse.id: .muse
        case ChatAgents.cursor.id: .cursor
        default: agent.hasPrefix("acp:") ? CodingProvider(agent) : nil
        }
    }
    /// A chat's agent ID for a coding agent: "claude-code", "codex", "muse", "cursor-agent", "acp:<id>".
    static func agentID(for provider: CodingProvider) -> String {
        switch provider {
        case .claude: ChatAgents.claude.id
        case .codex: ChatAgents.codex.id
        case .muse: ChatAgents.muse.id
        case .cursor: ChatAgents.cursor.id
        default: provider.rawValue
        }
    }
    /// "Claude", "Codex", or an added agent's own name.
    static func title(for agent: String) -> String {
        ChatAgents.kind(agent)?.title ?? provider(for: agent).map(CodingAgentNames.title) ?? "Your agent"
    }
    /// Its program's name, for "Not signed in to Claude Code".
    static func product(for agent: String) -> String {
        ChatAgents.kind(agent)?.product ?? provider(for: agent).map(CodingAgentNames.title) ?? "your agent"
    }

    /// Where each chat's agent works: a neutral folder, never a code project, kept so it resumes there.
    static func folder(for chat: UUID) -> URL {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return FileManager.default.temporaryDirectory.appendingPathComponent("KemoSabeAgentChats/" + chat.uuidString, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tsukumo/Agent Chats/" + chat.uuidString, isDirectory: true)
    }

    /// What one turn reports: the reply as it streams, then its end (the reply, or nil with the problem).
    struct TurnHandlers {
        var streaming: (String) -> Void
        var finished: (_ reply: String?, _ session: String?, _ problem: String?) -> Void
    }
    private final class Run {
        let session: any AgentSession
        let handlers: TurnHandlers
        var replies: [String: String] = [:]
        var order: [String] = []
        var handle: String?
        var lastProblem: String?
        init(session: any AgentSession, handle: String?, handlers: TurnHandlers) { self.session = session; self.handle = handle; self.handlers = handlers }
        var reply: String? { order.reversed().lazy.compactMap { self.replies[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } }
    }
    @ObservationIgnored private var runs: [UUID: Run] = [:]

    /// Whether this chat's agent is still answering.
    func isRunning(_ store: AppStore) -> Bool { store.agentChat.id.map { running.contains($0) } ?? false }

    /// Sends your message to the agent in the chat on screen (`SavedState.chatAgent`). Returns the chat's ID.
    @discardableResult func send(_ text: String, store: AppStore, chat: UUID? = nil) -> UUID {
        let agentID = store.state.chatAgent ?? AppStore.chatAgent(in: store.conversationMessages) ?? ChatHandoff.claudeAgentID
        let agent = Self.title(for: agentID)
        let current = store.agentChat
        let id = chat ?? current.id ?? UUID()
        guard runs[id] == nil else { store.error = "\(agent) is still answering. Wait for it, or stop it."; return id }
        store.error = nil
        ChatHandoffTranscript.beginTurn(id, text: text, agent: agent, agentID: agentID, store: store)
        // The chat on screen's context card goes to the agent once, ahead of the message; its session keeps it.
        let packet = chat == nil ? store.packetDelivery(for: .codingAgent(agentID), limit: ContextPacketBuilder.largeLimit, firstOnly: true) : nil
        if let packet { store.recordPacketDelivery(packet) }
        startTurn(chat: id, agent: agentID, text: packet.map { $0.text + "\n\n" + text } ?? text, resume: current.session, handlers: .init(
            // The newest reply streams in the chat.
            streaming: { [weak store] text in store?.streamHandoff(id, text) },
            finished: { [weak store] reply, session, problem in
                guard let store else { return }
                ChatHandoffTranscript.finishTurn(id, agent: agent, agentID: agentID, reply: reply, session: session, problem: problem, store: store)
            }))
        return id
    }

    /// Runs one turn of `agent` (a chat's agent ID) for a chat, whether it's the chat on screen or one
    /// that isn't here at all (an iPhone's chat through `KemoSabeRelay`): the agent in the chat's own
    /// neutral folder, continuing `resume`, with the same flags, tools, and declines. False when the
    /// chat already has a turn running.
    @discardableResult func startTurn(chat id: UUID, agent: String = ChatHandoff.claudeAgentID, text: String, resume: String?, handlers: TurnHandlers) -> Bool {
        guard runs[id] == nil else { return false }
        guard let provider = Self.provider(for: agent) else { handlers.finished(nil, resume, "That agent isn’t on this Mac."); return true }
        let folder = Self.folder(for: id)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { handlers.finished(nil, resume, error.localizedDescription); return true }
        var record = CodingTaskRecord(projectID: id, ownerID: "kemosabe-chat", title: String(text.prefix(80)), provider: provider, model: "",
                                      access: Self.access(for: provider), projectPath: folder.path, directory: folder.path, isolated: false)
        record.sessionID = resume
        let session = makeSession(record, id)
        let run = Run(session: session, handle: resume, handlers: handlers)
        runs[id] = run; running.insert(id)
        session.onEvent = { [weak run] event, delta in
            guard let run else { return }
            switch event.kind {
            case .assistant:
                if run.replies[event.id] == nil { run.order.append(event.id) }
                run.replies[event.id] = delta ? (run.replies[event.id] ?? "") + event.text : event.text
                if event.id == run.order.last { run.handlers.streaming(run.replies[event.id] ?? "") }
            case .system: run.lastProblem = [event.text, event.detail].filter { !$0.isEmpty }.joined(separator: ": ")
            default: break
            }
        }
        session.onSession = { [weak run] handle in run?.handle = handle }
        session.onReport = { report in
            if let signedIn = report.signedIn { CodingAgentRegistry.shared.report(provider, signIn: signedIn ? .signedIn : .signedOut) }
        }
        // It may ask Kemo and search the web; anything else it asks to do is declined.
        session.onApproval = { [weak session] approval in
            guard let approval else { return }
            try? session?.respond(approval.id, decision: Self.decision(for: approval), answers: "")
        }
        session.onState = { [weak self] state in
            guard let self, self.runs[id] != nil else { return }
            switch state {
            case .review, .done: self.finish(id)
            case .failed, .interrupted: self.finish(id, failed: true)
            default: break
            }
        }
        // Claude Code has the chat's words as its system prompt; the others get them with the first message.
        let message = provider == .claude || resume != nil ? text : Self.firstMessage(text)
        do { try session.send(message) } catch { finish(id, failed: true, problem: error.localizedDescription) }
        return true
    }

    /// Stops this chat's agent turn.
    func stop(store: AppStore) {
        guard let id = store.agentChat.id else { return }
        stopTurn(id)
    }
    /// Stops a chat's agent turn; it ends as stopped.
    func stopTurn(_ id: UUID, problem: String = "Stopped.") {
        guard runs[id] != nil else { return }
        finish(id, failed: true, problem: problem)
    }

    private func finish(_ id: UUID, failed: Bool = false, problem: String? = nil) {
        guard let run = runs.removeValue(forKey: id) else { return }
        running.remove(id)
        run.session.onEvent = nil; run.session.onState = nil; run.session.onApproval = nil; run.session.onSession = nil
        run.session.stop()
        run.handlers.finished(failed ? nil : run.reply, run.handle, problem ?? run.lastProblem)
    }

    /// The agents the model chip offers: Claude Code (even when it isn't installed, so the menu says
    /// so), then each other agent that's installed, with its official mark, whether it's signed in, and
    /// Sign in (a Tsukumo terminal tab running its own sign-in).
    static func options(registry: CodingAgentRegistry, desktop: DesktopNavigation) -> [ChatAgentOption] {
        registry.adapters.compactMap { adapter in
            let provider = adapter.provider
            let installed = registry.isInstalled(provider)
            guard installed || provider == .claude else { return nil }
            let id = agentID(for: provider), product = product(for: id)
            let signIn = registry.signIn(provider)
            let detail = !installed ? "\(product) isn’t installed" : signIn == .signedOut ? "Not signed in to \(product)" : "\(product) · your own sign-in"
            var option = ChatAgentOption(id: id, title: title(for: id), logo: ChatAgents.kind(id)?.logo ?? "", detail: detail, available: installed)
            if installed, signIn == .signedOut, let command = adapter.signInCommand {
                option.signIn = { AgentSignIn.openInTsukumo(command, name: product, desktop: desktop) }
            }
            return option
        }
    }
}

#if DEBUG
/// The Mac side of `--agent-handoff-fixture` (`ChatHandoffFixture`): the same chat through the real
/// runner, with a fake Claude in place of Claude Code.
@MainActor enum KemoSabeHandoffFixture {
    private static var played = false
    /// Seeds, swaps in the fake Claude, and types the message into the composer once the window is up.
    static func install(in store: AppStore, typeInto draft: @escaping (String) -> Void) {
        guard ChatHandoffFixture.requested, !played else { return }
        played = true
        ChatHandoffFixture.seed(store)
        KemoSabeHandoff.shared.makeSession = { [weak store] _, id in FakeClaude(chat: id, desk: store?.agentQuestions) }
        ChatHandoffFixture.type(into: draft) { [weak store] in
            guard let store else { return }
            KemoSabeHandoff.shared.send(ChatHandoffFixture.task, store: store, chat: ChatHandoffFixture.chatID)
        }
    }

    /// Plays Claude Code with the fixture's turn: works, asks Kemo, and replies with a date spot.
    final class FakeClaude: AgentSession {
        var onEvent: ((CodingEvent, Bool) -> Void)?
        var onState: ((CodingTaskStatus) -> Void)?
        var onSession: ((String) -> Void)?
        var onApproval: ((CodingApproval?) -> Void)?
        let chat: UUID
        weak var desk: AgentQuestionDesk?
        var pace: Double
        /// Who asks KemoSabe: Claude Code, or in tests another agent (Codex).
        let requester: AgentRequester
        /// What the chat sent, first to last.
        private(set) var sent: [String] = []
        private var work: Task<Void, Never>?
        init(chat: UUID, desk: AgentQuestionDesk?, pace: Double = 1, requester: AgentRequester? = nil) {
            self.chat = chat; self.desk = desk; self.pace = pace; self.requester = requester ?? ChatHandoffFixture.claude
        }
        func send(_ text: String) throws {
            sent.append(text)
            onState?(.working)
            onSession?("fixture-session")
            work = Task { @MainActor [weak self] in
                guard let self else { return }
                let reply = await ChatHandoffFixture.claudeTurn(chat: self.chat, desk: self.desk, pace: self.pace, requester: self.requester)
                guard !Task.isCancelled else { return }
                if let reply { self.onEvent?(.init(id: "fixture-reply", kind: .assistant, text: reply), false) }
                self.onState?(reply == nil ? .failed : .review)
            }
        }
        func respond(_ id: String, allow: Bool, answers: String) throws {}
        func stop() { work?.cancel(); work = nil }
    }
}
#endif

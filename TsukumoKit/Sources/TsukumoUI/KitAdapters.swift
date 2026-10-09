import Foundation
import TsukumoCore
import TsukumoPolicy
import TsukumoContext
import TsukumoGate
import TsukumoSystemOne
import TsukumoEngines

// The chat's seams, filled by TsukumoKit's modules: `EngineRunner` runs turns on TsukumoEngines,
// `GateAnswerer` answers through TsukumoGate, and `SystemOneRouter` routes with TsukumoSystemOne.

// MARK: What a bot sees

public extension BotTurn {
    /// The part of the thread this bot may see: the owner's messages that tagged it, and its own
    /// replies. Never another bot's words, and never what KemoSabe told another bot.
    var visibleHistory: [EngineMessage] {
        var turns: [EngineMessage] = []
        for message in thread.messages where message.id != self.message.id {
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let role: EngineMessage.Role
            switch message.author {
            case .owner where message.tags.contains(bot.id): role = .user
            case .bot(let id) where id == bot.id: role = .assistant
            default: continue
            }
            if let last = turns.last, last.role == role {
                turns[turns.count - 1] = EngineMessage(role: role, text: last.text + "\n\n" + text)
            } else {
                turns.append(EngineMessage(role: role, text: text))
            }
        }
        while turns.first?.role == .assistant { turns.removeFirst() }
        return Array(turns.suffix(40))
    }
}

public extension RecipientID {
    /// Who a bot is, as the policy and the Gate name it. `host` is an API connection's server.
    static func bot(_ bot: BotSpec, host: String? = nil) -> RecipientID {
        switch bot.engine {
        case .appleOnDevice: .appleOnDevice
        case .api(let profile): .apiModel(profile: profile, host: host ?? "unknown")
        case .codingAgent(let id): .codingAgent(id)
        case .acp(let id): .acpAgent(id)
        case .mlx(let model): .localModel(model)
        case .service(let id): .externalAgent("service:" + id)
        case .unknown(let raw): .externalAgent(raw)
        }
    }
}

// MARK: Engines

/// An engine for a bot, and who that bot is to the policy.
public struct ResolvedEngine: Sendable {
    public let engine: any Engine
    public let recipient: RecipientID
    public init(engine: any Engine, recipient: RecipientID) { self.engine = engine; self.recipient = recipient }
}

/// Runs a bot's turn on its TsukumoEngines engine, with `read_reference` and `ask_kemosabe` from
/// `TurnTools` (KemoSabe's questions become its card in the chat).
public struct EngineRunner: BotTurnRunning {
    /// The engine for a bot, or nil with the words to say why it can't run here.
    public let resolve: @Sendable (BotSpec) async -> Result<ResolvedEngine, EngineUnavailable>
    /// The artifact store `read_reference` reads from.
    public let store: ArtifactStore
    /// Context grants for `read_reference` (consent grants live in the Gate).
    public let grants: @Sendable () async -> [RecipientGrant]
    /// System One's `selectContext` for a turn. When set, each turn starts with a working set
    /// (`ContextSelection.run`): the references it picks, or, when it abstains, every authorized
    /// reference that fits. Nil keeps a turn to `read_reference` alone.
    public let selectContext: (@Sendable (BotTurn) async -> any ReferenceChooser)?
    /// Where each chat keeps its coding agents' sessions, so the next turn continues the same one. Nil starts
    /// a new session every turn.
    public let sessions: (any AgentSessionStoring)?

    public struct EngineUnavailable: Error, Sendable {
        public let message: String
        public init(_ message: String) { self.message = message }
    }

    public init(store: ArtifactStore, grants: @escaping @Sendable () async -> [RecipientGrant] = { [] },
                selectContext: (@Sendable (BotTurn) async -> any ReferenceChooser)? = nil,
                sessions: (any AgentSessionStoring)? = nil,
                resolve: @escaping @Sendable (BotSpec) async -> Result<ResolvedEngine, EngineUnavailable>) {
        self.store = store; self.grants = grants; self.selectContext = selectContext; self.sessions = sessions; self.resolve = resolve
    }

    /// What every bot is told besides its name and job: KemoSabe's standard voice, or a service bot's plain one.
    public static func instructions(for bot: BotSpec) -> String {
        bot.isKemoSabe
            ? "You are the owner's secure assistant, on their device. Nothing you read leaves it. Be warm, curious, and practical, like a friend who has it together. Keep replies short and conversational: give something concrete, and when it helps, ask one follow-up question. Don't introduce yourself or say you're here to help. Never use em dashes."
            : "Reply in plain sentences. Be warm and plain-spoken, in short sentences."
    }

    public func run(_ turn: BotTurn) -> AsyncThrowingStream<BotTurnEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await perform(turn) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func perform(_ turn: BotTurn, emit: @Sendable (BotTurnEvent) -> Void) async throws {
        // An outside caller's task never drives a coding agent (its files and commands).
        if turn.isolated && turn.bot.engine.runsOnlyOnMac {
            emit(.status("\(turn.bot.name) runs a coding agent, so it doesn’t take tasks from outside callers."))
            return
        }
        let resolved: ResolvedEngine
        switch await resolve(turn.bot) {
        case .failure(let reason): emit(.status(reason.message)); return
        case .success(let engine): resolved = engine
        }
        let asks = turn.bot.contextScope.mayAskKemoSabe && resolved.recipient.locality != .onDevice
        let askKemoSabe = turn.askKemoSabe
        let ask: @Sendable (String, String) async -> String = { question, purpose in
            await askKemoSabe(question, purpose) ?? "KemoSabe shared nothing. Carry on without it, or ask the owner directly."
        }
        if turn.isolated {
            // Only the caller's own words: no history, references, tools, or saved session.
            let isolatedTurn = EngineTurn(bot: turn.bot, instructions: Self.instructions(for: turn.bot), history: [], message: turn.message.text,
                                          references: [], manifest: [], tools: [], runTool: { _ in "No tools are available for this task." },
                                          approve: nil, session: nil)
            var streamed = ""
            for try await event in resolved.engine.run(isolatedTurn) {
                if case .text(let delta) = event { streamed += delta; emit(.text(delta)) }
                if case .done(let reply) = event, reply.text.hasPrefix(streamed), reply.text.count > streamed.count {
                    emit(.text(String(reply.text.dropFirst(streamed.count))))
                }
            }
            return
        }
        let contextGrants = await grants()
        let tools = TurnTools(store: store, recipient: resolved.recipient, grants: contextGrants, ceiling: turn.bot.contextScope.ceiling,
                              askKemoSabe: asks ? ask : nil)
        var references: [Page] = [], manifest: [ManifestEntry] = []
        if let selectContext {
            let request = TurnRequest(request: turn.message.text, recipient: resolved.recipient, grants: contextGrants, ceiling: turn.bot.contextScope.ceiling)
            // A working set that can't be built (a store problem) leaves the turn to `read_reference`.
            if let set = try? await ContextSelection.run(turn: request, store: store, chooser: await selectContext(turn)) {
                references = set.pages; manifest = set.manifest
            }
        }
        let key = AgentSessionKey(thread: turn.thread.id, bot: turn.bot.id, engine: turn.bot.engine.key, folder: turn.bot.contextScope.project ?? "")
        let session = turn.bot.engine.runsOnlyOnMac ? await sessions?.session(for: key) : nil
        let engineTurn = EngineTurn(bot: turn.bot, instructions: Self.instructions(for: turn.bot), history: turn.visibleHistory,
                                    message: turn.message.text, references: references, manifest: manifest,
                                    tools: tools.definitions, runTool: { await tools.run($0) }, approve: turn.approve, session: session)
        var streamed = ""
        for try await event in resolved.engine.run(engineTurn) {
            switch event {
            case .text(let delta):
                streamed += delta
                emit(.text(delta))
            case .activity(let activity):
                emit(.activity(activity))
            case .done(let reply):
                // A reply that wasn't streamed arrives whole here.
                if reply.text.hasPrefix(streamed), reply.text.count > streamed.count { emit(.text(String(reply.text.dropFirst(streamed.count)))) }
                if let next = reply.session, next != session { await sessions?.remember(next, for: key) }
            case .toolCall, .toolResult, .approvalRequested, .approvalDecided:
                break
            }
        }
    }
}

// MARK: Coding agents' sessions

/// Which coding agent session a chat continues: the chat, the bot, its engine, and its folder (an agent's
/// session belongs to the folder it ran in, so a new project starts a new session).
public struct AgentSessionKey: Hashable, Codable, Sendable {
    public let thread: UUID
    public let bot: UUID
    public let engine: String
    public let folder: String
    public init(thread: UUID, bot: UUID, engine: String, folder: String) { self.thread = thread; self.bot = bot; self.engine = engine; self.folder = folder }
    /// As saved: "thread|bot|engine|folder".
    public var raw: String { [thread.uuidString, bot.uuidString, engine, folder].joined(separator: "|") }
}

/// Keeps coding agents' session handles between turns, on this device (they mean nothing anywhere else).
public protocol AgentSessionStoring: Sendable {
    func session(for key: AgentSessionKey) async -> String?
    func remember(_ session: String, for key: AgentSessionKey) async
}

/// Sessions in memory (tests; a host without a store).
public actor AgentSessionMemory: AgentSessionStoring {
    private var sessions: [AgentSessionKey: String] = [:]
    public init() {}
    public func session(for key: AgentSessionKey) -> String? { sessions[key] }
    public func remember(_ session: String, for key: AgentSessionKey) { sessions[key] = session }
}

// MARK: KemoSabe

/// KemoSabe for the chat: TsukumoGate's `Gate`, with its consent prompt and share card shown on
/// KemoSabe's card in the chat, and "Not read" and "Not shared" on its answer.
@MainActor public final class GateAnswerer: KemoSabeAnswering {
    public let gate: Gate
    public nonisolated let device: String
    /// The API connection's server for a bot, so the Gate names the same recipient the engine does.
    private let host: @MainActor (BotSpec) -> String?
    private var consents: [GateExchangeID: @Sendable () async -> ConsentChoice] = [:]
    private var shares: [GateExchangeID: @Sendable (SharePrompt) async -> Bool] = [:]
    /// Consent and share cards whose answer this adapter still waits for (tests: each returns once its exchange ends).
    private(set) var decisionsInFlight = 0

    public init(gate: Gate, host: @escaping @MainActor (BotSpec) -> String? = { _ in nil }) {
        self.gate = gate
        self.device = gate.deviceName
        self.host = host
        gate.onConsentNeeded = { [weak self] prompt in self?.consentNeeded(prompt) }
        gate.onShareNeeded = { [weak self] request in self?.shareNeeded(request) }
    }

    public nonisolated func ask(_ question: KemoSabeQuestion, consent: @escaping @Sendable () async -> ConsentChoice,
                                share: @escaping @Sendable (SharePrompt) async -> Bool) async -> GateAnswerCard {
        await answer(question, consent: consent, share: share)
    }

    private func answer(_ question: KemoSabeQuestion, consent: @escaping @Sendable () async -> ConsentChoice,
                        share: @escaping @Sendable (SharePrompt) async -> Bool) async -> GateAnswerCard {
        consents[question.exchange] = consent
        shares[question.exchange] = share
        defer { consents[question.exchange] = nil; shares[question.exchange] = nil }
        let asked = GateQuestion(id: question.exchange, requester: .bot(question.asker, host: host(question.asker)),
                                 requesterName: question.asker.name, botID: question.asker.id,
                                 question: question.question, purpose: question.purpose)
        let answer = await gate.ask(asked)
        var card = answer.card
        let lines = Self.withheldLines(answer.withheld.summary)
        card.notRead = lines.notRead
        card.notShared = lines.notShared
        return dropIfStopped(card)
    }

    public nonisolated func ask(caller: KemoSabeCaller, exchange: GateExchangeID, question: String, purpose: String,
                                consent: @escaping @Sendable () async -> ConsentChoice,
                                share: @escaping @Sendable (SharePrompt) async -> Bool) async -> GateAnswerCard {
        await answer(caller: caller, exchange: exchange, question: question, purpose: purpose, consent: consent, share: share)
    }

    public func withdraw(_ exchange: GateExchangeID) { gate.withdraw(exchange) }
    public func undelivered(_ exchange: GateExchangeID) { gate.undeliver(exchange) }

    /// An answer whose asker was cancelled while it came back is dropped here too: not returned, and not journaled
    /// as shared.
    private func dropIfStopped(_ card: GateAnswerCard) -> GateAnswerCard {
        guard Task.isCancelled, card.outcome == .answered else { return card }
        gate.undeliver(card.exchange)
        return GateAnswerCard(exchange: card.exchange, askerName: card.askerName, question: card.question, outcome: .unavailable, device: card.device)
    }

    public nonisolated func release(_ text: String, source: String, to caller: KemoSabeCaller, exchange: GateExchangeID, question: String,
                                    purpose: String, consent: @escaping @Sendable () async -> ConsentChoice) async -> GateAnswerCard {
        await released(text, source: source, caller: caller, exchange: exchange, question: question, purpose: purpose, consent: consent)
    }

    private func released(_ text: String, source: String, caller: KemoSabeCaller, exchange: GateExchangeID, question: String, purpose: String,
                          consent: @escaping @Sendable () async -> ConsentChoice) async -> GateAnswerCard {
        consents[exchange] = consent
        defer { consents[exchange] = nil }
        let asked = GateQuestion(id: exchange, requester: caller.requester, requesterName: caller.name, botID: nil, question: question, purpose: purpose)
        let card = await gate.release(text, source: source, for: asked).card
        gate.withdraw(exchange)
        return dropIfStopped(card)
    }

    /// An outside caller's question: its own recipient, no bot's limits.
    private func answer(caller: KemoSabeCaller, exchange: GateExchangeID, question: String, purpose: String,
                        consent: @escaping @Sendable () async -> ConsentChoice, share: @escaping @Sendable (SharePrompt) async -> Bool) async -> GateAnswerCard {
        consents[exchange] = consent
        shares[exchange] = share
        defer { consents[exchange] = nil; shares[exchange] = nil }
        let asked = GateQuestion(id: exchange, requester: caller.requester, requesterName: caller.name, botID: nil, question: question, purpose: purpose)
        let answer = await gate.ask(asked)
        gate.withdraw(exchange)
        var card = answer.card
        let lines = Self.withheldLines(answer.withheld.summary)
        card.notRead = lines.notRead
        card.notShared = lines.notShared
        return dropIfStopped(card)
    }

    /// "Not read: 1 Device only chat. Not shared: 1 Sensitive chat." as its two parts, without labels.
    static func withheldLines(_ summary: String) -> (notRead: String?, notShared: String?) {
        func part(_ label: String) -> String? {
            guard let start = summary.range(of: label + ": ") else { return nil }
            let rest = summary[start.upperBound...]
            let end = rest.range(of: ". Not ")?.lowerBound ?? rest.endIndex
            let text = rest[..<end].trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            return text.isEmpty ? nil : text
        }
        return (part("Not read"), part("Not shared"))
    }

    private func consentNeeded(_ prompt: Gate.ConsentPrompt) {
        guard let ask = consents[prompt.exchange] else { return }
        let gate = self.gate
        decisionsInFlight += 1
        Task { @MainActor [weak self] in
            let choice = await ask()
            self?.decisionsInFlight -= 1
            // An asker that already gave up never turns into a decision on the owner's behalf.
            guard self?.consents[prompt.exchange] != nil else { return }
            gate.decide(Consent(rawValue: choice.rawValue) ?? .deny, for: prompt.exchange)
        }
    }

    private func shareNeeded(_ request: Gate.ShareRequest) {
        guard let ask = shares[request.exchange] else { return }
        let gate = self.gate
        let prompt = SharePrompt(answer: request.answer, sourceTitle: request.sourceTitle, level: request.level)
        decisionsInFlight += 1
        Task { @MainActor [weak self] in
            let allow = await ask(prompt)
            self?.decisionsInFlight -= 1
            // Bound to its exchange: the Gate drops it unless that exact card is still on screen.
            gate.share(allow, for: request.exchange)
        }
    }
}

// MARK: System One

/// Routes an untagged message with System One's `route` decision; nil (the thread's fallback) when
/// it abstains. The providers are read for each message, so turning one on in Settings applies at once,
/// and a thread is never treated as less private than it is (a Device only chat never reaches a hosted
/// model).
public struct SystemOneRouter: TurnRouting {
    public let providers: @Sendable () async -> SystemOneProviders
    public let level: PrivacyLevel
    public init(providers: SystemOneProviders, level: PrivacyLevel = .personal) {
        self.providers = { providers }; self.level = level
    }
    public init(level: PrivacyLevel = .personal, providers: @escaping @Sendable () async -> SystemOneProviders) {
        self.providers = providers; self.level = level
    }

    public func route(text: String, thread: ChatThread, bots: [BotSpec]) async -> RouteChoice? {
        let routed = await SystemOne.route(text, in: thread, bots: bots, providers: await providers(), level: max(level, thread.privacy))
        guard let source = routed.decidedBy, source != .fallback, let bot = routed.recipients.first else { return nil }
        return RouteChoice(bot: bot, reason: "System One (\(source)) picked it for this message.")
    }

    /// The `selectContext` decision for one bot's turn, at the thread's level. On this device only: its
    /// questions carry the references' summary lines (which can describe what KemoSabe found), and a hosted
    /// model is agreed to for a message's words, the question, and the bots as choices, nothing more.
    public func chooser(for turn: BotTurn) async -> any ReferenceChooser {
        var onDevice = await providers()
        onDevice.remotes = []
        return SystemOneContextChooser(providers: onDevice, level: max(level, turn.thread.privacy))
    }
}

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

    public struct EngineUnavailable: Error, Sendable {
        public let message: String
        public init(_ message: String) { self.message = message }
    }

    public init(store: ArtifactStore, grants: @escaping @Sendable () async -> [RecipientGrant] = { [] },
                resolve: @escaping @Sendable (BotSpec) async -> Result<ResolvedEngine, EngineUnavailable>) {
        self.store = store; self.grants = grants; self.resolve = resolve
    }

    /// What every bot is told besides its name and job: KemoSabe's standard voice, or another bot's
    /// personality (its tone and the owner's own words).
    public static func instructions(for bot: BotSpec) -> String {
        bot.isKemoSabe
            ? "You are the owner's secure assistant, on their device. Nothing you read leaves it. Be warm, curious, and practical, like a friend who has it together. Keep replies short and conversational: give something concrete, and when it helps, ask one follow-up question. Don't introduce yourself or say you're here to help. Never use em dashes."
            : "Reply in plain sentences. " + bot.personality.prompt
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
        let contextGrants = await grants()
        let tools = TurnTools(store: store, recipient: resolved.recipient, grants: contextGrants, ceiling: turn.bot.contextScope.ceiling,
                              askKemoSabe: asks ? ask : nil)
        let engineTurn = EngineTurn(bot: turn.bot, instructions: Self.instructions(for: turn.bot), history: turn.visibleHistory,
                                    message: turn.message.text, tools: tools.definitions, runTool: { await tools.run($0) })
        var streamed = ""
        for try await event in resolved.engine.run(engineTurn) {
            switch event {
            case .text(let delta):
                streamed += delta
                emit(.text(delta))
            case .done(let reply):
                // A reply that wasn't streamed arrives whole here.
                if reply.text.hasPrefix(streamed), reply.text.count > streamed.count { emit(.text(String(reply.text.dropFirst(streamed.count)))) }
            case .toolCall, .toolResult, .approvalRequested, .approvalDecided:
                break
            }
        }
    }
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
        return card
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
        Task { @MainActor in
            let choice = await ask()
            gate.decide(Consent(rawValue: choice.rawValue) ?? .deny)
        }
    }

    private func shareNeeded(_ request: Gate.ShareRequest) {
        guard let ask = shares[request.exchange] else { return }
        let gate = self.gate
        let prompt = SharePrompt(answer: request.answer, sourceTitle: request.sourceTitle, level: request.level)
        Task { @MainActor in
            gate.share(await ask(prompt))
        }
    }
}

// MARK: System One

/// Routes an untagged message with System One's `route` decision; nil (the thread's fallback) when
/// it abstains.
public struct SystemOneRouter: TurnRouting {
    public let providers: SystemOneProviders
    public let level: PrivacyLevel
    public init(providers: SystemOneProviders, level: PrivacyLevel = .personal) { self.providers = providers; self.level = level }

    public func route(text: String, thread: ChatThread, bots: [BotSpec]) async -> RouteChoice? {
        let routed = await SystemOne.route(text, in: thread, bots: bots, providers: providers, level: level)
        guard let source = routed.decidedBy, source != .fallback, let bot = routed.recipients.first else { return nil }
        return RouteChoice(bot: bot, reason: "System One (\(source)) picked it for this message.")
    }
}

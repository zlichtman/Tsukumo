import Foundation
import Observation
import TsukumoCore

/// One chat on screen: the thread, the composer's draft and chips, and the turns running in it.
///
/// Sending tags the bots (chips and "@name"); with none, System One routes (`TurnRouting`), and when it
/// abstains the message goes to the bot last spoken to. Each tagged bot gets one turn
/// (`BotTurnRunning`). When a bot asks KemoSabe something, KemoSabe's card joins the thread: it reads
/// (or, the first time, asks the owner) and becomes KemoSabe's answer, with what stayed on the device
/// and exactly what was shared (`KemoSabeAnswering`). Everything that happens is reported to Activity.
@MainActor @Observable public final class ChatSession {
    /// A step the chat took, in order (the demo's beats; tests read them).
    public enum Event: Hashable, Sendable {
        case sent(to: [UUID])
        case routed(to: UUID, bySystemOne: Bool)
        case working(UUID)
        case askedKemoSabe(GateExchangeID, by: UUID)
        case needsConsent(GateExchangeID)
        case needsShare(GateExchangeID)
        case answered(GateExchangeID, GateAnswerCard.Outcome)
        case replied(UUID)
        case stopped(UUID)
    }

    /// A bot's turn in progress.
    public struct Working: Hashable, Sendable {
        public var text = ""
        public var startedAt: Date
    }

    public private(set) var bots: [BotSpec]
    public private(set) var thread: ChatThread
    public var draft = ""
    /// The bots tagged with chips (the composer shows them selected).
    public var chips: Set<UUID> = []
    /// Bots working now, with their reply so far.
    public private(set) var working: [UUID: Working] = [:]
    /// KemoSabe exchanges in flight: their cards show KemoSabe reading, or the consent buttons.
    public private(set) var liveExchanges: Set<GateExchangeID> = []
    /// "Answered Claude: “After 7 tonight”", shown at the top for a moment.
    public private(set) var banner: String?
    public private(set) var events: [Event] = []

    @ObservationIgnored private let runner: any BotTurnRunning
    @ObservationIgnored private let gate: any KemoSabeAnswering
    @ObservationIgnored private let router: (any TurnRouting)?
    @ObservationIgnored private var turns: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var consents: [GateExchangeID: CheckedContinuation<ConsentChoice, Never>] = [:]
    @ObservationIgnored private var shareWaiters: [GateExchangeID: CheckedContinuation<Bool, Never>] = [:]
    /// Share cards waiting on the owner: one Sensitive item, and exactly what would be sent.
    public private(set) var sharePrompts: [GateExchangeID: SharePrompt] = [:]
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    /// Called after every change to the thread (the app saves it).
    @ObservationIgnored public var onThreadChange: ((ChatThread) -> Void)?
    /// Called for everything Activity shows.
    @ObservationIgnored public var onActivity: ((ActivityItem) -> Void)?
    /// How long the banner stays.
    @ObservationIgnored public var bannerSeconds: Double = 6

    public init(thread: ChatThread, bots: [BotSpec], runner: any BotTurnRunning, gate: any KemoSabeAnswering, router: (any TurnRouting)? = nil) {
        self.thread = thread; self.bots = bots; self.runner = runner; self.gate = gate; self.router = router
    }

    // MARK: What the composer shows

    /// The thread's bots, in thread order.
    public var threadBots: [BotSpec] { thread.bots(from: bots) }
    public func bot(_ id: UUID?) -> BotSpec? { id.flatMap { id in bots.first { $0.id == id } } }
    /// Who the draft would go to now: the tagged bots, or the fallback.
    public var recipients: [BotSpec] {
        thread.routing(text: draft, chips: chips, bots: bots).recipients.compactMap { bot($0) }
    }
    /// "Message Claude…"
    public var placeholder: String {
        let names = recipients.map(\.name)
        return names.isEmpty ? "Message your bots…" : "Message " + ListFormatter.localizedString(byJoining: names) + "…"
    }
    /// The device KemoSabe answers on ("iPhone").
    public var device: String { gate.device }
    public var isBusy: Bool { !working.isEmpty }
    public var canSend: Bool { !isBusy && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !recipients.isEmpty }
    /// The bot an "@" being typed at the end of the draft could name, for the suggestion strip.
    public var mentionSuggestions: [BotSpec] {
        guard let at = draft.lastIndex(of: "@") else { return [] }
        let typed = draft[draft.index(after: at)...]
        guard !typed.contains(" "), at == draft.startIndex || draft[draft.index(before: at)].isWhitespace else { return [] }
        let prefix = typed.lowercased()
        return threadBots.filter { prefix.isEmpty || $0.name.lowercased().replacingOccurrences(of: " ", with: "").hasPrefix(prefix) }
    }
    /// Finishes the "@" being typed with `bot`'s name.
    public func complete(mention bot: BotSpec) {
        guard let at = draft.lastIndex(of: "@") else { return }
        draft = String(draft[..<at]) + "@" + bot.name.replacingOccurrences(of: " ", with: "") + " "
    }
    public func toggleChip(_ id: UUID) {
        if chips.contains(id) { chips.remove(id) } else { chips.insert(id) }
    }
    /// Whether KemoSabe's card for `exchange` is still reading (or waiting on the owner).
    public func isLive(_ exchange: GateExchangeID) -> Bool { liveExchanges.contains(exchange) }
    /// A bot's working row shows unless KemoSabe is answering it right now (its card is what's live).
    public func showsWorkingRow(_ bot: UUID) -> Bool {
        guard working[bot] != nil else { return false }
        return !thread.messages.contains { message in
            message.parts.contains { part in
                if case .gateQuestion(let card) = part { card.askedBy == bot && liveExchanges.contains(card.exchange) } else { false }
            }
        }
    }
    /// Whether KemoSabe is reading the device for someone now (the stage shows it at its computer).
    public var kemoSabeIsReading: Bool { !liveExchanges.isEmpty }

    // MARK: Changing the chat

    /// Replaces the bots (after one is added, edited, or removed). The thread keeps every bot that still
    /// exists and gains new ones.
    public func update(bots: [BotSpec]) {
        self.bots = bots
        let ids = bots.map(\.id)
        thread.botIDs = thread.botIDs.filter(ids.contains) + ids.filter { !thread.botIDs.contains($0) }
        chips = chips.filter(ids.contains)
        changed()
    }

    /// Starts over with `thread` (a new chat, or one picked from the list). Running turns stop.
    public func open(_ thread: ChatThread) {
        stopAll()
        self.thread = thread
        draft = ""; chips = []; banner = nil
    }

    /// Sends the draft. Returns the owner's message, or nil when there was nothing to send.
    @discardableResult
    public func send() -> Message? {
        guard canSend else { return nil }
        let text = draft
        let decision = thread.routing(text: text, chips: chips, bots: bots)
        switch decision {
        case .tagged(let ids):
            return deliver(text, to: ids, routed: nil)
        case .untagged(let fallback):
            guard let router else {
                guard let fallback else { return nil }
                return deliver(text, to: [fallback], routed: (fallback, false, nil))
            }
            // System One picks; the fallback runs when it abstains.
            draft = ""
            let snapshot = thread, everyone = bots
            let message = thread.send(text, to: fallback.map { [$0] } ?? [])
            guard let message else { return nil }
            changed()
            Task { [weak self] in
                let choice = await router.route(text: text, thread: snapshot, bots: everyone)
                guard let self else { return }
                let target = choice?.bot ?? fallback
                guard let target, let index = self.thread.messages.firstIndex(where: { $0.id == message.id }) else { return }
                self.thread.messages[index].tags = [target]
                self.thread.lastSpokenTo = target
                self.record(routedTo: target, bySystemOne: choice != nil, reason: choice?.reason)
                self.startTurns(for: self.thread.messages[index])
            }
            return message
        }
    }

    private func deliver(_ text: String, to ids: [UUID], routed: (UUID, Bool, String?)?) -> Message? {
        guard let message = thread.send(text, to: ids) else { return nil }
        draft = ""
        changed()
        if let routed { record(routedTo: routed.0, bySystemOne: routed.1, reason: routed.2) }
        startTurns(for: message)
        return message
    }

    private func record(routedTo bot: UUID, bySystemOne: Bool, reason: String?) {
        events.append(.routed(to: bot, bySystemOne: bySystemOne))
        let name = self.bot(bot)?.name ?? "a bot"
        let detail = bySystemOne ? (reason ?? "System One picked it for this message.")
            : "No bot was tagged, so it went to the bot you last talked to."
        onActivity?(ActivityItem(kind: .systemOne, title: "Sent to \(name)", detail: detail, botID: bot, threadID: thread.id))
    }

    private func startTurns(for message: Message) {
        let recipients = thread.turns(for: message)
        events.append(.sent(to: recipients))
        for botID in recipients {
            guard let bot = bot(botID) else { continue }
            working[botID] = Working(startedAt: Date())
            events.append(.working(botID))
            let snapshot = thread, everyone = bots
            let turn = BotTurn(bot: bot, message: message, thread: snapshot, bots: everyone) { [weak self] question, purpose in
                guard let self else { return nil }
                return await self.askKemoSabe(for: bot, question: question, purpose: purpose)
            }
            let runner = self.runner
            turns[botID] = Task { [weak self] in
                var reply = ""
                var problem: String?
                var saidSomething = false
                do {
                    for try await event in runner.run(turn) {
                        guard let self else { return }
                        switch event {
                        case .text(let delta):
                            reply += delta
                            self.working[botID]?.text = reply
                        case .status(let line):
                            saidSomething = true
                            self.thread.append(Message(author: .bot(botID), parts: [.status(line)]))
                            self.changed()
                        }
                    }
                } catch is CancellationError {
                    problem = "Stopped."
                } catch {
                    problem = error.localizedDescription
                }
                guard let self else { return }
                if Task.isCancelled { problem = "Stopped." }
                self.finish(botID, reply: reply, problem: problem, saidSomething: saidSomething)
            }
        }
    }

    private func finish(_ botID: UUID, reply: String, problem: String?, saidSomething: Bool) {
        working[botID] = nil
        turns[botID] = nil
        let name = bot(botID)?.name ?? "The bot"
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            thread.append(Message(author: .bot(botID), parts: [.text(text)]))
            events.append(.replied(botID))
            let line = text.split(separator: "\n").first.map(String.init) ?? text
            onActivity?(ActivityItem(kind: .botWork, title: "\(name) replied", detail: line, botID: botID, threadID: thread.id))
        }
        if let problem {
            thread.append(Message(author: .bot(botID), parts: [.status(problem == "Stopped." ? "\(name) stopped." : "\(name) stopped. \(problem)")]))
            events.append(.stopped(botID))
        } else if text.isEmpty && !saidSomething {
            thread.append(Message(author: .bot(botID), parts: [.status("\(name) finished without a reply.")]))
        }
        changed()
    }

    /// Stops every running turn.
    public func stopAll() {
        for (_, task) in turns { task.cancel() }
        for (exchange, continuation) in consents { continuation.resume(returning: .deny); liveExchanges.remove(exchange) }
        consents = [:]
        for (_, continuation) in shareWaiters { continuation.resume(returning: false) }
        shareWaiters = [:]
    }

    // MARK: KemoSabe's card

    private func askKemoSabe(for bot: BotSpec, question: String, purpose: String) async -> String? {
        let request = KemoSabeQuestion(asker: bot, question: question, purpose: purpose)
        let card = GateQuestionCard(exchange: request.exchange, askedBy: bot.id, askerName: bot.name, question: question, purpose: purpose)
        let message = Message(author: .bot(BotSpec.kemoSabeID), parts: [.gateQuestion(card)])
        thread.append(message)
        liveExchanges.insert(request.exchange)
        events.append(.askedKemoSabe(request.exchange, by: bot.id))
        changed()
        let answer = await gate.ask(request, consent: { [weak self] in
            guard let self else { return .deny }
            return await self.waitForConsent(request.exchange)
        }, share: { [weak self] prompt in
            guard let self else { return false }
            return await self.waitForShare(prompt, request.exchange)
        })
        liveExchanges.remove(request.exchange)
        if let index = thread.messages.firstIndex(where: { $0.id == message.id }) {
            thread.messages[index].parts = [.gateAnswer(answer)]
        } else {
            thread.append(Message(author: .bot(BotSpec.kemoSabeID), parts: [.gateAnswer(answer)]))
        }
        events.append(.answered(request.exchange, answer.outcome))
        if answer.outcome == .answered, let shared = answer.shared { show(banner: "Answered \(bot.name): “\(shared)”") }
        onActivity?(.gate(answer, botID: bot.id, threadID: thread.id))
        changed()
        return answer.outcome == .answered ? answer.shared : nil
    }

    private func waitForConsent(_ exchange: GateExchangeID) async -> ConsentChoice {
        setQuestionState(exchange, .needsConsent)
        events.append(.needsConsent(exchange))
        let choice = await withCheckedContinuation { continuation in consents[exchange] = continuation }
        setQuestionState(exchange, .reading)
        return choice
    }

    /// The owner's answer on a consent card.
    public func decide(_ choice: ConsentChoice, for exchange: GateExchangeID) {
        guard let continuation = consents.removeValue(forKey: exchange) else { return }
        continuation.resume(returning: choice)
    }
    /// Whether the card for `exchange` waits on the owner.
    public func needsConsent(_ exchange: GateExchangeID) -> Bool { consents[exchange] != nil }

    private func waitForShare(_ prompt: SharePrompt, _ exchange: GateExchangeID) async -> Bool {
        sharePrompts[exchange] = prompt
        events.append(.needsShare(exchange))
        let allow = await withCheckedContinuation { continuation in shareWaiters[exchange] = continuation }
        sharePrompts[exchange] = nil
        return allow
    }
    /// The owner's answer on a share card: share this one Sensitive item, or not.
    public func decideShare(_ allow: Bool, for exchange: GateExchangeID) {
        guard let continuation = shareWaiters.removeValue(forKey: exchange) else { return }
        continuation.resume(returning: allow)
    }

    private func setQuestionState(_ exchange: GateExchangeID, _ state: GateQuestionCard.State) {
        for index in thread.messages.indices {
            for (partIndex, part) in thread.messages[index].parts.enumerated() {
                if case .gateQuestion(var card) = part, card.exchange == exchange {
                    card.state = state
                    thread.messages[index].parts[partIndex] = .gateQuestion(card)
                }
            }
        }
        changed()
    }

    private func show(banner text: String) {
        banner = text
        bannerTask?.cancel()
        let seconds = bannerSeconds
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }

    private func changed() { onThreadChange?(thread) }
}

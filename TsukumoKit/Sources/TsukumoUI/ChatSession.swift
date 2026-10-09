import Foundation
import Observation
import TsukumoCore
import TsukumoEngines
import TsukumoVoice

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
        case needsApproval(String)
        case approved(String, Bool)
    }

    /// Something a coding bot wants to do that its access leaves to the owner ("Edit Sources/App.swift").
    public struct PendingApproval: Identifiable, Hashable, Sendable {
        public let id: String
        public let bot: UUID
        public let summary: String
        public init(id: String, bot: UUID, summary: String) { self.id = id; self.bot = bot; self.summary = summary }
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
    /// What coding bots wait to be allowed, oldest first (their cards show Allow and Don't allow).
    public private(set) var approvals: [PendingApproval] = []

    @ObservationIgnored private let runner: any BotTurnRunning
    @ObservationIgnored private let gate: any KemoSabeAnswering
    @ObservationIgnored private let router: (any TurnRouting)?
    @ObservationIgnored private var turns: [UUID: Task<Void, Never>] = [:]
    /// Who waits on the owner's answer to a card, by its exchange. Each wait is resumed exactly once: by the
    /// owner's answer, or by `endWaits` when the exchange ends any other way (timeout, withdraw, cancel, stop).
    @ObservationIgnored private var consents: [GateExchangeID: [CheckedContinuation<ConsentChoice, Never>]] = [:]
    @ObservationIgnored private var shareWaiters: [GateExchangeID: [CheckedContinuation<Bool, Never>]] = [:]
    @ObservationIgnored private var approvalWaiters: [String: CheckedContinuation<Bool, Never>] = [:]
    /// Messages from an outside caller (`runIsolated`): their turns are isolated, with no history, tools, or KemoSabe.
    @ObservationIgnored private var isolatedMessages: Set<UUID> = []
    /// Outside callers' questions in flight, by exchange: stopping the chat cancels them (and the Gate's reading).
    @ObservationIgnored private var callerTasks: [GateExchangeID: Task<GateAnswerCard, Never>] = [:]
    /// Exchanges this chat stopped while they were in flight: whatever comes back for them is dropped, not shown.
    @ObservationIgnored private var stoppedExchanges: Set<GateExchangeID> = []
    /// What a coding bot is doing, as it happens (the dock's work cues and editor follow it).
    @ObservationIgnored public var onWork: ((UUID, CodingActivity) -> Void)?
    /// A coding bot is waiting on the owner (the dock can say so beside its tile).
    @ObservationIgnored public var onApprovalNeeded: ((PendingApproval) -> Void)?
    /// A bot's turn ended, however it ended.
    @ObservationIgnored public var onTurnEnded: ((UUID) -> Void)?
    /// Share cards waiting on the owner: one Sensitive item, and exactly what would be sent.
    public private(set) var sharePrompts: [GateExchangeID: SharePrompt] = [:]
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    /// Called after every change to the thread (the app saves it).
    @ObservationIgnored public var onThreadChange: ((ChatThread) -> Void)?
    /// Called for everything Activity shows.
    @ObservationIgnored public var onActivity: ((ActivityItem) -> Void)?
    /// How long the banner stays.
    @ObservationIgnored public var bannerSeconds: Double = 6
    /// The app's voice: a message said aloud (`say`) gets its reply spoken, in the bot's voice, while it
    /// streams in. Nil (tests, the demo) never speaks.
    @ObservationIgnored public var voice: VoiceHub?
    /// The message said aloud whose reply is spoken.
    @ObservationIgnored private var spokenMessage: UUID?
    /// Replies being spoken now, by bot.
    @ObservationIgnored private var spoken: [UUID: ReplySpeech] = [:]

    public init(thread: ChatThread, bots: [BotSpec], runner: any BotTurnRunning, gate: any KemoSabeAnswering, router: (any TurnRouting)? = nil) {
        self.thread = thread; self.bots = bots; self.runner = runner; self.gate = gate; self.router = router
    }

    // MARK: What the composer shows

    /// The thread's bots, in thread order.
    public var threadBots: [BotSpec] { thread.bots(from: bots) }
    /// The host may refuse persisted mutations while its store is recovering.
    @ObservationIgnored public var canWrite: @MainActor () -> Bool = { true }
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
        guard canWrite() else { return }
        self.bots = bots
        let ids = bots.map(\.id)
        // A bot that left (taken off the dock, removed on another device) stops at once: its turn and what it waits on.
        for id in Array(turns.keys) where !ids.contains(id) { stop(bot: id) }
        thread.botIDs = thread.botIDs.filter(ids.contains) + ids.filter { !thread.botIDs.contains($0) }
        chips = chips.filter(ids.contains)
        changed()
    }

    /// Starts over with `thread` (a new chat, or one picked from the list). Running turns stop.
    public func open(_ thread: ChatThread) {
        guard canWrite() else { return }
        stopAll()
        self.thread = thread
        draft = ""; chips = []; banner = nil
    }

    /// Sends the draft. Returns the owner's message, or nil when there was nothing to send.
    @discardableResult
    public func send() -> Message? {
        guard canWrite() else { return nil }
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
                guard let self, self.canWrite() else { return }
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
        guard canWrite() else { return nil }
        guard let message = thread.send(text, to: ids) else { return nil }
        draft = ""
        changed()
        if let routed { record(routedTo: routed.0, bySystemOne: routed.1, reason: routed.2) }
        startTurns(for: message)
        return message
    }

    /// Something said aloud. To a bot (tapping it in the dock, or holding it on iPhone): it goes to that bot
    /// as the owner's message, after its running turn (if any) stops. To the chat (the composer's
    /// microphone): with nothing typed it's sent like a typed message (tags and "@name" work); with a draft
    /// it's added to the draft for the owner to send. A sent message's reply is spoken while it streams in,
    /// when the app has a voice and replies are spoken.
    @discardableResult
    public func say(_ text: String, to botID: UUID? = nil) async -> Message? {
        guard canWrite() else { return nil }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let botID {
            guard bot(botID) != nil else { return nil }
            if let running = turns[botID] { running.cancel(); await running.value }
            guard canWrite(), let message = thread.send(text, to: [botID]) else { return nil }
            changed()
            spokenMessage = message.id
            startTurns(for: message)
            return message
        }
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty || isBusy {
            draft = typed.isEmpty ? text : typed + " " + text
            return nil
        }
        draft = text
        guard canSend else { return nil }
        let message = send()
        if let message {
            spokenMessage = message.id
            // A message sent to a tagged bot has started its turn already.
            startSpeaking(for: message.id)
        }
        return message
    }

    /// Starts speaking the reply to `messageID`, from the first bot answering it.
    private func startSpeaking(for messageID: UUID) {
        guard spokenMessage == messageID, let voice, let message = thread.messages.first(where: { $0.id == messageID }) else { return }
        guard let botID = thread.turns(for: message).first(where: { working[$0] != nil }), let bot = bot(botID) else { return }
        spokenMessage = nil
        if let reply = voice.speakReply(from: bot) { spoken[botID] = reply }
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
            let snapshot = thread, everyone = bots, isolated = isolatedMessages.contains(message.id)
            var approve: (@Sendable (ApprovalRequest) async -> Bool)?
            if !isolated {
                approve = { [weak self] request in
                    guard let self else { return false }
                    return await self.waitForApproval(request, bot: botID)
                }
            }
            let turn = BotTurn(bot: bot, message: message, thread: snapshot, bots: everyone, approve: approve, isolated: isolated) { [weak self] question, purpose in
                // An outside caller's task has no KemoSabe: the caller asks KemoSabe itself, on its own consent.
                guard let self, !isolated else { return nil }
                return await self.askKemoSabe(for: bot, question: question, purpose: purpose)
            }
            let runner = self.runner
            turns[botID] = Task { [weak self] in
                var reply = ""
                var problem: String?
                var saidSomething = false
                do {
                    for try await event in runner.run(turn) {
                        guard let self, self.canWrite() else { return }
                        // A bot that left the chat posts nothing more, whatever its runner still had buffered.
                        guard self.bot(botID) != nil else { continue }
                        switch event {
                        case .text(let delta):
                            reply += delta
                            self.working[botID]?.text = reply
                            self.spoken[botID]?.update(reply, final: false)
                        case .status(let line):
                            saidSomething = true
                            self.thread.append(Message(author: .bot(botID), parts: [.status(line)]))
                            self.changed()
                        case .activity(let activity):
                            self.onWork?(botID, activity)
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
        startSpeaking(for: message.id)
    }

    private func finish(_ botID: UUID, reply: String, problem: String?, saidSomething: Bool) {
        working[botID] = nil
        turns[botID] = nil
        for approval in approvals where approval.bot == botID { approvalWaiters.removeValue(forKey: approval.id)?.resume(returning: false) }
        approvals.removeAll { $0.bot == botID }
        onTurnEnded?(botID)
        if let speech = spoken.removeValue(forKey: botID) {
            if problem == nil { speech.update(reply.trimmingCharacters(in: .whitespacesAndNewlines), final: true) } else { speech.stop() }
        }
        guard canWrite() else { return }
        // A bot that left the chat while it worked says nothing more here, not even what it had streamed.
        guard bot(botID) != nil else { changed(); return }
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

    /// Stops everything in flight: every running turn, and every KemoSabe exchange this chat started (a bot's or
    /// an outside caller's, on screen, queued, or still reading). Each exchange is withdrawn from KemoSabe first, so
    /// its wait there ends at once and nothing is decided for the owner; then its card's waits end. The chat stays
    /// usable for new messages.
    public func stopAll() {
        for (_, task) in turns { task.cancel() }
        for (_, task) in callerTasks { task.cancel() }
        for exchange in liveExchanges.union(consents.keys).union(shareWaiters.keys) {
            if liveExchanges.contains(exchange) { stoppedExchanges.insert(exchange) }
            gate.withdraw(exchange)
            endWaits(exchange)
        }
        liveExchanges.removeAll()
        for (_, continuation) in approvalWaiters { continuation.resume(returning: false) }
        approvalWaiters = [:]
        approvals = []
    }

    /// Stops one bot's running turn: its KemoSabe questions are withdrawn first (so KemoSabe stops reading for it and
    /// nothing waits on their cards), anything it waits to be allowed is answered No, and its turn is cancelled. A bot
    /// that left (`update(bots:)`) posts nothing it had streamed so far.
    public func stop(bot id: UUID) {
        let asked = thread.messages.flatMap(\.parts).compactMap { part -> GateExchangeID? in
            if case .gateQuestion(let card) = part, card.askedBy == id { card.exchange } else { nil }
        }
        for exchange in asked where liveExchanges.contains(exchange) || consents[exchange] != nil || shareWaiters[exchange] != nil {
            if liveExchanges.contains(exchange) { stoppedExchanges.insert(exchange) }
            gate.withdraw(exchange)
            endWaits(exchange)
            liveExchanges.remove(exchange)
        }
        turns[id]?.cancel()
        for approval in approvals where approval.bot == id {
            approvalWaiters.removeValue(forKey: approval.id)?.resume(returning: false)
        }
        approvals.removeAll { $0.bot == id }
    }

    // MARK: A coding bot's approvals

    private func waitForApproval(_ request: ApprovalRequest, bot botID: UUID) async -> Bool {
        guard working[botID] != nil else { return false }
        let pending = PendingApproval(id: request.id, bot: botID, summary: request.summary)
        approvals.append(pending)
        events.append(.needsApproval(request.id))
        onApprovalNeeded?(pending)
        let allowed = await withCheckedContinuation { continuation in approvalWaiters[request.id] = continuation }
        approvals.removeAll { $0.id == request.id }
        events.append(.approved(request.id, allowed))
        guard canWrite() else { return false }
        let name = bot(botID)?.name ?? "A bot"
        onActivity?(ActivityItem(kind: .botWork, title: "\(name) asked: \(request.summary)", detail: allowed ? "You allowed it." : "You didn’t allow it.",
                                 botID: botID, threadID: thread.id))
        return allowed
    }

    /// The owner's answer to a coding bot's request.
    public func decideApproval(_ id: String, allow: Bool) {
        guard canWrite() else { return }
        guard let continuation = approvalWaiters.removeValue(forKey: id) else { return }
        continuation.resume(returning: allow)
    }

    // MARK: KemoSabe's card

    private func askKemoSabe(for bot: BotSpec, question: String, purpose: String) async -> String? {
        guard canWrite() else { return nil }
        let request = KemoSabeQuestion(asker: bot, question: question, purpose: purpose)
        let card = GateQuestionCard(exchange: request.exchange, askedBy: bot.id, askerName: bot.name, question: question, purpose: purpose)
        let message = Message(author: .bot(BotSpec.kemoSabeID), parts: [.gateQuestion(card)])
        thread.append(message)
        liveExchanges.insert(request.exchange)
        events.append(.askedKemoSabe(request.exchange, by: bot.id))
        changed()
        let returned = await gate.ask(request, consent: { [weak self] in
            guard let self else { return .deny }
            return await self.waitForConsent(request.exchange)
        }, share: { [weak self] prompt in
            guard let self else { return false }
            return await self.waitForShare(prompt, request.exchange)
        })
        liveExchanges.remove(request.exchange)
        // However the exchange ended (answered, timed out, withdrawn, cancelled), nothing waits on its card any more.
        endWaits(request.exchange)
        guard canWrite() else { return nil }
        let answer = dropIfStopped(returned, request.exchange)
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


    // MARK: Outside callers (Muse)

    /// A question from an outside caller (Muse), on KemoSabe's card in this chat: its consent buttons the
    /// first time, then what was shared and what stayed. The caller is its own recipient.
    public func askKemoSabe(from caller: KemoSabeCaller, question: String, purpose: String) async -> GateAnswerCard {
        await callerCard(caller, question: question, purpose: purpose) { gate, exchange, consent, share in
            await gate.ask(caller: caller, exchange: exchange, question: question, purpose: purpose, consent: consent, share: share)
        }
    }

    /// A bot's reply to an outside caller's task, leaving only through KemoSabe: a card here ("Share Chef’s reply
    /// with Muse?" and exactly what would be sent) the first time, Muse's consent after that, and the journal.
    /// Returns the card; its `shared` is what the caller may have. A shared reply isn't shown as shared (in this
    /// chat or Activity) until `finishRelease` says whether it was really handed over.
    public func release(_ reply: String, from botName: String, to caller: KemoSabeCaller, purpose: String) async -> GateAnswerCard {
        let preview = reply.count <= 280 ? reply : String(reply.prefix(279)) + "…"
        let question = "Share \(botName)’s reply with \(caller.name)? “\(preview)”"
        return await callerCard(caller, question: question, purpose: purpose, deferShared: true) { gate, exchange, consent, _ in
            await gate.release(reply, source: "\(botName)’s reply to \(caller.name)’s task", to: caller, exchange: exchange,
                               question: question, purpose: purpose, consent: consent)
        }
    }

    /// KemoSabe's card for an outside caller: posted, its consent and share answered here, then its answer.
    private func callerCard(_ caller: KemoSabeCaller, question: String, purpose: String, deferShared: Bool = false,
                            _ work: @escaping @MainActor (any KemoSabeAnswering, GateExchangeID, @escaping @Sendable () async -> ConsentChoice,
                                                          @escaping @Sendable (SharePrompt) async -> Bool) async -> GateAnswerCard) async -> GateAnswerCard {
        let exchange = GateExchangeID()
        guard canWrite() else {
            return GateAnswerCard(exchange: exchange, askerName: caller.name, question: question, outcome: .unavailable, device: "this device")
        }
        let card = GateQuestionCard(exchange: exchange, askedBy: nil, askerName: caller.name, question: question, purpose: purpose)
        let message = Message(author: .bot(BotSpec.kemoSabeID), parts: [.gateQuestion(card)])
        thread.append(message)
        liveExchanges.insert(exchange)
        changed()
        // The work is the chat's own task, so stopping the chat cancels it, and the Gate sees that while it reads.
        let gate = self.gate
        let consent: @Sendable () async -> ConsentChoice = { [weak self] in
            guard let self else { return .deny }
            return await self.waitForConsent(exchange)
        }
        let share: @Sendable (SharePrompt) async -> Bool = { [weak self] prompt in
            guard let self else { return false }
            return await self.waitForShare(prompt, exchange)
        }
        let task = Task { await work(gate, exchange, consent, share) }
        callerTasks[exchange] = task
        let returned = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        callerTasks[exchange] = nil
        let answer = dropIfStopped(returned, exchange)
        liveExchanges.remove(exchange)
        // A card nobody answered (the caller gave up) stops waiting on the owner.
        endWaits(exchange)
        if deferShared, answer.outcome == .answered {
            awaitingDelivery[exchange] = message.id
            return answer
        }
        post(answer, in: message.id)
        return answer
    }

    /// The card's outcome, shown in the chat and Activity.
    private func post(_ answer: GateAnswerCard, in messageID: UUID) {
        guard canWrite() else { return }
        if let index = thread.messages.firstIndex(where: { $0.id == messageID }) {
            thread.messages[index].parts = [.gateAnswer(answer)]
        } else {
            thread.append(Message(author: .bot(BotSpec.kemoSabeID), parts: [.gateAnswer(answer)]))
        }
        events.append(.answered(answer.exchange, answer.outcome))
        onActivity?(.gate(answer, botID: nil, threadID: thread.id))
        changed()
    }

    /// Ends a released reply (`release`): handed over, it's shown as shared; not (the caller was revoked or gave up
    /// after KemoSabe released it), KemoSabe is told it wasn't delivered (its journal and store), and it's shown as
    /// not sent. Only once; a card that wasn't shared was shown already.
    public func finishRelease(_ card: GateAnswerCard, delivered: Bool) {
        guard canWrite() else { return }
        guard let messageID = awaitingDelivery.removeValue(forKey: card.exchange) else { return }
        if delivered {
            post(card, in: messageID)
        } else {
            gate.undelivered(card.exchange)
            post(GateAnswerCard(exchange: card.exchange, askerName: card.askerName, question: card.question, outcome: .unavailable, device: card.device),
                 in: messageID)
        }
    }

    /// Why an outside caller's task has no reply.
    public struct RelayFailure: Error, Hashable, Sendable {
        public let message: String
        public init(_ message: String) { self.message = message }
    }

    /// Runs an outside caller's task on one bot in this chat, isolated: the bot gets only the task (no history,
    /// no saved engine session, no references, no tools, no KemoSabe), and a coding agent never runs. Meant
    /// for a throwaway session the host makes for one task. Cancelling stops the bot's turn.
    public func runIsolated(_ task: String, from caller: KemoSabeCaller, on botID: UUID) async -> Result<String, RelayFailure> {
        guard canWrite() else { return .failure(RelayFailure("Tsukumo is recovering its saved chats. Try again once it finishes.")) }
        guard let bot = bot(botID), !bot.isKemoSabe else { return .failure(RelayFailure("There’s no bot by that name here.")) }
        guard !bot.engine.runsOnlyOnMac else { return .failure(RelayFailure("\(bot.name) runs a coding agent, so it doesn’t take tasks from \(caller.name).")) }
        guard working[botID] == nil else { return .failure(RelayFailure("\(bot.name) is busy. Try again in a moment.")) }
        let text = "A task from \(caller.name), an assistant outside Tsukumo. Work only from what it says:\n\n\(task)"
        guard let message = thread.send(text, to: [botID]) else { return .failure(RelayFailure("\(bot.name) couldn’t take it.")) }
        isolatedMessages.insert(message.id)
        startTurns(for: message)
        let turn = turns[botID]
        await withTaskCancellationHandler {
            await turn?.value
        } onCancel: {
            Task { @MainActor [weak self] in self?.stopAll() }
        }
        isolatedMessages.remove(message.id)
        if Task.isCancelled { return .failure(RelayFailure("\(bot.name) stopped: the task ran out of time.")) }
        guard let start = thread.messages.firstIndex(where: { $0.id == message.id }) else { return .failure(RelayFailure("\(bot.name) didn’t reply.")) }
        var reply: String?, problem: String?
        for later in thread.messages[(start + 1)...] where later.author == .bot(botID) {
            for part in later.parts {
                if case .text(let text) = part { reply = text }
                if case .status(let line) = part { problem = line }
            }
        }
        if let reply { return .success(reply) }
        return .failure(RelayFailure(problem ?? "\(bot.name) finished without a reply."))
    }

    /// A line for the owner in this chat (an outside caller's task, recorded where the owner looks). Bots never
    /// see it: a bot's history is only the owner's messages to it and its own replies.
    public func note(_ line: String) {
        guard canWrite() else { return }
        thread.append(Message(author: .system, parts: [.status(line)]))
        changed()
    }

    /// Waits for the owner's answer on this exchange's consent card. An exchange that already ended gets no card
    /// and no wait: its answer is no at once (and the adapter drops it, since nothing asks any more).
    private func waitForConsent(_ exchange: GateExchangeID) async -> ConsentChoice {
        // An exchange that ended (stopped, answered) gets no card: it's withdrawn from KemoSabe first, so the no
        // that follows decides nothing.
        guard liveExchanges.contains(exchange) else { gate.withdraw(exchange); return .deny }
        setQuestionState(exchange, .needsConsent)
        events.append(.needsConsent(exchange))
        let choice = await withCheckedContinuation { continuation in consents[exchange, default: []].append(continuation) }
        if liveExchanges.contains(exchange) { setQuestionState(exchange, .reading) }
        return choice
    }

    /// The owner's answer on a consent card. Only the first answer for an exchange counts.
    public func decide(_ choice: ConsentChoice, for exchange: GateExchangeID) {
        guard canWrite() else { return }
        for continuation in consents.removeValue(forKey: exchange) ?? [] { continuation.resume(returning: choice) }
    }
    /// Whether the card for `exchange` waits on the owner.
    public func needsConsent(_ exchange: GateExchangeID) -> Bool { consents[exchange]?.isEmpty == false }

    private func waitForShare(_ prompt: SharePrompt, _ exchange: GateExchangeID) async -> Bool {
        guard liveExchanges.contains(exchange) else { gate.withdraw(exchange); return false }
        sharePrompts[exchange] = prompt
        events.append(.needsShare(exchange))
        let allow = await withCheckedContinuation { continuation in shareWaiters[exchange, default: []].append(continuation) }
        sharePrompts[exchange] = nil
        return allow
    }
    /// The owner's answer on a share card: share this one Sensitive item, or not. Only the first answer counts.
    /// Released replies waiting for `finishRelease`: their card's message.
    private var awaitingDelivery: [GateExchangeID: UUID] = [:]

    public func decideShare(_ allow: Bool, for exchange: GateExchangeID) {
        guard canWrite() else { return }
        for continuation in shareWaiters.removeValue(forKey: exchange) ?? [] { continuation.resume(returning: allow) }
    }

    /// What came back for an exchange this chat stopped (or for a cancelled asker) is dropped: no answer is shown or
    /// returned, and KemoSabe is told it wasn't delivered, so its journal never says "shared" for it.
    private func dropIfStopped(_ card: GateAnswerCard, _ exchange: GateExchangeID) -> GateAnswerCard {
        let stopped = stoppedExchanges.remove(exchange) != nil || Task.isCancelled
        guard stopped else { return card }
        // Its asker stopped: an answer that came back wasn't delivered, and a question left waiting on the owner was
        // withdrawn. The journal says so.
        gate.undelivered(exchange)
        guard card.outcome == .answered else { return card }
        return GateAnswerCard(exchange: exchange, askerName: card.askerName, question: card.question, outcome: .unavailable, device: card.device)
    }

    /// The exchange is over: every wait on its cards is resumed (no, and don't share), exactly once, and removed.
    /// The adapter drops these answers, because nothing asks for this exchange any more.
    private func endWaits(_ exchange: GateExchangeID) {
        for continuation in consents.removeValue(forKey: exchange) ?? [] { continuation.resume(returning: .deny) }
        for continuation in shareWaiters.removeValue(forKey: exchange) ?? [] { continuation.resume(returning: false) }
        sharePrompts[exchange] = nil
    }

    /// Waits on cards not yet resumed (tests).
    var openWaits: Int { consents.values.reduce(0) { $0 + $1.count } + shareWaiters.values.reduce(0) { $0 + $1.count } }

    private func setQuestionState(_ exchange: GateExchangeID, _ state: GateQuestionCard.State) {
        guard canWrite() else { return }
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

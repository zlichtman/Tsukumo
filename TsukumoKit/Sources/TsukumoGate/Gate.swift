import Foundation
import Observation
import TsukumoCore
import TsukumoPolicy
import TsukumoContext

/// Where KemoSabe keeps its answers as artifacts (an `ArtifactStore` in the apps; a fake in tests).
public protocol GateAnswerStore: Sendable {
    func put(_ draft: ArtifactDraft, derivedFrom lineage: [ArtifactRef]) async throws -> ArtifactRef
    func revoke(_ id: ArtifactID) async throws -> [ArtifactID]
}
extension ArtifactStore: GateAnswerStore {}

/// KemoSabe, the stopper (ported from the app's `AgentQuestionDesk`). An agent never reads personal
/// data: it asks a question, and KemoSabe answers it on this device.
///
/// 1. The first time an agent asks, the owner is asked: Allow always, Allow once, or Don't allow
///    (which keeps it quiet for a while).
/// 2. Only what the policy lets that agent have is read, by a model on this device. Device only and
///    Secret items are never read for an agent; nor is anything above the bot's ceiling.
/// 3. Personal items are covered by the agent's consent. A Sensitive item is read on the device,
///    and its answer goes to a card where the owner shares or declines that one item.
/// 4. Only the answer leaves, through a single-use envelope, and is kept as a `personalAnswer`
///    artifact on the device so a later turn can refer to it.
/// 5. Every exchange is journaled: who asked, the question, why, what was sent, and how much was
///    left out (counts, never content). A locked device answers nothing.
@MainActor @Observable
public final class Gate {
    /// "Let Claude ask KemoSabe?"
    public struct ConsentPrompt: Identifiable, Hashable, Sendable {
        public let exchange: GateExchangeID
        public let requester: RecipientID
        public let requesterName: String
        public let question: String
        public let purpose: String
        public var id: String { requester.grantKey }
    }
    /// "Share this with Claude?" for one Sensitive item, showing exactly what would be sent.
    public struct ShareRequest: Identifiable, Hashable, Sendable {
        public let exchange: GateExchangeID
        public let requesterName: String
        public let question: String
        /// Exactly what would be sent.
        public let answer: String
        /// Where it was found ("your conversation with Sarah").
        public let sourceTitle: String
        public let level: PrivacyLevel
        public var id: GateExchangeID { exchange }
    }
    /// What KemoSabe may do for one bot (from its `ContextScope`).
    public struct BotLimit: Hashable, Sendable {
        public var mayAsk: Bool
        public var ceiling: PrivacyLevel
        public init(mayAsk: Bool = true, ceiling: PrivacyLevel = .personal) { self.mayAsk = mayAsk; self.ceiling = ceiling }
    }
    /// The answer and its card.
    public struct Answer: Hashable, Sendable {
        public let outcome: GateOutcome
        public let card: GateAnswerCard
        public let withheld: Withheld
    }

    /// The kinds an agent's consent covers. A kind grant opens Personal items, never Sensitive.
    public static let consentKinds: [ItemKind] = [.textMessage, .calendarEvent, .reminder, .contact, .location, .note, .health,
                                                .email, .photo, .document, .music, .connector, .personalAnswer]
    public static let onceLifetime: TimeInterval = 10 * 60
    /// The most items the on-device model reads for one question.
    public static let maxSources = 8

    public private(set) var pendingConsent: ConsentPrompt?
    public private(set) var pendingShare: ShareRequest?
    /// The owner's consent grants (they stay on this device; they don't sync).
    public private(set) var grants: [RecipientGrant]

    /// The host may refuse persisted mutations while its store is recovering.
    @ObservationIgnored public var canWrite: @MainActor () -> Bool = { true }
    @ObservationIgnored public var model: any ExtractionModel
    @ObservationIgnored public var sources: [any PersonalSource]
    @ObservationIgnored public var limits: [UUID: BotLimit] = [:]
    /// Whether this device is locked; locked answers nothing.
    @ObservationIgnored public var isLocked: @MainActor () -> Bool = { false }
    /// Called when a consent prompt or share card appears (a notification, or a test that answers it).
    @ObservationIgnored public var onConsentNeeded: (@MainActor (ConsentPrompt) -> Void)?
    @ObservationIgnored public var onShareNeeded: (@MainActor (ShareRequest) -> Void)?
    /// Called whenever `grants` changes, so the app can save them.
    @ObservationIgnored public var onGrantsChanged: (@MainActor ([RecipientGrant]) -> Void)?
    @ObservationIgnored public var consentTimeout: Duration = .seconds(150)
    @ObservationIgnored public var shareTimeout: Duration = .seconds(150)
    /// How long "Don't allow" keeps an agent from asking again.
    @ObservationIgnored public var quietAfterDeny: TimeInterval = 10 * 60

    public let journal: GateJournal
    public let desk: DisclosureDesk
    /// Where answers are kept as artifacts; nil keeps none.
    public let answers: (any GateAnswerStore)?
    /// "iPhone" or "Mac", for the card.
    public let deviceName: String
    private let clock: @Sendable () -> Date

    @ObservationIgnored private var consentQueue: [ConsentPrompt] = []
    @ObservationIgnored private var consentWaiters: [String: [ConsentWaiter]] = [:]
    /// Allow once, for exactly the exchange it answered (never in `grants`, never shared with another question).
    @ObservationIgnored private var exchangeGrants: [GateExchangeID: RecipientGrant] = [:]
    /// Exchanges being answered now, and those whose asker stopped meanwhile (`withdraw`): a withdrawn exchange
    /// is checked after every step that waits (finding items, reading, consent, a share card, sealing, opening)
    /// and ends with nothing shared.
    @ObservationIgnored private var inFlight: Set<GateExchangeID> = []
    @ObservationIgnored private var withdrawn: Set<GateExchangeID> = []
    /// What an answer read, kept until it's handed over and journaled as shared.
    @ObservationIgnored private var delivering: [GateExchangeID: (read: String, withheld: Withheld, automatic: Bool)] = [:]
    /// Recent answers' stored artifacts, so one that wasn't delivered after all can be withdrawn.
    @ObservationIgnored private var storedAnswers: [(exchange: GateExchangeID, ref: ArtifactRef)] = []

    private func remember(_ ref: ArtifactRef, for exchange: GateExchangeID) {
        storedAnswers.append((exchange, ref))
        if storedAnswers.count > 64 { storedAnswers.removeFirst(storedAnswers.count - 64) }
    }

    /// The asker stopped after KemoSabe handed its answer over, so it was never delivered: the journal says so
    /// (never "shared" for text that didn't reach anyone), and the stored answer is withdrawn. A question the asker
    /// stopped while it waited on the owner is recorded as withdrawn, not waiting.
    public func undeliver(_ exchange: GateExchangeID) {
        journal.amend(exchange) { entry in
            switch entry.outcome {
            case .shared:
                entry.outcome = .unavailable
                entry.shared = nil
                entry.read += "; not delivered: the request was withdrawn"
            case .waiting:
                // Its asker stopped while it waited on the owner: nothing waits any more.
                entry.outcome = .unavailable
                entry.read += "; the request was withdrawn"
            default:
                return
            }
        }
        if let index = storedAnswers.lastIndex(where: { $0.exchange == exchange }), let answers {
            let ref = storedAnswers.remove(at: index).ref
            Task { _ = try? await answers.revoke(ref.id) }
        }
    }
    @ObservationIgnored private var shareQueue: [ShareRequest] = []
    @ObservationIgnored private var shareWaiters: [GateExchangeID: CheckedContinuation<Bool?, Never>] = [:]
    @ObservationIgnored private var deniedUntil: [String: Date] = [:]

    public init(model: any ExtractionModel, sources: [any PersonalSource], grants: [RecipientGrant] = [], journal: GateJournal = GateJournal(),
                answers: (any GateAnswerStore)? = nil, deviceName: String, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.model = model
        self.sources = sources
        self.grants = grants
        self.journal = journal
        self.answers = answers
        self.deviceName = deviceName
        self.clock = clock
        self.desk = DisclosureDesk(clock: clock)
    }

    /// Takes each bot's limits from its context scope.
    public func apply(bots: [BotSpec]) {
        limits = Dictionary(bots.map { ($0.id, BotLimit(mayAsk: $0.contextScope.mayAskKemoSabe, ceiling: $0.contextScope.ceiling)) },
                            uniquingKeysWith: { first, _ in first })
    }

    // MARK: Asking

    /// One question from an agent, answered or not. Never throws.
    public func ask(_ question: GateQuestion) async -> Answer {
        guard canWrite() else { return recoveryAnswer(question) }
        inFlight.insert(question.id)
        defer { inFlight.remove(question.id); withdrawn.remove(question.id); exchangeGrants[question.id] = nil }
        var withheld = Withheld()
        var looked: [PersonalItem] = []
        var outcome = await respond(question, withheld: &withheld, looked: &looked)
        guard canWrite() else { return recoveryAnswer(question) }
        var answerRef: ArtifactRef?
        if case .answered(let text) = outcome.0, let answers {
            answerRef = try? await answers.put(ArtifactDraft(
                kind: .personalAnswer, level: outcome.1, owner: .bot(BotSpec.kemoSabeID),
                summaryLine: Self.oneLine("KemoSabe’s answer for \(question.requesterName): \(question.question)"),
                source: PersonalNouns.readSummary(looked), content: text), derivedFrom: [])
        }
        // The final step: the stop check, the commit, and the return, with nothing that suspends in between.
        if case .answered(let sent) = outcome.0 {
            let pending = delivering.removeValue(forKey: question.id)
            if stopped(question) {
                // Stopped while the answer was being stored: it's withdrawn from the store and never handed over.
                if let answerRef, let answers { Task { _ = try? await answers.revoke(answerRef.id) } }
                answerRef = nil
                outcome = refuseStopped(question, read: pending?.read ?? "nothing", withheld: pending?.withheld ?? withheld)
            } else {
                record(question, .shared, read: pending?.read ?? PersonalNouns.readSummary(looked), shared: sent,
                       withheld: pending?.withheld ?? withheld, automatic: pending?.automatic ?? true)
                if let answerRef { remember(answerRef, for: question.id) }
            }
        }
        let shared: String? = if case .answered(let text) = outcome.0 { text } else { nil }
        let card = GateAnswerCard(exchange: question.id, askerName: question.requesterName, question: question.question,
                                  outcome: outcome.0.cardOutcome, shared: shared, stayed: PersonalNouns.stayed(looked),
                                  device: deviceName, answer: answerRef)
        return Answer(outcome: outcome.0, card: card, withheld: withheld)
    }

    /// A bot's reply to an outside caller's task (Muse's `bot.ask`), leaving for that caller. It goes out like
    /// one of KemoSabe's answers: only with the caller's consent (asked the first time, on the card), sealed
    /// for exactly that caller, and journaled with exactly what was sent. `question` names the caller and
    /// says what's being shared ("Share Chef’s reply with Muse?"); `source` names the bot ("Chef’s reply").
    public func release(_ text: String, source: String, for question: GateQuestion) async -> Answer {
        guard canWrite() else { return recoveryAnswer(question) }
        inFlight.insert(question.id)
        defer { inFlight.remove(question.id); withdrawn.remove(question.id); exchangeGrants[question.id] = nil }
        let outcome: (GateOutcome, PrivacyLevel) = await {
            guard question.isValid else { return (.refused("Nothing to share."), .open) }
            guard !isLocked() else { return (.unavailable("KemoSabe is locked right now (the \(deviceName) is locked). Ask again later."), .open) }
            if let until = deniedUntil[question.requester.grantKey], until > clock() {
                record(question, .declined, read: "nothing: you didn’t allow \(question.requesterName) to ask")
                return (.declined, .open)
            }
            if !consented(question) {
                switch await requestConsent(question) {
                case nil:
                    record(question, .waiting, read: "nothing yet: waiting for you to allow \(question.requesterName)")
                    return (.waiting, .open)
                case .deny?:
                    record(question, .declined, read: "nothing: you didn’t allow \(question.requesterName)")
                    return (.declined, .open)
                case .always?, .once?: break
                }
            }
            defer { spendOnce(question.requester); exchangeGrants[question.id] = nil }
            let label = TypeLabel(kind: .personalAnswer, level: .personal)
            do {
                // The final step: checked after the last wait, committed, and returned, with nothing in between.
                guard let sent = try await sealAndOpen(text, label: label, question, extraGrants: [answerGrant(question, label)]),
                      !stopped(question) else {
                    return refuseStopped(question, read: source)
                }
                record(question, .shared, read: source, shared: sent)
                return (.answered(sent), .personal)
            } catch {
                record(question, .failed, read: source)
                return (.unavailable("KemoSabe couldn’t send that. Nothing was shared."), .open)
            }
        }()
        let shared: String? = if case .answered(let sent) = outcome.0 { sent } else { nil }
        let card = GateAnswerCard(exchange: question.id, askerName: question.requesterName, question: question.question,
                                  outcome: outcome.0.cardOutcome, shared: shared, device: deviceName)
        return Answer(outcome: outcome.0, card: card, withheld: Withheld())
    }

    /// The outcome and the level of what was sent.
    private func respond(_ question: GateQuestion, withheld: inout Withheld, looked: inout [PersonalItem]) async -> (GateOutcome, PrivacyLevel) {
        guard question.isValid else {
            return (.refused("Ask one question of up to \(GateQuestion.maxQuestion) characters, with a short purpose."), .open)
        }
        guard !isLocked() else {
            return (.unavailable("KemoSabe is locked right now (the \(deviceName) is locked). Ask again later."), .open)
        }
        let key = question.requester.grantKey
        let limit = question.botID.flatMap { limits[$0] }
        if limit?.mayAsk == false {
            record(question, .declined, read: "nothing: you turned off asking KemoSabe for this bot")
            return (.declined, .open)
        }
        if let until = deniedUntil[key], until > clock() {
            record(question, .declined, read: "nothing: you didn’t allow \(question.requesterName) to ask")
            return (.declined, .open)
        }
        if !consented(question) {
            switch await requestConsent(question) {
            case nil:
                record(question, .waiting, read: "nothing yet: waiting for you to allow \(question.requesterName)")
                return (.waiting, .open)
            case .deny?:
                record(question, .declined, read: "nothing: you didn’t allow \(question.requesterName) to ask")
                return (.declined, .open)
            case .always?, .once?:
                break
            }
        }
        defer { spendOnce(question.requester); exchangeGrants[question.id] = nil }
        if stopped(question) { return refuseStopped(question, read: "nothing") }
        return await answer(question, ceiling: limit?.ceiling, withheld: &withheld, looked: &looked)
    }

    private func answer(_ question: GateQuestion, ceiling: PrivacyLevel?, withheld: inout Withheld,
                        looked: inout [PersonalItem]) async -> (GateOutcome, PrivacyLevel) {
        // Every source looks at once (a connected account may take a moment), and their items keep the sources' order.
        let found = await withTaskGroup(of: (Int, [PersonalItem]).self) { group in
            for (index, source) in sources.enumerated() { group.addTask { (index, await source.items(matching: question)) } }
            var lists: [Int: [PersonalItem]] = [:]
            for await (index, items) in group { lists[index] = items }
            return lists.keys.sorted().flatMap { lists[$0] ?? [] }
        }
        if stopped(question) { return refuseStopped(question, read: "nothing", withheld: withheld) }
        let relevant = Self.rank(found, for: question.question)
        let now = clock()
        let decision = ContextPolicy.evaluate(relevant.map(\.policyItem), to: question.requester, purpose: .agentQuestion,
                                              grants: grants(for: question), ceiling: ceiling, now: now)
        var readable: [PersonalItem] = [], sensitive: [PersonalItem] = []
        for item in relevant {
            switch decision.denied[item.policyItem] {
            case nil: readable.append(item)
            case .needsGrant?: sensitive.append(item)
            case .staysOnDevice?, .secret?, .aboveCeiling?: withheld.add(.notRead, item.label)
            }
        }
        guard model.isAvailable else {
            record(question, .unavailable, read: "nothing: the on-device model isn’t ready", withheld: withheld)
            return (.unavailable("Apple’s on-device model isn’t ready on the owner’s \(deviceName), so KemoSabe can’t look yet."), .open)
        }

        let chosen = Array(readable.prefix(Self.maxSources))
        if !chosen.isEmpty {
            looked = chosen
            let text = chosen.map { "[\($0.title)]\n\($0.text)" }.joined(separator: "\n\n")
            let result: Extraction.Result
            do { result = try await Extraction.run(model, lookingFor: question.question, in: text) } catch {
                record(question, .unavailable, read: PersonalNouns.readSummary(chosen), withheld: withheld)
                return (.unavailable("KemoSabe couldn’t read on the owner’s \(deviceName) right now. Ask again in a moment."), .open)
            }
            if stopped(question) { return refuseStopped(question, read: PersonalNouns.readSummary(chosen), withheld: withheld) }
            if case .found(let answer, _) = result {
                for item in sensitive { withheld.add(.notShared, item.label) }
                // Every source was already allowed to this requester, so the answer derived from them is too.
                let label = TypeLabel.combining(chosen.map(\.label), as: .personalAnswer)
                return await disclose(answer, label: label, question, read: chosen, withheld: withheld,
                                      extraGrants: [answerGrant(question, label)], automatic: true)
            }
        }

        // Not in what it may read without asking: one Sensitive item goes to a card, and the owner
        // sees exactly what would be shared.
        if let best = sensitive.first {
            for item in sensitive where item != best { withheld.add(.notShared, item.label) }
            looked = chosen + [best]
            let extracted = try? await Extraction.run(model, lookingFor: question.question, in: "[\(best.title)]\n\(best.text)")
            if stopped(question) { return refuseStopped(question, read: PersonalNouns.readSummary([best]), withheld: withheld) }
            if case .found(let answer, _)? = extracted {
                let request = ShareRequest(exchange: question.id, requesterName: question.requesterName, question: question.question,
                                           answer: answer, sourceTitle: best.title, level: best.label.level)
                switch await requestShare(request) {
                case true? where stopped(question):
                    return refuseStopped(question, read: PersonalNouns.readSummary([best]), withheld: withheld)
                case true?:
                    // Sharing on the card is the grant for exactly this answer.
                    let label = TypeLabel.combining([best.label], as: .personalAnswer)
                    return await disclose(answer, label: label, question, read: [best], withheld: withheld,
                                          extraGrants: [answerGrant(question, label)], automatic: false)
                case false?:
                    withheld.add(.notShared, best.label)
                    record(question, .declined, read: PersonalNouns.readSummary([best]), withheld: withheld, automatic: false)
                    return (.declined, .open)
                case nil:
                    record(question, .waiting, read: PersonalNouns.readSummary([best]), withheld: withheld, automatic: false)
                    return (.waiting, .open)
                }
            }
            withheld.add(.notShared, best.label)
        }
        record(question, .notFound, read: PersonalNouns.readSummary(chosen), withheld: withheld, automatic: true)
        return (.notFound, .open)
    }

    /// Seals the answer for exactly this requester and opens it once, immediately before it's returned.
    private func disclose(_ answer: String, label: TypeLabel, _ question: GateQuestion, read: [PersonalItem], withheld: Withheld,
                          extraGrants: [RecipientGrant], automatic: Bool) async -> (GateOutcome, PrivacyLevel) {
        do {
            guard let sent = try await sealAndOpen(answer, label: label, question, extraGrants: extraGrants) else {
                return refuseStopped(question, read: PersonalNouns.readSummary(read), withheld: withheld)
            }
            // "Shared" is journaled only where the answer is handed over (`ask`'s final step), never before.
            delivering[question.id] = (PersonalNouns.readSummary(read), withheld, automatic)
            return (.answered(sent), label.level)
        } catch {
            record(question, .failed, read: PersonalNouns.readSummary(read), withheld: withheld, automatic: automatic)
            return (.unavailable("KemoSabe couldn’t send that. Nothing was shared."), .open)
        }
    }

    /// Seals the answer for this requester and opens it once, unless the asker stopped: checked before sealing,
    /// after sealing (the envelope is destroyed unopened), and after opening (nothing is returned). Nil when stopped.
    private func sealAndOpen(_ text: String, label: TypeLabel, _ question: GateQuestion, extraGrants: [RecipientGrant]) async throws -> String? {
        guard !stopped(question) else { return nil }
        let envelope = try await desk.seal(text, label: label, for: question.requester, exchange: question.id,
                                           grants: grants(for: question) + extraGrants)
        guard !stopped(question) else { await desk.discard(envelope); return nil }
        let sent = try await desk.open(envelope, as: question.requester)
        guard !stopped(question) else { return nil }
        return sent
    }

    /// The asker withdrew this exchange or its task was cancelled.
    private func stopped(_ question: GateQuestion) -> Bool { withdrawn.contains(question.id) || Task.isCancelled }

    private func refuseStopped(_ question: GateQuestion, read: String, withheld: Withheld = Withheld()) -> (GateOutcome, PrivacyLevel) {
        record(question, .unavailable, read: read + "; nothing was shared: the request was withdrawn", withheld: withheld)
        return (.unavailable("The request was withdrawn, so KemoSabe shared nothing."), .open)
    }

    // MARK: Consent

    /// One asker waiting on the owner: its own exchange and its own prompt.
    private struct ConsentWaiter {
        let token: UUID
        let prompt: ConsentPrompt
        let continuation: CheckedContinuation<Consent?, Never>
    }

    /// The owner's answer to the consent prompt for `exchange`. It counts only while that exact exchange is the
    /// prompt on screen; an answer for any other (one that timed out, was cancelled, or was withdrawn) is dropped,
    /// so it can never authorize another question. Allow always covers this agent from now on, so every question
    /// it has waiting goes ahead (each still checked against its own scope). Allow once covers exactly this
    /// exchange; the agent's other waiting questions get a prompt of their own. Don't allow answers all of them
    /// and keeps the agent quiet for a while.
    public func decide(_ choice: Consent, for exchange: GateExchangeID) {
        guard canWrite() else { return }
        guard let prompt = pendingConsent, prompt.exchange == exchange else { return }
        let key = prompt.id, now = clock()
        let waiting = consentWaiters[key] ?? []
        switch choice {
        case .always:
            grants.removeAll { $0.recipient == key && $0.purpose == .agentQuestion }
            grants.append(RecipientGrant(recipient: prompt.requester, kinds: Self.consentKinds, purpose: .agentQuestion, grantedAt: now))
            onGrantsChanged?(grants)
            consentWaiters[key] = nil
            for waiter in waiting { waiter.continuation.resume(returning: .always) }
        case .once:
            // A grant for this exchange alone, never kept in `grants`, so no other question can use it.
            let mine = waiting.filter { $0.prompt.exchange == exchange }
            if !mine.isEmpty {
                exchangeGrants[exchange] = RecipientGrant(recipient: prompt.requester, kinds: Self.consentKinds, purpose: .agentQuestion,
                                                          expiresAt: now.addingTimeInterval(Self.onceLifetime), singleUse: true, grantedAt: now)
            }
            let rest = waiting.filter { $0.prompt.exchange != exchange }
            consentWaiters[key] = rest.isEmpty ? nil : rest
            for waiter in mine { waiter.continuation.resume(returning: .once) }
        case .deny:
            deniedUntil[key] = now.addingTimeInterval(quietAfterDeny)
            consentWaiters[key] = nil
            for waiter in waiting { waiter.continuation.resume(returning: .deny) }
        }
        pendingConsent = nil
        repairPrompts(key, first: true)
    }

    /// Takes down one exchange whose asker gave up (an outside caller's deadline), consent or share, without
    /// allowing or refusing anything. Only that exchange stops waiting; the agent's other questions keep a prompt.
    public func withdraw(_ exchange: GateExchangeID) {
        // Remembered while it's being answered, so a step still running (reading, sealing) ends with nothing shared.
        if inFlight.contains(exchange) { withdrawn.insert(exchange) }
        for key in Array(consentWaiters.keys) {
            let (gone, kept) = (consentWaiters[key] ?? []).reduce(into: ([ConsentWaiter](), [ConsentWaiter]())) { split, waiter in
                if waiter.prompt.exchange == exchange { split.0.append(waiter) } else { split.1.append(waiter) }
            }
            guard !gone.isEmpty else { continue }
            consentWaiters[key] = kept.isEmpty ? nil : kept
            for waiter in gone { waiter.continuation.resume(returning: nil) }
            repairPrompts(key)
        }
        dropShare(exchange)
    }

    /// Keeps one recipient's prompts honest after any change: while it has waiters, exactly one prompt (on screen
    /// or queued) shows, and it's for one of those waiters; with none, it has no prompt. Then the queue moves on.
    /// `first` puts its next prompt ahead of the queue (it was just answered on screen).
    private func repairPrompts(_ key: String, first: Bool = false) {
        let live = consentWaiters[key] ?? []
        let liveExchanges = Set(live.map(\.prompt.exchange))
        if let shown = pendingConsent, shown.id == key, !liveExchanges.contains(shown.exchange) { pendingConsent = nil }
        if let index = consentQueue.firstIndex(where: { $0.id == key }) {
            if let next = live.first {
                if !liveExchanges.contains(consentQueue[index].exchange) { consentQueue[index] = next.prompt }
            } else {
                consentQueue.remove(at: index)
            }
        } else if let next = live.first, pendingConsent?.id != key {
            if first { consentQueue.insert(next.prompt, at: 0) } else { consentQueue.append(next.prompt) }
        }
        advanceConsent()
    }

    private func advanceConsent() {
        guard pendingConsent == nil, !consentQueue.isEmpty else { return }
        let next = consentQueue.removeFirst()
        pendingConsent = next
        onConsentNeeded?(next)
    }

    /// Whether `exchange` still waits here on a consent prompt or a share card (tests).
    func isWaiting(_ exchange: GateExchangeID) -> Bool {
        consentWaiters.values.contains { $0.contains { $0.prompt.exchange == exchange } } || shareWaiters[exchange] != nil
            || consentQueue.contains { $0.exchange == exchange } || shareQueue.contains { $0.exchange == exchange }
    }

    /// Whether every recipient with a waiting question has exactly one prompt for one of them, and none without (tests).
    var promptsAreConsistent: Bool {
        var shown = consentQueue
        if let pendingConsent { shown.append(pendingConsent) }
        if pendingConsent == nil && !consentQueue.isEmpty { return false }
        for (key, waiters) in consentWaiters where !waiters.isEmpty {
            let prompts = shown.filter { $0.id == key }
            guard prompts.count == 1, waiters.contains(where: { $0.prompt.exchange == prompts[0].exchange }) else { return false }
        }
        return shown.allSatisfy { consentWaiters[$0.id]?.isEmpty == false }
    }

    /// The owner's consent given somewhere other than this Gate's own prompt: the KemoSabe gateway's card for
    /// a caller, or its standing grant. The same grant as Allow always (no expiry) or Allow for a while (an
    /// expiry), so the Gate asks nothing more and still applies its policy.
    public func grantConsent(_ requester: RecipientID, until: Date?) {
        guard canWrite() else { return }
        let now = clock()
        grants.removeAll { $0.recipient == requester.grantKey && $0.purpose == .agentQuestion }
        grants.append(RecipientGrant(recipient: requester, kinds: Self.consentKinds, purpose: .agentQuestion,
                                     expiresAt: until, grantedAt: now))
        deniedUntil[requester.grantKey] = nil
        onGrantsChanged?(grants)
    }

    /// Allow once given somewhere other than this Gate's own prompt (the gateway's card), bound like the Gate's own
    /// Allow once to exactly one exchange: the question the caller is about to ask with that id. It never enters
    /// `grants`, so no other question from the same requester, in flight now or later, can use it; it goes when
    /// that exchange ends, answered or not.
    public func grantConsentOnce(_ requester: RecipientID, for exchange: GateExchangeID) {
        guard canWrite() else { return }
        let now = clock()
        exchangeGrants[exchange] = RecipientGrant(recipient: requester, kinds: Self.consentKinds, purpose: .agentQuestion,
                                                  expiresAt: now.addingTimeInterval(Self.onceLifetime), singleUse: true, grantedAt: now)
        deniedUntil[requester.grantKey] = nil
    }

    /// Remove an agent's consent: it asks again next time.
    public func revokeConsent(_ requester: RecipientID) {
        guard canWrite() else { return }
        grants.removeAll { $0.recipient == requester.grantKey && $0.purpose == .agentQuestion }
        onGrantsChanged?(grants)
    }

    /// The owner's answer to the share card for `exchange`. It counts only while that exact card is on screen; a
    /// late answer for a card that timed out or was cancelled is dropped and never shares anything else.
    public func share(_ allow: Bool, for exchange: GateExchangeID) {
        guard canWrite() else { return }
        guard let request = pendingShare, request.exchange == exchange else { return }
        shareWaiters.removeValue(forKey: exchange)?.resume(returning: allow)
        pendingShare = nil
        advanceShare()
    }

    /// One share card's asker is gone (timed out, cancelled, withdrawn): its card comes down and the next one shows.
    private func dropShare(_ exchange: GateExchangeID) {
        shareQueue.removeAll { $0.exchange == exchange }
        if pendingShare?.exchange == exchange { pendingShare = nil }
        shareWaiters.removeValue(forKey: exchange)?.resume(returning: nil)
        advanceShare()
    }

    private func advanceShare() {
        guard pendingShare == nil, !shareQueue.isEmpty else { return }
        let next = shareQueue.removeFirst()
        pendingShare = next
        onShareNeeded?(next)
    }

    public func consentGrants(for requester: RecipientID) -> [RecipientGrant] {
        grants.filter { $0.applies(to: requester, purpose: .agentQuestion, now: clock()) }
    }

    /// Whether this question may go ahead: the agent's standing consent, or Allow once for exactly this exchange.
    private func consented(_ question: GateQuestion) -> Bool {
        !consentGrants(for: question.requester).isEmpty
            || exchangeGrants[question.id]?.applies(to: question.requester, purpose: .agentQuestion, now: clock()) == true
    }
    /// The grants this question is evaluated with: the standing ones and its own Allow once.
    private func grants(for question: GateQuestion) -> [RecipientGrant] {
        grants + (exchangeGrants[question.id].map { [$0] } ?? [])
    }

    private func requestConsent(_ question: GateQuestion) async -> Consent? {
        let key = question.requester.grantKey, token = UUID()
        guard !Task.isCancelled else { return nil }
        // A cancelled asker (a caller's deadline) stops waiting; only its own exchange.
        return await withTaskCancellationHandler {
            await waitForConsent(question, key: key, token: token)
        } onCancel: {
            Task { @MainActor [weak self] in self?.stopWaiting(key, token) }
        }
    }

    /// One waiter is done waiting (timed out or cancelled): its prompt comes down if it was showing, the agent's
    /// other questions keep a prompt, and the queue moves on. A late answer for it is dropped by `decide`.
    private func stopWaiting(_ key: String, _ token: UUID) {
        guard let index = consentWaiters[key]?.firstIndex(where: { $0.token == token }) else { return }
        let waiter = consentWaiters[key]!.remove(at: index)
        if consentWaiters[key]?.isEmpty == true { consentWaiters[key] = nil }
        waiter.continuation.resume(returning: nil)
        repairPrompts(key)
    }

    private func waitForConsent(_ question: GateQuestion, key: String, token: UUID) async -> Consent? {
        let timeout = consentTimeout
        let prompt = ConsentPrompt(exchange: question.id, requester: question.requester, requesterName: question.requesterName,
                                   question: question.question, purpose: question.purpose)
        return await withCheckedContinuation { continuation in
            consentWaiters[key, default: []].append(ConsentWaiter(token: token, prompt: prompt, continuation: continuation))
            repairPrompts(key)
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.stopWaiting(key, token)
            }
        }
    }

    private func requestShare(_ request: ShareRequest) async -> Bool? {
        guard !Task.isCancelled else { return nil }
        return await withTaskCancellationHandler {
            await waitForShare(request)
        } onCancel: {
            Task { @MainActor [weak self] in self?.dropShare(request.exchange) }
        }
    }

    private func waitForShare(_ request: ShareRequest) async -> Bool? {
        let timeout = shareTimeout
        return await withCheckedContinuation { continuation in
            shareWaiters[request.exchange] = continuation
            shareQueue.append(request)
            advanceShare()
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.dropShare(request.exchange)
            }
        }
    }

    /// "Allow once" covers one question: spent after it, answered or not.
    private func spendOnce(_ requester: RecipientID) {
        guard canWrite() else { return }
        let once = grants.filter { $0.recipient == requester.grantKey && $0.purpose == .agentQuestion && $0.singleUse }.map(\.id)
        guard !once.isEmpty else { return }
        RecipientGrants.spend(once, in: &grants)
        grants = RecipientGrants.pruned(grants, now: clock())
        onGrantsChanged?(grants)
    }

    // MARK: Helpers

    /// A single-use grant for exactly this exchange's answer, to this requester, that expires soon.
    private func answerGrant(_ question: GateQuestion, _ label: TypeLabel) -> RecipientGrant {
        RecipientGrant(recipient: question.requester, items: [PolicyItem(id: "answer:" + question.id.description, label: label)],
                       purpose: .agentQuestion, expiresAt: clock().addingTimeInterval(DisclosureDesk.lifetime), singleUse: true, grantedAt: clock())
    }

    private func recoveryAnswer(_ question: GateQuestion) -> Answer {
        let reason = "Tsukumo is recovering its saved chats. Try again once it finishes."
        return Answer(outcome: .unavailable(reason), card: GateAnswerCard(exchange: question.id, askerName: question.requesterName,
                      question: question.question, outcome: .unavailable, shared: nil, stayed: "nothing", device: deviceName), withheld: Withheld())
    }

    /// Journals an exchange now (the journal never suspends; its file follows).
    private func record(_ question: GateQuestion, _ outcome: GateJournalEntry.Outcome, read: String, shared: String? = nil,
                        withheld: Withheld = Withheld(), automatic: Bool = true) {
        guard canWrite() else { return }
        journal.append(GateJournalEntry(
            id: question.id, requester: question.requester.key, requesterName: question.requesterName, botID: question.botID,
            question: question.question, purpose: question.purpose, outcome: outcome, read: read, shared: shared,
            withheld: withheld.isEmpty ? nil : withheld.summary, withheldCount: withheld.total,
            receivedAt: question.receivedAt, decidedAt: clock(), automatic: automatic))
    }

    /// The items that share words with the question, best first (then newest). An item a source
    /// found by searching for this question counts as sharing one.
    public static func rank(_ items: [PersonalItem], for question: String) -> [PersonalItem] {
        let wanted = Extraction.terms(question)
        guard !wanted.isEmpty else { return [] }
        let scored: [(item: PersonalItem, score: Int)] = items.compactMap { item in
            let score = Extraction.terms(item.title + "\n" + item.text).intersection(wanted).count + (item.matched ? 1 : 0)
            return score > 0 ? (item, score) : nil
        }
        return scored.sorted { left, right in
            left.score != right.score ? left.score > right.score : (left.item.date ?? .distantPast) > (right.item.date ?? .distantPast)
        }.map(\.item)
    }

    static func oneLine(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count <= 180 ? flat : String(flat.prefix(179)) + "…"
    }
}

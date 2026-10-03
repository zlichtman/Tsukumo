import Foundation
import Observation
import TsukumoCore
import TsukumoPolicy
import TsukumoContext

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
    public static let consentKinds: [ItemKind] = [.textMessage, .calendarEvent, .reminder, .contact, .location, .note, .health, .personalAnswer]
    public static let onceLifetime: TimeInterval = 10 * 60
    /// The most items the on-device model reads for one question.
    public static let maxSources = 8

    public private(set) var pendingConsent: ConsentPrompt?
    public private(set) var pendingShare: ShareRequest?
    /// The owner's consent grants (they stay on this device; they don't sync).
    public private(set) var grants: [RecipientGrant]

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
    public let answers: ArtifactStore?
    /// "iPhone" or "Mac", for the card.
    public let deviceName: String
    private let clock: @Sendable () -> Date

    @ObservationIgnored private var consentQueue: [ConsentPrompt] = []
    @ObservationIgnored private var consentWaiters: [String: [(UUID, CheckedContinuation<Consent?, Never>)]] = [:]
    @ObservationIgnored private var shareQueue: [ShareRequest] = []
    @ObservationIgnored private var shareWaiters: [GateExchangeID: CheckedContinuation<Bool?, Never>] = [:]
    @ObservationIgnored private var deniedUntil: [String: Date] = [:]

    public init(model: any ExtractionModel, sources: [any PersonalSource], grants: [RecipientGrant] = [], journal: GateJournal = GateJournal(),
                answers: ArtifactStore? = nil, deviceName: String, clock: @escaping @Sendable () -> Date = { Date() }) {
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
        var withheld = Withheld()
        var looked: [PersonalItem] = []
        let outcome = await respond(question, withheld: &withheld, looked: &looked)
        var answerRef: ArtifactRef?
        if case .answered(let text) = outcome.0, let answers {
            answerRef = try? await answers.put(ArtifactDraft(
                kind: .personalAnswer, level: outcome.1, owner: .bot(BotSpec.kemoSabeID),
                summaryLine: Self.oneLine("KemoSabe’s answer for \(question.requesterName): \(question.question)"),
                source: PersonalNouns.readSummary(looked), content: text))
        }
        let shared: String? = if case .answered(let text) = outcome.0 { text } else { nil }
        let card = GateAnswerCard(exchange: question.id, askerName: question.requesterName, question: question.question,
                                  outcome: outcome.0.cardOutcome, shared: shared, stayed: PersonalNouns.stayed(looked),
                                  device: deviceName, answer: answerRef)
        return Answer(outcome: outcome.0, card: card, withheld: withheld)
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
            await record(question, .declined, read: "nothing: you turned off asking KemoSabe for this bot")
            return (.declined, .open)
        }
        if let until = deniedUntil[key], until > clock() {
            await record(question, .declined, read: "nothing: you didn’t allow \(question.requesterName) to ask")
            return (.declined, .open)
        }
        if consentGrants(for: question.requester).isEmpty {
            switch await requestConsent(question) {
            case nil:
                await record(question, .waiting, read: "nothing yet: waiting for you to allow \(question.requesterName)")
                return (.waiting, .open)
            case .deny?:
                await record(question, .declined, read: "nothing: you didn’t allow \(question.requesterName) to ask")
                return (.declined, .open)
            case .always?, .once?:
                break
            }
        }
        defer { spendOnce(question.requester) }
        return await answer(question, ceiling: limit?.ceiling, withheld: &withheld, looked: &looked)
    }

    private func answer(_ question: GateQuestion, ceiling: PrivacyLevel?, withheld: inout Withheld,
                        looked: inout [PersonalItem]) async -> (GateOutcome, PrivacyLevel) {
        var found: [PersonalItem] = []
        for source in sources { found += await source.items(matching: question) }
        let relevant = Self.rank(found, for: question.question)
        let now = clock()
        let decision = ContextPolicy.evaluate(relevant.map(\.policyItem), to: question.requester, purpose: .agentQuestion,
                                              grants: grants, ceiling: ceiling, now: now)
        var readable: [PersonalItem] = [], sensitive: [PersonalItem] = []
        for item in relevant {
            switch decision.denied[item.policyItem] {
            case nil: readable.append(item)
            case .needsGrant?: sensitive.append(item)
            case .staysOnDevice?, .secret?, .aboveCeiling?: withheld.add(.notRead, item.label)
            }
        }
        guard model.isAvailable else {
            await record(question, .unavailable, read: "nothing: the on-device model isn’t ready", withheld: withheld)
            return (.unavailable("Apple’s on-device model isn’t ready on the owner’s \(deviceName), so KemoSabe can’t look yet."), .open)
        }

        let chosen = Array(readable.prefix(Self.maxSources))
        if !chosen.isEmpty {
            looked = chosen
            let text = chosen.map { "[\($0.title)]\n\($0.text)" }.joined(separator: "\n\n")
            let result: Extraction.Result
            do { result = try await Extraction.run(model, lookingFor: question.question, in: text) } catch {
                await record(question, .unavailable, read: PersonalNouns.readSummary(chosen), withheld: withheld)
                return (.unavailable("KemoSabe couldn’t read on the owner’s \(deviceName) right now. Ask again in a moment."), .open)
            }
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
            if case .found(let answer, _)? = try? await Extraction.run(model, lookingFor: question.question, in: "[\(best.title)]\n\(best.text)") {
                let request = ShareRequest(exchange: question.id, requesterName: question.requesterName, question: question.question,
                                           answer: answer, sourceTitle: best.title, level: best.label.level)
                switch await requestShare(request) {
                case true?:
                    // Sharing on the card is the grant for exactly this answer.
                    let label = TypeLabel.combining([best.label], as: .personalAnswer)
                    return await disclose(answer, label: label, question, read: [best], withheld: withheld,
                                          extraGrants: [answerGrant(question, label)], automatic: false)
                case false?:
                    withheld.add(.notShared, best.label)
                    await record(question, .declined, read: PersonalNouns.readSummary([best]), withheld: withheld, automatic: false)
                    return (.declined, .open)
                case nil:
                    await record(question, .waiting, read: PersonalNouns.readSummary([best]), withheld: withheld, automatic: false)
                    return (.waiting, .open)
                }
            }
            withheld.add(.notShared, best.label)
        }
        await record(question, .notFound, read: PersonalNouns.readSummary(chosen), withheld: withheld, automatic: true)
        return (.notFound, .open)
    }

    /// Seals the answer for exactly this requester and opens it once, immediately before it's returned.
    private func disclose(_ answer: String, label: TypeLabel, _ question: GateQuestion, read: [PersonalItem], withheld: Withheld,
                          extraGrants: [RecipientGrant], automatic: Bool) async -> (GateOutcome, PrivacyLevel) {
        do {
            let envelope = try await desk.seal(answer, label: label, for: question.requester, exchange: question.id, grants: grants + extraGrants)
            let sent = try await desk.open(envelope, as: question.requester)
            await record(question, .shared, read: PersonalNouns.readSummary(read), shared: sent, withheld: withheld, automatic: automatic)
            return (.answered(sent), label.level)
        } catch {
            await record(question, .failed, read: PersonalNouns.readSummary(read), withheld: withheld, automatic: automatic)
            return (.unavailable("KemoSabe couldn’t send that. Nothing was shared."), .open)
        }
    }

    // MARK: Consent

    /// The owner's answer to the consent prompt on screen.
    public func decide(_ choice: Consent) {
        guard let prompt = pendingConsent else { return }
        let now = clock()
        switch choice {
        case .always, .once:
            grants.removeAll { $0.recipient == prompt.requester.grantKey && $0.purpose == .agentQuestion }
            grants.append(RecipientGrant(recipient: prompt.requester, kinds: Self.consentKinds, purpose: .agentQuestion,
                                         expiresAt: choice == .once ? now.addingTimeInterval(Self.onceLifetime) : nil,
                                         singleUse: choice == .once, grantedAt: now))
            onGrantsChanged?(grants)
        case .deny:
            deniedUntil[prompt.id] = now.addingTimeInterval(quietAfterDeny)
        }
        for (_, waiter) in consentWaiters.removeValue(forKey: prompt.id) ?? [] { waiter.resume(returning: choice) }
        pendingConsent = nil
        if !consentQueue.isEmpty {
            let next = consentQueue.removeFirst()
            pendingConsent = next
            onConsentNeeded?(next)
        }
    }

    /// Remove an agent's consent: it asks again next time.
    public func revokeConsent(_ requester: RecipientID) {
        grants.removeAll { $0.recipient == requester.grantKey && $0.purpose == .agentQuestion }
        onGrantsChanged?(grants)
    }

    /// The owner's answer to the share card on screen.
    public func share(_ allow: Bool) {
        guard let request = pendingShare else { return }
        shareWaiters.removeValue(forKey: request.exchange)?.resume(returning: allow)
        pendingShare = nil
        if !shareQueue.isEmpty {
            let next = shareQueue.removeFirst()
            pendingShare = next
            onShareNeeded?(next)
        }
    }

    public func consentGrants(for requester: RecipientID) -> [RecipientGrant] {
        grants.filter { $0.applies(to: requester, purpose: .agentQuestion, now: clock()) }
    }

    private func requestConsent(_ question: GateQuestion) async -> Consent? {
        let key = question.requester.grantKey, token = UUID(), timeout = consentTimeout
        return await withCheckedContinuation { continuation in
            consentWaiters[key, default: []].append((token, continuation))
            if pendingConsent?.id != key, !consentQueue.contains(where: { $0.id == key }) {
                let prompt = ConsentPrompt(exchange: question.id, requester: question.requester, requesterName: question.requesterName,
                                           question: question.question, purpose: question.purpose)
                if pendingConsent == nil {
                    pendingConsent = prompt
                    onConsentNeeded?(prompt)
                } else {
                    consentQueue.append(prompt)
                }
            }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                // The prompt stays up: an answer after this still counts for the next question.
                guard let self, let index = self.consentWaiters[key]?.firstIndex(where: { $0.0 == token }) else { return }
                self.consentWaiters[key]?.remove(at: index).1.resume(returning: nil)
            }
        }
    }

    private func requestShare(_ request: ShareRequest) async -> Bool? {
        let timeout = shareTimeout
        return await withCheckedContinuation { continuation in
            shareWaiters[request.exchange] = continuation
            if pendingShare == nil {
                pendingShare = request
                onShareNeeded?(request)
            } else {
                shareQueue.append(request)
            }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self, let waiter = self.shareWaiters.removeValue(forKey: request.exchange) else { return }
                if self.pendingShare?.exchange == request.exchange { self.pendingShare = nil }
                self.shareQueue.removeAll { $0.exchange == request.exchange }
                waiter.resume(returning: nil)
            }
        }
    }

    /// "Allow once" covers one question: spent after it, answered or not.
    private func spendOnce(_ requester: RecipientID) {
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

    private func record(_ question: GateQuestion, _ outcome: GateJournalEntry.Outcome, read: String, shared: String? = nil,
                        withheld: Withheld = Withheld(), automatic: Bool = true) async {
        try? await journal.append(GateJournalEntry(
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

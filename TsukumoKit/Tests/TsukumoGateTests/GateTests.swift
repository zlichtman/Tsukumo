import Foundation
import Testing
import TsukumoCore
import TsukumoPolicy
import TsukumoContext
@testable import TsukumoGate

/// A personal source with fixed items.
struct FixedSource: PersonalSource {
    let list: [PersonalItem]
    func items(matching question: GateQuestion) async -> [PersonalItem] { list }
}

/// The fixture model, recording every text it was given, so a test can prove what was never read.
final class RecordingModel: ExtractionModel, @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    let isAvailable: Bool
    init(isAvailable: Bool = true) { self.isAvailable = isAvailable }
    func extract(lookingFor: String, from text: String) async throws -> ExtractionDraft {
        lock.withLock { texts.append(text) }
        return try await FixtureExtractionModel().extract(lookingFor: lookingFor, from: text)
    }
    var read: String { lock.withLock { texts.joined(separator: "\n---\n") } }
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

/// KemoSabe's gate (porting `AgentQuestionTests` and `AgentRequestTests`).
@MainActor
struct GateTests {
    let claude = RecipientID.codingAgent("claude-code")
    let sarahChat = PersonalItem(id: "chat-sarah", kind: .textMessage, level: .personal, title: "your conversation with Sarah",
                                 text: "Sarah: free after 7 tonight, Sarah says dinner works", messages: 7)
    let doorCode = PersonalItem(id: "door", kind: .credential, level: .deviceOnly, title: "a secure note",
                                text: "Sarah door code tonight 4417 free")
    let diary = PersonalItem(id: "diary", kind: .note, level: .secret, title: "your diary", text: "Sarah tonight free secret thoughts")
    let therapy = PersonalItem(id: "therapy", kind: .health, level: .sensitive, title: "your health notes",
                               text: "Sarah: therapy tonight, free after 9")

    func question(_ text: String = "What time is Sarah free tonight?", bot: UUID? = nil) -> GateQuestion {
        GateQuestion(requester: claude, requesterName: "Claude", botID: bot, question: text, purpose: "planning a date")
    }

    func gate(_ items: [PersonalItem], model: any ExtractionModel = FixtureExtractionModel(), answers: ArtifactStore? = nil,
              clock: Clock = Clock(Date(timeIntervalSince1970: 1_900_000_000)), consent: Consent? = .always) -> Gate {
        let gate = Gate(model: model, sources: [FixedSource(list: items)], answers: answers, deviceName: "iPhone", clock: { clock.now })
        gate.consentTimeout = .milliseconds(50)
        gate.shareTimeout = .milliseconds(50)
        if let consent { gate.onConsentNeeded = { [weak gate] _ in gate?.decide(consent) } }
        return gate
    }

    @Test func answersWithOnlyTheAnswerAndShowsWhatStayed() async throws {
        let store = try ArtifactStore()
        let gate = gate([sarahChat, doorCode, diary], answers: store)
        let answer = await gate.ask(question())
        #expect(answer.outcome == .answered("free after 7 tonight, Sarah says dinner works"))
        #expect(answer.card.outcome == .answered)
        #expect(answer.card.stayed == "7 messages, 1 chat")
        #expect(answer.card.caption == "On this iPhone · Apple on-device")
        #expect(answer.withheld.summary == "Not read: 1 Device only secure note, 1 Secret note.")
        // The answer is kept as an artifact on the device, labeled by its sources.
        let ref = try #require(answer.card.answer)
        #expect(await store.effectiveLabel(of: ref)?.level == .personal)
        #expect(try await store.read(ref, for: .appleOnDevice, byteBudget: 1000).text == "free after 7 tonight, Sarah says dinner works")
    }

    @Test func deviceOnlyAndSecretAreNeverReadForAnAgent() async throws {
        let model = RecordingModel()
        let gate = gate([sarahChat, doorCode, diary], model: model)
        _ = await gate.ask(question())
        #expect(model.read.contains("free after 7"))
        #expect(!model.read.contains("4417"))
        #expect(!model.read.contains("secret thoughts"))
    }

    @Test func theJournalHoldsWhatWasSentAndNeverWhatWasLeftOut() async throws {
        let gate = gate([sarahChat, doorCode, diary])
        let q = question()
        _ = await gate.ask(q)
        let entry = try #require(await gate.journal.entry(q.id))
        #expect(entry.outcome == .shared)
        #expect(entry.shared == "free after 7 tonight, Sarah says dinner works")
        #expect(entry.requester == "coding:claude-code" && entry.purpose == "planning a date")
        #expect(entry.withheldCount == 2)
        let written = String(decoding: try TsukumoJSON.encoder.encode(await gate.journal.all()), as: UTF8.self)
        #expect(!written.contains("4417") && !written.contains("secret thoughts") && !written.contains("door code"))
    }

    @Test func alwaysIsAskedOnceAndHolds() async {
        var prompts = 0
        let gate = gate([sarahChat], consent: nil)
        gate.onConsentNeeded = { [weak gate] _ in prompts += 1; gate?.decide(.always) }
        _ = await gate.ask(question())
        _ = await gate.ask(question())
        #expect(prompts == 1)
        #expect(gate.consentGrants(for: claude).count == 1)
        gate.revokeConsent(claude)
        _ = await gate.ask(question())
        #expect(prompts == 2)
    }

    @Test func onceCoversOneQuestion() async {
        var prompts = 0
        let gate = gate([sarahChat], consent: nil)
        gate.onConsentNeeded = { [weak gate] _ in prompts += 1; gate?.decide(.once) }
        #expect(await gate.ask(question()).outcome != .declined)
        #expect(gate.consentGrants(for: claude).isEmpty, "Spent after one question")
        _ = await gate.ask(question())
        #expect(prompts == 2)
    }

    @Test func denyKeepsTheAgentQuietForAWhile() async {
        let clock = Clock(Date(timeIntervalSince1970: 1_900_000_000))
        var prompts = 0
        let gate = gate([sarahChat], clock: clock, consent: nil)
        gate.onConsentNeeded = { [weak gate] _ in prompts += 1; gate?.decide(.deny) }
        #expect(await gate.ask(question()).outcome == .declined)
        #expect(await gate.ask(question()).outcome == .declined)
        #expect(prompts == 1, "No prompt during the quiet period")
        clock.advance(gate.quietAfterDeny + 1)
        _ = await gate.ask(question())
        #expect(prompts == 2)
    }

    @Test func unansweredConsentWaitsAndShareNothing() async throws {
        let gate = gate([sarahChat], consent: nil)
        let q = question()
        let answer = await gate.ask(q)
        #expect(answer.outcome == .waiting)
        #expect(gate.pendingConsent?.requesterName == "Claude", "The prompt stays up")
        #expect(await gate.journal.entry(q.id)?.outcome == .waiting)
        // Answering later counts for the next question.
        gate.decide(.always)
        #expect(await gate.ask(question()).outcome == .answered("free after 7 tonight, Sarah says dinner works"))
    }

    @Test func sensitiveItemsAskOnACardShowingExactlyWhatWouldBeSent() async {
        var shown: [Gate.ShareRequest] = []
        let gate = gate([therapy])
        gate.onShareNeeded = { [weak gate] request in shown.append(request); gate?.share(true) }
        let answer = await gate.ask(question())
        #expect(shown.count == 1 && shown[0].level == .sensitive && shown[0].sourceTitle == "your health notes")
        #expect(answer.outcome == .answered(shown[0].answer))

        let declining = self.gate([therapy])
        declining.onShareNeeded = { [weak declining] _ in declining?.share(false) }
        let declined = await declining.ask(question())
        #expect(declined.outcome == .declined)
        #expect(declined.withheld.summary == "Not shared: 1 Sensitive health item.")
    }

    @Test func aPersonalAnswerNeverWaitsOnASensitiveCard() async {
        var cards = 0
        let gate = gate([sarahChat, therapy])
        gate.onShareNeeded = { _ in cards += 1 }
        let answer = await gate.ask(question())
        #expect(cards == 0)
        #expect(answer.outcome == .answered("free after 7 tonight, Sarah says dinner works"))
        #expect(answer.withheld.summary == "Not shared: 1 Sensitive health item.")
    }

    @Test func aLockedDeviceAnswersNothing() async {
        let model = RecordingModel()
        let gate = gate([sarahChat], model: model)
        gate.isLocked = { true }
        guard case .unavailable = await gate.ask(question()).outcome else { Issue.record("expected unavailable"); return }
        #expect(model.read.isEmpty)
    }

    @Test func noOnDeviceModelMeansNoAnswer() async {
        let gate = gate([sarahChat], model: RecordingModel(isAvailable: false))
        guard case .unavailable = await gate.ask(question()).outcome else { Issue.record("expected unavailable"); return }
    }

    @Test func aBotsScopeLimitsKemoSabe() async {
        let quiet = BotSpec(name: "Pip", engine: .codingAgent("claude-code"), look: .kemoSabe,
                            contextScope: ContextScope(mayAskKemoSabe: false))
        let strict = BotSpec(name: "Tofu", engine: .codingAgent("claude-code"), look: .kemoSabe, contextScope: ContextScope(ceiling: .open))
        let gate = gate([sarahChat])
        gate.apply(bots: [quiet, strict])
        #expect(await gate.ask(question(bot: quiet.id)).outcome == .declined)
        let limited = await gate.ask(question(bot: strict.id))
        #expect(limited.outcome == .notFound)
        #expect(limited.withheld.summary == "Not read: 1 Personal chat.")
    }

    @Test func malformedQuestionsAreRefused() async {
        let gate = gate([sarahChat])
        guard case .refused = await gate.ask(question(" ")).outcome else { Issue.record("expected refused"); return }
        guard case .refused = await gate.ask(question(String(repeating: "a", count: 501))).outcome else { Issue.record("expected refused"); return }
        let local = GateQuestion(requester: .appleOnDevice, requesterName: "Me", question: "q", purpose: "")
        guard case .refused = await gate.ask(local).outcome else { Issue.record("expected refused"); return }
    }

    @Test func nothingRelevantIsNotFound() async {
        let gate = gate([sarahChat])
        #expect(await gate.ask(question("Where is the spare key kept?")).outcome == .notFound)
    }
}

/// Single-use envelopes.
struct DisclosureTests {
    let claude = RecipientID.codingAgent("claude-code")
    let label = TypeLabel(kind: .personalAnswer, level: .personal)

    func grant(_ exchange: GateExchangeID) -> RecipientGrant {
        RecipientGrant(recipient: claude, items: [PolicyItem(id: "answer:" + exchange.description, label: label)], purpose: .agentQuestion, singleUse: true)
    }

    @Test func anEnvelopeOpensOnceForItsRecipientOnly() async throws {
        let desk = DisclosureDesk()
        let exchange = GateExchangeID()
        let envelope = try await desk.seal("After 7 tonight", label: label, for: claude, exchange: exchange, grants: [grant(exchange)])
        #expect(!envelope.description.contains("After 7"))
        #expect(!String(describing: Mirror(reflecting: envelope).children.map(\.value)).contains("After 7"))
        #expect(try await desk.open(envelope, as: claude) == "After 7 tonight")
        await #expect(throws: GateError.envelopeSpent) { try await desk.open(envelope, as: claude) }

        let other = try await desk.seal("x", label: label, for: claude, exchange: exchange, grants: [grant(exchange)])
        await #expect(throws: GateError.wrongRecipient) { try await desk.open(other, as: .codingAgent("codex")) }
        await #expect(throws: GateError.envelopeSpent) { try await desk.open(other, as: claude) }
    }

    @Test func envelopesExpireAndNeedThePolicy() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_900_000_000))
        let desk = DisclosureDesk(clock: { clock.now })
        let exchange = GateExchangeID()
        let envelope = try await desk.seal("a", label: label, for: claude, exchange: exchange, grants: [grant(exchange)])
        clock.advance(DisclosureDesk.lifetime + 1)
        await #expect(throws: GateError.expired) { try await desk.open(envelope, as: claude) }
        await #expect(throws: PolicyDenial.needsGrant) { try await desk.seal("a", label: label, for: claude, exchange: exchange, grants: []) }
        await #expect(throws: PolicyDenial.staysOnDevice) {
            try await desk.seal("a", label: TypeLabel(kind: .personalAnswer, level: .deviceOnly), for: claude, exchange: exchange, grants: [grant(exchange)])
        }
    }
}

/// The extraction contract.
struct ExtractionTests {
    @Test func anAnswerMustBeBackedByTheSource() {
        let source = "Sarah: free after 7 tonight"
        #expect(Extraction.validate(ExtractionDraft(found: true, answer: "After 7 tonight", excerpt: "free after 7 tonight"), source: source)
                == .found(answer: "After 7 tonight", excerpt: "free after 7 tonight"))
        // An invented quote shares nothing.
        #expect(Extraction.validate(ExtractionDraft(found: true, answer: "Noon", excerpt: "lunch at noon Friday"), source: source) == .notFound)
        // An unsupported answer is replaced by the quote.
        #expect(Extraction.validate(ExtractionDraft(found: true, answer: "Probably midnight", excerpt: "free after 7 tonight"), source: source)
                == .found(answer: "free after 7 tonight", excerpt: "free after 7 tonight"))
        #expect(Extraction.validate(ExtractionDraft(found: false, answer: "x", excerpt: "x"), source: source) == .notFound)
    }

    @Test func longSourcesAreFocusedOnTheQuestion() {
        let filler = (0..<400).map { "line \($0) about the weather" }.joined(separator: "\n")
        let text = filler + "\nSarah: free after 7 tonight\n" + filler
        let focused = Extraction.focus(text, on: "When is Sarah free tonight?")
        #expect(focused.count <= Extraction.maxSource)
        #expect(focused.contains("Sarah: free after 7 tonight"))
    }

    @Test func appleOnDeviceRunsOnlyWhereItIsAvailable() async throws {
        #if canImport(FoundationModels)
        guard #available(iOS 26, macOS 26, *) else { return }
        let model = AppleExtractionModel()
        guard model.isAvailable else { return }  // Skipped where Apple Intelligence isn't on.
        let result = try await Extraction.run(model, lookingFor: "What time is Sarah free?", in: "Sarah: I'm free after 7 tonight.")
        if case .found(let answer, _) = result { #expect(answer.contains("7")) }
        #endif
    }
}

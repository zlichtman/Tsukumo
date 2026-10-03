import Foundation
import Testing
import TsukumoCore
import TsukumoPolicy
import TsukumoContext
@testable import TsukumoSystemOne

/// A provider that answers each question with fixed probabilities (or fails), counting its calls
/// and keeping what it was sent.
final class FakeProvider: DecisionProvider, @unchecked Sendable {
    private let lock = NSLock()
    let modelVersion: String
    private let answer: (DecisionQuestion) -> [Double]
    private let failure: Error?
    private var requests: [DecisionRequest] = []
    init(_ version: String = "fake", failure: Error? = nil, answer: @escaping (DecisionQuestion) -> [Double]) {
        modelVersion = version; self.failure = failure; self.answer = answer
    }
    convenience init(_ version: String = "fake", picking index: Int, confidence: Double) {
        self.init(version) { question in
            let rest = (1 - confidence) / Double(question.options.count - 1)
            return question.options.indices.map { $0 == index ? confidence : rest }
        }
    }
    func decide(_ request: DecisionRequest) async throws -> DecisionResult {
        lock.withLock { requests.append(request) }
        if let failure { throw failure }
        return DecisionResult(modelVersion: modelVersion, answers: request.questions.map { DecisionAnswer(questionID: $0.id, probabilities: answer($0)) },
                              calibrated: false, abstention: nil)
    }
    var calls: Int { lock.withLock { requests.count } }
    var sent: [DecisionRequest] { lock.withLock { requests } }
}

/// The decision cascade (porting `SystemOneTests`): per-kind thresholds and abstention, providers in
/// order, every hosted call checked by the policy first, and a journal without request words.
struct SystemOneTests {
    let request = DecisionRequest(state: "plan dinner with Sarah tonight",
                                  questions: [DecisionQuestion(id: "fit", kind: .choice, instruction: "Which time fits?", options: ["6 PM", "7:30 PM", "9 PM"])],
                                  deadline: Date().addingTimeInterval(60))

    @Test func aConfidentLayaDecidesAndJevIsNotAsked() async {
        let laya = FakeProvider(picking: 1, confidence: 0.97), jev = FakeProvider(picking: 0, confidence: 0.99)
        let journal = DecisionJournal()
        let decision = await SystemOne.decide(.planFit, request, providers: SystemOneProviders(local: laya, remotes: [RemoteDecider(source: "jev", host: "h", provider: jev)], journal: journal), level: .personal)
        #expect(decision.decidedBy == .laya && decision.result?.answers.first?.selectedIndex == 1)
        #expect(jev.calls == 0)
        #expect(await journal.all().count == 1)
    }

    @Test func eachKindHasItsOwnThreshold() async {
        let laya = FakeProvider(picking: 0, confidence: 0.85)
        #expect(await SystemOne.decide(.planFit, request, providers: SystemOneProviders(local: laya), level: .open).decidedBy == .laya)
        #expect(await SystemOne.decide(.routineIntent, request, providers: SystemOneProviders(local: laya), level: .open).abstained)
        #expect(await SystemOne.decide(.route, request, providers: SystemOneProviders(local: laya), level: .open).abstained)
    }

    @Test func anUnsureLayaAsksJevForAPersonalRequest() async {
        let laya = FakeProvider(picking: 1, confidence: 0.5), jev = FakeProvider("Jev · test", picking: 2, confidence: 0.95)
        let decision = await SystemOne.decide(.planFit, request, providers: SystemOneProviders(local: laya, remotes: [RemoteDecider(source: "jev", host: "api.typesafe.ai", provider: jev)]), level: .personal)
        #expect(decision.decidedBy == "jev" && decision.result?.answers.first?.selectedIndex == 2)
        #expect(decision.steps.map(\.reason) == [.lowConfidence, nil])
        #expect(decision.steps.last?.sentTo == "api.typesafe.ai")
        #expect(jev.sent.first?.state == request.state, "Only the packet")
    }

    @Test func sensitiveDeviceOnlyAndSecretRequestsNeverReachAHostedService() async {
        for level in [PrivacyLevel.sensitive, .deviceOnly, .secret] {
            let jev = FakeProvider(picking: 0, confidence: 0.99)
            let decision = await SystemOne.decide(.planFit, request, providers: SystemOneProviders(remotes: [RemoteDecider(source: "jev", host: "h", provider: jev)]), level: level)
            #expect(jev.calls == 0, "\(level)")
            #expect(decision.steps.first?.reason == .privacy && decision.abstained)
        }
    }

    @Test func providersAreAskedInOrderUntilOneIsSure() async {
        let first = FakeProvider(picking: 0, confidence: 0.4), second = FakeProvider(picking: 0, confidence: 0.99), third = FakeProvider(picking: 0, confidence: 0.99)
        let remotes = [RemoteDecider(source: "a", host: "a", provider: first), RemoteDecider(source: "b", host: "b", provider: second),
                       RemoteDecider(source: "c", host: "c", provider: third)]
        let decision = await SystemOne.decide(.planFit, request, providers: SystemOneProviders(remotes: remotes), level: .open)
        #expect(decision.decidedBy == "b" && first.calls == 1 && second.calls == 1 && third.calls == 0)
    }

    @Test func failuresAndUnfamiliarInputAbstain() async {
        struct Boom: Error {}
        let broken = FakeProvider(failure: Boom()) { _ in [] }
        let failed = await SystemOne.decide(.planFit, request, providers: SystemOneProviders(local: broken), level: .open)
        #expect(failed.abstained && failed.steps.first?.reason == .unavailable)
        let rejected = await SystemOne.decide(.planFit, request, providers: SystemOneProviders(remotes: [
            RemoteDecider(source: "jev", host: "h", provider: FakeProvider(failure: RemoteDecisionError.keyRejected) { _ in [] })]), level: .open)
        #expect(rejected.steps.first?.reason == .rejected)
        let laya = FakeProvider(picking: 0, confidence: 0.99)
        let foreign = DecisionRequest(state: "今晩サラと夕食", questions: request.questions, deadline: request.deadline)
        let unfamiliar = await SystemOne.decide(.planFit, foreign, providers: SystemOneProviders(local: laya), level: .open)
        #expect(unfamiliar.steps.first?.reason == .outOfDistribution && laya.calls == 0)
    }

    @Test func malformedProviderOutputIsRefused() async {
        let bad = FakeProvider { _ in [0.9, 0.9, 0.9] }
        #expect(await SystemOne.decide(.planFit, request, providers: SystemOneProviders(local: bad), level: .open).abstained)
    }

    @Test func theJournalNeverHoldsTheRequestsWords() async throws {
        let journal = DecisionJournal()
        _ = await SystemOne.decide(.planFit, request, providers: SystemOneProviders(local: FakeProvider(picking: 1, confidence: 0.99), journal: journal), level: .open)
        let written = String(decoding: try TsukumoJSON.encoder.encode(await journal.all()), as: UTF8.self)
        #expect(!written.contains("Sarah") && !written.contains("dinner"))
        #expect(written.contains("7:30 PM"), "The choices are kept, so a decision can be marked")
        // No provider, nothing to journal.
        _ = await SystemOne.decide(.planFit, request, providers: SystemOneProviders(journal: journal), level: .open)
        #expect(await journal.all().count == 1)
    }

    @Test func thePersonalLayerDecidesWhereItBeatTheBase() async {
        var head = PersonalHead(questionID: "fit")
        head.choiceBias = ["9 PM": 5]
        let layer = PersonalLayer(heads: [.planFit: head])
        let laya = FakeProvider(picking: 0, confidence: 0.6)
        let decision = await SystemOne.decide(.planFit, request, providers: SystemOneProviders(local: laya, personal: layer), level: .open)
        #expect(decision.result?.answers.first?.selectedIndex == 2)
        #expect(decision.steps.first?.personal == true)
        #expect(decision.result?.modelVersion.hasSuffix("+ personal layer") == true)
    }
}

/// `route` and `selectContext`, and their defaults on abstention.
struct TurnDecisionTests {
    let pip = BotSpec(name: "Pip", engine: .appleOnDevice, role: "Plans dates and dinners", look: .kemoSabe)
    let tofu = BotSpec(name: "Tofu", engine: .codingAgent("claude-code"), role: "Codes in my projects", look: .kemoSabe)

    @Test func tagsDecideWithoutSystemOne() async {
        let laya = FakeProvider(picking: 0, confidence: 0.99)
        let thread = ChatThread(botIDs: [pip.id, tofu.id])
        let routed = await SystemOne.route("@tofu fix the build", in: thread, bots: [pip, tofu], providers: SystemOneProviders(local: laya), level: .open)
        #expect(routed.recipients == [tofu.id] && routed.tagged && laya.calls == 0)
    }

    @Test func untaggedMessagesAreRoutedBySystemOne() async throws {
        let laya = FakeProvider(picking: 1, confidence: 0.97)
        let thread = ChatThread(botIDs: [pip.id, tofu.id], lastSpokenTo: pip.id)
        let routed = await SystemOne.route("the build is failing", in: thread, bots: [pip, tofu], providers: SystemOneProviders(local: laya), level: .open)
        #expect(routed.recipients == [tofu.id] && routed.decidedBy == .laya)
        let options = try #require(laya.sent.first?.questions.first?.options)
        #expect(options == ["Pip: Plans dates and dinners", "Tofu: Codes in my projects"])
    }

    @Test func abstainingRoutesToTheBotLastSpokenTo() async {
        let thread = ChatThread(botIDs: [pip.id, tofu.id], lastSpokenTo: tofu.id)
        let unsure = await SystemOne.route("and tomorrow?", in: thread, bots: [pip, tofu],
                                           providers: SystemOneProviders(local: FakeProvider(picking: 0, confidence: 0.5)), level: .open)
        #expect(unsure.recipients == [tofu.id] && unsure.decidedBy == .fallback)
        let none = await SystemOne.route("and tomorrow?", in: thread, bots: [pip, tofu], providers: .none, level: .open)
        #expect(none.recipients == [tofu.id] && none.decidedBy == .fallback)
        let fresh = await SystemOne.route("hello", in: ChatThread(botIDs: [pip.id, tofu.id]), bots: [pip, tofu], providers: .none, level: .open)
        #expect(fresh.recipients == [pip.id])
    }

    @Test func aSensitiveThreadNeverRoutesThroughAHostedService() async {
        let jev = FakeProvider(picking: 1, confidence: 0.99)
        let thread = ChatThread(botIDs: [pip.id, tofu.id], lastSpokenTo: pip.id)
        let routed = await SystemOne.route("x", in: thread, bots: [pip, tofu],
                                           providers: SystemOneProviders(remotes: [RemoteDecider(source: "jev", host: "h", provider: jev)]), level: .sensitive)
        #expect(jev.calls == 0 && routed.recipients == [pip.id])
    }

    func store() async throws -> (ArtifactStore, ArtifactRef, ArtifactRef) {
        let store = try ArtifactStore()
        let menu = try await store.put(ArtifactDraft(kind: .note, level: .open, owner: .owner, summaryLine: "Restaurants on Valencia", content: "Osteria Lucia"))
        let code = try await store.put(ArtifactDraft(kind: .file, level: .open, owner: .owner, summaryLine: "Build script", content: "make all"))
        return (store, menu, code)
    }

    @Test func selectContextPicksTheNeededReferences() async throws {
        let (store, menu, _) = try await store()
        // "Needed" only for the restaurant list.
        let laya = FakeProvider { question in question.instruction.contains("Restaurants") ? [0.02, 0.98] : [0.97, 0.03] }
        let chooser = SystemOneContextChooser(providers: SystemOneProviders(local: laya), level: .open)
        let set = try await ContextSelection.run(turn: TurnRequest(request: "date spot tonight", recipient: .codingAgent("claude-code")),
                                                 store: store, chooser: chooser)
        #expect(set.pages.map(\.ref) == [menu] && !set.usedDefault)
        #expect(laya.calls == 1, "Decides once")
    }

    @Test func selectContextAbstainingIncludesEverythingAuthorizedThatFits() async throws {
        let (store, menu, code) = try await store()
        let chooser = SystemOneContextChooser(providers: SystemOneProviders(local: FakeProvider(picking: 1, confidence: 0.6)), level: .open)
        let set = try await ContextSelection.run(turn: TurnRequest(request: "date spot", recipient: .codingAgent("claude-code")), store: store, chooser: chooser)
        #expect(set.usedDefault && Set(set.pages.map(\.ref)) == [menu, code])
    }

    @Test func selectContextKeepsPrivateSummariesFromHostedServices() async throws {
        let store = try ArtifactStore()
        _ = try await store.put(ArtifactDraft(kind: .note, level: .sensitive, owner: .owner, summaryLine: "Therapy notes", content: "x"))
        let jev = FakeProvider(picking: 1, confidence: 0.99)
        let chooser = SystemOneContextChooser(providers: SystemOneProviders(remotes: [RemoteDecider(source: "jev", host: "h", provider: jev)]), level: .open)
        let set = try await ContextSelection.run(turn: TurnRequest(request: "x", recipient: .appleOnDevice), store: store, chooser: chooser)
        #expect(jev.calls == 0, "A Sensitive summary raises the packet's level")
        #expect(set.usedDefault)
    }
}

/// The owner's personal layer (porting `SystemOnePersonalTests`).
struct PersonalLayerTests {
    func marks(_ count: Int, kind: DecisionKind = .planFit, laya: [Double] = [0.6, 0.3, 0.1], correct: Int = 1) -> [MarkedDecision] {
        (0..<count).map { index in
            MarkedDecision(at: Date(timeIntervalSince1970: Double(index) * 60), kind: kind, questionID: "fit",
                           options: ["9:00 AM", "2:00 PM", "5:00 PM"], laya: laya, shown: 0, correct: correct)
        }
    }

    @Test func theNewestMarksAreHeldOut() {
        let (train, held) = PersonalTraining.split(marks(40))
        #expect(held.count == 12 && train.count == 28)
        #expect(held.allSatisfy { mark in train.allSatisfy { $0.at < mark.at } })
    }

    @Test func theLayerTurnsOnWhenItBeatsLayaOnHeldOutMarks() throws {
        let trained = try #require(PersonalTraining.train(.planFit, marks: marks(40)))
        #expect(trained.report.turnedOn && trained.head != nil)
        #expect(trained.report.personalRight >= trained.report.baseRight + PersonalTraining.minimumWin)
    }

    @Test func theBaseStaysWhenItIsAlreadyRight() throws {
        let trained = try #require(PersonalTraining.train(.planFit, marks: marks(40, correct: 0)))
        #expect(!trained.report.turnedOn && trained.head == nil)
    }

    @Test func nothingTrainsBelowTheMinimumOrOnAnotherDecisionsMarks() {
        #expect(PersonalTraining.train(.planFit, marks: marks(29)) == nil)
        #expect(PersonalTraining.train(.route, marks: marks(40)) == nil)
    }

    @Test func theLayerOnlyReweighsTheChoicesItWasGiven() {
        var head = PersonalHead(questionID: "fit")
        head.choiceBias = ["Something else": 50]
        let probabilities = head.probabilities(base: [0.6, 0.3, 0.1], options: ["9:00 AM", "2:00 PM", "5:00 PM"])
        #expect(probabilities.count == 3 && abs(probabilities.reduce(0, +) - 1) < 1e-9)
        #expect(probabilities.indices.max { probabilities[$0] < probabilities[$1] } == 0)
    }
}

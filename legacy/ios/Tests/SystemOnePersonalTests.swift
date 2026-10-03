import XCTest
#if os(macOS)
@testable import KemoSabeMac
#else
@testable import KemoSabe
#endif

/// Training Laya on your own decisions (September 29, 2026): marks stored on this device, a
/// personal layer over Laya's base scores that turns on only when it beats the base on held-out
/// marks, reset and delete, and the journal saying which layer decided. Shared by iPhone and Mac.
final class SystemOnePersonalTests: XCTestCase {
    private var folders: [URL] = []
    override func tearDown() { for folder in folders { try? FileManager.default.removeItem(at: folder) } }
    private func folder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("system-one-personal-" + UUID().uuidString, isDirectory: true)
        folders.append(url); return url
    }
    private let times = ["9:00 AM", "2:00 PM", "5:00 PM"]
    /// A Plan fit mark where Laya leaned to 9:00 AM; `correct` is what the person says was right.
    private func example(_ index: Int, correct: Int, laya: [Double] = [0.5, 0.35, 0.15], kind: DecisionKind = .candidateFit) -> SystemOneExample {
        .init(at: Date(timeIntervalSince1970: 1_800_000_000 + Double(index) * 60), kind: kind, questionID: kind == .candidateFit ? "fit" : "missing",
              options: kind == .candidateFit ? times : ["missing information", "fully specified"], laya: kind == .candidateFit ? laya : [0.6, 0.4],
              shown: 0, correct: correct)
    }

    // MARK: Marks

    func testMarksAreKeptReplacedUndoneAndDeleted() async throws {
        let folder = folder()
        let store = SystemOneExamples(url: folder.appendingPathComponent(SystemOneExamples.fileName))
        let record = SystemOneRecord(at: Date(), kind: .candidateFit, decidedBy: .fallback,
                                     steps: [.init(provider: .laya, version: "Laya test", score: 0.62, reason: .lowConfidence, layer: .base)],
                                     milliseconds: 40, questions: [.init(id: "fit", options: times, laya: [0.62, 0.3, 0.08])])
        let right = try XCTUnwrap(SystemOneExample(record: record, correct: 0))
        XCTAssertTrue(right.right)
        try await store.mark(right)
        let wrong = try XCTUnwrap(SystemOneExample(record: record, correct: 1))
        XCTAssertFalse(wrong.right)
        try await store.mark(wrong)
        var all = await store.all()
        XCTAssertEqual(all.count, 1, "Marking again replaces")
        XCTAssertEqual(all.first?.correct, 1)
        XCTAssertEqual(all.first?.laya, [0.62, 0.3, 0.08])
        XCTAssertTrue(VoiceModelFiles.isExcludedFromBackup(folder), "Device only: out of backups")
        try await store.unmark(record.id)
        all = await store.all()
        XCTAssertTrue(all.isEmpty)
        try await store.mark(right)
        try await store.deleteAll()
        all = await store.all()
        XCTAssertTrue(all.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(SystemOneExamples.fileName).path))
    }

    func testOnlyWhatLayaScoredCanBeMarked() throws {
        let jevOnly = SystemOneRecord(at: Date(), kind: .candidateFit, decidedBy: .jev,
                                      steps: [.init(provider: .jev, version: "Jev test", score: 0.9, reason: nil, sentTo: "api.typesafe.ai")],
                                      milliseconds: 90, questions: [.init(id: "fit", options: times, answer: 1)])
        XCTAssertNil(jevOnly.markable)
        XCTAssertNil(SystemOneExample(record: jevOnly, correct: 1))
        let older = SystemOneRecord(at: Date(), kind: .candidateFit, decidedBy: .laya, steps: [], milliseconds: 10)
        XCTAssertNil(older.markable, "Records from before September 29 have no choices")
        let decided = SystemOneRecord(at: Date(), kind: .candidateFit, decidedBy: .jev, steps: [], milliseconds: 10,
                                      questions: [.init(id: "fit", options: times, laya: [0.6, 0.3, 0.1], answer: 2)])
        XCTAssertEqual(decided.markable?.shown, 2, "The decided answer is what's marked, not Laya's lean")
        XCTAssertNil(SystemOneExample(record: decided, correct: 3), "Only one of its choices")
    }

    // MARK: Training

    func testTheNewestMarksAreHeldOut() {
        let marks = (0..<40).map { example($0, correct: 1) }.shuffled()
        let (train, held) = PersonalTraining.split(marks)
        XCTAssertEqual(held.count, 12)
        XCTAssertEqual(train.count, 28)
        XCTAssertTrue(train.map(\.at).max()! < held.map(\.at).min()!, "It's checked on decisions newer than any it learned from")
        XCTAssertEqual(PersonalTraining.split(Array(marks.prefix(30))).heldOut.count, 9, "30% of the minimum, rounded up")
        XCTAssertEqual(PersonalTraining.split(Array(marks.prefix(20))).heldOut.count, 8, "At least eight")
    }

    func testTheLayerTurnsOnWhenItBeatsLayaOnHeldOutMarks() throws {
        // Laya keeps leaning to 9:00 AM; the person keeps saying 2:00 PM.
        let marks = (0..<40).map { example($0, correct: 1, laya: [0.5 + Double($0 % 3) * 0.02, 0.35, 0.15 - Double($0 % 3) * 0.02]) }
        let (report, head) = try XCTUnwrap(PersonalTraining.train(.candidateFit, examples: marks))
        XCTAssertEqual(report.heldOut, 12); XCTAssertEqual(report.trained, 28)
        XCTAssertEqual(report.baseRight, 0)
        XCTAssertEqual(report.personalRight, 12)
        XCTAssertTrue(report.turnedOn)
        XCTAssertEqual(report.summary, "On 12 held-out decisions: Laya alone 0 right, with your layer 12. Your layer is on.")
        let layer = try XCTUnwrap(head)
        let reweighed = layer.probabilities(base: [0.5, 0.35, 0.15], options: times)
        XCTAssertEqual(reweighed.indices.max { reweighed[$0] < reweighed[$1] }, 1)
        XCTAssertEqual(reweighed.reduce(0, +), 1, accuracy: 1e-9)
    }

    func testTheBaseStaysWhenTheLayerDoesNotBeatIt() throws {
        // Laya is already right every time: nothing to fix.
        let right = (0..<40).map { example($0, correct: 0) }
        let kept = try XCTUnwrap(PersonalTraining.train(.candidateFit, examples: right))
        XCTAssertFalse(kept.report.turnedOn); XCTAssertNil(kept.head)
        XCTAssertEqual(kept.report.baseRight, kept.report.heldOut)
        XCTAssertTrue(kept.report.summary.hasSuffix("Laya alone got them all right, so there's nothing to fix yet. Keeping Laya's base."))
        // The newest 12 marks disagree with everything it learned from: no better than the base.
        let shifted = (0..<40).map { example($0, correct: $0 < 28 || $0 == 33 ? 1 : 0) }
        let tie = try XCTUnwrap(PersonalTraining.train(.candidateFit, examples: shifted))
        XCTAssertLessThanOrEqual(tie.report.personalRight, tie.report.baseRight)
        XCTAssertFalse(tie.report.turnedOn); XCTAssertNil(tie.head)
        XCTAssertTrue(tie.report.summary.hasSuffix("That isn't better, so Laya's base stays."))
    }

    /// Better by one held-out decision is too close to luck: the base stays.
    func testOneMoreRightIsNotEnough() throws {
        // Held out (the newest 12): five where 9:00 AM was right, six where 2:00 PM was, one 5:00 PM.
        let marks = (0..<40).map { index in example(index, correct: index < 28 ? 1 : index < 33 ? 0 : index < 39 ? 1 : 2) }
        let result = try XCTUnwrap(PersonalTraining.train(.candidateFit, examples: marks))
        XCTAssertEqual(result.report.baseRight, 5)
        XCTAssertEqual(result.report.personalRight, 6)
        XCTAssertFalse(result.report.turnedOn); XCTAssertNil(result.head)
        XCTAssertTrue(result.report.summary.hasSuffix("It needs to get at least 2 more right than Laya alone, so Laya's base stays."))
        // Two more right turns it on.
        let two = (0..<40).map { index in example(index, correct: index < 28 ? 1 : index < 33 ? 0 : 1) }
        let on = try XCTUnwrap(PersonalTraining.train(.candidateFit, examples: two))
        XCTAssertEqual(on.report.personalRight - on.report.baseRight, 2)
        XCTAssertTrue(on.report.turnedOn); XCTAssertNotNil(on.head)
    }

    func testNothingTrainsBelowTheMinimum() {
        let few = (0..<(PersonalTraining.minimumExamples - 1)).map { example($0, correct: 1) }
        XCTAssertNil(PersonalTraining.train(.candidateFit, examples: few))
        let state = PersonalTraining.trainAll(few)
        XCTAssertTrue(state.reports.isEmpty); XCTAssertTrue(state.heads.isEmpty)
        XCTAssertEqual(PersonalTraining.counts(few)[.candidateFit], PersonalTraining.minimumExamples - 1)
    }

    func testEachDecisionTrainsOnItsOwnMarks() {
        let marks = (0..<34).map { example($0, correct: 1) } + (0..<5).map { example($0, correct: 1, kind: .missingInformation) }
        let state = PersonalTraining.trainAll(marks)
        XCTAssertNotNil(state.report(.candidateFit))
        XCTAssertNil(state.report(.missingInformation), "Five marks aren't enough")
        XCTAssertEqual(state.activeKinds, [.candidateFit])
    }

    func testTrainingTakesSecondsNotMinutes() {
        let marks = (0..<400).map { example($0, correct: $0 % 4 == 0 ? 2 : 1) }
        let started = Date()
        _ = PersonalTraining.trainAll(marks)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    // MARK: Deciding with the layer

    private final class Leaning: DecisionProvider, @unchecked Sendable {
        let modelVersion = "Laya test"
        func decide(_ request: DecisionRequest) async throws -> DecisionResult {
            .init(modelVersion: modelVersion, answers: request.questions.map { question in
                .init(questionID: question.id, probabilities: question.options.count == 3 ? [0.5, 0.35, 0.15] : Array(repeating: 1 / Double(question.options.count), count: question.options.count))
            }, calibrated: false, abstention: nil)
        }
    }
    private func request(_ id: String = "fit") -> DecisionRequest {
        .init(state: "Make time for reading tomorrow afternoon", questions: [.init(id: id, kind: .choice, instruction: "Which permitted time best fits the stated request?", options: times)],
              deadline: Date().addingTimeInterval(30))
    }

    func testTheLayerDecidesAndTheJournalSaysSo() async throws {
        let marks = (0..<40).map { example($0, correct: 1) }
        let state = PersonalTraining.trainAll(marks)
        let folder = folder(), store = SystemOnePersonalStore(folder: folder)
        try store.save(state)
        let model = try XCTUnwrap(store.activeModel())
        let journal = SystemOneJournal(url: folder.appendingPathComponent(SystemOneJournal.fileName))

        let base = await SystemOne.decide(request(), kind: .candidateFit, level: .deviceOnly, providers: .init(laya: Leaning(), jev: nil, journal: journal))
        XCTAssertNil(base, "Laya alone is 50% sure, below plan fit's 80%")
        let result = await SystemOne.decide(request(), kind: .candidateFit, level: .deviceOnly, providers: .init(laya: Leaning(), jev: nil, journal: journal, personal: model))
        XCTAssertEqual(result?.answers.first?.selectedIndex, 1)
        XCTAssertEqual(result?.modelVersion, "Laya test + personal layer")

        let records = await journal.records()
        XCTAssertEqual(records.map(\.decidedBy), [.fallback, .laya])
        XCTAssertEqual(records.first?.steps.first?.layer, .base)
        XCTAssertNil(records.first?.layer)
        let decided = try XCTUnwrap(records.last)
        XCTAssertEqual(decided.layer, .personal)
        XCTAssertEqual(decided.steps.first?.layer, .personal)
        XCTAssertEqual(decided.questions?.first?.laya, [0.5, 0.35, 0.15], "Laya's base scores are kept for the next training")
        XCTAssertNotNil(decided.questions?.first?.personal)
        XCTAssertEqual(decided.questions?.first?.answer, 1)
        XCTAssertEqual(SystemOneView.decidedLine(decided), "Decided by Laya · your layer")
    }

    func testTheLayerOnlyReweighsTheChoicesItWasGiven() throws {
        let state = PersonalTraining.trainAll((0..<40).map { example($0, correct: 1) })
        let model = SystemOnePersonalModel(heads: state.heads)
        let base = DecisionResult(modelVersion: "Laya test", answers: [.init(questionID: "fit", probabilities: [0.5, 0.35, 0.15])], calibrated: false, abstention: nil)
        let applied = try XCTUnwrap(model.apply(to: base, for: request(), kind: .candidateFit))
        XCTAssertEqual(applied.answers.first?.probabilities.count, 3)
        XCTAssertNil(model.apply(to: base, for: request("other"), kind: .candidateFit), "Another question keeps the base")
        XCTAssertNil(model.apply(to: base, for: request(), kind: .missingInformation), "Another decision keeps the base")
    }

    func testResetGoesBackToTheBaseAndLayaMustBeThereForTheLayer() throws {
        let folder = folder(), store = SystemOnePersonalStore(folder: folder)
        try store.save(PersonalTraining.trainAll((0..<40).map { example($0, correct: 1) }))
        let defaults = UserDefaults(suiteName: "system-one-personal-" + UUID().uuidString)!
        let keys = KeychainJevKey(service: "com.zlichtman.kemosabe.system-one.tests." + UUID().uuidString)
        XCTAssertNotNil(SystemOneProviders.resolve(defaults: defaults, keys: keys, layaAvailable: true, folder: folder, laya: { Leaning() }).personal)
        XCTAssertNil(SystemOneProviders.resolve(defaults: defaults, keys: keys, layaAvailable: false, folder: folder).personal, "No Laya, no layer")
        store.reset()
        XCTAssertNil(store.activeModel())
        XCTAssertTrue(store.state().reports.isEmpty)
        XCTAssertNil(SystemOneProviders.resolve(defaults: defaults, keys: keys, layaAvailable: true, folder: folder, laya: { Leaning() }).personal)
    }

    func testReportsReadPlainly() {
        let report = SystemOnePersonalReport(kind: .candidateFit, at: Date(), examples: 40, trained: 28, heldOut: 12, baseRight: 7, personalRight: 7, turnedOn: false)
        XCTAssertEqual(report.summary, "On 12 held-out decisions: Laya alone 7 right, with your layer 7. That isn't better, so Laya's base stays.")
        XCTAssertFalse(report.summary.contains("\u{2014}"))
        let close = SystemOnePersonalReport(kind: .candidateFit, at: Date(), examples: 40, trained: 28, heldOut: 12, baseRight: 7, personalRight: 8, turnedOn: false)
        XCTAssertEqual(close.summary, "On 12 held-out decisions: Laya alone 7 right, with your layer 8. It needs to get at least 2 more right than Laya alone, so Laya's base stays.")
    }
}

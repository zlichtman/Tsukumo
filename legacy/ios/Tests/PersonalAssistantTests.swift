import XCTest
@testable import KemoSabe

@MainActor final class PersonalAssistantTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private let destination = RoutineDestination(id: "calendar", sourceID: "source", name: "Kemo", sourceName: "Local", reminders: false, maySync: false)
    private func write(now: Date = Date()) -> RoutineWrite {
        .init(operationID: UUID(), operation: .createBlock, destination: destination,
              start: now.addingTimeInterval(3600), end: now.addingTimeInterval(5400), timeZone: "UTC",
              calendarDigest: "day", targetID: nil, targetDigest: nil)
    }
    private func proposal(_ write: RoutineWrite) -> RoutineProposal {
        var p = RoutineProposal(key: UUID().uuidString, kind: .scheduleChange, title: "Focus", body: "Review block",
            scheduledAt: write.start, createdAt: Date(), expiresAt: Date().addingTimeInterval(600))
        p.routineWrite = write; return p
    }
    func testUncalibratedDecisionsDoNotClaimCalibration() async throws {
        let request = DecisionRequest(state: "State", questions: [.init(id: "x", kind: .choice, instruction: "Choose", options: ["a","b"])], deadline: Date().addingTimeInterval(30))
        try request.validate()
        XCTAssertThrowsError(try DecisionResult(modelVersion: "test", answers: [.init(questionID: "x", probabilities: [.nan,1])], calibrated: true, abstention: nil).validate(for: request))
        XCTAssertThrowsError(try DecisionResult(modelVersion: "test", answers: [.init(questionID: "wrong", probabilities: [0.5,0.5])], calibrated: false, abstention: nil).validate(for: request))
    }
    func testCorrectionsChangeRankingAndForgettingRebuilds() async throws {
        let learner = PreferenceLearner(url: directory().appendingPathComponent("preferences.json"))
        let source = UUID(), morning = PreferenceLearner.features(hour: 9, duration: 60), afternoon = PreferenceLearner.features(hour: 15, duration: 60)
        try await learner.record(.init(id: UUID(), sourceID: UUID(), features: morning, feedback: .rejected, createdAt: Date()))
        let before = try await learner.snapshot()
        try await learner.record(.init(id: UUID(), sourceID: source, features: afternoon, feedback: .correction, createdAt: Date()))
        let after = try await learner.snapshot()
        XCTAssertGreaterThan(PreferenceLearner.score(afternoon, in: after), PreferenceLearner.score(afternoon, in: before))
        XCTAssertGreaterThan(PreferenceLearner.score(afternoon, in: after), PreferenceLearner.score(morning, in: after))
        try await learner.forget(sourceID: source)
        let forgotten = try await learner.snapshot()
        XCTAssertEqual(forgotten.weights, before.weights)
        try await learner.reset()
        let reset = try await learner.snapshot(); XCTAssertTrue(reset.examples.isEmpty); XCTAssertEqual(reset.weights, [0,0,0,0,0])
    }
    func testPausedLearningIgnoresFeedback() async throws {
        let learner = PreferenceLearner(url: directory().appendingPathComponent("preferences.json"))
        try await learner.setLearning(false)
        try await learner.record(.init(id: UUID(), sourceID: UUID(), features: [1,0,0,0,0], feedback: .accepted, createdAt: Date()))
        let state = try await learner.snapshot(); XCTAssertTrue(state.examples.isEmpty)
    }
    func testRejectingDoesNotInventPreferenceReason() async throws {
        let learner = PreferenceLearner(url: directory().appendingPathComponent("preferences.json"))
        try await learner.record(.init(id: UUID(), sourceID: UUID(), features: [1,0,0,0,0], feedback: .rejected, createdAt: Date()))
        let state = try await learner.snapshot(); XCTAssertTrue(state.statements.isEmpty)
    }
    func testNativePayloadAndExpiryAreBoundToDigest() {
        let w = write(); var p = proposal(w); let original = p.digest
        p.expiresAt = p.expiresAt.addingTimeInterval(600); XCTAssertNotEqual(original, p.digest)
        p.routineWrite = .init(operationID: w.operationID, operation: w.operation, destination: w.destination, start: w.start.addingTimeInterval(60), end: w.end, timeZone: w.timeZone, calendarDigest: w.calendarDigest, targetID: nil, targetDigest: nil)
        XCTAssertNotEqual(original, p.digest)
    }
    func testPermissionRequiredAndRevocationPreventsClaim() async throws {
        let ledger = RoutineLedger(url: directory().appendingPathComponent("routines.json"))
        let w = write(), p = try await ledger.propose(proposal(w))
        try await ledger.setDestination(destination)
        do { _ = try await ledger.claimNative(id: p.id, digest: p.digest, reviewedDigest: nil, now: Date()); XCTFail("Missing permission") } catch {}
        let grant = StandingGrant(id: UUID(), destination: destination, operations: [.createBlock], earliestHour: 0, latestHour: 24, maximumMinutes: 240, expiresAt: Date().addingTimeInterval(86400))
        try await ledger.grant(grant); try await ledger.revokeGrant(id: grant.id)
        do { _ = try await ledger.claimNative(id: p.id, digest: p.digest, reviewedDigest: nil, now: Date()); XCTFail("Revoked permission") } catch {}
        _ = try await ledger.claimNative(id: p.id, digest: p.digest, reviewedDigest: p.digest, now: Date())
        do { _ = try await ledger.claimNative(id: p.id, digest: p.digest, reviewedDigest: p.digest, now: Date()); XCTFail("Duplicate claim") } catch {}
    }
    func testNativeRunnerVerifiesAndDoesNotDuplicate() async throws {
        let ledger = RoutineLedger(url: directory().appendingPathComponent("routines.json"))
        try await ledger.setDestination(destination)
        let p = try await ledger.propose(proposal(write())), native = NativeFixture()
        let runner = TaskRunner(ledger: ledger, native: native)
        let first = try await runner.run(id: p.id, reviewedDigest: p.digest)
        let second = try await runner.run(id: p.id)
        XCTAssertEqual(first, second); XCTAssertEqual(native.executions, 1)
    }
    func testUncertainWriteReconcilesWithoutReplay() async throws {
        let url = directory().appendingPathComponent("routines.json")
        let ledger = RoutineLedger(url: url)
        try await ledger.setDestination(destination)
        let p = try await ledger.propose(proposal(write())), native = NativeFixture()
        native.throwAfterWrite = true
        let runner = TaskRunner(ledger: ledger, native: native)
        do { _ = try await runner.run(id: p.id, reviewedDigest: p.digest); XCTFail("Should report uncertain") } catch {}
        let state = try await ledger.snapshot(); XCTAssertEqual(state.proposals.first?.status, .uncertain)
        let restarted = TaskRunner(ledger: RoutineLedger(url: url), native: native)
        _ = try await restarted.run(id: p.id, now: Date().addingTimeInterval(1200))
        XCTAssertEqual(native.executions, 1)
        let recovered = try await restarted.ledger.snapshot(); XCTAssertEqual(recovered.proposals.first?.status, .completed)
    }
    func testStaleCalendarAndCancellationNeverWrite() async throws {
        let ledger = RoutineLedger(url: directory().appendingPathComponent("routines.json"))
        try await ledger.setDestination(destination)
        let p = try await ledger.propose(proposal(write())), native = NativeFixture()
        native.stale = true; let runner = TaskRunner(ledger: ledger, native: native)
        do { _ = try await runner.run(id: p.id, reviewedDigest: p.digest); XCTFail("Stale source") } catch {}
        native.stale = false
        do { _ = try await runner.run(id: p.id, reviewedDigest: p.digest, current: { false }); XCTFail("Cancelled") } catch {}
        XCTAssertEqual(native.executions, 0)
    }
    func testBusyIntervalsAreHardConstraints() {
        let now = Date(), snapshot = RoutineDaySnapshot(date: Date(), busy: [.init(id: "meeting", start: Date(), end: Date().addingTimeInterval(3600), fingerprint: "a")])
        XCTAssertTrue(snapshot.conflicts(start: now.addingTimeInterval(30), end: now.addingTimeInterval(600)))
        XCTAssertFalse(snapshot.conflicts(start: now.addingTimeInterval(7200), end: now.addingTimeInterval(7500)))
    }
    func testExactMinutesAndExplicitLimitsCannotBeRankedAway() {
        XCTAssertTrue(DailyAssistant.permits(minute: 14*60+15, duration: 30, requested: 14*60+15, rule: .at))
        XCTAssertFalse(DailyAssistant.permits(minute: 14*60, duration: 30, requested: 14*60+15, rule: .at))
        XCTAssertFalse(DailyAssistant.permits(minute: 13*60, duration: 30, requested: 14*60, rule: .after))
        XCTAssertFalse(DailyAssistant.permits(minute: 13*60+45, duration: 30, requested: 14*60, rule: .before))
    }
    func testActivityPreferenceDoesNotBecomeUniversal() {
        var state = PreferenceState()
        state.statements = [.init(id: UUID(), sourceID: UUID(), text: "Exercise at nine", preferredHour: 9, updatedAt: Date(), activity: "exercise")]
        XCTAssertEqual(state.preference(for: "exercise")?.preferredHour, 9)
        XCTAssertNil(state.preference(for: "focus"))
    }
}

@MainActor private final class NativeFixture: RoutineNativeTools {
    var executions = 0; var throwAfterWrite = false; var stale = false
    var receipt: RoutineWriteReceipt?
    func destinations(reminders: Bool) throws -> [RoutineDestination] { [] }
    func day(_ date: Date) throws -> RoutineDaySnapshot { .init(date: date, busy: []) }
    func validate(_ write: RoutineWrite, owned: [RoutineWriteReceipt]) throws { if stale { throw RoutineError.stale } }
    func execute(_ write: RoutineWrite) throws -> RoutineWriteReceipt {
        executions += 1; let value = RoutineWriteReceipt(operationID: write.operationID, itemID: "created", fingerprint: "result", verifiedAt: Date()); receipt = value
        if throwAfterWrite { throw RoutineError.unavailable }; return value
    }
    func reconcile(_ write: RoutineWrite) async throws -> RoutineWriteReceipt? { receipt }
}

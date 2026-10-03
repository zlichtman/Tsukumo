import XCTest
@testable import KemoSabe

final class ContinuousContextTests: XCTestCase {
    let zone = TimeZone(identifier: "America/Chicago")!
    let now = Date(timeIntervalSince1970: 1_789_087_200)
    func testObservationsAreBoundedAndIdempotent() {
        var context = ContinuousContext(); let id=UUID()
        context.observe(id:id,kind:.conversation,text:String(repeating:"x",count:900),at:now)
        context.observe(id:id,kind:.conversation,text:"retry",at:now)
        XCTAssertEqual(context.observations.count,1); XCTAssertEqual(context.observations[0].text.count,300)
        for i in 0..<300 { context.observe(kind:.conversation,text:"event",at:now+Double(i)) }
        XCTAssertEqual(context.observations.count,128)
        context.compact(now:now+31*86400); XCTAssertTrue(context.observations.isEmpty)
    }
    func testTimingNeedsSeparateDaysAndDoesNotClaimSleep() {
        var context = ContinuousContext()
        for i in 0..<10 { context.observe(kind:.reportedBedtime,text:"goodnight",at:now-Double(i),timeZone:zone) }
        XCTAssertTrue(context.workingContext(now:now,timeZone:zone).isEmpty)
        for i in 1...3 { context.observe(kind:.reportedBedtime,text:"goodnight",at:now-Double(i)*86400,timeZone:zone) }
        let prompt = context.workingContext(now:now,timeZone:zone).joined()
        XCTAssertTrue(prompt.contains("Tentative pattern")); XCTAssertTrue(prompt.contains("not measured sleep"))
        XCTAssertTrue(context.workingContext(now:now,timeZone:TimeZone(secondsFromGMT:0)!).isEmpty)
    }
    func testPausedContextIsNeitherRecordedNorSupplied() {
        var context = ContinuousContext()
        context.observe(kind:.conversation,text:"private statement",at:now)
        context.learning=false
        context.observe(kind:.conversation,text:"must not be retained",at:now)
        XCTAssertEqual(context.observations.count,1)
        XCTAssertTrue(context.workingContext(now:now,timeZone:zone).isEmpty)
    }
    func testPausedSleepReportsDoNotLeakThroughLegacyFields() async throws {
        let ledger=RoutineLedger(url:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("routine.json"))
        try await ledger.recordBedtime(now-3600)
        try await ledger.setLearning(false)
        try await ledger.recordWake(now)
        let state=try await ledger.snapshot()
        XCTAssertNil(state.wokeAt)
        let request=PlanningRequest(message:"Morning",history:[],memories:[],standupFormat:"",now:now,routine:state)
        XCTAssertTrue(request.routineFacts.isEmpty)
    }
    func testCurrentRequestIsNotRepeatedAsEarlierContext() {
        let id=UUID(); var context=ContinuousContext()
        context.observe(id:id,kind:.conversation,text:"This is the current request",at:now)
        XCTAssertTrue(context.workingContext(now:now,timeZone:zone,excluding:id).isEmpty)
    }
    func testContinuitySurvivesRestartAndForgetPreservesApprovalLedger() async throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("routine.json")
        let ledger=RoutineLedger(url:url)
        try await ledger.observeConversation(id:UUID(),text:"Standup moved to Thursday",now:now)
        try await ledger.propose(.init(key:"draft",kind:.draft,title:"Review",body:"Draft",createdAt:now,expiresAt:now+1000))
        let restored=try await RoutineLedger(url:url).snapshot()
        XCTAssertEqual(restored.context?.observations.first?.text,"Standup moved to Thursday")
        try await ledger.clearContext()
        let cleared=try await ledger.snapshot()
        XCTAssertEqual(cleared.context?.observations.count,0); XCTAssertEqual(cleared.proposals.count,1)
        XCTAssertEqual(cleared.proposals[0].status,.needsReview)
    }
    func testPlanningCarriesBoundedContextWithoutEnablingActions() {
        var routine=RoutineDocument(); var context=ContinuousContext()
        for i in 0..<20 { context.observe(kind:.conversation,text:"Statement \(i)",at:now-Double(20-i)) }
        routine.context=context
        let request=PlanningRequest(message:"What did we discuss about my routine?",history:[],memories:[],standupFormat:"",now:now,routine:routine)
        XCTAssertEqual(request.routineFacts.count,4)
        XCTAssertTrue(request.prompt.contains("Statement 19")); XCTAssertFalse(request.prompt.contains("Statement 0"))
        XCTAssertTrue(routine.proposals.isEmpty)
    }
}

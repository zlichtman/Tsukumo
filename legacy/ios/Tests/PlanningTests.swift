import XCTest
@testable import KemoSabe

final class PlanningTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func request(notes: [MemoryNote] = []) -> PlanningRequest {
        .init(message: "Draft, remember, and set an alarm for something useful about " + notes.map(\.text).joined(separator: " "), history: [], memories: notes, standupFormat: "Short", now: now)
    }
    func draft(_ text: String = "A draft") -> CompanionPlan {
        .init(answer: "I already sent it!", actions: [.init(kind: .draft, title: "Draft", content: text)])
    }
    func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    func testContextIsBoundedAndExcludesDisabledNotes() {
        let notes = (0..<30).map { MemoryNote(text: "topic " + String(repeating: "x", count: 1000) + "\($0)") } + [MemoryNote(text: "DO NOT USE", useInChat: false)]
        let request = PlanningRequest(message: "topic " + String(repeating: "a", count: 3000), history: (0..<15).map { _ in .init(role: "You", text: String(repeating: "h", count: 1000)) }, memories: notes, standupFormat: String(repeating: "s", count: 1000), now: now)
        XCTAssertEqual(request.sources.count, 8); XCTAssertEqual(request.history.count, 4)
        XCTAssertEqual(request.message.count, 2000); XCTAssertLessThan(request.prompt.count, 9000)
        XCTAssertFalse(request.prompt.contains("DO NOT USE"))
    }
    func testInvalidActionRejectsEntirePlan() {
        var plan = draft(); plan.actions.append(.init(kind: .alarm, title: "Wake", content: "At eight", alarmTime: "tomorrow morning"))
        XCTAssertThrowsError(try PlanValidator.proposals(plan, request: request(), model: "Test", currentNotes: [], now: now))
        plan.actions[1].alarmTime = ISO8601DateFormatter().string(from: now - 60)
        XCTAssertThrowsError(try PlanValidator.proposals(plan, request: request(), model: "Test", currentNotes: [], now: now))
        plan.actions[1].alarmTime = ISO8601DateFormatter().string(from: now + 8*86400)
        XCTAssertThrowsError(try PlanValidator.proposals(plan, request: request(), model: "Test", currentNotes: [], now: now))
    }
    func testAlarmReviewDescribesExecutableTimeNotModelClaim() throws {
        let plan = CompanionPlan(answer: "Scheduled!", actions: [.init(kind: .alarm, title: "Wake", content: "An unrelated time", alarmTime: ISO8601DateFormatter().string(from: now+3600))])
        let proposals = try PlanValidator.proposals(plan, request: request(), model: "Test", currentNotes: [], now: now)
        XCTAssertEqual(proposals.first?.scheduledAt, now+3600)
        XCTAssertFalse(proposals[0].body.contains("unrelated"))
        XCTAssertFalse(PlanValidator.spokenReply(plan, proposals: proposals).contains("Scheduled!"))
        XCTAssertEqual(proposals[0].status, .needsReview)
    }
    func testAlarmRequiresOffsetAndReviewKeepsTimeZone() throws {
        let request = PlanningRequest(message: "Wake me", history: [], memories: [], standupFormat: "", now: now, timeZone: TimeZone(identifier: "America/Chicago")!)
        var plan = CompanionPlan(answer: "", actions: [.init(kind: .alarm, title: "Wake", content: "Alarm", alarmTime: "2027-01-15T09:00:00")])
        XCTAssertThrowsError(try PlanValidator.proposals(plan, request: request, model: "Test", currentNotes: [], now: now))
        plan.actions[0].alarmTime = ISO8601DateFormatter().string(from: now+3600)
        let p = try PlanValidator.proposals(plan, request: request, model: "Test", currentNotes: [], now: now)[0]
        XCTAssertTrue(p.body.contains("America/Chicago")); XCTAssertEqual(p.scheduledAt, now+3600)
    }
    func testChangedOrExcludedContextInvalidatesPlan() {
        let note = MemoryNote(text: "Old rule"), request = request(notes: [MemoryNote(text: "Other")])
        XCTAssertThrowsError(try PlanValidator.proposals(draft(), request: request, model: "Test", currentNotes: [note], now: now))
        let original = self.request(notes: [note]); var changed = note; changed.useInChat = false
        XCTAssertThrowsError(try PlanValidator.proposals(draft(), request: original, model: "Test", currentNotes: [changed], now: now))
        changed = note; changed.text = "New rule"
        XCTAssertThrowsError(try PlanValidator.proposals(draft(), request: original, model: "Test", currentNotes: [changed], now: now))
    }
    func testDeadlineAndSizeLimitsFailClosed() {
        XCTAssertThrowsError(try PlanValidator.proposals(draft(), request: request(), model: "Test", currentNotes: [], now: now+61))
        var plan = draft(); plan.actions = Array(repeating: plan.actions[0], count: 4)
        XCTAssertThrowsError(try PlanValidator.proposals(plan, request: request(), model: "Test", currentNotes: [], now: now))
        XCTAssertThrowsError(try PlanValidator.proposals(draft(String(repeating: "x", count: 4001)), request: request(), model: "Test", currentNotes: [], now: now))
    }
    func testMemoryScopeAndLengthAreValidated() {
        let plan = CompanionPlan(answer: "", actions: [.init(kind: .remember, title: "Memory", content: "A fact", memoryScope: "Admin")])
        XCTAssertThrowsError(try PlanValidator.proposals(plan, request: request(), model: "Test", currentNotes: [], now: now))
        let long = CompanionPlan(answer: "", actions: [.init(kind: .remember, title: "Memory", content: String(repeating: "x", count: 1001))])
        XCTAssertThrowsError(try PlanValidator.proposals(long, request: request(), model: "Test", currentNotes: [], now: now))
    }
    func testPlanCommitIsAtomicAndIdempotentAcrossRestart() async throws {
        let url = folder().appendingPathComponent("ledger.json"), request = request()
        let ledger = RoutineLedger(url: url)
        let proposals = try PlanValidator.proposals(draft(), request: request, model: "Test", currentNotes: [], now: now)
        let reconstructed = try PlanValidator.proposals(draft(), request: request, model: "Test", currentNotes: [], now: now+1)
        XCTAssertEqual(proposals.map(\.id), reconstructed.map(\.id))
        XCTAssertEqual(proposals.map(\.digest), reconstructed.map(\.digest))
        try await ledger.enqueuePlan(proposals); try await ledger.enqueuePlan(reconstructed)
        let restored = try await RoutineLedger(url: url).snapshot()
        XCTAssertEqual(restored.proposals.count, 1); XCTAssertEqual(restored.proposals.first?.digest, proposals[0].digest)
        var altered = proposals[0]; altered.body = "Changed after review"
        do { try await ledger.enqueuePlan([altered]); XCTFail("Replaced content") } catch {}
        let otherURL = folder().appendingPathComponent("ledger.json"), other = RoutineLedger(url: otherURL)
        var second = RoutineProposal(key: "invalid-second", kind: .draft, title: "Bad draft", body: String(repeating: "x", count: 5000), createdAt: now, expiresAt: now+100)
        second.origin = proposals[0].origin
        do { try await other.enqueuePlan(proposals + [second]); XCTFail("Partially committed invalid batch") } catch {}
        let empty = try await other.snapshot(); XCTAssertTrue(empty.proposals.isEmpty)
    }
    func testOriginAndScopeAreBoundToApproval() throws {
        var proposal = try PlanValidator.proposals(draft(), request: request(), model: "Test", currentNotes: [], now: now)[0]
        let digest = proposal.digest
        proposal.memoryScope = "Company"; XCTAssertNotEqual(proposal.digest, digest)
        proposal.memoryScope = nil
        proposal.origin = request().origin(model: "Different model"); XCTAssertNotEqual(proposal.digest, digest)
    }
    func testBackpressureDoesNotDropExistingWork() async throws {
        let ledger = RoutineLedger(url: folder().appendingPathComponent("ledger.json"))
        for i in 0..<64 {
            _ = try await ledger.propose(.init(key: "\(i)", kind: .morningBrief, title: "Brief", body: "Question", createdAt: now, expiresAt: now+100))
        }
        let p = try PlanValidator.proposals(draft(), request: request(), model: "Test", currentNotes: [], now: now)
        do { try await ledger.enqueuePlan(p); XCTFail("Unbounded queue") } catch {}
        let state = try await ledger.snapshot(); XCTAssertEqual(state.proposals.count, 64)
    }
    func testFinishedHistoryAndOverdueProposalsMakeRoomForNewPlans() async throws {
        let ledger = RoutineLedger(url: folder().appendingPathComponent("ledger.json"))
        for i in 0..<63 {
            let p = try await ledger.propose(.init(key: "done-\(i)", kind: .morningBrief, title: "Brief", body: "Question", createdAt: now - 100, expiresAt: now + 1000))
            try await ledger.reject(id: p.id)
        }
        let overdue = try await ledger.propose(.init(key: "overdue", kind: .morningBrief, title: "Brief", body: "Question", createdAt: now - 100, expiresAt: now - 1))
        let plan = try PlanValidator.proposals(draft(), request: request(), model: "Test", currentNotes: [], now: now)
        try await ledger.enqueuePlan(plan)
        let state = try await ledger.snapshot()
        XCTAssertEqual(state.proposals.count, 64)
        XCTAssertEqual(state.proposals.first { $0.id == overdue.id }?.status, .expired)
        XCTAssertTrue(state.proposals.contains { $0.key == plan[0].key && $0.status == .needsReview })
    }
    func testUncertainProposalCanBeDismissed() async throws {
        let ledger = RoutineLedger(url: folder().appendingPathComponent("ledger.json"))
        let p = try await ledger.propose(.init(key: "u", kind: .draft, title: "Draft", body: "Body", createdAt: now, expiresAt: now + 100))
        try await ledger.approve(id: p.id, digest: p.digest, now: now)
        _ = try await ledger.claim(id: p.id, now: now)
        try await ledger.finish(id: p.id, receipt: nil, now: now)
        try await ledger.dismissUncertain(id: p.id, now: now)
        let state = try await ledger.snapshot()
        XCTAssertEqual(state.proposals.first?.status, .rejected)
        do { try await ledger.dismissUncertain(id: p.id, now: now); XCTFail("Dismissed twice") } catch {}
    }
    @MainActor func testPlannerFeedsRealReviewFlowWithoutAutoSavingMemory() async throws {
        let provider = TestPlanner(plan: .init(answer: "Saved it", actions: [.init(kind: .remember, title: "Writing style", content: "I prefer short paragraphs.")]))
        let store = AppStore(repository: .init(url: folder().appendingPathComponent("state.json")), provider: provider)
        let done = expectation(description: "plan")
        var reply: String?
        store.send("Remember my writing style", completion: { reply = $0; done.fulfill() })
        await fulfillment(of: [done], timeout: 2)
        let snapshot = try await store.proposalLedger.snapshot()
        let p = try XCTUnwrap(snapshot.proposals.first)
        XCTAssertTrue(store.state.memories.isEmpty); XCTAssertEqual(p.status, .needsReview)
        XCTAssertTrue(reply?.contains("once you approve it in Day") == true)
        XCTAssertThrowsError(try store.keepApprovedMemory(p))
        let routines = RoutineStore(ledger: store.proposalLedger)
        await routines.review(p, store: store)
        XCTAssertEqual(store.state.memories.count, 1); XCTAssertEqual(store.state.memories[0].id, p.id)
        XCTAssertEqual(routines.state.proposals[0].receipt, "Saved to memory")
        await routines.review(p, store: store)
        XCTAssertEqual(store.state.memories.count, 1)
    }
    @MainActor func testAnInvalidDraftKeepsTheModelsQuestionInsteadOfFailing() async throws {
        // "Help me draft a reply. Ask me who it's for…": the model asks first and leaves the draft empty.
        let provider = TestPlanner(plan: .init(answer: "Sure. Who is it for, and what happened?", actions: [.init(kind: .draft, title: "Reply", content: "")]))
        let store = AppStore(repository: .init(url: folder().appendingPathComponent("state.json")), provider: provider)
        let done = expectation(description: "plan")
        var reply: String?
        store.send("Help me draft a reply. Ask me who it is for, what happened, and what I want to say.", completion: { reply = $0; done.fulfill() })
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(reply, "Sure. Who is it for, and what happened?")
        XCTAssertNil(store.error)
        let snapshot = try await store.proposalLedger.snapshot()
        XCTAssertTrue(snapshot.proposals.isEmpty, "Nothing invalid is saved")
    }
    @MainActor func testExcludedSourceBlocksApproval() async throws {
        let store = AppStore(repository: .init(url: folder().appendingPathComponent("state.json")), provider: TestPlanner(plan: draft()))
        let note = MemoryNote(text: "Private source"); store.saveMemory(note)
        let request = PlanningRequest(message: "Draft from Private source", history: [], memories: [note], standupFormat: "")
        let p = try PlanValidator.proposals(draft(), request: request, model: "Test", currentNotes: [note], now: Date())[0]
        try await store.proposalLedger.enqueuePlan([p])
        var excluded = note; excluded.useInChat = false; store.saveMemory(excluded)
        let routines = RoutineStore(ledger: store.proposalLedger)
        await routines.review(p, store: store)
        XCTAssertNotNil(routines.error)
        let state = try await store.proposalLedger.snapshot(); XCTAssertEqual(state.proposals[0].status, .needsReview)
    }
    @MainActor func testCancellationNeverCreatesLateProposals() async throws {
        let store = AppStore(repository: .init(url: folder().appendingPathComponent("state.json")), provider: TestPlanner(plan: draft(), delay: true))
        store.send("Draft a note"); try await Task.sleep(for: .milliseconds(20)); store.clearConversation()
        try await Task.sleep(for: .milliseconds(160))
        let state = try await store.proposalLedger.snapshot()
        XCTAssertTrue(state.proposals.isEmpty); XCTAssertTrue(store.state.messages.isEmpty)
    }
    @MainActor func testRemoteProviderCannotReceivePrivateSnapshot() async throws {
        let provider = TestPlanner(plan: draft(), local: false)
        let store = AppStore(repository: .init(url: folder().appendingPathComponent("state.json")), provider: provider)
        store.saveMemory(.init(text: "Private"))
        let done = expectation(description: "blocked")
        store.send("Help", completion: { _ in done.fulfill() })
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(provider.calls, 0); XCTAssertNotNil(store.error)
    }
    func testGateRetainsSlotUntilCancelledProviderReallyStops() async throws {
        let gate = ModelWorkGate()
        let first = Task {
            try await gate.run {
                await Task.detached { try? await Task.sleep(for: .milliseconds(150)); return 1 }.value
            }
        }
        try await Task.sleep(for: .milliseconds(20)); first.cancel()
        do { _ = try await gate.run { 2 }; XCTFail("Concurrent model work") } catch {}
        _ = try await first.value
        let next = try await gate.run { 3 }; XCTAssertEqual(next, 3)
    }
    @MainActor func testLegacyProviderCannotBypassLocalOnlyGate() async throws {
        let provider = RemoteLegacyProvider()
        let store = AppStore(repository: .init(url: folder().appendingPathComponent("state.json")), provider: provider)
        store.saveMemory(.init(text: "Private work context"))
        store.send("Draft something"); store.draftStandup()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(provider.calls, 0); XCTAssertNotNil(store.error)
    }
    @MainActor func testSpokenConversationStreamsWithoutCallingPlannerAndUsesBoundedLocalContext() async throws {
        let provider = FastLanePlanner()
        let store = AppStore(repository: .init(url: folder().appendingPathComponent("state.json")), provider: provider)
        store.state.messages = (0..<9).map { .init(role: $0.isMultiple(of: 2) ? "You" : "KemoSabe", text: String(repeating: "h", count: 900)) }
        store.state.memories = (0..<15).map { _ in .init(text: "topic " + String(repeating: "m", count: 900), scope: String(repeating: "s", count: 80)) }
        store.state.standupFormat = String(repeating: "f", count: 900)
        store.prepareVoice()
        let done = expectation(description: "spoken answer")
        var events: [String] = []
        store.send("Tell me about this topic", mode: .spokenConversation, onPartial: { _ in events.append("partial") }) { answer in
            XCTAssertEqual(answer, "A natural spoken answer.")
            events.append("completion"); done.fulfill()
        }
        await fulfillment(of: [done], timeout: 2)

        XCTAssertEqual(provider.prewarmModes, [.spokenConversation])
        XCTAssertEqual(provider.selectionCalls, 0)
        XCTAssertEqual(provider.planCalls, 0)
        XCTAssertEqual(provider.streamCalls, 1)
        XCTAssertEqual(events, ["partial", "completion"])
        XCTAssertEqual(provider.receivedHistory.count, 6)
        XCTAssertTrue(provider.receivedHistory.allSatisfy { $0.text.count <= 400 })
        XCTAssertEqual(provider.receivedMemories.count, 12)
        XCTAssertTrue(provider.receivedMemories.allSatisfy { $0.text.count <= 240 && $0.scope.count <= 40 })
        XCTAssertEqual(provider.receivedFormat.count, 500)
        let routine = try await store.proposalLedger.snapshot()
        XCTAssertEqual(routine.context?.observations.last?.text, "Tell me about this topic")
        XCTAssertTrue(routine.proposals.isEmpty)
    }
    @MainActor func testDefaultSendStillUsesPlannerInsteadOfConversationStream() async throws {
        let provider = FastLanePlanner()
        let store = AppStore(repository: .init(url: folder().appendingPathComponent("state.json")), provider: provider)
        let done = expectation(description: "planned answer")
        store.send("Help me plan", completion: { answer in
            XCTAssertEqual(answer, "A planned answer."); done.fulfill()
        })
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(provider.planCalls, 1)
        XCTAssertEqual(provider.streamCalls, 0)
    }
    @MainActor func testCancelledSpokenConversationDropsLateSnapshotsAndCompletion() async throws {
        let provider = FastLanePlanner(delayedStream: true)
        let store = AppStore(repository: .init(url: folder().appendingPathComponent("state.json")), provider: provider)
        var snapshots: [String] = []; var completed = false
        let first = expectation(description: "first snapshot before cancellation")
        store.send("Keep talking", mode: .spokenConversation, onPartial: {
            snapshots.append($0)
            if snapshots.count == 1 { first.fulfill() }
        }, completion: { _ in completed = true })
        await fulfillment(of: [first], timeout: 2)
        XCTAssertEqual(snapshots, ["First words. "])
        store.clearConversation()
        try await Task.sleep(for: .milliseconds(180))

        XCTAssertEqual(snapshots, ["First words. "])
        XCTAssertFalse(completed)
        XCTAssertTrue(store.state.messages.isEmpty)
    }
    @MainActor func testStreamingPlannerSkipsSelectorAndStreamsOrdinaryAnswer() async throws {
        let provider = FastLaneStreamingPlanner(plan: .init(answer: "A useful ordinary answer."))
        let store = AppStore(repository: .init(url: folder().appendingPathComponent("state.json")), provider: provider)
        let done = expectation(description: "streamed guided answer")
        var snapshots: [String] = []
        store.send("Talk this through", mode: .spokenConversation, onPartial: { snapshots.append($0) }) { answer in
            XCTAssertEqual(answer, "A useful ordinary answer."); done.fulfill()
        }
        await fulfillment(of: [done], timeout: 2)

        XCTAssertEqual(provider.streamPlanCalls, 1)
        XCTAssertEqual(provider.planCalls, 0)
        XCTAssertEqual(provider.selectionCalls, 0)
        XCTAssertEqual(provider.directStreamCalls, 0)
        XCTAssertEqual(snapshots, ["A useful", "A useful ordinary answer."])
        let routine = try await store.proposalLedger.snapshot()
        XCTAssertTrue(routine.proposals.isEmpty)
    }
    @MainActor func testStreamingPlannerWithholdsActionAnswerUntilValidationAndPreservesSources() async throws {
        let note = MemoryNote(text: "Please use short Orion updates.", scope: "Company")
        let plan = CompanionPlan(answer: "I saved that automatically.", actions: [
            .init(kind: .remember, title: "Orion update style", content: "Use short Orion updates.", memoryScope: "Company")
        ])
        let provider = FastLaneStreamingPlanner(plan: plan)
        let store = AppStore(repository: .init(url: folder().appendingPathComponent("state.json")), provider: provider)
        store.saveMemory(note)
        let done = expectation(description: "validated proposal notice")
        var snapshots: [String] = []; var reply: String?
        store.send("Remember my Orion update preference", mode: .spokenConversation,
                   onPartial: { snapshots.append($0) }) { answer in reply = answer; done.fulfill() }
        await fulfillment(of: [done], timeout: 2)

        XCTAssertTrue(snapshots.isEmpty, "Unvalidated action prose must never be streamed")
        XCTAssertTrue(reply?.contains("once you approve it in Day") == true)
        XCTAssertFalse(reply?.contains("automatically") == true)
        XCTAssertEqual(provider.selectionCalls, 0)
        let routine = try await store.proposalLedger.snapshot()
        let proposal = try XCTUnwrap(routine.proposals.first)
        XCTAssertEqual(proposal.status, .needsReview)
        XCTAssertEqual(proposal.origin?.sources.map(\.id), [note.id])
        XCTAssertTrue(store.state.memories.allSatisfy { $0.id != proposal.id })
    }
    @MainActor func testCancelledStreamingPlannerDropsLateSnapshotAndProposal() async throws {
        let plan = CompanionPlan(answer: "Late answer", actions: [
            .init(kind: .draft, title: "Late draft", content: "Must not be queued")
        ])
        let provider = FastLaneStreamingPlanner(plan: plan, delayed: true)
        let store = AppStore(repository: .init(url: folder().appendingPathComponent("state.json")), provider: provider)
        var snapshots: [String] = []; var completed = false
        store.send("Draft this", mode: .spokenConversation,
                   onPartial: { snapshots.append($0) }, completion: { _ in completed = true })
        try await Task.sleep(for: .milliseconds(30)); store.clearConversation()
        try await Task.sleep(for: .milliseconds(180))

        XCTAssertTrue(snapshots.isEmpty)
        XCTAssertFalse(completed)
        XCTAssertTrue(store.state.messages.isEmpty)
        let routine = try await store.proposalLedger.snapshot()
        XCTAssertTrue(routine.proposals.isEmpty)
    }
    func testReportedSleepContextDoesNotInventMeasurement() {
        var routine = RoutineDocument(); routine.bedtime = now - 8*3600; routine.wokeAt = now
        let req = PlanningRequest(message: "Morning", history: [], memories: [], standupFormat: "", now: now, routine: routine)
        XCTAssertTrue(req.prompt.contains("not measured sleep")); XCTAssertEqual(req.routineFacts.count, 2)
    }
}

final class RemoteLegacyProvider: AssistantProvider {
    var calls = 0
    var runsLocally: Bool { false }
    var isAvailable: Bool { true }
    var availabilityDescription: String { "Test remote provider" }
    func reply(to message: String, history: [ChatMessage], memories: [MemoryNote], standupFormat: String) async throws -> String { calls += 1; return "Never call" }
}

final class TestPlanner: AssistantProvider, CompanionPlanner {
    let output: CompanionPlan
    let delay: Bool
    let local: Bool
    var calls = 0
    init(plan: CompanionPlan, delay: Bool = false, local: Bool = true) { output = plan; self.delay = delay; self.local = local }
    var isAvailable: Bool { true }
    var availabilityDescription: String { "Test model" }
    var plannerID: String { "Test local model" }
    var runsLocally: Bool { local }
    func plan(_ request: PlanningRequest) async throws -> CompanionPlan {
        calls += 1
        if delay { await Task.detached { try? await Task.sleep(for: .milliseconds(120)) }.value }
        return output
    }
    func reply(to message: String, history: [ChatMessage], memories: [MemoryNote], standupFormat: String) async throws -> String { "Legacy reply" }
}

final class FastLanePlanner: AssistantProvider, ContextSelectingPlanner {
    var runsLocally = true
    var isAvailable = true
    var availabilityDescription = "Test local model"
    var plannerID = "Test local planner"
    let delayedStream: Bool
    var planCalls = 0
    var selectionCalls = 0
    var streamCalls = 0
    var prewarmModes: [AssistantRequestMode] = []
    var receivedHistory: [ChatMessage] = []
    var receivedMemories: [MemoryNote] = []
    var receivedFormat = ""
    init(delayedStream: Bool = false) { self.delayedStream = delayedStream }
    func prewarm(for mode: AssistantRequestMode) { prewarmModes.append(mode) }
    func selectContext(_ turn: ContextTurn) async throws -> ContextSelection {
        selectionCalls += 1; return .init(reads: [])
    }
    func plan(_ request: PlanningRequest) async throws -> CompanionPlan {
        planCalls += 1; return .init(answer: "A planned answer.")
    }
    func reply(to message: String, history: [ChatMessage], memories: [MemoryNote], standupFormat: String) async throws -> String {
        "A natural spoken answer."
    }
    func streamReply(to message: String, history: [ChatMessage], memories: [MemoryNote], standupFormat: String,
                     onSnapshot: @escaping @MainActor (String) -> Void) async throws -> String {
        streamCalls += 1; receivedHistory = history; receivedMemories = memories; receivedFormat = standupFormat
        if delayedStream {
            await onSnapshot("First words. ")
            await Task.detached { try? await Task.sleep(for: .milliseconds(120)) }.value
            await onSnapshot("First words. Late words.")
            return "First words. Late words."
        }
        await onSnapshot("A natural spoken answer.")
        return "A natural spoken answer."
    }
}

final class FastLaneStreamingPlanner: AssistantProvider, StreamingCompanionPlanner, ContextSelectingPlanner {
    var runsLocally = true
    var isAvailable = true
    var availabilityDescription = "Test streaming planner"
    var plannerID = "Test streaming planner"
    let output: CompanionPlan
    let delayed: Bool
    var planCalls = 0
    var selectionCalls = 0
    var streamPlanCalls = 0
    var directStreamCalls = 0
    var requests: [PlanningRequest] = []
    init(plan: CompanionPlan, delayed: Bool = false) { output = plan; self.delayed = delayed }
    func selectContext(_ turn: ContextTurn) async throws -> ContextSelection {
        selectionCalls += 1; return .init(reads: [])
    }
    func plan(_ request: PlanningRequest) async throws -> CompanionPlan {
        planCalls += 1; return output
    }
    func streamPlan(_ request: PlanningRequest,
                    onAnswerSnapshot: @escaping @MainActor (String) -> Void) async throws -> CompanionPlan {
        streamPlanCalls += 1; requests.append(request)
        if output.actions.isEmpty { await onAnswerSnapshot("A useful") }
        if delayed { await Task.detached { try? await Task.sleep(for: .milliseconds(120)) }.value }
        if output.actions.isEmpty { await onAnswerSnapshot(output.answer) }
        return output
    }
    func reply(to message: String, history: [ChatMessage], memories: [MemoryNote], standupFormat: String) async throws -> String {
        output.answer
    }
    func streamReply(to message: String, history: [ChatMessage], memories: [MemoryNote], standupFormat: String,
                     onSnapshot: @escaping @MainActor (String) -> Void) async throws -> String {
        directStreamCalls += 1; return output.answer
    }
}

/// Kemo answers as a chatbot; it proposes a memory, alarm, or draft only when asked.
final class ExplicitRequestTests: XCTestCase {
    func testOnlyAskedForActionsAreProposed() {
        XCTAssertFalse(ExplicitRequest.allows(.remember, in: "What's a good pasta recipe?"))
        XCTAssertFalse(ExplicitRequest.allows(.remember, in: "I love hiking with my sister"))
        XCTAssertTrue(ExplicitRequest.allows(.remember, in: "Remember that I love hiking"))
        XCTAssertTrue(ExplicitRequest.allows(.remember, in: "Don't forget my sister's birthday is May 3"))
        XCTAssertTrue(ExplicitRequest.allows(.alarm, in: "Wake me at 7"))
        XCTAssertFalse(ExplicitRequest.allows(.alarm, in: "How did you sleep?"))
        XCTAssertTrue(ExplicitRequest.allows(.draft, in: "Draft a reply to Sam"))
        XCTAssertFalse(ExplicitRequest.allows(.draft, in: "Tell me a joke"))
    }
    func testAnUnaskedMemoryIsDroppedAndTheAnswerKept() throws {
        let now = Date()
        let request = PlanningRequest(message: "I had a great run today", history: [], memories: [], standupFormat: "", now: now)
        let plan = CompanionPlan(answer: "Nice work! How far did you go?", actions: [
            .init(kind: .remember, title: "Running", content: "Enjoys running")])
        let proposals = try PlanValidator.proposals(plan, request: request, model: "test", currentNotes: [], now: now)
        XCTAssertTrue(proposals.isEmpty)
        XCTAssertEqual(PlanValidator.spokenReply(plan, proposals: proposals), "Nice work! How far did you go?")
    }
}


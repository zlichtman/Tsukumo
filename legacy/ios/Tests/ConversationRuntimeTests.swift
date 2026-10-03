import XCTest
@testable import KemoSabe

@MainActor final class ConversationRuntimeTests: XCTestCase {
    func testEverydayPromptDoesNotContainAmbientStandupOrNotes() {
        let request = PlanningRequest(message: "Count to ten", history: [], memories: [.init(text: "Secret project standup")],
            standupFormat: "Yesterday / Today / Blockers")
        XCTAssertEqual(ConversationPrompt.make(request), "Count to ten")
        XCTAssertTrue(request.sources.isEmpty)
        XCTAssertTrue(request.routineFacts.isEmpty)
        XCTAssertTrue(request.standupFormat.isEmpty)
    }
    func testRecallCanReturnZeroAndExcludesDisabledNotes() {
        let notes = [MemoryNote(text: "Orion work project"), .init(text: "Count to ten", useInChat: false)]
        XCTAssertTrue(MemoryRecall.relevant(notes, to: "Count to ten").isEmpty)
        XCTAssertTrue(MemoryRecall.relevant(notes, to: "the and please").isEmpty)
        XCTAssertEqual(MemoryRecall.relevant(notes, to: "Orion update").map(\.id), [notes[0].id])
    }
    func testHistoryIsOnlyAddedForSelectedFollowupAndActionsReceiveClock() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let request = PlanningRequest(message: "Count to ten", history: [.init(role: "You", text: "Unrelated old standup")],
            memories: [], standupFormat: "Yesterday / Today", now: now, timeZone: TimeZone(identifier: "America/Chicago")!)
        XCTAssertEqual(ConversationPrompt.make(request), "Count to ten")
        XCTAssertTrue(ConversationPrompt.make(request, includeHistory: true).contains("Unrelated old standup"))
        let clock = ConversationPrompt.make(request, includeClock: true)
        XCTAssertTrue(clock.contains("America\\/Chicago") || clock.contains("America/Chicago"))
        XCTAssertTrue(clock.contains(ISO8601DateFormatter().string(from: now)))
        XCTAssertTrue(clock.contains("utcOffsetSeconds"))
        XCTAssertFalse(clock.contains("Unrelated old standup"))
    }
    func testAggregateToolResultBudgetIsBounded() async throws {
        let tools = registry()
        try await tools.configureResultBudget(100) { $0.utf8.count }
        _ = try await tools.transform(String(repeating: "a", count: 60), operation: .repeatExactly)
        do {
            _ = try await tools.transform(String(repeating: "b", count: 60), operation: .repeatExactly)
            XCTFail("Aggregate output exceeded context reserve")
        } catch ToolFailure.budget {} catch { XCTFail("\(error)") }
    }
    func testAuditStorageFailureDoesNotDiscardSuccessfulAnswer() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Invalid diagnostic JSON, not the canonical state or approval ledger.
        try Data("unreadable diagnostics".utf8).write(to: folder.appendingPathComponent("context-runs.json"))
        let store = AppStore(repository: .init(url: folder.appendingPathComponent("state.json")), provider: ConversationProbe())
        let finished = expectation(description: "answer despite audit failure")
        store.send("Count from three to seven", completion: { answer in
            XCTAssertEqual(answer, "3, 4, 5, 6, 7."); finished.fulfill()
        })
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertNil(store.error)
    }
    func testMemoryChangesStartFreshContextWithoutDeletingVisibleHistory() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = ConversationProbe()
        let store = AppStore(repository: .init(url: folder.appendingPathComponent("state.json")), provider: model)
        store.state.messages = [.init(role: "KemoSabe", text: "Old answer derived from private context")]
        store.saveMemory(.init(text: "Changed context"))
        let finished = expectation(description: "fresh context")
        store.send("Count from three to seven", completion: { _ in finished.fulfill() })
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertTrue(model.receivedHistory.isEmpty)
        XCTAssertTrue(store.state.messages.contains { $0.text == "Old answer derived from private context" })
        XCTAssertEqual(store.state.messages.last?.contextRevision, store.state.contextRevision)
    }
    func testExactOperationsHaveBoundsAndNoEval() throws {
        XCTAssertEqual(try ExactOperations.sequence(start: 3, end: 7, step: 1), "3, 4, 5, 6, 7.")
        XCTAssertEqual(try ExactOperations.sequence(start: 5, end: 1, step: -1), "5, 4, 3, 2, 1.")
        XCTAssertEqual(try ExactOperations.sequence(start: 4, end: 4, step: 1), "4.")
        for input in [(0, 200, 1), (0, 10, 0), (0, 10, -1), (Int.min, Int.max, 1)] {
            XCTAssertThrowsError(try ExactOperations.sequence(start: input.0, end: input.1, step: input.2))
        }
        XCTAssertEqual(try ExactOperations.calculate("(17+3)*4"), "80")
        XCTAssertEqual(try ExactOperations.calculate("-2 + 6/4"), "-0.5")
        for expression in ["1/0", "system('x')", "1..2", "", "2e999", "(2+3", String(repeating: "(", count: 20)] {
            XCTAssertThrowsError(try ExactOperations.calculate(expression))
        }
        XCTAssertEqual(try ExactOperations.transform("orbit", operation: .spell), "O R B I T")
        XCTAssertEqual(try ExactOperations.transform("café", operation: .reverse), "éfac")
    }
    func testAlarmDateUsesLocalDayAndRejectsDSTAmbiguity() throws {
        let zone = TimeZone(identifier: "America/Chicago")!
        let parse = ISO8601DateFormatter()
        // UTC has already advanced to the next day; Chicago has not.
        let late = parse.date(from: "2026-09-15T04:25:00Z")!
        XCTAssertEqual(try ExactOperations.alarmDate(dayOffset: 1, hour: 8, minute: 0, now: late, timeZone: zone),
            parse.date(from: "2026-09-15T13:00:00Z"))
        XCTAssertThrowsError(try ExactOperations.alarmDate(dayOffset: 0, hour: 8, minute: 0, now: late, timeZone: zone))
        let spring = parse.date(from: "2026-03-07T15:00:00Z")!
        XCTAssertThrowsError(try ExactOperations.alarmDate(dayOffset: 1, hour: 2, minute: 30, now: spring, timeZone: zone))
        let autumn = parse.date(from: "2026-10-31T15:00:00Z")!
        XCTAssertThrowsError(try ExactOperations.alarmDate(dayOffset: 1, hour: 1, minute: 30, now: autumn, timeZone: zone))
    }
    func testToolBudgetAndNoExecutionFromProposal() async throws {
        let tools = registry()
        let result = try await tools.propose(.init(kind: .remember, title: "Preference", content: "Likes jazz"))
        XCTAssertTrue(result.contains("Nothing has been executed"))
        for _ in 0..<5 { _ = try await tools.calculate("1+1") }
        do { _ = try await tools.calculate("1+1"); XCTFail("Unbounded tool loop") } catch ToolFailure.budget {} catch { XCTFail("\(error)") }
        let actions = await tools.actions
        XCTAssertEqual(actions.count, 1)
    }
    func testConnectorToolsRequireNativeEnabledPermissionAndFreshTurn() async throws {
        XCTAssertThrowsError(try ActionGate.requireNativeRead(.gmail, enabled: [.gmail], permission: .allowed))
        XCTAssertThrowsError(try ActionGate.requireNativeRead(.calendar, enabled: [], permission: .allowed))
        XCTAssertThrowsError(try ActionGate.requireNativeRead(.calendar, enabled: [.calendar], permission: .denied))
        XCTAssertNoThrow(try ActionGate.requireNativeRead(.contacts, enabled: [.contacts], permission: .limited))
        let tools = registry(current: false)
        do { _ = try await tools.calculate("1+1"); XCTFail("Stale turn reached tool") } catch {}
        let receipts = await tools.receipts
        XCTAssertTrue(receipts.isEmpty)
    }
    func testMemoryBridgeAppliesLocalGrantAndDropsRevokedSources() async throws {
        let bridge = MemoryContextBridge(), owner = UUID()
        let note = MemoryNote(text: "Orion deadline is Friday", scope: "Company")
        try await bridge.synchronize([note], ownerID: owner)
        let found = try await bridge.lookup("Orion", ownerID: owner, recipient: .appleOnDevice, deadline: Date()+60)
        XCTAssertEqual(found.map(\.id), [note.id])
        try await bridge.synchronize([], ownerID: owner)
        let gone = try await bridge.lookup("Orion", ownerID: owner, recipient: .appleOnDevice, deadline: Date()+60)
        XCTAssertTrue(gone.isEmpty)
        try await bridge.synchronize([note], ownerID: owner)
        let restored = try await bridge.lookup("Orion", ownerID: owner, recipient: .appleOnDevice, deadline: Date()+60)
        XCTAssertEqual(restored.count, 1)
    }
    func testAppUsesConversationModelInsteadOfLegacyPlan() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = ConversationProbe()
        let store = AppStore(repository: .init(url: folder.appendingPathComponent("state.json")), provider: model)
        store.state.memories = [.init(text: "Unrelated standup context")]
        let finished = expectation(description: "direct answer")
        store.send("Count from three to seven", mode: .spokenConversation, completion: { answer in
            XCTAssertEqual(answer, "3, 4, 5, 6, 7."); finished.fulfill()
        })
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(model.calls, 1)
        let proposals = try await store.proposalLedger.snapshot().proposals
        XCTAssertTrue(proposals.isEmpty)
        let journal = try await store.contextJournal.snapshot()
        XCTAssertEqual(journal.last?.status, .answered)
        XCTAssertEqual(journal.last?.tools?.first?.name, "sequence")
    }
    func testRecallUsesMatchedEvidenceAndFullSourceRemainsRevocable() async throws {
        let bridge = MemoryContextBridge(), owner = UUID()
        var note = MemoryNote(text: String(repeating: "Unrelated context. ", count: 25) + "The telescope delivery is Thursday.")
        try await bridge.synchronize([note], ownerID: owner)
        let found = try await bridge.lookup("telescope", ownerID: owner, recipient: .appleOnDevice, deadline: Date()+60)
        XCTAssertEqual(found.count, 1)
        let match = try XCTUnwrap(found.first)
        XCTAssertTrue(match.excerpt.contains("Thursday"))
        XCTAssertTrue(match.excerpt.hasPrefix("…"))
        let full = try await bridge.lookup("source:" + note.id.uuidString, ownerID: owner, recipient: .appleOnDevice, deadline: Date()+60)
        XCTAssertEqual(full.first?.excerpt, note.text)
        note.useInChat = false
        try await bridge.synchronize([note], ownerID: owner)
        let revoked = try await bridge.lookup("source:" + note.id.uuidString, ownerID: owner, recipient: .appleOnDevice, deadline: Date()+60)
        XCTAssertTrue(revoked.isEmpty)
    }
    func testCloudDefaultsAndLegacyConsentCannotEnableLiveVoice() {
        XCTAssertFalse(CloudValidation.liveVoice)
        let state = SavedState()
        XCTAssertNil(state.liveCloudAudioConsent)
        XCTAssertFalse(VoiceCloudAccess().allowsCloudAudio)
    }
    private func registry(current: Bool = true) -> ToolRegistry {
        .init(deadline: Date()+60, lookup: { _ in [] }, read: { _, _ in throw ToolFailure.missingPermission }, isCurrent: { current }, recipient: .onDevice)
    }
}

private final class ConversationProbe: ModelProvider, CompanionPlanner {
    let runsLocally = true, isAvailable = true
    let availabilityDescription = "Test", plannerID = "Never used"
    var calls = 0
    var receivedHistory: [ChatMessage] = []
    func reply(to: String, history: [ChatMessage], memories: [MemoryNote], standupFormat: String) async throws -> String { XCTFail("Legacy answer route"); return "wrong" }
    func plan(_ request: PlanningRequest) async throws -> CompanionPlan { XCTFail("Action-first route"); return .init(answer: "wrong") }
    func respond(_ request: PlanningRequest, tools: ToolRegistry, onSnapshot: @escaping @MainActor (String) -> Void) async throws -> CompanionPlan {
        calls += 1
        receivedHistory = request.history
        XCTAssertTrue(request.sources.isEmpty); XCTAssertTrue(request.standupFormat.isEmpty)
        let text = try await tools.sequence(start: 3, end: 7, step: 1)
        await onSnapshot(text)
        return .init(answer: text)
    }
}

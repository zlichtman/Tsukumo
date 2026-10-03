import XCTest
@testable import KemoSabe

final class ContextOrchestratorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func request(notes: [MemoryNote] = [], routine: RoutineDocument = .init()) -> PlanningRequest {
        .init(message: "Prepare an Orion update", history: [], memories: notes, standupFormat: "Short", now: now, routine: routine)
    }
    private func draft() -> CompanionPlan {
        .init(answer: "Sent it", actions: [.init(kind: .draft, title: "Orion update", content: "Orion is ready for review.")])
    }

    @MainActor func testSelectedSourcesReachRealApprovalWithoutAutomaticMemoryWrite() async throws {
        let selected = MemoryNote(text: "Orion uses a staged rollout.", scope: "Company")
        let unselected = MemoryNote(text: "I enjoy long walks.")
        let excluded = MemoryNote(text: "Orion confidential budget", scope: "Company", useInChat: false)
        let provider = ContextTestPlanner(selections: [[.init(window: .company, query: "Orion")], []],
            output: .init(answer: "Saved it", actions: [.init(kind: .remember, title: "Rollout preference", content: "Prefer staged rollouts.", memoryScope: "Company")]))
        let store = AppStore(repository: .init(url: folder().appendingPathComponent("state.json")), provider: provider)
        [selected, unselected, excluded].forEach { store.saveMemory($0) }
        let completed = expectation(description: "foreground planning completed")
        var reply: String?
        store.send("Remember my Orion rollout preference", completion: { reply = $0; completed.fulfill() })
        await fulfillment(of: [completed], timeout: 3)

        let planned = try XCTUnwrap(provider.requests.first)
        XCTAssertEqual(planned.sources.map(\.id), [selected.id])
        XCTAssertEqual(provider.turns.count, 2)
        XCTAssertFalse(provider.turns[0].prompt.contains(selected.text), "Routing should start with a manifest, not raw note bodies")
        XCTAssertFalse(provider.turns.map(\.prompt).joined().contains(excluded.text))
        XCTAssertFalse(planned.prompt.contains(unselected.text))
        XCTAssertEqual(store.state.memories.count, 3)
        let ledger = try await store.proposalLedger.snapshot()
        let proposal = try XCTUnwrap(ledger.proposals.first)
        XCTAssertEqual(proposal.status, .needsReview)
        XCTAssertEqual(proposal.origin?.sources, planned.sources)
        XCTAssertEqual(proposal.origin?.requestID, planned.id)
        XCTAssertNil(proposal.approvedDigest)
        XCTAssertTrue(reply?.contains("once you approve it in Day") == true)
        XCTAssertThrowsError(try store.keepApprovedMemory(proposal))

        let review = RoutineStore(ledger: store.proposalLedger)
        await review.review(proposal, store: store)
        XCTAssertNil(review.error)
        XCTAssertEqual(store.state.memories.filter { $0.id == proposal.id }.count, 1)
        XCTAssertEqual(review.state.proposals.first?.receipt, "Saved to memory")
        let runs = try await store.contextJournal.snapshot()
        XCTAssertEqual(runs.first?.status, .planned)
        XCTAssertEqual(runs.first?.reads.map(\.window), [.company])
    }

    @MainActor func testExcludingASelectedSourceAfterPlanningBlocksRealApproval() async throws {
        var selected = MemoryNote(text: "Orion rollout strategy", scope: "Company")
        let provider = ContextTestPlanner(selections: [[.init(window: .company, query: "Orion")], []], output: draft())
        let store = AppStore(repository: .init(url: folder().appendingPathComponent("state.json")), provider: provider)
        store.saveMemory(selected)
        let completed = expectation(description: "draft ready")
        store.send("Prepare an Orion update", completion: { _ in completed.fulfill() })
        await fulfillment(of: [completed], timeout: 3)
        let state = try await store.proposalLedger.snapshot()
        let proposal = try XCTUnwrap(state.proposals.first)
        XCTAssertEqual(proposal.origin?.sources.map(\.id), [selected.id])

        selected.useInChat = false; store.saveMemory(selected)
        let review = RoutineStore(ledger: store.proposalLedger)
        await review.review(proposal, store: store)
        XCTAssertNotNil(review.error)
        XCTAssertEqual(review.state.proposals.first?.status, .needsReview)
        XCTAssertNil(review.state.proposals.first?.approvedDigest)
        XCTAssertNil(review.state.proposals.first?.receipt)
    }

    func testExcludedAndUnknownScopeNotesNeverEnterManifestOrReads() throws {
        let allowed = MemoryNote(text: "Visible Orion note", scope: "Company")
        let excluded = MemoryNote(text: "Hidden Orion note", scope: "Personal", useInChat: false)
        let unknown = MemoryNote(text: "Unknown-scope Orion note", scope: "Admin")
        let notes = [allowed, excluded, unknown]
        let snapshot = ContextSnapshot(memories: notes, routine: .init(), request: request(notes: notes))
        XCTAssertEqual(snapshot.manifest, [.init(window: .company, recordCount: 1)])
        XCTAssertEqual(snapshot.read(.init(window: .company, query: "Orion")).sources.map(\.id), [allowed.id])
        XCTAssertTrue(snapshot.read(.init(window: .personal, query: "Orion")).sources.isEmpty)
    }

    func testPendingReviewExcludesContentDerivedFromAnExcludedSource() throws {
        var note = MemoryNote(text: "Excluded Orion source secret", scope: "Company")
        let seed = request(notes: [note])
        let plan = CompanionPlan(answer: "Review", actions: [.init(kind: .draft, title: "Private derived title", content: "Private derived payload")])
        var routine = RoutineDocument()
        routine.proposals = try PlanValidator.proposals(plan, request: seed, model: "Test", currentNotes: [note], now: now)
        note.useInChat = false
        let snapshot = ContextSnapshot(memories: [note], routine: routine, request: request(notes: [note], routine: routine))
        XCTAssertFalse(snapshot.manifest.contains { $0.window == .pendingReview })
        let read = snapshot.read(.init(window: .pendingReview, query: "Private"))
        XCTAssertTrue(read.facts.isEmpty)
        XCTAssertTrue(read.sources.isEmpty)
    }

    func testPendingReviewCarriesSourceProvenanceIntoNewProposal() async throws {
        let note = MemoryNote(text: "Orion launch constraints", scope: "Company")
        let original = request(notes: [note])
        var routine = RoutineDocument()
        routine.proposals = try PlanValidator.proposals(draft(), request: original, model: "Test", currentNotes: [note], now: now)
        let next = request(notes: [note], routine: routine)
        let provider = ContextTestPlanner(selections: [[.init(window: .pendingReview, query: "Orion")], []], output: draft())
        let result = try await ContextOrchestrator.run(request: next,
            snapshot: .init(memories: [note], routine: routine, request: next), planner: provider,
            journal: .init(url: folder().appendingPathComponent("runs.json")), now: { self.now })
        XCTAssertTrue(result.groundedRequest.sources.isEmpty)
        XCTAssertEqual(result.groundedRequest.consultedSources?.map(\.id), [note.id])
        XCTAssertTrue(result.groundedRequest.routineFacts.joined().contains("not executed"))
        XCTAssertFalse(provider.turns.map(\.prompt).joined().contains(note.text), "Provenance must not duplicate dependency excerpts in routing prompts")
        let derived = try PlanValidator.proposals(result.plan, request: result.groundedRequest,
            model: provider.plannerID, currentNotes: [note], now: now)
        XCTAssertEqual(derived.first?.origin?.sources.map(\.id), [note.id])
        var thirdRoutine = RoutineDocument(); thirdRoutine.proposals = derived
        let thirdRequest = request(notes: [note], routine: thirdRoutine)
        let transitive = ContextSnapshot(memories: [note], routine: thirdRoutine, request: thirdRequest)
            .read(.init(window: .pendingReview, query: "Orion"))
        XCTAssertEqual(transitive.dependencies.map(\.id), [note.id])
        var excluded = note; excluded.useInChat = false
        XCTAssertThrowsError(try PlanValidator.proposals(result.plan, request: result.groundedRequest,
            model: provider.plannerID, currentNotes: [excluded], now: now))
        let excludedAgain = ContextSnapshot(memories: [excluded], routine: thirdRoutine, request: thirdRequest)
        XCTAssertFalse(excludedAgain.manifest.contains { $0.window == .pendingReview })
    }

    func testMigratedSleepReportsRemainRetrievableAndPausedReportsStayExcluded() {
        var routine = RoutineDocument(); routine.bedtime = now - 8 * 3600; routine.wokeAt = now - 60
        let seed = request(routine: routine)
        let snapshot = ContextSnapshot(memories: [], routine: routine, request: seed)
        XCTAssertTrue(snapshot.manifest.contains { $0.window == .continuity })
        let facts = snapshot.read(.init(window: .continuity, query: "reported bed waking")).facts.joined()
        XCTAssertTrue(facts.contains("reported going to bed"))
        XCTAssertTrue(facts.contains("reported waking"))
        XCTAssertTrue(facts.contains("not measured sleep"))
        var context = ContinuousContext(); context.learning = false; routine.context = context
        let paused = ContextSnapshot(memories: [], routine: routine, request: request(routine: routine))
        XCTAssertFalse(paused.manifest.contains { $0.window == .continuity })
        XCTAssertTrue(paused.read(.init(window: .continuity, query: "sleep")).facts.isEmpty)
    }

    func testSecondPassCanFollowAClueToFreshRecordsOutsideTheInitialRead() async throws {
        let target = MemoryNote(text: "Zephyr schedule is Thursday", scope: "Company")
        let clue = MemoryNote(text: "Orion depends on Zephyr", scope: "Company")
        let notes = [target, clue] + (0..<3).map { MemoryNote(text: "Orion milestone \($0)", scope: "Company") }
        let seed = request(notes: notes)
        let provider = ContextTestPlanner()
        provider.onSelect = { turn, index in
            if index == 0 { return .init(reads: [.init(window: .company, query: "Orion")]) }
            XCTAssertTrue(turn.observations.flatMap(\.sources).contains { $0.id == clue.id })
            XCTAssertFalse(turn.observations.flatMap(\.sources).contains { $0.id == target.id })
            return .init(reads: [.init(window: .company, query: "Zephyr")])
        }
        let journal = ContextRunJournal(url: folder().appendingPathComponent("runs.json"))
        let result = try await ContextOrchestrator.run(request: seed, snapshot: .init(memories: notes, routine: .init(), request: seed), planner: provider, journal: journal, now: { self.now })
        XCTAssertEqual(provider.turns.count, 2)
        XCTAssertEqual(provider.turns.map(\.readsRemaining), [4, 3])
        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertTrue(result.groundedRequest.sources.contains { $0.id == target.id })
        XCTAssertEqual(Set(result.groundedRequest.sources.map(\.id)).count, result.groundedRequest.sources.count)
        let runs = try await journal.snapshot()
        XCTAssertEqual(runs.first?.reads.count, 2)
    }

    func testEquivalentDuplicateReadsDoNotRepeatWorkOrSpendAnotherRead() async throws {
        let notes = [MemoryNote(text: "Orion context", scope: "Company")], seed = request()
        let provider = ContextTestPlanner(selections: [
            [.init(window: .company, query: "  ORION\n"), .init(window: .company, query: "orion")],
            [.init(window: .company, query: "Orion")]
        ])
        let journal = ContextRunJournal(url: folder().appendingPathComponent("runs.json"))
        let result = try await ContextOrchestrator.run(request: seed, snapshot: .init(memories: notes, routine: .init(), request: seed), planner: provider, journal: journal, now: { self.now })
        let runs = try await journal.snapshot()
        XCTAssertEqual(runs.first?.reads.count, 1)
        XCTAssertEqual(provider.turns.map(\.readsRemaining), [4, 3])
        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertEqual(result.groundedRequest.sources.count, 1)
    }

    func testFourReadsTwoPassesAndFinalContextAreBounded() async throws {
        let notes = ["Personal", "Company", "Industry"].flatMap { scope in
            (0..<6).map { MemoryNote(text: "\(scope) record \($0) " + String(repeating: "x", count: 800), scope: scope) }
        }
        var routine = RoutineDocument(), context = ContinuousContext()
        for i in 0..<10 { context.observe(kind: .conversation, text: "Earlier report \(i) " + String(repeating: "y", count: 500), at: now - Double(i + 1)) }
        routine.context = context
        let seed = request(notes: notes, routine: routine)
        let provider = ContextTestPlanner(selections: [
            [.init(window: .personal, query: "record"), .init(window: .company, query: "record")],
            [.init(window: .industry, query: "record"), .init(window: .continuity, query: "report")],
            [.init(window: .company, query: "never reached")]
        ], output: draft())
        let journal = ContextRunJournal(url: folder().appendingPathComponent("runs.json"))
        let result = try await ContextOrchestrator.run(request: seed, snapshot: .init(memories: notes, routine: routine, request: seed), planner: provider, journal: journal, now: { self.now })
        XCTAssertEqual(provider.turns.count, 2)
        XCTAssertEqual(provider.turns.map(\.readsRemaining), [4, 2])
        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertEqual(result.groundedRequest.sources.count, 8)
        XCTAssertTrue(result.groundedRequest.sources.allSatisfy { $0.excerpt.count <= 300 })
        XCTAssertLessThanOrEqual(result.groundedRequest.routineFacts.count, 8)
        XCTAssertTrue(result.groundedRequest.routineFacts.allSatisfy { $0.count <= 320 })
        let consulted = try XCTUnwrap(result.groundedRequest.consultedSources)
        XCTAssertEqual(consulted.count, 12)
        let omitted = try XCTUnwrap(consulted.first { source in !result.groundedRequest.sources.contains { $0.id == source.id } })
        let proposals = try PlanValidator.proposals(result.plan, request: result.groundedRequest,
            model: provider.plannerID, currentNotes: notes, now: now)
        XCTAssertEqual(proposals.first?.origin?.sources, consulted)
        var changed = notes
        let index = try XCTUnwrap(changed.firstIndex { $0.id == omitted.id })
        changed[index].useInChat = false
        XCTAssertThrowsError(try PlanValidator.proposals(result.plan, request: result.groundedRequest,
            model: provider.plannerID, currentNotes: changed, now: now), "Sources omitted from the final eight must still invalidate approval")
        let runs = try await journal.snapshot()
        XCTAssertEqual(runs.first?.reads.count, 4)
        XCTAssertTrue(runs[0].reads.allSatisfy { $0.records <= 4 })
    }

    func testInvalidReadSelectionsFailClosedBeforeFinalPlanning() async throws {
        let notes = [MemoryNote(text: "Orion", scope: "Company")], seed = request()
        let invalid: [[ContextRead]] = [
            Array(repeating: .init(window: .company, query: "Orion"), count: 3),
            [.init(window: .company, query: String(repeating: "q", count: 161))],
            [.init(window: .industry, query: "not in manifest")]
        ]
        for reads in invalid {
            let provider = ContextTestPlanner(selections: [reads])
            let journal = ContextRunJournal(url: folder().appendingPathComponent("runs.json"))
            do {
                _ = try await ContextOrchestrator.run(request: seed, snapshot: .init(memories: notes, routine: .init(), request: seed), planner: provider, journal: journal, now: { self.now })
                XCTFail("Invalid routing must not reach a plan")
            } catch PlanningError.invalid {} catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertTrue(provider.requests.isEmpty)
            let runs = try await journal.snapshot()
            XCTAssertEqual(runs.first?.status, .failed)
            XCTAssertTrue(runs[0].reads.isEmpty)
        }
    }

    func testTransitiveProvenanceCannotGrowWithoutBound() async throws {
        let notes = (0..<65).map { MemoryNote(text: "Orion source \($0)", scope: "Company") }
        var original = request(notes: notes)
        original.consultedSources = notes.map {
            .init(id: $0.id, fingerprint: PlanningSource.fingerprint($0), scope: $0.scope, excerpt: $0.text)
        }
        var routine = RoutineDocument()
        routine.proposals = try PlanValidator.proposals(draft(), request: original, model: "Test", currentNotes: notes, now: now)
        let seed = request(notes: notes, routine: routine)
        let provider = ContextTestPlanner(selections: [[.init(window: .pendingReview, query: "Orion")], []])
        do {
            _ = try await ContextOrchestrator.run(request: seed,
                snapshot: .init(memories: notes, routine: routine, request: seed), planner: provider,
                journal: .init(url: folder().appendingPathComponent("runs.json")), now: { self.now })
            XCTFail("Must reject oversized provenance instead of silently dropping dependencies")
        } catch PlanningError.contextLimit {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(provider.requests.isEmpty)
    }

    func testEmptySnapshotSkipsRoutingAndDoesNotKeepUnselectedSeedContext() async throws {
        var seed = request(notes: [.init(text: "Seed-only note")])
        seed.routineFacts = ["Seed-only fact"]
        let provider = ContextTestPlanner()
        let result = try await ContextOrchestrator.run(request: seed,
            snapshot: .init(memories: [], routine: .init(), request: seed), planner: provider,
            journal: .init(url: folder().appendingPathComponent("runs.json")), now: { self.now })
        XCTAssertTrue(provider.turns.isEmpty)
        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertTrue(result.groundedRequest.sources.isEmpty)
        XCTAssertTrue(result.groundedRequest.routineFacts.isEmpty)
    }

    func testDeadlineIsCheckedBeforeWorkAfterSelectionAndAfterFinalPlan() async throws {
        for phase in 0..<3 {
            let notes = [MemoryNote(text: "Orion", scope: "Company")], seed = request()
            let clock = ContextTestClock(phase == 0 ? seed.deadline : now)
            let provider = ContextTestPlanner(selections: [[]])
            if phase == 1 { provider.onSelect = { _, _ in clock.value = seed.deadline; return .init(reads: []) } }
            if phase == 2 { provider.onPlan = { _ in clock.value = seed.deadline; return .init(answer: "Too late") } }
            let journal = ContextRunJournal(url: folder().appendingPathComponent("runs.json"))
            do {
                _ = try await ContextOrchestrator.run(request: seed, snapshot: .init(memories: notes, routine: .init(), request: seed), planner: provider, journal: journal, now: { clock.value })
                XCTFail("Expired work returned a result")
            } catch PlanningError.expired {} catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(provider.turns.count, phase == 0 ? 0 : 1)
            XCTAssertEqual(provider.requests.count, phase == 2 ? 1 : 0)
            let runs = try await journal.snapshot()
            if phase == 0 { XCTAssertTrue(runs.isEmpty) } else { XCTAssertEqual(runs.first?.status, .failed) }
        }
    }

    func testCancellationStopsLateSelectionAndMarksRunInterrupted() async throws {
        let notes = [MemoryNote(text: "Orion", scope: "Company")], seed = request()
        let entered = expectation(description: "selection entered"), latch = ContextTestLatch()
        let provider = ContextTestPlanner()
        provider.onSelect = { _, _ in
            entered.fulfill(); await latch.wait()
            return .init(reads: [.init(window: .company, query: "Orion")])
        }
        let journal = ContextRunJournal(url: folder().appendingPathComponent("runs.json"))
        let task = Task {
            try await ContextOrchestrator.run(request: seed, snapshot: .init(memories: notes, routine: .init(), request: seed), planner: provider, journal: journal, now: { self.now })
        }
        await fulfillment(of: [entered], timeout: 3)
        task.cancel(); await latch.release()
        do { _ = try await task.value; XCTFail("Cancelled selection returned a plan") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(provider.requests.isEmpty)
        let runs = try await journal.snapshot()
        XCTAssertEqual(runs.first?.status, .interrupted)
        XCTAssertTrue(runs[0].reads.isEmpty)
    }

    @MainActor func testClearingForegroundConversationCannotEnqueueALatePlan() async throws {
        let entered = expectation(description: "foreground selection entered"), latch = ContextTestLatch()
        let provider = ContextTestPlanner(output: draft())
        provider.onSelect = { _, _ in
            entered.fulfill(); await latch.wait()
            return .init(reads: [.init(window: .company, query: "Orion")])
        }
        let store = AppStore(repository: .init(url: folder().appendingPathComponent("state.json")), provider: provider)
        store.saveMemory(.init(text: "Orion", scope: "Company"))
        store.send("Prepare an Orion update")
        await fulfillment(of: [entered], timeout: 3)
        store.clearConversation(); await latch.release()
        var runs = try await store.contextJournal.snapshot()
        for _ in 0..<100 where runs.first?.status == .running {
            try await Task.sleep(for: .milliseconds(10)); runs = try await store.contextJournal.snapshot()
        }
        XCTAssertEqual(runs.first?.status, .interrupted)
        XCTAssertTrue(store.state.messages.isEmpty)
        XCTAssertFalse(store.isThinking)
        XCTAssertTrue(provider.requests.isEmpty)
        let ledger = try await store.proposalLedger.snapshot()
        XCTAssertTrue(ledger.proposals.isEmpty)
    }

    @MainActor func testRemoteSelectorIsBlockedByForegroundAndDirectOrchestrator() async throws {
        let provider = ContextTestPlanner(local: false)
        let store = AppStore(repository: .init(url: folder().appendingPathComponent("state.json")), provider: provider)
        store.saveMemory(.init(text: "Private Orion strategy", scope: "Company"))
        let blocked = expectation(description: "remote route blocked")
        store.send("Orion update", completion: { _ in blocked.fulfill() })
        await fulfillment(of: [blocked], timeout: 3)
        XCTAssertNotNil(store.error)
        let seed = request(notes: store.state.memories)
        do {
            _ = try await ContextOrchestrator.run(request: seed,
                snapshot: .init(memories: store.state.memories, routine: .init(), request: seed),
                planner: provider, journal: store.contextJournal, now: { self.now })
            XCTFail("Remote selector received private context")
        } catch PlanningError.unavailable {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(provider.turns.isEmpty)
        XCTAssertTrue(provider.requests.isEmpty)
        let runs = try await store.contextJournal.snapshot()
        XCTAssertTrue(runs.isEmpty)
    }

    func testJournalContainsOnlyExecutionMetadata() async throws {
        let url = folder().appendingPathComponent("runs.json")
        let note = MemoryNote(text: "PRIVATE_EXCERPT_CANARY", scope: "Company")
        let seed = PlanningRequest(message: "PRIVATE_REQUEST_CANARY", history: [.init(role: "You", text: "PRIVATE_HISTORY_CANARY")], memories: [note], standupFormat: "PRIVATE_FORMAT_CANARY", now: now)
        let provider = ContextTestPlanner(selections: [[.init(window: .company, query: "PRIVATE_QUERY_CANARY")], []], output: .init(answer: "PRIVATE_ANSWER_CANARY"))
        _ = try await ContextOrchestrator.run(request: seed, snapshot: .init(memories: [note], routine: .init(), request: seed), planner: provider, journal: .init(url: url), now: { self.now })
        let data = try Data(contentsOf: url), text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("PRIVATE_"))
        XCTAssertFalse(text.contains(note.id.uuidString))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(document.keys), ["version", "runs"])
        let run = try XCTUnwrap((document["runs"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(run.keys), ["id", "startedAt", "status", "reads"])
        let read = try XCTUnwrap((run["reads"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(read.keys), ["window", "records"])
    }

    func testJournalRestartMarksUnfinishedRunInterruptedAndAllowsNewTurn() async throws {
        let url = folder().appendingPathComponent("runs.json"), oldID = UUID(), newID = UUID()
        let original = ContextRunJournal(url: url)
        try await original.begin(oldID, at: now)
        try await original.read(oldID, window: .company, count: 2)
        let restored = ContextRunJournal(url: url)
        let interrupted = try await restored.snapshot()
        XCTAssertEqual(interrupted.first?.status, .interrupted)
        XCTAssertEqual(interrupted.first?.reads.first?.records, 2)
        do { try await restored.begin(oldID, at: now + 1); XCTFail("Replayed an old run ID") } catch PlanningError.busy {}
        do { try await restored.finish(oldID, status: .planned); XCTFail("Old work became completed") } catch PlanningError.invalid {}
        try await restored.begin(newID, at: now + 1)
        try await restored.finish(newID, status: .planned)
        let reopened = try await ContextRunJournal(url: url).snapshot()
        XCTAssertEqual(reopened.map(\.id), [oldID, newID])
        XCTAssertEqual(reopened.map(\.status), [.interrupted, .planned])
    }

    func testJournalBoundsHistoryAndRejectsInvalidTransitionsOrReadCounts() async throws {
        let journal = ContextRunJournal(url: folder().appendingPathComponent("runs.json"))
        var ids: [UUID] = []
        for i in 0..<35 {
            let id = UUID(); ids.append(id)
            try await journal.begin(id, at: now + Double(i))
            try await journal.finish(id, status: .planned)
        }
        let bounded = try await journal.snapshot()
        XCTAssertEqual(bounded.count, 32)
        XCTAssertEqual(bounded.map(\.id), Array(ids.suffix(32)))
        let id = UUID(); try await journal.begin(id, at: now + 40)
        do { try await journal.begin(UUID(), at: now + 41); XCTFail("Concurrent run accepted") } catch PlanningError.busy {}
        for count in [-1, 5] {
            do { try await journal.read(id, window: .company, count: count); XCTFail("Invalid record count accepted") } catch PlanningError.invalid {}
        }
        for _ in 0..<4 { try await journal.read(id, window: .company, count: 4) }
        do { try await journal.read(id, window: .company, count: 1); XCTFail("Fifth read accepted") } catch PlanningError.invalid {}
        do { try await journal.finish(id, status: .running); XCTFail("Running is not a finish status") } catch PlanningError.invalid {}
        try await journal.finish(id, status: .failed)
        do { try await journal.read(id, window: .company, count: 1); XCTFail("Read after finish accepted") } catch PlanningError.invalid {}
        do { try await journal.finish(id, status: .planned); XCTFail("Terminal status changed") } catch PlanningError.invalid {}
    }

    func testFailedFinalJournalWriteDoesNotReturnPlanOrBlockNextTurn() async throws {
        let url = folder().appendingPathComponent("runs.json"), first = request(), second = request()
        let journal = ContextRunJournal(url: url)
        let provider = ContextTestPlanner()
        provider.onPlan = { _ in
            // An exact temporary fixture path becomes unwritable as a file,
            // independently of simulator file-protection behavior.
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            return .init(answer: "Must not be returned without a completed checkpoint")
        }
        do {
            _ = try await ContextOrchestrator.run(request: first,
                snapshot: .init(memories: [], routine: .init(), request: first), planner: provider,
                journal: journal, now: { self.now })
            XCTFail("A failed final journal write returned a plan")
        } catch {}
        let interrupted = try await journal.snapshot()
        XCTAssertEqual(interrupted.first?.status, .interrupted)
        try FileManager.default.removeItem(at: url)
        _ = try await ContextOrchestrator.run(request: second,
            snapshot: .init(memories: [], routine: .init(), request: second), planner: ContextTestPlanner(),
            journal: journal, now: { self.now })
        await journal.abandon(second.id)
        let restored = try await ContextRunJournal(url: url).snapshot()
        XCTAssertEqual(restored.map(\.status), [.interrupted, .planned])
        XCTAssertEqual(restored.map(\.id), [first.id, second.id])
    }

    func testJournalRejectsCorruptVersionAndOversizedHistoryWithoutOverwriting() async throws {
        let run: [String: Any] = ["id": UUID().uuidString, "startedAt": 0, "status": "planned", "reads": []]
        var oversizedRead = run
        oversizedRead["reads"] = Array(repeating: ["window": "company", "records": 1], count: 5)
        let invalid: [[String: Any]] = [
            ["version": 2, "runs": [run]],
            ["version": 1, "runs": Array(repeating: run, count: 33)],
            ["version": 1, "runs": [oversizedRead]]
        ]
        for document in invalid {
            let url = folder().appendingPathComponent("runs.json")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let original = try JSONSerialization.data(withJSONObject: document)
            try original.write(to: url)
            let journal = ContextRunJournal(url: url)
            do { _ = try await journal.snapshot(); XCTFail("Corrupt journal was accepted") } catch RoutineError.corrupt {}
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }
}

private final class ContextTestPlanner: AssistantProvider, ContextSelectingPlanner {
    let output: CompanionPlan
    let local: Bool
    let selections: [[ContextRead]]
    var turns: [ContextTurn] = []
    var requests: [PlanningRequest] = []
    var onSelect: ((ContextTurn, Int) async throws -> ContextSelection)?
    var onPlan: ((PlanningRequest) async throws -> CompanionPlan)?
    init(selections: [[ContextRead]] = [], output: CompanionPlan = .init(answer: "Ready to help"), local: Bool = true) {
        self.selections = selections; self.output = output; self.local = local
    }
    var isAvailable: Bool { true }
    var availabilityDescription: String { "Context test planner" }
    var plannerID: String { "Context test planner" }
    var runsLocally: Bool { local }
    func selectContext(_ turn: ContextTurn) async throws -> ContextSelection {
        let index = turns.count; turns.append(turn)
        if let onSelect { return try await onSelect(turn, index) }
        return .init(reads: index < selections.count ? selections[index] : [])
    }
    func plan(_ request: PlanningRequest) async throws -> CompanionPlan {
        requests.append(request)
        if let onPlan { return try await onPlan(request) }
        return output
    }
    func reply(to message: String, history: [ChatMessage], memories: [MemoryNote], standupFormat: String) async throws -> String {
        XCTFail("A selecting planner must not fall back to the legacy reply route")
        return "Unexpected legacy response"
    }
}

private final class ContextTestClock {
    var value: Date
    init(_ value: Date) { self.value = value }
}

private actor ContextTestLatch {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true; continuation?.resume(); continuation = nil
    }
}

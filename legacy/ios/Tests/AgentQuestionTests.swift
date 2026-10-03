import XCTest
#if os(macOS)
@testable import KemoSabeMac
#else
@testable import KemoSabe
#endif

/// Agents asking KemoSabe (design/CONTEXT-HARNESS.md#agents-asking-kemosabe): the owner's consent
/// per agent, the policy for what the on-device model may read for an agent, the card for Sensitive
/// items, and the transcript. A fake stands in for Apple's on-device model; nothing leaves the test.
@MainActor final class AgentQuestionTests: XCTestCase {
    private let muse = AgentRequester(recipient: .externalAgent("com.meta.muse"), name: "Muse")
    private let question = "What time did she say she was free?"
    private let sarah = """
        Sarah: The hike was unreal.
        Sarah: I'm free Friday after 7, want to do dinner?
        You: Perfect, I'll find a place.
        """
    private var folders: [URL] = []
    override func tearDown() async throws {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        folders = []
    }

    // MARK: Consent

    func testFirstQuestionAsksThenAllowAlwaysAnswersWithoutACard() async throws {
        let (store, model) = makeStore()
        seed(store, sarah, level: nil)
        async let first = store.agentQuestions.ask(ask())
        try await waitUntil { store.agentQuestions.consent != nil }
        XCTAssertEqual(store.agentQuestions.consent?.requester.name, "Muse")
        XCTAssertTrue(AgentConsentText.message(store.agentQuestions.consent!).contains(question))
        store.agentQuestions.decide(.always)
        let answer = await first
        XCTAssertEqual(answer, .answered("Friday after 7"), "Only the answer leaves, not the excerpt or the thread")
        XCTAssertNil(store.agentRequests.current, "No card for a Personal chat under Allow always")
        XCTAssertEqual(store.state.agentQuestionGrants(for: muse.recipient).count, 1)
        XCTAssertEqual(store.state.agentQuestionGrants(for: muse.recipient).first?.singleUse, false)

        // The next question goes straight through.
        let second = await store.agentQuestions.ask(ask())
        XCTAssertEqual(second, .answered("Friday after 7"))
        XCTAssertNil(store.agentQuestions.consent)
        XCTAssertEqual(model.calls.value, 2)

        let journal = try await store.agentRequests.journal.snapshot()
        XCTAssertEqual(journal.count, 2)
        let record = try XCTUnwrap(journal.last)
        XCTAssertEqual(record.requester, "Muse"); XCTAssertEqual(record.requesterKey, "agent:com.meta.muse")
        XCTAssertEqual(record.channel, "mcp"); XCTAssertEqual(record.outcome, .shared); XCTAssertEqual(record.automatic, true)
        XCTAssertEqual(record.lookingFor, question); XCTAssertEqual(record.purpose, "planning dinner")
        XCTAssertEqual(record.shared, "Friday after 7", "The transcript holds exactly what was sent")
        XCTAssertEqual(record.target, "your chats")
        XCTAssertNotNil(store.agentQuestions.notice)
    }

    func testDontAllowDeclinesAndDoesNotAskAgainRightAway() async throws {
        let (store, model) = makeStore()
        seed(store, sarah, level: nil)
        async let first = store.agentQuestions.ask(ask())
        try await waitUntil { store.agentQuestions.consent != nil }
        store.agentQuestions.decide(.deny)
        let firstAnswer = await first; XCTAssertEqual(firstAnswer, .declined)
        let again = await store.agentQuestions.ask(ask()); XCTAssertEqual(again, .declined)
        XCTAssertNil(store.agentQuestions.consent, "No second prompt")
        XCTAssertTrue(store.state.agentQuestionGrants(for: muse.recipient).isEmpty, "Nothing is granted")
        XCTAssertEqual(model.calls.value, 0, "Nothing was read")
        let journal = try await store.agentRequests.journal.snapshot()
        XCTAssertEqual(journal.map(\.outcome), [.declined, .declined])
        XCTAssertNil(journal.first?.shared)
    }

    func testAllowOnceCoversOneQuestionAndAnUnansweredPromptSharesNothing() async throws {
        let (store, _) = makeStore()
        seed(store, sarah, level: nil)
        store.agentQuestions.consentTimeout = .milliseconds(300)
        async let first = store.agentQuestions.ask(ask())
        try await waitUntil { store.agentQuestions.consent != nil }
        store.agentQuestions.decide(.once)
        let firstAnswer = await first; XCTAssertEqual(firstAnswer, .answered("Friday after 7"))
        XCTAssertTrue(store.state.agentQuestionGrants(for: muse.recipient).isEmpty, "Once is spent")

        // The next one asks again; nobody answers in time.
        let second = await store.agentQuestions.ask(ask())
        XCTAssertEqual(second, .waiting)
        XCTAssertNotNil(store.agentQuestions.consent, "The prompt stays up for the owner")
        let journal = try await store.agentRequests.journal.snapshot()
        XCTAssertEqual(journal.last?.outcome, .unanswered)
        XCTAssertNil(journal.last?.shared)
        // Answering late counts for the next question.
        store.agentQuestions.decide(.always)
        let late = await store.agentQuestions.ask(ask()); XCTAssertEqual(late, .answered("Friday after 7"))
    }

    func testRemovingAnAgentMakesItAskAgain() async throws {
        let (store, _) = makeStore()
        store.state.allowAgentQuestions(muse.recipient, once: false)
        store.state.allowAgentQuestions(.codingAgent("codex"), once: true)
        XCTAssertEqual(store.state.agentQuestionAgents().map { AgentIdentity.name(forKey: $0.recipient) }, ["Muse", "Codex"])
        store.state.revokeAgentQuestions(muse.recipient.key)
        XCTAssertTrue(store.state.agentQuestionGrants(for: muse.recipient).isEmpty)
        XCTAssertEqual(store.state.agentQuestionAgents().count, 1)
        // A grant for one agent never covers another.
        XCTAssertTrue(store.state.agentQuestionGrants(for: .codingAgent("claude-code")).isEmpty)
    }

    // MARK: The policy

    func testDeviceOnlyAndSecretAreNeverReadAndOnlyCounted() async throws {
        let (store, model) = makeStore()
        seed(store, "Sarah: I'm free Friday after 7, the lockbox code is 4411.", level: .deviceOnly)
        seed(store, "Sarah: I'm free Saturday too, my therapist moved.", level: .secret, keep: true)
        seed(store, "Sarah: Free for a walk sometime?", level: .open, keep: true)
        store.state.allowAgentQuestions(muse.recipient, once: false)
        let answer = await store.agentQuestions.ask(ask())
        XCTAssertEqual(answer, .notFound)
        XCTAssertFalse(model.inputs.value.joined().contains("lockbox"), "Device only never reaches the model for an agent")
        XCTAssertFalse(model.inputs.value.joined().contains("therapist"), "Secret never reaches any model")
        XCTAssertTrue(model.inputs.value.joined().contains("walk"))
        let record = try await lastRecord(store)
        XCTAssertEqual(record.outcome, .notFound)
        XCTAssertEqual(record.withheldCount, 2)
        XCTAssertEqual(record.withheld, "Not read: 1 Device only chat, 1 Secret chat.")
        XCTAssertFalse((record.withheld ?? "").contains("lockbox"))
    }

    func testPersonalNeedsTheAgentsGrantAndSensitiveGoesToTheCard() async throws {
        let (store, model) = makeStore()
        store.agentRequests.model = model
        let archive = seed(store, sarah, level: .sensitive)
        store.state.allowAgentQuestions(muse.recipient, once: false)
        async let pending = store.agentQuestions.ask(ask())
        try await waitUntil { if case .ready? = store.agentRequests.current?.phase { true } else { false } }
        let card = try XCTUnwrap(store.agentRequests.current)
        XCTAssertEqual(card.request.target, .conversation(archive.id))
        XCTAssertEqual(card.request.purpose, "planning dinner")
        XCTAssertEqual(card.subject?.title, "your conversation with Sarah")
        await store.agentRequests.share(.init(answer: "Friday after 7", excerpt: ""))
        let shared = await pending; XCTAssertEqual(shared, .answered("Friday after 7"), "The owner's Share is what's sent")
        let record = try await lastRecord(store)
        XCTAssertEqual(record.outcome, .shared); XCTAssertEqual(record.automatic, false)
        XCTAssertEqual(record.shared, "Friday after 7"); XCTAssertEqual(record.channel, "mcp")

        // Without any grant a Personal chat isn't read for an agent at all.
        XCTAssertFalse(ContextPolicy.allows(.conversation(UUID(), level: .personal), to: muse.recipient, purpose: .agentQuestion))
        XCTAssertTrue(ContextPolicy.allows(.conversation(UUID(), level: .personal), to: muse.recipient, purpose: .agentQuestion, grants: store.liveGrants))
        XCTAssertFalse(ContextPolicy.allows(.conversation(UUID(), level: .sensitive), to: muse.recipient, purpose: .agentQuestion, grants: store.liveGrants),
                       "Allow always never covers a Sensitive item")
    }

    func testACardTheOwnerNeverAnswersSendsNothing() async throws {
        let (store, model) = makeStore()
        store.agentRequests.model = model
        seed(store, sarah, level: .sensitive)
        store.state.allowAgentQuestions(muse.recipient, once: false)
        store.agentQuestions.cardTimeout = .milliseconds(300)
        let unanswered = await store.agentQuestions.ask(ask()); XCTAssertEqual(unanswered, .waiting)
        try await waitUntil { if case .ready? = store.agentRequests.current?.phase { true } else { false } }
        await store.agentRequests.share(.init(answer: "Friday after 7", excerpt: ""))
        let record = try await lastRecord(store)
        XCTAssertEqual(record.outcome, .failed, "A Share after the agent stopped waiting sends nothing")
        XCTAssertNil(record.shared)
    }

    func testALockedMacAnswersNothing() async throws {
        let (store, model) = makeStore()
        seed(store, sarah, level: nil)
        store.state.allowAgentQuestions(muse.recipient, once: false)
        store.agentQuestions.isLocked = { true }
        guard case .unavailable = await store.agentQuestions.ask(ask()) else { return XCTFail("Locked") }
        XCTAssertEqual(model.calls.value, 0)
    }

    func testMalformedQuestionsAreRefused() async {
        let (store, _) = makeStore()
        guard case .refused = await store.agentQuestions.ask(.init(requester: muse, question: " ", purpose: "x")) else { return XCTFail("Empty") }
        guard case .refused = await store.agentQuestions.ask(.init(requester: muse, question: String(repeating: "a", count: 501), purpose: "x")) else { return XCTFail("Long") }
        guard case .refused = await store.agentQuestions.ask(.init(requester: .init(recipient: .appleOnDevice, name: "Me"), question: question, purpose: "x")) else {
            return XCTFail("Nothing may pose as this device")
        }
        XCTAssertNil(store.agentQuestions.consent)
    }

    // MARK: Identity and the transcript

    func testAgentsAreNamedFromTheirConfigOrClientInfo() {
        XCTAssertEqual(AgentIdentity.requester(agent: "claude-code", clientName: nil, clientTitle: nil)?.recipient, .codingAgent("claude-code"))
        XCTAssertEqual(AgentIdentity.requester(agent: nil, clientName: "claude-code", clientTitle: nil)?.name, "Claude Code")
        XCTAssertEqual(AgentIdentity.requester(agent: nil, clientName: "codex-mcp-client", clientTitle: "Codex")?.recipient, .codingAgent("codex"))
        XCTAssertEqual(AgentIdentity.requester(agent: "muse", clientName: "whatever", clientTitle: nil)?.recipient, .externalAgent("com.meta.muse"))
        XCTAssertEqual(AgentIdentity.requester(agent: "acp:Gemini CLI", clientName: nil, clientTitle: nil)?.recipient, .acpAgent("geminicli"))
        let other = AgentIdentity.requester(agent: nil, clientName: "My Agent!", clientTitle: "My Agent")
        XCTAssertEqual(other?.recipient, .externalAgent("myagent")); XCTAssertEqual(other?.name, "My Agent")
        XCTAssertNil(AgentIdentity.requester(agent: nil, clientName: nil, clientTitle: nil))
        XCTAssertEqual(AgentIdentity.name(forKey: "coding:codex"), "Codex")
        XCTAssertEqual(AgentIdentity.name(forKey: "agent:myagent"), "myagent")
    }

    func testWithheldIsCountsNeverContent() {
        var withheld = AgentWithheld()
        withheld.add("notRead", .deviceOnly, .conversation)
        withheld.add("notRead", .secret, .memory); withheld.add("notRead", .secret, .memory)
        withheld.add("notShared", .sensitive, .journal)
        XCTAssertEqual(withheld.total, 4)
        XCTAssertEqual(withheld.summary, "Not read: 1 Device only chat, 2 Secret memories. Not shared: 1 Sensitive journal entry.")
        let data = try? JSONEncoder().encode(AgentRequestRecord(id: UUID(), requester: "Muse", requesterKey: "agent:x", channel: "mcp", target: "t",
            lookingFor: "q", outcome: .shared, shared: "a", receivedAt: Date(), decidedAt: Date()))
        // An older record without the new fields, and an outcome from a newer build, still load.
        let old = #"{"id":"8A3E6A1C-0B8B-4B7C-9E3E-4C3A8F0F0A11","requester":"Muse","requesterKey":"agent:x","channel":"fixture","target":"t","lookingFor":"q","outcome":"hologram","receivedAt":0,"decidedAt":0}"#
        let decoded = try? JSONDecoder().decode(AgentRequestRecord.self, from: Data(old.utf8))
        XCTAssertNotNil(data)
        XCTAssertEqual(decoded?.outcome, .failed)
        XCTAssertNil(decoded?.purpose)
    }

    func testAChatWithClaudeIsNeverTheOtherPersonInAThread() {
        let id = UUID()
        let archive = ConversationArchive(model: "Apple", recipient: nil, messages: [
            ChatMessage(handoff: .init(id: id, part: .task, agent: ChatHandoff.claude), text: "find a date spot"),
            ChatMessage(handoff: .init(id: id, part: .answer, agent: ChatHandoff.claude, question: "When is Sarah free?", stayed: "3 messages, 1 chat", shared: "After 7"), text: "After 7"),
            ChatMessage(handoff: .init(id: id, part: .result, agent: ChatHandoff.claude, session: "s-1"), text: "Osteria Lucia at 7:30"),
        ])
        XCTAssertNil(archive.counterpart)
        XCTAssertEqual(archive.messages.map(\.role), ["You", "KemoSabe", "Claude"], "Kemo is the local agent that answers")
        XCTAssertEqual(archive.messages[1].handoff?.stayedLine, "Stayed on this \(AgentDevice.name): 3 messages, 1 chat")
        XCTAssertEqual(ChatHandoff.localCaption(AgentDevice.name), "On this \(AgentDevice.name) · Apple on-device")
        XCTAssertEqual(ChatHandoff.localCaption("Watch"), "On your Watch · Apple on-device")
        let decoded = try? JSONDecoder().decode(ChatHandoff.self, from: Data(#"{"id":"8A3E6A1C-0B8B-4B7C-9E3E-4C3A8F0F0A11","part":"hologram","agent":"X"}"#.utf8))
        XCTAssertEqual(decoded?.part, .status, "A part from a newer build still shows")
        // "@Kemo …" is for Kemo alone; anything else goes to Claude.
        XCTAssertEqual(ChatAgentRouting.kemoMessage("@Kemo what's on my calendar?", companion: "Mochi"), "what's on my calendar?")
        XCTAssertEqual(ChatAgentRouting.kemoMessage("@kemosabe, remind me", companion: "Mochi"), "remind me")
        XCTAssertEqual(ChatAgentRouting.kemoMessage("@Mochi hi", companion: "Mochi"), "hi")
        XCTAssertNil(ChatAgentRouting.kemoMessage("@Kemonade stand ideas", companion: "Mochi"))
        XCTAssertNil(ChatAgentRouting.kemoMessage("ask Kemo later", companion: "Mochi"))
        XCTAssertNil(ChatAgentRouting.kemoMessage("@Kemo", companion: "Mochi"))
    }

    func testChoosingClaudeStartsItsOwnChatAndAModelEndsIt() {
        let (store, _) = makeStore()
        store.appendVisibleMessage(role: "You", text: "hello Kemo")
        store.selectChatAgent(ChatHandoff.claudeAgentID)
        XCTAssertEqual(store.state.chatAgent, ChatHandoff.claudeAgentID)
        XCTAssertTrue(store.conversationMessages.isEmpty, "A chat with Claude is its own conversation")
        XCTAssertEqual(store.modelRoute, .onDevice, "Kemo's part runs on Apple's on-device model")
        let id = UUID()
        store.appendVisibleMessage(ChatMessage(handoff: .init(id: id, part: .task, agent: ChatHandoff.claude), text: "plan dinner"))
        store.appendVisibleMessage(ChatMessage(handoff: .init(id: id, part: .result, agent: ChatHandoff.claude, session: "s-9"), text: "Osteria Lucia"))
        XCTAssertEqual(store.agentChat.id, id); XCTAssertEqual(store.agentChat.session, "s-9", "The next message continues Claude's session")
        store.selectAppleModel(.onDevice)
        XCTAssertNil(store.state.chatAgent)
        XCTAssertTrue(store.conversationMessages.isEmpty)
        let archive = try? XCTUnwrap(store.state.conversationArchives?.last)
        store.resumeArchivedConversation(archive?.id ?? UUID())
        XCTAssertEqual(store.state.chatAgent, ChatHandoff.claudeAgentID, "Reopening a chat with Claude continues it with Claude")
    }

    func testRankingReadsOnlyWhatSharesWords() {
        let items = [AgentQuestionSource(item: .conversation(UUID(), level: .open), title: "a", text: "We talked about the weather.", target: nil),
                     AgentQuestionSource(item: .conversation(UUID(), level: .open), title: "b", text: "I'm free Friday after 7.", target: nil)]
        XCTAssertEqual(AgentQuestionDesk.rank(items, for: question).map(\.title), ["b"])
        XCTAssertTrue(AgentQuestionDesk.rank(items, for: "the and you").isEmpty, "Stop words alone match nothing")
    }

    // MARK: Helpers

    private func lastRecord(_ store: AppStore) async throws -> AgentRequestRecord {
        let records = try await store.agentRequests.journal.snapshot()
        return try XCTUnwrap(records.last)
    }
    private func ask() -> AgentQuestion { .init(requester: muse, question: question, purpose: "planning dinner") }
    private func makeStore() -> (AppStore, QuestionFakeModel) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        folders.append(folder)
        let store = AppStore(repository: .init(url: folder.appendingPathComponent("state.json")), provider: APIUnavailableLocal(), apiKeys: MemoryAPIKeys())
        let model = QuestionFakeModel()
        store.agentQuestions.model = model
        store.agentQuestions.sources = StoreAgentQuestionSources(store: store, docs: nil, includeCalendar: false)
        return (store, model)
    }
    @discardableResult private func seed(_ store: AppStore, _ text: String, level: PrivacyLevel?, keep: Bool = false) -> ConversationArchive {
        var archive = ConversationArchive(model: "Messages", recipient: nil, messages: text.split(separator: "\n").map { line in
            let parts = line.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            return ChatMessage(role: parts[0], text: parts[1])
        })
        archive.privacy = level
        store.state.conversationArchives = (keep ? store.state.conversationArchives ?? [] : []) + [archive]
        store.save()
        return archive
    }
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < end else { return XCTFail("Timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

final class QuestionCounter<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock(); private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func update(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
}

/// Stands in for Apple's on-device model: finds "Friday after 7" when the text holds it.
struct QuestionFakeModel: AgentExtractionModel {
    let calls = QuestionCounter(0)
    let inputs = QuestionCounter<[String]>([])
    var isAvailable: Bool { true }
    func extract(lookingFor: String, from text: String) async throws -> AgentExtractionDraft {
        calls.update { $0 += 1 }; inputs.update { $0.append(text) }
        guard let line = text.split(separator: "\n").first(where: { $0.contains("Friday after 7") }) else { return .init(found: false, answer: "", excerpt: "") }
        return .init(found: true, answer: "Friday after 7", excerpt: String(line))
    }
}

import XCTest
#if os(macOS)
@testable import KemoSabeMac
#else
@testable import KemoSabe
#endif

/// Personal sources (design/CONTEXT-HARNESS.md#personal-sources): each is off until the owner turns
/// it on, contributes nothing while off, reads only small excerpts, and carries a level the policy
/// honors. Fakes stand in for Apple's permissions, location, and on-device model; no test reads this
/// device's real messages, contacts, reminders, or location.
@MainActor final class PersonalSourcesTests: XCTestCase {
    private let muse = AgentRequester(recipient: .externalAgent("com.meta.muse"), name: "Muse")
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private var folders: [URL] = []
    override func tearDown() async throws {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        folders = []
    }

    // MARK: The owner's switches

    func testEverySourceStartsOffAndMessagesAreSensitive() {
        let settings = PersonalSourceSettings(defaults: defaults())
        XCTAssertFalse(settings.messages); XCTAssertFalse(settings.location)
        XCTAssertEqual(settings.messagesLevel, .sensitive)
    }

    func testSwitchesPersistAndOnlySensitiveOrDeviceOnlyAreKept() {
        let store = defaults()
        let settings = PersonalSourceSettings(defaults: store)
        settings.messages = true; settings.messagesLevel = .deviceOnly; settings.location = true
        let again = PersonalSourceSettings(defaults: store)
        XCTAssertTrue(again.messages); XCTAssertTrue(again.location); XCTAssertEqual(again.messagesLevel, .deviceOnly)
        store.set(PrivacyLevel.open.rawValue, forKey: "kemo.sources.messages.level")
        XCTAssertEqual(PersonalSourceSettings(defaults: store).messagesLevel, .deviceOnly, "A level Messages doesn't offer falls to the most private")
    }

    // MARK: What a question asks for

    func testQuestionsNamePeopleWordsAndTime() {
        let free = MessagesQuery.parse("When is Sarah free?", now: now)
        XCTAssertEqual(free.names, ["Sarah"]); XCTAssertEqual(free.words, ["free"])
        let friday = MessagesQuery.parse("What did Sarah say about Friday?", now: now)
        XCTAssertEqual(friday.names, ["Sarah"]); XCTAssertEqual(friday.words, ["friday"])
        XCTAssertEqual(friday.since, Calendar.current.date(byAdding: .day, value: -MessagesQuery.defaultDays, to: Calendar.current.startOfDay(for: now)))
        let known = MessagesQuery.parse("what did sarah chen text me yesterday", knownNames: ["Sarah Chen", "Sam"], now: now)
        XCTAssertEqual(known.names, ["Sarah Chen"])
        XCTAssertEqual(known.since, Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: now)))
        XCTAssertEqual(known.until, Calendar.current.startOfDay(for: now))
        XCTAssertTrue(MessagesQuery.parse("Find a spot near me", now: now).names.isEmpty, "Question words aren't names")
    }

    // MARK: Excerpts

    func testExcerptsAreSmallAndNeverAWholeThread() {
        var thread: [TextMessage] = []
        for index in 0..<40 {
            let text = index % 5 == 0 ? "Free after 7? " + String(repeating: "long words ", count: 120) : "Message \(index) about the hike."
            thread.append(.init(id: "\(index)", chat: "1", sender: index.isMultiple(of: 2) ? "Sarah" : "You", fromMe: !index.isMultiple(of: 2),
                                date: now.addingTimeInterval(Double(index - 40) * 600), text: text))
        }
        let excerpts = MessageExcerpts.build(thread, query: MessagesQuery.parse("When is Sarah free?", now: now), named: true)
        XCTAssertFalse(excerpts.isEmpty)
        XCTAssertLessThanOrEqual(excerpts.count, MessageExcerpts.maxExcerpts)
        for excerpt in excerpts {
            XCTAssertLessThanOrEqual(excerpt.messages.count, MessageExcerpts.maxExcerptMessages)
            XCTAssertTrue(excerpt.messages.allSatisfy { $0.text.count <= MessageExcerpts.maxMessageCharacters })
            XCTAssertLessThanOrEqual(excerpt.messages.map(\.text.count).reduce(0, +), MessageExcerpts.maxExcerptCharacters)
            XCTAssertEqual(excerpt.title, "your messages with Sarah")
        }
        XCTAssertLessThan(Set(excerpts.flatMap { $0.messages.map(\.id) }).count, thread.count / 2, "Never the whole thread")
    }

    func testANamedPersonWithoutMatchingWordsGivesTheirLatestMessages() {
        let thread = [TextMessage(id: "1", chat: "a", sender: "Sarah", fromMe: false, date: now.addingTimeInterval(-7200), text: "Landed!"),
                      TextMessage(id: "2", chat: "a", sender: "You", fromMe: true, date: now.addingTimeInterval(-7000), text: "Welcome back"),
                      TextMessage(id: "3", chat: "b", sender: "Sam", fromMe: false, date: now.addingTimeInterval(-60), text: "Pizza?")]
        let excerpts = MessageExcerpts.build(thread, query: MessagesQuery.parse("What did Sarah say?", now: now), named: true)
        XCTAssertEqual(excerpts.map(\.id), ["1"], "Only Sarah's own message, never Sam's")
        XCTAssertTrue(excerpts[0].text.contains("Sarah (")); XCTAssertTrue(excerpts[0].text.contains("You ("))
        XCTAssertTrue(MessageExcerpts.build(thread, query: MessagesQuery.parse("What about pizza?", now: now), named: false).map(\.id) == ["3"])
        XCTAssertTrue(MessageExcerpts.build(thread, query: MessagesQuery.parse("What did Sarah say?", now: now), named: false).isEmpty,
                      "Without a matched person and no words, nothing")
    }

    // MARK: Messages you shared

    func testSharedMessagesAddListAndDelete() throws {
        let store = sharedStore()
        let first = try store.add(sender: "Sarah", text: "I'm free Friday after 7", date: now.addingTimeInterval(-60), now: now)
        let second = try store.add(sender: "Sam", text: "Running late", date: nil, now: now.addingTimeInterval(1))
        XCTAssertEqual(store.list().map(\.id), [second.id, first.id], "Newest first")
        XCTAssertEqual(store.list().first?.date, now.addingTimeInterval(1), "No date means when it arrived")
        store.delete(first.id)
        XCTAssertEqual(store.list().map(\.id), [second.id])
        store.deleteAll()
        XCTAssertTrue(store.list().isEmpty)
        XCTAssertThrowsError(try store.add(sender: " ", text: "x", date: nil)) { XCTAssertEqual($0 as? SharedMessagesStore.Failure, .empty) }
        XCTAssertThrowsError(try store.add(sender: "Sarah", text: "\n", date: nil))
        let long = try store.add(sender: "Sarah", text: String(repeating: "a", count: 5000), date: nil)
        XCTAssertEqual(long.text.count, SharedMessagesStore.maxText)
    }

    func testSharedMessagesKeepOnlyTheNewest() throws {
        let store = sharedStore()
        for index in 0...SharedMessagesStore.maxMessages {
            try store.add(sender: "Sarah", text: "Message \(index)", date: nil, now: now.addingTimeInterval(Double(index)))
        }
        XCTAssertEqual(store.count, SharedMessagesStore.maxMessages)
        XCTAssertFalse(store.list().contains { $0.text == "Message 0" }, "The oldest went first")
    }

    func testSharedMessagesContributeNothingWhileOffAndCarryTheChosenLevel() async throws {
        let settings = PersonalSourceSettings(defaults: defaults())
        let store = sharedStore()
        try store.add(sender: "Sarah", text: "I'm free Friday after 7", date: Date().addingTimeInterval(-3600))
        try store.add(sender: "Sam", text: "I'm free never", date: Date().addingTimeInterval(-1800))
        let source = SharedMessagesQuestionSource(store: store, settings: settings)
        let off = await source.sources(for: "When is Sarah free?", now: Date())
        XCTAssertTrue(off.isEmpty, "Off contributes nothing")
        settings.messages = true
        let on = await source.sources(for: "When is Sarah free?", now: Date())
        XCTAssertEqual(on.count, 1, "Only Sarah's")
        XCTAssertEqual(on.first?.item.ref.kind, .textMessage); XCTAssertEqual(on.first?.item.level, .sensitive)
        XCTAssertTrue(on.first?.text.contains("Friday after 7") == true); XCTAssertFalse(on.first?.text.contains("never") == true)
        guard case .excerpt(let subject)? = on.first?.target else { return XCTFail("An excerpt can go to the card") }
        XCTAssertEqual(subject.text, on.first?.text)
        settings.messagesLevel = .deviceOnly
        let deviceOnly = await source.sources(for: "When is Sarah free?", now: Date())
        XCTAssertEqual(deviceOnly.first?.item.level, .deviceOnly)
    }

    #if os(iOS)
    func testTheShortcutsActionStoresOnlyWhileMessagesIsOn() {
        let settings = PersonalSourceSettings(defaults: defaults())
        let store = sharedStore()
        let off = GiveMessageToKemoSabeIntent.give(sender: "Sarah", text: "Free after 7", date: nil, settings: settings, store: store)
        XCTAssertTrue(off.contains("Messages is off")); XCTAssertEqual(store.count, 0)
        settings.messages = true
        XCTAssertEqual(GiveMessageToKemoSabeIntent.give(sender: "Sarah", text: "Free after 7", date: nil, settings: settings, store: store), "KemoSabe has it.")
        XCTAssertEqual(store.list().map(\.text), ["Free after 7"])
        XCTAssertEqual(GiveMessageToKemoSabeIntent.give(sender: "", text: "x", date: nil, settings: settings, store: store), "There was no sender or message to save.")
        XCTAssertEqual(store.count, 1)
    }
    #endif

    // MARK: Asking through the desk

    func testASensitiveExcerptGoesToTheCardAndDeviceOnlyIsNeverRead() async throws {
        let (store, model) = makeStore(connections: PersonalFakeConnections(permission: .denied))
        store.agentRequests.model = model
        let settings = PersonalSourceSettings(defaults: defaults())
        settings.messages = true
        let shared = sharedStore()
        try shared.add(sender: "Sarah", text: "I'm free Friday after 7, the gate code is 4411", date: Date().addingTimeInterval(-3600))
        store.agentQuestions.sources = StoreAgentQuestionSources(store: store, docs: nil, includeCalendar: false,
                                                                 personal: [SharedMessagesQuestionSource(store: shared, settings: settings)])
        store.state.allowAgentQuestions(muse.recipient, once: false)
        async let pending = store.agentQuestions.ask(.init(requester: muse, question: "When is Sarah free?", purpose: "planning dinner"))
        try await waitUntil { if case .ready? = store.agentRequests.current?.phase { true } else { false } }
        let card = try XCTUnwrap(store.agentRequests.current)
        XCTAssertEqual(card.subject?.title, "your messages with Sarah")
        XCTAssertEqual(card.subject?.item.level, .sensitive)
        XCTAssertTrue(card.subject?.text.contains("Friday after 7") == true, "The card shows exactly the excerpt")
        await store.agentRequests.share(.init(answer: "Friday after 7", excerpt: ""))
        let answer = await pending
        XCTAssertEqual(answer, .answered("Friday after 7"), "Only what the owner shared leaves")

        // Device only: never read for an agent, only counted.
        settings.messagesLevel = .deviceOnly
        let before = model.inputs.value.count
        let second = await store.agentQuestions.ask(.init(requester: muse, question: "When is Sarah free?", purpose: "planning dinner"))
        XCTAssertEqual(second, .notFound)
        XCTAssertFalse(model.inputs.value.dropFirst(before).joined().contains("4411"))
        let journal = try await store.agentRequests.journal.snapshot()
        let record = try XCTUnwrap(journal.last)
        XCTAssertEqual(record.withheld, "Not read: 1 Device only Messages excerpt.")

        // Off: nothing at all.
        settings.messages = false
        let third = await store.agentQuestions.ask(.init(requester: muse, question: "When is Sarah free?", purpose: "planning dinner"))
        XCTAssertEqual(third, .notFound)
        let after = try await store.agentRequests.journal.snapshot()
        XCTAssertNil(after.last?.withheld)
    }

    // MARK: Location

    func testLocationNeedsTheSwitchPermissionAndAPlaceQuestion() async {
        let settings = PersonalSourceSettings(defaults: defaults())
        let locator = FakeLocator(permission: .allowed)
        let source = LocationQuestionSource(settings: settings, locator: locator)
        let off = await source.sources(for: "Find a spot near me", now: now)
        XCTAssertTrue(off.isEmpty)
        settings.location = true
        let on = await source.sources(for: "Find a spot near me", now: now)
        XCTAssertEqual(on.count, 1)
        XCTAssertEqual(on.first?.item, .location); XCTAssertEqual(on.first?.item.level, .sensitive)
        XCTAssertTrue(on.first?.text.contains("Mission District") == true)
        let unrelated = await source.sources(for: "When is Sarah free?", now: now)
        XCTAssertTrue(unrelated.isEmpty, "Only a question about where you are reads it")
        XCTAssertEqual(locator.reads, 1)
        locator.permission = .denied
        let denied = await source.sources(for: "What's nearby?", now: now)
        XCTAssertTrue(denied.isEmpty)
        XCTAssertEqual(locator.reads, 1, "Without Apple's permission it isn't read")
        XCTAssertEqual(CoarsePlace(latitude: 37.76, longitude: -122.42, area: nil).text, "About 37.76, -122.42, accurate to roughly a kilometer.")
    }

    // MARK: Reminders and Contacts

    func testRemindersAndContactsOnlyWhileConnected() async {
        let connections = PersonalFakeConnections(permission: .allowed)
        let (store, _) = makeStore(connections: connections)
        let sources = StoreAgentQuestionSources(store: store, docs: nil, includeCalendar: true, personal: [])
        var kinds = await sources.sources(for: "When is Sarah free?").map(\.item.ref.id)
        XCTAssertEqual(Set(kinds), ["calendar", "reminders", "contacts"])
        XCTAssertEqual(connections.queries, ["Sarah"], "Contacts are looked up by the name asked about, nothing else")
        store.state.markDisconnected(.reminders); store.state.markDisconnected(.contacts)
        kinds = await sources.sources(for: "When is Sarah free?").map(\.item.ref.id)
        XCTAssertEqual(kinds, ["calendar"], "Disconnected in KemoSabe contributes nothing")
        store.state.markConnected(.reminders); store.state.markConnected(.contacts)
        connections.access = .denied
        let denied = await sources.sources(for: "When is Sarah free?")
        XCTAssertTrue(denied.isEmpty, "Without Apple's permission nothing is read")
        connections.access = .allowed
        let left = await StoreAgentQuestionSources(store: store, docs: nil, includeCalendar: false, personal: []).sources(for: "When is Sarah free?")
        XCTAssertTrue(left.isEmpty)
        XCTAssertEqual(AgentQuestionDesk.readSummary([.init(item: .connector(.reminders), title: "", text: "", target: nil),
                                                      .init(item: .connector(.contacts), title: "", text: "", target: nil)]), "your reminders and contacts")
    }

    // MARK: The policy

    func testLevelsOfTheNewItems() {
        let grantAll = RecipientGrant(recipient: muse.recipient, kinds: [.textMessage, .location, .connector], purpose: .agentQuestion)
        let sensitive = ContextItem.textMessage("mac:1", level: .sensitive), deviceOnly = ContextItem.textMessage("mac:2", level: .deviceOnly)
        for item in [sensitive, .location] {
            XCTAssertTrue(ContextPolicy.allows(item, to: .appleOnDevice))
            XCTAssertTrue(ContextPolicy.allows(item, to: .applePrivateCloud))
            XCTAssertFalse(ContextPolicy.allows(item, to: muse.recipient, purpose: .agentQuestion, grants: [grantAll]), "A kind grant never opens a Sensitive item")
            XCTAssertTrue(ContextPolicy.allows(item, to: muse.recipient, purpose: .agentQuestion,
                                               grants: [RecipientGrant(recipient: muse.recipient, items: [item.ref], purpose: .agentQuestion)]))
        }
        XCTAssertTrue(ContextPolicy.allows(deviceOnly, to: .appleOnDevice))
        XCTAssertFalse(ContextPolicy.allows(deviceOnly, to: .applePrivateCloud))
        XCTAssertFalse(ContextPolicy.allows(deviceOnly, to: muse.recipient, purpose: .agentQuestion,
                                            grants: [RecipientGrant(recipient: muse.recipient, items: [deviceOnly.ref], purpose: .agentQuestion)]))
        // Reminders and Contacts are Personal, like Calendar: an agent's Allow always covers them.
        XCTAssertEqual(ContextItem.connector(.reminders).level, .personal)
        XCTAssertTrue(ContextPolicy.allows(.connector(.contacts), to: muse.recipient, purpose: .agentQuestion, grants: [grantAll]))
        XCTAssertFalse(ContextPolicy.allows(.connector(.contacts), to: muse.recipient, purpose: .agentQuestion))
    }

    // MARK: Helpers

    private func defaults() -> UserDefaults {
        let name = "personal-sources-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
    private func sharedStore() -> SharedMessagesStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        folders.append(folder)
        return SharedMessagesStore(folder: folder.appendingPathComponent("shared-messages"))
    }
    private func makeStore(connections: PersonalFakeConnections) -> (AppStore, QuestionFakeModel) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        folders.append(folder)
        let store = AppStore(repository: .init(url: folder.appendingPathComponent("state.json")), provider: APIUnavailableLocal(),
                             nativeConnections: connections, apiKeys: MemoryAPIKeys())
        let model = QuestionFakeModel()
        store.agentQuestions.model = model
        return (store, model)
    }
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < end else { return XCTFail("Timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// Apple's permissions and reads, faked: no privacy database or real data is touched.
final class PersonalFakeConnections: NativeConnectionClient, @unchecked Sendable {
    private let lock = NSLock()
    private var current: ConnectorPermission
    private var asked: [String] = []
    init(permission: ConnectorPermission) { current = permission }
    var access: ConnectorPermission {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
    var queries: [String] { lock.withLock { asked } }
    func permission(_ id: ConnectorID) -> ConnectorPermission { access }
    func request(_ id: ConnectorID) async throws -> Bool { false }
    func read(_ id: ConnectorID, query: String?) async throws -> String { "Today: 6:00 PM: Climbing." }
    func readAttributed(_ id: ConnectorID, query: String?) async throws -> ConnectorReadResult {
        if let query { lock.withLock { asked.append(query) } }
        let fields: [String: String] = id == .contacts ? ["name": "Sarah Chen", "phone": "+1 415 555 0100"] : ["title": "Book dinner", "due": "2026-09-30"]
        return .init(connector: id, fetchedAt: Date(), records: [.init(fields: fields)], totalCount: 1)
    }
}

@MainActor final class FakeLocator: CoarseLocating {
    var permission: ConnectorPermission
    private(set) var reads = 0
    init(permission: ConnectorPermission) { self.permission = permission }
    func request() async -> ConnectorPermission { permission }
    func current() async throws -> CoarsePlace {
        reads += 1
        return .init(latitude: 37.76, longitude: -122.42, area: "Mission District, San Francisco")
    }
}

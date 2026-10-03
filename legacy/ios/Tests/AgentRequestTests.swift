import XCTest
#if os(macOS)
@testable import KemoSabeMac
#else
@testable import KemoSabe
#endif

/// Agent-on-agent requests (design/CONTEXT-HARNESS.md#agent-requests): extraction on this device,
/// the card's decisions, only the slice leaving, and the journal. No model, network, or peer is used.
final class AgentRequestTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)
    private let muse = AgentRequester(recipient: .externalAgent("com.meta.muse"), name: "Muse")
    private let thread = """
        Sarah: Are we still on for Friday?
        You: I picked the restaurant for Friday: Osteria Lucia on Valencia, 7:30. Booked a table for two.
        Sarah: Perfect.
        You: My sister's new number is 555 0100.
        """

    // MARK: The extractor's output contract

    func testExtractionKeepsOnlyWhatTheSourceSupports() {
        let quote = "I picked the restaurant for Friday: Osteria Lucia on Valencia, 7:30."
        XCTAssertEqual(AgentExtractor.validate(.init(found: true, answer: "Osteria Lucia on Valencia at 7:30", excerpt: quote), source: thread),
                       .found(.init(answer: "Osteria Lucia on Valencia at 7:30", excerpt: quote)))
        // A paraphrased quote becomes the source line it came from: the excerpt is always the source's words.
        let paraphrase = AgentExtractor.validate(.init(found: true, answer: "Osteria Lucia",
            excerpt: "picked the restaurant for Friday, Osteria Lucia on Valencia"), source: thread)
        XCTAssertEqual(paraphrase, .found(.init(answer: "Osteria Lucia",
            excerpt: "You: I picked the restaurant for Friday: Osteria Lucia on Valencia, 7:30. Booked a table for two.")))
        // A made-up quote shares nothing.
        XCTAssertEqual(AgentExtractor.validate(.init(found: true, answer: "Chez Panisse", excerpt: "We booked Chez Panisse in Berkeley"), source: thread), .notFound)
        // An answer the source doesn't support is replaced by the excerpt.
        XCTAssertEqual(AgentExtractor.validate(.init(found: true, answer: "Probably somewhere downtown maybe", excerpt: quote), source: thread),
                       .found(.init(answer: quote, excerpt: quote)))
        XCTAssertEqual(AgentExtractor.validate(.init(found: false, answer: "x", excerpt: "y"), source: thread), .notFound)
        XCTAssertEqual(AgentExtractor.validate(.init(found: true, answer: "  ", excerpt: quote), source: thread), .notFound)
        // Everything shared is short.
        let long = String(repeating: "Osteria Lucia Valencia ", count: 40)
        if case .found(let slice) = AgentExtractor.validate(.init(found: true, answer: long, excerpt: quote), source: thread + "\n" + long) {
            XCTAssertLessThanOrEqual(slice.answer.count, AgentExtractor.maxAnswer)
        } else { XCTFail("Supported long answer is kept, bounded") }
    }

    func testTheModelSeesAtMostAFocusedWindowOfALongTarget() {
        let filler = (0..<400).map { "Line \($0) about the hike and the weather." }.joined(separator: "\n")
        let text = filler + "\nYou: I picked the restaurant for Friday: Osteria Lucia.\n" + filler
        let focused = AgentExtractor.focus(text, on: "the restaurant you picked for Friday")
        XCTAssertLessThanOrEqual(focused.count, AgentExtractor.maxSource)
        XCTAssertTrue(focused.contains("Osteria Lucia"))
    }

    func testExtractionRunsOnlyOnThisDeviceAndNeverOnSecretItems() async throws {
        let model = FakeExtractor(draft: .init(found: true, answer: "Osteria Lucia", excerpt: "Osteria Lucia on Valencia"))
        let subject = AgentRequestSubject(item: .conversation(UUID(), level: .sensitive), title: "your conversation with Sarah", text: thread)
        let result = try await AgentExtractor.run(model, lookingFor: "the restaurant", subject: subject)
        XCTAssertEqual(result, .found(.init(answer: "Osteria Lucia", excerpt: "Osteria Lucia on Valencia")))
        let secret = AgentRequestSubject(item: .conversation(UUID(), level: .secret), title: "x", text: thread)
        do { _ = try await AgentExtractor.run(model, lookingFor: "the restaurant", subject: secret); XCTFail("Secret is never read") }
        catch { XCTAssertEqual(error as? AgentExtractionError, .notOnDevice) }
        XCTAssertEqual(model.calls.value, 1)
    }

    #if DEBUG
    func testTheFixtureStandInIsDeterministic() async throws {
        let archive = await AgentRequestFixture.sarahConversation(now: now)
        let text = archive.messages.map { "\($0.role): \($0.text)" }.joined(separator: "\n")
        let first = try await FixtureAgentExtractionModel().extract(lookingFor: "the restaurant you picked for Friday", from: text)
        let second = try await FixtureAgentExtractionModel().extract(lookingFor: "the restaurant you picked for Friday", from: text)
        XCTAssertEqual(first, second)
        XCTAssertEqual(AgentExtractor.validate(first, source: text),
                       .found(.init(answer: "Osteria Lucia on Valencia, 7:30.", excerpt: "You: I picked the restaurant for Friday: Osteria Lucia on Valencia, 7:30.")))
        let missing = try await FixtureAgentExtractionModel().extract(lookingFor: "their passport number", from: text)
        XCTAssertFalse(missing.found)
    }
    #endif

    // MARK: Only the slice leaves

    func testTheEnvelopeCarriesNoPlaintext() async throws {
        let disclosure = AgentDisclosure(ownerID: UUID()), request = makeRequest()
        let slice = AgentSlice(answer: "Osteria Lucia on Valencia", excerpt: "I picked the restaurant for Friday")
        let envelope = try await disclosure.makeEnvelope(slice, level: .sensitive, for: request, grant: AgentDisclosure.grant(for: request, now: now), now: now)
        var dumped = ""; dump(envelope, to: &dumped)
        for rendering in [envelope.description, envelope.debugDescription, String(describing: envelope), String(reflecting: envelope), dumped] {
            XCTAssertFalse(rendering.contains("Osteria"), rendering)
            XCTAssertFalse(rendering.contains("restaurant"), rendering)
        }
        XCTAssertLessThanOrEqual(envelope.expiresAt.timeIntervalSince(now), AgentDisclosure.lifetime)
        let opened = try await disclosure.open(envelope, as: muse.recipient, now: now)
        XCTAssertEqual(opened, slice)
    }

    func testTheShareIsSingleUseShortLivedAndForTheRequesterOnly() async throws {
        let disclosure = AgentDisclosure(ownerID: UUID()), request = makeRequest()
        let slice = AgentSlice(answer: "Osteria Lucia", excerpt: "")
        let grant = AgentDisclosure.grant(for: request, now: now)
        let envelope = try await disclosure.makeEnvelope(slice, level: .personal, for: request, grant: grant, now: now)
        do { _ = try await disclosure.makeEnvelope(slice, level: .personal, for: request, grant: grant, now: now); XCTFail("The grant is spent") }
        catch { XCTAssertEqual(error as? AgentRequestError, .invalidGrant) }
        do { _ = try await disclosure.open(envelope, as: .externalAgent("someone.else"), now: now); XCTFail("Another recipient") }
        catch { XCTAssertEqual(error as? ContextBrokerError, .unauthorized) }

        let second = makeRequest()
        let late = try await disclosure.makeEnvelope(slice, level: .personal, for: second, grant: AgentDisclosure.grant(for: second, now: now), now: now)
        do { _ = try await disclosure.open(late, as: muse.recipient, now: now.addingTimeInterval(AgentDisclosure.lifetime + 1)); XCTFail("Expired") }
        catch { XCTAssertEqual(error as? ContextBrokerError, .expired) }

        let third = makeRequest()
        let once = try await disclosure.makeEnvelope(slice, level: .personal, for: third, grant: AgentDisclosure.grant(for: third, now: now), now: now)
        _ = try await disclosure.open(once, as: muse.recipient, now: now)
        // Opening revokes the slice's records, so a second open finds nothing to validate.
        do { _ = try await disclosure.open(once, as: muse.recipient, now: now); XCTFail("Opened once") }
        catch { XCTAssertEqual(error as? ContextBrokerError, .revoked) }

        // A long-lived or reusable grant can't stand in for the Share tap.
        let fourth = makeRequest()
        var standing = AgentDisclosure.grant(for: fourth, now: now); standing.singleUse = false
        do { _ = try await disclosure.makeEnvelope(slice, level: .personal, for: fourth, grant: standing, now: now); XCTFail("Not single-use") }
        catch { XCTAssertEqual(error as? AgentRequestError, .invalidGrant) }
        var lasting = AgentDisclosure.grant(for: fourth, now: now); lasting.expiresAt = now.addingTimeInterval(86_400)
        do { _ = try await disclosure.makeEnvelope(slice, level: .personal, for: fourth, grant: lasting, now: now); XCTFail("Too long") }
        catch { XCTAssertEqual(error as? AgentRequestError, .invalidGrant) }
    }

    func testDeviceOnlyAndSecretAreNeverShared() async throws {
        let disclosure = AgentDisclosure(ownerID: UUID())
        for level in [PrivacyLevel.deviceOnly, .secret] {
            let request = makeRequest()
            do {
                _ = try await disclosure.makeEnvelope(.init(answer: "Osteria Lucia", excerpt: ""), level: level, for: request,
                                                      grant: AgentDisclosure.grant(for: request, now: now), now: now)
                XCTFail("\(level) must not be shared")
            } catch { XCTAssertEqual(error as? AgentRequestError, .refused(level)) }
        }
        // Credential material is kept on this device whatever level the card had.
        let request = makeRequest()
        do {
            _ = try await disclosure.makeEnvelope(.init(answer: "-----BEGIN PRIVATE KEY-----\nabc", excerpt: ""), level: .open, for: request,
                                                  grant: AgentDisclosure.grant(for: request, now: now), now: now)
            XCTFail("Key material stays here")
        } catch { XCTAssertEqual(error as? AgentRequestError, .refused(.open)) }
    }

    // MARK: The card and the journal

    @MainActor func testShareSendsOnlyTheSliceAndIsJournaled() async throws {
        let (store, folder) = makeStore(); defer { try? FileManager.default.removeItem(at: folder) }
        let archive = seedSarah(store)
        let model = FakeExtractor(draft: .init(found: true, answer: "Osteria Lucia on Valencia, 7:30",
                                               excerpt: "I picked the restaurant for Friday: Osteria Lucia on Valencia, 7:30."))
        store.agentRequests.model = model
        let transport = LoopbackAgentTransport()
        store.agentRequests.receive(makeRequest(target: .conversationWith("Sarah")), replyTo: transport)
        XCTAssertEqual(store.agentRequests.current?.subject?.title, "your conversation with Sarah")
        XCTAssertEqual(store.agentRequests.current?.subject?.item.ref, .init(.conversation, archive.id))
        try await waitForReady(store)
        guard case .ready(let slice) = store.agentRequests.current?.phase else { return XCTFail("Ready") }
        // The person trims it before sharing.
        await store.agentRequests.share(.init(answer: "Osteria Lucia, 7:30", excerpt: slice.excerpt))
        XCTAssertEqual(store.agentRequests.current?.phase, .shared(.init(answer: "Osteria Lucia, 7:30", excerpt: slice.excerpt)))
        let received = await transport.received
        XCTAssertEqual(received.count, 1)
        let text = try XCTUnwrap(received.first?.text)
        XCTAssertTrue(text.contains("Osteria Lucia, 7:30"))
        XCTAssertFalse(text.contains("555 0100"), "The rest of the conversation stays here")
        XCTAssertFalse(text.contains("Perfect"))
        let journal = try await store.agentRequests.journal.snapshot()
        XCTAssertEqual(journal.count, 1)
        XCTAssertEqual(journal.first?.outcome, .shared)
        XCTAssertEqual(journal.first?.requester, "Muse")
        XCTAssertEqual(journal.first?.lookingFor, "the restaurant you picked for Friday")
        XCTAssertEqual(journal.first?.target, "your conversation with Sarah")
        XCTAssertEqual(journal.first?.shared, text)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.agentRequestJournalURL.path))
        store.agentRequests.dismiss()
        XCTAssertNil(store.agentRequests.current)
    }

    @MainActor func testDeclineSendsNothingAndIsJournaled() async throws {
        let (store, folder) = makeStore(); defer { try? FileManager.default.removeItem(at: folder) }
        seedSarah(store)
        store.agentRequests.model = FakeExtractor(draft: .init(found: true, answer: "Osteria Lucia", excerpt: "Osteria Lucia on Valencia"))
        let transport = LoopbackAgentTransport()
        store.agentRequests.receive(makeRequest(target: .conversationWith("Sarah")), replyTo: transport)
        try await waitForReady(store)
        await store.agentRequests.decline()
        XCTAssertEqual(store.agentRequests.current?.phase, .declined)
        let received = await transport.received
        XCTAssertEqual(received.map(\.text), [nil])
        let journal = try await store.agentRequests.journal.snapshot()
        XCTAssertEqual(journal.map(\.outcome), [.declined]); XCTAssertNil(journal.first?.shared)
    }

    @MainActor func testDeviceOnlyTargetsAreRefusedWithoutBeingRead() async throws {
        let (store, folder) = makeStore(); defer { try? FileManager.default.removeItem(at: folder) }
        let archive = seedSarah(store)
        store.setConversationPrivacy(.deviceOnly, for: archive.id)
        let model = FakeExtractor(draft: .init(found: true, answer: "Osteria Lucia", excerpt: "Osteria Lucia on Valencia"))
        store.agentRequests.model = model
        let transport = LoopbackAgentTransport()
        store.agentRequests.receive(makeRequest(target: .conversation(archive.id)), replyTo: transport)
        XCTAssertEqual(store.agentRequests.current?.phase, .refused(.deviceOnly))
        XCTAssertEqual(model.calls.value, 0, "Nothing is read")
        await store.agentRequests.share(.init(answer: "Osteria Lucia", excerpt: ""))
        XCTAssertEqual(store.agentRequests.current?.phase, .refused(.deviceOnly), "Share does nothing")
        await store.agentRequests.decline()
        let received = await transport.received
        XCTAssertEqual(received.map(\.text), [nil])
        let journal = try await store.agentRequests.journal.snapshot()
        XCTAssertEqual(journal.map(\.outcome), [.refused])
    }

    @MainActor func testNotFoundAndInvalidRequests() async throws {
        let (store, folder) = makeStore(); defer { try? FileManager.default.removeItem(at: folder) }
        seedSarah(store)
        store.agentRequests.model = FakeExtractor(draft: .init(found: false, answer: "", excerpt: ""))
        store.agentRequests.receive(makeRequest(target: .conversationWith("Nobody")), replyTo: LoopbackAgentTransport())
        XCTAssertEqual(store.agentRequests.current?.phase, .notFound)
        XCTAssertNil(store.agentRequests.current?.subject)
        await store.agentRequests.decline(); store.agentRequests.dismiss()
        store.agentRequests.receive(makeRequest(target: .conversationWith("Sarah")), replyTo: LoopbackAgentTransport())
        try await waitUntil { store.agentRequests.current?.phase == .notFound }
        await store.agentRequests.decline(); store.agentRequests.dismiss()
        // An agent can't pose as this device, and must say what it's looking for.
        store.agentRequests.receive(.init(requester: .init(recipient: .appleOnDevice, name: "Me"), target: .conversationWith("Sarah"),
                                          lookingFor: "x", channel: .appLink), replyTo: LoopbackAgentTransport())
        store.agentRequests.receive(.init(requester: muse, target: .conversationWith("Sarah"), lookingFor: " ", channel: .appLink),
                                    replyTo: LoopbackAgentTransport())
        XCTAssertNil(store.agentRequests.current)
        let journal = try await store.agentRequests.journal.snapshot()
        XCTAssertEqual(journal.map(\.outcome), [.notFound, .notFound])
    }

    // MARK: Helpers

    private func makeRequest(target: AgentRequestTarget = .conversationWith("Sarah")) -> AgentRequest {
        .init(requester: muse, target: target, lookingFor: "the restaurant you picked for Friday", receivedAt: now, channel: .appLink)
    }
    @MainActor private func makeStore() -> (AppStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (AppStore(repository: .init(url: folder.appendingPathComponent("state.json")), provider: APIUnavailableLocal(),
                         apiKeys: MemoryAPIKeys()), folder)
    }
    @MainActor @discardableResult private func seedSarah(_ store: AppStore) -> ConversationArchive {
        let archive = ConversationArchive(model: "Messages", recipient: nil, messages: thread.split(separator: "\n").map { line in
            let parts = line.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            return ChatMessage(role: parts[0], text: parts[1])
        })
        store.state.conversationArchives = [archive]; store.save()
        return archive
    }
    @MainActor private func waitForReady(_ store: AppStore) async throws {
        try await waitUntil {
            switch store.agentRequests.current?.phase {
            case .ready?: return true
            default: return false
            }
        }
    }
    @MainActor private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < end else { return XCTFail("Timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private struct FakeExtractor: AgentExtractionModel {
    let draft: AgentExtractionDraft
    let calls = Counter()
    var isAvailable: Bool { true }
    func extract(lookingFor: String, from text: String) async throws -> AgentExtractionDraft {
        calls.increment()
        return draft
    }
}

import Network
import XCTest
@testable import KemoSabeMac

/// Your Mac's agents from iPhone end to end on this Mac (design/CONTEXT-HARNESS.md#your-macs-agents-from-iphone): the Mac's
/// `KemoSabeRelay` (listener, pairing, `KemoSabeHandoff.startTurn`) and the phone's side (`MacRelayClient`,
/// `MacRelayPhoneSession`, its own `AgentQuestionDesk`) over TLS with pre-shared keys on localhost. A fake
/// agent stands in for Claude Code or Codex and calls `ask_kemosabe` the way the MCP bridge does; a fake extractor
/// stands in for the phone's on-device model. Nothing is advertised on the network.
@MainActor final class MacRelayLoopbackTests: XCTestCase {
    private var folders: [URL] = []
    private var relay: KemoSabeRelay!
    private var handoff: KemoSabeHandoff!
    private var claudes: [RelayFakeClaude] = []
    private let phone = UUID()

    override func setUp() async throws {
        let folder = temporaryFolder()
        let defaults = UserDefaults(suiteName: "kemo-relay-tests-" + UUID().uuidString)!
        handoff = KemoSabeHandoff()
        relay = KemoSabeRelay(defaults: defaults, folder: folder, handoff: handoff)
        relay.advertise = false
        relay.nameOverride = "Test Mac"
        relay.turns.claudeOverride = .signedIn
        handoff.makeSession = { [unowned self] record, chat in
            let claude = RelayFakeClaude(chat: chat, resume: record.sessionID, relay: self.relay, provider: record.provider)
            self.claudes.append(claude)
            return claude
        }
    }
    override func tearDown() async throws {
        relay.setEnabled(false)
        relay = nil; handoff = nil; claudes = []
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
    }

    func testPairChatAskKemoSabeOnThePhoneStopAndRefuseStrangers() async throws {
        // On: a code, and a listener that accepts only that code's key.
        relay.setEnabled(true)
        let offer = try XCTUnwrap(relay.offer)
        XCTAssertTrue(offer.isOpen())
        try await waitUntil { self.relay.port != nil }
        XCTAssertEqual(relay.invite?.url.host(), "pair-mac")

        // A wrong code never finishes the handshake.
        let wrong = await transport().open(mac: nil, identity: MacRelay.pairingIdentity, key: MacRelay.Keys.pairing(code: MacRelay.PairingCode.make()))
        XCTAssertThrowsError(try wrong.get(), "A code the Mac isn't showing")

        // Pairing with the code gives the phone its own key, and the Mac lists the phone.
        let pairing = try await transport().open(mac: nil, identity: MacRelay.pairingIdentity, key: MacRelay.Keys.pairing(code: offer.code)).get()
        let paired = try await MacRelayPairing.pair(over: pairing, phone: phone, name: "Test iPhone", code: offer.code).get()
        XCTAssertEqual(paired.mac, relay.mac); XCTAssertEqual(paired.name, "Test Mac"); XCTAssertEqual(paired.key.count, 32)
        XCTAssertEqual(relay.phones.map(\.id), [phone]); XCTAssertEqual(relay.phones.first?.key, paired.key)
        XCTAssertEqual(relay.phones.first?.name, "Test iPhone")
        XCTAssertEqual(relay.offer?.used, true, "Single-use")
        let saved = relay.folder.appendingPathComponent("phones.json")
        let mode = try FileManager.default.attributesOfItem(atPath: saved.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600, "Keys on disk are the owner's only")
        try await waitUntil { self.relay.port != nil }

        // The same code again, a wrong key, and a phone the Mac doesn't know are all refused.
        let reuse = await transport().open(mac: nil, identity: MacRelay.pairingIdentity, key: MacRelay.Keys.pairing(code: offer.code))
        XCTAssertThrowsError(try reuse.get(), "The code was used")
        let stolen = await transport().open(mac: nil, identity: MacRelay.identity(phone: phone), key: MacRelay.Keys.make())
        XCTAssertThrowsError(try stolen.get(), "Right phone, wrong key")
        let stranger = await transport().open(mac: nil, identity: MacRelay.identity(phone: UUID()), key: paired.key)
        XCTAssertThrowsError(try stranger.get(), "A phone that never paired")

        // The paired phone connects and hears about Claude Code on the Mac.
        let store = makePhoneStore()
        let session = MacRelayPhoneSession()
        session.store = store
        let client = try await connect(key: paired.key, session: session)
        XCTAssertEqual(client.welcome?.name, "Test Mac"); XCTAssertEqual(client.welcome?.claude, .signedIn)
        try await waitUntil { self.relay.connected.contains(self.phone) }

        // A turn: Claude asks KemoSabe; the PHONE's KemoSabe answers from the phone's data, on its card.
        XCTAssertTrue(session.send("ask: find a date spot for Sarah and I tonight", store: store))
        XCTAssertEqual(store.handoffWorking, ChatHandoff.claude)
        try await waitUntil { store.conversationMessages.last?.handoff?.part == .result }
        let parts = store.conversationMessages.compactMap { message in message.handoff.map { ($0.part, message.text, $0) } }
        XCTAssertEqual(parts.map(\.0), [.task, .answer, .result])
        XCTAssertEqual(parts[1].1, "After 7 tonight"); XCTAssertEqual(parts[1].2.shared, "After 7 tonight")
        XCTAssertEqual(parts[1].2.localCaption, "On this Mac · Apple on-device", "Answered where the phone's store is (this test host is a Mac)")
        XCTAssertEqual(parts[2].1, "Sarah’s free after 7 (KemoSabe said: After 7 tonight). Book Osteria Lucia for 7:30.")
        XCTAssertEqual(parts[2].2.session, "relay-session-1", "Claude's session comes back with the reply")
        XCTAssertNil(store.handoffWorking)
        let chat = try XCTUnwrap(store.agentChat.id)
        XCTAssertEqual(claudes.first?.chat, chat, "The Mac ran the phone's chat ID")
        XCTAssertEqual(claudes.first?.asked?.status, "answered")
        XCTAssertFalse(handoff.running.contains(chat))
        XCTAssertEqual(relay.turns.sessions[chat], "relay-session-1", "The Mac keeps the chat's --resume handle")
        let journal = try await store.agentRequests.journal.snapshot()
        XCTAssertEqual(journal.last?.shared, "After 7 tonight", "The phone journals what it shared")

        // The next message resumes Claude's session; stopping it ends the turn as stopped.
        XCTAssertTrue(session.send("slow: and a table for two", store: store))
        try await waitUntil { store.handoffStreaming == "Looking" }
        XCTAssertEqual(claudes.last?.resume, "relay-session-1")
        session.stop(store: store)
        try await waitUntil { store.handoffWorking == nil }
        XCTAssertEqual(store.conversationMessages.last?.handoff?.part, .status)
        XCTAssertEqual(store.conversationMessages.last?.text, "Claude stopped.")
        XCTAssertTrue(claudes.last?.stopped == true)

        // Removing the phone closes it out: its key no longer works.
        relay.remove(phone)
        try await waitUntil { !client.isConnected }
        try await waitUntil { self.relay.port != nil || self.relay.phones.isEmpty }
        XCTAssertTrue(relay.phones.isEmpty)
    }

    func testAPhoneThatReconnectsGetsTheReplyItMissed() async throws {
        let key = try await pairedPhone()
        let store = makePhoneStore()
        let session = MacRelayPhoneSession()
        session.store = store
        let first = try await connect(key: key, session: session)

        XCTAssertTrue(session.send("slow: plan Saturday", store: store))
        try await waitUntil { store.handoffStreaming == "Looking" }
        // The phone goes to the background: its connection drops mid-turn, and Claude finishes meanwhile.
        first.close()
        try await waitUntil { self.relay.connected.isEmpty }
        claudes.last?.finish("Saturday: farmers market at 9, then the beach.")
        try await waitUntil { !self.handoff.running.contains(store.agentChat.id!) }
        XCTAssertEqual(store.conversationMessages.last?.handoff?.part, .task, "Nothing reached the phone yet")

        // Back: the phone reconnects and asks for the turn.
        _ = try await connect(key: key, session: session)
        try await waitUntil { store.conversationMessages.last?.handoff?.part == .result }
        XCTAssertEqual(store.conversationMessages.last?.text, "Saturday: farmers market at 9, then the beach.")
        XCTAssertNil(store.handoffWorking)
    }

    func testAReplyThroughTheMacLandsInItsOwnChatAfterThePhoneSwitchesChats() async throws {
        let key = try await pairedPhone()
        let store = makePhoneStore()
        let session = MacRelayPhoneSession()
        session.store = store
        _ = try await connect(key: key, session: session)
        XCTAssertTrue(session.send("slow: plan Saturday", store: store))
        let chat = try XCTUnwrap(store.agentChat.id)
        let conversation = store.conversationID(for: store.currentConversationSlot)
        try await waitUntil { store.handoffStreaming == "Looking" }

        // Another chat on the phone while Claude works on the Mac.
        store.newConversation()
        XCTAssertNil(store.handoffWorking); XCTAssertEqual(store.handoffStreaming, "")
        XCTAssertNil(session.running(in: store))
        claudes.last?.finish("Saturday: farmers market at 9.")
        try await waitUntil { session.turns.isEmpty }
        XCTAssertTrue(store.conversationMessages.isEmpty, "Nothing lands in the chat on screen")
        let saved = try XCTUnwrap(store.state.conversationArchives?.first { $0.id == conversation })
        XCTAssertEqual(saved.messages.compactMap(\.handoff?.part), [.task, .result])
        XCTAssertEqual(saved.messages.last?.text, "Saturday: farmers market at 9.")
        XCTAssertEqual(saved.messages.last?.handoff?.id, chat)
        XCTAssertEqual(saved.messages.last?.handoff?.session, "relay-session-1")
    }

    func testUnpairingOnThePhoneWaitsForTheMacThenRemovesItThere() async throws {
        let key = try await pairedPhone()
        let defaults = UserDefaults(suiteName: "kemo-relay-unpair-" + UUID().uuidString)!
        let unpairing = MacRelayUnpairing(defaults: defaults)
        var confirmed = 0
        unpairing.onConfirmed = { confirmed += 1 }

        // Not connected: the unpair waits (across relaunches), and the Mac still knows the phone.
        unpairing.request(over: nil)
        XCTAssertTrue(unpairing.pending)
        XCTAssertTrue(MacRelayUnpairing(defaults: defaults).pending, "Still pending after a relaunch")
        XCTAssertEqual(relay.phones.map(\.id), [phone])
        XCTAssertEqual(confirmed, 0, "The key is kept until the Mac confirms")

        // The next connection sends it first; the Mac confirms, removes the phone, and forgets its key.
        let session = MacRelayPhoneSession()
        session.store = makePhoneStore()
        let client = try await connect(key: key, session: session)
        XCTAssertTrue(unpairing.connected(client))
        try await waitUntil { confirmed == 1 }
        XCTAssertFalse(unpairing.pending)
        XCTAssertFalse(MacRelayUnpairing(defaults: defaults).pending)
        XCTAssertTrue(relay.phones.isEmpty)
        XCTAssertEqual(KemoSabeRelay.load([MacRelayPairedPhone].self, from: relay.folder.appendingPathComponent("phones.json")), [])
        try await waitUntil { !client.isConnected }
        XCTAssertFalse(unpairing.connected(client), "Nothing pending any more")

        // The listener restarted without its key: the old key no longer opens a connection.
        relay.newCode()
        try await waitUntil { self.relay.port != nil }
        let again = await transport().open(mac: relay.mac, identity: MacRelay.identity(phone: phone), key: key)
        XCTAssertThrowsError(try again.get(), "The phone's key was removed")
    }

    func testUnpairingWhileConnectedStopsThePhonesTurnAndIsConfirmedAtOnce() async throws {
        let key = try await pairedPhone()
        let store = makePhoneStore()
        let session = MacRelayPhoneSession()
        session.store = store
        let client = try await connect(key: key, session: session)
        XCTAssertTrue(session.send("slow: plan Saturday", store: store))
        try await waitUntil { store.handoffStreaming == "Looking" }

        let unpairing = MacRelayUnpairing(defaults: UserDefaults(suiteName: "kemo-relay-unpair-" + UUID().uuidString)!)
        var confirmed = false
        unpairing.onConfirmed = { confirmed = true }
        unpairing.request(over: client)
        try await waitUntil { confirmed }
        XCTAssertTrue(claudes.last?.stopped == true, "The phone's turn stopped on the Mac")
        XCTAssertTrue(relay.phones.isEmpty)
        try await waitUntil { self.relay.connected.isEmpty }
    }

    func testAnUnpairWithoutTheKeysProofIsIgnored() async throws {
        let key = try await pairedPhone()
        let channel = try await transport().open(mac: relay.mac, identity: MacRelay.identity(phone: phone), key: key).get()
        var welcomed = false, unpaired = false, nonce = ""
        let phone = self.phone
        channel.onFrame = { frame in
            switch frame.type {
            case .challenge:
                nonce = frame.nonce ?? ""
                channel.send(.make(.hello) { $0.v = MacRelay.version; $0.phone = phone; $0.name = "Test iPhone"
                    $0.proof = MacRelay.Keys.proof(key: key, nonce: frame.nonce ?? "", phone: phone, kind: .hello) })
            case .welcome:
                welcomed = true
                // A proof for another nonce, then one made with another key, then another phone's ID.
                channel.send(.make(.unpair) { $0.phone = phone; $0.proof = MacRelay.Keys.proof(key: key, nonce: "old", phone: phone, kind: .unpair) })
                channel.send(.make(.unpair) { $0.phone = phone; $0.proof = MacRelay.Keys.proof(key: MacRelay.Keys.make(), nonce: nonce, phone: phone, kind: .unpair) })
                channel.send(.make(.unpair) { $0.phone = UUID(); $0.proof = "" })
            case .unpaired: unpaired = true
            default: break
            }
        }
        try await waitUntil { welcomed }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(unpaired)
        XCTAssertEqual(relay.phones.map(\.id), [phone], "Still paired")
        channel.close()
    }

    func testClaudesQuestionWithNoPhoneToAnswerIt() async throws {
        let key = try await pairedPhone()
        let store = makePhoneStore()
        let session = MacRelayPhoneSession()
        session.store = store
        let client = try await connect(key: key, session: session)
        XCTAssertTrue(session.send("slow: plan Saturday", store: store))
        try await waitUntil { store.handoffStreaming == "Looking" }
        let chat = try XCTUnwrap(store.agentChat.id)
        client.close()
        try await waitUntil { self.relay.connected.isEmpty }
        let request = KemoSabeBridgeWire.Request(secret: "", agent: "claude-code", question: "Is Sarah free?", purpose: "plans", handoff: chat.uuidString)
        let answer = await relay.answer(request)
        XCTAssertEqual(answer?.status, "unavailable")
        XCTAssertEqual(answer?.text, MacRelay.phoneUnreachable)
        // A question from the Mac's own chat isn't the relay's.
        let own = await relay.answer(.init(secret: "", agent: "claude-code", question: "Q", purpose: "", handoff: UUID().uuidString))
        XCTAssertNil(own)
        claudes.last?.finish("Done.")
    }

    func testTheMacSaysWhenClaudeCodeIsntSignedIn() async throws {
        let key = try await pairedPhone()
        relay.turns.claudeOverride = .signedOut
        let store = makePhoneStore()
        let session = MacRelayPhoneSession()
        session.store = store
        let client = try await connect(key: key, session: session)
        XCTAssertEqual(client.welcome?.claude, .signedOut)
        XCTAssertFalse(session.send("hello", store: store))
        XCTAssertEqual(store.error, MacRelay.AgentState.signedOut.problem)
        XCTAssertTrue(store.conversationMessages.isEmpty, "Nothing was sent")
        XCTAssertTrue(claudes.isEmpty)
    }

    func testThePhoneChoosesAnyAgentOnTheMacAndAnOlderPhoneStillGetsClaude() async throws {
        let key = try await pairedPhone()
        relay.turns.agentsOverride = [.init(id: "claude-code", name: "Claude", product: "Claude Code", state: .signedIn),
                                      .init(id: "codex", name: "Codex", product: "Codex", state: .signedIn),
                                      .init(id: "muse", name: "Muse Code", product: "Muse Code", state: .signedOut)]
        let store = makePhoneStore()
        store.state.allowAgentQuestions(.codingAgent("codex"), once: false)
        store.selectChatAgent("codex")
        let session = MacRelayPhoneSession()
        session.store = store
        let client = try await connect(key: key, session: session)
        XCTAssertEqual(client.welcome?.version, MacRelay.version)
        XCTAssertEqual(client.welcome?.agents?.map(\.id), ["claude-code", "codex", "muse"], "Every agent, with its state")
        XCTAssertEqual(client.welcome?.claude, .signedIn, "And Claude's, as version 1 had it")

        // A chat with Codex: the Mac runs Codex, and Codex's question is answered by the phone's KemoSabe.
        XCTAssertTrue(session.send("ask: find a date spot for Sarah and I tonight", store: store))
        XCTAssertEqual(store.handoffWorking, "Codex")
        try await waitUntil { store.conversationMessages.last?.handoff?.part == .result }
        XCTAssertEqual(claudes.last?.provider, .codex, "The Mac started Codex, not Claude")
        XCTAssertTrue(claudes.last?.sent.first?.hasPrefix("(From KemoSabe, about this chat) ") == true, "Codex hears where it's talking with the first message")
        XCTAssertEqual(claudes.last?.asked?.status, "answered")
        let messages = store.conversationMessages.filter { $0.handoff != nil }
        XCTAssertEqual(messages.compactMap(\.handoff?.part), [.task, .answer, .result])
        XCTAssertEqual(messages.map(\.role), ["You", "KemoSabe", "Codex"])
        XCTAssertEqual(Set(messages.compactMap(\.handoff?.agentID)), ["codex"])
        XCTAssertEqual(messages[1].text, "After 7 tonight")
        let journal = try await store.agentRequests.journal.snapshot()
        XCTAssertEqual(journal.last?.requester, "Codex")

        // An agent the Mac doesn't run, or one that isn't signed in there, says so and sends nothing.
        let other = makePhoneStore()
        other.selectChatAgent("cursor-agent")
        let otherSession = MacRelayPhoneSession(); otherSession.store = other
        otherSession.attach(client)
        XCTAssertFalse(otherSession.send("hello", store: other))
        XCTAssertEqual(other.error, "Cursor Agent isn’t on Test Mac. Choose another agent in the model menu.")
        other.selectChatAgent("muse")
        XCTAssertFalse(otherSession.send("hello", store: other))
        XCTAssertEqual(other.error, "Muse Code isn’t signed in on your Mac. Open Tsukumo on your Mac and sign in to Muse Code there.")
        XCTAssertEqual(claudes.count, 1)
        session.attach(client)

        // An older phone (version 1): welcomed in version 1 with no agent list, and its turn runs Claude.
        let channel = try await transport().open(mac: relay.mac, identity: MacRelay.identity(phone: phone), key: key).get()
        var welcome: MacRelay.Frame?
        let phone = self.phone, chat = UUID()
        channel.onFrame = { frame in
            switch frame.type {
            case .challenge:
                channel.send(.make(.hello) { $0.v = 1; $0.phone = phone; $0.name = "Old iPhone"
                    $0.proof = MacRelay.Keys.proof(key: key, nonce: frame.nonce ?? "", phone: phone, kind: .hello) })
            case .welcome:
                welcome = frame
                channel.send(.make(.send) { $0.chat = chat; $0.turn = UUID(); $0.text = "slow: plan Saturday" })
            default: break
            }
        }
        try await waitUntil { self.claudes.count == 2 }
        XCTAssertEqual(welcome?.v, 1); XCTAssertNil(welcome?.agents); XCTAssertEqual(welcome?.claude, .signedIn)
        XCTAssertEqual(claudes.last?.provider, .claude, "Without an agent, the chat is with Claude")
        XCTAssertEqual(claudes.last?.sent.first, "slow: plan Saturday", "Claude gets only the message; its words are its system prompt")
        claudes.last?.finish("Saturday.")
        channel.close()
    }

    // MARK: Helpers

    private func transport() -> MacRelayDirectTransport {
        MacRelayDirectTransport { [relay] in relay?.port.flatMap { NWEndpoint.Port(rawValue: $0) }.map { .hostPort(host: "127.0.0.1", port: $0) } }
    }
    private func pairedPhone() async throws -> Data {
        relay.setEnabled(true)
        let offer = try XCTUnwrap(relay.offer)
        try await waitUntil { self.relay.port != nil }
        let channel = try await transport().open(mac: nil, identity: MacRelay.pairingIdentity, key: MacRelay.Keys.pairing(code: offer.code)).get()
        let paired = try await MacRelayPairing.pair(over: channel, phone: phone, name: "Test iPhone", code: offer.code).get()
        try await waitUntil { self.relay.port != nil }
        return paired.key
    }
    private func connect(key: Data, session: MacRelayPhoneSession) async throws -> MacRelayClient {
        let channel = try await transport().open(mac: relay.mac, identity: MacRelay.identity(phone: phone), key: key).get()
        let client = MacRelayClient(phone: phone, key: key, name: "Test iPhone")
        client.start(channel)
        try await waitUntil { client.isConnected }
        session.attach(client)
        return client
    }
    /// The phone's account, seeded like the hand-off demo: Sarah's free after 7, and Claude may ask.
    private func makePhoneStore() -> AppStore {
        let folder = temporaryFolder()
        let store = AppStore(repository: .init(url: folder.appendingPathComponent("state.json")), provider: APIUnavailableLocal(), apiKeys: MemoryAPIKeys())
        ChatHandoffFixture.seed(store)
        store.agentQuestions.model = ChatHandoffFixture.FakeExtraction(delay: 0.05)
        return store
    }
    private func temporaryFolder() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacRelayTests-" + UUID().uuidString, isDirectory: true)
        folders.append(folder)
        return folder
    }
    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < end else { return XCTFail("Timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// Plays the chat's agent (Claude Code, or Codex) for a phone's turn. "ask:" calls `ask_kemosabe` as the
/// MCP bridge would (through `KemoSabeRelay.answer`, with the agent's own identity) and replies with
/// what KemoSabe said; "slow:" streams "Looking" and waits for `finish` or `stop`.
@MainActor final class RelayFakeClaude: AgentSession {
    var onEvent: ((CodingEvent, Bool) -> Void)?
    var onState: ((CodingTaskStatus) -> Void)?
    var onSession: ((String) -> Void)?
    var onApproval: ((CodingApproval?) -> Void)?
    let chat: UUID
    let resume: String?
    /// The agent the Mac started for the turn.
    let provider: CodingProvider
    weak var relay: KemoSabeRelay?
    private(set) var asked: KemoSabeBridgeWire.Response?
    private(set) var stopped = false
    /// What the Mac sent it, first to last.
    private(set) var sent: [String] = []
    private var work: Task<Void, Never>?
    init(chat: UUID, resume: String?, relay: KemoSabeRelay?, provider: CodingProvider = .claude) {
        self.chat = chat; self.resume = resume; self.relay = relay; self.provider = provider
    }
    func send(_ text: String) throws {
        sent.append(text)
        onState?(.working)
        onSession?("relay-session-1")
        if text.contains("slow:") { onEvent?(.init(id: "r1", kind: .assistant, text: "Looking"), false); return }
        let identity = provider == .codex ? "codex" : "claude-code"
        work = Task { @MainActor [weak self] in
            guard let self else { return }
            let request = KemoSabeBridgeWire.Request(secret: "", agent: identity, client: .init(name: identity, version: "1.0"),
                                                     question: ChatHandoffFixture.question, purpose: ChatHandoffFixture.purpose, handoff: self.chat.uuidString)
            let answer = await self.relay?.answer(request)
            self.asked = answer
            guard !Task.isCancelled else { return }
            self.finish("Sarah’s free after 7 (KemoSabe said: \(answer?.text ?? "nothing")). Book Osteria Lucia for 7:30.")
        }
    }
    func finish(_ reply: String) {
        onEvent?(.init(id: "r2", kind: .assistant, text: reply), false)
        onState?(.review)
    }
    func respond(_ id: String, allow: Bool, answers: String) throws {}
    func stop() { stopped = true; work?.cancel(); work = nil }
}

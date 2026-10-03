import XCTest
@testable import KemoSabe

/// Your Mac's agents on the iPhone (design/CONTEXT-HARNESS.md#your-macs-agents-from-iphone): what the
/// model menu says before pairing and lists after, and what the chat says when the Mac can't be
/// reached. The two ends talking are tested on the Mac (`MacRelayLoopbackTests`).
@MainActor final class MacRelayPhoneTests: XCTestCase {
    private var folder: URL?
    override func tearDown() async throws { if let folder { try? FileManager.default.removeItem(at: folder) } }

    func testBeforePairingOneRowAsksYouToPairYourMac() {
        let relay = MacRelayPhone(defaults: UserDefaults(suiteName: "kemo-relay-phone-" + UUID().uuidString)!)
        XCTAssertNil(relay.mac); XCTAssertEqual(relay.status, .notPaired)
        XCTAssertEqual(relay.options.count, 1)
        let option = relay.options[0]
        XCTAssertEqual(option.id, ChatHandoff.claudeAgentID); XCTAssertEqual(option.logo, "AgentLogoClaude")
        XCTAssertFalse(option.available)
        XCTAssertEqual(option.actionTitle, "Pair"); XCTAssertNotNil(option.signIn)
        XCTAssertEqual(option.detail, "Pair your Mac in Settings → Models → Agents on your Mac")
        XCTAssertFalse(relay.isConnected)
    }

    func testAPairedMacsAgentsAreListedWithTheirOwnMarksAndKeptWhileItsAway() throws {
        let suite = "kemo-relay-phone-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let macID = UUID()
        defer { MacRelayKeychain.delete(mac: macID) }
        XCTAssertTrue(MacRelayKeychain.save(MacRelay.Keys.make(), mac: macID))
        defaults.set(try JSONEncoder().encode(MacRelayPhone.PairedMac(id: macID, name: "Test Mac", paired: Date())), forKey: "kemo.relay.mac")
        let relay = MacRelayPhone(defaults: defaults)
        XCTAssertEqual(relay.options.map(\.id), [ChatHandoff.claudeAgentID], "Claude until the Mac says what it runs")
        relay.remember([.init(id: "claude-code", name: "Claude", product: "Claude Code", state: .signedIn),
                        .init(id: "codex", name: "Codex", product: "Codex", state: .signedOut),
                        .init(id: "muse", name: "Muse Code", product: "Muse Code", state: .installed),
                        .init(id: "cursor-agent", name: "Cursor Agent", product: "Cursor Agent", state: .notInstalled),
                        .init(id: "acp:1234", name: "Goose", product: "Goose", state: .signedIn)])
        let options = relay.options
        XCTAssertEqual(options.map(\.id), ["claude-code", "codex", "muse", "acp:1234"], "An agent that isn't installed there isn't offered")
        XCTAssertEqual(options.map(\.logo), ["AgentLogoClaude", "AgentLogoOpenAI", "AgentLogoMuse", ""])
        XCTAssertEqual(options.map(\.title), ["Claude", "Codex", "Muse Code", "Goose"])
        XCTAssertTrue(options.allSatisfy { $0.available && $0.signIn == nil })
        XCTAssertEqual(options[1].detail, "Looking for Test Mac…")
        // Kept for the next launch, so the menu lists them while the Mac is away.
        XCTAssertEqual(MacRelayPhone(defaults: defaults).options.map(\.id), ["claude-code", "codex", "muse", "acp:1234"])

        // A chat with Codex says Codex can't answer, and never offers the Claude API.
        let store = makeStore()
        store.selectChatAgent("codex")
        store.state.apiProfiles = [try APIModelProfile.validated(name: "Claude", endpoint: "https://api.anthropic.com/v1/messages", model: "claude-sonnet-4-5", format: .anthropic)]
        XCTAssertFalse(relay.send("hello", store: store))
        XCTAssertEqual(store.error, "Still looking for Test Mac. Try again in a moment.")
        relay.forget()
        XCTAssertEqual(relay.options.map(\.id), [ChatHandoff.claudeAgentID])
        XCTAssertEqual(MacRelayPhone(defaults: defaults).agents, [])
    }

    func testNotConnectedSaysSoAndOffersAClaudeAPIConnectionOnlyWhenThereIsOne() throws {
        let relay = MacRelayPhone(defaults: UserDefaults(suiteName: "kemo-relay-phone-" + UUID().uuidString)!)
        let store = makeStore()
        XCTAssertFalse(relay.send("hello", store: store))
        XCTAssertEqual(store.error, "Pair your Mac first: Settings → Models → Agents on your Mac.")
        XCTAssertTrue(store.conversationMessages.isEmpty, "Nothing is sent anywhere else")
        XCTAssertFalse(relay.unreachable(store).contains("Claude API"))
        store.state.apiProfiles = [try APIModelProfile.validated(name: "Claude", endpoint: "https://api.anthropic.com/v1/messages", model: "claude-sonnet-4-5", format: .anthropic)]
        XCTAssertTrue(relay.unreachable(store).hasSuffix("You can also switch to your Claude API connection in the model menu."))
        XCTAssertFalse(relay.unreachable(store).contains("Kemo "), "Rule 14")
    }

    func testUnpairingKeepsTheKeyUntilTheMacConfirmsOrYouForgetAnyway() throws {
        let suite = "kemo-relay-phone-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let macID = UUID()
        defer { MacRelayKeychain.delete(mac: macID) }
        XCTAssertTrue(MacRelayKeychain.save(MacRelay.Keys.make(), mac: macID))
        defaults.set(try JSONEncoder().encode(MacRelayPhone.PairedMac(id: macID, name: "Test Mac", paired: Date())), forKey: "kemo.relay.mac")
        let relay = MacRelayPhone(defaults: defaults)
        XCTAssertEqual(relay.mac?.id, macID); XCTAssertFalse(relay.isUnpairing)

        // Unpair with the Mac out of reach: nothing is forgotten yet, and chats with Claude are paused.
        relay.unpair()
        XCTAssertTrue(relay.isUnpairing)
        XCTAssertEqual(relay.mac?.id, macID)
        XCTAssertNotNil(MacRelayKeychain.load(mac: macID), "The key stays until the Mac confirms")
        XCTAssertEqual(relay.detail, "Unpairing from Test Mac…")
        XCTAssertFalse(relay.options.contains { $0.available })
        let store = makeStore()
        XCTAssertFalse(relay.send("hello", store: store))
        XCTAssertEqual(store.error, "You unpaired Test Mac, so Claude can’t answer here. Pair a Mac in Settings → Models → Agents on your Mac.")
        XCTAssertEqual(relay.unreachable(store), store.error, "The chat's own check says the same")
        XCTAssertTrue(store.conversationMessages.isEmpty)

        // Still waiting after a relaunch.
        let relaunched = MacRelayPhone(defaults: defaults)
        XCTAssertTrue(relaunched.isUnpairing)
        XCTAssertEqual(relaunched.mac?.id, macID)

        // Forget anyway: the Mac and its key are gone here, and nothing is pending.
        relaunched.forget()
        XCTAssertNil(relaunched.mac); XCTAssertEqual(relaunched.status, .notPaired)
        XCTAssertNil(MacRelayKeychain.load(mac: macID))
        XCTAssertFalse(relaunched.isUnpairing)
        XCTAssertFalse(MacRelayPhone(defaults: defaults).isUnpairing)
        XCTAssertNil(MacRelayPhone(defaults: defaults).mac)
    }

    func testAScannedLinkIsAnInvite() throws {
        let code = MacRelay.PairingCode.make(), mac = UUID()
        let invite = try XCTUnwrap(MacRelay.Invite(url: URL(string: "kemosabe://pair-mac?mac=\(mac.uuidString)&name=Zach%E2%80%99s%20Mac&code=\(code)")!))
        XCTAssertEqual(invite.mac, mac); XCTAssertEqual(invite.name, "Zach’s Mac"); XCTAssertEqual(invite.code, code)
        XCTAssertNil(MacRelay.Invite(url: URL(string: "kemosabe://chat")!), "The Live Activity's link isn't one")
    }

    func testAReplyLandsInItsOwnChatAfterYouSwitchChats() throws {
        let store = makeStore()
        store.selectChatAgent(ChatHandoff.claudeAgentID)
        let chat = UUID()
        ChatHandoffTranscript.beginTurn(chat, text: "plan Saturday", agent: ChatHandoff.claude, store: store)
        let conversation = store.conversationID(for: store.currentConversationSlot)
        store.streamHandoff(chat, "Looking")
        XCTAssertEqual(store.handoffWorking, ChatHandoff.claude)
        XCTAssertEqual(store.handoffStreaming, "Looking")

        // Another chat while Claude works on your Mac: its row, stream, and cards stay with their chat.
        store.newConversation()
        XCTAssertTrue(store.conversationMessages.isEmpty)
        XCTAssertNil(store.handoffWorking)
        XCTAssertEqual(store.handoffStreaming, "")
        store.appendVisibleMessage(role: "You", text: "something else")
        let requester = AgentRequester(recipient: .codingAgent(ChatHandoff.claudeAgentID), name: ChatHandoff.claude)
        let question = AgentQuestion(requester: requester, question: "Is Sarah free?", purpose: "plans", handoff: chat)
        let observer = try XCTUnwrap(store.agentQuestions.handoffObservers[chat])
        observer(question, nil, AgentExchangeReport())
        observer(question, .answered("After 7 tonight"), AgentExchangeReport())
        store.streamHandoff(chat, "Looking at places")
        XCTAssertEqual(store.handoffStreaming, "")

        ChatHandoffTranscript.finishTurn(chat, agent: ChatHandoff.claude, reply: "Farmers market at 9.", session: "s-1", store: store)
        XCTAssertEqual(store.conversationMessages.map(\.text), ["something else"], "Nothing lands in the chat on screen")
        let saved = try XCTUnwrap(store.state.conversationArchives?.first { $0.id == conversation })
        XCTAssertEqual(saved.messages.compactMap(\.handoff?.part), [.task, .answer, .result], "The question card became KemoSabe's answer in place")
        XCTAssertEqual(saved.messages.map(\.text), ["plan Saturday", "After 7 tonight", "Farmers market at 9."])
        XCTAssertTrue(store.handoffTurns.isEmpty)

        // Continuing that chat continues Claude's session there.
        store.selectChatAgent(ChatHandoff.claudeAgentID)
        store.resumeArchivedConversation(conversation)
        XCTAssertEqual(store.agentChat.id, chat)
        XCTAssertEqual(store.agentChat.session, "s-1")
    }

    func testAReplyForADeletedChatGoesNowhere() {
        let store = makeStore()
        store.selectChatAgent(ChatHandoff.claudeAgentID)
        let chat = UUID()
        ChatHandoffTranscript.beginTurn(chat, text: "plan Saturday", agent: ChatHandoff.claude, store: store)
        let conversation = store.conversationID(for: store.currentConversationSlot)
        store.newConversation()
        store.deleteArchivedConversation(conversation)
        ChatHandoffTranscript.finishTurn(chat, agent: ChatHandoff.claude, reply: "Farmers market at 9.", session: "s-1", store: store)
        XCTAssertTrue(store.conversationMessages.isEmpty)
        XCTAssertFalse((store.state.conversationArchives ?? []).contains { $0.messages.contains { $0.handoff?.id == chat } })
        XCTAssertTrue(store.handoffTurns.isEmpty)
    }

    private func makeStore() -> AppStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        self.folder = folder
        return AppStore(repository: .init(url: folder.appendingPathComponent("state.json")), provider: APIUnavailableLocal(), apiKeys: MemoryAPIKeys())
    }
}

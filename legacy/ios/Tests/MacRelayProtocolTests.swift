import XCTest
#if os(macOS)
@testable import KemoSabeMac
#else
@testable import KemoSabe
#endif

/// The protocol of your Mac's agents from iPhone (design/CONTEXT-HARNESS.md#your-macs-agents-from-iphone),
/// the same on both devices: pairing codes and links, their expiry, the keys, the frames on the wire,
/// versions (a version 1 Mac still runs Claude), and where its settings are. The two ends talking over
/// TLS on localhost are in the Mac's `MacRelayLoopbackTests`.
final class MacRelayProtocolTests: XCTestCase {
    func testAPairingCodeIsAtLeast128RandomBitsAndForgivingToType() throws {
        let code = MacRelay.PairingCode.make()
        XCTAssertEqual(code.count, 28)
        XCTAssertGreaterThanOrEqual(code.count * 5, 128, "Each symbol is 5 random bits")
        XCTAssertNotEqual(code, MacRelay.PairingCode.make())
        XCTAssertTrue(code.allSatisfy { MacRelay.PairingCode.alphabet.contains($0) })
        let grouped = MacRelay.PairingCode.grouped(code)
        XCTAssertEqual(grouped.split(separator: "-").map(\.count), [4, 4, 4, 4, 4, 4, 4])
        XCTAssertEqual(MacRelay.PairingCode.normalize(grouped.lowercased()), code, "Any case, with dashes")
        XCTAssertEqual(MacRelay.PairingCode.normalize(" oooo iiii llll 2222 3333 4444 5555 "), "0000111111112222333344445555", "O reads as 0; I and L as 1")
        XCTAssertNil(MacRelay.PairingCode.normalize("ABCD-EFGH"), "Too short")
        XCTAssertNil(MacRelay.PairingCode.normalize(String(repeating: "U", count: 28)), "Not in the alphabet")
        XCTAssertNil(MacRelay.PairingCode.normalize(code + "0"), "Too long")
    }

    func testThePairingLinkRoundTripsAndNothingElseIsOne() throws {
        let invite = MacRelay.Invite(mac: UUID(), name: "Zach’s MacBook Pro", code: MacRelay.PairingCode.make())
        let url = invite.url
        XCTAssertEqual(url.scheme, "kemosabe"); XCTAssertEqual(url.host(), "pair-mac")
        XCTAssertEqual(MacRelay.Invite(url: url), invite)
        XCTAssertEqual(MacRelay.Invite(typed: url.absoluteString), invite, "A pasted link")
        let typed = try XCTUnwrap(MacRelay.Invite(typed: MacRelay.PairingCode.grouped(invite.code).lowercased()))
        XCTAssertEqual(typed.code, invite.code); XCTAssertNil(typed.mac); XCTAssertNil(typed.name)
        XCTAssertNil(MacRelay.Invite(url: URL(string: "kemosabe://chat")!))
        XCTAssertNil(MacRelay.Invite(url: URL(string: "https://pair-mac/?code=\(invite.code)")!), "Only KemoSabe's own scheme")
        XCTAssertNil(MacRelay.Invite(url: URL(string: "kemosabe://pair-mac?code=SHORT")!))
        XCTAssertNil(MacRelay.Invite(url: URL(string: "kemosabe://pair-mac?mac=\(UUID().uuidString)")!), "No code, no invite")
        XCTAssertNil(MacRelay.Invite(typed: "hello"))
    }

    func testACodeWorksOnceForTenMinutes() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var offer = MacRelay.PairingOffer(created: start)
        XCTAssertTrue(offer.isOpen(at: start))
        XCTAssertTrue(offer.isOpen(at: start.addingTimeInterval(9 * 60 + 59)))
        XCTAssertFalse(offer.isOpen(at: start.addingTimeInterval(10 * 60)), "Expired after ten minutes")
        offer.used = true
        XCTAssertFalse(offer.isOpen(at: start.addingTimeInterval(1)), "Single-use")
    }

    func testKeysAndProofs() {
        let code = MacRelay.PairingCode.make()
        let pairing = MacRelay.Keys.pairing(code: code)
        XCTAssertEqual(pairing.count, 32)
        XCTAssertEqual(pairing, MacRelay.Keys.pairing(code: code), "Both ends derive the same key from the code")
        XCTAssertNotEqual(pairing, MacRelay.Keys.pairing(code: MacRelay.PairingCode.make()))
        XCTAssertNotEqual(pairing.prefix(code.utf8.count), Data(code.utf8), "Derived, never the code itself")
        let key = MacRelay.Keys.make()
        XCTAssertEqual(key.count, 32); XCTAssertNotEqual(key, MacRelay.Keys.make())

        let phone = UUID(), nonce = MacRelay.Keys.nonce()
        let proof = MacRelay.Keys.proof(key: key, nonce: nonce, phone: phone, kind: .hello)
        XCTAssertTrue(MacRelay.Keys.verify(proof, key: key, nonce: nonce, phone: phone, kind: .hello))
        XCTAssertFalse(MacRelay.Keys.verify(proof, key: key, nonce: MacRelay.Keys.nonce(), phone: phone, kind: .hello), "A new connection's nonce")
        XCTAssertFalse(MacRelay.Keys.verify(proof, key: MacRelay.Keys.make(), nonce: nonce, phone: phone, kind: .hello), "Another phone's key")
        XCTAssertFalse(MacRelay.Keys.verify(proof, key: key, nonce: nonce, phone: UUID(), kind: .hello), "Another phone's ID")
        XCTAssertFalse(MacRelay.Keys.verify(proof, key: key, nonce: nonce, phone: phone, kind: .pair), "A hello isn't a pairing")
        XCTAssertFalse(MacRelay.Keys.verify(nil, key: key, nonce: nonce, phone: phone, kind: .hello))
        XCTAssertEqual(MacRelay.phone(identity: MacRelay.identity(phone: phone)), phone)
        XCTAssertNil(MacRelay.phone(identity: MacRelay.pairingIdentity))
    }

    func testFramesSurviveAnyChunkingAndOversizeIsRefused() throws {
        let chat = UUID(), turn = UUID()
        let frames: [MacRelay.Frame] = [
            .make(.send) { $0.chat = chat; $0.turn = turn; $0.text = "find a date spot for Sarah and I tonight"; $0.session = "s-1" },
            .make(.delta) { $0.turn = turn; $0.text = "Sarah’s free after 7 ✨" },
            .make(.ask) { $0.chat = chat; $0.turn = turn; $0.ask = UUID(); $0.text = "What time is Sarah free tonight?"; $0.purpose = "planning a date"; $0.agent = "claude-code" },
            .make(.done) { $0.turn = turn; $0.reply = "Book Osteria Lucia for 7:30." },
        ]
        let data = try frames.map(MacRelay.Framing.encode).reduce(Data(), +)
        let first = try MacRelay.Framing.encode(frames[0])
        XCTAssertEqual(first.prefix(4).reduce(0) { ($0 << 8) | Int($1) }, first.count - 4, "A 4-byte big-endian length")

        var whole = MacRelay.Framing.Reader()
        XCTAssertEqual(try whole.append(data), frames)
        var bytes = MacRelay.Framing.Reader(), got: [MacRelay.Frame] = []
        for byte in data { got += try bytes.append(Data([byte])) }
        XCTAssertEqual(got, frames, "One byte at a time")
        XCTAssertEqual(bytes.pending, 0)

        var oversize = MacRelay.Framing.Reader()
        XCTAssertThrowsError(try oversize.append(Data([0x7f, 0xff, 0xff, 0xff])))
        XCTAssertThrowsError(try MacRelay.Framing.encode(.make(.send) { $0.text = String(repeating: "a", count: MacRelay.maxFrame) }))

        // A newer build's type and agent state read as unknown and installed, never a failure.
        let newer = try JSONDecoder().decode(MacRelay.Frame.self, from: Data(#"{"type":"teleport","claude":"thinking","v":3,"agents":[{"id":"codex","state":"dreaming"},{"id":"acp:x","name":"Goose"}]}"#.utf8))
        XCTAssertEqual(newer.type, .unknown); XCTAssertEqual(newer.claude, .installed)
        XCTAssertEqual(newer.agents?.map(\.id), ["codex", "acp:x"])
        XCTAssertEqual(newer.agents?.first?.name, "Codex", "A built-in agent's name when the Mac leaves it out")
        XCTAssertEqual(newer.agents?.first?.state, .installed)
        XCTAssertEqual(newer.agents?.last?.product, "Goose")
        XCTAssertNil(MacRelay.AgentState.signedIn.problem)
        XCTAssertTrue(MacRelay.AgentState.signedOut.problem?.contains("sign in to Claude Code there") == true, "Sign in on the Mac")
        XCTAssertEqual(MacRelay.AgentState.notInstalled.problem("Codex"), "Codex isn’t installed on your Mac. Install it on your Mac and sign in there.")
    }

    func testEachSideSpeaksTheLowerVersion() {
        XCTAssertEqual(MacRelay.version, 3)
        XCTAssertEqual(MacRelay.agreed(1), 1, "A version 1 Mac (Tsukumo 74) hears version 1")
        XCTAssertEqual(MacRelay.agreed(nil), 1)
        XCTAssertEqual(MacRelay.agreed(2), 2)
        XCTAssertEqual(MacRelay.agreed(7), 3, "A newer side hears this one's")
        XCTAssertNil(MacRelay.agreed(0))
    }

    /// A version 1 Mac (Tsukumo 74) over an in-memory channel: the phone says hello in version 1,
    /// offers Claude alone, never sends another agent, and a turn goes out without one.
    @MainActor func testAVersionOneMacStillRunsClaude() throws {
        let channel = MemoryChannel()
        let key = MacRelay.Keys.make(), phone = UUID(), mac = UUID()
        let client = MacRelayClient(phone: phone, key: key, name: "Test iPhone")
        client.start(channel)
        channel.onFrame?(.make(.challenge) { $0.v = 1; $0.nonce = "n1"; $0.mac = mac; $0.name = "Old Mac" })
        let hello = try XCTUnwrap(channel.sent.last)
        XCTAssertEqual(hello.type, .hello); XCTAssertEqual(hello.v, 1, "The Mac checks for exactly its own version")
        XCTAssertTrue(MacRelay.Keys.verify(hello.proof, key: key, nonce: "n1", phone: phone, kind: .hello))
        channel.onFrame?(.make(.welcome) { $0.v = 1; $0.mac = mac; $0.name = "Old Mac"; $0.claude = .signedIn })
        let welcome = try XCTUnwrap(client.welcome)
        XCTAssertNil(welcome.agents); XCTAssertEqual(welcome.version, 1)
        XCTAssertEqual(welcome.offered.map(\.id), [ChatHandoff.claudeAgentID]); XCTAssertEqual(welcome.offered.first?.state, .signedIn)
        XCTAssertFalse(client.send(chat: UUID(), turn: UUID(), text: "hi", session: nil, agent: "codex"), "It only runs Claude")
        XCTAssertTrue(client.send(chat: UUID(), turn: UUID(), text: "hi", session: nil))
        XCTAssertEqual(channel.sent.last?.type, .send); XCTAssertNil(channel.sent.last?.agent, "Version 1 frames stay as they were")

        // A version 2 Mac lists its agents, and a turn names its agent.
        let current = MemoryChannel()
        let next = MacRelayClient(phone: phone, key: key, name: "Test iPhone")
        next.start(current)
        current.onFrame?(.make(.challenge) { $0.v = 2; $0.nonce = "n2"; $0.mac = mac; $0.name = "Mac" })
        XCTAssertEqual(current.sent.last?.v, 2)
        current.onFrame?(.make(.welcome) { $0.v = 2; $0.mac = mac; $0.name = "Mac"; $0.claude = .signedIn
            $0.agents = [.init(id: "claude-code", name: "Claude", product: "Claude Code", state: .signedIn), .init(id: "codex", name: "Codex", product: "Codex", state: .signedOut)] })
        XCTAssertEqual(next.welcome?.offered.map(\.id), ["claude-code", "codex"])
        XCTAssertTrue(next.send(chat: UUID(), turn: UUID(), text: "hi", session: nil, agent: "codex"))
        XCTAssertEqual(current.sent.last?.agent, "codex")
        current.onFrame?(.make(.pong) { $0.claude = .signedIn; $0.agents = [.init(id: "codex", name: "Codex", product: "Codex", state: .signedIn)] })
        XCTAssertEqual(next.welcome?.agents?.first?.state, .signedIn, "Pong keeps the list current")
    }

    func testTheSettingsAreASectionOfModelsOnBothDevices() throws {
        XCTAssertNil(SettingsCatalog.page("Claude from iPhone"), "No separate page any more (AGENTS.md rule 10)")
        XCTAssertFalse(SettingsCatalog.groups.first { $0.name == "Integrations" }!.pages.contains { $0.id.contains("iPhone") })
        let models = try XCTUnwrap(SettingsCatalog.page("Models"))
        XCTAssertEqual(models.devices, [.iPhone, .mac])
        for word in ["claude", "codex", "muse", "cursor", "mac", "iphone", "pair"] {
            XCTAssertTrue(models.matches(word), word)
            XCTAssertEqual(SettingsCatalog.groups(for: .iPhone, search: word).flatMap(\.pages).map(\.id).contains("Models"), true, word)
            XCTAssertEqual(SettingsCatalog.groups(for: .mac, search: word).flatMap(\.pages).map(\.id).contains("Models"), true, word)
        }
        // Older links land on Models → LLM.
        for old in ["Claude from iPhone", "Use from iPhone", SettingsCatalog.macAgents.iPhone] {
            XCTAssertEqual(SettingsCatalog.moved[old]?.page, "Models", old); XCTAssertEqual(SettingsCatalog.moved[old]?.tab, .llm, old)
        }
        XCTAssertEqual(MacRelay.phoneSettings, "Settings → Models → Agents on your Mac")
        XCTAssertEqual(MacRelay.macSettings, "Tsukumo → Settings → Models → Agents on your Mac")
        for text in [MacRelay.phoneSettings, MacRelay.macSettings, SettingsCatalog.macAgents.keywords] {
            XCTAssertFalse(text.contains("—"), "No em dashes"); XCTAssertFalse(text.contains("Kemo "), "Rule 14")
        }
    }
}

/// A channel that keeps what's sent, for driving one end by hand.
@MainActor final class MemoryChannel: MacRelayChannel {
    var onFrame: ((MacRelay.Frame) -> Void)?
    var onClose: ((String?) -> Void)?
    private(set) var sent: [MacRelay.Frame] = []
    private(set) var closed = false
    func send(_ frame: MacRelay.Frame) { sent.append(frame) }
    func close(sending frame: MacRelay.Frame) { sent.append(frame); closed = true }
    func close() { closed = true }
}

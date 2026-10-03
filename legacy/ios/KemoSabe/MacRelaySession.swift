import Foundation
import Observation

// Your Mac's agents from iPhone: the two ends of one conversation
// (design/CONTEXT-HARNESS.md#your-macs-agents-from-iphone), over any `MacRelayChannel`. The Mac's end
// (`MacRelayHostCore`) checks who's talking, runs each turn with the chat's agent through a
// `MacRelayTurnRunner` (`KemoSabeHandoff` in Tsukumo), streams it, keeps finished results for ten
// minutes, and sends the agent's questions for KemoSabe to the phone whose chat it is. The phone's end
// (`MacRelayClient`) sends turns and answers those questions with its own KemoSabe. Compiled into both
// apps so the Mac's tests run both ends together.

/// A change in one turn, as the Mac reports it.
enum MacRelayTurnUpdate: Equatable, Sendable {
    /// The reply so far.
    case delta(String)
    case done(reply: String, session: String?)
    case failed(String)
}

/// What runs a phone's turn on the Mac: the chat's agent through `KemoSabeHandoff`, or a fake in tests.
@MainActor protocol MacRelayTurnRunner: AnyObject {
    /// Every agent the Mac can run for a phone, Claude first.
    var agents: [MacRelay.Agent] { get }
    /// Starts one turn with `agent` (its chat ID) and reports it through `update` until `.done` or `.failed`.
    func start(chat: UUID, turn: UUID, agent: String, text: String, session: String?, update: @escaping (MacRelayTurnUpdate) -> Void)
    /// Stops a turn; it still ends with `.failed`.
    func stop(turn: UUID)
}
extension MacRelayTurnRunner {
    /// Claude Code's state, for version 1 phones.
    var claude: MacRelay.AgentState { agents.first { $0.id == ChatHandoff.claudeAgentID }?.state ?? .notInstalled }
}

/// A phone paired with this Mac.
struct MacRelayPairedPhone: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    /// The long-term pre-shared key, also on the phone (in its Keychain).
    var key: Data
    var paired: Date
    var lastSeen: Date?
}

/// The agent's question for KemoSabe, forwarded to the phone.
struct MacRelayAsk: Equatable, Sendable {
    var id: UUID
    var chat: UUID
    var question: String
    var purpose: String
    /// The identity the MCP config named (`--agent codex`), and the MCP client's own name.
    var agent: String?
    var client: String?
}

extension MacRelay {
    /// The longest message a phone may send in one turn.
    static let maxText = 20_000
    /// What the agent gets when the phone can't answer its question.
    static let phoneUnreachable = "KemoSabe on the owner’s iPhone can’t be reached right now, so it can’t answer. Carry on without it, or ask again later."
}

// MARK: The Mac's end

@MainActor final class MacRelayHostCore {
    let mac: UUID
    var name: String
    let runner: MacRelayTurnRunner
    /// The phones paired now (their keys), read on each hello.
    var phones: () -> [MacRelayPairedPhone]
    /// The code on screen, if any.
    var offer: MacRelay.PairingOffer?
    var now: () -> Date = Date.init
    /// A phone paired with the code: save it (and give the listener its key).
    var onPaired: ((MacRelayPairedPhone) -> Void)?
    /// A paired phone connected (for "last seen").
    var onSeen: ((UUID) -> Void)?
    /// Who's connected changed.
    var onChange: (() -> Void)?
    /// A paired phone asked to be unpaired (and proved it holds its key): remove it and its key.
    var onUnpaired: ((UUID) -> Void)?
    /// A phone that carries the account's records said it has something new (`syncChanged`).
    var onSyncChanged: (() -> Void)?
    /// How long the agent waits for the phone's KemoSabe (the owner may be deciding on the consent card).
    var askTimeout: Duration = .seconds(190)

    private final class Peer {
        let channel: MacRelayChannel
        let nonce = MacRelay.Keys.nonce()
        let serial: Int
        var phone: UUID?
        /// The version this phone speaks.
        var version = MacRelay.oldestVersion
        /// It can carry the account's records (version 3, `hello.sync`).
        var hub = false
        init(_ channel: MacRelayChannel, serial: Int) { self.channel = channel; self.serial = serial }
    }
    private var serial = 0
    private struct Turn { let chat: UUID; let phone: UUID; var text = "" }
    /// Agents as a phone of this version hears them: all of them for version 2, none for version 1.
    private func agents(for peer: Peer) -> [MacRelay.Agent]? { peer.version >= 2 ? Array(runner.agents.prefix(MacRelay.maxAgents)) : nil }
    private var peers: [ObjectIdentifier: Peer] = [:]
    private var turns: [UUID: Turn] = [:]
    private var results: [UUID: (frame: MacRelay.Frame, phone: UUID, at: Date)] = [:]
    private var asks: [UUID: (phone: UUID, reply: CheckedContinuation<(status: String, text: String), Never>)] = [:]
    /// Sync requests waiting for the phone's answer, by request.
    private var syncRequests: [UUID: (peer: ObjectIdentifier, reply: CheckedContinuation<MacRelay.Frame, Error>)] = [:]
    /// How long a sync request waits for the phone.
    var syncTimeout: Duration = MacRelaySync.timeout

    init(mac: UUID, name: String, runner: MacRelayTurnRunner, phones: @escaping () -> [MacRelayPairedPhone]) {
        self.mac = mac; self.name = name; self.runner = runner; self.phones = phones
    }

    /// Phones connected now.
    var connected: Set<UUID> { Set(peers.values.compactMap(\.phone)) }
    /// Whether a phone's chat has a turn running here (so its agent's questions go to that phone).
    func owns(chat: UUID) -> Bool { turns.values.contains { $0.chat == chat } }
    var runningTurns: Int { turns.count }

    /// A connection finished its TLS handshake: challenge it.
    func accept(_ channel: MacRelayChannel) {
        serial += 1
        let peer = Peer(channel, serial: serial)
        let id = ObjectIdentifier(peer)
        peers[id] = peer
        channel.onFrame = { [weak self, weak peer] frame in if let peer { self?.handle(frame, from: peer) } }
        channel.onClose = { [weak self] _ in self?.drop(id) }
        channel.send(.make(.challenge) { $0.v = MacRelay.version; $0.nonce = peer.nonce; $0.mac = mac; $0.name = name })
    }

    /// Closes a phone's connections (it was removed).
    func disconnect(phone: UUID) {
        for (id, peer) in peers where peer.phone == phone { peer.channel.close(); drop(id) }
    }
    func disconnectAll() {
        for (id, peer) in peers { peer.channel.close(); drop(id) }
    }

    private func drop(_ id: ObjectIdentifier) {
        // Sync requests on this connection end now; the next sync asks again.
        for (request, waiting) in syncRequests where waiting.peer == id {
            syncRequests[request] = nil
            waiting.reply.resume(throwing: SyncError.unavailable(MacRelaySync.waiting))
        }
        guard let peer = peers.removeValue(forKey: id), let phone = peer.phone else { return }
        onChange?()
        // Questions waiting on this phone get an answer now, unless it's still connected another way.
        guard !connected.contains(phone) else { return }
        for (ask, waiting) in asks where waiting.phone == phone {
            asks[ask] = nil
            waiting.reply.resume(returning: ("unavailable", MacRelay.phoneUnreachable))
        }
    }

    private func refuse(_ peer: Peer, _ problem: String) {
        peer.channel.close(sending: .make(.refused) { $0.problem = problem })
        peers[ObjectIdentifier(peer)] = nil
    }

    private func handle(_ frame: MacRelay.Frame, from peer: Peer) {
        switch frame.type {
        case .hello: hello(frame, from: peer)
        case .pair: pair(frame, from: peer)
        case .ping: if peer.phone != nil { peer.channel.send(.make(.pong) { $0.claude = runner.claude; $0.agents = agents(for: peer) }) }
        default:
            guard let phone = peer.phone else { return refuse(peer, "Pair this iPhone first.") }
            switch frame.type {
            case .send: send(frame, phone: phone, peer: peer)
            case .stop:
                if let turn = frame.turn, turns[turn]?.phone == phone { runner.stop(turn: turn) }
            case .resume: resume(frame.turn, phone: phone, peer: peer)
            case .unpair: unpair(frame, phone: phone, peer: peer)
            case .answer:
                guard let id = frame.ask, let waiting = asks[id], waiting.phone == phone else { return }
                asks[id] = nil
                waiting.reply.resume(returning: (frame.status ?? "unavailable", String((frame.text ?? "").prefix(4000))))
            case .syncRecords, .syncAck, .syncFailed:
                guard let id = frame.request, let waiting = syncRequests[id], waiting.peer == ObjectIdentifier(peer) else { return }
                syncRequests[id] = nil
                waiting.reply.resume(returning: frame)
            case .syncChanged: if peer.hub { onSyncChanged?() }
            default: break
            }
        }
    }

    /// A phone's version: this build's or an older one it still speaks (a newer phone speaks this one).
    private static func speaks(_ v: Int?) -> Int? { v.flatMap { $0 >= MacRelay.oldestVersion && $0 <= MacRelay.version ? $0 : nil } }

    private func hello(_ frame: MacRelay.Frame, from peer: Peer) {
        guard let version = Self.speaks(frame.v) else { return refuse(peer, "Update KemoSabe on your iPhone and Tsukumo on your Mac to the same version.") }
        guard let id = frame.phone, let phone = phones().first(where: { $0.id == id }),
              MacRelay.Keys.verify(frame.proof, key: phone.key, nonce: peer.nonce, phone: id, kind: .hello) else {
            return refuse(peer, "This iPhone isn’t paired with this Mac any more. Pair it again in \(MacRelay.phoneSettings).")
        }
        peer.phone = id; peer.version = version
        peer.hub = version >= 3 && frame.sync == MacRelaySync.hub
        onSeen?(id); onChange?()
        peer.channel.send(.make(.welcome) { $0.v = version; $0.mac = mac; $0.name = name; $0.claude = runner.claude; $0.agents = agents(for: peer) })
    }

    private func pair(_ frame: MacRelay.Frame, from peer: Peer) {
        guard Self.speaks(frame.v) != nil else { return refuse(peer, "Update KemoSabe on your iPhone and Tsukumo on your Mac to the same version.") }
        guard let id = frame.phone, let offer, offer.isOpen(at: now()),
              MacRelay.Keys.verify(frame.proof, key: MacRelay.Keys.pairing(code: offer.code), nonce: peer.nonce, phone: id, kind: .pair) else {
            return refuse(peer, "That code didn’t work. Codes work once, for ten minutes: make a new one on your Mac.")
        }
        self.offer?.used = true
        let phone = MacRelayPairedPhone(id: id, name: String((frame.name ?? "iPhone").prefix(80)), key: MacRelay.Keys.make(), paired: now())
        onPaired?(phone)
        peer.channel.send(.make(.paired) { $0.v = Self.speaks(frame.v); $0.mac = mac; $0.name = name; $0.key = phone.key.base64EncodedString() })
    }

    /// The phone unpaired itself: proved with its key over this connection's nonce, its turns stop, the
    /// Mac confirms with `unpaired`, and the phone is removed (`onUnpaired`: its key leaves the listener).
    private func unpair(_ frame: MacRelay.Frame, phone: UUID, peer: Peer) {
        guard frame.phone == phone, let key = phones().first(where: { $0.id == phone })?.key,
              MacRelay.Keys.verify(frame.proof, key: key, nonce: peer.nonce, phone: phone, kind: .unpair) else { return }
        for (turn, running) in turns where running.phone == phone { runner.stop(turn: turn) }
        results = results.filter { $0.value.phone != phone }
        peer.channel.close(sending: .make(.unpaired) { $0.mac = mac; $0.phone = phone })
        drop(ObjectIdentifier(peer))
        onUnpaired?(phone)
    }

    private func send(_ frame: MacRelay.Frame, phone: UUID, peer: Peer) {
        guard let chat = frame.chat, let turn = frame.turn else { return }
        // A turn the Mac already has: the phone sent it again after reconnecting.
        if turns[turn] != nil || results[turn] != nil { return resume(turn, phone: phone, peer: peer) }
        let text = (frame.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= MacRelay.maxText else {
            return peer.channel.send(.make(.failed) { $0.turn = turn; $0.problem = "Send a message of up to \(MacRelay.maxText) characters." })
        }
        // Without an agent (a version 1 phone), the chat is with Claude.
        let id = frame.agent.flatMap { $0.isEmpty ? nil : $0 } ?? ChatHandoff.claudeAgentID
        guard let agent = runner.agents.first(where: { $0.id == id }) else {
            return peer.channel.send(.make(.failed) { $0.turn = turn; $0.problem = "That agent isn’t on your Mac any more. Choose another in the model menu." })
        }
        guard !turns.values.contains(where: { $0.chat == chat }) else {
            return peer.channel.send(.make(.failed) { $0.turn = turn; $0.problem = "\(agent.name) is still answering in this chat. Wait for it, or stop it." })
        }
        if let problem = agent.problem {
            return peer.channel.send(.make(.failed) { $0.turn = turn; $0.problem = problem })
        }
        turns[turn] = Turn(chat: chat, phone: phone)
        runner.start(chat: chat, turn: turn, agent: agent.id, text: text, session: frame.session) { [weak self] update in self?.update(turn, update) }
    }

    private func update(_ turn: UUID, _ update: MacRelayTurnUpdate) {
        guard var running = turns[turn] else { return }
        let frame: MacRelay.Frame
        switch update {
        case .delta(let text):
            running.text = text; turns[turn] = running
            channel(for: running.phone)?.send(.make(.delta) { $0.turn = turn; $0.text = text })
            return
        case .done(let reply, let session): frame = .make(.done) { $0.chat = running.chat; $0.turn = turn; $0.reply = reply; $0.session = session }
        case .failed(let problem): frame = .make(.failed) { $0.chat = running.chat; $0.turn = turn; $0.problem = problem }
        }
        turns[turn] = nil
        prune()
        results[turn] = (frame, running.phone, now())
        channel(for: running.phone)?.send(frame)
    }

    private func resume(_ turn: UUID?, phone: UUID, peer: Peer) {
        guard let turn else { return }
        prune()
        if let result = results[turn], result.phone == phone { peer.channel.send(result.frame) }
        else if let running = turns[turn], running.phone == phone { peer.channel.send(.make(.running) { $0.chat = running.chat; $0.turn = turn; $0.text = running.text }) }
        else { peer.channel.send(.make(.failed) { $0.turn = turn; $0.problem = "That reply isn’t on your Mac any more." }) }
    }

    private func prune() {
        let cutoff = now().addingTimeInterval(-MacRelay.resultLifetime)
        results = results.filter { $0.value.at > cutoff }
    }

    /// The newest connection from a phone.
    private func channel(for phone: UUID) -> MacRelayChannel? { peers.values.filter { $0.phone == phone }.max { $0.serial < $1.serial }?.channel }

    /// An agent's `ask_kemosabe` in a phone's chat: the phone's KemoSabe answers. Status and text for the MCP helper.
    func ask(_ ask: MacRelayAsk) async -> (status: String, text: String) {
        guard let running = turns.first(where: { $0.value.chat == ask.chat }), let channel = channel(for: running.value.phone) else {
            return ("unavailable", MacRelay.phoneUnreachable)
        }
        let turn = running.key, phone = running.value.phone, id = ask.id, timeout = askTimeout
        return await withCheckedContinuation { continuation in
            asks[id] = (phone, continuation)
            channel.send(.make(.ask) {
                $0.chat = ask.chat; $0.turn = turn; $0.ask = id; $0.text = ask.question; $0.purpose = ask.purpose; $0.agent = ask.agent; $0.client = ask.client
            })
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                guard let waiting = self?.asks.removeValue(forKey: id) else { return }
                waiting.reply.resume(returning: ("waiting", "KemoSabe on the owner’s iPhone hasn’t answered yet. Ask again in a minute."))
            }
        }
    }
}

// MARK: Sync through the phone (version 3)

extension MacRelayHostCore {
    /// The connected phone that can carry the account's records, or why there's none (for the Account page).
    func syncLink() -> Result<RelaySyncLink, SyncError> {
        guard !phones().isEmpty else { return .failure(.unavailable(MacRelaySync.notPaired)) }
        let live = peers.filter { $0.value.phone != nil }
        guard !live.isEmpty else { return .failure(.unavailable(MacRelaySync.waiting)) }
        guard let (id, _) = live.filter({ $0.value.hub }).max(by: { $0.value.serial < $1.value.serial }) else {
            return .failure(.unavailable(live.values.contains { $0.version < 3 }
                ? "Update KemoSabe on your iPhone to sync with it." : MacRelaySync.noHub))
        }
        return .success(HostSyncLink(core: self, peer: id))
    }
    /// A phone that carries the account's records is connected now.
    var hasSyncHub: Bool { peers.values.contains { $0.phone != nil && $0.hub } }

    /// Sends one sync request on a connection and waits for its answer.
    fileprivate func request(_ frame: MacRelay.Frame, peer id: ObjectIdentifier) async throws -> MacRelay.Frame {
        guard let peer = peers[id], peer.phone != nil, let request = frame.request else { throw SyncError.unavailable(MacRelaySync.waiting) }
        let timeout = syncTimeout
        let answer: MacRelay.Frame = try await withCheckedThrowingContinuation { continuation in
            syncRequests[request] = (id, continuation)
            peer.channel.send(frame)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                guard let waiting = self?.syncRequests.removeValue(forKey: request) else { return }
                waiting.reply.resume(throwing: SyncError.network("Your iPhone didn't answer in time. Sync will try again."))
            }
        }
        if answer.type == .syncFailed { throw SyncError.unavailable(answer.problem ?? MacRelaySync.noHub) }
        return answer
    }
}

/// One phone connection, as the Mac's sync transport sees it.
@MainActor private final class HostSyncLink: RelaySyncLink {
    let core: MacRelayHostCore
    let peer: ObjectIdentifier
    init(core: MacRelayHostCore, peer: ObjectIdentifier) { self.core = core; self.peer = peer }
    func pull(token: String?) async throws -> (records: [SyncRecord], token: String?, more: Bool) {
        let answer = try await core.request(.make(.syncPull) { $0.request = UUID(); $0.token = token }, peer: peer)
        return (answer.records ?? [], answer.token, answer.more == true)
    }
    func push(_ records: [SyncRecord]) async throws {
        _ = try await core.request(.make(.syncPush) { $0.request = UUID(); $0.records = records }, peer: peer)
    }
}

// MARK: The phone's end

@MainActor final class MacRelayClient {
    struct Welcome: Equatable, Sendable {
        let mac: UUID
        let name: String
        var claude: MacRelay.AgentState
        /// Every agent the Mac runs for this phone; nil from a version 1 Mac, which runs only Claude.
        var agents: [MacRelay.Agent]? = nil
        /// The version both sides speak.
        var version = MacRelay.version
        /// The agents to offer: the Mac's list, or Claude alone from a version 1 Mac.
        var offered: [MacRelay.Agent] {
            agents ?? [.init(id: ChatAgents.claude.id, name: ChatAgents.claude.title, product: ChatAgents.claude.product, state: claude)]
        }
    }
    let phone: UUID
    let key: Data
    let name: String
    private(set) var welcome: Welcome?
    private(set) var channel: MacRelayChannel?
    var onWelcome: ((Welcome) -> Void)?
    /// The connection ended, with the Mac's reason or the network's.
    var onClose: ((String?) -> Void)?
    var onTurn: ((UUID, MacRelayTurnUpdate) -> Void)?
    /// The agent asked KemoSabe: the phone's answer (status and text).
    var onAsk: ((MacRelayAsk) async -> (status: String, text: String))?
    /// The Mac confirmed it removed this phone (`unpaired`).
    var onUnpaired: (() -> Void)?
    /// Carries the account's records for a Mac without iCloud (`MacRelaySync`); nil when this phone can't.
    var syncHub: RelaySyncHub?
    private var refusal: String?
    /// This connection's nonce, for proofs after `hello` (`unpair`).
    private var nonce: String?

    init(phone: UUID, key: Data, name: String) { self.phone = phone; self.key = key; self.name = name }

    var isConnected: Bool { welcome != nil && channel != nil }

    /// Answers the Mac's challenge on a new channel.
    func start(_ channel: MacRelayChannel) {
        self.channel?.close()
        self.channel = channel; welcome = nil; refusal = nil; nonce = nil
        channel.onFrame = { [weak self] frame in self?.handle(frame) }
        channel.onClose = { [weak self] problem in self?.closed(problem) }
    }
    func close() {
        channel?.close(); channel = nil; welcome = nil
    }
    private func closed(_ problem: String?) {
        channel = nil; welcome = nil
        onClose?(refusal ?? problem)
    }

    /// Sends a turn with `agent` (its chat ID). A version 1 Mac runs only Claude, so it's never sent another agent.
    @discardableResult func send(chat: UUID, turn: UUID, text: String, session: String?, agent: String = ChatHandoff.claudeAgentID) -> Bool {
        guard isConnected, let channel, let welcome else { return false }
        guard welcome.agents != nil || agent == ChatHandoff.claudeAgentID else { return false }
        channel.send(.make(.send) { $0.chat = chat; $0.turn = turn; $0.text = text; $0.session = session; if welcome.agents != nil { $0.agent = agent } })
        return true
    }
    func stop(turn: UUID) { channel?.send(.make(.stop) { $0.turn = turn }) }
    func resume(turn: UUID) { channel?.send(.make(.resume) { $0.turn = turn }) }
    func ping() { channel?.send(.init(.ping)) }
    /// Tells a Mac that syncs through this phone that there's something new.
    func syncChanged() {
        guard isConnected, (welcome?.version ?? 0) >= 3, syncHub?.isAvailable == true else { return }
        channel?.send(.init(.syncChanged))
    }
    private static func problem(_ error: Error) -> String {
        if case SyncError.unavailable(let message)? = error as? SyncError { return message }
        return "Your iPhone couldn't read its synced copy right now. Sync will try again."
    }
    /// Asks the Mac to remove this phone, proving it holds its key. False when not connected; the Mac
    /// answers `unpaired` (`onUnpaired`).
    @discardableResult func unpair() -> Bool {
        guard isConnected, let channel, let nonce else { return false }
        channel.send(.make(.unpair) { $0.phone = phone; $0.proof = MacRelay.Keys.proof(key: key, nonce: nonce, phone: phone, kind: .unpair) })
        return true
    }

    private func handle(_ frame: MacRelay.Frame) {
        switch frame.type {
        case .challenge:
            guard let nonce = frame.nonce else { return }
            self.nonce = nonce
            // The lower of the two versions: a version 1 Mac hears version 1.
            let version = MacRelay.agreed(frame.v) ?? MacRelay.version
            channel?.send(.make(.hello) {
                $0.v = version; $0.phone = phone; $0.name = name; $0.build = Self.build
                if version >= 3, syncHub?.isAvailable == true { $0.sync = MacRelaySync.hub }
                $0.proof = MacRelay.Keys.proof(key: key, nonce: nonce, phone: phone, kind: .hello)
            })
        case .welcome:
            guard let mac = frame.mac else { return }
            let version = MacRelay.agreed(frame.v) ?? MacRelay.oldestVersion
            let welcome = Welcome(mac: mac, name: frame.name ?? "Mac", claude: frame.claude ?? .installed,
                                  agents: version >= 2 ? frame.agents.map { Array($0.prefix(MacRelay.maxAgents)) } : nil, version: version)
            self.welcome = welcome
            onWelcome?(welcome)
        case .pong:
            guard var next = welcome else { return }
            if let claude = frame.claude { next.claude = claude }
            if next.version >= 2, let agents = frame.agents { next.agents = Array(agents.prefix(MacRelay.maxAgents)) }
            if next != welcome { welcome = next; onWelcome?(next) }
        case .refused: refusal = frame.problem
        case .unpaired: if frame.phone == nil || frame.phone == phone { onUnpaired?() }
        case .delta, .running: if let turn = frame.turn { onTurn?(turn, .delta(frame.text ?? "")) }
        case .done: if let turn = frame.turn { onTurn?(turn, .done(reply: frame.reply ?? "", session: frame.session)) }
        case .failed: if let turn = frame.turn { onTurn?(turn, .failed(frame.problem ?? "Your Mac couldn’t finish that.")) }
        case .syncPull:
            guard let request = frame.request else { return }
            do {
                guard let hub = syncHub else { throw SyncError.unavailable(MacRelaySync.noHub) }
                let page = try hub.pull(token: frame.token)
                channel?.send(.make(.syncRecords) { $0.request = request; $0.records = page.records; $0.token = page.token; $0.more = page.more })
            } catch { channel?.send(.make(.syncFailed) { $0.request = request; $0.problem = Self.problem(error) }) }
        case .syncPush:
            guard let request = frame.request else { return }
            do {
                guard let hub = syncHub else { throw SyncError.unavailable(MacRelaySync.noHub) }
                try hub.push(frame.records ?? [])
                channel?.send(.make(.syncAck) { $0.request = request })
            } catch { channel?.send(.make(.syncFailed) { $0.request = request; $0.problem = Self.problem(error) }) }
        case .ask:
            guard let id = frame.ask, let chat = frame.chat else { return }
            let ask = MacRelayAsk(id: id, chat: chat, question: frame.text ?? "", purpose: frame.purpose ?? "", agent: frame.agent, client: frame.client)
            Task { @MainActor [weak self] in
                let answer: (status: String, text: String) = await self?.onAsk?(ask) ?? ("unavailable", MacRelay.phoneUnreachable)
                self?.channel?.send(.make(.answer) { $0.ask = id; $0.status = answer.status; $0.text = answer.text })
            }
        default: break
        }
    }

    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "" }
}

/// Unpairing, the phone's side: the Mac is told (`unpair`, proved with this phone's key) now if it's
/// connected, or first thing on the next connection, and the phone keeps its key until the Mac confirms
/// (`unpaired`). Pending survives relaunches. "Forget anyway" (`cancel`) is the owner's way out when the
/// Mac never answers (an older Tsukumo, or a Mac that already removed this phone).
@MainActor @Observable final class MacRelayUnpairing {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String
    private(set) var pending: Bool
    /// The Mac confirmed: forget it and its key now.
    @ObservationIgnored var onConfirmed: (() -> Void)?

    init(defaults: UserDefaults, key: String = "kemo.relay.unpair") {
        self.defaults = defaults; self.key = key
        pending = defaults.bool(forKey: key)
    }
    /// The owner unpaired: tells the Mac now when `client` is connected, otherwise on the next connection.
    func request(over client: MacRelayClient?) {
        set(true)
        if let client { send(over: client) }
    }
    /// A connection to the Mac is up (after `welcome`). True when an unpair is pending and was sent,
    /// so the connection is only for that.
    func connected(_ client: MacRelayClient) -> Bool {
        guard pending else { return false }
        send(over: client)
        return true
    }
    /// Forget anyway, or pairing another Mac: nothing is pending any more.
    func cancel() { set(false) }

    private func send(over client: MacRelayClient) {
        client.onUnpaired = { [weak self] in
            guard let self, self.pending else { return }
            self.set(false)
            self.onConfirmed?()
        }
        client.unpair()
    }
    private func set(_ value: Bool) {
        pending = value
        if value { defaults.set(true, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

/// Pairing over a channel opened with the code's key: proves the code, and gets this phone's own key.
@MainActor enum MacRelayPairing {
    struct Paired: Equatable, Sendable { let mac: UUID; let name: String; let key: Data }
    static func pair(over channel: MacRelayChannel, phone: UUID, name: String, code: String, timeout: Duration = .seconds(15)) async -> Result<Paired, MacRelay.Failure> {
        await withCheckedContinuation { continuation in
            var finished = false, refusal: String?
            @MainActor func done(_ result: Result<Paired, MacRelay.Failure>) {
                guard !finished else { return }
                finished = true
                channel.onFrame = nil; channel.onClose = nil; channel.close()
                continuation.resume(returning: result)
            }
            channel.onFrame = { frame in
                switch frame.type {
                case .challenge:
                    guard let nonce = frame.nonce else { return }
                    let version = MacRelay.agreed(frame.v) ?? MacRelay.version
                    channel.send(.make(.pair) {
                        $0.v = version; $0.phone = phone; $0.name = name; $0.build = MacRelayClient.build
                        $0.proof = MacRelay.Keys.proof(key: MacRelay.Keys.pairing(code: code), nonce: nonce, phone: phone, kind: .pair)
                    })
                case .paired:
                    guard let mac = frame.mac, let key = frame.key.flatMap({ Data(base64Encoded: $0) }), key.count == 32 else {
                        return done(.failure(.init("Your Mac sent something KemoSabe couldn’t read.")))
                    }
                    done(.success(.init(mac: mac, name: frame.name ?? "Mac", key: key)))
                case .refused: refusal = frame.problem
                default: break
                }
            }
            channel.onClose = { problem in done(.failure(.init(refusal ?? problem ?? "Your Mac closed the connection."))) }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                done(.failure(.init("Your Mac didn’t answer. Check that it’s on the same Wi‑Fi and showing the code.")))
            }
        }
    }
}

// MARK: The phone's chat

extension AgentQuestionDesk {
    /// The agent's question from the Mac, answered by this device's KemoSabe exactly as the Mac answers
    /// its own: the same consent (on the chat's card), the same policy, and the chat's cards (`handoff`).
    func answer(_ ask: MacRelayAsk) async -> (status: String, text: String) {
        guard let requester = AgentIdentity.requester(agent: ask.agent ?? ChatHandoff.claudeAgentID, clientName: ask.client, clientTitle: nil) else {
            return (AgentAnswer.refused("").status, "KemoSabe needs to know which agent is asking.")
        }
        let answer = await self.ask(.init(requester: requester, question: ask.question.trimmingCharacters(in: .whitespacesAndNewlines),
                                          purpose: ask.purpose.trimmingCharacters(in: .whitespacesAndNewlines), client: ask.client, handoff: ask.chat))
        return (answer.status, answer.text())
    }
}

/// A chat with an agent on this phone, run on the paired Mac: your message and the agent's reply in the
/// chat (`ChatHandoffTranscript`, the same cards as on the Mac), KemoSabe's answers from this phone,
/// stop, and turns picked up again after the connection comes back.
@MainActor final class MacRelayPhoneSession {
    weak var store: AppStore?
    private(set) var client: MacRelayClient?
    /// Turns waiting for their end, by turn: the chat each belongs to.
    private(set) var turns: [UUID: UUID] = [:]
    /// Each waiting turn's agent: its chat ID and name.
    private var agents: [UUID: (id: String, name: String)] = [:]

    /// Uses a newly connected client, and asks the Mac for any turn that was running when the last one dropped.
    func attach(_ client: MacRelayClient) {
        self.client = client
        client.onTurn = { [weak self] turn, update in self?.update(turn, update) }
        client.onAsk = { [weak self] ask in
            guard let self, let desk = self.store?.agentQuestions, self.turns.values.contains(ask.chat) else { return ("unavailable", MacRelay.phoneUnreachable) }
            return await desk.answer(ask)
        }
        if client.isConnected { for turn in turns.keys { client.resume(turn: turn) } }
    }
    func detach() { client = nil }

    /// The chat on screen's turn, while it runs.
    func running(in store: AppStore) -> UUID? {
        guard let chat = store.agentChat.id else { return nil }
        return turns.first { $0.value == chat }?.key
    }

    /// Sends your message to the chat's agent through the Mac. False (with the reason in `store.error`)
    /// when the Mac can't take it.
    @discardableResult func send(_ text: String, store: AppStore) -> Bool {
        self.store = store
        let id = store.state.chatAgent ?? ChatHandoff.claudeAgentID
        let fallback = ChatAgents.kind(id)?.title ?? "Your agent"
        guard let client, client.isConnected, let welcome = client.welcome else {
            store.error = "Your Mac isn’t connected, so \(fallback) can’t answer here."
            return false
        }
        guard let agent = welcome.offered.first(where: { $0.id == id }) else {
            store.error = welcome.agents == nil
                ? "Update Tsukumo on your Mac to chat with \(fallback) here. Claude works through it now."
                : "\(fallback) isn’t on \(welcome.name). Choose another agent in the model menu."
            return false
        }
        if let problem = agent.problem { store.error = problem; return false }
        let current = store.agentChat
        let chat = current.id ?? UUID()
        guard !turns.values.contains(chat) else { store.error = "\(agent.name) is still answering. Wait for it, or stop it."; return false }
        store.error = nil
        let turn = UUID()
        ChatHandoffTranscript.beginTurn(chat, text: text, agent: agent.name, agentID: agent.id, store: store)
        turns[turn] = chat; agents[turn] = (agent.id, agent.name)
        // The chat's context card goes to the agent once, ahead of the message; its session keeps it.
        let packet = store.packetDelivery(for: .codingAgent(agent.id), limit: ContextPacketBuilder.largeLimit, firstOnly: true)
        client.send(chat: chat, turn: turn, text: packet.map { $0.text + "\n\n" + text } ?? text, session: current.session, agent: agent.id)
        if let packet { store.recordPacketDelivery(packet) }
        return true
    }

    /// Ends every turn waiting here with `problem` (this iPhone is unpairing from its Mac).
    func endAll(_ problem: String) {
        for turn in turns.keys { update(turn, .failed(problem)) }
    }

    /// Stops the chat on screen's turn: the Mac stops the agent; without a connection it ends here.
    func stop(store: AppStore) {
        guard let turn = running(in: store) else { return }
        if let client, client.isConnected { client.stop(turn: turn) }
        else { update(turn, .failed("Stopped.")) }
    }

    private func update(_ turn: UUID, _ update: MacRelayTurnUpdate) {
        guard let chat = turns[turn], let store else { return }
        switch update {
        case .delta(let text):
            store.streamHandoff(chat, text)
        case .done(let reply, let session):
            let agent = agents.removeValue(forKey: turn) ?? (ChatHandoff.claudeAgentID, ChatHandoff.claude)
            turns[turn] = nil
            ChatHandoffTranscript.finishTurn(chat, agent: agent.name, agentID: agent.id, reply: reply, session: session, store: store)
        case .failed(let problem):
            let agent = agents.removeValue(forKey: turn) ?? (ChatHandoff.claudeAgentID, ChatHandoff.claude)
            turns[turn] = nil
            ChatHandoffTranscript.finishTurn(chat, agent: agent.name, agentID: agent.id, reply: nil, session: nil, problem: problem.isEmpty ? nil : problem, store: store)
        }
    }
}

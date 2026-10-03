import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import Network
import Observation
import SystemConfiguration

// Agents on your Mac, the Mac's side (design/CONTEXT-HARNESS.md#your-macs-agents-from-iphone). While
// Settings → Models → Agents on your Mac is on, Tsukumo advertises itself on this Wi‑Fi and answers the
// iPhones paired with it: each message from an iPhone's chat with an agent runs here through
// `KemoSabeHandoff.startTurn` (the owner's own Claude Code, Codex, Muse Code, Cursor Agent, or added ACP
// agent, headless, on their own sign-in, with the same flags as the Mac's own chat), and the reply
// streams back. The agent's questions for KemoSabe in those chats go back to the iPhone, whose KemoSabe
// answers them. Those chats keep their own session handle here and never show in this Mac's chat list.
// Nothing about any agent's sign-in leaves this Mac; the iPhone only ever gets replies and each agent's
// state (installed, signed in).
//
// Paired iPhones and their keys are in `Application Support/Tsukumo/Relay/phones.json` (a 0700 folder,
// a 0600 file). Pairing: a code on screen (and its QR code), single-use and good for ten minutes.

@MainActor @Observable final class KemoSabeRelay {
    static let shared: KemoSabeRelay = { let relay = KemoSabeRelay(); relay.carrySync(); return relay }()
    enum Status: Equatable { case off, starting, listening, failed(String) }
    private(set) var status: Status = .off
    private(set) var enabled: Bool
    /// Keeps the Mac from idle sleep while this is on and it's on power.
    var keepAwake: Bool { didSet { defaults.set(keepAwake, forKey: Self.keepAwakeKey); updateAwake() } }
    /// Holding the no-idle-sleep assertion now.
    private(set) var awake = false
    private(set) var offer: MacRelay.PairingOffer?
    private(set) var phones: [MacRelayPairedPhone] = []
    private(set) var connected: Set<UUID> = []
    private(set) var problem: String?
    let mac: UUID

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let folder: URL
    @ObservationIgnored private let listener = MacRelayListener()
    @ObservationIgnored private(set) var core: MacRelayHostCore!
    @ObservationIgnored let turns: KemoSabeRelayTurns
    @ObservationIgnored private let allowed = AllowList()
    /// Tests listen on localhost without Bonjour.
    @ObservationIgnored var advertise = true
    @ObservationIgnored var nameOverride: String?
    @ObservationIgnored private var assertion: IOPMAssertionID = 0
    @ObservationIgnored private var powerSource: CFRunLoopSource?

    static let enabledKey = "tsukumo.relay.enabled", keepAwakeKey = "tsukumo.relay.keepAwake", macKey = "tsukumo.relay.mac"

    init(defaults: UserDefaults = .standard, folder: URL = KemoSabeRelay.defaultFolder, handoff: KemoSabeHandoff = .shared) {
        self.defaults = defaults
        self.folder = folder
        if let saved = defaults.string(forKey: Self.macKey).flatMap(UUID.init(uuidString:)) { mac = saved }
        else { mac = UUID(); defaults.set(mac.uuidString, forKey: Self.macKey) }
        enabled = defaults.bool(forKey: Self.enabledKey)
        keepAwake = defaults.object(forKey: Self.keepAwakeKey) as? Bool ?? true
        turns = KemoSabeRelayTurns(handoff: handoff, file: folder.appendingPathComponent("chats.json"))
        phones = Self.load([MacRelayPairedPhone].self, from: folder.appendingPathComponent("phones.json")) ?? []
        core = MacRelayHostCore(mac: mac, name: name, runner: turns) { [weak self] in self?.phones ?? [] }
        core.onPaired = { [weak self] phone in self?.paired(phone) }
        core.onSeen = { [weak self] phone in self?.seen(phone) }
        core.onChange = { [weak self] in if let self { self.connected = self.core.connected } }
        // An iPhone unpaired itself (Models → Agents on your Mac → Unpair): removed here too.
        core.onUnpaired = { [weak self] phone in self?.remove(phone) }
        listener.onConnection = { [weak self] connection in
            guard let self else { connection.close(); return }
            self.core.accept(connection)
        }
        listener.onState = { [weak self] state in self?.listenerChanged(state) }
    }

    /// This Mac has no iCloud (the Homebrew and website builds): its account syncs through the paired
    /// iPhone while it's connected (`MacRelaySync`). A phone that can carry the records connecting, or
    /// saying it has something new, starts a sync.
    func carrySync() {
        MacRelaySync.macLink = { [weak self] in self?.core.syncLink() ?? .failure(.unavailable(MacRelaySync.notPaired)) }
        var hadHub = false
        let changed = core.onChange
        core.onChange = { [weak self] in
            changed?()
            guard let self else { return }
            let hub = self.core.hasSyncHub
            if hub, !hadHub, MacRelaySync.usesRelay { AccountSyncService.shared.syncSoon(after: .seconds(1)) }
            hadHub = hub
        }
        core.onSyncChanged = { if MacRelaySync.usesRelay { AccountSyncService.shared.syncSoon(after: .seconds(2)) } }
    }

    nonisolated static var defaultFolder: URL {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return FileManager.default.temporaryDirectory.appendingPathComponent("KemoSabeRelay-" + UUID().uuidString, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Tsukumo/Relay", isDirectory: true)
    }
    /// This Mac's name, as the iPhone shows it.
    var name: String { nameOverride ?? (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac" }

    // MARK: On and off

    /// Starts at launch when it was left on.
    func startIfEnabled() {
        guard enabled else { return }
        start()
    }
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        defaults.set(on, forKey: Self.enabledKey)
        if on { start(); if phones.isEmpty { newCode() } } else { stop() }
    }
    private func start() {
        problem = nil
        core.name = name
        restartListener()
        watchPower()
        updateAwake()
        // What the iPhone is told about each agent comes from its own status command.
        Task { await CodingAgentRegistry.shared.checkSignIn() }
    }
    private func stop() {
        listener.stop()
        core.disconnectAll()
        turns.stopAll()
        offer = nil; core.offer = nil; allowed.set(offer: nil)
        connected = []
        status = .off
        updateAwake()
    }
    /// Stops for quitting.
    func shutDown() {
        listener.stop(); core.disconnectAll(); turns.stopAll()
        release()
    }

    /// The port the listener got (tests connect to it on localhost).
    var port: UInt16? { listener.port }

    private func restartListener() {
        guard enabled else { return }
        var keys: [String: Data] = [:]
        for phone in phones { keys[MacRelay.identity(phone: phone.id)] = phone.key }
        if let offer, offer.isOpen() { keys[MacRelay.pairingIdentity] = MacRelay.Keys.pairing(code: offer.code) }
        allowed.set(phones: Set(phones.map(\.id)))
        allowed.set(offer: offer)
        guard !keys.isEmpty else { listener.stop(); status = .listening; return }
        let allowed = allowed
        listener.start(keys: keys, allow: { allowed.allows($0) }, service: advertise ? (name, mac) : nil)
    }
    private func listenerChanged(_ state: MacRelayListener.State) {
        switch state {
        case .ready: status = .listening; problem = nil
        case .starting: status = .starting
        case .failed(let reason): status = .failed(reason); problem = reason
        case .stopped: if !enabled { status = .off }
        }
    }

    // MARK: Pairing

    /// A new code, replacing any other.
    func newCode() {
        guard enabled else { return }
        let offer = MacRelay.PairingOffer()
        self.offer = offer; core.offer = offer
        restartListener()
    }
    /// What the QR code holds.
    var invite: MacRelay.Invite? { offer.map { .init(mac: mac, name: name, code: $0.code) } }
    private func paired(_ phone: MacRelayPairedPhone) {
        phones.removeAll { $0.id == phone.id }
        phones.append(phone)
        savePhones()
        offer?.used = true
        allowed.set(offer: offer)
        restartListener()
    }
    private func seen(_ phone: UUID) {
        guard let index = phones.firstIndex(where: { $0.id == phone }) else { return }
        phones[index].lastSeen = Date()
        savePhones()
    }
    /// Remove (here, or the iPhone's own Unpair): the iPhone's key is gone, its connections close, and
    /// the listener restarts without its key.
    func remove(_ phone: UUID) {
        phones.removeAll { $0.id == phone }
        savePhones()
        core.disconnect(phone: phone)
        connected = core.connected
        restartListener()
    }
    private func savePhones() {
        do { try Self.save(phones, to: folder.appendingPathComponent("phones.json")) }
        catch { problem = "Couldn’t save the paired iPhones: " + error.localizedDescription }
    }

    // MARK: The agent's questions

    /// An agent's `ask_kemosabe` from a turn an iPhone started: the iPhone's KemoSabe answers. Nil when the
    /// question isn't from an iPhone's chat (this Mac's KemoSabe answers it as usual).
    func answer(_ request: KemoSabeBridgeWire.Request) async -> KemoSabeBridgeWire.Response? {
        guard let chat = request.handoff.flatMap(UUID.init(uuidString:)), turns.owns(chat: chat) else { return nil }
        let client = [request.client?.name, request.client?.version].compactMap { $0 }.joined(separator: " ")
        let result = await core.ask(.init(id: UUID(), chat: chat, question: request.question.trimmingCharacters(in: .whitespacesAndNewlines),
                                          purpose: request.purpose.trimmingCharacters(in: .whitespacesAndNewlines), agent: request.agent,
                                          client: client.isEmpty ? nil : client))
        let status = KemoSabeBridgeWire.Status(rawValue: result.status) ?? .unavailable
        return .init(status: status == .notRunning ? KemoSabeBridgeWire.Status.unavailable.rawValue : status.rawValue, text: result.text)
    }

    // MARK: Keeping awake

    /// On power, with Agents on your Mac and Keep awake on: no idle sleep. The display may still sleep.
    func updateAwake() {
        let want = enabled && keepAwake && Self.onPower()
        guard want != awake else { return }
        if want {
            var id: IOPMAssertionID = 0
            let made = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                   "Agents on your Mac: answering your paired iPhone" as CFString, &id)
            guard made == kIOReturnSuccess else { return }
            assertion = id; awake = true
        } else { release() }
    }
    private func release() {
        guard awake else { return }
        IOPMAssertionRelease(assertion)
        assertion = 0; awake = false
    }
    static func onPower() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return true }
        return type == kIOPMACPowerKey
    }
    private func watchPower() {
        guard powerSource == nil, self === KemoSabeRelay.shared,
              let source = IOPSNotificationCreateRunLoopSource({ _ in
                  DispatchQueue.main.async { MainActor.assumeIsolated { KemoSabeRelay.shared.updateAwake() } }
              }, nil)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        powerSource = source
    }

    // MARK: QR code

    /// The pairing link as a QR code, crisp at any size.
    static func qrCode(_ url: URL, side: CGFloat = 220) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = max(1, (side / output.extent.width).rounded(.down))
        let image = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: image.extent.width, height: image.extent.height))
    }

    // MARK: Files

    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    /// Written whole, owner-only: a 0700 folder and a 0600 file.
    static func save<T: Encodable>(_ value: T, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(folder.path, 0o700)
        let data = try JSONEncoder().encode(value)
        let temporary = folder.appendingPathComponent("." + url.lastPathComponent + "." + UUID().uuidString)
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw MacRelay.Failure("Couldn’t write \(url.lastPathComponent).")
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        chmod(url.path, 0o600)
    }

    /// Who may finish a handshake right now, read on the TLS queue.
    final class AllowList: @unchecked Sendable {
        private let lock = NSLock()
        private var phones: Set<UUID> = []
        private var offerOpenUntil: Date?
        func set(phones: Set<UUID>) { lock.withLock { self.phones = phones } }
        func set(offer: MacRelay.PairingOffer?) { lock.withLock { offerOpenUntil = offer.flatMap { $0.used ? nil : $0.expires } } }
        func allows(_ identity: String) -> Bool {
            lock.withLock {
                if identity == MacRelay.pairingIdentity { return offerOpenUntil.map { Date() < $0 } ?? false }
                return MacRelay.phone(identity: identity).map { phones.contains($0) } ?? false
            }
        }
    }
}

/// Runs iPhones' turns with `KemoSabeHandoff`, keeping each iPhone chat's agent session (to continue it).
@MainActor final class KemoSabeRelayTurns: MacRelayTurnRunner {
    let handoff: KemoSabeHandoff
    let file: URL
    /// Each iPhone chat's agent session, by the iPhone's chat ID (a chat is with one agent).
    private(set) var sessions: [UUID: String]
    /// The chat of each running turn.
    private var chats: [UUID: UUID] = [:]
    /// Tests set what the iPhone is told about Claude Code.
    var claudeOverride: MacRelay.AgentState?
    /// Tests set every agent the iPhone is told about.
    var agentsOverride: [MacRelay.Agent]?

    init(handoff: KemoSabeHandoff, file: URL) {
        self.handoff = handoff; self.file = file
        sessions = KemoSabeRelay.load([UUID: String].self, from: file) ?? [:]
    }

    /// Claude Code (always, so the iPhone can say it isn't installed), then each other agent that's
    /// installed here, with its sign-in: what the iPhone's model menu lists.
    var agents: [MacRelay.Agent] {
        if let agentsOverride { return agentsOverride }
        let registry = CodingAgentRegistry.shared
        var list: [MacRelay.Agent] = registry.adapters.compactMap { adapter in
            let provider = adapter.provider
            let installed = registry.isInstalled(provider)
            guard installed || provider == .claude else { return nil }
            let id = KemoSabeHandoff.agentID(for: provider)
            let state: MacRelay.AgentState
            if !installed { state = .notInstalled } else {
                switch registry.signIn(provider) {
                case .signedIn: state = .signedIn
                case .signedOut: state = .signedOut
                case .unknown: state = .installed
                }
            }
            return .init(id: id, name: KemoSabeHandoff.title(for: id), product: KemoSabeHandoff.product(for: id), state: state)
        }
        if let claudeOverride, let index = list.firstIndex(where: { $0.id == ChatHandoff.claudeAgentID }) { list[index].state = claudeOverride }
        return list
    }
    func owns(chat: UUID) -> Bool { chats.values.contains(chat) }

    func start(chat: UUID, turn: UUID, agent: String, text: String, session: String?, update: @escaping (MacRelayTurnUpdate) -> Void) {
        chats[turn] = chat
        let started = handoff.startTurn(chat: chat, agent: agent, text: text, resume: sessions[chat] ?? session, handlers: .init(
            streaming: { update(.delta($0)) },
            finished: { [weak self] reply, handle, problem in
                guard let self else { return }
                self.chats[turn] = nil
                if let handle, self.sessions[chat] != handle {
                    self.sessions[chat] = handle
                    try? KemoSabeRelay.save(self.sessions, to: self.file)
                }
                if let reply, !reply.isEmpty { update(.done(reply: reply, session: handle)) }
                // The iPhone words it as the Mac's chat does ("Codex stopped. …").
                else { update(.failed(problem ?? "")) }
            }))
        if !started { chats[turn] = nil; update(.failed("\(KemoSabeHandoff.title(for: agent)) is still answering in this chat. Wait for it, or stop it.")) }
    }
    func stop(turn: UUID) {
        guard let chat = chats[turn] else { return }
        handoff.stopTurn(chat)
    }
    func stopAll() { for chat in Set(chats.values) { handoff.stopTurn(chat) } }
}

import Network
import Observation
import Security
import SwiftUI
import UIKit

// Agents on your Mac, the iPhone's side (design/CONTEXT-HARNESS.md#your-macs-agents-from-iphone). Pair once
// with the code your Mac shows (scan its QR code with the Camera, or type it in Settings → Models → Agents
// on your Mac); then choosing Claude, Codex, Muse Code, Cursor Agent, or another agent your Mac lists in
// the chat's model menu sends each message to that Mac, which runs it with its own copy of that agent and
// streams the reply here. The agent's questions for KemoSabe are answered by this iPhone's KemoSabe, with
// its own consent card. This iPhone never signs in to any agent or holds any agent's token: it has one
// key, for its own Mac, in the Keychain.
//
// Same Wi‑Fi only for now: the Mac is found with Bonjour. Nothing falls back to another model silently.

@MainActor @Observable final class MacRelayPhone {
    static let shared = MacRelayPhone()
    struct PairedMac: Codable, Equatable {
        let id: UUID
        var name: String
        let paired: Date
    }
    enum Status: Equatable {
        case notPaired, looking, connecting, connected
        /// The Mac isn't advertising on this Wi‑Fi (off, asleep, or another network).
        case notFound
        case problem(String)
    }
    private(set) var mac: PairedMac?
    private(set) var status: Status = .notPaired
    /// The agents the Mac said it runs, last time it was connected (kept, so the model menu lists them
    /// while it's looking); a Tsukumo that doesn't list them (version 1) runs Claude alone.
    private(set) var agents: [MacRelay.Agent] = []
    private(set) var pairing = false
    private(set) var pairingProblem: String?
    /// A scanned pairing link, waiting for the owner to confirm it.
    var pendingInvite: MacRelay.Invite?
    let session = MacRelayPhoneSession()
    /// Unpair: waiting for the Mac to confirm before the key is forgotten (`MacRelayUnpairing`).
    let unpairing: MacRelayUnpairing
    /// An unpair is waiting for the Mac: agent chats are paused and the key is kept until it confirms.
    var isUnpairing: Bool { mac != nil && unpairing.pending }
    let phone: UUID

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let browser = MacRelayBrowser()
    @ObservationIgnored private var client: MacRelayClient?
    @ObservationIgnored private var active = false
    @ObservationIgnored private var connecting = false
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var lookingSince: Date?

    private static let macKey = "kemo.relay.mac", phoneKey = "kemo.relay.phone", agentsKey = "kemo.relay.agents"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        unpairing = MacRelayUnpairing(defaults: defaults)
        if let saved = defaults.string(forKey: Self.phoneKey).flatMap(UUID.init(uuidString:)) { phone = saved }
        else { phone = UUID(); defaults.set(phone.uuidString, forKey: Self.phoneKey) }
        if let data = defaults.data(forKey: Self.macKey), let saved = try? JSONDecoder().decode(PairedMac.self, from: data),
           MacRelayKeychain.load(mac: saved.id) != nil {
            mac = saved; status = .looking
            agents = defaults.data(forKey: Self.agentsKey).flatMap { try? JSONDecoder().decode([MacRelay.Agent].self, from: $0) } ?? []
        }
        unpairing.onConfirmed = { [weak self] in self?.forget() }
        browser.onChange = { [weak self] found in self?.found(found) }
        browser.onProblem = { [weak self] problem in self?.status = .problem(problem) }
    }

    // MARK: Foreground and background

    /// The app came to the front (or left it). Connections only live while it's in front; a turn
    /// running on the Mac carries on, and its reply is picked up on return.
    func setActive(_ active: Bool, store: AppStore) {
        session.store = store
        self.active = active
        if active { connectIfNeeded() } else { disconnect() }
    }
    private func connectIfNeeded() {
        guard active, mac != nil, client == nil else { return }
        browser.start()
        if !connecting, status != .connected { status = .looking; lookingSince = Date() }
        found(browser.found)
        scheduleCheck()
    }
    private func disconnect() {
        retry?.cancel(); retry = nil
        client?.close(); client = nil; session.detach()
        browser.stop()
        if mac != nil, status == .connected || status == .connecting { status = .looking }
    }

    private func found(_ list: [MacRelayBrowser.Found]) {
        guard active, let mac, client == nil, !connecting, !pairing else { return }
        guard let match = list.first(where: { $0.mac == mac.id }) else { return }
        connect(to: match)
    }
    /// Says "not on this Wi‑Fi" when a few seconds of looking found nothing, and tries again later.
    private func scheduleCheck() {
        retry?.cancel()
        retry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled, self.active, self.mac != nil, self.client == nil, !self.connecting else { return }
            if self.status == .looking { self.status = .notFound }
            self.browser.stop(); self.browser.start()
            self.scheduleCheck()
        }
    }

    private func connect(to found: MacRelayBrowser.Found) {
        guard let mac, let key = MacRelayKeychain.load(mac: mac.id) else { return }
        connecting = true; status = .connecting
        let transport = MacRelayDirectTransport { found.endpoint }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let opened = await transport.open(mac: mac.id, identity: MacRelay.identity(phone: self.phone), key: key)
            self.connecting = false
            guard self.active, self.mac?.id == mac.id else { if case .success(let channel) = opened { channel.close() }; return }
            switch opened {
            case .failure(let failure):
                self.status = .problem(failure.message.contains("key") ? "\(mac.name) didn’t accept this iPhone. Pair it again: on your Mac, open \(MacRelay.macSettings)." : failure.message)
                self.scheduleCheck()
            case .success(let channel):
                let client = MacRelayClient(phone: self.phone, key: key, name: UIDevice.current.name)
                // A Mac without iCloud syncs the account's records through this iPhone (`MacRelaySync`).
                client.syncHub = RelaySyncHub.phone
                AccountSyncService.shared.onChanged = { [weak self] in self?.client?.syncChanged() }
                client.onWelcome = { [weak self, weak client] welcome in
                    guard let self, let client else { return }
                    self.status = .connected; self.remember(welcome.offered)
                    if welcome.name != self.mac?.name { self.rename(welcome.name) }
                    self.retry?.cancel()
                    // A pending unpair goes first; the connection is only for that.
                    if self.unpairing.connected(client) { return }
                    if self.session.client !== client { self.session.attach(client) }
                }
                client.onClose = { [weak self, weak client] problem in
                    guard let self, let client, self.client === client else { return }
                    self.client = nil; self.session.detach()
                    if let problem, problem.contains("isn’t paired") { self.status = .problem(problem); return }
                    self.status = .looking
                    guard self.active else { return }
                    self.retry?.cancel()
                    self.retry = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(2))
                        guard let self, !Task.isCancelled else { return }
                        self.found(self.browser.found); self.scheduleCheck()
                    }
                }
                self.client = client
                client.start(channel)
            }
        }
    }
    private func rename(_ name: String) {
        guard var mac else { return }
        mac.name = name; self.mac = mac; save(mac)
    }
    /// Keeps what the Mac said it runs, for the model menu while it's out of reach.
    func remember(_ list: [MacRelay.Agent]) {
        guard list != agents else { return }
        agents = list
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: Self.agentsKey) }
    }

    // MARK: Pairing

    /// Pairs with the Mac showing this code: finds it on this Wi‑Fi, proves the code, and keeps the key it sends.
    func pair(_ invite: MacRelay.Invite, store: AppStore) async {
        guard !pairing else { return }
        pendingInvite = nil
        pairing = true; pairingProblem = nil
        session.store = store
        defer { pairing = false }
        let wasActive = active
        active = true
        browser.start()
        var candidates: [MacRelayBrowser.Found] = []
        for _ in 0..<40 {
            candidates = browser.found.filter { invite.mac == nil || $0.mac == invite.mac }
            if !candidates.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        active = wasActive
        guard !candidates.isEmpty else {
            pairingProblem = "No Mac showing a code is on this Wi‑Fi. On your Mac, open \(MacRelay.macSettings) and turn it on, with this iPhone on the same Wi‑Fi."
            return
        }
        for candidate in candidates {
            let transport = MacRelayDirectTransport { candidate.endpoint }
            guard case .success(let channel) = await transport.open(mac: candidate.mac, identity: MacRelay.pairingIdentity, key: MacRelay.Keys.pairing(code: invite.code)) else {
                pairingProblem = "That code didn’t work. Codes work once, for ten minutes: make a new one on your Mac."
                continue
            }
            switch await MacRelayPairing.pair(over: channel, phone: phone, name: UIDevice.current.name, code: invite.code) {
            case .failure(let failure): pairingProblem = failure.message
            case .success(let paired):
                if let old = mac { MacRelayKeychain.delete(mac: old.id) }
                guard MacRelayKeychain.save(paired.key, mac: paired.mac) else { pairingProblem = "KemoSabe couldn’t save the key in this iPhone’s Keychain."; return }
                let saved = PairedMac(id: paired.mac, name: paired.name, paired: Date())
                // Pairing a Mac replaces any unpair still waiting for the one before.
                unpairing.cancel()
                disconnect()
                if mac?.id != saved.id { remember([]) }
                mac = saved; save(saved)
                status = .looking; pairingProblem = nil
                connectIfNeeded()
                return
            }
        }
    }
    /// Unpairs: agent chats here stop, and the Mac is told to remove this iPhone (now if it's connected,
    /// otherwise the next time it is). This iPhone keeps its key until the Mac confirms, then forgets it.
    func unpair() {
        guard mac != nil else { return }
        session.endAll("Stopped.")
        session.detach()
        unpairing.request(over: client?.isConnected == true ? client : nil)
        if client == nil { connectIfNeeded() }
    }
    /// Forgets the Mac and its key now: after the Mac confirmed the unpair, or "Forget anyway" (the Mac
    /// then still lists this iPhone until it's removed there).
    func forget() {
        unpairing.cancel()
        session.endAll("Stopped.")
        disconnect()
        if let mac { MacRelayKeychain.delete(mac: mac.id) }
        mac = nil; status = .notPaired
        remember([])
        defaults.removeObject(forKey: Self.macKey); defaults.removeObject(forKey: Self.agentsKey)
    }
    private func save(_ mac: PairedMac) {
        if let data = try? JSONEncoder().encode(mac) { defaults.set(data, forKey: Self.macKey) }
    }

    // MARK: The chat

    var isConnected: Bool { status == .connected && session.client?.isConnected == true }

    /// Sends a chat message to the chat's agent through the Mac, or says clearly why it can't.
    @discardableResult func send(_ text: String, store: AppStore) -> Bool {
        guard mac != nil else { store.error = "Pair your Mac first: \(MacRelay.phoneSettings)."; return false }
        guard !isUnpairing else { store.error = unreachable(store); return false }
        guard isConnected else { store.error = unreachable(store); connectIfNeeded(); return false }
        return session.send(text, store: store)
    }
    func stop(store: AppStore) { session.stop(store: store) }

    /// The chat's agent's name ("Codex"), for what the chat says.
    private func agentName(_ store: AppStore) -> String {
        let id = store.state.chatAgent ?? ChatHandoff.claudeAgentID
        return agents.first { $0.id == id }?.name ?? ChatAgents.kind(id)?.title ?? "Your agent"
    }
    /// Why the chat's agent can't answer here right now, and what the owner can do.
    func unreachable(_ store: AppStore) -> String {
        let agent = agentName(store)
        if isUnpairing, let mac { return "You unpaired \(mac.name), so \(agent) can’t answer here. Pair a Mac in \(MacRelay.phoneSettings)." }
        let name = mac?.name ?? "Your Mac"
        var line: String
        switch status {
        case .problem(let problem): line = problem
        case .connecting, .looking: line = "Still looking for \(name). Try again in a moment."
        default: line = "\(name) isn’t on this Wi‑Fi, so \(agent) can’t answer here. Put both on the same Wi‑Fi and wake your Mac."
        }
        if (store.state.chatAgent ?? ChatHandoff.claudeAgentID) == ChatHandoff.claudeAgentID, (store.state.apiProfiles ?? []).contains(where: { $0.wire == .anthropic }) {
            line += " You can also switch to your Claude API connection in the model menu."
        }
        return line
    }

    /// The model menu's agents: each one the Mac said it runs (Claude alone before it's said, or from a
    /// Tsukumo that doesn't list them), with where it stands. Before pairing, one row asks to pair.
    var options: [ChatAgentOption] {
        let listed = mac == nil || agents.isEmpty
            ? [MacRelay.Agent(id: ChatAgents.claude.id, name: ChatAgents.claude.title, product: ChatAgents.claude.product, state: .installed)]
            : agents.filter { $0.state != .notInstalled || $0.id == ChatHandoff.claudeAgentID }
        return listed.map { agent in
            var option = ChatAgentOption(id: agent.id, title: agent.name, logo: ChatAgents.kind(agent.id)?.logo ?? "", detail: detail(agent),
                                         available: mac != nil && !isUnpairing)
            if mac == nil || isUnpairing { option.actionTitle = "Pair"; option.signIn = { MacRelayPhone.shared.openSettings?() } }
            return option
        }
    }
    /// Opens Settings → Models → Agents on your Mac (set by the app's root).
    @ObservationIgnored var openSettings: (() -> Void)?
    /// Where the Mac stands, for every agent through it.
    var detail: String {
        guard let mac else { return "Pair your Mac in \(MacRelay.phoneSettings)" }
        if isUnpairing { return "Unpairing from \(mac.name)…" }
        switch status {
        case .notPaired: return "Pair your Mac in \(MacRelay.phoneSettings)"
        case .looking: return "Looking for \(mac.name)…"
        case .connecting: return "Connecting to \(mac.name)…"
        case .connected: return "Through \(mac.name) · connected"
        case .notFound: return "\(mac.name) isn’t on this Wi‑Fi"
        case .problem(let problem): return problem
        }
    }
    /// Where one agent stands: the Mac's line, or, while connected, whether it's installed and signed in there.
    func detail(_ agent: MacRelay.Agent) -> String {
        guard let mac, status == .connected, !isUnpairing else { return detail }
        switch agent.state {
        case .notInstalled: return "\(agent.product) isn’t installed on \(mac.name)"
        case .signedOut: return "Sign in to \(agent.product) on \(mac.name)"
        case .signedIn, .installed: return detail
        }
    }
}

/// This iPhone's key for its paired Mac, in the Keychain: this device only, never synced.
enum MacRelayKeychain {
    static let service = "com.zlichtman.kemosabe.relay"
    private static func query(_ mac: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: mac.uuidString,
         kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
    }
    static func save(_ key: Data, mac: UUID) -> Bool {
        SecItemDelete(query(mac) as CFDictionary)
        var item = query(mac)
        item[kSecValueData as String] = key
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
    static func load(mac: UUID) -> Data? {
        var item = query(mac)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data, data.count == 32 else { return nil }
        return data
    }
    static func delete(mac: UUID) { SecItemDelete(query(mac) as CFDictionary) }
}

// MARK: Settings → Models → Agents on your Mac

/// The Agents on your Mac row in Models → LLM: where it stands, in a few words.
@MainActor enum MacAgentsSummary {
    static var line: String {
        let relay = MacRelayPhone.shared
        guard let mac = relay.mac else { return "Not paired" }
        if relay.isUnpairing { return "Unpairing from \(mac.name)…" }
        switch relay.status {
        case .connected: return "\(mac.name) · Connected"
        case .looking, .connecting: return "\(mac.name) · Looking on this Wi‑Fi"
        case .notFound: return "\(mac.name) · Not on this Wi‑Fi"
        case .notPaired: return "Not paired"
        case .problem: return "\(mac.name) · Needs attention"
        }
    }
    static var on: Bool { MacRelayPhone.shared.status == .connected }
}

/// The last sections of Models → LLM on iPhone (`SettingsCatalog.macAgents`): pair with your Mac (the
/// code it shows, or its QR code scanned with the Camera), see whether it's reachable and what each of
/// its agents can do (installed, signed in), and unpair. The Mac's own sections have the same place
/// (`KemoSabeRelaySettings.swift`).
struct MacAgentsSettingsSection: View {
    @Environment(AppStore.self) private var store
    @State private var relay = MacRelayPhone.shared
    @State private var code = ""
    @State private var confirmingUnpair = false
    @State private var confirmingForget = false
    var body: some View {
        Section {
            if let mac = relay.mac, relay.isUnpairing {
                LabeledContent("Mac", value: mac.name)
                LabeledContent("Status") { Text(unpairingLine(mac.name)).foregroundStyle(.orange) }
                    .accessibilityIdentifier("relayPhoneStatus")
                Button("Forget \(mac.name) anyway", role: .destructive) { confirmingForget = true }.accessibilityIdentifier("relayForgetAnyway")
                    .confirmationDialog("Forget \(mac.name) without telling it?", isPresented: $confirmingForget, titleVisibility: .visible) {
                        Button("Forget anyway", role: .destructive) { relay.forget() }
                    } message: { Text("This iPhone forgets \(mac.name) and its key now. To remove this iPhone there too, open \(MacRelay.macSettings) on that Mac.") }
            } else if let mac = relay.mac {
                LabeledContent("Mac", value: mac.name)
                LabeledContent("Status") { Text(statusLine).foregroundStyle(relay.status == .connected ? Color.secondary : Color.orange) }
                    .accessibilityIdentifier("relayPhoneStatus")
                ForEach(relay.agents) { agent in agentRow(agent) }
                Button("Unpair \(mac.name)", role: .destructive) { confirmingUnpair = true }.accessibilityIdentifier("relayUnpair")
                    .confirmationDialog("Unpair \(mac.name)?", isPresented: $confirmingUnpair, titleVisibility: .visible) {
                        Button("Unpair", role: .destructive) { relay.unpair() }
                    } message: { Text("Agent chats on this iPhone stop working until you pair again. \(mac.name) removes this iPhone too.") }
            } else {
                Text("Chat with Claude Code, Codex, Muse Code, Cursor Agent, or another agent on your own Mac, each with its own sign-in there. KemoSabe never signs in to them on this iPhone.")
            }
        } header: { Text(SettingsCatalog.macAgents.iPhone) } footer: { Text(footer) }
        .listRowBackground(Color.primary.opacity(0.05))
        Section {
            TextField("Pairing code", text: $code).textInputAutocapitalization(.characters).autocorrectionDisabled()
                .font(.system(.callout, design: .monospaced)).accessibilityIdentifier("relayCodeField")
                .onSubmit(pair)
            Button(relay.pairing ? "Pairing…" : (relay.mac == nil ? "Pair" : "Pair this Mac instead"), action: pair)
                .disabled(relay.pairing || MacRelay.Invite(typed: code) == nil).accessibilityIdentifier("relayPair")
            if let problem = relay.pairingProblem { Text(problem).font(KemoType.font(.footnote)).foregroundStyle(.orange) }
        } header: { Text(relay.mac == nil ? "Pair your Mac" : "Pair another Mac") } footer: {
            Text("A code works once, for ten minutes. Only pair your own Mac.")
        }
        .listRowBackground(Color.primary.opacity(0.05))
    }
    /// An agent on the Mac: its mark, its name, and whether it's ready there.
    private func agentRow(_ agent: MacRelay.Agent) -> some View {
        HStack(spacing: 12) {
            ChatAgentLogo(logo: ChatAgents.kind(agent.id)?.logo ?? "", title: agent.name, size: 20).frame(width: 28)
            Text(agent.name)
            Spacer()
            Text(agentState(agent)).font(KemoType.font(.footnote)).foregroundStyle(agent.problem == nil ? Color.secondary : Color.orange)
        }
        .accessibilityElement(children: .combine).accessibilityIdentifier("relayAgent-" + agent.id)
    }
    private func agentState(_ agent: MacRelay.Agent) -> String {
        switch agent.state {
        case .signedIn: "Signed in"
        case .installed: "Installed"
        case .signedOut: "Not signed in"
        case .notInstalled: "Not installed"
        }
    }
    private var footer: String {
        guard let mac = relay.mac else {
            return "On your Mac, open \(MacRelay.macSettings), turn it on, and scan the code with this iPhone’s Camera, or type it below."
        }
        if relay.isUnpairing {
            return "KemoSabe tells \(mac.name) to remove this iPhone the next time both are on the same Wi‑Fi with KemoSabe open, then forgets it here. Until then this iPhone keeps its key for \(mac.name), and agent chats here are paused. Forget anyway only if \(mac.name) is gone: it keeps listing this iPhone until you remove it there."
        }
        let signIn = relay.status == .connected && relay.agents.contains { $0.state == .signedOut } ? " Sign in to an agent on \(mac.name) itself; this iPhone can’t sign in for it." : ""
        return "Choose an agent in the chat’s model menu. Each message runs on \(mac.name) with that agent’s own sign-in and comes back here; when the agent asks KemoSabe something, this iPhone’s KemoSabe answers. Works while this iPhone and your Mac are on the same Wi‑Fi." + signIn
    }
    private func unpairingLine(_ name: String) -> String {
        switch relay.status {
        case .connected: "Telling \(name)…"
        case .problem(let problem) where problem.contains("didn’t accept") || problem.contains("isn’t paired"):
            "\(name) doesn’t know this iPhone any more. You can forget it here."
        case .problem(let problem): problem
        case .notFound: "Waiting for \(name) on this Wi‑Fi"
        default: "Looking for \(name)…"
        }
    }
    private func pair() {
        guard let invite = MacRelay.Invite(typed: code) else { return }
        Task { await relay.pair(invite, store: store); if relay.pairingProblem == nil { code = "" } }
    }
    private var statusLine: String {
        switch relay.status {
        case .connected: "Connected"
        case .looking: "Looking on this Wi‑Fi…"
        case .connecting: "Connecting…"
        case .notFound: "Not on this Wi‑Fi"
        case .notPaired: "Not paired"
        case .problem(let problem): problem
        }
    }
}

/// A scanned pairing link asks before it pairs: a link from anyone else would send your agent chats to their Mac.
struct MacRelayInviteAlert: ViewModifier {
    @Environment(AppStore.self) private var store
    @State private var relay = MacRelayPhone.shared
    func body(content: Content) -> some View {
        content
            .onOpenURL { url in if let invite = MacRelay.Invite(url: url) { relay.pendingInvite = invite } }
            .alert("Use your agents through \(relay.pendingInvite?.name.map { "“\($0)”" } ?? "this Mac")?",
                   isPresented: Binding(get: { relay.pendingInvite != nil }, set: { if !$0 { relay.pendingInvite = nil } })) {
                Button("Pair") { if let invite = relay.pendingInvite { Task { await relay.pair(invite, store: store) } } }
                Button("Cancel", role: .cancel) { relay.pendingInvite = nil }
            } message: {
                Text("Only pair your own Mac. Your agent chats on this iPhone will run on it, with its own sign-ins.")
            }
    }
}

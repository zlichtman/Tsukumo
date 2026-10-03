import SwiftUI

/// Settings → Models → LLM → Agents on your Mac (Mac; `SettingsCatalog.macAgents`): let your paired
/// iPhone chat with this Mac's coding agents (Claude Code, Codex, Muse Code, Cursor Agent, and any you
/// added), each agent's sign-in here, keep the Mac awake while plugged in, pair an iPhone with the code
/// (or its QR code), and see or remove the paired iPhones. The iPhone's section in the same place,
/// "Agents on your Mac", is where it pairs and unpairs (design/UI-GUIDE.md).
/// The Agents on your Mac row in Models → LLM: where it stands, in a few words.
@MainActor enum MacAgentsSummary {
    static var line: String {
        let relay = KemoSabeRelay.shared
        guard relay.enabled else { return "Off" }
        let phones = relay.phones.count
        switch relay.status {
        case .off: return "Off"
        case .starting: return "Starting…"
        case .failed: return "Not running"
        case .listening:
            if !relay.connected.isEmpty { return "Your iPhone is connected" }
            return phones == 0 ? "On · No iPhone paired" : "On · \(phones == 1 ? "1 iPhone" : "\(phones) iPhones") paired"
        }
    }
    static var on: Bool { KemoSabeRelay.shared.enabled && !KemoSabeRelay.shared.connected.isEmpty }
}

struct MacAgentsSettingsSection: View {
    @Environment(DesktopNavigation.self) private var desktop
    @State private var relay = KemoSabeRelay.shared
    @State private var registry = CodingAgentRegistry.shared
    @State private var removing: MacRelayPairedPhone?
    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { relay.enabled }, set: { relay.setEnabled($0) })) {
                Text("Let your iPhone use this Mac’s agents")
                Text("Chats with an agent in KemoSabe on your paired iPhone run here, with each agent’s own sign-in, while your iPhone and this Mac are on the same Wi‑Fi. When an agent asks KemoSabe something, your iPhone’s KemoSabe answers. Nothing about any sign-in leaves this Mac.")
            }
            .accessibilityIdentifier("relayEnabled")
            if relay.enabled {
                LabeledContent {
                    Text(statusLabel).foregroundStyle(failed ? Color.orange : Color.secondary)
                } label: {
                    Text("Status")
                    Text(statusDetail)
                }.accessibilityIdentifier("relayStatus")
                Toggle(isOn: $relay.keepAwake) {
                    Text("Keep this Mac awake while plugged in")
                    Text("So your iPhone can reach it. The display can still sleep; on battery, the Mac sleeps as usual.")
                }.accessibilityIdentifier("relayKeepAwake")
            }
            ForEach(agents, id: \.id) { agent in agentRow(agent) }
        } header: { Text(SettingsCatalog.macAgents.mac) } footer: {
            Text("Your iPhone can chat with the agents installed here. Sign in to each on this Mac; your iPhone can’t sign in for it.")
        }
        .listRowBackground(Color.primary.opacity(0.05))
        .task { await registry.checkSignIn() }
        if relay.enabled { pairing }
        if !relay.phones.isEmpty { paired }
    }

    /// The agents your iPhone sees, as it sees them (`KemoSabeRelayTurns.agents`).
    private var agents: [MacRelay.Agent] { relay.turns.agents }
    private func agentRow(_ agent: MacRelay.Agent) -> some View {
        LabeledContent {
            if agent.state == .signedOut, let provider = KemoSabeHandoff.provider(for: agent.id),
               let command = registry.adapter(for: provider).signInCommand {
                Button("Sign in") { AgentSignIn.openInTsukumo(command, name: agent.product, desktop: desktop) }
                    .accessibilityIdentifier("relaySignIn-" + agent.id)
            } else { Text(stateLabel(agent.state)).foregroundStyle(.secondary) }
        } label: {
            HStack(spacing: 10) {
                ChatAgentLogo(logo: ChatAgents.kind(agent.id)?.logo ?? "", title: agent.name, size: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name)
                    Text(agent.state == .notInstalled ? "Install \(agent.product) on this Mac and sign in; until then your iPhone says it isn’t ready." : agent.product)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.accessibilityIdentifier("relayAgent-" + agent.id)
    }
    private func stateLabel(_ state: MacRelay.AgentState) -> String {
        switch state {
        case .signedIn: "Signed in"
        case .installed: CodingAgentSignInState.unknown.title
        case .signedOut: "Not signed in"
        case .notInstalled: "Not installed"
        }
    }

    private var pairing: some View {
        Section {
            if let offer = relay.offer, let invite = relay.invite {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let open = offer.isOpen(at: context.date)
                    HStack(alignment: .top, spacing: 22) {
                        Group {
                            if let image = KemoSabeRelay.qrCode(invite.url) {
                                Image(nsImage: image).interpolation(.none).resizable().frame(width: 176, height: 176)
                                    .padding(10).background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }.opacity(open ? 1 : 0.2).accessibilityLabel("Pairing QR code").accessibilityIdentifier("relayQRCode")
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Scan this with your iPhone’s Camera, or in KemoSabe on your iPhone open \(MacRelay.phoneSettings) and type the code.")
                                .fixedSize(horizontal: false, vertical: true)
                            Text(MacRelay.PairingCode.grouped(offer.code)).font(.system(size: 15, weight: .medium, design: .monospaced))
                                .textSelection(.enabled).opacity(open ? 1 : 0.35).accessibilityIdentifier("relayCode")
                            Text(caption(offer, now: context.date)).font(.system(size: 11)).foregroundStyle(.secondary)
                            Button(open ? "New code" : "Make a new code") { relay.newCode() }.accessibilityIdentifier("relayNewCode")
                            Text("Only pair iPhones you own: a paired iPhone can use your agents on your sign-ins.").font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }.padding(.vertical, 8)
                }
            } else {
                LabeledContent {
                    Button("Show a code") { relay.newCode() }.accessibilityIdentifier("relayNewCode")
                } label: {
                    Text("Pair an iPhone")
                    Text("Shows a code your iPhone scans or types. It works once, for ten minutes.")
                }
            }
        } header: { Text("Pair an iPhone") }
        .listRowBackground(Color.primary.opacity(0.05))
    }

    private var paired: some View {
        Section {
            ForEach(relay.phones) { phone in
                LabeledContent {
                    Button("Remove") { removing = phone }.accessibilityIdentifier("relayRemove-" + phone.id.uuidString)
                } label: {
                    Text(phone.name)
                    Text(phoneDetail(phone))
                }
            }
        } header: { Text("Paired iPhones") }
        .listRowBackground(Color.primary.opacity(0.05))
        .accessibilityIdentifier("relayPhones")
        .alert("Remove \(removing?.name ?? "this iPhone")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) { if let removing { relay.remove(removing.id) }; removing = nil }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { Text("It can’t use this Mac’s agents until you pair it again.") }
    }

    private func caption(_ offer: MacRelay.PairingOffer, now: Date) -> String {
        if offer.used { return "Used. Make a new code to pair another iPhone." }
        let left = Int(offer.expires.timeIntervalSince(now))
        guard left > 0 else { return "This code expired." }
        return String(format: "Works once. Expires in %d:%02d.", left / 60, left % 60)
    }
    private func phoneDetail(_ phone: MacRelayPairedPhone) -> String {
        if relay.connected.contains(phone.id) { return "Connected now" }
        let paired = "Paired " + phone.paired.formatted(date: .abbreviated, time: .omitted)
        guard let seen = phone.lastSeen else { return paired }
        return paired + " · last connected " + seen.formatted(.relative(presentation: .named))
    }
    private var failed: Bool { if case .failed = relay.status { true } else { false } }
    private var statusLabel: String {
        switch relay.status {
        case .off: "Off"
        case .starting: "Starting…"
        case .listening: relay.connected.isEmpty ? "Waiting for your iPhone" : "Connected"
        case .failed: "Not running"
        }
    }
    private var statusDetail: String {
        switch relay.status {
        case .failed(let reason): "This Mac can’t be found on the network: " + reason
        default: relay.awake ? "Staying awake while plugged in." : "Your iPhone finds this Mac on the same Wi‑Fi."
        }
    }
}

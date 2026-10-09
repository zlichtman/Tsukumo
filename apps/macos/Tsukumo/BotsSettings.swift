import AppKit
import SwiftUI
import TsukumoCore
import TsukumoDock
import TsukumoEngines
import TsukumoGateway
import TsukumoMuse
import TsukumoUI

// Settings, Bots (October 8, 2026; the owner: "all the bots go into the bots section", then "sort this out": bots
// made here and bots connected from elsewhere are two kinds). Bots: KemoSabe and the bots that run on the owner's
// engines on this Mac, with Add a Bot. Connected: the bots that live elsewhere (Muse, which also chats here; gateway
// agents), then each service not connected yet (its page: Muse's token and pairing, the gateway address and steps,
// OpenClaw's command), and agents to confirm. Each bot opens its page (TsukumoDock's `DockBotPanel`; KemoSabe's also
// holds the bots it answers, its chirps, and its journal). Then Agents (tokens). The engines underneath (keys, coding
// agents) are in Settings, Models; Settings, Gateway keeps the gateway's own switches.

/// Where a service stands on this Mac.
enum ServiceStatus: Equatable {
    case connected, notConnected, needsKey, notInstalled, needsPairing
    var title: String {
        switch self {
        case .connected: "Connected"
        case .notConnected: "Not connected"
        case .needsKey: "Needs a key"
        case .notInstalled: "Not installed"
        case .needsPairing: "Needs pairing"
        }
    }
    var color: Color { self == .connected ? .green : self == .notConnected || self == .notInstalled ? .secondary : .orange }
}

extension TsukumoDelegate {
    func status(_ service: ServiceID) -> ServiceStatus {
        if dock?.connections.isConnected(service) == true { return .connected }
        switch service {
        case .claude, .openAI:
            let provider: ConnectionRecord.Provider = service == .claude ? .anthropic : .openAI
            return connections.contains { $0.provider == provider } ? .needsKey : .notConnected
        case .codex, .cursor, .gemini: return .notInstalled
        case .muse: return muse?.hasToken == true ? .needsPairing : .notConnected
        case .grok, .openClaw: return .notConnected
        }
    }
    /// The installed coding agent behind a service, if it's on this Mac.
    func installedAgent(_ service: ServiceID) -> InstalledCodingAgent? {
        guard let id = service.codingAgent else { return nil }
        return coding.installed.first { $0.kind.id == id }
    }
}

struct BotsPane: View {
    let app: TsukumoDelegate
    let dock: BotDock
    @Bindable var state: SettingsState

    var body: some View {
        if let notice = dock.store.state.lineupNotice {
            SettingsCard("Your custom bots were moved", systemImage: "arrow.triangle.merge") {
                Text(notice.replacingOccurrences(of: "Your custom bots were moved: ", with: "")).font(.callout).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("lineupNotice")
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.storage.folder]) }
                    Spacer()
                    Button("OK") { app.dismissLineupNotice() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        if let problem = app.lineupProblem { SettingsNote(problem, warning: true) }
        let made = dock.bots.filter { !$0.isBroughtIn }, connected = dock.bots.filter(\.isBroughtIn)
        SettingsCard("Bots", systemImage: "person.2") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(made.enumerated()), id: \.element.id) { index, bot in
                    if index > 0 { Divider() }
                    botRow(bot)
                }
                Divider()
                Button { app.controller?.open(.addBot) } label: { Label("Add a Bot…", systemImage: "plus") }
                    .accessibilityIdentifier("settingsAddBot")
            }
            SettingsNote("KemoSabe, and the bots that run on your engines on this Mac: Tsukumo’s Claude bot on Claude Code, a Leafy of your own on Codex, a Codex or Claude Code conversation, or one you make.")
        }
        SettingsCard("Connected", systemImage: "point.3.connected.trianglepath.dotted") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(connected.enumerated()), id: \.element.id) { index, bot in
                    if index > 0 { Divider() }
                    botRow(bot)
                }
                // Each service that isn't connected yet: how to connect it.
                let open = Self.connectable.filter { service in !connected.contains { $0.service == service } && (service != .muse || app.muse != nil) }
                ForEach(Array(open.enumerated()), id: \.element) { index, service in
                    if index > 0 || !connected.isEmpty { Divider() }
                    Button { state.botPage = .service(service) } label: {
                        let status = app.status(service)
                        SettingsRow(Self.title(service), subtitle: status.title) {
                            ServiceMarkView(service, size: 30)
                        } trailing: {
                            if status != .connected { Text("Connect").font(.caption).foregroundStyle(.secondary) }
                            SettingsChevron()
                        }
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("connectAgent-" + service.rawValue)
                }
                ForEach(dock.unverifiedCallers) { caller in
                    Divider()
                    SettingsRow("“\(caller.name)”", systemImage: "questionmark.circle", subtitle: "Signed in and calls itself this. Say which it is to connect it.") {
                        Menu("This is…") {
                            ForEach(ServiceID.allCases) { service in
                                Button(service.title) { dock.bind(caller: caller.id, to: service, transport: caller.kind == .token ? "with a token you made" : "signed in with OAuth"); app.refreshServices() }
                            }
                            Divider()
                            Button("None of these") { dock.bind(caller: caller.id, to: nil, transport: caller.kind == .token ? "with a token you made" : "signed in with OAuth") }
                        }
                        .fixedSize()
                        .accessibilityIdentifier("bindCaller-" + caller.id)
                    }
                }
            }
            SettingsNote("Agents that live elsewhere and connect to this Mac. Each asks KemoSabe for anything about you, under your rules; Muse also chats here.")
        }
        if let gateway = app.gateway {
            AgentsCard(gateway: gateway, bot: { caller in dock.bots.first { $0.origin == .caller(id: caller) } },
                       open: { state.botPage = .bot($0.id) },
                       bind: { caller, service, transport in dock.bind(caller: caller, to: service, transport: transport); app.refreshServices() })
        }
    }

    /// The services that connect from elsewhere, in the order Connected lists them.
    static let connectable: [ServiceID] = [.muse, .openAI, .claude, .grok, .openClaw]
    static func title(_ service: ServiceID) -> String {
        switch service {
        case .openAI: "ChatGPT and dots"
        case .claude: "Claude.ai"
        default: service.title
        }
    }

    private func botRow(_ bot: BotSpec) -> some View {
        Button { state.botPage = bot.isKemoSabe ? .kemoSabe : .bot(bot.id) } label: {
            SettingsRow(bot.name, subtitle: bot.isKemoSabe ? dock.subtitle(bot.id) : BotPanelWords.kind(bot, engine: dock.engineInfo(bot.engine).title)) {
                BotAvatar(bot: bot, size: 30)
            } trailing: {
                if dock.needsYou(bot.id) { Text("Needs you").font(.caption).foregroundStyle(.orange) }
                if bot.isKemoSabe { Text(bot.kemoSabePalette.name).font(.caption).foregroundStyle(.secondary).accessibilityLabel("Palette") }
                SettingsChevron()
            }
        }
        .buttonStyle(.plain).accessibilityIdentifier("settingsBot-" + (bot.isKemoSabe ? "kemosabe" : bot.name))
    }
}

/// A bot's or a service's page over Settings (from Bots, Models, or search).
struct BotPageSheet: View {
    let app: TsukumoDelegate
    let dock: BotDock
    let page: BotPage
    let done: () -> Void
    var body: some View {
        switch page {
        case .kemoSabe:
            DockBotPanel(dock: dock, bot: dock.bot(BotSpec.kemoSabeID) ?? .kemoSabe(), inSettings: true,
                         more: AnyView(KemoSabeMore(app: app, dock: dock)), done: done)
                .frame(width: DockMetrics.panel.width, height: DockMetrics.panel.height)
        case .bot(let id):
            if let bot = dock.bot(id) {
                DockBotPanel(dock: dock, bot: bot, inSettings: true, done: done)
                    .frame(width: DockMetrics.panel.width, height: DockMetrics.panel.height)
            }
        case .service(let service):
            ServicePage(app: app, dock: dock, service: service, done: done).frame(width: 620, height: 680)
        }
    }
}

/// Which page is open in Settings, Bots: KemoSabe's, one of the owner's bots', or a service's.
enum BotPage: Hashable, Identifiable {
    case kemoSabe
    case bot(UUID)
    case service(ServiceID)
    var id: String {
        switch self {
        case .kemoSabe: "kemosabe"
        case .bot(let id): id.uuidString
        case .service(let service): service.rawValue
        }
    }
}

/// One service's page: how to connect it.
struct ServicePage: View {
    let app: TsukumoDelegate
    let dock: BotDock
    let service: ServiceID
    let done: () -> Void
    @State private var adding: ConnectionRecord.Provider?
    @State private var editing: ConnectionRecord?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                ServiceMarkView(service, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(service.title).font(.system(size: 20, weight: .bold))
                    let status = app.status(service)
                    HStack(spacing: 6) {
                        Circle().fill(status.color).frame(width: 8, height: 8)
                        Text(status.title + " · " + service.company).font(.callout).foregroundStyle(.secondary)
                    }
                    .fixedSize()
                    .accessibilityIdentifier("servicePageStatus")
                }
                .layoutPriority(1)
                Spacer()
                Button("Done") { done() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) { connect }
                    .padding(20)
            }
        }
        .sheet(item: $adding) { provider in ConnectionEditor(app: app, provider: provider, existing: nil) }
        .sheet(item: $editing) { record in ConnectionEditor(app: app, provider: record.provider, existing: record) }
        .accessibilityIdentifier("servicePage-" + service.rawValue)
    }

    // MARK: Connecting each service

    @ViewBuilder private var connect: some View {
        switch service {
        case .claude:
            agentCard
            keyCard(.anthropic)
            gatewayCard(steps: "In Claude’s Settings, open Connectors, click Add custom connector, and paste the address. Claude signs in, and you allow it in a window on this Mac.")
            SettingsCard("Tsukumo’s Claude bot", systemImage: "sparkles") {
                SettingsNote("Claude has no bot of its own, so Tsukumo makes one on your Claude Code: tasks in the background that ask KemoSabe for anything personal. Bring it in from Add a Bot.")
            }
        case .openAI:
            keyCard(.openAI)
            gatewayCard(title: "Let ChatGPT and dots ask KemoSabe",
                        steps: "In ChatGPT’s Settings, open Apps, then Advanced, turn on Developer mode, click Create, and paste the address. ChatGPT signs in, and you allow it in a window on this Mac.")
        case .grok:
            gatewayCard(steps: "On grok.com, open Connectors, choose Custom, and paste the address. Grok signs in, and you allow it in a window on this Mac.")
        case .openClaw:
            openClawCard
        case .muse:
            if let muse = app.muse { MuseCard(muse: muse) } else { SettingsNote("Muse isn’t available in the demo.") }
        case .codex, .cursor, .gemini:
            agentCard
            gatewayCard(steps: service == .codex
                        ? "To let Codex in a terminal ask KemoSabe too, make it a token in Settings, Gateway, Agents, and run the command shown there."
                        : "To let it ask KemoSabe from a terminal too, make it a token in Settings, Gateway, Agents.", local: true)
        }
    }

    /// A coding agent on this Mac: installed (its version and models) or how to get it.
    @ViewBuilder private var agentCard: some View {
        let title = service == .claude ? "Claude Code on this Mac" : service.title + " on this Mac"
        SettingsCard(title, systemImage: "terminal") {
            if let agent = app.installedAgent(service) {
                SettingsRow("Installed", systemImage: "checkmark.circle", subtitle: (agent.version.map { "Version \($0) · " } ?? "") + "runs with your own sign-in, never Tsukumo’s") { EmptyView() }
                let models = agent.models.filter { $0.id != "default" && !$0.id.isEmpty }.map(\.name)
                if !models.isEmpty { SettingsNote("Models it offers: " + models.joined(separator: ", ") + ". Pick one on each bot’s page.") }
            } else {
                let install = CodingAgentKind.all.first { $0.id == service.codingAgent }?.install ?? service.howToConnect
                SettingsRow("Not on this Mac", systemImage: "arrow.down.circle", subtitle: install) { EmptyView() }
                SettingsNote("Tsukumo looks for it each time it opens. It never installs an agent or signs in for you.")
            }
        }
    }

    /// An API key for chat (Claude or OpenAI).
    private func keyCard(_ provider: ConnectionRecord.Provider) -> some View {
        SettingsCard(provider == .anthropic ? "Claude API key" : "OpenAI API key", systemImage: "key") {
            if let record = app.connections.first(where: { $0.provider == provider }) {
                SettingsRow(record.name, subtitle: app.hasKey(record.id) ? "\(record.connection.model) · key in this Mac’s Keychain" : "No key on this Mac yet") {
                    EngineMarkView(record.provider.mark, size: 22).frame(width: 30, height: 30)
                } trailing: {
                    Button(app.hasKey(record.id) ? "Change…" : "Add Key…") { editing = record }
                }
            } else {
                SettingsRow("No key yet", systemImage: "key", subtitle: provider == .anthropic ? "Chat with Claude on your own key." : "Chat with OpenAI’s models on your own key.") {
                    Button("Add Key…") { adding = provider }.accessibilityIdentifier("serviceAddKey")
                }
            }
            SettingsNote("Keys stay in this Mac’s Keychain. They’re never synced or backed up.")
        }
    }

    /// The gateway's address for this service, with Copy and its steps.
    private func gatewayCard(title: String? = nil, steps: String, local: Bool = false) -> some View {
        SettingsCard(title ?? "Let \(service.title) ask KemoSabe", systemImage: "point.3.connected.trianglepath.dotted") {
            if let gateway = app.gateway {
                let address = local ? gateway.localURL : gateway.relay?.publicMCPURL
                if let address, gateway.store.settings.enabled {
                    HStack {
                        Text(address).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).lineLimit(2)
                        Spacer()
                        Button("Copy") { Self.copy(address) }.accessibilityIdentifier("serviceCopyAddress")
                    }
                    SettingsNote(steps)
                } else {
                    SettingsRow(gateway.store.settings.enabled ? "Turn on the public address first" : "Turn on the KemoSabe gateway first",
                                systemImage: "exclamationmark.circle",
                                subtitle: local ? "Agents on this Mac reach KemoSabe at its local address." : "Cloud agents reach KemoSabe through a public address, in Settings, Gateway.") {
                        Button("Open Gateway") { done(); app.showSettings(.gateway) }
                    }
                }
            } else {
                SettingsNote("The gateway isn’t available in the demo.")
            }
            SettingsNote("Every request follows your rules in Settings, Gateway: KemoSabe asks you on a card unless you’ve allowed it, and the activity shows on this page.")
        }
    }

    private var openClawCard: some View {
        SettingsCard("Connect OpenClaw", systemImage: "terminal") {
            if let gateway = app.gateway, gateway.store.settings.enabled {
                let url = gateway.relay?.publicMCPURL ?? gateway.localURL
                let command = "openclaw mcp add kemosabe --url \(url) --transport streamable-http --auth oauth"
                HStack(alignment: .top) {
                    Text(command).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Copy") { Self.copy(command) }.accessibilityIdentifier("serviceCopyCommand")
                }
                SettingsNote("Run it where OpenClaw runs. OpenClaw signs in, and you allow it in a window on this Mac.")
            } else {
                SettingsRow("Turn on the KemoSabe gateway first", systemImage: "exclamationmark.circle", subtitle: "OpenClaw reaches KemoSabe through the gateway.") {
                    Button("Open Gateway") { done(); app.showSettings(.gateway) }
                }
            }
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

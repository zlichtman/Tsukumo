import AppKit
import SwiftUI
import TsukumoCore
import TsukumoDock
import TsukumoGateway
import TsukumoUI

// Settings, Gateway (October 6, 2026): the KemoSabe gateway. Agents elsewhere (ChatGPT and dots, Claude, Grok,
// OpenClaw, Claude Code or Codex in a terminal) ask KemoSabe narrow questions over MCP on this Mac; plain code
// decides under the owner's grants and budgets, and only the answer leaves. Off until the owner turns it on.
// The server answers on 127.0.0.1; a public address, off by default, comes only through the Tsukumo relay (PublicAddressCard).

struct GatewayPane: View {
    let gateway: KemoSabeGateway
    /// Opens a sign-in's own window.
    var review: (GatewayApprovalRequest) -> Void = { _ in }
    /// The service the owner confirmed a caller is, if any, and binding one.
    var binding: (String) -> ServiceID? = { _ in nil }
    var bind: (String, ServiceID?, String) -> Void = { _, _, _ in }
    /// Who a request is from and how it came, for its card.
    var identity: (GatewayApprovalRequest) -> String? = { _ in nil }
    @State private var explaining = false
    @State private var portText = ""
    private var store: GatewayStore { gateway.store }
    private var settings: GatewaySettings { store.settings }

    var body: some View {
        SettingsCard("KemoSabe gateway", systemImage: "point.3.connected.trianglepath.dotted") {
            Toggle("Let agents ask KemoSabe", isOn: Binding(get: { settings.enabled }, set: { on in
                if on && !settings.explained { explaining = true } else { Task { await gateway.setEnabled(on) } }
            }))
            .accessibilityIdentifier("gateway-enabled")
            SettingsNote("Agents like ChatGPT, Claude, Grok, or a coding agent can ask KemoSabe a few narrow things: when you’re busy, a contact you allow, or a question you approve. KemoSabe decides on this Mac under your rules, and only the answer leaves.")
            if settings.enabled {
                Divider()
                SettingsRow(gateway.listening ? "Listening on this Mac" : "Not listening", systemImage: gateway.listening ? "checkmark.circle" : "exclamationmark.circle",
                            subtitle: gateway.problem ?? gateway.localURL) {
                    Button("Copy") { copy(gateway.localURL) }.disabled(!gateway.listening)
                }
                SettingsField("Port") {
                    TextField("Port", text: $portText).frame(width: 80).multilineTextAlignment(.trailing)
                        .onSubmit { applyPort() }
                    Button("Apply") { applyPort() }
                }
            }
        }
        .onAppear { portText = String(settings.port) }
        .alert("Let agents ask KemoSabe?", isPresented: $explaining) {
            Button("Turn On") { Task { await gateway.setEnabled(true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Tsukumo will answer agents on this Mac only (127.0.0.1). Each agent signs in and is its own caller. Nothing is shared unless a grant you give covers it or you allow it on a card, every disclosure is kept in the ledger, and you can revoke any agent here. Turn it off any time.")
        }

        if let relay = gateway.relay { PublicAddressCard(gateway: gateway, relay: relay) }

        SettingsCard("What agents may ask for", systemImage: "slider.horizontal.3") {
            Picker("Free/busy without asking", selection: Binding(get: { settings.freeBusyResolution }, set: { value in store.update { $0.freeBusyResolution = value } })) {
                Text("Whole days").tag(GatewaySettings.FreeBusyResolution.day)
                Text("Quarter hours").tag(GatewaySettings.FreeBusyResolution.quarterHour)
            }
            .pickerStyle(.segmented)
            Toggle("Files, message excerpts, and photos", isOn: Binding(get: { settings.contentTools }, set: { on in store.update { $0.contentTools = on } }))
            Toggle("Let agents send things to your Inbox", isOn: Binding(get: { settings.inbox }, set: { on in store.update { $0.inbox = on }; Task { await gateway.apply() } }))
            Stepper("Largest file shared: \(settings.maxFileBytes / 1_048_576) MB", value: Binding(get: { settings.maxFileBytes / 1_048_576 },
                                                                                                    set: { mb in store.update { $0.maxFileBytes = max(1, mb) * 1_048_576 } }), in: 1...50)
            SettingsNote("Finer free/busy times, and every file, excerpt, and photo, ask you on a card unless you allowed that one for an agent. Agents send things into your Inbox, kept apart and never opened for you.")
        }

        let waiting = gateway.desk.pending
        if !waiting.isEmpty {
            SettingsCard("Waiting for you", systemImage: "hand.raised") {
                GatewayRequestList(desk: gateway.desk, identity: identity)
                // A sign-in is allowed only in its own window (its arming delay and full details); here it can be shown or refused.
                ForEach(waiting.filter { if case .newClient = $0.kind { true } else { false } }) { request in
                    SettingsRow(request.title, systemImage: "person.badge.key", subtitle: "Unverified app. Review it in its window.") {
                        Button("Review…") { review(request) }
                        Button("Don’t Allow") { gateway.desk.answer(request.id, .deny) }
                    }
                }
            }
        }

        SettingsCard("Budgets", systemImage: "gauge.with.dots.needle.33percent") {
            budgetStepper("Disclosures per agent per day", \.unitsPerCaller, 1...500)
            budgetStepper("Disclosures for all agents per day", \.unitsEveryone, 1...2_000)
            budgetStepper("Different people per agent per day", \.contactsPerDay, 1...100)
            budgetStepper("Questions per agent per hour", \.asksPerHour, 1...100)
            budgetStepper("Cards waiting per agent", \.pendingPerCaller, 1...20)
            SettingsNote("One disclosure is a contact field, a day of free/busy, an answer, a list, a file, an excerpt, or a photo. Over a budget asks you; far over refuses without asking.")
        }

        let recent = Array(gateway.ledger.entries.suffix(30).reversed())
        if !recent.isEmpty {
            SettingsCard("Ledger", systemImage: "list.bullet.clipboard") {
                ForEach(Array(recent.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Divider() }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(entry.callerName + " · " + entry.tool.title).font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text(entry.at.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.tertiary)
                        }
                        Text(LedgerWords.outcome(entry)).font(.caption).foregroundStyle(.secondary)
                        if !entry.flags.isEmpty {
                            Text(entry.flags.map(LedgerWords.flag).joined(separator: " · ")).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                SettingsNote("What left, by kind and size, never the content itself. Files, excerpts, and photos are kept by their id and fingerprint.")
            }
        }

        if !gateway.inbox.items.isEmpty {
            SettingsCard("Inbox", systemImage: "tray.and.arrow.down") {
                ForEach(gateway.inbox.items.reversed()) { item in
                    SettingsRow(item.line, systemImage: item.kind == .link ? "link" : item.kind == .message ? "text.bubble" : "doc",
                                subtitle: [ByteCountFormatter.string(fromByteCount: Int64(item.bytes), countStyle: .file), item.note].compactMap { $0 }.joined(separator: " · ")) {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([gateway.inbox.url(item)]) }
                        Button("Delete", role: .destructive) { gateway.inbox.delete(item.id) }
                    }
                }
                SettingsNote("Kept in Tsukumo’s Inbox folder with macOS’s quarantine mark. Tsukumo never opens or runs them, and KemoSabe never reads them.")
            }
        }
    }

    private func budgetStepper(_ title: String, _ path: WritableKeyPath<GatewayBudget, Int>, _ range: ClosedRange<Int>) -> some View {
        Stepper("\(title): \(settings.budget[keyPath: path])", value: Binding(get: { settings.budget[keyPath: path] },
                                                                             set: { value in store.update { $0.budget[keyPath: path] = value } }), in: range)
    }
    private func applyPort() {
        guard let port = UInt16(portText), port >= 1024 else { portText = String(settings.port); return }
        store.update { $0.port = port }
        Task { await gateway.apply() }
    }
}

/// The public address (October 6, 2026, the owner chose a hosted Tsukumo relay): cloud agents reach the gateway
/// through the relay, over one connection this Mac opens. Off by default; turning it on explains once what the relay
/// sees. Then the relay's address, the status, the public MCP address with Copy, Disconnect or Connect, Delete This
/// Address, and how to connect each agent.
struct PublicAddressCard: View {
    let gateway: KemoSabeGateway
    let relay: RelayConnection
    @State private var explaining = false
    @State private var deleting = false
    @State private var relayText = ""
    private var settings: GatewaySettings { gateway.store.settings }

    var body: some View {
        SettingsCard("Public address", systemImage: "globe") {
            Toggle("Let cloud agents reach KemoSabe", isOn: Binding(get: { settings.relayEnabled }, set: { on in
                if on && !settings.relayExplained { explaining = true } else { gateway.setRelayEnabled(on) }
            }))
            .disabled(!settings.enabled && !settings.relayEnabled)
            .accessibilityIdentifier("gateway-relay-enabled")
            SettingsNote("Grok, Claude, ChatGPT, and OpenClaw run in the cloud and can’t reach this Mac. The Tsukumo relay gives KemoSabe an address on the internet and passes each request to this Mac over one connection Tsukumo opens, so nothing on your network listens.")
            if !settings.enabled { SettingsNote("Turn on Let agents ask KemoSabe first.") }
            if settings.relayEnabled {
                Divider()
                SettingsField("Relay") {
                    TextField("https://tsukumo-relay.<you>.workers.dev", text: $relayText)
                        .frame(width: 300).onSubmit { saveRelay() }
                        .accessibilityIdentifier("gateway-relay-url")
                    Button("Save") { saveRelay() }.disabled(relayText == settings.relayURL)
                }
                if !relayText.isEmpty, GatewaySettings.validRelay(relayText) == nil {
                    SettingsNote("Use the relay’s https address, with nothing after the name.", warning: true)
                }
                SettingsRow(statusTitle, systemImage: statusSymbol, subtitle: statusDetail) {
                    if relay.running {
                        Button("Disconnect") { relay.stop() }
                    } else {
                        Button("Connect") { relay.start() }.disabled(settings.relay == nil || !settings.enabled)
                    }
                }
                if let url = relay.publicMCPURL {
                    SettingsRow("Public MCP address", systemImage: "link", subtitle: url) {
                        Button("Copy") { copy(url) }
                    }
                }
                if !settings.relayDeviceID.isEmpty || relay.deleting {
                    Button(relay.deleting ? "Deleting This Address…" : "Delete This Address…", role: .destructive) { deleting = true }
                        .disabled(relay.deleting)
                }
                if let url = relay.publicMCPURL {
                    Divider()
                    ConnectSteps(url: url)
                }
            }
        }
        .onAppear { relayText = settings.relayURL }
        .alert("Let cloud agents reach KemoSabe?", isPresented: $explaining) {
            Button("Turn On") { gateway.setRelayEnabled(true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The relay passes requests between cloud agents and this Mac. It can see, and could keep, every request and answer that passes through it, including sign-in tokens and anything you allow to be shared. The Tsukumo relay is built to store nothing, but your Mac can’t check that for any relay, so use one you trust. Agents still need your approval: each one signs in in a window on this Mac, and every request follows your rules here. This Mac must be awake with Tsukumo open for agents to reach it.")
        }
        .alert("Delete this address?", isPresented: $deleting) {
            Button("Delete", role: .destructive) { if !relay.deleting { Task { await relay.unregister() } } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The relay forgets this Mac, and agents using this address can’t reach KemoSabe anymore. Turning the public address on again makes a new address.")
        }
    }

    private func saveRelay() {
        gateway.setRelayURL(relayText)
        relayText = settings.relayURL
    }

    private var statusTitle: String {
        switch relay.status {
        case .off: settings.enabled && settings.relay != nil ? "Disconnected" : "Not connected"
        case .connecting: "Connecting to the relay…"
        case .connected: "Connected through the relay"
        case .retrying: "Not connected"
        case .stopped: "Stopped"
        }
    }
    private var statusSymbol: String {
        switch relay.status {
        case .connected: "checkmark.circle"
        case .connecting: "arrow.triangle.2.circlepath"
        case .off: "pause.circle"
        case .retrying, .stopped: "exclamationmark.circle"
        }
    }
    private var statusDetail: String {
        switch relay.status {
        case .off: settings.relay == nil ? "Enter your relay’s address to connect." : "Agents can’t reach KemoSabe until you connect."
        case .connecting: settings.relayDeviceID.isEmpty ? "Making this Mac’s address." : "Proving this Mac to the relay."
        case .connected: "Agents can reach KemoSabe while this Mac is awake. This Mac’s key is in its Keychain" + (relay.keyKind == .secureEnclave ? ", in the Secure Enclave." : ".")
        case .retrying(let reason): reason + " Trying again soon."
        case .stopped(let reason): reason
        }
    }
}

/// How to add the public address to each cloud agent.
private struct ConnectSteps: View {
    let url: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connect an agent").font(.system(size: 13, weight: .semibold))
            step("Grok", "On grok.com, open Connectors, choose Custom, and paste the address.")
            step("Claude", "In Settings, open Connectors, click Add custom connector, and paste the address.")
            step("ChatGPT", "In Settings, open Apps, then Advanced, turn on Developer mode, click Create, and paste the address.")
            let command = "openclaw mcp add kemosabe --url \(url) --transport streamable-http --auth oauth"
            VStack(alignment: .leading, spacing: 3) {
                Text("OpenClaw").font(.callout.weight(.semibold))
                HStack(alignment: .top) {
                    Text(command).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Copy") { copy(command) }.controlSize(.small)
                }
            }
            SettingsNote("Each agent signs in, and you allow it in a window on this Mac. It gets nothing until you allow each kind of request.")
        }
    }
    private func step(_ name: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.callout.weight(.semibold))
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// The agents signed in to the gateway, with what each may do and Revoke, and Add an Agent with a Token (Settings, Bots;
/// the owner: adding an agent belongs with the bots). One that's a bot on the dock opens its page.
struct AgentsCard: View {
    let gateway: KemoSabeGateway
    /// The bot a caller came in as, if any, and opening its page.
    let bot: (String) -> BotSpec?
    let open: (BotSpec) -> Void
    let bind: (String, ServiceID?, String) -> Void
    @State private var adding = false
    var body: some View {
        SettingsCard("Agents", systemImage: "person.2.badge.key") {
            if gateway.store.callers.isEmpty {
                SettingsNote("No agent has signed in yet. Cloud agents sign in with OAuth and you allow them in a window on this Mac; a coding agent in a terminal uses a token.")
            }
            ForEach(Array(gateway.store.callers.enumerated()), id: \.element.id) { index, caller in
                if index > 0 { Divider() }
                if let bot = bot(caller.id) {
                    SettingsRow(caller.name, systemImage: caller.kind == .oauth ? "cloud" : caller.kind == .device ? "antenna.radiowaves.left.and.right" : "terminal",
                                subtitle: "On the dock as \(bot.name). Its grants, activity, and Revoke are on its page.") {
                        Button("Open") { open(bot) }
                    }
                } else {
                    CallerRow(gateway: gateway, caller: caller)
                }
            }
            Button("Add an Agent with a Token…") { adding = true }.accessibilityIdentifier("addTokenAgent")
        }
        .sheet(isPresented: $adding) { TokenSheet(gateway: gateway, bind: bind) }
    }
}

/// One agent: who it is, what it may do without asking, its use today, and Revoke.
private struct CallerRow: View {
    let gateway: KemoSabeGateway
    let caller: GatewayCaller
    var body: some View {
        let now = Date()
        let grants = gateway.store.grants(for: caller.id)
        VStack(alignment: .leading, spacing: 6) {
            SettingsRow(caller.name, systemImage: caller.kind == .oauth ? "cloud" : caller.kind == .device ? "antenna.radiowaves.left.and.right" : "terminal",
                        subtitle: [caller.detail, gateway.ledger.usage(for: caller.id)].joined(separator: " · ")) {
                Button("Revoke", role: .destructive) { gateway.revoke(caller) }
            }
            if grants.isEmpty {
                Text("Asks you each time.").font(.caption).foregroundStyle(.secondary).padding(.leading, 42)
            }
            ForEach(grants) { grant in
                HStack {
                    Label(grant.tool.title + ": " + grant.summary(now: now), systemImage: grant.tool.symbol).font(.caption)
                    Spacer()
                    Button("Remove") { gateway.store.revokeGrant(grant.id) }.controlSize(.small)
                }
                .padding(.leading, 42)
            }
        }
    }
}

/// Makes a token for an agent that can't sign in with OAuth (a coding agent in a terminal), shown once.
private struct TokenSheet: View {
    let gateway: KemoSabeGateway
    let bind: (String, ServiceID?, String) -> Void
    @State private var name = "Claude Code"
    @State private var service: ServiceID? = .claude
    @State private var token: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add an Agent with a Token").font(.system(size: 17, weight: .bold))
            if let token {
                Text("Copy it now: Tsukumo keeps only a fingerprint of it and can’t show it again.").font(.callout).foregroundStyle(.secondary)
                field("Token", token)
                field("Claude Code", KemoSabeGateway.claudeCodeCommand(url: gateway.localURL, token: token))
                field("Codex (with KEMOSABE_TOKEN set to the token)", KemoSabeGateway.codexCommand(url: gateway.localURL))
            } else {
                TextField("Name", text: $name)
                    .onChange(of: name) { _, typed in service = ServiceID.guess(forCallerName: typed) }
                ServicePicker(service: $service)
                Text("It can ask only what you allow, like any agent, and you can revoke it in Settings.").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                if token == nil {
                    Button("Cancel") { dismiss() }
                    Button("Make Token") {
                        let made = gateway.store.addTokenCaller(name: name)
                        bind(made.caller.id, service, "with a token you made")
                        token = made.token
                    }.buttonStyle(.borderedProminent)
                } else {
                    Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(22)
        .frame(width: 520)
    }
    private func field(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(value).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).lineLimit(3)
                Spacer()
                Button("Copy") { copy(value) }
            }
        }
    }
}

// MARK: Sign-in

/// The windows for clients signing in with OAuth, one at a time (TsukumoGateway's `GatewaySignInQueue`). Each window
/// is made for one request and never changes; a sign-in arriving meanwhile waits its turn.
@MainActor final class GatewaySignInWindow {
    let queue: GatewaySignInQueue
    private var window: NSWindow?
    private var closing: NSObjectProtocol?
    /// Binds an allowed caller (by its authenticated ID) to the service the owner picked, with how it came.
    let bind: (String, ServiceID?, String) -> Void
    init(desk: GatewayDesk, bind: @escaping (String, ServiceID?, String) -> Void = { _, _, _ in }) {
        queue = GatewaySignInQueue(desk: desk); self.bind = bind
    }

    func show(_ request: GatewayApprovalRequest) {
        if queue.current?.id == request.id { window?.makeKeyAndOrderFront(nil); return }
        if queue.add(request) { present() }
    }

    private func present() {
        guard let request = queue.current else { return }
        let id = request.id
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 360), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Connect to KemoSabe"
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: GatewaySignInView(request: request, armingDelay: .seconds(queue.armingDelay)) { [weak self] approval, service in
            guard let self, self.queue.answer(id, approval) else { return }
            if case .allowClient = approval { self.bind(request.callerID, service, GatewaySignInView.transport(request)) }
            self.window?.close()
        })
        window.contentView = host
        // As tall as its content, so the whole return address shows.
        window.setContentSize(host.fittingSize)
        window.center()
        // Closing the window is no answer: the sign-in waits until it expires, or the owner refuses it in Settings.
        closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closed(id) }
        }
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func closed(_ id: UUID) {
        if let closing { NotificationCenter.default.removeObserver(closing) }
        closing = nil
        window = nil
        if queue.current?.id == id { if queue.closed(id) { present() } } else if queue.advance() { present() }
    }
}

struct GatewaySignInView: View {
    let request: GatewayApprovalRequest
    /// Allow is enabled only after a moment, so a click meant for something else can't land on it (the queue
    /// refuses an early Allow too).
    var armingDelay: Duration = .seconds(1.5)
    /// The owner's answer, and which service they said it is (nil: none of them).
    let answer: (GatewayApproval, ServiceID?) -> Void
    @State private var freeBusy = false
    @State private var armed = false
    @State private var service: ServiceID?
    @State private var guessed = false

    /// How a sign-in came, in words kept with the owner's choice.
    static func transport(_ request: GatewayApprovalRequest) -> String {
        guard case .newClient(_, let local, let relayed) = request.kind else { return "signed in with OAuth" }
        return local ? "signed in from this Mac" : relayed ? "signed in through the relay" : "signed in through a public address"
    }
    @Environment(\.colorScheme) private var scheme

    private var redirect: (uri: String, local: Bool, relayed: Bool)? {
        if case .newClient(let uri, let local, let relayed) = request.kind { (uri, local, relayed) } else { nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "person.badge.key").font(.system(size: 26)).foregroundStyle(TsukumoTheme(scheme).accent)
                Text(request.title).font(.system(size: 17, weight: .bold)).fixedSize(horizontal: false, vertical: true)
            }
            Label("Unverified app. It named itself “\(request.callerName)”; Tsukumo can’t check that it is who it says.", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            if let redirect {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sends you back to").font(.caption).foregroundStyle(.secondary)
                    // The whole address, every character: wrapped, selectable, and scrollable when it's long.
                    ScrollView(.vertical) {
                        Text(redirect.uri).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            .lineLimit(nil).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120).fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Sends you back to " + redirect.uri)
                    Text(redirect.local ? "Connected from this Mac (127.0.0.1)." : redirect.relayed ? "Connected through the public relay." : "Connected through a public address.").font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                ServicePicker(service: $service)
                Text("Unverified: Tsukumo can’t check this. Its bot, activity, and permissions are filed under what you pick here.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("It gets nothing until you allow each kind of request.").font(.callout).fixedSize(horizontal: false, vertical: true)
            Toggle("Let it see when you’re busy or free (whole days, the next 7 days) without asking", isOn: $freeBusy)
            Text("Everything else asks you on a card the first time. You can revoke it in Settings, Gateway.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Don’t Allow") { answer(.deny, nil) }.keyboardShortcut(.cancelAction)
                Button("Allow") { answer(.allowClient(freeBusy ? [.freeBusy] : []), service) }
                    .buttonStyle(.borderedProminent).tint(TsukumoTheme(scheme).accent)
                    .disabled(!armed)
                    .accessibilityHint(armed ? "" : "Available in a moment")
            }
        }
        .padding(22)
        .frame(width: 460)
        .task {
            if !guessed { service = ServiceID.guess(forCallerName: request.callerName); guessed = true }
            try? await Task.sleep(for: armingDelay)
            armed = true
        }
    }
}

/// Which service a caller is, as the owner says: every service, or none of them.
struct ServicePicker: View {
    @Binding var service: ServiceID?
    var body: some View {
        Picker("This agent is", selection: $service) {
            Text("None of these (another agent)").tag(ServiceID?.none)
            Divider()
            ForEach(ServiceID.allCases) { Text($0.title).tag(ServiceID?.some($0)) }
        }
        .accessibilityIdentifier("callerService")
    }
}

import AppKit
import Observation
import SwiftUI
import TsukumoCore
import TsukumoEngines
import TsukumoGate
import TsukumoPolicy
import TsukumoSync
import TsukumoUI
import TsukumoDock
import TsukumoMuse
import TsukumoUpdate
import TsukumoVoice

// Settings (⌘,): a Mac Settings window with a sidebar, in MacSpaces' design language on Tsukumo's palette
// (the pieces are TsukumoDock's `SettingsPage`, `SettingsCard`, and `SettingsRow`). Its pages follow the
// iPhone's Settings, in the same order and with the same names where they overlap (AGENTS.md rule 9):
// Account, Bots, Models, KemoSabe; then what only a Mac has: the KemoSabe gateway, the Dock, and General. Each control has one
// home (rule 11): the dock's look is in Dock (its right-click menu keeps only where it sits, hiding, and
// magnification, like the Dock's own), KemoSabe's palette is in KemoSabe and in its own editor from Bots,
// and nothing chooses where the bots live: Tsukumo on a Mac is the side dock.

/// The pages, from the catalog both devices share (TsukumoUI's `SettingsCatalog`).
typealias SettingsSection = SettingsCatalog.Page

@MainActor @Observable final class SettingsState {
    var section: SettingsSection? = .account
    /// The Models page's tab (LLM, System One, Voice).
    var modelsPage: ModelsPane.Page = .llm
    /// A System One decision model's page, when one is open ("laya", or a hosted model's id).
    var systemOneDetail: String?
    /// A bot's page in Settings, Bots, when one is open.
    var botPage: BotPage?
    /// What's typed in Search.
    var search = ""
    /// The card a search result opened: its page scrolls to it and outlines it.
    var searchTarget: String?
}

/// The Settings window.
@MainActor final class SettingsWindow {
    let window: NSWindow
    let state = SettingsState()

    init(app: TsukumoDelegate) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 640),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = SettingsSection.account.title
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 720, height: 520)
        let window = self.window
        let host = NSHostingView(rootView: SettingsView(app: app, state: state) { window.title = $0.title })
        // The window owns its size, not SwiftUI's ideal size while a page changes.
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        window.setContentSize(NSSize(width: 880, height: 640))
        window.center()
    }

    func show(_ section: SettingsSection?) {
        if let section { state.section = section }
        window.title = (state.section ?? .account).title
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    /// DEBUG `--capture` is saving pictures.
    nonisolated(unsafe) static var capturing = false
    let app: TsukumoDelegate
    @Bindable var state: SettingsState
    /// The page changed (the window's title follows, for the Window menu and Mission Control).
    var changed: (SettingsSection) -> Void = { _ in }
    @Environment(\.colorScheme) private var scheme
    @State private var resultIndex = 0
    @State private var compactSearch = false
    @FocusState private var searchFocused: Bool
    private var results: [SettingsCatalog.Topic] { SettingsCatalog.search(state.search, on: .mac) }
    private var searching: Bool { !state.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var engineInfo: @Sendable (EngineID) -> EngineInfo {
        if let dock = app.dock { return dock.engineInfo }
        return { EngineInfo.standard($0) }
    }

    /// Fills the window it's given; below 720 points wide the sidebar shrinks to its icons.
    var body: some View {
        let colors = SettingsColors(scheme)
        let section = state.section ?? .account
        GeometryReader { proxy in
            let compact = proxy.size.width < 720
            HStack(spacing: 0) {
                SettingsSidebar(selection: $state.section, compact: compact, opened: { state.search = ""; state.searchTarget = nil; compactSearch = false }) {
                    if compact {
                        Button { compactSearch = true } label: { Image(systemName: "magnifyingglass").frame(maxWidth: .infinity, minHeight: 30) }
                            .buttonStyle(.plain).accessibilityLabel("Search settings")
                            .popover(isPresented: $compactSearch) { searchField.frame(width: 240).padding(12).onAppear { searchFocused = true } }
                    } else { searchField }
                }
                .frame(width: compact ? 60 : 214)
                Rectangle().fill(colors.border).frame(width: 1).ignoresSafeArea()
                Group { if searching { searchResults } else { page(section) } }
                .sheet(item: $state.botPage) { page in
                    if let dock = app.dock { BotPageSheet(app: app, dock: dock, page: page) { state.botPage = nil } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(\.engineInfo, engineInfo)
                .environment(\.codexPets, app.dock?.pets ?? [])
                .environment(\.voice, app.voice)
                .environment(\.settingsSearchTarget, state.searchTarget)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .background(colors.surface)
        .foregroundStyle(colors.ink)
        .tint(colors.accent)
        .frame(minWidth: 600, minHeight: 480)
        // `--capture` draws windows as AppKit does, which can't draw live Liquid Glass: the dock's glass draws its stand-in.
        .environment(\.dockGlassFallback, SettingsView.capturing)
        // ⌘F: Search.
        .background {
            Button { compactSearch = true; searchFocused = true } label: { EmptyView() }
                .keyboardShortcut("f", modifiers: .command).frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        }
        .onChange(of: state.search) { _, _ in resultIndex = 0 }
        .onChange(of: state.section) { _, section in changed(section ?? .account) }
    }

    /// Search, as MacSpaces has it: a capsule under Tsukumo's name; its results fill the page, ↑ and ↓ move, Return
    /// opens one, Esc clears.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search settings", text: $state.search)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityLabel("Search settings")
                .accessibilityIdentifier("settingsSearch")
                .tint(Color.primary)
                .onSubmit { if results.indices.contains(resultIndex) { open(results[resultIndex]) } }
                .onKeyPress(.downArrow) { resultIndex = min(max(0, results.count - 1), resultIndex + 1); return .handled }
                .onKeyPress(.upArrow) { resultIndex = max(0, resultIndex - 1); return .handled }
                .onKeyPress(.escape) { state.search = ""; searchFocused = false; compactSearch = false; return .handled }
            if !state.search.isEmpty {
                Button { state.search = ""; state.searchTarget = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12).frame(height: 34)
        .background(Color.primary.opacity(searchFocused ? 0.09 : 0.06), in: Capsule())
        .overlay { Capsule().strokeBorder(Color.primary.opacity(searchFocused ? 0.18 : 0), lineWidth: 1) }
    }

    private var searchResults: some View {
        let colors = SettingsColors(scheme)
        return SettingsPage(title: "Search", subtitle: "\(results.count) matching setting\(results.count == 1 ? "" : "s")",
                            scrollAnchor: results.indices.contains(resultIndex) ? "search." + results[resultIndex].id : nil) {
            if results.isEmpty {
                ContentUnavailableView.search(text: state.search)
            } else {
                VStack(spacing: 6) {
                    ForEach(results.indices, id: \.self) { index in
                        let result = results[index]
                        Button { open(result) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: result.page.symbol).frame(width: 22).foregroundStyle(colors.accent)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(result.title).font(.system(size: 14, weight: .semibold))
                                    Text(result.location).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(12).contentShape(Rectangle())
                            .background(index == resultIndex ? colors.selected : colors.tile, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                        .buttonStyle(.plain).id("search." + result.id)
                        .accessibilityLabel(result.title + ", in " + result.location)
                        .accessibilityIdentifier("settingsResult-" + result.id)
                    }
                }
            }
        }
    }

    @ViewBuilder private func page(_ section: SettingsSection) -> some View {
                SettingsPage(title: section.title, subtitle: section.subtitle) {
                    if let dock = app.dock {
                        switch section {
                        case .account: AccountPane(app: app)
                        case .bots: BotsPane(app: app, dock: dock, state: state)
                        case .models: ModelsPane(app: app, dock: dock, page: $state.modelsPage, systemOneDetail: $state.systemOneDetail,
                                                 openService: { state.botPage = .service($0) })
                        case .connections: SourcesCard(library: app.sources)
                        case .gateway: if let gateway = app.gateway { GatewayPane(gateway: gateway, review: { app.showSignIn($0) },
                                                                       binding: { dock.store.binding(forCaller: $0)?.service },
                                                                       bind: { caller, service, transport in dock.bind(caller: caller, to: service, transport: transport); app.refreshServices() },
                                                                       identity: { dock.identityLine(for: $0) }) } else { SettingsNote("The gateway isn’t available in the demo.") }
                        case .dock: BotDockSettingsView(dock: dock)
                        case .general: GeneralPane(app: app)
                        }
                    }
                }
                .id(section)
    }

    /// A search result: its page, Models' tab, or a bot's own page under Bots, scrolled to its card.
    private func open(_ topic: SettingsCatalog.Topic) {
        state.search = ""; compactSearch = false; searchFocused = false
        if let tab = topic.tab { state.modelsPage = tab }
        if topic.kemoSabeBot { state.botPage = .kemoSabe } else if let service = topic.service { state.botPage = .service(service) }
        if topic.newBot { app.controller?.open(.addBot) }
        state.searchTarget = topic.title
        state.section = topic.page
    }
}

/// The pages down the left, as MacSpaces has them: Tsukumo's icon and name on top, then each page's
/// plain symbol and name. The page you're on has a soft gray fill with a thin coral bar at its edge.
struct SettingsSidebar<Search: View>: View {
    @Binding var selection: SettingsSection?
    var compact = false
    /// A page was chosen here (Search clears).
    var opened: () -> Void = {}
    /// Search, under Tsukumo's name.
    @ViewBuilder var search: Search
    @State private var hovered: SettingsSection?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let colors = SettingsColors(scheme)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                TsukumoAppIcon(size: compact ? 30 : 34)
                if !compact {
                    Text("Tsukumo").font(.system(size: 15, weight: .bold))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, compact ? 15 : 16)
            .padding(.top, 20)
            .padding(.bottom, 16)

            search
                .padding(.horizontal, compact ? 8 : 10).padding(.bottom, 12)

            VStack(spacing: 3) {
                ForEach(SettingsSection.pages(on: .mac)) { item(for: $0, colors: colors) }
            }
            .padding(.horizontal, compact ? 8 : 10)
            Spacer(minLength: 14)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(colors.tile)
    }

    private func item(for section: SettingsSection, colors: SettingsColors) -> some View {
        let selected = (selection ?? .account) == section
        return Button { opened(); selection = section } label: {
            HStack(spacing: 10) {
                Image(systemName: section.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? colors.accent : colors.ink.opacity(0.65))
                    .frame(width: 19)
                if !compact {
                    Text(section.title).font(.system(size: 13, weight: selected ? .semibold : .medium))
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: compact ? .infinity : nil)
            .padding(.horizontal, compact ? 0 : 10)
            .frame(height: 34)
            .contentShape(Rectangle())
            .background(selected ? colors.selected : hovered == section ? colors.hover : .clear,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(alignment: .leading) {
                if selected { Capsule().fill(colors.accent).frame(width: 2, height: 16).offset(x: -1) }
            }
        }
        .buttonStyle(.plain)
        .onHover { inside in hovered = inside ? section : (hovered == section ? nil : hovered) }
        .help(compact ? section.title : "")
        .accessibilityLabel(section.title)
        .accessibilityIdentifier("settings-" + section.rawValue)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Tsukumo's app icon, rounded like a Dock icon.
struct TsukumoAppIcon: View {
    let size: CGFloat
    var body: some View {
        Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.22), radius: size * 0.12, y: size * 0.06)
            .accessibilityHidden(true)
    }
}

// MARK: Account

/// Signed out: a centered hero (KemoSabe's cloud in its palette, one headline, one line, Sign in with Apple);
/// signed in: the name with its initials, sync's pill, and Sign Out. Then what syncs and what never leaves,
/// once, as two short columns.
struct AccountPane: View {
    let app: TsukumoDelegate
    var body: some View {
        let state = app.sync?.state ?? .noAccount
        SettingsCard(app.accounts.isSignedIn ? "Your account" : "Sign in", systemImage: "person.crop.circle") {
            AccountSummary(accounts: app.accounts, companion: app.dock?.bot(BotSpec.kemoSabeID) ?? .kemoSabe(), sync: state.account,
                           fixtureSignIn: app.fixtureSignIn, device: "Mac")
        }
        SettingsCard("What goes where", systemImage: "arrow.triangle.2.circlepath.icloud") {
            SyncFacts(device: "Mac")
        }
    }
}

extension CloudSyncState {
    /// The account page's view of it.
    var account: AccountSync {
        AccountSync(title: title, short: short, detail: detail,
                    tone: isOn ? .on : isWaiting ? .waiting : self == .noAccount ? .off : .paused, lastSynced: lastSynced)
    }
}

// MARK: Bots

// MARK: Models

struct ModelsPane: View {
    typealias Page = SettingsCatalog.ModelsTab
    let app: TsukumoDelegate
    let dock: BotDock
    @Binding var page: Page
    @Binding var systemOneDetail: String?
    /// Opens a service's own page (its agent on this Mac, its key, how it connects).
    var openService: (ServiceID) -> Void = { _ in }
    @State private var adding: ConnectionRecord.Provider?
    @State private var editing: ConnectionRecord?

    var body: some View {
        Picker("Page", selection: $page) { ForEach(Page.allCases) { Text($0.title).tag($0) } }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .accessibilityIdentifier("modelsPage")
        Group {
            switch page {
            case .llm: llm
            case .systemOne: systemOne
            case .voice:
                if let voice = app.voice { VoicePane(voice: voice, dock: dock) }
                else { SettingsNote("Voice isn’t available in the demo.") }
            }
        }
        .sheet(item: $adding) { provider in ConnectionEditor(app: app, provider: provider, existing: nil) }
        .sheet(item: $editing) { record in ConnectionEditor(app: app, provider: record.provider, existing: record) }
    }

    @ViewBuilder private var llm: some View {
        SettingsCard("On this Mac", systemImage: "apple.intelligence") {
            let status = app.appleIntelligence
            SettingsRow("Apple on-device", subtitle: status.text) {
                EngineMarkView(.apple, size: 22).frame(width: 30, height: 30)
            } trailing: {
                Image(systemName: status.ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(status.ready ? Color.green : Color.orange)
            }
            SettingsNote("KemoSabe runs here. Nothing it reads leaves this Mac.")
        }
        SettingsCard("Coding agents", systemImage: "terminal") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array([ServiceID.claude, .codex, .cursor, .gemini].enumerated()), id: \.element) { index, service in
                    if index > 0 { Divider() }
                    let agent = app.installedAgent(service)
                    Button { openService(service) } label: {
                        SettingsRow(service == .claude ? "Claude Code" : service.title,
                                    subtitle: agent.map { "Installed" + ($0.version.map { " · \($0)" } ?? "") } ?? "Not on this Mac") {
                            ServiceMarkView(service, size: 30).opacity(agent == nil ? 0.6 : 1)
                        } trailing: { SettingsChevron() }
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("codingAgent-" + service.rawValue)
                }
            }
            SettingsNote("Bots run on these with your own sign-in, never Tsukumo’s. Tsukumo looks for them each time it opens.")
        }
        SettingsCard("API models", systemImage: "key") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(app.connections) { record in
                    Button { editing = record } label: {
                        SettingsRow(record.name, subtitle: app.hasKey(record.id) || record.provider == .compatible ? "\(record.connection.model) · key on this Mac" : "No key yet") {
                            EngineMarkView(record.provider.mark, size: 22).frame(width: 30, height: 30)
                        } trailing: { SettingsChevron() }
                    }
                    .buttonStyle(.plain)
                    .contextMenu { Button("Remove \(record.name)", role: .destructive) { app.remove(connection: record.id) } }
                    Divider()
                }
                Menu {
                    ForEach([ConnectionRecord.Provider.anthropic, .openAI]) { provider in
                        Button(provider.title) { adding = provider }
                    }
                } label: { Label("Connect an API model", systemImage: "plus") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityIdentifier("connectAPI")
            }
            SettingsNote("Bots made on a key run on it. Keys stay in this Mac’s Keychain; they’re never synced or backed up. A connection made on your iPhone shows here without its key.")
        }
    }

    /// System One's tab is its own file (`SystemOneSettings.swift`).
    @ViewBuilder private var systemOne: some View {
        if let center = app.systemOne { SystemOnePane(center: center, detail: $systemOneDetail) }
        else { SettingsNote("System One isn’t available in the demo.") }
    }
}

/// Connect or edit an API model provider. The key goes to this Mac's Keychain only.
struct ConnectionEditor: View {
    let app: TsukumoDelegate
    let provider: ConnectionRecord.Provider
    let existing: ConnectionRecord?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var endpoint = ""
    @State private var model = ""
    @State private var models: [String] = []
    @State private var key = ""
    @State private var checking = false
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name).accessibilityIdentifier("connectionName")
                    if provider == .compatible {
                        TextField("Address", text: $endpoint, prompt: Text("https://…/v1/chat/completions"))
                    }
                } header: {
                    Text(existing == nil ? "Connect \(provider.title)" : name)
                } footer: { Text(provider.detail) }
                Section {
                    SecureField("API key", text: $key, prompt: Text(existing.map { app.hasKey($0.id) } == true ? "Replace the saved key" : "Paste your key"))
                        .accessibilityIdentifier("connectionKey")
                } footer: {
                    Text("Saved in this Mac’s Keychain only.")
                }
                Section {
                    if models.isEmpty {
                        TextField("Model", text: $model).font(.body.monospaced())
                    } else {
                        Picker("Model", selection: $model) { ForEach(models, id: \.self) { Text($0).tag($0) } }
                    }
                }
                if let problem { Section { Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(.orange) } }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(checking ? "Checking…" : "Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(checking || name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("saveConnection")
            }
            .padding(16)
        }
        .frame(width: 460, height: 440)
        .onAppear {
            name = existing?.name ?? provider.title
            endpoint = existing?.connection.endpoint.absoluteString ?? provider.endpoint
            model = existing?.connection.model ?? provider.defaultModel
            models = existing?.models ?? []
        }
    }

    private func save() async {
        problem = nil
        let typed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = existing.flatMap { (try? app.keys.read($0.id)) ?? nil } ?? ""
        let usable = typed.isEmpty ? saved : typed
        guard let url = URL(string: endpoint) else { problem = "Enter the full HTTPS address of the model’s API."; return }
        checking = true
        defer { checking = false }
        // The provider's own model list checks the key, and offers its models.
        if !usable.isEmpty || provider == .compatible {
            do {
                let listed = try await ModelCatalog.models(provider: provider, endpoint: url, key: usable)
                if !listed.isEmpty {
                    models = listed
                    if !listed.contains(model) { model = listed[0] }
                }
            } catch {
                problem = error.localizedDescription
                return
            }
        }
        do {
            let connection = try APIConnection.validated(id: existing?.id ?? UUID(), name: name, endpoint: endpoint, model: model, wire: provider.wire)
            try app.save(connection: ConnectionRecord(connection: connection, provider: provider, models: models), key: typed.isEmpty ? nil : typed)
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}

// MARK: KemoSabe

/// KemoSabe: the bots it answers, whether it chirps, and its journal. Its character, palette, and voice are on its page
/// in Settings, Bots; what it may read is Settings, Connections.
/// The rest of KemoSabe's page in Settings, Bots, below its character, palette, and voice: the bots it answers
/// without asking, its chirps, and its journal, drawn like the page's other groups.
struct KemoSabeMore: View {
    let app: TsukumoDelegate
    let dock: BotDock
    @State private var journal: [GateJournalEntry] = []

    private var kemoSabe: Binding<BotSpec> {
        Binding(get: { dock.bot(BotSpec.kemoSabeID) ?? .kemoSabe() }, set: { dock.update($0) })
    }
    private var allowedBots: [BotSpec] {
        guard let gate = dock.gate else { return [] }
        return dock.bots.filter { bot in !bot.isKemoSabe && !gate.consentGrants(for: recipient(bot)).isEmpty }
    }
    private func recipient(_ bot: BotSpec) -> RecipientID {
        if case .api(let profile) = bot.engine { return .bot(bot, host: app.connections.first { $0.id == profile }?.host) }
        return .bot(bot)
    }

    var body: some View {
        group("Allowed bots") {
            if allowedBots.isEmpty {
                note("The first time a bot asks KemoSabe something, you choose on its card in the chat.")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(allowedBots.enumerated()), id: \.element.id) { index, bot in
                        if index > 0 { Divider() }
                        SettingsRow(bot.name, subtitle: "Answered without asking") {
                            BotAvatar(bot: bot, size: 28, showsEngine: false)
                        } trailing: {
                            Button("Ask Again") { dock.gate?.revokeConsent(recipient(bot)) }
                        }
                    }
                }
                note("Ask Again has KemoSabe ask you the next time that bot asks.")
            }
        }

        group("Chirps") {
            Toggle("Chirps in about what’s coming up", isOn: Binding(get: { kemoSabe.wrappedValue.permissions.mayChirp }, set: { on in
                var bot = kemoSabe.wrappedValue
                bot.permissions.mayChirp = on
                dock.update(bot)
            }))
            if kemoSabe.wrappedValue.permissions.mayChirp {
                ForEach(DockChirpSource.allCases) { source in
                    Toggle(source.title, isOn: Binding(get: { dock.store.chirpWatch(BotSpec.kemoSabeID).sources.contains(source) }, set: { on in
                        var watch = dock.store.chirpWatch(BotSpec.kemoSabeID)
                        watch.sources.removeAll { $0 == source }
                        if on { watch.sources.append(source) }
                        dock.store.setChirpWatch(watch, for: BotSpec.kemoSabeID)
                    }))
                    .padding(.leading, 20)
                }
            }
            note("A speech bubble from KemoSabe on the dock. It reads Calendar and Reminders only when macOS allows Tsukumo to.")
        }

        // The journal shows once KemoSabe has told a bot something.
        Group { if !journal.isEmpty { group("Journal") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(journal.reversed().enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Divider() }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(entry.requesterName).font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text(entry.decidedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.tertiary)
                        }
                        Text("“\(entry.question)”").font(.callout)
                        if !entry.purpose.isEmpty { Text("Why: " + entry.purpose).font(.caption).foregroundStyle(.secondary) }
                        Text(entry.shared.map { "Sent: “\($0)”" } ?? "Nothing was sent.").font(.caption).foregroundStyle(.secondary)
                        if let withheld = entry.withheld { Text(withheld).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        } } }
        .task { journal = dock.gate?.journal.all() ?? [] }
    }

    private func group(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 12, weight: .semibold))
            content()
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: General

struct GeneralPane: View {
    let app: TsukumoDelegate
    var body: some View {
        let login = app.launchAtLogin
        AppearanceCard()
        SettingsCard("Startup", systemImage: "power") {
            Toggle("Open at Login", isOn: Binding(get: { login.isOn }, set: { login.set($0) }))
                .accessibilityIdentifier("launchAtLogin")
            if login.needsApproval {
                SettingsNote("Allow Tsukumo in System Settings, General, Login Items.", warning: true)
            }
            if let problem = login.problem { SettingsNote(problem, warning: true) }
            SettingsNote("Your bots’ dock is there when you start your Mac.")
        }
        .onAppear { login.refresh() }
        SettingsCard("About", systemImage: "info.circle") {
            HStack(spacing: 12) {
                TsukumoAppIcon(size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Tsukumo " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""))
                        .font(.system(size: 14, weight: .semibold))
                    Text("Your bots’ side dock, with KemoSabe on this Mac.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let problem = app.migrationProblem { SettingsNote(problem, warning: true) }
        }
        SoftwareUpdateCard(updates: app.updates)
    }
}

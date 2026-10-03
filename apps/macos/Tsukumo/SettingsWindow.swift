import AppKit
import Observation
import SwiftUI
import TsukumoCore
import TsukumoEngines
import TsukumoGate
import TsukumoPolicy
import TsukumoUI
import TsukumoDock

// Settings (⌘,): a Mac Settings window with a sidebar. Its pages follow the iPhone's Settings, in the same
// order and with the same names where they overlap (AGENTS.md rule 9): Account, Bots, Models, KemoSabe;
// then what only a Mac has: the Dock, and General. Each control has one home (rule 11): the dock's look is
// in Dock (its right-click menu keeps only where it sits, hiding, and magnification, like the Dock's own),
// KemoSabe's color is in KemoSabe and in its own editor from Bots, and nothing chooses where the bots live:
// Tsukumo on a Mac is the side dock.

enum SettingsSection: String, CaseIterable, Identifiable, Sendable {
    case account, bots, models, kemoSabe, dock, general
    var id: String { rawValue }
    var title: String {
        switch self {
        case .account: "Account"
        case .bots: "Bots"
        case .models: "Models"
        case .kemoSabe: "KemoSabe"
        case .dock: "Dock"
        case .general: "General"
        }
    }
    var symbol: String {
        switch self {
        case .account: "person.crop.circle"
        case .bots: "person.2"
        case .models: "cpu"
        case .kemoSabe: "lock.shield"
        case .dock: "dock.rectangle"
        case .general: "gearshape"
        }
    }
}

@MainActor @Observable final class SettingsState {
    var section: SettingsSection? = .account
}

/// The Settings window.
@MainActor final class SettingsWindow {
    let window: NSWindow
    let state = SettingsState()

    init(app: TsukumoDelegate) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 580),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = SettingsSection.account.title
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 700, height: 480)
        let window = self.window
        window.contentViewController = NSHostingController(rootView: SettingsView(app: app, state: state) { window.title = $0.title })
        window.setContentSize(NSSize(width: 780, height: 580))
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
    let app: TsukumoDelegate
    @Bindable var state: SettingsState
    /// The page changed (the window's title follows, for the Window menu and Mission Control).
    var changed: (SettingsSection) -> Void = { _ in }
    private var engineInfo: @Sendable (EngineID) -> EngineInfo {
        if let dock = app.dock { return dock.engineInfo }
        return { EngineInfo.standard($0) }
    }

    var body: some View {
        let section = state.section ?? .account
        HStack(spacing: 0) {
            SettingsSidebar(selection: $state.section)
                .frame(width: 200)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(section.title).font(.title3.weight(.semibold))
                    .padding(.horizontal, 20).frame(height: 52, alignment: .center)
                    .accessibilityAddTraits(.isHeader)
                Divider()
                Group {
                    if let dock = app.dock {
                        switch section {
                        case .account: AccountPane(app: app)
                        case .bots: BotsPane(dock: dock)
                        case .models: ModelsPane(app: app, dock: dock)
                        case .kemoSabe: KemoSabePane(app: app, dock: dock)
                        case .dock: Form { BotDockSettingsView(dock: dock) }.formStyle(.grouped)
                        case .general: GeneralPane(app: app)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(\.engineInfo, engineInfo)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 700, minHeight: 480)
        .onChange(of: state.section) { _, section in changed(section ?? .account) }
    }
}

/// The pages, down the left like System Settings: each with its icon on a colored tile.
struct SettingsSidebar: View {
    @Binding var selection: SettingsSection?
    @Environment(\.colorScheme) private var scheme

    private func tile(_ section: SettingsSection) -> Color {
        switch section {
        case .account: .blue
        case .bots: .orange
        case .models: .purple
        case .kemoSabe: Color(red: 0.94, green: 0.44, blue: 0.36)
        case .dock: .teal
        case .general: .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Color.clear.frame(height: 44)   // under the window's buttons
            ForEach(SettingsSection.allCases) { section in
                let selected = (selection ?? .account) == section
                Button { selection = section } label: {
                    HStack(spacing: 8) {
                        Image(systemName: section.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(tile(section).gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        Text(section.title).font(.system(size: 13))
                            .foregroundStyle(selected ? Color.white : Color.primary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings-" + section.rawValue)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(scheme == .dark ? 0.6 : 0.5))
    }
}

// MARK: Account

struct AccountPane: View {
    let app: TsukumoDelegate
    var body: some View {
        let state = app.sync?.state ?? .noAccount
        Form {
            Section {
                AccountSummary(accounts: app.accounts, syncTitle: state.title, syncDetail: state.detail, syncOn: state.isOn,
                               fixtureSignIn: app.fixtureSignIn, device: "Mac")
            } footer: {
                Text(app.accounts.isSignedIn
                     ? "Signing out keeps your bots and chats on this Mac and stops syncing them. Your Apple ID is kept in this Mac’s Keychain only."
                     : "Signing in keeps your bots and chats in step with your iPhone through your own iCloud. Your Apple ID is kept in this Mac’s Keychain only.")
            }
            Section("What syncs") {
                Label("Your bots, how they look, and your chats", systemImage: "icloud")
                Label("The default model, and connections without their keys", systemImage: "icloud")
                Label("Never: API keys, KemoSabe’s answers, its journal and permissions, and chats you keep on one device", systemImage: "lock")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Bots

struct BotsPane: View {
    let dock: BotDock
    private enum Editing: Identifiable { case new, bot(UUID); var id: String { if case .bot(let id) = self { id.uuidString } else { "new" } } }
    @State private var editing: Editing?

    var body: some View {
        Form {
            Section {
                ForEach(Array(dock.bots.enumerated()), id: \.element.id) { index, bot in
                    Button { editing = .bot(bot.id) } label: {
                        HStack(spacing: 12) {
                            BotAvatar(bot: bot, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bot.name).font(.body.weight(.medium))
                                Text(dock.subtitle(bot.id)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if bot.isKemoSabe {
                                Circle().fill(bot.kemoSabeColor).frame(width: 14, height: 14).accessibilityLabel("Its color")
                            }
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settingsBot-" + (bot.isKemoSabe ? "kemosabe" : bot.name))
                    .contextMenu {
                        if !bot.isKemoSabe {
                            Button("Move Up") { dock.move(bot.id, to: index - 1) }.disabled(index <= 1)
                            Button("Move Down") { dock.move(bot.id, to: index + 1) }.disabled(index >= dock.bots.count - 1)
                            Divider()
                            Button("Remove \(bot.name)", role: .destructive) { dock.remove(bot.id) }
                        }
                    }
                }
                Button { editing = .new } label: { Label("Make a bot", systemImage: "plus") }
                    .accessibilityIdentifier("settingsAddBot")
            } header: {
                Text("Your bots")
            } footer: {
                Text("KemoSabe is always here. It runs on this Mac and answers the other bots’ questions about you. Right-click a bot to move or remove it.")
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { target in
            Group {
                switch target {
                case .new: DockBotForm(dock: dock, editing: nil, opensChat: false) { editing = nil }
                case .bot(let id): DockBotForm(dock: dock, editing: dock.bot(id), opensChat: false) { editing = nil }
                }
            }
            .frame(width: DockMetrics.form.width, height: DockMetrics.form.height)
        }
    }
}

// MARK: Models

struct ModelsPane: View {
    enum Page: String, CaseIterable, Identifiable {
        case llm, systemOne
        var id: String { rawValue }
        var title: String { self == .llm ? "LLM" : "System One" }
    }
    let app: TsukumoDelegate
    let dock: BotDock
    @State private var page: Page = .llm
    @State private var adding: ConnectionRecord.Provider?
    @State private var editing: ConnectionRecord?

    var body: some View {
        Form {
            Section {
                Picker("Page", selection: $page) { ForEach(Page.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
                    .accessibilityIdentifier("modelsPage")
            }
            if page == .llm { llm } else { systemOne }
        }
        .formStyle(.grouped)
        .sheet(item: $adding) { provider in ConnectionEditor(app: app, provider: provider, existing: nil) }
        .sheet(item: $editing) { record in ConnectionEditor(app: app, provider: record.provider, existing: record) }
    }

    @ViewBuilder private var llm: some View {
        Section {
            let status = app.appleIntelligence
            LabeledContent {
                Text(status.text).foregroundStyle(status.ready ? Color.secondary : Color.orange)
            } label: {
                Label("Apple on-device", systemImage: "apple.intelligence")
            }
        } header: {
            Text("On this Mac")
        } footer: {
            Text("KemoSabe runs here, and so can any bot you make with Apple on-device. Nothing it reads leaves this Mac.")
        }
        Section {
            Picker("New bots start on", selection: Binding(get: { dock.store.defaultModel?.engine ?? .appleOnDevice }, set: { engine in
                let record = app.connections.first { $0.engine == engine }
                dock.store.setDefaultModel(DefaultModel(engine: engine, model: record?.connection.model))
            })) {
                ForEach(dock.engineChoices) { choice in Text(choice.info.title).tag(choice.engine) }
            }
            .accessibilityIdentifier("defaultModel")
        } header: {
            Text("Default")
        } footer: {
            Text("The model a new bot starts on. It follows you to your iPhone; keys don’t.")
        }
        Section {
            ForEach(app.connections) { record in
                Button { editing = record } label: {
                    HStack(spacing: 12) {
                        EngineMarkView(record.provider.mark, size: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.name)
                            Text(app.hasKey(record.id) || record.provider == .compatible ? "\(record.connection.model) · key on this Mac" : "No key yet")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu { Button("Remove \(record.name)", role: .destructive) { app.remove(connection: record.id) } }
            }
            Menu {
                ForEach(ConnectionRecord.Provider.allCases) { provider in
                    Button(provider.title) { adding = provider }
                }
            } label: { Label("Connect an API model", systemImage: "plus") }
                .fixedSize()
                .accessibilityIdentifier("connectAPI")
        } header: {
            Text("API models")
        } footer: {
            Text("Keys stay in this Mac’s Keychain. They’re never synced or backed up. A connection made on your iPhone shows here without its key.")
        }
    }

    @ViewBuilder private var systemOne: some View {
        Section {
            LabeledContent("Routing", value: "The bot you last talked to")
            LabeledContent("Laya", value: "Not on this Mac yet")
        } header: {
            Text("Untagged messages")
        } footer: {
            Text("When you don’t tag a bot, System One picks one only when it’s sure; otherwise your message goes to the bot you last talked to.")
        }
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

/// KemoSabe: its color, what it may read and how private each source is, the bots it answers, whether
/// it chirps, and its journal.
struct KemoSabePane: View {
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
        Form {
            Section {
                HStack(spacing: 14) {
                    BotAvatar(bot: kemoSabe.wrappedValue, size: 44)
                    KemoSabeColorPicker(bot: kemoSabe, size: 22)
                }
            } header: {
                Text("Its color")
            } footer: {
                Text("KemoSabe is always the same: its cloud, its name, and Apple’s on-device model on this Mac. Its color is yours to pick: its card, ring, and buttons in your chats.")
            }

            Section {
                ForEach(PersonalSourceKind.allCases) { source in
                    let setting = app.setting(source)
                    Toggle(isOn: Binding(get: { setting.on }, set: { on in Task { await app.set(source, on: on) } })) {
                        Label(source.title, systemImage: source.symbol)
                    }
                    .accessibilityIdentifier("source-" + source.rawValue)
                    if setting.on {
                        Picker("How private", selection: Binding(get: { setting.level }, set: { level in Task { await app.set(source, level: level) } })) {
                            ForEach(PrivacyLevel.allCases) { Text($0.title).tag($0) }
                        }
                    }
                }
            } header: {
                Text("What KemoSabe may read")
            } footer: {
                Text("KemoSabe reads a source only on this Mac, and shares only the answer. Sensitive items ask you on a card each time. Device only never leaves this Mac. Secret is never read.")
            }

            Section {
                if allowedBots.isEmpty {
                    Text("The first time a bot asks KemoSabe something, you choose on its card in the chat.").foregroundStyle(.secondary)
                }
                ForEach(allowedBots) { bot in
                    HStack {
                        BotAvatar(bot: bot, size: 26, showsEngine: false)
                        Text(bot.name)
                        Spacer()
                        Button("Ask Again") { dock.gate?.revokeConsent(recipient(bot)) }
                    }
                }
            } header: {
                Text("Bots KemoSabe answers")
            } footer: {
                Text("Ask Again has KemoSabe ask you the next time that bot asks.")
            }

            Section {
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
                        .padding(.leading, 18)
                    }
                }
            } header: {
                Text("Speaking up")
            } footer: {
                Text("A speech bubble from KemoSabe on the dock. It reads Calendar and Reminders only when macOS allows Tsukumo to.")
            }

            Section("Journal") {
                if journal.isEmpty {
                    Text("What KemoSabe tells your bots shows here: who asked, why, and exactly what was sent.").foregroundStyle(.secondary)
                }
                ForEach(journal.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(entry.requesterName).font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(entry.decidedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("“\(entry.question)”").font(.callout)
                        if !entry.purpose.isEmpty { Text("Why: " + entry.purpose).font(.caption).foregroundStyle(.secondary) }
                        Text(entry.shared.map { "Sent: “\($0)”" } ?? "Nothing was sent.").font(.caption).foregroundStyle(.secondary)
                        if let withheld = entry.withheld { Text(withheld).font(.caption).foregroundStyle(.secondary) }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .formStyle(.grouped)
        .task { journal = await dock.gate?.journal.all() ?? [] }
    }
}

// MARK: General

struct GeneralPane: View {
    let app: TsukumoDelegate
    var body: some View {
        let login = app.launchAtLogin
        Form {
            Section {
                Toggle("Open at Login", isOn: Binding(get: { login.isOn }, set: { login.set($0) }))
                    .accessibilityIdentifier("launchAtLogin")
                if login.needsApproval {
                    Text("Allow Tsukumo in System Settings, General, Login Items.").font(.caption).foregroundStyle(.orange)
                }
                if let problem = login.problem { Text(problem).font(.caption).foregroundStyle(.orange) }
            } footer: {
                Text("Your bots’ dock is there when you start your Mac.")
            }
            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            }
            if let problem = app.migrationProblem {
                Section { Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
            }
        }
        .formStyle(.grouped)
        .onAppear { login.refresh() }
    }
}

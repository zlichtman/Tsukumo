import SwiftUI
import TsukumoCore
import TsukumoUI
import TsukumoEngines
import TsukumoGate
import TsukumoSync
import TsukumoVoice
import PhotosUI

/// Where Settings goes.
enum SettingsDestination: Hashable { case account, models, connections, activity }

/// Settings (design/UI-GUIDE.md, Settings), from your picture at the top right: your picture and name (Account), then every setting: Bots (KemoSabe, with
/// the bots it answers and its journal, and the owner's bots, with New Bot), Models (API connections, Apple
/// on-device, System One, and Voice), Connections (what KemoSabe may read, and how private each one is), and Activity.
struct SettingsScreen: View {
    @Environment(AppModel.self) private var model
    @Binding var path: [SettingsDestination]
    /// Closes Settings (its close button at the top).
    var close: () -> Void = {}
    /// Shows the chat (after Activity opens one).
    var showChat: () -> Void = {}
    @State private var editing: BotSpec?
    @State private var making: BotSpec?
    @State private var search = ""

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !search.trimmingCharacters(in: .whitespaces).isEmpty { results.tsukumoRows() } else { pages }
            }
            .searchable(text: $search, prompt: "Search settings")
            .tsukumoScreen(sheet: true)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button(role: .close, action: close).accessibilityIdentifier("closeSettings") }
            }
            .navigationDestination(for: SettingsDestination.self) { destination in
                switch destination {
                case .account: AccountPage()
                case .models: ModelsPage()
                case .connections: SourcesPage()
                case .activity: ActivityPage { showChat() }
                }
            }
            .sheet(item: $editing) { bot in
                BotSettingsSheet(bot: bot, engines: model.engineChoices, device: "iPhone",
                                 kemoSabeNote: "What KemoSabe may read is in Settings, Connections.",
                                 kemoSabeMore: AnyView(KemoSabeMore().environment(model))) { saved in
                    if let problem = model.save(bot: saved) { return problem.message }
                    editing = nil
                    return nil
                } onRemove: { model.problem = model.remove(bot: bot.id)?.message; editing = nil } onCancel: { editing = nil }
                .tsukumoSheet()
            }
            .sheet(item: $making) { bot in
                BotSettingsSheet(bot: bot, engines: model.engineChoices, device: "iPhone", isNew: true) { made in
                    switch model.add(bot: made) {
                    case .success: making = nil; return nil
                    case .failure(let problem): return problem.message
                    }
                } onCancel: { making = nil }
                .tsukumoSheet()
            }
        }
    }

    /// Search, from the catalog the Mac shares: each result opens where it is.
    @ViewBuilder private var results: some View {
        let found = SettingsCatalog.search(search, on: .iPhone)
        if found.isEmpty {
            Text("No settings match “\(search)”.").foregroundStyle(.secondary)
        }
        ForEach(found) { topic in
            switch topic.page {
            case .account: NavigationLink { AccountPage() } label: { result(topic) }
            case .models: NavigationLink { ModelsPage(page: topic.tab ?? .llm) } label: { result(topic) }
            case .connections: NavigationLink { SourcesPage() } label: { result(topic) }
            default:
                if topic.kemoSabeBot, let bot = model.bots.first(where: \.isKemoSabe) {
                    Button { editing = bot } label: { result(topic) }.buttonStyle(.plain)
                } else if topic.newBot {
                    Button { search = ""; making = newBot } label: { result(topic) }.buttonStyle(.plain)
                } else if let service = topic.service, service == .claude || service == .openAI {
                    // Not connected yet: its key goes in Models.
                    NavigationLink { ModelsPage(page: .llm) } label: { result(topic, note: "Not connected · add your key in Models.") }
                } else {
                    // Bots itself, or a service that doesn’t connect on iPhone yet: back to the list, where it is.
                    Button { search = "" } label: { result(topic, note: topic.service == nil ? nil : "Not on iPhone yet.") }.buttonStyle(.plain)
                }
            }
        }
    }
    private func result(_ topic: SettingsCatalog.Topic, note: String? = nil) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(topic.title)
                Text(note ?? topic.location).font(.footnote).foregroundStyle(.secondary)
            }
        } icon: { Image(systemName: topic.page.symbol) }
        .accessibilityIdentifier("settingsResult-" + topic.id)
    }

    @ViewBuilder private var pages: some View {
        Section {
            ProfileHeader()
                .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        }
        .tsukumoRows()

        Section {
            ForEach(model.bots) { bot in
                Button { editing = bot } label: { BotRow(bot: bot) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("bot-" + (bot.isKemoSabe ? "kemosabe" : bot.name))
            }
            Button { making = newBot } label: { Label("New Bot", systemImage: "plus") }
                .accessibilityIdentifier("newBot")
        } header: {
            Text("Bots")
        } footer: {
            let elsewhere = model.saved.count - model.bots.count
            Text("KemoSabe is always here, on this iPhone. Make a bot on Apple on-device or one of your keys in Models." + (elsewhere > 0 ? " \(elsewhere) of your bots can’t run on iPhone." : ""))
        }
        .tsukumoRows()

        Section {
            NavigationLink(value: SettingsDestination.models) {
                Label(SettingsCatalog.Page.models.title, systemImage: SettingsCatalog.Page.models.symbol)
            }
            .accessibilityIdentifier("settingsModels")
            NavigationLink(value: SettingsDestination.connections) {
                Label(SettingsCatalog.Page.connections.title, systemImage: SettingsCatalog.Page.connections.symbol)
            }
            .accessibilityIdentifier("settingsSources")
            NavigationLink(value: SettingsDestination.activity) {
                Label("Activity", systemImage: "list.bullet.rectangle.portrait")
            }
            .accessibilityIdentifier("settingsActivity")
            NotificationsRow()
        }
        .tsukumoRows()

        Section {
            LabeledContent("Version", value: Bundle.main.versionLine)
        } footer: {
            Text("Activity, KemoSabe’s journal, and your keys stay on this iPhone.")
        }
        .tsukumoRows()
    }
}

extension SettingsScreen {
    /// A new bot, on the first engine here that runs (an API key, else Apple on-device).
    var newBot: BotSpec {
        let engine = model.engineChoices.first { $0.unavailable == nil && $0.engine != .appleOnDevice }?.engine ?? .appleOnDevice
        return BotSpec(name: "", engine: engine, service: model.service(of: engine))
    }
}

struct BotRow: View {
    let bot: BotSpec
    @Environment(\.engineInfo) private var engineInfo
    var body: some View {
        HStack(spacing: 12) {
            BotAvatar(bot: bot, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(bot.name).font(.body.weight(.medium))
                Text(bot.isKemoSabe ? "On this iPhone" : "Runs on " + engineInfo(bot.engine).title)
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

// MARK: Models

/// Models: one page with LLM, System One, and Voice tabs (the Mac's Settings has the same).
struct ModelsPage: View {
    /// Models' tabs, from the catalog the Mac shares.
    typealias Page = SettingsCatalog.ModelsTab
    @Environment(AppModel.self) private var model
    @State private var page: Page = .llm
    @State private var adding: ConnectionRecord.Provider?
    init(page: Page = .llm) { _page = State(initialValue: page) }
    @State private var editing: ConnectionRecord?

    var body: some View {
        List {
            Group {
            Section {
                TsukumoSegmented(Page.allCases.map { ($0, $0.title) }, selection: $page)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            switch page {
            case .llm: llm
            case .systemOne: systemOne
            case .voice:
                if let voice = model.voice { VoiceSections(voice: voice) }
            }
            }
            .tsukumoRows()
        }
        .tsukumoScreen()
        .navigationTitle("Models")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $adding) { provider in ConnectionEditor(provider: provider, existing: nil).tsukumoSheet() }
        .sheet(item: $editing) { record in ConnectionEditor(provider: record.provider, existing: record).tsukumoSheet() }
    }

    @ViewBuilder private var llm: some View {
        Section {
            let status = AppleOnDevice.status
            LabeledContent {
                Text(status.text).foregroundStyle(status.ready ? Color.secondary : Color.orange)
            } label: {
                Label("Apple on-device", systemImage: "apple.intelligence")
            }
            .accessibilityIdentifier("appleOnDeviceStatus")
        } header: {
            Text("On this iPhone")
        } footer: {
            Text("KemoSabe runs here. Nothing it reads leaves this iPhone.")
        }
        Section {
            ForEach(model.connections) { record in
                Button { editing = record } label: {
                    HStack(spacing: 12) {
                        EngineMarkView(record.provider.mark, size: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.name)
                            Text(model.hasKey(record.id) || record.provider == .compatible ? "\(record.connection.model) · key on this iPhone" : "No key yet")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .onDelete { offsets in for index in offsets { model.remove(connection: model.connections[index].id) } }
            Menu {
                ForEach([ConnectionRecord.Provider.anthropic, .openAI]) { provider in
                    Button(provider.title) { adding = provider }
                }
            } label: { Label("Connect an API model", systemImage: "plus") }
            .accessibilityIdentifier("connectAPI")
        } header: {
            Text("API models")
        } footer: {
            Text("A Claude or OpenAI key brings that service’s bot beside KemoSabe. Keys stay in this iPhone’s Keychain. They’re never synced or backed up.")
        }
    }

    /// System One's tab is its own file (`SystemOneSettings.swift`).
    @ViewBuilder private var systemOne: some View {
        if let center = model.systemOne { SystemOneSections(center: center) }
    }
}

/// Connect or edit an API model provider. The key goes to the Keychain, this iPhone only.
struct ConnectionEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let provider: ConnectionRecord.Provider
    let existing: ConnectionRecord?
    @State private var name = ""
    @State private var endpoint = ""
    @State private var defaultModel = ""
    @State private var models: [String] = []
    @State private var key = ""
    @State private var checking = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Group {
                Section {
                    TextField("Name", text: $name).accessibilityIdentifier("connectionName")
                    if provider == .compatible {
                        TextField("https://…/v1/chat/completions", text: $endpoint)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                } footer: { Text(provider.detail) }
                Section {
                    SecureField(existing.map { model.hasKey($0.id) } == true ? "Replace the saved key" : "API key", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("connectionKey")
                } header: { Text("Key") } footer: {
                    Text("Saved in this iPhone’s Keychain only.")
                }
                Section("Default model") {
                    if models.isEmpty {
                        TextField("Model ID", text: $defaultModel).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .font(.callout.monospaced())
                    } else {
                        Picker("Model", selection: $defaultModel) { ForEach(models, id: \.self) { Text($0).tag($0) } }
                            .pickerStyle(.navigationLink)
                    }
                }
                if let problem { Section { Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(.orange) } }
                }
                .tsukumoRows()
            }
            .tsukumoScreen(sheet: true)
            .navigationTitle(existing == nil ? "Connect \(provider.title)" : name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(checking ? "Checking…" : "Save") { Task { await save() } }
                        .disabled(checking || name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("saveConnection")
                }
            }
            .onAppear {
                name = existing?.name ?? provider.title
                endpoint = existing?.connection.endpoint.absoluteString ?? provider.endpoint
                defaultModel = existing?.connection.model ?? provider.defaultModel
                models = existing?.models ?? []
            }
        }
    }

    private func save() async {
        problem = nil
        let typed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = existing.flatMap { (try? model.keys.read($0.id)) ?? nil } ?? ""
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
                    if !listed.contains(defaultModel) { defaultModel = listed[0] }
                }
            } catch {
                problem = error.localizedDescription
                return
            }
        }
        do {
            let connection = try APIConnection.validated(id: existing?.id ?? UUID(), name: name, endpoint: endpoint, model: defaultModel, wire: provider.wire)
            try model.save(connection: ConnectionRecord(connection: connection, provider: provider, models: models), key: typed.isEmpty ? nil : typed)
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}

// MARK: KemoSabe

/// The rest of KemoSabe's settings, below its character, palette, and voice: the bots it answers without asking,
/// and its journal.
struct KemoSabeMore: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            Section {
                if model.allowedBots.isEmpty {
                    Text("The first time a bot asks KemoSabe something, you choose on its card in the chat.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.allowedBots) { bot in
                    HStack {
                        BotAvatar(bot: bot, size: 28, showsEngine: false)
                        Text(bot.name)
                        Spacer()
                        Text("Allowed").foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button("Ask again") { model.revokeConsent(bot) }.tint(.orange)
                    }
                }
            } header: {
                Text("Allowed bots")
            } footer: {
                Text("Swipe to have KemoSabe ask you again next time.")
            }

            // The journal shows once KemoSabe has told a bot something.
            if !model.journal.isEmpty { Section("Journal") {
                ForEach(model.journal.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(entry.requesterName).font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(entry.decidedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("“\(entry.question)”").font(.footnote)
                        if !entry.purpose.isEmpty { Text("Why: " + entry.purpose).font(.caption).foregroundStyle(.secondary) }
                        Text(entry.shared.map { "Sent: “\($0)”" } ?? "Nothing was sent.").font(.caption).foregroundStyle(.secondary)
                        if let withheld = entry.withheld { Text(withheld).font(.caption).foregroundStyle(.secondary) }
                    }
                    .padding(.vertical, 2)
                }
            } }
        }
        .task { await model.refreshJournal() }
    }
}

extension Bundle {
    /// "1.0.0 (1)"
    var versionLine: String {
        let version = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }
}

// MARK: Account

/// Account: who you are (Sign in with Apple) and sync with your Mac.
struct AccountPage: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        List {
            Group {
            Section {
                AccountSummary(accounts: model.accounts, companion: model.bots.first(where: \.isKemoSabe) ?? .kemoSabe(),
                               sync: model.sync.state.account, fixtureSignIn: model.launch.uiTesting, device: "iPhone")
            }
            Section {
                SyncFacts(device: "iPhone", columns: false).padding(.vertical, 6)
            }
            }
            .tsukumoRows()
        }
        .tsukumoScreen()
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension CloudSyncState {
    /// The account page's view of it.
    var account: AccountSync {
        AccountSync(title: title, short: short, detail: detail,
                    tone: isOn ? .on : isWaiting ? .waiting : self == .noAccount ? .off : .paused, lastSynced: lastSynced)
    }
}

/// The top of Settings: your picture (any photo you pick, kept on this iPhone), your name, and how sync stands.
/// The name and sync open Account.
struct ProfileHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @State private var picked: PhotosPickerItem?

    var body: some View {
        let theme = TsukumoTheme(scheme)
        let name = model.accounts.account.map(\.name).flatMap { $0.isEmpty ? nil : $0 }
        HStack(spacing: 14) {
            PhotosPicker(selection: $picked, matching: .images) {
                ProfilePicture(photo: model.profilePhoto, name: name ?? "", size: 64)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "camera.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(theme.onAccent)
                            .frame(width: 22, height: 22).background(theme.accent, in: Circle())
                            .overlay(Circle().stroke(theme.surface, lineWidth: 2))
                    }
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Change your picture")
            .accessibilityIdentifier("profilePicture")
            .contextMenu {
                if model.profilePhoto != nil {
                    Button("Remove Picture", systemImage: "trash", role: .destructive) { model.setProfilePhoto(nil) }
                }
            }
            if model.canSignIn {
                NavigationLink(value: SettingsDestination.account) { nameAndSync(name, theme: theme) }
                    .accessibilityIdentifier("settingsAccount")
            } else {
                // A build that can't sign in: nothing to open, just where things are kept.
                nameAndSync(name, theme: theme)
                Spacer(minLength: 0)
            }
        }
        .task { model.loadProfilePhoto() }
        .onChange(of: picked) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) { model.setProfilePhoto(data) }
                picked = nil
            }
        }
    }
}

extension ProfileHeader {
    func nameAndSync(_ name: String?, theme: TsukumoTheme) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name ?? "You").font(.title3.weight(.semibold)).foregroundStyle(theme.ink)
            Text(!model.canSignIn ? "Your bots and chats stay on this iPhone" : model.accounts.isSignedIn ? model.sync.state.title : "Sign in to keep your bots in iCloud")
                .font(.footnote).foregroundStyle(theme.secondary).lineLimit(2)
        }
    }
}

/// Your picture, or your initials on KemoSabe's coral.
struct ProfilePicture: View {
    let photo: UIImage?
    let name: String
    let size: CGFloat
    var body: some View {
        Group {
            if let photo { Image(uiImage: photo).resizable().scaledToFill() }
            else { InitialsAvatar(name: name, size: size) }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

/// Notifications in Settings: on or off here, with iOS's own permission behind it.
struct NotificationsRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        let notifications = model.notifications
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { notifications.status == .on && notifications.enabled }, set: { on in
                notifications.enabled = on
                guard on else { return }
                switch notifications.status {
                case .notAsked, .unknown: Task { await notifications.ask() }
                case .off: if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                case .on: break
                }
            })) {
                Label("Notifications", systemImage: "bell.badge")
            }
            .accessibilityIdentifier("settingsNotifications")
            Text(notifications.status == .off ? "Off in iOS Settings. Turn this on to go there."
                 : "When a bot replies or needs your OK while you’re away from Tsukumo.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .task { await notifications.refresh() }
    }
}

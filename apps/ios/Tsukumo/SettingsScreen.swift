import SwiftUI
import TsukumoCore
import TsukumoUI
import TsukumoEngines
import TsukumoGate
import TsukumoSync
import TsukumoVoice

/// Settings: Account (who you are and sync), Bots (KemoSabe, with the bots it answers and its journal, and the
/// owner's bots, with New Bot), Models (API connections, Apple on-device, System One, and Voice), and Connections
/// (what KemoSabe may read, and how private each one is).
struct SettingsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var editing: BotSpec?
    @State private var making: BotSpec?
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !search.trimmingCharacters(in: .whitespaces).isEmpty { results } else { pages }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("closeSettings") } }
            .sheet(item: $editing) { bot in
                BotSettingsSheet(bot: bot, engines: model.engineChoices, device: "iPhone",
                                 kemoSabeNote: "What KemoSabe may read is in Settings, Connections.",
                                 kemoSabeMore: AnyView(KemoSabeMore().environment(model))) { saved in
                    if let problem = model.save(bot: saved) { return problem.message }
                    editing = nil
                    return nil
                } onRemove: { model.problem = model.remove(bot: bot.id)?.message; editing = nil } onCancel: { editing = nil }
            }
            .sheet(item: $making) { bot in
                BotSettingsSheet(bot: bot, engines: model.engineChoices, device: "iPhone", isNew: true) { made in
                    switch model.add(bot: made) {
                    case .success: making = nil; return nil
                    case .failure(let problem): return problem.message
                    }
                } onCancel: { making = nil }
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
                    // Bots itself, or a service that connects on the Mac: back to the list, where it is.
                    Button { search = "" } label: { result(topic, note: topic.service == nil ? nil : "Connect it on your Mac.") }.buttonStyle(.plain)
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
            NavigationLink { AccountPage() } label: {
                HStack(spacing: 12) {
                    Image(systemName: model.accounts.isSignedIn ? "person.crop.circle.fill" : "person.crop.circle")
                        .font(.system(size: 30)).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.accounts.account.map { $0.name.isEmpty ? "Account" : $0.name } ?? "Account").font(.body.weight(.medium))
                        Text(model.sync.state.title).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .accessibilityIdentifier("settingsAccount")
        }

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
            Text("KemoSabe is always here, on this iPhone. Make a bot on Apple on-device or one of your keys in Models; bots on your Mac’s coding agents and the ones you bring in there stay on your Mac." + (elsewhere > 0 ? " \(elsewhere) of your bots run only on your Mac." : ""))
        }

        Section {
            NavigationLink { ModelsPage() } label: {
                Label(SettingsCatalog.Page.models.title, systemImage: SettingsCatalog.Page.models.symbol)
            }
            .accessibilityIdentifier("settingsModels")
            NavigationLink { SourcesPage() } label: {
                Label(SettingsCatalog.Page.connections.title, systemImage: SettingsCatalog.Page.connections.symbol)
            }
            .accessibilityIdentifier("settingsSources")
        }

        Section {
            LabeledContent("Version", value: Bundle.main.versionLine)
        } footer: {
            Text("Activity, KemoSabe’s journal, and your keys stay on this iPhone. Your bots and chats sync with your Mac when you’re signed in.")
        }
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
            Section {
                Picker("Page", selection: $page) { ForEach(Page.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented)
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
        .navigationTitle("Models")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $adding) { provider in ConnectionEditor(provider: provider, existing: nil) }
        .sheet(item: $editing) { record in ConnectionEditor(provider: record.provider, existing: record) }
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
            Text("A Claude or OpenAI key brings that service’s bot beside KemoSabe. Keys stay in this iPhone’s Keychain. They’re never synced or backed up. A connection made on your Mac shows here without its key.")
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
            Section {
                AccountSummary(accounts: model.accounts, companion: model.bots.first(where: \.isKemoSabe) ?? .kemoSabe(),
                               sync: model.sync.state.account, fixtureSignIn: model.launch.uiTesting, device: "iPhone")
            }
            Section {
                SyncFacts(device: "iPhone", columns: false).padding(.vertical, 6)
            }
        }
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

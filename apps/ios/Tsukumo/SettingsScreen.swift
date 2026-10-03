import SwiftUI
import TsukumoCore
import TsukumoUI
import TsukumoEngines
import TsukumoGate
import TsukumoSync

/// Settings: Account (who you are and sync), your bots, Models (API connections, Apple on-device, the
/// default model, System One), and KemoSabe (personal sources and their levels, grants you've given,
/// and the journal).
struct SettingsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var editing: BotSpec?
    @State private var creating = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
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
                            .accessibilityIdentifier("bot-" + bot.name)
                            .deleteDisabled(bot.isKemoSabe)
                    }
                    .onDelete { offsets in
                        for index in offsets { model.remove(bot: model.bots[index].id) }
                    }
                    Button { creating = true } label: { Label("Make a bot", systemImage: "plus") }
                        .accessibilityIdentifier("settingsAddBot")
                } header: {
                    Text("Your bots")
                } footer: {
                    Text("KemoSabe is always here. It runs on this iPhone and answers the other bots’ questions about you.")
                }

                Section {
                    NavigationLink { ModelsPage() } label: {
                        Label("Models", systemImage: "cpu")
                    }
                    .accessibilityIdentifier("settingsModels")
                    NavigationLink { KemoSabePage() } label: {
                        Label("KemoSabe", systemImage: "lock.shield")
                    }
                    .accessibilityIdentifier("settingsKemoSabe")
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.versionLine)
                } footer: {
                    Text("Activity, KemoSabe’s journal, and your keys stay on this iPhone. Your bots and chats sync with your Mac when you’re signed in.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("closeSettings") } }
            .sheet(item: $editing) { bot in
                BotEditor(existing: model.bots, engines: model.engineChoices, editing: bot, device: "iPhone",
                          kemoSabeNote: "What KemoSabe may read, and the bots it answers, are in Settings, KemoSabe.") { saved in
                    model.save(bot: saved); editing = nil
                } onCancel: { editing = nil }
            }
            .sheet(isPresented: $creating) {
                BotEditor(existing: model.bots, engines: model.engineChoices, seed: model.launch.uiTesting ? 7 : nil) { bot in
                    model.save(bot: bot); creating = false
                } onCancel: { creating = false }
            }
        }
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
                Text(bot.isKemoSabe ? "On this iPhone" : [engineInfo(bot.engine).title, bot.role].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

// MARK: Models

/// Models: one page with LLM and System One tabs.
struct ModelsPage: View {
    enum Page: String, CaseIterable, Identifiable {
        case llm, systemOne
        var id: String { rawValue }
        var title: String { self == .llm ? "LLM" : "System One" }
    }
    @Environment(AppModel.self) private var model
    @State private var page: Page = .llm
    @State private var adding: ConnectionRecord.Provider?
    @State private var editing: ConnectionRecord?

    var body: some View {
        List {
            Section {
                Picker("Page", selection: $page) { ForEach(Page.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            if page == .llm { llm } else { systemOne }
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
            Text("KemoSabe runs here, and so can any bot you make with Apple on-device. Nothing it reads leaves this iPhone.")
        }
        Section {
            Picker("New bots start on", selection: Binding(get: { model.defaultModel?.engine ?? .appleOnDevice }, set: { engine in
                let record = model.connections.first { $0.engine == engine }
                model.setDefault(DefaultModel(engine: engine, model: record?.connection.model))
            })) {
                Text("Apple on-device").tag(EngineID.appleOnDevice)
                ForEach(model.connections) { record in Text(record.name).tag(record.engine) }
            }
            .accessibilityIdentifier("defaultModel")
        } header: {
            Text("Default")
        } footer: {
            Text("The model a new bot starts on. It follows you to your Mac; keys don’t.")
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
                ForEach(ConnectionRecord.Provider.allCases) { provider in
                    Button(provider.title) { adding = provider }
                }
            } label: { Label("Connect an API model", systemImage: "plus") }
            .accessibilityIdentifier("connectAPI")
        } header: {
            Text("API models")
        } footer: {
            Text("Keys stay in this iPhone’s Keychain. They’re never synced or backed up. A connection made on your Mac shows here without its key.")
        }
    }

    @ViewBuilder private var systemOne: some View {
        Section {
            LabeledContent("Routing", value: "The bot you last talked to")
            LabeledContent("Laya", value: "Not on this iPhone")
        } header: {
            Text("Untagged messages")
        } footer: {
            Text("When you don’t tag a bot, System One picks one only when it’s sure; otherwise your message goes to the bot you last talked to. What it decides shows in Activity.")
        }
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

/// KemoSabe: the sources it may read and how private they are, the bots it answers, and the journal.
struct KemoSabePage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                ForEach(SourceKind.allCases) { source in
                    let setting = model.setting(source)
                    Toggle(isOn: Binding(get: { setting.on }, set: { on in Task { await model.set(source, on: on) } })) {
                        Label(source.title, systemImage: source.symbol)
                    }
                    .accessibilityIdentifier("source-" + source.rawValue)
                    if setting.on {
                        Picker("How private", selection: Binding(get: { setting.level }, set: { level in Task { await model.set(source, level: level) } })) {
                            ForEach(PrivacyLevel.allCases) { Text($0.title).tag($0) }
                        }
                        .padding(.leading, 34)
                    }
                }
            } header: {
                Text("Personal sources")
            } footer: {
                Text("KemoSabe reads a source only on this iPhone, and shares only the answer. Sensitive items ask you on a card each time. Device only never leaves this iPhone. Secret is never read.")
            }

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
                Text("Bots KemoSabe answers")
            } footer: {
                Text("Swipe to have KemoSabe ask you again next time.")
            }

            Section("Journal") {
                if model.journal.isEmpty {
                    Text("What KemoSabe tells your bots shows here: who asked, why, and exactly what was sent.")
                        .foregroundStyle(.secondary)
                }
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
            }
        }
        .navigationTitle("KemoSabe")
        .navigationBarTitleDisplayMode(.inline)
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
                AccountSummary(accounts: model.accounts, syncTitle: model.sync.state.title, syncDetail: model.sync.state.detail,
                               syncOn: model.sync.state.isOn, fixtureSignIn: model.launch.uiTesting, device: "iPhone")
            } footer: {
                Text("Signing out keeps your bots and chats on this iPhone and stops syncing them. Your Apple ID is kept in this iPhone’s Keychain only.")
            }
            Section("What syncs") {
                Label("Your bots, how they look, and your chats", systemImage: "icloud")
                Label("The default model, and connections without their keys", systemImage: "icloud")
                Label("Never: API keys, KemoSabe’s answers, its journal and permissions, and chats you keep on this iPhone", systemImage: "lock")
            }
            .font(.subheadline)
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)

    }
}

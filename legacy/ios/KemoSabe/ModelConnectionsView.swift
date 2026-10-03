import SwiftUI

/// Settings → Models on iPhone and Mac, one page with three tabs (`ModelsTab`, AGENTS.md rule 10):
/// LLM (the models chats use), System One (fast decisions), and Training (everything you train
/// yourself). Voice isn't here: it always uses the best models the device can run (`VoiceAuto`), and
/// which voice the companion sounds like is on the Companion page.
struct ModelConnectionsView: View {
    @State private var tab: ModelsTab
    /// Opens Personalization from Training (the Mac's Settings page); iPhone pushes it instead.
    private let openPersonalization: (() -> Void)?
    init(tab: ModelsTab = .llm, openPersonalization: (() -> Void)? = nil) {
        _tab = State(initialValue: tab); self.openPersonalization = openPersonalization
    }
    var body: some View {
        VStack(spacing: 0) {
            Picker("Model", selection: $tab) {
                ForEach(ModelsTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .accessibilityIdentifier("modelsTabs")
            switch tab {
            case .llm: LLMModelsView()
            case .systemOne: SystemOneView()
            case .training: TrainingView(openPersonalization: openPersonalization)
            }
        }
        .modifier(ModelsBackground())
    }
}

/// The Models page's surfaces follow the app theme on both devices, never a system-gray Form (UI
/// guide principle 4): grouped rows on a soft tint over the theme's background.
private struct ModelsBackground: ViewModifier {
    #if os(iOS)
    @Environment(\.mobilePalette) private var palette
    func body(content: Content) -> some View { content.background(palette.background.ignoresSafeArea()) }
    #else
    func body(content: Content) -> some View { content }
    #endif
}
extension View {
    /// A Form on Models (and the voice pages): grouped, with the system background hidden.
    func modelsForm() -> some View { formStyle(.grouped).scrollContentBackground(.hidden) }
    /// A section's rows on the theme's soft tint.
    func modelsRow() -> some View { listRowBackground(Color.primary.opacity(0.05)) }
}

// MARK: LLM

/// Models → LLM: one list. The current default at the top; then Apple on-device, Private Cloud, each
/// model connection, and Agents on your Mac, each a row with its status; tapping a model makes it the
/// default for new chats (after its one line on where messages go, for anything that leaves the
/// device). Each connection's details (address, model, key, streaming, images, what it can read,
/// Remove) are on its own page; Add a connection opens the add sheet.
struct LLMModelsView: View {
    @Environment(AppStore.self) private var store
    @State private var adding = false
    @State private var confirming: APIModelProfile?
    @State private var detail: ConnectionRef?
    @State private var agents = false
    @State private var failure: String?
    /// Private Cloud is being chosen; its one destination line is shown first.
    @State private var choosingPrivateCloud = false
    /// Connections whose key is in this device's Keychain (a synced connection may not have one yet).
    @State private var keyed: Set<UUID> = []

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Default for new chats").font(KemoType.font(.caption, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    Text(store.modelLabel).font(KemoType.font(.title3, weight: .semibold)).accessibilityIdentifier("defaultModel")
                    Text(store.availability).font(KemoType.font(.footnote)).foregroundStyle(.secondary)
                    if let failure { Text(failure).foregroundStyle(.orange).font(KemoType.font(.caption)).accessibilityIdentifier("modelFailure") }
                }.padding(.vertical, 4)
                if store.runsOnlyOnDevice {
                    Label("Private: nothing leaves this device. The lock on the model button shows this.", systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("privacyLock")
                }
            }.modelsRow()
            Section {
                onDeviceRow
                privateCloudRow
                ForEach(store.state.apiProfiles ?? []) { profile in connectionRow(profile) }
                agentsRow
                Button { adding = true } label: {
                    Label("Add a connection", systemImage: "plus.circle").contentShape(Rectangle())
                }
                .disabled((store.state.apiProfiles?.count ?? 0) >= 12).accessibilityIdentifier("addModelConnection")
            } header: { Text("Models") } footer: {
                Text("Tap a model to make it the default for new chats. Any chat can still switch from the model button. Claude, OpenAI, Ollama, LM Studio, or any OpenAI-compatible API connect with Add a connection.")
            }.modelsRow()
        }
        .modelsForm()
        .sheet(isPresented: $adding, onDismiss: refreshKeys) { APIProfileEditor() }
        #if os(iOS)
        .navigationDestination(item: $detail) { ref in ModelConnectionDetail(profileID: ref.id, onChange: refreshKeys) }
        .navigationDestination(isPresented: $agents) { MacAgentsPage() }
        #else
        .sheet(item: $detail, onDismiss: refreshKeys) { ref in
            NavigationStack { ModelConnectionDetail(profileID: ref.id, onChange: refreshKeys) }.frame(width: 560, height: 620)
        }
        .sheet(isPresented: $agents) { NavigationStack { MacAgentsPage() }.frame(width: 620, height: 680) }
        #endif
        .task { store.refreshPrivateCloud(); refreshKeys() }
        .onChange(of: store.state.apiProfiles) { refreshKeys() }
        .confirmationDialog("Use \(AppleModel.privateCloud.title)?", isPresented: $choosingPrivateCloud, titleVisibility: .visible) {
            Button("Use " + AppleModel.privateCloud.title) { store.selectAppleModel(.privateCloud); choosingPrivateCloud = false }
                .accessibilityIdentifier("confirmPrivateCloud")
        } message: { Text(PrivateCloudText.destination) }
        .confirmationDialog("Use this model connection?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible) {
            if let profile = confirming {
                Button("Use " + profile.name) {
                    do { try store.selectAPIProfile(profile); failure = nil } catch { failure = error.localizedDescription }
                    confirming = nil
                }.accessibilityIdentifier("confirmConnection")
            }
        } message: {
            if let profile = confirming { Text(profile.useDisclosure) }
        }
    }
    private func refreshKeys() {
        keyed = Set((store.state.apiProfiles ?? []).filter { store.hasAPIKey($0) }.map(\.id))
    }

    private var onDeviceChosen: Bool { store.modelRoute == .onDevice && store.appleModel == .onDevice }
    private var onDeviceRow: some View {
        Button { store.selectAppleModel(.onDevice); failure = nil } label: {
            modelRow(symbol: "apple.intelligence", title: AppleModel.onDevice.title,
                     status: store.onDeviceAvailable ? "On this device · Private" : store.onDeviceAvailability, chosen: onDeviceChosen)
        }.buttonStyle(.plain).accessibilityIdentifier("model-onDevice")
            .accessibilityAddTraits(onDeviceChosen ? .isSelected : [])
    }
    /// Apple's server model: the same harness as on-device, with its destination named and its quota shown.
    @ViewBuilder private var privateCloudRow: some View {
        let status = store.privateCloudStatus
        let chosen = store.modelRoute == .onDevice && store.appleModel == .privateCloud
        Button { if !chosen { choosingPrivateCloud = true } } label: {
            modelRow(symbol: "cloud", title: AppleModel.privateCloud.title,
                     status: status.unavailableReason ?? (chosen ? PrivateCloudText.destination : "Apple’s larger model · Private Cloud Compute"), chosen: chosen)
                .opacity(status.isAvailable ? 1 : 0.5)
        }.buttonStyle(.plain).disabled(!status.isAvailable).accessibilityIdentifier("model-privateCloud")
            .accessibilityAddTraits(chosen ? .isSelected : [])
        if chosen {
            Text(PrivateCloudText.destination).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("privateCloudDestination")
        }
        if status.isAvailable, let quota = status.quotaLine() {
            Text(quota).font(.caption).foregroundStyle(.orange).accessibilityIdentifier("privateCloudQuota")
        }
    }
    private func connectionRow(_ profile: APIModelProfile) -> some View {
        let chosen = store.modelRoute == .api && store.activeAPIProfile == profile
        let hasKey = keyed.contains(profile.id) || profile.isLoopback
        return HStack(spacing: 8) {
            Button {
                if hasKey { if !chosen { confirming = profile } } else { detail = ConnectionRef(id: profile.id) }
            } label: {
                modelRow(symbol: profile.isLoopback ? "desktopcomputer" : "network", title: profile.name,
                         status: hasKey ? profile.model + " · " + (profile.endpoint.host ?? "") : "Add your key on this \(AppleAccountSession.device)",
                         statusColor: hasKey ? nil : .orange, chosen: chosen)
            }.buttonStyle(.plain).accessibilityIdentifier("model-api-" + profile.id.uuidString)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            Button { detail = ConnectionRef(id: profile.id) } label: {
                Image(systemName: "info.circle").font(.body).foregroundStyle(.secondary).frame(width: 30, height: 30).contentShape(Rectangle())
            }.buttonStyle(.borderless).accessibilityLabel("\(profile.name) details").accessibilityIdentifier("modelDetails-" + profile.id.uuidString)
        }
    }
    private var agentsRow: some View {
        Button { agents = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer.and.iphone").frame(width: 28).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(SettingsCatalog.macAgents.iPhone).font(.headline)
                    Text(MacAgentsSummary.line).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("macAgentsStatus")
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }.padding(.vertical, 6).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("openMacAgents")
    }
    private func modelRow(symbol: String, title: String, status: String, statusColor: Color? = nil, chosen: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 28).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(status).font(.caption).foregroundStyle(statusColor.map { AnyShapeStyle($0) } ?? AnyShapeStyle(HierarchicalShapeStyle.secondary)).lineLimit(2)
            }
            Spacer()
            if chosen {
                Text("Default").font(KemoType.font(.caption2, weight: .semibold)).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.tint.opacity(0.16), in: Capsule()).foregroundStyle(.tint)
            }
        }.padding(.vertical, 6).contentShape(Rectangle())
    }
}

/// A connection to show, by ID, so its page follows the saved connection.
struct ConnectionRef: Identifiable, Hashable { let id: UUID }

/// Agents on your Mac as its own page, from the LLM list: each device's own sections
/// (`MacAgentsSettingsSection`: pairing and each agent on iPhone; the relay switch, pairing code,
/// paired iPhones, and each agent's sign-in on the Mac).
struct MacAgentsPage: View {
    #if os(macOS)
    @Environment(\.dismiss) private var dismiss
    #endif
    var body: some View {
        Form { MacAgentsSettingsSection() }
            .modelsForm()
            .modifier(ModelsBackground())
            .navigationTitle(SettingsCatalog.macAgents.iPhone)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #else
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("closeMacAgents") } }
            #endif
    }
}

/// One model connection's page: make it the default, its address, model, and format, its key on this
/// device (a connection that arrived from your other device needs its key added here), streaming and
/// images, what it may read (Calendar, Reminders, Contacts, each confirmed with where results go), and
/// Remove.
struct ModelConnectionDetail: View {
    let profileID: UUID
    var onChange: () -> Void = {}
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var hasKey = false
    @State private var failure: String?
    @State private var confirming = false
    @State private var removing = false
    /// A connection being allowed to read, confirmed with where its results go.
    @State private var granting: ConnectorID?

    private var profile: APIModelProfile? { store.state.apiProfiles?.first { $0.id == profileID } }
    var body: some View {
        Group {
            if let profile { form(profile) } else { Text("This connection was removed.").foregroundStyle(.secondary) }
        }
        .modifier(ModelsBackground())
        .navigationTitle(profile?.name ?? "Connection")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #else
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("closeConnection") } }
        #endif
        .task { if let profile { hasKey = store.hasAPIKey(profile) } }
    }
    private func form(_ profile: APIModelProfile) -> some View {
        let chosen = store.modelRoute == .api && store.activeAPIProfile == profile
        let host = profile.endpoint.host ?? profile.endpoint.absoluteString
        return Form {
            Section {
                if chosen {
                    Label("Default for new chats", systemImage: "checkmark.circle.fill").foregroundStyle(.tint)
                } else {
                    Button("Make default") { confirming = true }.disabled(!hasKey && !profile.isLoopback).accessibilityIdentifier("makeDefault")
                }
                if let failure { Text(failure).font(.caption).foregroundStyle(.orange) }
            }.modelsRow()
            Section("Connection") {
                LabeledContent("Address") { Text(profile.endpoint.absoluteString).textSelection(.enabled).multilineTextAlignment(.trailing) }
                LabeledContent("Model", value: profile.model)
                LabeledContent("Format", value: profile.wire == .anthropic ? "Claude Messages" : "OpenAI-compatible")
                Toggle("Stream replies as they arrive", isOn: Binding(get: { profile.streaming }, set: { value in
                    var next = profile; next.streaming = value; store.updateAPIProfile(next)
                }))
                    .accessibilityIdentifier("connectionStreaming")
                Toggle("This model accepts images", isOn: Binding(get: { profile.supportsImages == true }, set: { value in
                    var next = profile; next.supportsImages = value; store.updateAPIProfile(next)
                }))
                    .accessibilityIdentifier("connectionImages")
            }.modelsRow()
            Section {
                if hasKey {
                    LabeledContent("API key") { Text("In this \(AppleAccountSession.device)'s Keychain").foregroundStyle(.secondary) }
                }
                HStack {
                    SecureField(hasKey ? "Replace the key" : "Paste your API key", text: $key).autocorrectionDisabled().accessibilityIdentifier("connectionKey")
                    Button("Save") { saveKey(profile) }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("saveConnectionKey")
                }
            } header: { Text("Key") } footer: {
                Text(hasKey ? "Keys stay on each device and never sync. It's only sent to \(host)." : "This connection came from your other device. Keys never sync, so add it here once. It's only sent to \(host).")
            }.modelsRow()
            Section {
                ForEach([ConnectorID.calendar, .reminders, .contacts]) { id in
                    Toggle(id.title, isOn: Binding(get: { store.state.apiGrants(profile.id).contains(id) }, set: { on in
                        if on { granting = id } else { store.setConnectorGrant(id, for: profile, allowed: false) }
                    })).accessibilityIdentifier("grant-\(id.rawValue)-" + profile.id.uuidString)
                }
            } header: { Text("What \(profile.name) can read") } footer: {
                Text("When it’s on, what \(profile.name) reads is sent to \(host). Off, it asks in the chat first.")
            }.modelsRow()
            Section {
                Button("Remove connection", role: .destructive) { removing = true }.accessibilityIdentifier("removeConnection")
            } footer: { Text("Removes it from your other devices too, with its chat. Its key is removed from this device.") }
            .modelsRow()
        }
        .modelsForm()
        .confirmationDialog("Use this model connection?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Use " + profile.name) {
                do { try store.selectAPIProfile(profile); failure = nil } catch { failure = error.localizedDescription }
            }
        } message: { Text(profile.useDisclosure) }
        .confirmationDialog(granting.map { "Let \(profile.name) read your \($0.title)?" } ?? "",
                            isPresented: Binding(get: { granting != nil }, set: { if !$0 { granting = nil } }), titleVisibility: .visible) {
            if let granting {
                Button("Always for this model") { store.setConnectorGrant(granting, for: profile, allowed: true); self.granting = nil }
                    .accessibilityIdentifier("confirmGrant")
                Button("Don’t allow", role: .cancel) { self.granting = nil }
            }
        } message: {
            Text("Results are sent to \(host). It reads only when a request needs it, and only what the tool returns is sent.")
        }
        .confirmationDialog("Remove this connection and its chat?", isPresented: $removing, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                do { try store.removeAPIProfile(profile); onChange(); dismiss() } catch { failure = error.localizedDescription }
            }
        } message: { Text("The API key and this connection’s conversation will be removed from this device, and the connection from your other devices. This cannot delete copies retained by the provider.") }
    }
    private func saveKey(_ profile: APIModelProfile) {
        do { try store.setAPIKey(key.trimmingCharacters(in: .whitespacesAndNewlines), for: profile); key = ""; hasKey = true; failure = nil; onChange() }
        catch { failure = error.localizedDescription }
    }
}

extension APIModelProfile {
    /// Shown before a connection is chosen, wherever it's chosen (Models and the chat's model chip).
    var useDisclosure: String {
        "New messages, attached images when enabled, and this connection’s own chat history will be sent to \(endpoint.absoluteString) using model \(model). This includes voice transcribed to text when the mic is on. Audio and private local context stay on this device; it reads your calendar, reminders, or contacts only after you allow it. The server controls its retention and may charge for requests."
    }
}

/// Adding a model: pick a provider, paste a key, and choose from its own model list. "Other"
/// keeps the full form for any OpenAI-compatible server. Opened from Models and from the chat's
/// model chip (Add model).
struct APIProfileEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var preset: APIModelPreset = .claude
    @State private var name = "Claude"
    @State private var endpoint = APIModelPreset.claude.endpoint
    @State private var model = ""
    @State private var key = ""
    @State private var streaming = true
    @State private var supportsImages = true
    @State private var models: [String] = []
    @State private var loading = false
    @State private var failure: String?
    /// Start chatting with the new model right away; the footer names where messages go.
    @State private var useNow = true
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Provider", selection: $preset) {
                        ForEach(APIModelPreset.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }.accessibilityIdentifier("providerPreset")
                    Text(preset.detail).font(.caption).foregroundStyle(.secondary)
                } footer: {
                    if preset.needsKey {
                        Text("A Claude or ChatGPT subscription can't be used by other apps' chat, so this needs an API key, billed by \(preset.title). On Mac, Claude Code and Codex sign in with your subscription in Settings → Agents.")
                    }
                }
                Section {
                    if preset.needsKey || preset == .custom {
                        SecureField(preset.needsKey ? "Paste your \(preset.title) API key" : "API key · optional for local servers", text: $key)
                            .autocorrectionDisabled().accessibilityIdentifier("providerKey")
                            .onSubmit { Task { await loadModels() } }
                    }
                    if let page = preset.keyPage {
                        Button("Get a key from \(preset.title)") { openURL(page) }.font(.caption)
                    }
                    if preset == .custom {
                        TextField("Full chat/completions URL", text: $endpoint).autocorrectionDisabled().accessibilityIdentifier("providerEndpoint")
                        TextField("Model ID", text: $model).autocorrectionDisabled().accessibilityIdentifier("providerModel")
                    } else if models.isEmpty {
                        Button { Task { await loadModels() } } label: {
                            HStack { Text(loading ? "Loading models…" : "Show models"); if loading { Spacer(); KemoOrb(size: 18, state: .connecting) } }
                        }.disabled(loading || (preset.needsKey && key.isEmpty)).accessibilityIdentifier("loadModels")
                    } else {
                        Picker("Model", selection: $model) { ForEach(models, id: \.self) { Text($0).tag($0) } }.accessibilityIdentifier("providerModel")
                    }
                } header: { Text(preset == .custom ? "Connection" : "Key and model") } footer: {
                    Text(preset.needsKey ? "Your key is saved in Keychain on this device. It's only sent to \(URL(string: preset.endpoint)?.host ?? "the provider")." : "Keys are saved in Keychain. Saving doesn't contact the server or switch your model.")
                }
                if preset.needsKey {
                    Section {
                        Toggle("Chat with this model now", isOn: $useNow).accessibilityIdentifier("useProviderNow")
                    } footer: {
                        Text(useNow ? "Your messages will go to \(URL(string: preset.endpoint)?.host ?? preset.title). Private commands still run on this device, and you can switch back from the model button." : "Saved for later; you'll keep your current model.")
                    }
                }
                Section {
                    TextField("Name", text: $name).accessibilityIdentifier("providerName")
                    Toggle("Stream replies as they arrive", isOn: $streaming)
                    Toggle("This model accepts images", isOn: $supportsImages)
                } header: { Text("Options") } footer: {
                    Text(preset == .ollama || preset == .lmStudio ? "Localhost on iPhone means the iPhone itself; on Mac, the Mac." : "Attached images are sent to this provider and kept in this connection's history.")
                }
                if let failure { Text(failure).foregroundStyle(.orange).font(.caption) }
            }.formStyle(.grouped)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .navigationTitle("Add model")
                // Paste a key and the provider is recognized, then its models load.
                .onChange(of: key) {
                    if let detected = APIModelPreset.detect(key: key), detected != preset { preset = detected }
                }
                .task(id: key) {
                    guard preset.needsKey, key.trimmingCharacters(in: .whitespacesAndNewlines).count >= 20, models.isEmpty else { return }
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled else { return }
                    await loadModels()
                }
                .onChange(of: preset) {
                    name = preset == .custom ? "" : preset.title; endpoint = preset.endpoint; model = ""; models = []
                    supportsImages = preset.acceptsImages; failure = nil
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            do {
                                let profile = try APIModelProfile.validated(name: name, endpoint: endpoint, model: model, streaming: streaming,
                                                                            supportsImages: supportsImages, format: preset.format)
                                try store.addAPIProfile(profile, key: key); key = ""
                                if useNow && preset.needsKey { try store.selectAPIProfile(profile) }
                                dismiss()
                            } catch { failure = error.localizedDescription }
                        }.disabled(name.isEmpty || endpoint.isEmpty || model.isEmpty).accessibilityIdentifier("saveProvider")
                    }
                }
        }
        #if os(macOS)
        .frame(width: 580, height: 560)
        #endif
    }
    private func loadModels() async {
        guard preset != .custom else { return }
        loading = true; failure = nil
        defer { loading = false }
        do {
            let found = try await APIModelCatalog.models(for: preset, key: key.trimmingCharacters(in: .whitespacesAndNewlines))
            models = found
            model = preset.preferredModel.flatMap { found.contains($0) ? $0 : nil } ?? found.first ?? ""
            if found.isEmpty { failure = "No chat models were offered for this key." }
        } catch { failure = error.localizedDescription }
    }
}

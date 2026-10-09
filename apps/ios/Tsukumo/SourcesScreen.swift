import SwiftUI
import UniformTypeIdentifiers
import TsukumoCore
import TsukumoGate
import TsukumoPolicy
import TsukumoUI

// Settings, Connections (what KemoSabe may read): TsukumoGate's `SourceLibrary` as a searchable list grouped by
// kind, the same catalog as the Mac's (AGENTS.md rule 9). Each row shows its icon, what it reads or what
// stands in the way, its state, and when it's on, how private it is. Turning one on asks iOS first. Files and
// folders and connected accounts are as many as the owner likes.

struct SourcesPage: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var picking = false
    @State private var adding: ConnectorDraft?
    @Environment(\.scenePhase) private var phase

    struct ConnectorDraft: Identifiable { let name: String; var id: String { name } }

    var body: some View {
        let library = model.sources
        let groups = library.groups(matching: search)
        List {
            if groups.isEmpty {
                Text("Nothing matches “\(search)”. Any service with an MCP server can be added as a connected account.")
                    .foregroundStyle(.secondary)
            }
            ForEach(groups, id: \.group) { item in
                Section {
                    ForEach(item.entries) { entry in
                        SourceListRow(library: library, entry: entry) { adding = ConnectorDraft(name: entry.kind == .mail ? "Mail" : "") }
                            .swipeActions { if entry.removable { Button("Remove", role: .destructive) { library.remove(entry.id) } } }
                        if entry.kind == .messages, entry.isOn { MessagesSetup(store: model.sharedMessages) }
                    }
                    if item.group == .filesAndMedia {
                        Button { picking = true } label: { Label("Add files or folders", systemImage: "plus") }
                            .accessibilityIdentifier("addFiles")
                    }
                    if item.group == .connected {
                        Button { adding = ConnectorDraft(name: "") } label: { Label("Add a connector", systemImage: "plus") }
                            .accessibilityIdentifier("addConnector")
                    }
                } header: {
                    Label(item.group.title, systemImage: item.group.symbol)
                } footer: {
                    if item.group == .connected { Text("Any service with an MCP server. KemoSabe sends it only a bot’s question and reads its answer on this iPhone.") }
                }
            }
            Section {
                if let problem = library.problem { Text(problem).foregroundStyle(.orange) }
            } footer: {
                Text("KemoSabe reads only on this iPhone, when a bot asks, and shares only the answer. Sensitive asks you on a card each time. Device only never leaves this iPhone. Secret is never read.")
            }
        }
        .searchable(text: $search, prompt: "Search sources")
        .navigationTitle("Connections")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder, .item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { library.addFiles(urls) }
        }
        .sheet(item: $adding) { draft in ConnectorSheet(library: library, name: draft.name) }
        .onAppear { library.refresh() }
        .onChange(of: phase) { _, phase in if phase == .active { library.refresh() } }
    }
}

/// One source: icon, title, what it reads or what stands in the way, its switch, and its level when on.
struct SourceListRow: View {
    let library: SourceLibrary
    let entry: SourceEntry
    let connect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: entry.symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(entry.isOn ? Color.accentColor : .secondary)
                    .frame(width: 32, height: 32)
                    .background((entry.isOn ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.06)), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).font(.body.weight(.medium))
                    Text(entry.detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                trailing
            }
            if case .on = entry.state {
                Picker("How private", selection: Binding(get: { entry.level }, set: { library.set(entry.id, level: $0) })) {
                    ForEach(entry.levels) { Text($0.title).tag($0) }
                }
                .padding(.leading, 44)
                .accessibilityIdentifier("sourceLevel-" + entry.id)
            }
            if case .needsPermission = entry.state, entry.opensSettings, let url = library.settingsURL(entry.id) {
                Button("Open Settings") { UIApplication.shared.open(url) }.padding(.leading, 44)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sourceRow-" + entry.id)
    }

    @ViewBuilder private var trailing: some View {
        switch entry.state {
        case .notOnDevice:
            Text(entry.stateTitle).font(.caption).foregroundStyle(.secondary)
        case .viaConnector:
            Button("Connect", action: connect).buttonStyle(.bordered).controlSize(.small).accessibilityIdentifier("connect-" + entry.id)
        default:
            Toggle(entry.title, isOn: Binding(get: { entry.isOn }, set: { on in Task { await library.set(entry.id, on: on) } }))
                .labelsHidden()
                .accessibilityIdentifier("source-" + entry.id)
        }
    }
}

/// Messages on iPhone: how to set up the automation, and what it gave KemoSabe.
struct MessagesSetup: View {
    @Environment(AppModel.self) private var model
    let store: SharedMessagesStore
    @State private var count = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Set up the automation").font(.subheadline.weight(.semibold))
            ForEach(Array(SharedMessagesStore.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1)").font(.caption.weight(.semibold)).foregroundStyle(.tint)
                    Text(step).font(.footnote).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Text(count == 0 ? "No messages given yet." : "\(count) message\(count == 1 ? "" : "s") kept on this iPhone, the newest \(SharedMessagesStore.maxMessages) at most.")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer()
                if count > 0 { Button("Delete All", role: .destructive) { store.deleteAll(); count = store.count }.font(.footnote) }
            }
        }
        .padding(.leading, 44)
        .onAppear { count = store.count }
    }
}

/// Add a connected account: an MCP server's address, a name, an optional token, and how private it is.
struct ConnectorSheet: View {
    let library: SourceLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var address = ""
    @State private var token = ""
    @State private var level: PrivacyLevel = SourceKind.connector.defaultLevel
    @State private var connecting = false
    @State private var problem: String?

    init(library: SourceLibrary, name: String) {
        self.library = library
        _name = State(initialValue: name)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (Notion, Gmail, GitHub…)", text: $name).accessibilityIdentifier("connectorName")
                    TextField("https://…/mcp", text: $address)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("connectorAddress")
                    SecureField("Token (optional)", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: {
                    Text("The token stays in this iPhone’s Keychain. KemoSabe sends the server only a bot’s question, and reads what it answers on this iPhone.")
                }
                Section {
                    Picker("How private", selection: $level) { ForEach(SourceKind.connector.levels) { Text($0.title).tag($0) } }
                } footer: { Text(level.detail) }
                if let problem { Section { Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(.orange) } }
            }
            .navigationTitle("Add a connector")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(connecting ? "Connecting…" : "Connect") { Task { await connect() } }
                        .disabled(connecting || address.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("connectorConnect")
                }
            }
        }
    }

    private func connect() async {
        connecting = true
        defer { connecting = false }
        problem = nil
        do {
            try await library.addAccount(name: name, url: address, token: token, level: level)
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}

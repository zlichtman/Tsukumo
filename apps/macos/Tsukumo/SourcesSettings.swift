import AppKit
import SwiftUI
import TsukumoCore
import TsukumoGate
import TsukumoPolicy
import TsukumoUI
import TsukumoDock

// Settings, KemoSabe, What KemoSabe may read: TsukumoGate's `SourceLibrary` as a searchable catalog grouped
// by kind (Personal, Communication, Files and Media, Places and Health, Connected accounts), the same
// catalog as the iPhone's (AGENTS.md rule 9). Each row shows its icon, what it reads or what stands in the
// way, its state, and when it's on, how private it is. Turning one on asks macOS first. Files and folders
// and connected accounts are as many as the owner likes.

struct SourcesCard: View {
    let library: SourceLibrary
    @State private var search = ""
    @State private var addingAccount: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let groups = library.groups(matching: search)
        let on = library.entries().filter(\.isOn).count
        SettingsCard("Sources", systemImage: "doc.text.magnifyingglass") {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search sources", text: $search).textFieldStyle(.plain).accessibilityIdentifier("sourceSearch")
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                            .buttonStyle(.plain).accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 9).frame(height: 28)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
                Text(on == 0 ? "None on" : "\(on) on").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .accessibilityIdentifier("sourcesOnCount")
            }
            if groups.isEmpty {
                SettingsNote("Nothing matches “\(search)”. Any service with an MCP server can be added as a connected account.")
            }
            VStack(alignment: .leading, spacing: 16) {
                ForEach(groups, id: \.group) { item in
                    group(item.group, item.entries)
                }
            }
            if let problem = library.problem { SettingsNote(problem, warning: true) }
            SettingsNote("KemoSabe reads only on this Mac, when a bot asks, and shares only the answer. Sensitive asks you on a card each time. Device only never leaves this Mac. Secret is never read.")
        }
        .sheet(item: Binding(get: { addingAccount.map(AccountDraft.init) }, set: { addingAccount = $0?.name })) { draft in
            ConnectorSheet(library: library, name: draft.name)
        }
        .onAppear { library.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in library.refresh() }
    }

    private struct AccountDraft: Identifiable { let name: String; var id: String { name } }

    private func group(_ group: SourceGroup, _ entries: [SourceEntry]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: group.symbol).font(.system(size: 10, weight: .semibold))
                Text(group.title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.4)
                let on = entries.filter(\.isOn).count
                if on > 0 { Text("\(on) on").font(.system(size: 10.5)).foregroundStyle(.tertiary) }
            }
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Divider() }
                    SourceRow(library: library, entry: entry) { addingAccount = entry.kind == .mail ? "Mail" : "" }
                }
                if group == .filesAndMedia {
                    if !entries.isEmpty { Divider() }
                    Button { pickFiles() } label: {
                        SettingsRow("Add files or folders…", systemImage: "plus", subtitle: "As many as you like. KemoSabe reads them only when a bot asks.") {}
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("addFiles")
                }
                if group == .connected {
                    if !entries.isEmpty { Divider() }
                    Button { addingAccount = "" } label: {
                        SettingsRow("Add a connector…", systemImage: "plus", subtitle: "Any service with an MCP server: its address, a name, and how private it is.") {}
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("addConnector")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color.primary.opacity(scheme == .dark ? 0.035 : 0.025), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Let KemoSabe Read"
        panel.message = "KemoSabe reads what you pick only on this Mac, when a bot asks, and shares only the answer."
        guard panel.runModal() == .OK else { return }
        library.addFiles(panel.urls)
    }
}

/// One source: its icon, what it reads or what stands in the way, and its switch and level.
struct SourceRow: View {
    let library: SourceLibrary
    let entry: SourceEntry
    let connect: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let accent = TsukumoTheme(scheme).accent
        SettingsRow(entry.title, subtitle: entry.detail) {
            Image(systemName: entry.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(entry.isOn ? accent : Color.primary.opacity(entry.isSwitchable ? 0.8 : 0.4))
                .frame(width: 30, height: 30)
                .background((entry.isOn ? accent.opacity(0.13) : Color.primary.opacity(0.06)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
        } trailing: {
            trailing
        }
        .contextMenu {
            if entry.removable { Button("Remove \(entry.title)", role: .destructive) { library.remove(entry.id) } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sourceRow-" + entry.id)
    }

    @ViewBuilder private var trailing: some View {
        switch entry.state {
        case .notOnDevice:
            StateBadge(text: entry.stateTitle, color: .secondary)
        case .viaConnector:
            Button("Connect…", action: connect).controlSize(.small).accessibilityIdentifier("connect-" + entry.id)
        case .needsPermission:
            HStack(spacing: 8) {
                if entry.opensSettings, let url = library.settingsURL(entry.id) {
                    Button("Open System Settings") { NSWorkspace.shared.open(url) }.controlSize(.small)
                } else {
                    StateBadge(text: "Needs permission", color: .orange)
                }
                toggle
            }
        case .on, .off:
            HStack(spacing: 8) {
                if entry.isOn {
                    Picker("How private", selection: Binding(get: { entry.level }, set: { library.set(entry.id, level: $0) })) {
                        ForEach(entry.levels) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize().controlSize(.small)
                    .help(entry.level.detail)
                    .accessibilityIdentifier("sourceLevel-" + entry.id)
                } else {
                    StateBadge(text: "Off", color: .secondary)
                }
                if entry.removable {
                    Button { library.remove(entry.id) } label: { Image(systemName: "minus.circle").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("Remove").accessibilityLabel("Remove \(entry.title)")
                }
                toggle
            }
        }
    }

    private var toggle: some View {
        Toggle("", isOn: Binding(get: { entry.isOn }, set: { on in Task { await library.set(entry.id, on: on) } }))
            .labelsHidden().toggleStyle(.switch).controlSize(.small)
            .accessibilityLabel(entry.title)
            .accessibilityIdentifier("source-" + entry.id)
    }
}

/// A word or two of state in a soft capsule.
struct StateBadge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.1), in: Capsule())
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
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("Notion, Gmail, GitHub…")).accessibilityIdentifier("connectorName")
                    TextField("Address", text: $address, prompt: Text("https://…/mcp")).accessibilityIdentifier("connectorAddress")
                    SecureField("Token", text: $token, prompt: Text("Optional")).accessibilityIdentifier("connectorToken")
                } header: {
                    Text("Add a connector")
                } footer: {
                    Text("Any service with an MCP server. The token stays in this Mac’s Keychain. KemoSabe sends the server only a bot’s question, and reads what it answers on this Mac.")
                }
                Section {
                    Picker("How private", selection: $level) { ForEach(SourceKind.connector.levels) { Text($0.title).tag($0) } }
                } footer: { Text(level.detail) }
                if let problem { Section { Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(.orange) } }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(connecting ? "Connecting…" : "Connect") { Task { await connect() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(connecting || address.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("connectorConnect")
            }
            .padding(16)
        }
        .frame(width: 460, height: 430)
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

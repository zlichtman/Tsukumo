import SwiftUI

struct PanelHost: View {
    let panel: AppPanel
    @Environment(\.mobilePalette) private var palette
    @Environment(AppStore.self) private var store
    @Environment(AppNavigation.self) private var navigation
    private var supportsVoice: Bool { [.settings, .connections, .appearance, .voice, .routine].contains(panel) }
    var body: some View {
        Group {
            switch panel {
            case .settings: SettingsView()
            case .connections: ConnectorDrawer()
            case .appearance: ThemeView()
            case .voice: VoiceSettingsView()
            case .animations: NavigationStack { AnimationGallery() }
            case .workspace: WorkspaceView()
            case .history: VoiceHistoryView()
            case .routine: RoutineView()
            case .model: ModelDrawer()
            case .nearby: NearbyKemosPanel()
            }
        }
        .modifier(MobileAppStyle())
        .presentationBackground(palette.background)
        .onAppear { if !supportsVoice { navigation.voiceBlocks.insert(panel.rawValue) } }
        .onDisappear { navigation.voiceBlocks.remove(panel.rawValue) }
    }
}

struct ConnectorDrawer: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mobilePalette) private var palette
    @Environment(AppStore.self) private var store
    @Environment(ConnectorStore.self) private var connectors
    @Environment(VoiceController.self) private var voice
    @State private var search = ""
    /// Messages or Location, when its page is open.
    @State private var personal: PersonalSourceKind?
    private var matching: [ConnectorID] {
        ConnectorID.allCases.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
    }
    private var matchingPersonal: [PersonalSourceKind] {
        PersonalSourceKind.allCases.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let selected = connectors.selected { detail(selected) }
                    else if let personal { personalDetail(personal) }
                    else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Connect an app").font(KemoType.font(.title2, weight: .semibold))
                            Text("Your apps, within reach.").font(KemoType.font(.callout)).foregroundStyle(.secondary)
                        }.padding(.top, 8)
                        VStack(spacing: 0) {
                            ForEach(matching.filter { connectors.status($0, state: store.state).usable }) { id in row(id) }
                        }.background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 24))
                        Text("Connect on this device").font(KemoType.font(.headline))
                        VStack(spacing: 0) {
                            ForEach(matching.filter { $0.isNative && !connectors.status($0, state: store.state).usable }) { id in
                                row(id)
                                if id != .contacts { Divider().overlay(.white.opacity(0.03)).padding(.leading, 70) }
                            }
                        }.background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 24))
                        // Messages and Location: off until you turn each on, and they stay on this iPhone.
                        if !matchingPersonal.isEmpty {
                            Text("Messages and location").font(KemoType.font(.headline))
                            VStack(spacing: 0) {
                                ForEach(matchingPersonal) { kind in
                                    PersonalSourceRow(kind: kind) { personal = kind }
                                    if kind != matchingPersonal.last { Divider().overlay(.white.opacity(0.03)).padding(.leading, 70) }
                                }
                            }.background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 24))
                        }
                        Text("More connections").font(KemoType.font(.headline))
                        VStack(spacing: 0) { ForEach(matching.filter { !$0.isNative }) { row($0) } }
                            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 24))
                        Text("Connections only read when you ask. Nothing is added to memory automatically.")
                            .font(KemoType.font(.caption)).foregroundStyle(.secondary)
                        // Agents that may ask KemoSabe (through Tsukumo on a Mac), with Remove.
                        Text("Agents allowed to ask").font(KemoType.font(.headline))
                        AgentQuestionGrantsList(store: store).padding(18)
                            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 24))
                    }
                }.padding(22).frame(maxWidth: 600).frame(maxWidth: .infinity)
            }.background(palette.background.ignoresSafeArea())
                .searchable(text: $search, prompt: "Find an app")
                .navigationTitle("Connections").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        if connectors.selected != nil || personal != nil {
                            Button("All apps", systemImage: "chevron.left") { connectors.selected = nil; personal = nil }.accessibilityIdentifier("allConnectors")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) { Button(role: .close) { dismiss() }.accessibilityIdentifier("closeConnections") }
                }
        }.onAppear { connectors.refresh() }
    }
    private func row(_ id: ConnectorID) -> some View {
        let status = connectors.status(id, state: store.state)
        return Button { connectors.selected = id } label: {
            HStack(spacing: 14) {
                connectorIcon(id, size: 42)
                VStack(alignment: .leading, spacing: 4) {
                    Text(id.title).font(KemoType.font(.headline)).foregroundStyle(.primary)
                    Text(status == .unavailable ? "Setup not available yet" : status.usable || status.opensSystemSettings ? status.rawValue : id.summary).font(KemoType.font(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: status.usable ? "checkmark.circle.fill" : "chevron.right")
                    .foregroundStyle(status.usable ? palette.accent : Color.primary.opacity(0.35))
                    .font(.system(size: status.usable ? 18 : 12, weight: .semibold))
            }.padding(16).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("connector-" + id.rawValue)
            .accessibilityValue(status.rawValue)
    }
    @ViewBuilder private func detail(_ id: ConnectorID) -> some View {
        let status = connectors.status(id, state: store.state)
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                connectorIcon(id, size: 60)
                VStack(alignment: .leading, spacing: 4) {
                    Text(id.title).font(KemoType.font(.title2, weight: .semibold))
                    Text(status.rawValue).font(KemoType.font(.caption)).foregroundStyle(palette.accent)
                        .accessibilityIdentifier("connectionStatus")
                }
            }
            Text(id.explanation).font(KemoType.font(.callout)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if id.isNative {
                // Denied, restricted, "Add events only", and selected contacts each say what's wrong
                // and where to change it, with a button to Settings.
                if let guidance = status.guidance(for: id) {
                    Text(guidance).font(KemoType.font(.callout)).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("connectorGuidance")
                }
                if status.usable {
                    Text("Try “\(id.example)”").font(KemoType.font(.callout, weight: .semibold))
                }
                if status.opensSystemSettings {
                    // Selected contacts still work, so its button is the quieter one.
                    if status.usable { settingsButton.buttonStyle(.bordered) }
                    else { settingsButton.buttonStyle(.borderedProminent).tint(palette.accent).foregroundStyle(palette.background) }
                }
                if status.usable {
                    Button("Disconnect") { voice.onCommand?(.disconnect(id)) }.buttonStyle(.bordered).accessibilityIdentifier("disconnectConnector")
                } else if status.opensSystemSettings {
                    EmptyView()
                } else {
                    Button { voice.onCommand?(.connect(id)) } label: {
                        HStack { Spacer(); if connectors.authorizing == id { KemoOrb(size: 20, state: .connecting) }; Text(connectors.authorizing == id ? "Waiting for permission" : "Connect " + id.title); Spacer() }.padding(.vertical, 8)
                    }.buttonStyle(.borderedProminent).tint(palette.accent).foregroundStyle(palette.background)
                        .disabled(connectors.authorizing != nil).accessibilityIdentifier("connectConnector")
                    Text("Or say “connect”. Apple will ask you to approve access.").font(KemoType.font(.caption)).foregroundStyle(.secondary)
                }
                if let message = connectors.message { Text(message).font(KemoType.font(.caption)).foregroundStyle(.secondary).accessibilityIdentifier("connectorMessage") }
            }
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 24))
        if id.isNative { Text("Disconnecting stops KemoSabe’s access. Apple permissions and your existing account sync are managed in iOS Settings.").font(KemoType.font(.caption)).foregroundStyle(.secondary) }
    }
    @ViewBuilder private func personalDetail(_ kind: PersonalSourceKind) -> some View {
        HStack(spacing: 16) {
            Image(systemName: kind.symbol).font(.system(size: 26, weight: .medium)).foregroundStyle(palette.accent)
                .frame(width: 60, height: 60).background(palette.accent.opacity(0.075), in: RoundedRectangle(cornerRadius: 20))
                .accessibilityHidden(true)
            Text(kind.title).font(KemoType.font(.title2, weight: .semibold))
        }
        switch kind {
        case .messages: SharedMessagesDetail()
        case .location: LocationSourceDetail()
        }
    }
    private var settingsButton: some View {
        Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
            .accessibilityIdentifier("connectorSystemSettings")
    }
    private func connectorIcon(_ id: ConnectorID, size: CGFloat) -> some View {
        Group {
            if let asset = id.logoAsset { Image(asset).resizable().scaledToFit().padding(size * 0.24) }
            else { Image(systemName: id.symbol).font(.system(size: size * 0.43, weight: .medium)) }
        }.foregroundStyle(palette.accent).frame(width: size, height: size)
            .background(palette.accent.opacity(0.075), in: RoundedRectangle(cornerRadius: size * 0.33))
            .overlay(RoundedRectangle(cornerRadius: size * 0.33).stroke(.white.opacity(0.07)))
            .accessibilityHidden(true)
    }
}

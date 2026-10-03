import SwiftUI
import AppKit

struct DesktopRootView: View {
    @Environment(AppStore.self) private var store
    @Environment(AppNavigation.self) private var navigation
    @Environment(DesktopNavigation.self) private var desktop
    @Environment(DesktopPreferences.self) private var preferences
    @Environment(MacVoiceInput.self) private var voice
    @Environment(ConnectorStore.self) private var connectors
    @Environment(RoutineStore.self) private var routines
    @Environment(DesktopProjects.self) private var projects
    @Environment(CodingWorkspaceStore.self) private var coding
    @Environment(OnboardingFlow.self) private var onboarding
    @State private var deletingCurrent = false
    @State private var deletingArchive: UUID?
    @State private var deletingTask: CodingTaskRecord?
    @State private var removingProject: DesktopProject?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var accountBarHeight: CGFloat = 40
    private static let sidebarSpacing: CGFloat = 12
    private var palette: DesktopPalette { preferences.palette(scheme) }
    @State private var draft = ""
    @State private var images: [ChatImage] = []
    @State private var attachmentRequest = 0
    /// The person keeps the big Kemo on the chat (Kemo's picture in the account bar hides it or brings it back).
    @State private var expanded = true
    /// Where Kemo is: up on the stage while the chat has room, otherwise in the latest reply's avatar (`ChatStage`).
    @State private var stageShown = true
    /// The chat page's height, which places a new chat's Kemo exactly where a new Tsukumo task's is.
    @State private var chatHeight: CGFloat = 0
    /// A performance just asked for (or Kemo's picture clicked) plays on the stage until you scroll or send.
    @State private var stagePinned = false
    @State private var selectedArchive: ConversationArchive?
    /// A chat whose context is being shared ("Share context with…", `ContextPacket`).
    @State private var sharingChat: ContextPacketSource?
    @State private var dictationPrefix = ""
    @State private var nativeTask: Task<Void, Never>?
    /// Set when a private command itself moves to the on-device model, so the route-change
    /// handler doesn't cancel the command that was just started.
    @State private var routeSwitchedForCommand = false
    @State private var searching = false
    @State private var readAloud = MacReadAloud.shared
    var minimize: () -> Void
    /// Shows or hides the floating companion without closing the window.
    var toggleCompanion: () -> Void = {}
    @State private var namingProject = false
    @State private var projectName = ""
    @State private var openProjects: Set<UUID> = []
    @State private var openMenu: SidebarMenu?
    var preferencesChanged: () -> Void
    private let pages: [(String, String)] = [("Chat", "bubble.left.and.bubble.right"), ("Day", "sun.max"), ("Library", "books.vertical"), ("Tsukumo", "curlybraces"), ("Connections", "point.3.connected.trianglepath.dotted"), ("Models", "cpu"), ("Appearance", "slider.horizontal.3")]
    var body: some View {
        Group {
            // A new install's onboarding fills the window's content (Settings can still open over it).
            if onboarding.active && desktop.settingsPage == nil { DesktopOnboardingView().ignoresSafeArea(.container, edges: .top) }
            // No account on this Mac (just signed out, say): sign in before anything else.
            else if AppleAccountSession.shared.needsSignIn { MacSignInGate().ignoresSafeArea(.container, edges: .top) }
            else if desktop.settingsPage != nil { DesktopSettingsView(changed: preferencesChanged) }
            else { workspace }
        }.background(palette.background).foregroundStyle(palette.foreground).tint(palette.accent)
            .font(preferences.font()).controlSize(.small)
            .preferredColorScheme(preferences.colorMode.scheme)
            .environment(\.chatAccentOverride, palette.accent)
            .confirmationDialog("Delete this task?", isPresented: Binding(get: { deletingTask != nil }, set: { if !$0 { deletingTask = nil } }), titleVisibility: .visible, presenting: deletingTask) { task in
                Button("Delete task", role: .destructive) { Task { await coding.delete(task.id) } }
            } message: { task in
                Text(CodingAgentSessionRemoval.summary(task))
            }
            .confirmationDialog("Remove this project from Tsukumo?", isPresented: Binding(get: { removingProject != nil }, set: { if !$0 { removingProject = nil } }), titleVisibility: .visible, presenting: removingProject) { project in
                Button("Remove project and its tasks", role: .destructive) {
                    Task { await coding.deleteTasks(ofProject: project.id); projects.remove(project.id) }
                }
            } message: { _ in Text("Its tasks, their worktrees, and their conversations are deleted. The folder on your Mac isn't touched.") }
            .sheet(item: $selectedArchive) { archive in
                ArchivedConversationDetail(archive: archive, resumed: { desktop.page = "Chat"; draft = "" }).frame(width: 650, height: 540)
            }
            // "Share context with…": the review card, then the chat it continues in (or the Tsukumo task it went to).
            .contextPacketSheet(source: $sharingChat, colors: .init(background: palette.background, surface: palette.sidebar,
                                                                     foreground: palette.foreground, accent: palette.accent)) { destination in
                if destination.kind == .chat { desktop.page = "Chat"; draft = "" }
            }
            .environment(\.contextPacketExtras, tsukumoExtras)
            // Another agent's request for one piece of context, answered here (`AgentRequestInbox`).
            .agentRequestSheet(store: store, colors: .init(background: palette.background, surface: palette.sidebar,
                                                           foreground: palette.foreground, accent: palette.accent))
            .confirmationDialog("Delete this conversation?", isPresented: Binding(get: { deletingCurrent || deletingArchive != nil }, set: { if !$0 { deletingCurrent = false; deletingArchive = nil } }), titleVisibility: .visible) {
                Button("Delete conversation", role: .destructive) {
                    if let id = deletingArchive { store.deleteArchivedConversation(id) } else { store.deleteCurrentConversation(); draft = "" }
                    deletingCurrent = false; deletingArchive = nil
                }
            } message: { Text("The conversation is removed from this device. Saved memories remain separately editable. Provider-retained copies cannot be deleted here.") }
            .onChange(of: store.conversationRevision) { draft = ""; images = [] }
            // Claude in the model chip and the new chat's suggestions, with its install and sign-in state.
            .environment(\.chatAgents, KemoSabeHandoff.options(registry: CodingAgentRegistry.shared, desktop: desktop))
            #if DEBUG
            // The chat-with-Claude demo (`--agent-handoff-fixture`): the message types in and goes to a fake Claude.
            .task { KemoSabeHandoffFixture.install(in: store) { draft = $0 } }
            #endif
        .onChange(of: desktop.settingsPage) { voice.stop(); nativeTask?.cancel() }
        // Onboarding lands in Tsukumo, on the project added during setup if there is one.
        .onChange(of: onboarding.finishedRevision) { desktop.page = "Tsukumo"; desktop.tsukumoSurface = "Project" }
    }
    /// Tsukumo tasks as destinations for a chat's context (`TsukumoContextHandoff`): delivered, the task opens.
    private var tsukumoExtras: ContextPacketExtras {
        let projects = projects, coding = coding, store = store, desktop = desktop
        return .init(destinations: {
            TsukumoContextHandoff.destinations(projects: projects.projects, tasks: coding.tasks, settings: .remembered())
        }, deliver: { packet, message in
            let project = projects.projects.first { $0.id == packet.destination.project }
            do {
                let id = try await TsukumoContextHandoff.deliver(packet, message: message, store: store, coding: coding, project: project,
                                                                 root: { try projects.resolve(project?.id ?? UUID()) }, settings: .remembered())
                if let project { projects.selected = project.id }
                coding.selected = id; desktop.page = "Tsukumo"; desktop.tsukumoSurface = "Project"
                return nil
            } catch { return error.localizedDescription }
        })
    }
    private var workspace: some View {
        HStack(spacing: 0) {
            if desktop.showSidebar { sidebar }
            VStack(spacing: 0) {
                header
                Group {
                    switch desktop.page {
                    case "Day": DesktopDayPage()
                    case "People": PeopleView()
                    case "Library": DesktopLibraryPage()
                    case "Connections": DesktopConnectionsView()
                    case "Models": ModelConnectionsView()
                    case "Tsukumo": CodingWorkspaceView()
                    case "Appearance": DesktopCompanionSettings(changed: preferencesChanged)
                    default: chat
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                // While a menu is open, a click here only closes it (native views like the terminal would otherwise take it).
                .allowsHitTesting(openMenu != .account)
            }.background(palette.background)
        }
        // Content runs up under the transparent titlebar, so the sidebar's first row sits beside the traffic lights.
        .ignoresSafeArea(.container, edges: .top)
        .overlay { menus }
        .onChange(of: desktop.page) { openMenu = nil }
        .onChange(of: desktop.settingsPage) { openMenu = nil }
        .background(palette.sidebar).tint(palette.accent)
            .onAppear {
                voice.onText = { draft = dictationPrefix + $0 }
                voice.cloudKeyProvider = { [store] in CloudVoice.key(in: store) }
                // Better voice models the owner agreed to download finish in the background.
                SpeechVoices.shared.resumeBetterModels()
            }
            .onChange(of: desktop.page) { voice.stop(); nativeTask?.cancel() }
            .onChange(of: store.modelRoute) {
                if routeSwitchedForCommand { routeSwitchedForCommand = false; return }
                voice.stop(); nativeTask?.cancel(); draft = ""
            }
            .onChange(of: store.state.selectedAPIProfile) { voice.stop(); nativeTask?.cancel(); draft = "" }
            .onChange(of: store.proposalRevision) { Task { await routines.refresh() } }
            .onChange(of: store.state.theme.id) { AccountStore.shared.companionChanged() }
            .alert("Local storage needs attention", isPresented: Binding(get: { store.storageError != nil }, set: { _ in })) {
                Button("Retry") { store.retrySave() }
            } message: { Text(store.storageError ?? "") }
    }
    private var inTsukumo: Bool { desktop.page == "Tsukumo" }
    private var sidebar: some View {
        @Bindable var desktop = desktop
        return VStack(alignment: .leading, spacing: Self.sidebarSpacing) {
            TitlebarControls()
            // The app name reads like Codex's: plain text in the theme's foreground, with a menu to switch.
            HStack(spacing: 6) {
                Button { withAnimation(.easeOut(duration: 0.18)) { openMenu = openMenu == .mode ? nil : .mode } } label: {
                    HStack(spacing: 5) {
                        Text(inTsukumo ? "Tsukumo" : "KemoSabe").font(preferences.font(19)).fontWeight(.semibold)
                        Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(openMenu == .mode ? 180 : 0))
                    }.foregroundStyle(palette.foreground).contentShape(Rectangle())
                }
                .buttonStyle(.plain).fixedSize().accessibilityIdentifier("modeSwitch")
                Spacer()
                Button { withAnimation(.easeOut(duration: 0.15)) { searching.toggle() }; if !searching { desktop.search = "" } } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(DesktopRowButtonStyle(selected: searching, inset: 6)).help("Search").accessibilityLabel("Search")
            }.padding(.leading, 8)
            // Switching apps rolls down inside the sidebar, pushing the rows below, instead of floating over them.
            if openMenu == .mode { modeChoices.transition(.move(edge: .top).combined(with: .opacity)) }
            if searching {
                TextField(inTsukumo ? "Search projects and tasks" : "Search chats", text: $desktop.search).textFieldStyle(.plain).padding(8)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityIdentifier("sidebarSearch")
            }
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    if inTsukumo { desktop.tsukumoSurface = "Project"; coding.selected = nil }
                    else { store.newConversation(); desktop.page = "Chat"; draft = "" }
                } label: { row("New chat", symbol: "square.and.pencil") }
                    .buttonStyle(DesktopRowButtonStyle()).accessibilityIdentifier("newChat")
                if inTsukumo {
                    // Coding lives in Tsukumo.
                    tsukumoRow("Coordination", symbol: "point.3.filled.connected.trianglepath.dotted")
                    tsukumoRow("Terminal", symbol: "terminal")
                    settingsRow("Agents", page: "Agents", symbol: "sparkles")
                    settingsRow("Editors", page: "Editors", symbol: "app.dashed")
                } else {
                    // People and your day live with KemoSabe.
                    mode("People", page: "People", symbol: "person.2")
                    mode("Day", page: "Day", symbol: "sun.max")
                    mode("Library", page: "Library", symbol: "books.vertical")
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if inTsukumo { codeProjects } else { chatProjects; recents }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.scrollIndicators(.hidden)
            UpdateCard(accent: palette.accent)
            Divider().padding(.horizontal, -10)
            account.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { accountBarHeight = $0 }
        }.font(preferences.font()).padding(.horizontal, 10).padding(.bottom, 10).frame(width: 248)
            .background(SidebarSurface(tint: palette.sidebar, translucent: preferences.translucentSidebar))
            .overlay(alignment: .trailing) { Divider() }
            .alert("New project", isPresented: $namingProject) {
                TextField("Name", text: $projectName)
                Button("Cancel", role: .cancel) { projectName = "" }
                Button("Create") { store.createProject(projectName); projectName = "" }
            } message: { Text("Projects group chats. Each chat keeps its own history.") }
    }
    /// KemoSabe's projects are folders of chats, like ChatGPT's.
    @ViewBuilder private var chatProjects: some View {
        HStack {
            sectionTitle("Projects")
            Spacer()
            Button { namingProject = true } label: { Image(systemName: "plus") }.buttonStyle(DesktopRowButtonStyle(inset: 6)).help("New project").accessibilityIdentifier("newChatProject")
        }
        ForEach(store.projects) { project in
            let expandedProject = openProjects.contains(project.id)
            Button { if expandedProject { openProjects.remove(project.id) } else { openProjects.insert(project.id) } } label: {
                row(project.name, symbol: expandedProject ? "folder.fill" : "folder")
            }.buttonStyle(DesktopRowButtonStyle())
                .contextMenu {
                    Button("New chat in project") { store.newConversation(in: project.id); desktop.page = "Chat"; draft = "" }
                    Button("Delete project", role: .destructive) { store.deleteProject(project.id) }
                }
            if expandedProject {
                ForEach(chats(in: project.id)) { archive in archiveRow(archive).padding(.leading, 18) }
            }
        }
        if store.projects.isEmpty { emptyNote("No projects") }
    }
    @ViewBuilder private var recents: some View {
        sectionTitle("Recents").padding(.top, 14)
        if desktop.search.isEmpty, !store.conversationMessages.isEmpty {
            Button { desktop.page = "Chat" } label: { row(store.conversationMessages.first(where: { $0.role == "You" })?.text ?? "Current chat", symbol: nil) }
                .buttonStyle(DesktopRowButtonStyle(selected: desktop.page == "Chat")).contextMenu {
                    if !store.projects.isEmpty {
                        Menu("Move to project") { ForEach(store.projects) { project in Button(project.name) { store.moveCurrentConversation(to: project.id) } } }
                    }
                    PrivacyLevelMenu(current: store.currentConversationPrivacy) { store.setCurrentConversationPrivacy($0) }
                    Button("Share context with…") { sharingChat = .init(id: store.conversationID(for: store.currentConversationSlot)) }
                    Button("Delete conversation", role: .destructive) { deletingCurrent = true }
                }
        }
        let archives = chats(in: nil)
        ForEach(archives) { archiveRow($0) }
        if archives.isEmpty && store.conversationMessages.isEmpty { emptyNote(desktop.search.isEmpty ? "No chats" : "No matching chats") }
    }
    private func chats(in project: UUID?) -> [ConversationArchive] {
        (store.state.conversationArchives ?? []).reversed().filter {
            desktop.search.isEmpty ? $0.projectID == project : $0.title.localizedCaseInsensitiveContains(desktop.search) && project == nil
        }
    }
    private func archiveRow(_ archive: ConversationArchive) -> some View {
        // A past chat reopens where you left off, as in Codex; one held with another model opens read-only.
        Button {
            if store.canResume(archive) { store.resumeArchivedConversation(archive.id); desktop.page = "Chat"; draft = "" }
            else { selectedArchive = archive }
        } label: { row(archive.title, symbol: nil) }
            .buttonStyle(DesktopRowButtonStyle()).contextMenu {
                if !store.projects.isEmpty {
                    Menu("Move to project") {
                        ForEach(store.projects) { project in Button(project.name) { store.move(archive.id, to: project.id) } }
                        if archive.projectID != nil { Button("Remove from project") { store.move(archive.id, to: nil) } }
                    }
                }
                PrivacyLevelMenu(current: store.conversationPrivacy(archive.id)) { store.setConversationPrivacy($0, for: archive.id) }
                Button("Share context with…") { sharingChat = .init(id: archive.id) }
                Button("Delete conversation", role: .destructive) { deletingArchive = archive.id }
            }
    }
    /// Tsukumo's projects are code folders on this Mac.
    @ViewBuilder private var codeProjects: some View {
        HStack {
            sectionTitle("Projects")
            Spacer()
            Button { projects.choose(); desktop.tsukumoSurface = "Project" } label: { Image(systemName: "plus") }.buttonStyle(DesktopRowButtonStyle(inset: 6)).help("Add project")
        }
        // Search finds projects by name and tasks by title, agent, or status (CodingChatStore).
        let folders = projects.projects.filter { desktop.search.isEmpty || $0.name.localizedCaseInsensitiveContains(desktop.search) || coding.forProject($0.id).contains { CodingWorkspaceStore.matches($0, desktop.search) } }
        let numbered = coding.sidebarOrder(project: projects.selected).map(\.id)
        ForEach(folders) { project in
            Button { projects.selected = project.id; coding.selected = nil; desktop.tsukumoSurface = "Project" } label: { row(project.name, symbol: "folder") }
                .buttonStyle(DesktopRowButtonStyle(selected: desktop.tsukumoSurface == "Project" && projects.selected == project.id && coding.selected == nil))
                .contextMenu { Button("Remove from Projects…", role: .destructive) { removingProject = project } }
            ForEach(coding.sidebarOrder(project: project.id).filter { CodingWorkspaceStore.matches($0, desktop.search) || project.name.localizedCaseInsensitiveContains(desktop.search) }) { task in
                CodingTaskSidebarRow(task: task, number: project.id == projects.selected ? numbered.firstIndex(of: task.id).map { $0 + 1 }.flatMap { $0 <= 9 ? $0 : nil } : nil, onDelete: { deletingTask = task })
            }
        }
        if folders.isEmpty { emptyNote(desktop.search.isEmpty ? "No projects" : "No matching projects") }
        // Tasks left behind by a project removed in an earlier build, so they can still be deleted.
        let orphans = coding.orphans(keeping: Set(projects.projects.map(\.id)))
        if !orphans.isEmpty {
            sectionTitle("Other tasks")
            ForEach(orphans) { task in taskRow(task, project: nil) }
        }
        if !projects.notice.isEmpty { Text(projects.notice).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8) }
        if coding.tasks.isEmpty && !folders.isEmpty { emptyNote("No coding tasks yet") }
    }
    private func taskRow(_ task: CodingTaskRecord, project: UUID?) -> some View {
        Button { if let project { projects.selected = project }; coding.selected = task.id; desktop.tsukumoSurface = "Project" } label: {
            HStack(spacing: 6) {
                Circle().fill(task.status == .working ? Color.green : task.status == .needsInput ? Color.orange : Color.secondary).frame(width: 5, height: 5)
                Text(task.title).lineLimit(1)
                Spacer(minLength: 0)
            }.font(.system(size: 12)).padding(.leading, 22).padding(.vertical, 5)
        }.buttonStyle(DesktopRowButtonStyle(selected: coding.selected == task.id))
            .help(task.status.title + " · " + task.provider.title)
            .contextMenu {
                Button("Archive") { coding.archive(task.id) }
                Button("Delete task…", role: .destructive) { deletingTask = task }
            }
    }
    private func tsukumoRow(_ title: String, symbol: String) -> some View {
        Button { desktop.tsukumoSurface = title } label: { row(title, symbol: symbol) }
            .buttonStyle(DesktopRowButtonStyle(selected: desktop.tsukumoSurface == title)).accessibilityIdentifier("tsukumo-" + title)
    }
    private func settingsRow(_ title: String, page: String, symbol: String) -> some View {
        Button { desktop.settingsPage = page } label: { row(title, symbol: symbol) }.buttonStyle(DesktopRowButtonStyle())
    }
    /// You and your companion at the bottom of the sidebar. Your photo and name open the
    /// account menu, as in Codex; Kemo's picture shows or hides the floating companion.
    private var account: some View {
        HStack(spacing: 0) {
            Button { openMenu = openMenu == .account ? nil : .account } label: {
                HStack(spacing: 9) {
                    AccountPhoto(size: 26)
                    Text(AccountStore.shared.firstName).lineLimit(1)
                    Spacer(minLength: 0)
                }.font(preferences.font(13)).padding(.leading, 8).padding(.vertical, 7).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("openSettings")
            // Kemo's picture brings the big Kemo up in the chat, as the smiley did.
            Button { showBigKemo() } label: {
                ArtworkCompanion(theme: store.state.theme, reducedMotion: true, active: false)
                    .frame(width: 26, height: 26).scaleEffect(1.2).background(Color.primary.opacity(0.06), in: Circle()).clipShape(Circle())
                    .overlay(Circle().strokeBorder(bigKemoShown ? palette.accent : .clear, lineWidth: 1.5))
                    .padding(.horizontal, 8).padding(.vertical, 5).contentShape(Rectangle())
            }.buttonStyle(.plain).help(bigKemoShown ? "Hide \(CompanionIdentity.name)" : "Show \(CompanionIdentity.name)")
                .accessibilityLabel(bigKemoShown ? "Hide \(CompanionIdentity.name)" : "Show \(CompanionIdentity.name)").accessibilityIdentifier("toggleCompanion")
        }
        .background(Color.primary.opacity(openMenu == .account || desktop.settingsPage != nil ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    private var bigKemoShown: Bool { expanded && stageShown && desktop.page == "Chat" }
    private func showBigKemo() {
        withAnimation(.easeOut(duration: 0.2)) {
            if desktop.page != "Chat" { desktop.page = "Chat"; expanded = true; stagePinned = true }
            else if bigKemoShown { expanded = false; stagePinned = false }
            else { expanded = true; stagePinned = true }
        }
    }
    private var stageReduceMotion: Bool { preferences.followReduceMotion ? reduceMotion : preferences.reduceMotion }

    // MARK: Menus (drawn in the window, like Codex's, rather than as system menus)
    enum SidebarMenu { case mode, account }
    @ViewBuilder private var menus: some View {
        if let menu = openMenu, menu != .mode {
            ZStack {
                Color.black.opacity(0.001).onTapGesture { openMenu = nil }
                Group {
                    switch menu {
                    case .mode: EmptyView()
                    // Above the divider over the account bar (bar + row spacing + bottom inset), with a
                    // small gap, and inside the sidebar with the account row's insets, as in Codex.
                    case .account: accountMenu.padding(.bottom, accountBarHeight + Self.sidebarSpacing + 10 + 8).padding(.leading, 10)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: menu == .mode ? .topLeading : .bottomLeading)
            }
            // While a menu is open, only it answers clicks and VoiceOver, as a real menu does.
            .accessibilityAddTraits(.isModal)
            .onExitCommand { openMenu = nil }
        }
    }
    private var modeChoices: some View {
        VStack(alignment: .leading, spacing: 2) {
            modeChoice("KemoSabe", detail: "Your personal agent", selected: !inTsukumo) { CompanionAvatar(theme: store.state.theme, size: 24) } action: { desktop.page = "Chat" }
            modeChoice("Tsukumo", detail: "Coding", selected: inTsukumo) { TsukumoMark(size: 24) } action: { desktop.page = "Tsukumo" }
        }.padding(4).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityIdentifier("modeChoices")
    }
    private func modeChoice<Icon: View>(_ title: String, detail: String, selected: Bool, @ViewBuilder icon: () -> Icon, action: @escaping () -> Void) -> some View {
        // The page switches at once; only the chooser rolls up. Animating the switch itself
        // animated the whole workspace (terminal, file tree, chat) and felt laggy.
        Button { action(); withAnimation(.easeOut(duration: 0.15)) { openMenu = nil } } label: {
            HStack(spacing: 10) {
                icon().frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(preferences.font(13))
                    Text(detail).font(preferences.font(11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tint) }
            }.padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
        }.buttonStyle(DesktopRowButtonStyle(selected: selected)).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var accountMenu: some View {
        MenuPanel(width: 228) {
            // The header opens your account, as Codex's does.
            Button { desktop.settingsPage = "Account"; openMenu = nil } label: { HStack(spacing: 11) {
                AccountPhoto(size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(AccountStore.shared.displayName.isEmpty ? "You" : AccountStore.shared.displayName).font(.system(size: 14, weight: .semibold))
                    // The plan, as in Codex. Everyone is on Free until plans exist.
                    Text(AccountPlan.current).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 10).contentShape(Rectangle()) }
            .buttonStyle(.plain).accessibilityIdentifier("accountHeader")
            Divider().padding(.horizontal, 8).padding(.bottom, 4)
            MenuPanelRow(title: "Usage", symbol: "gauge.with.dots.needle.33percent", shortcut: "›") { desktop.settingsPage = "Usage"; openMenu = nil }
            MenuPanelRow(title: companionShown ? "Hide companion" : "Show companion", symbol: "pawprint", shortcut: "⌘M") { toggleCompanion(); openMenu = nil }
            MenuPanelRow(title: "Invite a friend", symbol: "paperplane") { inviteFriend(); openMenu = nil }
            MenuPanelRow(title: "Settings", symbol: "gearshape", shortcut: "⌘,") { desktop.settingsPage = "General"; openMenu = nil }
            // Signing out comes with iCloud accounts; until then this opens Account, which says so.
            MenuPanelRow(title: "Log out", symbol: "rectangle.portrait.and.arrow.right") { desktop.settingsPage = "Account"; openMenu = nil }
            if DeveloperMode.shared.enabled {
                MenuPanelRow(title: "Developer settings", symbol: "hammer") { desktop.settingsPage = "Companion"; openMenu = nil }
            }
        }
    }
    private var companionShown: Bool { preferences.isVisible }
    /// Shares an invitation with the Mac's share menu (Messages, Mail, AirDrop…).
    private func inviteFriend() {
        guard let view = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: ["I'm trying KemoSabe, a personal AI companion. Want to try it with me?"])
        picker.show(relativeTo: CGRect(x: 24, y: 64, width: 1, height: 1), of: view, preferredEdge: .maxY)
    }
    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(preferences.font(13)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 6)
    }
    private func emptyNote(_ text: String) -> some View {
        Text(text).font(preferences.font(13)).foregroundStyle(.tertiary).padding(.horizontal, 8).padding(.vertical, 4)
    }
    private func row(_ title: String, symbol: String?) -> some View {
        HStack(spacing: 9) {
            if let symbol { Image(systemName: symbol).frame(width: 16) }
            Text(title).lineLimit(1)
            Spacer(minLength: 0)
        }.font(preferences.font(13)).padding(.horizontal, 8).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
    private func mode(_ title: String, page: String, symbol: String) -> some View {
        Button { desktop.page = page } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol).frame(width: 16)
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
            }.font(preferences.font(13)).padding(.horizontal, 8).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }.buttonStyle(DesktopRowButtonStyle(selected: desktop.page == page)).accessibilityIdentifier("mode-" + title)
            .onHover { hovering in if preferences.pointerCursors { (hovering ? NSCursor.pointingHand : NSCursor.arrow).set() } }
    }
    /// The top of the main pane shares the traffic lights' row.
    private var header: some View {
        HStack(spacing: 12) {
            if !desktop.showSidebar { TitlebarControls().fixedSize() }
            // Chat and Tsukumo speak for themselves; other pages keep a quiet title.
            if !["Chat", "Tsukumo"].contains(desktop.page) { Text(desktop.page).font(preferences.font(13)).fontWeight(.medium).foregroundStyle(.secondary) }
            Spacer()
        }.font(preferences.font(12)).padding(.horizontal, desktop.showSidebar ? 18 : 10).frame(height: 30)
    }
    private var chat: some View {
        VStack(spacing: 0) {
            // Kemo on the stage while there's room, then in the latest reply's avatar; the conversation
            // shares the composer's centered column.
            DesktopChatStage(expanded: expanded, pinned: $stagePinned, stageShown: $stageShown,
                             active: desktop.windowVisible, reduceMotion: stageReduceMotion, pageHeight: chatHeight) { draft = $0; submit() }
                // A finished reply is read aloud when that's on (Models → Voice), never over dictation.
                .onChange(of: store.isThinking) { wasThinking, thinking in
                    guard wasThinking, !thinking, readAloud.enabled, !voice.listening,
                          let reply = store.conversationMessages.last, reply.role != "You" else { return }
                    readAloud.speak(reply.text, id: reply.id, store: store)
                }
            VStack(spacing: 9) {
                // One signal per state, as on iPhone: the composer shows listening ("Listening…" and the
                // microphone's orb) and the transcript's row shows thinking, so there's no glow under the
                // composer. This line is only for a problem, a review note, or a transcriber at work.
                if !voice.status.isEmpty { Text(voice.status).font(KemoType.font(.caption)).foregroundStyle(.secondary).accessibilityIdentifier("voiceStatus") }
                ChatComposerPanel(text: $draft, images: $images, surface: palette.sidebar, accent: palette.accent, listening: voice.listening, attachmentRequest: attachmentRequest,
                    microphoneOn: voice.listening, microphoneBusy: voice.authorizing || voice.transcribing, microphoneUnavailable: false,
                    send: submit, cancel: { if store.handoffWorking != nil { KemoSabeHandoff.shared.stop(store: store) } else { store.cancel() } }, attach: { attachmentRequest += 1 },
                    newConversation: { store.newConversation(); desktop.page = "Chat"; draft = "" },
                    toggleMicrophone: {
                        if !voice.listening { dictationPrefix = draft.isEmpty ? "" : draft + " "; readAloud.stop() }
                        voice.toggle()
                    }, focusChanged: { _ in })
                // On-device privacy shows as the lock on the model button; a connected model names where
                // messages go, and Apple's Private Cloud says it runs on Private Cloud Compute.
                if store.modelRoute != .onDevice || store.appleModel == .privateCloud {
                    HStack(spacing: 5) {
                        Image(systemName: store.modelRoute == .onDevice ? "cloud" : "network")
                        Text(store.modelRoute == .onDevice ? PrivateCloudText.destination
                             : "Messages sent to " + (store.activeAPIProfile?.endpoint.host ?? "your model"))
                        Spacer()
                    }.font(KemoType.font(.caption2)).foregroundStyle(.secondary).padding(.horizontal, 8)
                }
            }.padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 22).frame(maxWidth: 780)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { chatHeight = $0 }
    }
    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !images.isEmpty {
            voice.stop()
            let attached = store.takeComposerAttachments()
            if store.sendImages(text, images: images, attachments: attached) { draft = ""; images = [] } else { store.composerAttachments = attached }
            return
        }
        guard !text.isEmpty, !store.isThinking else { return }
        guard text.count <= 2000 else { store.error = "Keep this message under 2,000 characters."; return }
        voice.stop(); readAloud.stop()
        // Sending ends a pinned performance; a command that asks for one pins it again.
        stagePinned = false
        // A chat with an agent: your message goes to it, and "@Kemo …" to Kemo on this Mac only.
        if store.state.chatAgent != nil {
            if let kemo = ChatAgentRouting.kemoMessage(text) {
                guard store.canChat else { store.error = store.availability; return }
                draft = ""; store.send(kemo, attachments: store.takeComposerAttachments()); return
            }
            if let working = store.handoffWorking { store.error = "\(working) is still answering. Stop it, or wait."; return }
            draft = ""; KemoSabeHandoff.shared.send(text, store: store); return
        }
        if let command = VoiceCommand.parse(text) {
            if command.requiresPrivateContext, store.modelRoute != .onDevice {
                // Cancel older work now; the route-change handler would otherwise cancel this command too.
                voice.stop(); nativeTask?.cancel()
                routeSwitchedForCommand = true
                store.selectModel(.onDevice)
                if store.modelRoute != .onDevice { routeSwitchedForCommand = false }
            }
            draft = ""; store.appendVisibleMessage(role: "You", text: text); handle(command)
        } else {
            guard store.canChat else { store.error = store.availability; return }
            draft = ""; store.send(text, attachments: store.takeComposerAttachments())
        }
    }
    private func reply(_ text: String) { store.appendVisibleMessage(role: "KemoSabe", text: text) }
    private func handle(_ command: VoiceCommand) {
        if let response = VoiceSettingsAction.apply(command, to: &store.state) { store.save(); reply(response); return }
        switch command {
        case .perform(let performance): navigation.perform(performance); expanded = true; stagePinned = true; reply(performance == .idle ? "Stopped." : "Here goes.")
        case .open(let panel):
            let page: String = switch panel {
            case .model: "Models"
            case .connections: "Connections"
            case .workspace, .history: "Library"
            case .routine: "Day"
            default: "Appearance"
            }
            if ["Appearance", "Models", "Connections"].contains(page) { desktop.settingsPage = page } else { desktop.page = page }; reply("Opened " + page.lowercased() + ".")
        case .home, .back: desktop.page = "Chat"
        case .runShortcut(let name): reply(ShortcutsIntegration.shared.run(name))
        case .cancel: nativeTask?.cancel(); store.cancel(); store.cancelStandup(); reply("Cancelled. Existing drafts remain for review.")
        case .pause: voice.stop(); reply("Microphone off.")
        case .help: reply("You can type or dictate, change the model, ask me to dance, or review your day and memories. Press Command-M to keep me nearby on your desktop.")
        case .connect, .connectSelected: desktop.settingsPage = "Connections"; reply("Choose the connection to review its access.")
        case .disconnect(let id): reply(connectors.disconnect(id, store: store))
        case .agenda: read(.calendar)
        case .reminders: read(.reminders)
        case .contact(let name): read(.contacts, query: name)
        case .goodnight, .morning:
            nativeTask = Task {
                if command == .goodnight { await routines.goodnight() } else { await routines.morning() }
                guard !Task.isCancelled else { return }
                reply(routines.error ?? (command == .goodnight ? "Goodnight." : "Good morning. Your day is ready to review."))
            }
        default: break
        }
    }
    private func read(_ id: ConnectorID, query: String? = nil) {
        nativeTask?.cancel(); nativeTask = Task {
            let result = await connectors.read(id, query: query, store: store)
            guard !Task.isCancelled else { return }; reply(result)
        }
    }
}

/// Your account photo, or your initials when there isn't one.
struct AccountPhoto: View {
    var size: CGFloat
    @State private var account = AccountStore.shared
    var body: some View {
        Group {
            if let url = account.photoURL, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Text(initials).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.primary.opacity(0.1))
            }
        }.frame(width: size, height: size).clipShape(Circle()).accessibilityLabel("Your photo")
    }
    private var initials: String {
        let letters = account.displayName.split(separator: " ").prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

/// A menu drawn in the window, like Codex's account and app menus: rounded,
/// themed, with icons, details, and shortcuts.
struct MenuPanel<Content: View>: View {
    var width: CGFloat
    @ViewBuilder var content: Content
    @Environment(DesktopPreferences.self) private var preferences
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 1) { content }
            .padding(6).frame(width: width, alignment: .leading)
            // A step lighter than the sidebar, as Codex's menus are.
            .background(Color.white.opacity(scheme == .dark ? 0.07 : 0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .background(preferences.palette(scheme).sidebar, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
    }
}

struct MenuPanelRow<Icon: View>: View {
    let title: String
    var detail: String? = nil
    var shortcut: String? = nil
    var selected = false
    @ViewBuilder var icon: Icon
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon.frame(width: 26, alignment: .center)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13.5))
                    if let detail { Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 8)
                if let shortcut { Text(shortcut).font(.system(size: 12)).foregroundStyle(.tertiary) }
                if selected { Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tint) }
            }
            .padding(.horizontal, 10).padding(.vertical, detail == nil ? 7 : 6)
            .background(Color.primary.opacity(hovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovering = $0 }
    }
}
extension MenuPanelRow where Icon == AnyView {
    init(title: String, symbol: String, shortcut: String? = nil, action: @escaping () -> Void) {
        self.init(title: title, shortcut: shortcut, icon: { AnyView(Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(.secondary)) }, action: action)
    }
}

/// Tsukumo's logo mark without the wordmark, for menus. The bundled logo is used
/// unchanged; the mark is cropped from it when drawn.
struct TsukumoMark: View {
    var size: CGFloat
    static let mark: NSImage? = {
        guard let url = Bundle.main.url(forResource: "Tsukumo", withExtension: "png"), let image = NSImage(contentsOf: url),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        // The mark's square in the 1774 × 887 logo, scaled to whatever size the file is.
        let scale = CGFloat(cg.width) / 1774
        guard let cropped = cg.cropping(to: CGRect(x: 732 * scale, y: 205 * scale, width: 305 * scale, height: 305 * scale)) else { return nil }
        return NSImage(cgImage: cropped, size: .init(width: cropped.width, height: cropped.height))
    }()
    var body: some View {
        Group {
            if let mark = Self.mark { Image(nsImage: mark).resizable().scaledToFit() }
            else { Image(systemName: "curlybraces") }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}


/// Sidebar toggle and back/forward on the traffic lights' row, as in Codex. The same
/// controls sit in the main window and in Settings.
struct TitlebarControls: View {
    @Environment(DesktopNavigation.self) private var desktop
    var body: some View {
        HStack(spacing: 8) {
            Spacer().frame(width: 70)
            Button { desktop.showSidebar.toggle() } label: { Image(systemName: "sidebar.left") }
                .help(desktop.showSidebar ? "Hide sidebar" : "Show sidebar").accessibilityLabel(desktop.showSidebar ? "Hide sidebar" : "Show sidebar")
                .accessibilityIdentifier("toggleSidebar")
            Button { desktop.goBack() } label: { Image(systemName: "chevron.left") }.disabled(desktop.history.isEmpty).help("Back").accessibilityLabel("Back")
            Button { desktop.goForward() } label: { Image(systemName: "chevron.right") }.disabled(desktop.future.isEmpty).help("Forward").accessibilityLabel("Forward")
            Spacer(minLength: 0)
        }.buttonStyle(DesktopRowButtonStyle(inset: 5)).font(.system(size: 15, weight: .regular)).foregroundStyle(.secondary).frame(height: 30)
    }
}

/// The Mac chat's stage and transcript (`ChatStage`): while the chat has room, the big Kemo is up on
/// the stage acting out the task it's working on, as on iPhone; when the conversation fills the view,
/// it shrinks into the latest reply's avatar, and it hops back up when there's room again.
struct DesktopChatStage: View {
    /// The person keeps the big Kemo on the chat.
    var expanded: Bool
    /// A performance just asked for plays on the stage until the person scrolls or sends.
    @Binding var pinned: Bool
    @Binding var stageShown: Bool
    var active = true
    var reduceMotion = false
    /// The whole chat page's height (`NewChatMetrics.topInset`).
    var pageHeight: CGFloat = 0
    var suggestion: (String) -> Void
    @Environment(AppStore.self) private var store
    @Environment(AppNavigation.self) private var navigation
    @State private var metrics = ChatStage.Metrics()
    /// The person scrolled by hand and isn't back at the latest message (`ChatStage`).
    @State private var browsing = false
    @Namespace private var kemoSpace
    /// The same size as a new chat's Kemo and Tsukumo's Kemo at work.
    static let stageHeight: CGFloat = NewChatMetrics.kemoSize
    var body: some View {
        let empty = store.conversationMessages.isEmpty
        VStack(spacing: 0) {
            // A new chat's Kemo is in the greeting (`NewChatLayout`), as in a new Tsukumo task.
            if expanded && stageShown && !empty { kemo }
            ChatTranscript(suggestion: suggestion).frame(maxWidth: 780).frame(maxWidth: .infinity)
                .environment(\.chatStage, ChatStageContext(namespace: kemoSpace, kemoInAvatar: !(expanded && stageShown),
                    anchorsTop: ChatStage.anchorsTop(metrics, stageHeight: Self.stageHeight, shown: stageShown && expanded, browsing: browsing),
                    reduceMotion: reduceMotion, report: { update($0) }, scrolled: { browsing = true; if pinned { pinned = false } },
                    emptyKemo: expanded && empty ? AnyView(kemo) : nil,
                    emptyTopInset: NewChatMetrics.topInset(pageHeight: pageHeight)))
        }
        .onChange(of: store.conversationRevision) { pinned = false; update() }
        .onChange(of: expanded) { update() }
        .onChange(of: pinned) { update() }
        .onChange(of: store.conversationMessages.isEmpty) { update() }
    }
    /// The big Kemo acting out what it's doing, on the stage or in a new chat's greeting.
    private var kemo: some View {
        ArtworkCompanion(theme: store.state.theme,
            performance: ChatStage.performance(live: TaskActivity.live(navigation.performance.rawValue, store: store),
                                               conversationEmpty: store.conversationMessages.isEmpty),
            reducedMotion: reduceMotion, active: active, replay: navigation.performanceRevision, framesPerSecond: 30)
            .frame(height: Self.stageHeight).accessibilityIdentifier("homeCompanion")
            .modifier(StageKemo(namespace: reduceMotion ? nil : kemoSpace))
    }
    /// Kemo hops between the stage and the latest reply's avatar as the room comes and goes.
    private func update(_ next: ChatStage.Metrics? = nil) {
        let measured = metrics.viewportHeight > 0
        if let next { metrics = next; if ChatStage.atBottom(next) { browsing = false } }
        let shown = ChatStage.stageShown(metrics, stageHeight: Self.stageHeight, shown: stageShown && expanded,
                                         allowed: expanded, pinned: pinned, empty: store.conversationMessages.isEmpty, browsing: browsing)
        guard shown != stageShown else { return }
        // The first measurement places Kemo without a hop.
        if !measured { stageShown = shown; return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.74)) { stageShown = shown }
    }
}

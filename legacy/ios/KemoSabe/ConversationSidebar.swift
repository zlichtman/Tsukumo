import SwiftUI

/// Conversations open from the composer as a drawer: projects, the current chat,
/// and saved chats, each viewable, movable, and deletable here. Projects only
/// organize the list; every conversation stays its own history. Saved memories
/// stay separate in Library.
struct ConversationSidebar: View {
    @Environment(AppStore.self) private var store
    @Environment(\.mobilePalette) private var palette
    var close: () -> Void
    /// Called after the person continues a saved conversation.
    var resumed: () -> Void
    var deleteCurrent: () -> Void
    /// Starts a new conversation, in a project when one is given.
    var newConversation: (UUID?) -> Void = { _ in }
    @State private var search = ""
    /// Show only conversations started on one device.
    @State private var device: ConversationDevice?
    @State private var opened: ConversationArchive?
    /// A chat whose context is being shared ("Share context with…").
    @State private var sharing: ContextPacketSource?
    @State private var pendingDelete: PendingDelete?
    @State private var naming: ProjectNaming?
    @State private var path: [UUID] = []
    private enum PendingDelete: Equatable { case current, saved(UUID), project(UUID) }
    fileprivate struct ProjectNaming: Identifiable { var id: UUID?; var name: String }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if search.isEmpty {
                    Section {
                        ForEach(store.projects) { project in
                            NavigationLink(value: project.id) {
                                row(project.name, detail: count(in: project.id), symbol: "folder")
                            }
                            .accessibilityIdentifier("project-" + project.name)
                            .contextMenu { projectMenu(project) }
                            .swipeActions { Button("Delete", role: .destructive) { pendingDelete = .project(project.id) } }
                            .listRowBackground(Color.clear)
                        }
                        Button { naming = .init(id: nil, name: "") } label: {
                            Label("New project", systemImage: "folder.badge.plus").foregroundStyle(palette.accent)
                        }.accessibilityIdentifier("newProject").listRowBackground(Color.clear)
                    } header: { Text("Projects") }
                }
                chats(project: nil)
            }
            .listStyle(.insetGrouped).scrollContentBackground(.hidden)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search conversations")
            .safeAreaInset(edge: .top, spacing: 0) {
                // Filter by where a conversation started.
                Picker("Device", selection: $device) {
                    Text("All").tag(ConversationDevice?.none)
                    ForEach(ConversationDevice.allCases) { Label($0.rawValue, systemImage: $0.symbol).tag(Optional($0)) }
                }.pickerStyle(.segmented).padding(.horizontal, 16).padding(.bottom, 6).accessibilityIdentifier("conversationDevice")
            }
            .navigationTitle("Chats").navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar(project: nil) }
            .navigationDestination(for: UUID.self) { id in projectPage(id) }
            .background(palette.background.ignoresSafeArea())
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button(deleteButton, role: .destructive) {
                switch pendingDelete {
                case .current: deleteCurrent()
                case .saved(let id): store.deleteArchivedConversation(id)
                case .project(let id): path.removeAll { $0 == id }; store.deleteProject(id)
                case nil: break
                }
                pendingDelete = nil
            }
        } message: { Text(deleteMessage) }
        .alert(naming?.id == nil ? "New project" : "Rename project", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: Binding(get: { naming?.name ?? "" }, set: { naming?.name = $0 }))
                .accessibilityIdentifier("projectName")
            Button("Cancel", role: .cancel) { naming = nil }
            Button(naming?.id == nil ? "Create" : "Rename") {
                if let naming {
                    if let id = naming.id { store.renameProject(id, to: naming.name) } else { store.createProject(naming.name) }
                }
                naming = nil
            }.accessibilityIdentifier("saveProject")
        } message: { Text("Projects group chats. Each chat keeps its own history.") }
        .sheet(item: $opened) { ArchivedConversationDetail(archive: $0, resumed: resumed) }
        // The context moved to another chat: the drawer closes on that chat.
        .contextPacketSheet(source: $sharing, colors: .init(background: palette.background, surface: palette.surface,
                                                             foreground: palette.foreground, accent: palette.accent)) { _ in resumed() }
    }

    // MARK: Lists

    @ViewBuilder private func chats(project: UUID?) -> some View {
        let showsCurrent = currentMatches && (device == nil || (store.state.currentDevice ?? .this) == device)
            && (project == nil ? search.isEmpty || store.state.currentProjectID == nil : store.state.currentProjectID == project)
        let saved = savedChats(in: project)
        if showsCurrent {
            Section("Now") {
                Button(action: close) { row(currentTitle, detail: store.modelLabel, symbol: "bubble.left.and.bubble.right.fill") }
                    .accessibilityIdentifier("currentConversation")
                    .swipeActions { Button("Delete", role: .destructive) { pendingDelete = .current } }
                    .contextMenu {
                        moveMenu(current: store.state.currentProjectID) { store.moveCurrentConversation(to: $0) }
                        PrivacyLevelMenu(current: store.currentConversationPrivacy) { store.setCurrentConversationPrivacy($0) }
                        if !store.conversationMessages.isEmpty {
                            Button("Share context with…", systemImage: "square.stack.3d.up") {
                                sharing = .init(id: store.conversationID(for: store.currentConversationSlot))
                            }
                        }
                        Button("Delete conversation", systemImage: "trash", role: .destructive) { pendingDelete = .current }
                    }
                    .listRowBackground(Color.clear)
            }
        }
        if !saved.isEmpty {
            Section(project == nil && search.isEmpty ? "Chats" : "Earlier") {
                ForEach(saved) { archive in
                    Button { opened = archive } label: {
                        row(archive.title, detail: archive.model + " · " + archive.date.formatted(date: .abbreviated, time: .shortened), symbol: (archive.device ?? .iPhone).symbol)
                    }.accessibilityIdentifier("savedConversation")
                        .swipeActions { Button("Delete", role: .destructive) { pendingDelete = .saved(archive.id) } }
                        .contextMenu {
                            moveMenu(current: archive.projectID) { store.move(archive.id, to: $0) }
                            PrivacyLevelMenu(current: store.conversationPrivacy(archive.id)) { store.setConversationPrivacy($0, for: archive.id) }
                            Button("Share context with…", systemImage: "square.stack.3d.up") { sharing = .init(id: archive.id) }
                            Button("Delete conversation", systemImage: "trash", role: .destructive) { pendingDelete = .saved(archive.id) }
                        }
                        .listRowBackground(Color.clear)
                }
            }
        }
        if !showsCurrent && saved.isEmpty {
            ContentUnavailableView(search.isEmpty ? (project == nil ? "No conversations yet" : "No chats in this project") : "No matching conversations",
                                   systemImage: "bubble.left.and.bubble.right",
                                   description: Text(search.isEmpty ? (project == nil ? "Your conversations appear here." : "Start one here, or long-press a chat to move it in.") : "Try another word."))
                .listRowBackground(Color.clear)
        }
    }
    private func projectPage(_ id: UUID) -> some View {
        let project = store.projects.first { $0.id == id }
        return List { chats(project: id) }
            .listStyle(.insetGrouped).scrollContentBackground(.hidden)
            .background(palette.background.ignoresSafeArea())
            .navigationTitle(project?.name ?? "Project").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                toolbar(project: id)
                if let project {
                    ToolbarItem(placement: .secondaryAction) { Button("Rename", systemImage: "pencil") { naming = .init(id: project.id, name: project.name) } }
                    ToolbarItem(placement: .secondaryAction) { Button("Delete project", systemImage: "trash", role: .destructive) { pendingDelete = .project(project.id) } }
                }
            }
    }
    @ToolbarContentBuilder private func toolbar(project: UUID?) -> some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(role: .close, action: close)
                .accessibilityLabel("Close conversations").accessibilityIdentifier("closeConversations")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { newConversation(project); close() } label: { Image(systemName: "square.and.pencil") }
                .accessibilityLabel(project == nil ? "New chat" : "New chat in this project")
                .accessibilityIdentifier(project == nil ? "drawerNewChat" : "projectNewChat")
        }
    }
    @ViewBuilder private func projectMenu(_ project: ConversationProject) -> some View {
        Button("New chat here", systemImage: "square.and.pencil") { newConversation(project.id); close() }
        Button("Rename", systemImage: "pencil") { naming = .init(id: project.id, name: project.name) }
        Button("Delete project", systemImage: "trash", role: .destructive) { pendingDelete = .project(project.id) }
    }
    @ViewBuilder private func moveMenu(current: UUID?, move: @escaping (UUID?) -> Void) -> some View {
        if !store.projects.isEmpty {
            Menu("Move to project", systemImage: "folder") {
                ForEach(store.projects) { project in
                    Button(project.name, systemImage: current == project.id ? "checkmark" : "folder") { move(project.id) }
                }
                if current != nil { Button("Remove from project", systemImage: "folder.badge.minus") { move(nil) } }
            }
        }
    }

    // MARK: Data

    private var currentMatches: Bool {
        !store.conversationMessages.isEmpty && (search.isEmpty || store.conversationMessages.contains { $0.text.localizedCaseInsensitiveContains(search) })
    }
    /// With a search, every matching chat; otherwise chats filed in the given project (nil: unfiled).
    private func savedChats(in project: UUID?) -> [ConversationArchive] {
        (store.state.conversationArchives ?? []).reversed().filter { archive in
            guard search.isEmpty else {
                return (archive.title + archive.model).localizedCaseInsensitiveContains(search)
                    || archive.messages.contains { $0.text.localizedCaseInsensitiveContains(search) }
            }
            return archive.projectID == project
        }.filter { device == nil || ($0.device ?? .iPhone) == device }
    }
    private func count(in project: UUID) -> String {
        let chats = (store.state.conversationArchives ?? []).filter { $0.projectID == project }.count
            + (store.state.currentProjectID == project && !store.conversationMessages.isEmpty ? 1 : 0)
        return chats == 1 ? "1 chat" : "\(chats) chats"
    }
    private var currentTitle: String {
        let first = store.conversationMessages.first { $0.role == "You" }?.text ?? ""
        return first.isEmpty ? "Current conversation" : String(first.prefix(80))
    }
    private var deleteTitle: String {
        if case .project = pendingDelete { return "Delete this project?" }
        return "Delete this conversation?"
    }
    private var deleteButton: String {
        if case .project = pendingDelete { return "Delete project" }
        return "Delete conversation"
    }
    private var deleteMessage: String {
        if case .project = pendingDelete { return "Its chats stay in your list, just not in a project." }
        return "Deletes it from KemoSabe. Saved memories and copies kept by a model provider are separate."
    }
    private func row(_ title: String, detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(palette.accent).frame(width: 22).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).foregroundStyle(palette.foreground).lineLimit(2)
                Text(detail).font(KemoType.font(.caption)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 4).contentShape(Rectangle())
    }
}

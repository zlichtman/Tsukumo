import SwiftUI

/// Saved information and outputs are inspectable separately. Source excerpts
/// remain available on each draft, without a mandatory memory setup workflow.
/// Conversations live in the chat's side menu (ConversationSidebar). Docs and Journal
/// (`LibraryDocsViews`) sit beside Memories and Drafts; Kemo reads them only when attached in chat.
struct WorkspaceView: View {
    var embedded = false
    @Environment(AppStore.self) private var store
    @Environment(RoutineStore.self) private var routines
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mobilePalette) private var palette
    @State private var section = "Memories"
    @State private var search = ""
    @State private var editing: MemoryNote?
    @State private var deletingMemory: MemoryNote?
    @State private var deleting: WorkItem?
    @State private var showFormat = false
    /// Pages, journal days, and the Trash pushed from Docs and Journal.
    @State private var path: [DocRoute] = []
    static let sections = ["Memories", "Drafts", "Docs", "Journal", "Requests"]
    private var items: [WorkItem] { (store.state.workItems ?? []).filter { search.isEmpty || ($0.title + $0.draft).localizedCaseInsensitiveContains(search) } }
    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 12) {
                if embedded {
                    HStack {
                        Text("Library").font(KemoType.font(.title2, weight: .semibold))
                        Spacer()
                        sectionButtons
                    }.padding(.horizontal, 20).padding(.top, 12)
                }
                VStack(spacing: 10) {
                    Picker("Library", selection: $section) {
                        ForEach(Self.sections, id: \.self) { Text($0).tag($0) }
                    }.pickerStyle(.segmented).accessibilityIdentifier("librarySections")
                    ContentSearchField(prompt: "Search " + section.lowercased(), text: $search, identifier: "librarySearch")
                }.padding(.horizontal, 20)
                Group {
                    switch section {
                    case "Docs": DocsLibraryList(search: search) { path.append($0) }
                    case "Journal": JournalLibraryList(search: search) { path.append($0) }
                    // Agents' requests: who asked, what, and exactly what was sent (design/UI-GUIDE.md).
                    case "Requests":
                        ScrollView { AgentRequestTranscript(inbox: store.agentRequests, search: search).padding(.horizontal, 20).padding(.bottom, 24) }
                    default:
                        List {
                            if section == "Memories" { memories }
                            else { drafts }
                        }
                    }
                }.listStyle(.insetGrouped).scrollContentBackground(.hidden).background(palette.background)
                .navigationTitle(embedded ? "" : "Library").navigationBarTitleDisplayMode(.inline)
                .toolbar(embedded ? .hidden : .visible, for: .navigationBar)
                .onChange(of: section) { search = "" }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { if !embedded { Button(role: .close) { dismiss() } } }
                    ToolbarItem(placement: .primaryAction) {
                        if !embedded { sectionButtons }
                    }
                }
                .navigationDestination(for: DocRoute.self) { route in
                    switch route {
                    case .page(let id): DocPageScreen(pageID: id) { path.append($0) }
                    case .journalDay(let day): JournalDayScreen(day: day)
                    case .trash: DocsTrashScreen()
                    }
                }
                .sheet(item: $editing) { MemoryEditor(note: $0) }
                .sheet(isPresented: $showFormat) { formatSheet }
                .confirmationDialog("Forget this memory?", isPresented: Binding(get: { deletingMemory != nil }, set: { if !$0 { deletingMemory = nil } }), titleVisibility: .visible) {
                    Button("Forget memory", role: .destructive) { if let note = deletingMemory { store.deleteMemory(note.id) }; deletingMemory = nil }
                } message: { Text("Dependent learning is removed. Earlier conversation replies may still mention it.") }
                .confirmationDialog("Delete this draft?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                    Button("Delete", role: .destructive) { if let deleting { store.deleteWork(deleting.id) }; deleting = nil }
                }
        }.background(palette.background.ignoresSafeArea())  // themed behind the header, picker, and search too
            .task { await routines.refresh() }
            .onChange(of: store.proposalRevision) { Task { await routines.refresh() } }
        }
    }
    /// The header's buttons for the section shown.
    @ViewBuilder private var sectionButtons: some View {
        switch section {
        case "Memories": Button("Add memory", systemImage: "plus") { editing = MemoryNote(text: "") }.labelStyle(.iconOnly).frame(width: 36, height: 36).accessibilityIdentifier("addMemory")
        case "Docs": DocsHeaderButtons { path.append($0) }
        case "Journal": JournalHeaderButtons { path.append($0) }
        default: EmptyView()
        }
    }
    private var memories: some View {
        Section {
            let notes = store.state.memories.filter { search.isEmpty || ($0.text + $0.scope).localizedCaseInsensitiveContains(search) }
            if notes.isEmpty {
                ContentUnavailableView(search.isEmpty ? "No saved memories" : "No matching memories", systemImage: "square.stack", description: Text(search.isEmpty ? "Keep a useful detail about you. Tap + to add a memory." : "Try another word.")).listRowBackground(Color.clear)
            }
            ForEach(notes) { note in
                Button { editing = note } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: note.useInChat ? "text.quote" : "text.badge.minus").foregroundStyle(.secondary).frame(width: 24).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(note.text).foregroundStyle(.primary).lineLimit(3)
                            Text(note.scope + (note.useInChat ? " · Available locally" : " · Not used in chat")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }.padding(.vertical, 6)
                }.buttonStyle(.plain)
                    .swipeActions { Button("Forget", role: .destructive) { deletingMemory = note } }
                    .contextMenu { Button("Edit") { editing = note }; Button("Forget", role: .destructive) { deletingMemory = note } }
            }
        } header: { Text("Saved memories") } footer: {
            Label("Enabled memories stay on this device and help your Apple local model.", systemImage: "lock.shield").font(.caption)
        }
    }
    private var drafts: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Prepared for you").font(KemoType.font(.headline))
                Spacer()
                Menu {
                    Button("Standup format") { showFormat = true }
                    Button("Prepare standup draft") { store.draftStandup() }.disabled(!store.canChat || store.standupNotes(for: .appleOnDevice).isEmpty)
                } label: { Image(systemName: "ellipsis").frame(width: 32, height: 32) }.accessibilityLabel("Draft options")
            }
            let proposals = routines.state.proposals.reversed().filter { $0.origin != nil && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }
            if items.isEmpty && proposals.isEmpty { ContentUnavailableView("No drafts yet", systemImage: "doc.text", description: Text("Ask KemoSabe to draft something, then review it here. Nothing is posted automatically.")) }
            ForEach(proposals) { proposal in
                VStack(alignment: .leading, spacing: 12) {
                    ProposalCard(proposal: proposal)
                    if let origin = proposal.origin {
                        DisclosureGroup("Sources · \(origin.sources.count)") {
                            ForEach(origin.sources, id: \.id) { source in Text(source.scope + ": " + source.excerpt).font(KemoType.font(.caption)).foregroundStyle(.secondary).padding(.vertical, 4) }
                        }.font(KemoType.font(.caption))
                    }
                }.padding(16).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            }
            if store.working || store.isThinking { Button("Cancel draft") { store.cancel(); store.cancelStandup() } }
            ForEach(items.reversed()) { item in
                VStack(alignment: .leading, spacing: 12) {
                    Text(item.title).font(KemoType.font(.headline))
                    Text(item.status).font(KemoType.font(.caption)).foregroundStyle(.secondary)
                    if !item.draft.isEmpty {
                        Text(item.draft).textSelection(.enabled)
                        DisclosureGroup("Sources · \(item.sourceIDs.count)") {
                            ForEach(item.sourceNotes ?? [], id: \.id) { note in Text(note.scope + ": " + note.text).font(KemoType.font(.caption)).foregroundStyle(.secondary) }
                        }
                        if item.status == "Needs review" { Button("Mark reviewed") { store.markReviewed(item.id) } }
                    }
                    Button("Delete draft", role: .destructive) { deleting = item }.font(KemoType.font(.caption))
                }.padding(16).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            }
            if let error = routines.error ?? store.error { Text(error).font(KemoType.font(.caption)).foregroundStyle(.orange) }
            Text("Drafts keep their saved source excerpts. Delete a draft to remove those copies too.").font(KemoType.font(.caption)).foregroundStyle(.secondary)
        }
    }
    private var formatSheet: some View {
        @Bindable var store = store
        return NavigationStack {
            Form {
                Section("Standup format") {
                    TextField("How does your team do standup?", text: $store.state.standupFormat, axis: .vertical).lineLimit(3...6)
                        .onChange(of: store.state.standupFormat) { store.state.standupFormat = String(store.state.standupFormat.prefix(500)); store.save() }
                }
            }.navigationTitle("Draft preferences").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showFormat = false } } }
        }
    }
}

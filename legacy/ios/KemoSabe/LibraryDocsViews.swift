import SwiftUI
import UniformTypeIdentifiers

// Docs and Journal in the iPhone's Library, beside Memories and Drafts: lists in the Library's
// themed style, and pages, days, and the Trash pushed on its navigation stack.
// See design/DOCS-AND-JOURNAL.md.

enum DocRoute: Hashable {
    case page(UUID)
    case journalDay(String)
    case trash
}

/// Library → Docs: search, Favorites, Recent, the page tree, and the Trash.
struct DocsLibraryList: View {
    let search: String
    let open: (DocRoute) -> Void
    @State private var docs = DocsStore.shared
    @State private var moving: DocPage?
    @Environment(\.mobilePalette) private var palette
    var body: some View {
        List {
            if let error = docs.error { Section { Text(error).font(KemoType.font(.footnote)).foregroundStyle(.orange) } }
            if !search.isEmpty {
                let hits = docs.search(search)
                Section("Results") {
                    if hits.isEmpty { Text("No matching pages").foregroundStyle(.secondary) }
                    ForEach(hits) { hit in
                        Button { open(.page(hit.id)) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                if let page = docs.page(hit.id) { DocPageLabel(page: page).foregroundStyle(.primary) }
                                if let snippet = hit.snippet { Text(snippet).font(KemoType.font(.caption)).foregroundStyle(.secondary).lineLimit(2) }
                            }
                        }.accessibilityIdentifier("docResult-" + hit.title)
                    }
                }
            } else {
                if !docs.favorites.isEmpty {
                    Section("Favorites") { ForEach(docs.favorites) { row($0) } }
                }
                if docs.livePages.count > 4 {
                    Section("Recent") { ForEach(docs.recent) { row($0) } }
                }
                Section("Pages") {
                    if docs.livePages.isEmpty {
                        ContentUnavailableView("No pages yet", systemImage: "doc.text", description: Text("Tap + to start a page."))
                            .listRowBackground(Color.clear)
                    }
                    OutlineGroup(DocTreeItem.tree(docs), children: \.children) { item in row(item.page) }
                }
                Section {
                    Button { open(.trash) } label: {
                        HStack {
                            Label("Trash", systemImage: "trash").foregroundStyle(.primary)
                            Spacer()
                            if !docs.trash.isEmpty { Text("\(docs.trash.count)").foregroundStyle(.secondary) }
                        }
                    }.accessibilityIdentifier("docsTrash")
                }
            }
        }
        .sheet(item: $moving) { page in
            DocPagePicker(docs: docs, title: "Move to", excluding: DocOutline.descendants(of: page.id, in: docs.pages).union([page.id]), offersTopLevel: true) { parent in
                docs.move(page.id, to: parent)
            }
        }
        .onAppear { docs.reloadIfNeeded() }
    }
    private func row(_ page: DocPage) -> some View {
        Button { open(.page(page.id)) } label: {
            HStack {
                DocPageLabel(page: page).foregroundStyle(.primary)
                Spacer(minLength: 0)
                if page.favorite { Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(.tint) }
            }
        }
        .contextMenu {
            Button("Add sub-page", systemImage: "doc.badge.plus") { if let child = docs.createPage(parent: page.id) { open(.page(child.id)) } }
            Button(page.favorite ? "Remove from Favorites" : "Add to Favorites", systemImage: page.favorite ? "star.slash" : "star") { docs.toggleFavorite(page.id) }
            Button("Move to…", systemImage: "arrow.right.doc.on.clipboard") { moving = page }
            PrivacyLevelMenu(current: page.privacyLevel) { level in docs.updatePage(page.id) { $0.privacy = level } }
            Button("Move to Trash", systemImage: "trash", role: .destructive) { docs.moveToTrash(page.id) }
        }
        .swipeActions {
            Button("Trash", systemImage: "trash", role: .destructive) { docs.moveToTrash(page.id) }
            Button(page.favorite ? "Unfavorite" : "Favorite", systemImage: "star") { docs.toggleFavorite(page.id) }.tint(.orange)
        }
        .accessibilityIdentifier("docRow-" + page.displayTitle)
    }
}

/// One page, pushed from the Library, with the keyboard's format bar.
struct DocPageScreen: View {
    let pageID: UUID
    let open: (DocRoute) -> Void
    @State private var docs = DocsStore.shared
    @State private var model = DocEditorModel()
    @State private var moving = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mobilePalette) private var palette
    var body: some View {
        ScrollView {
            DocPageEditor(pageID: pageID, docs: docs, openPage: { open(.page($0)) }, model: model)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(palette.background.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if let page = docs.page(pageID), page.trashed == nil {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(page.favorite ? "Remove from Favorites" : "Add to Favorites", systemImage: page.favorite ? "star.fill" : "star") { docs.toggleFavorite(pageID) }
                        .accessibilityIdentifier("docFavorite")
                    ShareLink(item: DocMarkdownFile(name: page.displayTitle, markdown: docs.markdown(for: pageID) ?? ""), preview: SharePreview(page.displayTitle)) {
                        Image(systemName: "square.and.arrow.up")
                    }.accessibilityLabel("Export as Markdown").accessibilityIdentifier("docExport")
                    Menu {
                        Button("Add sub-page", systemImage: "doc.badge.plus") { if let child = docs.createPage(parent: pageID) { open(.page(child.id)) } }
                        Button("Move to…", systemImage: "arrow.right.doc.on.clipboard") { moving = true }
                        Button("Move to Trash", systemImage: "trash", role: .destructive) { docs.moveToTrash(pageID); dismiss() }
                    } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Page options").accessibilityIdentifier("docOptions")
                }
            }
            ToolbarItemGroup(placement: .keyboard) {
                if model.editing != nil {
                    ScrollView(.horizontal, showsIndicators: false) { DocFormatBar(blocks: blocksBinding, model: model, compact: true) }
                }
            }
        }
        .sheet(isPresented: $moving) {
            DocPagePicker(docs: docs, title: "Move to", excluding: DocOutline.descendants(of: pageID, in: docs.pages).union([pageID]), offersTopLevel: true) { parent in
                docs.move(pageID, to: parent)
            }
        }
        .onDisappear { docs.flush() }
    }
    private var blocksBinding: Binding<[DocBlock]> {
        Binding(get: { docs.page(pageID)?.blocks ?? [DocBlock()] }, set: { blocks in docs.updatePage(pageID) { $0.blocks = blocks } })
    }
}

/// Pages in the Trash: restore them, or delete them for good.
struct DocsTrashScreen: View {
    @State private var docs = DocsStore.shared
    @State private var deleting: DocPage?
    @State private var emptying = false
    @Environment(\.mobilePalette) private var palette
    var body: some View {
        List {
            if docs.trash.isEmpty {
                ContentUnavailableView("Trash is empty", systemImage: "trash").listRowBackground(Color.clear)
            }
            ForEach(docs.trash) { page in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        DocPageLabel(page: page)
                        if let trashed = page.trashed { Text("Deleted " + trashed.formatted(.relative(presentation: .named))).font(KemoType.font(.caption)).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button("Restore") { docs.restore(page.id) }.buttonStyle(.bordered).accessibilityIdentifier("docRestore-" + page.displayTitle)
                }
                .swipeActions { Button("Delete", role: .destructive) { deleting = page } }
                .contextMenu { Button("Delete Forever", systemImage: "trash", role: .destructive) { deleting = page } }
            }
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(palette.background.ignoresSafeArea())
        .navigationTitle("Trash").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar { if !docs.trash.isEmpty { Button("Empty Trash") { emptying = true }.accessibilityIdentifier("docsEmptyTrash") } }
        .confirmationDialog("Delete “\(deleting?.displayTitle ?? "")” forever?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete Forever", role: .destructive) { if let page = deleting { docs.deleteForever(page.id) }; deleting = nil }
        } message: { Text("It and its sub-pages are removed from all your devices. This can't be undone.") }
        .confirmationDialog("Empty the Trash?", isPresented: $emptying, titleVisibility: .visible) {
            Button("Delete All Forever", role: .destructive) { docs.emptyTrash() }
        } message: { Text("Every page in the Trash is removed from all your devices. This can't be undone.") }
    }
}

// MARK: Journal

/// Library → Journal: today, On this day, and a timeline or a month calendar.
struct JournalLibraryList: View {
    let search: String
    let open: (DocRoute) -> Void
    @State private var docs = DocsStore.shared
    @State private var lock = JournalLock.shared
    @AppStorage("kemo.journal.mode") private var mode = "Timeline"
    @State private var month: (year: Int, month: Int) = {
        let parts = JournalCalendar.components(JournalCalendar.dayKey(for: Date())) ?? (2026, 1, 1)
        return (parts.year, parts.month)
    }()
    private var today: String { JournalCalendar.dayKey(for: Date()) }
    var body: some View {
        List {
            if !lock.isOpen {
                JournalLockedView().listRowBackground(Color.clear)
            } else if !search.isEmpty {
                let entries = docs.searchJournal(search)
                Section("Results") {
                    if entries.isEmpty { Text("No matching entries").foregroundStyle(.secondary) }
                    ForEach(entries) { entry in
                        Button { open(.journalDay(entry.day)) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(JournalCalendar.title(for: entry.day, relativeTo: today)).font(KemoType.font(.caption, weight: .semibold)).foregroundStyle(.secondary)
                                JournalEntryRow(entry: entry, docs: docs)
                            }
                        }.buttonStyle(.plain)
                    }
                }
            } else {
                Section {
                    Picker("View", selection: $mode) {
                        Text("Timeline").tag("Timeline"); Text("Calendar").tag("Calendar")
                    }.pickerStyle(.segmented).accessibilityIdentifier("journalMode")
                    let todays = docs.entries(on: today)
                    Button { open(.journalDay(today)) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Today").font(KemoType.font(.headline)).foregroundStyle(.primary)
                                Spacer()
                                let streak = JournalCalendar.streak(docs.entries, today: today)
                                if streak >= 2 { Label("\(streak) days", systemImage: "flame").font(KemoType.font(.caption)).foregroundStyle(.secondary).accessibilityIdentifier("journalStreak") }
                            }
                            Text(todays.map(\.summary).first { !$0.isEmpty } ?? JournalPrompts.prompt(for: today))
                                .font(KemoType.font(.subheadline)).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }.accessibilityIdentifier("journalTodayRow")
                }
                let past = JournalCalendar.onThisDay(docs.entries, today: today)
                if !past.isEmpty { Section { JournalOnThisDay(groups: past) { open(.journalDay($0)) } } }
                if mode == "Calendar" {
                    Section {
                        JournalMonthView(month: $month, days: docs.daysWithEntries, selected: nil, today: today) { open(.journalDay($0)) }
                    }
                } else {
                    let groups = JournalCalendar.grouped(docs.entries.filter { !$0.isEmpty })
                    if groups.isEmpty {
                        ContentUnavailableView("No entries yet", systemImage: "book.closed", description: Text("Tap Today to start."))
                            .listRowBackground(Color.clear)
                    }
                    ForEach(groups, id: \.day) { group in
                        Section(JournalCalendar.title(for: group.day, relativeTo: today)) {
                            ForEach(group.entries) { entry in
                                Button { open(.journalDay(entry.day)) } label: { JournalEntryRow(entry: entry, docs: docs) }
                                    .buttonStyle(.plain).accessibilityIdentifier("journalEntryRow-" + entry.day)
                            }
                        }
                    }
                }
            }
        }
        .onAppear { docs.reloadIfNeeded() }
    }
}

/// One day of the journal, with the day before and after a tap (or a swipe) away.
struct JournalDayScreen: View {
    @State var day: String
    @State private var docs = DocsStore.shared
    @State private var lock = JournalLock.shared
    @State private var started: UUID?
    @Environment(\.mobilePalette) private var palette
    private var today: String { JournalCalendar.dayKey(for: Date()) }
    var body: some View {
        ScrollView {
            if !lock.isOpen {
                JournalLockedView()
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Button { day = JournalCalendar.shift(day, by: -1) } label: { Image(systemName: "chevron.left").frame(width: 36, height: 36) }
                            .accessibilityLabel("Previous day").accessibilityIdentifier("journalPrevDay")
                        Spacer()
                        Text(JournalCalendar.title(for: day, relativeTo: today)).font(KemoType.font(.title3, weight: .semibold))
                            .accessibilityIdentifier("journalDayTitle").accessibilityValue(day)
                        Spacer()
                        Button { day = JournalCalendar.shift(day, by: 1) } label: { Image(systemName: "chevron.right").frame(width: 36, height: 36) }
                            .disabled(day >= today).accessibilityLabel("Next day").accessibilityIdentifier("journalNextDay")
                    }.buttonStyle(.plain)
                    let entries = docs.entries(on: day)
                    if entries.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(JournalPrompts.prompt(for: day)).font(KemoType.font(.title3)).foregroundStyle(.secondary)
                            Button("Start writing", systemImage: "square.and.pencil") { started = docs.createEntry(on: day)?.id }
                                .buttonStyle(.borderedProminent).accessibilityIdentifier("journalWrite")
                        }.padding(.top, 20)
                    }
                    ForEach(entries) { entry in
                        JournalEntryEditor(entryID: entry.id, docs: docs, autofocus: entry.id == started)
                        if entry.id != entries.last?.id { Divider() }
                    }
                    if !entries.isEmpty {
                        Button("Add another entry", systemImage: "plus") { started = docs.createEntry(on: day)?.id }
                            .font(KemoType.font(.footnote)).foregroundStyle(.secondary).buttonStyle(.plain).accessibilityIdentifier("journalAddEntry")
                    }
                }.padding(.horizontal, 24).padding(.vertical, 20)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .simultaneousGesture(DragGesture(minimumDistance: 60).onEnded { value in
            guard abs(value.translation.width) > abs(value.translation.height) * 2 else { return }
            if value.translation.width < 0, day < today { day = JournalCalendar.shift(day, by: 1) }
            else if value.translation.width > 0 { day = JournalCalendar.shift(day, by: -1) }
        })
        .background(palette.background.ignoresSafeArea())
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .onDisappear { docs.flush() }
    }
}

/// The Library header's buttons for Docs: import a file, and a new page.
struct DocsHeaderButtons: View {
    let open: (DocRoute) -> Void
    @State private var docs = DocsStore.shared
    @State private var importing = false
    var body: some View {
        HStack(spacing: 4) {
            Button("Import", systemImage: "square.and.arrow.down") { importing = true }.labelStyle(.iconOnly).frame(width: 36, height: 36)
                .accessibilityIdentifier("importDocs")
            Button("New page", systemImage: "plus") { if let page = docs.createPage() { open(.page(page.id)) } }.labelStyle(.iconOnly).frame(width: 36, height: 36)
                .accessibilityIdentifier("newDocPage")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.markdownDocument, .plainText, .text], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            var last: DocPage?
            for url in urls {
                do { last = try docs.importFile(url) } catch { docs.error = error.localizedDescription }
            }
            if urls.count == 1, let last { open(.page(last.id)) }
        }
    }
}

/// The Library header's buttons for Journal: its options and today's page.
struct JournalHeaderButtons: View {
    let open: (DocRoute) -> Void
    @State private var lock = JournalLock.shared
    @AppStorage("kemo.journal.prompts") private var showPrompts = true
    var body: some View {
        HStack(spacing: 4) {
            Menu {
                Toggle("Lock with \(lock.method)", isOn: Binding(get: { lock.enabled }, set: { on in Task { await lock.setEnabled(on) } }))
                    .accessibilityIdentifier("journalLockToggle")
                Toggle("Show prompts", isOn: $showPrompts)
            } label: { Image(systemName: "ellipsis").frame(width: 36, height: 36) }
                .accessibilityLabel("Journal options").accessibilityIdentifier("journalOptions")
            Button("Today", systemImage: "square.and.pencil") { open(.journalDay(JournalCalendar.dayKey(for: Date()))) }
                .labelStyle(.iconOnly).frame(width: 36, height: 36).accessibilityIdentifier("journalToday")
        }
    }
}

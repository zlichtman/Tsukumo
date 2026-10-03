import SwiftUI
import UniformTypeIdentifiers

// Library → Docs and Journal on the Mac: two panes, the page tree (or the journal's calendar and
// timeline) on the left and the editor on the right. The editor, the pages, and the entries are
// the iPhone's (`DocPageEditor`, `JournalEntryEditor`, `DocsStore`). See design/DOCS-AND-JOURNAL.md.

enum DocsSelection: Hashable {
    case page(UUID)
    case trash
}

struct DesktopDocsLibrary: View {
    @Binding var section: String
    @State private var docs = DocsStore.shared
    @State private var lock = JournalLock.shared
    @State private var selection: DocsSelection?
    @State private var day = JournalCalendar.dayKey(for: Date())
    @State private var query = ""
    @State private var importing = false
    @State private var moving: DocPage?
    /// Pages whose sub-pages are showing in the sidebar.
    @State private var expanded = Set<UUID>()
    @AppStorage("kemo.journal.prompts") private var showPrompts = true
    @State private var month: (year: Int, month: Int) = {
        let parts = JournalCalendar.components(JournalCalendar.dayKey(for: Date())) ?? (2026, 1, 1)
        return (parts.year, parts.month)
    }()
    private var today: String { JournalCalendar.dayKey(for: Date()) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Library").font(.system(size: 26, weight: .semibold))
                QuietSegmented(options: DesktopLibraryPage.sections, selection: $section).accessibilityIdentifier("librarySections")
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("Search \(section.lowercased())", text: $query).textFieldStyle(.plain).frame(width: 200).accessibilityIdentifier("librarySearch")
                }.padding(.horizontal, 10).padding(.vertical, 6).background(Color.primary.opacity(0.06), in: Capsule())
            }
            .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 14)
            Divider().opacity(0.6)
            HStack(spacing: 0) {
                Group { if section == "Docs" { docsSidebar } else { journalSidebar } }
                    .frame(width: 270)
                Divider().opacity(0.6)
                Group { if section == "Docs" { docsDetail } else { journalDetail } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: section) { query = "" }
        .onAppear {
            docs.reloadIfNeeded()
            if selection == nil, let first = docs.favorites.first ?? docs.recent.first { selection = .page(first.id) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.markdownDocument, .plainText, .text], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                do { let page = try docs.importFile(url); selection = .page(page.id) } catch { docs.error = error.localizedDescription }
            }
        }
        .sheet(item: $moving) { page in
            DocPagePicker(docs: docs, title: "Move to", excluding: DocOutline.descendants(of: page.id, in: docs.pages).union([page.id]), offersTopLevel: true) { parent in
                docs.move(page.id, to: parent)
            }
        }
    }

    // MARK: Docs

    private var docsSidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button { if let page = docs.createPage() { selection = .page(page.id) } } label: { Label("New page", systemImage: "square.and.pencil") }
                    .buttonStyle(DesktopRowButtonStyle(inset: 6)).accessibilityIdentifier("newDocPage")
                Spacer()
                Button { importing = true } label: { Image(systemName: "square.and.arrow.down") }
                    .buttonStyle(DesktopRowButtonStyle(inset: 6)).help("Import Markdown or text").accessibilityIdentifier("importDocs")
            }.font(.system(size: 13)).padding(.horizontal, 12).padding(.vertical, 8)
            // Rows in the sidebar's own style (DesktopRowButtonStyle), as in the main window.
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if let error = docs.error { Text(error).font(.caption).foregroundStyle(.orange).padding(.horizontal, 8) }
                    if !query.isEmpty {
                        heading("Results")
                        let hits = docs.search(query)
                        if hits.isEmpty { Text("No matching pages").font(.system(size: 13)).foregroundStyle(.tertiary).padding(.horizontal, 8) }
                        ForEach(hits) { hit in
                            if let page = docs.page(hit.id) { row(page, snippet: hit.snippet) }
                        }
                    } else {
                        if !docs.favorites.isEmpty {
                            heading("Favorites")
                            ForEach(docs.favorites) { row($0) }
                        }
                        if docs.livePages.count > 4 {
                            heading("Recent")
                            ForEach(docs.recent) { row($0) }
                        }
                        heading("Pages")
                        if docs.livePages.isEmpty { Text("No pages yet").font(.system(size: 13)).foregroundStyle(.tertiary).padding(.horizontal, 8) }
                        ForEach(docs.rootPages) { tree($0, depth: 0) }
                        Button { selection = .trash } label: {
                            Label("Trash" + (docs.trash.isEmpty ? "" : " (\(docs.trash.count))"), systemImage: "trash")
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 6)
                        }.buttonStyle(DesktopRowButtonStyle(selected: selection == .trash)).padding(.top, 10)
                            .accessibilityIdentifier("docsTrash")
                    }
                }.font(.system(size: 13)).padding(.horizontal, 10).padding(.bottom, 16)
            }
        }
    }
    private func heading(_ title: String) -> some View {
        Text(title).font(.system(size: 13)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 4)
    }
    /// A page and, when it's open, its sub-pages.
    private func tree(_ page: DocPage, depth: Int) -> AnyView {
        let children = depth < 12 ? docs.children(of: page.id) : []
        return AnyView(VStack(alignment: .leading, spacing: 1) {
            row(page, depth: depth, children: !children.isEmpty)
            if expanded.contains(page.id) { ForEach(children) { tree($0, depth: depth + 1) } }
        })
    }
    private func row(_ page: DocPage, depth: Int = 0, children: Bool = false, snippet: String? = nil) -> some View {
        Button { selection = .page(page.id) } label: {
            HStack(spacing: 4) {
                if children {
                    Button { if expanded.contains(page.id) { expanded.remove(page.id) } else { expanded.insert(page.id) } } label: {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(expanded.contains(page.id) ? 90 : 0)).frame(width: 14, height: 14)
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel(expanded.contains(page.id) ? "Hide sub-pages" : "Show sub-pages")
                } else { Color.clear.frame(width: 14, height: 14) }
                VStack(alignment: .leading, spacing: 2) {
                    DocPageLabel(page: page)
                    if let snippet { Text(snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer(minLength: 0)
                if page.favorite { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.tint) }
            }
            .padding(.leading, CGFloat(depth) * 14).padding(.horizontal, 6).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(DesktopRowButtonStyle(selected: selection == .page(page.id)))
        .contextMenu {
            Button("Add sub-page") { if let child = docs.createPage(parent: page.id) { expanded.insert(page.id); selection = .page(child.id) } }
            Button(page.favorite ? "Remove from Favorites" : "Add to Favorites") { docs.toggleFavorite(page.id) }
            Button("Move to…") { moving = page }
            PrivacyLevelMenu(current: page.privacyLevel) { level in docs.updatePage(page.id) { $0.privacy = level } }
            Divider()
            Button("Move to Trash", role: .destructive) { docs.moveToTrash(page.id); if selection == .page(page.id) { selection = nil } }
        }
        .accessibilityIdentifier("docRow-" + page.displayTitle)
    }
    @ViewBuilder private var docsDetail: some View {
        switch selection {
        case .page(let id) where docs.page(id) != nil:
            DesktopDocPageDetail(pageID: id, docs: docs, open: { selection = .page($0) }, move: { moving = docs.page(id) },
                                 trash: { docs.moveToTrash(id); selection = nil })
                .id(id)
        case .trash: DesktopDocsTrash(docs: docs) { selection = .page($0) }
        default:
            VStack(spacing: 10) {
                Image(systemName: "doc.text").font(.system(size: 30)).foregroundStyle(.secondary)
                Text(docs.livePages.isEmpty ? "No pages yet" : "Choose a page").font(.system(size: 15, weight: .semibold))
                Button("New page") { if let page = docs.createPage() { selection = .page(page.id) } }.buttonStyle(.borderedProminent)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Journal

    private var journalSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Button { day = today } label: { Label("Today", systemImage: "square.and.pencil") }
                        .buttonStyle(DesktopRowButtonStyle(inset: 6)).accessibilityIdentifier("journalToday")
                    Spacer()
                    let streak = JournalCalendar.streak(docs.entries, today: today)
                    if streak >= 2 { Label("\(streak) days", systemImage: "flame").font(.caption).foregroundStyle(.secondary) }
                    Menu {
                        Toggle("Lock with \(lock.method)", isOn: Binding(get: { lock.enabled }, set: { on in Task { await lock.setEnabled(on) } }))
                        Toggle("Show prompts", isOn: $showPrompts)
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel("Journal options")
                }.font(.system(size: 13))
                if lock.isOpen {
                    JournalMonthView(month: $month, days: docs.daysWithEntries, selected: day, today: today) { day = $0 }
                    let past = JournalCalendar.onThisDay(docs.entries, today: today)
                    if !past.isEmpty { JournalOnThisDay(groups: past) { day = $0 } }
                    VStack(alignment: .leading, spacing: 10) {
                        let entries = query.isEmpty ? docs.journal.filter { !$0.isEmpty } : docs.searchJournal(query)
                        Text(query.isEmpty ? "Timeline" : "Results").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                        if entries.isEmpty { Text(query.isEmpty ? "No entries yet" : "No matching entries").font(.callout).foregroundStyle(.tertiary) }
                        ForEach(entries.prefix(60)) { entry in
                            Button { day = entry.day } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(JournalCalendar.title(for: entry.day, relativeTo: today)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    JournalEntryRow(entry: entry, docs: docs)
                                }.padding(8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(DesktopRowButtonStyle(selected: entry.day == day))
                        }
                    }
                }
            }.padding(16)
        }
    }
    @ViewBuilder private var journalDetail: some View {
        if !lock.isOpen { JournalLockedView() } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Button { day = JournalCalendar.shift(day, by: -1) } label: { Image(systemName: "chevron.left") }
                            .buttonStyle(DesktopRowButtonStyle(inset: 6)).help("Previous day").accessibilityIdentifier("journalPrevDay")
                        Text(JournalCalendar.title(for: day, relativeTo: today)).font(.system(size: 22, weight: .semibold))
                            .accessibilityIdentifier("journalDayTitle")
                        Button { day = JournalCalendar.shift(day, by: 1) } label: { Image(systemName: "chevron.right") }
                            .buttonStyle(DesktopRowButtonStyle(inset: 6)).disabled(day >= today).help("Next day").accessibilityIdentifier("journalNextDay")
                        Spacer()
                    }
                    let entries = docs.entries(on: day)
                    if entries.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(JournalPrompts.prompt(for: day)).font(.system(size: 17)).foregroundStyle(.secondary)
                            Button("Start writing") { _ = docs.createEntry(on: day) }.buttonStyle(.borderedProminent).accessibilityIdentifier("journalWrite")
                        }
                    }
                    ForEach(entries) { entry in
                        JournalEntryEditor(entryID: entry.id, docs: docs)
                        if entry.id != entries.last?.id { Divider() }
                    }
                    if !entries.isEmpty {
                        Button("Add another entry", systemImage: "plus") { _ = docs.createEntry(on: day) }
                            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityIdentifier("journalAddEntry")
                    }
                }
                .padding(.horizontal, 48).padding(.vertical, 28).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity)
            }
            .onDisappear { docs.flush() }
        }
    }
}

/// One page on the Mac: the format bar and the page's actions above the page.
struct DesktopDocPageDetail: View {
    let pageID: UUID
    let docs: DocsStore
    let open: (UUID) -> Void
    let move: () -> Void
    let trash: () -> Void
    @State private var model = DocEditorModel()
    var body: some View {
        VStack(spacing: 0) {
            if let page = docs.page(pageID) {
                HStack(spacing: 10) {
                    DocFormatBar(blocks: blocksBinding, model: model)
                    Spacer()
                    Button { docs.toggleFavorite(pageID) } label: { Image(systemName: page.favorite ? "star.fill" : "star") }
                        .buttonStyle(DesktopRowButtonStyle(inset: 6)).help(page.favorite ? "Remove from Favorites" : "Add to Favorites").accessibilityIdentifier("docFavorite")
                    ShareLink(item: DocMarkdownFile(name: page.displayTitle, markdown: docs.markdown(for: pageID) ?? ""), preview: SharePreview(page.displayTitle)) {
                        Image(systemName: "square.and.arrow.up")
                    }.buttonStyle(DesktopRowButtonStyle(inset: 6)).help("Export as Markdown").accessibilityIdentifier("docExport")
                    Menu {
                        Button("Add sub-page") { if let child = docs.createPage(parent: pageID) { open(child.id) } }
                        Button("Move to…") { move() }
                        Divider()
                        Button("Move to Trash", role: .destructive) { trash() }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel("Page options")
                }
                .font(.system(size: 13)).padding(.horizontal, 16).padding(.vertical, 6)
                .disabled(page.trashed != nil)
                Divider().opacity(0.5)
            }
            ScrollView {
                DocPageEditor(pageID: pageID, docs: docs, openPage: open, model: model).padding(.bottom, 40)
            }
        }
        .onDisappear { docs.flush() }
    }
    private var blocksBinding: Binding<[DocBlock]> {
        Binding(get: { docs.page(pageID)?.blocks ?? [DocBlock()] }, set: { blocks in docs.updatePage(pageID) { $0.blocks = blocks } })
    }
}

/// The Trash on the Mac.
struct DesktopDocsTrash: View {
    let docs: DocsStore
    let open: (UUID) -> Void
    @State private var deleting: DocPage?
    @State private var emptying = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Trash").font(.system(size: 22, weight: .semibold))
                    Spacer()
                    if !docs.trash.isEmpty { Button("Empty Trash") { emptying = true }.accessibilityIdentifier("docsEmptyTrash") }
                }
                if docs.trash.isEmpty { Text("Trash is empty").foregroundStyle(.secondary).padding(.top, 20) }
                ForEach(docs.trash) { page in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            DocPageLabel(page: page)
                            if let trashed = page.trashed { Text("Deleted " + trashed.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button("Restore") { docs.restore(page.id); open(page.id) }
                        Button("Delete Forever", role: .destructive) { deleting = page }
                    }
                    .padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }.padding(.horizontal, 48).padding(.vertical, 28).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity)
        }
        .confirmationDialog("Delete “\(deleting?.displayTitle ?? "")” forever?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete Forever", role: .destructive) { if let page = deleting { docs.deleteForever(page.id) }; deleting = nil }
        } message: { Text("It and its sub-pages are removed from all your devices. This can't be undone.") }
        .confirmationDialog("Empty the Trash?", isPresented: $emptying, titleVisibility: .visible) {
            Button("Delete All Forever", role: .destructive) { docs.emptyTrash() }
        } message: { Text("Every page in the Trash is removed from all your devices. This can't be undone.") }
    }
}

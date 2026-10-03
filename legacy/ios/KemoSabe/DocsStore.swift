import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

/// Docs and Journal for the open account, in its folder (`AccountDirectory`): one file per page
/// (`Docs/pages/ID.json`) and per entry (`Docs/journal/ID.json`), and images as files beside them
/// (`Docs/assets`), all with complete file protection. Nothing here is model context: Kemo sees a
/// page or an entry only when the person attaches it to a message (`ChatDocAttachment`).
///
/// A file that can't be read (a locked device, damage) keeps the whole store read-only and out of
/// sync until it opens, so nothing is overwritten and nothing looks deleted to other devices.
@MainActor @Observable final class DocsStore {
    /// The open account's docs; replaced when the account changes while the app runs.
    private(set) static var shared = DocsStore(folder: defaultFolder)
    static func reopen() { shared.close(); shared = DocsStore(folder: defaultFolder) }
    static var defaultFolder: URL {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing"), arguments.contains("--isolated-fixture") || arguments.contains("--planner-fixture") {
            return FileManager.default.temporaryDirectory.appendingPathComponent("DocsUITests/\(UUID().uuidString)", isDirectory: true)
        }
        #endif
        return AccountDirectory.currentFolder.appendingPathComponent("Docs", isDirectory: true)
    }

    private(set) var pages: [DocPage] = []
    private(set) var entries: [JournalEntry] = []
    private(set) var loadFailed = false
    var error: String?
    @ObservationIgnored let folder: URL
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var dirtyPages = Set<UUID>()
    @ObservationIgnored private var dirtyEntries = Set<UUID>()
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    /// Called after changes reach disk, so account sync can follow (set by the app).
    @ObservationIgnored var onSaved: (() -> Void)?
    /// How long edits wait before they're written, so typing writes once per pause.
    @ObservationIgnored var saveDelay: Duration = .milliseconds(600)

    init(folder: URL) {
        self.folder = folder
        load()
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing"), arguments.contains("--docs-sample"), folder.path.contains("DocsUITests") { seedSample() }
        #endif
    }

    var pagesFolder: URL { folder.appendingPathComponent("pages", isDirectory: true) }
    var journalFolder: URL { folder.appendingPathComponent("journal", isDirectory: true) }
    var assetsFolder: URL { folder.appendingPathComponent("assets", isDirectory: true) }
    func assetURL(_ name: String) -> URL { assetsFolder.appendingPathComponent(name) }
    /// Whether sync may read and apply the store: it's open and every file was read.
    var syncable: Bool { !closed && !loadFailed }
    var canEdit: Bool { !closed && !loadFailed }

    // MARK: Loading and saving

    func load() {
        var loadedPages: [DocPage] = [], loadedEntries: [JournalEntry] = []
        do {
            loadedPages = try Self.readAll(DocPage.self, in: pagesFolder)
            loadedEntries = try Self.readAll(JournalEntry.self, in: journalFolder)
            pages = loadedPages; entries = loadedEntries
            loadFailed = false; error = nil
        } catch {
            loadFailed = true
            self.error = "Your docs couldn't be opened. They haven't been changed, and editing is paused until they open."
        }
    }
    /// Tries again after a failed load (for example once the device is unlocked).
    func reloadIfNeeded() { if loadFailed, !closed { load() } }
    private static func readAll<T: Decodable & Identifiable>(_ type: T.Type, in folder: URL) throws -> [T] where T.ID == UUID {
        let files = FileManager.default
        guard files.fileExists(atPath: folder.path) else { return [] }
        let names = try files.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".json") }
        return try names.compactMap { name in
            guard let id = UUID(uuidString: String(name.dropLast(5))) else { return nil }
            let value = try JSONDecoder().decode(T.self, from: Data(contentsOf: folder.appendingPathComponent(name)))
            return value.id == id ? value : nil
        }
    }
    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        guard !closed else { throw AccountDirectory.WriteRefused() }
        try AccountDirectory.checkWrite(to: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.protectedWrite(SyncEngine.encode(value), to: url)
    }
    /// Writes with complete file protection. A Mac folder that can't take a protection class (a
    /// temporary folder, for one) gets a plain atomic write; FileVault still encrypts the disk.
    nonisolated static func protectedWrite(_ data: Data, to url: URL) throws {
        do { try data.write(to: url, options: [.atomic, .completeFileProtection]) }
        catch {
            #if os(macOS)
            try data.write(to: url, options: .atomic)
            #else
            throw error
            #endif
        }
    }
    private func pageURL(_ id: UUID) -> URL { pagesFolder.appendingPathComponent(id.uuidString + ".json") }
    private func entryURL(_ id: UUID) -> URL { journalFolder.appendingPathComponent(id.uuidString + ".json") }
    private func scheduleFlush() {
        flushTask?.cancel()
        let delay = saveDelay
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }
    /// Writes every pending change now.
    func flush() {
        flushTask?.cancel(); flushTask = nil
        guard canEdit, !dirtyPages.isEmpty || !dirtyEntries.isEmpty else { return }
        var failed = false
        for id in dirtyPages {
            guard let page = pages.first(where: { $0.id == id }) else { dirtyPages.remove(id); continue }
            do { try write(page, to: pageURL(id)); dirtyPages.remove(id) } catch { failed = true }
        }
        for id in dirtyEntries {
            guard let entry = entries.first(where: { $0.id == id }) else { dirtyEntries.remove(id); continue }
            do { try write(entry, to: entryURL(id)); dirtyEntries.remove(id) } catch { failed = true }
        }
        error = failed ? "Some changes couldn't be saved yet. They'll be saved when you edit again." : nil
        onSaved?()
    }
    /// Before an account switch: writes what's pending, then stops writing.
    func close() {
        flush()
        closed = true
    }

    // MARK: Pages

    func page(_ id: UUID?) -> DocPage? { id.flatMap { id in pages.first { $0.id == id } } }
    var livePages: [DocPage] { pages.filter { $0.trashed == nil } }
    func children(of parent: UUID?) -> [DocPage] { DocOutline.children(of: parent, in: pages) }
    /// Top-level pages, and any whose parent isn't here (deleted on another device, say), so no page is ever out of reach.
    var rootPages: [DocPage] {
        let live = Set(livePages.map(\.id))
        return livePages.filter { page in page.parentID.map { !live.contains($0) } ?? true }.sorted { ($0.order, $0.created) < ($1.order, $1.created) }
    }
    var favorites: [DocPage] { livePages.filter(\.favorite).sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending } }
    /// Recently edited pages.
    var recent: [DocPage] { Array(livePages.sorted { $0.modified > $1.modified }.prefix(5)) }
    var trash: [DocPage] { DocOutline.trashRoots(pages) }
    func title(_ id: UUID) -> String? { page(id)?.displayTitle }

    @discardableResult func createPage(parent: UUID? = nil, title: String = "", blocks: [DocBlock]? = nil, now: Date = Date()) -> DocPage? {
        guard canEdit else { return nil }
        let parent = parent.flatMap { id in page(id)?.trashed == nil ? id : nil }
        var page = DocPage(parentID: parent, title: String(title.prefix(DocPage.maxTitle)), blocks: blocks ?? [DocBlock()], now: now)
        page.order = (children(of: parent).map(\.order).max() ?? 0) + 1
        pages.append(page)
        mark(page: page.id)
        flush()
        return page
    }
    /// Changes a page and saves it shortly after (typing writes once per pause).
    func updatePage(_ id: UUID, now: Date = Date(), _ change: (inout DocPage) -> Void) {
        guard canEdit, let index = pages.firstIndex(where: { $0.id == id }) else { return }
        var page = pages[index]
        change(&page)
        page.title = String(page.title.prefix(DocPage.maxTitle))
        if page.blocks.isEmpty { page.blocks = [DocBlock()] }
        if page.blocks.count > DocPage.maxBlocks { page.blocks = Array(page.blocks.prefix(DocPage.maxBlocks)) }
        guard page != pages[index] else { return }
        page.modified = now
        pages[index] = page
        mark(page: id)
    }
    private func mark(page id: UUID) { dirtyPages.insert(id); scheduleFlush() }
    private func mark(entry id: UUID) { dirtyEntries.insert(id); scheduleFlush() }
    func toggleFavorite(_ id: UUID) { updatePage(id) { $0.favorite.toggle() } }
    @discardableResult func move(_ id: UUID, to parent: UUID?) -> Bool {
        guard canEdit else { return false }
        var next = pages
        guard DocOutline.move(id, to: parent, in: &next) else { return false }
        pages = next; mark(page: id); flush()
        return true
    }
    func moveToTrash(_ id: UUID, now: Date = Date()) {
        guard canEdit else { return }
        let before = pages
        DocOutline.trash(id, in: &pages, now: now)
        for (old, new) in zip(before, pages) where old != new { dirtyPages.insert(new.id) }
        flush()
    }
    func restore(_ id: UUID, now: Date = Date()) {
        guard canEdit else { return }
        let before = pages
        DocOutline.restore(id, in: &pages, now: now)
        for (old, new) in zip(before, pages) where old != new { dirtyPages.insert(new.id) }
        flush()
    }
    /// Deletes a page from the Trash for good, with its sub-pages and the images only they used.
    func deleteForever(_ id: UUID) {
        guard canEdit else { return }
        let removed = DocOutline.deletion(id, in: pages)
        let images = Set(pages.filter { removed.contains($0.id) }.flatMap(Self.images(in:)))
        pages.removeAll { removed.contains($0.id) }
        for id in removed { dirtyPages.remove(id); try? FileManager.default.removeItem(at: pageURL(id)) }
        removeUnused(images)
        onSaved?()
    }
    func emptyTrash() { for root in trash { deleteForever(root.id) } }

    // MARK: Search

    struct SearchHit: Identifiable, Equatable {
        let id: UUID
        let title: String
        let snippet: String?
        let icon: DocIcon?
    }
    /// Pages whose title or text contains the query, title matches first.
    func search(_ query: String) -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var titled: [SearchHit] = [], texted: [SearchHit] = []
        for page in livePages.sorted(by: { $0.modified > $1.modified }) {
            if page.displayTitle.localizedCaseInsensitiveContains(q) { titled.append(.init(id: page.id, title: page.displayTitle, snippet: Self.snippet(page.plainText, q), icon: page.icon)) }
            else if let snippet = Self.snippet(page.plainText, q) { texted.append(.init(id: page.id, title: page.displayTitle, snippet: snippet, icon: page.icon)) }
        }
        return titled + texted
    }
    func searchJournal(_ query: String) -> [JournalEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return entries.filter { $0.plainText.localizedCaseInsensitiveContains(q) || $0.tags.contains { $0.localizedCaseInsensitiveContains(q) } }
            .sorted { $0.created > $1.created }
    }
    /// A line around the first match.
    static func snippet(_ text: String, _ query: String) -> String? {
        guard let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        let start = text.index(range.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 80, limitedBy: text.endIndex) ?? text.endIndex
        let line = text[start..<end].replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return (start > text.startIndex ? "…" : "") + line + (end < text.endIndex ? "…" : "")
    }

    // MARK: Journal

    /// Every entry, newest first.
    var journal: [JournalEntry] { entries.sorted { $0.created > $1.created } }
    func entry(_ id: UUID?) -> JournalEntry? { id.flatMap { id in entries.first { $0.id == id } } }
    func entries(on day: String) -> [JournalEntry] { entries.filter { $0.day == day }.sorted { $0.created < $1.created } }
    var daysWithEntries: Set<String> { Set(entries.map(\.day)) }
    /// Starts an entry on a day (today by default). A past day's entry is dated at noon that day.
    @discardableResult func createEntry(on day: String? = nil, now: Date = Date(), zone: TimeZone = .current) -> JournalEntry? {
        guard canEdit else { return nil }
        let today = JournalCalendar.dayKey(for: now, in: zone)
        let key = day ?? today
        var created = now
        if key != today, let start = JournalCalendar.date(for: key, in: zone) { created = start.addingTimeInterval(12 * 3600) }
        let entry = JournalEntry(created: created, timeZone: zone, day: key)
        entries.append(entry)
        mark(entry: entry.id); flush()
        return entry
    }
    func updateEntry(_ id: UUID, now: Date = Date(), _ change: (inout JournalEntry) -> Void) {
        guard canEdit, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var entry = entries[index]
        change(&entry)
        entry.tags = Array(NSOrderedSet(array: entry.tags.compactMap(JournalEntry.cleanTag)).array.compactMap { $0 as? String }.prefix(JournalEntry.maxTags))
        entry.photos = Array(entry.photos.prefix(JournalEntry.maxPhotos))
        if entry.blocks.isEmpty { entry.blocks = [DocBlock()] }
        guard entry != entries[index] else { return }
        entry.modified = now
        entries[index] = entry
        mark(entry: id)
    }
    func deleteEntry(_ id: UUID) {
        guard canEdit, let entry = entry(id) else { return }
        entries.removeAll { $0.id == id }
        dirtyEntries.remove(id)
        try? FileManager.default.removeItem(at: entryURL(id))
        removeUnused(Set(entry.photos.map(\.file) + entry.blocks.compactMap { $0.image?.file }))
        onSaved?()
    }

    // MARK: Images

    /// Adds a photo as a JPEG of at most 2048 pixels, without its metadata (location, camera).
    func addImage(_ data: Data) throws -> DocImageRef {
        guard canEdit else { throw DocsError.unavailable }
        let prepared = try Self.prepareImage(data)
        let name = "img-" + UUID().uuidString + ".jpg"
        let url = assetURL(name)
        try AccountDirectory.checkWrite(to: url)
        try FileManager.default.createDirectory(at: assetsFolder, withIntermediateDirectories: true)
        try Self.protectedWrite(prepared.jpeg, to: url)
        return DocImageRef(file: name, width: prepared.width, height: prepared.height)
    }
    struct PreparedImage: Sendable { let jpeg: Data; let width: Int; let height: Int }
    nonisolated static func prepareImage(_ data: Data, maxSide: Int = 2048) throws -> PreparedImage {
        guard data.count <= 40_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) >= 1,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxSide] as CFDictionary) else { throw DocsError.unreadableImage }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw DocsError.unreadableImage }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw DocsError.unreadableImage }
        return PreparedImage(jpeg: output as Data, width: image.width, height: image.height)
    }
    private static func images(in page: DocPage) -> [String] {
        page.blocks.compactMap { $0.image?.file } + (page.cover?.kind == .image ? [page.cover!.value] : [])
    }
    /// Every image a page or entry still uses.
    var referencedImages: Set<String> {
        Set(pages.flatMap(Self.images(in:)) + entries.flatMap { $0.photos.map(\.file) + $0.blocks.compactMap { $0.image?.file } })
    }
    /// Removes images nothing uses any more.
    private func removeUnused(_ candidates: Set<String>) {
        let used = referencedImages
        for name in candidates where !used.contains(name) && DocImageRef.validName(name) { try? FileManager.default.removeItem(at: assetURL(name)) }
    }
    /// Removes an image a page or entry just stopped using.
    func releaseImage(_ name: String) { removeUnused([name]) }

    // MARK: Import and export

    /// A page from a Markdown or plain-text file.
    @discardableResult func importFile(_ url: URL, parent: UUID? = nil) throws -> DocPage {
        guard canEdit else { throw DocsError.unavailable }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 5_000_001) ?? Data()
        guard data.count <= 5_000_000, let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { throw DocsError.tooLarge }
        let name = url.deletingPathExtension().lastPathComponent
        let markdown = ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased())
        var page = markdown ? DocMarkdown.page(from: text, fallbackTitle: name) : DocMarkdown.page(fromPlainText: text, title: name)
        page.parentID = parent.flatMap { self.page($0)?.trashed == nil ? $0 : nil }
        page.order = (children(of: page.parentID).map(\.order).max() ?? 0) + 1
        // Links to pages that aren't here become plain text.
        for index in page.blocks.indices where page.blocks[index].kind == .pageLink {
            if self.page(page.blocks[index].pageID) == nil { page.blocks[index] = DocBlock(text: "Linked page", indent: page.blocks[index].indent) }
        }
        pages.append(page)
        mark(page: page.id); flush()
        return page
    }
    /// A page as Markdown, with links to other pages named.
    func markdown(for id: UUID) -> String? {
        guard let page = page(id) else { return nil }
        return DocMarkdown.export(page) { [weak self] in self?.title($0) }
    }

    // MARK: Sync

    func syncSnapshot() -> [String: SyncItem]? {
        guard syncable else { return nil }
        var items: [String: SyncItem] = [:]
        for page in pages {
            guard let payload = try? SyncEngine.encode(page) else { return nil }
            items[DocsSyncAdapter.pagePrefix + page.id.uuidString] = .init(type: SyncType.docPage, payload: payload)
        }
        for entry in entries {
            guard let payload = try? SyncEngine.encode(entry) else { return nil }
            items[DocsSyncAdapter.entryPrefix + entry.id.uuidString] = .init(type: SyncType.journalEntry, payload: payload)
        }
        let files = FileManager.default
        if files.fileExists(atPath: assetsFolder.path) {
            guard let names = try? files.contentsOfDirectory(atPath: assetsFolder.path) else { return nil }
            for name in names where DocImageRef.validName(name) {
                // An image that can't be read now (a locked device) means the snapshot isn't complete.
                guard let data = try? Data(contentsOf: assetURL(name)) else { return nil }
                items[DocsSyncAdapter.assetPrefix + name] = .init(type: SyncType.docAsset, payload: data)
            }
        }
        return items
    }
    func applySynced(_ changes: [String: SyncItem?]) -> Set<String> {
        guard syncable else { return [] }
        var applied = Set<String>()
        for (id, item) in changes {
            if id.hasPrefix(DocsSyncAdapter.pagePrefix), let uuid = UUID(uuidString: String(id.dropFirst(DocsSyncAdapter.pagePrefix.count))) {
                if let item {
                    guard item.type == SyncType.docPage, let page = try? JSONDecoder().decode(DocPage.self, from: item.payload), page.id == uuid else { continue }
                    do { try write(page, to: pageURL(uuid)) } catch { continue }
                    if let index = pages.firstIndex(where: { $0.id == uuid }) { pages[index] = page } else { pages.append(page) }
                } else {
                    pages.removeAll { $0.id == uuid }
                    dirtyPages.remove(uuid)
                    try? FileManager.default.removeItem(at: pageURL(uuid))
                }
                applied.insert(id)
            } else if id.hasPrefix(DocsSyncAdapter.entryPrefix), let uuid = UUID(uuidString: String(id.dropFirst(DocsSyncAdapter.entryPrefix.count))) {
                if let item {
                    guard item.type == SyncType.journalEntry, let entry = try? JSONDecoder().decode(JournalEntry.self, from: item.payload), entry.id == uuid else { continue }
                    do { try write(entry, to: entryURL(uuid)) } catch { continue }
                    if let index = entries.firstIndex(where: { $0.id == uuid }) { entries[index] = entry } else { entries.append(entry) }
                } else {
                    entries.removeAll { $0.id == uuid }
                    dirtyEntries.remove(uuid)
                    try? FileManager.default.removeItem(at: entryURL(uuid))
                }
                applied.insert(id)
            } else if id.hasPrefix(DocsSyncAdapter.assetPrefix) {
                let name = String(id.dropFirst(DocsSyncAdapter.assetPrefix.count))
                guard DocImageRef.validName(name) else { continue }
                if let item {
                    guard item.type == SyncType.docAsset, item.payload.count <= 20_000_000, !closed else { continue }
                    do {
                        try AccountDirectory.checkWrite(to: assetURL(name))
                        try FileManager.default.createDirectory(at: assetsFolder, withIntermediateDirectories: true)
                        try Self.protectedWrite(item.payload, to: assetURL(name))
                    } catch { continue }
                } else { try? FileManager.default.removeItem(at: assetURL(name)) }
                applied.insert(id)
            }
        }
        return applied
    }

    #if DEBUG
    /// Sample pages and entries for UI tests and screenshots (`--docs-sample`).
    func seedSample() {
        guard pages.isEmpty else { return }
        let now = Date()
        var blocks = DocMarkdown.blocks(from: """
        Ideas for the week, sorted by how much they excite me.

        ## This week
        - [x] Book the ferry
        - [ ] Call about the studio
        - [ ] Draft the reading list

        > [!NOTE]
        > 💡 Keep mornings for writing.

        - ▸ Reading list
          - The quiet parts of cities
          - A field guide to clouds

        ```swift
        let plan = ["walk", "write", "read"]
        ```

        | Day | Plan |
        | --- | --- |
        | Mon | Studio |
        | Tue | Ferry |
        """)
        if blocks.isEmpty { blocks = [DocBlock()] }
        guard var trip = createPage(title: "Weekend plans", blocks: blocks, now: now) else { return }
        trip.icon = .emoji("🗺️"); trip.cover = DocCover(kind: .gradient, value: "dawn"); trip.favorite = true
        updatePage(trip.id) { $0 = trip }
        if let child = createPage(parent: trip.id, title: "Packing", blocks: DocMarkdown.blocks(from: "- [ ] Rain jacket\n- [ ] Camera"), now: now) {
            updatePage(child.id) { $0.icon = .symbol("bag") }
        }
        _ = createPage(title: "Recipes", blocks: DocMarkdown.blocks(from: "1. Toast the rice\n2. Add stock slowly"), now: now.addingTimeInterval(-3600))
        let zone = TimeZone.current
        for (offset, text, mood) in [(0, "Walked to the harbor before work. The light was pink on the water.", JournalMood.good),
                                     (-1, "Slow day. Finished the draft and made soup.", .okay),
                                     (-365, "First day in the new apartment.", .great)] {
            let day = JournalCalendar.shift(JournalCalendar.dayKey(for: now, in: zone), by: offset)
            guard let entry = createEntry(on: day, now: now, zone: zone) else { continue }
            updateEntry(entry.id) { $0.blocks = [DocBlock(text: text)]; $0.mood = mood; $0.tags = offset == 0 ? ["morning", "harbor"] : [] }
        }
        flush()
    }
    #endif
}

enum DocsError: LocalizedError {
    case unavailable, unreadableImage, tooLarge
    var errorDescription: String? {
        switch self {
        case .unavailable: "Your docs aren't open right now, so nothing was changed."
        case .unreadableImage: "That image couldn't be added. Try another one."
        case .tooLarge: "That file is too large or isn't text. Choose a Markdown or plain-text file under 5 MB."
        }
    }
}

/// Docs and Journal as account records in the personal zone: one per page, one per entry, and one
/// per image (large payloads travel as CloudKit assets). Deletions become tombstones through
/// `SyncEngine.reconcile`. A store that isn't open returns no snapshot, so nothing looks deleted.
@MainActor final class DocsSyncAdapter: SyncAdapter {
    static let pagePrefix = "docpage-", entryPrefix = "journal-", assetPrefix = "docasset-"
    let docs: DocsStore
    init(docs: DocsStore) { self.docs = docs }
    let types: Set<String> = [SyncType.docPage, SyncType.journalEntry, SyncType.docAsset]
    func snapshot() -> [String: SyncItem]? { docs.syncSnapshot() }
    func apply(_ changes: [String: SyncItem?]) -> Set<String> { docs.applySynced(changes) }
    /// The open account's docs, with their saves starting a sync.
    static func forSharedStore() -> DocsSyncAdapter {
        DocsStore.shared.onSaved = { AccountSyncService.shared.localChanged() }
        return DocsSyncAdapter(docs: DocsStore.shared)
    }
}

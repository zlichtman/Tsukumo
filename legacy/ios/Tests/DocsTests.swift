import XCTest
#if os(macOS)
@testable import KemoSabeMac
#else
@testable import KemoSabe
#endif

/// Docs and Journal (design/DOCS-AND-JOURNAL.md): the block model, Markdown, shortcuts, the page
/// tree and Trash, journal days, sync with tombstones, and that chat context holds only what's attached.
final class DocsTests: XCTestCase {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("DocsTests-" + UUID().uuidString, isDirectory: true)
    }

    // MARK: Blocks and serialization

    func testBlocksRoundTripThroughJSONAndToleranceForNewerKinds() throws {
        var page = DocPage(title: "Plan", blocks: [DocBlock(kind: .todo, text: "Book **ferry**", indent: 1), DocBlock(kind: .code, text: "let x = 1")])
        page.icon = .emoji("🗺️"); page.cover = DocCover(kind: .gradient, value: "dawn")
        page.blocks[1].language = "swift"
        let decoded = try JSONDecoder().decode(DocPage.self, from: try SyncEngine.encode(page))
        XCTAssertEqual(decoded, page)
        XCTAssertEqual(decoded.blocks[0].checked, false, "A to-do starts unchecked")

        // A kind from a newer build opens as text; an image name with a path is refused.
        let json = #"{"id":"\#(UUID().uuidString)","title":"x","blocks":[{"id":"\#(UUID().uuidString)","kind":"hologram","text":"hi"},{"id":"\#(UUID().uuidString)","kind":"image","image":{"file":"../../secret.jpg","width":1,"height":1}}]}"#
        let tolerant = try JSONDecoder().decode(DocPage.self, from: Data(json.utf8))
        XCTAssertEqual(tolerant.blocks[0].kind, .paragraph)
        XCTAssertEqual(tolerant.blocks[0].text, "hi")
        XCTAssertNil(tolerant.blocks[1].image)
        XCTAssertFalse(DocImageRef.validName("a/b.jpg"))
        XCTAssertTrue(DocImageRef.validName("img-" + UUID().uuidString + ".jpg"))
    }

    func testOlderChatMessagesStillDecodeWithoutAttachments() throws {
        let old = #"{"id":"\#(UUID().uuidString)","role":"You","text":"Hi","date":0}"#
        let message = try JSONDecoder().decode(ChatMessage.self, from: Data(old.utf8))
        XCTAssertNil(message.attachments)
    }

    // MARK: Markdown

    func testMarkdownExportAndImportRoundTrip() {
        let linked = UUID()
        var blocks: [DocBlock] = [
            DocBlock(kind: .heading1, text: "Heading"),
            DocBlock(text: "Some **bold** and _italic_ text with `code` and a [link](https://example.com)."),
            DocBlock(kind: .heading2, text: "Lists"),
            DocBlock(kind: .bulleted, text: "One"),
            DocBlock(kind: .bulleted, text: "Nested", indent: 1),
            DocBlock(kind: .numbered, text: "First"),
            DocBlock(kind: .numbered, text: "Second"),
            DocBlock(kind: .todo, text: "Open"),
            DocBlock(kind: .todo, text: "Done"),
            DocBlock(kind: .toggle, text: "More"),
            DocBlock(text: "Inside the toggle", indent: 1),
            DocBlock(kind: .heading3, text: "Small"),
            DocBlock(kind: .quote, text: "A line\nand another"),
            DocBlock(kind: .callout, text: "Keep mornings for writing"),
            DocBlock(kind: .code, text: "let a = 1\nprint(a)"),
            DocBlock(kind: .divider),
            DocBlock(kind: .image, text: "The harbor"),
            DocBlock(kind: .pageLink),
            DocBlock(kind: .table),
            DocBlock(text: "# not a heading"),
        ]
        blocks[8].checked = true
        blocks[13].icon = "💡"
        blocks[14].language = "swift"
        blocks[16].image = DocImageRef(file: "img-1.jpg", width: 10, height: 8)
        blocks[17].pageID = linked
        blocks[18].table = DocTable(rows: [["Day", "Plan"], ["Mon", "Studio | desk"], ["Tue", ""]])
        let page = DocPage(title: "Round trip", blocks: blocks)

        let markdown = DocMarkdown.export(page) { $0 == linked ? "Other page" : nil }
        XCTAssertTrue(markdown.hasPrefix("# Round trip\n\n# Heading"))
        XCTAssertTrue(markdown.contains("- One\n  - Nested\n1. First\n2. Second\n- [ ] Open\n- [x] Done\n- ▸ More"))
        XCTAssertTrue(markdown.contains("> [!NOTE]\n> 💡 Keep mornings"))
        XCTAssertTrue(markdown.contains("```swift\nlet a = 1\nprint(a)\n```"))
        XCTAssertTrue(markdown.contains("| Day | Plan |\n| --- | --- |\n| Mon | Studio \\| desk |"))
        XCTAssertTrue(markdown.contains("[Other page](kemo-doc:" + linked.uuidString + ")"))
        XCTAssertTrue(markdown.contains("\\# not a heading"))

        let imported = DocMarkdown.page(from: markdown, image: { $0 == "img-1.jpg" ? DocImageRef(file: "img-1.jpg", width: 10, height: 8) : nil })
        XCTAssertEqual(imported.title, "Round trip")
        func shape(_ block: DocBlock) -> [String] {
            [block.kind.rawValue, block.text, "\(block.indent)", "\(block.checked ?? false)", block.language ?? "", block.icon ?? "",
             block.image?.file ?? "", block.pageID?.uuidString ?? "", (block.table?.rows ?? []).description]
        }
        XCTAssertEqual(imported.blocks.map(shape), page.blocks.map(shape))
        // Exporting what was imported gives the same Markdown.
        XCTAssertEqual(DocMarkdown.export(imported) { $0 == linked ? "Other page" : nil }, markdown)
    }

    func testPlainTextImportKeepsParagraphs() {
        let page = DocMarkdown.page(fromPlainText: "First line\nsame paragraph\n\nSecond paragraph\n", title: "Notes")
        XCTAssertEqual(page.title, "Notes")
        XCTAssertEqual(page.blocks.map(\.text), ["First line\nsame paragraph", "Second paragraph"])
        XCTAssertTrue(page.blocks.allSatisfy { $0.kind == .paragraph })
    }

    func testForModelExportNamesImagesAndLinksWithoutFiles() {
        let other = UUID()
        var image = DocBlock(kind: .image, text: "Beach"); image.image = DocImageRef(file: "img-2.jpg", width: 1, height: 1)
        var link = DocBlock(kind: .pageLink); link.pageID = other
        let text = DocMarkdown.export(blocks: [image, link], forModel: true) { _ in "Packing" }
        XCTAssertEqual(text, "[Image: Beach]\n\nLinked page: Packing\n")
    }

    // MARK: Typing

    func testMarkdownShortcutsTurnParagraphsIntoBlocks() {
        func apply(_ text: String) -> DocBlock? { DocShortcuts.apply(DocBlock(text: text)) }
        XCTAssertEqual(apply("# ")?.kind, .heading1)
        XCTAssertEqual(apply("## Title")?.kind, .heading2)
        XCTAssertEqual(apply("## Title")?.text, "Title")
        XCTAssertEqual(apply("### ")?.kind, .heading3)
        XCTAssertEqual(apply("- ")?.kind, .bulleted)
        XCTAssertEqual(apply("* ")?.kind, .bulleted)
        XCTAssertEqual(apply("1. ")?.kind, .numbered)
        XCTAssertEqual(apply("12) Twelve")?.text, "Twelve")
        XCTAssertEqual(apply("[] ")?.kind, .todo)
        XCTAssertEqual(apply("[ ] ")?.checked, false)
        XCTAssertEqual(apply("[x] ")?.checked, true)
        XCTAssertEqual(apply("> ")?.kind, .quote)
        XCTAssertEqual(apply("``` ")?.kind, .code)
        XCTAssertEqual(apply("```swift ")?.language, "swift")
        XCTAssertEqual(apply("---")?.kind, .divider)
        XCTAssertNil(apply("#hashtag"))
        XCTAssertNil(apply("-dash"))
        XCTAssertNil(apply("```swift code "))
        var heading = DocBlock(kind: .heading1, text: "- ")
        heading.applyDefaults()
        XCTAssertNil(DocShortcuts.apply(heading), "Shortcuts only turn plain text into blocks")
        XCTAssertEqual(DocShortcuts.codeFence("```python"), "python")
        XCTAssertNil(DocShortcuts.codeFence("plain"))
    }

    func testSlashAndMentionTokens() {
        XCTAssertEqual(DocShortcuts.token("/", in: "/hea")?.query, "hea")
        XCTAssertEqual(DocShortcuts.token("/", in: "/hea")?.start, 0)
        XCTAssertEqual(DocShortcuts.token("/", in: "Buy /to")?.start, 4)
        XCTAssertNil(DocShortcuts.token("/", in: "and/or"))
        XCTAssertNil(DocShortcuts.token("/", in: "/two words"))
        XCTAssertEqual(DocShortcuts.token("@", in: "see @Gro")?.query, "Gro")
        XCTAssertNil(DocShortcuts.token("@", in: "me@example.com"))
        XCTAssertEqual(DocShortcuts.removing(tokenAt: 4, in: "Buy /to"), "Buy ")
        XCTAssertEqual(DocSlashItem.matching("h1").first, .kind(.heading1))
        XCTAssertEqual(DocSlashItem.matching("tod").first, .kind(.todo))
        XCTAssertEqual(DocSlashItem.matching("check").first, .kind(.todo))
        XCTAssertTrue(DocSlashItem.matching("sub").contains(.subPage))
        XCTAssertEqual(DocSlashItem.matching("").count, DocSlashItem.all.count)
    }

    func testInlineFormattingWrapsAndUnwraps() {
        let bold = DocInline.toggle(.bold, in: "make this bold", range: 10..<14)
        XCTAssertEqual(bold.text, "make this **bold**")
        XCTAssertEqual(bold.selection, 12..<16)
        let unbold = DocInline.toggle(.bold, in: bold.text, range: bold.selection)
        XCTAssertEqual(unbold.text, "make this bold")
        XCTAssertEqual(DocInline.toggle(.italic, in: "a b", range: 2..<3).text, "a _b_")
        XCTAssertEqual(DocInline.toggle(.code, in: "`x`", range: 0..<3).text, "x")
        let link = DocInline.toggle(.link, in: "see docs", range: 4..<8)
        XCTAssertEqual(link.text, "see [docs](https://)")
        XCTAssertEqual(Array(link.text)[link.selection].map(String.init).joined(), "https://")
        XCTAssertEqual(DocInline.plain("**bold** and _it_"), "bold and it")
        let id = UUID()
        XCTAssertEqual(DocInline.pageID(from: URL(string: "kemo-doc:" + id.uuidString)!), id)
    }

    func testUndoGroupsTypingAndKeepsStructuralSteps() {
        var stack = DocUndoStack<[String]>()
        let t0 = Date()
        stack.record(["a"], typingIn: "b1", at: t0)
        stack.record(["ab"], typingIn: "b1", at: t0 + 0.5)
        stack.record(["abc"], typingIn: "b1", at: t0 + 3)
        stack.record(["abc", ""], at: t0 + 3.1)
        XCTAssertEqual(stack.undo(current: ["abc", "", "x"]), ["abc", ""])
        XCTAssertEqual(stack.undo(current: ["abc", ""]), ["abc"])
        XCTAssertEqual(stack.undo(current: ["abc"]), ["a"])
        XCTAssertNil(stack.undo(current: ["a"]))
        XCTAssertEqual(stack.redo(current: ["a"]), ["abc"])
    }

    // MARK: Blocks inside a page

    func testIndentOutdentMoveAndNumbering() {
        var blocks = [DocBlock(kind: .numbered, text: "1"), DocBlock(kind: .numbered, text: "2"), DocBlock(kind: .bulleted, text: "child", indent: 1),
                      DocBlock(kind: .numbered, text: "3"), DocBlock(text: "end")]
        let ids = blocks.map(\.id)
        XCTAssertEqual(DocOutline.numbers(blocks)[ids[3]], 3, "A deeper item between numbered items doesn't restart the count")
        XCTAssertFalse(DocOutline.indent(ids[0], in: &blocks), "The first block has nothing to nest under")
        XCTAssertTrue(DocOutline.indent(ids[1], in: &blocks))
        XCTAssertEqual(blocks.map(\.indent), [0, 1, 2, 0, 0], "Indenting takes the nested block along")
        XCTAssertEqual(DocOutline.numbers(blocks)[ids[3]], 2)
        XCTAssertTrue(DocOutline.outdent(ids[1], in: &blocks))
        XCTAssertEqual(blocks.map(\.indent), [0, 0, 1, 0, 0])
        // Moving a block takes what's nested under it.
        XCTAssertTrue(DocOutline.move(ids[1], before: nil, in: &blocks))
        XCTAssertEqual(blocks.map(\.id), [ids[0], ids[3], ids[4], ids[1], ids[2]])
        XCTAssertFalse(DocOutline.move(ids[1], before: ids[2], in: &blocks), "Never into its own nested blocks")
        XCTAssertTrue(DocOutline.moveUp(ids[4], in: &blocks))
        XCTAssertEqual(blocks.map(\.id), [ids[0], ids[4], ids[3], ids[1], ids[2]])
        XCTAssertTrue(DocOutline.moveDown(ids[0], in: &blocks))
        XCTAssertEqual(blocks.map(\.id), [ids[4], ids[0], ids[3], ids[1], ids[2]])
    }

    func testClosedToggleHidesItsContents() {
        var toggle = DocBlock(kind: .toggle, text: "More"); toggle.collapsed = true
        let blocks = [toggle, DocBlock(text: "hidden", indent: 1), DocBlock(text: "hidden too", indent: 2), DocBlock(text: "shown")]
        XCTAssertEqual(DocOutline.visible(blocks).map(\.text), ["More", "shown"])
        XCTAssertEqual(DocOutline.subtree(at: 0, in: blocks), 0..<3)
    }

    // MARK: Pages: nesting, moving, Trash

    @MainActor func testNestingMovingTrashAndRestore() throws {
        let docs = DocsStore(folder: folder())
        let trip = try XCTUnwrap(docs.createPage(title: "Trip"))
        let packing = try XCTUnwrap(docs.createPage(parent: trip.id, title: "Packing"))
        let shoes = try XCTUnwrap(docs.createPage(parent: packing.id, title: "Shoes"))
        let recipes = try XCTUnwrap(docs.createPage(title: "Recipes"))
        XCTAssertEqual(docs.children(of: nil).map(\.title), ["Trip", "Recipes"])
        XCTAssertEqual(DocOutline.path(to: shoes.id, in: docs.pages).map(\.title), ["Trip", "Packing"])

        XCTAssertFalse(docs.move(trip.id, to: shoes.id), "A page can't move under its own sub-page")
        XCTAssertFalse(docs.move(trip.id, to: trip.id))
        XCTAssertTrue(docs.move(packing.id, to: recipes.id))
        XCTAssertEqual(docs.children(of: recipes.id).map(\.title), ["Packing"])
        XCTAssertEqual(docs.page(shoes.id)?.parentID, packing.id, "Sub-pages move with their page")

        docs.moveToTrash(recipes.id)
        XCTAssertEqual(docs.livePages.map(\.title), ["Trip"])
        XCTAssertEqual(docs.trash.map(\.title), ["Recipes"], "Only what was trashed on its own is listed")
        docs.restore(recipes.id)
        XCTAssertEqual(Set(docs.livePages.map(\.title)), ["Trip", "Recipes", "Packing", "Shoes"])

        // A sub-page trashed on its own comes back at the top when its parent is gone.
        docs.moveToTrash(packing.id)
        docs.moveToTrash(recipes.id)
        docs.deleteForever(recipes.id)
        docs.restore(packing.id)
        XCTAssertNil(docs.page(packing.id)?.parentID)
        XCTAssertNil(docs.page(recipes.id))

        // Deleting forever removes the page, its sub-pages, their files, and images only they used.
        let image = try docs.addImage(DocsTests.jpeg())
        docs.updatePage(packing.id) { var block = DocBlock(kind: .image); block.image = image; $0.blocks.append(block) }
        docs.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: docs.assetURL(image.file).path))
        docs.moveToTrash(packing.id)
        docs.deleteForever(packing.id)
        XCTAssertNil(docs.page(shoes.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: docs.assetURL(image.file).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: docs.pagesFolder.appendingPathComponent(shoes.id.uuidString + ".json").path))
    }

    @MainActor func testPagesPersistAndSearchFindsTitlesAndText() throws {
        let place = folder()
        let docs = DocsStore(folder: place)
        let page = try XCTUnwrap(docs.createPage(title: "Groceries"))
        docs.updatePage(page.id) { $0.blocks = [DocBlock(kind: .todo, text: "Oat milk"), DocBlock(text: "From the market on Saturday")] }
        docs.toggleFavorite(page.id)
        docs.flush()
        let reopened = DocsStore(folder: place)
        XCTAssertEqual(reopened.page(page.id)?.blocks.map(\.text), ["Oat milk", "From the market on Saturday"])
        XCTAssertEqual(reopened.favorites.map(\.id), [page.id])
        XCTAssertEqual(reopened.search("groc").map(\.id), [page.id])
        XCTAssertEqual(reopened.search("market").first?.snippet?.contains("market"), true)
        XCTAssertTrue(reopened.search("nothing like this").isEmpty)
    }

    @MainActor func testImportingMarkdownAndTextFiles() throws {
        let docs = DocsStore(folder: folder())
        let source = folder()
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let md = source.appendingPathComponent("Plan.md"), txt = source.appendingPathComponent("Notes.txt")
        try "# Weekend\n\n- [ ] Ferry\n- Bread".write(to: md, atomically: true, encoding: .utf8)
        try "Line one\n\nLine two".write(to: txt, atomically: true, encoding: .utf8)
        let a = try docs.importFile(md), b = try docs.importFile(txt)
        XCTAssertEqual(a.title, "Weekend")
        XCTAssertEqual(a.blocks.map(\.kind), [.todo, .bulleted])
        XCTAssertEqual(b.title, "Notes")
        XCTAssertEqual(b.blocks.map(\.text), ["Line one", "Line two"])
    }

    // MARK: Journal

    func testJournalDaysStayWhereTheyWereWritten() throws {
        let losAngeles = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles")), tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        // 05:30 UTC on September 27 is the evening of the 26th in Los Angeles and the afternoon of the 27th in Tokyo.
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-27T05:30:00Z"))
        let written = JournalEntry(created: instant, timeZone: losAngeles)
        XCTAssertEqual(written.day, "2026-09-26")
        XCTAssertEqual(JournalEntry(created: instant, timeZone: tokyo).day, "2026-09-27")
        // Read later somewhere else, it keeps its day.
        let decoded = try JSONDecoder().decode(JournalEntry.self, from: try SyncEngine.encode(written))
        XCTAssertEqual(decoded.day, "2026-09-26")
        let late = JournalEntry(created: instant.addingTimeInterval(3600), timeZone: tokyo)
        let groups = JournalCalendar.grouped([written, late])
        XCTAssertEqual(groups.map(\.day), ["2026-09-27", "2026-09-26"])
        XCTAssertEqual(JournalCalendar.shift("2026-12-31", by: 1), "2027-01-01")
        XCTAssertEqual(JournalCalendar.shift("2024-03-01", by: -1), "2024-02-29")
        XCTAssertEqual(JournalCalendar.shift("2026-03-08", by: 1), "2026-03-09", "A daylight-saving change doesn't skip a day")
    }

    func testOnThisDayStreakAndMonthGrid() {
        func entry(_ day: String, text: String = "x") -> JournalEntry {
            var entry = JournalEntry(created: Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "UTC")!, day: day)
            entry.blocks = [DocBlock(text: text)]
            return entry
        }
        let entries = [entry("2025-09-26", text: "Last year"), entry("2023-09-26"), entry("2026-09-26"), entry("2025-09-25"), entry("2024-02-29", text: "Leap")]
        let past = JournalCalendar.onThisDay(entries, today: "2026-09-26")
        XCTAssertEqual(past.map(\.years), [1, 3])
        XCTAssertEqual(past.first?.entries.first?.summary, "Last year")
        XCTAssertEqual(JournalCalendar.onThisDay(entries, today: "2025-02-28").first?.entries.first?.summary, "Leap", "February 29 shows on the 28th in other years")
        XCTAssertTrue(JournalCalendar.onThisDay(entries, today: "2028-02-28").isEmpty, "…but not in a leap year")

        let streak = [entry("2026-09-24"), entry("2026-09-25"), entry("2026-09-26"), entry("2026-09-22")]
        XCTAssertEqual(JournalCalendar.streak(streak, today: "2026-09-26"), 3)
        XCTAssertEqual(JournalCalendar.streak(streak, today: "2026-09-27"), 3, "Today without an entry yet doesn't end the streak")
        XCTAssertEqual(JournalCalendar.streak(streak, today: "2026-09-28"), 0)
        XCTAssertEqual(JournalCalendar.streak([entry("2026-09-26", text: "")], today: "2026-09-26"), 0, "An empty entry doesn't count")

        // September 2026 starts on a Tuesday.
        let sundayFirst = JournalCalendar.monthGrid(year: 2026, month: 9, firstWeekday: 1)
        XCTAssertEqual(sundayFirst.prefix(2).compactMap { $0 }.count, 0)
        XCTAssertEqual(sundayFirst[2], "2026-09-01")
        XCTAssertEqual(sundayFirst.compactMap { $0 }.count, 30)
        XCTAssertEqual(JournalCalendar.monthGrid(year: 2026, month: 9, firstWeekday: 2)[1], "2026-09-01")
        XCTAssertNotEqual(JournalPrompts.prompt(for: "2026-09-26"), JournalPrompts.prompt(for: "2026-09-26", offset: 1))
    }

    @MainActor func testJournalEntriesOnADayAndTags() throws {
        let docs = DocsStore(folder: folder())
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-26T18:00:00Z"))
        let utc = TimeZone(identifier: "UTC")!
        let first = try XCTUnwrap(docs.createEntry(now: now, zone: utc))
        let second = try XCTUnwrap(docs.createEntry(now: now.addingTimeInterval(60), zone: utc))
        let past = try XCTUnwrap(docs.createEntry(on: "2026-09-20", now: now, zone: utc))
        XCTAssertEqual(docs.entries(on: "2026-09-26").map(\.id), [first.id, second.id], "More than one entry a day, in order")
        XCTAssertEqual(past.day, "2026-09-20")
        XCTAssertEqual(JournalCalendar.dayKey(for: past.created, in: utc), "2026-09-20")
        docs.updateEntry(first.id) { $0.tags = ["#Morning", "morning", "big walk"]; $0.mood = .good }
        XCTAssertEqual(docs.entry(first.id)?.tags, ["morning", "big-walk"])
        XCTAssertEqual(docs.entry(first.id)?.mood, .good)
        docs.deleteEntry(second.id)
        XCTAssertEqual(docs.entries(on: "2026-09-26").count, 1)
    }

    // MARK: Sync

    @MainActor func testDocsAndJournalSyncWithTombstones() async throws {
        let transport = MemorySyncTransport()
        let phoneEngine = SyncEngine(transport: transport, device: "phone"), macEngine = SyncEngine(transport: transport, device: "mac")
        let phone = DocsStore(folder: folder()), mac = DocsStore(folder: folder())
        let page = try XCTUnwrap(phone.createPage(title: "Shared plan", blocks: [DocBlock(text: "Hello from the phone")]))
        let entry = try XCTUnwrap(phone.createEntry())
        let image = try phone.addImage(DocsTests.jpeg())
        phone.updateEntry(entry.id) { $0.photos = [image]; $0.mood = .great }
        phone.flush()

        try phoneEngine.reconcile(DocsSyncAdapter(docs: phone)); try await phoneEngine.sync()
        try await macEngine.sync(); try macEngine.reconcile(DocsSyncAdapter(docs: mac))
        XCTAssertEqual(mac.page(page.id)?.blocks.first?.text, "Hello from the phone")
        XCTAssertEqual(mac.entry(entry.id)?.mood, .great)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mac.assetURL(image.file).path), "The photo arrives as its own record")
        let reopened = DocsStore(folder: mac.folder)
        XCTAssertEqual(reopened.page(page.id)?.title, "Shared plan", "What arrived was saved")

        // An edit on the Mac comes back.
        mac.updatePage(page.id) { $0.title = "Shared plan, edited" }
        mac.flush()
        try macEngine.reconcile(DocsSyncAdapter(docs: mac)); try await macEngine.sync()
        try await phoneEngine.sync(); try phoneEngine.reconcile(DocsSyncAdapter(docs: phone))
        XCTAssertEqual(phone.page(page.id)?.title, "Shared plan, edited")

        // Deleting forever and deleting an entry become tombstones on the other device.
        phone.moveToTrash(page.id)
        phone.deleteForever(page.id)
        phone.deleteEntry(entry.id)
        try phoneEngine.reconcile(DocsSyncAdapter(docs: phone)); try await phoneEngine.sync()
        XCTAssertTrue(phoneEngine.state.records.values.contains { $0.id == DocsSyncAdapter.pagePrefix + page.id.uuidString && $0.deleted })
        try await macEngine.sync(); try macEngine.reconcile(DocsSyncAdapter(docs: mac))
        XCTAssertNil(mac.page(page.id))
        XCTAssertNil(mac.entry(entry.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mac.assetURL(image.file).path))
        XCTAssertTrue(DocsSyncAdapter(docs: mac).types.allSatisfy { SyncType.personalOnly.contains($0) }, "Docs and Journal never enter a shared zone")
    }

    @MainActor func testAStoreThatIsNotOpenNeverLooksDeleted() async throws {
        let transport = MemorySyncTransport()
        let engine = SyncEngine(transport: transport, device: "phone")
        let place = folder()
        let docs = DocsStore(folder: place)
        _ = docs.createPage(title: "Keep me")
        try engine.reconcile(DocsSyncAdapter(docs: docs)); try await engine.sync()
        XCTAssertTrue(engine.state.outbox.isEmpty)

        // A file that can't be read (damage, or a locked device) keeps the store closed to sync.
        try Data("not json".utf8).write(to: docs.pagesFolder.appendingPathComponent(UUID().uuidString + ".json"))
        let damaged = DocsStore(folder: place)
        XCTAssertTrue(damaged.loadFailed)
        XCTAssertNil(damaged.syncSnapshot())
        XCTAssertNil(damaged.createPage(title: "Refused"), "Nothing is written while it can't be read")
        let result = try engine.reconcile(DocsSyncAdapter(docs: damaged))
        XCTAssertEqual(result, ReconcileResult())
        XCTAssertTrue(engine.state.outbox.isEmpty, "No tombstones for pages it couldn't read")

        docs.close()
        XCTAssertNil(docs.syncSnapshot(), "A closed store (after an account switch) isn't read either")
    }

    // MARK: Chat context holds only what's attached

    @MainActor func testContextHoldsOnlyTheAttachedDoc() throws {
        let docs = DocsStore(folder: folder())
        let parent = try XCTUnwrap(docs.createPage(title: "Project", blocks: [DocBlock(text: "Parent notes: ship Friday")]))
        _ = docs.createPage(parent: parent.id, title: "Private sub-page", blocks: [DocBlock(text: "Salary numbers")])
        _ = docs.createPage(title: "Diary", blocks: [DocBlock(text: "Something unrelated")])
        let entry = try XCTUnwrap(docs.createEntry())
        docs.updateEntry(entry.id) { $0.blocks = [DocBlock(text: "Walked by the water")]; $0.mood = .good; $0.tags = ["walk"] }

        let attachment = try XCTUnwrap(docs.attachment(page: parent.id))
        XCTAssertEqual(attachment.kind, .doc)
        XCTAssertTrue(attachment.text.contains("Parent notes: ship Friday"))
        XCTAssertFalse(attachment.text.contains("Salary numbers"), "Sub-pages aren't included")
        XCTAssertFalse(attachment.text.contains("Something unrelated"))
        let journal = try XCTUnwrap(docs.attachment(entry: entry.id))
        XCTAssertTrue(journal.text.contains("Walked by the water") && journal.text.contains("Mood: Good") && journal.text.contains("#walk"))

        // What a model receives: the attached text only, and nothing when nothing is attached.
        XCTAssertNil(AttachedContext.compose([], limit: 3000))
        let composed = try XCTUnwrap(AttachedContext.compose([attachment], limit: AttachedContext.onDeviceLimit))
        XCTAssertTrue(composed.contains("Parent notes: ship Friday"))
        XCTAssertFalse(composed.contains("Something unrelated") || composed.contains("Walked by the water"))
        let long = ChatDocAttachment(sourceID: UUID(), kind: .doc, title: "Long", text: String(repeating: "a", count: 10_000))
        XCTAssertLessThan(try XCTUnwrap(AttachedContext.compose([long], limit: 3000)).count, 3200)

        // On-device: the prompt carries the attachment for this turn; history keeps only a note.
        var request = PlanningRequest(message: "Summarize it", history: [], memories: [], standupFormat: "")
        XCTAssertEqual(ConversationPrompt.make(request), "Summarize it", "Nothing attached, nothing added")
        request.attached = composed
        let prompt = ConversationPrompt.make(request)
        XCTAssertTrue(prompt.contains("Parent notes: ship Friday") && prompt.hasSuffix("Summarize it"))
        XCTAssertFalse(ConversationPrompt.make(request, includeAttached: false).contains("Parent notes"))
        let earlier = ChatMessage(role: "You", text: "Look at this", attachments: [attachment])
        let next = PlanningRequest(message: "And now?", history: [earlier], memories: [], standupFormat: "")
        XCTAssertNil(next.history.first?.attachments)
        XCTAssertTrue(next.history.first?.text.contains("Attached earlier: “Project”") == true)

        // A connected model: only the message it was attached to carries the text.
        let packet = try ExternalConversationPacket.make(message: "And now?", history: [earlier], attached: AttachedContext.compose([journal], limit: AttachedContext.connectedLimit))
        let contents = packet.messages.map(\.content)
        XCTAssertFalse(contents.dropLast().contains { $0.contains("Parent notes") }, "An earlier attachment isn't sent again")
        XCTAssertTrue(contents[1].contains("Attached earlier"))
        XCTAssertTrue(contents.last?.contains("Walked by the water") == true)
        XCTAssertFalse(contents.joined().contains("Something unrelated"))
    }

    @MainActor func testComposerAttachmentsGoWithOneMessageAndNameTheirDestination() throws {
        let store = AppStore(repository: .init(url: folder().appendingPathComponent("state.json")), provider: OnDeviceAssistant())
        XCTAssertNil(store.attachmentDestination, "On-device: nothing leaves this device")
        let attachment = ChatDocAttachment(sourceID: UUID(), kind: .doc, title: "Plan", text: "x")
        XCTAssertNil(store.attachOrConfirm(attachment), "Attached at once when it stays on this device")
        XCTAssertEqual(store.composerAttachments.map(\.title), ["Plan"])
        XCTAssertNil(store.attachOrConfirm(attachment), "The same doc isn't attached twice")
        XCTAssertEqual(store.composerAttachments.count, 1)
        XCTAssertEqual(store.takeComposerAttachments().count, 1)
        XCTAssertTrue(store.composerAttachments.isEmpty, "Only the next message takes them")
    }

    // MARK: Helpers

    static func jpeg() -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0.5, blue: 0.4, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }
}

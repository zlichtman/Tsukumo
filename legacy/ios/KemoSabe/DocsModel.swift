import Foundation

// Docs: pages you write in Library, next to Memories and Drafts, on iPhone and Mac.
// A page is a title, an optional icon and cover, and a flat list of blocks; nesting (sub-pages)
// is a parent link, and nesting inside a page (list items, a toggle's contents) is each block's
// indent. Everything here is plain data and pure functions, shared by both apps and the tests.
// Kemo never reads a page unless the person attaches it to a chat message.
// See design/DOCS-AND-JOURNAL.md.

enum DocBlockKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case paragraph, heading1, heading2, heading3, bulleted, numbered, todo, toggle, quote, callout, code, divider, image, pageLink, table
    var id: String { rawValue }
    var title: String {
        switch self {
        case .paragraph: "Text"
        case .heading1: "Heading 1"
        case .heading2: "Heading 2"
        case .heading3: "Heading 3"
        case .bulleted: "Bulleted list"
        case .numbered: "Numbered list"
        case .todo: "To-do"
        case .toggle: "Toggle"
        case .quote: "Quote"
        case .callout: "Callout"
        case .code: "Code"
        case .divider: "Divider"
        case .image: "Image"
        case .pageLink: "Link to page"
        case .table: "Table"
        }
    }
    var symbol: String {
        switch self {
        case .paragraph: "text.alignleft"
        case .heading1: "textformat.size.larger"
        case .heading2: "textformat.size"
        case .heading3: "textformat.size.smaller"
        case .bulleted: "list.bullet"
        case .numbered: "list.number"
        case .todo: "checkmark.square"
        case .toggle: "chevron.right.square"
        case .quote: "text.quote"
        case .callout: "lightbulb"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .divider: "minus"
        case .image: "photo"
        case .pageLink: "arrow.up.forward.square"
        case .table: "tablecells"
        }
    }
    /// Words the block menu also matches ("/h1", "/check", "/hr").
    var keywords: [String] {
        switch self {
        case .paragraph: ["text", "plain", "paragraph"]
        case .heading1: ["h1", "heading", "title", "large"]
        case .heading2: ["h2", "heading", "medium"]
        case .heading3: ["h3", "heading", "small"]
        case .bulleted: ["bullet", "list", "unordered", "ul"]
        case .numbered: ["number", "list", "ordered", "ol"]
        case .todo: ["todo", "task", "check", "checkbox"]
        case .toggle: ["toggle", "collapse", "fold", "details"]
        case .quote: ["quote", "blockquote"]
        case .callout: ["callout", "note", "tip", "highlight"]
        case .code: ["code", "snippet", "fence", "monospace"]
        case .divider: ["divider", "line", "hr", "separator"]
        case .image: ["image", "photo", "picture", "camera"]
        case .pageLink: ["link", "page", "mention"]
        case .table: ["table", "grid", "rows", "columns"]
        }
    }
    /// Blocks you type in. An image's text is its caption.
    var hasText: Bool { ![.divider, .pageLink, .table].contains(self) }
    /// Kinds Return continues ("Milk" then Return starts another to-do).
    var continuesOnReturn: Bool { [.bulleted, .numbered, .todo].contains(self) }
    /// What "Turn into" offers.
    static let textKinds: [DocBlockKind] = [.paragraph, .heading1, .heading2, .heading3, .bulleted, .numbered, .todo, .toggle, .quote, .callout, .code]
}

/// An image stored as a file in the account's Docs folder.
struct DocImageRef: Codable, Equatable, Hashable, Sendable {
    var file: String
    var width: Int
    var height: Int
    /// Only names this app makes are accepted from a file or another device (no paths).
    static func validName(_ name: String) -> Bool {
        name.count <= 80 && name.hasSuffix(".jpg") && !name.hasPrefix(".")
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }
    }
}

/// A small table: rows of plain cells; the first row is the header.
struct DocTable: Codable, Equatable, Sendable {
    var rows: [[String]] = [["", "", ""], ["", "", ""], ["", "", ""]]
    static let maxRows = 40, maxColumns = 8
    var columnCount: Int { rows.map(\.count).max() ?? 0 }
    /// Every row the same width, within the limits.
    mutating func normalize() {
        let width = min(Self.maxColumns, max(1, columnCount))
        rows = Array(rows.prefix(Self.maxRows)).map { row in
            let cut = Array(row.prefix(width))
            return cut + Array(repeating: "", count: width - cut.count)
        }
        if rows.isEmpty { rows = [Array(repeating: "", count: width)] }
    }
}

struct DocBlock: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var kind: DocBlockKind = .paragraph
    /// Inline Markdown: **bold**, _italic_, `code`, ~~strike~~, and [links](https://…).
    var text = ""
    /// Nesting inside the page: list items under list items, a toggle's contents.
    var indent = 0
    var checked: Bool?
    var collapsed: Bool?
    var language: String?
    /// A callout's emoji.
    var icon: String?
    var image: DocImageRef?
    var pageID: UUID?
    var table: DocTable?
    static let maxIndent = 6

    init(id: UUID = UUID(), kind: DocBlockKind = .paragraph, text: String = "", indent: Int = 0) {
        self.id = id; self.kind = kind; self.text = text; self.indent = indent
        applyDefaults()
    }
    /// The fields a kind needs, set when a block becomes that kind.
    mutating func applyDefaults() {
        switch kind {
        case .todo: checked = checked ?? false
        case .toggle: collapsed = collapsed ?? false
        case .code: language = language ?? ""
        case .callout: icon = icon ?? "💡"
        case .table: table = table ?? DocTable()
        default: break
        }
    }
    /// Turns this block into another kind, keeping its text when the new kind has text.
    func turned(into kind: DocBlockKind) -> DocBlock {
        var next = self
        next.kind = kind
        if !kind.hasText { next.text = "" }
        next.applyDefaults()
        return next
    }
    var isEmptyText: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }

    enum CodingKeys: String, CodingKey { case id, kind, text, indent, checked, collapsed, language, icon, image, pageID, table }
    /// A kind a newer build adds opens as text rather than making the page unreadable.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)).flatMap { $0.flatMap(DocBlockKind.init(rawValue:)) } ?? .paragraph
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        indent = min(Self.maxIndent, max(0, try c.decodeIfPresent(Int.self, forKey: .indent) ?? 0))
        checked = try c.decodeIfPresent(Bool.self, forKey: .checked)
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        image = try? c.decodeIfPresent(DocImageRef.self, forKey: .image)
        pageID = try c.decodeIfPresent(UUID.self, forKey: .pageID)
        table = try? c.decodeIfPresent(DocTable.self, forKey: .table)
        if kind == .image, image.map({ !DocImageRef.validName($0.file) }) ?? true { image = nil }
    }
}

/// A page's icon: an emoji, or an SF Symbol name.
struct DocIcon: Codable, Equatable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case emoji, symbol }
    var kind: Kind
    var value: String
    static func emoji(_ value: String) -> DocIcon { .init(kind: .emoji, value: value) }
    static func symbol(_ value: String) -> DocIcon { .init(kind: .symbol, value: value) }
}

/// A page's cover: one of the app's gradients, or a photo.
struct DocCover: Codable, Equatable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case gradient, image }
    var kind: Kind
    var value: String
}

struct DocPage: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var parentID: UUID?
    var title = ""
    var icon: DocIcon?
    var cover: DocCover?
    var blocks: [DocBlock] = [DocBlock()]
    var created = Date()
    var modified = Date()
    var favorite = false
    /// Position among its siblings.
    var order: Double = 0
    /// When it went to the Trash; the pages that went with it share `trashedWith`.
    var trashed: Date?
    var trashedWith: UUID?
    /// Who may read it (`PrivacyLevel`); nil is the default for docs (`DocPage.defaultPrivacy`).
    var privacy: PrivacyLevel?
    static let maxTitle = 200, maxBlocks = 2_000

    var displayTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : title }
    /// All the page's words, for search.
    var plainText: String { blocks.map(\.searchText).joined(separator: "\n") }

    init(id: UUID = UUID(), parentID: UUID? = nil, title: String = "", blocks: [DocBlock] = [DocBlock()], now: Date = Date()) {
        self.id = id; self.parentID = parentID; self.title = title; self.blocks = blocks
        created = now; modified = now
    }
    enum CodingKeys: String, CodingKey { case id, parentID, title, icon, cover, blocks, created, modified, favorite, order, trashed, trashedWith, privacy }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        parentID = try c.decodeIfPresent(UUID.self, forKey: .parentID)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        icon = try? c.decodeIfPresent(DocIcon.self, forKey: .icon)
        cover = try? c.decodeIfPresent(DocCover.self, forKey: .cover)
        blocks = try c.decodeIfPresent([DocBlock].self, forKey: .blocks) ?? []
        if blocks.isEmpty { blocks = [DocBlock()] }
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? .distantPast
        modified = try c.decodeIfPresent(Date.self, forKey: .modified) ?? created
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        order = try c.decodeIfPresent(Double.self, forKey: .order) ?? 0
        trashed = try c.decodeIfPresent(Date.self, forKey: .trashed)
        trashedWith = try c.decodeIfPresent(UUID.self, forKey: .trashedWith)
        privacy = try c.decodeIfPresent(PrivacyLevel.self, forKey: .privacy)
        if cover?.kind == .image, let file = cover?.value, !DocImageRef.validName(file) { cover = nil }
    }
}

extension DocBlock {
    /// The words in a block (without Markdown), for search and snippets.
    var searchText: String {
        switch kind {
        case .table: (table?.rows ?? []).map { $0.joined(separator: " ") }.joined(separator: " ")
        case .divider, .pageLink: ""
        default: DocInline.plain(text)
        }
    }
}

// MARK: Pages as a tree

enum DocOutline {
    /// A page's live children, in order.
    static func children(of parent: UUID?, in pages: [DocPage]) -> [DocPage] {
        pages.filter { $0.parentID == parent && $0.trashed == nil }.sorted { ($0.order, $0.created) < ($1.order, $1.created) }
    }
    /// Every page under `id` (not `id` itself), trashed or not.
    static func descendants(of id: UUID, in pages: [DocPage]) -> Set<UUID> {
        var found = Set<UUID>(), frontier = [id]
        while let next = frontier.popLast() {
            for page in pages where page.parentID == next && !found.contains(page.id) && page.id != id {
                found.insert(page.id); frontier.append(page.id)
            }
        }
        return found
    }
    /// A page can move under another page, or to the top, but never under itself or its own sub-pages.
    static func canMove(_ id: UUID, to parent: UUID?, in pages: [DocPage]) -> Bool {
        guard let parent else { return true }
        guard parent != id, pages.contains(where: { $0.id == parent && $0.trashed == nil }) else { return false }
        return !descendants(of: id, in: pages).contains(parent)
    }
    /// Moves a page (with its sub-pages) under `parent`, last among its new siblings.
    @discardableResult static func move(_ id: UUID, to parent: UUID?, in pages: inout [DocPage], now: Date = Date()) -> Bool {
        guard canMove(id, to: parent, in: pages), let index = pages.firstIndex(where: { $0.id == id }) else { return false }
        let siblings = children(of: parent, in: pages).filter { $0.id != id }
        pages[index].parentID = parent
        pages[index].order = (siblings.map(\.order).max() ?? 0) + 1
        pages[index].modified = now
        return true
    }
    /// The page's ancestors, outermost first.
    static func path(to id: UUID, in pages: [DocPage]) -> [DocPage] {
        var result: [DocPage] = [], seen = Set<UUID>()
        var current = pages.first { $0.id == id }?.parentID
        while let parent = current, !seen.contains(parent), let page = pages.first(where: { $0.id == parent }) {
            result.insert(page, at: 0); seen.insert(parent); current = page.parentID
        }
        return result
    }
    /// Moves a page and its sub-pages to the Trash together.
    static func trash(_ id: UUID, in pages: inout [DocPage], now: Date = Date()) {
        let group = descendants(of: id, in: pages).union([id])
        for index in pages.indices where group.contains(pages[index].id) && pages[index].trashed == nil {
            pages[index].trashed = now; pages[index].trashedWith = id; pages[index].modified = now
        }
    }
    /// Brings back what went to the Trash with `id`. A page whose parent is gone or still in the
    /// Trash comes back at the top level.
    static func restore(_ id: UUID, in pages: inout [DocPage], now: Date = Date()) {
        for index in pages.indices where pages[index].trashedWith == id {
            pages[index].trashed = nil; pages[index].trashedWith = nil; pages[index].modified = now
        }
        let live = Set(pages.filter { $0.trashed == nil }.map(\.id))
        for index in pages.indices where pages[index].trashed == nil {
            if let parent = pages[index].parentID, !live.contains(parent) { pages[index].parentID = nil; pages[index].modified = now }
        }
    }
    /// What was trashed on its own (restoring it brings back its sub-pages too), newest first.
    static func trashRoots(_ pages: [DocPage]) -> [DocPage] {
        pages.filter { $0.trashed != nil && ($0.trashedWith == $0.id || $0.trashedWith == nil) }.sorted { ($0.trashed ?? .distantPast) > ($1.trashed ?? .distantPast) }
    }
    /// The pages a permanent delete of `id` removes: it and the sub-pages that went to the Trash
    /// with it. A sub-page trashed on its own stays in the Trash (restoring it brings it back at
    /// the top), and one that's somehow still live is never deleted this way.
    static func deletion(_ id: UUID, in pages: [DocPage]) -> Set<UUID> {
        let under = descendants(of: id, in: pages)
        return Set(pages.filter { under.contains($0.id) && $0.trashedWith == id }.map(\.id)).union([id])
    }

    // MARK: Blocks inside a page

    /// The block at `index` and the blocks nested under it.
    static func subtree(at index: Int, in blocks: [DocBlock]) -> Range<Int> {
        guard blocks.indices.contains(index) else { return index..<index }
        var end = index + 1
        while end < blocks.count, blocks[end].indent > blocks[index].indent { end += 1 }
        return index..<end
    }
    /// The blocks shown: the contents of a closed toggle are hidden.
    static func visible(_ blocks: [DocBlock]) -> [DocBlock] {
        var result: [DocBlock] = [], hiddenBelow: Int?
        for block in blocks {
            if let level = hiddenBelow {
                if block.indent > level { continue }
                hiddenBelow = nil
            }
            result.append(block)
            if block.kind == .toggle, block.collapsed == true { hiddenBelow = block.indent }
        }
        return result
    }
    /// The number each numbered item shows: counting restarts after anything that isn't a
    /// numbered item at the same level (deeper items in between don't interrupt it).
    static func numbers(_ blocks: [DocBlock]) -> [UUID: Int] {
        var result: [UUID: Int] = [:], counters: [Int: Int] = [:]
        for block in blocks {
            for level in counters.keys where level > block.indent { counters[level] = nil }
            if block.kind == .numbered {
                let next = (counters[block.indent] ?? 0) + 1
                counters[block.indent] = next; result[block.id] = next
            } else { counters[block.indent] = nil }
        }
        return result
    }
    /// Indents a block and what's nested under it, one level, under the block above.
    @discardableResult static func indent(_ id: UUID, in blocks: inout [DocBlock]) -> Bool {
        guard let index = blocks.firstIndex(where: { $0.id == id }), index > 0,
              blocks[index].indent <= blocks[index - 1].indent, blocks[index].indent < DocBlock.maxIndent else { return false }
        for i in subtree(at: index, in: blocks) { blocks[i].indent = min(DocBlock.maxIndent, blocks[i].indent + 1) }
        return true
    }
    @discardableResult static func outdent(_ id: UUID, in blocks: inout [DocBlock]) -> Bool {
        guard let index = blocks.firstIndex(where: { $0.id == id }), blocks[index].indent > 0 else { return false }
        for i in subtree(at: index, in: blocks) { blocks[i].indent = max(0, blocks[i].indent - 1) }
        return true
    }
    /// Moves a block, with what's nested under it, to just before `target` (nil: to the end). It
    /// takes the target's level; its nested blocks keep their places relative to it.
    @discardableResult static func move(_ id: UUID, before target: UUID?, in blocks: inout [DocBlock]) -> Bool {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return false }
        let range = subtree(at: index, in: blocks)
        if let target, blocks[range].contains(where: { $0.id == target }) { return false }
        var moving = Array(blocks[range])
        var rest = blocks; rest.removeSubrange(range)
        let insertAt = target.flatMap { t in rest.firstIndex { $0.id == t } } ?? rest.count
        let level = target.flatMap { t in rest.first { $0.id == t }?.indent } ?? 0
        let shift = level - moving[0].indent
        for i in moving.indices { moving[i].indent = min(DocBlock.maxIndent, max(0, moving[i].indent + shift)) }
        rest.insert(contentsOf: moving, at: insertAt)
        guard rest.map(\.id) != blocks.map(\.id) || rest != blocks else { return false }
        blocks = rest
        return true
    }
    /// Moves a block above the previous block at its level (or its parent).
    @discardableResult static func moveUp(_ id: UUID, in blocks: inout [DocBlock]) -> Bool {
        guard let index = blocks.firstIndex(where: { $0.id == id }), index > 0 else { return false }
        let level = blocks[index].indent
        // Only past a sibling: a block never leaves its parent this way.
        guard let previous = blocks[..<index].lastIndex(where: { $0.indent <= level }), blocks[previous].indent == level else { return false }
        return move(id, before: blocks[previous].id, in: &blocks)
    }
    /// Moves a block below the next block at its level.
    @discardableResult static func moveDown(_ id: UUID, in blocks: inout [DocBlock]) -> Bool {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return false }
        let end = subtree(at: index, in: blocks).upperBound
        guard end < blocks.count, blocks[end].indent == blocks[index].indent else { return false }
        let level = blocks[index].indent
        let afterNext = subtree(at: end, in: blocks).upperBound
        let target = afterNext < blocks.count ? blocks[afterNext].id : nil
        guard move(id, before: target, in: &blocks) else { return false }
        // Moved to the end or before a shallower block: it keeps its own level.
        if let moved = blocks.firstIndex(where: { $0.id == id }), blocks[moved].indent != level {
            let shift = level - blocks[moved].indent
            for i in subtree(at: moved, in: blocks) { blocks[i].indent = min(DocBlock.maxIndent, max(0, blocks[i].indent + shift)) }
        }
        return true
    }
}

// MARK: Typing

/// Markdown shortcuts as you type, and the "/" and "@" menus' queries.
enum DocShortcuts {
    /// A paragraph that starts with a Markdown marker becomes that block, without the marker:
    /// `# `, `## `, `### `, `- ` or `* `, `1. `, `[] ` or `[ ] ` (and `[x] `), `> `, a code fence
    /// (```` ``` ```` then a space, with an optional language), and `---`.
    static func apply(_ block: DocBlock) -> DocBlock? {
        guard block.kind == .paragraph else { return nil }
        let text = block.text
        func strip(_ prefix: String, into kind: DocBlockKind) -> DocBlock {
            var next = block.turned(into: kind); next.text = String(text.dropFirst(prefix.count)); return next
        }
        for (prefix, kind) in [("### ", DocBlockKind.heading3), ("## ", .heading2), ("# ", .heading1), ("- [ ] ", .todo), ("- [x] ", .todo),
                               ("[ ] ", .todo), ("[] ", .todo), ("[x] ", .todo), ("- ", .bulleted), ("* ", .bulleted), ("> ", .quote)] where text.hasPrefix(prefix) {
            var next = strip(prefix, into: kind)
            if kind == .todo { next.checked = prefix.contains("x") }
            return next
        }
        if let match = text.firstMatch(of: #/^(\d{1,3})[.)] /#) {
            var next = block.turned(into: .numbered); next.text = String(text[match.range.upperBound...]); return next
        }
        if text == "---" || text == "***" || text == "___" { return block.turned(into: .divider) }
        if text.hasSuffix(" "), let fence = codeFence(String(text.dropLast())) {
            var next = block.turned(into: .code); next.text = ""; next.language = fence; return next
        }
        return nil
    }
    /// The language of a fence line ("```swift" → "swift"; "```" → ""), or nil when it isn't one.
    static func codeFence(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("```") else { return nil }
        let language = String(trimmed.dropFirst(3))
        guard language.count <= 20, language.allSatisfy({ $0.isLetter || $0.isNumber || "+#-_.".contains($0) }) else { return nil }
        return language.lowercased()
    }
    /// A menu trigger being typed: `/` or `@` at the start or after a space, followed by a query
    /// with no spaces, at the end of the text. Returns the character offset where the trigger starts.
    static func token(_ trigger: Character, in text: String) -> (start: Int, query: String)? {
        guard let at = text.lastIndex(of: trigger) else { return nil }
        let query = text[text.index(after: at)...]
        guard query.count <= 24, !query.contains(where: { $0.isWhitespace }), !query.contains(trigger) else { return nil }
        if at != text.startIndex {
            let before = text[text.index(before: at)]
            guard before.isWhitespace else { return nil }
        }
        return (text.distance(from: text.startIndex, to: at), String(query))
    }
    /// Removes the token found by `token` from the text.
    static func removing(tokenAt start: Int, in text: String) -> String {
        guard start >= 0, start <= text.count else { return text }
        return String(text.prefix(start)).replacingOccurrences(of: "\u{200B}", with: "")
    }
}

/// What the "/" menu offers: a block kind, or a new sub-page linked from here.
enum DocSlashItem: Hashable, Identifiable {
    case kind(DocBlockKind)
    case subPage
    var id: String { switch self { case .kind(let kind): kind.rawValue; case .subPage: "subPage" } }
    var title: String { switch self { case .kind(let kind): kind.title; case .subPage: "Sub-page" } }
    var symbol: String { switch self { case .kind(let kind): kind.symbol; case .subPage: "doc.badge.plus" } }
    private var keywords: [String] { switch self { case .kind(let kind): kind.keywords; case .subPage: ["page", "subpage", "sub-page", "new", "child"] } }
    static let all: [DocSlashItem] = DocBlockKind.allCases.map(DocSlashItem.kind) + [.subPage]
    /// Items whose name or keywords start with the query, best first.
    static func matching(_ query: String, in items: [DocSlashItem] = all) -> [DocSlashItem] {
        let q = query.lowercased()
        guard !q.isEmpty else { return items }
        let titled = items.filter { $0.title.lowercased().hasPrefix(q) || $0.title.lowercased().split(separator: " ").contains { $0.hasPrefix(q) } }
        let keyed = items.filter { item in !titled.contains(item) && item.keywords.contains { $0.hasPrefix(q) } }
        return titled + keyed
    }
}

// MARK: Inline formatting

enum DocInlineStyle: String, CaseIterable, Sendable {
    case bold, italic, code, strikethrough, link
    var marker: String {
        switch self { case .bold: "**"; case .italic: "_"; case .code: "`"; case .strikethrough: "~~"; case .link: "" }
    }
    var title: String { switch self { case .bold: "Bold"; case .italic: "Italic"; case .code: "Code"; case .strikethrough: "Strikethrough"; case .link: "Link" } }
    var symbol: String { switch self { case .bold: "bold"; case .italic: "italic"; case .code: "chevron.left.forwardslash.chevron.right"; case .strikethrough: "strikethrough"; case .link: "link" } }
}

enum DocInline {
    /// Applies (or removes) a style on the selected characters. Offsets are in characters; the
    /// result gives the new text and the selection to keep.
    static func toggle(_ style: DocInlineStyle, in text: String, range: Range<Int>) -> (text: String, selection: Range<Int>) {
        let characters = Array(text)
        let lower = max(0, min(range.lowerBound, characters.count)), upper = max(lower, min(range.upperBound, characters.count))
        let selected = String(characters[lower..<upper])
        if style == .link {
            // [selected](https://) with the address selected, ready to paste.
            let label = selected.isEmpty ? "link" : selected
            let inserted = "[" + label + "](https://)"
            let result = String(characters[..<lower]) + inserted + String(characters[upper...])
            let urlStart = lower + label.count + 3
            return (result, urlStart..<(urlStart + 8))
        }
        let marker = Array(style.marker), m = marker.count
        // Already wrapped just outside the selection: unwrap.
        if lower >= m, upper + m <= characters.count, Array(characters[(lower - m)..<lower]) == marker, Array(characters[upper..<(upper + m)]) == marker {
            let result = String(characters[..<(lower - m)]) + selected + String(characters[(upper + m)...])
            return (result, (lower - m)..<(upper - m))
        }
        // The selection itself includes the markers: unwrap.
        if selected.count >= 2 * m, selected.hasPrefix(style.marker), selected.hasSuffix(style.marker) {
            let inner = String(selected.dropFirst(m).dropLast(m))
            let result = String(characters[..<lower]) + inner + String(characters[upper...])
            return (result, lower..<(lower + inner.count))
        }
        let result = String(characters[..<lower]) + style.marker + selected + style.marker + String(characters[upper...])
        return (result, (lower + m)..<(upper + m))
    }
    /// Text without inline Markdown, for search, snippets, and titles.
    static func plain(_ text: String) -> String {
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return String(attributed.characters)
        }
        return text
    }
    /// The inline Markdown shown as formatted text. Page links (`kemo-doc:`) stay links.
    static func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
    /// A link to another page, as inline Markdown.
    static func pageLink(_ id: UUID, title: String) -> String {
        let label = title.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
        return "[" + (label.isEmpty ? "Untitled" : label) + "](" + pageScheme + ":" + id.uuidString + ")"
    }
    static let pageScheme = "kemo-doc"
    /// The page a `kemo-doc:` link points to.
    static func pageID(from url: URL) -> UUID? {
        guard url.scheme == pageScheme else { return nil }
        return UUID(uuidString: url.absoluteString.dropFirst(pageScheme.count + 1).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }
}

// MARK: Undo

/// Undo and redo for a page's blocks. Typing in one block is grouped into one step until you
/// pause or move to another block; every structural change is its own step.
struct DocUndoStack<Value: Equatable> {
    private(set) var undoStack: [Value] = []
    private(set) var redoStack: [Value] = []
    private var lastKey: String?
    private var lastTime: Date?
    let limit = 100
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    /// Saves the state before a change. A typing change with the same key within `window`
    /// seconds of the last one joins it.
    mutating func record(_ value: Value, typingIn key: String? = nil, at now: Date = Date(), window: TimeInterval = 1.2) {
        if let key, key == lastKey, let lastTime, now.timeIntervalSince(lastTime) < window {
            self.lastTime = now; return
        }
        if undoStack.last != value { undoStack.append(value) }
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        redoStack.removeAll()
        lastKey = key; lastTime = key == nil ? nil : now
    }
    mutating func undo(current: Value) -> Value? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current); lastKey = nil
        return previous
    }
    mutating func redo(current: Value) -> Value? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current); lastKey = nil
        return next
    }
    mutating func reset() { undoStack = []; redoStack = []; lastKey = nil; lastTime = nil }
}

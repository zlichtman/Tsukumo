import Foundation

/// Pages to and from Markdown. Export is what the share sheet sends; import turns a Markdown or
/// plain-text file into a page. The two round-trip: importing an exported page gives the same
/// blocks back.
///
/// - Headings `#`–`###`, lists `-`, `1.`, to-dos `- [ ]`/`- [x]`, quotes `>`, code fences,
///   `---`, and pipe tables, as usual. Nesting is two spaces per level.
/// - A toggle is a list item that starts with `▸ ` (it reads as a disclosure elsewhere).
/// - A callout is a note quote: `> [!NOTE]` then `> 💡 text`.
/// - An image is `![caption](file.jpg)`; a link to another page is `[Title](kemo-doc:ID)` on its own line.
enum DocMarkdown {
    static let togglePrefix = "▸ "

    // MARK: Export

    /// `forModel` writes images as their captions and page links as their titles, for a chat attachment.
    static func export(_ page: DocPage, forModel: Bool = false, title: (UUID) -> String? = { _ in nil }) -> String {
        var out = ""
        if !page.title.trimmingCharacters(in: .whitespaces).isEmpty { out = "# " + page.title + "\n\n" }
        return out + export(blocks: page.blocks, forModel: forModel, title: title)
    }

    static func export(blocks: [DocBlock], forModel: Bool = false, title: (UUID) -> String? = { _ in nil }) -> String {
        let numbers = DocOutline.numbers(blocks)
        var parts: [String] = []
        var previousWasList = false
        for block in blocks {
            let pad = String(repeating: "  ", count: block.indent)
            let isList = [.bulleted, .numbered, .todo, .toggle].contains(block.kind)
            var line: String
            switch block.kind {
            case .paragraph:
                if block.text.isEmpty { continue }
                line = pad + escaped(block.text).replacingOccurrences(of: "\n", with: "\n" + pad)
            case .heading1: line = pad + "# " + block.text
            case .heading2: line = pad + "## " + block.text
            case .heading3: line = pad + "### " + block.text
            case .bulleted: line = pad + "- " + block.text
            case .numbered: line = pad + "\(numbers[block.id] ?? 1). " + block.text
            case .todo: line = pad + (block.checked == true ? "- [x] " : "- [ ] ") + block.text
            case .toggle: line = pad + "- " + togglePrefix + block.text
            case .quote: line = block.text.split(separator: "\n", omittingEmptySubsequences: false).map { pad + "> " + $0 }.joined(separator: "\n")
            case .callout:
                let body = ((block.icon.map { $0 + " " }) ?? "") + block.text
                line = pad + "> [!NOTE]\n" + body.split(separator: "\n", omittingEmptySubsequences: false).map { pad + "> " + $0 }.joined(separator: "\n")
            case .code:
                let fence = block.text.contains("```") ? "~~~" : "```"
                line = pad + fence + (block.language ?? "") + "\n" + block.text.split(separator: "\n", omittingEmptySubsequences: false).map { pad + $0 }.joined(separator: "\n") + "\n" + pad + fence
            case .divider: line = pad + "---"
            case .image:
                guard let image = block.image else { continue }
                if forModel { line = pad + "[Image" + (block.text.isEmpty ? "" : ": " + block.text) + "]"; break }
                line = pad + "![" + block.text.replacingOccurrences(of: "]", with: ")") + "](" + image.file + ")"
            case .pageLink:
                guard let id = block.pageID else { continue }
                if forModel { line = pad + "Linked page: " + (title(id) ?? "Page"); break }
                line = pad + DocInline.pageLink(id, title: title(id) ?? "Page")
            case .table:
                var table = block.table ?? DocTable(); table.normalize()
                let rows = table.rows.map { pad + "| " + $0.map(cell).joined(separator: " | ") + " |" }
                let separator = pad + "|" + Array(repeating: " --- |", count: table.columnCount).joined()
                line = ([rows[0], separator] + rows.dropFirst()).joined(separator: "\n")
            }
            // List items sit on consecutive lines; everything else is separated by a blank line.
            if !parts.isEmpty { parts.append(isList && previousWasList ? "\n" : "\n\n") }
            parts.append(line)
            previousWasList = isList
        }
        return parts.joined() + (parts.isEmpty ? "" : "\n")
    }
    private static func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }
    /// A paragraph that would read as another block gets a backslash, so it comes back as text.
    private static func escaped(_ text: String) -> String {
        let markers = ["#", "- ", "* ", "+ ", "> ", "```", "~~~", "---", "***", "___", "|", "![", "\\"]
        if markers.contains(where: { text.hasPrefix($0) }) || text.firstMatch(of: #/^\d{1,9}[.)] /#) != nil { return "\\" + text }
        return text
    }

    // MARK: Import

    /// A page from Markdown. A first-line `# Title` becomes the page's title (otherwise
    /// `fallbackTitle`). `image` resolves an image's file name to a stored image (nil keeps its
    /// caption as text).
    static func page(from markdown: String, fallbackTitle: String = "", image: (String) -> DocImageRef? = { _ in nil }, now: Date = Date()) -> DocPage {
        var lines = normalizedLines(markdown)
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        var title = fallbackTitle
        if let first = lines.first, first.hasPrefix("# ") {
            title = String(first.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            lines.removeFirst()
        }
        var blocks = parse(lines, image: image)
        if blocks.isEmpty { blocks = [DocBlock()] }
        var page = DocPage(title: String(title.prefix(DocPage.maxTitle)), blocks: Array(blocks.prefix(DocPage.maxBlocks)), now: now)
        page.created = now; page.modified = now
        return page
    }
    /// Plain text: paragraphs separated by blank lines; single line breaks stay in the paragraph.
    static func page(fromPlainText text: String, title: String, now: Date = Date()) -> DocPage {
        let paragraphs = normalizedLines(text).split(whereSeparator: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map { $0.joined(separator: "\n") }
        let blocks = paragraphs.map { DocBlock(text: $0) }
        return DocPage(title: String(title.prefix(DocPage.maxTitle)), blocks: blocks.isEmpty ? [DocBlock()] : Array(blocks.prefix(DocPage.maxBlocks)), now: now)
    }

    private static func normalizedLines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    static func blocks(from markdown: String, image: (String) -> DocImageRef? = { _ in nil }) -> [DocBlock] {
        parse(normalizedLines(markdown), image: image)
    }

    private static func parse(_ lines: [String], image: (String) -> DocImageRef?) -> [DocBlock] {
        var blocks: [DocBlock] = []
        var i = 0
        func level(_ line: String) -> (indent: Int, rest: String) {
            var spaces = 0
            for character in line { if character == " " { spaces += 1 } else if character == "\t" { spaces += 2 } else { break } }
            return (min(DocBlock.maxIndent, spaces / 2), String(line.drop(while: { $0 == " " || $0 == "\t" })))
        }
        while i < lines.count {
            let raw = lines[i]
            let (indent, line) = level(raw)
            if line.isEmpty { i += 1; continue }
            // Code fence.
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                let fence = String(line.prefix(3))
                var block = DocBlock(kind: .code, indent: indent)
                block.language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased()
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    // Strip the block's own indentation from each line.
                    var text = lines[i]; var strip = indent * 2
                    while strip > 0, text.hasPrefix(" ") { text.removeFirst(); strip -= 1 }
                    body.append(text); i += 1
                }
                i += 1
                block.text = body.joined(separator: "\n")
                blocks.append(block); continue
            }
            // Table: a pipe row followed by a separator row.
            if line.hasPrefix("|"), i + 1 < lines.count, level(lines[i + 1]).rest.firstMatch(of: #/^\|?\s*:?-{2,}/#) != nil {
                var rows = [cells(line)]
                i += 2
                while i < lines.count, level(lines[i]).rest.hasPrefix("|") { rows.append(cells(level(lines[i]).rest)); i += 1 }
                var block = DocBlock(kind: .table, indent: indent)
                var table = DocTable(rows: rows); table.normalize(); block.table = table
                blocks.append(block); continue
            }
            // Quote or callout: consecutive `>` lines.
            if line.hasPrefix(">") {
                var body: [String] = []
                while i < lines.count {
                    let (_, rest) = level(lines[i])
                    guard rest.hasPrefix(">") else { break }
                    var text = String(rest.dropFirst())
                    if text.hasPrefix(" ") { text.removeFirst() }
                    body.append(text); i += 1
                }
                if let first = body.first, first.range(of: #"^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]"#, options: .regularExpression) != nil {
                    var block = DocBlock(kind: .callout, indent: indent)
                    var text = Array(body.dropFirst()).joined(separator: "\n")
                    block.icon = nil
                    if let emoji = text.first, isEmoji(emoji) {
                        block.icon = String(emoji); text = String(text.dropFirst()); if text.hasPrefix(" ") { text.removeFirst() }
                    }
                    block.text = text
                    blocks.append(block)
                } else {
                    blocks.append(DocBlock(kind: .quote, text: body.joined(separator: "\n"), indent: indent))
                }
                continue
            }
            i += 1
            if let match = line.firstMatch(of: #/^(#{1,6}) (.*)$/#) {
                let kind: DocBlockKind = match.1.count == 1 ? .heading1 : match.1.count == 2 ? .heading2 : .heading3
                blocks.append(DocBlock(kind: kind, text: String(match.2), indent: indent)); continue
            }
            if ["---", "***", "___"].contains(line.trimmingCharacters(in: .whitespaces)) {
                blocks.append(DocBlock(kind: .divider, indent: indent)); continue
            }
            if let match = line.firstMatch(of: #/^[-*+] \[([ xX])\] ?(.*)$/#) {
                var block = DocBlock(kind: .todo, text: String(match.2), indent: indent)
                block.checked = match.1 != " "
                blocks.append(block); continue
            }
            if let match = line.firstMatch(of: #/^[-*+] (.*)$/#) {
                let text = String(match.1)
                if text.hasPrefix(togglePrefix) {
                    blocks.append(DocBlock(kind: .toggle, text: String(text.dropFirst(togglePrefix.count)), indent: indent))
                } else { blocks.append(DocBlock(kind: .bulleted, text: text, indent: indent)) }
                continue
            }
            if let match = line.firstMatch(of: #/^\d{1,9}[.)] (.*)$/#) {
                blocks.append(DocBlock(kind: .numbered, text: String(match.1), indent: indent)); continue
            }
            if let match = line.firstMatch(of: #/^!\[(.*)\]\((.+)\)$/#) {
                let target = String(match.2)
                if let ref = image(URL(fileURLWithPath: target).lastPathComponent) {
                    var block = DocBlock(kind: .image, text: String(match.1), indent: indent); block.image = ref
                    blocks.append(block)
                } else if target.hasPrefix("http://") || target.hasPrefix("https://") {
                    blocks.append(DocBlock(text: "[" + (match.1.isEmpty ? "Image" : String(match.1)) + "](" + target + ")", indent: indent))
                } else if !match.1.isEmpty {
                    blocks.append(DocBlock(text: String(match.1), indent: indent))
                }
                continue
            }
            if let match = line.firstMatch(of: #/^\[(.*)\]\(kemo-doc:([0-9A-Fa-f-]{36})\)$/#), let id = UUID(uuidString: String(match.2)) {
                var block = DocBlock(kind: .pageLink, indent: indent); block.pageID = id
                blocks.append(block); continue
            }
            // A paragraph: this line and the ones after it until a blank line or another block.
            var text = line.hasPrefix("\\") ? String(line.dropFirst()) : line
            while i < lines.count {
                let (_, next) = level(lines[i])
                if next.isEmpty || startsBlock(next) { break }
                text += "\n" + next; i += 1
            }
            blocks.append(DocBlock(text: text, indent: indent))
        }
        return blocks
    }
    /// Whether a character is an emoji (not a digit or symbol that merely can be one).
    static func isEmoji(_ character: Character) -> Bool {
        guard let first = character.unicodeScalars.first else { return false }
        return first.properties.isEmojiPresentation || (character.unicodeScalars.count > 1 && first.properties.isEmoji)
    }
    private static func startsBlock(_ line: String) -> Bool {
        line.hasPrefix("#") || line.hasPrefix(">") || line.hasPrefix("```") || line.hasPrefix("~~~") || line.hasPrefix("|")
            || line.firstMatch(of: #/^[-*+] /#) != nil || line.firstMatch(of: #/^\d{1,9}[.)] /#) != nil
            || ["---", "***", "___"].contains(line.trimmingCharacters(in: .whitespaces)) || line.hasPrefix("![")
    }
    private static func cells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") && !trimmed.hasSuffix("\\|") { trimmed.removeLast() }
        var cells: [String] = [], current = "", escaping = false
        for character in trimmed {
            if escaping { current.append(character); escaping = false; continue }
            if character == "\\" { escaping = true; continue }
            if character == "|" { cells.append(current.trimmingCharacters(in: .whitespaces)); current = ""; continue }
            current.append(character)
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }
}

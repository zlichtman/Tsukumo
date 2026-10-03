import SwiftUI
import AppKit

// MARK: Blocks

/// Agent replies as Markdown blocks. Written for streaming: a code fence that hasn't closed yet
/// is shown as code up to the end, and a half-typed table row is just a paragraph until its
/// separator line arrives. Inline syntax (bold, code, links) is left to `AttributedString`.
enum CodingMarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([CodingMarkdownListItem])
    case quote([CodingMarkdownBlock])
    case code(language: String, text: String, closed: Bool)
    case table(header: [String], alignments: [CodingMarkdownAlignment], rows: [[String]])
    case rule
}
struct CodingMarkdownListItem: Equatable {
    /// Nesting depth, 0 for top-level items.
    var depth: Int
    /// "•" for bullets, or the item's number with its punctuation ("3.").
    var marker: String
    var text: String
    /// A task-list checkbox (`- [ ]` or `- [x]`), when the item has one.
    var checked: Bool?
}
enum CodingMarkdownAlignment: Equatable { case leading, center, trailing }

enum CodingMarkdown {
    static func parse(_ source: String) -> [CodingMarkdownBlock] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [CodingMarkdownBlock] = []
        var paragraph: [String] = []
        var items: [CodingMarkdownListItem] = []
        var index = 0
        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        func flushList() { if !items.isEmpty { blocks.append(.list(items)); items = [] } }
        func flush() { flushParagraph(); flushList() }
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Fenced code: ``` or ~~~, with an optional language; unclosed runs to the end.
            if let fence = fenceMarker(trimmed) {
                flush()
                let language = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
                var body: [String] = [], closed = false
                let indent = line.prefix { $0 == " " }.count
                index += 1
                while index < lines.count {
                    let inner = lines[index]
                    if inner.trimmingCharacters(in: .whitespaces).hasPrefix(fence), inner.trimmingCharacters(in: .whitespaces).allSatisfy({ $0 == fence.first }) { closed = true; index += 1; break }
                    // Code inside an indented list item drops that indent.
                    body.append(String(inner.dropFirst(min(indent, inner.prefix { $0 == " " }.count))))
                    index += 1
                }
                blocks.append(.code(language: language.lowercased(), text: body.joined(separator: "\n"), closed: closed))
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                // A blank line inside a list ends it only if what follows isn't another item.
                if !items.isEmpty, let next = lines[(index + 1)...].first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }), listItem(next) == nil { flushList() }
                index += 1; continue
            }
            if let heading = heading(trimmed) { flush(); blocks.append(heading); index += 1; continue }
            if isRule(trimmed) { flush(); blocks.append(.rule); index += 1; continue }
            if trimmed.hasPrefix(">") {
                flush()
                var quoted: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var inner = lines[index].trimmingCharacters(in: .whitespaces).dropFirst()
                    if inner.first == " " { inner = inner.dropFirst() }
                    quoted.append(String(inner)); index += 1
                }
                blocks.append(.quote(parse(quoted.joined(separator: "\n"))))
                continue
            }
            if trimmed.contains("|"), index + 1 < lines.count, let alignments = tableSeparator(lines[index + 1]) {
                flush()
                let header = cells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count {
                    let row = lines[index].trimmingCharacters(in: .whitespaces)
                    guard !row.isEmpty, row.contains("|") else { break }
                    var values = cells(row)
                    if values.count < header.count { values += Array(repeating: "", count: header.count - values.count) }
                    rows.append(Array(values.prefix(header.count))); index += 1
                }
                let aligned = alignments.count >= header.count ? Array(alignments.prefix(header.count)) : alignments + Array(repeating: .leading, count: header.count - alignments.count)
                blocks.append(.table(header: header, alignments: aligned, rows: rows))
                continue
            }
            if let item = listItem(line) {
                flushParagraph(); items.append(item); index += 1; continue
            }
            // A continuation line of a list item (indented, or simply the next line of its text).
            if !items.isEmpty, paragraph.isEmpty {
                items[items.count - 1].text += "\n" + trimmed; index += 1; continue
            }
            paragraph.append(line); index += 1
        }
        flush()
        return blocks
    }
    private static func fenceMarker(_ trimmed: String) -> String? {
        for fence in ["````", "```", "~~~"] where trimmed.hasPrefix(fence) { return fence }
        return nil
    }
    private static func heading(_ trimmed: String) -> CodingMarkdownBlock? {
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return .heading(level: hashes, text: text.trimmingCharacters(in: .whitespaces))
    }
    private static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }
    static func listItem(_ line: String) -> CodingMarkdownListItem? {
        let spaces = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let body = line.drop { $0 == " " || $0 == "\t" }
        var marker: String, rest: Substring
        if let first = body.first, "-*+".contains(first), body.dropFirst().first == " " {
            marker = "•"; rest = body.dropFirst(2)
        } else {
            let digits = body.prefix { $0.isNumber }
            guard !digits.isEmpty, digits.count <= 9 else { return nil }
            let after = body.dropFirst(digits.count)
            guard let punctuation = after.first, punctuation == "." || punctuation == ")", after.dropFirst().first == " " else { return nil }
            marker = String(digits) + "."; rest = after.dropFirst(2)
        }
        var checked: Bool?
        if rest.hasPrefix("[ ] ") { checked = false; rest = rest.dropFirst(4) }
        else if rest.hasPrefix("[x] ") || rest.hasPrefix("[X] ") { checked = true; rest = rest.dropFirst(4) }
        return .init(depth: spaces / 2, marker: marker, text: rest.trimmingCharacters(in: .whitespaces), checked: checked)
    }
    private static func tableSeparator(_ line: String) -> [CodingMarkdownAlignment]? {
        let parts = cells(line.trimmingCharacters(in: .whitespaces))
        guard !parts.isEmpty, line.contains("-") else { return nil }
        var alignments: [CodingMarkdownAlignment] = []
        for part in parts {
            let cell = part.trimmingCharacters(in: .whitespaces)
            guard !cell.isEmpty, cell.allSatisfy({ $0 == "-" || $0 == ":" }), cell.contains("-") else { return nil }
            alignments.append(cell.hasPrefix(":") && cell.hasSuffix(":") ? .center : cell.hasSuffix(":") ? .trailing : .leading)
        }
        return alignments
    }
    /// A table row's cells; `\|` is a literal bar, and the outer bars are optional.
    static func cells(_ row: String) -> [String] {
        var trimmed = row
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") && !trimmed.hasSuffix("\\|") { trimmed.removeLast() }
        var cells: [String] = [], current = "", escaped = false
        for character in trimmed {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "|" { cells.append(current.trimmingCharacters(in: .whitespaces)); current = ""; continue }
            current.append(character)
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }
    /// Inline Markdown (bold, italics, code, links, strikethrough) with inline code in the code font.
    static func inline(_ text: String, code: Font) -> AttributedString {
        var result = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible))) ?? AttributedString(text)
        for run in result.runs where run.inlinePresentationIntent?.contains(.code) == true {
            result[run.range].font = code
            result[run.range].backgroundColor = Color.primary.opacity(0.07)
        }
        return result
    }
}

// MARK: Syntax colors

/// A small, fast highlighter for code blocks and diffs: keywords, strings, comments, numbers,
/// and type names, by language family. It never fails; unknown languages get the C-like rules.
enum CodingSyntax {
    enum Kind: Equatable { case plain, keyword, string, comment, number, type }
    struct Segment: Equatable { var text: String; var kind: Kind }
    private static let keywords: [String: Set<String>] = [
        "swift": ["import", "func", "let", "var", "class", "struct", "enum", "protocol", "extension", "if", "else", "guard", "return", "switch", "case", "default", "for", "in", "while", "repeat", "break", "continue", "throw", "throws", "try", "catch", "do", "async", "await", "public", "private", "fileprivate", "internal", "static", "final", "override", "init", "deinit", "self", "Self", "true", "false", "nil", "some", "any", "where", "defer", "inout", "mutating", "weak", "unowned", "lazy", "typealias", "associatedtype", "actor", "nonisolated", "is", "as"],
        "c": ["auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long", "register", "return", "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile", "while", "class", "public", "private", "protected", "namespace", "template", "typename", "new", "delete", "this", "true", "false", "nullptr", "NULL", "virtual", "override", "using", "import", "package", "interface", "extends", "implements", "final", "throws", "throw", "try", "catch", "finally", "boolean", "null", "fun", "val", "var", "func", "go", "defer", "chan", "map", "range", "select", "type", "struct", "fn", "let", "mut", "impl", "trait", "pub", "use", "mod", "crate", "match", "loop", "self", "Self", "super", "where", "async", "await", "move", "ref", "dyn", "as", "in"],
        "js": ["const", "let", "var", "function", "return", "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "new", "delete", "typeof", "instanceof", "in", "of", "class", "extends", "super", "this", "import", "export", "from", "as", "async", "await", "yield", "try", "catch", "finally", "throw", "true", "false", "null", "undefined", "interface", "type", "enum", "implements", "public", "private", "protected", "readonly", "static", "void", "never", "unknown", "any", "keyof", "satisfies"],
        "python": ["def", "class", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "is", "import", "from", "as", "with", "try", "except", "finally", "raise", "pass", "break", "continue", "lambda", "yield", "global", "nonlocal", "async", "await", "True", "False", "None", "self", "assert", "del", "match", "case"],
        "ruby": ["def", "class", "module", "end", "if", "elsif", "else", "unless", "while", "until", "for", "in", "do", "return", "yield", "begin", "rescue", "ensure", "raise", "self", "nil", "true", "false", "and", "or", "not", "then", "require", "attr_accessor"],
        "shell": ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until", "case", "esac", "function", "return", "export", "local", "readonly", "echo", "cd", "set", "unset", "source", "exit", "true", "false"],
        "json": ["true", "false", "null"],
        "sql": ["select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table", "index", "drop", "alter", "join", "left", "right", "inner", "outer", "on", "group", "by", "order", "limit", "and", "or", "not", "null", "as", "primary", "key", "references", "distinct", "having", "union"],
    ]
    /// The language family for a fence's language tag or a file extension.
    static func family(_ language: String) -> String {
        switch language.lowercased() {
        case "swift": "swift"
        case "js", "javascript", "jsx", "ts", "typescript", "tsx", "mjs", "cjs": "js"
        case "py", "python": "python"
        case "rb", "ruby": "ruby"
        case "sh", "bash", "zsh", "shell", "console", "fish": "shell"
        case "json", "jsonc": "json"
        case "sql": "sql"
        case "yaml", "yml", "toml", "ini", "dockerfile", "makefile", "text", "txt", "plaintext", "markdown", "md": "plain"
        case "diff", "patch": "diff"
        default: "c"
        }
    }
    static func segments(_ code: String, language: String) -> [Segment] {
        let family = family(language)
        if family == "diff" {
            return code.split(separator: "\n", omittingEmptySubsequences: false).enumerated().flatMap { index, line -> [Segment] in
                let kind: Kind = line.hasPrefix("+") ? .string : line.hasPrefix("-") ? .keyword : line.hasPrefix("@@") ? .type : .plain
                return (index > 0 ? [Segment(text: "\n", kind: .plain)] : []) + [Segment(text: String(line), kind: kind)]
            }
        }
        let words = keywords[family] ?? []
        let hashComments = ["python", "ruby", "shell", "plain"].contains(family) || language.lowercased() == "yaml" || language.lowercased() == "yml" || language.lowercased() == "toml"
        let slashComments = !["python", "ruby", "shell", "json", "plain"].contains(family)
        let dashComments = family == "sql"
        var out: [Segment] = []
        func add(_ text: String, _ kind: Kind) {
            guard !text.isEmpty else { return }
            if let last = out.last, last.kind == kind { out[out.count - 1].text += text } else { out.append(.init(text: text, kind: kind)) }
        }
        let chars = Array(code)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if (slashComments && c == "/" && next == "/") || (hashComments && c == "#") || (dashComments && c == "-" && next == "-") {
                var j = i; while j < chars.count, chars[j] != "\n" { j += 1 }
                add(String(chars[i..<j]), .comment); i = j; continue
            }
            if slashComments && c == "/" && next == "*" {
                var j = i + 2
                while j < chars.count, !(chars[j] == "*" && j + 1 < chars.count && chars[j + 1] == "/") { j += 1 }
                j = min(chars.count, j + 2)
                add(String(chars[i..<j]), .comment); i = j; continue
            }
            if c == "\"" || c == "'" || c == "`" {
                // Triple-quoted strings (Swift, Python) run to their closing triple.
                if next == c, i + 2 < chars.count, chars[i + 2] == c {
                    var j = i + 3
                    while j + 2 < chars.count, !(chars[j] == c && chars[j + 1] == c && chars[j + 2] == c) { j += 1 }
                    j = min(chars.count, j + 3)
                    add(String(chars[i..<j]), .string); i = j; continue
                }
                // A lone apostrophe in prose-like languages isn't a string.
                if c == "'" && (family == "swift" || family == "plain") { add(String(c), .plain); i += 1; continue }
                var j = i + 1
                while j < chars.count, chars[j] != c, chars[j] != "\n" || c == "`" { if chars[j] == "\\" { j += 1 }; j += 1 }
                j = min(chars.count, j + 1)
                add(String(chars[i..<j]), .string); i = j; continue
            }
            if c.isNumber, i == 0 || !(chars[i - 1].isLetter || chars[i - 1] == "_") {
                var j = i
                while j < chars.count, chars[j].isHexDigit || chars[j] == "." || chars[j] == "_" || chars[j] == "x" || chars[j] == "b" || chars[j] == "o" { j += 1 }
                add(String(chars[i..<j]), .number); i = j; continue
            }
            if c.isLetter || c == "_" || c == "@" || c == "$" {
                var j = i + 1
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                let word = String(chars[i..<j])
                let lookup = family == "sql" ? word.lowercased() : word
                if words.contains(lookup) { add(word, .keyword) }
                else if family != "plain", family != "json", family != "shell", word.first?.isUppercase == true, word.count > 1 { add(word, .type) }
                else { add(word, .plain) }
                i = j; continue
            }
            add(String(c), .plain); i += 1
        }
        return out
    }
    static func color(_ kind: Kind) -> Color {
        switch kind {
        case .plain: .primary
        case .keyword: Color(nsColor: .systemPink)
        case .string: Color(nsColor: .systemGreen)
        case .comment: .secondary
        case .number: Color(nsColor: .systemOrange)
        case .type: Color(nsColor: .systemTeal)
        }
    }
    static func attributed(_ code: String, language: String, font: Font) -> AttributedString {
        var result = AttributedString()
        for segment in segments(code, language: language) {
            var piece = AttributedString(segment.text)
            piece.foregroundColor = color(segment.kind); piece.font = font
            if segment.kind == .comment { piece.font = font.italic() }
            result += piece
        }
        return result
    }
}

// MARK: Views

/// Renders an agent's Markdown: headings, paragraphs, lists with checkboxes, quotes, tables, rules,
/// and code blocks with syntax colors and a copy button.
struct CodingMarkdownView: View {
    let text: String
    var codeSize: CGFloat = 12
    var body: some View {
        let blocks = CodingMarkdown.parse(text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in CodingMarkdownBlockView(block: block, codeSize: codeSize) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
private struct CodingMarkdownBlockView: View {
    let block: CodingMarkdownBlock
    let codeSize: CGFloat
    var body: some View {
        let code = Font.system(size: codeSize, design: .monospaced)
        switch block {
        case .heading(let level, let text):
            Text(CodingMarkdown.inline(text, code: code)).font(.system(size: level == 1 ? 19 : level == 2 ? 16 : 14, weight: .semibold))
                .padding(.top, level <= 2 ? 4 : 2).textSelection(.enabled)
        case .paragraph(let text):
            Text(CodingMarkdown.inline(text, code: code)).lineSpacing(3).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        case .list(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        if let checked = item.checked {
                            Image(systemName: checked ? "checkmark.square.fill" : "square").foregroundStyle(checked ? Color.accentColor : .secondary).font(.system(size: 12))
                        } else {
                            Text(item.marker).foregroundStyle(.secondary).monospacedDigit().frame(minWidth: item.marker == "•" ? 8 : 16, alignment: .trailing)
                        }
                        Text(CodingMarkdown.inline(item.text, code: code)).lineSpacing(3).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            .strikethrough(item.checked == true, color: .secondary)
                    }.padding(.leading, CGFloat(item.depth) * 18)
                }
            }
        case .quote(let blocks):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.35)).frame(width: 3)
                VStack(alignment: .leading, spacing: 8) { ForEach(Array(blocks.enumerated()), id: \.offset) { _, inner in CodingMarkdownBlockView(block: inner, codeSize: codeSize) } }
                    .foregroundStyle(.secondary)
            }
        case .code(let language, let text, _):
            CodingCodeBlock(code: text, language: language, size: codeSize)
        case .table(let header, let alignments, let rows):
            CodingMarkdownTable(header: header, alignments: alignments, rows: rows, code: code)
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }
}
private struct CodingMarkdownTable: View {
    let header: [String]
    let alignments: [CodingMarkdownAlignment]
    let rows: [[String]]
    let code: Font
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow { ForEach(header.indices, id: \.self) { cell(header[$0], column: $0).fontWeight(.semibold) } }
                    .background(Color.primary.opacity(0.05))
                ForEach(rows.indices, id: \.self) { row in
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow { ForEach(header.indices, id: \.self) { cell(rows[row][$0], column: $0) } }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
    private func cell(_ text: String, column: Int) -> some View {
        let alignment: Alignment = (column < alignments.count ? alignments[column] : .leading) == .center ? .center : (column < alignments.count ? alignments[column] : .leading) == .trailing ? .trailing : .leading
        return Text(CodingMarkdown.inline(text, code: code)).textSelection(.enabled).padding(.horizontal, 10).padding(.vertical, 6)
            .frame(minWidth: 60, maxWidth: 360, alignment: alignment).gridColumnAlignment(alignment == .center ? .center : alignment == .trailing ? .trailing : .leading)
    }
}
/// A code block: language and Copy in a header row, colored code that scrolls sideways, and long
/// blocks folded to their first lines until expanded.
struct CodingCodeBlock: View {
    let code: String
    let language: String
    var size: CGFloat = 12
    var foldAfter = 30
    @State private var expanded = false
    @State private var copied = false
    var body: some View {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        let folded = !expanded && lines.count > foldAfter + 6
        let shown = folded ? lines.prefix(foldAfter).joined(separator: "\n") : code
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(language.isEmpty ? "code" : language).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button { copy() } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11)).labelStyle(.titleAndIcon)
                }.buttonStyle(DesktopRowButtonStyle(inset: 4)).accessibilityLabel("Copy code")
            }.padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 4)
            Divider().opacity(0.5)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(CodingSyntax.attributed(shown, language: language, font: .system(size: size, design: .monospaced)))
                    .textSelection(.enabled).fixedSize(horizontal: true, vertical: true).padding(12)
            }
            if lines.count > foldAfter + 6 {
                Button(expanded ? "Show less" : "Show all \(lines.count) lines") { expanded.toggle() }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 8)
            }
        }
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
    private func copy() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
    }
}

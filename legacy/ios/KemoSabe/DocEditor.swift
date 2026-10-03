import ImageIO
import SwiftUI
import UniformTypeIdentifiers
#if canImport(PhotosUI)
import PhotosUI
#endif

// The block editor shared by Docs and Journal on iPhone and Mac. Each block is edited as inline
// Markdown in its own field and shown formatted when you move on; `/` opens the block menu, `@`
// links a page, Markdown shortcuts turn a line into a heading, list, to-do, quote, code, or
// divider as you type, Return continues a list, and deleting an empty block removes it.
// See design/DOCS-AND-JOURNAL.md and the UI guide.

enum DocEditorText {
    /// An empty block holds one invisible character, so deleting it (the keyboard's delete on an
    /// empty line) can be seen and remove the block.
    static let sentinel = "\u{200B}"
}

/// What one editor is doing: which block is being edited, the selection, the open menu, and undo.
@MainActor @Observable final class DocEditorModel {
    struct Menu: Equatable {
        enum Trigger: Equatable { case slash, mention }
        var trigger: Trigger
        var block: UUID
        var start: Int
        var query: String
    }
    /// The block shown as a text field (the rest are shown formatted).
    var editing: UUID?
    var selection: TextSelection?
    var menu: Menu?
    var highlighted = 0
    var undo = DocUndoStack<[DocBlock]>()
    /// Bumped to rebuild a block's field when its text must be reset (after deleting an empty block's marker).
    var epochs: [UUID: Int] = [:]
    /// A block waiting for an image, or for a page to link.
    var imageFor: UUID?
    var linkFor: UUID?
    var pickingImage = false
    var pickingLink = false
    /// A focus request the editor carries out once the block's field exists.
    private(set) var focusRequest: UUID?
    private(set) var requestToken = 0
    /// Where the cursor goes in the requested block: its start, or its end (nil).
    private(set) var cursorAtStart = false
    func request(_ id: UUID, atStart: Bool = false) {
        editing = id; focusRequest = id; cursorAtStart = atStart; requestToken += 1
    }
    func bump(_ id: UUID) { epochs[id, default: 0] += 1 }
}

/// Everything the editor needs from where it's shown.
struct DocEditorHost {
    let docs: DocsStore
    /// The page being edited (nil in a journal entry): sub-pages go under it, and `@` leaves it out.
    var pageID: UUID?
    var openPage: (UUID) -> Void
    /// Text shown in an empty first block (a journal prompt, or the block hint).
    var firstPlaceholder: String?
    /// The space under the last block that continues the page when tapped.
    var trailingSpace: CGFloat = 80
}

extension DocBlocksEditor {
    /// The grip's width and gap: the editor sits this far into the margin so text lines up with the title.
    static let gutter: CGFloat = 22
}

struct DocBlocksEditor: View {
    @Binding var blocks: [DocBlock]
    @Bindable var model: DocEditorModel
    let host: DocEditorHost
    @FocusState private var focus: UUID?

    var body: some View {
        let visible = DocOutline.visible(blocks)
        let numbers = DocOutline.numbers(blocks)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, block in
                VStack(alignment: .leading, spacing: 0) {
                    DocBlockRow(block: block, index: index, number: numbers[block.id], editing: model.editing == block.id,
                                epoch: model.epochs[block.id] ?? 0, focus: $focus, text: textBinding(block.id), selection: selectionBinding(block.id),
                                host: host, placeholder: placeholder(for: block, at: index), isFirst: index == 0,
                                actions: actions(for: block.id))
                    if let menu = model.menu, menu.block == block.id { menuView(menu) }
                }
                .dropDestination(for: String.self) { items, _ in _ = drop(items, before: block.id) }
            }
            // Tapping below the last block continues the page.
            Color.clear.frame(height: host.trailingSpace).contentShape(Rectangle())
                .onTapGesture { appendParagraphIfNeeded() }
                .dropDestination(for: String.self) { items, _ in _ = drop(items, before: nil) }
                .accessibilityIdentifier("docEditorEnd")
        }
        .environment(\.openURL, OpenURLAction { url in
            if let id = DocInline.pageID(from: url) { host.openPage(id); return .handled }
            return .systemAction
        })
        .onChange(of: focus) { _, new in
            if let new { model.editing = new; return }
            // A field that loses focus shows formatted again, unless another block is taking over.
            let pending = model.editing
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                if focus == nil, model.editing == pending { model.editing = nil; model.menu = nil }
            }
        }
        .onChange(of: model.requestToken) { focusRequested() }
        .docImagePicker(isPresented: $model.pickingImage, docs: host.docs, limit: 1) { refs in addImage(refs.first) }
        .sheet(isPresented: $model.pickingLink) {
            DocPagePicker(docs: host.docs, title: "Link to page", excluding: host.pageID.map { [$0] } ?? [], choose: { id in linkPage(id) }, cancel: { linkPage(nil) })
        }
    }

    // MARK: Bindings

    private func index(_ id: UUID) -> Int? { blocks.firstIndex { $0.id == id } }
    private func textBinding(_ id: UUID) -> Binding<String> {
        Binding(get: {
            guard let block = blocks.first(where: { $0.id == id }) else { return "" }
            return block.text.isEmpty ? DocEditorText.sentinel : block.text
        }, set: { textChanged(id, $0) })
    }
    private func selectionBinding(_ id: UUID) -> Binding<TextSelection?> {
        Binding(get: { model.editing == id ? model.selection : nil }, set: { if model.editing == id { model.selection = $0 } })
    }
    private func placeholder(for block: DocBlock, at index: Int) -> String? {
        guard block.text.isEmpty else { return nil }
        if index == 0, blocks.count == 1, let first = host.firstPlaceholder { return first }
        switch block.kind {
        case .paragraph: return model.editing == block.id ? "Type / for blocks, @ to link a page" : nil
        case .heading1, .heading2, .heading3: return block.kind.title
        case .bulleted, .numbered: return "List"
        case .todo: return "To-do"
        case .toggle: return "Toggle"
        case .quote: return "Quote"
        case .callout: return "Callout"
        case .code: return "Code"
        case .image: return "Add a caption"
        default: return nil
        }
    }
    private func focusRequested() {
        guard let id = model.focusRequest else { return }
        let atStart = model.cursorAtStart
        Task { @MainActor in
            // The field appears on the next pass; focus it then.
            try? await Task.sleep(for: .milliseconds(30))
            focus = id
            if atStart, let block = blocks.first(where: { $0.id == id }), !block.text.isEmpty {
                model.selection = TextSelection(insertionPoint: block.text.startIndex)
            }
        }
    }

    // MARK: Typing

    private func textChanged(_ id: UUID, _ raw: String) {
        guard let i = index(id) else { return }
        let old = blocks[i]
        if raw.isEmpty { deletedAtEmpty(i); return }
        let value = raw.replacingOccurrences(of: DocEditorText.sentinel, with: "")
        guard value != old.text else { return }
        // Return: a new line typed into a block that isn't code.
        if old.kind != .code, let newline = Self.insertedNewline(old: old.text, new: value) {
            if let menu = model.menu, menu.block == id {
                // Return picks the highlighted menu item.
                let text = String(value.prefix(newline)) + String(value.dropFirst(newline + 1))
                blocks[i].text = text
                chooseHighlighted(menu)
                return
            }
            let before = String(value.prefix(newline))
            if old.kind == .paragraph, let language = DocShortcuts.codeFence(before), before.hasPrefix("```") {
                model.undo.record(blocks)
                var code = old.turned(into: .code); code.text = String(value.dropFirst(newline + 1)); code.language = language
                blocks[i] = code; model.bump(id)
                return
            }
            split(at: i, text: value, newline: newline)
            return
        }
        model.undo.record(blocks, typingIn: id.uuidString)
        var block = old
        block.text = value
        if let converted = DocShortcuts.apply(block) {
            model.undo.record(blocks)
            blocks[i] = converted
            model.menu = nil
            if converted.kind == .divider {
                let next = DocBlock(indent: converted.indent)
                blocks.insert(next, at: i + 1)
                model.request(next.id)
            } else if converted.kind.layoutGroup != old.kind.layoutGroup {
                // A quote, callout, or code block is laid out differently: its field is new.
                model.request(id)
            }
            return
        }
        blocks[i] = block
        updateMenu(for: block)
    }
    /// Where a single new line was typed, as a character offset.
    static func insertedNewline(old: String, new: String) -> Int? {
        let a = Array(old), b = Array(new)
        guard b.filter({ $0 == "\n" }).count > a.filter({ $0 == "\n" }).count else { return nil }
        var p = 0
        while p < a.count, p < b.count, a[p] == b[p] { p += 1 }
        // The new line is at the first difference (or right after an identical run of new lines).
        while p < b.count, b[p] != "\n" { p += 1 }
        return p < b.count ? p : nil
    }
    private func split(at i: Int, text value: String, newline: Int) {
        model.undo.record(blocks)
        let before = String(value.prefix(newline)), after = String(value.dropFirst(newline + 1))
        var current = blocks[i]
        // Return on an empty list item ends the list (or steps out one level).
        if current.kind.continuesOnReturn || current.kind == .toggle, before.isEmpty, after.isEmpty {
            if current.indent > 0 { DocOutline.outdent(current.id, in: &blocks) }
            else { blocks[i] = current.turned(into: .paragraph) }
            model.bump(current.id); model.request(current.id)
            return
        }
        current.text = before
        var next = DocBlock(text: after, indent: current.indent)
        switch current.kind {
        case .bulleted, .numbered, .todo: next = next.turned(into: current.kind); next.checked = current.kind == .todo ? false : nil
        case .toggle:
            // Inside an open toggle, the next line is its first item.
            if current.collapsed != true { next.indent = min(DocBlock.maxIndent, current.indent + 1) } else { next = next.turned(into: .toggle) }
        default: break
        }
        blocks[i] = current
        // After a closed toggle, the new block goes after its hidden contents.
        let insertAt = current.kind == .toggle && current.collapsed == true ? DocOutline.subtree(at: i, in: blocks).upperBound : i + 1
        blocks.insert(next, at: insertAt)
        model.bump(current.id)
        model.menu = nil
        model.request(next.id, atStart: true)
    }
    /// The invisible marker of an empty block was deleted: turn a list item or heading back into
    /// text, step out a level, or remove the block and go to the one above.
    private func deletedAtEmpty(_ i: Int) {
        let block = blocks[i]
        model.menu = nil
        model.undo.record(blocks)
        if block.kind != .paragraph {
            blocks[i] = block.turned(into: .paragraph)
            model.bump(block.id); model.request(block.id); return
        }
        if block.indent > 0 {
            DocOutline.outdent(block.id, in: &blocks)
            model.bump(block.id); model.request(block.id); return
        }
        guard blocks.count > 1, i > 0 else { model.bump(block.id); model.request(block.id); return }
        blocks.remove(at: i)
        if let previous = blocks[..<i].lastIndex(where: { $0.kind.hasText && $0.kind != .image }) {
            let id = blocks[previous].id
            model.bump(id); model.request(id)
        } else { model.editing = nil }
    }
    /// Delete at the start of a non-empty block (hardware keyboards): join it to the block above.
    private func mergeWithPrevious(_ id: UUID) -> Bool {
        guard let i = index(id), i > 0, let selection = model.selection, case .selection(let range) = selection.indices,
              range.isEmpty, range.lowerBound == blocks[i].text.startIndex, !blocks[i].text.isEmpty else { return false }
        let previousIndex = i - 1
        guard blocks[previousIndex].kind.hasText, blocks[previousIndex].kind != .image else { return false }
        model.undo.record(blocks)
        let join = blocks[previousIndex].text.count
        blocks[previousIndex].text += blocks[i].text
        blocks.remove(at: i)
        let previous = blocks[previousIndex]
        model.bump(previous.id); model.request(previous.id)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            if let text = blocks.first(where: { $0.id == previous.id })?.text, let point = text.index(text.startIndex, offsetBy: join, limitedBy: text.endIndex) {
                model.selection = TextSelection(insertionPoint: point)
            }
        }
        return true
    }
    private func appendParagraphIfNeeded() {
        if let last = blocks.last, last.kind == .paragraph, last.text.isEmpty { model.request(last.id); return }
        model.undo.record(blocks)
        let block = DocBlock()
        blocks.append(block)
        model.request(block.id)
    }

    // MARK: Menus

    private func updateMenu(for block: DocBlock) {
        if let token = DocShortcuts.token("/", in: block.text), block.kind != .code {
            let menu = DocEditorModel.Menu(trigger: .slash, block: block.id, start: token.start, query: token.query)
            if model.menu != menu { model.highlighted = 0 }
            model.menu = DocSlashItem.matching(token.query, in: slashItems).isEmpty ? nil : menu
        } else if let token = DocShortcuts.token("@", in: block.text), block.kind != .code {
            let menu = DocEditorModel.Menu(trigger: .mention, block: block.id, start: token.start, query: token.query)
            if model.menu != menu { model.highlighted = 0 }
            model.menu = menu
        } else { model.menu = nil }
    }
    private var slashItems: [DocSlashItem] { host.pageID == nil ? DocSlashItem.all.filter { $0 != .subPage } : DocSlashItem.all }
    private func mentionPages(_ query: String) -> [DocPage] {
        let q = query.lowercased()
        return host.docs.livePages.filter { $0.id != host.pageID && (q.isEmpty || $0.displayTitle.lowercased().contains(q)) }
            .sorted { $0.modified > $1.modified }.prefix(6).map { $0 }
    }
    @ViewBuilder private func menuView(_ menu: DocEditorModel.Menu) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            switch menu.trigger {
            case .slash:
                let items = Array(DocSlashItem.matching(menu.query, in: slashItems).prefix(9))
                ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                    menuRow(title: item.title, symbol: item.symbol, highlighted: offset == model.highlighted, identifier: "slashItem-" + item.id) { applySlash(item, menu: menu) }
                }
            case .mention:
                let pages = mentionPages(menu.query)
                if pages.isEmpty { Text("No pages match").font(KemoType.font(.footnote)).foregroundStyle(.secondary).padding(10) }
                ForEach(Array(pages.enumerated()), id: \.element.id) { offset, page in
                    menuRow(title: page.displayTitle, symbol: "doc.text", icon: page.icon, highlighted: offset == model.highlighted, identifier: "mentionPage-" + page.displayTitle) { insertMention(page, menu: menu) }
                }
            }
        }
        .padding(4)
        .frame(maxWidth: 300, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .padding(.leading, 28).padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(menu.trigger == .slash ? "slashMenu" : "mentionMenu")
    }
    private func menuRow(title: String, symbol: String, icon: DocIcon? = nil, highlighted: Bool, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    if let icon { DocIconView(icon: icon, size: 15) } else { Image(systemName: symbol).font(.system(size: 13, weight: .medium)) }
                }.frame(width: 26, height: 26).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                Text(title).font(KemoType.font(.subheadline)).lineLimit(1)
                Spacer(minLength: 0)
            }.padding(.horizontal, 8).padding(.vertical, 5).contentShape(Rectangle())
                .background(highlighted ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).accessibilityIdentifier(identifier)
    }
    private func chooseHighlighted(_ menu: DocEditorModel.Menu) {
        switch menu.trigger {
        case .slash:
            let items = DocSlashItem.matching(menu.query, in: slashItems)
            if items.indices.contains(model.highlighted) { applySlash(items[model.highlighted], menu: menu) } else { model.menu = nil }
        case .mention:
            let pages = mentionPages(menu.query)
            if pages.indices.contains(model.highlighted) { insertMention(pages[model.highlighted], menu: menu) } else { model.menu = nil }
        }
    }
    private func moveHighlight(_ step: Int) -> Bool {
        guard let menu = model.menu else { return false }
        let count = menu.trigger == .slash ? min(9, DocSlashItem.matching(menu.query, in: slashItems).count) : mentionPages(menu.query).count
        guard count > 0 else { return false }
        model.highlighted = (model.highlighted + step + count) % count
        return true
    }
    private func applySlash(_ item: DocSlashItem, menu: DocEditorModel.Menu) {
        guard let i = index(menu.block) else { model.menu = nil; return }
        model.undo.record(blocks)
        model.menu = nil
        var block = blocks[i]
        block.text = DocShortcuts.removing(tokenAt: menu.start, in: block.text)
        let empty = block.text.trimmingCharacters(in: .whitespaces).isEmpty
        switch item {
        case .subPage:
            blocks[i] = block
            guard let child = host.docs.createPage(parent: host.pageID) else { return }
            var link = DocBlock(kind: .pageLink, indent: block.indent); link.pageID = child.id
            if empty { link.id = block.id; blocks[i] = link } else { blocks.insert(link, at: i + 1) }
            host.openPage(child.id)
        case .kind(let kind):
            switch kind {
            case .divider, .table, .pageLink, .image:
                var inserted = DocBlock(kind: kind, indent: block.indent)
                if empty { inserted.id = block.id; blocks[i] = inserted } else { blocks[i] = block; blocks.insert(inserted, at: i + 1) }
                if kind == .image { model.imageFor = inserted.id; model.pickingImage = true }
                else if kind == .pageLink { model.linkFor = inserted.id; model.pickingLink = true }
                else {
                    let insertedIndex = empty ? i : i + 1
                    let next = DocBlock(indent: block.indent)
                    blocks.insert(next, at: insertedIndex + 1)
                    if kind == .divider { model.request(next.id) } else { model.editing = nil }
                }
            default:
                blocks[i] = block.turned(into: kind)
                model.bump(block.id); model.request(block.id)
            }
        }
    }
    private func insertMention(_ page: DocPage, menu: DocEditorModel.Menu) {
        guard let i = index(menu.block) else { model.menu = nil; return }
        model.undo.record(blocks)
        blocks[i].text = DocShortcuts.removing(tokenAt: menu.start, in: blocks[i].text) + DocInline.pageLink(page.id, title: page.displayTitle) + " "
        model.menu = nil
        model.bump(menu.block); model.request(menu.block)
    }
    private func addImage(_ ref: DocImageRef?) {
        defer { model.imageFor = nil }
        guard let id = model.imageFor, let i = index(id) else { return }
        guard let ref else {
            // Nothing chosen: an empty image block goes away.
            if blocks[i].image == nil { blocks.remove(at: i); if blocks.isEmpty { blocks = [DocBlock()] } }
            return
        }
        blocks[i].kind = .image; blocks[i].image = ref
        if i == blocks.count - 1 { blocks.append(DocBlock(indent: blocks[i].indent)) }
    }
    private func linkPage(_ id: UUID?) {
        defer { model.linkFor = nil; model.pickingLink = false }
        guard let blockID = model.linkFor, let i = index(blockID) else { return }
        guard let id else { if blocks[i].pageID == nil { blocks.remove(at: i); if blocks.isEmpty { blocks = [DocBlock()] } }; return }
        blocks[i].kind = .pageLink; blocks[i].pageID = id
    }

    // MARK: Block actions

    private func actions(for id: UUID) -> DocBlockActions {
        DocBlockActions(
            turnInto: { kind in mutate { if let i = index(id) { blocks[i] = blocks[i].turned(into: kind) } }; model.request(id) },
            toggleChecked: { mutate { if let i = index(id) { blocks[i].checked = !(blocks[i].checked ?? false) } } },
            toggleCollapsed: { mutate { if let i = index(id) { blocks[i].collapsed = !(blocks[i].collapsed ?? false) } } },
            setLanguage: { language in if let i = index(id) { blocks[i].language = language } },
            setIcon: { icon in if let i = index(id) { blocks[i].icon = icon } },
            setTable: { table in if let i = index(id) { model.undo.record(blocks, typingIn: "table-" + id.uuidString); blocks[i].table = table } },
            indent: { mutate { DocOutline.indent(id, in: &blocks) } },
            outdent: { mutate { DocOutline.outdent(id, in: &blocks) } },
            moveUp: { mutate { DocOutline.moveUp(id, in: &blocks) } },
            moveDown: { mutate { DocOutline.moveDown(id, in: &blocks) } },
            duplicate: { mutate { if let i = index(id) { let range = DocOutline.subtree(at: i, in: blocks); let copies = blocks[range].map { var b = $0; b.id = UUID(); return b }; blocks.insert(contentsOf: copies, at: range.upperBound) } } },
            // An image's file stays until the page is deleted for good, so Undo can bring it back.
            delete: { mutate { if let i = index(id) { blocks.removeSubrange(DocOutline.subtree(at: i, in: blocks)); if blocks.isEmpty { blocks = [DocBlock()] } } } },
            replaceImage: { model.imageFor = id; model.pickingImage = true },
            choosePage: { model.linkFor = id; model.pickingLink = true },
            focus: { model.request(id) },
            submit: { submitReturn(id) },
            keyTab: { shift in mutate { if shift { DocOutline.outdent(id, in: &blocks) } else { DocOutline.indent(id, in: &blocks) } }; model.request(id) },
            keyDelete: { mergeWithPrevious(id) },
            keyArrow: { step in
                if moveHighlight(step) { return true }
                return moveFocus(from: id, step: step)
            },
            keyEscape: { if model.menu != nil { model.menu = nil; return true }; return false },
            dragPayload: "kemo-block:" + id.uuidString
        )
    }
    private func mutate(_ change: () -> Void) {
        model.undo.record(blocks)
        change()
    }
    /// Return on a Mac (a multi-line field submits): split at the cursor, or add a line in code.
    private func submitReturn(_ id: UUID) {
        guard let i = index(id) else { return }
        let text = blocks[i].text
        var offset = text.count
        if let selection = model.selection, case .selection(let range) = selection.indices {
            offset = text.distance(from: text.startIndex, to: min(range.upperBound, text.endIndex))
        }
        let characters = Array(text)
        let updated = String(characters.prefix(offset)) + "\n" + String(characters.dropFirst(offset))
        if blocks[i].kind == .code {
            blocks[i].text = updated
            model.bump(id); model.request(id)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
                if let text = blocks.first(where: { $0.id == id })?.text, let point = text.index(text.startIndex, offsetBy: offset + 1, limitedBy: text.endIndex) {
                    model.selection = TextSelection(insertionPoint: point)
                }
            }
            return
        }
        textChanged(id, updated)
    }
    private func moveFocus(from id: UUID, step: Int) -> Bool {
        let visible = DocOutline.visible(blocks).filter { $0.kind.hasText }
        guard let i = visible.firstIndex(where: { $0.id == id }) else { return false }
        let text = visible[i].text
        if let selection = model.selection, case .selection(let range) = selection.indices {
            if step < 0, range.lowerBound != text.startIndex { return false }
            if step > 0, range.upperBound != text.endIndex, !text.isEmpty { return false }
        }
        let j = i + step
        guard visible.indices.contains(j) else { return false }
        model.request(visible[j].id, atStart: step > 0)
        return true
    }
    private func drop(_ items: [String], before target: UUID?) -> Bool {
        guard let item = items.first, item.hasPrefix("kemo-block:"), let id = UUID(uuidString: String(item.dropFirst("kemo-block:".count))),
              id != target else { return false }
        model.undo.record(blocks)
        return DocOutline.move(id, before: target, in: &blocks)
    }

    // MARK: Formatting (called from the format bar)

    /// Applies an inline style to the selection in the block being edited.
    static func format(_ style: DocInlineStyle, blocks: inout [DocBlock], model: DocEditorModel) {
        guard let id = model.editing, let i = blocks.firstIndex(where: { $0.id == id }), blocks[i].kind.hasText, blocks[i].kind != .code else { return }
        let text = blocks[i].text
        var range = text.count..<text.count
        if let selection = model.selection, case .selection(let selected) = selection.indices, !text.isEmpty {
            let lower = text.distance(from: text.startIndex, to: min(selected.lowerBound, text.endIndex))
            let upper = text.distance(from: text.startIndex, to: min(selected.upperBound, text.endIndex))
            range = lower..<max(lower, upper)
        }
        model.undo.record(blocks)
        let result = DocInline.toggle(style, in: text, range: range)
        blocks[i].text = result.text
        model.bump(id); model.request(id)
        let updated = result.text
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            guard let lower = updated.index(updated.startIndex, offsetBy: result.selection.lowerBound, limitedBy: updated.endIndex),
                  let upper = updated.index(updated.startIndex, offsetBy: result.selection.upperBound, limitedBy: updated.endIndex) else { return }
            model.selection = TextSelection(range: lower..<upper)
        }
    }
    static func turn(_ kind: DocBlockKind, blocks: inout [DocBlock], model: DocEditorModel) {
        guard let id = model.editing, let i = blocks.firstIndex(where: { $0.id == id }) else { return }
        model.undo.record(blocks)
        blocks[i] = blocks[i].turned(into: kind)
        model.request(id)
    }
    static func shift(indent: Bool, blocks: inout [DocBlock], model: DocEditorModel) {
        guard let id = model.editing else { return }
        model.undo.record(blocks)
        if indent { DocOutline.indent(id, in: &blocks) } else { DocOutline.outdent(id, in: &blocks) }
        model.request(id)
    }
    static func undo(blocks: inout [DocBlock], model: DocEditorModel) {
        guard let previous = model.undo.undo(current: blocks) else { return }
        blocks = previous; model.editing = nil; model.menu = nil
    }
    static func redo(blocks: inout [DocBlock], model: DocEditorModel) {
        guard let next = model.undo.redo(current: blocks) else { return }
        blocks = next; model.editing = nil; model.menu = nil
    }
}

/// What a block row can ask its editor to do.
struct DocBlockActions {
    var turnInto: (DocBlockKind) -> Void
    var toggleChecked: () -> Void
    var toggleCollapsed: () -> Void
    var setLanguage: (String) -> Void
    var setIcon: (String) -> Void
    var setTable: (DocTable) -> Void
    var indent: () -> Void
    var outdent: () -> Void
    var moveUp: () -> Void
    var moveDown: () -> Void
    var duplicate: () -> Void
    var delete: () -> Void
    var replaceImage: () -> Void
    var choosePage: () -> Void
    var focus: () -> Void
    var submit: () -> Void
    var keyTab: (Bool) -> Void
    var keyDelete: () -> Bool
    var keyArrow: (Int) -> Bool
    var keyEscape: () -> Bool
    var dragPayload: String
}

// MARK: One block

struct DocBlockRow: View {
    let block: DocBlock
    let index: Int
    let number: Int?
    let editing: Bool
    let epoch: Int
    var focus: FocusState<UUID?>.Binding
    @Binding var text: String
    @Binding var selection: TextSelection?
    let host: DocEditorHost
    let placeholder: String?
    let isFirst: Bool
    let actions: DocBlockActions
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            handle
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                marker
                content
            }
        }
        .padding(.leading, CGFloat(block.indent) * 24)
        .padding(.top, topPadding).padding(.bottom, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        #if os(macOS)
        .onHover { hovering = $0 }
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("docBlock-\(index)")
        .accessibilityValue(block.kind.rawValue)
    }
    private var topPadding: CGFloat {
        switch block.kind {
        case .heading1: isFirst ? 4 : 18
        case .heading2: isFirst ? 4 : 14
        case .heading3: isFirst ? 4 : 10
        case .divider: 6
        default: 3
        }
    }

    // The grip: drag to reorder, tap for the block's actions.
    private var handle: some View {
        Menu {
            Menu("Turn into") {
                ForEach(DocBlockKind.textKinds) { kind in
                    Button(kind.title, systemImage: kind.symbol) { actions.turnInto(kind) }
                }
            }
            Button("Duplicate", systemImage: "plus.square.on.square") { actions.duplicate() }
            Button("Move up", systemImage: "arrow.up") { actions.moveUp() }
            Button("Move down", systemImage: "arrow.down") { actions.moveDown() }
            Button("Indent", systemImage: "increase.indent") { actions.indent() }
            Button("Outdent", systemImage: "decrease.indent") { actions.outdent() }
            if block.kind == .image { Button("Replace image", systemImage: "photo") { actions.replaceImage() } }
            if block.kind == .pageLink { Button("Choose page", systemImage: "doc.text") { actions.choosePage() } }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { actions.delete() }
        } label: {
            Image(systemName: "circle.grid.2x3.fill").font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary).frame(width: 18, height: 22).contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .opacity(editing || hovering ? 1 : 0)
        .draggable(actions.dragPayload) { Label(block.kind.title, systemImage: block.kind.symbol).padding(8) }
        .accessibilityLabel("Block actions")
        .accessibilityIdentifier("docBlockActions-\(index)")
    }

    @ViewBuilder private var marker: some View {
        switch block.kind {
        case .bulleted:
            Text(["•", "◦", "▪︎"][block.indent % 3]).font(KemoType.font(.body, weight: .bold)).frame(width: 18)
        case .numbered:
            Text("\(number ?? 1).").font(KemoType.font(.body).monospacedDigit()).frame(minWidth: 18, alignment: .trailing)
        case .todo:
            Button(action: actions.toggleChecked) {
                Image(systemName: block.checked == true ? "checkmark.square.fill" : "square").font(.system(size: 17))
                    .foregroundStyle(block.checked == true ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }.buttonStyle(.plain).frame(width: 20)
                .accessibilityLabel(block.checked == true ? "Done" : "Not done").accessibilityIdentifier("docTodo-\(index)")
        case .toggle:
            Button(action: actions.toggleCollapsed) {
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
                    .rotationEffect(.degrees(block.collapsed == true ? 0 : 90)).frame(width: 18, height: 18)
            }.buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel(block.collapsed == true ? "Show contents" : "Hide contents").accessibilityIdentifier("docToggle-\(index)")
        default: EmptyView()
        }
    }

    @ViewBuilder private var content: some View {
        switch block.kind {
        case .divider:
            Rectangle().fill(Color.primary.opacity(0.14)).frame(height: 1).frame(maxWidth: .infinity).padding(.vertical, 8)
                .draggable(actions.dragPayload)
        case .image: imageContent
        case .pageLink: pageLinkContent
        case .table:
            DocTableEditor(table: block.table ?? DocTable(), set: actions.setTable)
        case .code: codeContent
        case .quote:
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.primary.opacity(0.35)).frame(width: 3)
                textContent
            }.fixedSize(horizontal: false, vertical: true)
        case .callout:
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Menu {
                    ForEach(["💡", "📌", "⚠️", "✅", "❓", "🔥", "📝", "🌱"], id: \.self) { emoji in Button(emoji) { actions.setIcon(emoji) } }
                } label: { Text(block.icon ?? "💡").font(.system(size: 18)) }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                    .accessibilityLabel("Callout icon")
                textContent
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        default: textContent
        }
    }

    private var font: Font {
        switch block.kind {
        case .heading1: KemoType.font(.title, weight: .bold)
        case .heading2: KemoType.font(.title2, weight: .semibold)
        case .heading3: KemoType.font(.title3, weight: .semibold)
        case .code: .system(.callout, design: .monospaced)
        default: KemoType.font(.body)
        }
    }

    /// The field while editing, the formatted text otherwise.
    @ViewBuilder private var textContent: some View {
        ZStack(alignment: .topLeading) {
            if let placeholder, block.text.isEmpty {
                Text(placeholder).font(font).foregroundStyle(.tertiary).allowsHitTesting(false).lineLimit(1)
                    .accessibilityHidden(true)
            }
            if editing { field } else { rendered }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var field: some View {
        TextField("", text: $text, selection: $selection, axis: .vertical)
            .textFieldStyle(.plain).font(font)
            .focused(focus, equals: block.id)
            .id(epoch)
            .onSubmit { submit() }
            .onKeyPress(.tab, phases: .down) { press in actions.keyTab(press.modifiers.contains(.shift)); return .handled }
            .onKeyPress(.delete) { actions.keyDelete() ? .handled : .ignored }
            .onKeyPress(.upArrow) { actions.keyArrow(-1) ? .handled : .ignored }
            .onKeyPress(.downArrow) { actions.keyArrow(1) ? .handled : .ignored }
            .onKeyPress(.escape) { actions.keyEscape() ? .handled : .ignored }
            .accessibilityIdentifier("docBlockEditing")
            .accessibilityLabel(block.kind.title)
    }
    private func submit() {
        #if os(macOS)
        actions.submit()
        #endif
    }
    private var rendered: some View {
        Text(block.text.isEmpty ? AttributedString(" ") : DocInline.attributed(block.text))
            .font(font)
            .strikethrough(block.kind == .todo && block.checked == true)
            .foregroundStyle(block.kind == .todo && block.checked == true ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { actions.focus() }
            .draggable(actions.dragPayload) { Text(DocInline.plain(block.text).prefix(40)).padding(8) }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Edit")
    }

    private var codeContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Menu {
                    ForEach(DocCodeLanguages.all, id: \.self) { language in
                        Button(language.isEmpty ? "Plain text" : language) { actions.setLanguage(language) }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text((block.language ?? "").isEmpty ? "Plain text" : block.language!).font(KemoType.font(.caption, weight: .medium))
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    }.foregroundStyle(.secondary)
                }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).accessibilityLabel("Code language")
                Spacer()
                Button {
                    #if os(iOS)
                    UIPasteboard.general.string = block.text
                    #elseif os(macOS)
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(block.text, forType: .string)
                    #endif
                } label: { Image(systemName: "doc.on.doc").font(.system(size: 11)) }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Copy code")
            }
            textContent
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var imageContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image = block.image {
                DocImageView(docs: host.docs, ref: image, maxHeight: 420)
                    .draggable(actions.dragPayload)
            } else {
                Button(action: actions.replaceImage) {
                    Label("Add an image", systemImage: "photo.badge.plus").font(KemoType.font(.subheadline))
                        .frame(maxWidth: .infinity).padding(.vertical, 22)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain)
            }
            textContent.font(KemoType.font(.footnote)).foregroundStyle(.secondary)
        }
    }

    private var pageLinkContent: some View {
        let page = host.docs.page(block.pageID)
        return Button {
            if let id = block.pageID, page?.trashed == nil, page != nil { host.openPage(id) } else { actions.choosePage() }
        } label: {
            HStack(spacing: 8) {
                if let icon = page?.icon { DocIconView(icon: icon, size: 16) } else { Image(systemName: "doc.text").foregroundStyle(.secondary) }
                Text(page.map { $0.trashed == nil ? $0.displayTitle : $0.displayTitle + " (in Trash)" } ?? "Choose a page")
                    .font(KemoType.font(.body, weight: .medium)).underline(page != nil, color: .primary.opacity(0.25))
                Image(systemName: "arrow.up.forward").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }.padding(.vertical, 3).contentShape(Rectangle())
        }.buttonStyle(.plain).draggable(actions.dragPayload)
            .accessibilityIdentifier("docPageLink-\(page?.displayTitle ?? "none")")
    }
}

extension DocBlockKind {
    /// Kinds drawn the same way share a group; changing between groups gives the block a new field.
    var layoutGroup: Int {
        switch self {
        case .quote: 1
        case .callout: 2
        case .code: 3
        case .divider, .image, .pageLink, .table: 4
        default: 0
        }
    }
}

enum DocCodeLanguages {
    static let all = ["", "swift", "python", "javascript", "typescript", "json", "bash", "html", "css", "markdown", "sql", "go", "rust", "ruby", "kotlin", "java", "c", "cpp", "yaml"]
}

// MARK: Table

struct DocTableEditor: View {
    let table: DocTable
    let set: (DocTable) -> Void
    var body: some View {
        var normalized = table; normalized.normalize()
        let columns = normalized.columnCount
        return VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(normalized.rows.indices, id: \.self) { row in
                        GridRow {
                            ForEach(0..<columns, id: \.self) { column in
                                TextField(row == 0 ? "Header" : "", text: Binding(get: { normalized.rows[row][column] }, set: { value in
                                    var next = normalized; next.rows[row][column] = String(value.prefix(500)); set(next)
                                }), axis: .vertical)
                                .textFieldStyle(.plain)
                                .font(row == 0 ? KemoType.font(.subheadline, weight: .semibold) : KemoType.font(.subheadline))
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .frame(minWidth: 96, maxWidth: 220, alignment: .leading)
                                .background(row == 0 ? Color.primary.opacity(0.05) : .clear)
                                .overlay(Rectangle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                                .accessibilityIdentifier("docTableCell-\(row)-\(column)")
                            }
                        }
                    }
                }
            }
            HStack(spacing: 14) {
                Button("Row", systemImage: "plus") { var next = normalized; next.rows.append(Array(repeating: "", count: columns)); next.normalize(); set(next) }
                    .disabled(normalized.rows.count >= DocTable.maxRows)
                Button("Column", systemImage: "plus") { var next = normalized; next.rows = next.rows.map { $0 + [""] }; next.normalize(); set(next) }
                    .disabled(columns >= DocTable.maxColumns)
                Menu {
                    Button("Remove last row", role: .destructive) { var next = normalized; if next.rows.count > 1 { next.rows.removeLast() }; set(next) }
                        .disabled(normalized.rows.count <= 1)
                    Button("Remove last column", role: .destructive) { var next = normalized; if columns > 1 { next.rows = next.rows.map { Array($0.dropLast()) } }; set(next) }
                        .disabled(columns <= 1)
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 20) }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                    .accessibilityLabel("Table options")
            }.font(KemoType.font(.caption)).buttonStyle(.plain).foregroundStyle(.secondary)
        }
    }
}

// MARK: Icons, images, and pickers

struct DocIconView: View {
    let icon: DocIcon
    var size: CGFloat = 16
    var body: some View {
        switch icon.kind {
        case .emoji: Text(icon.value).font(.system(size: size))
        case .symbol: Image(systemName: icon.value).font(.system(size: size * 0.9, weight: .medium)).foregroundStyle(.tint)
        }
    }
}

/// A page's icon or the page symbol, for lists.
struct DocPageLabel: View {
    let page: DocPage
    var body: some View {
        Label {
            Text(page.displayTitle).lineLimit(1)
        } icon: {
            if let icon = page.icon { DocIconView(icon: icon, size: 16) } else { Image(systemName: "doc.text").foregroundStyle(.secondary) }
        }
    }
}

/// Emoji and symbols a page can use as its icon.
enum DocIconChoices {
    static let emoji = ["📄", "📝", "📚", "📌", "💡", "🗺️", "✈️", "🏠", "🍳", "🎵", "🎨", "🌱", "🧠", "💼", "🎯", "⭐️", "🔥", "🌊", "☀️", "🌙", "❤️", "🧪", "📷", "🛒"]
    static let symbols = ["doc.text", "book.closed", "bookmark", "star", "heart", "lightbulb", "list.bullet", "checklist", "calendar", "house", "briefcase", "cart", "airplane", "map", "leaf", "paintpalette", "music.note", "camera", "fork.knife", "graduationcap", "hammer", "flag", "globe", "sparkles"]
}

/// The app's cover gradients, in its own palette.
enum DocCovers {
    static let gradients: [(id: String, colors: [Color])] = [
        ("dawn", [Color(red: 0.98, green: 0.62, blue: 0.52), Color(red: 0.55, green: 0.33, blue: 0.55)]),
        ("lagoon", [Color(red: 0.36, green: 0.72, blue: 0.74), Color(red: 0.2, green: 0.36, blue: 0.56)]),
        ("sage", [Color(red: 0.72, green: 0.8, blue: 0.64), Color(red: 0.36, green: 0.5, blue: 0.4)]),
        ("sun", [Color(red: 1, green: 0.84, blue: 0.5), Color(red: 0.95, green: 0.55, blue: 0.4)]),
        ("plum", [Color(red: 0.42, green: 0.27, blue: 0.47), Color(red: 0.2, green: 0.14, blue: 0.27)]),
        ("graphite", [Color(red: 0.5, green: 0.52, blue: 0.56), Color(red: 0.22, green: 0.23, blue: 0.26)])
    ]
    static func colors(_ id: String) -> [Color] { gradients.first { $0.id == id }?.colors ?? gradients[0].colors }
}

/// An image from the Docs folder, loaded off the main thread.
struct DocImageView: View {
    let docs: DocsStore
    let ref: DocImageRef
    var maxHeight: CGFloat = 360
    var fill = false
    @State private var image: CGImage?
    @State private var missing = false
    var body: some View {
        Group {
            if let image {
                let picture = Image(decorative: image, scale: 1).resizable()
                if fill { picture.scaledToFill() } else { picture.scaledToFit().frame(maxHeight: maxHeight) }
            } else {
                ZStack {
                    Rectangle().fill(Color.primary.opacity(0.06))
                    if missing {
                        Label("Waiting for this photo", systemImage: "photo").font(KemoType.font(.caption)).foregroundStyle(.secondary)
                    }
                }.aspectRatio(CGFloat(max(1, ref.width)) / CGFloat(max(1, ref.height)), contentMode: .fit).frame(maxHeight: fill ? nil : maxHeight)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: ref.file) {
            let url = docs.assetURL(ref.file)
            let loaded = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1600] as CFDictionary)
            }.value
            image = loaded; missing = loaded == nil
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("Photo").accessibilityAddTraits(.isImage)
    }
}

/// Chooses pages: for a link block, or where to move a page.
struct DocPagePicker: View {
    let docs: DocsStore
    let title: String
    var excluding: Set<UUID> = []
    /// Offers "Top level" first (for moving a page).
    var offersTopLevel = false
    /// The chosen page, or nil for "Top level".
    let choose: (UUID?) -> Void
    var cancel: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    var body: some View {
        NavigationStack {
            List {
                if offersTopLevel {
                    Button { choose(nil); dismiss() } label: { Label("Top level", systemImage: "square.stack") }.accessibilityIdentifier("movePageTopLevel")
                }
                ForEach(docs.livePages.filter { !excluding.contains($0.id) && (query.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(query)) }
                    .sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }) { page in
                    Button { choose(page.id); dismiss() } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            DocPageLabel(page: page)
                            let path = DocOutline.path(to: page.id, in: docs.pages).map(\.displayTitle)
                            if !path.isEmpty { Text(path.joined(separator: " › ")).font(KemoType.font(.caption)).foregroundStyle(.secondary).padding(.leading, 30) }
                        }
                    }.buttonStyle(.plain).accessibilityIdentifier("pickPage-" + page.displayTitle)
                }
            }
            .searchable(text: $query)
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { cancel(); dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 420)
        #endif
    }
}

extension View {
    /// Adds photos to Docs or Journal from the photo library, the camera (iPhone), or Files.
    func docImagePicker(isPresented: Binding<Bool>, docs: DocsStore, limit: Int, add: @escaping ([DocImageRef]) -> Void) -> some View {
        modifier(DocImagePicker(isPresented: isPresented, docs: docs, limit: limit, add: add))
    }
}

private struct DocImagePicker: ViewModifier {
    @Binding var isPresented: Bool
    let docs: DocsStore
    let limit: Int
    let add: ([DocImageRef]) -> Void
    @State private var library = false
    @State private var camera = false
    @State private var files = false
    @State private var items: [PhotosPickerItem] = []
    @State private var chose = false
    func body(content: Content) -> some View {
        content
            .confirmationDialog("Add a photo", isPresented: $isPresented, titleVisibility: .hidden) {
                Button("Photo Library") { chose = true; library = true }
                #if os(iOS)
                Button("Camera") { chose = true; camera = true }
                #endif
                Button("Files") { chose = true; files = true }
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                    Button("Sample photo") { chose = true; addData([DocSamplePhoto.jpeg()]) }.accessibilityIdentifier("docSamplePhoto")
                }
                #endif
                Button("Cancel", role: .cancel) { }
            }
            .onChange(of: isPresented) { _, open in
                if open { chose = false } else {
                    Task { @MainActor in try? await Task.sleep(for: .milliseconds(300)); if !chose, !library, !camera, !files { add([]) } }
                }
            }
            .photosPicker(isPresented: $library, selection: $items, maxSelectionCount: limit, matching: .images)
            .onChange(of: items) {
                let picked = items; items = []
                guard !picked.isEmpty else { return }
                Task {
                    var data: [Data] = []
                    for item in picked { if let value = try? await PickedImage.load(item) { data.append(value) } }
                    addData(data)
                }
            }
            .fileImporter(isPresented: $files, allowedContentTypes: [.image], allowsMultipleSelection: limit > 1) { result in
                guard case .success(let urls) = result else { add([]); return }
                let data = urls.prefix(limit).compactMap { url -> Data? in
                    let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    return try? Data(contentsOf: url)
                }
                addData(Array(data))
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $camera) {
                CameraSheet { photo in
                    if let ref = try? docs.addImage(photo.jpeg) { add([ref]) }
                }
            }
            #endif
    }
    private func addData(_ data: [Data]) {
        var refs: [DocImageRef] = []
        for item in data.prefix(limit) {
            do { refs.append(try docs.addImage(item)) } catch { docs.error = error.localizedDescription }
        }
        add(refs)
    }
}

#if DEBUG
/// A drawn photo for UI tests and screenshots (no photo library in the test runner).
enum DocSamplePhoto {
    static func jpeg(width: Int = 900, height: Int = 600) -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Data() }
        let colors = [CGColor(red: 0.98, green: 0.62, blue: 0.52, alpha: 1), CGColor(red: 0.36, green: 0.3, blue: 0.55, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        }
        context.setFillColor(CGColor(red: 1, green: 0.95, blue: 0.85, alpha: 0.9))
        context.fillEllipse(in: CGRect(x: width * 2 / 3, y: height * 3 / 5, width: height / 4, height: height / 4))
        guard let image = context.makeImage() else { return Data() }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }
}
#endif

// MARK: Format bar

/// Inline styles, block type, indent, and undo, for the block being edited: the keyboard's bar on
/// iPhone, a bar over the page on Mac (with ⌘B, ⌘I, ⌘E, ⌘K, ⌘] and ⌘[).
struct DocFormatBar: View {
    @Binding var blocks: [DocBlock]
    @Bindable var model: DocEditorModel
    var compact = false
    var body: some View {
        HStack(spacing: compact ? 2 : 4) {
            Menu {
                ForEach(DocBlockKind.textKinds) { kind in
                    Button(kind.title, systemImage: kind.symbol) { DocBlocksEditor.turn(kind, blocks: &blocks, model: model) }
                }
            } label: { Image(systemName: "textformat").frame(width: 32, height: 30) }
                .menuIndicator(.hidden).accessibilityLabel("Turn into").accessibilityIdentifier("docTurnInto")
            ForEach([DocInlineStyle.bold, .italic, .code, .strikethrough, .link], id: \.self) { style in
                Button { DocBlocksEditor.format(style, blocks: &blocks, model: model) } label: {
                    Image(systemName: style.symbol).frame(width: 30, height: 30)
                }.accessibilityLabel(style.title).accessibilityIdentifier("docFormat-" + style.rawValue)
                    .keyboardShortcut(Self.key(style), modifiers: style == .strikethrough ? [.command, .shift] : .command)
            }
            Divider().frame(height: 18)
            Button { DocBlocksEditor.shift(indent: false, blocks: &blocks, model: model) } label: { Image(systemName: "decrease.indent").frame(width: 30, height: 30) }
                .accessibilityLabel("Outdent").keyboardShortcut("[", modifiers: .command)
            Button { DocBlocksEditor.shift(indent: true, blocks: &blocks, model: model) } label: { Image(systemName: "increase.indent").frame(width: 30, height: 30) }
                .accessibilityLabel("Indent").keyboardShortcut("]", modifiers: .command)
            Divider().frame(height: 18)
            Button { DocBlocksEditor.undo(blocks: &blocks, model: model) } label: { Image(systemName: "arrow.uturn.backward").frame(width: 30, height: 30) }
                .disabled(!model.undo.canUndo).accessibilityLabel("Undo").accessibilityIdentifier("docUndo")
            Button { DocBlocksEditor.redo(blocks: &blocks, model: model) } label: { Image(systemName: "arrow.uturn.forward").frame(width: 30, height: 30) }
                .disabled(!model.undo.canRedo).accessibilityLabel("Redo").accessibilityIdentifier("docRedo")
        }
        .buttonStyle(.plain).font(.system(size: 14, weight: .medium))
        .disabled(model.editing == nil && !model.undo.canUndo && !model.undo.canRedo)
    }
    private static func key(_ style: DocInlineStyle) -> KeyEquivalent {
        switch style { case .bold: "b"; case .italic: "i"; case .code: "e"; case .strikethrough: "x"; case .link: "k" }
    }
}

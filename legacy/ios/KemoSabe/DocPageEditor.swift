import SwiftUI
import UniformTypeIdentifiers

/// One page: its cover, icon, title, blocks, and sub-pages. Shared by the iPhone's Library and the
/// Mac's two-pane Docs; each adds its own toolbar around it.
struct DocPageEditor: View {
    let pageID: UUID
    let docs: DocsStore
    var openPage: (UUID) -> Void
    @Bindable var model: DocEditorModel
    @State private var choosingIcon = false
    @State private var choosingCover = false
    @State private var coverPhoto = false
    @FocusState private var titleFocused: Bool
    #if os(macOS)
    private let sidePadding: CGFloat = 48
    #else
    private let sidePadding: CGFloat = 24
    #endif

    var body: some View {
        if let page = docs.page(pageID) {
            VStack(alignment: .leading, spacing: 0) {
                if let cover = page.cover { coverView(cover) }
                VStack(alignment: .leading, spacing: 8) {
                    if page.trashed != nil { trashedBanner }
                    let path = DocOutline.path(to: pageID, in: docs.pages)
                    if !path.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(path) { ancestor in
                                Button(ancestor.displayTitle) { openPage(ancestor.id) }.buttonStyle(.plain).lineLimit(1)
                                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                            }
                        }.font(KemoType.font(.caption)).foregroundStyle(.secondary).padding(.top, page.cover == nil ? 4 : 0)
                    }
                    header(page)
                    DocBlocksEditor(blocks: blocksBinding, model: model,
                                    host: DocEditorHost(docs: docs, pageID: pageID, openPage: openPage, firstPlaceholder: "Type / for blocks, @ to link a page"))
                        .disabled(page.trashed != nil)
                        .padding(.leading, -DocBlocksEditor.gutter)
                    subPages
                }
                .padding(.horizontal, sidePadding)
                .padding(.top, page.cover == nil ? 12 : 0)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .sheet(isPresented: $choosingIcon) { DocIconPicker(current: page.icon) { icon in docs.updatePage(pageID) { $0.icon = icon } } }
            .confirmationDialog("Cover", isPresented: $choosingCover) {
                ForEach(DocCovers.gradients, id: \.id) { cover in
                    Button(cover.id.capitalized) { docs.updatePage(pageID) { $0.cover = DocCover(kind: .gradient, value: cover.id) } }
                }
                Button("Photo…") { coverPhoto = true }
                if page.cover != nil { Button("Remove cover", role: .destructive) { docs.updatePage(pageID) { $0.cover = nil } } }
            }
            .docImagePicker(isPresented: $coverPhoto, docs: docs, limit: 1) { refs in
                guard let ref = refs.first else { return }
                docs.updatePage(pageID) { $0.cover = DocCover(kind: .image, value: ref.file) }
            }
        } else {
            ContentUnavailableView("This page is gone", systemImage: "doc.text", description: Text("It was deleted on another device."))
        }
    }

    private var blocksBinding: Binding<[DocBlock]> {
        Binding(get: { docs.page(pageID)?.blocks ?? [DocBlock()] }, set: { blocks in docs.updatePage(pageID) { $0.blocks = blocks } })
    }
    private var titleBinding: Binding<String> {
        Binding(get: { docs.page(pageID)?.title ?? "" }, set: { title in
            // Return in the title goes to the first block.
            if title.contains("\n") {
                docs.updatePage(pageID) { $0.title = title.replacingOccurrences(of: "\n", with: "") }
                focusFirstBlock()
            } else { docs.updatePage(pageID) { $0.title = title } }
        })
    }
    private func focusFirstBlock() {
        guard let first = docs.page(pageID)?.blocks.first(where: { $0.kind.hasText }) else { return }
        titleFocused = false
        model.request(first.id, atStart: true)
    }

    private func coverView(_ cover: DocCover) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                switch cover.kind {
                case .gradient: LinearGradient(colors: DocCovers.colors(cover.value), startPoint: .topLeading, endPoint: .bottomTrailing)
                case .image: DocImageView(docs: docs, ref: DocImageRef(file: cover.value, width: 1600, height: 600), fill: true)
                }
            }
            .frame(height: 150).frame(maxWidth: .infinity).clipped()
            Button("Change cover") { choosingCover = true }
                .font(KemoType.font(.caption, weight: .medium)).buttonStyle(.plain)
                .padding(.horizontal, 10).padding(.vertical, 5).background(.ultraThinMaterial, in: Capsule()).padding(10)
                .accessibilityIdentifier("docChangeCover")
        }
    }

    private func header(_ page: DocPage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let icon = page.icon {
                Button { choosingIcon = true } label: { DocIconView(icon: icon, size: 44) }.buttonStyle(.plain)
                    .accessibilityLabel("Page icon").accessibilityIdentifier("docIcon")
            }
            HStack(spacing: 14) {
                if page.icon == nil {
                    Button("Add icon", systemImage: "face.smiling") { choosingIcon = true }.accessibilityIdentifier("docAddIcon")
                }
                if page.cover == nil {
                    Button("Add cover", systemImage: "photo") { choosingCover = true }.accessibilityIdentifier("docAddCover")
                }
            }.font(KemoType.font(.caption)).buttonStyle(.plain).foregroundStyle(.secondary)
            TextField("Untitled", text: titleBinding, axis: .vertical)
                .font(KemoType.font(.largeTitle, weight: .bold)).textFieldStyle(.plain)
                .focused($titleFocused).onSubmit { focusFirstBlock() }
                .disabled(page.trashed != nil)
                .accessibilityIdentifier("docTitle")
        }.padding(.top, page.icon != nil && page.cover != nil ? -30 : 0)
    }

    private var trashedBanner: some View {
        HStack {
            Label("This page is in the Trash.", systemImage: "trash").font(KemoType.font(.footnote))
            Spacer()
            Button("Restore") { docs.restore(page(root: pageID)) }.font(KemoType.font(.footnote, weight: .semibold)).accessibilityIdentifier("docRestoreBanner")
        }.padding(10).background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
    }
    /// The page whose trashing took this one along.
    private func page(root id: UUID) -> UUID { docs.page(id)?.trashedWith ?? id }

    @ViewBuilder private var subPages: some View {
        let children = docs.children(of: pageID)
        let linked = Set(docs.page(pageID)?.blocks.compactMap(\.pageID) ?? [])
        let unlinked = children.filter { !linked.contains($0.id) }
        VStack(alignment: .leading, spacing: 4) {
            if !unlinked.isEmpty {
                Text("Sub-pages").font(KemoType.font(.caption, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 8)
                ForEach(unlinked) { child in
                    Button { openPage(child.id) } label: { DocPageLabel(page: child).font(KemoType.font(.body)) }
                        .buttonStyle(.plain).padding(.vertical, 3).accessibilityIdentifier("docSubPage-" + child.displayTitle)
                }
            }
            if docs.page(pageID)?.trashed == nil {
                Button("Add sub-page", systemImage: "plus") {
                    if let child = docs.createPage(parent: pageID) { openPage(child.id) }
                }.font(KemoType.font(.footnote)).buttonStyle(.plain).foregroundStyle(.secondary).padding(.top, 4)
                    .accessibilityIdentifier("docAddSubPage")
            }
        }.padding(.bottom, 40)
    }
}

/// A page and its sub-pages, for the outline in the Library.
struct DocTreeItem: Identifiable {
    let page: DocPage
    let children: [DocTreeItem]?
    var id: UUID { page.id }
    @MainActor static func tree(_ docs: DocsStore, parent: UUID? = nil, depth: Int = 0) -> [DocTreeItem] {
        (parent == nil ? docs.rootPages : docs.children(of: parent)).map { page in
            let children = depth < 12 ? tree(docs, parent: page.id, depth: depth + 1) : []
            return DocTreeItem(page: page, children: children.isEmpty ? nil : children)
        }
    }
}

/// Emoji and symbols for a page's icon.
struct DocIconPicker: View {
    let current: DocIcon?
    let choose: (DocIcon?) -> Void
    @Environment(\.dismiss) private var dismiss
    private let columns = [GridItem(.adaptive(minimum: 44), spacing: 8)]
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Emoji").font(KemoType.font(.caption, weight: .semibold)).foregroundStyle(.secondary)
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(DocIconChoices.emoji, id: \.self) { emoji in cell(.emoji(emoji)) }
                    }
                    Text("Symbols").font(KemoType.font(.caption, weight: .semibold)).foregroundStyle(.secondary)
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(DocIconChoices.symbols, id: \.self) { symbol in cell(.symbol(symbol)) }
                    }
                    if current != nil {
                        Button("Remove icon", role: .destructive) { choose(nil); dismiss() }.padding(.top, 8)
                    }
                }.padding(20)
            }
            .navigationTitle("Icon")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } } }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #else
        .frame(width: 420, height: 440)
        #endif
    }
    private func cell(_ icon: DocIcon) -> some View {
        Button { choose(icon); dismiss() } label: {
            DocIconView(icon: icon, size: 24).frame(width: 44, height: 44)
                .background(current == icon ? Color.primary.opacity(0.12) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).accessibilityIdentifier("docIconChoice-" + icon.value)
    }
}

/// A page as a Markdown file for the share sheet, written only when it's shared.
struct DocMarkdownFile: Transferable {
    let name: String
    let markdown: String
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .markdownDocument) { file in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DocExport-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(file.fileName)
            try file.markdown.write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
    var fileName: String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return (cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(80))) + ".md"
    }
}

extension UTType {
    /// Markdown (`.md`), a kind of plain text.
    static let markdownDocument = UTType("net.daringfireball.markdown") ?? UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText
}

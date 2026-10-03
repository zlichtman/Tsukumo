import AppKit
import SwiftUI
import CryptoKit
import Observation

/// A local, read-only reference surface. Reading a project does not grant a
/// model, shell, remote agent, or the personal assistant access to its files.
struct ProjectReference: Identifiable, Equatable, Sendable {
    let relativePath: String
    let byteCount: Int
    let kind: Kind
    enum Kind: String, Sendable { case document, image }
    var id: String { relativePath }
    var title: String { URL(fileURLWithPath: relativePath).lastPathComponent }
}
struct ProjectLibraryIndex: Sendable {
    let references: [ProjectReference]
    let incomplete: Bool
    static let maximumTextBytes = 256_000
    static let excluded = Set(["node_modules", "build", "DerivedData", "releases", "EvaluationAssets", "Pods", "venv", "__pycache__", ".build", "dist", "target"])
    /// Readable as text in the viewer: documents, source code, and configuration.
    static let textExtensions: Set<String> = ["md", "txt", "swift", "m", "mm", "h", "c", "cc", "cpp", "hpp", "js", "jsx", "ts", "tsx", "mjs", "cjs",
        "py", "rb", "go", "rs", "kt", "java", "cs", "php", "sh", "zsh", "bash", "fish", "json", "yml", "yaml", "toml", "xml", "plist",
        "html", "css", "scss", "sql", "graphql", "metal", "strings", "xcconfig", "entitlements", "gradle", "lock", "csv", "env", "ini", "cfg", "conf"]
    static let textNames: Set<String> = ["Makefile", "Dockerfile", "Podfile", "Gemfile", "Package.swift", "LICENSE", "Procfile"]
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "svg"]
    static func read(_ root: URL) throws -> Self {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey]
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { throw CocoaError(.fileReadUnknown) }
        var files: [ProjectReference] = [], visited = 0, incomplete = false
        let resolvedRoot = root.resolvingSymlinksInPath().path
        for case let url as URL in iterator {
            try Task.checkCancellation(); visited += 1
            if visited > 40_000 || files.count >= 4_000 { incomplete = true; break }
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true || excluded.contains(url.lastPathComponent) { iterator.skipDescendants(); continue }
            guard values.isRegularFile == true else { continue }
            let ext = url.pathExtension.lowercased()
            let kind: ProjectReference.Kind
            if imageExtensions.contains(ext) { kind = .image }
            else if textExtensions.contains(ext) || textNames.contains(url.lastPathComponent) { kind = .document }
            else { continue }
            let limit = kind == .document ? maximumTextBytes : 10_000_000
            guard let size = values.fileSize, size <= limit else { incomplete = true; continue }
            // Compare resolved paths: a root reached through a link (/var → /private/var) enumerates as its target.
            let path = url.resolvingSymlinksInPath().path.replacingOccurrences(of: resolvedRoot + "/", with: "", options: .anchored)
            files.append(.init(relativePath: path, byteCount: size, kind: kind))
        }
        return .init(references: files.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }, incomplete: incomplete)
    }
    static func bytes(_ item: ProjectReference, root: URL) throws -> Data {
        // Recheck every component immediately before opening, including directory
        // links introduced since indexing. Never follow a link outside the grant.
        let parts = item.relativePath.split(separator: "/").map(String.init)
        guard !parts.isEmpty, !parts.contains(where: { $0 == "." || $0 == ".." || $0.hasPrefix(".") }) else { throw CocoaError(.fileReadNoPermission) }
        var url = root
        for part in parts {
            url.appendPathComponent(part)
            if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw CocoaError(.fileReadNoPermission) }
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        let limit = item.kind == .document ? maximumTextBytes : 10_000_000
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= limit else { throw CocoaError(.fileReadTooLarge) }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw CocoaError(.fileReadTooLarge) }
        return data
    }
}

/// A folder in the project tree, with its subfolders and files.
struct ProjectTreeNode: Identifiable, Equatable {
    let name: String
    let path: String
    var folders: [ProjectTreeNode] = []
    var files: [ProjectReference] = []
    var id: String { path }
    static func build(_ references: [ProjectReference]) -> ProjectTreeNode {
        var root = ProjectTreeNode(name: "", path: "")
        for reference in references {
            let parts = reference.relativePath.split(separator: "/").map(String.init)
            root.insert(reference, folders: parts.dropLast(), prefix: "")
        }
        root.sort()
        return root
    }
    private mutating func insert(_ reference: ProjectReference, folders: ArraySlice<String>, prefix: String) {
        guard let first = folders.first else { files.append(reference); return }
        let path = prefix.isEmpty ? first : prefix + "/" + first
        if let index = self.folders.firstIndex(where: { $0.name == first }) {
            self.folders[index].insert(reference, folders: folders.dropFirst(), prefix: path)
        } else {
            var folder = ProjectTreeNode(name: first, path: path)
            folder.insert(reference, folders: folders.dropFirst(), prefix: path)
            self.folders.append(folder)
        }
    }
    private mutating func sort() {
        folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        files.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        for index in folders.indices { folders[index].sort() }
    }
}

@MainActor @Observable final class TsukumoLibrary {
    var references: [ProjectReference] = []
    var selected: ProjectReference?
    var text = ""
    var image: NSImage?
    var fingerprint = ""
    var folderName = ""
    var loading = false
    var notice = ""
    var query = ""
    var showImages = false
    private(set) var root: URL?
    private var scoped = false
    private var revision = UUID()
    private var task: Task<Void, Never>?
    private var scan: Task<ProjectLibraryIndex, Error>?
    var visible: [ProjectReference] {
        references.filter { query.isEmpty || $0.relativePath.localizedCaseInsensitiveContains(query) }
    }
    /// The project as folders and files, folders first, built from the checked index.
    private(set) var tree = ProjectTreeNode(name: "", path: "")
    /// Open folders, by relative path.
    var expanded: Set<String> = []
    func toggle(_ folder: String) { if expanded.contains(folder) { expanded.remove(folder) } else { expanded.insert(folder) } }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.prompt = "Open project"
        panel.message = "Choose a project folder. Tsukumo shows its files and opens a terminal there; it sends no files to a model."
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.open(url) }
        }
    }
    func open(_ url: URL) {
        close(); root = url; scoped = url.startAccessingSecurityScopedResource(); folderName = url.lastPathComponent
        let token = revision; loading = true
        let scan = Task.detached(priority: .userInitiated) { try ProjectLibraryIndex.read(url) }
        self.scan = scan
        task = Task {
            do {
                let index = try await scan.value
                guard token == revision, !Task.isCancelled else { return }
                references = index.references; loading = false
                tree = ProjectTreeNode.build(index.references)
                notice = index.incomplete ? "Some large files or folders were skipped. Open a narrower folder to see more." : ""
                // Start on the project's README, as a code host would.
                if let first = references.first(where: { $0.relativePath.lowercased() == "readme.md" }) ?? references.first(where: { $0.kind == .document }) { select(first) }
            } catch {
                guard token == revision else { return }; loading = false; notice = "This folder could not be read. Choose it again."
            }
        }
    }
    func select(_ item: ProjectReference) {
        guard let root else { return }
        selected = item; text = ""; image = nil; fingerprint = ""
        do {
            let data = try ProjectLibraryIndex.bytes(item, root: root)
            fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if item.kind == .document {
                guard let value = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
                text = value
            } else {
                guard let value = NSImage(data: data) else { throw CocoaError(.fileReadCorruptFile) }; image = value
            }
        } catch { notice = "This file changed, is too large, or cannot be read. Refresh the project to try again." }
    }
    func refresh() { if let root { open(root) } }
    func close() {
        task?.cancel(); scan?.cancel(); task = nil; scan = nil; revision = UUID()
        if scoped { root?.stopAccessingSecurityScopedResource() }
        scoped = false; root = nil; references = []; selected = nil; text = ""; image = nil
        folderName = ""; fingerprint = ""; notice = ""; loading = false; query = ""
        tree = ProjectTreeNode(name: "", path: ""); expanded = []
    }
}

struct TsukumoWorkspace: View {
    @Environment(DesktopPreferences.self) private var preferences
    @Environment(\.colorScheme) private var scheme
    @State private var library = TsukumoLibrary()
    @Environment(DesktopNavigation.self) private var desktop
    @Environment(CodingApplicationRegistry.self) private var applications
    @Environment(DesktopProjects.self) private var projects
    private var lavender: Color { preferences.palette(scheme).accent }
    var body: some View {
        VStack(spacing: 0) {
            // A header only when there's something to act on, as in Codex; the sidebar's + opens projects.
            if desktop.tsukumoSurface == "Coordination" || library.root != nil {
            HStack(spacing: 14) {
                // Project and Coordination are chosen in the sidebar.
                if desktop.tsukumoSurface == "Coordination" { Label("Coordination", systemImage: "point.3.filled.connected.trianglepath.dotted").font(.system(size: 13, weight: .medium)) }
                else if !library.folderName.isEmpty { Label(library.folderName, systemImage: "folder").font(.system(size: 13, weight: .medium)) }
                Spacer()
                if let root = library.root {
                    // Quiet icon buttons, as in Codex's window header.
                    HStack(spacing: 2) {
                        Menu {
                            ForEach(applications.applications) { app in Button(app.name) { applications.open(app, project: root) }.disabled(!app.available) }
                            Divider()
                            Button("Add coding application…") { desktop.settingsPage = "Editors" }
                        } label: { Image(systemName: "arrow.up.forward.app") }
                            .menuStyle(.button).menuIndicator(.hidden).help("Open in…").accessibilityLabel("Open in")
                        Button { library.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh project").accessibilityLabel("Refresh project")
                        Button { library.close() } label: { Image(systemName: "xmark") }.help("Close project").accessibilityLabel("Close project")
                    }
                    .buttonStyle(DesktopRowButtonStyle(inset: 6))
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 22).padding(.vertical, 10)
            Divider()
            }
            if desktop.tsukumoSurface == "Coordination" { WeaveBoard(project: library.folderName) }
            else if library.folderName.isEmpty { welcome }
            else {
                // Files and the document on top; the terminal and coding agents below.
                VSplitView {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                            TextField("Find a file", text: $library.query).textFieldStyle(.plain).accessibilityIdentifier("tsukumoSearch")
                        }.font(.system(size: 12)).padding(.horizontal, 9).padding(.vertical, 6)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        if library.loading { KemoOrb(size: 18, state: .searching).padding(.leading, 4) }
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                if library.query.isEmpty {
                                    // A folder tree, folders first, like an editor's.
                                    ProjectTreeRows(node: library.tree, depth: 0, library: library, accent: lavender)
                                } else {
                                    ForEach(library.visible) { item in
                                        ProjectFileRow(item: item, depth: 0, detail: (item.relativePath as NSString).deletingLastPathComponent,
                                                       selected: library.selected == item, accent: lavender) { library.select(item) }
                                    }
                                    if library.visible.isEmpty && !library.loading { Text("No matching files").font(.caption).foregroundStyle(.secondary).padding(8) }
                                }
                            }
                        }
                    }.padding(.horizontal, 10).padding(.vertical, 10).frame(width: 250).background(preferences.palette(scheme).sidebar)
                    Divider()
                    ScrollView([.horizontal, .vertical]) {
                        VStack(alignment: .leading, spacing: 16) {
                            if let item = library.selected {
                                Text(item.relativePath).font(.system(size: 12, weight: .semibold)).foregroundStyle(lavender)
                                if let image = library.image { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 950) }
                                else { Text(verbatim: library.text).font(preferences.codeFont).textSelection(.enabled).frame(width: 680, alignment: .leading) }
                                Text("Source SHA-256 · " + library.fingerprint).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            } else { Text("Select a document or design.").foregroundStyle(.secondary) }
                        }.padding(24)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }.frame(minHeight: 160)
                if let root = library.root {
                    TerminalPanel(directory: root).frame(minHeight: 150, idealHeight: 320)
                }
                }
            }
            if !library.notice.isEmpty { Text(library.notice).font(.caption).foregroundStyle(.orange).padding(10) }
        }.background(preferences.palette(scheme).background).tint(lavender).onDisappear { library.close() }
            .onAppear { openSelected() }.onChange(of: projects.selected) { openSelected() }
    }
    private func openSelected() {
        guard let id = projects.selected else { library.close(); return }
        do { library.open(try projects.resolve(id)) } catch { library.close(); library.notice = "Project access expired. Add the folder again." }
    }
    private var welcome: some View {
        VStack(spacing: 16) {
            if let url = Bundle.main.url(forResource: "Tsukumo", withExtension: "png"), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 240, height: 132).accessibilityLabel("Tsukumo")
            }
            Text("What are you working on?").font(.system(size: 28, weight: .semibold))
            Text("Open a folder to browse it and run a terminal, Codex, or Claude Code there.").font(.system(size: 13)).foregroundStyle(.secondary)
            Button("Open project…", action: projects.choose).padding(.top, 6).accessibilityIdentifier("tsukumoOpenProject")
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A level of the project tree: folders (click to open) and then files.
private struct ProjectTreeRows: View {
    let node: ProjectTreeNode
    let depth: Int
    let library: TsukumoLibrary
    let accent: Color
    var body: some View {
        ForEach(node.folders) { folder in
            let open = library.expanded.contains(folder.path)
            Button { library.toggle(folder.path) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 10)
                    Image(systemName: open ? "folder.fill" : "folder").font(.system(size: 12)).foregroundStyle(accent.opacity(0.85))
                    Text(folder.name).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12.5)).padding(.leading, CGFloat(depth) * 14 + 4).padding(.trailing, 6).frame(height: 24)
                .contentShape(Rectangle())
            }.buttonStyle(DesktopRowButtonStyle()).accessibilityLabel(folder.name + (open ? ", open folder" : ", folder"))
            if open { ProjectTreeRows(node: folder, depth: depth + 1, library: library, accent: accent) }
        }
        ForEach(node.files) { file in
            ProjectFileRow(item: file, depth: depth, detail: nil, selected: library.selected == file, accent: accent) { library.select(file) }
        }
    }
}

/// One file: an icon for its type, its name, and in search results the folder it's in.
private struct ProjectFileRow: View {
    let item: ProjectReference
    let depth: Int
    let detail: String?
    let selected: Bool
    let accent: Color
    let select: () -> Void
    var body: some View {
        Button(action: select) {
            HStack(spacing: 6) {
                Spacer().frame(width: 10)
                Image(systemName: Self.symbol(for: item)).font(.system(size: 11.5)).foregroundStyle(.secondary).frame(width: 14)
                Text(item.title).lineLimit(1)
                if let detail, !detail.isEmpty { Text(detail).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head) }
                Spacer(minLength: 0)
            }
            .font(.system(size: 12.5)).padding(.leading, CGFloat(depth) * 14 + 4).padding(.trailing, 6).frame(height: 24)
            .background(selected ? accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }.buttonStyle(DesktopRowButtonStyle()).accessibilityAddTraits(selected ? .isSelected : [])
    }
    static func symbol(for item: ProjectReference) -> String {
        if item.kind == .image { return "photo" }
        switch (item.relativePath as NSString).pathExtension.lowercased() {
        case "swift": return "swift"
        case "md", "txt": return "doc.text"
        case "json", "yml", "yaml", "toml", "plist", "xml", "xcconfig", "entitlements": return "gearshape"
        case "sh", "zsh", "bash": return "terminal"
        default: return "chevron.left.forwardslash.chevron.right"
        }
    }
}


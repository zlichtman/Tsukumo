import SwiftUI
import AppKit
import CryptoKit

struct CodingWorkspaceView: View {
    @Environment(CodingWorkspaceStore.self) private var coding
    @Environment(DesktopProjects.self) private var projects
    @Environment(DesktopNavigation.self) private var desktop
    @Environment(DesktopPreferences.self) private var preferences
    @Environment(\.colorScheme) private var scheme
    /// The new task's agent, model, effort, access, and worktree choice.
    @State private var settings = CodingNewTaskSettings.remembered()
    /// Which panes are open beside the conversation (one side pane) and below it (the terminal).
    @State private var panes = CodingPaneState()
    /// The Changes pane's tab: the review ("Changes") or the file editor ("Files").
    @State private var changesTab = "Changes"
    /// A file "Open in editor" asked the Files tab to open.
    @State private var editorRequest: String?
    @State private var creating = false
    /// The new task page's height, which places Kemo where a new KemoSabe chat's is.
    @State private var newTaskHeight: CGFloat = 0
    @State private var comparing: UUID?
    @State private var commands = CodingChatCommands.shared
    private var selected: CodingTaskRecord? { coding.task(coding.selected) }
    var body: some View {
        VStack(spacing: 0) {
            if desktop.tsukumoSurface == "Coordination" { CodingCollaborationView() }
            else if desktop.tsukumoSurface == "Terminal" { TerminalPage() }
            else if let task = selected {
                taskHeader(task)
                Divider()
                VSplitView {
                    HSplitView {
                        conversation(task).frame(minWidth: 300, maxWidth: .infinity)
                        if let side = panes.side { sidePane(side, task: task).frame(minWidth: 320, idealWidth: 440, maxWidth: .infinity) }
                    }.frame(minHeight: 260)
                    // The terminal runs in the task's own folder (its worktree).
                    if panes.terminal { TerminalPanel(directory: URL(fileURLWithPath: task.directory)).id(task.directory).frame(minHeight: 120, idealHeight: 230) }
                }
            } else { newTask }
            if !coding.notice.isEmpty {
                HStack { Text(coding.notice).font(.caption).textSelection(.enabled); Spacer(); Button("Dismiss") { coding.notice = "" }.disabled(coding.storageFailed) }.padding(10).foregroundStyle(.orange)
            }
        }
        .background(preferences.palette(scheme).background)
        .overlay(alignment: .top) {
            if commands.paletteOpen {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.001).onTapGesture { commands.paletteOpen = false }
                    CodingCommandPalette(task: selected) { path in
                        if selected != nil { panes.side = .changes; changesTab = "Files"; editorRequest = path }
                    }.padding(.top, 70)
                }
            }
        }
        .sheet(item: Binding(get: { comparing.map(CodingCompareID.init) }, set: { comparing = $0?.id })) { CodingCompareView(group: $0.id) }
        .task { coding.startMonitoring() }
        // Opening a task (from anywhere) clears its unread mark.
        .onChange(of: coding.selected) { if let id = coding.selected { coding.select(id) } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in if let id = coding.selected { coding.select(id) } }
        // A file card asks for its file in the Changes pane.
        .onChange(of: commands.revealed) { if commands.revealed != nil { panes.side = .changes; changesTab = "Changes" } }
        // The choices for a new chat are remembered for the next one.
        .onChange(of: settings) { settings.remember() }
    }
    private func taskHeader(_ task: CodingTaskRecord) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title).font(.headline).lineLimit(1)
                Text("\(task.provider.title) · \(task.model.isEmpty ? "Default model" : task.model)\(task.effort.map { " · " + $0 } ?? "") · \(task.access.title) · \(task.isolated ? "Worktree" : "Working folder")").font(.caption).foregroundStyle(task.access == .full ? .orange : .secondary)
            }
            Spacer()
            if let group = task.group, coding.group(group).count > 1 {
                Button { comparing = group } label: { Label("Compare", systemImage: "rectangle.split.2x1").font(.system(size: 12)) }
                    .buttonStyle(DesktopRowButtonStyle(inset: 6)).help("Compare Claude Code's and Codex's changes side by side")
            }
            // While it works, the orb is in the conversation and Stop is the composer's button.
            if !task.status.running { Text(CodingTaskStatusBadge.label(task)).font(.caption).foregroundStyle(.secondary) }
            CodingTaskToolbar(task: task, panes: $panes).padding(.leading, 6)
        }.padding(.horizontal, 14).padding(.vertical, 10)
    }
    @ViewBuilder private func sidePane(_ pane: CodingPane, task: CodingTaskRecord) -> some View {
        VStack(spacing: 0) {
            switch pane {
            case .changes:
                HStack {
                    QuietSegmented(options: ["Changes", "Files"], selection: $changesTab).font(.system(size: 12))
                    Spacer()
                }.padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
                if changesTab == "Files" {
                    CodingFileEditor(root: URL(fileURLWithPath: task.directory), editable: !task.status.running && !coding.busy.contains(task.id), openRequest: $editorRequest)
                } else {
                    CodingChangesPane(task: task) { path in editorRequest = path; changesTab = "Files" }
                }
            case .browser: CodingBrowserPane(task: task, browser: CodingPaneModels.browser)
            case .device: CodingDevicePane(task: task, simulator: CodingPaneModels.simulator)
            }
        }
        .background(preferences.palette(scheme).background)
    }
    /// The transcript and the composer on one center line; the agent's request pops up over the composer.
    private func conversation(_ task: CodingTaskRecord) -> some View {
        VStack(spacing: 0) {
            CodingTranscriptView(task: task)
            CodingComposer(task: task, settings: $settings) { _, _, _ in }
                .overlay(alignment: .top) {
                    if let approval = coding.approvals[task.id] {
                        CodingApprovalPopup(task: task, approval: approval)
                            .alignmentGuide(.top) { $0[.bottom] + 10 }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.15), value: coding.approvals[task.id]?.id)
                .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 22).frame(maxWidth: 780).frame(maxWidth: .infinity)
        }
    }
    /// A new chat looks like KemoSabe's: Kemo at work and a greeting on the center line, a few ways to
    /// start, and the grouped composer with the project, agent, model, access, and place in it.
    private var newTask: some View {
        VStack(spacing: 0) {
            ScrollView {
                CodingNewChatGreeting(provider: settings.provider, project: projects.projects.first { $0.id == projects.selected }?.name, creating: creating,
                                      pageHeight: newTaskHeight)
                    .padding(.horizontal, 24).frame(maxWidth: 780).frame(maxWidth: .infinity)
            }
            VStack(spacing: 7) {
                CodingComposer(task: nil, settings: $settings) { text, images, compare in
                    guard let project = projects.projects.first(where: { $0.id == projects.selected }) else { return }
                    start(project, text: text, images: images, compare: compare)
                }
                HStack(spacing: 5) {
                    Image(systemName: "lock")
                    Text("\(settings.provider.title) uses its own sign-in. Only this project and your message go to it; your chats and memories don't.")
                    Spacer()
                }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 10)
            }.padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 22).frame(maxWidth: 780).frame(maxWidth: .infinity)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { newTaskHeight = $0 }
    }
    private func start(_ project: DesktopProject, text: String, images: [URL], compare: [CodingProvider]?) {
        creating = true; commands.starting = text
        let settings = settings
        Task {
            defer { creating = false }
            do {
                let root = try projects.resolve(project.id)
                if let compare { await coding.runWith(compare, project: project, root: root, prompt: text, access: settings.access, images: images) }
                else { _ = await coding.create(project: project, root: root, provider: settings.provider, model: settings.model, access: settings.access, isolated: settings.isolated, prompt: text, options: .init(effort: settings.effort, images: images)) }
            } catch { coding.notice = error.localizedDescription }
        }
    }
}
private struct CodingCompareID: Identifiable { var id: UUID }

// The collaboration page (CodingCollaborationView) is in CodingCollabPage.swift.

struct CodingFileEditor: View {
    let root: URL
    let editable: Bool
    /// A relative path to open (from the Changes pane's "Open in editor"); cleared once handled.
    var openRequest: Binding<String?> = .constant(nil)
    /// The line to show when `openRequest` opens a file (a terminal's file:line).
    var openLine: Int? = nil
    @State private var revealLine: Int?
    @State private var library = TsukumoLibrary()
    @State private var drafts: [String: String] = [:]
    @State private var originals: [String: String] = [:]
    @State private var openFiles: [ProjectReference] = []
    @State private var selection: ProjectReference?
    @State private var notice = ""
    @State private var confirmReload = false
    /// The account's drafts folder, captured with the drafts it holds (nil while signed out).
    @State private var draftFolder: URL?
    @Environment(CodingWorkspaceStore.self) private var coding
    var body: some View {
        VStack(spacing: 8) {
            TextField("Find a file", text: $library.query).textFieldStyle(.roundedBorder)
            ScrollView(.horizontal) {
                HStack { ForEach(openFiles) { file in Button(file.title + (drafts[file.id] != originals[file.id] ? " •" : "")) { selection = file } } }
            }
            HSplitView {
                List(library.visible) { file in Button(file.relativePath) { open(file) }.buttonStyle(.plain).font(.caption) }.frame(minWidth: 100, idealWidth: 140)
                if let file = selection, file.kind == .document {
                    CodingTextEditor(text: Binding(get: { drafts[file.id] ?? "" }, set: { drafts[file.id] = $0; keepDraft(file) }), editable: editable, line: revealLine).frame(minWidth: 130)
                } else { Text("Open a text file to edit").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            HStack {
                Text(selection?.relativePath ?? "").font(.caption).lineLimit(1)
                Spacer()
                Button("Save") { save() }.keyboardShortcut("s", modifiers: .command).disabled(!editable || selection == nil)
                Button("Reload") { confirmReload = true }.disabled(selection == nil)
            }
            if !editable { Text("Stop the agent before editing this task's files.").font(.caption).foregroundStyle(.secondary) }
            if !notice.isEmpty { Text(notice).font(.caption).foregroundStyle(.orange) }
        }.padding(10).task(id: root.path + "\n" + (coding.accountID ?? "")) {
            // A new folder or a new account starts clean; drafts reload from that account's folder.
            library.open(root); drafts = [:]; originals = [:]; openFiles = []; selection = nil; notice = ""
            draftFolder = coding.draftsFolder
            openRequested()
        }
        .onChange(of: openRequest.wrappedValue) { openRequested() }
        .confirmationDialog("Discard this draft and reload the file from disk?", isPresented: $confirmReload) {
            Button("Discard draft and reload", role: .destructive) { if let selection { open(selection, reload: true) } }
        }
    }
    /// Opens the requested file as a tab. Its reference is made from the path (the index may still
    /// be scanning); `ProjectLibraryIndex.bytes` rechecks it for links, hidden folders, and size.
    private func openRequested() {
        guard let path = openRequest.wrappedValue else { return }
        openRequest.wrappedValue = nil
        revealLine = openLine
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        let size = (try? root.appendingPathComponent(path).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        open(library.references.first { $0.relativePath == path } ?? ProjectReference(relativePath: path, byteCount: size, kind: ProjectLibraryIndex.imageExtensions.contains(ext) ? .image : .document))
    }
    private func open(_ file: ProjectReference, reload: Bool = false) {
        guard file.kind == .document else { notice = "Use your editor to open images and binary files."; return }
        if drafts[file.id] == nil || reload {
            do {
                guard let text = String(data: try ProjectLibraryIndex.bytes(file, root: root), encoding: .utf8) else { throw CodingFailure("File is not UTF-8 text.") }
                if !reload, let saved = try CodingEditorDraft.load(folder: draftFolder, root: root, path: file.id) {
                    drafts[file.id] = saved.text; originals[file.id] = saved.original
                } else {
                    drafts[file.id] = text; originals[file.id] = text
                    try CodingEditorDraft.remove(folder: draftFolder, root: root, path: file.id)
                }
            } catch { notice = error.localizedDescription; return }
        }
        if !openFiles.contains(file) { openFiles.append(file) }; selection = file; notice = ""
    }
    private func keepDraft(_ file: ProjectReference) {
        guard let text = drafts[file.id], let original = originals[file.id] else { return }
        do { try CodingEditorDraft(text: text, original: original).save(folder: draftFolder, root: root, path: file.id) }
        catch { notice = "Draft could not be saved: " + error.localizedDescription }
    }
    private func save() {
        guard editable, let file = selection, let text = drafts[file.id], let original = originals[file.id] else { return }
        do {
            try CodingEditorIO.save(file: file, root: root, original: original, replacement: text)
            originals[file.id] = text; try CodingEditorDraft.remove(folder: draftFolder, root: root, path: file.id); notice = "Saved"
        } catch { notice = error.localizedDescription }
    }
}
struct CodingEditorDraft: Codable {
    var text: String
    var original: String
    /// Drafts live in the signed-in account's folder (`CodingWorkspaceStore.draftsFolder`);
    /// with no account (signed out) nothing is kept or read.
    private static func url(folder: URL, root: URL, path: String) -> URL {
        let key = SHA256.hash(data: Data((root.path + "\n" + path).utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(key + ".json")
    }
    static func load(folder: URL?, root: URL, path: String) throws -> Self? {
        guard let folder else { return nil }
        let url = url(folder: folder, root: root, path: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
    func save(folder: URL?, root: URL, path: String) throws {
        guard let folder else { throw CodingFailure("Sign in to keep drafts.") }
        let url = Self.url(folder: folder, root: root, path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func remove(folder: URL?, root: URL, path: String) throws {
        guard let folder else { return }
        let url = url(folder: folder, root: root, path: path)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
enum CodingEditorIO {
    static func save(file: ProjectReference, root: URL, original: String, replacement: String) throws {
        guard replacement.utf8.count <= ProjectLibraryIndex.maximumTextBytes else { throw CodingFailure("File exceeds the editor's size limit.") }
        let current = try ProjectLibraryIndex.bytes(file, root: root)
        guard current == Data(original.utf8) else { throw CodingFailure("This file changed on disk. Copy your draft before reloading; it has not been overwritten.") }
        let url = root.appendingPathComponent(file.relativePath)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        try Data(replacement.utf8).write(to: url, options: .atomic)
        if let mode = attributes[.posixPermissions] { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path) }
    }
}
/// Native editor with undo, monospaced text, and lightweight keyword/string highlighting.
private struct CodingTextEditor: NSViewRepresentable {
    @Binding var text: String
    var editable: Bool
    /// A line to scroll to and select once (from a terminal's file:line).
    var line: Int? = nil
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(), view = NSTextView()
        view.isRichText = false; view.allowsUndo = true; view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false; view.isAutomaticTextReplacementEnabled = false
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular); view.delegate = context.coordinator
        view.textContainerInset = NSSize(width: 10, height: 10); view.autoresizingMask = [.width]; view.isVerticallyResizable = true
        scroll.documentView = view; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self; view.isEditable = editable
        if view.string != text { view.string = text; context.coordinator.highlight(view) }
        if let line, context.coordinator.revealed != line {
            context.coordinator.revealed = line
            let lines = (view.string as NSString).components(separatedBy: "\n")
            let start = lines.prefix(max(0, line - 1)).reduce(0) { $0 + ($1 as NSString).length + 1 }
            let range = NSRange(location: min(start, (view.string as NSString).length), length: line - 1 < lines.count ? (lines[line - 1] as NSString).length : 0)
            DispatchQueue.main.async { view.scrollRangeToVisible(range); view.setSelectedRange(range); view.showFindIndicator(for: range) }
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodingTextEditor
        var revealed: Int?
        init(_ parent: CodingTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }; parent.text = view.string; highlight(view)
        }
        func highlight(_ view: NSTextView) {
            guard let storage = view.textStorage else { return }
            let all = NSRange(location: 0, length: storage.length)
            storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: all)
            let patterns: [(String, NSColor)] = [(#"\b(import|func|let|var|class|struct|enum|if|else|return|async|await|throw|try|const|function|def|from|export|public|private|case|switch|for|in|true|false|null|nil)\b"#, .systemPurple), (#"\"([^\"\\]|\\.)*\""#, .systemGreen), (#"//[^\n]*"#, .secondaryLabelColor)]
            for (pattern, color) in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                for match in regex.matches(in: view.string, range: all) { storage.addAttribute(.foregroundColor, value: color, range: match.range) }
            }
        }
    }
}

import SwiftUI
import AppKit
import Observation

// MARK: Slash commands

/// A slash command typed in the composer: Tsukumo's own (`/new`, `/model`, `/compact`, `/review`,
/// `/clear`) or one the agent reported (sent to it as the message, which is how Claude Code's
/// headless mode takes its commands).
struct CodingSlashCommand: Equatable {
    enum Action: Equatable {
        case newTask, model(String), effort(String), compact, review, clear, agent(String)
    }
    var action: Action
    /// Tsukumo's own commands, with what each does.
    static let builtIn: [(name: String, detail: String)] = [
        ("new", "Start a new task"),
        ("model", "Choose the model, or /model <name>"),
        ("effort", "Set reasoning effort, or /effort <level>"),
        ("compact", "Ask the agent to summarize its context"),
        ("review", "Ask the agent to review this task's changes"),
        ("clear", "Start a fresh agent session in this task"),
    ]
    /// Reads a message that starts with "/". Tsukumo's commands win; a name the agent reported
    /// goes to the agent with its arguments; anything else isn't a command (so "/usr/bin is…" is
    /// sent as text).
    static func parse(_ text: String, agentCommands: [String] = []) -> CodingSlashCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), trimmed.count > 1 else { return nil }
        let body = trimmed.dropFirst()
        let name = String(body.prefix { !$0.isWhitespace }).lowercased()
        let argument = body.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "new": return .init(action: .newTask)
        case "model": return .init(action: .model(argument))
        case "effort": return .init(action: .effort(argument.lowercased()))
        case "compact": return .init(action: .compact)
        case "review": return .init(action: .review)
        case "clear": return .init(action: .clear)
        default:
            let known = agentCommands.map { $0.hasPrefix("/") ? String($0.dropFirst()).lowercased() : $0.lowercased() }
            return known.contains(name) ? .init(action: .agent(trimmed)) : nil
        }
    }
    /// Suggestions for what's typed so far ("/co" → compact, and agent commands starting with it).
    static func suggestions(_ text: String, agentCommands: [String]) -> [(name: String, detail: String)] {
        guard text.hasPrefix("/"), !text.contains(" "), !text.contains("\n") else { return [] }
        let typed = text.dropFirst().lowercased()
        let own = builtIn.filter { $0.name.hasPrefix(typed) }
        let names = Set(builtIn.map(\.name))
        let agent = agentCommands.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 }
            .filter { !names.contains($0.lowercased()) && $0.lowercased().hasPrefix(typed) }.sorted()
            .map { (name: $0, detail: "Agent command") }
        return Array((own + agent).prefix(12))
    }
}

// MARK: @ mentions

/// Fuzzy file search for `@` mentions: the query's characters must appear in order in the path;
/// matches in the file name, at word starts, and in a row score higher, and shorter paths win ties.
enum CodingMentionSearch {
    static func score(_ query: String, _ path: String) -> Int? {
        let q = Array(query.lowercased()), p = Array(path.lowercased())
        guard !q.isEmpty else { return 0 }
        let nameStart = (path.lastIndex(of: "/").map { path.distance(from: path.startIndex, to: $0) + 1 }) ?? 0
        var score = 0, qi = 0, last = -2, streak = 0
        for (pi, character) in p.enumerated() where qi < q.count && character == q[qi] {
            var bonus = 1
            if pi == last + 1 { streak += 1; bonus += 4 * streak } else { streak = 0 }
            if pi == 0 || "/_-. ".contains(p[pi - 1]) { bonus += 6 }
            if pi >= nameStart { bonus += 3 }
            score += bonus; last = pi; qi += 1
        }
        guard qi == q.count else { return nil }
        // A file name that starts with the query is what people usually mean.
        if path.dropFirst(nameStart).lowercased().hasPrefix(query.lowercased()) { score += 20 }
        return score * 100 - p.count
    }
    static func rank(_ query: String, in paths: [String], limit: Int = 8) -> [String] {
        var scored: [(path: String, score: Int)] = []
        for path in paths { if let value = score(query, path) { scored.append((path, value)) } }
        scored.sort { a, b in a.score != b.score ? a.score > b.score : a.path < b.path }
        return scored.prefix(limit).map(\.path)
    }
    /// The `@` word being typed at the end of the text, if any ("fix @src/ap" → "src/ap").
    static func activeQuery(_ text: String) -> String? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        if at > text.startIndex, !text[text.index(before: at)].isWhitespace { return nil }
        let query = text[text.index(after: at)...]
        guard !query.contains(where: \.isWhitespace) else { return nil }
        return String(query)
    }
    /// Replaces the `@` word being typed with the chosen path and a trailing space.
    static func complete(_ text: String, with path: String) -> String {
        guard let at = text.lastIndex(of: "@") else { return text }
        return String(text[..<at]) + "@" + path + " "
    }
    /// The project's files for mentions: tracked and untracked, minus ignored ones.
    static func files(in directory: URL) async -> [String] {
        let tracked = (try? await CodingCommand.git(["ls-files", "-z", "--cached", "--others", "--exclude-standard"], at: directory)) ?? ""
        if !tracked.isEmpty { return Array(tracked.split(separator: "\0").map(String.init).prefix(20_000)) }
        // Not a Git folder: the library index (text and image files, hidden folders skipped).
        return await Task.detached { (try? ProjectLibraryIndex.read(directory))?.references.map(\.relativePath) ?? [] }.value
    }
}

// MARK: Commands from the menu and the palette

/// Requests from the menu bar, the command palette, and cards, which the task views carry out.
@MainActor @Observable final class CodingChatCommands {
    static let shared = CodingChatCommands()
    var paletteOpen = false
    /// The message a new chat was started with, shown while its worktree is made.
    var starting: String?
    /// A file a card asked the Changes pane to show.
    struct Reveal: Equatable { var path: String; var token = UUID() }
    private(set) var revealed: Reveal?
    /// Bumped to put the keyboard in the composer.
    private(set) var focusToken = UUID()
    /// Bumped to open the composer's model menu (from `/model` with no name).
    private(set) var modelMenuToken: UUID?
    func reveal(_ path: String) { revealed = .init(path: path) }
    func focusComposer() { focusToken = UUID() }
    func openModelMenu() { modelMenuToken = UUID() }
}

/// Tsukumo's Task menu: new task, command palette, stop, and switching tasks with ⌘1–9. Menu key
/// equivalents run after the focused view has had its chance, so ⌘K still clears a focused terminal.
@MainActor final class CodingChatMenu: NSObject {
    private let coding: CodingWorkspaceStore
    private let desktop: DesktopNavigation
    private let projects: DesktopProjects
    private let open: () -> Void
    init(coding: CodingWorkspaceStore, desktop: DesktopNavigation, projects: DesktopProjects, open: @escaping () -> Void) {
        self.coding = coding; self.desktop = desktop; self.projects = projects; self.open = open
    }
    func item() -> NSMenuItem {
        let item = NSMenuItem(), menu = NSMenu(title: "Task")
        func add(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0) {
            let entry = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            entry.keyEquivalentModifierMask = modifiers; entry.target = self; entry.tag = tag
        }
        add("New Task", #selector(newTask), "n", [.command, .shift])
        add("Command Palette…", #selector(palette), "k")
        menu.addItem(.separator())
        add("Stop Task", #selector(stop), ".")
        menu.addItem(.separator())
        for number in 1...9 { add("Task \(number)", #selector(select(_:)), "\(number)", tag: number) }
        item.submenu = menu
        return item
    }
    /// ⌘N: a new task while in Tsukumo (the Window menu's New conversation calls this first).
    func newTaskIfCoding() -> Bool {
        guard desktop.page == "Tsukumo" else { return false }
        newTask(); return true
    }
    @objc func newTask() {
        open(); desktop.page = "Tsukumo"; desktop.tsukumoSurface = "Project"; coding.selected = nil
        CodingChatCommands.shared.focusComposer()
    }
    @objc private func palette() { open(); desktop.page = "Tsukumo"; CodingChatCommands.shared.paletteOpen.toggle() }
    @objc private func stop() { if let id = coding.selected, coding.task(id)?.status.running == true { coding.stop(id) } }
    @objc private func select(_ sender: NSMenuItem) {
        let tasks = coding.sidebarOrder(project: desktop.page == "Tsukumo" ? projects.selected : nil)
        guard sender.tag - 1 < tasks.count else { return }
        let task = tasks[sender.tag - 1]
        open(); desktop.page = "Tsukumo"; desktop.tsukumoSurface = "Project"; projects.selected = task.projectID; coding.select(task.id)
    }
}

/// ⌘K: one search over tasks, the project's files, and actions.
struct CodingCommandPalette: View {
    let task: CodingTaskRecord?
    var openFile: (String) -> Void
    @Environment(CodingWorkspaceStore.self) private var coding
    @Environment(DesktopProjects.self) private var projects
    @Environment(DesktopNavigation.self) private var desktop
    @State private var query = ""
    @State private var files: [String] = []
    @State private var highlighted = 0
    @FocusState private var focused: Bool
    private struct Entry: Identifiable { var id: String; var title: String; var detail: String; var symbol: String; var run: () -> Void }
    var body: some View {
        let entries = results
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search tasks, files, and actions", text: $query).textFieldStyle(.plain).font(.system(size: 15)).focused($focused)
                    .onSubmit { if entries.indices.contains(highlighted) { run(entries[highlighted]) } }
                    .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(0, entries.count - 1)); return .handled }
                    .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
                    .onKeyPress(.escape) { close(); return .handled }
            }.padding(14)
            Divider()
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            Button { run(entry) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: entry.symbol).frame(width: 16).foregroundStyle(.secondary)
                                    Text(entry.title).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(entry.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                }.font(.system(size: 13)).padding(.horizontal, 10).padding(.vertical, 7).contentShape(Rectangle())
                            }.buttonStyle(DesktopRowButtonStyle(selected: index == highlighted)).id(entry.id)
                        }
                        if entries.isEmpty { Text("Nothing matches").font(.system(size: 12)).foregroundStyle(.secondary).padding(20) }
                    }.padding(6)
                }.onChange(of: highlighted) { if entries.indices.contains(highlighted) { reader.scrollTo(entries[highlighted].id) } }
            }.frame(height: 320)
        }
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
        .onAppear { focused = true }
        .onChange(of: query) { highlighted = 0 }
        .task(id: task?.directory) {
            guard let task else { files = []; return }
            files = await CodingMentionSearch.files(in: URL(fileURLWithPath: task.directory))
        }
    }
    private var results: [Entry] {
        var actions: [Entry] = [
            .init(id: "a-new", title: "New task", detail: "⇧⌘N", symbol: "square.and.pencil") { coding.selected = nil; desktop.tsukumoSurface = "Project"; CodingChatCommands.shared.focusComposer() },
            .init(id: "a-coord", title: "Open Coordination", detail: "", symbol: "point.3.filled.connected.trianglepath.dotted") { desktop.tsukumoSurface = "Coordination" },
            .init(id: "a-project", title: "Open project…", detail: "", symbol: "folder.badge.plus") { projects.choose() },
        ]
        if let task {
            if task.status.running { actions.append(.init(id: "a-stop", title: "Stop task", detail: "⌘.", symbol: "stop.circle") { coding.stop(task.id) }) }
            actions.append(.init(id: "a-pin", title: task.pinned == true ? "Unpin task" : "Pin task", detail: "", symbol: "pin") { coding.setPinned(task.id, task.pinned != true) })
            actions.append(.init(id: "a-review", title: "Ask the agent to review its changes", detail: "/review", symbol: "checklist") { coding.review(task.id) })
            actions.append(.init(id: "a-archive", title: "Archive task", detail: "", symbol: "archivebox") { coding.archive(task.id) })
        }
        let tasks = coding.tasks.filter { $0.archived != true }.sorted { $0.updated > $1.updated }.map { record in
            Entry(id: "t-" + record.id.uuidString, title: record.title, detail: record.provider.title + " · " + CodingTaskStatusBadge.label(record), symbol: "bubble.left.and.text.bubble.right") {
                projects.selected = record.projectID; coding.select(record.id); desktop.tsukumoSurface = "Project"
            }
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return actions + Array(tasks.prefix(8)) }
        func matches(_ entry: Entry) -> Bool { CodingMentionSearch.score(trimmed, entry.title) != nil }
        let fileEntries = CodingMentionSearch.rank(trimmed, in: files, limit: 8).map { path in
            Entry(id: "f-" + path, title: path, detail: "File", symbol: "doc") { openFile(path) }
        }
        return actions.filter(matches) + tasks.filter(matches).prefix(8) + fileEntries
    }
    private func run(_ entry: Entry) { close(); entry.run() }
    private func close() { CodingChatCommands.shared.paletteOpen = false }
}

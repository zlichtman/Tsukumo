import AppKit
import Observation
import SwiftTerm
import SwiftUI

// Tsukumo's terminal surfaces: the Terminal page (tabs of split panes, restored on relaunch), the
// quick terminal, and the terminal panel under a project or task. All three are a
// `TerminalWorkspace` drawn by `TerminalSurfaceView`.

/// The tabs and splits of one terminal surface, and the actions on them. Pane processes live in
/// `TerminalSessions`; this owns which panes exist and how they're arranged.
@MainActor @Observable final class TerminalWorkspace {
    enum Kind: Equatable { case main, quick, panel(String) }
    struct FindState: Equatable {
        var pane: UUID
        var text = ""
        var caseSensitive = false
        var regex = false
        var index = 0
        var total = 0
        /// Bumped each time ⌘F is pressed, so the field takes focus again.
        var focusRequest = 0
    }
    let kind: Kind
    private(set) var layout: TerminalLayout { didSet { if layout != oldValue { save() } } }
    var find: FindState?
    var renamingTab: UUID?
    /// Called when the last tab closes (the quick terminal hides).
    @ObservationIgnored var onEmpty: (() -> Void)?
    @ObservationIgnored private let storageKey: String?

    static let main = TerminalWorkspace(kind: .main, storageKey: "terminal.layout.main")
    static let quick = TerminalWorkspace(kind: .quick, storageKey: "terminal.layout.quick")
    private static var panels: [String: TerminalWorkspace] = [:]
    /// The terminal panel for a project's or task's folder; it lasts while Tsukumo runs.
    static func panel(_ directory: URL) -> TerminalWorkspace {
        if let existing = panels[directory.path] { return existing }
        let workspace = TerminalWorkspace(kind: .panel(directory.path), storageKey: nil)
        panels[directory.path] = workspace
        return workspace
    }

    init(kind: Kind, storageKey: String?, layout: TerminalLayout? = nil) {
        self.kind = kind
        // Tests never read or write the app's saved layout.
        self.storageKey = KemoSabeMacApp.isTestHost ? nil : storageKey
        if let layout { self.layout = layout }
        else if let key = self.storageKey, let data = UserDefaults.standard.data(forKey: key), let saved = try? JSONDecoder().decode(TerminalLayout.self, from: data) {
            self.layout = saved.forRestore(home: NSHomeDirectory()) { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
        } else { self.layout = TerminalLayout() }
    }
    private func save() {
        guard let storageKey, let data = try? JSONEncoder().encode(layout.forRestore(home: NSHomeDirectory(), exists: { _ in true })) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    var home: String { NSHomeDirectory() }
    private var baseDirectory: String {
        if case .panel(let path) = kind { return path }
        return home
    }
    /// The focused pane's folder (as its shell reports it), for a new tab or split.
    var currentDirectory: String? {
        guard let pane = layout.selectedTab?.focusedPane else { return nil }
        return TerminalSessions.shared.state(pane.id)?.cwd ?? pane.directory
    }
    func title(of tab: TerminalTab) -> String {
        guard let pane = tab.focusedPane else { return tab.customTitle ?? "Terminal" }
        return TerminalSessions.shared.title(for: pane, custom: tab.customTitle)
    }

    // MARK: Opening

    private func newPane(profile: TerminalProfile?, agent: CodingAgentCommand?, directory: String?) -> TerminalPaneSpec {
        let preferences = TerminalPreferences.shared
        let profile = profile ?? preferences.profile(nil)
        let folder = directory ?? profile.startFolder(current: currentDirectory ?? baseDirectory, home: home)
        let command = agent?.command ?? (profile.command.isEmpty ? nil : profile.command)
        let label = agent?.name ?? (profile.command.isEmpty ? nil : profile.name)
        return TerminalPaneSpec(directory: folder, profileID: profile.id, command: command, label: label)
    }
    /// A new tab after the current one. Returns its pane, for callers that follow what runs in it.
    @discardableResult func openTab(profile: TerminalProfile? = nil, agent: CodingAgentCommand? = nil, directory: String? = nil) -> UUID {
        let pane = newPane(profile: profile, agent: agent, directory: directory)
        layout.newTab(pane, after: layout.selectedIndex)
        TerminalSessions.shared.focus(pane.id)
        return pane.id
    }
    /// Opens one tab when there's none, in the surface's own folder.
    func ensureTab() {
        if layout.tabs.isEmpty { openTab(directory: nil) }
    }
    /// Splits the focused pane; the new pane starts in the same folder with the default profile.
    func split(_ axis: TerminalSplitAxis, profile: TerminalProfile? = nil) {
        guard layout.selectedTab != nil else { openTab(profile: profile); return }
        let pane = newPane(profile: profile, agent: nil, directory: currentDirectory)
        layout.split(axis, with: pane)
        TerminalSessions.shared.focus(pane.id)
    }

    // MARK: Closing

    /// ⌘W: closes the focused pane, asking first when something is still running in it.
    func closeFocusedPane() {
        guard let pane = layout.selectedTab?.focused else { return }
        close(panes: [pane], description: "this terminal") { [weak self] in self?.removePane(pane) }
    }
    func closeTab(_ id: UUID) {
        guard let tab = layout.tabs.first(where: { $0.id == id }) else { return }
        close(panes: tab.root.paneIDs, description: tab.root.paneIDs.count > 1 ? "this tab" : "this terminal") { [weak self] in
            guard let self else { return }
            TerminalSessions.shared.end(layout.closeTab(id))
            afterClose()
        }
    }
    func closePane(_ id: UUID) {
        close(panes: [id], description: "this terminal") { [weak self] in self?.removePane(id) }
    }
    private func removePane(_ id: UUID) {
        TerminalSessions.shared.end(layout.closePane(id))
        afterClose()
    }
    private func afterClose() {
        if find.map({ id in !layout.allPanes.contains { $0.id == id.pane } }) == true { find = nil }
        if let pane = layout.selectedTab?.focused { TerminalSessions.shared.focus(pane) }
        if layout.tabs.isEmpty { onEmpty?() }
    }
    private func close(panes: [UUID], description: String, then action: @escaping () -> Void) {
        let running = panes.compactMap { TerminalSessions.shared.runningProgram($0) }
        guard let first = running.first else { action(); return }
        let alert = NSAlert()
        alert.messageText = "Close \(description)?"
        alert.informativeText = running.count > 1 ? "\(running.count) programs are still running. Closing stops them." : "\(first) is still running. Closing stops it."
        alert.addButton(withTitle: "Close"); alert.addButton(withTitle: "Cancel")
        if let window = NSApp.keyWindow { alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { action() } } }
        else if alert.runModal() == .alertFirstButtonReturn { action() }
    }

    // MARK: Moving around

    func select(_ tab: UUID) {
        guard let index = layout.tabs.firstIndex(where: { $0.id == tab }) else { return }
        layout.selectTab(at: index)
        if let pane = layout.selectedTab?.focused { TerminalSessions.shared.focus(pane) }
    }
    func moveTab(_ id: UUID, before target: UUID?) {
        guard let source = layout.tabs.firstIndex(where: { $0.id == id }) else { return }
        let destination = target.flatMap { t in layout.tabs.firstIndex { $0.id == t } } ?? layout.tabs.count
        layout.moveTab(from: source, to: destination)
    }
    func rename(_ tab: UUID, _ title: String) { layout.rename(tab, title); renamingTab = nil }
    func setRatio(_ ratio: Double, at path: [Int], in tab: UUID) { layout.setRatio(ratio, at: path, in: tab) }
    func equalize(_ tab: UUID) { layout.equalize(tab) }
    /// A click in a pane focuses it (and its tab).
    func focusFromClick(_ pane: UUID) {
        guard layout.selectedTab?.focused != pane else { return }
        layout.focus(pane)
        TerminalSessions.shared.focus(pane)
    }
    func directoryChanged(_ pane: UUID, _ path: String) { layout.updateDirectory(pane, path) }

    /// A key command from a pane in this surface.
    func perform(_ action: TerminalKeyAction, from pane: UUID) -> Bool {
        if layout.selectedTab?.focused != pane { layout.focus(pane) }
        switch action {
        case .newTab: openTab()
        case .closePane: closeFocusedPane()
        case .splitRight: split(.sideBySide)
        case .splitDown: split(.stacked)
        case .equalizeSplits: if let tab = layout.selectedTab { equalize(tab.id) }
        case .focus(let direction):
            if layout.moveFocus(direction), let next = layout.selectedTab?.focused { TerminalSessions.shared.focus(next) } else { NSSound.beep() }
        case .selectTab(let index):
            guard !layout.tabs.isEmpty else { return false }
            select(layout.tabs[index < 0 ? layout.tabs.count - 1 : min(index, layout.tabs.count - 1)].id)
        case .nextTab, .previousTab:
            layout.cycleTab(action == .nextTab ? 1 : -1)
            if let next = layout.selectedTab?.focused { TerminalSessions.shared.focus(next) }
        case .find:
            if find?.pane == pane { find?.focusRequest += 1 } else { endFind(); find = FindState(pane: pane, text: NSPasteboard(name: .find).string(forType: .string) ?? "") }
        case .findNext, .findPrevious:
            guard find?.pane == pane else { return false }
            runFind(backward: action == .findPrevious)
        default: return false
        }
        return true
    }

    // MARK: Find

    /// Searches the pane's scrollback for the find text. Backward goes up toward older output.
    func runFind(backward: Bool) {
        guard var state = find, let view = TerminalSessions.shared.existingView(state.pane) else { return }
        let result = view.find(state.text, options: SearchOptions(caseSensitive: state.caseSensitive, regex: state.regex), backward: backward)
        state.index = result.index; state.total = result.total
        find = state
        if !state.text.isEmpty {
            let pasteboard = NSPasteboard(name: .find)
            pasteboard.clearContents(); pasteboard.setString(state.text, forType: .string)
        }
    }
    func endFind() {
        guard let state = find else { return }
        find = nil
        TerminalSessions.shared.existingView(state.pane)?.endFind()
        TerminalSessions.shared.focus(state.pane)
    }
}

// MARK: The Terminal page

/// Tsukumo → Terminal: a standalone terminal with tabs and splits, restored on relaunch. A file
/// ⌘-clicked in it opens in Tsukumo's editor beside it.
struct TerminalPage: View {
    @Environment(DesktopNavigation.self) private var desktop
    @Environment(DesktopPreferences.self) private var preferences
    @Environment(\.colorScheme) private var scheme
    @State private var workspace = TerminalWorkspace.main
    @State private var editor: TerminalEditorTarget?
    @State private var editorRequest: String?
    var body: some View {
        HSplitView {
            TerminalSurfaceView(workspace: workspace, openSettings: { desktop.settingsPage = "Terminal" })
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            if let editor {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text").foregroundStyle(.secondary)
                        Text(editor.relativePath + (editor.line.map { ":\($0)" } ?? "")).lineLimit(1).truncationMode(.head)
                        Spacer()
                        Button { self.editor = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(DesktopRowButtonStyle(inset: 6)).help("Close editor").accessibilityLabel("Close editor")
                    }.font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 6).background(preferences.palette(scheme).sidebar)
                    Divider()
                    CodingFileEditor(root: editor.root, editable: true, openRequest: $editorRequest, openLine: editor.line)
                        .id(editor.root.path)
                }
                .frame(minWidth: 320, idealWidth: 480, maxWidth: .infinity)
                .background(preferences.palette(scheme).background)
            }
        }
        .onAppear {
            workspace.ensureTab()
            TerminalFileOpener.handler = { url, line in
                let root = TerminalFileOpener.projectRoot(for: url)
                let relative = url.path.replacingOccurrences(of: root.path + "/", with: "", options: .anchored)
                editor = TerminalEditorTarget(root: root, relativePath: relative, line: line)
                editorRequest = relative
            }
        }
        .onDisappear { TerminalFileOpener.handler = nil }
    }
}
struct TerminalEditorTarget: Equatable {
    var root: URL
    var relativePath: String
    var line: Int?
}

/// The terminal panel under a project or task, in its folder. The same tabs and splits as the
/// Terminal page, with the installed agents one click away.
struct TerminalPanel: View {
    let directory: URL
    var body: some View {
        TerminalSurfaceView(workspace: TerminalWorkspace.panel(directory), compact: true, openSettings: nil)
    }
}

// MARK: Tabs and splits

/// A terminal surface: its tab bar and the selected tab's split panes.
struct TerminalSurfaceView: View {
    let workspace: TerminalWorkspace
    var compact = false
    var openSettings: (() -> Void)?
    @Environment(DesktopPreferences.self) private var preferences
    @Environment(\.colorScheme) private var scheme
    @State private var sessions = TerminalSessions.shared
    @State private var terminalPreferences = TerminalPreferences.shared
    var body: some View {
        let palette = preferences.palette(scheme)
        VStack(spacing: 0) {
            TerminalTabBar(workspace: workspace, openSettings: openSettings).background(palette.sidebar)
            Divider()
            if let tab = workspace.layout.selectedTab {
                TerminalSplitNodeView(workspace: workspace, tab: tab, node: tab.root, path: [])
                    .id(tab.id)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "terminal").font(.system(size: 26)).foregroundStyle(.secondary)
                    Text("No terminal open").foregroundStyle(.secondary)
                    Button("New terminal") { workspace.openTab() }.keyboardShortcut("t", modifiers: .command)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(palette.background)
            }
        }
        .onAppear {
            sessions.checkAgents()
            workspace.ensureTab()
        }
    }
}

/// Tabs (drag to reorder, double-click to rename), agents, and the terminal menu.
struct TerminalTabBar: View {
    let workspace: TerminalWorkspace
    var openSettings: (() -> Void)?
    @State private var sessions = TerminalSessions.shared
    @State private var terminalPreferences = TerminalPreferences.shared
    @State private var renameText = ""
    @FocusState private var renaming: Bool
    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(workspace.layout.tabs.enumerated()), id: \.element.id) { index, tab in
                        tabView(tab, index: index, selected: workspace.layout.selectedTab?.id == tab.id)
                    }
                }
            }
            Spacer(minLength: 8)
            if SecureKeyboardEntry.isOn && terminalPreferences.secureKeyboardEntry {
                Image(systemName: "lock.fill").foregroundStyle(.secondary).help("Secure keyboard entry is on").accessibilityLabel("Secure keyboard entry is on")
            }
            ForEach(CodingAgentCommand.known.filter { sessions.installed.contains($0.command) }.prefix(2)) { agent in
                Button { workspace.openTab(agent: agent) } label: { Label(agent.name, systemImage: "sparkles") }
                    .buttonStyle(DesktopRowButtonStyle(inset: 6)).help("Start \(agent.name) in a new tab")
                    .accessibilityIdentifier("startAgent-" + agent.id)
            }
            Button { workspace.split(.sideBySide) } label: { Image(systemName: "square.split.2x1") }
                .buttonStyle(DesktopRowButtonStyle(inset: 6)).help("Split right (⌘D)").accessibilityLabel("Split right")
                .disabled(workspace.layout.tabs.isEmpty)
            menu
        }
        .font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 5)
    }
    private var focused: UUID? { workspace.layout.selectedTab?.focused }
    private var menu: some View {
        Menu {
            Button("New terminal") { workspace.openTab() }
            if terminalPreferences.profiles.count > 1 {
                Menu("New tab with profile") {
                    ForEach(terminalPreferences.profiles) { profile in Button(profile.name) { workspace.openTab(profile: profile) } }
                }
            }
            Section("Agents") {
                ForEach(CodingAgentCommand.known) { agent in
                    let available = sessions.installed.contains(agent.command)
                    Button(available ? agent.name : agent.name + " (not installed)") { workspace.openTab(agent: agent) }.disabled(!available)
                }
            }
            Divider()
            Button("Split right") { workspace.split(.sideBySide) }.disabled(focused == nil)
            Button("Split down") { workspace.split(.stacked) }.disabled(focused == nil)
            Button("Even out splits") { if let tab = workspace.layout.selectedTab { workspace.equalize(tab.id) } }.disabled((workspace.layout.selectedTab?.panes.count ?? 0) < 2)
            Divider()
            Button("Find…") { if let focused { _ = workspace.perform(.find, from: focused) } }.disabled(focused == nil)
            Button("Select output of last command") { if let focused { sessions.existingView(focused)?.selectCommandOutput() } }.disabled(focused == nil)
            Button("Clear") { if let focused { sessions.clear(focused) } }.disabled(focused == nil)
            Divider()
            Button("Larger text") { sessions.adjustFont(1) }
            Button("Smaller text") { sessions.adjustFont(-1) }
            Button("Actual size") { sessions.adjustFont(0) }.disabled(sessions.fontDelta == 0)
            if let openSettings {
                Divider()
                Button("Terminal settings…") { openSettings() }
            }
        } label: { Image(systemName: "plus") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("New terminal, agents, and terminal commands")
            .accessibilityIdentifier("newTerminal")
    }
    private func tabView(_ tab: TerminalTab, index: Int, selected: Bool) -> some View {
        let pane = tab.focusedPane
        let state = pane.flatMap { sessions.state($0.id) }
        let title = workspace.title(of: tab)
        let exited = state?.exited == true
        let bell = tab.panes.contains { sessions.state($0.id)?.bellRang == true }
        return HStack(spacing: 6) {
            Image(systemName: exited ? "stop.circle" : state?.tracker.isRunning == true ? "circle.fill" : pane?.label != nil ? "sparkles" : "terminal")
                .font(.system(size: state?.tracker.isRunning == true ? 6 : 11)).frame(width: 12)
            if workspace.renamingTab == tab.id {
                TextField("Tab name", text: $renameText).textFieldStyle(.plain).frame(width: 130).focused($renaming)
                    .onSubmit { workspace.rename(tab.id, renameText) }
                    .onExitCommand { workspace.renamingTab = nil }
                    .onAppear { renameText = tab.customTitle ?? title; renaming = true }
            } else {
                Text(title).lineLimit(1).truncationMode(.middle).frame(maxWidth: 170, alignment: .leading)
                    .foregroundStyle(exited ? .secondary : .primary)
            }
            if tab.panes.count > 1 { Text("\(tab.panes.count)").font(.system(size: 10)).foregroundStyle(.secondary).help("\(tab.panes.count) panes") }
            if bell && !selected { Circle().fill(Color.orange).frame(width: 5, height: 5).accessibilityLabel("Bell") }
            Button { workspace.closeTab(tab.id) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Close tab").accessibilityLabel("Close \(title)")
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color.primary.opacity(selected ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        // A click selects at once; a second click renames.
        .onTapGesture { workspace.select(tab.id) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { workspace.renamingTab = tab.id })
        .contextMenu {
            Button("Rename…") { workspace.renamingTab = tab.id }
            if tab.customTitle != nil { Button("Use automatic title") { workspace.rename(tab.id, "") } }
            Button("Close tab") { workspace.closeTab(tab.id) }
        }
        .draggable(tab.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)), id != tab.id else { return false }
            workspace.moveTab(id, before: tab.id)
            return true
        }
        .help(index < 9 ? "⌘\(index + 1)" : "")
        .accessibilityElement(children: .combine).accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(exited ? "Exited" : "").accessibilityIdentifier("terminalTab")
    }
}

/// One node of a tab's split tree: a pane, or two subtrees with a draggable divider between them.
struct TerminalSplitNodeView: View {
    let workspace: TerminalWorkspace
    let tab: TerminalTab
    let node: TerminalSplit
    let path: [Int]
    @State private var hovering = false
    var body: some View {
        switch node {
        case .pane(let id):
            if let pane = tab.pane(id) {
                TerminalPaneView(workspace: workspace, pane: pane, focused: tab.focused == id, dimmed: tab.panes.count > 1 && tab.focused != id)
            }
        case .split(let axis, let ratio, let first, let second):
            GeometryReader { geometry in
                let horizontal = axis == .sideBySide
                let total = horizontal ? geometry.size.width : geometry.size.height
                let firstSize = max(0, (total - 1) * ratio)
                let layout = horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
                layout {
                    TerminalSplitNodeView(workspace: workspace, tab: tab, node: first, path: path + [0])
                        .frame(width: horizontal ? firstSize : nil, height: horizontal ? nil : firstSize)
                    divider(horizontal: horizontal, total: total)
                    TerminalSplitNodeView(workspace: workspace, tab: tab, node: second, path: path + [1])
                }
                .coordinateSpace(name: spaceName)
            }
        }
    }
    /// A hairline with a wider grab area; drag to resize, double-click to even out.
    private func divider(horizontal: Bool, total: CGFloat) -> some View {
        Rectangle().fill(Color.primary.opacity(hovering ? 0.25 : 0.12))
            .frame(width: horizontal ? 1 : nil, height: horizontal ? nil : 1)
            .overlay {
                Color.clear.contentShape(Rectangle())
                    .frame(width: horizontal ? 8 : nil, height: horizontal ? nil : 8)
                    .onHover { inside in
                        hovering = inside
                        if inside { (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named(spaceName)).onChanged { value in
                        guard total > 0 else { return }
                        workspace.setRatio(Double((horizontal ? value.location.x : value.location.y) / total), at: path, in: tab.id)
                    })
                    .onTapGesture(count: 2) { workspace.setRatio(0.5, at: path, in: tab.id) }
            }
            .accessibilityElement().accessibilityLabel(horizontal ? "Vertical divider" : "Horizontal divider")
            .accessibilityAdjustableAction { direction in
                guard case .split(_, let ratio, _, _) = node else { return }
                workspace.setRatio(ratio + (direction == .increment ? 0.05 : -0.05), at: path, in: tab.id)
            }
    }
    private var spaceName: String { "terminal-split-" + path.map(String.init).joined() }
}

/// One pane: its terminal, a dim when another pane has focus, the find bar, and the bar shown when
/// its process has ended.
struct TerminalPaneView: View {
    let workspace: TerminalWorkspace
    let pane: TerminalPaneSpec
    let focused: Bool
    let dimmed: Bool
    @Environment(DesktopPreferences.self) private var preferences
    @Environment(\.colorScheme) private var scheme
    @State private var sessions = TerminalSessions.shared
    @State private var terminalPreferences = TerminalPreferences.shared
    var body: some View {
        let state = sessions.state(pane.id)
        let appearance = self.appearance
        ZStack(alignment: .topTrailing) {
            TerminalPaneHost(workspace: workspace, pane: pane, appearance: appearance, focused: focused)
                .id("\(pane.id)-\(state?.run ?? 0)")
                .padding(.leading, 6).padding(.top, 4)
                .background(background(appearance))
            if dimmed { Color.black.opacity(scheme == .dark ? 0.18 : 0.06).allowsHitTesting(false) }
            if let find = workspace.find, find.pane == pane.id {
                TerminalFindBar(workspace: workspace).padding(8)
            }
        }
        .overlay(alignment: .bottom) { if state?.exited == true { exitedBar(state) } }
    }
    private var appearance: TerminalAppearance {
        let profile = terminalPreferences.profile(pane.profileID)
        let palette = preferences.palette(scheme)
        let colors = TerminalColorScheme.named(profile.colorScheme).resolved(appBackground: NSColor(palette.background), appForeground: NSColor(palette.foreground),
                                                                             appAccent: NSColor(palette.accent), appIsDark: scheme == .dark)
        let size = (profile.fontSize > 0 ? profile.fontSize : preferences.codeFontSize) + sessions.fontDelta
        return TerminalAppearance(colors: colors, fontFamily: profile.fontFamily.isEmpty ? preferences.codeFontFamily : profile.fontFamily,
                                  fontSize: max(7, size), cursor: profile.cursor, cursorBlinks: profile.cursorBlinks, opacity: terminalPreferences.opacity)
    }
    @ViewBuilder private func background(_ appearance: TerminalAppearance) -> some View {
        if appearance.opacity < 1 {
            ZStack {
                if terminalPreferences.blur { TerminalBlurMaterial() }
                Color(nsColor: appearance.colors.background.withAlphaComponent(appearance.opacity))
            }
        } else {
            Color(nsColor: appearance.colors.background)
        }
    }
    private func exitedBar(_ state: TerminalPaneState?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "stop.circle").foregroundStyle(.secondary)
            Text(state?.exitCode.map { "Process exited (code \($0))" } ?? "Process exited").foregroundStyle(.secondary)
            Spacer()
            Button("Restart") { sessions.restart(pane.id) }.buttonStyle(DesktopRowButtonStyle(inset: 6)).accessibilityIdentifier("restartTerminal")
            Button("Close") { workspace.closePane(pane.id) }.buttonStyle(DesktopRowButtonStyle(inset: 6))
        }
        .font(.system(size: 12)).padding(.horizontal, 12).padding(.vertical, 6)
        .background(preferences.palette(scheme).sidebar).overlay(alignment: .top) { Divider() }
    }
}

/// ⌘F: find in the pane's scrollback, with every visible match highlighted and a count.
struct TerminalFindBar: View {
    let workspace: TerminalWorkspace
    @FocusState private var fieldFocused: Bool
    var body: some View {
        let state = workspace.find
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in terminal", text: Binding(get: { workspace.find?.text ?? "" }, set: { workspace.find?.text = $0; workspace.runFind(backward: true) }))
                .textFieldStyle(.plain).frame(width: 170).focused($fieldFocused)
                .onSubmit { workspace.runFind(backward: !NSEvent.modifierFlags.contains(.shift)) }
                .onExitCommand { workspace.endFind() }
                .accessibilityIdentifier("terminalFindField")
            Text(summary(state)).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit().frame(minWidth: 54, alignment: .trailing)
            toggle("Aa", on: state?.caseSensitive == true, help: "Match case") { workspace.find?.caseSensitive.toggle(); workspace.runFind(backward: true) }
            toggle(".*", on: state?.regex == true, help: "Regular expression") { workspace.find?.regex.toggle(); workspace.runFind(backward: true) }
            Button { workspace.runFind(backward: true) } label: { Image(systemName: "chevron.up") }.help("Previous match (⇧⌘G)").accessibilityLabel("Previous match")
            Button { workspace.runFind(backward: false) } label: { Image(systemName: "chevron.down") }.help("Next match (⌘G)").accessibilityLabel("Next match")
            Button { workspace.endFind() } label: { Image(systemName: "xmark") }.help("Close (Esc)").accessibilityLabel("Close find")
        }
        .buttonStyle(DesktopRowButtonStyle(inset: 5))
        .font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .onAppear { fieldFocused = true; if !(state?.text.isEmpty ?? true) { workspace.runFind(backward: true) } }
        .onChange(of: state?.focusRequest) { fieldFocused = true }
    }
    private func summary(_ state: TerminalWorkspace.FindState?) -> String {
        guard let state, !state.text.isEmpty else { return "" }
        if state.total == 0 { return "No matches" }
        return state.index > 0 ? "\(state.index) of \(state.total)" : "\(state.total) found"
    }
    private func toggle(_ label: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(label).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(on ? Color.accentColor : .secondary) }
            .help(help).accessibilityLabel(help).accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Hosts a pane's terminal view. The view lives in `TerminalSessions`; a container keeps it, so a
/// pane that moves in the tree (after a split) is re-parented rather than restarted.
struct TerminalPaneHost: NSViewRepresentable {
    let workspace: TerminalWorkspace
    let pane: TerminalPaneSpec
    let appearance: TerminalAppearance
    let focused: Bool
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> TerminalPaneContainer {
        let container = TerminalPaneContainer()
        let view = TerminalSessions.shared.view(for: pane, owner: workspace)
        appearance.apply(to: view)
        container.attach(view)
        context.coordinator.focused = focused
        if focused { TerminalSessions.shared.focus(pane.id) }
        return container
    }
    func updateNSView(_ container: TerminalPaneContainer, context: Context) {
        // A pane that was just closed isn't started again by a late update.
        guard let view = TerminalSessions.shared.existingView(pane.id)
                ?? (workspace.layout.allPanes.contains { $0.id == pane.id } ? TerminalSessions.shared.view(for: pane, owner: workspace) : nil) else { return }
        if container.terminal !== view { container.attach(view) }
        appearance.apply(to: view)
        // Focus moves with the tree (a split, ⌘⌥arrows, a click), not on every redraw.
        if focused && !context.coordinator.focused { TerminalSessions.shared.focus(pane.id) }
        context.coordinator.focused = focused
    }
    static func dismantleNSView(_ container: TerminalPaneContainer, coordinator: Coordinator) {
        // The pane keeps its process; its view is reused when it shows again.
        container.detach()
    }
    final class Coordinator { var focused = false }
}

final class TerminalPaneContainer: NSView {
    private(set) weak var terminal: TsukumoTerminalView?
    func attach(_ view: TsukumoTerminalView) {
        terminal = view
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
    }
    func detach() {
        if let terminal, terminal.superview === self { terminal.removeFromSuperview() }
    }
}

/// The blur behind a translucent terminal.
struct TerminalBlurMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

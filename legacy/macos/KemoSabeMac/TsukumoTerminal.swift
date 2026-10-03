import AppKit
import Darwin
import SwiftTerm
import SwiftUI

/// A coding agent Tsukumo can start in a terminal: a command-line tool the person
/// installed and signed in to themselves. Tsukumo launches it in the project folder;
/// it runs with the person's own tools and logins, as it would in Terminal.
struct CodingAgentCommand: Identifiable, Hashable {
    let id: String
    let name: String
    let command: String
    static let known: [CodingAgentCommand] = [
        .init(id: "codex", name: "Codex", command: "codex"),
        .init(id: "claude", name: "Claude Code", command: "claude"),
        .init(id: "gemini", name: "Gemini CLI", command: "gemini"),
        .init(id: "opencode", name: "OpenCode", command: "opencode")
    ]
}

/// What Tsukumo knows about a pane's shell right now, from its marks and titles.
struct TerminalPaneState: Equatable {
    /// The folder the pane started in (a project's or task's folder), for finding its dev servers.
    var origin: String
    /// The shell's folder, from OSC 7.
    var cwd: String?
    /// The latest title a program set (OSC 0 or 2), and the one set while the current command runs.
    var programTitle: String?
    var commandTitle: String?
    var tracker = TerminalCommandTracker()
    var exited = false
    var exitCode: Int32?
    /// Bumped by Restart, so the pane gets a fresh terminal view and process.
    var run = 0
    /// The bell rang while the pane wasn't in front; cleared when it's focused.
    var bellRang = false
}

/// Every terminal pane in Tsukumo: their views (which outlive SwiftUI, so shells and agents keep
/// running while you switch pages) and what their shells have reported. Closing a pane ends its process.
@MainActor @Observable final class TerminalSessions {
    static let shared = TerminalSessions()
    private(set) var states: [UUID: TerminalPaneState] = [:]
    /// Agents found on the person's PATH, checked once through their login shell.
    private(set) var installed: Set<String> = []
    private(set) var checkedAgents = false
    /// Points added to (or taken from) the terminal font size: ⌘+, ⌘-, and ⌘0.
    private(set) var fontDelta: CGFloat = 0
    @ObservationIgnored private var views: [UUID: TsukumoTerminalView] = [:]
    @ObservationIgnored private var integrationReady: Bool?

    static var shell: String { ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh" }
    static var home: String { NSHomeDirectory() }

    func state(_ id: UUID) -> TerminalPaneState? { states[id] }
    func existingView(_ id: UUID) -> TsukumoTerminalView? { views[id] }

    /// The title for a pane: its running command, the program's own title, or its folder.
    func title(for pane: TerminalPaneSpec, custom: String? = nil) -> String {
        let state = states[pane.id]
        let hasIntegration = state?.tracker.hasIntegration == true
        // Without integration, a foreground program other than the shell is the best sign something runs.
        let running = state?.tracker.isRunning == true ? (state?.tracker.running ?? foregroundProcessName(pane.id))
                    : hasIntegration ? nil : foregroundProcessName(pane.id)
        // An agent's name stands in until its command starts; then the command (or its own title) shows.
        let label = (state?.tracker.prompts ?? 0) == 0 ? pane.label : nil
        // With integration the folder is known; without it, a shell's own title is the best guess.
        let programTitle = running != nil ? state?.commandTitle : (hasIntegration ? nil : state?.programTitle)
        return TerminalTitle.make(custom: custom, command: running, programTitle: programTitle,
                                  directory: hasIntegration || programTitle == nil ? (state?.cwd ?? pane.directory) : nil, label: label, home: Self.home)
    }

    /// The terminal view for a pane, created and started once.
    func view(for spec: TerminalPaneSpec, owner: TerminalWorkspace) -> TsukumoTerminalView {
        if let existing = views[spec.id] { existing.owner = owner; return existing }
        let preferences = TerminalPreferences.shared
        let profile = preferences.profile(spec.profileID)
        var options = TerminalOptions.default
        options.scrollback = preferences.scrollback
        options.cursorStyle = profile.cursor.style(blinking: profile.cursorBlinks)
        let view = TsukumoTerminalView(frame: .init(x: 0, y: 0, width: 800, height: 300), font: nil, options: options)
        view.paneID = spec.id
        view.owner = owner
        // The view keeps its own relay (the delegate is weak), so a pane that's hidden when its
        // process ends still learns of it.
        view.relay = TerminalRelay(id: spec.id)
        view.processDelegate = view.relay
        if preferences.gpuRendering { try? view.setUseMetal(true) }
        views[spec.id] = view
        var state = states[spec.id] ?? TerminalPaneState(origin: spec.directory)
        state.cwd = spec.directory; state.exited = false; state.exitCode = nil; state.tracker = TerminalCommandTracker()
        states[spec.id] = state
        start(view, spec: spec, profile: profile)
        return view
    }

    private func start(_ view: TsukumoTerminalView, spec: TerminalPaneSpec, profile: TerminalProfile) {
        let preferences = TerminalPreferences.shared
        if integrationReady == nil { integrationReady = TerminalShellIntegration.install() }
        let shell = profile.shell.isEmpty ? Self.shell : (profile.shell as NSString).expandingTildeInPath
        let inherited = ProcessInfo.processInfo.environment
        let launch = TerminalShellIntegration.launch(shell: shell, enabled: preferences.shellIntegration && integrationReady == true, inherited: inherited)
        var environment: [String: String] = [:]
        for entry in Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true) {
            let parts = entry.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { environment[String(parts[0])] = String(parts[1]) }
        }
        for key in ["HOME", "USER", "LOGNAME", "PATH", "SHELL", "TMPDIR", "SSH_AUTH_SOCK", "__CF_USER_TEXT_ENCODING", "LANG", "LC_ALL", "LC_CTYPE"] {
            if let value = inherited[key] { environment[key] = value }
        }
        environment["TERM_PROGRAM"] = "Tsukumo"
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String { environment["TERM_PROGRAM_VERSION"] = version }
        environment.merge(launch.environment) { _, new in new }
        environment.merge(profile.environment) { _, new in new }
        var isDirectory: ObjCBool = false
        let folder = FileManager.default.fileExists(atPath: spec.directory, isDirectory: &isDirectory) && isDirectory.boolValue ? spec.directory : Self.home
        view.startProcess(executable: launch.executable, args: launch.arguments, environment: environment.map { "\($0.key)=\($0.value)" },
                          execName: launch.execName, currentDirectory: folder)
        // A command (an agent, or a profile's command) is typed at the first prompt, so the shell is
        // there when it ends. Without integration there's no prompt mark; it's typed after a moment.
        if let command = spec.command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty {
            view.pendingCommand = command
            let wait: Double = launch.integration == nil ? 0.6 : 6
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak view] in view?.typePendingCommand() }
        }
    }

    /// Ends panes' processes and forgets them.
    func end(_ ids: [UUID]) {
        for id in ids {
            // An exited process isn't signalled again: its ID may already belong to another process.
            if let view = views.removeValue(forKey: id) {
                if states[id]?.exited != true { view.terminate() }
                view.removeFromSuperview()
            }
            states.removeValue(forKey: id)
        }
    }
    /// Starts a pane's shell (or agent) again in a fresh terminal.
    func restart(_ id: UUID) {
        if let view = views.removeValue(forKey: id) {
            if states[id]?.exited != true { view.terminate() }
            view.removeFromSuperview()
        }
        states[id]?.exited = false; states[id]?.exitCode = nil; states[id]?.run += 1
    }
    /// Gives a pane's terminal the keyboard.
    func focus(_ id: UUID) {
        states[id]?.bellRang = false
        guard let view = views[id] else { return }
        if let window = view.window { window.makeFirstResponder(view) } else { view.focusWhenAttached = true }
    }
    /// Clears the screen and scrollback (⌘K); the shell redraws its prompt.
    func clear(_ id: UUID) { views[id]?.clearAll() }
    /// ⌘+ and ⌘- step the terminal text size; 0 (⌘0) goes back to the profile's size.
    func adjustFont(_ step: CGFloat) { fontDelta = step == 0 ? 0 : min(24, max(-8, fontDelta + step)) }
    /// The latest output of the terminals that started in a folder (up to 64 KB each), for finding a
    /// dev server a person started there.
    func recentOutput(in directory: URL) -> [String] {
        states.filter { $0.value.origin == directory.path }.keys.compactMap { views[$0]?.recentText }
    }
    /// Whether closing the pane would stop something: a command the shell reported, or any
    /// process in the foreground other than the shell. Returns its name.
    func runningProgram(_ id: UUID) -> String? {
        guard let state = states[id], !state.exited else { return nil }
        if state.tracker.isRunning { return state.tracker.running.map { String($0.prefix(40)) } ?? foregroundProcessName(id) ?? "A command" }
        return foregroundProcessName(id)
    }
    /// The name of the pane's foreground process when it isn't the shell itself.
    func foregroundProcessName(_ id: UUID) -> String? {
        guard let process = views[id]?.process, process.running, process.childfd >= 0 else { return nil }
        let group = tcgetpgrp(process.childfd)
        guard group > 0, group != process.shellPid else { return nil }
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(group, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    // MARK: Reports from the views

    func handle(_ events: [TerminalShellEvent], from id: UUID) {
        guard var state = states[id] else { return }
        let view = views[id]
        for event in events {
            if let finished = state.tracker.apply(event) {
                state.commandTitle = nil
                let preferences = TerminalPreferences.shared
                let inFront = NSApp.isActive && view?.window?.isKeyWindow == true
                if preferences.notifyLongCommands, TerminalCommandTracker.shouldNotify(finished, threshold: preferences.longCommandSeconds, appActive: inFront) {
                    TerminalNotifications.commandFinished(finished, folder: state.cwd)
                }
            }
            switch event {
            case .directory(let path):
                state.cwd = path
                view?.owner?.directoryChanged(id, path)
            case .title(let title):
                state.programTitle = title
                if state.tracker.isRunning { state.commandTitle = title }
            case .commandStart: state.commandTitle = nil
            case .promptStart: view?.typePendingCommand()
            default: break
            }
        }
        if states[id] != state { states[id] = state }
    }
    func markExited(_ id: UUID, code: Int32?) {
        guard states[id] != nil else { return }
        states[id]?.exited = true; states[id]?.exitCode = code
    }
    func titleChanged(_ id: UUID, _ title: String) {
        guard var state = states[id] else { return }
        state.programTitle = title
        if state.tracker.isRunning { state.commandTitle = title }
        if states[id] != state { states[id] = state }
    }
    func bellRang(_ id: UUID) {
        guard let view = views[id], view.window?.firstResponder !== view else { return }
        states[id]?.bellRang = true
    }

    /// Finds which agents are installed, through a login shell so Homebrew and npm paths count.
    func checkAgents() {
        guard !checkedAgents else { return }
        checkedAgents = true
        let names = CodingAgentCommand.known.map(\.command)
        let shell = Self.shell
        Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-l", "-c", names.map { "command -v \($0) >/dev/null 2>&1 && echo \($0)" }.joined(separator: "; ")]
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            var found: Set<String> = []
            if (try? process.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                found = Set(String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init))
            }
            let result = found
            await MainActor.run { TerminalSessions.shared.installed = result }
        }
    }
}

// MARK: Keys

/// The terminal's key commands. They apply while a terminal has the keyboard, before the app's menus.
enum TerminalKeyAction: Equatable {
    case newTab, closePane, splitRight, splitDown, focus(TerminalDirection), equalizeSplits
    case find, findNext, findPrevious, previousPrompt, nextPrompt, selectOutput
    case selectTab(Int), nextTab, previousTab
    case clear, fontBigger, fontSmaller, fontReset

    /// The command for a key and its modifiers (`key` is the key's character, ignoring modifiers).
    static func action(key: String, modifiers: NSEvent.ModifierFlags) -> TerminalKeyAction? {
        let flags = modifiers.intersection([.command, .option, .shift, .control])
        let up = String(UnicodeScalar(NSUpArrowFunctionKey)!), down = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!), right = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        switch flags {
        case [.command]:
            switch key {
            case "t": return .newTab
            case "w": return .closePane
            case "d": return .splitRight
            case "f": return .find
            case "g": return .findNext
            case "k": return .clear
            case "=", "+": return .fontBigger
            case "-": return .fontSmaller
            case "0": return .fontReset
            case up: return .previousPrompt
            case down: return .nextPrompt
            case "1", "2", "3", "4", "5", "6", "7", "8": return .selectTab(Int(key)! - 1)
            case "9": return .selectTab(-1)
            default: return nil
            }
        case [.command, .shift]:
            switch key.lowercased() {
            case "d": return .splitDown
            case "g": return .findPrevious
            case "a": return .selectOutput
            case "]", "}": return .nextTab
            case "[", "{": return .previousTab
            case "+", "=": return .fontBigger
            case "_": return .fontSmaller
            default: return nil
            }
        case [.command, .option]:
            switch key {
            case left: return .focus(.left)
            case right: return .focus(.right)
            case up: return .focus(.up)
            case down: return .focus(.down)
            default: return nil
            }
        case [.command, .control]:
            return key == "=" ? .equalizeSplits : nil
        case [.control]:
            return key == "\t" ? .nextTab : nil
        case [.control, .shift]:
            return key == "\t" || key == "\u{19}" ? .previousTab : nil
        default: return nil
        }
    }
}

/// Option as Meta for each Option key: SwiftTerm has one switch, so it's set from the key that's
/// down just before each key press reaches the terminal.
@MainActor enum TerminalOptionKeys {
    private static var monitor: Any?
    static func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if let view = event.window?.firstResponder as? TsukumoTerminalView {
                view.optionAsMetaKey = isMeta(rawFlags: event.modifierFlags.rawValue, preferences: TerminalPreferences.shared)
            }
            return event
        }
    }
    /// The device-dependent bits say which Option key is down (left 0x20, right 0x40).
    static func isMeta(rawFlags: UInt, preferences: TerminalPreferences) -> Bool {
        let left = rawFlags & 0x20 != 0, right = rawFlags & 0x40 != 0
        if left && right { return preferences.leftOptionIsMeta || preferences.rightOptionIsMeta }
        if left { return preferences.leftOptionIsMeta }
        if right { return preferences.rightOptionIsMeta }
        return preferences.leftOptionIsMeta
    }
}

// MARK: The terminal view

/// A terminal view with Tsukumo's behavior: focus on click, shell integration (folder, prompt marks,
/// command timing), key commands, find with highlighted matches, ⌘-click on files, copy on select,
/// paste protection, the bell, and the tail of its output (to find dev servers).
final class TsukumoTerminalView: LocalProcessTerminalView {
    var paneID = UUID()
    weak var owner: TerminalWorkspace?
    /// Reports the title and the process's exit for this view's pane.
    var relay: TerminalRelay?
    /// Set when the view is shown, so it takes keyboard focus once it's in a window.
    var focusWhenAttached = false
    /// Typed at the first prompt, then cleared.
    var pendingCommand: String?
    /// The appearance last applied, so an unchanged one isn't applied again (that resizes the grid).
    var terminalAppearance: TerminalAppearance?
    private var tail = TerminalByteRing(capacity: 65_536)
    private var scanner = TerminalOSCScanner()
    private var matchOverlay: TerminalMatchOverlay?
    private var mouseDownPoint: NSPoint?

    var recentText: String { String(decoding: tail.bytes, as: UTF8.self) }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        tail.append(slice)
        let events = scanner.scanFast(slice)
        if !events.isEmpty { MainActor.assumeIsolated { TerminalSessions.shared.handle(events, from: paneID) } }
        if matchOverlay?.term.isEmpty == false { matchOverlay?.needsDisplay = true }
    }
    func typePendingCommand() {
        guard let command = pendingCommand else { return }
        pendingCommand = nil
        send(txt: command + "\r")
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if focusWhenAttached, let window { focusWhenAttached = false; window.makeFirstResponder(self) }
    }
    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        MainActor.assumeIsolated { owner?.focusFromClick(paneID) }
        mouseDownPoint = event.locationInWindow
        super.mouseDown(with: event)
    }
    override func mouseUp(with event: NSEvent) {
        let moved = mouseDownPoint.map { hypot($0.x - event.locationInWindow.x, $0.y - event.locationInWindow.y) > 3 } ?? false
        // ⌘-click on a file path (file:line:col) opens it; URLs are SwiftTerm's own links.
        if event.modifierFlags.contains(.command), !moved, event.clickCount == 1, openPath(at: event) { return }
        super.mouseUp(with: event)
        if MainActor.assumeIsolated({ TerminalPreferences.shared.copyOnSelect }), selectionActive, let text = getSelection(), !text.isEmpty {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown,
              let action = TerminalKeyAction.action(key: event.charactersIgnoringModifiers ?? "", modifiers: event.modifierFlags) else {
            return super.performKeyEquivalent(with: event)
        }
        return MainActor.assumeIsolated { perform(action) } || super.performKeyEquivalent(with: event)
    }
    @MainActor func perform(_ action: TerminalKeyAction) -> Bool {
        switch action {
        case .clear: clearAll(); return true
        case .fontBigger: TerminalSessions.shared.adjustFont(1); return true
        case .fontSmaller: TerminalSessions.shared.adjustFont(-1); return true
        case .fontReset: TerminalSessions.shared.adjustFont(0); return true
        case .previousPrompt: jumpToPrompt(previous: true); return true
        case .nextPrompt: jumpToPrompt(previous: false); return true
        case .selectOutput: return selectCommandOutput()
        default: return owner?.perform(action, from: paneID) ?? false
        }
    }
    @objc override func paste(_ sender: Any) {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        let protect = MainActor.assumeIsolated { TerminalPreferences.shared.pasteProtection }
        if protect, let warning = PasteProtection.warning(for: text) {
            let alert = NSAlert()
            alert.messageText = "Paste this text?"
            let preview = text.count > 400 ? String(text.prefix(400)) + "…" : text
            alert.informativeText = warning + "\n\n" + preview
            alert.addButton(withTitle: "Paste"); alert.addButton(withTitle: "Cancel")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't ask again"
            let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                if alert.suppressionButton?.state == .on { MainActor.assumeIsolated { TerminalPreferences.shared.pasteProtection = false } }
                if response == .alertFirstButtonReturn { self?.pasteNow(sender) }
            }
            if let window { alert.beginSheetModal(for: window, completionHandler: finish) } else { finish(alert.runModal()) }
            return
        }
        super.paste(sender)
    }
    private func pasteNow(_ sender: Any) { super.paste(sender) }
    override func bell(source: Terminal) {
        MainActor.assumeIsolated {
            let preferences = TerminalPreferences.shared
            switch preferences.bell {
            case .off: bellStyle = .none
            case .visual: bellStyle = .visual
            case .sound: bellStyle = .sound
            }
            if preferences.bounceDockOnBell && !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
            TerminalSessions.shared.bellRang(paneID)
        }
        super.bell(source: source)
    }
    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link), url.isFileURL {
            MainActor.assumeIsolated { TerminalFileOpener.open(url, line: nil) }
            return
        }
        super.requestOpenLink(source: source, link: link, params: params)
    }
    override func scrolled(source terminal: Terminal, yDisp: Int) {
        super.scrolled(source: terminal, yDisp: yDisp)
        matchOverlay?.needsDisplay = true
    }
    /// Clears the screen and the scrollback. Control-L asks the shell (or a full-screen program)
    /// to redraw, so the prompt comes back at the top.
    func clearAll() {
        send(txt: "\u{0C}")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.getTerminal().clearScrollback() }
    }

    // MARK: Geometry

    /// The size of one cell, computed as SwiftTerm does (the width of "W", snapped to the pixel grid).
    var cellSize: CGSize {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let height = ceil((CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)) * scale) / scale
        let width = (font.advancement(forGlyph: font.glyph(withName: "W")).width * scale).rounded() / scale
        return CGSize(width: max(1, width), height: max(1, height))
    }
    /// The visible row and column under a point in the view.
    func cell(at point: NSPoint) -> (row: Int, column: Int) {
        let size = cellSize
        return (Int((bounds.height - point.y) / size.height), Int(point.x / size.width))
    }

    // MARK: Files

    private func openPath(at event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        let (row, column) = cell(at: point)
        guard let line = getTerminal().getLine(row: row)?.translateToString(trimRight: true),
              let match = TerminalPathDetector.match(in: line, column: column) else { return false }
        let base = MainActor.assumeIsolated { TerminalSessions.shared.state(paneID)?.cwd } ?? NSHomeDirectory()
        guard let url = TerminalPathDetector.resolve(match.path, relativeTo: base) else { return false }
        MainActor.assumeIsolated { TerminalFileOpener.open(url, line: match.line) }
        return true
    }

    // MARK: Prompts and output

    /// Rows (from the start of the scrollback) where a prompt begins, from OSC 133 marks.
    func promptRows() -> [Int] {
        let terminal = getTerminal()
        var rows: [Int] = [], row = 0
        while terminal.bufferLine(atRow: row) != nil {
            if terminal.semanticPromptMarks(at: row).contains(where: { $0.kind == .initial }) { rows.append(row) }
            row += 1
        }
        return rows
    }
    private var lineCount: Int {
        let terminal = getTerminal()
        var count = terminal.getTopVisibleRow() + terminal.rows
        while terminal.bufferLine(atRow: count) != nil { count += 1 }
        return count
    }
    /// ⌘↑ and ⌘↓: scroll so the previous or next prompt is at the top. Without marks, a page.
    func jumpToPrompt(previous: Bool) {
        let top = getTerminal().getTopVisibleRow()
        let prompts = promptRows()
        guard !prompts.isEmpty else { previous ? pageUp() : pageDown(); return }
        if previous {
            scrollTo(row: prompts.last(where: { $0 < top }) ?? 0)
        } else if let next = prompts.first(where: { $0 > top }) {
            scrollTo(row: next)
        } else {
            scrollTo(row: lineCount)
        }
    }
    /// ⌘⇧A: selects the output of the last command (or, scrolled back, of the command at the top of
    /// the screen), from the marks. Copy it with ⌘C.
    @discardableResult func selectCommandOutput() -> Bool {
        let terminal = getTerminal()
        let prompts = promptRows()
        guard !prompts.isEmpty else { NSSound.beep(); return false }
        let total = lineCount
        let atBottom = terminal.getTopVisibleRow() + terminal.rows >= total
        let index: Int
        if atBottom { index = max(0, prompts.count - 2) }
        else { index = prompts.lastIndex(where: { $0 <= terminal.getTopVisibleRow() }) ?? 0 }
        let start = prompts[index], end = index + 1 < prompts.count ? prompts[index + 1] : total
        var rows: [Int] = []
        for row in (start + 1)..<max(start + 1, end) {
            let isOutput = (0..<terminal.cols).contains { column in
                if case .output = terminal.semanticContent(at: Position(col: column, row: row)) ?? .none { return true }
                return false
            }
            if isOutput { rows.append(row) }
        }
        // Trailing blank rows aren't part of the output.
        while let last = rows.last, (terminal.bufferLine(atRow: last)?.translateToString(trimRight: true) ?? "").isEmpty { rows.removeLast() }
        guard let first = rows.first, let last = rows.last else { NSSound.beep(); return false }
        selection.setSelection(start: Position(col: 0, row: first), end: Position(col: terminal.cols - 1, row: last))
        if first < terminal.getTopVisibleRow() || first >= terminal.getTopVisibleRow() + terminal.rows { scrollTo(row: max(0, first - 1)) }
        setNeedsDisplay(bounds)
        return true
    }

    // MARK: Find

    /// Searches the scrollback: highlights every visible match and selects the current one.
    /// Returns the current match's place and the number of matches.
    @discardableResult func find(_ term: String, options: SearchOptions, backward: Bool) -> (index: Int, total: Int) {
        let overlay = matchOverlay ?? {
            let overlay = TerminalMatchOverlay(frame: bounds)
            overlay.autoresizingMask = [.width, .height]
            overlay.terminalView = self
            addSubview(overlay)
            matchOverlay = overlay
            return overlay
        }()
        overlay.term = term; overlay.options = options
        overlay.needsDisplay = true
        guard !term.isEmpty else { clearSearch(); return (0, 0) }
        if backward { findPrevious(term, options: options) } else { findNext(term, options: options) }
        return searchMatchSummary(term, options: options)
    }
    func endFind() {
        matchOverlay?.removeFromSuperview(); matchOverlay = nil
        clearSearch()
    }
}

/// Draws a soft highlight on every visible match of the find term, over the terminal's text.
final class TerminalMatchOverlay: NSView {
    weak var terminalView: TsukumoTerminalView?
    var term = ""
    var options = SearchOptions()
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let view = terminalView, !term.isEmpty else { return }
        let terminal = view.getTerminal()
        let size = view.cellSize
        let color = view.caretColor.withAlphaComponent(0.28)
        color.setFill()
        for row in 0..<terminal.rows {
            guard let text = terminal.getLine(row: row)?.translateToString(trimRight: true), !text.isEmpty else { continue }
            for range in TerminalFind.matches(of: term, in: text, options: options) {
                let rect = NSRect(x: CGFloat(range.lowerBound) * size.width, y: bounds.height - CGFloat(row + 1) * size.height,
                                  width: CGFloat(range.count) * size.width, height: size.height)
                NSBezierPath(roundedRect: rect.insetBy(dx: -0.5, dy: 0.5), xRadius: 2.5, yRadius: 2.5).fill()
            }
        }
    }
}

/// Finding matches in one line of terminal text, as column ranges.
enum TerminalFind {
    static func matches(of term: String, in line: String, options: SearchOptions) -> [Range<Int>] {
        guard !term.isEmpty else { return [] }
        var pattern = options.regex ? term : NSRegularExpression.escapedPattern(for: term)
        if options.wholeWord { pattern = "\\b" + pattern + "\\b" }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options.caseSensitive ? [] : [.caseInsensitive]) else { return [] }
        let characters = Array(line)
        let ns = line as NSString
        return regex.matches(in: line, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard match.range.length > 0, let range = Range(match.range, in: line) else { return nil }
            // Columns count characters (one cell each), not UTF-16 units.
            let start = line.distance(from: line.startIndex, to: range.lowerBound)
            let count = line.distance(from: range.lowerBound, to: range.upperBound)
            return start < characters.count ? start..<(start + count) : nil
        }
    }
}

// MARK: File paths

/// Finds a file path under the pointer in a line of terminal output: `Sources/App.swift:42:7`,
/// `./build.sh`, `~/notes.md`, `/etc/hosts`. A path needs a slash or an extension.
enum TerminalPathDetector {
    struct Match: Equatable {
        var path: String
        var line: Int?
        var column: Int?
    }
    private static let token = try! NSRegularExpression(pattern: #"(?:~|\.{1,2})?/?[A-Za-z0-9_@%+\-.~/]*[A-Za-z0-9_@%+\-~](?::\d+)?(?::\d+)?"#)

    static func match(in line: String, column: Int) -> Match? {
        let ns = line as NSString
        for result in token.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            guard let range = Range(result.range, in: line) else { continue }
            let start = line.distance(from: line.startIndex, to: range.lowerBound)
            let end = line.distance(from: line.startIndex, to: range.upperBound)
            guard column >= start && column < end else { continue }
            return parse(String(line[range]))
        }
        return nil
    }
    static func parse(_ token: String) -> Match? {
        var text = token
        var numbers: [Int] = []
        // Up to two trailing :N parts are a line and a column.
        for _ in 0..<2 {
            guard let colon = text.lastIndex(of: ":"), let number = Int(text[text.index(after: colon)...]) else { break }
            numbers.insert(number, at: 0); text = String(text[..<colon])
        }
        while let last = text.last, ".,;".contains(last) { text.removeLast() }
        guard !text.isEmpty, text.contains("/") || (text as NSString).pathExtension.count > 0, !text.hasPrefix("//") else { return nil }
        if text.contains("://") { return nil }
        return Match(path: text, line: numbers.first, column: numbers.count > 1 ? numbers[1] : nil)
    }
    /// The file the path names, relative to the shell's folder; nil unless it exists.
    static func resolve(_ path: String, relativeTo base: String) -> URL? {
        let expanded = (path as NSString).expandingTildeInPath
        let full = expanded.hasPrefix("/") ? expanded : (base as NSString).appendingPathComponent(expanded)
        let url = URL(fileURLWithPath: full).standardizedFileURL
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// Opens a file ⌘-clicked in a terminal: in Tsukumo's editor on the Terminal page when it's open,
/// otherwise in the app macOS uses for it. Folders open in Finder.
@MainActor enum TerminalFileOpener {
    /// Set by the Terminal page while it's shown.
    static var handler: ((URL, Int?) -> Void)?
    static func open(_ url: URL, line: Int?) {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if isDirectory.boolValue { NSWorkspace.shared.activateFileViewerSelecting([url]); return }
        if let handler { handler(url, line) } else { NSWorkspace.shared.open(url) }
    }
    /// The folder an editor should treat as the project: the nearest one above the file with a `.git`,
    /// or the file's own folder.
    static func projectRoot(for file: URL) -> URL {
        var folder = file.deletingLastPathComponent()
        while folder.path != "/" {
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) { return folder }
            folder.deleteLastPathComponent()
        }
        return file.deletingLastPathComponent()
    }
}

// MARK: Support

/// The last `capacity` bytes written, without shifting the whole buffer on every write.
struct TerminalByteRing {
    private var storage: [UInt8]
    private var start = 0
    private(set) var count = 0
    let capacity: Int
    init(capacity: Int) { self.capacity = capacity; storage = [UInt8](repeating: 0, count: capacity) }
    /// Copies in at most two runs (up to the end of the storage, then from its start), so a large
    /// chunk of output costs a couple of memory copies rather than a loop per byte.
    mutating func append(_ bytes: ArraySlice<UInt8>) {
        var source = bytes
        if source.count >= capacity { source = source.suffix(capacity); start = 0; count = 0 }
        guard !source.isEmpty else { return }
        let end = (start + count) % capacity
        let first = min(source.count, capacity - end)
        storage.replaceSubrange(end..<(end + first), with: source.prefix(first))
        let rest = source.count - first
        if rest > 0 { storage.replaceSubrange(0..<rest, with: source.suffix(rest)) }
        let overflow = max(0, count + source.count - capacity)
        count = min(capacity, count + source.count)
        start = (start + overflow) % capacity
    }
    mutating func append(_ bytes: [UInt8]) { append(bytes[...]) }
    var bytes: [UInt8] {
        if start + count <= capacity { return Array(storage[start..<(start + count)]) }
        return Array(storage[start...] + storage[..<((start + count) % capacity)])
    }
}

/// Fonts, colors, cursor, and opacity for a terminal view, from its profile, the app theme, and ⌘+/⌘-.
struct TerminalAppearance: Equatable {
    var colors: TerminalColors
    var fontFamily: String
    var fontSize: CGFloat
    var cursor: TerminalCursorShape
    var cursorBlinks: Bool
    var opacity: CGFloat

    var font: NSFont {
        (fontFamily == "System" || fontFamily.isEmpty ? nil : NSFontManager.shared.font(withFamily: fontFamily, traits: [], weight: 5, size: fontSize))
            ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }
    func apply(to view: TsukumoTerminalView) {
        guard view.terminalAppearance != self else { return }
        let previous = view.terminalAppearance
        view.terminalAppearance = self
        if previous?.colors != colors {
            view.installColors(colors.swiftTermANSI)
            view.nativeForegroundColor = colors.foreground
            view.caretColor = colors.cursor
            view.selectedTextBackgroundColor = colors.cursor.withAlphaComponent(0.35)
        }
        if previous?.colors.background != colors.background || previous?.opacity != opacity {
            view.nativeBackgroundColor = colors.background.withAlphaComponent(opacity)
        }
        if previous?.fontFamily != fontFamily || previous?.fontSize != fontSize { view.font = font }
        if previous?.cursor != cursor || previous?.cursorBlinks != cursorBlinks { view.getTerminal().setCursorStyle(cursor.style(blinking: cursorBlinks)) }
    }
}

/// Passes a pane's title changes and its process's exit to `TerminalSessions`. Owned by the pane's
/// view, so it outlives the SwiftUI host that happens to show it.
final class TerminalRelay: NSObject, LocalProcessTerminalViewDelegate {
    let id: UUID
    init(id: UUID) { self.id = id }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        let id = id
        Task { @MainActor in TerminalSessions.shared.titleChanged(id, title) }
    }
    // OSC 7 is read by Tsukumo's own scanner, which also sees the shell's other marks.
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        let id = id
        Task { @MainActor in TerminalSessions.shared.markExited(id, code: exitCode) }
    }
}

import AppKit
import Carbon.HIToolbox
import SwiftUI

// The quick terminal: a global shortcut (⌥Space by default) drops a terminal down from the top of
// the screen and puts it away again, like Ghostty's quick terminal and iTerm's hotkey window.
// The shortcut is a Carbon hot key, which needs no Accessibility permission.

// MARK: The shortcut

/// A key and its modifiers, in Carbon's terms (what `RegisterEventHotKey` takes), written the
/// way macOS menus show them ("⌥Space", "⌃⇧`").
struct TerminalHotkey: Equatable, CustomStringConvertible {
    var keyCode: UInt32
    /// Carbon modifier flags: `cmdKey`, `shiftKey`, `optionKey`, `controlKey`.
    var modifiers: UInt32

    static let defaultQuick = TerminalHotkey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))

    private static let names: [(String, Int)] = [
        ("Space", kVK_Space), ("Return", kVK_Return), ("Tab", kVK_Tab), ("Esc", kVK_Escape), ("Delete", kVK_Delete),
        ("`", kVK_ANSI_Grave), ("-", kVK_ANSI_Minus), ("=", kVK_ANSI_Equal), ("[", kVK_ANSI_LeftBracket), ("]", kVK_ANSI_RightBracket),
        ("\\", kVK_ANSI_Backslash), (";", kVK_ANSI_Semicolon), ("'", kVK_ANSI_Quote), (",", kVK_ANSI_Comma), (".", kVK_ANSI_Period), ("/", kVK_ANSI_Slash),
        ("←", kVK_LeftArrow), ("→", kVK_RightArrow), ("↑", kVK_UpArrow), ("↓", kVK_DownArrow),
        ("A", kVK_ANSI_A), ("B", kVK_ANSI_B), ("C", kVK_ANSI_C), ("D", kVK_ANSI_D), ("E", kVK_ANSI_E), ("F", kVK_ANSI_F), ("G", kVK_ANSI_G),
        ("H", kVK_ANSI_H), ("I", kVK_ANSI_I), ("J", kVK_ANSI_J), ("K", kVK_ANSI_K), ("L", kVK_ANSI_L), ("M", kVK_ANSI_M), ("N", kVK_ANSI_N),
        ("O", kVK_ANSI_O), ("P", kVK_ANSI_P), ("Q", kVK_ANSI_Q), ("R", kVK_ANSI_R), ("S", kVK_ANSI_S), ("T", kVK_ANSI_T), ("U", kVK_ANSI_U),
        ("V", kVK_ANSI_V), ("W", kVK_ANSI_W), ("X", kVK_ANSI_X), ("Y", kVK_ANSI_Y), ("Z", kVK_ANSI_Z),
        ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3), ("4", kVK_ANSI_4), ("5", kVK_ANSI_5), ("6", kVK_ANSI_6),
        ("7", kVK_ANSI_7), ("8", kVK_ANSI_8), ("9", kVK_ANSI_9),
        ("F1", kVK_F1), ("F2", kVK_F2), ("F3", kVK_F3), ("F4", kVK_F4), ("F5", kVK_F5), ("F6", kVK_F6), ("F7", kVK_F7), ("F8", kVK_F8),
        ("F9", kVK_F9), ("F10", kVK_F10), ("F11", kVK_F11), ("F12", kVK_F12), ("F13", kVK_F13), ("F14", kVK_F14), ("F15", kVK_F15)
    ]
    /// Other ways people write a key.
    private static let aliases: [String: String] = [
        "space": "Space", "spacebar": "Space", "return": "Return", "enter": "Return", "tab": "Tab", "esc": "Esc", "escape": "Esc",
        "delete": "Delete", "backspace": "Delete", "grave": "`", "backtick": "`", "tilde": "`", "minus": "-", "equal": "=", "equals": "=",
        "left": "←", "right": "→", "up": "↑", "down": "↓"
    ]
    private static let modifierSymbols: [(Character, Int)] = [("⌃", controlKey), ("⌥", optionKey), ("⇧", shiftKey), ("⌘", cmdKey)]
    private static let modifierWords: [String: Int] = [
        "ctrl": controlKey, "control": controlKey, "⌃": controlKey, "opt": optionKey, "option": optionKey, "alt": optionKey, "⌥": optionKey,
        "shift": shiftKey, "⇧": shiftKey, "cmd": cmdKey, "command": cmdKey, "⌘": cmdKey
    ]

    init(keyCode: UInt32, modifiers: UInt32) { self.keyCode = keyCode; self.modifiers = modifiers }

    /// Reads "⌥Space", "⌃⇧`", "option+space", "Ctrl+Alt+T", or "F12".
    init?(_ text: String) {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        var modifiers = 0
        while let first = rest.first, let symbol = Self.modifierSymbols.first(where: { $0.0 == first }), rest.count > 1 {
            modifiers |= symbol.1; rest = rest.dropFirst()
        }
        var keyName = String(rest)
        if rest.count > 1, rest.contains("+") {
            let parts = rest.split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            // "cmd++" ends with an empty part: the key is "+", which isn't supported here.
            guard let last = parts.last, !last.isEmpty else { return nil }
            for part in parts.dropLast() {
                guard let flag = Self.modifierWords[part.lowercased()] else { return nil }
                modifiers |= flag
            }
            keyName = last
        }
        let canonical = Self.aliases[keyName.lowercased()] ?? (keyName.count == 1 ? keyName.uppercased() : keyName.uppercased().hasPrefix("F") ? keyName.uppercased() : keyName)
        guard let code = Self.names.first(where: { $0.0 == canonical })?.1 else { return nil }
        self.init(keyCode: UInt32(code), modifiers: UInt32(modifiers))
    }
    /// From a key press recorded in Settings.
    init?(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        guard Self.names.contains(where: { $0.1 == Int(keyCode) }) else { return nil }
        var modifiers = 0
        if flags.contains(.control) { modifiers |= controlKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.shift) { modifiers |= shiftKey }
        if flags.contains(.command) { modifiers |= cmdKey }
        self.init(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers))
    }
    var keyName: String { Self.names.first { $0.1 == Int(keyCode) }?.0 ?? "Key \(keyCode)" }
    var description: String {
        Self.modifierSymbols.filter { modifiers & UInt32($0.1) != 0 }.map { String($0.0) }.joined() + keyName
    }
    /// The key caps to draw, one per key.
    var keyCaps: [String] { Self.modifierSymbols.filter { modifiers & UInt32($0.1) != 0 }.map { String($0.0) } + [keyName] }
    private var isFunctionKey: Bool { keyName.count > 1 && keyName.hasPrefix("F") }
    /// Why this can't be the shortcut, or nil when it can. A shortcut needs ⌘, ⌥, or ⌃ (Shift alone
    /// would take a character away from typing), except for function keys.
    var problem: String? {
        let strong = UInt32(cmdKey | optionKey | controlKey)
        if modifiers & strong == 0 && !isFunctionKey { return "Add ⌘, ⌥, or ⌃ so the shortcut doesn't take a key you type." }
        return nil
    }
}

/// Registers the quick terminal's shortcut with the system and says clearly when it can't.
@MainActor final class TerminalGlobalHotkey {
    static let shared = TerminalGlobalHotkey()
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onPress: (() -> Void)?
    /// What happened with the last registration, for Settings: nil when it worked.
    private(set) var problem: String?

    /// Registers `hotkey`, replacing any earlier one. Returns a message when it can't be used.
    @discardableResult func register(_ hotkey: TerminalHotkey) -> String? {
        unregister()
        if let problem = hotkey.problem { self.problem = problem; return problem }
        if let owner = Self.systemConflict(hotkey) {
            problem = "\(hotkey) is \(owner). Choose another shortcut, or turn that one off in System Settings → Keyboard → Keyboard Shortcuts."
            return problem
        }
        installHandler()
        let id = EventHotKeyID(signature: OSType(0x54534B4D), id: 1) // "TSKM"
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        switch status {
        case noErr: reference = ref; problem = nil
        case OSStatus(eventHotKeyExistsErr): problem = "Another app already uses \(hotkey). Choose another shortcut, or change it in that app."
        default: problem = "\(hotkey) couldn't be registered (error \(status)). Choose another shortcut."
        }
        return problem
    }
    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
    }
    private func installHandler() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Task { @MainActor in TerminalGlobalHotkey.shared.onPress?() }
            return noErr
        }, 1, &type, nil, &handler)
    }
    /// The macOS shortcut already using this key, if any (Spotlight, input sources, Mission Control…).
    static func systemConflict(_ hotkey: TerminalHotkey) -> String? {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr, let array = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return nil }
        for entry in array {
            guard (entry[kHISymbolicHotKeyEnabled as String] as? Bool) ?? true,
                  let code = entry[kHISymbolicHotKeyCode as String] as? Int, let modifiers = entry[kHISymbolicHotKeyModifiers as String] as? Int else { continue }
            let relevant = UInt32(modifiers) & UInt32(cmdKey | optionKey | controlKey | shiftKey)
            if UInt32(code) == hotkey.keyCode && relevant == hotkey.modifiers { return "used by macOS" }
        }
        return nil
    }
}

// MARK: The panel

/// A panel that takes the keyboard without bringing Tsukumo's main window forward.
final class QuickTerminalPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Shows and hides the quick terminal, a drop-down from the top of the screen with the pointer.
@MainActor final class QuickTerminal: NSObject, NSWindowDelegate {
    static let shared = QuickTerminal()
    private var panel: QuickTerminalPanel?
    private var preferences: DesktopPreferences?
    private var previousApp: NSRunningApplication?
    private var animating = false
    var isShown: Bool { panel?.isVisible == true }

    /// Called once at launch: the shortcut, Option-as-Meta per side, and secure keyboard entry.
    func install(preferences: DesktopPreferences) {
        self.preferences = preferences
        TerminalOptionKeys.start()
        SecureKeyboardEntry.start()
        TerminalGlobalHotkey.shared.onPress = { [weak self] in self?.toggle() }
        TerminalWorkspace.quick.onEmpty = { [weak self] in self?.hide() }
        reload()
    }
    /// Registers (or removes) the shortcut from the current settings. Returns a problem to show.
    @discardableResult func reload() -> String? {
        let settings = TerminalPreferences.shared
        guard settings.quickTerminal else { TerminalGlobalHotkey.shared.unregister(); return nil }
        guard let hotkey = TerminalHotkey(settings.quickHotkey) else { return "Tsukumo can't read the shortcut “\(settings.quickHotkey)”." }
        return TerminalGlobalHotkey.shared.register(hotkey)
    }
    func toggle() { isShown ? hide() : show() }

    func show() {
        guard !animating, let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main else { return }
        let panel = self.panel ?? makePanel()
        let frame = shownFrame(on: screen)
        if !NSRunningApplication.current.isActive { previousApp = NSWorkspace.shared.frontmostApplication }
        TerminalWorkspace.quick.ensureTab()
        panel.setFrame(frame.offsetBy(dx: 0, dy: frame.height), display: false)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.makeKey()
        animate(panel, to: frame) {}
        if let pane = TerminalWorkspace.quick.layout.selectedTab?.focused { TerminalSessions.shared.focus(pane) }
    }
    func hide() {
        guard let panel, panel.isVisible, !animating else { return }
        animate(panel, to: panel.frame.offsetBy(dx: 0, dy: panel.frame.height)) { [weak self] in
            panel.orderOut(nil)
            // Back to the app you were in, as Ghostty does.
            if let previous = self?.previousApp, !previous.isTerminated, previous != NSRunningApplication.current { previous.activate() }
            self?.previousApp = nil
        }
    }
    private func shownFrame(on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let height = (visible.height * TerminalPreferences.shared.quickHeight).rounded()
        return NSRect(x: visible.minX, y: visible.maxY - height, width: visible.width, height: height)
    }
    private func animate(_ panel: NSPanel, to frame: NSRect, completion: @escaping () -> Void) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrame(frame, display: true); completion(); return
        }
        animating = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor in self?.animating = false; completion() }
        }
    }
    private func makePanel() -> QuickTerminalPanel {
        let panel = QuickTerminalPanel(contentRect: .init(x: 0, y: 0, width: 900, height: 360), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Quick terminal"
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.delegate = self
        if let preferences { panel.contentView = NSHostingView(rootView: QuickTerminalView().environment(preferences)) }
        panel.setAccessibilityIdentifier("quickTerminal")
        self.panel = panel
        return panel
    }
    func windowDidResignKey(_ notification: Notification) {
        // Clicking elsewhere puts it away, unless a sheet (a paste or close confirmation) is open.
        guard TerminalPreferences.shared.quickHidesOnFocusLoss, panel?.attachedSheet == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, let panel = self.panel, !panel.isKeyWindow, panel.attachedSheet == nil, NSApp.modalWindow == nil else { return }
            self.previousApp = nil
            self.hide()
        }
    }
}

/// The quick terminal's content: the same tabs and splits, with rounded lower corners.
struct QuickTerminalView: View {
    @Environment(DesktopPreferences.self) private var preferences
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let palette = preferences.palette(scheme)
        TerminalSurfaceView(workspace: TerminalWorkspace.quick, openSettings: nil)
            .background(palette.background.opacity(TerminalPreferences.shared.opacity < 1 ? 0 : 1))
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12, style: .continuous))
            .overlay(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
            .preferredColorScheme(preferences.colorMode.scheme)
            .foregroundStyle(palette.foreground).tint(palette.accent)
            .font(preferences.font()).controlSize(.small)
    }
}

import AppKit
import SwiftUI
import Observation

enum CompanionPlacement {
    /// Reconnect displays, changed resolution, and a saved off-screen origin all
    /// converge on a visible rectangle without changing the user's chosen size.
    static func clamped(_ frame: CGRect, screens: [CGRect]) -> CGRect {
        guard !screens.isEmpty else { return frame }
        let screen = screens.max { left, right in
            intersectionArea(frame, left) < intersectionArea(frame, right)
        }!
        let width = min(frame.width, screen.width), height = min(frame.height, screen.height)
        return CGRect(x: min(max(frame.minX, screen.minX), screen.maxX - width),
                      y: min(max(frame.minY, screen.minY), screen.maxY - height), width: width, height: height)
    }
    private static func intersectionArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let rect = a.intersection(b); return rect.isNull ? 0 : rect.width * rect.height
    }
}

@MainActor @Observable final class DesktopPreferences {
    var isVisible = false
    private let defaults: UserDefaults
    var size: Double { didSet { defaults.set(size, forKey: "companion.size") } }
    var characterOnly: Bool { didSet { defaults.set(characterOnly, forKey: "companion.characterOnly") } }
    var showName: Bool { didSet { defaults.set(showName, forKey: "companion.name") } }
    var animate: Bool { didSet { defaults.set(animate, forKey: "companion.animate") } }
    var opacity: Double { didSet { defaults.set(opacity, forKey: "companion.opacity") } }
    /// The companion's name, shared with every surface through CompanionIdentity.
    var name: String { didSet { if !name.trimmingCharacters(in: .whitespaces).isEmpty { CompanionIdentity.set(name) } } }
    var showOnAllSpaces: Bool { didSet { defaults.set(showOnAllSpaces, forKey: "companion.spaces") } }
    var colorMode: DesktopColorMode { didSet { defaults.set(colorMode.rawValue, forKey: "desktop.colorMode") } }
    var lightTheme: DesktopThemeName { didSet { defaults.set(lightTheme.rawValue, forKey: "desktop.lightTheme") } }
    var darkTheme: DesktopThemeName { didSet { defaults.set(darkTheme.rawValue, forKey: "desktop.darkTheme") } }
    var interfaceTheme: DesktopThemeName {
        get { theme(for: activeScheme) }
        set { setTheme(newValue, for: activeScheme) }
    }
    private var activeScheme: ColorScheme { colorMode == .light ? .light : colorMode == .dark ? .dark : NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light }
    func theme(for scheme: ColorScheme) -> DesktopThemeName { scheme == .dark ? darkTheme : lightTheme }
    func setTheme(_ theme: DesktopThemeName, for scheme: ColorScheme) { if scheme == .dark { darkTheme = theme } else { lightTheme = theme } }

    var translucentSidebar: Bool { didSet { defaults.set(translucentSidebar, forKey: "desktop.translucentSidebar") } }
    var showMenuBar: Bool { didSet { defaults.set(showMenuBar, forKey: "desktop.menuBar") } }
    var followReduceMotion: Bool { didSet { defaults.set(followReduceMotion, forKey: "desktop.followReduceMotion") } }
    var reduceMotion: Bool { didSet { defaults.set(reduceMotion, forKey: "desktop.reduceMotion") } }
    var interfaceAccent: String { didSet { defaults.set(interfaceAccent, forKey: "desktop.accent") } }
    var interfaceBackground: String { didSet { defaults.set(interfaceBackground, forKey: "desktop.background") } }
    var interfaceForeground: String { didSet { defaults.set(interfaceForeground, forKey: "desktop.foreground") } }
    var uiFontFamily: String { didSet { defaults.set(uiFontFamily, forKey: "desktop.uiFont") } }
    var codeFontFamily: String { didSet { defaults.set(codeFontFamily, forKey: "desktop.codeFont") } }
    var contentFontFamily: String { didSet { defaults.set(contentFontFamily, forKey: "desktop.contentFont") } }
    var uiFontSize: Double { didSet { defaults.set(uiFontSize, forKey: "desktop.fontSize") } }
    var codeFontSize: Double { didSet { defaults.set(codeFontSize, forKey: "desktop.codeSize") } }
    var contentFontSize: Double { didSet { defaults.set(contentFontSize, forKey: "desktop.contentSize") } }
    var fontWeight: String { didSet { defaults.set(fontWeight, forKey: "desktop.fontWeight") } }
    var contentFontWeight: String { didSet { defaults.set(contentFontWeight, forKey: "desktop.contentFontWeight") } }
    var codeFontWeight: String { didSet { defaults.set(codeFontWeight, forKey: "desktop.codeFontWeight") } }
    static let weights = ["Light", "Regular", "Medium", "Semibold", "Bold"]
    static func weight(_ name: String) -> Font.Weight {
        switch name { case "Light": .light; case "Medium": .medium; case "Semibold": .semibold; case "Bold": .bold; default: .regular }
    }
    var pointerCursors: Bool { didSet { defaults.set(pointerCursors, forKey: "desktop.pointerCursors") } }
    var contrast: Double { didSet { defaults.set(contrast, forKey: "desktop.contrast") } }
    var diffMarkers: String { didSet { defaults.set(diffMarkers, forKey: "desktop.diffMarkers") } }
    var codeFont: Font {
        (codeFontFamily == "System" ? Font.system(size: codeFontSize, design: .monospaced) : Font.custom(codeFontFamily, size: codeFontSize)).weight(Self.weight(codeFontWeight))
    }
    func font(_ size: Double? = nil, content: Bool = false) -> Font {
        let ownContentFont = content && contentFontFamily != "Same as UI"
        let family = ownContentFont ? contentFontFamily : uiFontFamily
        let pointSize = size ?? (content ? contentFontSize : uiFontSize)
        let weight = Self.weight(ownContentFont ? contentFontWeight : fontWeight)
        return (family == "System" ? Font.system(size: pointSize) : Font.custom(family, size: pointSize)).weight(weight)
    }
    func palette(_ scheme: ColorScheme) -> DesktopPalette {
        DesktopPalette.make(theme(for: scheme), dark: scheme == .dark, contrast: contrast,
            accent: colorHex(interfaceAccent, scheme: scheme), background: colorHex(interfaceBackground, scheme: scheme), foreground: colorHex(interfaceForeground, scheme: scheme))
    }
    func colorHex(_ value: String, scheme: ColorScheme) -> String? {
        let parts = value.components(separatedBy: "|")
        let part = parts.count == 2 ? parts[scheme == .dark ? 1 : 0] : ""
        return part.count == 6 && part.allSatisfy { $0.isHexDigit } ? part : nil
    }
    func customColor(_ value: String, scheme: ColorScheme) -> Color? { colorHex(value, scheme: scheme).map { Color(hex: $0) } }
    func settingColor(_ hex: String, existing: String, scheme: ColorScheme) -> String {
        var parts = existing.components(separatedBy: "|"); if parts.count != 2 { parts = ["", ""] }
        parts[scheme == .dark ? 1 : 0] = hex.replacingOccurrences(of: "#", with: ""); return parts.joined(separator: "|")
    }
    func resetColors(for scheme: ColorScheme) {
        interfaceAccent = settingColor("", existing: interfaceAccent, scheme: scheme)
        interfaceBackground = settingColor("", existing: interfaceBackground, scheme: scheme)
        interfaceForeground = settingColor("", existing: interfaceForeground, scheme: scheme)
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        colorMode = DesktopColorMode(rawValue: defaults.string(forKey: "desktop.colorMode") ?? "") ?? .dark
        // New installs start dark, in the theme that matches the logo.
        let legacyTheme = DesktopThemeName(rawValue: defaults.string(forKey: "desktop.theme") ?? "") ?? .kemoSabe
        lightTheme = DesktopThemeName(rawValue: defaults.string(forKey: "desktop.lightTheme") ?? "") ?? legacyTheme
        darkTheme = DesktopThemeName(rawValue: defaults.string(forKey: "desktop.darkTheme") ?? "") ?? legacyTheme
        translucentSidebar = defaults.object(forKey: "desktop.translucentSidebar") as? Bool ?? true
        showMenuBar = defaults.object(forKey: "desktop.menuBar") as? Bool ?? true
        followReduceMotion = defaults.object(forKey: "desktop.followReduceMotion") as? Bool ?? true
        reduceMotion = defaults.bool(forKey: "desktop.reduceMotion")
        interfaceAccent = defaults.string(forKey: "desktop.accent") ?? "|"
        interfaceBackground = defaults.string(forKey: "desktop.background") ?? "|"
        interfaceForeground = defaults.string(forKey: "desktop.foreground") ?? "|"
        uiFontFamily = defaults.string(forKey: "desktop.uiFont") ?? "System"
        codeFontFamily = defaults.string(forKey: "desktop.codeFont") ?? "System"
        codeFontSize = min(24, max(10, defaults.object(forKey: "desktop.codeSize") as? Double ?? 13))
        contentFontFamily = defaults.string(forKey: "desktop.contentFont") ?? "Same as UI"
        uiFontSize = min(20, max(11, defaults.object(forKey: "desktop.fontSize") as? Double ?? 13))
        contentFontSize = min(24, max(12, defaults.object(forKey: "desktop.contentSize") as? Double ?? 15))
        fontWeight = defaults.string(forKey: "desktop.fontWeight") ?? "Regular"
        contentFontWeight = defaults.string(forKey: "desktop.contentFontWeight") ?? "Regular"
        codeFontWeight = defaults.string(forKey: "desktop.codeFontWeight") ?? "Regular"
        pointerCursors = defaults.object(forKey: "desktop.pointerCursors") as? Bool ?? false
        contrast = min(100, max(0, defaults.object(forKey: "desktop.contrast") as? Double ?? 50))
        diffMarkers = defaults.string(forKey: "desktop.diffMarkers") ?? "Color"
        size = min(112, max(56, defaults.object(forKey: "companion.size") as? Double ?? 68))
        characterOnly = defaults.object(forKey: "companion.characterOnly") as? Bool ?? true
        showName = defaults.object(forKey: "companion.name") as? Bool ?? true
        animate = defaults.object(forKey: "companion.animate") as? Bool ?? true
        opacity = min(1, max(0.5, defaults.object(forKey: "companion.opacity") as? Double ?? 1))
        // Earlier builds kept the Mac badge's label under its own key.
        // Earlier builds kept the Mac badge's label under its own key; the name now belongs to the account.
        if AccountDirectory.accountSettings.string(forKey: CompanionIdentity.key) == nil, let label = defaults.string(forKey: "companion.label") { CompanionIdentity.set(label) }
        name = CompanionIdentity.name
        showOnAllSpaces = defaults.object(forKey: "companion.spaces") as? Bool ?? true
    }
    var panelSize: NSSize { .init(width: showName && !characterOnly ? size + 154 : size + 8, height: size + 8) }
}

final class CompanionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// AppKit owns movement so dragging never also activates the chat button.
final class CompanionDragView: NSView {
    var clicked: (() -> Void)?
    var moved: (() -> Void)?
    var menuBuilder: (() -> NSMenu)?
    private var start: NSPoint?
    private var origin: NSPoint?
    private var dragged = false
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        start = NSEvent.mouseLocation; origin = window?.frame.origin; dragged = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start, let origin, let window else { return }
        let now = NSEvent.mouseLocation
        if hypot(now.x - start.x, now.y - start.y) > 4 { dragged = true }
        if dragged { window.setFrameOrigin(.init(x: origin.x + now.x - start.x, y: origin.y + now.y - start.y)) }
    }
    override func mouseUp(with event: NSEvent) {
        guard start != nil else { return }
        if dragged { moved?() } else { clicked?() }
        start = nil; origin = nil
    }
    override func rightMouseDown(with event: NSEvent) {
        if let menu = menuBuilder?() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
    override func accessibilityPerformPress() -> Bool { clicked?(); return true }
}

struct FloatingCompanionView: View {
    @Environment(AppStore.self) private var store
    @Environment(DesktopPreferences.self) private var preferences
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 9) {
            ArtworkCompanion(theme: store.state.theme, performance: TaskActivity.live(navigation.performance.rawValue, store: store),
                reducedMotion: (preferences.followReduceMotion ? reduceMotion : preferences.reduceMotion) || !preferences.animate, active: preferences.animate && preferences.isVisible,
                replay: navigation.performanceRevision, framesPerSecond: 24)
                .frame(width: preferences.size, height: preferences.size)
            if preferences.showName && !preferences.characterOnly {
                VStack(alignment: .leading, spacing: 3) {
                    Text(preferences.name.isEmpty ? "KemoSabe" : preferences.name).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                    Text(store.isThinking ? "Thinking…" : "Here when you need me").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }.frame(width: 127, alignment: .leading).padding(.trailing, 9)
            }
        }.padding(4)
            .background {
                if !preferences.characterOnly { Capsule().fill(.ultraThinMaterial).overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1)) }
            }
            .opacity(preferences.opacity).preferredColorScheme(preferences.colorMode.scheme)
    }
}

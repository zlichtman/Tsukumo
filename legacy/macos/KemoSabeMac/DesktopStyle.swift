import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum DesktopColorMode: String, CaseIterable { case system = "System", light = "Light", dark = "Dark"
    var scheme: ColorScheme? { self == .system ? nil : self == .dark ? .dark : .light }
}
enum DesktopThemeName: String, CaseIterable {
    case graphite = "Graphite", lavender = "Lavender", forest = "Forest", sand = "Sand"
    /// The default: the logo's plum, cream, and coral.
    case kemoSabe = "KemoSabe"
    /// Tsukumo's logo: violet on near-black and cream.
    case tsukumo = "Tsukumo", harbor = "Harbor"
    // Raw values are saved IDs and stay as they were; brand-named ones show a new name (`ThemeNames`).
    case absolutely = "Absolutely", ayu = "Ayu", catppuccin = "Catppuccin", codex = "Codex", dracula = "Dracula", github = "GitHub", gruvbox = "Gruvbox", linear = "Linear", lobster = "Lobster", material = "Material", matrix = "Matrix", monokai = "Monokai", nightOwl = "Night Owl", nord = "Nord", notion = "Notion", oscurange = "Oscurange", one = "One", proof = "Proof", raycast = "Raycast", rosePine = "Rose Pine", sentry = "Sentry", solarized = "Solarized", temple = "Temple", tokyoNight = "Tokyo Night", vercel = "Vercel", vscode = "VS Code Plus", xcode = "Xcode"
    var label: String { self == .forest ? "Everforest" : ThemeNames.current(rawValue) }
    func supports(_ scheme: ColorScheme) -> Bool {
        if let modes = DesktopThemeCatalog.presets[label] { return modes[scheme == .dark ? "dark" : "light"] != nil }
        return true
    }
    static func available(_ scheme: ColorScheme) -> [Self] { allCases.filter { $0.supports(scheme) }.sorted { $0.label < $1.label } }
}
enum DesktopThemeCatalog {
    static let presets: [String: [String: [String: String]]] = {
        guard let url = Bundle.main.url(forResource: "ThemePresets", withExtension: "json"), let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode([String: [String: [String: String]]].self, from: data) else { return [:] }
        return value
    }()
}
struct DesktopPalette {
    let background: Color
    let sidebar: Color
    let accent: Color
    let foreground: Color
    static func make(_ name: DesktopThemeName, dark: Bool, contrast: Double = 50, accent: String? = nil, background: String? = nil, foreground: String? = nil) -> Self {
        let colors: (String, String, String, String)
        if let value = DesktopThemeCatalog.presets[name.label]?[dark ? "dark" : "light"], let bg = value["background"], let side = value["sidebar"], let accent = value["accent"], let fg = value["foreground"] {
            colors = (bg, side, accent, fg)
        } else { switch (name, dark) {
        case (.graphite, true): colors = ("19191B", "131315", "F2C9AC", "F2F0EB")
        case (.lavender, true): colors = ("201F30", "292737", "B79AEF", "E9E3F5")
        case (.forest, true): colors = ("2D353B", "343F40", "A7C080", "D3C6AA")
        case (.sand, true): colors = ("2B2522", "342C26", "D9AE81", "F0E1CE")
        case (.graphite, false): colors = ("FAFAF8", "F0F0ED", "8B4B2B", "26241F")
        case (.lavender, false): colors = ("F8F5FE", "EDE7F7", "7555B0", "30263D")
        case (.forest, false): colors = ("F6F6ED", "E9ECDF", "4D704C", "303D33")
        case (.sand, false): colors = ("FBF4E7", "EDE3D3", "8F5835", "3A2C22")
        default: colors = dark ? ("19191B", "131315", "F2C9AC", "F2F0EB") : ("FAFAF8", "F0F0ED", "8B4B2B", "26241F")
        } }
        let amount = (min(100, max(0, contrast)) - 50) / 250
        func adjusted(_ color: Color, foreground: Bool) -> Color {
            let target: NSColor = (dark == foreground) == (amount >= 0) ? .white : .black
            return Color(nsColor: NSColor(color).blended(withFraction: abs(amount), of: target) ?? NSColor(color))
        }
        return .init(background: adjusted(Color(hex: background ?? colors.0), foreground: false), sidebar: adjusted(Color(hex: colors.1), foreground: false), accent: Color(hex: accent ?? colors.2), foreground: adjusted(Color(hex: foreground ?? colors.3), foreground: true))
    }
}

@MainActor enum DesktopIconArtwork {
    /// Tsukumo's bundled icon (scripts/make_tsukumo_icon.swift renders it from the
    /// unchanged logo). The same file backs Finder, the closed Dock tile, and the running app.
    static func bundledIcon() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "Tsukumo", withExtension: "icns") else { return nil }
        return NSImage(contentsOf: url)
    }
    static func apply() {
        if let image = bundledIcon() { NSApp.applicationIconImage = image }
    }
}

struct DesktopThemeDocument: Codable, Equatable {
    let version: Int
    let mode: String
    let preset: String
    let accent: String
    let background: String
    let foreground: String
    let contrast: Double
    func validate() throws {
        guard version == 1, ["Light", "Dark"].contains(mode), DesktopThemeName(rawValue: preset) != nil,
              contrast.isFinite, (0...100).contains(contrast),
              [accent, background, foreground].allSatisfy({ $0.count == 6 && $0.allSatisfy(\.isHexDigit) }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
}
extension DesktopPreferences {
    func themeDocument(scheme: ColorScheme) -> DesktopThemeDocument {
        let base = DesktopPalette.make(theme(for: scheme), dark: scheme == .dark)
        return .init(version: 1, mode: scheme == .dark ? "Dark" : "Light", preset: theme(for: scheme).rawValue,
                     accent: colorHex(interfaceAccent, scheme: scheme) ?? base.accent.hexValue,
                     background: colorHex(interfaceBackground, scheme: scheme) ?? base.background.hexValue,
                     foreground: colorHex(interfaceForeground, scheme: scheme) ?? base.foreground.hexValue,
                     contrast: contrast)
    }
    func importTheme(_ data: Data) throws {
        guard data.count <= 16_384 else { throw CocoaError(.fileReadTooLarge) }
        let theme = try JSONDecoder().decode(DesktopThemeDocument.self, from: data)
        try theme.validate() // Validate the whole document before mutating any preferences.
        let scheme: ColorScheme = theme.mode == "Dark" ? .dark : .light
        colorMode = theme.mode == "Dark" ? .dark : .light
        interfaceTheme = DesktopThemeName(rawValue: theme.preset)!
        interfaceAccent = settingColor(theme.accent, existing: interfaceAccent, scheme: scheme)
        interfaceBackground = settingColor(theme.background, existing: interfaceBackground, scheme: scheme)
        interfaceForeground = settingColor(theme.foreground, existing: interfaceForeground, scheme: scheme)
        contrast = theme.contrast
    }
}

struct SettingsContent<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 22) { content }.frame(maxWidth: 760).padding(.horizontal, 28).padding(.vertical, 16).frame(maxWidth: .infinity) }
    }
}
struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !title.isEmpty { Text(title).font(.system(size: 13, weight: .medium)) }
            VStack(spacing: 0) { content }.padding(.horizontal, 18)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.primary.opacity(0.06), lineWidth: 1))
        }
    }
}
struct SettingsRow<Control: View>: View {
    @Environment(DesktopPreferences.self) private var preferences
    let title: String
    var detail: String? = nil
    @ViewBuilder var control: Control
    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 16)
            control.fixedSize(horizontal: true, vertical: false).onHover { inside in if preferences.pointerCursors { (inside ? NSCursor.pointingHand : NSCursor.arrow).set() } }
        }.padding(.vertical, 12).frame(minHeight: 42)
    }
}
struct InterfaceAppearanceSection: View {
    @Environment(DesktopPreferences.self) private var preferences
    @Environment(\.colorScheme) private var scheme
    @State private var importing = false
    @State private var status = ""
    var changed: () -> Void
    private var palette: DesktopPalette { preferences.palette(scheme) }
    /// JetBrains Mono ships with the app, so it's offered first even where it isn't installed.
    private var fonts: [String] { ["System", BundledFonts.jetBrainsMono] + NSFontManager.shared.availableFontFamilies.filter { $0 != BundledFonts.jetBrainsMono }.sorted() }
    var body: some View {
        @Bindable var preferences = preferences
        VStack(alignment: .leading, spacing: 22) {
            // As in Codex: mode cards, then a before-and-after of the theme in code.
            VStack(alignment: .leading, spacing: 14) {
                Text("Theme").font(.system(size: 13, weight: .medium))
                HStack(spacing: 12) {
                    ForEach(DesktopColorMode.allCases, id: \.self) { mode in
                        Button { preferences.colorMode = mode } label: {
                            VStack(spacing: 8) {
                                ThemeModeCard(mode: mode, selected: preferences.colorMode == mode, accent: palette.accent)
                                Text(mode.rawValue).font(.system(size: 12)).foregroundStyle(preferences.colorMode == mode ? .primary : .secondary)
                            }
                        }.buttonStyle(.plain).accessibilityIdentifier("appearance-" + mode.rawValue).accessibilityAddTraits(preferences.colorMode == mode ? .isSelected : [])
                    }
                }
                ThemeCodePreview(before: DesktopPalette.make(preferences.theme(for: scheme), dark: scheme == .dark), after: palette,
                                 contrast: Int(preferences.contrast), markers: preferences.diffMarkers, font: preferences.codeFont)
            }
            SettingsCard(title: "") {
                SettingsRow(title: scheme == .dark ? "Dark theme" : "Light theme") {
                    HStack(spacing: 16) {
                        Button("Import") { importing = true }.buttonStyle(.plain).foregroundStyle(.secondary).help("Import a theme JSON file")
                        Button("Copy theme") { copyTheme() }.buttonStyle(.plain).foregroundStyle(.secondary).help("Copy this theme as JSON")
                        DesktopThemeChooser(scheme: scheme) { changed() }
                    }
                }
                Divider()
                colorRow("Accent", value: $preferences.interfaceAccent, fallback: palette.accent)
                Divider()
                colorRow("Background", value: $preferences.interfaceBackground, fallback: palette.background)
                Divider()
                colorRow("Foreground", value: $preferences.interfaceForeground, fallback: palette.foreground)
                Divider()
                SettingsRow(title: "UI font") {
                    HStack(spacing: 8) {
                        QuietMenuPicker(title: "UI font", options: fonts, selection: $preferences.uiFontFamily, width: 160)
                        QuietMenuPicker(title: "UI font weight", options: DesktopPreferences.weights, selection: $preferences.fontWeight, width: 120)
                    }
                }
                Divider()
                SettingsRow(title: "Content font") {
                    HStack(spacing: 8) {
                        QuietMenuPicker(title: "Content font", options: ["Same as UI"] + fonts, selection: $preferences.contentFontFamily, width: 160)
                        QuietMenuPicker(title: "Content font weight", options: DesktopPreferences.weights, selection: $preferences.contentFontWeight, width: 120)
                            .disabled(preferences.contentFontFamily == "Same as UI").help("Uses the UI font's weight while it's the same font")
                    }
                }
                Divider()
                SettingsRow(title: "Code font") {
                    HStack(spacing: 8) {
                        QuietMenuPicker(title: "Code font", options: fonts, selection: $preferences.codeFontFamily, width: 160)
                        QuietMenuPicker(title: "Code font weight", options: DesktopPreferences.weights, selection: $preferences.codeFontWeight, width: 120)
                    }
                }
                Divider()
                SettingsRow(title: "Translucent sidebar") { Toggle("Translucent sidebar", isOn: $preferences.translucentSidebar).labelsHidden().toggleStyle(.switch) }
                Divider()
                // No `step`: on macOS a stepped slider draws a tick for every value, the line under the bar.
                SettingsRow(title: "Contrast") { HStack(spacing: 14) { Slider(value: Binding(get: { preferences.contrast }, set: { preferences.contrast = $0.rounded() }), in: 0...100).frame(width: 150); Text("\(Int(preferences.contrast))").monospacedDigit().frame(width: 26, alignment: .trailing) } }
                Divider()
                SettingsRow(title: "Custom colors", detail: "App colors are separate from the companion palette.") { Button("Reset colors") { preferences.resetColors(for: scheme); preferences.contrast = 50 } }
            }
            SettingsCard(title: "Preferences") {
                SettingsRow(title: "Use pointer cursors", detail: "Change the cursor to a pointer over buttons and rows.") { Toggle("Use pointer cursors", isOn: $preferences.pointerCursors).labelsHidden().toggleStyle(.switch) }
                Divider()
                SettingsRow(title: "Reduce motion", detail: "Reduce animations or match your system.") {
                    QuietSegmented(options: ["System", "On", "Off"], selection: Binding(get: { preferences.followReduceMotion ? "System" : preferences.reduceMotion ? "On" : "Off" }, set: { preferences.followReduceMotion = $0 == "System"; preferences.reduceMotion = $0 == "On" }))
                }
                Divider()
                SettingsRow(title: "UI font size", detail: "The base size for the app's interface.") { PixelField(value: $preferences.uiFontSize, range: 11...20) }
                Divider()
                SettingsRow(title: "Content font size", detail: "The size of messages and documents.") { PixelField(value: $preferences.contentFontSize, range: 12...24) }
                Divider()
                SettingsRow(title: "Code font size", detail: "The size of code in chats, previews, and the terminal.") { PixelField(value: $preferences.codeFontSize, range: 10...24) }
                Divider()
                SettingsRow(title: "Diff markers", detail: "Show changes with colors or +/− markers.") {
                    QuietSegmented(options: ["Color", "+/−"], selection: $preferences.diffMarkers)
                }
                Divider()
                SettingsRow(title: "Font smoothing", detail: "Text rendering is managed by macOS.") { Text("System").foregroundStyle(.secondary) }
            }
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("themeImportStatus") }
        }.onChange(of: scheme) {
            if !preferences.theme(for: scheme).supports(scheme) { preferences.setTheme(.codex, for: scheme) }
        }.fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get(); let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                try preferences.importTheme(handle.read(upToCount: 16_385) ?? Data())
                status = "Theme imported. Companion colors are unchanged."
            } catch { status = "Could not import this theme. Choose a KemoSabe theme JSON file with valid colors." }
        }
    }
    /// A pill filled with the color and its hex value, as in Codex; clicking opens the color panel.
    private func colorRow(_ title: String, value: Binding<String>, fallback: Color) -> some View {
        let color = preferences.customColor(value.wrappedValue, scheme: scheme) ?? fallback
        return SettingsRow(title: title) {
            ColorPill(title: title, color: color) { value.wrappedValue = preferences.settingColor($0.hexValue, existing: value.wrappedValue, scheme: scheme) }
        }
    }
    private func copyTheme() {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(preferences.themeDocument(scheme: scheme)), let text = String(data: data, encoding: .utf8) {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); status = "Theme JSON copied."
        }
    }
}

/// The System, Light, and Dark cards: a small window with a header and a stack of cards.
struct ThemeModeCard: View {
    let mode: DesktopColorMode
    let selected: Bool
    let accent: Color
    var body: some View {
        ZStack {
            if mode == .system {
                HStack(spacing: 0) { mock(dark: false); mock(dark: true) }
            } else { mock(dark: mode == .dark) }
        }
        .frame(height: 128).frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? accent.opacity(0.9) : Color.primary.opacity(0.1), lineWidth: selected ? 2 : 1))
    }
    private func mock(dark: Bool) -> some View {
        let back = dark ? Color(hex: "5A5A5E") : Color(hex: "F2F2F3")
        let card = dark ? Color(hex: "3A3A3E") : .white
        let line = dark ? Color.white.opacity(0.22) : Color.black.opacity(0.1)
        return ZStack(alignment: .top) {
            back
            VStack(spacing: 6) {
                Capsule().fill(line).frame(width: 70, height: 6)
                Capsule().fill(line.opacity(0.6)).frame(width: 110, height: 3)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(0..<3, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 4) {
                            Capsule().fill(line).frame(width: 44, height: 5)
                            Capsule().fill(line.opacity(0.5)).frame(width: 64, height: 2)
                        }
                    }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(card, in: UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10))
                    .padding(.horizontal, 16).padding(.top, 8)
            }.padding(.top, 20)
        }
    }
}

/// The theme's colors shown as a before-and-after in code, like Codex's preview: the stock
/// theme on the left, your current colors on the right, in your code font and diff markers.
struct ThemeCodePreview: View {
    let before: DesktopPalette
    let after: DesktopPalette
    let contrast: Int
    let markers: String
    let font: Font
    var body: some View {
        HStack(spacing: 0) {
            side(removed: true, surface: "sidebar", accent: before.accent.hexValue, contrast: 50)
            side(removed: false, surface: "sidebar-elevated", accent: after.accent.hexValue, contrast: contrast)
        }
        .background(after.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .accessibilityElement(children: .ignore).accessibilityLabel("Theme preview in code")
    }
    private func side(removed: Bool, surface: String, accent: String, contrast: Int) -> some View {
        let tint: Color = removed ? .red : .green
        let lines: [(Int, String, Bool)] = [(1, "const themePreview: ThemeConfig = {", false), (2, "  surface: \"\(surface)\",", true),
                                             (3, "  accent: \"#\(accent.lowercased())\",", true), (4, "  contrast: \(contrast),", true), (5, "};", false)]
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(lines, id: \.0) { number, text, changed in
                HStack(spacing: 0) {
                    Rectangle().fill(changed && markers == "Color" ? tint.opacity(0.8) : .clear).frame(width: 3)
                    Text("\(number)").foregroundStyle(changed && markers == "Color" ? tint : .secondary).frame(width: 30, alignment: .trailing).padding(.trailing, 12)
                    Text((changed && markers != "Color" ? (removed ? "- " : "+ ") : "") + text).foregroundStyle(.primary).lineLimit(1)
                    Spacer(minLength: 0)
                }.font(font).padding(.vertical, 4)
                    .background(changed && markers == "Color" ? tint.opacity(0.12) : .clear)
            }
        }.padding(.vertical, 6).frame(maxWidth: .infinity)
    }
}

/// A dropdown drawn like Codex's: plain text, a small chevron, a hairline rounded border.
struct QuietMenuPicker: View {
    let title: String
    let options: [String]
    @Binding var selection: String
    var width: CGFloat = 160
    var body: some View {
        // Plain menu items: a Picker nested in a Menu didn't write the choice back on macOS.
        Menu {
            ForEach(options, id: \.self) { option in
                Button { selection = option } label: {
                    if option == selection { Label(option, systemImage: "checkmark") } else { Text(option) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(selection).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }.padding(.horizontal, 12).frame(width: width, height: 30)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
                .contentShape(Rectangle())
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().accessibilityLabel(title).accessibilityValue(selection)
    }
}

/// Codex's segmented choice: plain labels, the current one in a soft pill.
struct QuietSegmented: View {
    let options: [String]
    @Binding var selection: String
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                Button { selection = option } label: {
                    Text(option).padding(.horizontal, 11).padding(.vertical, 5)
                        .foregroundStyle(selection == option ? .primary : .secondary)
                        .background(Color.primary.opacity(selection == option ? 0.09 : 0), in: Capsule())
                        .contentShape(Capsule())
                }.buttonStyle(.plain).accessibilityAddTraits(selection == option ? .isSelected : [])
            }
        }
    }
}

/// A number field with a px suffix, as in Codex.
struct PixelField: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    @State private var text = ""
    var body: some View {
        HStack(spacing: 8) {
            TextField("", text: $text).textFieldStyle(.plain).monospacedDigit()
                .padding(.horizontal, 10).frame(width: 64, height: 28)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
                .onSubmit(commit)
                .onKeyPress(.upArrow) { step(1); return .handled }
                .onKeyPress(.downArrow) { step(-1); return .handled }
            Text("px").foregroundStyle(.secondary)
        }
        .onAppear { text = "\(Int(value))" }
        .onChange(of: value) { text = "\(Int(value))" }
        .onChange(of: text) { if let number = Double(text), range.contains(number) { value = number } }
    }
    private func commit() { value = min(max(Double(text) ?? value, range.lowerBound), range.upperBound); text = "\(Int(value))" }
    private func step(_ delta: Double) { value = min(max(value + delta, range.lowerBound), range.upperBound) }
}

/// A pill filled with a color and showing its hex value; clicking opens the system color panel.
struct ColorPill: View {
    let title: String
    let color: Color
    let changed: (Color) -> Void
    var body: some View {
        Button { ColorPanelBridge.shared.open(color: color, changed: changed) } label: {
            HStack(spacing: 10) {
                Circle().strokeBorder(ink.opacity(0.35), lineWidth: 1).frame(width: 16, height: 16)
                Text("#" + color.hexValue.uppercased()).font(.system(size: 13, design: .monospaced)).foregroundStyle(ink)
                Spacer(minLength: 0)
            }.padding(.horizontal, 10).frame(width: 150, height: 30)
                .background(color, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        }.buttonStyle(.plain).accessibilityLabel(title).accessibilityValue("#" + color.hexValue.uppercased())
    }
    /// Dark text on light colors and light text on dark ones.
    private var ink: Color {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .gray
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent > 0.6 ? .black : .white
    }
}

@MainActor final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    private var changed: ((Color) -> Void)?
    func open(color: Color, changed: @escaping (Color) -> Void) {
        self.changed = nil
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = NSColor(color)
        self.changed = changed
        panel.setTarget(self); panel.setAction(#selector(colorChanged(_:)))
        panel.isContinuous = true
        panel.orderFront(nil)
    }
    @objc private func colorChanged(_ panel: NSColorPanel) { changed?(Color(nsColor: panel.color)) }
}

/// One control surface across settings, with native keyboard/focus behavior.
struct DesktopButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        DesktopButtonSurface(configuration: configuration, prominent: prominent)
    }
    private struct DesktopButtonSurface: View {
        let configuration: Configuration
        let prominent: Bool
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false
        var body: some View {
            configuration.label.font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 13).padding(.vertical, 6).frame(minHeight: 28)
                .foregroundStyle(configuration.role == .destructive ? Color.red : Color.primary)
                // Soft capsules, as in Codex.
                .background(Color.primary.opacity(!enabled ? 0.035 : configuration.isPressed ? 0.11 : hovering ? 0.08 : 0.055), in: Capsule())
                .overlay(Capsule().stroke(Color.primary.opacity(hovering ? 0.10 : 0.06), lineWidth: 0.5))
                .opacity(enabled ? 1 : 0.4).contentShape(Capsule())
                .onHover { hovering = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}

struct DesktopRowButtonStyle: ButtonStyle {
    var selected = false
    /// Space between a bare label or icon and its highlight. Rows that pad their own label use 0.
    var inset: CGFloat = 0
    func makeBody(configuration: Configuration) -> some View { Surface(configuration: configuration, selected: selected, inset: inset) }
    private struct Surface: View {
        let configuration: Configuration
        let selected: Bool
        let inset: CGFloat
        @Environment(\.colorScheme) private var colorScheme
        @State private var hovering = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label.padding(inset).contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .background((colorScheme == .dark ? Color.white : Color.black).opacity(!enabled ? 0 : configuration.isPressed ? 0.11 : hovering ? (selected ? 0.095 : 0.065) : selected ? 0.075 : 0), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .opacity(enabled ? 1 : 0.4).onHover { hovering = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// A bounded visual browser: selecting applies once and closes, just like a menu.
struct DesktopThemeChooser: View {
    @Environment(DesktopPreferences.self) private var preferences
    let scheme: ColorScheme
    var changed: () -> Void
    @State private var presented = false
    @State private var search = ""
    private var selection: DesktopThemeName { preferences.theme(for: scheme) }
    private var choices: [DesktopThemeName] {
        DesktopThemeName.available(scheme).filter { search.isEmpty || $0.label.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        Button { search = ""; presented.toggle() } label: {
            HStack(spacing: 7) {
                let colors = DesktopPalette.make(selection, dark: scheme == .dark)
                Circle().fill(colors.accent).frame(width: 10, height: 10)
                Text(selection.label).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
        }.buttonStyle(DesktopButtonStyle()).accessibilityLabel("Choose theme, " + selection.label)
            .accessibilityIdentifier("chooseThemeGallery")
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Choose a theme").font(.system(size: 15, weight: .semibold))
                            Text(scheme == .dark ? "Dark appearance" : "Light appearance").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { presented = false } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                            .buttonStyle(DesktopRowButtonStyle()).accessibilityLabel("Close themes")
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Find a theme", text: $search).textFieldStyle(.plain).accessibilityIdentifier("themeSearch")
                    }.padding(10).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 14) {
                            ForEach(choices, id: \.self) { theme in
                                Button {
                                    preferences.setTheme(theme, for: scheme)
                                    preferences.resetColors(for: scheme)
                                    changed(); presented = false
                                } label: {
                                    DesktopThemeTile(theme: theme, dark: scheme == .dark, selected: selection == theme)
                                }.buttonStyle(ThemeTileButtonStyle()).accessibilityLabel(theme.label)
                                    .accessibilityAddTraits(selection == theme ? .isSelected : [])
                                    .accessibilityIdentifier("themeTile-" + theme.rawValue)
                            }
                        }.padding(3)
                        if choices.isEmpty { Text("No matching themes").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 32) }
                    }.frame(height: 320)
                }.padding(18).frame(width: 440).onExitCommand { presented = false }
            }
    }
}

private struct DesktopThemeTile: View {
    let theme: DesktopThemeName
    let dark: Bool
    let selected: Bool
    var body: some View {
        let colors = DesktopPalette.make(theme, dark: dark)
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Circle().fill(colors.accent).frame(width: 7, height: 7)
                    ForEach(0..<3) { _ in Capsule().fill(colors.foreground.opacity(0.25)).frame(height: 3) }
                    Spacer(minLength: 0)
                }.padding(8).frame(width: 35).background(colors.sidebar)
                VStack(alignment: .leading, spacing: 7) {
                    Capsule().fill(colors.foreground.opacity(0.7)).frame(width: 31, height: 4)
                    Capsule().fill(colors.foreground.opacity(0.18)).frame(height: 3)
                    Capsule().fill(colors.foreground.opacity(0.18)).frame(height: 3)
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 3).fill(colors.accent).frame(width: 25, height: 8)
                }.padding(9).frame(maxWidth: .infinity).background(colors.background)
            }.frame(height: 76).clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? colors.accent : Color.primary.opacity(0.1), lineWidth: selected ? 2 : 0.5))
            HStack(spacing: 4) {
                Text(theme.label).font(.system(size: 11, weight: selected ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(colors.accent) }
            }.foregroundStyle(.primary)
        }.contentShape(Rectangle())
    }
}

private struct ThemeTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Surface(configuration: configuration) }
    private struct Surface: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        var body: some View {
            configuration.label.padding(5)
                .background(Color.primary.opacity(hovering ? 0.055 : 0), in: RoundedRectangle(cornerRadius: 12))
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .onHover { hovering = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}

/// The sidebar's surface, as in Codex and Finder: the desktop shows softly through
/// (macOS vibrancy behind the window), tinted with the theme's sidebar color, so
/// it reads lighter than the main pane. Opaque when translucency is off.
struct SidebarSurface: View {
    var tint: Color
    var translucent: Bool
    var body: some View {
        if translucent {
            ZStack {
                BehindWindowMaterial()
                tint.opacity(0.6)
                Color.white.opacity(0.035)
            }
        } else {
            tint
        }
    }
}

private struct BehindWindowMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}


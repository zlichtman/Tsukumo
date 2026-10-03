#if os(iOS)
import SwiftUI

struct AppThemeColors: Codable, Equatable {
    var background: String
    var foreground: String
    var sidebar: String
    var accent: String
}

@MainActor @Observable final class MobileAppearance {
    static let shared = MobileAppearance()
    private let defaults: UserDefaults
    var mode: String { didSet { defaults.set(mode, forKey: "app.appearance.mode") } }
    var lightTheme: String { didSet { defaults.set(lightTheme, forKey: "app.appearance.light") } }
    var darkTheme: String { didSet { defaults.set(darkTheme, forKey: "app.appearance.dark") } }
    var fontName: String { didSet { defaults.set(fontName, forKey: "app.appearance.font") } }
    var textScale: Double { didSet { defaults.set(textScale, forKey: "app.appearance.scale") } }
    var custom: [String: AppThemeColors] { didSet { if let data = try? JSONEncoder().encode(custom) { defaults.set(data, forKey: "app.appearance.custom") } } }
    let themes: [String: [String: AppThemeColors]]
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // New installs start dark, in the theme that matches the logo.
        mode = defaults.string(forKey: "app.appearance.mode") ?? "Dark"
        lightTheme = ThemeNames.current(defaults.string(forKey: "app.appearance.light") ?? "KemoSabe")
        darkTheme = ThemeNames.current(defaults.string(forKey: "app.appearance.dark") ?? "KemoSabe")
        fontName = defaults.string(forKey: "app.appearance.font") ?? "System"
        textScale = defaults.object(forKey: "app.appearance.scale") as? Double ?? 1
        custom = defaults.data(forKey: "app.appearance.custom").flatMap { try? JSONDecoder().decode([String: AppThemeColors].self, from: $0) } ?? [:]
        themes = Bundle.main.url(forResource: "ThemePresets", withExtension: "json").flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String: [String: AppThemeColors]].self, from: $0) } ?? [:]
    }
    var colorScheme: ColorScheme? { mode == "System" ? nil : mode == "Light" ? .light : .dark }
    func colors(_ scheme: ColorScheme) -> AppThemeColors {
        let variant = scheme == .dark ? "dark" : "light"
        let name = scheme == .dark ? darkTheme : lightTheme
        return custom[variant] ?? themes[name]?[variant] ?? themes["Slate"]?[variant] ?? .init(background: scheme == .dark ? "111111" : "FFFFFF", foreground: scheme == .dark ? "FCFCFC" : "0D0D0D", sidebar: "777777", accent: "0169CC")
    }
    func names(_ scheme: ColorScheme) -> [String] { themes.keys.filter { themes[$0]?[scheme == .dark ? "dark" : "light"] != nil }.sorted() }
}

struct MobilePalette {
    var background = Color(uiColor: .systemBackground)
    var foreground = Color.primary
    var surface = Color(uiColor: .secondarySystemGroupedBackground)
    var accent = Color.accentColor
}
private struct MobilePaletteKey: EnvironmentKey { static let defaultValue = MobilePalette() }
extension EnvironmentValues {
    var mobilePalette: MobilePalette { get { self[MobilePaletteKey.self] } set { self[MobilePaletteKey.self] = newValue } }
}
struct MobileAppStyle: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @State private var appearance = MobileAppearance.shared
    func body(content: Content) -> some View {
        let colors = appearance.colors(appearance.colorScheme ?? scheme)
        let palette = MobilePalette(background: Color(hex: colors.background), foreground: Color(hex: colors.foreground), surface: Color(hex: colors.sidebar), accent: Color(hex: colors.accent))
        content.environment(\.colorScheme, appearance.colorScheme ?? scheme).environment(\.mobilePalette, palette).environment(\.chatAccentOverride, palette.accent)
            .preferredColorScheme(appearance.colorScheme).tint(palette.accent).foregroundStyle(palette.foreground)
            .font(KemoType.font(.body)).background(palette.background.ignoresSafeArea())
    }
}

struct AppAppearancePage: View {
    @State private var appearance = MobileAppearance.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.mobilePalette) private var palette
    @AppStorage("kemo.navigation.showNames") private var showNames = false
    private var editingScheme: ColorScheme { appearance.colorScheme ?? scheme }
    var body: some View {
        @Bindable var appearance = appearance
        Form {
            Section("Theme") {
                Picker("Appearance", selection: $appearance.mode) { ForEach(["System", "Light", "Dark"], id: \.self) { Text($0) } }.pickerStyle(.segmented).accessibilityIdentifier("appColorMode")
                if appearance.mode != "Dark" { MobileThemeChooser(appearance: appearance, scheme: .light) }
                if appearance.mode != "Light" { MobileThemeChooser(appearance: appearance, scheme: .dark) }
            }
            Section {
                color("Accent", key: \.accent)
                color("Background", key: \.background)
                color("Foreground", key: \.foreground)
                Button("Reset custom colors") { appearance.custom.removeValue(forKey: editingScheme == .dark ? "dark" : "light") }
                    .disabled(appearance.custom[editingScheme == .dark ? "dark" : "light"] == nil)
            } header: { Text(editingScheme == .dark ? "Dark colors" : "Light colors") } footer: { Text("App colors are independent of KemoSabe’s character palette.") }
            Section("Typography") {
                Picker("UI font", selection: $appearance.fontName) { ForEach(["System", "Rounded", "Serif", "Avenir Next", BundledFonts.jetBrainsMono, "Monospaced"], id: \.self) { Text($0) } }
                HStack { Text("Text size"); Slider(value: $appearance.textScale, in: 0.9...1.3, step: 0.05).accessibilityLabel("Text size"); Text("\(Int(appearance.textScale * 100))%").monospacedDigit().font(.caption) }
                Text("The quick brown fox jumps over the lazy dog.").font(KemoType.font(.body)).padding(.vertical, 4)
            }
            Section("Navigation") { Toggle("Show tab names", isOn: $showNames) }
        }.scrollContentBackground(.hidden).background(palette.background).navigationTitle("Appearance").navigationBarTitleDisplayMode(.inline)
            .onChange(of: appearance.lightTheme) { appearance.custom.removeValue(forKey: "light") }
            .onChange(of: appearance.darkTheme) { appearance.custom.removeValue(forKey: "dark") }
    }
    private func color(_ title: String, key: WritableKeyPath<AppThemeColors, String>) -> some View {
        ColorPicker(title, selection: Binding(get: { Color(hex: appearance.colors(editingScheme)[keyPath: key]) }, set: { value in
            var colors = appearance.colors(editingScheme); colors[keyPath: key] = value.hexValue
            appearance.custom[editingScheme == .dark ? "dark" : "light"] = colors
        }), supportsOpacity: false)
    }
}

/// Shared search treatment for content pages: full-width, clearable, and independent of filters.
struct ContentSearchField: View {
    let prompt: String
    @Binding var text: String
    var identifier: String
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain).textInputAutocapitalization(.never).autocorrectionDisabled().focused($focused).submitLabel(.search).onSubmit { focused = false }.accessibilityIdentifier(identifier)
            if !text.isEmpty { Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).accessibilityLabel("Clear search") }
        }.padding(.horizontal, 14).frame(minHeight: 46).background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.045)))
    }
}

private struct MobileThemeChooser: View {
    let appearance: MobileAppearance
    let scheme: ColorScheme
    @State private var showing = false
    @State private var query = ""
    private var name: String { scheme == .dark ? appearance.darkTheme : appearance.lightTheme }
    var body: some View {
        Button { query = ""; showing = true } label: {
            HStack {
                Text(scheme == .dark ? "Dark theme" : "Light theme").foregroundStyle(.primary)
                Spacer()
                Text(name)
                Image(systemName: "chevron.right").font(.caption)
            }
        }.accessibilityIdentifier(scheme == .dark ? "appDarkTheme" : "appLightTheme")
            .sheet(isPresented: $showing) {
                NavigationStack {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 18) {
                            ForEach(appearance.names(scheme).filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }, id: \.self) { theme in
                                if let colors = appearance.themes[theme]?[scheme == .dark ? "dark" : "light"] {
                                    Button {
                                        if scheme == .dark { appearance.darkTheme = theme } else { appearance.lightTheme = theme }
                                        showing = false
                                    } label: {
                                        VStack(alignment: .leading, spacing: 8) {
                                            HStack(spacing: 0) {
                                                Color(hex: colors.sidebar).frame(width: 35)
                                                VStack(alignment: .leading, spacing: 9) {
                                                    Capsule().fill(Color(hex: colors.foreground).opacity(0.7)).frame(width: 42, height: 5)
                                                    Capsule().fill(Color(hex: colors.foreground).opacity(0.2)).frame(height: 4)
                                                    Spacer()
                                                    Capsule().fill(Color(hex: colors.accent)).frame(width: 35, height: 12)
                                                }.padding(13).frame(maxWidth: .infinity).background(Color(hex: colors.background))
                                            }.frame(height: 100).clipShape(RoundedRectangle(cornerRadius: 14))
                                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(hex: colors.accent).opacity(name == theme ? 1 : 0.15), lineWidth: name == theme ? 2 : 1))
                                            HStack { Text(theme).font(.subheadline); Spacer(); if name == theme { Image(systemName: "checkmark.circle.fill") } }.foregroundStyle(.primary)
                                        }
                                    }.buttonStyle(.plain).accessibilityIdentifier("mobileTheme-" + theme)
                                }
                            }
                        }.padding(20)
                    }.navigationTitle("Choose a theme").navigationBarTitleDisplayMode(.inline)
                        .searchable(text: $query, prompt: "Find a theme")
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(role: .close) { showing = false } } }
                }
            }
    }
}
#endif

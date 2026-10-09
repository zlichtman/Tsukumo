#if os(macOS)
import SwiftUI
import TsukumoCore
import TsukumoUI

// Settings, Dock (October 3): a page you can see. A live preview of the side dock sits on top (the real
// shelf, in miniature, with the owner's own bots, on a little desktop beside macOS's Dock), and every
// choice below changes it as it's made: Style as drawn tiles (each the real shelf in that style), the
// dock's color as swatches with a color picker and Automatic, sizes as sliders with their values, the
// indicators and names as small drawn choices, and Position as a little screen you tap. In MacSpaces'
// Settings design (`SettingsChrome`). The dock's settings are this Mac's own; they don't sync.

/// How the side dock looks and behaves: the Tsukumo app's Settings, Dock. The bots themselves are in
/// Settings, Bots.
public struct BotDockSettingsView: View {
    let dock: BotDock
    public init(dock: BotDock) { self.dock = dock }

    private func percent(_ value: Double, _ range: ClosedRange<Double>) -> String {
        "\(Int(((value - range.lowerBound) / (range.upperBound - range.lowerBound) * 100).rounded()))%"
    }

    public var body: some View {
        let settings = dock.settings
        let store = dock.store
        DockPreview(dock: dock)
            .accessibilityIdentifier("dockPreview")

        SettingsCard("Style", systemImage: "paintbrush") {
            HStack(spacing: 10) {
                ForEach(DockStyle.allCases) { style in
                    DockStyleTile(style: style, tint: settings.tint, selected: settings.style == style) {
                        store.update { $0.style = style }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("dockStyle")
            Divider()
            DockColorRow(tint: settings.tint) { tint in store.update { $0.tint = tint } }
        }

        SettingsCard("Size", systemImage: "arrow.up.left.and.arrow.down.right") {
            SettingsSlider("Size", value: Binding(get: { settings.size }, set: { size in store.update { $0.size = size } }),
                           in: DockSettings.sizeRange, valueText: "\(Int(settings.size)) pt")
            SettingsSlider("Spacing", value: Binding(get: { settings.spacing }, set: { spacing in store.update { $0.spacing = spacing } }),
                           in: DockSettings.spacingRange, valueText: percent(settings.spacing, DockSettings.spacingRange))
            SettingsSlider("Corners", value: Binding(get: { settings.corners }, set: { corners in store.update { $0.corners = corners } }),
                           in: DockSettings.cornersRange, valueText: percent(settings.corners, DockSettings.cornersRange))
            Divider()
            Toggle("Magnification", isOn: Binding(get: { settings.magnification }, set: { on in store.update { $0.magnification = on } }))
            if settings.magnification {
                SettingsSlider("Magnified size", value: Binding(get: { settings.magnifiedSize }, set: { size in store.update { $0.magnifiedSize = size } }),
                               in: DockSettings.magnifiedRange, valueText: "\(Int(settings.magnifiedSize)) pt")
            }
            Toggle("Separator before Together and Settings", isOn: Binding(get: { settings.separators }, set: { on in store.update { $0.separators = on } }))
        }

        SettingsCard("Indicators", systemImage: "circle.badge.checkmark") {
            DockChoiceRow(title: "Working or waiting on you", choices: DockIndicator.allCases, selected: settings.indicator, label: \.title) { choice in
                IndicatorGlyph(indicator: choice, tint: settings.tint)
            } pick: { value in store.update { $0.indicator = value } }
            Divider()
            DockChoiceRow(title: "Names on hover", choices: DockLabelStyle.allCases, selected: settings.labels, label: \.title) { choice in
                NameGlyph(style: choice)
            } pick: { value in store.update { $0.labels = value } }
        }

        SettingsCard("Position", systemImage: "rectangle.righthalf.inset.filled") {
            HStack(alignment: .center, spacing: 22) {
                DockPositionPicker(edge: settings.edge, position: settings.position) { edge, position in
                    store.update { $0.edge = edge; $0.position = position }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(settings.edge.title) edge, \(settings.position.title.lowercased())").font(.system(size: 13, weight: .semibold))
                        .accessibilityIdentifier("dockPositionTitle")
                    Toggle("Automatically hide", isOn: Binding(get: { settings.autohide }, set: { on in store.update { $0.autohide = on } }))
                    if settings.autohide {
                        Picker("Hide after", selection: Binding(get: { settings.autohideDelay }, set: { delay in store.update { $0.autohideDelay = delay } })) {
                            ForEach(DockSettings.delayChoices, id: \.1) { Text($0.0).tag($0.1) }
                        }
                        .pickerStyle(.segmented).fixedSize()
                    }
                    SettingsNote("Tap a spot on the screen. Hidden, the dock waits as a sliver at the edge until the pointer reaches it.")
                }
            }
        }

        SettingsCard("Animation and sound", systemImage: "face.smiling") {
            SettingsField("Animation") {
                Picker("Animation", selection: Binding(get: { settings.animation }, set: { level in store.update { $0.animation = level } })) {
                    ForEach(DockAnimationLevel.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            Toggle("Sleep at night", isOn: Binding(get: { settings.sleepAtNight }, set: { on in store.update { $0.sleepAtNight = on } }))
            Toggle("Chirp sounds", isOn: Binding(get: { settings.chirpSounds }, set: { on in store.update { $0.chirpSounds = on } }))
                .accessibilityIdentifier("dockChirpSounds")
        }

        SettingsCard("Coding bots", systemImage: "chevron.left.forwardslash.chevron.right") {
            SettingsField("Follow their edits in") {
                Picker("Follow their edits in", selection: Binding(get: { settings.followEditor ?? "" }, set: { id in store.update { $0.followEditor = id.isEmpty ? nil : id } })) {
                    Text("Nowhere").tag("")
                    ForEach(EditorTarget.installed(), id: \.bundleID) { Text($0.name).tag($0.bundleID) }
                }
                .labelsHidden().fixedSize().accessibilityIdentifier("dockFollowEditor")
            }
            SettingsNote("When a coding bot with a project starts working, its folder opens in this editor, and each file its agent edits is shown there, never while you're typing somewhere else.")
        }
    }
}

// MARK: The preview

/// The side dock in miniature: the real shelf (`DockShelfView`) with the owner's bots, laid out by the same
/// `DockLayout` on a little desktop, so every setting shows as it changes. It holds still and takes no clicks.
struct DockPreview: View {
    let dock: BotDock
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The desktop it's drawn on, before it's scaled to fit.
    static let screen = CGSize(width: 1000, height: 560)

    var body: some View {
        let colors = SettingsColors(scheme)
        GeometryReader { proxy in
            let scale = proxy.size.width / Self.screen.width
            desktop
                .frame(width: Self.screen.width, height: Self.screen.height)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .aspectRatio(Self.screen.width / Self.screen.height, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(colors.border, lineWidth: 1) }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of the side dock")
        .accessibilityValue("\(dock.settings.style.title), \(dock.settings.edge.title) edge, \(dock.settings.position.title.lowercased())")
    }

    private var desktop: some View {
        let settings = dock.settings
        let layout = DockLayout(settings: settings, tiles: dock.bots.count + 2, screen: CGRect(origin: .zero, size: Self.screen))
        let frame = layout.revealedFrame
        let dark = scheme == .dark
        return ZStack(alignment: .topLeading) {
            // A wallpaper with some color in it, so glass and tints read.
            LinearGradient(colors: dark ? [Color(red: 0.13, green: 0.12, blue: 0.24), Color(red: 0.32, green: 0.18, blue: 0.3), Color(red: 0.12, green: 0.2, blue: 0.3)]
                                        : [Color(red: 0.62, green: 0.74, blue: 0.95), Color(red: 0.95, green: 0.74, blue: 0.7), Color(red: 0.98, green: 0.9, blue: 0.78)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(.white.opacity(dark ? 0.06 : 0.22)).frame(width: 520).blur(radius: 60).offset(x: 120, y: 160)
            // The menu bar, and macOS's own Dock at the bottom.
            Rectangle().fill(.ultraThinMaterial).frame(height: 24).frame(maxWidth: .infinity)
            HStack(spacing: 10) {
                ForEach(0..<7, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill([Color.blue, .green, .orange, .pink, .purple, .teal, .gray][index].opacity(0.75)).frame(width: 40, height: 40)
                }
            }
            .padding(8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .position(x: Self.screen.width / 2, y: Self.screen.height - 34)
            DockShelfView(dock: dock, layout: layout, revealed: true, reduceMotion: reduceMotion, active: false)
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: Self.screen.height - frame.midY)
        }
        .environment(\.colorScheme, scheme)
    }
}

// MARK: Style and color

/// One style, drawn: the real shelf in that style on a scrap of wallpaper, with three little bots.
struct DockStyleTile: View {
    let style: DockStyle
    let tint: String?
    let selected: Bool
    let pick: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = TsukumoTheme(scheme)
        Button(action: pick) {
            VStack(spacing: 7) {
                ZStack {
                    LinearGradient(colors: scheme == .dark ? [Color(red: 0.2, green: 0.17, blue: 0.32), Color(red: 0.14, green: 0.22, blue: 0.3)]
                                                         : [Color(red: 0.7, green: 0.8, blue: 0.97), Color(red: 0.98, green: 0.82, blue: 0.76)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
                    ZStack {
                        DockShelf(style: style, shape: shape, accent: theme.accent, tint: tint.map { RGB(hex: $0).color })
                        VStack(spacing: 5) {
                            Circle().fill(theme.accent).frame(width: 11, height: 11)
                            Circle().fill(Color(red: 0.45, green: 0.62, blue: 0.95)).frame(width: 11, height: 11)
                            Circle().fill(Color(red: 0.55, green: 0.78, blue: 0.5)).frame(width: 11, height: 11)
                        }
                    }
                    .frame(width: 22, height: 56)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 10)
                }
                .frame(height: 70)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selected ? theme.accent : Color.primary.opacity(0.12), lineWidth: selected ? 2 : 1)
                }
                .overlay(alignment: .topLeading) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(.white, theme.accent).padding(5)
                    }
                }
                Text(style.title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.primary : .secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(style.title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("dockStyle-" + style.rawValue)
    }
}

/// The dock's color: Automatic (follows the theme), a row of swatches, and a color picker for any other.
struct DockColorRow: View {
    let tint: String?
    let pick: (String?) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = TsukumoTheme(scheme)
        let custom = tint.map { hex in !DockSettings.tintSwatches.contains { $0.hex == hex } } ?? false
        HStack(spacing: 12) {
            Text("Color").lineLimit(1).frame(width: 124, alignment: .leading)
            HStack(spacing: 7) {
                swatch(nil, name: "Automatic", selected: tint == nil) {
                    Circle().fill(AngularGradient(colors: [theme.accent, .blue, .green, theme.accent], center: .center))
                        .overlay(Circle().fill(.background).padding(6))
                }
                ForEach(DockSettings.tintSwatches, id: \.hex) { item in
                    swatch(item.hex, name: item.name, selected: tint == item.hex) { Circle().fill(RGB(hex: item.hex).color) }
                }
                ColorPicker("Other color", selection: Binding(get: { tint.map { RGB(hex: $0).color } ?? theme.accent },
                                                              set: { pick(RGB($0).hex) }), supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 34, height: 22)
                    .overlay {
                        if custom {
                            RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.6), lineWidth: 2)
                                .frame(width: 40, height: 28).allowsHitTesting(false)
                        }
                    }
                    .help("Any color")
                    .accessibilityIdentifier("dockColorPicker")
            }
            Spacer(minLength: 0)
        }
        Text(tint == nil ? "Automatic: the glass as it is, coral for Tinted glass, the window color for Solid."
                         : "Tints the glass, fills Solid, and colors the sliver and working marks in every style.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func swatch(_ hex: String?, name: String, selected: Bool, @ViewBuilder fill: () -> some View) -> some View {
        Button { pick(hex) } label: {
            fill()
                .frame(width: 20, height: 20)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                .padding(3)
                .overlay { if selected { Circle().strokeBorder(Color.primary.opacity(0.6), lineWidth: 2) } }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("dockColor-" + (hex ?? "automatic"))
    }
}

// MARK: Small drawn choices

/// A row of small drawn choices with their names under them.
struct DockChoiceRow<Choice: Hashable & Identifiable, Glyph: View>: View {
    let title: String
    let choices: [Choice]
    let selected: Choice
    let label: KeyPath<Choice, String>
    @ViewBuilder let glyph: (Choice) -> Glyph
    let pick: (Choice) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let accent = TsukumoTheme(scheme).accent
        HStack(alignment: .center, spacing: 12) {
            Text(title).lineLimit(2).frame(width: 124, alignment: .leading)
            HStack(spacing: 8) {
                ForEach(choices) { choice in
                    let on = choice == selected
                    Button { pick(choice) } label: {
                        VStack(spacing: 5) {
                            glyph(choice)
                                .frame(width: 66, height: 40)
                                .background(Color.primary.opacity(on ? 0.06 : 0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(on ? accent : Color.primary.opacity(0.1), lineWidth: on ? 2 : 1)
                                }
                            Text(choice[keyPath: label]).font(.system(size: 11, weight: on ? .semibold : .regular))
                                .foregroundStyle(on ? Color.primary : .secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(title + ": " + choice[keyPath: label])
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// A little bot for the drawn choices.
private struct GlyphBot: View {
    var size: CGFloat = 18
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Circle().fill(LinearGradient(colors: [TsukumoTheme(scheme).accent.opacity(0.85), TsukumoTheme(scheme).accent], startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay(HStack(spacing: size * 0.18) { Circle().frame(width: size * 0.14); Circle().frame(width: size * 0.14) }.foregroundStyle(.black.opacity(0.7)).offset(y: -size * 0.05))
    }
}

private struct IndicatorGlyph: View {
    let indicator: DockIndicator
    let tint: String?
    var body: some View {
        let mark = tint.map { RGB(hex: $0).color }
        HStack(spacing: 5) {
            GlyphBot()
                .overlay { if indicator == .ring { Circle().strokeBorder(mark ?? .orange, lineWidth: 1.5).frame(width: 24, height: 24) } }
            if indicator == .dot { Circle().fill(mark ?? Color.primary.opacity(0.75)).frame(width: 4, height: 4) }
        }
    }
}

private struct NameGlyph: View {
    let style: DockLabelStyle
    var body: some View {
        HStack(spacing: 4) {
            switch style {
            case .glass:
                Text("Ada").font(.system(size: 9, weight: .medium)).padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.regularMaterial, in: Capsule()).overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            case .plain:
                Text("Ada").font(.system(size: 9, weight: .medium)).shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
            case .off:
                EmptyView()
            }
            GlyphBot(size: 16)
        }
    }
}

// MARK: Position

/// A little screen: tap the left or right edge, at the top, center, or bottom.
struct DockPositionPicker: View {
    let edge: DockSettings.Edge
    let position: DockSettings.Position
    let pick: (DockSettings.Edge, DockSettings.Position) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let accent = TsukumoTheme(scheme).accent
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.05))
            RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.18), lineWidth: 1.5)
            VStack(spacing: 0) {
                Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 7)
                Spacer()
                RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.12)).frame(width: 54, height: 8).padding(.bottom, 5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            HStack {
                column(.left, accent: accent)
                Spacer()
                column(.right, accent: accent)
            }
            .padding(.horizontal, 6)
            .padding(.top, 12).padding(.bottom, 6)
        }
        .frame(width: 168, height: 106)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dockEdge")
    }

    private func column(_ side: DockSettings.Edge, accent: Color) -> some View {
        VStack(spacing: 4) {
            ForEach(DockSettings.Position.allCases) { spot in
                let on = side == edge && spot == position
                Button { pick(side, spot) } label: {
                    Capsule().fill(on ? accent : Color.primary.opacity(0.16))
                        .frame(width: on ? 8 : 6, height: 22)
                        .frame(width: 24, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(side.title) edge, \(spot.title.lowercased())")
                .accessibilityLabel("\(side.title) edge, \(spot.title.lowercased())")
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("dockPosition-\(side.rawValue)-\(spot.rawValue)")
            }
        }
    }
}
#endif

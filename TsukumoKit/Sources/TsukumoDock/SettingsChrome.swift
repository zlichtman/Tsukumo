#if os(macOS)
import SwiftUI
import TsukumoUI

// The pieces of the Mac app's Settings window, in MacSpaces' design language (its SettingsPage,
// SettingsCard, and rows, in MacSpaces' Sources/Settings), on Tsukumo's palette: the warm paper or plum
// page, a slightly lighter card with a hairline border, a page title with one line under it, and cards
// with a symbol and a quiet title. They live here so the dock's own settings (`BotDockSettingsView`) use
// them too.

/// The Settings window's colors, from Tsukumo's palette.
public struct SettingsColors: Sendable {
    public let scheme: ColorScheme
    public init(_ scheme: ColorScheme) { self.scheme = scheme }
    private var theme: TsukumoTheme { TsukumoTheme(scheme) }
    private var dark: Bool { scheme == .dark }
    /// The page behind everything.
    public var surface: Color { theme.background }
    /// The sidebar and the cards: a little lighter than the page.
    public var tile: Color { (dark ? theme.backgroundRGB.mix(theme.inkRGB, 0.06) : theme.backgroundRGB.mix(.white, 0.62)).color }
    /// Card borders and the sidebar's edge.
    public var border: Color { theme.ink.opacity(dark ? 0.12 : 0.1) }
    /// The selected sidebar row: a soft gray.
    public var selected: Color { theme.ink.opacity(dark ? 0.09 : 0.065) }
    /// A row under the pointer.
    public var hover: Color { theme.ink.opacity(dark ? 0.04 : 0.03) }
    /// Tsukumo's coral.
    public var accent: Color { theme.accent }
    public var ink: Color { theme.ink }
}

public extension EnvironmentValues {
    /// The card a Settings search result opened (its title): the page scrolls to it and outlines it.
    @Entry var settingsSearchTarget: String? = nil
}

/// A Settings page: a large title, one line under it, then its cards. `scrollAnchor` (an id in the page) is
/// scrolled to the middle, as search's highlighted result is; otherwise the page scrolls to the card a search opened.
public struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    let scrollAnchor: String?
    let content: Content
    @Environment(\.colorScheme) private var scheme
    @Environment(\.settingsSearchTarget) private var target
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(title: String, subtitle: String, scrollAnchor: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.scrollAnchor = scrollAnchor; self.content = content()
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.system(size: 26, weight: .bold)).accessibilityAddTraits(.isHeader)
                        Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 2)
                    content
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .task(id: scrollAnchor ?? target) {
                guard let id = scrollAnchor ?? target.map({ "settings." + $0 }) else { return }
                await Task.yield()
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: scrollAnchor == nil ? .top : .center) }
            }
        }
        .background(SettingsColors(scheme).surface)
        .foregroundStyle(SettingsColors(scheme).ink)
    }
}

/// A card: a symbol and a quiet title, then its content.
public struct SettingsCard<Content: View>: View {
    let title: String
    let systemImage: String
    let content: Content
    @Environment(\.colorScheme) private var scheme

    public init(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title; self.systemImage = systemImage; self.content = content()
    }

    public var body: some View {
        let colors = SettingsColors(scheme)
        VStack(alignment: .leading, spacing: 13) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.tile, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(colors.border, lineWidth: 1) }
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(colors.accent.opacity(target == title ? 0.65 : 0), lineWidth: 1.5) }
        .id("settings." + title)
    }
    @Environment(\.settingsSearchTarget) private var target
}

/// A row in a card's list: an icon (or any leading view), a title with an optional count, a line under
/// it, and what goes at the end (a chevron where it opens something).
public struct SettingsRow<Leading: View, Trailing: View>: View {
    let title: String
    let count: Int?
    let subtitle: String?
    let leading: Leading
    let trailing: Trailing

    public init(_ title: String, count: Int? = nil, subtitle: String? = nil,
                @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.count = count; self.subtitle = subtitle; self.leading = leading(); self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    if let count { Text("\(count)").font(.caption).foregroundStyle(.tertiary) }
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

public extension SettingsRow where Leading == SettingsIcon {
    /// A row with an SF Symbol on a soft tile.
    init(_ title: String, systemImage: String, count: Int? = nil, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.init(title, count: count, subtitle: subtitle, leading: { SettingsIcon(systemImage) }, trailing: trailing)
    }
}

/// An SF Symbol on a soft 30 pt tile, for list rows.
public struct SettingsIcon: View {
    let systemImage: String
    public init(_ systemImage: String) { self.systemImage = systemImage }
    public var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .semibold))
            .frame(width: 30, height: 30)
            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The chevron at the end of a row that opens something.
public struct SettingsChevron: View {
    public init() {}
    public var body: some View {
        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary).accessibilityHidden(true)
    }
}

/// A line of quiet text in a card (what a group does, or a warning in orange).
public struct SettingsNote: View {
    let text: String
    let warning: Bool
    public init(_ text: String, warning: Bool = false) { self.text = text; self.warning = warning }
    public var body: some View {
        Text(text).font(.caption).foregroundStyle(warning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A labeled control in a card: the label on the left, the control on the right.
public struct SettingsField<Control: View>: View {
    let title: String
    let control: Control
    public init(_ title: String, @ViewBuilder control: () -> Control) { self.title = title; self.control = control() }
    public var body: some View {
        HStack(spacing: 12) {
            Text(title).lineLimit(1)
            Spacer(minLength: 12)
            control
        }
    }
}

/// A slider with its label and value, as MacSpaces' `SettingsSlider`.
public struct SettingsSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let valueText: String
    public init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, valueText: String) {
        self.title = title; _value = value; self.range = range; self.valueText = valueText
    }
    public var body: some View {
        HStack(spacing: 12) {
            Text(title).lineLimit(1).fixedSize(horizontal: true, vertical: false).frame(width: 124, alignment: .leading)
            Slider(value: $value, in: range).frame(maxWidth: .infinity)
            Text(valueText).font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 58, alignment: .trailing)
        }
        .frame(minWidth: 300)
    }
}
#endif

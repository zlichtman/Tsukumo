import SwiftUI

// Tsukumo's design system (design/UI-GUIDE.md, Design system): every screen is built from these, so a sheet, a list,
// a picker, and an empty page look like the chat they came from. Colors come from `TsukumoTheme`; nothing uses a
// bare system gray, a stock segmented control, or an unthemed sheet.

public extension TsukumoTheme {
    /// A raised surface: a card, a list row, a sheet's group (a solid color, so rows never show the page through).
    var surface: Color { surfaceRGB.color }
    var surfaceRGB: RGB { backgroundRGB.mix(inkRGB, scheme == .dark ? 0.07 : 0.035) }
    /// A sheet's page: the chat's own, so a page reads the same in a sheet and on its own.
    var sheet: Color { background }
    /// A selected control's fill (a segment, a chip).
    var selected: Color { accent.opacity(scheme == .dark ? 0.24 : 0.16) }
}

/// The one spacing scale and the corner radii every screen uses.
public enum TsukumoMetrics {
    public static let gutter: CGFloat = 16
    public static let cardCorner: CGFloat = 22
    public static let rowCorner: CGFloat = 14
    public static let control: CGFloat = 38
    /// The one spring for things that move (sheets, chips, the slider, the tab bar's companions).
    public static let spring = Animation.spring(duration: 0.32, bounce: 0.14)
}

// MARK: Buttons

/// Every tappable that isn't a system control: it shrinks a little under the finger.
public struct PressableButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A round icon button in the composer's row (conversations, new chat): 38 pt on the theme's fill.
public struct ControlCircle: View {
    let label: String
    let systemImage: String
    let action: () -> Void
    @State private var taps = 0
    @Environment(\.colorScheme) private var scheme
    public init(_ label: String, systemImage: String, action: @escaping () -> Void) {
        self.label = label; self.systemImage = systemImage; self.action = action
    }
    public var body: some View {
        let theme = TsukumoTheme(scheme)
        Button { taps += 1; action() } label: {
            Image(systemName: systemImage).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.ink.opacity(0.85))
                .frame(width: TsukumoMetrics.control, height: TsukumoMetrics.control)
                .background(theme.ink.opacity(scheme == .dark ? 0.08 : 0.06), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
        .accessibilityLabel(label)
    }
}

// MARK: Segmented choice

/// The segmented picker: options in a capsule, the chosen one on an accent fill that slides between them. Used
/// instead of the system's segmented control everywhere (Activity's filter, a bot's speed).
public struct TsukumoSegmented<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    @Namespace private var namespace
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init(_ options: [(value: Value, title: String)], selection: Binding<Value>) {
        self.options = options; self._selection = selection
    }
    public var body: some View {
        let theme = TsukumoTheme(scheme)
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let on = option.value == selection
                Button {
                    withAnimation(reduceMotion ? nil : TsukumoMetrics.spring) { selection = option.value }
                } label: {
                    Text(option.title).font(.subheadline.weight(on ? .semibold : .medium)).lineLimit(1).minimumScaleFactor(0.8)
                        .foregroundStyle(on ? theme.ink : theme.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background {
                            if on { Capsule().fill(theme.selected).matchedGeometryEffect(id: "segment", in: namespace) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(theme.surface, in: Capsule())
        .overlay(Capsule().stroke(theme.hairline))
        .sensoryFeedback(.selection, trigger: selection)
    }
}

// MARK: Empty state

/// What a page shows with nothing in it: KemoSabe's tone, an icon in a soft circle, a title, and one line.
public struct TsukumoEmptyState: View {
    let systemImage: String
    let title: String
    let message: String
    @Environment(\.colorScheme) private var scheme
    public init(_ title: String, systemImage: String, message: String) {
        self.title = title; self.systemImage = systemImage; self.message = message
    }
    public var body: some View {
        let theme = TsukumoTheme(scheme)
        VStack(spacing: 12) {
            Image(systemName: systemImage).font(.system(size: 24, weight: .medium)).foregroundStyle(theme.accent)
                .frame(width: 60, height: 60).background(theme.accent.opacity(0.12), in: Circle())
            Text(title).font(.headline).foregroundStyle(theme.ink)
            Text(message).font(.subheadline).foregroundStyle(theme.secondary).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32).padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Screens, lists, and sheets

/// A screen on the theme: its page color behind everything (lists included), its ink, and its accent as the tint.
struct TsukumoScreen: ViewModifier {
    var sheet: Bool
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let theme = TsukumoTheme(scheme)
        content
            .scrollContentBackground(.hidden)
            .background((sheet ? theme.sheet : theme.background).ignoresSafeArea())
            .foregroundStyle(theme.ink)
            .tint(theme.accent)
            .listRowSeparatorTint(theme.hairline)
    }
}

/// A list section's rows on the theme's surface.
struct TsukumoRows: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let theme = TsukumoTheme(scheme)
        content.listRowBackground(theme.surface).listRowSeparatorTint(theme.hairline)
    }
}

/// A sheet on the theme: its page color, a grabber, and the system's rounded top.
struct TsukumoSheet: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .presentationBackground(TsukumoTheme(scheme).sheet)
            .presentationDragIndicator(.visible)
    }
}

/// A sheet as tall as what it shows (measured), up to the full screen when pulled.
struct FittedSheet: ViewModifier {
    @State private var height: CGFloat = 320
    @State private var detent: PresentationDetent = .height(320)
    func body(content: Content) -> some View {
        ScrollView {
            content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured in
                let fitted = min(max(measured + 28, 220), 680)
                guard abs(fitted - height) > 1 else { return }
                let wasFitted = detent == .height(height)
                height = fitted
                if wasFitted { detent = .height(fitted) }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.height(height), .large], selection: $detent)
        .modifier(TsukumoSheet())
    }
}

public extension View {
    /// The screen on Tsukumo's theme (`sheet`: a sheet's page color).
    func tsukumoScreen(sheet: Bool = false) -> some View { modifier(TsukumoScreen(sheet: sheet)) }
    /// A list section's rows on the theme's surface.
    func tsukumoRows() -> some View { modifier(TsukumoRows()) }
    /// A sheet on the theme, with its grabber.
    func tsukumoSheet() -> some View { modifier(TsukumoSheet()) }
    /// A sheet sized to its content, pulled up to full height.
    func fittedSheet() -> some View { modifier(FittedSheet()) }
}

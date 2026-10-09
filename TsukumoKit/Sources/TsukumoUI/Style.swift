import SwiftUI
import TsukumoCore

// TsukumoUI: the demo chat, the bots' settings, and Activity (docs/ARCHITECTURE.md#tsukumoui).
// Plain SwiftUI so the iPhone app and the Mac app share it. Everything here reads its colors
// from `TsukumoTheme`, which follows the color scheme, so a view renders the same in a test's
// `ImageRenderer` as on screen.

/// An sRGB color as numbers, so colors can be mixed the same way on every platform.
public struct RGB: Hashable, Sendable {
    public var red: Double, green: Double, blue: Double

    public init(red: Double, green: Double, blue: Double) { self.red = red; self.green = green; self.blue = blue }
    /// "EF705B"
    public init(hex: String) {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")), radix: 16) ?? 0
        self.init(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
    /// This color blended toward `other` by `amount` (0…1).
    public func mix(_ other: RGB, _ amount: Double) -> RGB {
        let t = min(1, max(0, amount))
        return RGB(red: red + (other.red - red) * t, green: green + (other.green - green) * t, blue: blue + (other.blue - blue) * t)
    }
    public var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }
    /// "EF705B"
    public var hex: String {
        String(format: "%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }
    /// A color picked in a color picker, as sRGB numbers.
    public init(_ color: Color) {
        let resolved = color.resolve(in: EnvironmentValues())
        self.init(red: min(1, max(0, Double(resolved.red))), green: min(1, max(0, Double(resolved.green))), blue: min(1, max(0, Double(resolved.blue))))
    }
    /// WCAG relative luminance.
    public var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
    /// WCAG contrast ratio, from 1 to 21.
    public func contrast(with other: RGB) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
    public static let white = RGB(red: 1, green: 1, blue: 1)
    public static let black = RGB(red: 0, green: 0, blue: 0)
}

public extension BotSpec {
    /// KemoSabe's color in the chat (its card, ring, lock, and buttons): its companion palette's accent
    /// (coral in Apricot), or the palette's body where the accent is too pale to fill a button.
    var kemoSabeColor: Color { kemoSabePalette.legibleAccentRGB.color }
    /// The same color for words on the chat's background: moved toward the ink until it reads (3:1).
    func kemoSabeTextColor(_ scheme: ColorScheme) -> Color {
        let theme = TsukumoTheme(scheme)
        var color = kemoSabePalette.legibleAccentRGB
        for _ in 0..<10 where color.contrast(with: theme.backgroundRGB) < 3 { color = color.mix(theme.inkRGB, 0.15) }
        return color.color
    }
}

public extension BotPalette {
    var bodyRGB: RGB { RGB(hex: body) }
    var accentRGB: RGB { RGB(hex: accent) }
    var backgroundRGB: RGB { RGB(hex: background) }
    /// The accent, or the body when the accent is too pale to carry white text (Ink's cream).
    var legibleAccentRGB: RGB { accentRGB.luminance > 0.5 ? bodyRGB : accentRGB }
}

/// The chat's colors: KemoSabe's Apricot, as in the website demo. Dark is the demo's plum; light is a
/// warm paper with the same coral.
public struct TsukumoTheme: Sendable {
    public let scheme: ColorScheme
    public init(_ scheme: ColorScheme) { self.scheme = scheme }

    private static let apricot = BotPalette.named("apricot")
    private var dark: Bool { scheme == .dark }

    /// The page behind the chat (plum `211B2C` in dark).
    public var background: Color { backgroundRGB.color }
    public var backgroundRGB: RGB { dark ? Self.apricot.backgroundRGB : RGB(hex: "FBF6EE") }
    /// The coral every KemoSabe card and the send button use (`EF705B`).
    public var accent: Color { Self.apricot.accentRGB.color }
    /// Body text: cream on plum, plum on paper.
    public var ink: Color { inkRGB.color }
    public var inkRGB: RGB { dark ? RGB(hex: "F3EADF") : RGB(hex: "2A2234") }
    /// Quieter text: names, captions, "Working…".
    public var secondary: Color { ink.opacity(dark ? 0.58 : 0.6) }
    /// A soft fill: the owner's bubble, suggestion rows, the composer.
    public var fill: Color { ink.opacity(dark ? 0.065 : 0.05) }
    /// A hairline around fills.
    public var hairline: Color { ink.opacity(dark ? 0.08 : 0.1) }
    /// The send button's arrow.
    public var onAccent: Color { dark ? Color.black.opacity(0.85) : .white }
}

/// Fonts sized as the website demo's: the system font at iPhone sizes (scaling with the owner's text
/// size on iPhone; fixed elsewhere, so a snapshot on a Mac lays out like the phone).
public enum TsukumoType {
    public static func size(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        case .headline: 17
        case .subheadline: 15
        case .callout: 16
        case .footnote: 13
        case .caption: 12
        case .caption2: 11
        default: 17
        }
    }
    public static func font(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        #if os(iOS)
        .system(style, weight: weight)
        #else
        .system(size: size(style), weight: weight)
        #endif
    }
}

/// How roomy the chat is: `.regular` is the website demo at iPhone sizes; `.compact` is the same chat at
/// Mac sizes, for the side dock's bubble.
public enum ChatDensity: Sendable, Hashable {
    case regular, compact
    /// Text scale against the iPhone sizes (17 pt body becomes 13 pt).
    public var textScale: CGFloat { self == .compact ? 0.765 : 1 }
}

public extension EnvironmentValues {
    /// The chat's density (`.regular` unless a Mac surface asks for `.compact`).
    @Entry var chatDensity: ChatDensity = .regular
}

/// A `TsukumoType` font at the chat's density.
struct TsukumoFont: ViewModifier {
    let style: Font.TextStyle
    let weight: Font.Weight
    @Environment(\.chatDensity) private var density
    func body(content: Content) -> some View {
        if density == .regular {
            content.font(TsukumoType.font(style, weight: weight))
        } else {
            content.font(.system(size: (TsukumoType.size(style) * density.textScale).rounded(), weight: weight))
        }
    }
}

public extension View {
    /// The chat's font for `style`, scaled by the chat's density.
    func tsukumoFont(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> some View {
        modifier(TsukumoFont(style: style, weight: weight))
    }
}

/// Images that ship with TsukumoUI (KemoSabe's artwork, Tsukumo's mark and wordmark, engine marks).
public enum TsukumoArt {
    public enum Name: String, CaseIterable, Sendable {
        case kemoSabe = "KemoSabe"
        case kemoSabeSearching = "KemoSabeSearching"
        case mark = "TsukumoMark"
        case wordmark = "TsukumoWordmark"
        case claude = "EngineMarkClaude"
        case openAI = "EngineMarkOpenAI"
    }
    public static func url(_ name: Name) -> URL? { Bundle.module.url(forResource: name.rawValue, withExtension: "png") }
    public static func image(_ name: Name) -> Image {
        #if canImport(UIKit)
        if let url = url(name), let image = UIImage(contentsOfFile: url.path) { return Image(uiImage: image) }
        #elseif canImport(AppKit)
        if let url = url(name), let image = NSImage(contentsOf: url) { return Image(nsImage: image) }
        #endif
        return Image(systemName: "questionmark.square.dashed")
    }
}

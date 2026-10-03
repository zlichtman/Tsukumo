import CoreText
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Fonts that ship inside the app (JetBrains Mono, under the SIL Open Font
/// License in Resources/Fonts). Registered once at launch for this process only.
enum BundledFonts {
    static let jetBrainsMono = "JetBrains Mono"
    static func register() {
        let urls = (Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? [])
            + (Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [])
        for url in urls where url.lastPathComponent.hasPrefix("JetBrainsMono") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
    /// JetBrains Mono's static weights, since SwiftUI can't synthesize them from one file.
    static func jetBrainsMonoName(_ weight: Font.Weight) -> String {
        switch weight {
        case .bold, .heavy, .black: "JetBrainsMono-Bold"
        case .semibold: "JetBrainsMono-SemiBold"
        case .medium: "JetBrainsMono-Medium"
        default: "JetBrainsMono-Regular"
        }
    }
}

/// Avenir Next is the UI typeface; the supplied wordmark remains artwork, not retyped text.
enum KemoType {
    @MainActor static func font(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        let size: CGFloat
        switch style {
        case .largeTitle: size = 34
        case .title: size = 28
        case .title2: size = 22
        case .title3: size = 20
        case .headline: size = 17
        case .subheadline: size = 15
        case .callout: size = 16
        case .footnote: size = 13
        case .caption: size = 12
        case .caption2: size = 11
        default: size = 17
        }
        #if os(macOS)
        return .system(size: max(11, size - 2), weight: weight)
        #else
        let preferences = MobileAppearance.shared
        let scaled = size * preferences.textScale
        let accessibleSize = UIFontMetrics.default.scaledValue(for: scaled)
        switch preferences.fontName {
        case "Avenir Next": return .custom(weight == .bold || weight == .semibold ? "AvenirNext-DemiBold" : "AvenirNext-Regular", size: scaled, relativeTo: style)
        case "Rounded": return .system(size: accessibleSize, weight: weight, design: .rounded)
        case "Serif": return .system(size: accessibleSize, weight: weight, design: .serif)
        case "Monospaced": return .custom("Menlo", size: scaled, relativeTo: style).weight(weight)
        case BundledFonts.jetBrainsMono: return .custom(BundledFonts.jetBrainsMonoName(weight), size: scaled, relativeTo: style)
        default: return .system(size: accessibleSize, weight: weight)
        }
        #endif
    }
    static func configureNavigation() {
        #if os(iOS)
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.titleTextAttributes = [.font: UIFontMetrics(forTextStyle: .headline).scaledFont(for: UIFont.systemFont(ofSize: 17, weight: .semibold)), .foregroundColor: UIColor.label]
        appearance.largeTitleTextAttributes = [.font: UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: UIFont.systemFont(ofSize: 34, weight: .bold)), .foregroundColor: UIColor.label]
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        #endif
    }
}

struct BrandWordmark: View {
    var body: some View {
        // Normalized window onto the original lettering. The source file is copied unchanged.
        GeometryReader { proxy in
            let full = proxy.size.width / 0.80
            Image("BrandWordmark").resizable().frame(width: full, height: full)
                .layerEffect(ShaderLibrary.kemoPlate(
                    .float2(Float(full),Float(full)), .float(0), .color(.white), .color(.white), .float(0),
                    .float4(1,0,0,0), .float4(0,0,0,0)
                ), maxSampleOffset: .zero)
                .offset(x: -full * 0.10, y: -full * 0.69)
        }.frame(width: 156, height: 21).clipped()
            .accessibilityLabel("KemoSabe")
    }
}

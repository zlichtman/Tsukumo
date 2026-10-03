import SwiftUI
import UIKit

/// The watch follows the iPhone. Its interface uses the dark variant of the iPhone's
/// app theme, because the watch is always dark, and Kemo uses the character palette.
/// Until the iPhone shares them, the watch uses the approved Apricot colors.
struct WatchStyle {
    var background: Color
    /// Fills the Talk button.
    var accent: Color
    /// The Talk button's label, black or white, whichever reads better on the accent.
    var onAccent: Color
    /// The accent, lightened where needed to stay readable as text or icons on the background.
    var readableAccent: Color

    init(_ theme: WatchLink.Theme?) {
        var background = theme.flatMap { KemoTint.RGB(hex: $0.background) } ?? KemoTint.RGB(r: 0x21 / 255, g: 0x1B / 255, b: 0x2C / 255)
        let accent = theme.flatMap { KemoTint.RGB(hex: $0.accent) } ?? KemoTint.RGB(r: 0xEF / 255, g: 0x70 / 255, b: 0x5B / 255)
        // Watch text is white, so a light custom background is darkened to keep it legible.
        let black = KemoTint.RGB(r: 0, g: 0, b: 0), white = KemoTint.RGB(r: 1, g: 1, b: 1)
        while background.luminance > 0.08 { background = background.mixed(with: black, 0.25) }
        var readable = accent
        while readable.contrast(with: background) < 3 { readable = readable.mixed(with: white, 0.25) }
        self.background = background.color
        self.accent = accent.color
        onAccent = accent.contrast(with: white) >= accent.contrast(with: black) ? .white : .black
        readableAccent = readable.color
    }
}

extension KemoTint.RGB {
    var color: Color { Color(.sRGB, red: Double(r), green: Double(g), blue: Double(b)) }
}

/// Kemo's frames in the iPhone's character palette, each recolored once per palette.
@MainActor enum KemoFrames {
    private static var palette: WatchLink.Palette?
    private static var images: [String: Image] = [:]

    static func image(_ name: String, palette: WatchLink.Palette?) -> Image {
        guard let palette, palette.tinted,
              let body = KemoTint.RGB(hex: palette.body), let accent = KemoTint.RGB(hex: palette.accent) else { return Image(name) }
        if self.palette != palette { self.palette = palette; images = [:] }
        if let image = images[name] { return image }
        guard let source = UIImage(named: name)?.cgImage,
              let tinted = KemoTint.recolored(source, body: body, accent: accent) else { return Image(name) }
        let image = Image(decorative: tinted, scale: 1)
        images[name] = image
        return image
    }
}

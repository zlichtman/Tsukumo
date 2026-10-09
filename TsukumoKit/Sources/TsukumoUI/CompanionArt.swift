import CoreGraphics
import Foundation
import SwiftUI
import TsukumoCore
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// KemoSabe's cloud (the look behind `KemoSabeLook.cloud`) in its companion palette, ported from the old KemoSabe app: its `kemoPlate` shader
// (legacy/ios/KemoSabe/KemoArtwork.metal) and the watch's CPU copy of it (`KemoTint`, in
// legacy/ios/KemoSabeWatch/KemoTint.swift). The artwork is painted in Apricot (cream with coral); each
// pixel keeps its light and shade and takes the palette's body color, or its accent where the paint is
// saturated coral. Props (the computer and keyboard while it reads) keep their cream keys and dark
// screen, and only their coral shell changes, as in the old app. Recolored pictures are cached per palette.

/// KemoSabe's artwork recolored to a companion palette.
public enum CompanionArt {
    /// A gamma-encoded sRGB color as the shader saw it.
    public struct Tint: Equatable, Sendable {
        public var r: Float, g: Float, b: Float
        public init(r: Float, g: Float, b: Float) { self.r = r; self.g = g; self.b = b }
        public init(hex: String) {
            let value = UInt32(BotTint.normalized(hex) ?? "000000", radix: 16) ?? 0
            r = Float((value >> 16) & 0xFF) / 255; g = Float((value >> 8) & 0xFF) / 255; b = Float(value & 0xFF) / 255
        }
    }

    /// Where a prop is drawn in the reading picture (`KemoSabeSearching.png`), in unit coordinates: its
    /// monitor and keyboard, minus the paws resting on the keys.
    static func isProp(x: Float, y: Float) -> Bool {
        func ellipse(_ cx: Float, _ cy: Float, _ rx: Float, _ ry: Float) -> Bool {
            let dx = (x - cx) / rx, dy = (y - cy) / ry
            return dx * dx + dy * dy <= 1
        }
        if ellipse(0.318, 0.765, 0.085, 0.072) || ellipse(0.485, 0.765, 0.082, 0.072) { return false }
        if y >= 0.775 { return true }
        // The monitor: a rounded rectangle.
        let (x0, y0, x1, y1, r): (Float, Float, Float, Float, Float) = (0.521, 0.524, 0.925, 0.87, 0.06)
        guard x >= x0, x <= x1, y >= y0, y <= y1 else { return false }
        let cx = min(max(x, x0 + r), x1 - r), cy = min(max(y, y0 + r), y1 - r)
        return (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r
    }

    /// Recolors premultiplied RGBA8 pixels in place. `prop` says which pixels belong to a prop.
    static func recolor(_ pixels: UnsafeMutableBufferPointer<UInt8>, width: Int, height: Int, bytesPerRow: Int,
                        body: Tint, accent: Tint, prop: ((Float, Float) -> Bool)?) {
        // The shader's reference cream, so Apricot maps to itself.
        let bodyR = body.r / 0.965, bodyG = body.g / 0.91, bodyB = body.b / 0.82
        for row in 0..<height {
            let y = (Float(row) + 0.5) / Float(height)
            for column in 0..<width {
                let i = row * bytesPerRow + column * 4
                let alpha = Float(pixels[i + 3]) / 255
                guard alpha > 0 else { continue }
                let scale = 1 / (255 * alpha)
                let r = min(1, Float(pixels[i]) * scale), g = min(1, Float(pixels[i + 1]) * scale), b = min(1, Float(pixels[i + 2]) * scale)
                let light = r / 0.97
                let out: (Float, Float, Float)
                if let prop, prop((Float(column) + 0.5) / Float(width), y) {
                    // A prop keeps its cream and dark parts; its coral shell (and the shell's highlights) takes the accent.
                    let coral = smoothstep(0.12, 0.30, r - g)
                    out = (r + (accent.r * light - r) * coral, g + (accent.g * light - g) * coral, b + (accent.b * light - b) * coral)
                } else {
                    // Saturated coral paint takes the accent; everything else takes the body color.
                    let coral = smoothstep(0.25, 0.43, r - g)
                    out = (r * bodyR + (accent.r * light - r * bodyR) * coral,
                           g * bodyG + (accent.g * light - g * bodyG) * coral,
                           b * bodyB + (accent.b * light - b * bodyB) * coral)
                }
                pixels[i] = channel(out.0, alpha); pixels[i + 1] = channel(out.1, alpha); pixels[i + 2] = channel(out.2, alpha)
            }
        }
    }

    /// A recolored copy of an Apricot picture, or nil if it can't be drawn. `maxSide` draws it smaller first.
    public static func recolored(_ image: CGImage, palette: BotPalette, props: Bool, maxSide: Int? = nil) -> CGImage? {
        let scale = maxSide.map { min(1, Double($0) / Double(max(image.width, image.height))) } ?? 1
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        if palette.id != BotPalette.all[0].id {
            // CGContext rows run top to bottom in memory, as the picture does.
            let pixels = UnsafeMutableBufferPointer<UInt8>(start: data.assumingMemoryBound(to: UInt8.self), count: context.bytesPerRow * height)
            let prop: ((Float, Float) -> Bool)? = props ? { x, y in isProp(x: x, y: y) } : nil
            recolor(pixels, width: width, height: height, bytesPerRow: context.bytesPerRow,
                    body: Tint(hex: palette.body), accent: Tint(hex: palette.accent), prop: prop)
        }
        return context.makeImage()
    }

    private static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }
    private static func channel(_ value: Float, _ alpha: Float) -> UInt8 {
        UInt8((min(1, max(0, value)) * alpha * 255).rounded())
    }

    // MARK: Cached pictures

    private static let cache = Cache()
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var images: [String: CGImage] = [:]
        private var sources: [String: CGImage] = [:]
        func image(_ key: String, make: () -> CGImage?) -> CGImage? {
            lock.lock(); defer { lock.unlock() }
            if let image = images[key] { return image }
            guard let made = make() else { return nil }
            images[key] = made
            return made
        }
        func source(_ name: TsukumoArt.Name) -> CGImage? {
            lock.lock(); defer { lock.unlock() }
            if let image = sources[name.rawValue] { return image }
            guard let url = TsukumoArt.url(name), let provider = CGDataProvider(url: url as CFURL),
                  let image = CGImage(pngDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
            sources[name.rawValue] = image
            return image
        }
    }

    /// KemoSabe resting (or at its computer while it reads) in `palette`. `small` draws a 240-pixel picture
    /// (tiles, avatars), which is quicker to make.
    public static func cgImage(searching: Bool = false, palette: BotPalette, small: Bool = false) -> CGImage? {
        let name: TsukumoArt.Name = searching ? .kemoSabeSearching : .kemoSabe
        guard let source = cache.source(name) else { return nil }
        if palette.id == BotPalette.all[0].id && !small { return source }
        return cache.image("\(name.rawValue)|\(palette.id)|\(small ? "s" : "l")") {
            recolored(source, palette: palette, props: searching, maxSide: small ? 240 : nil)
        }
    }

    /// The same, as a SwiftUI image.
    public static func image(searching: Bool = false, palette: BotPalette, small: Bool = false) -> Image {
        guard let cgImage = cgImage(searching: searching, palette: palette, small: small) else {
            return TsukumoArt.image(searching ? .kemoSabeSearching : .kemoSabe)
        }
        #if canImport(UIKit)
        return Image(uiImage: UIImage(cgImage: cgImage))
        #else
        return Image(nsImage: NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)))
        #endif
    }
}

// MARK: Palette tiles

/// A companion palette shown the way it looks: KemoSabe in those colors on the palette's own background,
/// with its name under it (ported from the old app's `CompanionPaletteTile`).
public struct CompanionPaletteTile: View {
    public let palette: BotPalette
    public let selected: Bool
    public var height: CGFloat
    public var look: KemoSabeLook
    public init(palette: BotPalette, selected: Bool, height: CGFloat = 96, look: KemoSabeLook = .standard) {
        self.palette = palette; self.selected = selected; self.height = height; self.look = look
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                LinearGradient(colors: [palette.backgroundRGB.color, palette.backgroundRGB.color.opacity(0.82)], startPoint: .top, endPoint: .bottom)
                KemoSabeFigure(palette: palette, shadow: false, look: look)
                    .frame(width: height * 0.86, height: height * 0.86)
                    .allowsHitTesting(false)
            }
            .frame(height: height).frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? palette.legibleAccentRGB.color : Color.primary.opacity(0.1), lineWidth: selected ? 2 : 0.5))
            HStack(spacing: 4) {
                Text(palette.name).font(.system(size: 12, weight: selected ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(palette.legibleAccentRGB.color) }
            }
            .foregroundStyle(.primary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(palette.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The companion palettes as a grid of tiles, KemoSabe in each (the old app's `CompanionPaletteGrid`,
/// without its search: there are twenty).
public struct CompanionPaletteGrid: View {
    public let selectedID: String
    public var minimum: CGFloat
    public var tileHeight: CGFloat
    /// The look the tiles show KemoSabe in.
    public var look: KemoSabeLook
    public let choose: (BotPalette) -> Void
    public init(selectedID: String, minimum: CGFloat = 96, tileHeight: CGFloat = 92, look: KemoSabeLook = .standard,
                choose: @escaping (BotPalette) -> Void) {
        self.selectedID = selectedID; self.minimum = minimum; self.tileHeight = tileHeight; self.look = look; self.choose = choose
    }
    /// The offered palettes, with a saved one that isn't offered any more (Blueberry) at the end.
    private var palettes: [BotPalette] {
        let shown = BotPalette.companion
        if shown.contains(where: { $0.id == selectedID }) { return shown }
        return shown + [BotPalette.named(selectedID)]
    }
    public var body: some View {
        FullRowsGrid(minimum: minimum, spacing: 12, rowSpacing: 14) {
            ForEach(palettes) { palette in
                Button { choose(palette) } label: {
                    CompanionPaletteTile(palette: palette, selected: palette.id == selectedID, height: tileHeight, look: look)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(palette.name)
                .accessibilityAddTraits(palette.id == selectedID ? .isSelected : [])
                .accessibilityIdentifier("kemoSabePalette-" + palette.id)
            }
        }
        .padding(2)
    }
}

/// A grid whose rows are all full: of the column counts that fit the width (tiles at least
/// `minimum` wide), it takes the widest one that divides the items evenly, as long as it's at least
/// two thirds of what fits; otherwise as many as fit. Twenty palettes: five columns on a Mac, four on
/// an iPhone, and never a half-empty last row.
struct FullRowsGrid: Layout {
    var minimum: CGFloat
    var spacing: CGFloat
    var rowSpacing: CGFloat

    static func columns(count: Int, fitting: Int) -> Int {
        let fit = max(1, fitting)
        guard count > fit else { return max(1, count) }
        let floor = max(2, Int((Double(fit) * 2 / 3).rounded(.up)))
        for candidate in stride(from: fit, through: floor, by: -1) where count % candidate == 0 { return candidate }
        return fit
    }

    private func metrics(width: CGFloat, count: Int) -> (columns: Int, tile: CGFloat) {
        let fitting = Int((width + spacing) / (minimum + spacing))
        let columns = Self.columns(count: count, fitting: fitting)
        let tile = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        return (columns, max(1, tile))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? (minimum + spacing) * 5
        let (columns, tile) = metrics(width: width, count: subviews.count)
        let rows = stride(from: 0, to: subviews.count, by: columns).map { start in
            subviews[start..<min(start + columns, subviews.count)].map { $0.sizeThatFits(.init(width: tile, height: nil)).height }.max() ?? 0
        }
        return CGSize(width: width, height: rows.reduce(0, +) + rowSpacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (columns, tile) = metrics(width: bounds.width, count: subviews.count)
        var y = bounds.minY
        for start in stride(from: 0, to: subviews.count, by: columns) {
            let row = subviews[start..<min(start + columns, subviews.count)]
            let height = row.map { $0.sizeThatFits(.init(width: tile, height: nil)).height }.max() ?? 0
            for (offset, subview) in row.enumerated() {
                let x = bounds.minX + CGFloat(offset) * (tile + spacing)
                subview.place(at: CGPoint(x: x, y: y), proposal: .init(width: tile, height: height))
            }
            y += height + rowSpacing
        }
    }
}


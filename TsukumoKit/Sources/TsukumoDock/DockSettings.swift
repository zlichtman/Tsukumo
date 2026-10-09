#if os(macOS)
import Foundation
import CoreGraphics

// How the side dock sits on the screen and looks (design/UI-GUIDE.md#the-side-dock), ported from the old
// Mac app's dock. It's meant to sit beside macOS's own Dock as if it belonged
// there, so its size and magnification start from the system Dock's (`com.apple.dock` tilesize,
// magnification, largesize), and the shelf uses the same Liquid Glass. Every choice is the owner's and is
// saved with the dock (`BotDockStore`).

/// The shelf's look.
public enum DockStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    case glass, tinted, solid, minimal
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .glass: "Glass"
        case .tinted: "Tinted glass"
        case .solid: "Solid"
        case .minimal: "Minimal"
        }
    }
}
/// Names beside a tile under the pointer.
public enum DockLabelStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    case glass, plain, off
    public var id: String { rawValue }
    public var title: String { self == .glass ? "Glass" : self == .plain ? "Plain" : "Off" }
}
/// Which bots are working or waiting on you.
public enum DockIndicator: String, CaseIterable, Codable, Sendable, Identifiable {
    case dot, ring, none
    public var id: String { rawValue }
    public var title: String { self == .dot ? "Dot" : self == .ring ? "Ring" : "None" }
}
/// How much the characters move.
public enum DockAnimationLevel: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Everything: loops, look-arounds, reactions.
    case lively
    /// Slower and smaller.
    case calm
    /// Poses only, as with Reduce Motion.
    case still
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

/// The dock's settings, saved with it.
public struct DockSettings: Codable, Equatable, Sendable {
    public enum Edge: String, CaseIterable, Codable, Sendable, Identifiable {
        case right, left
        public var id: String { rawValue }
        public var title: String { rawValue.capitalized }
    }
    public enum Position: String, CaseIterable, Codable, Sendable, Identifiable {
        case top, center, bottom
        public var id: String { rawValue }
        public var title: String { rawValue.capitalized }
    }
    public static let sizeRange: ClosedRange<Double> = 32...80
    public static let magnifiedRange: ClosedRange<Double> = 40...128
    public static let delayRange: ClosedRange<Double> = 0...2
    public static let spacingRange: ClosedRange<Double> = 0.04...0.3
    public static let cornersRange: ClosedRange<Double> = 0.15...0.5
    public static let delayChoices: [(String, Double)] = [("None", 0), ("Short", 0.4), ("Medium", 0.7), ("Long", 1.5)]

    public var edge: Edge = .right
    public var position: Position = .center
    /// A tile's size in points, like the Dock's icon size.
    public var size: Double = 48
    public var magnification = false
    /// A tile's size under the pointer when magnification is on.
    public var magnifiedSize: Double = 72
    /// Tucks away to a sliver until the pointer reaches the edge.
    public var autohide = true
    /// Seconds after the pointer leaves before it tucks away.
    public var autohideDelay: Double = 0.7
    public var animation: DockAnimationLevel = .lively
    /// Liquid Glass, glass tinted with the accent, a solid color, or no shelf.
    public var style: DockStyle = .glass
    /// Space between tiles, as a fraction of a tile.
    public var spacing: Double = 0.1
    /// The shelf's corners, as a fraction of its thickness (0.5 is fully round).
    public var corners: Double = 0.4
    /// The line before + and Together, like the one before the Trash.
    public var separators = true
    public var labels: DockLabelStyle = .glass
    public var indicator: DockIndicator = .dot
    /// A thin ring in the engine's color at a bot's feet (default), its mark, or nothing.
    /// Characters sleep at night (11 pm to 7 am) while they have nothing to do.
    public var sleepAtNight = true
    /// A soft sound when a bot chirps in.
    public var chirpSounds = false
    /// The shelf's color ("RRGGBB"), or nil for Automatic: the glass as it is, Tsukumo's coral for Tinted
    /// glass, the window color for Solid. It tints every style: the glass lightly, Tinted glass more, Solid
    /// fills with it, and in every style (Minimal too) it colors the sliver at the edge and the working
    /// indicators.
    public var tint: String?
    /// The editor a coding bot's project opens in, following each file its agent edits (its bundle ID), or nil for none.
    public var followEditor: String?

    /// The color row in Settings, Dock, after Automatic.
    public static let tintSwatches: [(name: String, hex: String)] = [
        ("Coral", "EF705B"), ("Amber", "E9A23B"), ("Sage", "7FA87A"), ("Teal", "3A9E98"), ("Sky", "4F8FD6"),
        ("Iris", "7467D4"), ("Rose", "D9668F"), ("Graphite", "5D5B66"), ("Midnight", "23263A")
    ]

    public init() {}

    public var namesOnHover: Bool {
        get { labels != .off }
        set { labels = newValue ? (labels == .off ? .glass : labels) : .off }
    }

    /// The defaults for a new dock: the system Dock's size and magnification, when it says.
    public static func matchingSystemDock(_ dock: UserDefaults? = UserDefaults(suiteName: "com.apple.dock")) -> DockSettings {
        var settings = DockSettings()
        if let dock {
            if let size = dock.object(forKey: "tilesize") as? Double, size > 0 { settings.size = size }
            if let on = dock.object(forKey: "magnification") as? Bool { settings.magnification = on }
            if let large = dock.object(forKey: "largesize") as? Double, large > 0 { settings.magnifiedSize = large }
        }
        return settings.clamped()
    }

    /// Every value brought into its range.
    public func clamped() -> DockSettings {
        var copy = self
        copy.spacing = min(Self.spacingRange.upperBound, max(Self.spacingRange.lowerBound, spacing))
        copy.corners = min(Self.cornersRange.upperBound, max(Self.cornersRange.lowerBound, corners))
        copy.size = min(Self.sizeRange.upperBound, max(Self.sizeRange.lowerBound, size.rounded()))
        copy.magnifiedSize = min(Self.magnifiedRange.upperBound, max(copy.size + 8, magnifiedSize.rounded()))
        copy.autohideDelay = min(Self.delayRange.upperBound, max(Self.delayRange.lowerBound, autohideDelay))
        if let tint = copy.tint {
            let digits = tint.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).uppercased()
            copy.tint = digits.count == 6 && UInt32(digits, radix: 16) != nil ? digits : nil
        }
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case edge, position, size, magnification, magnifiedSize, autohide, autohideDelay, animation, style, spacing, corners
        case separators, labels, indicator, sleepAtNight, chirpSounds, tint, followEditor
    }
    /// Settings saved by a newer build keep loading; anything missing takes its default. (An older file's
    /// "home", where the bots lived, is ignored: the Tsukumo app is always the side dock.)
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DockSettings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        edge = value(.edge, d.edge)
        position = value(.position, d.position)
        size = value(.size, d.size)
        magnification = value(.magnification, d.magnification)
        magnifiedSize = value(.magnifiedSize, d.magnifiedSize)
        autohide = value(.autohide, d.autohide)
        autohideDelay = value(.autohideDelay, d.autohideDelay)
        animation = value(.animation, d.animation)
        style = value(.style, d.style)
        spacing = value(.spacing, d.spacing)
        corners = value(.corners, d.corners)
        separators = value(.separators, d.separators)
        labels = value(.labels, d.labels)
        indicator = value(.indicator, d.indicator)
        sleepAtNight = value(.sleepAtNight, d.sleepAtNight)
        chirpSounds = value(.chirpSounds, d.chirpSounds)
        tint = (try? c.decodeIfPresent(String.self, forKey: .tint)) ?? nil
        followEditor = (try? c.decodeIfPresent(String.self, forKey: .followEditor)) ?? nil
        self = clamped()
    }
}

// MARK: Layout

/// Where the dock's shelf, tiles, bubble, and speech bubbles go for the owner's settings, in screen
/// coordinates (origin bottom left, as AppKit's). Pure, so each edge and position is tested directly.
public struct DockLayout: Equatable, Sendable {
    public let settings: DockSettings
    /// Every tile: the bots, then Together and Settings (always last).
    public let tiles: Int
    /// The screen's visible frame.
    public let screen: CGRect

    public static let screenMargin: CGFloat = 6
    public static let separatorGap: CGFloat = 12
    public static let labelSpace: CGFloat = 170
    public static let sliver: CGFloat = 4

    public init(settings: DockSettings, tiles: Int, screen: CGRect) {
        self.settings = settings; self.tiles = max(1, tiles); self.screen = screen
    }

    public var size: CGFloat { CGFloat(settings.size) }
    public var padding: CGFloat { (size * 0.14).rounded() }
    public var spacing: CGFloat { (size * CGFloat(settings.spacing)).rounded() }
    /// The shelf's thickness and its corners, like the Dock's.
    public var thickness: CGFloat { size + padding * 2 }
    public var cornerRadius: CGFloat { (thickness * CGFloat(settings.corners)).rounded() }
    public var length: CGFloat { padding * 2 + CGFloat(tiles) * size + CGFloat(max(0, tiles - 1)) * spacing + Self.separatorGap }
    /// How far a magnified tile reaches past the shelf.
    public var reach: CGFloat { settings.magnification ? CGFloat(settings.magnifiedSize) - size : 0 }
    public var inwardSpace: CGFloat { reach + (settings.namesOnHover ? Self.labelSpace : 0) }

    /// The shelf, on screen.
    public var shelf: CGRect {
        let x = settings.edge == .right ? screen.maxX - Self.screenMargin - thickness : screen.minX + Self.screenMargin
        let y: CGFloat
        switch settings.position {
        case .top: y = screen.maxY - Self.screenMargin - length - reach
        case .center: y = screen.midY - length / 2
        case .bottom: y = screen.minY + Self.screenMargin + reach
        }
        return CGRect(x: x, y: y, width: thickness, height: length)
    }
    /// The panel while the dock is out: the shelf, room for magnified tiles, and names beside them.
    public var revealedFrame: CGRect {
        let s = shelf
        let x = settings.edge == .right ? s.minX - inwardSpace : s.minX - Self.screenMargin
        return CGRect(x: x, y: s.minY - reach, width: s.width + inwardSpace + Self.screenMargin, height: s.height + reach * 2)
    }
    /// The panel while tucked away: a sliver against the edge, as long as the shelf.
    public var tuckedFrame: CGRect {
        let s = shelf, width = Self.sliver + 6
        let x = settings.edge == .right ? screen.maxX - width : screen.minX
        return CGRect(x: x, y: s.minY, width: width, height: s.height)
    }
    /// The shelf inside the revealed panel (top-left origin, as SwiftUI draws it).
    public var shelfInPanel: CGRect {
        let panel = revealedFrame, s = shelf
        return CGRect(x: s.minX - panel.minX, y: panel.maxY - s.maxY, width: s.width, height: s.height)
    }
    /// A tile's center along the shelf, from the shelf's top. The separator sits before + and Together.
    public func tileOffset(_ index: Int) -> CGFloat {
        let separator: CGFloat = index >= tiles - 2 ? Self.separatorGap : 0
        return padding + CGFloat(index) * (size + spacing) + size / 2 + separator
    }
    /// A tile's center on screen.
    public func tileCenter(_ index: Int) -> CGPoint { CGPoint(x: shelf.midX, y: shelf.maxY - tileOffset(index)) }
    /// A bubble beside a tile, on the screen side away from the edge, kept on screen.
    public func bubbleFrame(forTile index: Int, size bubble: CGSize) -> CGRect {
        let center = tileCenter(index), s = shelf
        let x = settings.edge == .right ? s.minX - reach - 8 - bubble.width : s.maxX + reach + 8
        var y = center.y - bubble.height / 2
        y = min(max(y, screen.minY + 8), screen.maxY - bubble.height - 8)
        return CGRect(x: x, y: y, width: bubble.width, height: bubble.height)
    }
    /// A speech bubble from a tile: its tail level with the tile.
    public func calloutFrame(forTile index: Int, size callout: CGSize) -> CGRect {
        let center = tileCenter(index), s = shelf
        let x = settings.edge == .right ? s.minX - callout.width - 2 : s.maxX + 2
        return CGRect(x: x, y: center.y - callout.height + 26, width: callout.width, height: callout.height)
    }

    /// The Dock's magnification: full at the pointer, fading to none about two tiles away.
    public static func magnification(distance: CGFloat, size: CGFloat, magnified: CGFloat) -> CGFloat {
        guard magnified > size else { return 1 }
        let range = size * 2.2
        guard distance < range else { return 1 }
        return 1 + (magnified / size - 1) * cos(distance / range * .pi / 2)
    }
}

/// The panels beside the dock.
public enum DockMetrics {
    public static let bubble = CGSize(width: 400, height: 520)
    public static let panel = CGSize(width: 420, height: 600)
    public static let callout = CGSize(width: 262, height: 80)
    public static func size(for surface: DockSurface?) -> CGSize {
        if case .panel? = surface { return panel }
        if case .addBot? = surface { return panel }
        return bubble
    }
}
#endif

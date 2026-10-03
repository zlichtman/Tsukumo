import Foundation

// A bot's clay character, without any drawing (TsukumoUI and TsukumoDock draw it). Ported from the
// dock's `DockLook` and the add-bot logic in the stopped dock branch (`BotMaking.swift`).

/// A bot's character: a body shape, a palette with the owner's own colors in place of any of its
/// colors, eyes and an expression, a topper, an accessory, a prop, and how it sits in the Mac's dock
/// (its size and ring).
///
/// KemoSabe's character is always its cloud: `normalizedForKemoSabe()` keeps only its color
/// (`accentColor`), so a synced or decoded KemoSabe can never carry another look.
public struct BotLook: Codable, Hashable, Sendable {
    public enum Shape: String, CaseIterable, Codable, Sendable, Identifiable {
        case bean, gumdrop, block, mochi, sprout, pebble
        public var id: String { rawValue }
        public var title: String { rawValue.capitalized }
    }
    public enum Eyes: String, CaseIterable, Codable, Sendable, Identifiable {
        case dots, ovals, sparkle, visor
        public var id: String { rawValue }
        public var title: String { rawValue.capitalized }
    }
    /// Something on its head that makes its silhouette its own.
    public enum Topper: String, CaseIterable, Codable, Sendable, Identifiable {
        case none, ears, roundEars, antenna, tuft, leaf
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .none: "Nothing"
            case .ears: "Pointy ears"
            case .roundEars: "Round ears"
            case .antenna: "Antenna"
            case .tuft: "Tuft"
            case .leaf: "Leaf"
            }
        }
    }
    public enum Prop: String, CaseIterable, Codable, Sendable, Identifiable {
        case none, pencil, hardHat, glasses, wrench, headset, paintbrush, book, antenna
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .none: "Nothing"
            case .hardHat: "Hard hat"
            default: rawValue.capitalized
            }
        }
    }
    /// Its face at rest (a state's own face, talking or asleep, wins while it lasts).
    public enum Expression: String, CaseIterable, Codable, Sendable, Identifiable {
        case smile, grin, calm, smirk, wow, focused
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .smile: "Smile"
            case .grin: "Big grin"
            case .calm: "Calm"
            case .smirk: "Smirk"
            case .wow: "Wow"
            case .focused: "Focused"
            }
        }
    }
    /// Something it wears, from the clay family.
    public enum Accessory: String, CaseIterable, Codable, Sendable, Identifiable {
        case none, bowTie, scarf, necklace, flower, badge
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .none: "Nothing"
            case .bowTie: "Bow tie"
            case .scarf: "Scarf"
            case .necklace: "Necklace"
            case .flower: "Flower"
            case .badge: "Badge"
            }
        }
    }
    /// The thin ring at its feet in the Mac's dock.
    public enum Ring: String, CaseIterable, Codable, Sendable, Identifiable {
        /// The color of what runs it, when the dock shows engines as rings.
        case engine
        /// `ringColor`, always.
        case custom
        /// No ring.
        case hidden
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .engine: "Engine color"
            case .custom: "My color"
            case .hidden: "No ring"
            }
        }
    }

    /// How big it may sit in the dock, against the dock's tile size.
    public static let scaleRange: ClosedRange<Double> = 0.8...1.25

    public var shape: Shape
    /// A palette ID from `BotPalette.all`.
    public var palette: String
    public var eyes: Eyes
    public var prop: Prop
    public var topper: Topper
    /// Its body color as hex ("F5E7CF") in place of the palette's; nil is the palette's.
    public var bodyColor: String?
    /// Its accent (cheeks, ears, antenna, the dots it thinks with) as hex; nil is the palette's. For
    /// KemoSabe, its one color: its card, ring, and buttons in the chat.
    public var accentColor: String?
    public var expression: Expression
    public var accessory: Accessory
    /// Rosy cheeks.
    public var blush: Bool
    /// Its size in the dock (`scaleRange`).
    public var scale: Double
    public var ring: Ring
    /// The ring's color as hex, when `ring` is `.custom`.
    public var ringColor: String?

    public init(shape: Shape, palette: String, eyes: Eyes, prop: Prop = .none, topper: Topper = .none,
                bodyColor: String? = nil, accentColor: String? = nil, expression: Expression = .smile, accessory: Accessory = .none,
                blush: Bool = true, scale: Double = 1, ring: Ring = .engine, ringColor: String? = nil) {
        self.shape = shape; self.palette = palette; self.eyes = eyes; self.prop = prop; self.topper = topper
        self.bodyColor = bodyColor; self.accentColor = accentColor; self.expression = expression; self.accessory = accessory
        self.blush = blush; self.scale = scale; self.ring = ring; self.ringColor = ringColor
    }

    /// KemoSabe's own look: its cloud, in coral.
    public static let kemoSabe = BotLook(shape: .bean, palette: "apricot", eyes: .dots)
    /// KemoSabe's look in its own color (any valid hex; `BotTint.kemoSabe` are the ones offered).
    public static func kemoSabe(tint: String?) -> BotLook {
        var look = kemoSabe
        look.accentColor = tint.flatMap(BotTint.normalized)
        return look
    }
    /// This look as KemoSabe may have it: the standard cloud, keeping only its color.
    public func normalizedForKemoSabe() -> BotLook { .kemoSabe(tint: accentColor) }

    /// A clean copy: colors that aren't hex are dropped and the dock size is kept in range.
    public func normalized() -> BotLook {
        var copy = self
        copy.bodyColor = bodyColor.flatMap(BotTint.normalized)
        copy.accentColor = accentColor.flatMap(BotTint.normalized)
        copy.ringColor = ringColor.flatMap(BotTint.normalized)
        copy.scale = scale.isFinite ? min(Self.scaleRange.upperBound, max(Self.scaleRange.lowerBound, scale)) : 1
        if copy.ring == .custom && copy.ringColor == nil { copy.ring = .engine }
        return copy
    }

    /// The colors it's drawn with: the palette's, with the owner's own in place of any.
    public var bodyHex: String { bodyColor ?? BotPalette.named(palette).body }
    public var accentHex: String { accentColor ?? BotPalette.named(palette).accent }
    public var inkHex: String { BotPalette.named(palette).background }

    /// Changes whenever the drawing would (for caches of baked pictures). The dock size and ring
    /// aren't drawn into the character, so they aren't in it.
    public var drawingKey: String {
        [shape.rawValue, palette, eyes.rawValue, prop.rawValue, topper.rawValue, bodyColor ?? "-", accentColor ?? "-",
         expression.rawValue, accessory.rawValue, blush ? "blush" : "plain"].joined(separator: "|")
    }

    private enum CodingKeys: String, CodingKey {
        case shape, palette, eyes, prop, topper, bodyColor, accentColor, expression, accessory, blush, scale, ring, ringColor
    }
    /// A part a newer build added falls back to a plain one, so the bot still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func raw<T: RawRepresentable>(_ key: CodingKeys, _ fallback: T) -> T where T.RawValue == String {
            (try? c.decodeIfPresent(String.self, forKey: key)).flatMap { $0.flatMap(T.init(rawValue:)) } ?? fallback
        }
        func text(_ key: CodingKeys) -> String? { (try? c.decodeIfPresent(String.self, forKey: key)).flatMap { $0 } }
        shape = raw(.shape, Shape.bean)
        palette = text(.palette) ?? BotPalette.all[0].id
        eyes = raw(.eyes, Eyes.dots)
        prop = raw(.prop, Prop.none)
        topper = raw(.topper, Topper.none)
        bodyColor = text(.bodyColor)
        accentColor = text(.accentColor)
        expression = raw(.expression, Expression.smile)
        accessory = raw(.accessory, Accessory.none)
        blush = (try? c.decodeIfPresent(Bool.self, forKey: .blush)).flatMap { $0 } ?? true
        scale = (try? c.decodeIfPresent(Double.self, forKey: .scale)).flatMap { $0 } ?? 1
        ring = raw(.ring, Ring.engine)
        ringColor = text(.ringColor)
        self = normalized()
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(shape, forKey: .shape)
        try c.encode(palette, forKey: .palette)
        try c.encode(eyes, forKey: .eyes)
        try c.encode(prop, forKey: .prop)
        try c.encode(topper, forKey: .topper)
        try c.encodeIfPresent(bodyColor, forKey: .bodyColor)
        try c.encodeIfPresent(accentColor, forKey: .accentColor)
        try c.encode(expression, forKey: .expression)
        try c.encode(accessory, forKey: .accessory)
        try c.encode(blush, forKey: .blush)
        try c.encode(scale, forKey: .scale)
        try c.encode(ring, forKey: .ring)
        try c.encodeIfPresent(ringColor, forKey: .ringColor)
    }

    /// Two bots look alike when their shape and palette match: the rest is too small to tell apart.
    public func sameCharacter(as other: BotLook) -> Bool { shape == other.shape && palette == other.palette }

    /// A random character unlike every one in `taken`: a shape, palette, and topper no other bot has
    /// while there are some left, eyes at random, and a prop that suits its starter.
    public static func random(for starter: BotStarter = .custom, taken: [BotLook], using rng: inout some RandomNumberGenerator) -> BotLook {
        func fresh<T: Hashable>(_ all: [T], used: [T]) -> [T] {
            let free = all.filter { !used.contains($0) }
            return free.isEmpty ? all : free
        }
        let bright = BotPalette.bright.map(\.id)
        for _ in 0..<64 {
            let shape = fresh(Shape.allCases, used: taken.map(\.shape)).randomElement(using: &rng) ?? .bean
            let palette = fresh(bright, used: taken.map(\.palette)).randomElement(using: &rng) ?? bright[0]
            let prop = starter.props.randomElement(using: &rng) ?? .none
            var toppers: [Topper] = [.ears, .roundEars, .antenna, .tuft, .leaf, .none]
            if prop == .headset { toppers.removeAll { $0 == .ears || $0 == .roundEars } }
            if prop == .antenna { toppers.removeAll { $0 == .antenna } }
            let topper: Topper = prop == .hardHat ? .none : fresh(toppers, used: taken.map(\.topper)).randomElement(using: &rng) ?? .none
            let eyes: Eyes = prop == .hardHat ? .visor : [Eyes.dots, .ovals, .sparkle].randomElement(using: &rng) ?? .dots
            let look = BotLook(shape: shape, palette: palette, eyes: eyes, prop: prop, topper: topper)
            if !taken.contains(where: { $0.sameCharacter(as: look) }) { return look }
        }
        // Every quick pick collided (a very full dock): walk the combinations for one that's free.
        for shape in Shape.allCases {
            for palette in BotPalette.all.map(\.id) {
                let look = BotLook(shape: shape, palette: palette, eyes: .dots)
                if !taken.contains(where: { $0.sameCharacter(as: look) }) { return look }
            }
        }
        return BotLook(shape: .bean, palette: bright[0], eyes: .dots)
    }

    /// Rerolls the character (a new shape, palette, eyes, topper, and prop) and keeps what the owner
    /// set by hand: their colors, expression, accessory, cheeks, and dock size and ring.
    public func rerolled(for starter: BotStarter = .custom, taken: [BotLook], using rng: inout some RandomNumberGenerator) -> BotLook {
        var next = BotLook.random(for: starter, taken: taken + [self], using: &rng)
        next.bodyColor = bodyColor; next.accentColor = accentColor; next.expression = expression; next.accessory = accessory
        next.blush = blush; next.scale = scale; next.ring = ring; next.ringColor = ringColor
        return next
    }

    /// A character for a bot from what its name and job say it does: a prop for its job (homework and
    /// class get a pencil, code a hard hat with a visor, research glasses, design a paintbrush, ops a
    /// wrench, calls a headset, writing a book), and a shape, palette, and topper no other bot has while
    /// some are left (never KemoSabe's own palette or the quiet grays). The same words give the same
    /// character, so a form's preview doesn't jump while the owner types.
    public static func suggested(name: String, job: String, taken: [BotLook] = []) -> BotLook {
        let words = (name + " " + job).lowercased()
        func has(_ keys: [String]) -> Bool { keys.contains { words.contains($0) } }
        let prop: Prop =
            has(["homework", "class", "study", "school", "exam", "essay", "notes", "deadline"]) ? .pencil :
            has(["code", "coder", "dev", "app", "bug", "build", "engineer", "ios", "swift"]) ? .hardHat :
            has(["research", "paper", "read", "thesis", "learn"]) ? .glasses :
            has(["site", "web", "design", "art", "draw", "logo"]) ? .paintbrush :
            has(["fix", "repair", "ops", "server", "deploy", "infra"]) ? .wrench :
            has(["music", "podcast", "call", "meeting", "voice", "support"]) ? .headset :
            has(["book", "writing", "writer", "journal", "story", "blog"]) ? .book : .none
        var seed = UInt64(5381)
        for byte in name.lowercased().utf8 { seed = seed &* 33 &+ UInt64(byte) }
        let shapes = Shape.allCases, eyes: [Eyes] = [.dots, .ovals, .sparkle]
        let usedPalettes = Set(taken.map(\.palette)), usedShapes = Set(taken.map(\.shape))
        let bright = BotPalette.bright.map(\.id)
        let freePalettes = bright.filter { !usedPalettes.contains($0) }
        let palettes = freePalettes.isEmpty ? bright : freePalettes
        let freeShapes = shapes.filter { !usedShapes.contains($0) }
        let shapePool = freeShapes.isEmpty ? shapes : freeShapes
        var toppers: [Topper] = [.ears, .roundEars, .antenna, .tuft, .leaf]
        if prop == .headset { toppers.removeAll { $0 == .ears || $0 == .roundEars } }
        let usedToppers = Set(taken.map(\.topper))
        let freeToppers = toppers.filter { !usedToppers.contains($0) }
        let topperPool = freeToppers.isEmpty ? toppers : freeToppers
        return BotLook(shape: shapePool[Int(seed % UInt64(shapePool.count))],
                       palette: palettes[Int((seed / 7) % UInt64(palettes.count))],
                       eyes: prop == .hardHat ? .visor : eyes[Int((seed / 13) % UInt64(eyes.count))],
                       prop: prop,
                       topper: prop == .hardHat ? .none : topperPool[Int((seed / 17) % UInt64(topperPool.count))])
    }
}

/// A named color to pick from: KemoSabe's colors, and the custom colors any other bot can wear.
/// Stock names never use another company's name.
public struct BotTint: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// Six hex digits, uppercase ("EF705B").
    public let hex: String

    /// KemoSabe's colors: coral (its own) first.
    public static let kemoSabe: [BotTint] = [
        .init(id: "coral", name: "Coral", hex: "EF705B"),
        .init(id: "tangerine", name: "Tangerine", hex: "F08A3C"),
        .init(id: "honey", name: "Honey", hex: "D9A23A"),
        .init(id: "sage", name: "Sage", hex: "6E9B6A"),
        .init(id: "teal", name: "Teal", hex: "2F8F8B"),
        .init(id: "sky", name: "Sky", hex: "3F86C6"),
        .init(id: "iris", name: "Iris", hex: "6F63C9"),
        .init(id: "plum", name: "Plum", hex: "9A4F96"),
        .init(id: "rose", name: "Rose", hex: "D45C86"),
        .init(id: "slate", name: "Slate", hex: "66707E")
    ]
    /// Colors for a bot's body, accent, or ring, beside its palette's own.
    public static let custom: [BotTint] = kemoSabe + [
        .init(id: "cream", name: "Cream", hex: "F5E7CF"),
        .init(id: "mint", name: "Mint", hex: "BFE8D3"),
        .init(id: "lilac", name: "Lilac", hex: "DCCFF3"),
        .init(id: "blush", name: "Blush", hex: "F6CFD6"),
        .init(id: "lemon", name: "Lemon", hex: "F7E79B"),
        .init(id: "ice", name: "Ice", hex: "D3E6F5"),
        .init(id: "charcoal", name: "Charcoal", hex: "3B3F47"),
        .init(id: "snow", name: "Snow", hex: "F7F5F1")
    ]

    /// Six hex digits, uppercase, or nil when `value` isn't a color ("#ef705b" becomes "EF705B").
    public static func normalized(_ value: String) -> String? {
        let digits = value.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespacesAndNewlines)).uppercased()
        guard digits.count == 6, digits.allSatisfy({ $0.isHexDigit }) else { return nil }
        return digits
    }
    /// The named color with this hex, if it's one of `custom`.
    public static func named(hex: String?) -> BotTint? {
        guard let hex = hex.flatMap(normalized) else { return nil }
        return custom.first { $0.hex == hex }
    }
}

/// A character palette: body, accent, and background colors as hex. Stock names never use another
/// company's name.
public struct BotPalette: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let body: String
    public let accent: String
    public let background: String

    public static let all: [BotPalette] = [
        .init(id: "apricot", name: "Apricot", body: "F5E7CF", accent: "EF705B", background: "211B2C"),
        .init(id: "matcha", name: "Matcha", body: "DCD89A", accent: "6E7238", background: "282A1B"),
        .init(id: "lavender", name: "Lavender", body: "E2D9F5", accent: "8563BD", background: "252039"),
        .init(id: "rose", name: "Rose", body: "F5D7DD", accent: "B74F76", background: "311E29"),
        .init(id: "sky", name: "Sky", body: "D0E7F4", accent: "397AA4", background: "192938"),
        .init(id: "cocoa", name: "Cocoa", body: "E5CCAD", accent: "815036", background: "2A211E"),
        .init(id: "butter", name: "Butter", body: "F5E5A6", accent: "B47B35", background: "2A251C"),
        .init(id: "pistachio", name: "Pistachio", body: "CBECD2", accent: "2E7355", background: "17372E"),
        .init(id: "peach", name: "Peach", body: "F3D0B8", accent: "C96956", background: "302022"),
        .init(id: "blueberry", name: "Blueberry", body: "D4D8F2", accent: "7873B6", background: "202138"),
        .init(id: "porcelain", name: "Porcelain", body: "F0ECE5", accent: "8091A2", background: "232930"),
        .init(id: "moss", name: "Moss", body: "91AD94", accent: "344C3F", background: "182622"),
        .init(id: "midnight", name: "Midnight", body: "BFCBDC", accent: "6D87AC", background: "141D2C"),
        .init(id: "cherry", name: "Cherry", body: "EDC8CC", accent: "AE435C", background: "2B1923"),
        .init(id: "graphite", name: "Graphite", body: "D5D3CF", accent: "66656D", background: "202024"),
        .init(id: "aurora", name: "Aurora", body: "CBEAE1", accent: "8276AE", background: "1D2533"),
        .init(id: "ember", name: "Ember", body: "F0A678", accent: "913E49", background: "301D23"),
        .init(id: "lagoon", name: "Lagoon", body: "A7DCD8", accent: "235D70", background: "112B34"),
        .init(id: "mulberry", name: "Mulberry", body: "CFA3CA", accent: "663C6B", background: "2F1D33"),
        .init(id: "ink", name: "Ink", body: "7685B6", accent: "FFF0CF", background: "121827"),
        .init(id: "paper", name: "Paper", body: "EEECE2", accent: "353D4C", background: "1A202B")
    ]
    /// The palettes a new bot may get at random: never KemoSabe's own or the quiet grays.
    public static let bright: [BotPalette] = all.filter { !["apricot", "graphite", "porcelain", "paper", "midnight", "ink"].contains($0.id) }
    /// A palette by ID, or KemoSabe's when it's unknown.
    public static func named(_ id: String) -> BotPalette { all.first { $0.id == id } ?? all[0] }
}

/// A random number generator that can be seeded, for tests and previews (SplitMix64).
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public init() { state = UInt64.random(in: 1...UInt64.max) }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Fun, original names for new bots: none is a product, a company, or a well-known assistant.
public enum BotNames {
    public static let pool = [
        "Pip", "Bramble", "Tofu", "Pickle", "Nimbus", "Sprocket", "Biscuit", "Fennel", "Juniper", "Waffles",
        "Noodle", "Marzipan", "Clover", "Puddle", "Zephyr", "Doodle", "Quill", "Basil", "Toffee", "Wobble",
        "Ziggy", "Momo", "Sunny", "Kiwi", "Taro", "Miso", "Nugget", "Fizz", "Button", "Scout",
        "Skipper", "Dumpling", "Pretzel", "Maple", "Olive", "Peanut", "Tumble", "Hopper", "Whisk", "Gizmo",
        "Bumble", "Crumpet", "Dewdrop", "Figgy", "Jellybean", "Lentil", "Mallow", "Nutmeg", "Parsnip", "Radish"
    ]
    /// A name no bot has (ignoring case), at random; once they're all taken, one with a number.
    public static func next(taken: [String], using rng: inout some RandomNumberGenerator) -> String {
        let used = Set(taken.map { $0.lowercased() })
        let free = pool.filter { !used.contains($0.lowercased()) }
        if let name = free.randomElement(using: &rng) { return name }
        let base = pool.randomElement(using: &rng) ?? "Bot"
        var number = 2
        while used.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }
}

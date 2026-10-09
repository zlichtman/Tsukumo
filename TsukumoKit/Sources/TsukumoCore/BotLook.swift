import Foundation

// What a bot looks like, without any drawing (TsukumoUI and TsukumoDock draw it). KemoSabe has a look of its own:
// its figure (its cloud, or the two-tone figure) in a companion palette. A bot on Codex may wear one of the owner's Codex
// pets (`pet`; OpenAI's characters stay on OpenAI's product, `BotSpec.wearsCodexPets`); any bot may wear one of
// Tsukumo's own characters (`tsukumo:<id>`, shipped in TsukumoUI); every other bot wears its service's mark. The clay characters of the old apps (shapes, eyes, toppers,
// props, the owner's colors, dock sizes and rings) are gone; a file written before still loads, and those parts are
// ignored.

/// KemoSabe's figure, its owner's pick (`BotLook.figure`): `.cloud` is its own companion cloud, the standard;
/// `.finder` is the two-tone figure with a blue half and a white half.
public enum KemoSabeLook: String, CaseIterable, Identifiable, Sendable {
    /// KemoSabe's own cloud, the default.
    case cloud
    /// The two-tone figure.
    case finder
    public var id: String { rawValue }
    /// KemoSabe's look until its owner picks one (`BotLook.figure`): its cloud.
    public static let standard: KemoSabeLook = .cloud
    /// The palette KemoSabe starts in with this look: Apricot (cream and coral) or Classic (white and blue).
    public var defaultPalette: String { self == .finder ? "classic" : "apricot" }
    /// Its name in the character picker. The figure is named for what it is (the owner, October 8, 2026: "it's the
    /// Finder icon"), the one exception to AGENTS.md rule 8.
    public var title: String { self == .cloud ? "KemoSabe" : "Finder" }
}

/// What a bot looks like: KemoSabe's companion palette (one of `BotPalette.all`) and figure, or another bot's pet.
/// `normalizedForKemoSabe()` keeps only the palette and figure, so a synced or decoded KemoSabe can never carry
/// another look.
public struct BotLook: Codable, Hashable, Sendable {
    /// The most a pet's small picture may weigh (it syncs with the bot).
    public static let maxPetImage = 48 * 1024
    /// A palette ID from `BotPalette.all`. For KemoSabe, its companion palette.
    public var palette: String
    /// The palette's accent, kept beside it so an older build that knew only KemoSabe's accent color still
    /// shows about the same color. Nil for Apricot.
    public var accentColor: String?
    /// KemoSabe's figure, when its owner picked one; nil is the standard look (its cloud). It syncs with the palette.
    public var figure: KemoSabeLook?
    /// Another bot's character: a Codex pet's ID ("seedy", or "custom:<folder>" for one the owner hatched), drawn
    /// from the owner's own Codex on a Mac. Nil wears its service's mark.
    public var pet: String?
    /// The pet's name, for a device that can't read the owner's Codex.
    public var petName: String?
    /// A small still picture of the pet (PNG), so a device without the owner's Codex still shows it.
    public var petImage: Data?

    public init(palette: String = KemoSabeLook.standard.defaultPalette, accentColor: String? = nil, figure: KemoSabeLook? = nil,
                pet: String? = nil, petName: String? = nil, petImage: Data? = nil) {
        self.palette = palette; self.accentColor = accentColor; self.figure = figure
        self.pet = pet; self.petName = petName; self.petImage = petImage
    }
    /// A bot wearing a pet.
    /// Whether a pet id is one of Tsukumo's own characters, which any bot may wear.
    public static func isTsukumoCharacter(_ id: String?) -> Bool { id?.hasPrefix("tsukumo:") ?? false }

    public static func pet(_ id: String, name: String?, image: Data?) -> BotLook {
        BotLook(pet: id, petName: name, petImage: image).normalized()
    }

    /// KemoSabe's own look, in the palette its look starts with.
    public static let kemoSabe = BotLook.kemoSabe(palette: KemoSabeLook.standard.defaultPalette)
    /// KemoSabe in one of its companion palettes (`BotPalette.all`; an unknown ID is Apricot), and its figure.
    public static func kemoSabe(palette id: String, figure: KemoSabeLook? = nil) -> BotLook {
        let palette = BotPalette.named(id)
        return BotLook(palette: palette.id, accentColor: palette.id == "apricot" ? nil : palette.accent, figure: figure)
    }
    /// This look as KemoSabe may have it: its companion palette and figure. A look saved when KemoSabe had only an
    /// accent color (an older build, another device) takes the palette nearest that color.
    public func normalizedForKemoSabe() -> BotLook {
        .kemoSabe(palette: BotPalette.companion(palette: palette, accent: accentColor).id, figure: figure)
    }
    /// The figure KemoSabe shows.
    public var kemoSabeFigure: KemoSabeLook { figure ?? .standard }

    /// A clean copy: an accent that isn't hex is dropped, and a pet's ID, name, and picture are bounded (a picture
    /// that's too big, or isn't a PNG, is dropped; the pet still shows where its Codex is).
    public func normalized() -> BotLook {
        let id = pet?.trimmingCharacters(in: .whitespacesAndNewlines)
        let keptPet = id.flatMap { !$0.isEmpty && $0.count <= 120 && !$0.contains("/") && !$0.contains("..") ? $0 : nil }
        let name = petName?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)
        let image = petImage.flatMap { $0.count <= Self.maxPetImage && $0.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? $0 : nil }
        return BotLook(palette: palette, accentColor: accentColor.flatMap(BotTint.normalized), figure: figure,
                       pet: keptPet, petName: keptPet == nil ? nil : name.map(String.init).flatMap { $0.isEmpty ? nil : $0 },
                       petImage: keptPet == nil ? nil : image)
    }

    private enum CodingKeys: String, CodingKey { case palette, accentColor, figure, pet, petName, petImage }
    /// The palette, its accent, the figure, and the pet are read (a figure a newer build added is the standard look); the clay
    /// parts an older build wrote are ignored.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        palette = (try? c.decodeIfPresent(String.self, forKey: .palette)).flatMap { $0 } ?? BotPalette.all[0].id
        accentColor = (try? c.decodeIfPresent(String.self, forKey: .accentColor)).flatMap { $0 }
        figure = (try? c.decodeIfPresent(String.self, forKey: .figure)).flatMap { $0 }.flatMap(KemoSabeLook.init(rawValue:))
        pet = (try? c.decodeIfPresent(String.self, forKey: .pet)).flatMap { $0 }
        petName = (try? c.decodeIfPresent(String.self, forKey: .petName)).flatMap { $0 }
        petImage = (try? c.decodeIfPresent(Data.self, forKey: .petImage)).flatMap { $0 }
        self = normalized()
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(palette, forKey: .palette)
        try c.encodeIfPresent(accentColor, forKey: .accentColor)
        try c.encodeIfPresent(figure?.rawValue, forKey: .figure)
        try c.encodeIfPresent(pet, forKey: .pet)
        try c.encodeIfPresent(petName, forKey: .petName)
        try c.encodeIfPresent(petImage, forKey: .petImage)
    }
}

/// A named color. Only KemoSabe's ten old accent colors are left: a KemoSabe saved with one takes the palette
/// `BotPalette.forAccent` maps it to. Stock names never use another company's name.
public struct BotTint: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// Six hex digits, uppercase ("EF705B").
    public let hex: String

    /// The ten accent colors KemoSabe had before it had palettes (coral, its own, first).
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

    /// Six hex digits, uppercase, or nil when `value` isn't a color ("#ef705b" becomes "EF705B").
    public static func normalized(_ value: String) -> String? {
        let digits = value.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespacesAndNewlines)).uppercased()
        guard digits.count == 6, digits.allSatisfy({ $0.isHexDigit }) else { return nil }
        return digits
    }
}

/// One of KemoSabe's companion palettes: body, accent, and background colors as hex. On the two-tone look the
/// body is its light half and the accent its dark half; on the cloud, its body and its coral paint. Stock names
/// never use another company's name.
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
        .init(id: "paper", name: "Paper", body: "EEECE2", accent: "353D4C", background: "1A202B"),
        // The two-tone look's own colors: a white half and a blue half (October 7, 2026).
        .init(id: "classic", name: "Classic", body: "F6F8FB", accent: "2F7DF6", background: "14243D")
    ]
    /// A palette by ID, or Apricot when it's unknown.
    public static func named(_ id: String) -> BotPalette { all.first { $0.id == id } ?? all[0] }

    // MARK: KemoSabe's companion palettes (the old KemoSabe app's `BotTheme` presets and `ThemeShelf`)

    /// The palettes KemoSabe's editor offers: each look's own palette first (Apricot for the cloud, Classic for the
    /// two-tone look), then the old app's featured eight, then the rest. Blueberry isn't offered (as in the old app)
    /// but stays valid for a KemoSabe saved with it.
    public static let companion: [BotPalette] = {
        let featured = ["apricot", "classic", "matcha", "lavender", "sky", "rose", "aurora", "cocoa", "graphite"]
        return featured.map(named) + all.filter { !featured.contains($0.id) && $0.id != "blueberry" }
    }()

    /// Where each of KemoSabe's ten old accent colors goes.
    static let legacyTints: [String: String] = [
        "EF705B": "apricot",   // Coral
        "F08A3C": "peach",     // Tangerine
        "D9A23A": "butter",    // Honey
        "6E9B6A": "pistachio", // Sage
        "2F8F8B": "lagoon",    // Teal
        "3F86C6": "sky",       // Sky
        "6F63C9": "lavender",  // Iris
        "9A4F96": "mulberry",  // Plum
        "D45C86": "rose",      // Rose
        "66707E": "graphite"   // Slate
    ]

    /// The companion palette for an accent color: the palette with exactly that accent, the one an old
    /// KemoSabe color maps to, else the offered palette whose accent is nearest.
    public static func forAccent(_ hex: String) -> BotPalette {
        guard let hex = BotTint.normalized(hex) else { return all[0] }
        if let exact = all.first(where: { $0.accent == hex }) { return exact }
        if let id = legacyTints[hex] { return named(id) }
        func rgb(_ value: String) -> (Double, Double, Double) {
            let n = UInt32(value, radix: 16) ?? 0
            return (Double((n >> 16) & 255), Double((n >> 8) & 255), Double(n & 255))
        }
        let target = rgb(hex)
        func distance(_ palette: BotPalette) -> Double {
            let c = rgb(palette.accent)
            // Weighted RGB ("redmean"), close enough to how far apart two colors look.
            let r = (target.0 + c.0) / 2, dr = target.0 - c.0, dg = target.1 - c.1, db = target.2 - c.2
            return (2 + r / 256) * dr * dr + 4 * dg * dg + (2 + (255 - r) / 256) * db * db
        }
        return companion.min { distance($0) < distance($1) } ?? all[0]
    }

    /// KemoSabe's palette from a saved look: its palette, unless an accent color that isn't that palette's
    /// says it was saved with an old accent color (then the palette for that color).
    public static func companion(palette id: String, accent: String?) -> BotPalette {
        let known = all.first { $0.id == id }
        guard let accent = accent.flatMap(BotTint.normalized) else { return known ?? all[0] }
        if let known, known.accent == accent { return known }
        return forAccent(accent)
    }
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

import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import TsukumoCore
import UniformTypeIdentifiers

// The owner's Codex pets, read where Codex keeps them and drawn animated (October 8, 2026). The built-in pets ship
// inside the ChatGPT app (and Codex.app, when it's there) as sprite sheets in its Electron archive
// (`Contents/Resources/app.asar`, at `webview/assets/<id>-spritesheet-v<N>-<hash>.webp`); only the archive's header
// is read, then each sheet by its offset, never the whole file. Pets the owner hatched with Codex's `hatch-pet`
// skill live in CODEX_HOME (`pets/<slug>/pet.json` and `avatars/<slug>/avatar.json`), each beside its sheet. A sheet
// is 8 columns of 192 x 208 cells, 9 rows (version 1, 1536 x 1872) or 11 (version 2, 1536 x 2288); each row is one
// animation, timed as Codex times it (`PetAnimation`). The owner's ChatGPT "dot", an always-on cloud agent that wears
// a pet, is read from Codex's global state, those few fields only (`CodexPets.primaryDot`). Finding pets reads the
// owner's folders, so it's macOS only; the model, the sheets, and `CodexPetView` work on both. Every failure is
// nil or empty: a pet that can't be read is left out, and a view that can't draw its pet draws nothing.

/// A Codex pet: a built-in one (`seedy`) or one the owner hatched (`custom:<slug>`).
public struct CodexPet: Identifiable, Hashable, Sendable {
    /// "seedy", or "custom:<slug>".
    public let id: String
    /// "Seedy", or the hatched pet's own name.
    public let name: String
    /// One line about it; may be empty.
    public let description: String
    /// 1 (9 rows) or 2 (11 rows).
    public let spriteVersion: Int
    /// Where its sheet is.
    let sheet: SheetSource

    /// One the owner hatched with Codex.
    public var isCustom: Bool { id.hasPrefix("custom:") }
    /// One of Tsukumo's own characters, which any bot may wear.
    public var isTsukumo: Bool { BotLook.isTsukumoCharacter(id) }
}

/// Where a pet's sheet is: a span of an asar archive, or a file of its own (as last modified, so an edited sheet
/// is read again).
enum SheetSource: Hashable, Sendable {
    case archive(URL, offset: UInt64, size: Int)
    case file(URL, modified: Date?)
}

/// The owner's ChatGPT dot: its always-on cloud agent and the pet it wears.
public struct CodexDot: Hashable, Sendable {
    /// Its thread in Codex.
    public let threadID: String
    public let aeonID: String?
    /// Whether it's reachable now.
    public let available: Bool
    /// "Leafy"
    public let name: String
    /// "active"
    public let status: String?
    /// The pet it wears: a built-in id ("seedy"), or a cloud one (`pet_…`) that can't be drawn here, so the view
    /// falls back.
    public let petID: String?

    /// Opens its thread in Codex.
    public var link: URL? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        guard let thread = threadID.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "codex://threads/" + thread)
    }
}

/// What a pet acts out: one row of its sheet each, timed as the Codex app times it. Codex plays the others three
/// times and settles back to idle; in the dock they loop while the state lasts.
public enum PetAnimation: String, CaseIterable, Sendable {
    case idle, runningRight, runningLeft, waving, jumping, failed, waiting, running, review

    /// Its row on the sheet.
    public var row: Int { timing.row }
    public var frameCount: Int { durations.count }
    /// Each frame's time on screen, in milliseconds.
    public var durations: [Int] {
        // Idle is slow breathing: Codex's idle timings, six times as long.
        if self == .idle { return [280, 110, 110, 140, 140, 320].map { $0 * 6 } }
        return Array(repeating: timing.ms, count: timing.frames - 1) + [timing.last]
    }

    private var timing: (row: Int, frames: Int, ms: Int, last: Int) {
        switch self {
        case .idle: (0, 6, 0, 0)
        case .runningRight: (1, 8, 120, 220)
        case .runningLeft: (2, 8, 120, 220)
        case .waving: (3, 4, 140, 280)
        case .jumping: (4, 5, 140, 280)
        case .failed: (5, 8, 140, 240)
        case .waiting: (6, 6, 150, 260)
        case .running: (7, 6, 120, 220)
        case .review: (8, 6, 150, 280)
        }
    }

    /// The frame showing `elapsed` seconds in, looping.
    public func frame(at elapsed: TimeInterval) -> Int {
        let cycle = durations.reduce(0, +)
        var t = Int((max(0, elapsed) * 1000).rounded(.down)) % cycle
        for (index, duration) in durations.enumerated() {
            if t < duration { return index }
            t -= duration
        }
        return 0
    }

    /// How often a view needs to look: the largest step every frame lasts a whole number of, and never more often
    /// than 30 times a second (so a resting pet redraws about 16 times a second, not 30).
    var tick: TimeInterval {
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        return max(1.0 / 30, Double(durations.reduce(0, gcd)) / 1000)
    }

    /// What a tile's state looks like on a pet. Thinking is review (reading over the work); talking and chirping
    /// wave, since the pet is turned to the owner and speaking up, which reads apart from thinking's head-down
    /// review; sleeping is idle held still (`CodexPetView`).
    public init(_ state: BotState) {
        switch state {
        case .idle, .sleeping: self = .idle
        case .working: self = .running
        case .thinking: self = .review
        case .talking, .chirping: self = .waving
        case .needsYou: self = .waiting
        case .done: self = .jumping
        }
    }
}

/// Finding the owner's Codex pets, and their sheets, frames, and small pictures.
public enum CodexPets {
    /// A cell's size on every sheet.
    public static let cellWidth = 192, cellHeight = 208, columns = 8

    /// The sheet's size for a sprite version, or nil for a version that doesn't exist.
    static func sheetSize(version: Int) -> (width: Int, height: Int)? {
        switch version {
        case 1: (1536, 1872)
        case 2: (1536, 2288)
        default: nil
        }
    }
    static func version(width: Int, height: Int) -> Int? {
        [1, 2].first { version in sheetSize(version: version).map { $0 == (width, height) } ?? false }
    }

    /// The built-in pets the Codex app names, in its order.
    static let builtIn: [(id: String, name: String, description: String)] = [
        ("codex", "Codex", "The original Codex companion."),
        ("dewey", "Dewey", "A calm companion for focused workspace days"),
        ("fireball", "Fireball", "Hot path energy for fast iteration."),
        ("hoots", "Hoots", "A sharp-eyed owl for polished work in a blink."),
        ("rocky", "Rocky", "A steady rock when the diff gets large."),
        ("seedy", "Seedy", "Small green shoots for new ideas."),
        ("stacky", "Stacky", "A balanced stack for deep work."),
        ("bsod", "BSOD", "A tiny blue-screen gremlin."),
        ("null-signal", "Null Signal", "Quiet signal from the void.")
    ]

    /// Tsukumo's own characters, hatched for Tsukumo with Codex's `hatch-pet` skill and shipped in the app
    /// (`Resources/Character-<slug>.webp`, ART-NOTICE.txt). Any bot may wear one, on any device.
    public static let tsukumo: [CodexPet] = [
        ("lobster", "Lobster", "A bright red lobster with big friendly claws."),
        ("brain", "Brain", "A thoughtful pink brain with little arms and legs."),
        ("octopus", "Octopus", "A playful purple octopus juggling with its eight tentacles."),
        ("fox", "Fox", "A clever orange fox with a big fluffy tail."),
        ("cat", "Cat", "A sleek black cat with bright green eyes."),
        ("penguin", "Penguin", "A round friendly penguin wearing a tiny scarf."),
        ("frog", "Frog", "A cheerful green frog with a bright friendly smile.")
    ].compactMap { slug, name, description in
        guard let url = Bundle.module.url(forResource: "Character-" + slug, withExtension: "webp") else { return nil }
        return CodexPet(id: "tsukumo:" + slug, name: name, description: description, spriteVersion: 2, sheet: .file(url, modified: nil))
    }

    // MARK: Sheets and frames

    /// The pet's whole sheet, decoded (cached; a few at a time).
    public static func sheet(for pet: CodexPet) -> CGImage? {
        cache.sheet(pet.sheet) {
            guard let data = bytes(pet.sheet), let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                  let size = sheetSize(version: pet.spriteVersion), image.width == size.width, image.height == size.height else { return nil }
            return image
        }
    }

    /// Whether the pet's sheet loads; otherwise the caller draws something else.
    public static func canDraw(_ pet: CodexPet) -> Bool { sheet(for: pet) != nil }

    /// One cell: frame `index` of `animation`.
    public static func frame(_ pet: CodexPet, animation: PetAnimation, index: Int) -> CGImage? {
        guard index >= 0, index < animation.frameCount, let sheet = sheet(for: pet) else { return nil }
        return sheet.cropping(to: CGRect(x: index * cellWidth, y: animation.row * cellHeight, width: cellWidth, height: cellHeight))
    }

    /// The pet at rest (idle's first frame) trimmed to what's drawn and centered in a `side`-pixel square, as PNG
    /// (small avatars).
    public static func avatarPNG(_ pet: CodexPet, side: Int) -> Data? {
        guard side > 0, side <= 2048 else { return nil }
        return cache.avatar(pet.sheet, side: side) {
            guard let cell = frame(pet, animation: .idle, index: 0), let bounds = visibleBounds(cell), let trimmed = cell.cropping(to: bounds),
                  let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            let scale = Double(side) / Double(max(trimmed.width, trimmed.height))
            let width = Double(trimmed.width) * scale, height = Double(trimmed.height) * scale
            context.interpolationQuality = .high
            context.draw(trimmed, in: CGRect(x: (Double(side) - width) / 2, y: (Double(side) - height) / 2, width: width, height: height))
            guard let image = context.makeImage() else { return nil }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            return CGImageDestinationFinalize(destination) ? data as Data : nil
        }
    }

    /// The rectangle of a picture's pixels that aren't (nearly) transparent, in its own top-left coordinates.
    static func visibleBounds(_ image: CGImage) -> CGRect? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 8 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    // MARK: Hatching

    /// Opens a new Codex thread asking its `hatch-pet` skill for a pet, named and described when they're given.
    /// The description is shortened to keep the link under 500 characters.
    public static func hatchLink(name: String? = nil, description: String? = nil) -> URL {
        func clean(_ text: String?) -> String {
            (text ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        var name = String(clean(name).prefix(60))
        var description = clean(description)
        // Unreserved characters only, so "$", "&", "+", and "=" in the prompt survive the query.
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func link() -> String {
            let ask = name.isEmpty ? "Hatch me a new pet" + (description.isEmpty ? "" : ": " + description)
                : "Hatch a pet named " + name + (description.isEmpty ? "" : ": " + description)
            return "codex://threads/new?prompt=" + ("$hatch-pet " + ask).addingPercentEncoding(withAllowedCharacters: unreserved)!
        }
        var text = link()
        while text.count > 500, !(description.isEmpty && name.isEmpty) {
            let over = max(1, (text.count - 500) / 9)
            if description.isEmpty { name = String(name.dropLast(over)) } else { description = String(description.dropLast(over)) }
            text = link()
        }
        return URL(string: text)!
    }

    // MARK: Reading bytes

    /// `count` bytes at `offset` (fewer at the end of the file), or nil.
    static func read(_ url: URL, at offset: UInt64, count: Int) -> Data? {
        guard count > 0, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.read(upToCount: count) else { return nil }
        return data
    }

    /// A sheet's bytes (up to 64 MB).
    static func bytes(_ source: SheetSource) -> Data? {
        let limit = 64 << 20
        switch source {
        case .archive(let url, let offset, let size):
            guard size <= limit, let data = read(url, at: offset, count: size), data.count == size else { return nil }
            return data
        case .file(let url, _):
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= limit else { return nil }
            return try? Data(contentsOf: url)
        }
    }

    /// A PNG's or WebP's pixel size from its first 30 bytes, without decoding it.
    static func imageSize(_ header: Data) -> (width: Int, height: Int)? {
        let b = [UInt8](header.prefix(30))
        func le(_ at: Int, _ count: Int) -> Int { (0..<count).reduce(0) { $0 | Int(b[at + $1]) << (8 * $1) } }
        func be(_ at: Int) -> Int { (0..<4).reduce(0) { $0 << 8 | Int(b[at + $1]) } }
        func tag(_ at: Int) -> String { String(decoding: b[at..<at + 4], as: UTF8.self) }
        if b.count >= 24, b[0..<8].elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return (be(16), be(20))
        }
        guard b.count >= 30, tag(0) == "RIFF", tag(8) == "WEBP" else { return nil }
        switch tag(12) {
        case "VP8 ": return (le(26, 2) & 0x3FFF, le(28, 2) & 0x3FFF)
        case "VP8L":
            guard b[20] == 0x2F else { return nil }
            let bits = le(21, 4)
            return ((bits & 0x3FFF) + 1, (bits >> 14 & 0x3FFF) + 1)
        case "VP8X": return (le(24, 3) + 1, le(27, 3) + 1)
        default: return nil
        }
    }

    // MARK: The cache

    static let cache = Cache()
    final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        /// Decoded sheets, newest last; a sheet is 14 MB, so only a few stay.
        private var sheets: [(SheetSource, CGImage)] = []
        private var unreadable: Set<SheetSource> = []
        private var avatars: [String: Data] = [:]
        private var archives: [String: [ArchiveSheet]] = [:]
        static let keptSheets = 4

        func sheet(_ source: SheetSource, make: () -> CGImage?) -> CGImage? {
            lock.lock(); defer { lock.unlock() }
            if let index = sheets.firstIndex(where: { $0.0 == source }) {
                let kept = sheets.remove(at: index)
                sheets.append(kept)
                return kept.1
            }
            guard !unreadable.contains(source) else { return nil }
            guard let made = make() else { unreadable.insert(source); return nil }
            sheets.append((source, made))
            if sheets.count > Self.keptSheets { sheets.removeFirst() }
            return made
        }
        func avatar(_ source: SheetSource, side: Int, make: () -> Data?) -> Data? {
            let key = "\(source)|\(side)"
            lock.lock()
            if let data = avatars[key] { lock.unlock(); return data }
            lock.unlock()
            guard let made = make() else { return nil }
            lock.lock(); avatars[key] = made; lock.unlock()
            return made
        }
        func archive(_ key: String, make: () -> [ArchiveSheet]) -> [ArchiveSheet] {
            lock.lock(); defer { lock.unlock() }
            if let sheets = archives[key] { return sheets }
            let made = make()
            archives[key] = made
            return made
        }
    }

    /// A built-in pet's sheet found in an archive, with its size.
    struct ArchiveSheet: Sendable {
        let id: String, version: Int, source: SheetSource, width: Int, height: Int
    }
}

#if os(macOS)
public extension CodexPets {
    /// CODEX_HOME, else `~/.codex`.
    static var defaultHome: URL {
        if let path = ProcessInfo.processInfo.environment["CODEX_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }
    /// The apps that carry the built-in pets, first one first.
    static let defaultApps = [URL(fileURLWithPath: "/Applications/ChatGPT.app"), URL(fileURLWithPath: "/Applications/Codex.app")]

    /// Every pet that can be drawn: the built-in ones in the Codex app's order (any it adds later after them, by
    /// id), then the owner's own, newest first.
    static func installed(home: URL = defaultHome, apps: [URL] = defaultApps) -> [CodexPet] {
        var builtIns: [String: CodexPet] = [:]
        for app in apps {
            for sheet in archiveSheets(app.appendingPathComponent("Contents/Resources/app.asar")) where builtIns[sheet.id] == nil {
                guard let spriteVersion = version(width: sheet.width, height: sheet.height) else { continue }
                let known = builtIn.first { $0.id == sheet.id }
                builtIns[sheet.id] = CodexPet(id: sheet.id, name: known?.name ?? titled(sheet.id), description: known?.description ?? "",
                                              spriteVersion: spriteVersion, sheet: sheet.source)
            }
        }
        let order = builtIn.map(\.id)
        let sorted = builtIns.values.sorted { a, b in
            switch (order.firstIndex(of: a.id), order.firstIndex(of: b.id)) {
            case let (i?, j?): i < j
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): a.id < b.id
            }
        }
        return sorted + custom(home: home)
    }

    /// The pet with this id, if it's installed.
    static func pet(id: String, home: URL = defaultHome, apps: [URL] = defaultApps) -> CodexPet? {
        installed(home: home, apps: apps).first { $0.id == id }
    }

    /// The owner's ChatGPT dot, from Codex's global state; only its thread, name, status, and pet are read.
    static func primaryDot(home: URL = defaultHome) -> CodexDot? {
        let url = home.appendingPathComponent(".codex-global-state.json")
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 64 << 20,
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let atoms = root["electron-persisted-atom-state"] as? [String: Any],
              let primary = atoms["primary-aeon-selection-v1"] as? [String: Any],
              let response = primary["response"] as? [String: Any],
              let selection = response["selection"] as? [String: Any],
              let profile = response["profile"] as? [String: Any],
              let thread = selection["thread_id"] as? String, !thread.isEmpty,
              let name = profile["display_name"] as? String, !name.isEmpty else { return nil }
        let wearsPet = (profile["avatar_type"] as? String).map { $0 == "codex-pet" } ?? true
        let pet = wearsPet ? ((profile["avatar_manifest"] as? [String: Any])?["pet_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } : nil
        return CodexDot(threadID: thread, aeonID: selection["aeon_id"] as? String, available: selection["available"] as? Bool ?? false,
                        name: name, status: profile["status"] as? String, petID: pet)
    }
}

extension CodexPets {
    /// "null-signal" as "Null Signal".
    static func titled(_ id: String) -> String {
        id.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// The pet sheets in an asar archive (the newest version of each id), read from its header alone and kept
    /// while the archive's size and date stay the same.
    static func archiveSheets(_ asar: URL) -> [ArchiveSheet] {
        guard let values = try? asar.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]), let fileSize = values.fileSize else { return [] }
        let key = "\(asar.path)|\(fileSize)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        return cache.archive(key) { readArchiveSheets(asar) }
    }

    /// An asar archive: 4, the header pickle's size S, the pickle's payload size, the JSON's length J, J bytes of
    /// JSON (the folder tree), and the files' bytes from 8 + S on, each at its node's decimal `offset`.
    static func readArchiveSheets(_ asar: URL) -> [ArchiveSheet] {
        guard let prefix = read(asar, at: 0, count: 16), prefix.count == 16 else { return [] }
        let words = (0..<4).map { i in (0..<4).reduce(0) { $0 | Int(prefix[i * 4 + $1]) << (8 * $1) } }
        let (pickleSize, jsonLength) = (words[1], words[3])
        guard words[0] == 4, jsonLength > 0, jsonLength <= pickleSize - 8, pickleSize <= 64 << 20,
              let json = read(asar, at: 16, count: jsonLength), json.count == jsonLength,
              let tree = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return [] }
        var folder: [String: Any]? = tree
        for name in ["webview", "assets"] {
            folder = ((folder?["files"] as? [String: Any])?[name] as? [String: Any])
        }
        guard let files = folder?["files"] as? [String: Any] else { return [] }
        let base = UInt64(8 + pickleSize)
        let pattern = /^([a-z0-9][a-z0-9_-]*)-spritesheet-v([0-9]+)-[0-9A-Za-z]+\.webp$/
        var newest: [String: (version: Int, source: SheetSource)] = [:]
        for (name, node) in files {
            guard let match = name.wholeMatch(of: pattern), let version = Int(match.2), let node = node as? [String: Any],
                  let size = node["size"] as? Int, size > 0 else { continue }
            let id = String(match.1)
            if let kept = newest[id], kept.version >= version { continue }
            if node["unpacked"] as? Bool == true {
                let file = URL(fileURLWithPath: asar.path + ".unpacked").appendingPathComponent("webview/assets/" + name)
                newest[id] = (version, .file(file, modified: nil))
            } else if let offset = (node["offset"] as? String).flatMap(UInt64.init) {
                newest[id] = (version, .archive(asar, offset: base + offset, size: size))
            }
        }
        return newest.compactMap { id, entry in
            guard let size = headerSize(entry.source) else { return nil }
            return ArchiveSheet(id: id, version: entry.version, source: entry.source, width: size.width, height: size.height)
        }
    }

    /// A sheet's pixel size from its first bytes.
    static func headerSize(_ source: SheetSource) -> (width: Int, height: Int)? {
        switch source {
        case .archive(let url, let offset, _): read(url, at: offset, count: 30).flatMap(imageSize)
        case .file(let url, _): read(url, at: 0, count: 30).flatMap(imageSize)
        }
    }

    /// The owner's hatched pets: `pets/<slug>/pet.json`, then `avatars/<slug>/avatar.json` for slugs not already
    /// found, newest first. A sheet must be inside its pet's folder and the size its version says.
    static func custom(home: URL) -> [CodexPet] {
        let files = FileManager.default
        var found: [(pet: CodexPet, made: Date)] = []
        for (folderName, manifestName) in [("pets", "pet.json"), ("avatars", "avatar.json")] {
            let root = home.appendingPathComponent(folderName, isDirectory: true)
            for slug in (try? files.contentsOfDirectory(atPath: root.path)) ?? [] where !slug.hasPrefix(".") {
                guard !found.contains(where: { $0.pet.id == "custom:" + slug }) else { continue }
                let folder = root.appendingPathComponent(slug, isDirectory: true)
                let manifest = folder.appendingPathComponent(manifestName)
                guard let data = try? Data(contentsOf: manifest), data.count <= 1 << 20,
                      let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let version = fields["spriteVersionNumber"] == nil ? 1 : (fields["spriteVersionNumber"] as? Int ?? 0)
                let path = fields["spritesheetPath"] == nil ? "spritesheet.webp" : (fields["spritesheetPath"] as? String ?? "")
                guard let expected = sheetSize(version: version), let sheet = contained(path, in: folder),
                      let size = headerSize(.file(sheet, modified: nil)), size == expected else { continue }
                let modified = (try? sheet.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                let name = [fields["displayName"], fields["id"]].compactMap { ($0 as? String).flatMap { $0.isEmpty ? nil : $0 } }.first ?? slug
                let pet = CodexPet(id: "custom:" + slug, name: name, description: fields["description"] as? String ?? "",
                                   spriteVersion: version, sheet: .file(sheet, modified: modified))
                let made = (try? manifest.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                found.append((pet, made))
            }
        }
        return found.sorted { $0.made != $1.made ? $0.made > $1.made : $0.pet.name < $1.pet.name }.map(\.pet)
    }

    /// `path` inside `folder`, symlinks resolved, or nil if it's absolute, climbs out, or leads out through a link.
    static func contained(_ path: String, in folder: URL) -> URL? {
        let parts = path.split(separator: "/")
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"), !parts.contains(".."), !parts.isEmpty else { return nil }
        let base = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = folder.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(base + "/") else { return nil }
        return resolved
    }
}
#endif

// MARK: The view

/// A Codex pet acting out a tile's state, one cell of its sheet at a time on a periodic clock (still under Reduce
/// Motion, while asleep, or with `still`: the animation's first frame). Draws nothing when the sheet can't be read;
/// check `CodexPets.canDraw(_:)` to pick something else.
public struct CodexPetView: View {
    public var pet: CodexPet
    public var state: BotState
    public var still: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date.now

    public init(pet: CodexPet, state: BotState = .idle, still: Bool = false) {
        self.pet = pet; self.state = state; self.still = still
    }

    public var body: some View {
        let animation = PetAnimation(state)
        Group {
            if still || reduceMotion || state == .sleeping || !CodexPets.canDraw(pet) {
                cell(animation, 0)
            } else {
                TimelineView(.periodic(from: start, by: animation.tick)) { context in
                    cell(animation, animation.frame(at: context.date.timeIntervalSince(start)))
                }
            }
        }
        .onChange(of: state) { start = .now }
        .accessibilityElement()
        .accessibilityLabel(state.label.isEmpty ? pet.name : pet.name + ", " + state.label.lowercased())
    }

    @ViewBuilder private func cell(_ animation: PetAnimation, _ index: Int) -> some View {
        if let image = CodexPets.frame(pet, animation: animation, index: index) {
            Image(decorative: image, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
        } else {
            Color.clear
        }
    }
}

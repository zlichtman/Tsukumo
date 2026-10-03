import AVFoundation
import ImageIO
import Foundation
import Observation
import SwiftUI
import UIKit

/// Your one profile, arranged by you: a cover and picture, name, handle, headline, and bio, then
/// blocks you choose, order, style, and hide (Photos, Music, Work, Writing, Personal, Links, and
/// your companion's watch game). Filled by importing your own export, from your music library's
/// real play counts, or by hand. Stored on this iPhone with complete file protection, outside the
/// model's context. See design/PROFILE-REDESIGN.md.
struct SocialProfile: Codable, Equatable {
    var name = ""
    var handle = ""
    var bio = ""
    /// A line about what you do, as on LinkedIn ("iOS engineer at Kemo").
    var headline: String?
    /// Your profile picture, its own file and not a post; nil shows your initials.
    var picture: String?
    /// Profiles before September 25 used a post as the picture; it moves out of your posts into
    /// its own file the first time the profile opens.
    var avatar: UUID?
    /// The wide cover behind your picture, as on LinkedIn; nil shows your accent's colors.
    var banner: String?
    /// Featured slots from before September 25; no longer shown, and kept so nothing is lost.
    var featured: [UUID?] = Array(repeating: nil, count: SocialProfile.featuredSlots)
    var media: [ProfileMedia] = []
    /// Music you picked by hand (a song on repeat, a favorite album or song).
    var songs: [ProfileSong] = []
    var links: [ProfileLink] = []
    var experience: [WorkEntry] = []
    var education: [EducationEntry] = []
    var skills: [String] = []
    /// Licenses and certifications, as on LinkedIn.
    var certifications: [CertificationEntry] = []
    /// Languages and how well you speak them, as on LinkedIn.
    var languages: [LanguageEntry] = []
    /// The About at the top of Work, as on LinkedIn (separate from your bio).
    var about: String?
    var interests: [String] = []
    /// Short facts you choose to show, like hometown or languages.
    var facts: [ProfileFact] = []
    var blog: ProfileBlog?
    /// Your blocks, in the order they show, each with its style and whether it's hidden.
    var blocks: [ProfileBlock] = ProfileBlockKind.defaultLayout
    /// Your profile's accent color ("#RRGGBB"); nil follows the app theme.
    var accent: String?
    /// The post pinned to the top of Photos.
    var pinned: UUID?
    /// Listening stats computed on this iPhone from your music library; nil until you connect it.
    var musicStats: MusicStats?
    /// Sections hidden before blocks (September 25, 2026). Kept in step with `blocks` so an older
    /// build still hides the same things.
    var hiddenSections: [ProfileSection] = []
    /// Posts brought in from an export, by where they came from ("instagram:media/posts/…"),
    /// so importing the same export again skips them.
    var importedSources: [String: UUID] = [:]
    /// The headline and summary from a LinkedIn import, offered until you use or dismiss them.
    var linkedInIntro: ImportedIntro?
    static let featuredSlots = 6
    static let maxBio = 500, maxAbout = 2600
    static let maxExperience = 50, maxEducation = 20, maxSkills = 60, maxInterests = 40, maxFacts = 12
    static let maxCertifications = 30, maxLanguages = 12

    func block(_ kind: ProfileBlockKind) -> ProfileBlock { blocks.first { $0.kind == kind } ?? ProfileBlock(kind: kind) }
    func shows(_ kind: ProfileBlockKind) -> Bool { !block(kind).hidden }
    func style(_ kind: ProfileBlockKind) -> ProfileBlockStyle { block(kind).style ?? kind.defaultStyle }
    /// Who can see a block once you share your profile: Only you until you choose.
    func audience(_ kind: ProfileBlockKind) -> ProfileAudience { block(kind).audience ?? .onlyYou }
    /// Posts in the order they show: the pinned one first, then newest first by the day taken.
    var orderedMedia: [ProfileMedia] {
        let sorted = media.sorted { $0.day > $1.day }
        guard let pinned, let first = sorted.first(where: { $0.id == pinned }) else { return sorted }
        return [first] + sorted.filter { $0.id != pinned }
    }

    /// Handles are lowercase letters, numbers, dots, and underscores, up to 30.
    static func cleanHandle(_ value: String) -> String {
        String(value.lowercased().filter { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "." || $0 == "_" }.prefix(30))
    }
}

extension SocialProfile {
    /// Every field is optional in the file, so profiles saved by older builds still open.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        handle = try c.decodeIfPresent(String.self, forKey: .handle) ?? ""
        bio = try c.decodeIfPresent(String.self, forKey: .bio) ?? ""
        headline = try c.decodeIfPresent(String.self, forKey: .headline)
        picture = try c.decodeIfPresent(String.self, forKey: .picture)
        avatar = try c.decodeIfPresent(UUID.self, forKey: .avatar)
        banner = try c.decodeIfPresent(String.self, forKey: .banner)
        featured = try c.decodeIfPresent([UUID?].self, forKey: .featured) ?? featured
        media = try c.decodeIfPresent([ProfileMedia].self, forKey: .media) ?? []
        songs = try c.decodeIfPresent([ProfileSong].self, forKey: .songs) ?? []
        links = try c.decodeIfPresent([ProfileLink].self, forKey: .links) ?? []
        experience = try c.decodeIfPresent([WorkEntry].self, forKey: .experience) ?? []
        education = try c.decodeIfPresent([EducationEntry].self, forKey: .education) ?? []
        skills = try c.decodeIfPresent([String].self, forKey: .skills) ?? []
        certifications = try c.decodeIfPresent([CertificationEntry].self, forKey: .certifications) ?? []
        languages = try c.decodeIfPresent([LanguageEntry].self, forKey: .languages) ?? []
        about = try c.decodeIfPresent(String.self, forKey: .about)
        interests = try c.decodeIfPresent([String].self, forKey: .interests) ?? []
        facts = try c.decodeIfPresent([ProfileFact].self, forKey: .facts) ?? []
        blog = try c.decodeIfPresent(ProfileBlog.self, forKey: .blog)
        accent = try c.decodeIfPresent(String.self, forKey: .accent)
        pinned = try c.decodeIfPresent(UUID.self, forKey: .pinned)
        // Stats are recomputed from the library, so a file this build can't read loses nothing.
        musicStats = try? c.decodeIfPresent(MusicStats.self, forKey: .musicStats)
        // A section a later build adds is ignored rather than making the file unreadable.
        hiddenSections = (try c.decodeIfPresent([String].self, forKey: .hiddenSections) ?? []).compactMap(ProfileSection.init)
        importedSources = try c.decodeIfPresent([String: UUID].self, forKey: .importedSources) ?? [:]
        linkedInIntro = try c.decodeIfPresent(ImportedIntro.self, forKey: .linkedInIntro)
        if let saved = try c.decodeIfPresent([ProfileBlock.Stored].self, forKey: .blocks) {
            // A block or style a later build adds is dropped rather than making the file unreadable.
            blocks = ProfileBlock.normalized(saved.compactMap(\.block))
        } else {
            blocks = ProfileBlock.migrated(from: hiddenSections)
        }
    }
    /// Whether a saved profile file already has blocks (profiles from before September 25 don't).
    static func hasBlocks(_ data: Data) -> Bool {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["blocks"] != nil
    }
}

/// The sections of the profile before blocks; read only to carry hidden sections forward.
enum ProfileSection: String, Codable, CaseIterable, Identifiable {
    case posts, work, social, writing, personal
    var id: String { rawValue }
}

/// A part of your profile you can move, style, and hide.
enum ProfileBlockKind: String, Codable, CaseIterable, Identifiable {
    case photos, music, work, writing, personal, links, kemo
    var id: String { rawValue }
    var title: String {
        switch self {
        case .photos: "Photos"; case .music: "Music"; case .work: "Work"; case .writing: "Writing"
        case .personal: "Personal"; case .links: "Links"; case .kemo: "Watch game"
        }
    }
    var symbol: String {
        switch self {
        case .photos: "square.grid.3x3.fill"; case .music: "music.note"; case .work: "briefcase.fill"; case .writing: "text.book.closed.fill"
        case .personal: "heart.fill"; case .links: "link"; case .kemo: "applewatch"
        }
    }
    /// The looks a block can take; the first is its default.
    var styles: [ProfileBlockStyle] {
        switch self {
        case .photos: [.grid, .feed]
        case .music: [.topArtists, .topSongs, .onRepeat]
        case .work: [.full, .summary]
        case .writing: [.list, .latest]
        case .links: [.cards, .icons]
        case .personal, .kemo: []
        }
    }
    var defaultStyle: ProfileBlockStyle { styles.first ?? .standard }
    /// A new profile: what you show off first, then the rest.
    static let defaultLayout: [ProfileBlock] = allCases.map { ProfileBlock(kind: $0) }
}

enum ProfileBlockStyle: String, Codable, CaseIterable {
    case standard, grid, feed, topArtists, topSongs, onRepeat, full, summary, list, latest, cards, icons
    var title: String {
        switch self {
        case .standard: "Standard"; case .grid: "Grid"; case .feed: "Feed"
        case .topArtists: "Top artists"; case .topSongs: "Top songs"; case .onRepeat: "On repeat"
        case .full: "Full"; case .summary: "Summary"; case .list: "List"; case .latest: "Latest post"
        case .cards: "Cards"; case .icons: "Icons"
        }
    }
    var symbol: String {
        switch self {
        case .standard: "square"; case .grid: "square.grid.3x3"; case .feed: "rectangle.grid.1x2"
        case .topArtists: "person.2.fill"; case .topSongs: "list.number"; case .onRepeat: "repeat"
        case .full: "list.bullet.rectangle"; case .summary: "rectangle.compress.vertical"; case .list: "list.bullet"; case .latest: "doc.richtext"
        case .cards: "rectangle.grid.2x2"; case .icons: "circle.grid.3x3"
        }
    }
}

struct ProfileBlock: Codable, Equatable, Identifiable {
    var kind: ProfileBlockKind
    var hidden = false
    /// Nil uses the block's default style.
    var style: ProfileBlockStyle?
    /// Who can see it once you share your profile; nil is Only you (September 27, 2026).
    var audience: ProfileAudience?
    var id: String { kind.rawValue }

    /// What's read from the file: names this build doesn't know are kept as nil and dropped.
    struct Stored: Decodable {
        let block: ProfileBlock?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard let kind = (try? c.decode(String.self, forKey: .kind)).flatMap(ProfileBlockKind.init) else { block = nil; return }
            let hidden = (try? c.decodeIfPresent(Bool.self, forKey: .hidden)) ?? false
            let style = (try? c.decodeIfPresent(String.self, forKey: .style)).flatMap(ProfileBlockStyle.init)
            // An audience a later build adds reads as Only you, never as wider.
            let audience = (try? c.decodeIfPresent(String.self, forKey: .audience)).flatMap(ProfileAudience.init)
            block = ProfileBlock(kind: kind, hidden: hidden, style: style, audience: audience)
        }
    }
    /// Each block once, in your order, with any missing block added at the end and styles that
    /// don't belong to a block cleared.
    static func normalized(_ blocks: [ProfileBlock]) -> [ProfileBlock] {
        var seen = Set<ProfileBlockKind>(), result: [ProfileBlock] = []
        for var block in blocks where seen.insert(block.kind).inserted {
            if let style = block.style, !block.kind.styles.contains(style) { block.style = nil }
            result.append(block)
        }
        for kind in ProfileBlockKind.allCases where !seen.contains(kind) { result.append(ProfileBlock(kind: kind)) }
        return result
    }
    /// Blocks for a profile saved with sections: what you hid stays hidden (Social became Links,
    /// and Personal held music, so hiding it hides both).
    static func migrated(from hidden: [ProfileSection]) -> [ProfileBlock] {
        ProfileBlockKind.defaultLayout.map { block in
            var block = block
            switch block.kind {
            case .work: block.hidden = hidden.contains(.work)
            case .links: block.hidden = hidden.contains(.social)
            case .writing: block.hidden = hidden.contains(.writing)
            case .music, .personal: block.hidden = hidden.contains(.personal)
            case .photos, .kemo: break
            }
            return block
        }
    }
    /// The sections an older build should hide for these blocks.
    static func legacySections(_ blocks: [ProfileBlock]) -> [ProfileSection] {
        func hidden(_ kind: ProfileBlockKind) -> Bool { blocks.first { $0.kind == kind }?.hidden ?? false }
        var sections: [ProfileSection] = []
        if hidden(.work) { sections.append(.work) }
        if hidden(.links) { sections.append(.social) }
        if hidden(.writing) { sections.append(.writing) }
        if hidden(.personal) && hidden(.music) { sections.append(.personal) }
        return sections
    }
}

/// Accent colors for the profile, chosen to read on light and dark backgrounds.
enum ProfileAccent {
    static let choices: [(name: String, hex: String)] = [
        ("Coral", "#E8735A"), ("Plum", "#8E5BA8"), ("Rose", "#D9658F"), ("Sun", "#E0A43A"),
        ("Sage", "#6E9E78"), ("Ocean", "#3F84C4"), ("Lagoon", "#2E9C9A"), ("Graphite", "#6F7480"),
    ]
    /// The color for a saved "#RRGGBB".
    static func color(_ hex: String) -> Color { Color(hex: String(hex.drop { $0 == "#" })) }
    static func isValid(_ hex: String) -> Bool {
        hex.count == 7 && hex.hasPrefix("#") && hex.dropFirst().allSatisfy(\.isHexDigit)
    }
}

/// A month and year as LinkedIn writes them ("Jan 2020", or just "2020").
struct ProfileMonth: Codable, Hashable, Comparable {
    var year: Int
    var month: Int?
    static func < (a: Self, b: Self) -> Bool { (a.year, a.month ?? 0) < (b.year, b.month ?? 0) }
    var text: String {
        guard let month, (1...12).contains(month) else { return String(year) }
        return Calendar.current.shortMonthSymbols[month - 1] + " " + String(year)
    }
    /// "Jan 2020", "January 2020", "2020", "2020-01", or "01/2020"; nil for anything else.
    static func parse(_ raw: String) -> ProfileMonth? {
        let parts = raw.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "/" || $0 == "," || $0.isNewline }).map(String.init)
        func year(_ text: String) -> Int? { Int(text).flatMap { (1900...2200).contains($0) ? $0 : nil } }
        switch parts.count {
        case 1: return year(parts[0]).map { ProfileMonth(year: $0) }
        case 2, 3:
            if let y = year(parts[0]), let m = Int(parts[1]), (1...12).contains(m) { return ProfileMonth(year: y, month: m) }
            if let m = Int(parts[0]), (1...12).contains(m), let y = year(parts[parts.count - 1]) { return ProfileMonth(year: y, month: m) }
            let word = parts[0].lowercased().prefix(3)
            let names = DateFormatter(); names.locale = Locale(identifier: "en_US_POSIX")
            guard word.count == 3, let m = names.shortMonthSymbols.firstIndex(where: { $0.lowercased() == word }),
                  let y = year(parts[parts.count - 1]) else { return nil }
            return ProfileMonth(year: y, month: m + 1)
        default: return nil
        }
    }
    /// "Jan 2020 – Present", "2014 – 2018", or empty when there are no dates.
    static func range(_ start: ProfileMonth?, _ end: ProfileMonth?, current: Bool) -> String {
        switch (start, end) {
        case let (start?, end?): start == end ? start.text : start.text + " \u{2013} " + end.text
        case let (start?, nil): current ? start.text + " \u{2013} Present" : start.text
        case let (nil, end?): end.text
        default: ""
        }
    }
    /// How many months from `start` through `end` (or now), counting both months as LinkedIn does;
    /// a year without a month counts from January or through December.
    static func months(_ start: ProfileMonth, _ end: ProfileMonth?, now: Date = .now) -> Int {
        let today = Calendar.current.dateComponents([.year, .month], from: now)
        let last = end.map { ($0.year, $0.month ?? 12) } ?? (today.year ?? start.year, today.month ?? 12)
        let first = (start.year, start.month ?? 1)
        return max(1, (last.0 - first.0) * 12 + (last.1 - first.1) + 1)
    }
    /// "3 yrs 2 mos", "1 yr", or "8 mos", as LinkedIn writes a duration.
    static func duration(months: Int) -> String {
        let years = months / 12, rest = months % 12
        var parts: [String] = []
        if years > 0 { parts.append("\(years) \(years == 1 ? "yr" : "yrs")") }
        if rest > 0 { parts.append("\(rest) \(rest == 1 ? "mo" : "mos")") }
        return parts.joined(separator: " ")
    }
}

/// A job, as on LinkedIn. No end date means you work there now.
struct WorkEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = ""
    var company = ""
    var location = ""
    var start: ProfileMonth?
    var end: ProfileMonth?
    var summary = ""
    var dates: String { ProfileMonth.range(start, end, current: true) }
    var isCurrent: Bool { end == nil && start != nil }
    /// "Mar 2022 – Present · 3 yrs 7 mos"; just the dates when there's no start.
    func datesAndDuration(now: Date = .now) -> String {
        guard let start else { return dates }
        return [dates, ProfileMonth.duration(months: ProfileMonth.months(start, end, now: now))].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    static func newestFirst(_ a: WorkEntry, _ b: WorkEntry) -> Bool {
        if (a.end == nil) != (b.end == nil) { return a.end == nil }
        let zero = ProfileMonth(year: 0)
        return (a.end ?? a.start ?? zero, a.start ?? zero) > (b.end ?? b.start ?? zero, b.start ?? zero)
    }
    /// Roles at the same company next to each other become one group, as LinkedIn shows a
    /// promotion: the company once, with each role under it.
    static func grouped(_ entries: [WorkEntry]) -> [[WorkEntry]] {
        var groups: [[WorkEntry]] = []
        for entry in entries {
            let company = entry.company.trimmingCharacters(in: .whitespaces).lowercased()
            if !company.isEmpty, let last = groups.last?.last, last.company.trimmingCharacters(in: .whitespaces).lowercased() == company {
                groups[groups.count - 1].append(entry)
            } else { groups.append([entry]) }
        }
        return groups
    }
    /// A group's whole span, from its first start to its last end.
    static func span(_ group: [WorkEntry], now: Date = .now) -> String? {
        let starts = group.compactMap(\.start)
        guard let first = starts.min() else { return nil }
        let end: ProfileMonth? = group.contains { $0.end == nil } ? nil : group.compactMap(\.end).max()
        return ProfileMonth.duration(months: ProfileMonth.months(first, end, now: now))
    }
}

/// A license or certification, as on LinkedIn.
struct CertificationEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    /// Who issued it.
    var authority = ""
    var issued: ProfileMonth?
    var expires: ProfileMonth?
    var link: String?
    var url: URL? { link.flatMap(URL.init(string:)).flatMap { $0.scheme?.lowercased() == "https" ? $0 : nil } }
}

/// A language and how well you speak it ("Native or bilingual").
struct LanguageEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var proficiency = ""
}

/// Two or three letters for a company or school, for its tile when there's no logo.
enum ProfileInitials {
    static func of(_ name: String) -> String {
        let skip: Set<String> = ["of", "the", "and", "at", "for", "inc", "inc.", "llc", "ltd", "co", "co."]
        let words = name.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "," }).map(String.init)
            .filter { !skip.contains($0.lowercased()) }
        let letters = words.prefix(2).compactMap { $0.first(where: \.isLetter).map { String($0).uppercased() } }.joined()
        return letters.isEmpty ? String(name.prefix(1)).uppercased() : letters
    }
}

struct EducationEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var school = ""
    var degree = ""
    var start: ProfileMonth?
    var end: ProfileMonth?
    var notes = ""
    var dates: String { ProfileMonth.range(start, end, current: false) }
}

struct ProfileFact: Codable, Identifiable, Equatable {
    var id = UUID()
    var label: String
    var value: String
    static let suggestions = ["Hometown", "Lives in", "Languages", "Pronouns"]
}

/// Your blog: the address you gave, the feed found there, and its latest posts.
struct ProfileBlog: Codable, Equatable {
    var address: String
    var feed: String?
    var title: String?
    var entries: [BlogEntry] = []
    var refreshed: Date?
    /// The one host KemoSabe contacts for it.
    var host: String? { FeedDiscovery.normalize(feed ?? address)?.host }
}

struct BlogEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var link: String?
    var date: Date?
    var summary: String
    var url: URL? { link.flatMap(URL.init(string:)).flatMap { ["https", "http"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil } }
}

struct ImportedIntro: Codable, Equatable {
    var headline: String?
    var summary: String?
    /// "San Francisco, CA", offered as a Lives in fact.
    var location: String?
    var isEmpty: Bool { headline == nil && summary == nil && location == nil }
}

struct ProfileMedia: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case photo, video }
    var id = UUID()
    var kind: Kind
    var file: String
    var thumbnail: String
    var added = Date()
    var duration: Double?
    /// What you wrote under the post.
    var caption: String?
    /// When the photo or video was taken, read from the file, so old camera-roll posts land on their day.
    var takenAt: Date?
    /// Where an imported post came from ("instagram"); nil for posts added here.
    var source: String?
    var day: Date { takenAt ?? added }
}

/// Music you picked by hand.
struct ProfileSong: Codable, Identifiable, Equatable {
    enum Pick: String, Codable, CaseIterable, Identifiable {
        case onRepeat, favoriteSong, favoriteAlbum
        var id: String { rawValue }
        var title: String {
            switch self { case .onRepeat: "Song on repeat"; case .favoriteSong: "Favorite song"; case .favoriteAlbum: "Favorite album" }
        }
    }
    var id = UUID()
    var title: String
    var artist: String
    /// Artwork saved from your music library, if the song came from there.
    var artwork: String?
    /// What it is on your profile; nil for songs added before picks (shown as a favorite song).
    var pick: Pick?
}

struct ProfileLink: Codable, Identifiable, Equatable {
    enum Platform: String, Codable, CaseIterable, Identifiable {
        case instagram, tiktok, x, youtube, spotify, appleMusic, linkedIn, website
        var id: String { rawValue }
        var title: String {
            switch self {
            case .instagram: "Instagram"; case .tiktok: "TikTok"; case .x: "X"; case .youtube: "YouTube"
            case .spotify: "Spotify"; case .appleMusic: "Apple Music"; case .linkedIn: "LinkedIn"; case .website: "Website"
            }
        }
        var symbol: String {
            switch self {
            case .instagram: "camera"; case .tiktok: "music.note.tv"; case .x: "at"; case .youtube: "play.rectangle"
            case .spotify, .appleMusic: "music.note"; case .linkedIn: "briefcase"; case .website: "globe"
            }
        }
        /// The public profile address for a handle; websites take a full address.
        func url(for value: String) -> URL? {
            let handle = value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            guard !handle.isEmpty else { return nil }
            if handle.lowercased().hasPrefix("https://") { return URL(string: handle) }
            let escaped = handle.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? handle
            switch self {
            case .instagram: return URL(string: "https://www.instagram.com/\(escaped)")
            case .tiktok: return URL(string: "https://www.tiktok.com/@\(escaped)")
            case .x: return URL(string: "https://x.com/\(escaped)")
            case .youtube: return URL(string: "https://www.youtube.com/@\(escaped)")
            case .linkedIn: return URL(string: "https://www.linkedin.com/in/\(escaped)")
            case .spotify, .appleMusic, .website: return URL(string: "https://\(escaped)")
            }
        }
    }
    var id = UUID()
    var platform: Platform
    var value: String
    var url: URL? { platform.url(for: value) }
}

@MainActor @Observable final class ProfileStore {
    /// The open account's profile; replaced when the account changes while the app runs.
    private(set) static var shared = ProfileStore(folder: defaultFolder, records: .shared)
    static func reopen() { shared.closed = true; shared = ProfileStore(folder: defaultFolder, records: .shared) }
    /// Set once the device moved to another account: nothing more is written.
    @ObservationIgnored private var closed = false
    static var defaultFolder: URL {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing"), arguments.contains("--isolated-fixture") || arguments.contains("--planner-fixture") {
            return FileManager.default.temporaryDirectory.appendingPathComponent("ProfileUITests/\(UUID().uuidString)", isDirectory: true)
        }
        #endif
        return AccountDirectory.currentFolder.appendingPathComponent("Profile", isDirectory: true)
    }
    /// What profile.json holds. Name and handle are kept in it only for older builds; the
    /// account owns them (see `profile`).
    private var stored = SocialProfile()
    /// Your profile, with the name and handle always taken from your account, so an edit
    /// here can never write back an older name, and an account change shows at once.
    var profile: SocialProfile {
        var merged = stored
        merged.name = account.account.name; merged.handle = account.account.handle
        return merged
    }
    private(set) var error: String?
    /// Set when profile.json exists but couldn't be read; edits are refused so it isn't replaced.
    private(set) var loadFailed = false
    @ObservationIgnored private let folder: URL
    @ObservationIgnored private let account: AccountStore
    @ObservationIgnored private let records: AccountRecords?
    @ObservationIgnored private var thumbnails: [String: UIImage] = [:]

    init(folder: URL, account: AccountStore? = nil, records: AccountRecords? = nil) {
        self.folder = folder
        self.account = account ?? .shared
        self.records = records
        load()
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing"), arguments.contains("--profile-sample"), folder.path.contains("ProfileUITests") { seedSample() }
        #endif
    }
    private var file: URL { folder.appendingPathComponent("profile.json") }
    /// Where Posts' feed or grid choice was kept before it became the Photos block's style.
    static let legacyLayoutKey = "kemo.profile.layout"

    func load() {
        guard FileManager.default.fileExists(atPath: file.path) else {
            // The earlier Profile tab kept only a name and bio.
            stored.name = AccountDirectory.accountSettings.string(forKey: "kemo.profile.name") ?? ""
            stored.bio = AccountDirectory.accountSettings.string(forKey: "kemo.profile.bio") ?? ""
            adoptLegacyIdentity()
            return
        }
        do {
            let data = try Data(contentsOf: file)
            var loaded = try JSONDecoder().decode(SocialProfile.self, from: data)
            loaded.featured = Array((loaded.featured + Array(repeating: nil, count: SocialProfile.featuredSlots)).prefix(SocialProfile.featuredSlots))
            if !SocialProfile.hasBlocks(data) {
                // Before blocks, Posts' feed or grid was a setting on this iPhone (Feed by default).
                let grid = UserDefaults.standard.string(forKey: Self.legacyLayoutKey) == "Grid"
                if let index = loaded.blocks.firstIndex(where: { $0.kind == .photos }) { loaded.blocks[index].style = grid ? .grid : .feed }
            }
            stored = loaded
            loadFailed = false
            adoptLegacyIdentity()
            movePictureOutOfPosts()
        } catch {
            // Locked device, disk error, or a damaged file: keep it untouched and refuse edits until it opens.
            loadFailed = true
            self.error = "Your profile couldn't be opened. It hasn't been changed, and edits are paused until it opens."
        }
    }
    /// Profiles saved before the account existed held the name and handle; move them into
    /// the account once, only if the account has never been named.
    private func adoptLegacyIdentity() {
        guard account.account.updated == .distantPast, account.account.name.isEmpty, !stored.name.isEmpty || !stored.handle.isEmpty else { return }
        account.update { $0.name = stored.name; $0.handle = stored.handle }
    }
    /// Older profiles used one of your posts as the picture, so it showed twice. Copy it to its
    /// own picture file and take it out of your posts, once.
    private func movePictureOutOfPosts() {
        guard stored.picture == nil, let id = stored.avatar, let post = stored.media.first(where: { $0.id == id }), post.kind == .photo else { return }
        let name = "picture-\(UUID().uuidString).jpg"
        do { try FileManager.default.copyItem(at: url(post.file), to: url(name)) } catch { return }
        stored.picture = name; stored.avatar = nil
        stored.media.removeAll { $0.id == id }
        save()
        for file in [post.file, post.thumbnail] { try? FileManager.default.removeItem(at: url(file)) }
    }
    func update(_ change: (inout SocialProfile) -> Void) {
        guard !loadFailed else { return }
        var next = profile
        change(&next)
        next.name = String(next.name.prefix(100))
        next.handle = SocialProfile.cleanHandle(next.handle)
        next.bio = String(next.bio.prefix(SocialProfile.maxBio))
        next.headline = next.headline.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)) }.flatMap { $0.isEmpty ? nil : $0 }
        next.links = Array(next.links.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }.prefix(12))
        next.songs = Array(next.songs.prefix(20))
        for index in next.media.indices {
            next.media[index].caption = next.media[index].caption.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2200)) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        Self.bound(&next)
        let ids = Set(next.media.map(\.id))
        if next.importedSources.count > 5000 { next.importedSources = next.importedSources.filter { ids.contains($0.value) } }
        next.featured = next.featured.map { $0.flatMap { ids.contains($0) ? $0 : nil } }
        if let avatar = next.avatar, !ids.contains(avatar) { next.avatar = nil }
        stored = next
        save()
        // Your name and handle belong to the account. Only an actual change to them is sent there,
        // so editing a bio or a photo never touches the account.
        if next.name != account.account.name || next.handle != account.account.handle {
            account.update { $0.name = next.name; $0.handle = next.handle }
        }
        record()
        onChanged?()
    }
    /// Called after every change, so the people you share with get it (`ProfileSharingStore`).
    @ObservationIgnored var onChanged: (@MainActor () -> Void)?
    /// The folder the profile's files live in (sharing keeps its own files beside them).
    var directory: URL { folder }
    /// Trims every section's text and caps each list, so no import or edit can grow the file without bound.
    static func bound(_ profile: inout SocialProfile) {
        func clip(_ text: String, _ limit: Int) -> String { String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit)) }
        func tags(_ list: [String], _ limit: Int) -> [String] {
            var seen = Set<String>()
            return Array(list.map { clip($0.split(whereSeparator: \.isWhitespace).joined(separator: " "), 50) }
                .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }.prefix(limit))
        }
        profile.experience = Array(profile.experience.map { entry in
            var entry = entry
            entry.title = clip(entry.title, 120); entry.company = clip(entry.company, 120); entry.location = clip(entry.location, 120)
            entry.summary = clip(entry.summary, 2000)
            return entry
        }.filter { !$0.title.isEmpty || !$0.company.isEmpty }.prefix(SocialProfile.maxExperience))
        profile.education = Array(profile.education.map { entry in
            var entry = entry
            entry.school = clip(entry.school, 120); entry.degree = clip(entry.degree, 120); entry.notes = clip(entry.notes, 1000)
            return entry
        }.filter { !$0.school.isEmpty }.prefix(SocialProfile.maxEducation))
        profile.skills = tags(profile.skills, SocialProfile.maxSkills)
        profile.interests = tags(profile.interests, SocialProfile.maxInterests)
        profile.facts = Array(profile.facts.map { ProfileFact(id: $0.id, label: clip($0.label, 30), value: clip($0.value, 120)) }
            .filter { !$0.value.isEmpty }.prefix(SocialProfile.maxFacts))
        if var blog = profile.blog {
            blog.address = clip(blog.address, 300); blog.feed = blog.feed.map { clip($0, 2000) }; blog.title = blog.title.map { clip($0, 200) }
            blog.entries = Array(blog.entries.prefix(FeedParser.maxEntries).map { entry in
                BlogEntry(id: entry.id, title: clip(entry.title, 300), link: entry.link.map { clip($0, 2000) }, date: entry.date, summary: clip(entry.summary, 400))
            })
            profile.blog = blog.address.isEmpty ? nil : blog
        }
        profile.certifications = Array(profile.certifications.map { entry in
            var entry = entry
            entry.name = clip(entry.name, 150); entry.authority = clip(entry.authority, 120)
            entry.link = entry.link.map { clip($0, 2000) }.flatMap { $0.isEmpty ? nil : $0 }
            return entry
        }.filter { !$0.name.isEmpty }.prefix(SocialProfile.maxCertifications))
        profile.languages = Array(profile.languages.map { LanguageEntry(id: $0.id, name: clip($0.name, 50), proficiency: clip($0.proficiency, 60)) }
            .filter { !$0.name.isEmpty }.prefix(SocialProfile.maxLanguages))
        profile.about = profile.about.map { clip($0, SocialProfile.maxAbout) }.flatMap { $0.isEmpty ? nil : $0 }
        profile.blocks = ProfileBlock.normalized(profile.blocks)
        profile.hiddenSections = ProfileBlock.legacySections(profile.blocks)
        if let accent = profile.accent, !ProfileAccent.isValid(accent) { profile.accent = nil }
        if let pinned = profile.pinned, !profile.media.contains(where: { $0.id == pinned }) { profile.pinned = nil }
        for index in profile.songs.indices {
            profile.songs[index].title = clip(profile.songs[index].title, 120); profile.songs[index].artist = clip(profile.songs[index].artist, 120)
        }
        profile.songs = Array(profile.songs.filter { !$0.title.isEmpty }.prefix(20))
        if let intro = profile.linkedInIntro {
            let headline = intro.headline.map { clip($0, 120) }.flatMap { $0.isEmpty ? nil : $0 }
            let summary = intro.summary.map { clip($0, SocialProfile.maxAbout) }.flatMap { $0.isEmpty ? nil : $0 }
            let location = intro.location.map { clip($0, 120) }.flatMap { $0.isEmpty ? nil : $0 }
            let next = ImportedIntro(headline: headline, summary: summary, location: location)
            profile.linkedInIntro = next.isEmpty ? nil : next
        }
    }
    /// The profile text queued for your other devices in the account's personal zone. Posts,
    /// songs, and blog posts aren't part of it; the picture and cover are their own records
    /// (`ProfileImageSyncAdapter`).
    struct Synced: Codable, Equatable {
        var headline: String?
        var bio: String
        var links: [ProfileLink]
        var experience: [WorkEntry]?
        var education: [EducationEntry]?
        var skills: [String]?
        var interests: [String]?
        var blog: String?
        // Added with blocks (September 25, 2026). A build that sends them always sends them (an
        // empty text or list when there's none), so nil means an older device and changes nothing.
        var blocks: [ProfileBlock]?
        /// "" for the theme's accent.
        var accent: String?
        var about: String?
        var certifications: [CertificationEntry]?
        var languages: [LanguageEntry]?
        var facts: [ProfileFact]?
        init(headline: String?, bio: String, links: [ProfileLink], experience: [WorkEntry]?, education: [EducationEntry]?, skills: [String]?,
             interests: [String]?, blog: String?, blocks: [ProfileBlock]? = nil, accent: String? = nil, about: String? = nil,
             certifications: [CertificationEntry]? = nil, languages: [LanguageEntry]? = nil, facts: [ProfileFact]? = nil) {
            self.headline = headline; self.bio = bio; self.links = links; self.experience = experience; self.education = education
            self.skills = skills; self.interests = interests; self.blog = blog; self.blocks = blocks; self.accent = accent
            self.about = about; self.certifications = certifications; self.languages = languages; self.facts = facts
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            headline = try c.decodeIfPresent(String.self, forKey: .headline)
            bio = try c.decodeIfPresent(String.self, forKey: .bio) ?? ""
            links = try c.decodeIfPresent([ProfileLink].self, forKey: .links) ?? []
            experience = try c.decodeIfPresent([WorkEntry].self, forKey: .experience)
            education = try c.decodeIfPresent([EducationEntry].self, forKey: .education)
            skills = try c.decodeIfPresent([String].self, forKey: .skills)
            interests = try c.decodeIfPresent([String].self, forKey: .interests)
            blog = try c.decodeIfPresent(String.self, forKey: .blog)
            blocks = (try? c.decodeIfPresent([ProfileBlock.Stored].self, forKey: .blocks))?.compactMap(\.block)
            accent = try? c.decodeIfPresent(String.self, forKey: .accent)
            about = try? c.decodeIfPresent(String.self, forKey: .about)
            certifications = try? c.decodeIfPresent([CertificationEntry].self, forKey: .certifications)
            languages = try? c.decodeIfPresent([LanguageEntry].self, forKey: .languages)
            facts = try? c.decodeIfPresent([ProfileFact].self, forKey: .facts)
        }
    }
    func record() {
        guard let records, !loadFailed else { return }
        records.put(synced, id: AccountRecords.profileID, type: SyncType.profile)
    }
    var synced: Synced {
        Synced(headline: stored.headline, bio: stored.bio, links: stored.links, experience: stored.experience, education: stored.education,
               skills: stored.skills, interests: stored.interests, blog: stored.blog?.address, blocks: stored.blocks, accent: stored.accent ?? "",
               about: stored.about ?? "", certifications: stored.certifications, languages: stored.languages, facts: stored.facts)
    }
    /// Whether sync may read and apply the profile: it's open and was read.
    var syncable: Bool { !closed && !loadFailed }
    /// Takes another device's profile text. Posts and songs stay on each device; a blog
    /// from another device comes as its address, and its posts are fetched here when refreshed.
    func applySynced(_ remote: Synced) -> Bool {
        guard syncable else { return false }
        var next = stored
        next.headline = remote.headline; next.bio = remote.bio; next.links = remote.links
        next.experience = remote.experience ?? []; next.education = remote.education ?? []
        next.skills = remote.skills ?? []; next.interests = remote.interests ?? []
        if remote.blog != next.blog?.address { next.blog = remote.blog.map { ProfileBlog(address: $0) } }
        if let blocks = remote.blocks { next.blocks = ProfileBlock.normalized(blocks) }
        if let accent = remote.accent { next.accent = accent.isEmpty ? nil : accent }
        if let about = remote.about { next.about = about.isEmpty ? nil : about }
        if let certifications = remote.certifications { next.certifications = certifications }
        if let languages = remote.languages { next.languages = languages }
        if let facts = remote.facts { next.facts = facts }
        Self.bound(&next)
        guard next != stored else { return true }
        stored = next
        save()
        onChanged?()
        return error == nil
    }
    private func save() {
        guard !closed else { return }
        do {
            try AccountDirectory.checkWrite(to: file)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(stored).write(to: file, options: [.atomic, .completeFileProtection])
            error = nil
        } catch { self.error = "Your profile couldn't be saved. Try again." }
    }

    // MARK: Media

    /// Adds a photo, resized to at most 2048 pixels, newest first.
    @discardableResult func addPhoto(_ data: Data) throws -> UUID {
        guard !loadFailed else { throw ProfileError.profileUnavailable }
        return try insert(Self.preparePhoto(data))
    }
    /// A photo resized and encoded, ready to add; safe to make off the main thread.
    struct PreparedPhoto: Sendable {
        let full: Data
        let thumbnail: Data
        let taken: Date?
    }
    nonisolated static func preparePhoto(_ data: Data) throws -> PreparedPhoto {
        guard let image = UIImage(data: data) else { throw ProfileError.unreadable }
        guard let full = image.kemoResized(maxSide: 2048).jpegData(compressionQuality: 0.88),
              let thumbnail = image.kemoResized(maxSide: 480).jpegData(compressionQuality: 0.8) else { throw ProfileError.unreadable }
        return PreparedPhoto(full: full, thumbnail: thumbnail, taken: captureDate(data))
    }
    /// Adds a prepared photo as a post; an imported one keeps its caption, date, and where it came from.
    @discardableResult func insert(_ photo: PreparedPhoto, caption: String? = nil, takenAt: Date? = nil, source: String? = nil, sourceKey: String? = nil) throws -> UUID {
        guard !loadFailed else { throw ProfileError.profileUnavailable }
        let id = UUID()
        try write(photo.full, "\(id).jpg"); try write(photo.thumbnail, "\(id)-thumb.jpg")
        update { profile in
            profile.media.insert(.init(id: id, kind: .photo, file: "\(id).jpg", thumbnail: "\(id)-thumb.jpg", caption: caption, takenAt: takenAt ?? photo.taken, source: source), at: 0)
            if let sourceKey { profile.importedSources[sourceKey] = id }
        }
        return id
    }
    /// Adds a video by copying it in, with a thumbnail from its first second.
    func addVideo(at source: URL, caption: String? = nil, takenAt: Date? = nil, origin: String? = nil, sourceKey: String? = nil) async throws {
        guard !loadFailed else { throw ProfileError.profileUnavailable }
        let id = UUID(), ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension.lowercased()
        guard !closed else { throw AccountDirectory.WriteRefused() }
        try AccountDirectory.checkWrite(to: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent("\(id).\(ext)")
        try FileManager.default.copyItem(at: source, to: destination)
        try? (destination as NSURL).setResourceValue(URLFileProtection.complete, forKey: .fileProtectionKey)
        let asset = AVURLAsset(url: destination)
        let seconds = try? await asset.load(.duration).seconds
        let taken = try? await asset.load(.creationDate)?.load(.dateValue)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        guard let frame = try? await generator.image(at: CMTime(seconds: min(1, (seconds ?? 0) / 2), preferredTimescale: 600)).image,
              let thumbData = UIImage(cgImage: frame).jpegData(compressionQuality: 0.8) else {
            try? FileManager.default.removeItem(at: destination); throw ProfileError.unreadable
        }
        try write(thumbData, "\(id)-thumb.jpg")
        update { profile in
            profile.media.insert(.init(id: id, kind: .video, file: destination.lastPathComponent, thumbnail: "\(id)-thumb.jpg", duration: seconds,
                                       caption: caption, takenAt: takenAt ?? taken ?? nil, source: origin), at: 0)
            if let sourceKey { profile.importedSources[sourceKey] = id }
        }
    }
    func remove(_ media: ProfileMedia) {
        guard !loadFailed else { return }
        for name in [media.file, media.thumbnail] { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
        thumbnails[media.thumbnail] = nil
        update { $0.media.removeAll { $0.id == media.id } }
    }
    func url(_ name: String) -> URL { folder.appendingPathComponent(name) }
    func thumbnail(_ media: ProfileMedia) -> UIImage? {
        if let image = thumbnails[media.thumbnail] { return image }
        let image = UIImage(contentsOfFile: url(media.thumbnail).path)
        thumbnails[media.thumbnail] = image
        return image
    }
    func image(_ media: ProfileMedia) -> UIImage? { UIImage(contentsOfFile: url(media.file).path) }
    func media(_ id: UUID?) -> ProfileMedia? { id.flatMap { id in profile.media.first { $0.id == id } } }
    /// The capture date in a photo's metadata, if it has one.
    nonisolated static func captureDate(_ data: Data) -> Date? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        guard let raw = (exif?[kCGImagePropertyExifDateTimeOriginal] ?? tiff?[kCGImagePropertyTIFFDateTime]) as? String else { return nil }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: raw)
    }
    /// Sets your profile picture from photo data, as its own file (not a post); nil goes back to your Kemo.
    /// It's kept at the size it syncs at (`ProfileImageSyncAdapter.pictureSide`), so the file is what
    /// your other devices get.
    func setPicture(_ data: Data?) throws {
        guard !loadFailed else { throw ProfileError.profileUnavailable }
        let old = profile.picture
        var name: String?
        if let data {
            let jpeg = try PickedImage.squareJPEG(data, side: ProfileImageSyncAdapter.pictureSide)
            name = "picture-\(UUID().uuidString).jpg"
            try write(jpeg, name!)
        }
        update { $0.picture = name; $0.avatar = nil }
        if let old { thumbnails[old] = nil; try? FileManager.default.removeItem(at: url(old)) }
        onImagesChanged?()
    }
    func setCaption(_ caption: String, for id: UUID) {
        update { profile in
            if let index = profile.media.firstIndex(where: { $0.id == id }) { profile.media[index].caption = caption }
        }
    }
    /// Sets the wide background behind your picture; nil goes back to your theme's colors. Kept at the
    /// size it syncs at (`ProfileImageSyncAdapter.coverSide`).
    func setBanner(_ data: Data?) throws {
        guard !loadFailed else { throw ProfileError.profileUnavailable }
        let old = profile.banner
        var name: String?
        if let data {
            let jpeg = try PickedImage.resizedJPEG(data, maxSide: ProfileImageSyncAdapter.coverSide)
            name = "banner-\(UUID().uuidString).jpg"
            try write(jpeg, name!)
        }
        update { $0.banner = name }
        if let old { thumbnails[old] = nil; try? FileManager.default.removeItem(at: url(old)) }
        onImagesChanged?()
    }
    /// Called after the picture or cover changes on this device, so a sync can follow soon.
    @ObservationIgnored var onImagesChanged: (@MainActor () -> Void)?

    /// The picture's or cover's file as it is now, for sync: `.some(nil)` when there's none, nil when
    /// the file can't be read now (a locked device).
    func syncedImage(cover: Bool) -> Data?? {
        guard let name = cover ? stored.banner : stored.picture else { return .some(nil) }
        let file = url(name)
        guard FileManager.default.fileExists(atPath: file.path) else { return .some(nil) }
        guard let data = try? Data(contentsOf: file) else { return nil }
        return .some(data)
    }
    /// Takes the picture or cover another device set (nil removes it), as it came.
    func applySyncedImage(_ data: Data?, cover: Bool) -> Bool {
        guard syncable else { return false }
        let before = stored
        let old = cover ? stored.banner : stored.picture
        var name: String?
        if let data {
            name = (cover ? "banner-" : "picture-") + UUID().uuidString + ".jpg"
            do { try write(data, name!) } catch { return false }
        }
        if cover { stored.banner = name } else { stored.picture = name; stored.avatar = nil }
        save()
        guard error == nil else {
            stored = before
            if let name { try? FileManager.default.removeItem(at: url(name)) }
            return false
        }
        if let old { thumbnails[old] = nil; try? FileManager.default.removeItem(at: url(old)) }
        onChanged?()
        return true
    }
    func bannerImage() -> UIImage? {
        guard let banner = profile.banner else { return nil }
        if let image = thumbnails[banner] { return image }
        let image = UIImage(contentsOfFile: url(banner).path); thumbnails[banner] = image; return image
    }
    /// Your profile picture, from its own file or, for older profiles, the post it pointed at.
    func pictureImage() -> UIImage? {
        if let picture = profile.picture {
            if let image = thumbnails[picture] { return image }
            let image = UIImage(contentsOfFile: url(picture).path); thumbnails[picture] = image; return image
        }
        return media(profile.avatar).flatMap(thumbnail)
    }
    /// Your initials, from your name, for when there's no picture.
    var initials: String {
        let letters = profile.name.split(whereSeparator: \.isWhitespace).prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        return letters.isEmpty ? String(profile.handle.prefix(1)).uppercased() : letters
    }
    /// Your picture, or your initials in a circle when you haven't chosen one.
    func tabAvatar(side: CGFloat = 28) -> UIImage? {
        let frame = CGRect(x: 0, y: 0, width: side, height: side)
        guard let image = pictureImage(), image.size.width > 0, image.size.height > 0 else {
            guard !initials.isEmpty else { return nil }
            return UIGraphicsImageRenderer(size: frame.size).image { _ in
                UIColor.secondarySystemFill.setFill(); UIBezierPath(ovalIn: frame).fill()
                let text = NSAttributedString(string: initials, attributes: [.font: UIFont.systemFont(ofSize: side * 0.4, weight: .semibold), .foregroundColor: UIColor.label])
                let size = text.size()
                text.draw(at: CGPoint(x: (side - size.width) / 2, y: (side - size.height) / 2))
            }.withRenderingMode(.alwaysOriginal)
        }
        return UIGraphicsImageRenderer(size: frame.size).image { _ in
            UIBezierPath(ovalIn: frame).addClip()
            let scale = max(side / image.size.width, side / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
        }.withRenderingMode(.alwaysOriginal)
    }
    /// The first word of your profile name, for greetings.
    var firstName: String? { profile.name.split(separator: " ").first.map(String.init) }

    /// Puts a photo or video in a featured slot, or clears the slot with nil.
    func feature(_ id: UUID?, in slot: Int) {
        guard profile.featured.indices.contains(slot) else { return }
        update { profile in
            if let id, let existing = profile.featured.firstIndex(of: id) { profile.featured[existing] = nil }
            profile.featured[slot] = id
        }
    }
    func featureInFirstEmptySlot(_ id: UUID) {
        guard !profile.featured.contains(id), let slot = profile.featured.firstIndex(where: { $0 == nil }) else { return }
        feature(id, in: slot)
    }

    // MARK: Layout

    func setHidden(_ kind: ProfileBlockKind, _ hidden: Bool) {
        update { profile in
            if let index = profile.blocks.firstIndex(where: { $0.kind == kind }) { profile.blocks[index].hidden = hidden }
        }
    }
    func setStyle(_ kind: ProfileBlockKind, _ style: ProfileBlockStyle) {
        guard kind.styles.contains(style) else { return }
        update { profile in
            if let index = profile.blocks.firstIndex(where: { $0.kind == kind }) { profile.blocks[index].style = style }
        }
    }
    /// Moves a block up (negative) or down (positive) by that many places.
    func moveBlock(_ kind: ProfileBlockKind, by offset: Int) {
        guard let from = profile.blocks.firstIndex(where: { $0.kind == kind }) else { return }
        let to = min(max(from + offset, 0), profile.blocks.count - 1)
        guard to != from else { return }
        update { profile in
            let block = profile.blocks.remove(at: from)
            profile.blocks.insert(block, at: to)
        }
    }
    /// Moves a block to where another one is, as a drag does.
    func moveBlock(_ kind: ProfileBlockKind, to target: ProfileBlockKind) {
        guard kind != target, let from = profile.blocks.firstIndex(where: { $0.kind == kind }),
              let to = profile.blocks.firstIndex(where: { $0.kind == target }) else { return }
        moveBlock(kind, by: to - from)
    }
    func setAccent(_ hex: String?) { update { $0.accent = hex } }
    /// Who can see a block once you share your profile.
    func setAudience(_ kind: ProfileBlockKind, _ audience: ProfileAudience) {
        update { profile in
            if let index = profile.blocks.firstIndex(where: { $0.kind == kind }) { profile.blocks[index].audience = audience == .onlyYou ? nil : audience }
        }
    }
    /// Sets several blocks' audiences at once (the first time you share).
    func setAudiences(_ audiences: [ProfileBlockKind: ProfileAudience]) {
        update { profile in
            for index in profile.blocks.indices {
                if let audience = audiences[profile.blocks[index].kind] { profile.blocks[index].audience = audience == .onlyYou ? nil : audience }
            }
        }
    }
    /// Pins a post to the top of Photos, or unpins with nil.
    func pin(_ id: UUID?) { update { $0.pinned = id } }

    // MARK: Music

    /// Asks for the music library when needed, then computes the stats from it and saves them
    /// with small artwork. Returns the access, so a refusal can be named.
    @discardableResult func connectMusic(_ library: MusicLibrarySource) async -> MusicLibraryAccess {
        guard !loadFailed else { return library.access }
        var access = library.access
        if access == .notDetermined { access = await library.requestAccess() }
        guard access == .authorized else { return access }
        await refreshMusic(library)
        return access
    }
    /// Recomputes the stats from the library, only once it's connected and access is allowed.
    func refreshMusic(_ library: MusicLibrarySource) async {
        guard !loadFailed, library.access == .authorized else { return }
        var stats = MusicStats.compute(await library.items())
        var saved: [String: String] = [:]
        for id in stats.artworkSources {
            guard let image = library.artwork(for: id, side: 240), let data = image.kemoResized(maxSide: 240).jpegData(compressionQuality: 0.82) else { continue }
            let name = "music-\(Self.fileSafe(id)).jpg"
            if (try? write(data, name)) != nil { saved[id] = name; thumbnails[name] = nil }
        }
        for index in stats.topArtists.indices { stats.topArtists[index].artwork = stats.topArtists[index].artworkSource.flatMap { saved[$0] } }
        for index in stats.topSongs.indices { stats.topSongs[index].artwork = saved[stats.topSongs[index].id] }
        for index in stats.onRepeat.indices { stats.onRepeat[index].artwork = saved[stats.onRepeat[index].id] }
        update { $0.musicStats = stats }
        removeUnusedMusicArtwork(keeping: Set(saved.values))
    }
    /// Takes the stats off your profile and deletes their artwork. Your hand picks stay.
    func disconnectMusic() {
        update { $0.musicStats = nil }
        removeUnusedMusicArtwork(keeping: [])
    }
    /// Whether the stats are older than half a day, so opening the profile refreshes them.
    var musicIsStale: Bool { profile.musicStats.map { Date().timeIntervalSince($0.updated) > 12 * 3600 } ?? false }
    private func removeUnusedMusicArtwork(keeping: Set<String>) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix("music-") && !keeping.contains(name) {
            thumbnails[name] = nil
            try? FileManager.default.removeItem(at: url(name))
        }
    }
    private static func fileSafe(_ id: String) -> String { String(id.filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(40)) }
    func artworkImage(_ name: String?) -> UIImage? {
        guard let name else { return nil }
        if let image = thumbnails[name] { return image }
        let image = UIImage(contentsOfFile: url(name).path); thumbnails[name] = image; return image
    }

    func addSong(title: String, artist: String, artwork: UIImage? = nil, pick: ProfileSong.Pick? = nil) {
        let title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        let artist = String(artist.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        guard !title.isEmpty else { return }
        var saved: String?
        if let data = artwork?.kemoResized(maxSide: 300).jpegData(compressionQuality: 0.85) {
            let name = "song-\(UUID()).jpg"
            if (try? write(data, name)) != nil { saved = name }
        }
        // One song on repeat and one favorite album at a time; the new one takes the old one's place.
        let replaced = pick.map { pick in pick == .favoriteSong ? [] : profile.songs.filter { $0.pick == pick } } ?? []
        update { profile in
            profile.songs.removeAll { song in replaced.contains { $0.id == song.id } }
            profile.songs.insert(.init(title: title, artist: artist, artwork: saved, pick: pick), at: 0)
        }
        for song in replaced { if let artwork = song.artwork { try? FileManager.default.removeItem(at: url(artwork)) } }
    }
    func removeSong(_ song: ProfileSong) {
        if let artwork = song.artwork { try? FileManager.default.removeItem(at: url(artwork)) }
        update { $0.songs.removeAll { $0.id == song.id } }
    }

    // MARK: Imports

    /// Adds what a LinkedIn export holds, skipping entries already on your profile. Its headline
    /// and summary are only offered (`linkedInIntro`), never written over yours.
    @discardableResult func applyLinkedIn(_ result: LinkedInImport.Result) -> Int {
        var added = 0
        func key(_ parts: String...) -> String { parts.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.joined(separator: "|") }
        update { profile in
            let jobs = Set(profile.experience.map { key($0.title, $0.company, $0.start?.text ?? "") })
            for entry in result.experience where !jobs.contains(key(entry.title, entry.company, entry.start?.text ?? "")) {
                profile.experience.append(entry); added += 1
            }
            profile.experience.sort(by: WorkEntry.newestFirst)
            let schools = Set(profile.education.map { key($0.school, $0.degree) })
            for entry in result.education where !schools.contains(key(entry.school, entry.degree)) { profile.education.append(entry); added += 1 }
            let skills = Set(profile.skills.map { $0.lowercased() })
            for skill in result.skills where !skills.contains(skill.lowercased()) { profile.skills.append(skill); added += 1 }
            let certifications = Set(profile.certifications.map { key($0.name, $0.authority) })
            for entry in result.certifications where !certifications.contains(key(entry.name, entry.authority)) { profile.certifications.append(entry); added += 1 }
            let languages = Set(profile.languages.map { $0.name.lowercased() })
            for entry in result.languages where !languages.contains(entry.name.lowercased()) { profile.languages.append(entry); added += 1 }
            // The headline, summary, and location are only offered, never written over yours.
            let headline = result.headline.flatMap { $0 == profile.headline ? nil : $0 }
            let summary = result.summary.flatMap { $0 == profile.about || $0 == profile.bio ? nil : $0 }
            let location = result.location.flatMap { place in profile.facts.contains { $0.value == place } ? nil : place }
            let intro = ImportedIntro(headline: headline, summary: summary, location: location)
            if !intro.isEmpty { profile.linkedInIntro = intro }
        }
        return added
    }

    struct ImportReport: Equatable {
        var added = 0
        var alreadyHere = 0
        var failed = 0
        /// Posts past this import's cap, brought in by importing again.
        var left = 0
    }
    /// Brings posts from Instagram's "Download your information" export (JSON) into your posts,
    /// newest first, with their captions and dates. Posts imported before are skipped.
    func importInstagram(from folder: URL, progress: @escaping (Int, Int) -> Void) async throws -> ImportReport {
        guard !loadFailed else { throw ProfileError.profileUnavailable }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let found = try await Task.detached(priority: .userInitiated) { () throws -> (URL, [InstagramImport.Post]) in
            guard let located = InstagramImport.locate(in: folder) else { throw ProfileImportError.noInstagramPosts }
            var posts: [InstagramImport.Post] = []
            for list in located.lists { posts += try InstagramImport.posts(fromJSON: ImportFiles.data(list, limit: 100_000_000)) }
            return (located.root, posts)
        }.value
        let root = found.0
        var seen = Set<String>(), report = ImportReport()
        var fresh: [InstagramImport.Post] = []
        for post in found.1 where seen.insert(post.uri).inserted {
            if stored.importedSources["instagram:" + post.uri] != nil { report.alreadyHere += 1 } else { fresh.append(post) }
        }
        guard !found.1.isEmpty else { throw ProfileImportError.noInstagramPosts }
        fresh.sort { ($0.taken ?? .distantPast) > ($1.taken ?? .distantPast) }
        let batch = Array(fresh.prefix(InstagramImport.maxPerImport))
        report.left = fresh.count - batch.count
        for (index, post) in batch.enumerated() {
            if Task.isCancelled { report.left += batch.count - index; break }
            progress(index, batch.count)
            let key = "instagram:" + post.uri
            do {
                guard let file = InstagramImport.file(for: post.uri, in: root) else { throw ProfileError.unreadable }
                if post.isVideo {
                    let copy = try await Task.detached { try ImportFiles.copyToTemporary(file) }.value
                    defer { try? FileManager.default.removeItem(at: copy) }
                    try await addVideo(at: copy, caption: post.caption, takenAt: post.taken, origin: "instagram", sourceKey: key)
                } else {
                    let photo = try await Task.detached { try ProfileStore.preparePhoto(ImportFiles.data(file, limit: 60_000_000)) }.value
                    try insert(photo, caption: post.caption, takenAt: post.taken, source: "instagram", sourceKey: key)
                }
                report.added += 1
            } catch { report.failed += 1 }
        }
        progress(batch.count, batch.count)
        return report
    }

    /// Finds the blog's feed and saves its latest posts. The one network request the profile makes,
    /// and only when you add the address or tap Refresh.
    func setBlog(_ address: String) async throws {
        guard !loadFailed else { throw ProfileError.profileUnavailable }
        let result = try await FeedFetcher().fetch(address)
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        update { $0.blog = ProfileBlog(address: address, feed: result.feed.absoluteString, title: result.parsed.title, entries: result.parsed.entries, refreshed: .now) }
    }
    func refreshBlog() async throws {
        guard let blog = profile.blog else { return }
        let result = try await FeedFetcher().fetch(blog.feed ?? blog.address)
        update {
            $0.blog?.feed = result.feed.absoluteString; $0.blog?.title = result.parsed.title
            $0.blog?.entries = result.parsed.entries; $0.blog?.refreshed = .now
        }
    }

    private func write(_ data: Data, _ name: String) throws {
        guard !closed else { throw AccountDirectory.WriteRefused() }
        try AccountDirectory.checkWrite(to: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent(name), options: [.atomic, .completeFileProtection])
    }
}

enum ProfileImportError: LocalizedError {
    case noInstagramPosts, nothingFromLinkedIn
    var errorDescription: String? {
        switch self {
        case .noInstagramPosts: "No posts were found. Choose the unzipped export folder, the one that holds “your_instagram_activity”, and make sure the export is in JSON format."
        case .nothingFromLinkedIn: "Nothing to import was found. Choose the unzipped LinkedIn export folder, or its Profile, Positions, Education, Skills, Certifications, or Languages file."
        }
    }
}

enum ProfileError: LocalizedError {
    case unreadable
    /// The profile file couldn't be opened, so nothing is added until it does.
    case profileUnavailable
    var errorDescription: String? {
        switch self {
        case .unreadable: "That photo or video couldn't be added. Try another one."
        case .profileUnavailable: "Your profile couldn't be opened, so nothing was added. It hasn't been changed."
        }
    }
}

extension UIImage {
    /// A centered square crop, scaled to `side` pixels.
    func kemoSquare(side: CGFloat) -> UIImage {
        let edge = min(size.width, size.height)
        guard edge > 0 else { return self }
        let target = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat.default(); format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            let scale = side / edge
            draw(in: CGRect(x: (side - size.width * scale) / 2, y: (side - size.height * scale) / 2, width: size.width * scale, height: size.height * scale))
        }
    }
    func kemoResized(maxSide: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxSide else { return self }
        let scale = maxSide / longest
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default(); format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in draw(in: CGRect(origin: .zero, size: target)) }
    }
}

extension ProfileImageSyncAdapter {
    /// Your profile's picture and cover (the Mac shows the picture as your account photo).
    static func forProfile(_ profiles: ProfileStore) -> ProfileImageSyncAdapter {
        ProfileImageSyncAdapter(slots: [
            .init(id: pictureID, type: SyncType.profilePicture, maxSide: pictureSide,
                  read: { profiles.syncedImage(cover: false) }, write: { profiles.applySyncedImage($0, cover: false) }),
            .init(id: coverID, type: SyncType.profileCover, maxSide: coverSide,
                  read: { profiles.syncedImage(cover: true) }, write: { profiles.applySyncedImage($0, cover: true) })
        ], isOpen: { profiles.syncable })
    }
    /// The open account's profile, with a new picture or cover starting a sync.
    static func forSharedProfile() -> ProfileImageSyncAdapter {
        ProfileStore.shared.onImagesChanged = { AccountSyncService.shared.localChanged() }
        return forProfile(.shared)
    }
}

/// Your profile text, under the ID `AccountRecords` already uses. Posts and songs stay on each
/// device; the picture and cover sync as their own records (`ProfileImageSyncAdapter`).
@MainActor final class ProfileSyncAdapter: SyncAdapter {
    let profiles: ProfileStore
    init(profiles: ProfileStore) { self.profiles = profiles }
    let types: Set<String> = [SyncType.profile]
    func snapshot() -> [String: SyncItem]? {
        guard profiles.syncable, let payload = try? SyncEngine.encode(profiles.synced) else { return nil }
        return [AccountRecords.profileID: .init(type: SyncType.profile, payload: payload)]
    }
    func apply(_ changes: [String: SyncItem?]) -> Set<String> {
        var applied = Set<String>()
        for (id, item) in changes where id == AccountRecords.profileID {
            // Another device never removes your profile.
            guard let item else { applied.insert(id); continue }
            if let value = try? JSONDecoder().decode(ProfileStore.Synced.self, from: item.payload), profiles.applySynced(value) { applied.insert(id) }
        }
        return applied
    }
}

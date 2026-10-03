import Foundation
import MediaPlayer
import UIKit

// Listening stats for the profile's Music block, computed on this iPhone from the person's own
// music library (MediaPlayer's play counts, last-played dates, and genres). Nothing is fetched
// from a server and nothing is estimated: every number is a sum of the library's own counts.
// Apple Music's recently played history (MusicKit) needs the MusicKit app service on the App ID,
// and Spotify needs a developer client ID; both are "Complete later" (design/PROFILE-REDESIGN.md).

/// One song in the library, as the stats read it.
struct MusicLibraryItem: Equatable, Sendable {
    /// The library's persistent ID, used to find the song's artwork.
    var id: String
    var title: String
    var artist: String
    var album: String = ""
    var genre: String = ""
    var playCount: Int
    var lastPlayed: Date?
}

/// What the Music block shows, computed from the library and saved with the profile.
struct MusicStats: Codable, Equatable {
    struct Artist: Codable, Equatable, Identifiable {
        var name: String
        var plays: Int
        /// The saved artwork of the artist's most-played song.
        var artwork: String?
        /// The library ID of that song, to save its artwork.
        var artworkSource: String?
        var id: String { name }
    }
    struct Song: Codable, Equatable, Identifiable {
        var id: String
        var title: String
        var artist: String
        var album: String
        var plays: Int
        var lastPlayed: Date?
        var artwork: String?
    }
    struct Genre: Codable, Equatable, Identifiable {
        var name: String
        var plays: Int
        /// Share of plays among songs that have a genre, from 0 to 1.
        var share: Double
        var id: String { name }
    }
    var topArtists: [Artist] = []
    var topSongs: [Song] = []
    var topGenres: [Genre] = []
    /// Songs played in the last `recentDays` days, most played first.
    var onRepeat: [Song] = []
    var totalPlays = 0
    var songsPlayed = 0
    var updated = Date()

    static let limit = 10, genreLimit = 5, recentDays = 30
    var isEmpty: Bool { totalPlays == 0 }

    /// The stats for these songs. Songs never played are left out; ties go to the more recently
    /// played, then alphabetical, so the same library always gives the same stats.
    static func compute(_ items: [MusicLibraryItem], now: Date = .now) -> MusicStats {
        let played = items.filter { $0.playCount > 0 }
        func song(_ item: MusicLibraryItem) -> Song {
            Song(id: item.id, title: item.title, artist: item.artist, album: item.album, plays: item.playCount, lastPlayed: item.lastPlayed)
        }
        func byPlays(_ a: MusicLibraryItem, _ b: MusicLibraryItem) -> Bool {
            if a.playCount != b.playCount { return a.playCount > b.playCount }
            if (a.lastPlayed ?? .distantPast) != (b.lastPlayed ?? .distantPast) { return (a.lastPlayed ?? .distantPast) > (b.lastPlayed ?? .distantPast) }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
        let sorted = played.sorted(by: byPlays)
        var stats = MusicStats(updated: now)
        stats.totalPlays = played.reduce(0) { $0 + $1.playCount }
        stats.songsPlayed = played.count
        stats.topSongs = sorted.prefix(limit).map(song)

        // Artists: every play of every song by them, pictured by their most-played song.
        var artists: [String: (name: String, plays: Int, top: MusicLibraryItem)] = [:]
        for item in sorted {
            let name = item.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let key = name.lowercased()
            if let existing = artists[key] { artists[key] = (existing.name, existing.plays + item.playCount, existing.top) }
            else { artists[key] = (name, item.playCount, item) }
        }
        stats.topArtists = artists.values.sorted { a, b in
            a.plays != b.plays ? a.plays > b.plays : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }.prefix(limit).map { Artist(name: $0.name, plays: $0.plays, artworkSource: $0.top.id) }

        // Genres: share of the plays of songs that have one.
        var genres: [String: (name: String, plays: Int)] = [:]
        for item in played {
            let name = item.genre.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            genres[name.lowercased(), default: (name, 0)].plays += item.playCount
        }
        let genrePlays = genres.values.reduce(0) { $0 + $1.plays }
        stats.topGenres = genres.values.sorted { a, b in
            a.plays != b.plays ? a.plays > b.plays : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }.prefix(genreLimit).map { Genre(name: $0.name, plays: $0.plays, share: genrePlays > 0 ? Double($0.plays) / Double(genrePlays) : 0) }

        // On repeat lately: played in the last 30 days, most played first.
        let since = Calendar.current.date(byAdding: .day, value: -recentDays, to: now) ?? now
        stats.onRepeat = sorted.filter { ($0.lastPlayed ?? .distantPast) >= since }.prefix(limit).map(song)
        return stats
    }
    /// Every song ID whose artwork the stats show.
    var artworkSources: Set<String> {
        Set(topArtists.compactMap(\.artworkSource) + topSongs.map(\.id) + onRepeat.map(\.id))
    }
}

/// Access to the music library, as the profile needs it.
enum MusicLibraryAccess: Equatable { case notDetermined, denied, restricted, authorized }

/// Where the songs come from: the iPhone's library, or a fake one in tests and UI tests.
@MainActor protocol MusicLibrarySource {
    var access: MusicLibraryAccess { get }
    func requestAccess() async -> MusicLibraryAccess
    func items() async -> [MusicLibraryItem]
    func artwork(for id: String, side: CGFloat) -> UIImage?
}

/// The iPhone's music library through MediaPlayer. Asks for access only when the person taps
/// Connect Apple Music; reads titles, artists, albums, genres, play counts, last-played dates,
/// and artwork, and nothing else.
@MainActor final class DeviceMusicLibrary: MusicLibrarySource {
    private var loaded: [String: MPMediaItem] = [:]
    var access: MusicLibraryAccess { Self.map(MPMediaLibrary.authorizationStatus()) }
    func requestAccess() async -> MusicLibraryAccess {
        let status = await withCheckedContinuation { continuation in MPMediaLibrary.requestAuthorization { continuation.resume(returning: $0) } }
        return Self.map(status)
    }
    func items() async -> [MusicLibraryItem] {
        guard access == .authorized else { return [] }
        let songs = await Task.detached(priority: .userInitiated) { () -> [MPMediaItem] in
            let query = MPMediaQuery.songs()
            query.addFilterPredicate(MPMediaPropertyPredicate(value: MPMediaType.music.rawValue, forProperty: MPMediaItemPropertyMediaType, comparisonType: .contains))
            return query.items ?? []
        }.value
        loaded = [:]
        return songs.map { item in
            let id = String(item.persistentID)
            loaded[id] = item
            return MusicLibraryItem(id: id, title: item.title ?? "", artist: item.artist ?? item.albumArtist ?? "", album: item.albumTitle ?? "",
                                    genre: item.genre ?? "", playCount: item.playCount, lastPlayed: item.lastPlayedDate)
        }
    }
    func artwork(for id: String, side: CGFloat) -> UIImage? { loaded[id]?.artwork?.image(at: CGSize(width: side, height: side)) }
    private static func map(_ status: MPMediaLibraryAuthorizationStatus) -> MusicLibraryAccess {
        switch status {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        default: .notDetermined
        }
    }
}

/// A made-up library for tests and UI tests, with drawn artwork. Never used by a real install.
@MainActor final class SampleMusicLibrary: MusicLibrarySource {
    var access: MusicLibraryAccess
    var songs: [MusicLibraryItem]
    init(access: MusicLibraryAccess = .notDetermined, songs: [MusicLibraryItem] = SampleMusicLibrary.sample()) {
        self.access = access; self.songs = songs
    }
    func requestAccess() async -> MusicLibraryAccess {
        if access == .notDetermined { access = .authorized }
        return access
    }
    func items() async -> [MusicLibraryItem] { access == .authorized ? songs : [] }
    func artwork(for id: String, side: CGFloat) -> UIImage? {
        let hue = CGFloat(id.unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value) * 67) % 360 }) / 360
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            UIColor(hue: hue, saturation: 0.55, brightness: 0.85, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            UIColor(hue: hue, saturation: 0.7, brightness: 0.55, alpha: 1).setFill()
            UIBezierPath(ovalIn: CGRect(x: side * 0.2, y: side * 0.2, width: side * 0.6, height: side * 0.6)).fill()
        }
    }
    nonisolated static func sample(now: Date = .now) -> [MusicLibraryItem] {
        func ago(_ days: Int) -> Date { now.addingTimeInterval(-Double(days) * 86_400) }
        return [
            .init(id: "1", title: "Pink + White", artist: "Frank Ocean", album: "Blonde", genre: "R&B/Soul", playCount: 212, lastPlayed: ago(1)),
            .init(id: "2", title: "Nights", artist: "Frank Ocean", album: "Blonde", genre: "R&B/Soul", playCount: 148, lastPlayed: ago(3)),
            .init(id: "3", title: "Motion Sickness", artist: "Phoebe Bridgers", album: "Stranger in the Alps", genre: "Alternative", playCount: 131, lastPlayed: ago(40)),
            .init(id: "4", title: "Nightcall", artist: "Kavinsky", album: "OutRun", genre: "Electronic", playCount: 97, lastPlayed: ago(2)),
            .init(id: "5", title: "Kyoto", artist: "Phoebe Bridgers", album: "Punisher", genre: "Alternative", playCount: 88, lastPlayed: ago(12)),
            .init(id: "6", title: "Redbone", artist: "Childish Gambino", album: "Awaken, My Love!", genre: "R&B/Soul", playCount: 64, lastPlayed: ago(90)),
            .init(id: "7", title: "Midnight City", artist: "M83", album: "Hurry Up, We're Dreaming", genre: "Electronic", playCount: 51, lastPlayed: ago(5)),
            .init(id: "8", title: "Holocene", artist: "Bon Iver", album: "Bon Iver", genre: "Alternative", playCount: 33, lastPlayed: ago(200)),
            .init(id: "9", title: "Unplayed", artist: "Nobody", album: "", genre: "Pop", playCount: 0, lastPlayed: nil),
        ]
    }
}

#if DEBUG
/// A filled-in profile for UI tests and screenshots (`--ui-testing --profile-sample`), written into
/// the test's own temporary profile folder. Never part of a release build.
extension ProfileStore {
    func seedSample() {
        guard profile.media.isEmpty, profile.experience.isEmpty else { return }
        let colors: [UIColor] = [.systemPink, .systemOrange, .systemTeal, .systemIndigo, .systemMint, .systemPurple, .systemYellow]
        for (index, color) in colors.enumerated() {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 1100)).image { context in
                let hueShift = CGFloat(index) / CGFloat(colors.count)
                color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 900, height: 1100))
                UIColor(hue: hueShift, saturation: 0.35, brightness: 1, alpha: 0.55).setFill()
                UIBezierPath(ovalIn: CGRect(x: 120 + CGFloat(index * 40), y: 200, width: 620, height: 620)).fill()
                UIColor.white.withAlphaComponent(0.25).setFill()
                UIBezierPath(rect: CGRect(x: 0, y: 820, width: 900, height: 280)).fill()
            }
            guard let data = image.jpegData(compressionQuality: 0.85), let prepared = try? ProfileStore.preparePhoto(data) else { continue }
            let taken = Calendar.current.date(byAdding: .day, value: -index * 3, to: .now)
            try? insert(prepared, caption: index == 0 ? "Golden hour on the pier" : index == 2 ? "Soup roll #2" : nil, takenAt: taken)
        }
        update { profile in
            profile.name = "Avery Chen"; profile.handle = "avery"
            profile.headline = "Product designer at Northwind Labs"
            profile.bio = "Film photos, synths, and slow mornings."
            profile.accent = "#E8735A"
            profile.about = "I design calm, friendly software. Eight years across mobile and wearables, most recently leading design for a companion app on iPhone, Apple Watch, and Mac."
            profile.experience = [
                WorkEntry(title: "Lead Product Designer", company: "Northwind Labs", location: "San Francisco, CA", start: ProfileMonth(year: 2024, month: 2),
                          summary: "Lead design for KemoSabe on iPhone, Apple Watch, and Mac. Built the design system and the companion's animation suite."),
                WorkEntry(title: "Product Designer", company: "Northwind Labs", location: "San Francisco, CA", start: ProfileMonth(year: 2021, month: 6), end: ProfileMonth(year: 2024, month: 1),
                          summary: "Designed onboarding and the first watch app."),
                WorkEntry(title: "Designer", company: "Tidepool Studio", location: "Oakland, CA", start: ProfileMonth(year: 2018, month: 9), end: ProfileMonth(year: 2021, month: 5)),
            ]
            profile.education = [EducationEntry(school: "Rhode Island School of Design", degree: "BFA, Graphic Design", start: ProfileMonth(year: 2014), end: ProfileMonth(year: 2018))]
            profile.certifications = [CertificationEntry(name: "Certified Accessibility Professional", authority: "IAAP", issued: ProfileMonth(year: 2023, month: 4))]
            profile.skills = ["Interaction design", "Prototyping", "SwiftUI", "Design systems", "Motion", "User research", "Figma", "Accessibility", "Typography", "Illustration", "Film photography", "Workshops"]
            profile.languages = [LanguageEntry(name: "English", proficiency: "Native or bilingual"), LanguageEntry(name: "Mandarin", proficiency: "Professional working")]
            profile.interests = ["Film photography", "Synths", "Climbing", "Ramen"]
            profile.facts = [ProfileFact(label: "Lives in", value: "San Francisco"), ProfileFact(label: "Pronouns", value: "she/her")]
            profile.links = [ProfileLink(platform: .instagram, value: "avery.film"), ProfileLink(platform: .linkedIn, value: "averychen"),
                             ProfileLink(platform: .youtube, value: "averymakes"), ProfileLink(platform: .website, value: "avery.design")]
            profile.blog = ProfileBlog(address: "avery.design", feed: "https://avery.design/feed", title: "Notes from the studio", entries: [
                BlogEntry(title: "Designing a companion that breathes", link: "https://avery.design/breathes", date: .now.addingTimeInterval(-4 * 86_400),
                          summary: "How we made KemoSabe feel alive without making it loud."),
                BlogEntry(title: "Soup: film that soaked", link: "https://avery.design/soup", date: .now.addingTimeInterval(-20 * 86_400),
                          summary: "Notes on a generative film look."),
            ], refreshed: .now)
        }
        if let first = profile.media.last { pin(first.id) }
        WatchLink.PetSummary(level: 4, xp: 150, streak: 6, starved: 1, updated: .now).save()
    }
}
#endif

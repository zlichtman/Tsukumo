import Foundation
import TsukumoCore
import TsukumoPolicy
#if os(iOS)
import CoreLocation
import MapKit
import MediaPlayer
#endif

// Location and Music, on iPhone (ported from legacy/ios/KemoSabe/PersonalSourcesPhone.swift and new):
//
// - Location: "near me". Only for a question about where the owner is or what's close, Apple's When In Use
//   location, rounded to about a kilometer, read once per question and kept ten minutes in memory only.
//   Apple Maps may name the area from the rounded coordinates.
// - Music: what's playing in the Music app and what the owner played lately from their library, for a
//   question about music.

// MARK: Location

/// This device's approximate location.
public struct CoarsePlace: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    /// "Mission District, San Francisco", when Apple Maps could name it.
    public var area: String?
    public init(latitude: Double, longitude: Double, area: String? = nil) { self.latitude = latitude; self.longitude = longitude; self.area = area }
    /// About a kilometer: two decimal places.
    public var text: String {
        let coordinates = String(format: "%.2f, %.2f", latitude, longitude)
        return (area.map { "Near \($0) (about \(coordinates))" } ?? "About \(coordinates)") + ", accurate to roughly a kilometer."
    }
}

public protocol CoarseLocating: Sendable {
    func current() async throws -> CoarsePlace
}

/// "Near me", only for a question about where the owner is or what's close.
public struct LocationSource: PersonalSource {
    public let level: PrivacyLevel
    public let locator: any CoarseLocating
    static let cues = ["near me", "nearby", "near here", "around me", "around here", "close to me", "closest", "nearest", "where am i",
                       "my location", "where i am", "in my area", "local", "walking distance"]
    public init(level: PrivacyLevel, locator: any CoarseLocating) { self.level = level; self.locator = locator }
    public static func asksAboutPlace(_ question: String) -> Bool { MessagesQuery.mentions(question, any: cues) }
    public func items(matching question: GateQuestion) async -> [PersonalItem] {
        guard Self.asksAboutPlace(question.question), let place = try? await locator.current() else { return [] }
        return [PersonalItem(id: "location:approximate", kind: .location, level: level, title: "your approximate location",
                             text: "Where you are now: " + place.text, date: question.receivedAt, matched: true)]
    }
}

#if os(iOS)
/// Apple's When In Use location, rounded to about a kilometer, read once per question and kept ten minutes
/// in memory only.
@MainActor public final class SystemCoarseLocator: NSObject, CoarseLocating, CLLocationManagerDelegate {
    public static let shared = SystemCoarseLocator()
    private let manager = CLLocationManager()
    private var permissionWaiters: [CheckedContinuation<SourcePermission, Never>] = []
    private var locationWaiters: [CheckedContinuation<CLLocation, Error>] = []
    private var recent: (place: CoarsePlace, at: Date)?
    private var reading = 0
    struct Unavailable: Error {}

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced
    }
    public var permission: SourcePermission {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: .granted
        case .denied: .denied
        case .restricted: .restricted
        default: .notDetermined
        }
    }
    public func request() async -> SourcePermission {
        guard permission == .notDetermined else { return permission }
        return await withCheckedContinuation { continuation in
            permissionWaiters.append(continuation)
            manager.requestWhenInUseAuthorization()
        }
    }
    public func current() async throws -> CoarsePlace {
        guard permission == .granted else { throw Unavailable() }
        if let recent, Date().timeIntervalSince(recent.at) < 600 { return recent.place }
        let location = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CLLocation, Error>) in
            locationWaiters.append(continuation)
            guard locationWaiters.count == 1 else { return }
            reading += 1
            let attempt = reading
            manager.requestLocation()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard let self, self.reading == attempt else { return }
                self.finishLocation(.failure(Unavailable()))
            }
        }
        let latitude = (location.coordinate.latitude * 100).rounded() / 100, longitude = (location.coordinate.longitude * 100).rounded() / 100
        let place = CoarsePlace(latitude: latitude, longitude: longitude, area: await PlaceNames.shared.name(latitude: latitude, longitude: longitude))
        recent = (place, Date())
        return place
    }
    private func finishLocation(_ result: Result<CLLocation, Error>) {
        reading += 1
        let waiters = locationWaiters; locationWaiters = []
        for waiter in waiters { waiter.resume(with: result) }
    }
    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.permission != .notDetermined else { return }
            let waiters = self.permissionWaiters; self.permissionWaiters = []
            for waiter in waiters { waiter.resume(returning: self.permission) }
        }
    }
    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in self.finishLocation(.success(location)) }
    }
    nonisolated public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finishLocation(.failure(error)) }
    }
}
#endif

// MARK: Music

/// One song.
public struct ListenedSong: Hashable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    public var lastPlayed: Date?
    public var playCount: Int
    public init(title: String, artist: String, album: String = "", lastPlayed: Date? = nil, playCount: Int = 0) {
        self.title = title; self.artist = artist; self.album = album; self.lastPlayed = lastPlayed; self.playCount = playCount
    }
    var line: String {
        var line = "“\(title)” by \(artist.isEmpty ? "an unknown artist" : artist)"
        if !album.isEmpty { line += " (\(album))" }
        return line
    }
}

public protocol ListeningReading: Sendable {
    func nowPlaying() async -> ListenedSong?
    func recentlyPlayed(limit: Int) async -> [ListenedSong]
}

/// What's playing and what the owner played lately, for a question about music.
public struct MusicSource: PersonalSource {
    public let level: PrivacyLevel
    public let reader: any ListeningReading
    static let cues = ["music", "song", "songs", "listening", "listen", "listened", "playing", "artist", "album", "track", "band", "playlist", "tune"]
    public init(level: PrivacyLevel, reader: any ListeningReading) { self.level = level; self.reader = reader }
    public func items(matching question: GateQuestion) async -> [PersonalItem] {
        guard MessagesQuery.mentions(question.question, any: Self.cues) else { return [] }
        var items: [PersonalItem] = []
        if let song = await reader.nowPlaying() {
            items.append(PersonalItem(id: "music:now", kind: .music, level: level, title: "what’s playing", text: "Playing now: " + song.line + ".",
                                      date: question.receivedAt, matched: true))
        }
        let recent = await reader.recentlyPlayed(limit: 25)
        if !recent.isEmpty {
            let lines = recent.map { song in
                song.line + (song.lastPlayed.map { ", last played " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
                    + (song.playCount > 0 ? ", played \(song.playCount) times" : "")
            }
            items.append(PersonalItem(id: "music:recent", kind: .music, level: level, title: "what you played lately",
                                      text: "Played lately:\n" + lines.joined(separator: "\n"), date: recent.first?.lastPlayed, matched: true))
        }
        return items
    }
}

#if os(iOS)
/// The Music app's player and the owner's library (media library permission).
public struct SystemListening: ListeningReading {
    public init() {}
    public static var status: SourcePermission {
        switch MPMediaLibrary.authorizationStatus() {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        default: .denied
        }
    }
    public static func request() async -> SourcePermission {
        await withCheckedContinuation { continuation in MPMediaLibrary.requestAuthorization { _ in continuation.resume() } }
        return status
    }
    public func nowPlaying() async -> ListenedSong? {
        guard Self.status == .granted else { return nil }
        return await MainActor.run {
            MPMusicPlayerController.systemMusicPlayer.nowPlayingItem.map(Self.song)
        }
    }
    public func recentlyPlayed(limit: Int) async -> [ListenedSong] {
        guard Self.status == .granted else { return [] }
        let items = MPMediaQuery.songs().items ?? []
        return items.filter { $0.lastPlayedDate != nil }.sorted { ($0.lastPlayedDate ?? .distantPast) > ($1.lastPlayedDate ?? .distantPast) }
            .prefix(limit).map(Self.song)
    }
    static func song(_ item: MPMediaItem) -> ListenedSong {
        ListenedSong(title: item.title ?? "Untitled", artist: item.artist ?? "", album: item.albumTitle ?? "", lastPlayed: item.lastPlayedDate,
                     playCount: item.playCount)
    }
}
#endif

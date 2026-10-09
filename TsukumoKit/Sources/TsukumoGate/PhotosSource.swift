import Foundation
import Photos
import ImageIO
import CoreGraphics
#if canImport(MapKit)
import CoreLocation
import MapKit
#endif
import TsukumoCore
import TsukumoPolicy

// Photos: what the photo library says about the owner's photos (PhotoKit metadata), never the pictures:
// their albums (names, how many, when), and the days they took photos, with roughly where (rounded to about
// ten kilometers, named by Apple Maps when it can). It answers "When was I last in Tahoe?" or "How many
// photos from the wedding?". PhotoKit has no public way to read the People album's names, so people aren't
// part of it. On a Mac the app needs the Photos entitlement under the hardened runtime.

/// One album.
public struct PhotoAlbum: Hashable, Sendable {
    public var id: String
    public var title: String
    public var count: Int
    public var start: Date?
    public var end: Date?
    public init(id: String, title: String, count: Int, start: Date? = nil, end: Date? = nil) {
        self.id = id; self.title = title; self.count = count; self.start = start; self.end = end
    }
}

/// The photos taken on one day around one place.
public struct PhotoDay: Hashable, Sendable {
    public var day: Date
    public var count: Int
    /// Rounded to about ten kilometers.
    public var latitude: Double?
    public var longitude: Double?
    public init(day: Date, count: Int, latitude: Double? = nil, longitude: Double? = nil) {
        self.day = day; self.count = count; self.latitude = latitude; self.longitude = longitude
    }
}

/// One photo, as a list of what could be shared shows it: when, how big. Never where, never the picture.
public struct PhotoAsset: Hashable, Sendable {
    public var id: String
    public var date: Date?
    public var width: Int
    public var height: Int
    public init(id: String, date: Date?, width: Int, height: Int) { self.id = id; self.date = date; self.width = width; self.height = height }
}

public protocol PhotoLibraryReading: Sendable {
    func albums() async -> [PhotoAlbum]
    func days(from start: Date, to end: Date) async -> [PhotoDay]
    /// A place's name ("Truckee, California"), or nil.
    func placeName(latitude: Double, longitude: Double) async -> String?
    /// The newest photos, or those in the album with this title (for the KemoSabe gateway's list).
    func assets(album: String?, limit: Int) async -> [PhotoAsset]
    /// One photo as a JPEG no larger than `maxDimension` on its long side, with every bit of its metadata
    /// stripped; with `location`, only a rough place (about a kilometer) is written back. Never downloads.
    func jpeg(_ id: String, maxDimension: Int, location: Bool) async -> Data?
}

public extension PhotoLibraryReading {
    func assets(album: String?, limit: Int) async -> [PhotoAsset] { [] }
    func jpeg(_ id: String, maxDimension: Int, location: Bool) async -> Data? { nil }
}

/// Re-encodes a picture as a small JPEG with nothing but its pixels: no EXIF, no GPS, no maker notes, no
/// thumbnails. A rough location is written back only when asked.
public enum PhotoJPEG {
    public static func downscale(_ data: Data, maxDimension: Int, latitude: Double? = nil, longitude: Double? = nil) -> Data? {
        guard maxDimension > 0, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxDimension, kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return nil }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.82]
        if let latitude, let longitude {
            let lat = (latitude * 100).rounded() / 100, lon = (longitude * 100).rounded() / 100
            properties[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: abs(lat), kCGImagePropertyGPSLatitudeRef: lat >= 0 ? "N" : "S",
                                                         kCGImagePropertyGPSLongitude: abs(lon), kCGImagePropertyGPSLongitudeRef: lon >= 0 ? "E" : "W"]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }
}

/// The albums and days that could answer a question.
public struct PhotosSource: PersonalSource {
    public let level: PrivacyLevel
    public let library: any PhotoLibraryReading
    /// At most this many places are named per question.
    public static let maxNamedPlaces = 8
    static let cues = ["photo", "photos", "picture", "pictures", "pic", "pics", "album", "albums", "trip", "vacation", "where was i",
                       "last in", "went to", "visited", "took"]

    public init(level: PrivacyLevel, library: any PhotoLibraryReading = SystemPhotoLibrary()) { self.level = level; self.library = library }

    public func items(matching question: GateQuestion) async -> [PersonalItem] {
        let asks = MessagesQuery.mentions(question.question, any: Self.cues)
        let terms = Extraction.terms(question.question)
        var items: [PersonalItem] = []
        for album in await library.albums() {
            let named = !Extraction.terms(album.title).intersection(terms).isEmpty
            guard asks || named else { continue }
            var text = "Album “\(album.title)”: \(album.count) photo" + (album.count == 1 ? "" : "s")
            if let start = album.start, let end = album.end {
                text += ", " + start.formatted(date: .long, time: .omitted) + (Calendar.current.isDate(start, inSameDayAs: end) ? "" : " to " + end.formatted(date: .long, time: .omitted))
            }
            items.append(PersonalItem(id: "photo-album:" + album.id, kind: .photo, level: level, title: "your photo album “\(album.title)”",
                                      text: text + ".", date: album.end, matched: named || asks))
        }
        guard asks else { return items }
        let window = MessagesQuery.parse(question.question, now: question.receivedAt, defaultDays: 365)
        var named = 0
        for day in await library.days(from: window.since, to: window.until).sorted(by: { $0.day > $1.day }).prefix(60) {
            var place: String?
            if let latitude = day.latitude, let longitude = day.longitude {
                if named < Self.maxNamedPlaces {
                    named += 1
                    place = await library.placeName(latitude: latitude, longitude: longitude)
                }
                place = place ?? String(format: "about %.1f, %.1f", latitude, longitude)
            }
            let text = "Photos on " + day.day.formatted(date: .complete, time: .omitted) + ": \(day.count)" + (place.map { ", near " + $0 } ?? "") + "."
            items.append(PersonalItem(id: "photo-day:\(Int(day.day.timeIntervalSince1970)):\(day.latitude ?? 0):\(day.longitude ?? 0)", kind: .photo,
                                      level: level, title: "your photos", text: text, date: day.day, matched: true))
        }
        return items
    }
}

/// The system's photo library.
public struct SystemPhotoLibrary: PhotoLibraryReading {
    public init() {}
    public static var status: SourcePermission {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited: .granted
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        default: .denied
        }
    }
    public static func request() async -> SourcePermission {
        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status
    }

    public func albums() async -> [PhotoAlbum] {
        guard Self.status == .granted else { return [] }
        var list: [PhotoAlbum] = []
        for type in [PHAssetCollectionType.album] {
            let collections = PHAssetCollection.fetchAssetCollections(with: type, subtype: .any, options: nil)
            collections.enumerateObjects { collection, _, stop in
                let options = PHFetchOptions()
                options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
                let assets = PHAsset.fetchAssets(in: collection, options: options)
                guard assets.count > 0 else { return }
                list.append(PhotoAlbum(id: collection.localIdentifier, title: collection.localizedTitle ?? "Untitled", count: assets.count,
                                       start: assets.firstObject?.creationDate, end: assets.lastObject?.creationDate))
                if list.count >= 80 { stop.pointee = true }
            }
        }
        return list
    }

    public func days(from start: Date, to end: Date) async -> [PhotoDay] {
        guard Self.status == .granted else { return [] }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate <= %@", start as NSDate, end as NSDate)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 6000
        let assets = PHAsset.fetchAssets(with: options)
        var groups: [String: PhotoDay] = [:]
        let calendar = Calendar.current
        assets.enumerateObjects { asset, _, _ in
            guard let date = asset.creationDate else { return }
            let day = calendar.startOfDay(for: date)
            let latitude = asset.location.map { ($0.coordinate.latitude * 10).rounded() / 10 }
            let longitude = asset.location.map { ($0.coordinate.longitude * 10).rounded() / 10 }
            let key = "\(day.timeIntervalSince1970)|\(latitude ?? 999)|\(longitude ?? 999)"
            groups[key, default: PhotoDay(day: day, count: 0, latitude: latitude, longitude: longitude)].count += 1
        }
        return Array(groups.values)
    }

    public func placeName(latitude: Double, longitude: Double) async -> String? {
        await PlaceNames.shared.name(latitude: latitude, longitude: longitude)
    }

    public func assets(album: String?, limit: Int) async -> [PhotoAsset] {
        guard Self.status == .granted else { return [] }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = max(1, min(limit, 200))
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        var fetched: PHFetchResult<PHAsset>
        if let album, !album.isEmpty {
            let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
            var match: PHAssetCollection?
            collections.enumerateObjects { collection, _, stop in
                if collection.localizedTitle?.localizedCaseInsensitiveCompare(album) == .orderedSame { match = collection; stop.pointee = true }
            }
            guard let match else { return [] }
            fetched = PHAsset.fetchAssets(in: match, options: options)
        } else {
            fetched = PHAsset.fetchAssets(with: options)
        }
        var list: [PhotoAsset] = []
        fetched.enumerateObjects { asset, _, _ in
            list.append(PhotoAsset(id: asset.localIdentifier, date: asset.creationDate, width: asset.pixelWidth, height: asset.pixelHeight))
        }
        return list
    }

    public func jpeg(_ id: String, maxDimension: Int, location: Bool) async -> Data? {
        guard Self.status == .granted, let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject,
              asset.mediaType == .image else { return nil }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false
        options.deliveryMode = .highQualityFormat
        options.version = .current
        let data: Data? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
        guard let data else { return nil }
        let place = location ? asset.location?.coordinate : nil
        return PhotoJPEG.downscale(data, maxDimension: maxDimension, latitude: place?.latitude, longitude: place?.longitude)
    }
}

/// Apple Maps' names for rounded places, kept in memory for the session.
actor PlaceNames {
    static let shared = PlaceNames()
    private var cache: [String: String?] = [:]
    func name(latitude: Double, longitude: Double) async -> String? {
        let key = String(format: "%.2f,%.2f", latitude, longitude)
        if let known = cache[key] { return known }
        var name: String?
        #if canImport(MapKit)
        if #available(iOS 26, macOS 26, *),
           let request = MKReverseGeocodingRequest(location: CLLocation(latitude: latitude, longitude: longitude)),
           let item = try? await request.mapItems.first {
            name = item.addressRepresentations?.cityWithContext
        }
        #endif
        cache[key] = name
        return name
    }
}

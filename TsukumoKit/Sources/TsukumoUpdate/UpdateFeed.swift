#if os(macOS)
import Foundation

// Tsukumo's Dock updates itself from the owner's website (docs/ARCHITECTURE.md, "Updates"). The feed is
// https://zlichtman.com/downloads/tsukumo.json, written by scripts/release-mac.sh:
//
//   {"version": "2.04", "build": 204, "url": "https://zlichtman.com/downloads/Tsukumo-2.04.dmg",
//    "sha256": "<64 hex>", "minimumMacOS": "26.0", "notes": "<one short line>"}
//
// Everything here is checked before anything is downloaded, and the download is checked again before
// anything is installed (UpdateVerifier).

/// Who an update must come from and be: the app's bundle ID, its team, and its name in the disk image.
public struct UpdateIdentity: Equatable, Sendable {
    public let bundleIdentifier: String
    public let teamIdentifier: String
    public let appName: String

    public init(bundleIdentifier: String, teamIdentifier: String, appName: String) {
        self.bundleIdentifier = bundleIdentifier; self.teamIdentifier = teamIdentifier; self.appName = appName
    }

    /// Tsukumo's Dock: Developer ID, team 28LJG7MXT3.
    public static let tsukumo = UpdateIdentity(bundleIdentifier: "com.zlichtman.tsukumo.mac", teamIdentifier: "28LJG7MXT3", appName: "Tsukumo.app")

    /// The code requirement the new app must satisfy: Apple's anchor, this team's leaf certificate, and this
    /// bundle ID.
    public var requirement: String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\" and identifier \"\(bundleIdentifier)\""
    }

    /// The same, narrowed to Developer ID (the Developer ID CA and a Developer ID Application leaf), so a
    /// build signed for development by the same team doesn't pass either.
    public var developerIDRequirement: String {
        requirement + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    }
}

/// The rules for where updates come from, and their limits.
public enum UpdatePolicy {
    /// The one host the feed and the download may come from (and redirect within).
    public static let host = "zlichtman.com"
    public static let feedURL = URL(string: "https://zlichtman.com/downloads/tsukumo.json")!
    /// The feed is a few hundred bytes.
    public static let maxFeedBytes = 64 * 1024
    /// The DMG is about 22 MB; anything over this is refused while it downloads.
    public static let maxDownloadBytes = 400 * 1024 * 1024
    public static let feedTimeout: TimeInterval = 30
    public static let downloadTimeout: TimeInterval = 20 * 60
    /// Automatic checks: a few seconds after launch, then every six hours while Tsukumo runs.
    public static let launchDelay: Duration = .seconds(10)
    public static let checkInterval: TimeInterval = 6 * 60 * 60
    /// The notes shown under "Version X is available" are cut to this many characters.
    public static let maxNotesLength = 400

    /// HTTPS on exactly zlichtman.com: no other host or subdomain, no user or password, no port but 443.
    public static func isAllowed(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), host == Self.host,
              url.user == nil, url.password == nil else { return false }
        if let port = url.port, port != 443 { return false }
        return true
    }

    /// A DMG under /downloads/ on the allowed host.
    public static func isAllowedDownload(_ url: URL?) -> Bool {
        guard isAllowed(url), let url else { return false }
        let path = url.path
        guard path.hasPrefix("/downloads/"), path.lowercased().hasSuffix(".dmg"), url.query == nil, url.fragment == nil else { return false }
        return !url.pathComponents.contains("..") && !path.contains("//")
    }

    /// Builds (CFBundleVersion) are compared, never version strings.
    public static func isNewer(_ build: Int, than current: Int) -> Bool { build > current }

    /// "26.0" or "26.0.1" as an OperatingSystemVersion, or nil.
    public static func osVersion(_ text: String) -> OperatingSystemVersion? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), let number = Int(part), number >= 0 else { return nil }
            numbers.append(number)
        }
        return OperatingSystemVersion(majorVersion: numbers[0], minorVersion: numbers.count > 1 ? numbers[1] : 0,
                                      patchVersion: numbers.count > 2 ? numbers[2] : 0)
    }

    /// Whether `running` is at least `minimum`.
    public static func satisfies(_ minimum: OperatingSystemVersion, running: OperatingSystemVersion) -> Bool {
        (running.majorVersion, running.minorVersion, running.patchVersion) >= (minimum.majorVersion, minimum.minorVersion, minimum.patchVersion)
    }
}

/// tsukumo.json, checked.
public struct UpdateFeed: Equatable, Sendable {
    public let version: String
    public let build: Int
    public let url: URL
    public let sha256: String
    public let minimumMacOS: String
    public let notes: String

    public init(version: String, build: Int, url: URL, sha256: String, minimumMacOS: String, notes: String) {
        self.version = version; self.build = build; self.url = url; self.sha256 = sha256; self.minimumMacOS = minimumMacOS; self.notes = notes
    }

    private struct Wire: Decodable {
        let version: String
        let build: Int
        let url: String
        let sha256: String
        let minimumMacOS: String
        let notes: String?
    }

    /// Parses and checks the feed: its size, a plain version and a positive build, the DMG's address (HTTPS
    /// on zlichtman.com under /downloads/), a 64-digit SHA-256, and a macOS version. Notes are one line, cut
    /// short.
    public static func parse(_ data: Data) throws(UpdateFailure) -> UpdateFeed {
        guard data.count <= UpdatePolicy.maxFeedBytes else { throw .tooLarge }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { throw .feedInvalid }
        let version = wire.version.trimmingCharacters(in: .whitespaces)
        guard isPlainVersion(version), wire.build > 0 else { throw .feedInvalid }
        guard let url = URL(string: wire.url), UpdatePolicy.isAllowedDownload(url) else { throw .untrustedLocation }
        let sha = wire.sha256.lowercased()
        guard sha.count == 64, sha.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { throw .feedInvalid }
        guard UpdatePolicy.osVersion(wire.minimumMacOS) != nil else { throw .feedInvalid }
        var notes = (wire.notes ?? "").split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if notes.count > UpdatePolicy.maxNotesLength { notes = String(notes.prefix(UpdatePolicy.maxNotesLength - 1)) + "…" }
        return UpdateFeed(version: version, build: wire.build, url: url, sha256: sha, minimumMacOS: wire.minimumMacOS, notes: notes)
    }

    /// Digits and dots: "2.04", "2.4.1".
    static func isPlainVersion(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return (1...4).contains(parts.count) && parts.allSatisfy { !$0.isEmpty && $0.count <= 6 && $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }
}

/// Why an update didn't happen, in plain words.
public enum UpdateFailure: Error, Equatable, Sendable {
    case offline
    case badResponse(Int)
    case feedInvalid
    case untrustedLocation
    case tooLarge
    case checksumMismatch
    case mountFailed
    case appMissing
    case wrongBundle
    case notNewer
    case mismatch
    case needsNewerMacOS(String)
    case wrongArchitecture
    case badSignature
    case notNotarized
    case copyFailed
    case translocated
    case onDiskImage
    case notWritable
    case installFailed
    case unsafeApp
    case busy
    case cantSwap
    case cancelled
    case swapBackFailed(String)

    public var message: String {
        switch self {
        case .offline: "Couldn’t reach zlichtman.com. Check your connection and try again."
        case .badResponse(let code): "The update server answered with an error (\(code))."
        case .feedInvalid: "The update information couldn’t be read."
        case .untrustedLocation: "The update pointed somewhere other than zlichtman.com, so it was ignored."
        case .tooLarge: "The download was larger than expected, so it was stopped."
        case .checksumMismatch: "The download didn’t match its checksum, so it was thrown away."
        case .mountFailed: "The downloaded disk image couldn’t be opened."
        case .appMissing: "The disk image didn’t hold exactly one Tsukumo app."
        case .wrongBundle: "The downloaded app isn’t Tsukumo’s Dock."
        case .notNewer: "The downloaded app isn’t newer than this one."
        case .mismatch: "The downloaded app’s version doesn’t match the update information."
        case .needsNewerMacOS(let minimum): "This update needs macOS \(minimum) or later."
        case .wrongArchitecture: "This update doesn’t run on this Mac’s processor."
        case .badSignature: "The downloaded app isn’t signed by Tsukumo’s developer, so it was thrown away."
        case .notNotarized: "The downloaded app isn’t notarized by Apple, so it was thrown away."
        case .copyFailed: "The update couldn’t be prepared. Try again."
        case .translocated: "Move Tsukumo to your Applications folder, open it from there, then install the update."
        case .onDiskImage: "Tsukumo is running from its disk image. Drag it to Applications, open it from there, then install the update."
        case .notWritable: "Tsukumo can’t replace itself in its folder. Open the download and drag Tsukumo to Applications instead."
        case .installFailed: "The update couldn’t be installed. Your current version is unchanged."
        case .unsafeApp: "The downloaded app holds something an app shouldn’t, so it was thrown away."
        case .busy: "Another copy of Tsukumo is installing an update. Try again in a moment."
        case .cantSwap: "Tsukumo can’t replace itself safely on this disk. Open the download and drag Tsukumo to Applications instead."
        case .cancelled: "The update was stopped."
        case .swapBackFailed(let previous): "The new version failed its last check, and your previous version couldn’t be put back. It’s at \(previous). Move the new Tsukumo.app beside it to the Trash, then rename the previous one Tsukumo.app and open it."
        }
    }

    /// The owner can install by hand from the kept DMG instead.
    public var offersDownload: Bool { self == .notWritable || self == .cantSwap }

    /// A build this Mac can never run (decided only after its signature passed): remembered for a while, so it
    /// isn't downloaded again.
    public var isUnrunnable: Bool {
        switch self {
        case .needsNewerMacOS, .wrongArchitecture: true
        default: false
        }
    }
}
#endif

import Darwin
import Foundation
import TsukumoCore
import TsukumoGate
import TsukumoPolicy
import UniformTypeIdentifiers
import ImageIO
import CoreGraphics

// What the content tools read, through KemoSabe's own catalog and readers: the files and folders the owner
// picked (their bookmarks), this Mac's Messages history (`MessagesDatabase`, read only), and the photo library
// (`PhotoLibraryReading`). Nothing here indexes or copies anything; each call reads what it needs.

/// Something a caller could ask for, as a list shows it: a name, an id, a size. Never what's in it.
public struct ShareableItem: Hashable, Sendable {
    public var id: String
    public var kind: ShareKind
    public var name: String
    /// Bytes for a file; messages for a conversation; pixels on the long side for a photo.
    public var size: Int?
    public var date: Date?
    public var level: PrivacyLevel
    public init(id: String, kind: ShareKind, name: String, size: Int? = nil, date: Date? = nil, level: PrivacyLevel) {
        self.id = id; self.kind = kind; self.name = name; self.size = size; self.date = date; self.level = level
    }
}

/// A picked folder (or file) the gateway can see into, at the owner's level for it.
public struct ShareableFolder: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var level: PrivacyLevel
    public init(id: UUID, name: String, level: PrivacyLevel) { self.id = id; self.name = name; self.level = level }
}

/// A file, read for sharing.
public struct SharedFile: Hashable, Sendable {
    public var name: String
    public var mimeType: String
    public var data: Data
    public var level: PrivacyLevel
    /// Its text, when it's a text file that reads as UTF-8 (sent inline; anything else goes as a blob).
    public var text: String? {
        guard let type = UTType(mimeType: mimeType), type.conforms(to: .text) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// One message in an excerpt.
public struct ExcerptMessage: Hashable, Sendable {
    public var sender: String
    public var fromMe: Bool
    public var date: Date
    public var text: String
    public init(sender: String, fromMe: Bool, date: Date, text: String) { self.sender = sender; self.fromMe = fromMe; self.date = date; self.text = text }
}

/// Why a file can't be read.
public enum ContentProblem: Error, Hashable, Sendable {
    case notFound, tooLarge(Int), outsideFolder
    /// Picked before folders' identities were kept: the owner picks it again.
    case unanchored
}

/// Where the content tools read from. `LibraryContent` is the real one; `FixtureContent` serves made-up items to
/// tests and `--ui-testing`.
@MainActor public protocol GatewayContent: AnyObject {
    /// The picked folders and files that are on.
    func folders() -> [ShareableFolder]
    func files(in folders: [UUID], query: String?, limit: Int) -> [ShareableItem]
    func file(_ id: String, maxBytes: Int) -> Result<SharedFile, ContentProblem>
    /// Messages' level, or nil when it's off or macOS hasn't allowed it.
    var messagesLevel: PrivacyLevel? { get }
    func threads(query: String?, limit: Int) async -> [ShareableItem]
    /// The newest `limit` messages of a conversation (by its id) or with a person (by name), oldest first.
    func messages(thread: String?, contact: String?, since: Date, until: Date, limit: Int) async -> [ExcerptMessage]
    var photosLevel: PrivacyLevel? { get }
    func photos(album: String?, limit: Int) async -> [ShareableItem]
    func photo(_ id: String, maxDimension: Int, location: Bool) async -> Data?
}

// MARK: Files, safely

/// Turning a caller's file id into a file without leaving the folder the owner picked.
public enum GatewayFiles {
    public static let maxScanned = 3_000
    /// "file:<folder>:<path inside it>".
    public static func id(folder: UUID, path: String) -> String { "file:" + folder.uuidString + ":" + path }
    public static func parse(_ id: String) -> (folder: UUID, path: String)? {
        let parts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "file", let folder = UUID(uuidString: parts[1]), !parts[2].isEmpty else { return nil }
        return (folder, parts[2])
    }

    /// The parts of a relative path, or nil if it's absolute, climbs, hides, or is too long.
    static func components(_ relative: String) -> [String]? {
        guard relative.count <= 1_024, !relative.hasPrefix("/"), !relative.contains("\0"), !relative.contains("\\") else { return nil }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.count <= 64, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") }) else { return nil }
        return parts
    }

    /// Opens the anchored folder: the picked folder itself, or a picked file's parent, by the path as it is (never
    /// resolved first), without following a symlink, and only if it's still the folder the owner picked (`anchor`: its
    /// device and inode then). A symlink or another folder swapped in anywhere along the path is refused. Without an
    /// anchor (a pick from before anchors were kept) nothing is opened: the owner picks it again.
    static func anchored(root: URL, isFolder: Bool, anchor: FileAnchor?) -> Result<Int32, ContentProblem> {
        guard let anchor else { return .failure(.unanchored) }
        let base = root.standardizedFileURL
        let folder = isFolder ? base : base.deletingLastPathComponent()
        let dir = Darwin.open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { return .failure(errno == ENOENT ? .notFound : .outsideFolder) }
        var info = stat()
        guard fstat(dir, &info) == 0, UInt64(bitPattern: Int64(info.st_dev)) == anchor.device, UInt64(info.st_ino) == anchor.inode else {
            close(dir)
            return .failure(.outsideFolder)
        }
        return .success(dir)
    }

    /// Opens and reads the file `relative` names under the anchored folder, with no window between checking and
    /// reading: each folder below it is opened from the one before (`openat` with `O_NOFOLLOW`), the file's type and
    /// size come from `fstat` on the descriptor that was opened, and the bytes from that same descriptor, never more
    /// than `maxBytes`. A picked file is served only under its recorded name (`leaf`), opened from its anchored parent
    /// without following a link: whatever the file's path now resolves to doesn't matter.
    public static func open(root: URL, isFolder: Bool, leaf: String? = nil, relative: String, anchor: FileAnchor?, level: PrivacyLevel,
                            maxBytes: Int) -> Result<SharedFile, ContentProblem> {
        guard let parts = components(relative) else { return .failure(.outsideFolder) }
        if !isFolder { guard let leaf, parts == [leaf] else { return .failure(.outsideFolder) } }
        var dir: Int32
        switch anchored(root: root, isFolder: isFolder, anchor: anchor) {
        case .failure(let problem): return .failure(problem)
        case .success(let fd): dir = fd
        }
        for (index, part) in parts.enumerated() {
            let last = index == parts.count - 1
            let next = openat(dir, part, last ? (O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) : (O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
            let failure = errno
            close(dir)
            guard next >= 0 else { return .failure(failure == ENOENT ? .notFound : .outsideFolder) }
            dir = next
        }
        let fd = dir
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return .failure(.outsideFolder) }
        guard info.st_size <= off_t(maxBytes) else { return .failure(.tooLarge(Int(info.st_size))) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while data.count <= maxBytes {
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { return .failure(.notFound) }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        // The file grew while it was read: refused, never cut.
        guard data.count <= maxBytes else { return .failure(.tooLarge(data.count)) }
        let name = parts[parts.count - 1]
        let mime = UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return .success(SharedFile(name: name, mimeType: mime, data: data, level: level))
    }

    static let packageExtensions: Set<String> = ["app", "bundle", "framework", "photoslibrary", "musiclibrary", "xcodeproj", "xcworkspace", "pkg", "plugin"]
    static let skippedFolders: Set<String> = ["node_modules", "build", "DerivedData"]

    /// The files under the anchored folder whose path matches the query (all when there's none), newest first: the
    /// same identity check as reads, then a walk through descriptors (`fdopendir`, `readdir`, `fstatat` without
    /// following, `openat` with `O_NOFOLLOW` into each folder), so a symlink is never listed or entered and a folder
    /// swapped in shows nothing. A picked file lists only under its recorded name.
    public static func list(root: URL, isFolder: Bool, leaf: String? = nil, anchor: FileAnchor?, folder: UUID, level: PrivacyLevel,
                            query: String?, limit: Int) -> [ShareableItem] {
        guard case .success(let rootFD) = anchored(root: root, isFolder: isFolder, anchor: anchor) else { return [] }
        let wanted = query?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
        var items: [ShareableItem] = []
        func add(_ path: String, _ info: stat) {
            guard wanted.isEmpty || path.lowercased().contains(wanted) else { return }
            items.append(ShareableItem(id: id(folder: folder, path: path), kind: .files, name: path, size: Int(info.st_size),
                                       date: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)), level: level))
        }
        if !isFolder {
            defer { close(rootFD) }
            var info = stat()
            if let leaf, fstatat(rootFD, leaf, &info, AT_SYMLINK_NOFOLLOW) == 0, (info.st_mode & S_IFMT) == S_IFREG { add(leaf, info) }
            return items
        }
        var scanned = 0
        /// Lists one folder (taking ownership of its descriptor), then each folder in it, one descriptor deep at a time.
        func walk(_ fd: Int32, prefix: String, depth: Int) {
            guard let dir = fdopendir(fd) else { close(fd); return }
            defer { closedir(dir) }
            var folders: [String] = []
            while scanned < maxScanned, let entry = readdir(dir) {
                var raw = entry.pointee.d_name
                let name = withUnsafePointer(to: &raw) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
                guard !name.hasPrefix("."), !name.isEmpty else { continue }
                scanned += 1
                var info = stat()
                guard fstatat(dirfd(dir), name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                switch info.st_mode & S_IFMT {
                case S_IFREG: add(prefix + name, info)
                case S_IFDIR:
                    if depth < 16, !skippedFolders.contains(name), !packageExtensions.contains((name as NSString).pathExtension.lowercased()) { folders.append(name) }
                default: continue   // symlinks, devices, FIFOs: never listed or entered
                }
            }
            for name in folders where scanned < maxScanned {
                let child = openat(dirfd(dir), name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if child >= 0 { walk(child, prefix: prefix + name + "/", depth: depth + 1) }
            }
        }
        walk(rootFD, prefix: "", depth: 0)
        return Array(items.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(limit))
    }
}

// MARK: Messages, grouped

public enum GatewayMessages {
    /// Conversations from a run of messages, newest first: each one's id, a name, and how many messages.
    public static func threads(_ messages: [TextMessage], level: PrivacyLevel, query: String?, limit: Int) -> [ShareableItem] {
        var order: [String] = [], counts: [String: Int] = [:], names: [String: String] = [:], dates: [String: Date] = [:]
        var people: [String: [String]] = [:]
        for message in messages {
            if counts[message.chat] == nil { order.append(message.chat) }
            counts[message.chat, default: 0] += 1
            dates[message.chat] = max(dates[message.chat] ?? .distantPast, message.date)
            if let name = message.chatName { names[message.chat] = name }
            if !message.fromMe, !(people[message.chat] ?? []).contains(message.sender) { people[message.chat, default: []].append(message.sender) }
        }
        let wanted = query?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
        return order.compactMap { chat -> ShareableItem? in
            let others = people[chat] ?? []
            let name = names[chat] ?? (others.isEmpty ? "A conversation" : "Conversation with " + others.prefix(3).map(mask).joined(separator: ", "))
            guard wanted.isEmpty || name.lowercased().contains(wanted) || others.contains(where: { $0.lowercased().contains(wanted) }) else { return nil }
            return ShareableItem(id: "thread:" + chat, kind: .messages, name: name, size: counts[chat], date: dates[chat], level: level)
        }.prefix(limit).map { $0 }
    }
    /// A phone number or address as a list shows it: its last four characters ("•••0142").
    public static func mask(_ handle: String) -> String {
        handle.contains("@") || handle.filter(\.isNumber).count >= 7 ? "•••" + String(handle.suffix(4)) : handle
    }
}

// MARK: The real one

/// KemoSabe's catalog: the picked folders that are on, Messages and Photos while they're on and allowed.
@MainActor public final class LibraryContent: GatewayContent {
    private let library: SourceLibrary
    private let database: MessagesDatabase?
    private let contacts: any ContactsReading
    private let photoLibrary: any PhotoLibraryReading

    public init(library: SourceLibrary, messages: MessagesDatabase?, contacts: any ContactsReading = SystemContacts(),
                photos: any PhotoLibraryReading = SystemPhotoLibrary()) {
        self.library = library; self.database = messages; self.contacts = contacts; self.photoLibrary = photos
    }

    public func folders() -> [ShareableFolder] {
        library.settings.folders.filter(\.setting.on).map { ShareableFolder(id: $0.id, name: $0.name, level: $0.setting.level) }
    }

    private func picked(_ id: UUID) -> (PickedFolder, URL)? {
        guard let folder = library.settings.folders.first(where: { $0.id == id && $0.setting.on }),
              let root = FolderSource(folder: folder).resolve() else { return nil }
        return (folder, root)
    }

    public func files(in folders: [UUID], query: String?, limit: Int) -> [ShareableItem] {
        folders.flatMap { id -> [ShareableItem] in
            guard let (folder, root) = picked(id) else { return [] }
            let scoped = root.startAccessingSecurityScopedResource()
            defer { if scoped { root.stopAccessingSecurityScopedResource() } }
            return GatewayFiles.list(root: root, isFolder: folder.isFolder, leaf: folder.name, anchor: folder.anchor, folder: folder.id,
                                     level: folder.setting.level, query: query, limit: limit)
        }.prefix(limit).map { $0 }
    }

    public func file(_ id: String, maxBytes: Int) -> Result<SharedFile, ContentProblem> {
        guard let parsed = GatewayFiles.parse(id), let (folder, root) = picked(parsed.folder) else { return .failure(.notFound) }
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        return GatewayFiles.open(root: root, isFolder: folder.isFolder, leaf: folder.name, relative: parsed.path, anchor: folder.anchor,
                                 level: folder.setting.level, maxBytes: maxBytes)
    }

    public var messagesLevel: PrivacyLevel? {
        guard database != nil, library.isReadable(.messages) else { return nil }
        return library.settings.setting(.messages).level
    }

    public func threads(query: String?, limit: Int) async -> [ShareableItem] {
        guard let database, let level = messagesLevel else { return [] }
        let now = Date()
        let recent = (try? database.messages(withHandles: nil, since: now.addingTimeInterval(-30 * 86_400), until: now, limit: 3_000) { $0 }) ?? []
        return GatewayMessages.threads(recent, level: level, query: query, limit: limit)
    }

    public func messages(thread: String?, contact: String?, since: Date, until: Date, limit: Int) async -> [ExcerptMessage] {
        guard let database, messagesLevel != nil else { return [] }
        var names: [String: String] = [:]
        var rows: Set<Int64>?
        if let contact {
            let cards = await contacts.contacts(named: contact).filter { !$0.phones.isEmpty || !$0.emails.isEmpty }
            guard !cards.isEmpty else { return [] }
            for card in cards { for handle in card.phones + card.emails { names[MessagesHandle.key(handle)] = card.name } }
            let wanted = Set(names.keys)
            rows = Set(((try? database.handles()) ?? [:]).filter { wanted.contains(MessagesHandle.key($0.value)) }.keys)
        }
        let scan = thread == nil ? limit : 3_000
        let found = (try? database.messages(withHandles: rows, since: since, until: until, limit: scan) { handle in
            names[MessagesHandle.key(handle)] ?? (handle.isEmpty ? "Someone" : handle)
        }) ?? []
        let chat = thread.flatMap { $0.hasPrefix("thread:") ? String($0.dropFirst(7)) : nil }
        let picked = found.filter { chat == nil || $0.chat == chat }.prefix(limit)
        return picked.reversed().map { ExcerptMessage(sender: $0.sender, fromMe: $0.fromMe, date: $0.date, text: $0.text) }
    }

    public var photosLevel: PrivacyLevel? {
        guard library.isReadable(.photos) else { return nil }
        return library.settings.setting(.photos).level
    }
    public func photos(album: String?, limit: Int) async -> [ShareableItem] {
        guard let level = photosLevel else { return [] }
        return await photoLibrary.assets(album: album, limit: limit).map {
            ShareableItem(id: "photo:" + $0.id, kind: .photos, name: "Photo" + ($0.date.map { " from " + $0.formatted(date: .abbreviated, time: .shortened) } ?? ""),
                          size: max($0.width, $0.height), date: $0.date, level: level)
        }
    }
    public func photo(_ id: String, maxDimension: Int, location: Bool) async -> Data? {
        guard photosLevel != nil, id.hasPrefix("photo:") else { return nil }
        return await photoLibrary.jpeg(String(id.dropFirst(6)), maxDimension: maxDimension, location: location)
    }
}

// MARK: Made-up content (tests, `--ui-testing`, the smoke test)

/// Made-up files in a temporary folder, made-up messages, and made-up photos. Never the owner's.
@MainActor public final class FixtureContent: GatewayContent {
    public var folderList: [ShareableFolder]
    public var roots: [UUID: URL]
    /// Each folder's identity when it was "picked" (taken when the fixture is made).
    public var anchors: [UUID: FileAnchor] = [:]
    public var threadList: [String: (name: String, messages: [ExcerptMessage])]
    public var messagesLevel: PrivacyLevel?
    public var photoList: [String: Data]
    public var photosLevel: PrivacyLevel?

    public init(folders: [ShareableFolder] = [], roots: [UUID: URL] = [:], threads: [String: (name: String, messages: [ExcerptMessage])] = [:],
                messagesLevel: PrivacyLevel? = .personal, photos: [String: Data] = [:], photosLevel: PrivacyLevel? = .personal) {
        folderList = folders; self.roots = roots; threadList = threads; self.messagesLevel = messagesLevel; photoList = photos; self.photosLevel = photosLevel
        anchors = roots.compactMapValues { FileAnchor.of($0, isFolder: true) }
    }

    public func folders() -> [ShareableFolder] { folderList }
    public func files(in folders: [UUID], query: String?, limit: Int) -> [ShareableItem] {
        folders.flatMap { id -> [ShareableItem] in
            guard let root = roots[id], let folder = folderList.first(where: { $0.id == id }) else { return [] }
            return GatewayFiles.list(root: root, isFolder: true, anchor: anchors[id], folder: id, level: folder.level, query: query, limit: limit)
        }.prefix(limit).map { $0 }
    }
    public func file(_ id: String, maxBytes: Int) -> Result<SharedFile, ContentProblem> {
        guard let parsed = GatewayFiles.parse(id), let root = roots[parsed.folder], let folder = folderList.first(where: { $0.id == parsed.folder }) else {
            return .failure(.notFound)
        }
        return GatewayFiles.open(root: root, isFolder: true, relative: parsed.path, anchor: anchors[parsed.folder],
                                 level: folder.level, maxBytes: maxBytes)
    }
    public func threads(query: String?, limit: Int) async -> [ShareableItem] {
        guard let level = messagesLevel else { return [] }
        let wanted = query?.lowercased() ?? ""
        return threadList.sorted { $0.key < $1.key }.filter { wanted.isEmpty || $0.value.name.lowercased().contains(wanted) }.prefix(limit).map {
            ShareableItem(id: $0.key, kind: .messages, name: $0.value.name, size: $0.value.messages.count, date: $0.value.messages.last?.date, level: level)
        }
    }
    public func messages(thread: String?, contact: String?, since: Date, until: Date, limit: Int) async -> [ExcerptMessage] {
        let all: [ExcerptMessage]
        if let thread { all = threadList[thread]?.messages ?? [] }
        else if let contact { all = threadList.values.first { $0.name.localizedCaseInsensitiveContains(contact) }?.messages ?? [] }
        else { all = [] }
        return Array(all.filter { $0.date >= since && $0.date <= until }.suffix(limit))
    }
    public func photos(album: String?, limit: Int) async -> [ShareableItem] {
        guard let level = photosLevel else { return [] }
        return photoList.keys.sorted().prefix(limit).map { ShareableItem(id: $0, kind: .photos, name: "Photo", size: 1_024, level: level) }
    }
    public func photo(_ id: String, maxDimension: Int, location: Bool) async -> Data? {
        photoList[id].flatMap { PhotoJPEG.downscale($0, maxDimension: maxDimension) }
    }

    /// A made-up folder with a note, a CSV, and a nested file, in a temporary folder; made-up messages; one
    /// made-up photo.
    public static func sample(folder: URL, now: Date = Date()) -> FixtureContent {
        let id = UUID(uuidString: "00000000-0000-4000-8000-00000000F11E")!
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("Trips"), withIntermediateDirectories: true)
        try? Data("Packing list: passport, charger, rain jacket.\n".utf8).write(to: folder.appendingPathComponent("Packing.md"))
        try? Data("day,city\n1,Kyoto\n2,Osaka\n".utf8).write(to: folder.appendingPathComponent("Trips/Itinerary.csv"))
        let thread = ExcerptMessage(sender: "Sarah Lin", fromMe: false, date: now.addingTimeInterval(-3_600), text: "Dinner at 7:30 still works?")
        let reply = ExcerptMessage(sender: "You", fromMe: true, date: now.addingTimeInterval(-3_000), text: "Yes, see you there.")
        return FixtureContent(folders: [ShareableFolder(id: id, name: "Fixture folder", level: .personal)], roots: [id: folder],
                              threads: ["thread:fixture-sarah": (name: "Sarah Lin", messages: [thread, reply])],
                              photos: ["photo:fixture-1": FixtureImage.jpeg])
    }
}

/// A tiny made-up picture (a coral square), as a JPEG with a made-up GPS position in its metadata, so tests can
/// show the position is stripped.
public enum FixtureImage {
    public static var jpeg: Data {
        let width = 64, height = 48
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return Data() }
        context.setFillColor(CGColor(red: 0.94, green: 0.44, blue: 0.36, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return Data() }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return Data() }
        let properties: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.7749, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 122.4194, kCGImagePropertyGPSLongitudeRef: "W"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "made-up fixture"],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        CGImageDestinationFinalize(destination)
        return out as Data
    }
}

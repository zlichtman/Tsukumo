import Foundation
import Observation
import TsukumoCore
import TsukumoPolicy

// What KemoSabe may read (October 3): one catalog, the same on iPhone and Mac (AGENTS.md rule 9), grouped by
// kind. Every source reads only on this device, only when a bot's question reaches the Gate, and only after
// the owner turns it on (which asks the system for permission where the system has one). Each carries the
// level the owner set, and the Gate's policy decides what may be read for a bot: Sensitive asks on a card,
// Device only never leaves, Secret is never read. Picked files and connected accounts are as many as the
// owner likes. A source this device can't read says so instead of offering a switch.

/// The device a catalog is for.
public enum SourceDevice: String, Sendable {
    case mac, iPhone
    public var name: String { self == .mac ? "Mac" : "iPhone" }
    public static var current: SourceDevice {
        #if os(macOS)
        .mac
        #else
        .iPhone
        #endif
    }
}

/// The catalog's groups, in order.
public enum SourceGroup: String, CaseIterable, Identifiable, Sendable {
    case personal, communication, filesAndMedia, placesAndHealth, connected
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .personal: "Personal"
        case .communication: "Communication"
        case .filesAndMedia: "Files and Media"
        case .placesAndHealth: "Places and Health"
        case .connected: "Connected accounts"
        }
    }
    public var symbol: String {
        switch self {
        case .personal: "person.text.rectangle"
        case .communication: "bubble.left.and.text.bubble.right"
        case .filesAndMedia: "folder"
        case .placesAndHealth: "location"
        case .connected: "link"
        }
    }
}

/// A kind of source. Picked files and connected accounts can have many entries each.
public enum SourceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case calendar, reminders, contacts, messages, mail, photos, music, files, location, connector
    public var id: String { rawValue }

    public var group: SourceGroup {
        switch self {
        case .calendar, .reminders, .contacts: .personal
        case .messages, .mail: .communication
        case .photos, .music, .files: .filesAndMedia
        case .location: .placesAndHealth
        case .connector: .connected
        }
    }
    public var title: String {
        switch self {
        case .calendar: "Calendar"
        case .reminders: "Reminders"
        case .contacts: "Contacts"
        case .messages: "Messages"
        case .mail: "Mail"
        case .photos: "Photos"
        case .music: "Music"
        case .files: "Files and folders"
        case .location: "Location"
        case .connector: "Connected account"
        }
    }
    public var symbol: String {
        switch self {
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .contacts: "person.crop.circle"
        case .messages: "message"
        case .mail: "envelope"
        case .photos: "photo.on.rectangle"
        case .music: "music.note"
        case .files: "folder"
        case .location: "location"
        case .connector: "link"
        }
    }
    /// What its items are, for the policy (each kind has a floor).
    public var itemKind: ItemKind {
        switch self {
        case .calendar: .calendarEvent
        case .reminders: .reminder
        case .contacts: .contact
        case .messages: .textMessage
        case .mail: .email
        case .photos: .photo
        case .music: .music
        case .files: .document
        case .location: .location
        case .connector: .connector
        }
    }
    public var defaultLevel: PrivacyLevel {
        switch self {
        case .messages, .location: .sensitive
        default: max(.personal, itemKind.floor)
        }
    }
    /// The levels the owner can pick: from the kind's floor to Device only (Secret would mean never read).
    public var levels: [PrivacyLevel] { [.open, .personal, .sensitive, .deviceOnly].filter { $0 >= itemKind.floor } }

    /// What it reads, in one line, on this device.
    public func summary(on device: SourceDevice) -> String {
        switch self {
        case .calendar: "Events from yesterday to two weeks ahead."
        case .reminders: "Reminders you haven’t finished."
        case .contacts: "The contact card of someone a bot asks about."
        case .messages: device == .mac ? "A few messages around what a bot asks about, from Messages on this Mac."
                                       : "Messages you give KemoSabe with a Shortcuts automation."
        case .mail: "Your mail service, as a connected account."
        case .photos: "When and roughly where you took photos, and your albums. Never the pictures."
        case .music: "What’s playing, and what you played lately."
        case .files: "Text, Markdown, PDFs, and code in what you pick."
        case .location: "Where you are, to about a kilometer, for “near me”."
        case .connector: "Any service with an MCP server."
        }
    }

    /// Whether this device can read it.
    public func availability(on device: SourceDevice) -> SourceAvailability {
        switch self {
        case .mail:
            .viaConnector("Tsukumo doesn’t open Mail’s own files. Add your mail service as a connected account.")
        case .location, .music:
            device == .iPhone ? .here : .elsewhere("Not on this Mac. Turn it on in Tsukumo on your iPhone.")
        default: .here
        }
    }

    /// The built-in sources (one each), in the catalog's order.
    public static let builtIn: [SourceKind] = [.calendar, .reminders, .contacts, .messages, .mail, .photos, .music, .location]
}

public enum SourceAvailability: Hashable, Sendable {
    case here
    /// Another of the owner's devices reads it.
    case elsewhere(String)
    /// It comes in through a connected account.
    case viaConnector(String)
}

/// The owner's choices for one source.
public struct PersonalSourceSetting: Codable, Hashable, Sendable {
    public var on = false
    public var level: PrivacyLevel
    public init(on: Bool = false, level: PrivacyLevel) { self.on = on; self.level = level }
}

/// A file or folder the owner picked, read on demand through its bookmark.
public struct PickedFolder: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var bookmark: Data
    public var isFolder: Bool
    public var setting: PersonalSourceSetting
    /// The identity (device and inode) of the folder itself, or of a picked file's parent folder, when the owner
    /// picked it: the KemoSabe gateway opens nothing under it unless what it opens is still that same folder.
    public var anchor: FileAnchor?
    public init(id: UUID = UUID(), name: String, bookmark: Data, isFolder: Bool, setting: PersonalSourceSetting, anchor: FileAnchor? = nil) {
        self.id = id; self.name = name; self.bookmark = bookmark; self.isFolder = isFolder; self.setting = setting; self.anchor = anchor
    }
}

/// A folder's identity on disk: its device and inode, which a rename or a symlink swapped in at its path can't fake.
public struct FileAnchor: Codable, Hashable, Sendable {
    public var device: UInt64
    public var inode: UInt64
    public init(device: UInt64, inode: UInt64) { self.device = device; self.inode = inode }
    /// The identity of the folder at `url`, or of a file's parent folder, at that path as it is (a folder that is
    /// itself a symlink has none: pick the folder it points to).
    public static func of(_ url: URL, isFolder: Bool) -> FileAnchor? {
        let path = url.standardizedFileURL
        let folder = isFolder ? path : path.deletingLastPathComponent()
        var info = stat()
        guard lstat(folder.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return FileAnchor(device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino))
    }
}

/// A connected account: an MCP server the owner added, and the tool KemoSabe asks it with.
public struct ConnectedAccount: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var url: URL
    /// The server's tool KemoSabe calls with a bot's question, and the argument the question goes in.
    public var tool: String
    public var argument: String
    /// Whether a token for it is in the Keychain.
    public var hasToken: Bool
    public var setting: PersonalSourceSetting
    public init(id: UUID = UUID(), name: String, url: URL, tool: String, argument: String, hasToken: Bool, setting: PersonalSourceSetting) {
        self.id = id; self.name = name; self.url = url; self.tool = tool; self.argument = argument; self.hasToken = hasToken; self.setting = setting
    }
}

/// Everything the owner chose, saved as one file (`sources.json`) on this device. It never syncs.
public struct SourceSettings: Codable, Equatable, Sendable {
    public var builtIn: [String: PersonalSourceSetting] = [:]
    public var folders: [PickedFolder] = []
    public var accounts: [ConnectedAccount] = []
    public init() {}

    public func setting(_ kind: SourceKind) -> PersonalSourceSetting {
        builtIn[kind.rawValue] ?? PersonalSourceSetting(level: kind.defaultLevel)
    }

    private enum CodingKeys: String, CodingKey { case builtIn, folders, accounts }
    public init(from decoder: Decoder) throws {
        if let c = try? decoder.container(keyedBy: CodingKeys.self), c.contains(.builtIn) || c.contains(.folders) || c.contains(.accounts) {
            builtIn = (try? c.decodeIfPresent([String: PersonalSourceSetting].self, forKey: .builtIn)) ?? [:]
            folders = (try? c.decodeIfPresent([PickedFolder].self, forKey: .folders)) ?? []
            accounts = (try? c.decodeIfPresent([ConnectedAccount].self, forKey: .accounts)) ?? []
            return
        }
        // Builds before October 3 saved `[PersonalSourceKind: PersonalSourceSetting]`, which JSON writes as
        // a list of keys and values: ["calendar", {...}, "reminders", {...}].
        var list = try decoder.unkeyedContainer()
        while !list.isAtEnd {
            let key = try list.decode(String.self)
            builtIn[key] = try list.decode(PersonalSourceSetting.self)
        }
    }
}

// MARK: Permission

/// What the system says about reading a source.
public enum SourcePermission: Hashable, Sendable {
    case granted, notDetermined, denied, restricted
    /// Nothing to read here (no Messages history on this Mac, say).
    case unavailable(String)
}

/// The system's permissions, behind a protocol so tests never touch the owner's data.
@MainActor public protocol SourceAuthorizing: AnyObject {
    func status(_ kind: SourceKind) -> SourcePermission
    /// Asks the system (its own prompt), or for a permission only System Settings grants, says where it stands.
    func request(_ kind: SourceKind) async -> SourcePermission
    /// Where the owner changes it, when the fix is in System Settings.
    func settingsURL(_ kind: SourceKind) -> URL?
    /// Why it needs permission, and what to do, in plain words.
    func guidance(_ kind: SourceKind, _ permission: SourcePermission) -> String
}

public extension SourceAuthorizing {
    func guidance(_ kind: SourceKind, _ permission: SourcePermission) -> String {
        let device = SourceDevice.current
        let place = device == .mac ? "System Settings, Privacy & Security, \(kind.title)" : "Settings, Tsukumo"
        switch permission {
        case .restricted: return "\(kind.title) is restricted on this \(device.name) by Screen Time or a device profile."
        case .unavailable(let why): return why
        default: return "Allow Tsukumo in \(place)."
        }
    }
}

// MARK: The catalog's rows

/// One row of the catalog.
public struct SourceEntry: Identifiable, Hashable, Sendable {
    public enum State: Hashable, Sendable {
        case off
        case on(PrivacyLevel)
        /// Turned on, but the system hasn't allowed it (and why, in plain words).
        case needsPermission(String)
        case notOnDevice(String)
        /// Comes in through a connected account.
        case viaConnector(String)
    }
    /// "calendar", "folder:<uuid>", "account:<uuid>".
    public let id: String
    public let kind: SourceKind
    public let title: String
    public let symbol: String
    public let summary: String
    public let state: State
    public let level: PrivacyLevel
    public let levels: [PrivacyLevel]
    /// Picked files and connected accounts can be removed.
    public let removable: Bool
    /// The fix is in System Settings (or Settings on iPhone).
    public let opensSettings: Bool

    public var group: SourceGroup { kind.group }
    /// Whether the owner turned it on (it may still need permission).
    public var isOn: Bool {
        switch state {
        case .on, .needsPermission: true
        default: false
        }
    }
    /// Whether it has a switch at all.
    public var isSwitchable: Bool {
        switch state {
        case .notOnDevice, .viaConnector: false
        default: true
        }
    }
    /// The state in a word or two: "Off", "Personal", "Needs permission", "Not on this Mac".
    public var stateTitle: String {
        switch state {
        case .off: "Off"
        case .on(let level): level.title
        case .needsPermission: "Needs permission"
        case .notOnDevice: "Not on this \(SourceDevice.current.name)"
        case .viaConnector: "Connect an account"
        }
    }
    /// The line under the title: what it reads, or what stands in the way.
    public var detail: String {
        switch state {
        case .needsPermission(let why), .notOnDevice(let why), .viaConnector(let why): why
        default: summary
        }
    }
}

// MARK: Making the Gate's sources

/// Makes the Gate's sources from the owner's choices. The system's is `SourceFactory.system`; tests pass fakes.
public struct SourceFactory: Sendable {
    public var builtIn: @MainActor @Sendable (SourceKind, PrivacyLevel, SourceSettings) -> (any PersonalSource)?
    public var folder: @MainActor @Sendable (PickedFolder) -> any PersonalSource
    public var account: @MainActor @Sendable (ConnectedAccount, String?) -> any PersonalSource
    public init(builtIn: @escaping @MainActor @Sendable (SourceKind, PrivacyLevel, SourceSettings) -> (any PersonalSource)?,
                folder: @escaping @MainActor @Sendable (PickedFolder) -> any PersonalSource,
                account: @escaping @MainActor @Sendable (ConnectedAccount, String?) -> any PersonalSource) {
        self.builtIn = builtIn; self.folder = folder; self.account = account
    }
}

// MARK: The library

/// The catalog and the owner's choices, for Settings, KemoSabe on both devices, and the Gate's sources.
@MainActor @Observable public final class SourceLibrary {
    /// The host may refuse persisted mutations while its store is recovering.
    @ObservationIgnored public var canWrite: @MainActor () -> Bool = { true }
    public private(set) var settings: SourceSettings
    public private(set) var permissions: [SourceKind: SourcePermission] = [:]
    /// The last thing that didn't work, in words (shown once, calmly).
    public var problem: String?
    public let device: SourceDevice

    @ObservationIgnored private let file: URL?
    @ObservationIgnored private let authorizer: any SourceAuthorizing
    @ObservationIgnored private let factory: SourceFactory
    @ObservationIgnored private let tokens: any ConnectorTokenStore
    /// Connects to an MCP server and lists its tools (stubbed in tests).
    @ObservationIgnored private let discover: @Sendable (URL, String?) async throws -> [MCPTool]
    /// The Gate's sources changed.
    @ObservationIgnored public var onChange: (() -> Void)?

    public init(file: URL?, device: SourceDevice = .current, authorizer: any SourceAuthorizing, factory: SourceFactory,
                tokens: any ConnectorTokenStore = MemoryConnectorTokens(),
                discover: @escaping @Sendable (URL, String?) async throws -> [MCPTool] = { url, token in try await MCPClient(url: url, token: token).tools() }) {
        self.file = file; self.device = device; self.authorizer = authorizer; self.factory = factory; self.tokens = tokens; self.discover = discover
        settings = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(SourceSettings.self, from: $0) } ?? SourceSettings()
        refresh()
    }

    /// Reads the system's permissions again (when Settings shows, or the app comes back).
    public func refresh() {
        var next: [SourceKind: SourcePermission] = [:]
        for kind in SourceKind.builtIn where kind.availability(on: device) == .here {
            // Opening Messages' history to check is a read: only once the owner turned it on.
            if kind == .messages, device == .mac, !settings.setting(.messages).on { next[kind] = .notDetermined; continue }
            next[kind] = authorizer.status(kind)
        }
        if next != permissions { permissions = next }
    }

    // MARK: Rows

    /// Every row, grouped and in order, matching the search (title, what it reads, or its group).
    public func groups(matching search: String = "") -> [(group: SourceGroup, entries: [SourceEntry])] {
        let wanted = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let all = entries()
        return SourceGroup.allCases.compactMap { group in
            let rows = all.filter { $0.group == group }.filter { entry in
                wanted.isEmpty || [entry.title, entry.summary, group.title, entry.kind.title].contains { $0.lowercased().contains(wanted) }
            }
            // Picked files and connected accounts always show their group, so the owner can add one.
            let addable = group == .connected || group == .filesAndMedia
            return rows.isEmpty && !(addable && (wanted.isEmpty || group.title.lowercased().contains(wanted))) ? nil : (group, rows)
        }
    }

    public func entries() -> [SourceEntry] {
        var list: [SourceEntry] = []
        for kind in SourceKind.builtIn {
            list.append(entry(kind))
            if kind == .music {
                for folder in settings.folders { list.append(entry(folder)) }
            }
        }
        for account in settings.accounts { list.append(entry(account)) }
        return list
    }

    public func entry(_ id: String) -> SourceEntry? { entries().first { $0.id == id } }

    private func entry(_ kind: SourceKind) -> SourceEntry {
        let setting = settings.setting(kind)
        let state: SourceEntry.State
        var opensSettings = false
        switch kind.availability(on: device) {
        case .elsewhere(let why): state = .notOnDevice(why)
        case .viaConnector(let why): state = .viaConnector(why)
        case .here:
            if !setting.on {
                state = .off
            } else {
                let permission = permissions[kind] ?? .notDetermined
                if permission == .granted {
                    state = .on(setting.level)
                } else {
                    state = .needsPermission(authorizer.guidance(kind, permission))
                    if case .unavailable = permission {} else { opensSettings = authorizer.settingsURL(kind) != nil }
                }
            }
        }
        return SourceEntry(id: kind.rawValue, kind: kind, title: kind.title, symbol: kind.symbol, summary: kind.summary(on: device),
                           state: state, level: setting.level, levels: kind.levels, removable: false, opensSettings: opensSettings)
    }
    private func entry(_ folder: PickedFolder) -> SourceEntry {
        SourceEntry(id: "folder:" + folder.id.uuidString, kind: .files, title: folder.name, symbol: folder.isFolder ? "folder" : "doc.text",
                    summary: folder.isFolder ? "A folder you picked: its text files, read when a bot asks." : "A file you picked, read when a bot asks.",
                    state: folder.setting.on ? .on(folder.setting.level) : .off, level: folder.setting.level,
                    levels: SourceKind.files.levels, removable: true, opensSettings: false)
    }
    private func entry(_ account: ConnectedAccount) -> SourceEntry {
        SourceEntry(id: "account:" + account.id.uuidString, kind: .connector, title: account.name, symbol: "link",
                    summary: "\(account.url.host() ?? account.url.absoluteString), asked with its “\(account.tool)” tool.",
                    state: account.setting.on ? .on(account.setting.level) : .off, level: account.setting.level,
                    levels: SourceKind.connector.levels, removable: true, opensSettings: false)
    }

    // MARK: Changing it

    /// Turns a source on (asking the system first, where it has a prompt) or off.
    public func set(_ id: String, on: Bool) async {
        guard canWrite() else { return }
        problem = nil
        if let kind = SourceKind(rawValue: id), SourceKind.builtIn.contains(kind) {
            guard kind.availability(on: device) == .here else { return }
            var setting = settings.setting(kind)
            setting.on = on
            if on {
                var permission = authorizer.status(kind)
                if permission == .notDetermined { permission = await authorizer.request(kind) }
                guard canWrite() else { return }
                permissions[kind] = permission
            }
            settings.builtIn[kind.rawValue] = setting
        } else if let index = folderIndex(id) {
            settings.folders[index].setting.on = on
        } else if let index = accountIndex(id) {
            settings.accounts[index].setting.on = on
        }
        save()
    }

    public func set(_ id: String, level: PrivacyLevel) {
        guard canWrite() else { return }
        if let kind = SourceKind(rawValue: id), SourceKind.builtIn.contains(kind) {
            var setting = settings.setting(kind)
            setting.level = max(level, kind.itemKind.floor)
            settings.builtIn[kind.rawValue] = setting
        } else if let index = folderIndex(id) {
            settings.folders[index].setting.level = level
        } else if let index = accountIndex(id) {
            settings.accounts[index].setting.level = level
        } else { return }
        save()
    }

    /// Where the owner allows it, when the fix is in System Settings.
    public func settingsURL(_ id: String) -> URL? { SourceKind(rawValue: id).flatMap(authorizer.settingsURL) }

    /// Adds files or folders the owner picked (from an open panel or the Files app), each on at `level`.
    @discardableResult
    public func addFiles(_ urls: [URL], level: PrivacyLevel = SourceKind.files.defaultLevel) -> [String] {
        guard canWrite() else { return [] }
        var added: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else {
                problem = "Tsukumo couldn’t keep “\(url.lastPathComponent)”. Try picking it again."
                continue
            }
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if let existing = settings.folders.first(where: { $0.bookmark == bookmark }) { added.append("folder:" + existing.id.uuidString); continue }
            let folder = PickedFolder(name: url.lastPathComponent, bookmark: bookmark, isFolder: isFolder,
                                      setting: PersonalSourceSetting(on: true, level: level), anchor: FileAnchor.of(url, isFolder: isFolder))
            settings.folders.append(folder)
            added.append("folder:" + folder.id.uuidString)
        }
        save()
        return added
    }

    /// Connects to an MCP server, finds the tool KemoSabe can ask it with, and adds it (the token into
    /// this device's Keychain). Throws a message to show.
    @discardableResult
    public func addAccount(name: String, url text: String, token: String?, level: PrivacyLevel = SourceKind.connector.defaultLevel) async throws -> ConnectedAccount {
        guard canWrite() else { throw CocoaError(.fileWriteNoPermission) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), url.host() != nil,
              scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1"].contains(url.host() ?? "")) else {
            throw ConnectorError.message("Enter the server’s full https:// address.")
        }
        let token = token.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        let tools = try await discover(url, token)
        guard canWrite() else { throw CocoaError(.fileWriteNoPermission) }
        guard let tool = MCPTool.best(tools) else {
            throw ConnectorError.message("This server has no tool KemoSabe can ask a question with (one that takes a search or a question).")
        }
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = ConnectedAccount(name: label.isEmpty ? (url.host() ?? "Connected account") : label, url: url, tool: tool.name,
                                       argument: tool.argument ?? "query", hasToken: token != nil,
                                       setting: PersonalSourceSetting(on: true, level: max(level, SourceKind.connector.itemKind.floor)))
        if let token { try tokens.save(token, for: account.id) }
        settings.accounts.append(account)
        save()
        return account
    }

    /// Removes a picked file or a connected account (and its token).
    public func remove(_ id: String) {
        guard canWrite() else { return }
        if let index = folderIndex(id) {
            settings.folders.remove(at: index)
        } else if let index = accountIndex(id) {
            tokens.remove(settings.accounts[index].id)
            settings.accounts.remove(at: index)
        } else { return }
        save()
    }

    // MARK: The Gate

    /// The Gate's sources: each source that's on and allowed, at its level.
    public func sources() -> [any PersonalSource] {
        var list: [any PersonalSource] = []
        for kind in SourceKind.builtIn where kind.availability(on: device) == .here {
            let setting = settings.setting(kind)
            guard setting.on, permissions[kind] == .granted, let source = factory.builtIn(kind, setting.level, settings) else { continue }
            list.append(source)
        }
        for folder in settings.folders where folder.setting.on { list.append(factory.folder(folder)) }
        for account in settings.accounts where account.setting.on {
            list.append(factory.account(account, account.hasToken ? tokens.read(account.id) : nil))
        }
        return list
    }

    /// Whether a built-in source is on and allowed (Dock chirps read Calendar and Reminders only then).
    public func isReadable(_ kind: SourceKind) -> Bool { settings.setting(kind).on && permissions[kind] == .granted }

    private func folderIndex(_ id: String) -> Int? {
        guard id.hasPrefix("folder:") else { return nil }
        return settings.folders.firstIndex { "folder:" + $0.id.uuidString == id }
    }
    private func accountIndex(_ id: String) -> Int? {
        guard id.hasPrefix("account:") else { return nil }
        return settings.accounts.firstIndex { "account:" + $0.id.uuidString == id }
    }

    private func save() {
        if let file {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(settings).write(to: file, options: [.atomic])
        }
        onChange?()
    }
}

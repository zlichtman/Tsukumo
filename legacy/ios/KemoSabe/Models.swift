import SwiftUI
#if os(macOS)
import AppKit
#endif

struct BotTheme: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var body: String
    var accent: String
    var background: String
    static let presets: [BotTheme] = [
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
    /// Refresh only an exact old stock palette. A saved custom palette (even a
    /// green one, or one named Matcha) must never be overwritten by this update.
    static func refreshedStock(_ saved: BotTheme) -> BotTheme {
        let previous: [BotTheme] = [
            .init(id: "matcha", name: "Matcha", body: "DCE7BD", accent: "527453", background: "172820"),
            .init(id: "pistachio", name: "Pistachio", body: "D8E5CD", accent: "658666", background: "1E2923"),
            .init(id: "moss", name: "Moss", body: "BBCDB0", accent: "526848", background: "1C241B")
        ]
        guard previous.contains(saved) else { return saved }
        return presets.first { $0.id == saved.id } ?? saved
    }
    var bodyColor: Color { Color(hex: body) }
    var accentColor: Color { Color(hex: accent) }
    var backgroundColor: Color { Color(hex: background) }
}

/// Curated shelf; the full preset catalogue stays stable for saved selections.
enum ThemeShelf {
    static let featuredIDs = ["apricot", "matcha", "lavender", "sky", "rose", "aurora", "cocoa", "graphite"]
    static var featured: [BotTheme] { featuredIDs.compactMap { id in BotTheme.presets.first { $0.id == id } } }
    static var more: [BotTheme] { BotTheme.presets.filter { !featuredIDs.contains($0.id) } }
    /// Keep Blueberry available to saved selections while the drawer shows 20 stock palettes.
    static var visible: [BotTheme] { (featured + more).filter { $0.id != "blueberry" } }
    static func extraCurrent(_ current: BotTheme) -> BotTheme? {
        guard more.contains(where: { $0.id == current.id }) else { return nil }
        return current
    }
    static func signature(_ theme: BotTheme) -> String {
        [theme.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), theme.body.uppercased(), theme.accent.uppercased(), theme.background.uppercased()].joined(separator: "|")
    }
    static func uniqueCustom(_ themes: [BotTheme], currentID: String) -> [BotTheme] {
        var result: [BotTheme] = []
        for theme in themes {
            if let index = result.firstIndex(where: { signature($0) == signature(theme) }) {
                if theme.id == currentID { result[index] = theme }
            } else { result.append(theme) }
        }
        return result
    }
}

extension Color {
    init(hex: String) {
        let value = UInt32(hex, radix: 16) ?? 0
        self.init(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
    var hexValue: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if os(macOS)
        (NSColor(self).usingColorSpace(.sRGB) ?? .white).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
        #else
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        return String(format: "%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

struct Performance: Codable, Identifiable {
    let id: String
    let name: String
    let group: String
    let description: String
    /// Position in the curated animation suite people browse; nil for performances
    /// that play only as app states (for example a coding task's deploy step).
    var suite: Int? = nil
    static var suite: [Performance] { all.filter { $0.suite != nil }.sorted { ($0.suite ?? 0) < ($1.suite ?? 0) } }
    static let all: [Performance] = {
        guard let url = Bundle.main.url(forResource: "catalog", withExtension: "json", subdirectory: "Character"),
              let data = try? Data(contentsOf: url), let catalog = try? JSONDecoder().decode([Performance].self, from: data) else { return [] }
        return catalog
    }()
}

/// Saved-memory lineage is distinct from MemoryDatabase's revision dependency.
/// It binds a parent note's stable ID to its content/policy fingerprint without
/// copying the parent's text into the derived note.
struct MemorySourceDependency: Codable, Equatable, Hashable {
    let id: UUID
    let fingerprint: String
}

struct MemoryNote: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var scope: String = "Personal"
    var useInChat = true
    var contextNamespace: String?
    // Optional so legacy notes decode and re-encode without changing their shape.
    var sourceDependencies: [MemorySourceDependency]?
    var inheritedSensitivity: UInt8?
    /// The level the person chose (`PrivacyLevel`); nil uses the default from its labels
    /// (`MemoryPrivacy.level`). Not part of `PlanningSource.fingerprint`, so changing it never
    /// invalidates notes derived from this one (`ContextPolicyDigest`).
    var privacy: PrivacyLevel?
}

struct ChatMessage: Codable, Identifiable, Equatable {
    var id = UUID()
    var role: String
    var text: String
    var images: [ChatImage]?
    /// Docs or journal entries attached to this message (`ChatDocAttachment`); only this message's
    /// turn reads their text.
    var attachments: [ChatDocAttachment]?
    var date = Date()
    /// Revision of the local disclosure context used for this turn. Legacy
    /// visible history remains decodable but is not implicitly current.
    var contextRevision: Int?
    /// Part of a task handed to another agent (`ChatHandoff`): its speaker is that agent or the
    /// Apple on-device helper, never the other person in a thread.
    var handoff: ChatHandoff?
}

/// The device a conversation started on, for filtering the list.
enum ConversationDevice: String, Codable, CaseIterable, Identifiable {
    case iPhone, mac = "Mac", watch = "Watch"
    var id: String { rawValue }
    var symbol: String { switch self { case .iPhone: "iphone"; case .mac: "laptopcomputer"; case .watch: "applewatch" } }
    static var this: ConversationDevice {
        #if os(macOS)
        .mac
        #else
        .iPhone
        #endif
    }
}

struct ConversationArchive: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    let model: String
    let recipient: String?
    var messages: [ChatMessage]
    var apiProfileID: UUID? = nil
    /// The project folder it's filed in, if any. Filing never shares context between conversations.
    var projectID: UUID? = nil
    /// Where the conversation started: iPhone, Mac, or Watch.
    var device: ConversationDevice? = nil
    /// Who may read this chat (`PrivacyLevel`); nil is `ConversationPrivacy.defaultLevel`.
    var privacy: PrivacyLevel? = nil
    var title: String { String((messages.first(where: { $0.role == "You" })?.text ?? "Conversation").prefix(70)) }
    /// The other person, when this is a thread with someone rather than with Kemo.
    var counterpart: String? { messages.first { $0.handoff == nil && !["You", "KemoSabe", CompanionIdentity.name].contains($0.role) }?.role }
}

/// A named folder for conversations, like a project in Codex or ChatGPT. It only
/// organizes the list: conversations in a project stay separate histories.
struct ConversationProject: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var created = Date()
    static let maxName = 60
}

/// The default model as it syncs: Apple's (on-device or Private Cloud) or a connection, by ID.
struct DefaultModelChoice: Codable, Equatable {
    var route: KemoModelRoute
    /// `AppleModel` raw value on the Apple route; nil is on-device.
    var appleModel: String?
    var profile: UUID?
    init(route: KemoModelRoute, appleModel: String? = nil, profile: UUID? = nil) { self.route = route; self.appleModel = appleModel; self.profile = profile }
}

/// Which model answers: Apple's (on-device or Private Cloud, `SavedState.appleModel`) or a connected
/// model. A route this build doesn't have (the removed "managed" cloud demo, or one from a later
/// build) reads as on-device, so the rest of the saved state still loads.
enum KemoModelRoute: String, Codable {
    case onDevice, api
    init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .onDevice
    }
}

struct SavedState: Codable {
    /// The format this file was written in. Missing means a build before versioning (1.0.0 build 42).
    /// A build refuses to load, and so never overwrites, a file from a newer format.
    var schemaVersion: Int?
    /// The account this data belongs to (`AccountIdentity.id`). Another account never loads it.
    var ownerAccountID: String?
    var theme = BotTheme.presets[0]
    var memories: [MemoryNote] = []
    var people: PeopleDirectory?
    var messages: [ChatMessage] = []
    /// The agent this chat talks to (`ChatHandoff`, "claude-code"), chosen in the model chip; nil is Kemo.
    var chatAgent: String?
    var conversationArchives: [ConversationArchive]?
    var conversationProjects: [ConversationProject]?
    /// The project the current conversation belongs to; it's filed there when saved.
    var currentProjectID: UUID?
    /// Where the current conversation started.
    var currentDevice: ConversationDevice?
    var standupFormat = "Yesterday / Today / Blockers. Short bullets, first person."
    var onboarded = false
    var voiceEnabled: Bool?
    var captionsEnabled: Bool?
    var permissionSetupAttempted: Bool?
    var customThemes: [BotTheme]?
    var speechVoiceID: String?
    var speechRate: Double?
    var patientListening: Bool?
    var voiceInterruptions: Bool?
    var workItems: [WorkItem]?
    var enabledConnectors: [String]?
    /// Native connections the person disconnected in KemoSabe. Written by Disconnect and cleared by
    /// Connect; otherwise Apple's permission, however it was granted, means connected.
    var disconnectedConnectors: [String]?
    /// Per connected API model (by profile ID), the connections it may read ("Always for this model").
    /// The on-device model needs no grant; selecting a model never grants anything.
    var apiConnectorGrants: [String: [String]]?
    var modelRoute: KemoModelRoute?
    /// On the Apple route, which of Apple's models answers (`AppleModel` raw value); nil is on-device.
    /// A string, so an unknown value from a later build never stops this state from loading.
    var appleModel: String?
    var apiProfiles: [APIModelProfile]?
    var selectedAPIProfile: UUID?
    /// The account's default model for new chats, the same on every device (it syncs as a preference,
    /// `AppStoreSyncAdapter`). Choosing a model sets it; each device uses it when it can
    /// (`AppStore.applyDefaultModel`: a connection's key is per device).
    var defaultModel: DefaultModelChoice?
    var apiConversations: [String: [ChatMessage]]?
    /// The reasoning effort chosen for each model profile (`ModelEffortKey`), in that provider's own
    /// words. Sent only to that model, and only when it accepts it (`ModelEffortCatalog`).
    var modelEfforts: [String: String]?

    var contextOwnerID: UUID?
    // Separate from text-cloud consent. Never inferred from legacy modelRoute.
    var liveCloudAudioConsent: Bool?
    var memoryPrivacy: [MemoryPrivacyAssessment]?
    /// Monotonic local policy/context epoch for history isolation.
    var contextRevision: Int?
    /// Deleted chats whose continuity notes (in routines.json) still have to be forgotten, as
    /// digests of the deleted text rather than the text itself. Saved in the same write that
    /// removes the chat, so an interrupted deletion finishes on the next launch.
    var pendingContextForgets: [String]?
    /// Each open conversation, by where it's held ("onDevice", "api-<connection>"). A
    /// conversation keeps one ID whether it's open or saved, so it's one record on every device.
    var openConversations: [String: OpenConversation]?
    /// The person's durable grants (`RecipientGrant`), one per recipient, items or kinds, purpose, and
    /// expiry. They replace `apiConnectorGrants`, which is migrated once and then left empty.
    var recipientGrants: [RecipientGrant]?
}

/// An open conversation's identity and the details it had when it was saved, so it's the same
/// record whether it's open or in the list (see `AppStoreSyncAdapter`).
struct OpenConversation: Codable, Equatable {
    var id: UUID
    var date: Date?
    var projectID: UUID?
    var device: ConversationDevice?
    var privacy: PrivacyLevel?
    /// The context this chat started with (`ContextPacket`), shown as its context card. Kept on this
    /// device only; a packet this build can't read is dropped rather than stopping the account loading.
    var packet: ContextPacket?

    init(id: UUID, date: Date? = nil, projectID: UUID? = nil, device: ConversationDevice? = nil, privacy: PrivacyLevel? = nil, packet: ContextPacket? = nil) {
        self.id = id; self.date = date; self.projectID = projectID; self.device = device; self.privacy = privacy; self.packet = packet
    }
    private enum CodingKeys: String, CodingKey { case id, date, projectID, device, privacy, packet }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        date = try container.decodeIfPresent(Date.self, forKey: .date)
        projectID = try container.decodeIfPresent(UUID.self, forKey: .projectID)
        device = try container.decodeIfPresent(ConversationDevice.self, forKey: .device)
        privacy = try container.decodeIfPresent(PrivacyLevel.self, forKey: .privacy)
        packet = try? container.decodeIfPresent(ContextPacket.self, forKey: .packet)
    }
}

struct WorkItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = "Standup draft"
    var status = "Queued"
    var draft = ""
    var sourceIDs: [UUID] = []
    var sourceNotes: [MemoryNote]?
    var createdAt = Date()
}

enum LocalRepositoryError: Error, Equatable {
    /// The file was written by a newer build; this build can't read it safely.
    case newerSchema(Int)
    /// The file belongs to a different account than the one it was opened for.
    case otherAccount
}

struct LocalRepository {
    /// Bump when `SavedState` changes in a way older builds can't read, and add a migration in `read`.
    static let schemaVersion = 1
    let url: URL
    /// The account whose data this is; nil for test and fixture repositories.
    var owner: String? = nil
    /// Local accounts whose folder this account adopted at Sign in with Apple; their state opens
    /// as this account's and is saved under this account from then on.
    var formerOwners: Set<String> = []
    /// The current account's state, in its own folder (see `AccountDirectory`).
    static var standard: LocalRepository {
        .init(url: AccountDirectory.currentFolder.appendingPathComponent("state.json"), owner: AccountDirectory.current().id,
              formerOwners: AccountDirectory.currentFormerOwners)
    }
    /// A copy of the file as it was before this build first rewrote it in a new format
    /// (empty when the file was already current).
    var backupURL: URL { url.deletingPathExtension().appendingPathExtension("before-v\(Self.schemaVersion).json") }
    func read() throws -> SavedState {
        guard FileManager.default.fileExists(atPath: url.path) else { return SavedState() }
        let data = try Data(contentsOf: url)
        var state = try JSONDecoder().decode(SavedState.self, from: data)
        if let version = state.schemaVersion, version > Self.schemaVersion { throw LocalRepositoryError.newerSchema(version) }
        if let owner, let stateOwner = state.ownerAccountID, stateOwner != owner, !formerOwners.contains(stateOwner) { throw LocalRepositoryError.otherAccount }
        state.theme = BotTheme.refreshedStock(state.theme)
        Self.keepCloudDemoConversation(from: data, in: &state)
        return state
    }
    /// The removed cloud demo ("KemoSabe cloud") kept its open conversation apart (`managedMessages`,
    /// held in the "managed" slot). It moves into the conversation list once, under the ID it already
    /// had, so it stays one record everywhere; it can be read there but not continued.
    static func keepCloudDemoConversation(from data: Data, in state: inout SavedState) {
        struct Legacy: Decodable { var managedMessages: [ChatMessage]? }
        let open = state.openConversations?.removeValue(forKey: "managed")
        guard let messages = (try? JSONDecoder().decode(Legacy.self, from: data))?.managedMessages, !messages.isEmpty else { return }
        let id = open?.id ?? UUID()
        guard !(state.conversationArchives ?? []).contains(where: { $0.id == id }) else { return }
        let archive = ConversationArchive(id: id, date: open?.date ?? messages.first?.date ?? Date(), model: "KemoSabe cloud", recipient: nil,
                                          messages: messages.map { var message = $0; message.contextRevision = nil; return message },
                                          projectID: open?.projectID, device: open?.device, privacy: open?.privacy)
        state.conversationArchives = (state.conversationArchives ?? []) + [archive]
    }
    func save(_ state: SavedState) throws {
        // Never into an account that's no longer open, or while one is changing (`AccountDirectory.permitsWrite`).
        try AccountDirectory.checkWrite(to: url)
        var folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        try keepOriginalBeforeUpgrade()
        var state = state; state.schemaVersion = Self.schemaVersion
        if let owner { state.ownerAccountID = owner }
        try JSONEncoder().encode(state).write(to: url, options: [.atomic, .completeFileProtection])
    }
    /// Before the first write in a new format, keep the older file once, so an upgrade that
    /// goes wrong can be recovered from rather than leaving only the rewritten copy.
    private func keepOriginalBeforeUpgrade() throws {
        let files = FileManager.default
        guard files.fileExists(atPath: url.path), !files.fileExists(atPath: backupURL.path) else { return }
        struct Version: Decodable { var schemaVersion: Int? }
        let data = try Data(contentsOf: url)
        let version = (try? JSONDecoder().decode(Version.self, from: data))?.schemaVersion ?? 0
        // An empty file records that the check ran and nothing older needed keeping,
        // so later saves don't parse the whole state again.
        try (version < Self.schemaVersion ? data : Data()).write(to: backupURL, options: [.atomic, .completeFileProtection])
    }
}


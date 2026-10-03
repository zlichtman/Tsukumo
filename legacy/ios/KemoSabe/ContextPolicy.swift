import Foundation

// The context harness's one vocabulary (design/CONTEXT-HARNESS.md): who may receive context
// (`RecipientID`), how private each item is (`PrivacyLevel`), and one decision
// (`ContextPolicy.evaluate`) that every disclosure path asks before anything leaves its store.

// MARK: Recipients

/// Where a recipient runs, which decides what it may read without the person's say-so.
enum RecipientLocality: String, Codable, Sendable {
    /// On this device: Apple's on-device models (Foundation Models, Core ML), local voices, other chats here.
    case onDevice
    /// Apple's servers: Private Cloud Compute, and the person's own private iCloud database.
    case appleCloud
    /// Anywhere outside this device and Apple's servers: another company's model or agent, or another person's device.
    case thirdPartyCloud
}

/// Every recipient of context, named once. Each is its own recipient with its own grants: being
/// selected, installed, or nearby never grants anything.
enum RecipientID: Hashable, Sendable {
    case appleOnDevice
    case applePrivateCloud
    /// A connected API model. Its endpoint is fixed when it's added, so the profile names it.
    case apiModel(profile: UUID, host: String)
    /// A Tsukumo coding agent by its adapter (`claude-code`, `codex`, `cursor-agent`, …).
    case codingAgent(String)
    /// Any agent reached over the Agent Client Protocol, by the identity it runs as.
    case acpAgent(String)
    /// Another company's agent (for example Meta's Muse), by the identity it presents.
    case externalAgent(String)
    /// Another person's Kemo nearby, by its ephemeral peer ID.
    case nearbyPeer(UUID)
    /// Another KemoSabe chat, when context moves between conversations.
    case chat(UUID)
    /// The person's own private iCloud database (every field in `encryptedValues`).
    case iCloudSync
    /// A reply voice: Apple's and Kokoro run here; a cloud voice is its own recipient.
    case voice(backend: String, local: Bool)

    var locality: RecipientLocality {
        switch self {
        case .appleOnDevice, .chat: .onDevice
        case .voice(_, let local): local ? .onDevice : .thirdPartyCloud
        case .applePrivateCloud, .iCloudSync: .appleCloud
        case .apiModel, .codingAgent, .acpAgent, .externalAgent, .nearbyPeer: .thirdPartyCloud
        }
    }
    /// Where its reads go, in words the person can check.
    var host: String {
        switch self {
        case .appleOnDevice, .chat: "this device"
        case .applePrivateCloud: PrivateCloudText.journalDestination
        case .apiModel(_, let host): host
        case .codingAgent(let id), .acpAgent(let id), .externalAgent(let id): id
        case .nearbyPeer: "a nearby secure assistant"
        case .iCloudSync: "your private iCloud"
        case .voice(let backend, let local): local ? "this device" : backend
        }
    }
    var kind: RecipientKind {
        switch self {
        case .appleOnDevice: .appleOnDevice
        case .applePrivateCloud: .applePrivateCloud
        case .apiModel: .apiModel
        case .codingAgent: .codingAgent
        case .acpAgent: .acpAgent
        case .externalAgent: .externalAgent
        case .nearbyPeer: .nearbyPeer
        case .chat: .chat
        case .iCloudSync: .iCloudSync
        case .voice: .voice
        }
    }
    /// A stable string for saved grants. A connected model is keyed by its profile alone.
    var key: String {
        switch self {
        case .appleOnDevice: "apple-on-device"
        case .applePrivateCloud: "apple-private-cloud"
        case .apiModel(let profile, _): "api:" + profile.uuidString
        case .codingAgent(let id): "coding:" + id
        case .acpAgent(let id): "acp:" + id
        case .externalAgent(let id): "agent:" + id
        case .nearbyPeer(let id): "nearby:" + id.uuidString
        case .chat(let id): "chat:" + id.uuidString
        case .iCloudSync: "icloud-sync"
        case .voice(let backend, let local): "voice:" + backend + (local ? ":local" : ":cloud")
        }
    }
    static func api(_ profile: APIModelProfile) -> Self {
        .apiModel(profile: profile.id, host: profile.endpoint.host ?? profile.endpoint.absoluteString)
    }
}

/// A recipient without its identity, for restrictions such as "only nearby peers".
enum RecipientKind: String, Codable, CaseIterable, Sendable {
    case appleOnDevice, applePrivateCloud, apiModel, codingAgent, acpAgent, externalAgent, nearbyPeer, chat, iCloudSync, voice
}

extension AppleModel {
    /// Each of Apple's models is its own recipient: Private Cloud is Apple's server, not this device.
    var recipient: RecipientID { self == .onDevice ? .appleOnDevice : .applePrivateCloud }
}

// MARK: Privacy levels

/// How private one item is. The person sets it on memories, docs, journal entries, and whole chats;
/// every other item has a fixed level (`ContextItem`). Higher levels reach fewer recipients.
enum PrivacyLevel: String, Codable, CaseIterable, Comparable, Identifiable, Sendable {
    /// Any model or agent the person uses.
    case open
    /// Apple's models; another company's model or agent only with a grant.
    case personal
    /// Apple's models; another company's model or agent only for that one item, when the person shares it.
    case sensitive
    /// Only models on this device. Never Apple's servers or anyone else.
    case deviceOnly
    /// No model reads it, not even on this device.
    case secret

    var id: String { rawValue }
    private var rank: Int { Self.allCases.firstIndex(of: self) ?? Self.allCases.count }
    static func < (left: Self, right: Self) -> Bool { left.rank < right.rank }
    var title: String {
        switch self {
        case .open: "Open"
        case .personal: "Personal"
        case .sensitive: "Sensitive"
        case .deviceOnly: "Device only"
        case .secret: "Secret"
        }
    }
    /// One short line for pickers.
    var detail: String {
        switch self {
        case .open: "Any model or agent you use."
        case .personal: "Apple’s models. Others when you allow."
        case .sensitive: "Apple’s models. Others only when you share it."
        case .deviceOnly: "Only models on this device."
        case .secret: "No model reads it."
        }
    }
    var symbol: String {
        switch self {
        case .open: "globe"
        case .personal: "person"
        case .sensitive: "hand.raised"
        case .deviceOnly: "lock.iphone"
        case .secret: "lock"
        }
    }
    /// Whether any recipient beyond this device can ever receive it, with any grant.
    var canLeaveDevice: Bool { self < .deviceOnly }

    /// A level written by a newer build that this one doesn't know is treated as the most private.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .secret
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// The least private level that still honors these labels: health, child, or company data is
    /// sensitive, and credential material never leaves the device.
    static func floor(_ labels: BrokerSensitivity) -> Self {
        if labels.contains(.secret) { return .deviceOnly }
        if !labels.isDisjoint(with: [.health, .child, .company]) { return .sensitive }
        if labels.contains(.personal) { return .personal }
        return .open
    }
}

// MARK: Items

enum ContextItemKind: String, Codable, CaseIterable, Sendable {
    case memory, doc, journal, conversation, message, person, connector
    /// A record in a `ContextBroker` namespace.
    case record
    /// What the on-device model extracted for an agent's request (`AgentRequest`).
    case slice
    /// A few messages from Messages: the Mac's history, or what the iPhone's automation shared
    /// (`PersonalSources.swift`). Sensitive, or Device only when the owner chooses.
    case textMessage
    /// This device's approximate location, for "near me". Sensitive.
    case location
}

struct ContextItemRef: Hashable, Codable, Sendable {
    let kind: ContextItemKind
    let id: String
    init(_ kind: ContextItemKind, _ id: String) { self.kind = kind; self.id = id }
    init(_ kind: ContextItemKind, _ id: UUID) { self.init(kind, id.uuidString) }
    /// The form saved in a grant.
    var key: String { kind.rawValue + ":" + id }
}

/// One piece of context and the level that governs it.
struct ContextItem: Hashable, Sendable {
    let ref: ContextItemRef
    let level: PrivacyLevel
    init(_ ref: ContextItemRef, level: PrivacyLevel) { self.ref = ref; self.level = level }

    /// A saved memory. "Not used in chat" is Secret; otherwise the person's choice, or a default from
    /// its labels (the background classifier's, inherited ones, and a company scope).
    static func memory(_ note: MemoryNote, assessment: MemoryPrivacyAssessment? = nil) -> Self {
        .init(.init(.memory, note.id), level: MemoryPrivacy.level(note, assessment: assessment))
    }
    static func doc(_ page: DocPage) -> Self { .init(.init(.doc, page.id), level: page.privacyLevel) }
    static func journal(_ entry: JournalEntry) -> Self { .init(.init(.journal, entry.id), level: entry.privacyLevel) }
    /// A whole chat. Its messages share its level.
    static func conversation(_ id: UUID, level: PrivacyLevel?) -> Self {
        .init(.init(.conversation, id), level: level ?? ConversationPrivacy.defaultLevel)
    }
    /// A People profile. People stay outside model context; this level governs an agent's request for one.
    static func person(_ profile: PeopleProfile) -> Self { .init(.init(.person, profile.id), level: .sensitive) }
    /// What a Calendar, Reminders, or Contacts read returns (`ConnectorReadResult.privacy`).
    static func connector(_ id: ConnectorID) -> Self { .init(.init(.connector, id.rawValue), level: ConnectorReadResult.privacyLevel) }
}

enum MemoryPrivacy {
    static let defaultLevel: PrivacyLevel = .personal
    static func level(_ note: MemoryNote, assessment: MemoryPrivacyAssessment? = nil) -> PrivacyLevel {
        guard note.useInChat else { return .secret }
        if let chosen = note.privacy { return chosen }
        var labels = BrokerSensitivity(rawValue: note.inheritedSensitivity ?? 0)
        if note.scope == "Company" { labels.insert(.company) }
        if let assessment, assessment.noteID == note.id, assessment.fingerprint == PlanningSource.fingerprint(note) {
            labels.formUnion(BrokerSensitivity(rawValue: assessment.labels))
        }
        return max(defaultLevel, PrivacyLevel.floor(labels))
    }
    /// Sets a memory's level. Secret is the same as "Not used in chat", so the two never disagree.
    static func set(_ level: PrivacyLevel, on note: inout MemoryNote) {
        note.useInChat = level != .secret
        note.privacy = level == .secret ? nil : level
    }
}

enum ConversationPrivacy {
    static let defaultLevel: PrivacyLevel = .personal
}

extension DocPage {
    static let defaultPrivacy: PrivacyLevel = .personal
    var privacyLevel: PrivacyLevel { privacy ?? Self.defaultPrivacy }
}

extension JournalEntry {
    /// A journal is intimate by default: Apple's models, and another company's only entry by entry.
    static let defaultPrivacy: PrivacyLevel = .sensitive
    var privacyLevel: PrivacyLevel { privacy ?? Self.defaultPrivacy }
}

/// The level-only part of a memory's identity. Kept apart from `PlanningSource.fingerprint`, so a
/// privacy change reprojects the memory without invalidating notes derived from it.
enum ContextPolicyDigest {
    static func memory(_ note: MemoryNote, assessment: MemoryPrivacyAssessment? = nil) -> String {
        "privacy:" + (note.privacy?.rawValue ?? "default") + ":" + MemoryPrivacy.level(note, assessment: assessment).rawValue
    }
}

extension ContextPurpose {
    static let conversation: Self = "conversation"
    /// Apple's on-device model reading one target for an agent's request.
    static let extraction: Self = "agent-request-extraction"
    static func agentRequest(_ id: UUID) -> Self { .init(rawValue: "agent-request:" + id.uuidString) }
}

// MARK: Grants

/// The person's durable permission for one recipient to receive some items, or every item of some
/// kinds, for one purpose, until an expiry. Saved in the account (`SavedState.recipientGrants`).
/// Stored as plain strings, so a grant written by a newer build never stops the account loading;
/// one this build can't read simply matches nothing.
struct RecipientGrant: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    /// `RecipientID.key`.
    let recipient: String
    /// `ContextItemRef.key` for each item it covers.
    var items: [String]?
    /// `ContextItemKind` raw values it covers. A kind grant never covers a Sensitive item.
    var kinds: [String]?
    /// `ContextPurpose` raw value.
    let purpose: String
    /// nil lasts until the person turns it off.
    var expiresAt: Date?
    /// Covers one disclosure; the caller spends it (`RecipientGrants.spend`).
    var singleUse = false
    var used: Bool?
    var grantedAt = Date()

    init(id: UUID = UUID(), recipient: RecipientID, items: [ContextItemRef] = [], kinds: [ContextItemKind] = [],
         purpose: ContextPurpose, expiresAt: Date? = nil, singleUse: Bool = false, grantedAt: Date = Date()) {
        self.id = id
        self.recipient = recipient.key
        self.items = items.isEmpty ? nil : items.map(\.key)
        self.kinds = kinds.isEmpty ? nil : kinds.map(\.rawValue)
        self.purpose = purpose.rawValue
        self.expiresAt = expiresAt
        self.singleUse = singleUse
        self.grantedAt = grantedAt
    }
    func isLive(now: Date) -> Bool { (expiresAt.map { $0 > now } ?? true) && !(singleUse && used == true) }
    func applies(to recipient: RecipientID, purpose: ContextPurpose, now: Date) -> Bool {
        self.recipient == recipient.key && self.purpose == purpose.rawValue && isLive(now: now)
    }
    func coversItem(_ ref: ContextItemRef) -> Bool { items?.contains(ref.key) == true }
    func coversKind(_ kind: ContextItemKind) -> Bool { kinds?.contains(kind.rawValue) == true }
}

enum RecipientGrants {
    /// Marks single-use grants spent. Call when the disclosure a decision allowed actually happens.
    static func spend(_ ids: [UUID], in grants: inout [RecipientGrant]) {
        for index in grants.indices where ids.contains(grants[index].id) && grants[index].singleUse { grants[index].used = true }
    }
    /// Drops expired and spent grants.
    static func pruned(_ grants: [RecipientGrant], now: Date) -> [RecipientGrant] { grants.filter { $0.isLive(now: now) } }
}

// MARK: The decision

enum DisclosureDenial: Equatable, Sendable {
    /// Personal or Sensitive, to another company's model or agent, without a grant that covers it.
    case needsGrant
    /// Device only, to anything beyond this device.
    case staysOnDevice
    /// Secret: no model reads it.
    case secret
}

struct DisclosureDecision: Equatable, Sendable {
    let recipient: RecipientID
    let purpose: ContextPurpose
    let allowed: [ContextItemRef]
    let denied: [ContextItemRef: DisclosureDenial]
    /// Grants the allowed items rely on; single-use ones are spent by whoever discloses.
    let grantsUsed: [UUID]
    var permitsAll: Bool { denied.isEmpty }
    func permits(_ ref: ContextItemRef) -> Bool { allowed.contains(ref) }
}

/// The one policy. Standing rules by level and locality; grants open only what a level allows them to.
///
/// | Level       | On this device | Apple Private Cloud | Another company's model or agent |
/// |-------------|----------------|---------------------|----------------------------------|
/// | Open        | yes            | yes                 | yes                              |
/// | Personal    | yes            | yes                 | with an item or kind grant       |
/// | Sensitive   | yes            | yes                 | with a grant for that item       |
/// | Device only | yes            | never               | never                            |
/// | Secret      | never          | never               | never                            |
///
/// Private Cloud sharing on-device's context is the owner's rule, and it's expressed here, so a
/// Device only item never reaches it. The person's private iCloud database is storage for their own
/// devices, not a reader: it keeps every item, in encrypted fields.
enum ContextPolicy {
    static func evaluate(_ items: [ContextItem], to recipient: RecipientID, purpose: ContextPurpose,
                         grants: [RecipientGrant], now: Date) -> DisclosureDecision {
        let live = grants.filter { $0.applies(to: recipient, purpose: purpose, now: now) }
        var allowed: [ContextItemRef] = [], denied: [ContextItemRef: DisclosureDenial] = [:], used: [UUID] = []
        for item in items {
            switch decide(item, recipient: recipient, grants: live) {
            case .success(let grant):
                allowed.append(item.ref)
                if let grant, !used.contains(grant) { used.append(grant) }
            case .failure(let reason): denied[item.ref] = reason
            }
        }
        return .init(recipient: recipient, purpose: purpose, allowed: allowed, denied: denied, grantsUsed: used)
    }
    static func allows(_ item: ContextItem, to recipient: RecipientID, purpose: ContextPurpose = .conversation,
                       grants: [RecipientGrant] = [], now: Date = Date()) -> Bool {
        evaluate([item], to: recipient, purpose: purpose, grants: grants, now: now).permitsAll
    }
    /// The items of `items` this recipient may have, in their order.
    static func filter<T>(_ values: [T], item: (T) -> ContextItem, to recipient: RecipientID, purpose: ContextPurpose = .conversation,
                          grants: [RecipientGrant] = [], now: Date = Date()) -> [T] {
        values.filter { allows(item($0), to: recipient, purpose: purpose, grants: grants, now: now) }
    }
    /// Whether a reader may have Device only items: exactly when it runs on this device. The lock on
    /// the model button shows this. (iCloud keeps every item as storage, not as a reader.)
    static func keepsEverythingOnDevice(_ recipient: RecipientID) -> Bool {
        recipient != .iCloudSync && allows(.init(.init(.record, "device-only-probe"), level: .deviceOnly), to: recipient, purpose: .conversation)
    }

    private static func decide(_ item: ContextItem, recipient: RecipientID,
                               grants: [RecipientGrant]) -> Result<UUID?, DisclosureDenial> {
        if recipient == .iCloudSync { return .success(nil) }
        switch item.level {
        case .secret: return .failure(.secret)
        case .deviceOnly: return recipient.locality == .onDevice ? .success(nil) : .failure(.staysOnDevice)
        case .open: return .success(nil)
        case .personal, .sensitive:
            if recipient.locality != .thirdPartyCloud { return .success(nil) }
            if let grant = grants.first(where: { $0.coversItem(item.ref) }) { return .success(grant.id) }
            if item.level == .personal, let grant = grants.first(where: { $0.coversKind(item.ref.kind) }) { return .success(grant.id) }
            return .failure(.needsGrant)
        }
    }
}

extension DisclosureDenial: Error {}

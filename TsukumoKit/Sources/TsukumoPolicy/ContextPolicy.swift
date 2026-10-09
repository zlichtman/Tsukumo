import Foundation
import TsukumoCore

/// The owner's permission for one recipient to receive some items, or every item of some kinds,
/// for one purpose, until an expiry. Stored as plain strings, so a grant written by a newer build
/// never stops anything loading; one this build can't read simply matches nothing.
public struct RecipientGrant: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// `RecipientID.grantKey`.
    public let recipient: String
    /// `PolicyItem.key` for each item it covers.
    public var items: [String]
    /// `ItemKind` raw values it covers. A kind grant never covers a Sensitive item.
    public var kinds: [String]
    public let purpose: Purpose
    /// Nil lasts until the owner turns it off.
    public var expiresAt: Date?
    /// Covers one disclosure; whoever discloses spends it (`RecipientGrants.spend`).
    public var singleUse: Bool
    public var used: Bool
    public var grantedAt: Date

    public init(id: UUID = UUID(), recipient: RecipientID, items: [PolicyItem] = [], kinds: [ItemKind] = [], purpose: Purpose,
                expiresAt: Date? = nil, singleUse: Bool = false, grantedAt: Date = Date()) {
        self.id = id
        self.recipient = recipient.grantKey
        self.items = items.map(\.key)
        self.kinds = kinds.map(\.rawValue)
        self.purpose = purpose
        self.expiresAt = expiresAt
        self.singleUse = singleUse
        self.used = false
        self.grantedAt = grantedAt
    }

    public func isLive(now: Date) -> Bool { (expiresAt.map { $0 > now } ?? true) && !(singleUse && used) }
    public func applies(to recipient: RecipientID, purpose: Purpose, now: Date) -> Bool {
        self.recipient == recipient.grantKey && self.purpose == purpose && isLive(now: now)
    }
    public func covers(item: PolicyItem) -> Bool { items.contains(item.key) }
    public func covers(kind: ItemKind) -> Bool { kinds.contains(kind.rawValue) }

    private enum CodingKeys: String, CodingKey { case id, recipient, items, kinds, purpose, expiresAt, singleUse, used, grantedAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        recipient = try c.decode(String.self, forKey: .recipient)
        items = try c.decodeIfPresent([String].self, forKey: .items) ?? []
        kinds = try c.decodeIfPresent([String].self, forKey: .kinds) ?? []
        purpose = try c.decode(Purpose.self, forKey: .purpose)
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
        singleUse = try c.decodeIfPresent(Bool.self, forKey: .singleUse) ?? false
        used = try c.decodeIfPresent(Bool.self, forKey: .used) ?? false
        grantedAt = try c.decodeIfPresent(Date.self, forKey: .grantedAt) ?? .distantPast
    }
}

public enum RecipientGrants {
    /// Marks single-use grants spent. Call when the disclosure a decision allowed actually happens.
    public static func spend(_ ids: [UUID], in grants: inout [RecipientGrant]) {
        for index in grants.indices where ids.contains(grants[index].id) && grants[index].singleUse { grants[index].used = true }
    }
    /// Drops expired and spent grants.
    public static func pruned(_ grants: [RecipientGrant], now: Date) -> [RecipientGrant] { grants.filter { $0.isLive(now: now) } }
}

/// Why an item may not go to a recipient.
public enum PolicyDenial: String, Codable, Hashable, Sendable, Error {
    /// Personal or Sensitive, to another company's model or agent, without a grant that covers it.
    case needsGrant
    /// Device only, to anything beyond this device.
    case staysOnDevice
    /// Secret: no model reads it.
    case secret
    /// Above the most private level this recipient (a bot) may ever receive.
    case aboveCeiling
}

/// What the policy decided for a set of items and one recipient.
public struct PolicyDecision: Hashable, Sendable {
    public let recipient: RecipientID
    public let purpose: Purpose
    public let allowed: [PolicyItem]
    public let denied: [PolicyItem: PolicyDenial]
    /// Grants the allowed items rely on; single-use ones are spent by whoever discloses.
    public let grantsUsed: [UUID]
    public var permitsAll: Bool { denied.isEmpty }
    public func permits(_ item: PolicyItem) -> Bool { allowed.contains(item) }
}

/// The one policy: a pure function of type labels, the recipient, the purpose, and grants.
///
/// | Level       | On this device | Apple's servers (Private Cloud, iCloud) | Another company's model or agent |
/// |-------------|----------------|------------------------------------------|----------------------------------|
/// | Open        | yes            | yes                                      | yes                              |
/// | Personal    | yes            | yes                                      | with an item or kind grant       |
/// | Sensitive   | yes            | yes                                      | with a grant for that item       |
/// | Device only | yes            | never                                    | never                            |
/// | Secret      | never          | never                                    | never                            |
///
/// A `ceiling` (a bot's `ContextScope.ceiling`) can only take more away.
public enum ContextPolicy {
    public static func evaluate(_ items: [PolicyItem], to recipient: RecipientID, purpose: Purpose,
                                grants: [RecipientGrant], ceiling: PrivacyLevel? = nil, now: Date) -> PolicyDecision {
        let live = grants.filter { $0.applies(to: recipient, purpose: purpose, now: now) }
        var allowed: [PolicyItem] = [], denied: [PolicyItem: PolicyDenial] = [:], used: [UUID] = []
        for item in items {
            switch decide(item, recipient: recipient, grants: live, ceiling: ceiling) {
            case .success(let grant):
                allowed.append(item)
                if let grant, !used.contains(grant) { used.append(grant) }
            case .failure(let reason):
                denied[item] = reason
            }
        }
        return PolicyDecision(recipient: recipient, purpose: purpose, allowed: allowed, denied: denied, grantsUsed: used)
    }

    public static func allows(_ item: PolicyItem, to recipient: RecipientID, purpose: Purpose = .conversation,
                              grants: [RecipientGrant] = [], ceiling: PrivacyLevel? = nil, now: Date = Date()) -> Bool {
        evaluate([item], to: recipient, purpose: purpose, grants: grants, ceiling: ceiling, now: now).permitsAll
    }

    /// The values this recipient may have, in their order. Use it for metadata too: a title or a
    /// manifest line carries the label of the item it describes.
    public static func filter<T>(_ values: [T], item: (T) -> PolicyItem, to recipient: RecipientID, purpose: Purpose = .conversation,
                                 grants: [RecipientGrant] = [], ceiling: PrivacyLevel? = nil, now: Date = Date()) -> [T] {
        values.filter { allows(item($0), to: recipient, purpose: purpose, grants: grants, ceiling: ceiling, now: now) }
    }

    /// Whether a recipient may have Device only items: exactly when it runs on this device.
    public static func keepsEverythingOnDevice(_ recipient: RecipientID) -> Bool {
        allows(PolicyItem(.note, "device-only-probe", level: .deviceOnly), to: recipient)
    }

    private static func decide(_ item: PolicyItem, recipient: RecipientID, grants: [RecipientGrant],
                               ceiling: PrivacyLevel?) -> Result<UUID?, PolicyDenial> {
        let level = item.label.level
        if level == .secret { return .failure(.secret) }
        if level == .deviceOnly, recipient.locality != .onDevice { return .failure(.staysOnDevice) }
        if let ceiling, level > ceiling { return .failure(.aboveCeiling) }
        switch level {
        case .open, .deviceOnly, .secret:
            return .success(nil)
        case .personal, .sensitive:
            if recipient.locality != .thirdPartyCloud { return .success(nil) }
            if let grant = grants.first(where: { $0.covers(item: item) }) { return .success(grant.id) }
            if level == .personal, let grant = grants.first(where: { $0.covers(kind: item.label.kind) }) { return .success(grant.id) }
            return .failure(.needsGrant)
        }
    }
}

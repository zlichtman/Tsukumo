import Foundation

// The shared vocabulary that messages and bots need and every other module speaks: how private an
// item is, and how a message points at a stored artifact or a KemoSabe exchange. The store itself
// lives in TsukumoContext and the rules in TsukumoPolicy; only the names live here, so Core stays
// at the bottom of the dependency list.

// MARK: Privacy levels

/// How private one item is. Higher levels reach fewer recipients (TsukumoPolicy decides who).
///
/// | Level       | On this device | Apple's servers | Another company's model or agent |
/// |-------------|----------------|-----------------|----------------------------------|
/// | Open        | yes            | yes             | yes                              |
/// | Personal    | yes            | yes             | with an item or kind grant       |
/// | Sensitive   | yes            | yes             | with a grant for that item       |
/// | Device only | yes            | never           | never                            |
/// | Secret      | never          | never           | never                            |
public enum PrivacyLevel: String, Codable, CaseIterable, Comparable, Identifiable, Sendable {
    case open
    case personal
    case sensitive
    case deviceOnly
    case secret

    public var id: String { rawValue }
    private var rank: Int { Self.allCases.firstIndex(of: self) ?? Self.allCases.count }
    public static func < (left: Self, right: Self) -> Bool { left.rank < right.rank }

    public var title: String {
        switch self {
        case .open: "Open"
        case .personal: "Personal"
        case .sensitive: "Sensitive"
        case .deviceOnly: "Device only"
        case .secret: "Secret"
        }
    }
    /// One short line for pickers.
    public var detail: String {
        switch self {
        case .open: "Any model or agent you use."
        case .personal: "Apple’s models. Others when you allow."
        case .sensitive: "Apple’s models. Others only when you share it."
        case .deviceOnly: "Only models on this device."
        case .secret: "No model reads it."
        }
    }
    /// Whether any recipient beyond this device can ever receive it, with any grant.
    public var canLeaveDevice: Bool { self < .deviceOnly }

    /// A level written by a newer build that this one doesn't know is treated as the most private.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .secret
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: Artifacts

/// One artifact in the store, across all its revisions.
public struct ArtifactID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { rawValue = UUID() }
    public var description: String { rawValue.uuidString }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(UUID.self) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}

/// A pinned pointer at one revision of one artifact. A read through it fails if the artifact has
/// moved on or its content no longer hashes to `sha256`, so a reference never serves stale text.
public struct ArtifactRef: Hashable, Codable, Sendable {
    public let id: ArtifactID
    /// Starts at 1; every change makes a new revision and never overwrites an old one.
    public let revision: Int
    /// Lowercase hex SHA-256 of the revision's content.
    public let sha256: String
    public init(id: ArtifactID, revision: Int, sha256: String) {
        self.id = id
        self.revision = revision
        self.sha256 = sha256
    }
}

// MARK: KemoSabe exchanges

/// One question an agent asked KemoSabe and everything that followed (consent, the answer, the
/// journal entry). Message parts and the Gate's journal share it.
public struct GateExchangeID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { rawValue = UUID() }
    public var description: String { rawValue.uuidString }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(UUID.self) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}

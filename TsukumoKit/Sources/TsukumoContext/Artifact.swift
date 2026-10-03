import Foundation
import CryptoKit
import TsukumoCore
import TsukumoPolicy

/// What an artifact holds.
public struct ArtifactKind: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public var description: String { rawValue }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }

    /// A file an agent read or wrote.
    public static let file: ArtifactKind = "file"
    /// What a tool returned.
    public static let toolResult: ArtifactKind = "toolResult"
    /// One message in a thread, kept whole.
    public static let turn: ArtifactKind = "turn"
    /// KemoSabe's answer to an agent, kept on the device.
    public static let personalAnswer: ArtifactKind = "personalAnswer"
    /// Anything the owner or a bot wrote down.
    public static let note: ArtifactKind = "note"

    /// The policy kind its label uses.
    public var itemKind: ItemKind { ItemKind(rawValue: rawValue) }
}

/// One revision of one artifact, without its content. Content comes only through a pinned read.
public struct Artifact: Hashable, Sendable {
    public let ref: ArtifactRef
    public let kind: ArtifactKind
    /// The label it was stored with.
    public let label: TypeLabel
    /// Who made it.
    public let owner: Author
    /// One line about it, for the manifest. Labeled and filtered like the content.
    public let summaryLine: String
    /// Where it came from ("Sources/App.swift", "web_search"), when that's known.
    public let source: String?
    /// The exact revisions it was derived from.
    public let lineage: [ArtifactRef]
    public let createdAt: Date
    public let lineCount: Int
    public let byteCount: Int
}

/// What to store: a new artifact (no `id`), or a new revision of one (`id` and the revision it
/// builds on, so two writers never silently overwrite each other).
public struct ArtifactDraft: Sendable {
    public var id: ArtifactID?
    /// The revision this one replaces; required with `id`.
    public var basedOn: Int?
    public var kind: ArtifactKind
    public var label: TypeLabel
    public var owner: Author
    public var summaryLine: String
    public var source: String?
    public var content: String

    public init(id: ArtifactID? = nil, basedOn: Int? = nil, kind: ArtifactKind, level: PrivacyLevel, owner: Author,
                summaryLine: String, source: String? = nil, content: String) {
        self.id = id; self.basedOn = basedOn; self.kind = kind
        self.label = TypeLabel(kind: kind.itemKind, level: level)
        self.owner = owner; self.summaryLine = summaryLine; self.source = source; self.content = content
    }
}

/// One line of the manifest: what a recipient may know exists. Never content.
public struct ManifestEntry: Hashable, Sendable {
    public let ref: ArtifactRef
    public let kind: ArtifactKind
    /// Its effective label (its own, raised by its sources'), so a caller passing the summary on
    /// (System One, say) can check that recipient too.
    public let label: TypeLabel
    public let summaryLine: String
    public let source: String?
    public let owner: Author
    public let lineCount: Int
    public let byteCount: Int
    public let createdAt: Date
    /// It was derived from a revision that has since changed: its sources say something newer now.
    public let sourcesChanged: Bool
}

/// Exactly the lines asked for, from exactly the revision asked for.
public struct Page: Hashable, Sendable {
    public let ref: ArtifactRef
    /// 1-based, inclusive.
    public let lines: ClosedRange<Int>
    public let totalLines: Int
    public let text: String
    public let lineage: [ArtifactRef]
    /// Grants the read relied on; the caller spends single-use ones (`RecipientGrants.spend`).
    public let grantsUsed: [UUID]
    public var isWhole: Bool { lines.lowerBound == 1 && lines.upperBound == totalLines }
}

public enum ArtifactStoreError: Error, Hashable, Sendable {
    case invalidDraft(String)
    /// `basedOn` isn't the current revision: someone else wrote first.
    case revisionConflict(current: Int)
    /// A lineage reference names a missing, revoked, or moved-on revision.
    case invalidLineage
    case notFound
    case revoked
    /// The reference names an older revision: the artifact has changed since.
    case staleRevision(current: Int)
    /// The content no longer hashes to the reference's SHA-256.
    case hashMismatch
    case invalidRange
    /// The read is bigger than its budget. It fails rather than being cut; ask for fewer lines.
    case overBudget(bytes: Int, budget: Int)
    case notPermitted(PolicyDenial)
}

enum ArtifactHash {
    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

import Foundation
import TsukumoCore

/// What an item is. Each kind has a floor: the least private level an item of that kind may carry.
/// Open for new kinds: a kind this build doesn't know has no floor beyond its label.
public struct ItemKind: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public var description: String { rawValue }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }

    // Artifacts (TsukumoContext).
    public static let file: ItemKind = "file"
    public static let toolResult: ItemKind = "toolResult"
    public static let turn: ItemKind = "turn"
    public static let note: ItemKind = "note"
    /// What KemoSabe extracted for an agent. Its label comes from the sources it was read from.
    public static let personalAnswer: ItemKind = "personalAnswer"
    // Personal sources (TsukumoGate).
    public static let textMessage: ItemKind = "textMessage"
    public static let calendarEvent: ItemKind = "calendarEvent"
    public static let reminder: ItemKind = "reminder"
    public static let contact: ItemKind = "contact"
    public static let location: ItemKind = "location"
    /// A password, key, door code, or anything else that unlocks something.
    public static let credential: ItemKind = "credential"
    public static let health: ItemKind = "health"

    /// The least private level an item of this kind may have. A label below it is raised to it.
    public var floor: PrivacyLevel {
        switch self {
        case .credential: .deviceOnly
        case .location, .health: .sensitive
        // Messages are Personal at least, so an agent the owner allowed always can be answered
        // from them (the demo); the owner can raise a source to Sensitive or Device only.
        case .textMessage, .contact, .calendarEvent, .reminder, .personalAnswer: .personal
        default: .open
        }
    }
}

/// An item's type label: its kind and level. The only input the policy reads; no model output and
/// no item content can change a decision except through a label.
public struct TypeLabel: Hashable, Codable, Sendable {
    public let kind: ItemKind
    public let level: PrivacyLevel
    /// The level is raised to the kind's floor; it is never below it.
    public init(kind: ItemKind, level: PrivacyLevel) {
        self.kind = kind
        self.level = max(level, kind.floor)
    }
    private enum CodingKeys: String, CodingKey { case kind, level }
    /// A saved label below its kind's floor is raised on reading, too.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kind: try c.decode(ItemKind.self, forKey: .kind), level: try c.decode(PrivacyLevel.self, forKey: .level))
    }

    /// This label after a classifier's proposal: raised when it proposes a more private level,
    /// unchanged when it proposes a less private one. A classifier can never lower a label.
    public func raised(by proposal: PrivacyLevel?) -> TypeLabel {
        guard let proposal, proposal > level else { return self }
        return TypeLabel(kind: kind, level: proposal)
    }
    /// The most private of several labels (an item derived from them all), as `kind`.
    public static func combining(_ labels: [TypeLabel], as kind: ItemKind) -> TypeLabel {
        TypeLabel(kind: kind, level: labels.map(\.level).max() ?? .open)
    }
}

/// Something that proposes a level for an item from its content (a research knob, swappable). It
/// lives outside the policy; its proposal only ever raises a label (`TypeLabel.raised(by:)`).
public protocol LabelClassifier: Sendable {
    func propose(kind: ItemKind, text: String) async -> PrivacyLevel?
}

/// One item the policy decides on: an identity and its label. Metadata (a title, a name, a manifest
/// line) is labeled with the item it describes and filtered the same way.
public struct PolicyItem: Hashable, Sendable {
    public let id: String
    public let label: TypeLabel
    public init(id: String, label: TypeLabel) { self.id = id; self.label = label }
    public init(_ kind: ItemKind, _ id: String, level: PrivacyLevel) { self.init(id: id, label: TypeLabel(kind: kind, level: level)) }
    /// The form saved in a grant: "kind:id".
    public var key: String { label.kind.rawValue + ":" + id }
}

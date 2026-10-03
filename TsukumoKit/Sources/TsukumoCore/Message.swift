import Foundation

/// Who wrote a message. Saved as one string ("owner", "bot:<UUID>", "system").
public enum Author: Hashable, Codable, Sendable {
    case owner
    /// A bot, KemoSabe included (`BotSpec.kemoSabeID`).
    case bot(UUID)
    /// A line from Tsukumo itself.
    case system

    public var key: String {
        switch self {
        case .owner: "owner"
        case .bot(let id): "bot:" + id.uuidString
        case .system: "system"
        }
    }
    public var botID: UUID? { if case .bot(let id) = self { id } else { nil } }

    /// An author a newer build wrote that this one can't read shows as a system line.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw == "owner" { self = .owner }
        else if raw.hasPrefix("bot:"), let id = UUID(uuidString: String(raw.dropFirst(4))) { self = .bot(id) }
        else { self = .system }
    }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(key) }
}

/// An agent's question to KemoSabe, as its card shows it while KemoSabe reads (or asks the owner).
public struct GateQuestionCard: Codable, Hashable, Sendable {
    public enum State: String, Codable, Sendable {
        /// KemoSabe is reading on the device.
        case reading
        /// The first time: the owner is asked (Allow always, Allow once, Don't allow).
        case needsConsent
        public init(from decoder: Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .reading
        }
    }
    public var exchange: GateExchangeID
    /// The bot that asked, when a bot did.
    public var askedBy: UUID?
    /// "Claude"
    public var askerName: String
    /// "What time is Sarah free tonight?"
    public var question: String
    /// Why it asked ("planning a date").
    public var purpose: String
    public var state: State

    public init(exchange: GateExchangeID, askedBy: UUID?, askerName: String, question: String, purpose: String, state: State = .reading) {
        self.exchange = exchange; self.askedBy = askedBy; self.askerName = askerName
        self.question = question; self.purpose = purpose; self.state = state
    }
}

/// KemoSabe's answer card: what it read on the device, what it shared, and what stayed. It never
/// holds the content that stayed behind, only how much there was.
public struct GateAnswerCard: Codable, Hashable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        /// Answered; `shared` is exactly what went to the agent.
        case answered
        /// The owner said Don't allow, or the quiet period after it is still on.
        case denied
        /// Nothing the agent may have could answer it.
        case nothingToShare
        /// KemoSabe couldn't answer here (a locked device, no on-device model).
        case unavailable
        public init(from decoder: Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unavailable
        }
    }
    public var exchange: GateExchangeID
    public var askerName: String
    public var question: String
    public var outcome: Outcome
    /// Exactly what went to the agent ("After 7 tonight").
    public var shared: String?
    /// How much was read and stayed on the device ("7 messages, 2 chats"), never the words.
    public var stayed: String?
    /// The device that answered ("iPhone", "Mac").
    public var device: String
    /// The stored answer (a `personalAnswer` artifact on the device), so a later turn can refer to it.
    public var answer: ArtifactRef?
    /// What KemoSabe left unread because the agent may never have it ("1 Device only chat"), never
    /// its words. Nil when nothing was left out.
    public var notRead: String? = nil
    /// What KemoSabe read but the owner didn't share on its card ("1 Sensitive chat"), never its words.
    public var notShared: String? = nil

    public init(exchange: GateExchangeID, askerName: String, question: String, outcome: Outcome, shared: String? = nil,
                stayed: String? = nil, device: String, answer: ArtifactRef? = nil) {
        self.exchange = exchange; self.askerName = askerName; self.question = question; self.outcome = outcome
        self.shared = shared; self.stayed = stayed; self.device = device; self.answer = answer
    }

    /// "On this iPhone · Apple on-device"
    public var caption: String { "On this \(device) · Apple on-device" }
    /// "Stayed on this iPhone: 7 messages, 2 chats"
    public var stayedLine: String? { stayed.map { "Stayed on this \(device): \($0)" } }
    /// "Not read: 1 Device only chat."
    public var notReadLine: String? { notRead.map { "Not read: \($0)." } }
    /// "Not shared: 1 Sensitive chat."
    public var notSharedLine: String? { notShared.map { "Not shared: \($0)." } }
}

/// One piece of a message. Saved with a "type" field; a part a newer build added is kept whole as
/// `.unknown` and written back unchanged, so a round trip never loses it.
public enum Part: Hashable, Codable, Sendable {
    case text(String)
    /// An agent asked KemoSabe something.
    case gateQuestion(GateQuestionCard)
    /// KemoSabe's answer card.
    case gateAnswer(GateAnswerCard)
    /// A line about the bot itself ("Codex isn't signed in", "Stopped").
    case status(String)
    /// A reference to a stored artifact (a file, a tool result, an earlier turn, an answer).
    case artifact(ArtifactRef)
    /// Written by a newer build; shown as nothing, kept as written.
    case unknown(JSONValue)

    private enum CodingKeys: String, CodingKey { case type, text, card, ref }
    private enum Kind: String { case text, gateQuestion, gateAnswer, status, artifact }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch Kind(rawValue: type) {
        case .text: self = .text(try c.decode(String.self, forKey: .text))
        case .status: self = .status(try c.decode(String.self, forKey: .text))
        case .gateQuestion: self = .gateQuestion(try c.decode(GateQuestionCard.self, forKey: .card))
        case .gateAnswer: self = .gateAnswer(try c.decode(GateAnswerCard.self, forKey: .card))
        case .artifact: self = .artifact(try c.decode(ArtifactRef.self, forKey: .ref))
        case nil: self = .unknown(try JSONValue(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        if case .unknown(let value) = self { try value.encode(to: encoder); return }
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text): try c.encode(Kind.text.rawValue, forKey: .type); try c.encode(text, forKey: .text)
        case .status(let text): try c.encode(Kind.status.rawValue, forKey: .type); try c.encode(text, forKey: .text)
        case .gateQuestion(let card): try c.encode(Kind.gateQuestion.rawValue, forKey: .type); try c.encode(card, forKey: .card)
        case .gateAnswer(let card): try c.encode(Kind.gateAnswer.rawValue, forKey: .type); try c.encode(card, forKey: .card)
        case .artifact(let ref): try c.encode(Kind.artifact.rawValue, forKey: .type); try c.encode(ref, forKey: .ref)
        case .unknown: break
        }
    }
}

/// One message in a thread.
public struct Message: Codable, Identifiable, Hashable, Sendable {
    public static let maxText = 8000

    public var id: UUID
    public var date: Date
    public var author: Author
    public var parts: [Part]
    /// The bots it went to (an owner's message), in thread order, each once.
    public var tags: [UUID]

    public init(id: UUID = UUID(), date: Date = Date(), author: Author, parts: [Part], tags: [UUID] = []) {
        self.id = id; self.date = date; self.author = author; self.parts = parts; self.tags = tags
    }
    public static func owner(_ text: String, tags: [UUID], date: Date = Date()) -> Message {
        Message(date: date, author: .owner, parts: [.text(text)], tags: tags)
    }

    /// Its text parts, joined.
    public var text: String {
        parts.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: "\n")
    }
    /// Every artifact it refers to, in order, each once (answer cards included).
    public var references: [ArtifactRef] {
        var refs: [ArtifactRef] = []
        for part in parts {
            let ref: ArtifactRef? = switch part {
            case .artifact(let ref): ref
            case .gateAnswer(let card): card.answer
            default: nil
            }
            if let ref, !refs.contains(ref) { refs.append(ref) }
        }
        return refs
    }

    private enum CodingKeys: String, CodingKey { case id, date, author, parts, tags }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        author = try c.decode(Author.self, forKey: .author)
        parts = try c.decodeIfPresent([Part].self, forKey: .parts) ?? []
        tags = try c.decodeIfPresent([UUID].self, forKey: .tags) ?? []
    }
}

import Foundation
import TsukumoCore
import TsukumoPolicy

/// An agent's question to KemoSabe ("What time is Sarah free tonight?"), from its `ask_kemosabe` tool.
public struct GateQuestion: Identifiable, Hashable, Sendable {
    public static let maxQuestion = 500, maxPurpose = 200

    public var id: GateExchangeID
    public let requester: RecipientID
    /// "Claude"
    public let requesterName: String
    /// The bot that asked, when a bot did (its `ContextScope` limits what KemoSabe reads for it).
    public let botID: UUID?
    public let question: String
    /// Why it's asking, in its words.
    public let purpose: String
    public var receivedAt: Date

    public init(id: GateExchangeID = GateExchangeID(), requester: RecipientID, requesterName: String, botID: UUID? = nil,
                question: String, purpose: String, receivedAt: Date = Date()) {
        self.id = id; self.requester = requester; self.requesterName = requesterName; self.botID = botID
        self.question = question; self.purpose = purpose; self.receivedAt = receivedAt
    }

    /// One short question, a short purpose, a name, and a requester that isn't on this device
    /// (an on-device model reads directly; it never asks the Gate).
    public var isValid: Bool {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && text.count <= Self.maxQuestion && purpose.count <= Self.maxPurpose
            && !requesterName.trimmingCharacters(in: .whitespaces).isEmpty && requester.locality != .onDevice
    }
}

/// The owner's first answer to "Let Claude ask KemoSabe?".
public enum Consent: String, Codable, Hashable, Sendable { case always, once, deny }

/// What the agent gets back.
public enum GateOutcome: Hashable, Sendable {
    /// Exactly what was sent.
    case answered(String)
    case notFound
    /// The owner said no, to the agent or to this item.
    case declined
    /// The owner hasn't answered the prompt or card yet.
    case waiting
    /// Locked, or Apple's on-device model isn't ready.
    case unavailable(String)
    /// The question itself is malformed.
    case refused(String)

    /// What the agent reads.
    public func text(owner: String = "The owner", device: String) -> String {
        switch self {
        case .answered(let text): text
        case .notFound: "KemoSabe couldn’t find that in what it may share with you."
        case .declined: "\(owner) didn’t share that. Don’t ask again for it; carry on without it or ask them directly."
        case .waiting: "\(owner) hasn’t answered on their \(device) yet. Ask again in a minute."
        case .unavailable(let reason), .refused(let reason): reason
        }
    }
    public var cardOutcome: GateAnswerCard.Outcome {
        switch self {
        case .answered: .answered
        case .notFound: .nothingToShare
        case .declined: .denied
        case .waiting, .unavailable, .refused: .unavailable
        }
    }
}

/// One personal item an answer might come from (a Messages chat, an event, a contact). Its text is
/// read only by Apple's on-device model, on this device.
public struct PersonalItem: Hashable, Sendable {
    public let id: String
    public let label: TypeLabel
    /// How the owner's transcript names it ("your conversation with Sarah").
    public let title: String
    public let text: String
    public var date: Date?
    /// For a chat: how many messages it holds ("Stayed on this iPhone: 7 messages, 2 chats").
    public var messages: Int
    /// The source found it by searching for this question, so it ranks as relevant even when it
    /// shares no word with the question.
    public var matched: Bool

    public init(id: String, kind: ItemKind, level: PrivacyLevel, title: String, text: String, date: Date? = nil,
                messages: Int = 0, matched: Bool = false) {
        self.id = id; self.label = TypeLabel(kind: kind, level: level); self.title = title; self.text = text
        self.date = date; self.messages = messages; self.matched = matched
    }
    public var policyItem: PolicyItem { PolicyItem(id: id, label: label) }
}

/// Where answers come from: Calendar, Reminders, Contacts, Messages, Photos, picked files, Location, Music,
/// connected accounts (`SourceLibrary`). Each labels its own
/// items; the Gate decides what may be read.
public protocol PersonalSource: Sendable {
    func items(matching question: GateQuestion) async -> [PersonalItem]
}

/// What an answer left out, as counts by reason, level, and kind. Never content.
public struct Withheld: Codable, Hashable, Sendable {
    public enum Reason: String, Codable, Sendable {
        /// Device only, Secret, or above the bot's ceiling: never read for an agent.
        case notRead
        /// Read on the device but not shared (Sensitive, not shared on its card).
        case notShared
    }
    public private(set) var counts: [String: Int] = [:]
    public init() {}
    public var isEmpty: Bool { counts.isEmpty }
    public var total: Int { counts.values.reduce(0, +) }
    public mutating func add(_ reason: Reason, _ label: TypeLabel) {
        counts[reason.rawValue + "." + label.level.rawValue + "." + label.kind.rawValue, default: 0] += 1
    }
    /// "Not read: 1 Device only note. Not shared: 1 Sensitive Messages chat."
    public var summary: String {
        func part(_ reason: Reason) -> String? {
            let items = counts.keys.filter { $0.hasPrefix(reason.rawValue + ".") }.sorted().compactMap { key -> String? in
                let pieces = key.split(separator: ".", maxSplits: 2).map(String.init)
                guard pieces.count == 3, let level = PrivacyLevel(rawValue: pieces[1]), let count = counts[key] else { return nil }
                return "\(count) \(level.title) \(PersonalNouns.noun(ItemKind(rawValue: pieces[2]), count: count))"
            }
            return items.isEmpty ? nil : items.joined(separator: ", ")
        }
        var lines: [String] = []
        if let read = part(.notRead) { lines.append("Not read: " + read + ".") }
        if let shared = part(.notShared) { lines.append("Not shared: " + shared + ".") }
        return lines.joined(separator: " ")
    }
}

enum PersonalNouns {
    static func noun(_ kind: ItemKind, count: Int = 1) -> String {
        let one = count == 1
        switch kind {
        case .textMessage: return one ? "chat" : "chats"
        case .calendarEvent: return one ? "calendar event" : "calendar events"
        case .reminder: return one ? "reminder" : "reminders"
        case .contact: return one ? "contact" : "contacts"
        case .location: return "location"
        case .credential: return one ? "secure note" : "secure notes"
        case .note: return one ? "note" : "notes"
        case .health: return one ? "health item" : "health items"
        case .email: return one ? "email" : "emails"
        case .photo: return one ? "photo record" : "photo records"
        case .document: return one ? "file" : "files"
        case .music: return "listening history"
        case .connector: return one ? "connected account result" : "connected account results"
        default: return one ? "item" : "items"
        }
    }

    /// "7 messages, 2 chats, 1 calendar event": what was looked at on the device, as counts only.
    static func stayed(_ items: [PersonalItem]) -> String? {
        let messages = items.reduce(0) { $0 + $1.messages }
        var parts: [String] = []
        if messages > 0 { parts.append("\(messages) message" + (messages == 1 ? "" : "s")) }
        var order: [ItemKind] = [], counts: [ItemKind: Int] = [:]
        for item in items {
            if counts[item.label.kind] == nil { order.append(item.label.kind) }
            counts[item.label.kind, default: 0] += 1
        }
        for kind in order { parts.append("\(counts[kind] ?? 0) " + noun(kind, count: counts[kind] ?? 0)) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// "your chats and calendar events": the kinds read, for the owner's journal.
    static func readSummary(_ items: [PersonalItem]) -> String {
        var nouns: [String] = []
        for item in items {
            let noun = noun(item.label.kind, count: 2)
            if !nouns.contains(noun) { nouns.append(noun) }
        }
        guard let last = nouns.last else { return "nothing it may read matched" }
        return "your " + (nouns.count == 1 ? last : nouns.dropLast().joined(separator: ", ") + " and " + last)
    }
}

import Foundation

// What the fixed lineup of 2.05 (October 7, 2026) retired, kept for good. 2.05 moved the owner's custom bots into one
// bot per service: a bot whose engine was a service's folded into that service's bot (its messages and tags moving to
// it, its conversation merging into the service's), and any other left the dock (its messages staying as lines from
// Tsukumo with its name); a backup of each was written first. Since October 8, 2026 the owner makes bots again, so
// nothing is moved any more, but what 2.05 moved stays moved: its aliases (`LineupAliases`) map the old IDs, so a
// device that still holds the old bots and chats is understood when it syncs, never mistaken for new bots or for
// deletions.

/// What the lineup migration retired, kept for good: each folded bot's service bot, each archived bot, and each chat
/// merged into another.
public struct LineupAliases: Codable, Hashable, Sendable {
    /// A folded bot's ID to its service bot's.
    public var bots: [UUID: UUID] = [:]
    /// Bots that left the dock for the backup (no service).
    public var retiredBots: Set<UUID> = []
    /// A chat merged into another, to the chat it lives on in.
    public var chats: [UUID: UUID] = [:]

    public init(bots: [UUID: UUID] = [:], retiredBots: Set<UUID> = [], chats: [UUID: UUID] = [:]) {
        self.bots = bots; self.retiredBots = retiredBots; self.chats = chats
    }
    public var isEmpty: Bool { bots.isEmpty && retiredBots.isEmpty && chats.isEmpty }

    // Written with string keys, sorted, so the same aliases are always the same bytes (sync compares them by hash).
    private enum CodingKeys: String, CodingKey { case bots, retiredBots, chats }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func map(_ key: CodingKeys) -> [UUID: UUID] {
            let raw = (try? c.decodeIfPresent([String: String].self, forKey: key)) ?? nil
            return Dictionary(uniqueKeysWithValues: (raw ?? [:]).compactMap { pair in
                UUID(uuidString: pair.key).flatMap { old in UUID(uuidString: pair.value).map { (old, $0) } }
            })
        }
        bots = map(.bots)
        chats = map(.chats)
        retiredBots = Set(((try? c.decodeIfPresent([String].self, forKey: .retiredBots)) ?? nil)?.compactMap(UUID.init(uuidString:)) ?? [])
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Dictionary(uniqueKeysWithValues: bots.map { ($0.key.uuidString, $0.value.uuidString) }), forKey: .bots)
        try c.encode(retiredBots.map(\.uuidString).sorted(), forKey: .retiredBots)
        try c.encode(Dictionary(uniqueKeysWithValues: chats.map { ($0.key.uuidString, $0.value.uuidString) }), forKey: .chats)
    }
    public mutating func add(_ other: LineupAliases) {
        bots.merge(other.bots) { _, new in new }
        retiredBots.formUnion(other.retiredBots)
        chats.merge(other.chats) { _, new in new }
    }
    /// Each retired bot's fate, as `LineupMigration.rewrite` takes it.
    public var fates: [UUID: LineupMigration.Fate] {
        var fates: [UUID: LineupMigration.Fate] = [:]
        for (old, new) in bots { if let service = ServiceID(botID: new) { fates[old] = .folded(service) } }
        for id in retiredBots { fates[id] = .archived }
        return fates
    }
    /// Whether this ID is a bot the migration retired (folded or archived).
    public func retires(bot id: UUID) -> Bool { bots[id] != nil || retiredBots.contains(id) }
    /// The chat a chat ID lives on as now (itself unless it was merged).
    public func chat(_ id: UUID) -> UUID {
        var current = id, steps = 0
        while let next = chats[current], next != current, steps < 16 { current = next; steps += 1 }
        return current
    }
    /// A chat as it is after the migration: retired bots' messages and tags moved, and its ID the surviving chat's.
    public func rewrite(_ thread: ChatThread) -> ChatThread {
        var copy = isEmpty ? thread : LineupMigration.rewrite(thread, fates: fates)
        copy.id = chat(thread.id)
        return copy
    }
}

public enum LineupMigration {
    /// What became of one custom bot.
    public enum Fate: Hashable, Sendable {
        case folded(ServiceID)
        case archived
    }

    /// A chat after the migration: a folded bot's messages and tags are its service bot's, a departed bot's messages
    /// stay as lines from Tsukumo with its name in front, and the chat's bots follow.
    public static func rewrite(_ thread: ChatThread, fates: [UUID: Fate], names: [UUID: String] = [:]) -> ChatThread {
        func mapped(_ id: UUID) -> UUID? {
            switch fates[id] {
            case .folded(let service)?: service.botID
            case .archived?: nil
            case nil: id
            }
        }
        var thread = thread
        var botIDs: [UUID] = []
        for id in thread.botIDs { if let next = mapped(id), !botIDs.contains(next) { botIDs.append(next) } }
        thread.botIDs = botIDs
        thread.lastSpokenTo = thread.lastSpokenTo.flatMap(mapped)
        thread.messages = thread.messages.map { message in
            var message = message
            var tags: [UUID] = []
            for id in message.tags { if let next = mapped(id), !tags.contains(next) { tags.append(next) } }
            message.tags = tags
            message.parts = message.parts.map { part in
                guard case .gateQuestion(var card) = part, let asker = card.askedBy else { return part }
                card.askedBy = mapped(asker)
                return .gateQuestion(card)
            }
            if case .bot(let id) = message.author, let fate = fates[id] {
                switch fate {
                case .folded(let service): message.author = .bot(service.botID)
                case .archived:
                    message.author = .system
                    let name = names[id] ?? "A bot"
                    if let first = message.parts.firstIndex(where: { if case .text = $0 { true } else { false } }),
                       case .text(let text) = message.parts[first], !text.hasPrefix(name + ": ") {
                        message.parts[first] = .text(name + ": " + text)
                    }
                }
            }
            return message
        }
        return thread
    }
}

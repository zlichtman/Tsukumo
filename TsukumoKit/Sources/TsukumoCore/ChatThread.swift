import Foundation

/// A conversation between the owner and some bots. (Named `ChatThread`, not `Thread`, so it never
/// shadows Foundation's `Thread` in an app that imports both.)
public struct ChatThread: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    /// The bots in it, in the order the thread shows them.
    public var botIDs: [UUID]
    public var messages: [Message]
    /// The bot the owner last talked to alone: an untagged message goes there when System One
    /// abstains.
    public var lastSpokenTo: UUID?
    /// How private the whole chat is. Personal by default; Device only keeps it off iCloud and every
    /// other device ("Keep on this iPhone").
    public var privacy: PrivacyLevel

    public init(id: UUID = UUID(), title: String = "", botIDs: [UUID], messages: [Message] = [], lastSpokenTo: UUID? = nil,
                privacy: PrivacyLevel = .personal) {
        self.id = id; self.title = title; self.botIDs = botIDs; self.messages = messages; self.lastSpokenTo = lastSpokenTo
        self.privacy = privacy
    }

    /// The thread's bots out of `all`, in thread order (bots that no longer exist are skipped).
    public func bots(from all: [BotSpec]) -> [BotSpec] { botIDs.compactMap { id in all.first { $0.id == id } } }

    /// How an owner's message would be routed in this thread: to the bots it tags, or untagged with
    /// the fallback (the bot last spoken to, else the thread's first bot).
    public func routing(text: String, chips: Set<UUID> = [], bots all: [BotSpec]) -> Routing.Decision {
        Routing.decide(text: text, chips: chips, lastSpokenTo: lastSpokenTo, bots: bots(from: all))
    }

    /// Adds the owner's message, sent to `recipients` (the tags, or whoever routing chose). Returns
    /// it, or nil when there's nothing to send or nobody in the thread to send it to. Talking to
    /// exactly one bot makes it the bot last spoken to.
    @discardableResult
    public mutating func send(_ text: String, to recipients: [UUID], date: Date = Date()) -> Message? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var targets: [UUID] = []
        for id in botIDs where recipients.contains(id) && !targets.contains(id) { targets.append(id) }
        guard !body.isEmpty, body.count <= Message.maxText, !targets.isEmpty else { return nil }
        let message = Message.owner(body, tags: targets, date: date)
        messages.append(message)
        if targets.count == 1 { lastSpokenTo = targets[0] }
        return message
    }

    /// Adds a bot's (or KemoSabe's, or Tsukumo's) message.
    public mutating func append(_ message: Message) { messages.append(message) }

    /// The turns an owner's message starts: one per bot it went to, in thread order, each once.
    public func turns(for message: Message) -> [UUID] {
        guard message.author == .owner else { return [] }
        return botIDs.filter { message.tags.contains($0) }
    }

    private enum CodingKeys: String, CodingKey { case id, title, botIDs, messages, lastSpokenTo, privacy }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        botIDs = try c.decodeIfPresent([UUID].self, forKey: .botIDs) ?? []
        messages = try c.decodeIfPresent([Message].self, forKey: .messages) ?? []
        lastSpokenTo = try c.decodeIfPresent(UUID.self, forKey: .lastSpokenTo)
        privacy = (try? c.decodeIfPresent(PrivacyLevel.self, forKey: .privacy)).flatMap { $0 } ?? .personal
    }
}

/// Tag to send: who an owner's message goes to. The chips the owner tapped and anyone named with
/// "@" are tagged; with neither, the message is untagged and System One's `route` decides, falling
/// back to the bot last spoken to (ported from the dock's `DockRouting`).
public enum Routing {
    public enum Decision: Hashable, Sendable {
        /// The owner named these bots, in thread order, each once.
        case tagged([UUID])
        /// Nobody named. `fallback` is who gets it if System One abstains.
        case untagged(fallback: UUID?)

        /// The bots it goes to without asking System One.
        public var recipients: [UUID] {
            switch self {
            case .tagged(let ids): ids
            case .untagged(let fallback): fallback.map { [$0] } ?? []
            }
        }
    }

    /// Bots named with "@Name", in `bots` order. Case doesn't matter; a name with spaces may be
    /// written without them, or by its first word when no other bot's name starts with that word;
    /// KemoSabe also answers to "@kemosabe" whatever it's called. "@Pip," counts; "@Pipe" doesn't.
    /// Without the "@", a name counts when the message starts with it ("Leafy, can you…") or right after
    /// ask, tell, or hey ("ask Muse about…"), the way people address someone (the owner, October 8, 2026).
    public static func mentions(in text: String, bots: [BotSpec]) -> [UUID] {
        let lowered = text.lowercased()
        func firstWord(_ name: String) -> String { name.split(separator: " ").first.map(String.init) ?? name }
        var found: [UUID] = []
        for bot in bots {
            let name = bot.name.lowercased().trimmingCharacters(in: .whitespaces)
            let first = firstWord(name)
            var forms = [name, name.replacingOccurrences(of: " ", with: "")]
            if bots.filter({ firstWord($0.name.lowercased().trimmingCharacters(in: .whitespaces)) == first }).count == 1 { forms.append(first) }
            if bot.isKemoSabe { forms.append("kemosabe") }
            if forms.contains(where: { mentioned($0, in: lowered) || addressed($0, in: lowered) }) { found.append(bot.id) }
        }
        return found
    }

    /// The tagged bots (chips and mentions), in `bots` order, each once.
    public static func tagged(text: String, chips: Set<UUID>, bots: [BotSpec]) -> [UUID] {
        let named = chips.union(mentions(in: text, bots: bots))
        return bots.map(\.id).filter { named.contains($0) }
    }

    public static func decide(text: String, chips: Set<UUID>, lastSpokenTo: UUID?, bots: [BotSpec]) -> Decision {
        let tagged = tagged(text: text, chips: chips, bots: bots)
        if !tagged.isEmpty { return .tagged(tagged) }
        if let lastSpokenTo, bots.contains(where: { $0.id == lastSpokenTo }) { return .untagged(fallback: lastSpokenTo) }
        return .untagged(fallback: bots.first?.id)
    }

    /// Who the message goes to with no System One: the tagged bots, else the fallback.
    public static func recipients(text: String, chips: Set<UUID>, lastSpokenTo: UUID?, bots: [BotSpec]) -> [UUID] {
        decide(text: text, chips: chips, lastSpokenTo: lastSpokenTo, bots: bots).recipients
    }

    /// The name, without "@", opening the message or right after a word that addresses someone.
    private static func addressed(_ name: String, in text: String) -> Bool {
        guard name.count >= 3 else { return false }
        let words = text.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "’") }).map(String.init)
        let parts = name.split(separator: " ").map(String.init)
        guard !parts.isEmpty, words.count >= parts.count else { return false }
        func at(_ index: Int) -> Bool { index + parts.count <= words.count && Array(words[index..<index + parts.count]) == parts }
        if at(0) { return true }
        for (index, word) in words.enumerated().dropLast() where ["ask", "tell", "hey", "hi"].contains(word) && at(index + 1) { return true }
        return false
    }

    private static func mentioned(_ name: String, in text: String) -> Bool {
        guard !name.isEmpty else { return false }
        var search = text.startIndex
        while let range = text.range(of: "@" + name, range: search..<text.endIndex) {
            if range.upperBound == text.endIndex || !(text[range.upperBound].isLetter || text[range.upperBound].isNumber) { return true }
            search = range.upperBound
        }
        return false
    }
}

import Foundation
import Observation

// Personal sources (design/CONTEXT-HARNESS.md#personal-sources): what KemoSabe may read to answer
// "when is Sarah free", "what did Sarah say about Friday", or "find a spot near me". Each one is off
// until the owner turns it on in Connections, and needs Apple's permission too; a source that's off
// contributes nothing. Every item carries a `PrivacyLevel`, so `ContextPolicy` decides what may
// leave: Messages are Sensitive (or Device only, the owner's choice) and Location is Sensitive, so an
// agent gets one only when the owner shares it on the card. Reminders and Contacts are Personal
// connection reads, like Calendar.

// MARK: The owner's switches

/// This device's switches for Messages and Location. Kept in this device's settings, never in the
/// synced account: Messages on a Mac and messages shared on an iPhone stay where they are.
@MainActor @Observable final class PersonalSourceSettings {
    static let shared = PersonalSourceSettings()
    /// The levels the owner can choose for Messages.
    static let messageLevels: [PrivacyLevel] = [.sensitive, .deviceOnly]
    @ObservationIgnored private let defaults: UserDefaults
    /// iPhone: accept messages from the Shortcuts automation and answer from them. Mac: read Messages.
    var messages: Bool { didSet { defaults.set(messages, forKey: Keys.messages) } }
    /// Sensitive (Apple's models; an agent only when the owner shares one excerpt) or Device only.
    var messagesLevel: PrivacyLevel { didSet { defaults.set(messagesLevel.rawValue, forKey: Keys.messagesLevel) } }
    /// Answer "near me" from this device's approximate location.
    var location: Bool { didSet { defaults.set(location, forKey: Keys.location) } }

    private enum Keys {
        static let messages = "kemo.sources.messages", messagesLevel = "kemo.sources.messages.level", location = "kemo.sources.location"
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        messages = defaults.bool(forKey: Keys.messages)
        let stored = defaults.string(forKey: Keys.messagesLevel).flatMap(PrivacyLevel.init(rawValue:))
        messagesLevel = stored.map { Self.messageLevels.contains($0) ? $0 : .deviceOnly } ?? .sensitive
        location = defaults.bool(forKey: Keys.location)
    }
}

// MARK: Sources for one question

/// A source that searches for one question rather than listing everything it holds.
@MainActor protocol PersonalQuestionSource {
    /// What might answer `question`, or nothing when the owner hasn't turned it on.
    func sources(for question: String, now: Date) async -> [AgentQuestionSource]
}

extension ContextItem {
    /// One excerpt from Messages, at the level the owner chose for Messages.
    static func textMessage(_ id: String, level: PrivacyLevel) -> Self { .init(.init(.textMessage, id), level: level) }
    /// This device's approximate location: Sensitive, so an agent gets it only when the owner shares it.
    static let location = Self(.init(.location, "approximate"), level: .sensitive)
}

// MARK: Messages: what a question asks for

/// What a question asks of Messages: who (names the owner knows), which words, and when.
struct MessagesQuery: Equatable, Sendable {
    var names: [String]
    var words: Set<String>
    var since: Date
    var until: Date
    /// How far back a question without a time looks.
    static let defaultDays = 90

    /// Names are People or Contacts names the question mentions, and capitalized words that aren't
    /// question words, days, or months. Words are what's left of the question's terms.
    static func parse(_ question: String, knownNames: [String] = [], now: Date, calendar: Calendar = .current) -> Self {
        let lower = question.lowercased()
        var names: [String] = []
        for name in knownNames where !name.isEmpty {
            let first = name.split(separator: " ").first.map(String.init) ?? name
            for candidate in [name, first] where wordRange(candidate.lowercased(), in: lower) {
                if !names.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) { names.append(candidate) }
                break
            }
        }
        for name in capitalizedNames(in: question) where !names.contains(where: { $0.lowercased().split(separator: " ").contains(Substring(name.lowercased())) }) {
            names.append(name)
        }
        names = Array(names.prefix(3))
        let nameTerms = Set(names.flatMap { $0.lowercased().split(separator: " ").map(String.init) })
        let words = AgentQuestionTerms.terms(question).subtracting(nameTerms).subtracting(timeWords)
        let today = calendar.startOfDay(for: now)
        func daysAgo(_ days: Int) -> Date { calendar.date(byAdding: .day, value: -days, to: today) ?? today }
        var since = daysAgo(defaultDays), until = now
        if wordRange("today", in: lower) || wordRange("tonight", in: lower) { since = today }
        else if wordRange("yesterday", in: lower) { since = daysAgo(1); until = today }
        else if lower.contains("last week") { since = daysAgo(14) }
        else if wordRange("week", in: lower) || lower.contains("lately") || lower.contains("recently") { since = daysAgo(7) }
        else if wordRange("month", in: lower) { since = daysAgo(31) }
        return .init(names: names, words: words, since: since, until: until)
    }
    static let timeWords: Set<String> = ["today", "tonight", "yesterday", "week", "last", "month", "lately", "recently", "recent", "message", "text", "texted", "messages"]
    private static let notNames: Set<String> = ["i", "what", "when", "where", "who", "why", "how", "is", "are", "did", "does", "do", "can", "could", "would",
        "should", "will", "find", "tell", "give", "show", "the", "a", "an", "my", "me", "and", "or", "kemosabe", "messages", "message",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "today", "tonight", "tomorrow", "yesterday",
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
    static func capitalizedNames(in text: String) -> [String] {
        text.split { !$0.isLetter && $0 != "'" && $0 != "’" }.map { word -> String in
            var word = String(word)
            for suffix in ["'s", "’s"] where word.hasSuffix(suffix) { word = String(word.dropLast(2)) }
            return word
        }.filter { word in
            guard let first = word.first, first.isUppercase, word.count > 1 else { return false }
            return !notNames.contains(word.lowercased())
        }
    }
    static func wordRange(_ word: String, in text: String) -> Bool {
        guard !word.isEmpty else { return false }
        var searchStart = text.startIndex
        while let range = text.range(of: word, range: searchStart..<text.endIndex) {
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            if !(before?.isLetter ?? false), !(after?.isLetter ?? false) { return true }
            searchStart = range.upperBound
        }
        return false
    }
}

/// The desk's words for ranking, available off the main actor.
enum AgentQuestionTerms {
    static let stopWords: Set<String> = ["the", "and", "you", "your", "for", "that", "this", "what", "with", "are", "was", "were", "from", "have",
        "has", "did", "does", "she", "her", "him", "his", "they", "them", "their", "say", "said", "tell", "told", "when", "where", "which",
        "who", "how", "about", "any", "can", "could", "would", "should", "will", "just", "our", "out", "there", "then", "than", "into"]
    static func terms(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map { word -> String in
            let word = String(word)
            return word.count > 4 && word.hasSuffix("s") ? String(word.dropLast()) : word
        }.filter { $0.count > 2 && !stopWords.contains($0) })
    }
}

// MARK: Messages: excerpts

/// One message, from the Mac's Messages or shared from an iPhone automation.
struct TextMessage: Equatable, Sendable {
    /// Stable within its source: the Mac's message row, or the shared message's ID.
    let id: String
    /// The conversation it belongs to, so an excerpt never mixes two.
    let chat: String
    /// A group chat's name, when it has one.
    var chatName: String? = nil
    /// "Sarah", or the handle when the person isn't in People or Contacts. "You" when from the owner.
    let sender: String
    let fromMe: Bool
    let date: Date
    let text: String
}

/// A few messages around one that matched. Never a whole thread.
struct MessageExcerpt: Equatable, Sendable {
    let id: String
    /// "your messages with Sarah"
    let title: String
    let messages: [TextMessage]
    var date: Date { messages.last?.date ?? .distantPast }
    /// What Apple's on-device model reads, and what the card shows.
    var text: String {
        messages.map { "\($0.fromMe ? "You" : $0.sender) (\(MessageExcerpts.stamp($0.date))): \($0.text)" }.joined(separator: "\n")
    }
}

enum MessageExcerpts {
    /// One message is cut to this many characters.
    static let maxMessageCharacters = 280
    /// One excerpt is at most this long, and this many messages: the match and one on each side.
    static let maxExcerptCharacters = 900
    static let maxExcerptMessages = 3
    /// At most this many excerpts answer one question.
    static let maxExcerpts = 6
    /// A neighbor this far from the match isn't part of the same moment.
    static let neighborWindow: TimeInterval = 6 * 3600

    /// Excerpts around the messages that match `query`, best match first. `messages` may hold several
    /// chats; `named` says they're already the chats of someone the question named. With a name and no
    /// word that matches, that person's latest few messages stand in.
    static func build(_ messages: [TextMessage], query: MessagesQuery, named: Bool) -> [MessageExcerpt] {
        let inWindow = messages.filter { $0.date >= query.since && $0.date <= query.until && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let byChat = Dictionary(grouping: inWindow, by: \.chat).mapValues { $0.sorted { $0.date < $1.date } }
        var hits: [(chat: String, index: Int, score: Int, date: Date)] = []
        for (chat, list) in byChat {
            for (index, message) in list.enumerated() {
                let score = query.words.isEmpty ? 0 : AgentQuestionTerms.terms(message.text).intersection(query.words).count
                if score > 0 { hits.append((chat, index, score, message.date)) }
            }
        }
        if hits.isEmpty, named {
            // "What did Sarah say?": her latest messages, one excerpt each.
            for (chat, list) in byChat {
                for (index, message) in list.enumerated() where !message.fromMe && sender(message.sender, matches: query.names) {
                    hits.append((chat, index, 0, message.date))
                }
            }
            hits.sort { $0.date > $1.date }
            hits = Array(hits.prefix(3))
        }
        hits.sort { $0.score != $1.score ? $0.score > $1.score : $0.date > $1.date }
        var excerpts: [MessageExcerpt] = [], used = Set<String>()
        for hit in hits {
            guard excerpts.count < maxExcerpts, let list = byChat[hit.chat] else { break }
            let match = list[hit.index]
            guard !used.contains(match.id) else { continue }
            var picked = [match]
            if hit.index > 0, match.date.timeIntervalSince(list[hit.index - 1].date) <= neighborWindow { picked.insert(list[hit.index - 1], at: 0) }
            if hit.index + 1 < list.count, list[hit.index + 1].date.timeIntervalSince(match.date) <= neighborWindow { picked.append(list[hit.index + 1]) }
            picked = Array(picked.prefix(maxExcerptMessages)).map(trimmed)
            while picked.count > 1, picked.map(\.text.count).reduce(0, +) > maxExcerptCharacters - 60 * picked.count {
                // Keep the match; drop the neighbor farther from it.
                if picked.first?.id != match.id { picked.removeFirst() } else { picked.removeLast() }
            }
            used.formUnion(picked.map(\.id))
            excerpts.append(.init(id: match.id, title: title(for: match, in: list), messages: picked))
        }
        return excerpts
    }
    static func trimmed(_ message: TextMessage) -> TextMessage {
        let text = message.text.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > maxMessageCharacters else { return .init(id: message.id, chat: message.chat, chatName: message.chatName, sender: message.sender, fromMe: message.fromMe, date: message.date, text: text) }
        return .init(id: message.id, chat: message.chat, chatName: message.chatName, sender: message.sender, fromMe: message.fromMe, date: message.date,
                     text: String(text.prefix(maxMessageCharacters - 1)) + "…")
    }
    static func title(for match: TextMessage, in list: [TextMessage]) -> String {
        if let name = match.chatName, !name.isEmpty { return "your group chat “\(name)”" }
        let other = match.fromMe ? list.first(where: { !$0.fromMe })?.sender : match.sender
        return other.map { "your messages with \($0)" } ?? "your messages"
    }
    static func stamp(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }
    /// The excerpts as question sources, at `level`. Each can go to the card on its own.
    static func sources(_ excerpts: [MessageExcerpt], origin: String, level: PrivacyLevel) -> [AgentQuestionSource] {
        excerpts.map { excerpt in
            let item = ContextItem.textMessage(origin + ":" + excerpt.id, level: level)
            return AgentQuestionSource(item: item, title: excerpt.title, text: excerpt.text,
                                       target: .excerpt(.init(item: item, title: excerpt.title, text: excerpt.text)),
                                       date: excerpt.date, messages: excerpt.messages.count, matched: true)
        }
    }
    /// Whether `sender` (as the automation or Messages gave it) is one of `names`.
    static func sender(_ sender: String, matches names: [String]) -> Bool {
        let lower = sender.lowercased()
        return names.contains { name in
            let wanted = name.lowercased()
            return lower == wanted || MessagesQuery.wordRange(wanted, in: lower)
        }
    }
}

// MARK: Messages you shared (iPhone)

/// Messages the owner's Shortcuts automation gave KemoSabe ("Give message to KemoSabe"). Only what
/// the automation passes; no history. Each message is its own small file in this account's folder,
/// written so it can be saved while the iPhone is locked (Class B) and read once it's unlocked. Never
/// synced; deleted one by one in Connections → Messages, or all at once.
struct SharedMessagesStore: Sendable {
    struct Message: Codable, Equatable, Identifiable, Sendable {
        var id = UUID()
        let sender: String
        let text: String
        let date: Date
        var receivedAt = Date()
    }
    enum Failure: Error, Equatable { case empty, tooLong, full }
    static let maxSender = 120, maxText = 2000
    /// Kept: the newest this many. An older one is removed when a new one arrives.
    static let maxMessages = 500
    let folder: URL
    init(folder: URL) { self.folder = folder }
    /// This account's store.
    static var current: Self { .init(folder: AccountDirectory.currentFolder.appendingPathComponent("shared-messages", isDirectory: true)) }

    @discardableResult func add(sender: String, text: String, date: Date?, now: Date = Date()) throws -> Message {
        let sender = sender.trimmingCharacters(in: .whitespacesAndNewlines), text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sender.isEmpty, !text.isEmpty else { throw Failure.empty }
        guard sender.count <= Self.maxSender else { throw Failure.tooLong }
        let message = Message(sender: sender, text: String(text.prefix(Self.maxText)), date: min(date ?? now, now), receivedAt: now)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(message)
        #if os(iOS)
        try data.write(to: file(message), options: [.atomic, .completeFileProtectionUnlessOpen])
        #else
        try data.write(to: file(message), options: [.atomic])
        #endif
        prune()
        return message
    }
    /// Newest first. Unreadable files (the iPhone is locked) are skipped, not deleted.
    func list() -> [Message] {
        files().compactMap { try? JSONDecoder().decode(Message.self, from: Data(contentsOf: $0)) }.sorted { $0.date > $1.date }
    }
    func delete(_ id: UUID) {
        for url in files() where url.lastPathComponent.hasSuffix(id.uuidString + ".json") { try? FileManager.default.removeItem(at: url) }
    }
    func deleteAll() { try? FileManager.default.removeItem(at: folder) }
    var count: Int { files().count }

    private func file(_ message: Message) -> URL {
        folder.appendingPathComponent(String(format: "%013.0f", message.receivedAt.timeIntervalSince1970 * 1000) + "-" + message.id.uuidString + ".json")
    }
    private func files() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    /// File names start with when they arrived, so the oldest go first.
    private func prune() {
        let all = files()
        guard all.count > Self.maxMessages else { return }
        for url in all.prefix(all.count - Self.maxMessages) { try? FileManager.default.removeItem(at: url) }
    }
}

/// Messages the owner shared, for one question: only while Messages is on here.
@MainActor struct SharedMessagesQuestionSource: PersonalQuestionSource {
    let store: SharedMessagesStore
    let settings: PersonalSourceSettings
    var knownNames: () -> [String] = { [] }
    func sources(for question: String, now: Date) async -> [AgentQuestionSource] {
        guard settings.messages else { return [] }
        let query = MessagesQuery.parse(question, knownNames: knownNames(), now: now)
        let named = !query.names.isEmpty
        let messages = store.list().filter { !named || MessageExcerpts.sender($0.sender, matches: query.names) }.map {
            // Each sender's messages are one conversation.
            TextMessage(id: $0.id.uuidString, chat: $0.sender.lowercased(), sender: $0.sender, fromMe: false, date: $0.date, text: $0.text)
        }
        return MessageExcerpts.sources(MessageExcerpts.build(messages, query: query, named: named), origin: "shared", level: settings.messagesLevel)
    }
}

// MARK: Location

/// This device's approximate location, read once when a question needs it.
struct CoarsePlace: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    /// "Mission District, San Francisco", when Apple's maps could name it.
    var area: String?
    /// About a kilometer: two decimal places.
    var text: String {
        let coordinates = String(format: "%.2f, %.2f", latitude, longitude)
        return (area.map { "Near \($0) (about \(coordinates))" } ?? "About \(coordinates)") + ", accurate to roughly a kilometer."
    }
}

@MainActor protocol CoarseLocating: AnyObject {
    var permission: ConnectorPermission { get }
    /// Apple's When In Use prompt.
    func request() async -> ConnectorPermission
    func current() async throws -> CoarsePlace
}

/// "Near me": only with the owner's switch, Apple's When In Use permission, and a question about
/// where they are or what's close.
@MainActor struct LocationQuestionSource: PersonalQuestionSource {
    let settings: PersonalSourceSettings
    let locator: CoarseLocating
    static let cues = ["near me", "nearby", "near here", "around me", "around here", "close to me", "closest", "nearest", "where am i", "my location",
                       "where i am", "in my area", "local", "walking distance"]
    static func asksAboutPlace(_ question: String) -> Bool {
        let lower = question.lowercased()
        return cues.contains { MessagesQuery.wordRange($0, in: lower) }
    }
    func sources(for question: String, now: Date) async -> [AgentQuestionSource] {
        guard settings.location, locator.permission == .allowed, Self.asksAboutPlace(question),
              let place = try? await locator.current() else { return [] }
        let title = "your approximate location"
        let text = "Where you are now: " + place.text
        return [.init(item: .location, title: title, text: text, target: .excerpt(.init(item: .location, title: title, text: text)),
                      date: now, matched: true)]
    }
}

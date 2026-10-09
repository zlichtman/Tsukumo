import Foundation
import SQLite3
import TsukumoCore
import TsukumoPolicy

// Messages, ported from the old apps (legacy/ios/KemoSabe/PersonalSources.swift and
// legacy/macos/KemoSabeMac/MacMessagesSource.swift):
//
// - On a Mac, with Messages in iCloud, ~/Library/Messages/chat.db holds the owner's history. macOS guards
//   that folder: reading it needs Full Disk Access, which only the owner grants in System Settings. KemoSabe
//   opens it read-only, for one question at a time, and hands Apple's on-device model a few small excerpts,
//   never a whole thread. Nothing from it is saved, synced, or indexed.
// - On iPhone, apps can't read Messages. A Shortcuts automation can give KemoSabe each new message from the
//   people the owner picks ("Give Message to KemoSabe"); KemoSabe keeps them on the iPhone, never syncs
//   them, and reads only a few at a time.

// MARK: What a question asks for

/// What a question asks of Messages: who (names the owner knows), which words, and when.
public struct MessagesQuery: Equatable, Sendable {
    public var names: [String]
    public var words: Set<String>
    public var since: Date
    public var until: Date
    /// How far back a question without a time looks.
    public static let defaultDays = 90

    /// Names are known names the question mentions, and capitalized words that aren't question words,
    /// days, or months. Words are what's left of the question's terms.
    public static func parse(_ question: String, knownNames: [String] = [], now: Date, defaultDays: Int = defaultDays,
                             calendar: Calendar = .current) -> Self {
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
        let words = MessagesTerms.terms(question).subtracting(nameTerms).subtracting(timeWords)
        let today = calendar.startOfDay(for: now)
        func daysAgo(_ days: Int) -> Date { calendar.date(byAdding: .day, value: -days, to: today) ?? today }
        var since = daysAgo(defaultDays), until = now
        if wordRange("today", in: lower) || wordRange("tonight", in: lower) { since = today }
        else if wordRange("yesterday", in: lower) { since = daysAgo(1); until = today }
        else if lower.contains("last week") { since = daysAgo(14) }
        else if wordRange("week", in: lower) || lower.contains("lately") || lower.contains("recently") { since = daysAgo(7) }
        else if wordRange("month", in: lower) { since = daysAgo(31) }
        else if wordRange("year", in: lower) { since = daysAgo(366) }
        return .init(names: names, words: words, since: since, until: until)
    }
    static let timeWords: Set<String> = ["today", "tonight", "yesterday", "week", "last", "month", "year", "lately", "recently", "recent",
                                         "message", "text", "texted", "messages"]
    private static let notNames: Set<String> = ["i", "what", "when", "where", "who", "why", "how", "is", "are", "did", "does", "do", "can", "could",
        "would", "should", "will", "find", "tell", "give", "show", "the", "a", "an", "my", "me", "and", "or", "kemosabe", "messages", "message",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "today", "tonight", "tomorrow", "yesterday",
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december",
        "which", "whose", "has", "have", "any", "please", "look", "check", "photos", "music", "calendar", "reminders", "contacts"]
    public static func capitalizedNames(in text: String) -> [String] {
        text.split { !$0.isLetter && $0 != "'" && $0 != "’" }.map { word -> String in
            var word = String(word)
            for suffix in ["'s", "’s"] where word.hasSuffix(suffix) { word = String(word.dropLast(2)) }
            return word
        }.filter { word in
            guard let first = word.first, first.isUppercase, word.count > 1 else { return false }
            return !notNames.contains(word.lowercased())
        }
    }
    public static func wordRange(_ word: String, in text: String) -> Bool {
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
    /// Whether the question mentions any of these phrases as words.
    public static func mentions(_ question: String, any phrases: [String]) -> Bool {
        let lower = question.lowercased()
        return phrases.contains { wordRange($0, in: lower) }
    }
}

/// Words for matching messages, plurals folded.
public enum MessagesTerms {
    static let stopWords: Set<String> = ["the", "and", "you", "your", "for", "that", "this", "what", "with", "are", "was", "were", "from", "have",
        "has", "did", "does", "she", "her", "him", "his", "they", "them", "their", "say", "said", "tell", "told", "when", "where", "which",
        "who", "how", "about", "any", "can", "could", "would", "should", "will", "just", "our", "out", "there", "then", "than", "into"]
    public static func terms(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map { word -> String in
            let word = String(word)
            return word.count > 4 && word.hasSuffix("s") ? String(word.dropLast()) : word
        }.filter { $0.count > 2 && !stopWords.contains($0) })
    }
}

// MARK: Excerpts

/// One message, from the Mac's Messages or shared from an iPhone automation.
public struct TextMessage: Equatable, Sendable {
    /// Stable within its source: the Mac's message row, or the shared message's ID.
    public let id: String
    /// The conversation it belongs to, so an excerpt never mixes two.
    public let chat: String
    /// A group chat's name, when it has one.
    public var chatName: String?
    /// "Sarah", or the handle when the person isn't in Contacts. "You" when from the owner.
    public let sender: String
    public let fromMe: Bool
    public let date: Date
    public let text: String
    public init(id: String, chat: String, chatName: String? = nil, sender: String, fromMe: Bool, date: Date, text: String) {
        self.id = id; self.chat = chat; self.chatName = chatName; self.sender = sender; self.fromMe = fromMe; self.date = date; self.text = text
    }
}

/// A few messages around one that matched. Never a whole thread.
public struct MessageExcerpt: Equatable, Sendable {
    public let id: String
    /// "your messages with Sarah"
    public let title: String
    public let messages: [TextMessage]
    public var date: Date { messages.last?.date ?? .distantPast }
    /// What Apple's on-device model reads, and what the card shows.
    public var text: String {
        messages.map { "\($0.fromMe ? "You" : $0.sender) (\(MessageExcerpts.stamp($0.date))): \($0.text)" }.joined(separator: "\n")
    }
}

public enum MessageExcerpts {
    /// One message is cut to this many characters.
    static let maxMessageCharacters = 280
    /// One excerpt is at most this long, and this many messages: the match and one on each side.
    static let maxExcerptCharacters = 900
    static let maxExcerptMessages = 3
    /// At most this many excerpts answer one question.
    public static let maxExcerpts = 6
    /// A neighbor this far from the match isn't part of the same moment.
    static let neighborWindow: TimeInterval = 6 * 3600

    /// Excerpts around the messages that match `query`, best match first. `named` says they're already the
    /// chats of someone the question named; with a name and no matching word, their latest messages stand in.
    public static func build(_ messages: [TextMessage], query: MessagesQuery, named: Bool) -> [MessageExcerpt] {
        let inWindow = messages.filter { $0.date >= query.since && $0.date <= query.until && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let byChat = Dictionary(grouping: inWindow, by: \.chat).mapValues { $0.sorted { $0.date < $1.date } }
        var hits: [(chat: String, index: Int, score: Int, date: Date)] = []
        for (chat, list) in byChat {
            for (index, message) in list.enumerated() {
                let score = query.words.isEmpty ? 0 : MessagesTerms.terms(message.text).intersection(query.words).count
                if score > 0 { hits.append((chat, index, score, message.date)) }
            }
        }
        if hits.isEmpty, named {
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
                if picked.first?.id != match.id { picked.removeFirst() } else { picked.removeLast() }
            }
            used.formUnion(picked.map(\.id))
            excerpts.append(.init(id: match.id, title: title(for: match, in: list), messages: picked))
        }
        return excerpts
    }
    static func trimmed(_ message: TextMessage) -> TextMessage {
        var text = message.text.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > maxMessageCharacters { text = String(text.prefix(maxMessageCharacters - 1)) + "…" }
        return TextMessage(id: message.id, chat: message.chat, chatName: message.chatName, sender: message.sender, fromMe: message.fromMe,
                           date: message.date, text: text)
    }
    static func title(for match: TextMessage, in list: [TextMessage]) -> String {
        if let name = match.chatName, !name.isEmpty { return "your group chat “\(name)”" }
        let other = match.fromMe ? list.first(where: { !$0.fromMe })?.sender : match.sender
        return other.map { "your messages with \($0)" } ?? "your messages"
    }
    static func stamp(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }
    /// The excerpts as the Gate's items, at `level`. Each can go to the card on its own.
    public static func items(_ excerpts: [MessageExcerpt], origin: String, level: PrivacyLevel) -> [PersonalItem] {
        excerpts.map { excerpt in
            PersonalItem(id: "message:" + origin + ":" + excerpt.id, kind: .textMessage, level: level, title: excerpt.title, text: excerpt.text,
                         date: excerpt.date, messages: excerpt.messages.count, matched: true)
        }
    }
    /// Whether `sender` (as the automation or Messages gave it) is one of `names`.
    public static func sender(_ sender: String, matches names: [String]) -> Bool {
        let lower = sender.lowercased()
        return names.contains { name in
            let wanted = name.lowercased()
            return lower == wanted || MessagesQuery.wordRange(wanted, in: lower)
        }
    }
}

// MARK: Messages on a Mac

/// Whether this Mac's Messages history can be read.
public enum MacMessagesAccess: Equatable, Sendable {
    case granted
    /// macOS refused to open it: Tsukumo needs Full Disk Access.
    case needsFullDiskAccess
    /// There's no Messages history on this Mac (Messages isn't set up, or Messages in iCloud is off).
    case noHistory

    /// Privacy & Security, Full Disk Access, in System Settings.
    public static let fullDiskAccessSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}

/// A Messages database (`chat.db`), opened read-only for each read and closed after it.
public struct MessagesDatabase: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    /// This Mac's Messages history (the app passes nil under `--ui-testing`, so tests never touch it).
    #if os(macOS)
    public static var system: MessagesDatabase {
        MessagesDatabase(url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db"))
    }
    #endif

    public struct Failure: Error, Equatable { public let code: Int32; public let message: String }

    public func access() -> MacMessagesAccess {
        if (try? ReadOnlySQLite(url: url, probe: "SELECT 1 FROM message LIMIT 1")) != nil { return .granted }
        // Without Full Disk Access macOS hides the folder itself; with it, a missing file means no history.
        let folderReadable = (try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) != nil
        return folderReadable && !FileManager.default.fileExists(atPath: url.path) ? .noHistory : .needsFullDiskAccess
    }

    /// Every handle (a phone number or email address) by its row.
    public func handles() throws -> [Int64: String] {
        let connection = try ReadOnlySQLite(url: url, probe: "SELECT 1 FROM message LIMIT 1")
        var result: [Int64: String] = [:]
        try connection.rows("SELECT ROWID, id FROM handle") { row in
            if let id = row.text(1) { result[row.int(0)] = id }
        }
        return result
    }

    /// Messages between `since` and `until`, newest first, at most `limit`: every message in the chats these
    /// handles take part in, or in every chat when `handles` is nil. Reactions and system rows are left out.
    public func messages(withHandles handles: Set<Int64>?, since: Date, until: Date, limit: Int, name: (String) -> String) throws -> [TextMessage] {
        if let handles, handles.isEmpty { return [] }
        let connection = try ReadOnlySQLite(url: url, probe: "SELECT 1 FROM message LIMIT 1")
        // Dates are seconds since 2001 in old rows and nanoseconds in newer ones.
        let seconds = "(CASE WHEN m.date > 100000000000 THEN m.date / 1000000000 ELSE m.date END)"
        var sql = """
            SELECT m.ROWID, m.text, m.attributedBody, m.is_from_me, m.date, h.id, c.ROWID, c.display_name
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat c ON c.ROWID = cmj.chat_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE \(seconds) >= ? AND \(seconds) <= ?
              AND COALESCE(m.associated_message_type, 0) = 0 AND COALESCE(m.item_type, 0) = 0
            """
        var bindings: [Int64] = [Int64(since.timeIntervalSinceReferenceDate.rounded(.down)), Int64(until.timeIntervalSinceReferenceDate.rounded(.up))]
        if let handles {
            let sorted = handles.sorted()
            sql += " AND cmj.chat_id IN (SELECT chat_id FROM chat_handle_join WHERE handle_id IN (\(sorted.map { _ in "?" }.joined(separator: ","))))"
            bindings += sorted
        }
        sql += " ORDER BY m.date DESC LIMIT ?"
        bindings.append(Int64(max(1, limit)))
        var result: [TextMessage] = []
        try connection.rows(sql, bindings) { row in
            let text = row.text(1).flatMap { $0.isEmpty ? nil : $0 } ?? row.blob(2).flatMap(MessagesTypedStream.text)
            guard let text, !text.isEmpty else { return }
            let fromMe = row.int(3) != 0
            let raw = row.int(4)
            let date = Date(timeIntervalSinceReferenceDate: raw > 100_000_000_000 ? Double(raw) / 1_000_000_000 : Double(raw))
            let handle = row.text(5) ?? ""
            result.append(.init(id: String(row.int(0)), chat: String(row.int(6)), chatName: row.text(7).flatMap { $0.isEmpty ? nil : $0 },
                                sender: fromMe ? "You" : name(handle), fromMe: fromMe, date: date, text: text))
        }
        return result
    }
}

/// One read-only SQLite connection to someone else's database. `mode=ro` sees rows still in the write-ahead
/// log without writing anything; if the log can't be opened read-only, the file is read as it is
/// (`immutable=1`). `query_only` refuses any write either way.
final class ReadOnlySQLite {
    let db: OpaquePointer
    init(url: URL, probe: String) throws {
        let path = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path
        var lastError = MessagesDatabase.Failure(code: SQLITE_CANTOPEN, message: "unable to open")
        for options in ["mode=ro", "mode=ro&immutable=1"] {
            var handle: OpaquePointer?
            let code = sqlite3_open_v2("file:" + path + "?" + options, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil)
            guard code == SQLITE_OK, let handle else {
                lastError = .init(code: code, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open")
                sqlite3_close_v2(handle); continue
            }
            sqlite3_busy_timeout(handle, 500)
            // The first read is where macOS's refusal, or a log it can't open, shows up.
            let check = sqlite3_exec(handle, "PRAGMA query_only = 1; " + probe + ";", nil, nil, nil)
            guard check == SQLITE_OK else {
                lastError = .init(code: check, message: String(cString: sqlite3_errmsg(handle)))
                sqlite3_close_v2(handle); continue
            }
            db = handle
            return
        }
        throw lastError
    }
    deinit { sqlite3_close_v2(db) }

    struct Row {
        let statement: OpaquePointer
        func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func text(_ column: Int32) -> String? {
            guard sqlite3_column_type(statement, column) != SQLITE_NULL, let value = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: value)
        }
        func blob(_ column: Int32) -> Data? {
            guard sqlite3_column_type(statement, column) == SQLITE_BLOB, let bytes = sqlite3_column_blob(statement, column) else { return nil }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
        }
    }
    func rows(_ sql: String, _ bindings: [Int64] = [], _ each: (Row) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw MessagesDatabase.Failure(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() { sqlite3_bind_int64(statement, Int32(index + 1), value) }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW { each(Row(statement: statement)); continue }
            if step == SQLITE_DONE { return }
            throw MessagesDatabase.Failure(code: step, message: String(cString: sqlite3_errmsg(db)))
        }
    }
}

/// The text of a newer message's `attributedBody`: an NSAttributedString in Apple's old typedstream
/// archive format. Read by hand, never unarchived, so nothing in it can instantiate a class: after the
/// `NSString` class name comes `+`, the length (one byte, or 0x81 and two bytes, or 0x82 and four,
/// little-endian), and the UTF-8 text.
public enum MessagesTypedStream {
    public static func text(from data: Data) -> String? {
        let bytes = [UInt8](data), marker = Array("NSString".utf8)
        guard bytes.count > marker.count,
              let start = (0...(bytes.count - marker.count)).first(where: { Array(bytes[$0..<($0 + marker.count)]) == marker }) else { return nil }
        var index = start + marker.count
        guard let plus = bytes[index..<min(index + 12, bytes.count)].firstIndex(of: 0x2B) else { return nil }
        index = plus + 1
        guard index < bytes.count else { return nil }
        let length: Int
        switch bytes[index] {
        case 0x81:
            guard index + 2 < bytes.count else { return nil }
            length = Int(bytes[index + 1]) | Int(bytes[index + 2]) << 8; index += 3
        case 0x82:
            guard index + 4 < bytes.count else { return nil }
            length = (0..<4).reduce(0) { $0 | Int(bytes[index + 1 + $1]) << (8 * $1) }; index += 5
        case let byte where byte < 0x80:
            length = Int(byte); index += 1
        default: return nil
        }
        guard length > 0, index + length <= bytes.count else { return nil }
        return String(bytes: bytes[index..<(index + length)], encoding: .utf8)
    }
}

/// A person's handles as Messages stores them: an email address, or a phone number's last ten digits.
public enum MessagesHandle {
    public static func key(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.contains("@") { return value }
        let digits = value.filter(\.isNumber)
        return digits.count > 10 ? String(digits.suffix(10)) : digits
    }
}

/// Messages on this Mac, for one question.
public struct MacMessagesSource: PersonalSource {
    public let database: MessagesDatabase
    public let level: PrivacyLevel
    /// Names to handles (Contacts, when it's on and allowed), so "What did Sarah say?" finds her chats.
    public let contacts: (any ContactsReading)?
    /// How many of the newest messages in the window one question may scan.
    public static let scanLimit = 3000
    public init(database: MessagesDatabase, level: PrivacyLevel, contacts: (any ContactsReading)?) {
        self.database = database; self.level = level; self.contacts = contacts
    }

    public func excerpts(for question: String, now: Date = Date()) async -> [MessageExcerpt] {
        let query = MessagesQuery.parse(question, now: now)
        var named: [ContactCard] = []
        if let contacts { for name in query.names { named += await contacts.contacts(named: name) } }
        named = named.filter { !$0.phones.isEmpty || !$0.emails.isEmpty }
        guard !named.isEmpty || !query.words.isEmpty else { return [] }
        var names: [String: String] = [:]
        for person in named { for handle in person.phones + person.emails { names[MessagesHandle.key(handle)] = person.name } }
        let wanted = Set(named.flatMap { $0.phones + $0.emails }.map(MessagesHandle.key))
        do {
            var rows: Set<Int64>?
            if !wanted.isEmpty { rows = Set(try database.handles().filter { wanted.contains(MessagesHandle.key($0.value)) }.keys) }
            let messages = try database.messages(withHandles: rows, since: query.since, until: query.until, limit: Self.scanLimit) { handle in
                names[MessagesHandle.key(handle)] ?? (handle.isEmpty ? "Someone" : handle)
            }
            return MessageExcerpts.build(messages, query: query, named: !named.isEmpty)
        } catch { return [] }
    }

    public func items(matching question: GateQuestion) async -> [PersonalItem] {
        MessageExcerpts.items(await excerpts(for: question.question), origin: "mac", level: level)
    }
}

// MARK: Messages you shared (iPhone)

/// Messages the owner's Shortcuts automation gave KemoSabe ("Give Message to KemoSabe"). Only what the
/// automation passes; no history. Each message is its own small file in the app's folder, written so it can
/// be saved while the iPhone is locked and read once it's unlocked. Never synced.
public struct SharedMessagesStore: Sendable {
    public struct Message: Codable, Equatable, Identifiable, Sendable {
        public var id = UUID()
        public let sender: String
        public let text: String
        public let date: Date
        public var receivedAt = Date()
    }
    public enum Failure: Error, Equatable { case empty, tooLong }
    public static let maxSender = 120, maxText = 2000
    /// Kept: the newest this many. An older one is removed when a new one arrives.
    public static let maxMessages = 500
    public let folder: URL
    public init(folder: URL) { self.folder = folder }

    @discardableResult public func add(sender: String, text: String, date: Date?, now: Date = Date()) throws -> Message {
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
    public func list() -> [Message] {
        files().compactMap { try? JSONDecoder().decode(Message.self, from: Data(contentsOf: $0)) }.sorted { $0.date > $1.date }
    }
    public func delete(_ id: UUID) {
        for url in files() where url.lastPathComponent.hasSuffix(id.uuidString + ".json") { try? FileManager.default.removeItem(at: url) }
    }
    public func deleteAll() { try? FileManager.default.removeItem(at: folder) }
    public var count: Int { files().count }

    private func file(_ message: Message) -> URL {
        folder.appendingPathComponent(String(format: "%013.0f", message.receivedAt.timeIntervalSince1970 * 1000) + "-" + message.id.uuidString + ".json")
    }
    private func files() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    private func prune() {
        let all = files()
        guard all.count > Self.maxMessages else { return }
        for url in all.prefix(all.count - Self.maxMessages) { try? FileManager.default.removeItem(at: url) }
    }

    /// The steps for the automation, as Settings shows them.
    public static let steps = [
        "In Shortcuts, open Automation and tap + to make a new one. Choose Message.",
        "Choose Sender and pick the people KemoSabe may hear about. Choose Run Immediately.",
        "Add the action Give Message to KemoSabe. Set Sender to the Shortcut Input’s Sender and Message to its Content."
    ]
}

/// Messages the owner shared, for one question.
public struct SharedMessagesSource: PersonalSource {
    public let store: SharedMessagesStore
    public let level: PrivacyLevel
    public init(store: SharedMessagesStore, level: PrivacyLevel) { self.store = store; self.level = level }
    public func items(matching question: GateQuestion) async -> [PersonalItem] {
        let query = MessagesQuery.parse(question.question, now: question.receivedAt)
        let named = !query.names.isEmpty
        let messages = store.list().filter { !named || MessageExcerpts.sender($0.sender, matches: query.names) }.map {
            // Each sender's messages are one conversation.
            TextMessage(id: $0.id.uuidString, chat: $0.sender.lowercased(), sender: $0.sender, fromMe: false, date: $0.date, text: $0.text)
        }
        return MessageExcerpts.items(MessageExcerpts.build(messages, query: query, named: named), origin: "shared", level: level)
    }
}

import Foundation
import SQLite3

// Messages on the Mac (design/CONTEXT-HARNESS.md#personal-sources). With Messages in iCloud, this
// Mac's ~/Library/Messages/chat.db holds the owner's message history. Tsukumo isn't sandboxed, but
// macOS still guards that folder: reading it needs Full Disk Access, which only the owner can grant
// in System Settings. KemoSabe then reads it only while the owner has Messages on in Connections,
// read-only, for one question at a time, and hands Apple's on-device model a few small excerpts
// (`MessageExcerpts`), never a whole thread. Nothing from it is saved, synced, or indexed.

/// Whether this Mac's Messages history can be read.
enum MacMessagesAccess: Equatable, Sendable {
    case granted
    /// macOS refused to open it: Tsukumo needs Full Disk Access.
    case needsFullDiskAccess
    /// There's no Messages history on this Mac (Messages isn't set up, or Messages in iCloud is off).
    case noHistory

    /// Privacy & Security → Full Disk Access in System Settings.
    static let fullDiskAccessSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}

/// A Messages database (`chat.db`), opened read-only for each read and closed after it.
struct MessagesDatabase: Sendable {
    let url: URL
    /// This Mac's Messages history. Nil in a test host or an isolated fixture, so neither ever
    /// touches the owner's real messages.
    static var system: MessagesDatabase? {
        let arguments = ProcessInfo.processInfo.arguments
        guard !AccountDirectory.isTestHost, !arguments.contains("--isolated-fixture"), !arguments.contains("--ui-testing") else { return nil }
        return .init(url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db"))
    }

    struct Failure: Error, Equatable { let code: Int32; let message: String }

    func access() -> MacMessagesAccess {
        guard FileManager.default.fileExists(atPath: url.path) else { return .noHistory }
        do { _ = try Connection(url: url); return .granted } catch { return .needsFullDiskAccess }
    }

    /// Every handle (a phone number or email address) by its row.
    func handles() throws -> [Int64: String] {
        let connection = try Connection(url: url)
        var result: [Int64: String] = [:]
        try connection.rows("SELECT ROWID, id FROM handle") { row in
            if let id = row.text(1) { result[row.int(0)] = id }
        }
        return result
    }

    /// Messages between `since` and `until`, newest first, at most `limit`: every message in the chats
    /// these handles take part in, or in every chat when `handles` is nil. Reactions and system rows
    /// (a member joined, a name changed) are left out.
    func messages(withHandles handles: Set<Int64>?, since: Date, until: Date, limit: Int,
                  name: (String) -> String) throws -> [TextMessage] {
        if let handles, handles.isEmpty { return [] }
        let connection = try Connection(url: url)
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
                                sender: fromMe ? "You" : name(handle),
                                fromMe: fromMe, date: date, text: text))
        }
        return result
    }

    /// One read-only connection. `mode=ro` sees messages still in the write-ahead log (the newest
    /// ones) without writing anything; if the log can't be opened read-only, the database file is read
    /// as it is (`immutable=1`). `query_only` refuses any write either way.
    private final class Connection {
        let db: OpaquePointer
        init(url: URL) throws {
            let path = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path
            var lastError = Failure(code: SQLITE_CANTOPEN, message: "unable to open")
            for options in ["mode=ro", "mode=ro&immutable=1"] {
                var handle: OpaquePointer?
                let code = sqlite3_open_v2("file:" + path + "?" + options, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil)
                guard code == SQLITE_OK, let handle else {
                    lastError = Failure(code: code, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open")
                    sqlite3_close_v2(handle); continue
                }
                sqlite3_busy_timeout(handle, 500)
                // The first read is where macOS's refusal, or a log it can't open, shows up.
                let probe = sqlite3_exec(handle, "PRAGMA query_only = 1; SELECT 1 FROM message LIMIT 1;", nil, nil, nil)
                guard probe == SQLITE_OK else {
                    lastError = Failure(code: probe, message: String(cString: sqlite3_errmsg(handle)))
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
                throw Failure(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }
            for (index, value) in bindings.enumerated() { sqlite3_bind_int64(statement, Int32(index + 1), value) }
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_ROW { each(Row(statement: statement)); continue }
                if step == SQLITE_DONE { return }
                throw Failure(code: step, message: String(cString: sqlite3_errmsg(db)))
            }
        }
    }
}

/// The text of a newer message's `attributedBody`: an NSAttributedString in Apple's old typedstream
/// archive format. Read by hand, never unarchived, so nothing in it can instantiate a class: after
/// the `NSString` class name comes `+`, the length (one byte, or 0x81 and two bytes, or 0x82 and four,
/// little-endian), and the UTF-8 text.
enum MessagesTypedStream {
    static func text(from data: Data) -> String? {
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

// MARK: Who's who

/// A person's handles as Messages stores them: an email address, or a phone number's last ten digits.
enum MessagesHandle {
    static func key(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.contains("@") { return value }
        let digits = value.filter(\.isNumber)
        return digits.count > 10 ? String(digits.suffix(10)) : digits
    }
}

struct MessagesPerson: Equatable, Sendable {
    let name: String
    let handles: [String]
}

/// Names to handles: People, and the system address book when Contacts is connected here.
@MainActor protocol MessagesPeopleDirectory {
    /// People and contacts named like these names.
    func people(named names: [String]) async -> [MessagesPerson]
    /// Everyone in People, for naming the sender of a message that matched by its words.
    func everyone() -> [MessagesPerson]
}

@MainActor struct StoreMessagesPeople: MessagesPeopleDirectory {
    weak var store: AppStore?
    /// Look in Contacts too, when it's connected here. Off in tests.
    var includeContacts = true
    func people(named names: [String]) async -> [MessagesPerson] {
        guard let store else { return [] }
        var found = everyone().filter { MessageExcerpts.sender($0.name, matches: names) }
        if includeContacts, store.state.kemoAllows(.contacts), PeopleContactsReader.permitted {
            for name in names.prefix(3) {
                for source in (try? await PeopleContactsReader().fetch(query: name)) ?? [] {
                    let person = Self.person(source.fields)
                    if let person, !found.contains(person) { found.append(person) }
                }
            }
        }
        return found
    }
    func everyone() -> [MessagesPerson] {
        (store?.state.people?.profiles ?? []).compactMap { profile in
            Self.person([.init(kind: .name, value: profile.name)] + profile.sources.flatMap(\.fields))
        }
    }
    static func person(_ fields: [PeopleField]) -> MessagesPerson? {
        guard let name = fields.first(where: { $0.kind == .name })?.value else { return nil }
        let handles = fields.filter { $0.kind == .email || $0.kind == .phone }.map(\.value)
        return handles.isEmpty ? nil : .init(name: name, handles: handles)
    }
}

// MARK: The source

extension AppStore {
    /// This Mac's personal sources for agents' questions: Messages.
    static func devicePersonalSources(for store: AppStore) -> [any PersonalQuestionSource] {
        [MacMessagesSource(database: MessagesDatabase.system, settings: .shared, people: StoreMessagesPeople(store: store))]
    }
    /// The Messages source questions on this Mac read, for the relay (`MacMessagesAnswering`).
    var macMessages: MacMessagesAnswering? { personalQuestionSources.lazy.compactMap { $0 as? MacMessagesAnswering }.first }
}

/// What the Mac relay can call to answer a question from the owner's iPhone with this Mac's
/// Messages: small excerpts for Apple's on-device model here, and nothing at all while the owner has
/// Messages off or hasn't granted Full Disk Access. The same excerpts feed `AgentQuestionDesk`, so a
/// relayed question asked through the desk gets them without calling this directly.
@MainActor protocol MacMessagesAnswering: AnyObject {
    /// On in Connections and readable.
    var isAvailable: Bool { get }
    /// The excerpts that might answer `question`: at most `MessageExcerpts.maxExcerpts`, each a few
    /// short messages.
    func excerpts(for question: String, now: Date) async -> [MessageExcerpt]
}

@MainActor final class MacMessagesSource: PersonalQuestionSource, MacMessagesAnswering {
    let database: MessagesDatabase?
    let settings: PersonalSourceSettings
    let people: any MessagesPeopleDirectory
    /// How many of the newest messages in the window one question may scan.
    static let scanLimit = 3000

    init(database: MessagesDatabase?, settings: PersonalSourceSettings, people: any MessagesPeopleDirectory) {
        self.database = database; self.settings = settings; self.people = people
    }
    /// Checks by trying to open it, so it's only called when Connections shows or a question needs it.
    var access: MacMessagesAccess { database?.access() ?? .noHistory }
    var isAvailable: Bool { settings.messages && access == .granted }

    func excerpts(for question: String, now: Date) async -> [MessageExcerpt] {
        guard settings.messages, let database else { return [] }
        let everyone = people.everyone()
        let query = MessagesQuery.parse(question, knownNames: everyone.map(\.name), now: now)
        let named = query.names.isEmpty ? [] : await people.people(named: query.names)
        // Someone the question names but no handle is known for: search by its words alone.
        guard !named.isEmpty || !query.words.isEmpty else { return [] }
        var names: [String: String] = [:]
        for person in everyone + named { for handle in person.handles { names[MessagesHandle.key(handle)] = person.name } }
        let wanted = Set(named.flatMap(\.handles).map(MessagesHandle.key))
        let limit = Self.scanLimit, handleNames = names
        let messages: [TextMessage]? = await Task.detached(priority: .userInitiated) { () -> [TextMessage]? in
            do {
                var rows: Set<Int64>?
                if !wanted.isEmpty { rows = Set(try database.handles().filter { wanted.contains(MessagesHandle.key($0.value)) }.keys) }
                return try database.messages(withHandles: rows, since: query.since, until: query.until, limit: limit) { handle in
                    handleNames[MessagesHandle.key(handle)] ?? (handle.isEmpty ? "Someone" : handle)
                }
            } catch { return nil }
        }.value
        guard let messages else { return [] }
        return MessageExcerpts.build(messages, query: query, named: !named.isEmpty)
    }

    func sources(for question: String, now: Date) async -> [AgentQuestionSource] {
        MessageExcerpts.sources(await excerpts(for: question, now: now), origin: "mac", level: settings.messagesLevel)
    }
}

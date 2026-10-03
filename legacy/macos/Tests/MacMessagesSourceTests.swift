import XCTest
import SQLite3
@testable import KemoSabeMac

/// Messages on the Mac against a fixture `chat.db` each test builds: the schema subset KemoSabe
/// reads, a row whose text is only in `attributedBody`, a reaction, and a group chat. The owner's
/// real ~/Library/Messages is never opened (`MessagesDatabase.system` is nil in a test host).
@MainActor final class MacMessagesSourceTests: XCTestCase {
    private var folders: [URL] = []
    private let now = Date()
    override func tearDown() async throws {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        folders = []
    }

    func testTheTestHostNeverPointsAtTheRealMessages() {
        XCTAssertNil(MessagesDatabase.system)
        let store = makeStore()
        XCTAssertTrue(store.personalQuestionSources.isEmpty, "A test host's stores read no personal source")
        XCTAssertTrue(AppStore.devicePersonalSources(for: store).allSatisfy { ($0 as? MacMessagesSource)?.database == nil })
    }

    func testAccessDependsOnOpeningTheDatabase() throws {
        let missing = MessagesDatabase(url: folder().appendingPathComponent("chat.db"))
        XCTAssertEqual(missing.access(), .noHistory)
        let unreadable = folder().appendingPathComponent("chat.db")
        try Data("not a database".utf8).write(to: unreadable)
        XCTAssertEqual(MessagesDatabase(url: unreadable).access(), .needsFullDiskAccess, "Can't open it: ask for Full Disk Access")
        XCTAssertEqual(MessagesDatabase(url: try fixture()).access(), .granted)
    }

    func testReadsTextAndAttributedBodyAndSkipsReactions() throws {
        let database = MessagesDatabase(url: try fixture())
        let rows = try database.messages(withHandles: nil, since: now.addingTimeInterval(-30 * 86400), until: now, limit: 100) { MessagesHandle.key($0) == "4155550100" ? "Sarah" : $0 }
        XCTAssertTrue(rows.contains { $0.text == "I'm free Friday after 7" && $0.sender == "Sarah" }, "Newer rows keep their text in attributedBody")
        XCTAssertTrue(rows.contains { $0.text.hasPrefix("A long one:") && $0.text.count > 200 }, "A long attributedBody uses the two-byte length")
        XCTAssertFalse(rows.contains { $0.text.hasPrefix("Loved") }, "Reactions aren't messages")
        XCTAssertTrue(rows.contains { $0.fromMe && $0.sender == "You" })
        XCTAssertEqual(rows.first { $0.chatName != nil }?.chatName, "Hike crew")
        XCTAssertFalse(rows.contains { $0.text.contains("old news") }, "Outside the window")
    }

    func testTheDatabaseIsNeverWritten() throws {
        let url = try fixture()
        let before = try Data(contentsOf: url)
        let modified = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        _ = try MessagesDatabase(url: url).messages(withHandles: nil, since: .distantPast, until: now, limit: 100) { $0 }
        _ = MessagesDatabase(url: url).access()
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, modified)
    }

    func testTypedStreamLengths() throws {
        XCTAssertEqual(MessagesTypedStream.text(from: Self.typedStream("Hi")), "Hi")
        let long = String(repeating: "é", count: 150)
        XCTAssertEqual(MessagesTypedStream.text(from: Self.typedStream(long)), long)
        XCTAssertEqual(MessagesTypedStream.text(from: Self.archived("Archived by Apple’s own coder")), "Archived by Apple’s own coder",
                       "The same format NSArchiver writes")
        XCTAssertNil(MessagesTypedStream.text(from: Data("NSString".utf8)))
        XCTAssertNil(MessagesTypedStream.text(from: Data()))
    }

    func testPersonMatchingThroughPeople() async throws {
        let (source, settings, store) = try makeSource()
        settings.messages = true
        store.state.people = PeopleDirectory(profiles: [person("Sarah Chen", phone: "(415) 555-0100"), person("Sam Lee", email: "SAM@example.com")])
        let excerpts = await source.excerpts(for: "When is Sarah free?", now: now)
        XCTAssertFalse(excerpts.isEmpty)
        XCTAssertTrue(excerpts.allSatisfy { $0.messages.allSatisfy { $0.sender == "Sarah Chen" || $0.fromMe || $0.sender == "Sam Lee" } },
                      "Handles are named from People")
        let hers = try XCTUnwrap(excerpts.first { $0.text.contains("I'm free Friday after 7") })
        XCTAssertEqual(hers.title, "your messages with Sarah Chen")
        XCTAssertTrue(hers.text.contains("You ("), "With the owner's reply around it")
        XCTAssertTrue(excerpts.contains { $0.title == "your group chat “Hike crew”" }, "Sarah's group chats count too")
        XCTAssertFalse(excerpts.contains { $0.text.contains("Dentist") }, "Only chats Sarah is in")
        let sam = await source.excerpts(for: "What did Sam say about Friday?", now: now)
        XCTAssertTrue(sam.contains { $0.text.contains("Sam's free Friday") && $0.title == "your group chat “Hike crew”" })
    }

    func testExcerptsStaySmall() async throws {
        let (source, settings, store) = try makeSource(extra: 60)
        settings.messages = true
        store.state.people = PeopleDirectory(profiles: [person("Sarah Chen", phone: "+1 415 555 0100")])
        let excerpts = await source.excerpts(for: "When is Sarah free?", now: now)
        XCTAssertLessThanOrEqual(excerpts.count, MessageExcerpts.maxExcerpts)
        XCTAssertTrue(excerpts.allSatisfy { $0.messages.count <= MessageExcerpts.maxExcerptMessages })
        XCTAssertTrue(excerpts.allSatisfy { $0.messages.allSatisfy { $0.text.count <= MessageExcerpts.maxMessageCharacters } })
        XCTAssertLessThan(excerpts.flatMap(\.messages).count, 60, "Never the thread")
    }

    func testOffContributesNothingAndOnFeedsTheDeskAtTheChosenLevel() async throws {
        let (source, settings, store) = try makeSource()
        store.state.people = PeopleDirectory(profiles: [person("Sarah Chen", phone: "+14155550100")])
        let off = await source.sources(for: "When is Sarah free?", now: now)
        XCTAssertTrue(off.isEmpty)
        XCTAssertFalse(source.isAvailable)
        settings.messages = true
        let on = await source.sources(for: "When is Sarah free?", now: now)
        XCTAssertFalse(on.isEmpty)
        XCTAssertTrue(on.allSatisfy { $0.item.level == .sensitive && $0.item.ref.kind == .textMessage && $0.item.ref.id.hasPrefix("mac:") && $0.matched })
        settings.messagesLevel = .deviceOnly
        let deviceOnly = await source.sources(for: "When is Sarah free?", now: now)
        XCTAssertTrue(deviceOnly.allSatisfy { $0.item.level == .deviceOnly })

        // Through the desk (an account without People, so only Messages can answer): Device only is
        // never read for an agent, only counted.
        let desk = makeStore(), model = QuestionFakeModel()
        desk.agentQuestions.model = model
        desk.agentQuestions.sources = StoreAgentQuestionSources(store: desk, docs: nil, includeCalendar: false, personal: [source])
        let muse = AgentRequester(recipient: .externalAgent("com.meta.muse"), name: "Muse")
        desk.state.allowAgentQuestions(muse.recipient, once: false)
        let answer = await desk.agentQuestions.ask(.init(requester: muse, question: "When is Sarah free?", purpose: "dinner"))
        XCTAssertEqual(answer, .notFound)
        XCTAssertEqual(model.calls.value, 0)
        let journal = try await desk.agentRequests.journal.snapshot()
        XCTAssertTrue(journal.last?.withheld?.hasPrefix("Not read:") == true)
    }

    // MARK: Fixture

    private func makeStore() -> AppStore {
        AppStore(repository: .init(url: folder().appendingPathComponent("state.json")), provider: APIUnavailableLocal(), apiKeys: MemoryAPIKeys())
    }
    private func makeSource(extra: Int = 0) throws -> (MacMessagesSource, PersonalSourceSettings, AppStore) {
        let name = "mac-messages-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let settings = PersonalSourceSettings(defaults: defaults), store = makeStore()
        let source = MacMessagesSource(database: .init(url: try fixture(extra: extra)), settings: settings,
                                       people: StoreMessagesPeople(store: store, includeContacts: false))
        return (source, settings, store)
    }
    private func person(_ name: String, phone: String? = nil, email: String? = nil) -> PeopleProfile {
        var fields = [PeopleField(kind: .name, value: name)]
        if let phone { fields.append(.init(kind: .phone, value: phone)) }
        if let email { fields.append(.init(kind: .email, value: email)) }
        return PeopleProfile(sources: [PeopleSource(kind: .note, label: "Your note", fields: fields)])
    }
    private func folder() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacMessages-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        return folder
    }

    /// A chat.db with the tables and columns KemoSabe reads. Dates are nanoseconds since 2001, as on
    /// current macOS; one old row uses seconds.
    private func fixture(extra: Int = 0) throws -> URL {
        let url = folder().appendingPathComponent("chat.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        func exec(_ sql: String) { XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db))) }
        exec("""
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL, service TEXT NOT NULL);
            CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT, chat_identifier TEXT, display_name TEXT);
            CREATE TABLE message (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT, text TEXT, attributedBody BLOB, handle_id INTEGER DEFAULT 0,
                date INTEGER, is_from_me INTEGER DEFAULT 0, associated_message_type INTEGER DEFAULT 0, item_type INTEGER DEFAULT 0);
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER, message_date INTEGER DEFAULT 0);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            INSERT INTO handle (ROWID, id, service) VALUES (1, '+14155550100', 'iMessage'), (2, 'sam@example.com', 'iMessage'), (3, '+12125550199', 'SMS');
            INSERT INTO chat (ROWID, guid, chat_identifier, display_name) VALUES (1, 'iMessage;-;+14155550100', '+14155550100', ''),
                (2, 'iMessage;+;chat1', 'chat1', 'Hike crew'), (3, 'SMS;-;+12125550199', '+12125550199', '');
            INSERT INTO chat_handle_join VALUES (1, 1), (2, 1), (2, 2), (3, 3);
            """)
        var rowID: Int64 = 0
        func add(chat: Int64, handle: Int64, fromMe: Bool = false, text: String?, body: Data? = nil, secondsAgo: Double, reaction: Bool = false, nanoseconds: Bool = true) {
            rowID += 1
            let stamp = now.addingTimeInterval(-secondsAgo).timeIntervalSinceReferenceDate
            var statement: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO message (ROWID, guid, text, attributedBody, handle_id, date, is_from_me, associated_message_type) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", -1, &statement, nil)
            sqlite3_bind_int64(statement, 1, rowID)
            sqlite3_bind_text(statement, 2, "guid-\(rowID)", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if let text { sqlite3_bind_text(statement, 3, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) } else { sqlite3_bind_null(statement, 3) }
            if let body { _ = body.withUnsafeBytes { sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32(body.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) } }
            else { sqlite3_bind_null(statement, 4) }
            sqlite3_bind_int64(statement, 5, fromMe ? 0 : handle)
            sqlite3_bind_int64(statement, 6, nanoseconds ? Int64(stamp * 1_000_000_000) : Int64(stamp))
            sqlite3_bind_int64(statement, 7, fromMe ? 1 : 0)
            sqlite3_bind_int64(statement, 8, reaction ? 2000 : 0)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
            exec("INSERT INTO chat_message_join (chat_id, message_id) VALUES (\(chat), \(rowID))")
        }
        add(chat: 1, handle: 1, text: "old news from last year", secondsAgo: 400 * 86400, nanoseconds: false)
        add(chat: 1, handle: 1, text: "Are we still on for Friday?", secondsAgo: 7200)
        add(chat: 1, handle: 1, fromMe: true, text: "Yes! When works?", secondsAgo: 7100)
        add(chat: 1, handle: 1, text: nil, body: Self.typedStream("I'm free Friday after 7"), secondsAgo: 7000)
        add(chat: 1, handle: 1, text: "Loved “I'm free Friday after 7”", secondsAgo: 6900, reaction: true)
        add(chat: 1, handle: 1, text: nil, body: Self.archived("A long one: " + String(repeating: "trail notes ", count: 30)), secondsAgo: 5000)
        add(chat: 2, handle: 2, text: "Sam's free Friday too", secondsAgo: 3000)
        add(chat: 3, handle: 3, text: "Dentist reminder: free cleaning Friday", secondsAgo: 2000)
        for index in 0..<extra {
            add(chat: 1, handle: 1, fromMe: index.isMultiple(of: 2), text: "free " + String(repeating: "chatter ", count: 60) + "\(index)", secondsAgo: Double(1000 - index))
        }
        return url
    }

    /// An NSAttributedString as Messages stores it, built by hand: the typedstream header, the class
    /// chain, then `NSString`, `+`, the length, and the UTF-8 text.
    static func typedStream(_ text: String) -> Data {
        let utf8 = Array(text.utf8)
        var bytes: [UInt8] = [0x04, 0x0B] + Array("streamtyped".utf8) + [0x81, 0xE8, 0x03, 0x84, 0x01, 0x40, 0x84, 0x84, 0x84, 0x12]
        bytes += Array("NSAttributedString".utf8) + [0x00, 0x84, 0x84, 0x08] + Array("NSObject".utf8) + [0x00, 0x85, 0x92, 0x84, 0x84, 0x84, 0x08]
        bytes += Array("NSString".utf8) + [0x01, 0x94, 0x84, 0x01, 0x2B]
        bytes += utf8.count < 0x80 ? [UInt8(utf8.count)] : [0x81, UInt8(utf8.count & 0xFF), UInt8(utf8.count >> 8)]
        bytes += utf8 + [0x86, 0x84, 0x02, 0x69, 0x49, 0x01, 0x01, 0x92, 0x84, 0x84, 0x84, 0x0C]
        return Data(bytes)
    }
    /// The same, written by Apple's own (deprecated) typedstream coder.
    @available(macOS, deprecated: 10.13)
    static func archived(_ text: String) -> Data { NSArchiver.archivedData(withRootObject: NSAttributedString(string: text)) }
}

import XCTest
import Darwin
@testable import KemoSabeMac

/// The MacSpaces receiver with a fake agent and a temporary account folder: no real conversation,
/// no installed app, and never the person's socket endpoint.
@MainActor final class MacSpacesBridgeTests: XCTestCase {
    private var folder: URL!
    private var fake: BridgeFakeSession!
    private var coding: CodingWorkspaceStore!
    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacSpacesBridgeTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fake = BridgeFakeSession()
        let session = fake!
        coding = CodingWorkspaceStore(storage: .init(directory: folder.appendingPathComponent("account-one"), ownerID: "one"), sessionFactory: { _ in session })
    }
    override func tearDown() async throws {
        coding?.stopAll()
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }
    /// A fixture conversation waiting for review, so it can take a new prompt.
    private func fixtureConversation() async throws -> UUID {
        let created = await coding.create(project: DesktopProject(name: "Fixture", bookmark: Data()), root: folder, provider: .codex, model: "", access: .edit, isolated: false, prompt: "Initial fixture")
        let id = try XCTUnwrap(created)
        fake.onState?(.review)
        return id
    }
    private func server(receipts: BridgeReceiptStore? = nil, open: @escaping (UUID) -> Void = { _ in }) throws -> MacSpacesBridgeServer {
        let store = try receipts ?? BridgeReceiptStore(url: folder.appendingPathComponent("receipts.json"))
        return MacSpacesBridgeServer(coding: coding, receipts: store, status: MacSpacesBridgeStatus(), open: open)
    }
    private func send(_ server: MacSpacesBridgeServer, _ request: MacSpacesBridge.Request) throws -> MacSpacesBridge.Response {
        try JSONDecoder().decode(MacSpacesBridge.Response.self, from: server.handle(JSONEncoder().encode(request)))
    }

    func testRoutingReplayCancellationAndAccountSwitch() async throws {
        let id = try await fixtureConversation()
        var opened: UUID?
        let server = try server { opened = $0 }
        let discovery = try send(server, .init(operation: .discover))
        XCTAssertEqual(discovery.conversations.map(\.id), [id])
        let request = MacSpacesBridge.Request(operation: .submit, conversation: id, prompt: "Explicit test prompt")
        XCTAssertNil(try send(server, request).error)
        // The same request again (a retry after a lost reply) replays the receipt; nothing is resent.
        XCTAssertNil(try send(server, request).error)
        XCTAssertEqual(fake.sent.filter { $0 == "Explicit test prompt" }.count, 1)
        XCTAssertEqual(try send(server, .init(operation: .status, conversation: id)).conversations.first?.canCancel, true)
        XCTAssertNil(try send(server, .init(operation: .open, conversation: id)).error)
        XCTAssertEqual(opened, id)
        XCTAssertNil(try send(server, .init(operation: .cancel, conversation: id)).error)
        XCTAssertGreaterThan(fake.stops, 0)
        XCTAssertNotNil(try send(server, .init(operation: .cancel, conversation: id)).error, "Cancel after the task stopped reports it, and does nothing")
        XCTAssertNotNil(try send(server, .init(operation: .submit, conversation: UUID(), prompt: "Wrong recipient")).error)
        // Another account sees none of the first account's conversations, and old IDs stop working.
        coding.switchAccount(to: .init(directory: folder.appendingPathComponent("account-two"), ownerID: "two"))
        XCTAssertEqual(try send(server, .init(operation: .discover)).conversations, [])
        XCTAssertNotNil(try send(server, request).error)
        XCTAssertNotNil(try send(server, .init(operation: .open, conversation: id)).error)
        XCTAssertNotNil(try send(server, .init(operation: .cancel, conversation: id)).error)
        // Signed out: nothing is listed or sent.
        coding.switchAccount(to: nil)
        XCTAssertNotNil(try send(server, .init(operation: .discover)).error)
        // Back in the first account, the earlier request still replays instead of sending again.
        coding.switchAccount(to: .init(directory: folder.appendingPathComponent("account-one"), ownerID: "one"))
        XCTAssertEqual(try send(server, .init(operation: .discover)).conversations.map(\.id), [id])
        XCTAssertNil(try send(server, request).error)
        XCTAssertEqual(fake.sent.filter { $0 == "Explicit test prompt" }.count, 1)
    }

    func testDuplicateRequestIdentifierWithChangedPayloadIsRefused() async throws {
        let id = try await fixtureConversation()
        let server = try server()
        var request = MacSpacesBridge.Request(operation: .submit, conversation: id, prompt: "First prompt")
        XCTAssertNil(try send(server, request).error)
        fake.onState?(.review)
        request.prompt = "Changed prompt, same identifier"
        XCTAssertNotNil(try send(server, request).error)
        XCTAssertEqual(fake.sent.filter { $0.hasPrefix("Changed") }.count, 0)
        // A receipt reserved but never completed (a crash mid-send) replays as uncertain, not a resend.
        let receipts = try BridgeReceiptStore(url: folder.appendingPathComponent("uncertain.json"))
        let pending = MacSpacesBridge.Request(operation: .submit, conversation: id, prompt: "Crashed before the reply")
        try receipts.reserve(pending, owner: "one")
        let afterCrash = try self.server(receipts: BridgeReceiptStore(url: folder.appendingPathComponent("uncertain.json")))
        let uncertain = try send(afterCrash, pending)
        XCTAssertNotNil(uncertain.error)
        XCTAssertEqual(uncertain.uncertain, true, "MacSpaces is told the outcome is unknown, so it keeps the same request")
        XCTAssertEqual(fake.sent.filter { $0 == "Crashed before the reply" }.count, 0)
    }

    func testReceiptWriteFailureSendsNothing() async throws {
        let id = try await fixtureConversation()
        // The receipts' folder is a regular file, so the reservation can't be written.
        let blocker = folder.appendingPathComponent("blocked")
        try Data().write(to: blocker)
        let server = try server(receipts: BridgeReceiptStore(url: blocker.appendingPathComponent("receipts.json")))
        let response = try send(server, .init(operation: .submit, conversation: id, prompt: "Must not be sent"))
        XCTAssertNotNil(response.error)
        XCTAssertEqual(fake.sent.filter { $0 == "Must not be sent" }.count, 0)
        // Unreadable receipts keep the receiver from starting at all.
        let corrupt = folder.appendingPathComponent("corrupt.json")
        try Data("not json".utf8).write(to: corrupt)
        let status = MacSpacesBridgeStatus()
        let endpoint = try shortEndpoint()
        let failing = MacSpacesBridgeServer(coding: coding, endpoint: endpoint, receiptsURL: corrupt, status: status) { _ in }
        XCTAssertThrowsError(try failing.start())
        XCTAssertFalse(failing.isListening)
        XCTAssertFalse(FileManager.default.fileExists(atPath: endpoint.path), "Nothing listens when receipts can't be read")
        guard case .failed = status.state else { return XCTFail("The failure is visible in Settings") }
    }

    func testMalformedOversizedAndMismatchedRequests() async throws {
        let id = try await fixtureConversation()
        let server = try server()
        func error(_ data: Data) throws -> String? { try JSONDecoder().decode(MacSpacesBridge.Response.self, from: server.handle(data)).error }
        XCTAssertNotNil(try error(Data("not json".utf8)))
        XCTAssertNotNil(try error(Data(count: MacSpacesBridge.maxBytes + 1)))
        var future = MacSpacesBridge.Request(operation: .discover); future.version = 99
        XCTAssertNotNil(try error(JSONEncoder().encode(future)))
        XCTAssertNotNil(try send(server, .init(operation: .submit, conversation: id, prompt: "   ")).error)
        XCTAssertNotNil(try send(server, .init(operation: .submit, conversation: id, prompt: String(repeating: "a", count: 64 * 1024 + 1))).error)
        XCTAssertNotNil(try send(server, .init(operation: .status)).error, "Everything but discovery names a conversation")
        XCTAssertEqual(fake.sent.count, 1, "Only the fixture's own first prompt was sent")
        // A frame header over the limit is refused before its body is read.
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { close(pair[0]); close(pair[1]) }
        LocalBridgeTransport.configure(pair[1])
        let header: [UInt8] = [0, 3, 0, 0] // 196,608 bytes
        XCTAssertEqual(header.withUnsafeBytes { Darwin.write(pair[0], $0.baseAddress, 4) }, 4)
        XCTAssertThrowsError(try LocalBridgeTransport.readFrame(from: pair[1]))
        XCTAssertThrowsError(try LocalBridgeTransport.writeFrame(Data(count: MacSpacesBridge.maxBytes + 1), to: pair[0]))
    }

    func testListenerStartsRecoversStaleEndpointStopsAndRestarts() async throws {
        let endpoint = try shortEndpoint()
        defer { try? FileManager.default.removeItem(at: endpoint.deletingLastPathComponent()) }
        // A socket left by a process that died: bound, never unlinked, nobody listening.
        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try LocalBridgeTransport.address(endpoint)
        XCTAssertEqual(withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(stale, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }, 0)
        close(stale)
        XCTAssertTrue(FileManager.default.fileExists(atPath: endpoint.path))

        let status = MacSpacesBridgeStatus()
        let server = MacSpacesBridgeServer(coding: coding, endpoint: endpoint, receiptsURL: folder.appendingPathComponent("listener-receipts.json"), status: status) { _ in }
        try server.start()
        XCTAssertTrue(server.isListening)
        guard case .listening = status.state else { return XCTFail("Listening is shown once the socket is bound") }
        var info = stat()
        XCTAssertEqual(lstat(endpoint.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)

        // A second receiver never takes over a live endpoint.
        let secondStatus = MacSpacesBridgeStatus()
        let second = MacSpacesBridgeServer(coding: coding, endpoint: endpoint, receiptsURL: folder.appendingPathComponent("second.json"), status: secondStatus) { _ in }
        XCTAssertThrowsError(try second.start())
        guard case .failed = secondStatus.state else { return XCTFail("A taken endpoint is a visible failure") }
        XCTAssertTrue(server.isListening)

        // This test process isn't the signed MacSpaces: the listener refuses it before reading.
        // (The second receiver's liveness probe above is refused the same way, so count up from there.)
        try await Task.sleep(for: .milliseconds(300))
        let refusedBefore = status.refusals
        XCTAssertThrowsError(try rawExchange(endpoint, Data("{}".utf8)))
        for _ in 0..<40 where status.refusals == refusedBefore { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(status.refusals, refusedBefore + 1)
        XCTAssertEqual(status.lastRefusal?.note, MacSpacesBridgeStatus.note(.identity))
        XCTAssertNil(status.lastRequest, "A refused peer's request is never handled")

        server.stop()
        XCTAssertFalse(server.isListening)
        XCTAssertFalse(FileManager.default.fileExists(atPath: endpoint.path), "Stopping removes the endpoint it bound")
        try server.start()
        XCTAssertTrue(server.isListening)
        server.stop()

        // Something other than a socket at the endpoint is never removed.
        try Data("keep".utf8).write(to: endpoint)
        XCTAssertThrowsError(try server.start())
        XCTAssertEqual(try Data(contentsOf: endpoint), Data("keep".utf8))
    }

    /// A socket path short enough for sockaddr_un, outside the person's real endpoint folder.
    private func shortEndpoint() throws -> URL {
        let directory = URL(fileURLWithPath: "/private/tmp/msb-" + UUID().uuidString.prefix(8), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("endpoint")
    }
    /// Connects and sends a frame without verifying the server, as an unverified peer would.
    private func rawExchange(_ url: URL, _ data: Data) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        LocalBridgeTransport.configure(fd)
        var address = try LocalBridgeTransport.address(url)
        guard withUnsafePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }) == 0 else {
            throw MacSpacesBridge.Failure("connect failed")
        }
        try LocalBridgeTransport.writeFrame(data, to: fd)
        return try LocalBridgeTransport.readFrame(from: fd)
    }
}
// MARK: Version 2: capabilities, new quick tasks, the personal chat, attachments, progress

@MainActor final class MacSpacesBridgeV2Tests: XCTestCase {
    private var folder: URL!
    private var fake: BridgeFakeSession!
    private var coding: CodingWorkspaceStore!
    private var chat: BridgeFakeChat!
    private var project: DesktopProject!
    private var remembered = CodingNewTaskSettings()
    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacSpacesBridgeV2-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Project"), withIntermediateDirectories: true)
        fake = BridgeFakeSession(); chat = BridgeFakeChat()
        let session = fake!
        coding = CodingWorkspaceStore(storage: .init(directory: folder.appendingPathComponent("account"), ownerID: "one"), sessionFactory: { _ in session })
        project = DesktopProject(name: "Fixture project", bookmark: Data())
        remembered.isolated = false
    }
    override func tearDown() async throws {
        coding?.stopAll()
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }
    private var outbox: URL { folder.appendingPathComponent("Outbox") }
    private func server() throws -> MacSpacesBridgeServer {
        let project = project!, root = folder.appendingPathComponent("Project"), chat = chat!, settings = remembered
        let routes = MacSpacesBridgeRoutes(chat: { chat }, projects: { [project] }, resolve: { _ in root }, newTask: { settings }, openChat: { chat.opened += 1 }, outbox: outbox)
        return MacSpacesBridgeServer(coding: coding, receipts: try BridgeReceiptStore(url: folder.appendingPathComponent("receipts.json")), status: MacSpacesBridgeStatus(), routes: routes) { _ in }
    }
    private func send(_ server: MacSpacesBridgeServer, _ request: MacSpacesBridge.Request) throws -> MacSpacesBridge.Response {
        try JSONDecoder().decode(MacSpacesBridge.Response.self, from: server.handle(JSONEncoder().encode(request)))
    }
    private func codingConversation() async throws -> UUID {
        let created = await coding.create(project: project, root: folder.appendingPathComponent("Project"), provider: .codex, model: "", access: .edit, isolated: false, prompt: "Initial fixture")
        let id = try XCTUnwrap(created); fake.onState?(.review); return id
    }

    func testVersionOneClientsKeepWorkingAndLearnCapabilities() async throws {
        let id = try await codingConversation()
        let server = try server()
        let discovery = try send(server, .init(version: 1, operation: .discover))
        XCTAssertEqual(discovery.version, 1, "Answered in the request's version")
        XCTAssertEqual(discovery.capabilities?.version, 2)
        XCTAssertEqual(discovery.capabilities?.destinations.map(\.kind), ["personal", "coding"])
        XCTAssertTrue(discovery.capabilities?.supports(.create) == true)
        XCTAssertEqual(discovery.conversations.map(\.id), [id], "An empty KemoSabe chat isn't listed")
        // What a version 1 MacSpaces decodes and checks: the same response, version 1.
        let reply = try send(server, .init(version: 1, operation: .submit, conversation: id, prompt: "Version one prompt"))
        XCTAssertNil(reply.error); XCTAssertEqual(reply.version, 1)
        XCTAssertEqual(fake.sent.filter { $0 == "Version one prompt" }.count, 1)
        // Version 2 features need a version 2 request.
        XCTAssertNotNil(try send(server, .init(version: 1, operation: .create, prompt: "x", destination: "personal")).error)
        XCTAssertNotNil(try send(server, .init(version: 3, operation: .discover)).error)
    }

    func testNewQuickTaskInAProjectStartsOnceWithAccessCapped() async throws {
        remembered.access = .autoEdit
        let server = try server()
        let request = MacSpacesBridge.Request(operation: .create, prompt: "Explicit new task", destination: "project:" + project.id.uuidString)
        let reply = try send(server, request)
        XCTAssertNil(reply.error)
        let id = try XCTUnwrap(reply.conversations.first?.id)
        XCTAssertEqual(reply.conversations.first?.status, CodingTaskStatus.preparing.title)
        for _ in 0..<100 where coding.task(id) == nil || fake.sent.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let task = try XCTUnwrap(coding.task(id))
        XCTAssertEqual(task.access, .edit, "MacSpaces never starts a task that skips Tsukumo's approvals")
        XCTAssertNil(coding.selected, "A quick task doesn't take over the window's selection")
        // The same request again replays; a second task is never created.
        XCTAssertEqual(try send(server, request).conversations.first?.id, id)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(coding.tasks.count, 1)
        XCTAssertEqual(fake.sent.filter { $0 == "Explicit new task" }.count, 1)
        XCTAssertNotNil(try send(server, .init(operation: .create, prompt: "Nowhere", destination: "project:" + UUID().uuidString)).error)
    }

    func testPersonalChatRouteSendsOnceAndSharesNoContent() async throws {
        chat.ready = true
        let server = try server()
        let create = MacSpacesBridge.Request(operation: .create, prompt: "Hello from the notch", destination: "personal")
        let reply = try send(server, create)
        XCTAssertNil(reply.error)
        XCTAssertEqual(chat.newChats, 1); XCTAssertEqual(chat.sent, ["Hello from the notch"])
        XCTAssertNil(try send(server, create).error)
        XCTAssertEqual(chat.sent.count, 1, "A replay never sends again")
        let listed = try XCTUnwrap(try send(server, .init(operation: .discover)).conversations.first)
        XCTAssertEqual(listed.kind, "personal"); XCTAssertEqual(listed.title, "KemoSabe chat")
        XCTAssertEqual(listed.id, chat.bridgeChatID)
        chat.replying = true
        XCTAssertEqual(try send(server, .init(operation: .status, conversation: listed.id)).conversations.first?.canCancel, true)
        XCTAssertNotNil(try send(server, .init(operation: .submit, conversation: listed.id, prompt: "While replying")).error)
        XCTAssertNil(try send(server, .init(operation: .cancel, conversation: listed.id)).error)
        XCTAssertEqual(chat.stops, 1)
        XCTAssertNil(try send(server, .init(operation: .open, conversation: listed.id)).error)
        XCTAssertEqual(chat.opened, 1)
        XCTAssertNotNil(try send(server, .init(operation: .submit, conversation: listed.id, prompt: String(repeating: "a", count: 2001))).error)
        // A send the chat refuses (a Secret chat, a model not ready) is reported, not claimed.
        chat.refuse = "This chat is Secret."
        XCTAssertEqual(try send(server, .init(operation: .submit, conversation: listed.id, prompt: "Refused")).error?.hasPrefix("This chat is Secret."), true)
        XCTAssertEqual(chat.sent.count, 1)
    }

    func testAttachmentsAreVerifiedCopiedAndBounded() async throws {
        let id = try await codingConversation()
        let server = try server()
        let image = folder.appendingPathComponent("shot.png"), notes = folder.appendingPathComponent("notes.txt")
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: image); try Data("notes".utf8).write(to: notes)
        var request = MacSpacesBridge.Request(operation: .submit, conversation: id, prompt: "With files")
        request.attachments = try MacSpacesBridge.Attachment.stage([image, notes], for: request.id, outbox: outbox)
        XCTAssertNil(try send(server, request).error)
        let input = try XCTUnwrap(fake.inputs.last)
        XCTAssertEqual(input.images.count, 1)
        XCTAssertTrue(input.text.contains("Attached from MacSpaces"))
        XCTAssertFalse(input.images[0].path.contains("/Outbox/"), "The agent gets Tsukumo's own copy")
        // A file changed after it was attached is refused before anything is sent.
        fake.onState?(.review)
        var changed = MacSpacesBridge.Request(operation: .submit, conversation: id, prompt: "Tampered")
        changed.attachments = try MacSpacesBridge.Attachment.stage([notes], for: changed.id, outbox: outbox)
        try Data("different".utf8).write(to: MacSpacesBridge.Attachment.folder(for: changed.id, outbox: outbox).appendingPathComponent("notes.txt"))
        XCTAssertNotNil(try send(server, changed).error)
        XCTAssertFalse(fake.sent.contains("Tampered"))
        // Names are plain file names, and the count and size are bounded.
        var bad = MacSpacesBridge.Request(operation: .submit, conversation: id, prompt: "Bad")
        bad.attachments = [.init(name: "../escape", size: 1, sha256: String(repeating: "0", count: 64))]
        XCTAssertNotNil(try send(server, bad).error)
        bad.attachments = Array(repeating: .init(name: "a", size: 1, sha256: String(repeating: "0", count: 64)), count: 5)
        XCTAssertThrowsError(try bad.validate())
        // The personal chat doesn't take files.
        chat.ready = true; chat.messages = [UUID()]
        var personal = MacSpacesBridge.Request(operation: .submit, conversation: chat.bridgeChatID, prompt: "File to chat")
        personal.attachments = try MacSpacesBridge.Attachment.stage([notes], for: personal.id, outbox: outbox)
        XCTAssertNotNil(try send(server, personal).error)
        XCTAssertTrue(chat.sent.isEmpty)
    }

    func testProgressIsContentFreeAndFlagsApproval() async throws {
        let id = try await codingConversation()
        let server = try server()
        _ = try send(server, .init(operation: .submit, conversation: id, prompt: "Do work"))
        fake.onEvent?(.init(kind: .command, text: "secret-command --token"), false)
        var status = try XCTUnwrap(try send(server, .init(operation: .status, conversation: id)).conversations.first)
        XCTAssertEqual(status.activity, "Running a command")
        XCTAssertEqual(status.needsApproval, false)
        fake.onState?(.needsInput)
        status = try XCTUnwrap(try send(server, .init(operation: .status, conversation: id)).conversations.first)
        XCTAssertEqual(status.needsApproval, true)
        XCTAssertEqual(status.activity, "Needs you in Tsukumo")
        let encoded = String(decoding: server.handle(try JSONEncoder().encode(MacSpacesBridge.Request(operation: .status, conversation: id))), as: UTF8.self)
        XCTAssertFalse(encoded.contains("secret-command"), "No event content leaves Tsukumo")
    }
}
@MainActor private final class BridgeFakeChat: MacSpacesPersonalChat {
    var ready = false, replying = false
    var messages: [UUID] = []
    var chatID = UUID()
    var sent: [String] = []
    var newChats = 0, stops = 0, opened = 0
    var refuse: String?
    var bridgeChatID: UUID? { messages.isEmpty ? nil : chatID }
    var bridgeReplying: Bool { replying }
    var bridgeReady: Bool { ready }
    var bridgeLastMessage: UUID? { messages.last }
    var bridgeError: String? { refuse }
    func bridgeStartNewChat() { newChats += 1; messages = []; chatID = UUID() }
    func bridgeSend(_ text: String) { guard refuse == nil else { return }; sent.append(text); messages.append(UUID()) }
    func bridgeStop() { stops += 1; replying = false }
}
@MainActor private final class BridgeFakeSession: AgentSession {
    var onEvent: ((CodingEvent, Bool) -> Void)?
    var onState: ((CodingTaskStatus) -> Void)?
    var onSession: ((String) -> Void)?
    var onApproval: ((CodingApproval?) -> Void)?
    var sent: [String] = []
    var stops = 0
    var inputs: [CodingTurnInput] = []
    func send(_ text: String) throws { sent.append(text); onState?(.working) }
    func send(input: CodingTurnInput) throws { inputs.append(input); try send(input.text) }
    func respond(_ id: String, allow: Bool, answers: String) throws {}
    func stop() { stops += 1 }
}

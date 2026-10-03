import XCTest
@testable import KemoSabeMac

/// A KemoSabe chat's context handed to a Tsukumo coding task (`TsukumoContextHandoff`): the agent is
/// its own recipient, only the allowed slice goes ahead of the owner's message, the transcript shows
/// the message as written with a note of the context, the task keeps the packet as its lineage, and
/// the delivery is journaled. A fake agent session; no agent runs.
@MainActor final class ContextPacketTsukumoTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ContextPacketTsukumo-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let folder { try? FileManager.default.removeItem(at: folder) } }

    func testEachAgentIsItsOwnRecipient() {
        XCTAssertEqual(TsukumoContextHandoff.recipient(.claude), .codingAgent("claude-code"))
        XCTAssertEqual(TsukumoContextHandoff.recipient(.codex), .codingAgent("codex"))
        XCTAssertEqual(TsukumoContextHandoff.recipient(.cursor), .codingAgent("cursor-agent"))
        XCTAssertEqual(TsukumoContextHandoff.recipient(.muse), .externalAgent("com.meta.muse"))
        let custom = UUID()
        XCTAssertEqual(TsukumoContextHandoff.recipient(.custom(custom)), .acpAgent(custom.uuidString.lowercased()))
        for provider in [CodingProvider.claude, .codex, .cursor, .muse, .custom(custom)] {
            XCTAssertEqual(TsukumoContextHandoff.recipient(provider).locality, .thirdPartyCloud)
        }
    }

    func testDestinationsAreANewTaskPerProjectAndTasksThatCanTakeAMessage() {
        let project = DesktopProject(name: "Portfolio", bookmark: Data()), gone = UUID()
        func task(_ title: String, _ status: CodingTaskStatus, project: UUID, archived: Bool? = nil) -> CodingTaskRecord {
            var record = CodingTaskRecord(projectID: project, ownerID: "local-test", title: title, provider: .claude, model: "", access: .edit,
                                          projectPath: folder.path, directory: folder.path, isolated: false)
            record.status = status; record.archived = archived
            return record
        }
        let tasks = [task("Fix login", .review, project: project.id), task("Running", .working, project: project.id),
                     task("Done", .done, project: project.id), task("Archived", .ready, project: project.id, archived: true),
                     task("Orphan", .ready, project: gone)]
        let list = TsukumoContextHandoff.destinations(projects: [project], tasks: tasks, settings: .init(provider: .codex))
        XCTAssertEqual(list.map(\.place), ["a new task in “Portfolio”", "the task “Fix login”"])
        XCTAssertEqual(list[0].reader, RecipientID.codingAgent("codex").key)
        XCTAssertEqual(list[0].name, "Codex")
        XCTAssertNil(list[0].task)
        XCTAssertEqual(list[1].reader, RecipientID.codingAgent("claude-code").key, "An existing task's own agent reads it")
        XCTAssertEqual(list.map(\.kind), [.codingTask, .codingTask])
    }

    func testANewTaskStartsWithOnlyTheAllowedSliceAndItsLineage() async throws {
        let (store, coding, fake) = makeStores()
        let project = DesktopProject(name: "Portfolio", bookmark: Data())
        var packet = makePacket(to: TsukumoContextHandoff.destinations(projects: [project], tasks: [], settings: .init(provider: .codex))[0])
        packet.consented = packet.items.filter { $0.level == .sensitive }.map(\.id)
        let id = try await TsukumoContextHandoff.deliver(packet, message: "Add a dinner page to the site.", store: store, coding: coding,
                                                         project: project, root: { self.folder }, settings: .init(provider: .codex, access: .full, isolated: false))
        let task = try XCTUnwrap(coding.task(id))
        XCTAssertEqual(task.provider, .codex)
        XCTAssertEqual(task.access, .edit, "A handed-over task never starts with more than Ask first")
        XCTAssertEqual(task.contextPackets, [packet.id])
        // The agent gets the allowed slice ahead of the message.
        let sent = try XCTUnwrap(fake.sent.first)
        XCTAssertTrue(sent.hasPrefix("Context the owner brought from your chat “Dinner plans”"))
        XCTAssertTrue(sent.hasSuffix("\n\nAdd a dinner page to the site."))
        XCTAssertTrue(sent.contains("personal fact") && sent.contains("sensitive fact"))
        XCTAssertFalse(sent.contains("device fact") || sent.contains("secret fact"))
        // The transcript: a note with exactly what went, then the message as written.
        let note = try XCTUnwrap(task.events.last { $0.kind == .system && $0.text.hasPrefix("Context from KemoSabe") })
        XCTAssertEqual(note.text, "Context from KemoSabe: your chat “Dinner plans”")
        XCTAssertTrue(sent.hasPrefix(note.detail))
        XCTAssertEqual(task.events.last { $0.kind == .user }?.text, "Add a dinner page to the site.")
        // The journal.
        try await waitUntil { store.agentRequests.journalRevision > 0 }
        let records = try await store.agentRequests.journal.snapshot()
        let record = try XCTUnwrap(records.last)
        XCTAssertTrue(record.isPacket)
        XCTAssertEqual(record.requester, "Codex")
        XCTAssertEqual(record.requesterKey, "coding:codex")
        XCTAssertEqual(record.target, "a new task in “Portfolio”")
        XCTAssertEqual(record.purpose, "A coding task")
        XCTAssertEqual(record.withheld, "Not shared: 1 Device only memory, 1 Secret memory.")
        XCTAssertEqual(record.shared, note.detail)
    }

    func testAnExistingTaskGetsItAsItsNextMessage() async throws {
        let (store, coding, fake) = makeStores()
        let project = DesktopProject(name: "Portfolio", bookmark: Data())
        let created = await coding.create(project: project, root: folder, provider: .claude, model: "", access: .edit, isolated: false, prompt: "First")
        let id = try XCTUnwrap(created)
        fake.onState?(.review)
        let destination = try XCTUnwrap(TsukumoContextHandoff.destinations(projects: [project], tasks: coding.tasks, settings: .init()).first { $0.task == id })
        let packet = makePacket(to: destination)
        _ = try await TsukumoContextHandoff.deliver(packet, message: "", store: store, coding: coding, project: project, root: { self.folder }, settings: .init())
        XCTAssertEqual(fake.sent.count, 2)
        XCTAssertTrue(fake.sent[1].hasSuffix("\n\nHere’s context from KemoSabe for this task."))
        XCTAssertTrue(fake.sent[1].contains("personal fact"))
        XCTAssertFalse(fake.sent[1].contains("sensitive fact"), "Sensitive needs the owner to include it")
        XCTAssertEqual(coding.task(id)?.contextPackets, [packet.id])
        // A busy task is refused, and nothing is sent.
        fake.onState?(.working)
        do {
            _ = try await TsukumoContextHandoff.deliver(makePacket(to: destination), message: "More", store: store, coding: coding, project: project,
                                                        root: { self.folder }, settings: .init())
            XCTFail("A running task can't take it")
        } catch {}
        XCTAssertEqual(fake.sent.count, 2)
    }

    func testNothingAllowedSendsNothing() async throws {
        let (store, coding, fake) = makeStores()
        let project = DesktopProject(name: "Portfolio", bookmark: Data())
        var packet = makePacket(to: TsukumoContextHandoff.destinations(projects: [project], tasks: [], settings: .init())[0])
        packet.items = packet.items.filter { $0.level >= .deviceOnly }
        do {
            _ = try await TsukumoContextHandoff.deliver(packet, message: "Go", store: store, coding: coding, project: project, root: { self.folder }, settings: .init())
            XCTFail("Device only and Secret never go to an agent")
        } catch {}
        XCTAssertTrue(fake.sent.isEmpty)
        XCTAssertTrue(coding.tasks.isEmpty)
    }

    // MARK: Helpers

    private func makeStores() -> (AppStore, CodingWorkspaceStore, PacketFakeSession) {
        let store = AppStore(repository: .init(url: folder.appendingPathComponent("state.json")), provider: APIUnavailableLocal(), apiKeys: MemoryAPIKeys())
        let fake = PacketFakeSession()
        let coding = CodingWorkspaceStore(storage: .init(directory: folder.appendingPathComponent("Coding"), ownerID: "local-test"), sessionFactory: { _ in fake })
        return (store, coding, fake)
    }
    private func makePacket(to destination: ContextPacketDestination) -> ContextPacket {
        let levels: [(PrivacyLevel, String)] = [(.personal, "personal fact"), (.sensitive, "sensitive fact"), (.deviceOnly, "device fact"), (.secret, "secret fact")]
        let items = levels.map { level, text in
            let id = UUID().uuidString
            return ContextPacketItem(kind: ContextItemKind.memory.rawValue, sourceID: id, title: text, text: text, level: level,
                                     lineage: .init(source: "memory:" + id, origin: "your chat “Dinner plans”", capturedAt: Date()))
        }
        return .init(createdAt: Date(), purpose: "A coding task", origin: "your chat “Dinner plans”", items: items, destination: destination)
    }
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < end else { return XCTFail("Timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor private final class PacketFakeSession: AgentSession {
    var onEvent: ((CodingEvent, Bool) -> Void)?
    var onState: ((CodingTaskStatus) -> Void)?
    var onSession: ((String) -> Void)?
    var onApproval: ((CodingApproval?) -> Void)?
    var sent: [String] = []
    func send(_ text: String) throws { sent.append(text); onState?(.working) }
    func respond(_ id: String, allow: Bool, answers: String) throws {}
    func interrupt() {}
    func stop() {}
}

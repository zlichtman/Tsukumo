import XCTest
@testable import KemoSabe

@MainActor final class ConversationProjectsTests: XCTestCase {
    private var root: URL!
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }
    private func makeStore() -> AppStore {
        AppStore(repository: .init(url: root.appendingPathComponent("state.json")), provider: APIUnavailableLocal(), apiKeys: MemoryAPIKeys())
    }

    func testChatsFileIntoProjectsAndSurviveReload() throws {
        let store = makeStore()
        let trip = try XCTUnwrap(store.createProject("  Tahoe trip  "))
        XCTAssertEqual(trip.name, "Tahoe trip")
        XCTAssertNil(store.createProject("   "), "A project needs a name")
        // A new chat started in the project is filed there when it's saved.
        store.newConversation(in: trip.id)
        store.appendVisibleMessage(role: "You", text: "Find lodging near Northstar")
        store.newConversation()
        XCTAssertNil(store.state.currentProjectID, "A plain new chat isn't in a project")
        let filed = try XCTUnwrap(store.state.conversationArchives?.last)
        XCTAssertEqual(filed.projectID, trip.id)
        // Move it out and back in.
        store.move(filed.id, to: nil)
        XCTAssertNil(store.state.conversationArchives?.last?.projectID)
        store.move(filed.id, to: trip.id)
        store.move(filed.id, to: UUID())
        XCTAssertEqual(store.state.conversationArchives?.last?.projectID, trip.id, "Unknown projects are ignored")
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.projects.map(\.name), ["Tahoe trip"])
        XCTAssertEqual(reloaded.state.conversationArchives?.last?.projectID, trip.id)
    }
    func testContinuingKeepsTheProjectAndDeletingAProjectKeepsItsChats() throws {
        let store = makeStore()
        let work = try XCTUnwrap(store.createProject("Work"))
        store.appendVisibleMessage(role: "You", text: "Draft my standup")
        store.moveCurrentConversation(to: work.id)
        store.newConversation()
        let archive = try XCTUnwrap(store.state.conversationArchives?.last)
        store.resumeArchivedConversation(archive.id)
        XCTAssertEqual(store.state.currentProjectID, work.id)
        store.renameProject(work.id, to: "Job")
        XCTAssertEqual(store.projects.first?.name, "Job")
        store.newConversation()
        store.deleteProject(work.id)
        XCTAssertTrue(store.projects.isEmpty)
        XCTAssertEqual(store.state.conversationArchives?.count, 1, "Deleting a project never deletes chats")
        XCTAssertNil(store.state.conversationArchives?.first?.projectID)
    }
    func testOlderSavedStateWithoutProjectsStillLoads() throws {
        // A build 38 archive: every field it saved, and no project.
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","date":780000000,"model":"Apple on-device","messages":[{"id":"7F9619FF-8B86-D011-B42D-00C04FC964FF","role":"You","text":"hi","date":780000000}]}"#
        let archive = try JSONDecoder().decode(ConversationArchive.self, from: Data(json.utf8))
        XCTAssertNil(archive.projectID)
    }
}

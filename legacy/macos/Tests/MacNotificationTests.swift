import XCTest
@testable import KemoSabeMac

/// Tsukumo's notifications (the owner's request, September 25, 2026): the same switches as the
/// iPhone under the Mac's existing keys, and the notices left for the iPhone carry no message text.
@MainActor final class MacNotificationTests: XCTestCase {
    func testTheMacKeepsItsSwitchesAndDefaults() {
        XCTAssertEqual(NotificationKind.replies.key, "tsukumo.notifyReplies")
        XCTAssertEqual(NotificationKind.coding.key, "tsukumo.notifyTasks")
        XCTAssertFalse(NotificationKind.replies.defaultOn, "Replies stay off on the Mac until turned on, as before")
        XCTAssertTrue(NotificationKind.coding.defaultOn)
        XCTAssertTrue(NotificationKind.day.defaultOn)
        XCTAssertFalse(CodingTaskNotifications.enabled, "Never from a test host")
        XCTAssertEqual(SettingsCatalog.page("Notifications")?.devices, [.iPhone, .mac])
        XCTAssertNil(SettingsCatalog.page("Notifications")?.planned)
    }
    func testNoticesForTheIPhoneCarryNoTitleCommandOrQuestion() throws {
        let prompt = "Please rotate the production secrets in deploy.sh"
        let task = CodingTaskRecord(projectID: UUID(), ownerID: "local-test", title: prompt, provider: .claude, model: "", access: .edit,
                                    projectPath: "/Users/someone/Code/KemoSabe", directory: "/Users/someone/Code/KemoSabe", isolated: false)
        var approval = CodingApproval(id: "a1", title: "Run rm -rf build", detail: "rm -rf build")
        approval.command = "rm -rf build"
        let notices = [CodingTaskNotifications.notice(for: task, approval: approval),
                       CodingTaskNotifications.notice(for: task, state: .review),
                       CodingTaskNotifications.notice(for: task, state: .failed)]
        XCTAssertEqual(notices.map(\.kind), [.approval, .finished, .failed])
        XCTAssertEqual(notices[0].request, .command)
        for notice in notices {
            XCTAssertEqual(notice.agent, "Claude Code"); XCTAssertEqual(notice.project, "KemoSabe")
            let text = String(decoding: try JSONEncoder().encode(notice), as: UTF8.self)
            for secret in [prompt, "rm -rf", "deploy.sh", "/Users/someone"] { XCTAssertFalse(text.contains(secret), secret) }
        }
        approval.kind = .question
        XCTAssertEqual(CodingTaskNotifications.notice(for: task, approval: approval).request, .question)
    }
}

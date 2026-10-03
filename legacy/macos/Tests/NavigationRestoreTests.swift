import XCTest
@testable import KemoSabeMac

final class NavigationRestoreTests: XCTestCase {
    @MainActor func testNavigationRestoresAndRejectsUnknownDestinations() throws {
        let suite = "NavigationRestoreTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = DesktopNavigation(defaults: defaults)
        first.page = "Tsukumo"; first.settingsPage = "Appearance"; first.showSidebar = false
        let restored = DesktopNavigation(defaults: defaults)
        XCTAssertEqual(restored.page, "Tsukumo")
        XCTAssertEqual(restored.settingsPage, "Appearance")
        XCTAssertFalse(restored.showSidebar)
        restored.settingsPage = nil
        XCTAssertNil(DesktopNavigation(defaults: defaults).settingsPage)
        defaults.set("unknown", forKey: "desktop.lastPage")
        XCTAssertEqual(DesktopNavigation(defaults: defaults).page, "Chat")
    }
}

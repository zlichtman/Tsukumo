import XCTest
@testable import KemoSabeMac

final class DesktopCompanionTests: XCTestCase {
    func testDisconnectedMonitorPositionReturnsInsideRemainingScreen() {
        let screen = CGRect(x: 0, y: 30, width: 1440, height: 870)
        let result = CompanionPlacement.clamped(.init(x: -2000, y: -800, width: 230, height: 76), screens: [screen])
        XCTAssertTrue(screen.contains(result))
        XCTAssertEqual(result.size, .init(width: 230, height: 76))
    }
    func testCompanionStaysOnChosenMonitorWhenResized() {
        let first = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let second = CGRect(x: 1440, y: 30, width: 1920, height: 1050)
        let result = CompanionPlacement.clamped(.init(x: 3300, y: 1000, width: 250, height: 120), screens: [first, second])
        XCTAssertTrue(second.contains(result)); XCTAssertEqual(result.maxX, second.maxX)
    }
    @MainActor func testCompanionSettingsPersistAndInvalidSizesAreClamped() {
        let suite = "KemoCompanionTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(9000, forKey: "companion.size")
        let preferences = DesktopPreferences(defaults: defaults)
        XCTAssertEqual(preferences.size, 112)
        preferences.showName = false; preferences.size = 76; preferences.animate = false
        let restored = DesktopPreferences(defaults: defaults)
        XCTAssertFalse(restored.showName); XCTAssertFalse(restored.animate)
        XCTAssertEqual(restored.panelSize, .init(width: 84, height: 84))
    }
    @MainActor func testInterfaceThemePersistsWithSeparateLightDarkColors() {
        let suite = "KemoSettingsTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = DesktopPreferences(defaults: defaults)
        preferences.colorMode = .light; preferences.interfaceTheme = .forest
        preferences.translucentSidebar = false
        preferences.interfaceAccent = preferences.settingColor("112233", existing: preferences.interfaceAccent, scheme: .light)
        preferences.interfaceAccent = preferences.settingColor("AABBCC", existing: preferences.interfaceAccent, scheme: .dark)
        let restored = DesktopPreferences(defaults: defaults)
        XCTAssertEqual(restored.interfaceTheme, .forest)
        XCTAssertEqual(restored.colorMode, .light); XCTAssertFalse(restored.translucentSidebar)
        XCTAssertEqual(restored.interfaceAccent, "112233|AABBCC")
        XCTAssertNotNil(DesktopIconArtwork.bundledIcon(), "Tsukumo.icns must ship in the app bundle")
        restored.resetColors(for: .light); XCTAssertEqual(restored.interfaceAccent, "|AABBCC")
    }
}

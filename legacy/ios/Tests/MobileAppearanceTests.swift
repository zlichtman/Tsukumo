import XCTest
@testable import KemoSabe

final class MobileAppearanceTests: XCTestCase {
    @MainActor func testIndependentModesPersistWithoutChangingCharacterPalette() throws {
        let suite = "appearance-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let before = SavedState().theme
        let preferences = MobileAppearance(defaults: defaults)
        XCTAssertEqual(preferences.themes.count, 31, "29 stock families plus KemoSabe and Tsukumo")
        XCTAssertEqual(preferences.themes.values.reduce(0) { $0 + $1.count }, 48)
        preferences.lightTheme = "Everforest"; preferences.darkTheme = "Catppuccin"; preferences.mode = "Light"
        preferences.custom["light"] = .init(background: "FFFFFF", foreground: "111111", sidebar: "EEEEEE", accent: "123456")
        let restored = MobileAppearance(defaults: defaults)
        XCTAssertEqual(restored.colors(.light).accent, "123456")
        XCTAssertEqual(restored.colors(.dark).background, "1E1E2E")
        XCTAssertEqual(restored.lightTheme, "Everforest")
        XCTAssertEqual(restored.mode, "Light")
        XCTAssertEqual(SavedState().theme.id, before.id)
        XCTAssertEqual(SavedState().theme.body, before.body)
    }
    @MainActor func testBrandNamedThemesAreRenamedAndSavedChoicesCarryOver() throws {
        let suite = "appearance-rename-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("Codex", forKey: "app.appearance.light"); defaults.set("Vercel", forKey: "app.appearance.dark")
        let preferences = MobileAppearance(defaults: defaults)
        XCTAssertEqual(preferences.lightTheme, "Slate"); XCTAssertEqual(preferences.darkTheme, "Onyx")
        XCTAssertEqual(preferences.colors(.light).accent, "0169CC")
        for old in ThemeNames.renamed.keys { XCTAssertNil(preferences.themes[old], old) }
        XCTAssertNotNil(preferences.themes["Tsukumo"]?["dark"]); XCTAssertNotNil(preferences.themes["Tsukumo"]?["light"])
        // The theme grid is three across; keep every row full.
        XCTAssertEqual(preferences.names(.dark).count % 3, 0); XCTAssertEqual(preferences.names(.light).count % 3, 0)
    }
}

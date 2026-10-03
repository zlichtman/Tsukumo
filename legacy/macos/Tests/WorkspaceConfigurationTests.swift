import XCTest
@testable import KemoSabeMac

final class WorkspaceConfigurationTests: XCTestCase {
    @MainActor func testThemeImportIsAtomicAndDoesNotChangeCompanionOrPermissions() throws {
        let suite = "KemoConfigurationTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = DesktopPreferences(defaults: defaults)
        prefs.size = 92; prefs.characterOnly = true
        let before = prefs.interfaceAccent
        let invalid = DesktopThemeDocument(version: 1, mode: "Dark", preset: "Forest", accent: "script", background: "000000", foreground: "FFFFFF", contrast: 50)
        XCTAssertThrowsError(try prefs.importTheme(JSONEncoder().encode(invalid)))
        XCTAssertEqual(prefs.interfaceAccent, before); XCTAssertEqual(prefs.interfaceTheme, .kemoSabe)
        let valid = DesktopThemeDocument(version: 1, mode: "Light", preset: "Forest", accent: "123456", background: "FEFEFE", foreground: "123123", contrast: 70)
        try prefs.importTheme(JSONEncoder().encode(valid))
        XCTAssertEqual(prefs.colorMode, .light); XCTAssertEqual(prefs.interfaceAccent, "123456|")
        XCTAssertEqual(prefs.size, 92); XCTAssertTrue(prefs.characterOnly)
        let recovered = DesktopPreferences(defaults: defaults)
        XCTAssertEqual(recovered.themeDocument(scheme: .light), valid)
    }
    @MainActor func testBundledThemeCatalogAndIndependentModesSurviveRelaunch() throws {
        XCTAssertEqual(DesktopThemeCatalog.presets.count, 31, "29 stock families plus KemoSabe and Tsukumo")
        XCTAssertEqual(DesktopThemeCatalog.presets.values.reduce(0) { $0 + $1.count }, 48)
        // Every named theme has colors, no stock theme carries another company's name, and the
        // three-across gallery has full rows in both modes.
        let builtIn: Set<DesktopThemeName> = [.graphite, .lavender, .sand]
        for theme in DesktopThemeName.allCases where !builtIn.contains(theme) { XCTAssertNotNil(DesktopThemeCatalog.presets[theme.label], theme.label) }
        for old in ThemeNames.renamed.keys { XCTAssertNil(DesktopThemeCatalog.presets[old], old) }
        XCTAssertEqual(DesktopThemeName.codex.label, "Slate"); XCTAssertEqual(DesktopThemeName(rawValue: "Vercel")?.label, "Onyx")
        XCTAssertEqual(DesktopThemeName.available(.dark).count % 3, 0); XCTAssertEqual(DesktopThemeName.available(.light).count % 3, 0)
        for (_, modes) in DesktopThemeCatalog.presets {
            for (_, colors) in modes {
                for key in ["background", "sidebar", "accent", "foreground"] {
                    let hex = try XCTUnwrap(colors[key])
                    XCTAssertEqual(hex.count, 6)
                    XCTAssertTrue(hex.allSatisfy(\.isHexDigit))
                }
            }
        }
        let suite = "KemoThemes." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = DesktopPreferences(defaults: defaults)
        prefs.setTheme(.catppuccin, for: .dark); prefs.setTheme(.github, for: .light)
        prefs.interfaceAccent = "112233|AABBCC"
        prefs.resetColors(for: .dark)
        let restored = DesktopPreferences(defaults: defaults)
        XCTAssertEqual(restored.theme(for: .light), .github)
        XCTAssertEqual(restored.theme(for: .dark), .catppuccin)
        XCTAssertEqual(restored.colorHex(restored.interfaceAccent, scheme: .light), "112233")
        XCTAssertNil(restored.colorHex(restored.interfaceAccent, scheme: .dark))
    }
    func testExactAnimationNamesDoNotBecomeModelPrompts() {
        XCTAssertEqual(VoiceCommand.parse("coding animation"), .perform(.coding))
        XCTAssertEqual(VoiceCommand.parse("the debugging animation"), .perform(.debugging))
        XCTAssertNil(VoiceCommand.parse("explain the coding animation"))
        XCTAssertNil(VoiceCommand.parse("don't play the coding animation"))
    }
    func testCoordinationRejectsOtherProjectAndTraversal() throws {
        let example = WeaveSnapshot.example(project: "Kemo")
        let data = try JSONEncoder().encode(example)
        XCTAssertThrowsError(try WeaveSnapshot.decode(data, project: "Other"))
        XCTAssertEqual(try WeaveSnapshot.decode(data, project: "Kemo"), example)
        for path in ["../secret", "/private/file", "a/../b", "a//b", "a\\b"] { XCTAssertFalse(WeaveSnapshot.validPath(path)) }
    }
    func testCoordinationShowsUnreleasedOverlapAndAcknowledgmentSeparately() {
        let example = WeaveSnapshot.example(project: "Kemo")
        XCTAssertEqual(example.conflicts, ["src/auth/session.ts", "tests/auth.test.ts"])
        XCTAssertEqual(example.messages.filter(\.acknowledged).count, 1)
        XCTAssertEqual(example.owners("src/auth/session.ts").count, 2)
        // A message agreeing to release a scope does not itself release the claim.
        XCTAssertTrue(example.conflicts.contains("src/auth/session.ts"))
    }
    func testParentFileClaimsOverlapWithoutSubstringFalsePositives() {
        let snapshot = WeaveSnapshot(version: 1, project: "Kemo", revision: 2, agents: [
            .init(id: "one", provider: "A", task: "Scope", state: "Working", files: ["src/auth"]),
            .init(id: "two", provider: "B", task: "Scope", state: "Review", files: ["src/auth/session.ts"]),
            .init(id: "three", provider: "C", task: "Scope", state: "Working", files: ["src/author.ts"])
        ], messages: [])
        XCTAssertEqual(snapshot.owners("src/auth/session.ts").count, 2)
        XCTAssertEqual(snapshot.owners("src/author.ts").count, 1)
    }
}

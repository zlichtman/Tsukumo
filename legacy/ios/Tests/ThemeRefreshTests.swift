import XCTest
@testable import KemoSabe

final class ThemeRefreshTests: XCTestCase {
    private let oldGreens: [BotTheme] = [
        .init(id: "matcha", name: "Matcha", body: "DCE7BD", accent: "527453", background: "172820"),
        .init(id: "pistachio", name: "Pistachio", body: "D8E5CD", accent: "658666", background: "1E2923"),
        .init(id: "moss", name: "Moss", body: "BBCDB0", accent: "526848", background: "1C241B")
    ]
    private func rgb(_ hex: String) -> [Double] {
        let value = UInt32(hex, radix: 16)!
        return [Double((value >> 16) & 255)/255, Double((value >> 8) & 255)/255, Double(value & 255)/255]
    }
    private func luminance(_ hex: String) -> Double {
        let values = rgb(hex).map { $0 <= 0.04045 ? $0/12.92 : pow(($0+0.055)/1.055, 2.4) }
        return values[0]*0.2126 + values[1]*0.7152 + values[2]*0.0722
    }
    private func contrast(_ a: String, _ b: String) -> Double {
        (max(luminance(a), luminance(b))+0.05)/(min(luminance(a), luminance(b))+0.05)
    }
    func testGreensDoNotRegressToNearlyIdenticalSwatches() {
        let greens = BotTheme.presets.filter { ["matcha", "pistachio", "moss"].contains($0.id) }
        XCTAssertEqual(greens.count, 3)
        // A coarse swatch guard, not a substitute for inspecting the lit character.
        for i in 0..<greens.count {
            for j in (i+1)..<greens.count {
                let distance = sqrt(zip(rgb(greens[i].body), rgb(greens[j].body)).reduce(0) { $0 + pow($1.0-$1.1, 2) })
                XCTAssertGreaterThan(distance, 0.22)
            }
        }
    }
    func testNewPalettesKeepTextAndFaceContrast() {
        let updated = ["matcha", "pistachio", "moss", "ember", "lagoon", "mulberry", "ink", "paper"]
        for id in updated {
            let theme = BotTheme.presets.first { $0.id == id }!
            XCTAssertGreaterThanOrEqual(contrast(theme.body, theme.background), 4.5, id + " UI foreground")
            XCTAssertGreaterThanOrEqual(contrast(theme.body, theme.accent), 3, id + " painted face")
        }
    }
    func testOldStockSelectionsRefreshWithoutChangingIDs() throws {
        let repository = LocalRepository(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("state.json"))
        for old in oldGreens {
            var state = SavedState(); state.theme = old; state.memories = [.init(text: "Keep this note")]
            try repository.save(state)
            let restored = try repository.read()
            XCTAssertEqual(restored.theme.id, old.id)
            XCTAssertEqual(restored.theme, BotTheme.presets.first { $0.id == old.id })
            XCTAssertNotEqual(restored.theme.body, old.body)
            XCTAssertEqual(restored.memories, state.memories)
        }
    }
    func testCustomAndEditedPalettesAreNeverOverwritten() throws {
        let repository = LocalRepository(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("state.json"))
        var custom = oldGreens[0]; custom.id = "custom-matcha"
        var edited = oldGreens[1]; edited.accent = "ABCDEF"
        var renamed = oldGreens[2]; renamed.name = "My green"
        let blueberry = BotTheme.presets.first { $0.id == "blueberry" }!
        var customBlueberry = blueberry; customBlueberry.id = "custom-blueberry"
        for theme in [custom, edited, renamed, BotTheme.presets[0], blueberry, customBlueberry] {
            var state = SavedState(); state.theme = theme; state.customThemes = [custom, edited, renamed, customBlueberry]
            try repository.save(state)
            let restored = try repository.read()
            XCTAssertEqual(restored.theme, theme)
            XCTAssertEqual(restored.customThemes, state.customThemes)
        }
    }
}

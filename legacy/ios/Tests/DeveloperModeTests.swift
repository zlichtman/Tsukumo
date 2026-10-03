import XCTest
@testable import KemoSabe

@MainActor final class DeveloperModeTests: XCTestCase {
    private func freshMode() -> DeveloperMode {
        let suite = "kemo.developer.tests." + UUID().uuidString
        return DeveloperMode(defaults: UserDefaults(suiteName: suite)!)
    }
    func testSevenQuickTapsUnlock() {
        let mode = freshMode()
        guard !mode.enabled else { return } // --developer launch argument
        let start = Date()
        var notes: [String?] = []
        for i in 0..<7 { notes.append(mode.tapVersion(now: start.addingTimeInterval(Double(i) * 0.5))) }
        XCTAssertTrue(mode.enabled)
        XCTAssertNil(notes[0], "The first taps stay quiet")
        XCTAssertEqual(notes[3], "3 more taps for developer settings.")
        XCTAssertEqual(notes[5], "1 more tap for developer settings.")
        XCTAssertEqual(notes[6], "Developer settings unlocked. Find them at the bottom of Companion.")
    }
    func testSlowTapsStartOver() {
        let mode = freshMode()
        guard !mode.enabled else { return }
        let start = Date()
        for i in 0..<6 { _ = mode.tapVersion(now: start.addingTimeInterval(Double(i) * 0.5)) }
        _ = mode.tapVersion(now: start.addingTimeInterval(10))
        XCTAssertFalse(mode.enabled)
        XCTAssertEqual(mode.taps, 1)
    }
    func testChoiceIsStoredPerDevice() {
        let defaults = UserDefaults(suiteName: "kemo.developer.tests." + UUID().uuidString)!
        let mode = DeveloperMode(defaults: defaults)
        mode.enabled = true
        XCTAssertTrue(defaults.bool(forKey: "kemo.developer.enabled"))
        mode.enabled = false
        XCTAssertFalse(DeveloperMode(defaults: defaults).enabled)
    }
}

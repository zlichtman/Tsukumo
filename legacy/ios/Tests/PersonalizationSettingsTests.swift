import XCTest
#if os(macOS)
@testable import KemoSabeMac
#else
@testable import KemoSabe
#endif

/// Settings → Personalization (the owner's instruction, September 26, 2026): times in the locale's
/// format, the longest-block choices, and the standing-permission line shown only when it's true.
@MainActor final class PersonalizationSettingsTests: XCTestCase {
    private let destination = RoutineDestination(id: "cal", sourceID: "icloud", name: "Home", sourceName: "iCloud", reminders: false, maySync: true)
    private func grant(_ earliest: Int, _ latest: Int, _ maximum: Int) -> StandingGrant {
        .init(id: UUID(), destination: destination, operations: [.createBlock], earliestHour: earliest, latestHour: latest, maximumMinutes: maximum,
              expiresAt: Date(timeIntervalSince1970: 1_793_000_000))
    }
    func testHoursUseTheLocalesTimeFormat() {
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(PersonalRoutineSettings.hour(9, timeZone: utc, locale: Locale(identifier: "en_US")).replacingOccurrences(of: "\u{202F}", with: " "), "9:00 AM")
        XCTAssertEqual(PersonalRoutineSettings.hour(18, timeZone: utc, locale: Locale(identifier: "de_DE")), "18:00")
        XCTAssertEqual(PersonalRoutineSettings.hour(24, timeZone: utc, locale: Locale(identifier: "de_DE")),
                       PersonalRoutineSettings.hour(0, timeZone: utc, locale: Locale(identifier: "de_DE")), "The end of the day is midnight")
    }
    func testLongestBlockChoicesReadAsDurations() {
        XCTAssertEqual(PersonalRoutineSettings.blockChoices.map(PersonalRoutineSettings.duration), ["30 min", "1 h", "1.5 h", "2 h", "3 h"])
        XCTAssertEqual(PersonalRoutineSettings.stored(1), "1 choice stored")
        XCTAssertEqual(PersonalRoutineSettings.stored(12), "12 choices stored")
    }
    func testTheStandingPermissionLineShowsOnlyWhenLimitsDiffer() {
        XCTAssertNil(PersonalRoutineSettings.standingNote(grants: [], earliest: 9, latest: 18, maximum: 120), "No permission, nothing to say")
        XCTAssertNil(PersonalRoutineSettings.standingNote(grants: [grant(9, 18, 120)], earliest: 9, latest: 18, maximum: 120), "Same limits")
        for (e, l, m) in [(8, 18, 120), (9, 17, 120), (9, 18, 60)] {
            XCTAssertNotNil(PersonalRoutineSettings.standingNote(grants: [grant(9, 18, 120)], earliest: e, latest: l, maximum: m))
        }
    }
    func testAGrantSummarizesItsOwnLimits() {
        let summary = PersonalRoutineSettings.grantSummary(grant(9, 18, 90), timeZone: TimeZone(identifier: "UTC")!, locale: Locale(identifier: "en_GB"))
        XCTAssertTrue(summary.hasSuffix("9:00–18:00 · up to 1.5 h · until 26 Oct 2026"), summary)
    }
}

import XCTest
#if os(macOS)
@testable import KemoSabeMac
#else
@testable import KemoSabe
#endif

/// Flipping through days in Day (the owner's instruction, September 26, 2026): what a day covers
/// in each time zone, across daylight saving changes, and which events, reminders, and Kemo items
/// belong to it.
final class DayRangeTests: XCTestCase {
    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: zone)!; return calendar
    }
    private func date(_ text: String, _ zone: String) -> Date {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: zone); formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    func testADayIsMidnightToMidnightAcrossDaylightSaving() {
        let newYork = calendar("America/New_York")
        // Clocks go back on November 1, 2026: that day has 25 hours.
        let fallBack = DayRange.interval(for: date("2026-11-01 15:00", "America/New_York"), calendar: newYork)
        XCTAssertEqual(fallBack.start, date("2026-11-01 00:00", "America/New_York"))
        XCTAssertEqual(fallBack.end, date("2026-11-02 00:00", "America/New_York"))
        XCTAssertEqual(fallBack.duration, 25 * 3600)
        // Clocks go forward on March 8, 2026: 23 hours.
        let springForward = DayRange.interval(for: date("2026-03-08 12:00", "America/New_York"), calendar: newYork)
        XCTAssertEqual(springForward.duration, 23 * 3600)
        // An ordinary day.
        XCTAssertEqual(DayRange.interval(for: date("2026-09-26 08:00", "America/New_York"), calendar: newYork).duration, 24 * 3600)
    }
    func testMovingByDaysKeepsMidnightAcrossDaylightSaving() {
        let newYork = calendar("America/New_York")
        let saturday = date("2026-10-31 18:30", "America/New_York")
        XCTAssertEqual(DayRange.shift(saturday, by: 1, calendar: newYork), date("2026-11-01 00:00", "America/New_York"))
        XCTAssertEqual(DayRange.shift(saturday, by: 2, calendar: newYork), date("2026-11-02 00:00", "America/New_York"), "Not 23:00 after the 25-hour day")
        XCTAssertEqual(DayRange.shift(date("2026-03-09 09:00", "America/New_York"), by: -1, calendar: newYork), date("2026-03-08 00:00", "America/New_York"))
        let start = date("2026-09-26 00:00", "America/New_York")
        XCTAssertEqual(DayRange.shift(DayRange.shift(start, by: 40, calendar: newYork), by: -40, calendar: newYork), start, "Forward and back returns to the same day")
    }
    func testTheSameMomentIsADifferentDayInAnotherTimeZone() {
        let moment = date("2026-09-26 23:30", "America/Los_Angeles") // 06:30 on the 27th in UTC, 15:30 in Tokyo
        XCTAssertEqual(DayRange.start(of: moment, calendar: calendar("America/Los_Angeles")), date("2026-09-26 00:00", "America/Los_Angeles"))
        XCTAssertEqual(DayRange.start(of: moment, calendar: calendar("UTC")), date("2026-09-27 00:00", "UTC"))
        XCTAssertEqual(DayRange.start(of: moment, calendar: calendar("Asia/Tokyo")), date("2026-09-27 00:00", "Asia/Tokyo"))
        let now = date("2026-09-27 10:00", "Asia/Tokyo")
        XCTAssertEqual(DayRange.relation(of: moment, now: now, calendar: calendar("Asia/Tokyo")), .today)
        XCTAssertEqual(DayRange.relation(of: moment, now: now, calendar: calendar("America/Los_Angeles")), .today)
        XCTAssertEqual(DayRange.relation(of: DayRange.shift(now, by: -1, calendar: calendar("UTC")), now: now, calendar: calendar("UTC")), .past)
        XCTAssertEqual(DayRange.relation(of: DayRange.shift(now, by: 1, calendar: calendar("UTC")), now: now, calendar: calendar("UTC")), .future)
    }
    func testEventsBelongToEachDayTheyTouch() {
        let zone = "Europe/Berlin", berlin = calendar(zone)
        let friday = DayRange.interval(for: date("2026-09-25 12:00", zone), calendar: berlin)
        let saturday = DayRange.interval(for: date("2026-09-26 12:00", zone), calendar: berlin)
        // Across midnight: on both days.
        let (lateStart, lateEnd) = (date("2026-09-25 23:30", zone), date("2026-09-26 00:30", zone))
        XCTAssertTrue(DayRange.overlaps(start: lateStart, end: lateEnd, day: friday))
        XCTAssertTrue(DayRange.overlaps(start: lateStart, end: lateEnd, day: saturday))
        // Ending exactly at midnight: not on the next day. An all-day event covers only its day.
        XCTAssertFalse(DayRange.overlaps(start: date("2026-09-25 22:00", zone), end: date("2026-09-26 00:00", zone), day: saturday))
        XCTAssertTrue(DayRange.overlaps(start: date("2026-09-25 00:00", zone), end: date("2026-09-26 00:00", zone), day: friday))
        XCTAssertFalse(DayRange.overlaps(start: date("2026-09-25 00:00", zone), end: date("2026-09-26 00:00", zone), day: saturday))
        // No length: the day it starts on.
        XCTAssertTrue(DayRange.overlaps(start: saturday.start, end: saturday.start, day: saturday))
        XCTAssertFalse(DayRange.overlaps(start: saturday.start, end: saturday.start, day: friday))
    }
    func testAnAllDayReminderIsDueOnItsDateWhereverYouAre() throws {
        var components = DateComponents(); components.year = 2026; components.month = 11; components.day = 1
        for zone in ["America/New_York", "Asia/Tokyo", "Pacific/Kiritimati"] {
            let due = try XCTUnwrap(DayRange.due(components, calendar: calendar(zone)))
            XCTAssertTrue(due.allDay)
            XCTAssertEqual(due.date, date("2026-11-01 00:00", zone), zone)
        }
        // With a time and its own zone it's that exact moment, which is another local day elsewhere.
        components.hour = 9; components.minute = 15; components.timeZone = TimeZone(identifier: "Asia/Tokyo")
        let timed = try XCTUnwrap(DayRange.due(components, calendar: calendar("America/Los_Angeles")))
        XCTAssertFalse(timed.allDay)
        XCTAssertEqual(timed.date, date("2026-11-01 09:15", "Asia/Tokyo"))
        let losAngeles = DayRange.interval(for: date("2026-10-31 12:00", "America/Los_Angeles"), calendar: calendar("America/Los_Angeles"))
        XCTAssertTrue(losAngeles.contains(timed.date), "9:15 in Tokyo is still October 31 in Los Angeles")
        // Without a zone, the time is read in the calendar's zone.
        components.timeZone = nil
        XCTAssertEqual(DayRange.due(components, calendar: calendar("America/Los_Angeles"))?.date, date("2026-11-01 09:15", "America/Los_Angeles"))
        XCTAssertNil(DayRange.due(DateComponents(), calendar: calendar("UTC")), "No date, not due")
    }
    func testKemoItemsLandOnTheDayOfTheirTime() {
        let zone = "America/New_York", newYork = calendar(zone)
        func proposal(_ title: String, at time: Date?) -> RoutineProposal {
            .init(key: title, kind: .alarm, title: title, body: "", scheduledAt: time, createdAt: date("2026-09-20 08:00", zone), expiresAt: .distantFuture)
        }
        let items = [proposal("Late", at: date("2026-11-01 23:59", zone)), proposal("Early", at: date("2026-11-01 00:00", zone)),
                     proposal("Next", at: date("2026-11-02 00:00", zone)), proposal("Undated", at: nil),
                     proposal("Extra hour", at: date("2026-11-01 01:30", zone).addingTimeInterval(3600))]
        let day = DayRange.proposals(items, on: date("2026-11-01 12:00", zone), calendar: newYork)
        XCTAssertEqual(day.map(\.title), ["Early", "Extra hour", "Late"], "In time order; the repeated 1 o'clock hour is still November 1")
        XCTAssertEqual(DayRange.proposals(items, on: date("2026-11-02 12:00", zone), calendar: newYork).map(\.title), ["Next"])
    }
    func testHeadings() {
        let utc = calendar("UTC"), now = date("2026-09-26 10:00", "UTC")
        XCTAssertEqual(DayRange.heading(now, now: now, calendar: utc), "Your day")
        XCTAssertEqual(DayRange.heading(DayRange.shift(now, by: 1, calendar: utc), now: now, calendar: utc), "Tomorrow")
        XCTAssertEqual(DayRange.heading(DayRange.shift(now, by: -1, calendar: utc), now: now, calendar: utc), "Yesterday")
    }
}

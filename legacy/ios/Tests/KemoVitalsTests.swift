import XCTest

/// Kemo as a pet on the watch (`ios/KemoSabeWatch/KemoVitals.swift`, compiled into this target):
/// decay from timestamps, feeding, clamping, moods, and the nudge rules.
final class KemoVitalsTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    func testDecayCountsWakingHoursFullyAndSleepAtAQuarter() {
        XCTAssertEqual(KemoVitals.decayHours(from: date(25, 10), to: date(25, 16), calendar: calendar), 6, accuracy: 1e-9)
        // 21:00 to 09:00: one waking hour, ten sleeping hours at a quarter, one waking hour.
        XCTAssertEqual(KemoVitals.decayHours(from: date(25, 21), to: date(26, 9), calendar: calendar), 1 + 2.5 + 1, accuracy: 1e-9)
        XCTAssertEqual(KemoVitals.decayHours(from: date(25, 16), to: date(25, 10), calendar: calendar), 0)
        // Only the last week counts, however long Kemo was left.
        XCTAssertEqual(KemoVitals.decayHours(from: date(1, 10), to: date(25, 10), calendar: calendar), 7 * (14 + 2.5), accuracy: 1e-9)
    }

    func testMetersDecayFromTimestampsAndClamp() {
        let fed = KemoVitals(fullness: 1, cheer: 1, updated: date(25, 9), lastFed: date(25, 9))
        let noon = fed.at(date(25, 15), calendar: calendar)
        XCTAssertEqual(noon.fullness, 1 - 6.0 / 12, accuracy: 1e-9)
        XCTAssertEqual(noon.cheer, 1 - 6.0 / 18, accuracy: 1e-9)
        XCTAssertEqual(noon.updated, date(25, 15))
        // Decaying in two steps gives the same answer as one.
        XCTAssertEqual(fed.at(date(25, 12), calendar: calendar).at(date(25, 15), calendar: calendar).fullness, noon.fullness, accuracy: 1e-9)
        let gone = fed.at(date(28, 15), calendar: calendar)
        XCTAssertEqual(gone.fullness, 0); XCTAssertEqual(gone.cheer, 0)
        // A clock that went backwards changes nothing.
        XCTAssertEqual(fed.at(date(25, 8), calendar: calendar), fed)
    }

    func testTalkingFeedsKemoAndAHelloIsASnack() {
        XCTAssertEqual(KemoVitals.Food(heard: "Hi Kemo!"), .snack)
        XCTAssertEqual(KemoVitals.Food(heard: "hello"), .snack)
        XCTAssertEqual(KemoVitals.Food(heard: "What's on my calendar this afternoon?"), .meal)
        XCTAssertEqual(KemoVitals.Food(heard: ""), .meal, "A spoken question whose words didn't come back is still a chat")

        let hungry = KemoVitals(fullness: 0.1, cheer: 0.5, updated: date(25, 10), lastFed: nil)
        let meal = hungry.fed(.meal, at: date(25, 13), calendar: calendar)
        XCTAssertEqual(meal.fullness, 0 + 0.4, accuracy: 1e-9, "Decays to empty first, then the meal")
        XCTAssertEqual(meal.cheer, 0.5 - 3.0 / 18 + 0.25, accuracy: 1e-9)
        XCTAssertEqual(meal.lastFed, date(25, 13)); XCTAssertEqual(meal.updated, date(25, 13))
        let snack = hungry.fed(.snack, at: date(25, 10), calendar: calendar)
        XCTAssertEqual(snack.fullness, 0.2, accuracy: 1e-9)
        XCTAssertEqual(snack.cheer, 0.65, accuracy: 1e-9)
        // Never over full.
        var full = KemoVitals(fullness: 0.9, cheer: 0.95, updated: date(25, 10), lastFed: nil)
        for _ in 0..<5 { full = full.fed(.meal, at: date(25, 10), calendar: calendar) }
        XCTAssertEqual(full.fullness, 1); XCTAssertEqual(full.cheer, 1)
    }

    func testChatsEarnXPAndLevelsTakeLonger() {
        var kemo = KemoVitals.newborn(at: date(25, 9))
        XCTAssertEqual(kemo.level, 1)
        kemo = kemo.fed(.meal, at: date(25, 10), calendar: calendar)
        kemo = kemo.fed(.snack, at: date(25, 11), calendar: calendar)
        XCTAssertEqual(kemo.xp, 13); XCTAssertEqual(kemo.level, 1)
        kemo = kemo.fed(.meal, at: date(25, 12), calendar: calendar)
        XCTAssertEqual(kemo.level, 2, "15 XP reaches level 2")
        XCTAssertEqual(KemoVitals.xpToReach(3), 60)
        XCTAssertGreaterThan(kemo.levelProgress, 0); XCTAssertLessThan(kemo.levelProgress, 1)
    }
    func testAStreakCountsDaysInARowAndBreaksAfterAMissedDay() {
        var kemo = KemoVitals.newborn(at: date(20, 9))
        XCTAssertEqual(kemo.streak(at: date(20, 9), calendar: calendar), 0)
        kemo = kemo.fed(.meal, at: date(20, 10), calendar: calendar)
        kemo = kemo.fed(.snack, at: date(20, 18), calendar: calendar)
        XCTAssertEqual(kemo.streak(at: date(20, 19), calendar: calendar), 1, "Two chats in one day count once")
        kemo = kemo.fed(.meal, at: date(21, 9), calendar: calendar)
        XCTAssertEqual(kemo.streak(at: date(21, 9), calendar: calendar), 2)
        XCTAssertEqual(kemo.streak(at: date(22, 20), calendar: calendar), 2, "Still alive the next day")
        XCTAssertEqual(kemo.streak(at: date(23, 9), calendar: calendar), 0, "A missed day breaks it")
        kemo = kemo.fed(.meal, at: date(23, 9), calendar: calendar)
        XCTAssertEqual(kemo.streak(at: date(23, 9), calendar: calendar), 1)
    }
    func testOlderSavesWithoutTheGameStillLoad() throws {
        let old = #"{"fullness":0.5,"cheer":0.5,"updated":800000000}"#
        let kemo = try JSONDecoder().decode(KemoVitals.self, from: Data(old.utf8))
        XCTAssertEqual(kemo.level, 1); XCTAssertNil(kemo.xp)
    }
    func testMoodFollowsTheMetersAndTheNight() {
        func mood(_ fullness: Double, _ cheer: Double, at hour: Int, fedAt: Date? = nil) -> KemoVitals.Mood {
            KemoVitals(fullness: fullness, cheer: cheer, updated: date(25, hour), lastFed: fedAt).mood(at: date(25, hour), calendar: calendar)
        }
        XCTAssertEqual(mood(0.9, 0.9, at: 12), .happy)
        XCTAssertEqual(mood(0.5, 0.5, at: 12), .content)
        XCTAssertEqual(mood(0.2, 0.9, at: 12), .hungry)
        XCTAssertEqual(mood(0.2, 0.1, at: 12), .hungry, "Hunger comes first")
        XCTAssertEqual(mood(0.8, 0.1, at: 12), .lonely)
        XCTAssertEqual(mood(0.1, 0.1, at: 23), .sleepy, "At night Kemo sleeps, hungry or not")
        XCTAssertEqual(mood(0.1, 0.1, at: 7), .sleepy)
        XCTAssertEqual(mood(0.9, 0.9, at: 23, fedAt: date(25, 22, 55)), .happy, "It stays up a little after a late chat")
        // Left alone from a full breakfast, Kemo is hungry by the evening.
        let breakfast = KemoVitals(fullness: 1, cheer: 1, updated: date(25, 8), lastFed: date(25, 8))
        XCTAssertEqual(breakfast.mood(at: date(25, 9), calendar: calendar), .happy)
        XCTAssertEqual(breakfast.mood(at: date(25, 17), calendar: calendar), .hungry)
    }

    func testStarvedCountsEachTimeFoodRanOut() {
        let empty = KemoVitals(fullness: 0, cheer: 0.5, updated: date(25, 10), lastFed: nil)
        let fed = empty.fed(.meal, at: date(25, 11), calendar: calendar)
        XCTAssertEqual(fed.starved, 1)
        XCTAssertEqual(fed.fed(.snack, at: date(25, 12), calendar: calendar).starved, 1, "Not while Kemo still has food")
        let fine = KemoVitals(fullness: 0.9, cheer: 0.9, updated: date(25, 10), lastFed: nil)
        XCTAssertNil(fine.fed(.meal, at: date(25, 11), calendar: calendar).starved)
    }

    func testNudgesNeedToBeTurnedOn() {
        let hungry = KemoVitals(fullness: 0.1, cheer: 0.1, updated: date(25, 10), lastFed: nil)
        XCTAssertEqual(KemoNudge.plan(for: hungry, now: date(25, 10), delivered: [], enabled: false, calendar: calendar), [])
        XCTAssertFalse(KemoNudge.plan(for: hungry, now: date(25, 10), delivered: [], enabled: true, calendar: calendar).isEmpty)
    }

    func testNudgesWaitAfterUseAndKeepAGap() {
        let hungry = KemoVitals(fullness: 0.1, cheer: 0.8, updated: date(25, 10), lastFed: nil)
        let plan = KemoNudge.plan(for: hungry, now: date(25, 10), delivered: [], enabled: true, calendar: calendar)
        XCTAssertEqual(plan.first, KemoNudge(kind: .hungry, date: date(25, 11)), "Not while the app was just in use")
        XCTAssertEqual(plan.map(\.date), [date(25, 11), date(25, 15), date(26, 8)])
        for (earlier, later) in zip(plan, plan.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later.date.timeIntervalSince(earlier.date), KemoNudge.minimumGap)
        }
        // A nudge shown at 9:30 pushes the next one to 13:30.
        let after = KemoNudge.plan(for: hungry, now: date(25, 10), delivered: [date(25, 9, 30)], enabled: true, calendar: calendar)
        XCTAssertEqual(after.first?.date, date(25, 13, 30))
    }

    func testAtMostTwoADayAndNeverAtNight() {
        let hungry = KemoVitals(fullness: 0, cheer: 0, updated: date(25, 6), lastFed: nil)
        let plan = KemoNudge.plan(for: hungry, now: date(25, 6), delivered: [], enabled: true, limit: 10, calendar: calendar)
        XCTAssertFalse(plan.isEmpty)
        for nudge in plan {
            let hour = calendar.component(.hour, from: nudge.date)
            XCTAssertTrue((8..<22).contains(hour), "No nudge at \(hour):00")
        }
        let perDay = Dictionary(grouping: plan) { calendar.startOfDay(for: $0.date) }
        XCTAssertTrue(perDay.values.allSatisfy { $0.count <= KemoNudge.maxPerDay })
        // Planned up to 48 hours ahead, at most two a day: 25th, 26th, and the 27th until 6:00 (asleep).
        XCTAssertEqual(plan.count, 4)
        XCTAssertEqual(plan.first?.date, date(25, 8), "Kemo wakes at 8:00, and asks then")
        // Two already shown today: nothing more until tomorrow morning.
        let shown = [date(25, 9), date(25, 13, 15)]
        let later = KemoNudge.plan(for: hungry, now: date(25, 18), delivered: shown, enabled: true, calendar: calendar)
        XCTAssertEqual(later.first?.date, date(26, 8))
    }

    func testAHappyKemoWaitsUntilItIsActuallyHungryOrLonely() {
        // Fed to the brim at 9:00: fullness crosses 0.3 after 8.4 waking hours, at 17:24.
        let fed = KemoVitals(fullness: 1, cheer: 1, updated: date(25, 9), lastFed: date(25, 9))
        let plan = KemoNudge.plan(for: fed, now: date(25, 9), delivered: [], enabled: true, calendar: calendar)
        XCTAssertEqual(plan.first?.kind, .hungry)
        XCTAssertEqual(plan.first?.date, date(25, 17, 30), "The first 15-minute step after it gets hungry")
        // Lonely but well fed: a lonely nudge.
        let lonely = KemoVitals(fullness: 1, cheer: 0.2, updated: date(25, 9), lastFed: nil)
        XCTAssertEqual(KemoNudge.plan(for: lonely, now: date(25, 9), delivered: [], enabled: true, calendar: calendar).first?.kind, .lonely)
        XCTAssertEqual(KemoNudge(kind: .hungry, date: .now).title(name: "Mochi"), "Mochi's hungry")
        XCTAssertEqual(KemoNudge(kind: .lonely, date: .now).title(name: "Mochi"), "Mochi misses you")
    }

    func testVitalsRoundTripForTheComplication() throws {
        let vitals = KemoVitals(fullness: 0.42, cheer: 0.7, updated: date(25, 12), lastFed: date(25, 11))
        XCTAssertEqual(try JSONDecoder().decode(KemoVitals.self, from: JSONEncoder().encode(vitals)), vitals)
        XCTAssertEqual(KemoVitals.newborn(at: date(25, 12)).mood(at: date(25, 12), calendar: calendar), .happy)
    }
}

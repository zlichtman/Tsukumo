import Foundation

/// Kemo as a pocket pet on the wrist (the owner's Tamagotchi instruction, September 25, 2026):
/// talking to Kemo feeds it, and it slowly gets hungry and lonely when left alone.
///
/// Pure and deterministic: the meters are stored as of `updated` and decay is computed from
/// timestamps, never from timers, so any `now` gives the same answer. Kemo sleeps at night
/// (22:00–8:00), when it gets hungry four times more slowly. This is pet state, not personal
/// data: two numbers and two dates, with no words from any conversation.
/// Compiled into the watch app, its complication, and the iOS unit tests.
struct KemoVitals: Codable, Equatable, Sendable {
    /// 0 is starving, 1 is full, as of `updated`.
    var fullness: Double
    /// 0 is lonely, 1 is delighted, as of `updated`.
    var cheer: Double
    var updated: Date
    /// When the person last talked with Kemo, if ever.
    var lastFed: Date?
    /// Experience from every chat (a meal 10, a snack 3); it only grows. Optional so older saves load.
    var xp: Int? = nil
    /// Days in a row with at least one chat, as of `streakDay` (the start of that day).
    var streak: Int? = nil
    var streakDay: Date? = nil
    /// Times the food meter ran empty before the next chat (Kemo's "death count"; it never dies).
    var starved: Int? = nil

    /// Kemo on the first launch: comfortably fed and glad to meet you.
    static func newborn(at now: Date) -> KemoVitals { KemoVitals(fullness: 0.8, cheer: 0.8, updated: now, lastFed: nil) }

    /// What talking gave Kemo. A finished question and answer is a meal; a quick hello is a snack.
    enum Food: Equatable, Sendable {
        case snack, meal
        /// A hello of three words or fewer ("hi Kemo") is a snack; anything more is a meal.
        init(heard: String) {
            let words = heard.split { $0.isWhitespace || $0.isPunctuation }.count
            self = words > 0 && words <= 3 ? .snack : .meal
        }
        var fullness: Double { self == .meal ? 0.4 : 0.1 }
        var cheer: Double { self == .meal ? 0.25 : 0.15 }
        var xp: Int { self == .meal ? 10 : 3 }
    }

    enum Mood: String, Codable, CaseIterable, Sendable {
        case happy, content, hungry, lonely, sleepy
        /// One word, for the complication and accessibility.
        var word: String {
            switch self {
            case .happy: "Happy"
            case .content: "Content"
            case .hungry: "Hungry"
            case .lonely: "Lonely"
            case .sleepy: "Asleep"
            }
        }
        /// A small SF Symbol beside the word; nil when nothing needs saying.
        var symbol: String? {
            switch self {
            case .happy: "heart.fill"
            case .content: nil
            case .hungry: "fork.knife"
            case .lonely: "hand.wave.fill"
            case .sleepy: "moon.zzz.fill"
            }
        }
    }

    // MARK: Rules

    /// Full to empty in 12 waking hours.
    static let fullnessPerHour = 1.0 / 12
    /// Delighted to lonely in 18 waking hours.
    static let cheerPerHour = 1.0 / 18
    /// Asleep, Kemo uses a quarter of the energy.
    static let nightRate = 0.25
    /// Kemo sleeps from 22:00 to 8:00, and never nudges then.
    static let bedtimeHour = 22, wakeHour = 8
    static let hungryBelow = 0.3, lonelyBelow = 0.3
    /// Just after a chat at night, Kemo stays up a little before it falls back asleep.
    static let stayUpAfterTalking: TimeInterval = 10 * 60

    // MARK: Time

    /// The meters as they are at `now`. Earlier times return the stored meters unchanged.
    func at(_ now: Date, calendar: Calendar = .current) -> KemoVitals {
        guard now > updated else { return self }
        let hours = Self.decayHours(from: updated, to: now, calendar: calendar)
        var next = self
        next.fullness = Self.clamp(fullness - hours * Self.fullnessPerHour)
        next.cheer = Self.clamp(cheer - hours * Self.cheerPerHour)
        next.updated = now
        return next
    }
    /// Kemo after talking at `now`.
    func fed(_ food: Food, at now: Date, calendar: Calendar = .current) -> KemoVitals {
        var next = at(now, calendar: calendar)
        if next.fullness <= 0 { next.starved = (starved ?? 0) + 1 }
        next.fullness = Self.clamp(next.fullness + food.fullness)
        next.cheer = Self.clamp(next.cheer + food.cheer)
        next.updated = max(now, updated)
        next.lastFed = now
        next.xp = (xp ?? 0) + food.xp
        let today = calendar.startOfDay(for: now)
        if let day = streakDay, calendar.isDate(day, inSameDayAs: today) { next.streak = max(1, streak ?? 1) }
        else if let day = streakDay, let yesterday = calendar.date(byAdding: .day, value: -1, to: today), calendar.isDate(day, inSameDayAs: yesterday) { next.streak = (streak ?? 0) + 1 }
        else { next.streak = 1 }
        next.streakDay = today
        return next
    }

    // MARK: Game

    /// Level from experience: each level takes a little longer (15 × level² XP to reach the next).
    var level: Int { Self.level(for: xp ?? 0) }
    static func level(for xp: Int) -> Int { 1 + Int((Double(max(0, xp)) / 15).squareRoot()) }
    static func xpToReach(_ level: Int) -> Int { 15 * (level - 1) * (level - 1) }
    /// How far through the current level, 0 to 1.
    var levelProgress: Double {
        let start = Self.xpToReach(level), end = Self.xpToReach(level + 1)
        return Double((xp ?? 0) - start) / Double(max(1, end - start))
    }
    /// The streak as it stands at `now`: kept through today and yesterday, broken after a missed day.
    func streak(at now: Date, calendar: Calendar = .current) -> Int {
        guard let day = streakDay, let streak else { return 0 }
        let today = calendar.startOfDay(for: now)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return 0 }
        return calendar.isDate(day, inSameDayAs: today) || calendar.isDate(day, inSameDayAs: yesterday) ? streak : 0
    }
    func mood(at now: Date, calendar: Calendar = .current) -> Mood {
        let current = at(now, calendar: calendar)
        let justTalked = lastFed.map { now.timeIntervalSince($0) < Self.stayUpAfterTalking && now >= $0 } ?? false
        if Self.isNight(now, calendar: calendar), !justTalked { return .sleepy }
        if current.fullness < Self.hungryBelow { return .hungry }
        if current.cheer < Self.lonelyBelow { return .lonely }
        if current.fullness >= 0.7, current.cheer >= 0.6 { return .happy }
        return .content
    }

    static func isNight(_ date: Date, calendar: Calendar) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return hour >= bedtimeHour || hour < wakeHour
    }
    /// Hours of decay between two dates: waking hours count fully, sleeping hours at `nightRate`.
    /// Only the last week counts; by then every meter is empty anyway.
    static func decayHours(from start: Date, to end: Date, calendar: Calendar) -> Double {
        var cursor = max(start, end.addingTimeInterval(-7 * 86_400))
        var hours = 0.0
        while cursor < end {
            let night = isNight(cursor, calendar: calendar)
            let boundary = calendar.nextDate(after: cursor, matching: DateComponents(hour: night ? wakeHour : bedtimeHour, minute: 0, second: 0),
                                             matchingPolicy: .nextTime) ?? end
            let segmentEnd = min(max(boundary, cursor.addingTimeInterval(1)), end)
            hours += segmentEnd.timeIntervalSince(cursor) / 3600 * (night ? nightRate : 1)
            cursor = segmentEnd
        }
        return hours
    }
    private static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
}

/// A gentle local notification when Kemo is hungry or lonely. Only after the person turns
/// nudges on; at most `maxPerDay` a day, `minimumGap` apart, never while Kemo sleeps, and
/// never within `quietAfterUse` of using the app.
struct KemoNudge: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable { case hungry, lonely }
    var kind: Kind
    var date: Date

    static let maxPerDay = 2
    static let minimumGap: TimeInterval = 4 * 3600
    static let quietAfterUse: TimeInterval = 3600
    /// How far ahead nudges are planned. If they go unanswered, Kemo stops asking until the app is opened again.
    static let horizon: TimeInterval = 48 * 3600
    static let step: TimeInterval = 15 * 60

    /// What the watch says. Short, like the rest of the watch.
    func title(name: String) -> String { kind == .hungry ? "\(name)'s hungry" : "\(name) misses you" }
    func body(name: String) -> String { kind == .hungry ? "Say hi. Talking feeds \(name)." : "Say hi when you have a moment." }

    /// The next nudges for Kemo as it is at `now`, assuming nobody talks to it before then.
    /// `delivered` are nudges already shown, which count toward each day's limit and the gap.
    static func plan(for vitals: KemoVitals, now: Date, delivered: [Date], enabled: Bool,
                     limit: Int = 3, calendar: Calendar = .current) -> [KemoNudge] {
        guard enabled, limit > 0 else { return [] }
        var planned: [KemoNudge] = []
        var earliest = now.addingTimeInterval(quietAfterUse)
        if let last = delivered.filter({ $0 <= now }).max() { earliest = max(earliest, last.addingTimeInterval(minimumGap)) }
        var time = earliest
        let end = now.addingTimeInterval(horizon)
        while time <= end, planned.count < limit {
            defer { time = time.addingTimeInterval(step) }
            guard !KemoVitals.isNight(time, calendar: calendar) else { continue }
            let sameDay = delivered.filter { calendar.isDate($0, inSameDayAs: time) }.count
                + planned.filter { calendar.isDate($0.date, inSameDayAs: time) }.count
            guard sameDay < maxPerDay else { continue }
            let kind: Kind
            switch vitals.mood(at: time, calendar: calendar) {
            case .hungry: kind = .hungry
            case .lonely: kind = .lonely
            default: continue
            }
            planned.append(KemoNudge(kind: kind, date: time))
            time = time.addingTimeInterval(minimumGap - step)
        }
        return planned
    }
}

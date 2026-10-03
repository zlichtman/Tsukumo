import Foundation

// Journal: a private daily journal in Library, with the same block editor as Docs, photos
// (including the film camera's looks), a mood, and tags. Kemo never reads it unless the person
// attaches an entry to a chat message. See design/DOCS-AND-JOURNAL.md.

enum JournalMood: String, Codable, CaseIterable, Identifiable, Sendable {
    case rough, low, okay, good, great
    var id: String { rawValue }
    var title: String {
        switch self { case .rough: "Rough"; case .low: "Low"; case .okay: "Okay"; case .good: "Good"; case .great: "Great" }
    }
    var symbol: String {
        switch self {
        case .rough: "cloud.bolt.rain"
        case .low: "cloud.drizzle"
        case .okay: "cloud.sun"
        case .good: "sun.max"
        case .great: "sparkles"
        }
    }
}

struct JournalEntry: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    /// When it was started.
    var created: Date
    /// The day it belongs to ("2026-09-26"), fixed where it was written: an entry from late at
    /// night in Tokyo stays on that day when you read it in Los Angeles.
    var day: String
    var timeZone: String
    var blocks: [DocBlock] = [DocBlock()]
    var photos: [DocImageRef] = []
    var mood: JournalMood?
    var tags: [String] = []
    var modified: Date
    /// Who may read it (`PrivacyLevel`); nil is the default for entries (`JournalEntry.defaultPrivacy`).
    var privacy: PrivacyLevel?
    static let maxPhotos = 12, maxTags = 12

    init(id: UUID = UUID(), created: Date = Date(), timeZone: TimeZone = .current, day: String? = nil) {
        self.id = id; self.created = created; self.timeZone = timeZone.identifier
        self.day = day ?? JournalCalendar.dayKey(for: created, in: timeZone); modified = created
    }
    var plainText: String { blocks.map(\.searchText).joined(separator: "\n") }
    /// The first words, for the timeline and the chat chip.
    var summary: String {
        let text = plainText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return String(text.prefix(120))
    }
    var isEmpty: Bool { plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && photos.isEmpty && mood == nil && tags.isEmpty }

    enum CodingKeys: String, CodingKey { case id, created, day, timeZone, blocks, photos, mood, tags, modified, privacy }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        created = try c.decode(Date.self, forKey: .created)
        timeZone = try c.decodeIfPresent(String.self, forKey: .timeZone) ?? TimeZone.current.identifier
        let zone = TimeZone(identifier: timeZone) ?? .current
        let saved = try c.decodeIfPresent(String.self, forKey: .day)
        day = saved.flatMap { JournalCalendar.isDayKey($0) ? $0 : nil } ?? JournalCalendar.dayKey(for: created, in: zone)
        blocks = try c.decodeIfPresent([DocBlock].self, forKey: .blocks) ?? []
        if blocks.isEmpty { blocks = [DocBlock()] }
        photos = (try c.decodeIfPresent([DocImageRef].self, forKey: .photos) ?? []).filter { DocImageRef.validName($0.file) }
        mood = (try? c.decodeIfPresent(String.self, forKey: .mood)).flatMap { $0.flatMap(JournalMood.init(rawValue:)) }
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        modified = try c.decodeIfPresent(Date.self, forKey: .modified) ?? created
        privacy = try c.decodeIfPresent(PrivacyLevel.self, forKey: .privacy)
    }
    /// A tag as it's kept: lowercase words and hyphens, without the #.
    static func cleanTag(_ tag: String) -> String? {
        let cleaned = tag.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: " ", with: "-").filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return cleaned.isEmpty ? nil : String(cleaned.prefix(30))
    }
}

/// Days as keys ("yyyy-MM-dd" in the Gregorian calendar), so an entry's day never moves.
enum JournalCalendar {
    static func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone; return calendar
    }
    static func dayKey(for date: Date, in zone: TimeZone = .current) -> String {
        let parts = calendar(zone).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 1, parts.day ?? 1)
    }
    static func isDayKey(_ key: String) -> Bool { components(key) != nil }
    static func components(_ key: String) -> (year: Int, month: Int, day: Int)? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard key.count == 10, parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        return (parts[0], parts[1], parts[2])
    }
    /// The start of the day in `zone`.
    static func date(for key: String, in zone: TimeZone = .current) -> Date? {
        guard let parts = components(key) else { return nil }
        return calendar(zone).date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day))
    }
    /// The day `days` after (or before) this one.
    static func shift(_ key: String, by days: Int) -> String {
        let utc = TimeZone(identifier: "UTC")!
        guard let date = date(for: key, in: utc), let moved = calendar(utc).date(byAdding: .day, value: days, to: date) else { return key }
        return dayKey(for: moved, in: utc)
    }
    /// Entries grouped by day, newest day first; entries in a day in the order they were written.
    static func grouped(_ entries: [JournalEntry]) -> [(day: String, entries: [JournalEntry])] {
        Dictionary(grouping: entries, by: \.day).map { (day: $0.key, entries: $0.value.sorted { $0.created < $1.created }) }
            .sorted { $0.day > $1.day }
    }
    /// Entries from this day in earlier years, most recent year first. On February 28 of a year
    /// without a leap day, February 29 is included.
    static func onThisDay(_ entries: [JournalEntry], today: String) -> [(years: Int, entries: [JournalEntry])] {
        guard let now = components(today) else { return [] }
        let leap = (now.year % 4 == 0 && now.year % 100 != 0) || now.year % 400 == 0
        let matches = entries.filter { entry in
            guard let parts = components(entry.day), parts.year < now.year else { return false }
            if parts.month == now.month && parts.day == now.day { return true }
            return !leap && now.month == 2 && now.day == 28 && parts.month == 2 && parts.day == 29
        }
        return Dictionary(grouping: matches) { now.year - (components($0.day)?.year ?? now.year) }
            .map { (years: $0.key, entries: $0.value.sorted { $0.created < $1.created }) }
            .sorted { $0.years < $1.years }
    }
    /// Days in a row with an entry, ending today (or yesterday, if today has none yet).
    static func streak(_ entries: [JournalEntry], today: String) -> Int {
        let days = Set(entries.filter { !$0.isEmpty }.map(\.day))
        var day = days.contains(today) ? today : shift(today, by: -1)
        var count = 0
        while days.contains(day) { count += 1; day = shift(day, by: -1) }
        return count
    }
    /// A month's days for a calendar grid: leading nils for the days before the 1st, by the
    /// calendar's first weekday.
    static func monthGrid(year: Int, month: Int, firstWeekday: Int = Calendar.current.firstWeekday) -> [String?] {
        var calendar = calendar(TimeZone(identifier: "UTC")!); calendar.firstWeekday = firstWeekday
        guard let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let range = calendar.range(of: .day, in: .month, for: first) else { return [] }
        let weekday = calendar.component(.weekday, from: first)
        let leading = (weekday - firstWeekday + 7) % 7
        return Array(repeating: nil, count: leading) + range.map { String(format: "%04d-%02d-%02d", year, month, $0) }
    }
    /// "Friday, September 26" (with the year when it isn't this year).
    static func title(for key: String, relativeTo today: String = dayKey(for: Date())) -> String {
        if key == today { return "Today" }
        if key == shift(today, by: -1) { return "Yesterday" }
        guard let date = date(for: key, in: TimeZone(identifier: "UTC")!) else { return key }
        var style = Date.FormatStyle(); style.timeZone = TimeZone(identifier: "UTC")!
        let sameYear = components(key)?.year == components(today)?.year
        return sameYear ? date.formatted(style.weekday(.wide).month(.wide).day()) : date.formatted(style.weekday(.wide).month(.wide).day().year())
    }
    static func monthTitle(year: Int, month: Int) -> String {
        guard let date = date(for: String(format: "%04d-%02d-01", year, month), in: TimeZone(identifier: "UTC")!) else { return "" }
        var style = Date.FormatStyle(); style.timeZone = TimeZone(identifier: "UTC")!
        return date.formatted(style.month(.wide).year())
    }
}

/// A few quiet prompts for an empty page, one per day, in the app's own words.
enum JournalPrompts {
    static let all = [
        "What made today different from yesterday?",
        "Something small you noticed and want to keep.",
        "Who did you think about today, and why?",
        "What took more energy than it should have?",
        "A moment you'd happily live again.",
        "What are you looking forward to this week?",
        "What did you learn, even if it was tiny?",
        "Where did your attention go today?",
        "Something you're ready to let go of.",
        "What would make tomorrow a little easier?",
        "A conversation that stayed with you.",
        "What felt like yours today?",
        "Describe a place you were in today.",
        "What are you grateful for right now?"
    ]
    /// The day's prompt; `offset` steps to another when asked.
    static func prompt(for day: String, offset: Int = 0) -> String {
        let seed = day.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        let index = ((seed + offset) % all.count + all.count) % all.count
        return all[index]
    }
}

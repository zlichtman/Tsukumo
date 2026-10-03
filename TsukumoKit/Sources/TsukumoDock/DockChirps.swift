#if os(macOS)
import EventKit
import Foundation
import TsukumoCore
import TsukumoPolicy

// Chirps (design/UI-GUIDE.md#the-side-dock), ported from the old Mac app's dock: a bot
// speaking up on its own. What triggers one is a fixed set of rules run on this Mac, with no model and no
// service: a Calendar event or reminder coming up within the bot's window (only sources the host says
// the owner allowed, and only items the policy lets be read on this device), a bot finishing while the
// owner wasn't looking, and a bot needing the owner. A chirp is shown here only; it never goes to a bot.

/// Where an upcoming item comes from.
public enum DockChirpSource: String, CaseIterable, Codable, Sendable, Identifiable {
    case calendar, reminders
    public var id: String { rawValue }
    public var title: String { self == .calendar ? "Calendar events coming up" : "Reminders coming due" }
    var kind: ItemKind { self == .calendar ? .calendarEvent : .reminder }
}

/// What a bot chirps about: sources, words, and how far ahead. Saved with the dock, by bot.
public struct DockChirpWatch: Codable, Hashable, Sendable {
    public static let maxWords = 8
    public static let leadChoices: [(String, Int)] = [("30 minutes", 30), ("1 hour", 60), ("2 hours", 120), ("4 hours", 240), ("1 day", 1440)]
    public var sources: [DockChirpSource] = []
    /// Only items whose title has one of these words; empty means any item it watches.
    public var words: [String] = []
    /// How far ahead a chirp looks, in minutes.
    public var leadMinutes: Int = 120
    public init(sources: [DockChirpSource] = [], words: [String] = [], leadMinutes: Int = 120) {
        self.sources = sources; self.words = words; self.leadMinutes = leadMinutes
    }
    /// Trimmed, lowercased, bounded words; a window between 15 minutes and a day.
    public func cleaned() -> DockChirpWatch {
        DockChirpWatch(sources: DockChirpSource.allCases.filter(sources.contains),
                       words: Array(words.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }.prefix(Self.maxWords)),
                       leadMinutes: min(24 * 60, max(15, leadMinutes)))
    }
}

/// A Calendar event or reminder coming up.
public struct DockUpcomingItem: Equatable, Sendable {
    /// Stable across reads: the event's identifier and start, or the reminder's.
    public let id: String
    public let title: String
    /// When it starts, or when it's due.
    public let date: Date
    public let source: DockChirpSource
    public var allDay = false
    /// How private the owner says this source is (Personal by default).
    public var level: PrivacyLevel = .personal
    public init(id: String, title: String, date: Date, source: DockChirpSource, allDay: Bool = false, level: PrivacyLevel = .personal) {
        self.id = id; self.title = title; self.date = date; self.source = source; self.allDay = allDay; self.level = level
    }
}

/// One chirp to post: who says it, the words, and the key that makes it happen once.
public struct DockChirp: Equatable, Sendable {
    public let bot: UUID
    public let text: String
    public let key: String
    public init(bot: UUID, text: String, key: String) { self.bot = bot; self.text = text; self.key = key }
}

public enum DockChirpRules {
    /// How often the dock looks at what's coming up.
    public static let interval: Duration = .seconds(300)

    /// Chirps for items coming up: each item once, from the first bot in dock order that may chirp,
    /// watches its source, whose words match its title, and whose window it's in. `allowed` is what the
    /// owner allowed right now; anything else is left out, and so is anything the policy keeps from
    /// being read on this device (Secret).
    public static func upcoming(bots: [BotSpec], watches: [UUID: DockChirpWatch], items: [DockUpcomingItem], now: Date,
                                allowed: Set<DockChirpSource>, calendar: Calendar = .current, chirped: (String) -> Bool) -> [DockChirp] {
        var chirps: [DockChirp] = []
        for item in items.sorted(by: { $0.date < $1.date }) where allowed.contains(item.source) {
            let policyItem = PolicyItem(id: item.id, label: TypeLabel(kind: item.source.kind, level: item.level))
            guard ContextPolicy.allows(policyItem, to: .appleOnDevice, now: now) else { continue }
            guard let bot = bots.first(where: { $0.permissions.mayChirp && watches[$0.id].map { watch in self.watches(watch, item, now: now, calendar: calendar) } == true }) else { continue }
            let key = Self.key(bot: bot.id, item: item)
            guard !chirped(key), !chirps.contains(where: { $0.key == key }) else { continue }
            chirps.append(DockChirp(bot: bot.id, text: phrase(item, now: now, calendar: calendar), key: key))
        }
        return chirps
    }
    public static func key(bot: UUID, item: DockUpcomingItem) -> String { bot.uuidString + "|" + item.source.rawValue + "|" + item.id }

    /// Whether a bot with `watch` chirps about `item` now.
    public static func watches(_ watch: DockChirpWatch, _ item: DockUpcomingItem, now: Date, calendar: Calendar = .current) -> Bool {
        guard watch.sources.contains(item.source), matches(watch.words, item.title) else { return false }
        if item.allDay { return calendar.isDate(item.date, inSameDayAs: now) }
        let ahead = item.date.timeIntervalSince(now)
        return ahead > 0 && ahead <= TimeInterval(watch.leadMinutes * 60)
    }
    /// Any of the words appears in the title as a word or a word's start ("stat" matches "Stats").
    public static func matches(_ words: [String], _ title: String) -> Bool {
        guard !words.isEmpty else { return true }
        let titleWords = title.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return words.contains { word in titleWords.contains { $0.hasPrefix(word.lowercased()) } }
    }

    /// "Your stats assignment is due in 2 hours." or "Stats lecture starts in 45 minutes."
    public static func phrase(_ item: DockUpcomingItem, now: Date, calendar: Calendar = .current) -> String {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = title.isEmpty ? (item.source == .reminders ? "reminder" : "event") : title
        if item.source == .reminders {
            let subject = "Your " + lowercasedFirst(name)
            return item.allDay ? subject + " is due today." : subject + " is due in " + span(item.date.timeIntervalSince(now)) + "."
        }
        return item.allDay ? name + " is today." : name + " starts in " + span(item.date.timeIntervalSince(now)) + "."
    }
    /// "45 minutes", "2 hours", "1 hour 30 minutes".
    public static func span(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 { return minutes == 1 ? "a minute" : "\(minutes) minutes" }
        var hours = minutes / 60, rest = Int((Double(minutes % 60) / 5).rounded()) * 5
        if rest < 10 { rest = 0 } else if rest > 50 { rest = 0; hours += 1 }
        let hourText = hours == 1 ? "1 hour" : "\(hours) hours"
        return rest == 0 ? hourText : hourText + " \(rest) minutes"
    }
    /// "Stats assignment" becomes "stats assignment"; "PSYCH 101 essay" keeps its capitals.
    static func lowercasedFirst(_ text: String) -> String {
        guard let first = text.split(separator: " ").first, first.count > 1,
              first.dropFirst().allSatisfy({ !$0.isUppercase }) else { return text }
        return text.prefix(1).lowercased() + text.dropFirst()
    }

    /// The speech bubble when a bot finishes and the owner isn't looking at it: its reply's first line.
    public static func finished(_ reply: String) -> String {
        let line = reply.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        let plain = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        guard !plain.isEmpty else { return "Done." }
        return plain.count > 110 ? String(plain.prefix(109)) + "…" : plain
    }
    /// A bot waiting on the owner (KemoSabe's consent, or an approval).
    public static let needsYou = "I need your OK before I go on."
}

// MARK: Reading what's coming up

/// What's coming up, read on this Mac.
@MainActor public protocol DockUpcomingSource {
    func items(from start: Date, to end: Date, sources: Set<DockChirpSource>) async -> [DockUpcomingItem]
}

/// Calendar events and unfinished reminders from EventKit. It only reads with full access already
/// granted; it never asks (that belongs to the host's settings).
@MainActor public final class EventKitDockSource: DockUpcomingSource {
    private let store = EKEventStore()
    public init() {}
    /// Apple's full access for this source, already granted.
    public static func permitted(_ source: DockChirpSource) -> Bool {
        switch source {
        case .calendar: EKEventStore.authorizationStatus(for: .event) == .fullAccess
        case .reminders: EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        }
    }
    public func items(from start: Date, to end: Date, sources: Set<DockChirpSource>) async -> [DockUpcomingItem] {
        var list: [DockUpcomingItem] = []
        let calendar = Calendar.current
        if sources.contains(.calendar), Self.permitted(.calendar) {
            let dayStart = calendar.startOfDay(for: start)
            list += store.events(matching: store.predicateForEvents(withStart: dayStart, end: end, calendars: nil)).map { event in
                DockUpcomingItem(id: event.calendarItemIdentifier + "@" + String(Int(event.startDate.timeIntervalSince1970)),
                                 title: String((event.title ?? "").prefix(160)), date: event.startDate, source: .calendar, allDay: event.isAllDay)
            }
        }
        if sources.contains(.reminders), Self.permitted(.reminders) {
            let predicate = store.predicateForIncompleteReminders(withDueDateStarting: calendar.startOfDay(for: start), ending: end, calendars: nil)
            let found: [DockUpcomingItem] = await withCheckedContinuation { continuation in
                store.fetchReminders(matching: predicate) { reminders in
                    let items: [DockUpcomingItem] = (reminders ?? []).compactMap { reminder in
                        guard let components = reminder.dueDateComponents, let due = calendar.date(from: components) else { return nil }
                        return DockUpcomingItem(id: reminder.calendarItemIdentifier, title: String((reminder.title ?? "").prefix(160)),
                                                date: due, source: .reminders, allDay: components.hour == nil)
                    }
                    continuation.resume(returning: items)
                }
            }
            list += found
        }
        return list
    }
}
#endif

import EventKit
import SwiftUI

// MARK: Day ranges

/// The calendar math behind flipping through days (the owner's instruction, September 26, 2026):
/// what one day covers in a time zone (23 or 25 hours across a DST change), moving by whole days,
/// and which events, reminders, and Kemo items belong to a day. Pure, so it's tested directly.
enum DayRange {
    enum Relation: Equatable { case past, today, future }
    static func start(of date: Date, calendar: Calendar) -> Date { calendar.startOfDay(for: date) }
    /// Midnight to the next midnight in the calendar's time zone.
    static func interval(for day: Date, calendar: Calendar) -> DateInterval {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start).map(calendar.startOfDay(for:)) ?? start.addingTimeInterval(86400)
        return DateInterval(start: start, end: end)
    }
    /// The start of the day `days` away, keeping to midnight across DST changes.
    static func shift(_ day: Date, by days: Int, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: day)
        return calendar.date(byAdding: .day, value: days, to: start).map(calendar.startOfDay(for:)) ?? start
    }
    static func relation(of day: Date, now: Date, calendar: Calendar) -> Relation {
        let (a, b) = (calendar.startOfDay(for: day), calendar.startOfDay(for: now))
        return a == b ? .today : a < b ? .past : .future
    }
    /// Whether something from `start` to `end` falls on the day. An event ending exactly at midnight
    /// isn't on the next day; one with no length belongs to the day it starts.
    static func overlaps(start: Date, end: Date, day: DateInterval) -> Bool {
        if end <= start { return start >= day.start && start < day.end }
        return start < day.end && end > day.start
    }
    /// A reminder's due date. Without a time it's due on its date in the calendar's time zone,
    /// whatever zone it was written in; with a time and a zone it's that exact moment.
    static func due(_ components: DateComponents, calendar: Calendar) -> (date: Date, allDay: Bool)? {
        guard let year = components.year, let month = components.month, let day = components.day else { return nil }
        if components.hour == nil {
            var local = DateComponents(); local.year = year; local.month = month; local.day = day
            return calendar.date(from: local).map { (calendar.startOfDay(for: $0), true) }
        }
        var zoned = calendar
        if let zone = components.timeZone { zoned.timeZone = zone }
        var exact = DateComponents(); exact.year = year; exact.month = month; exact.day = day
        exact.hour = components.hour; exact.minute = components.minute ?? 0; exact.second = components.second ?? 0
        return zoned.date(from: exact).map { ($0, false) }
    }
    /// When a Kemo item is for: the time it writes, or the time it's scheduled at.
    static func date(of proposal: RoutineProposal) -> Date? { proposal.routineWrite?.start ?? proposal.scheduledAt }
    /// Kemo's items for a day, by their time.
    static func proposals(_ proposals: [RoutineProposal], on day: Date, calendar: Calendar) -> [RoutineProposal] {
        let range = interval(for: day, calendar: calendar)
        return proposals.compactMap { proposal in date(of: proposal).map { (proposal, $0) } }
            .filter { range.contains($0.1) && $0.1 < range.end }
            .sorted { $0.1 < $1.1 }.map(\.0)
    }
}

// MARK: Calendar and Reminders, by day

/// Your calendar and reminders in Day, one day at a time: read on this device when a day is shown,
/// with the days either side fetched ahead so flipping is instant, and refreshed when the calendar
/// changes. Read only; nothing here reaches a model unless you ask Kemo about it. Each kind is read
/// only while it's connected (`ConnectorStore.status`) and Apple's permission allows it, and
/// nothing is read while signed out.
@MainActor @Observable final class DayCalendar {
    struct Event: Identifiable, Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let allDay: Bool
        let calendar: String
        let color: Color
    }
    struct Reminder: Identifiable, Equatable {
        let id: String
        let title: String
        let due: Date
        let allDay: Bool
        let completed: Bool
        let list: String
        let color: Color
    }
    struct Day: Equatable {
        var events: [Event] = []
        var reminders: [Reminder] = []
    }
    private(set) var days: [Date: Day] = [:]
    /// Set by the view from Connections' status; a change drops what was read.
    var calendarAllowed = false { didSet { if calendarAllowed != oldValue { reset() } } }
    var remindersAllowed = false { didSet { if remindersAllowed != oldValue { reset() } } }
    private let store = EKEventStore()
    private var calendar: Calendar { .current }
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var requested: Set<Date> = []
    @ObservationIgnored private var generation = 0
    /// The day shown, so a change re-reads it and its neighbors.
    @ObservationIgnored private var focus: Date?

    static var permitted: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    static var remindersPermitted: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reset() }
        }
    }
    /// What was read for a day, or nil until it has been.
    func day(_ date: Date) -> Day? { days[DayRange.start(of: date, calendar: calendar)] }
    /// Reads a day and the days either side, each once.
    func prefetch(around date: Date) {
        focus = date
        for offset in [0, 1, -1] { load(DayRange.shift(date, by: offset, calendar: calendar)) }
    }
    func load(_ date: Date) {
        let key = DayRange.start(of: date, calendar: calendar)
        guard !requested.contains(key) else { return }
        requested.insert(key)
        // Keep a few weeks around the days in use; drop the rest.
        if days.count > 42 { days = days.filter { abs($0.key.timeIntervalSince(key)) < 21 * 86400 } }
        guard !AppleAccountSession.shared.needsSignIn else { days[key] = Day(); return }
        let range = DayRange.interval(for: key, calendar: calendar)
        var day = Day()
        if calendarAllowed, Self.permitted {
            day.events = store.events(matching: store.predicateForEvents(withStart: range.start, end: range.end, calendars: nil))
                .filter { DayRange.overlaps(start: $0.startDate, end: $0.endDate, day: range) }
                .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
                .prefix(200)
                .map { Event(id: $0.calendarItemIdentifier + "@" + String($0.startDate.timeIntervalSince1970), title: String(($0.title ?? "Untitled event").prefix(160)),
                             start: $0.startDate, end: $0.endDate, allDay: $0.isAllDay, calendar: $0.calendar.title, color: Color(cgColor: $0.calendar.cgColor)) }
        }
        days[key] = day
        guard remindersAllowed, Self.remindersPermitted else { return }
        let token = generation
        let calendar = calendar
        let open = store.predicateForIncompleteReminders(withDueDateStarting: range.start, ending: range.end, calendars: nil)
        let done = store.predicateForCompletedReminders(withCompletionDateStarting: range.start, ending: range.end, calendars: nil)
        Task { [weak self, store] in
            async let unfinished = Self.fetch(open, in: store)
            async let finished = Self.fetch(done, in: store)
            let all = await unfinished + finished
            let reminders = all.compactMap { reminder -> Reminder? in
                guard let components = reminder.dueDateComponents, let due = DayRange.due(components, calendar: calendar),
                      range.contains(due.date), due.date < range.end else { return nil }
                return Reminder(id: reminder.calendarItemIdentifier, title: String((reminder.title ?? "Untitled reminder").prefix(160)), due: due.date,
                                allDay: due.allDay, completed: reminder.isCompleted, list: reminder.calendar.title, color: Color(cgColor: reminder.calendar.cgColor))
            }
            .sorted { ($0.completed ? 1 : 0, $0.allDay ? 0 : 1, $0.due) < ($1.completed ? 1 : 0, $1.allDay ? 0 : 1, $1.due) }
            await MainActor.run {
                guard let self, self.generation == token, self.remindersAllowed else { return }
                self.days[key, default: Day()].reminders = Array(reminders.prefix(100))
            }
        }
    }
    private nonisolated static func fetch(_ predicate: NSPredicate, in store: EKEventStore) async -> [EKReminder] {
        await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) }
        }
    }
    /// Forgets what was read, so the days on screen are read again.
    func reset() {
        generation += 1
        requested = []; days = [:]
        if let focus { prefetch(around: focus) }
    }
}

// MARK: The day's calendar and reminders

/// A day's events and reminders, at the top of Day on iPhone and Mac. Connect Calendar is offered
/// through Connections' own connect, exactly as before; reminders show only while connected.
struct DayCalendarSection: View {
    let day: Date
    let calendar: DayCalendar
    @Environment(AppStore.self) private var store
    @Environment(ConnectorStore.self) private var connectors
    @Environment(\.openURL) private var openURL
    @State private var message: String?
    /// The same "connected" as Connections: Apple's full access and KemoSabe's own switch.
    private var status: ConnectorStatus { connectors.status(.calendar, state: store.state) }
    private var relation: DayRange.Relation { DayRange.relation(of: day, now: Date(), calendar: .current) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if status.usable && DayCalendar.permitted {
                events
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Bring in your calendar", systemImage: "calendar").font(KemoType.font(.headline))
                    Text(status.guidance(for: .calendar) ?? "See each day's events here. Read only, on this device; KemoSabe reads it only when you ask.")
                        .font(KemoType.font(.callout)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("dayCalendarGuidance")
                    if status.opensSystemSettings {
                        Button("Open Settings") { if let url = Self.settingsURL { openURL(url) } }.accessibilityIdentifier("dayCalendarSettings")
                    } else {
                        // Through Connections' own connect, so this grant turns the connection on everywhere.
                        Button("Connect Calendar") {
                            Task { message = await connectors.connect(.calendar, store: store); calendar.reset() }
                        }.disabled(connectors.authorizing != nil).accessibilityIdentifier("connectDayCalendar")
                    }
                    if let message, !status.usable { Text(message).font(KemoType.font(.caption)).foregroundStyle(.secondary) }
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
            }
            if let reminders = calendar.day(day)?.reminders, !reminders.isEmpty { remindersList(reminders) }
        }
    }
    private static var settingsURL: URL? {
        #if os(iOS)
        URL(string: UIApplication.openSettingsURLString)
        #else
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
        #endif
    }
    private var events: some View {
        let events = calendar.day(day)?.events ?? []
        return VStack(alignment: .leading, spacing: 8) {
            Text("Calendar").font(KemoType.font(.headline))
            if events.isEmpty {
                Text(calendar.day(day) == nil ? " " : relation == .today ? "Nothing on your calendar today." : "Nothing on your calendar.")
                    .font(KemoType.font(.callout)).foregroundStyle(.secondary)
            }
            ForEach(events) { event in
                HStack(alignment: .top, spacing: 12) {
                    RoundedRectangle(cornerRadius: 2).fill(event.color).frame(width: 4, height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title).font(KemoType.font(.body)).lineLimit(2)
                        Text(event.allDay ? "All day · " + event.calendar
                             : event.start.formatted(date: .omitted, time: .shortened) + "–" + event.end.formatted(date: .omitted, time: .shortened) + " · " + event.calendar)
                            .font(KemoType.font(.caption)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }.accessibilityElement(children: .combine).accessibilityIdentifier("dayEvent")
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
    }
    private func remindersList(_ reminders: [DayCalendar.Reminder]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reminders").font(KemoType.font(.headline))
            ForEach(reminders) { reminder in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: reminder.completed ? "checkmark.circle.fill" : "circle").foregroundStyle(reminder.color).font(.system(size: 16))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(reminder.title).font(KemoType.font(.body)).lineLimit(2).strikethrough(reminder.completed).foregroundStyle(reminder.completed ? .secondary : .primary)
                        Text((reminder.allDay ? "Due" : "Due " + reminder.due.formatted(date: .omitted, time: .shortened)) + " · " + reminder.list)
                            .font(KemoType.font(.caption)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }.accessibilityElement(children: .combine).accessibilityIdentifier("dayReminder")
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
    }
}

/// Keeps a `DayCalendar` in step with Connections: what may be read, and the days around the one shown.
struct DayCalendarLoader: ViewModifier {
    let day: Date
    let calendar: DayCalendar
    @Environment(AppStore.self) private var store
    @Environment(ConnectorStore.self) private var connectors
    func body(content: Content) -> some View {
        let calendarOn = connectors.status(.calendar, state: store.state).usable
        let remindersOn = connectors.status(.reminders, state: store.state).usable
        content
            .task { connectors.refresh(); calendar.start() }
            .task(id: [calendarOn, remindersOn]) {
                calendar.calendarAllowed = calendarOn; calendar.remindersAllowed = remindersOn
                calendar.prefetch(around: day)
            }
            .onChange(of: day) { calendar.prefetch(around: day) }
    }
}

// MARK: Kemo's plan for a day

/// Kemo's items with a time on a day: past days are read-only history; later days show what's
/// planned. Approving happens where items wait for you (Needs your attention on today).
struct DayPlanList: View {
    let day: Date
    let proposals: [RoutineProposal]
    var body: some View {
        let items = DayRange.proposals(proposals, on: day, calendar: .current)
        let relation = DayRange.relation(of: day, now: Date(), calendar: .current)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(relation == .past ? "\(CompanionIdentity.name)'s plan · history" : "\(CompanionIdentity.name)'s plan").font(KemoType.font(.headline))
                ForEach(items) { proposal in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(DayRange.date(of: proposal).map { $0.formatted(date: .omitted, time: .shortened) } ?? "")
                            .font(KemoType.font(.caption)).foregroundStyle(.secondary).frame(minWidth: 58, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(proposal.title).font(KemoType.font(.body)).lineLimit(2)
                            Text(proposal.receipt ?? proposal.status.label).font(KemoType.font(.caption)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }.accessibilityElement(children: .combine).accessibilityIdentifier("dayPlanItem")
                }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

extension DayRange {
    /// "Today", "Tomorrow", "Yesterday", or the weekday: the day's heading.
    static func heading(_ day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        switch calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: day)).day ?? 0 {
        case 0: "Your day"
        case 1: "Tomorrow"
        case -1: "Yesterday"
        default: day.formatted(.dateTime.weekday(.wide))
        }
    }
}

import EventKit
import Foundation
import TsukumoCore
import TsukumoPolicy

// KemoSabe's Calendar and Reminders, on iPhone and Mac alike (moved from the iPhone app, October 2; part of
// `SourceLibrary`'s catalog since October 3): read with EventKit only when the owner turns a source on
// (which asks the system for access) and only when a bot's question reaches the Gate. Each item carries
// the level the owner set; the Gate's policy decides what may be read for a bot. On a Mac the app also needs the Calendars entitlement under the
// hardened runtime, and the usage strings in its Info.plist.

/// EventKit's side of Calendar and Reminders.
public enum EventKitAccess {
    public static func entity(_ kind: SourceKind) -> EKEntityType { kind == .reminders ? .reminder : .event }
    /// Whether the system lets this app read it.
    public static func authorized(_ kind: SourceKind) -> Bool { EKEventStore.authorizationStatus(for: entity(kind)) == .fullAccess }
    public static func status(_ kind: SourceKind) -> SourcePermission {
        switch EKEventStore.authorizationStatus(for: entity(kind)) {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        default: .denied
        }
    }
    /// Asks the system for access.
    public static func request(_ kind: SourceKind) async -> SourcePermission {
        let store = EKEventStore()
        let granted = (try? await (kind == .reminders ? store.requestFullAccessToReminders() : store.requestFullAccessToEvents())) ?? false
        return granted ? .granted : status(kind)
    }
}

/// Events from a day ago to two weeks ahead.
public struct CalendarSource: PersonalSource {
    public let level: PrivacyLevel
    public init(level: PrivacyLevel) { self.level = level }
    public func items(matching question: GateQuestion) async -> [PersonalItem] {
        guard EventKitAccess.authorized(.calendar) else { return [] }
        let store = EKEventStore()
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-86_400), end: now.addingTimeInterval(14 * 86_400), calendars: nil)
        return store.events(matching: predicate).prefix(200).map { event in
            var lines = ["Event: " + (event.title ?? "Untitled")]
            lines.append("When: " + Self.when(event))
            if let location = event.location, !location.isEmpty { lines.append("Where: " + location) }
            // The next two days count as relevant to any question, so "When am I free tonight?" sees them.
            return PersonalItem(id: "event:" + (event.eventIdentifier ?? UUID().uuidString), kind: .calendarEvent, level: level,
                                title: "your calendar", text: lines.joined(separator: "\n"), date: event.startDate,
                                matched: event.startDate < now.addingTimeInterval(2 * 86_400))
        }
    }
    static func when(_ event: EKEvent) -> String {
        if event.isAllDay { return event.startDate.formatted(date: .complete, time: .omitted) + ", all day" }
        return event.startDate.formatted(date: .complete, time: .shortened) + " to " + event.endDate.formatted(date: .omitted, time: .shortened)
    }
}

/// Reminders that aren't done.
public struct RemindersSource: PersonalSource {
    public let level: PrivacyLevel
    public init(level: PrivacyLevel) { self.level = level }
    public func items(matching question: GateQuestion) async -> [PersonalItem] {
        guard EventKitAccess.authorized(.reminders) else { return [] }
        let level = self.level
        return await withCheckedContinuation { continuation in
            let store = EKEventStore()
            let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            store.fetchReminders(matching: predicate) { reminders in
                let items = (reminders ?? []).prefix(200).map { reminder in
                    var lines = ["Reminder: " + (reminder.title ?? "Untitled")]
                    if let due = reminder.dueDateComponents?.date { lines.append("Due: " + due.formatted(date: .complete, time: .shortened)) }
                    if let notes = reminder.notes, !notes.isEmpty { lines.append("Notes: " + notes) }
                    return PersonalItem(id: "reminder:" + reminder.calendarItemIdentifier, kind: .reminder, level: level,
                                        title: "your reminders", text: lines.joined(separator: "\n"), date: reminder.dueDateComponents?.date)
                }
                continuation.resume(returning: Array(items))
            }
        }
    }
}

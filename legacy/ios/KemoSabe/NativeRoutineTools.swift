import Foundation
import EventKit

@MainActor final class AppleRoutineTools: RoutineNativeTools {
    private let store = EKEventStore()
    var enabled: () -> Set<ConnectorID> = { [] }
    /// Apple's permission; injectable so the gate is testable without the system's privacy database.
    var permission: (ConnectorID) -> ConnectorPermission = { AppleConnectionClient().permission($0) }
    /// Who the day planner's reads reach. The same gate as every other connection read
    /// (`ActionGate.requireNativeRead`): a connected API model would need its own grant.
    var recipient: () -> ToolRecipient = { .onDevice }
    func require(_ reminders: Bool) throws {
        // Signed out, nothing is read or written (everything runs through the account).
        if AppleAccountSession.shared.needsSignIn { throw ToolFailure.missingPermission }
        let connector: ConnectorID = reminders ? .reminders : .calendar
        // Planning reads and writes need full access; "Add events only" and selected contacts don't count.
        guard permission(connector) == .allowed else { throw ToolFailure.missingPermission }
        try ActionGate.requireNativeRead(connector, enabled: enabled(), permission: permission(connector), recipient: recipient())
    }
    private func describe(_ calendar: EKCalendar, reminders: Bool) -> RoutineDestination {
        .init(id: calendar.calendarIdentifier, sourceID: calendar.source.sourceIdentifier,
              name: calendar.title, sourceName: calendar.source.title, reminders: reminders,
              maySync: calendar.source.sourceType != .local)
    }
    func destinations(reminders: Bool) throws -> [RoutineDestination] {
        try require(reminders)
        return store.calendars(for: reminders ? .reminder : .event).filter(\.allowsContentModifications)
            .map { describe($0, reminders: reminders) }.sorted { $0.name < $1.name }
    }
    func day(_ date: Date) throws -> RoutineDaySnapshot {
        try require(false)
        let start = Calendar.current.startOfDay(for: date)
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { throw RoutineError.unavailable }
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
        guard events.count <= 200 else { throw ToolFailure.budget }
        return .init(date: start, busy: events.filter { $0.availability != .free && $0.status != .canceled }.map {
            .init(id: $0.calendarItemIdentifier, start: $0.startDate, end: $0.endDate, fingerprint: fingerprint($0))
        })
    }
    private func fingerprint(_ item: EKCalendarItem) -> String {
        var parts = [item.calendarItemIdentifier, item.calendar.calendarIdentifier, item.calendar.source.sourceIdentifier,
                     item.title ?? "", item.url?.absoluteString ?? "", item.notes ?? "", item.lastModifiedDate?.description ?? ""]
        if let event = item as? EKEvent {
            parts += [String(event.startDate.timeIntervalSince1970), String(event.endDate.timeIntervalSince1970),
                      String(event.isAllDay), String(event.hasRecurrenceRules), String(event.hasAttendees)]
        }
        if let reminder = item as? EKReminder {
            parts += [reminder.dueDateComponents?.description ?? "", String(reminder.isCompleted), String(reminder.hasRecurrenceRules)]
        }
        return RoutineHash.of(parts)
    }
    private func calendar(for write: RoutineWrite) throws -> EKCalendar {
        try require(write.destination.reminders)
        guard let calendar = store.calendar(withIdentifier: write.destination.id), calendar.allowsContentModifications,
              describe(calendar, reminders: write.destination.reminders) == write.destination else { throw RoutineError.stale }
        return calendar
    }
    func validate(_ write: RoutineWrite, owned: [RoutineWriteReceipt]) throws {
        try write.validate(now: Date())
        _ = try calendar(for: write)
        if !write.destination.reminders {
            let snapshot = try day(write.start)
            // Compare non-Kemo commitments; earlier writes in this same plan
            // may add owned blocks, but must still pass the overlap check.
            let ownedIDs = Set(owned.map(\.itemID))
            let external = RoutineDaySnapshot(date: snapshot.date, busy: snapshot.busy.filter { !ownedIDs.contains($0.id) })
            guard external.digest == write.calendarDigest,
                  !snapshot.conflicts(start: write.start, end: write.end, excluding: write.targetID) else { throw RoutineError.stale }
        }
        if let targetID = write.targetID {
            guard let receipt = owned.last(where: { $0.itemID == targetID }),
                  let item = store.calendarItem(withIdentifier: targetID), item.calendar.calendarIdentifier == write.destination.id,
                  !item.hasRecurrenceRules, item.url == URL(string: "kemosabe://routine/\(receipt.operationID.uuidString)"),
                  fingerprint(item) == write.targetDigest, receipt.fingerprint == write.targetDigest else { throw RoutineError.stale }
            if let event = item as? EKEvent, event.hasAttendees || event.isAllDay { throw RoutineError.unavailable }
            if let reminder = item as? EKReminder, reminder.isCompleted { throw RoutineError.unavailable }
        }
    }
    func execute(_ write: RoutineWrite) throws -> RoutineWriteReceipt {
        let destination = try calendar(for: write)
        let item: EKCalendarItem
        if write.destination.reminders {
            let reminder: EKReminder
            if let id = write.targetID {
                guard let value = store.calendarItem(withIdentifier: id) as? EKReminder else { throw RoutineError.stale }
                reminder = value
            } else { reminder = EKReminder(eventStore: store) }
            reminder.calendar = destination; reminder.title = write.externalTitle; reminder.url = write.marker
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: write.timeZone)!
            var components = calendar.dateComponents([.year,.month,.day,.hour,.minute], from: write.start)
            components.timeZone = calendar.timeZone; components.calendar = calendar
            reminder.dueDateComponents = components; reminder.alarms = [EKAlarm(absoluteDate: write.start)]
            try store.save(reminder, commit: true); item = reminder
        } else {
            let event: EKEvent
            if let id = write.targetID {
                guard let value = store.calendarItem(withIdentifier: id) as? EKEvent else { throw RoutineError.stale }
                event = value
            } else { event = EKEvent(eventStore: store) }
            event.calendar = destination; event.title = write.externalTitle; event.url = write.marker
            event.startDate = write.start; event.endDate = write.end
            event.timeZone = TimeZone(identifier: write.timeZone)
            try store.save(event, span: .thisEvent, commit: true); item = event
        }
        guard let reread = store.calendarItem(withIdentifier: item.calendarItemIdentifier), matches(reread, write: write) else { throw RoutineError.stale }
        return .init(operationID: write.operationID, itemID: reread.calendarItemIdentifier, fingerprint: fingerprint(reread), verifiedAt: Date())
    }
    private func matches(_ item: EKCalendarItem, write: RoutineWrite) -> Bool {
        guard item.calendar.calendarIdentifier == write.destination.id, item.url == write.marker, item.title == write.externalTitle else { return false }
        if let event = item as? EKEvent { return event.startDate == write.start && event.endDate == write.end && !event.hasAttendees && !event.hasRecurrenceRules }
        if let reminder = item as? EKReminder {
            guard let components = reminder.dueDateComponents, let date = components.date else { return false }
            return abs(date.timeIntervalSince(write.start)) < 1 && !reminder.isCompleted && !reminder.hasRecurrenceRules
        }
        return false
    }
    func reconcile(_ write: RoutineWrite) async throws -> RoutineWriteReceipt? {
        let destination = try calendar(for: write)
        let items: [EKCalendarItem]
        if write.destination.reminders {
            let predicate = store.predicateForReminders(in: [destination])
            let fetched: [EKReminder]? = await withCheckedContinuation { continuation in
                store.fetchReminders(matching: predicate) { continuation.resume(returning: $0) }
            }
            try require(true)
            guard let fetched else { throw RoutineError.unavailable }
            guard fetched.count <= 2000 else { throw ToolFailure.budget }; items = fetched
        } else {
            items = store.events(matching: store.predicateForEvents(withStart: write.start.addingTimeInterval(-86400), end: write.end.addingTimeInterval(86400), calendars: [destination]))
        }
        let matches = items.filter { $0.url == write.marker }
        guard matches.count == 1, let item = matches.first, self.matches(item, write: write) else { return nil }
        return .init(operationID: write.operationID, itemID: item.calendarItemIdentifier, fingerprint: fingerprint(item), verifiedAt: Date())
    }
}

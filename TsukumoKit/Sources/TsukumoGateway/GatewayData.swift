import EventKit
import Foundation
import TsukumoCore
import TsukumoGate
import TsukumoPolicy

/// The owner's calendar as the gateway reads it: when they're busy, and nothing else. A reader never returns
/// titles, attendees, locations, or notes; the gateway couldn't send them if it wanted to.
public protocol BusyTimeReading: Sendable {
    func busy(from start: Date, to end: Date) async -> [DateInterval]
}

/// EventKit's busy times: events that aren't marked free and that the owner hasn't declined. All-day events
/// count only when they're marked busy (a birthday or a holiday isn't).
public struct SystemBusyTimes: BusyTimeReading {
    public init() {}
    public func busy(from start: Date, to end: Date) async -> [DateInterval] {
        guard EventKitAccess.authorized(.calendar), end > start else { return [] }
        let store = EKEventStore()
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
        return events.prefix(2_000).compactMap { event in
            guard event.status != .canceled, event.availability != .free else { return nil }
            if event.isAllDay, event.availability != .busy, event.availability != .unavailable { return nil }
            if event.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined { return nil }
            guard let from = event.startDate, let to = event.endDate, to > from else { return nil }
            return DateInterval(start: from, end: to)
        }
    }
}

/// Where the typed tools read from, and at what level the owner keeps each source (nil: off, or macOS hasn't
/// allowed it). Built from KemoSabe's own catalog, so the gateway reads only what KemoSabe may read.
public struct GatewaySources: Sendable {
    public var calendarLevel: @MainActor @Sendable () -> PrivacyLevel?
    public var contactsLevel: @MainActor @Sendable () -> PrivacyLevel?
    public var busy: any BusyTimeReading
    public var contacts: any ContactsReading

    public init(calendarLevel: @escaping @MainActor @Sendable () -> PrivacyLevel?, contactsLevel: @escaping @MainActor @Sendable () -> PrivacyLevel?,
                busy: any BusyTimeReading, contacts: any ContactsReading) {
        self.calendarLevel = calendarLevel; self.contactsLevel = contactsLevel; self.busy = busy; self.contacts = contacts
    }

    /// KemoSabe's catalog: Calendar and Contacts at the levels the owner set there, read only while they're on
    /// and allowed.
    @MainActor public static func library(_ library: SourceLibrary, busy: any BusyTimeReading = SystemBusyTimes(),
                                          contacts: any ContactsReading = SystemContacts()) -> GatewaySources {
        GatewaySources(calendarLevel: { [weak library] in
            guard let library, library.isReadable(.calendar) else { return nil }
            return library.settings.setting(.calendar).level
        }, contactsLevel: { [weak library] in
            guard let library, library.isReadable(.contacts) else { return nil }
            return library.settings.setting(.contacts).level
        }, busy: busy, contacts: contacts)
    }

    /// Nothing to read (the gateway's tools say so).
    public static let none = GatewaySources(calendarLevel: { nil }, contactsLevel: { nil }, busy: FixtureBusyTimes(blocks: []),
                                            contacts: FixtureContacts(cards: []))
}

// MARK: Fake data (tests, `--ui-testing`, and the smoke test; never the owner's)

/// Busy times from a fixed list.
public struct FixtureBusyTimes: BusyTimeReading {
    public let blocks: [DateInterval]
    public init(blocks: [DateInterval]) { self.blocks = blocks }
    public func busy(from start: Date, to end: Date) async -> [DateInterval] {
        blocks.filter { $0.end > start && $0.start < end }
    }
    /// A made-up day: busy 9:00 to 10:30 and 1:00 to 2:00 tomorrow, and 4:15 to 5:00 the day after, in the
    /// calendar's time zone.
    public static func sample(now: Date = Date(), calendar: Calendar = .current) -> FixtureBusyTimes {
        let tomorrow = calendar.startOfDay(for: now.addingTimeInterval(86_400))
        func at(_ day: Date, _ hour: Int, _ minute: Int) -> Date { calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day }
        let after = tomorrow.addingTimeInterval(86_400)
        return FixtureBusyTimes(blocks: [DateInterval(start: at(tomorrow, 9, 0), end: at(tomorrow, 10, 30)),
                                         DateInterval(start: at(tomorrow, 13, 0), end: at(tomorrow, 14, 0)),
                                         DateInterval(start: at(after, 16, 15), end: at(after, 17, 0))])
    }
}

/// Contacts from a fixed list, looked up the way Contacts does (any part of the name starting with the words).
public struct FixtureContacts: ContactsReading {
    public let cards: [ContactCard]
    public init(cards: [ContactCard]) { self.cards = cards }
    public func contacts(named name: String) async -> [ContactCard] {
        let words = name.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        return cards.filter { card in
            let parts = card.name.lowercased().split(separator: " ").map(String.init)
            return words.allSatisfy { word in parts.contains { $0.hasPrefix(word) } }
        }
    }
    /// Made-up people with made-up numbers (555) and example.com addresses.
    public static let sample = FixtureContacts(cards: [
        ContactCard(id: "fixture-sarah", name: "Sarah Lin", organization: "Lantern Studio", phones: ["+1 415 555 0142", "+1 415 555 0199"],
                    emails: ["sarah@example.com"], birthday: DateComponents(month: 4, day: 12), place: "San Francisco, CA",
                    givenName: "Sarah", familyName: "Lin"),
        ContactCard(id: "fixture-mateo", name: "Mateo Ruiz", phones: ["+1 212 555 0170"], emails: ["mateo@example.com"],
                    givenName: "Mateo", familyName: "Ruiz"),
        ContactCard(id: "fixture-alex-1", name: "Alex Kim", phones: ["+1 312 555 0101"], givenName: "Alex", familyName: "Kim"),
        ContactCard(id: "fixture-alex-2", name: "Alex Park", phones: ["+1 312 555 0102"], givenName: "Alex", familyName: "Park"),
    ])
}

import Foundation
import EventKit
import Contacts
import CryptoKit

struct ConnectorFieldRecord: Codable, Equatable, Sendable {
    let fields: [String: String]
}
struct ConnectorReadResult: Encodable, Equatable, Sendable {
    let connector: ConnectorID
    let fetchedAt: Date
    let records: [ConnectorFieldRecord]
    let totalCount: Int
    // Source floor, not a model-assigned confidence. OS access isn't disclosure consent.
    let localOnly = true
    /// Every read is Personal (`ContextItem.connector`): Apple's models may have it, another company's
    /// model only with its own grant for that connection.
    static let privacyLevel: PrivacyLevel = .personal
    let privacy = ConnectorReadResult.privacyLevel
}

/// Immutable evidence for connector data consulted by a proposal. The result
/// digest excludes fetchedAt and dictionary/record ordering, but includes every
/// returned field and totalCount so hidden additions/removals invalidate it.
struct ConnectorSource: Codable, Equatable, Hashable, Sendable {
    static let maximumLifetime: TimeInterval = 15 * 60
    let connector: ConnectorID
    let query: String?
    let resultDigest: String
    let readAt: Date
    let expiresAt: Date

    init(result: ConnectorReadResult, query: String?) {
        connector = result.connector
        self.query = Self.normalizedQuery(query)
        resultDigest = Self.digest(result)
        readAt = result.fetchedAt
        expiresAt = result.fetchedAt.addingTimeInterval(Self.maximumLifetime)
    }

    func isValid(now: Date) -> Bool {
        connector.isNative && resultDigest.count == 64 && resultDigest.allSatisfy(\.isHexDigit) &&
            (query.map({ !$0.isEmpty && $0.count <= 120 }) ?? true) &&
            readAt.timeIntervalSince1970.isFinite && expiresAt.timeIntervalSince1970.isFinite &&
            expiresAt > readAt && expiresAt.timeIntervalSince(readAt) <= Self.maximumLifetime &&
            readAt <= now.addingTimeInterval(5) && now < expiresAt
    }

    static func normalizedQuery(_ query: String?) -> String? {
        guard let query else { return nil }
        let value = query.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return value.isEmpty ? nil : String(value.prefix(120))
    }
    /// Calendar reads cover one day: today, or tomorrow when the query says so.
    static func calendarDayOffset(_ query: String?) -> Int { normalizedQuery(query) == "tomorrow" ? 1 : 0 }

    static func digest(_ result: ConnectorReadResult) -> String {
        func framed(_ value: String) -> String { "\(value.utf8.count):\(value)" }
        let normalizedRecords = result.records.map { record in
            record.fields.map { (framed($0.key), framed($0.value.replacingOccurrences(of: "\r\n", with: "\n"))) }
                .sorted { $0.0 < $1.0 }.map { $0.0 + $0.1 }.joined(separator: "|")
        }.sorted()
        let canonical = [framed(result.connector.rawValue), String(result.totalCount),
                         result.localOnly ? "1" : "0", framed(result.privacy.rawValue)] +
            normalizedRecords.map(framed)
        return SHA256.hash(data: Data(canonical.joined(separator: "|").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

enum ConnectorSourceError: Error, Equatable { case invalid, expired, disconnected, changed }

enum ConnectorSourceValidation {
    /// Re-check immediately before approval. Both authorization and result bytes
    /// are checked again after the async read; uncertainty is denial.
    @MainActor static func requireCurrent(_ sources: [ConnectorSource],
        clock: @escaping @MainActor @Sendable () -> Date = { Date() },
        enabled: @escaping @MainActor @Sendable () -> Set<ConnectorID>,
        permission: @escaping @MainActor @Sendable (ConnectorID) -> ConnectorPermission,
        read: @escaping @MainActor @Sendable (ConnectorID, String?) async throws -> ConnectorReadResult) async throws {
        guard sources.count <= 6, Set(sources.map { "\($0.connector.rawValue)|\($0.query ?? "")" }).count == sources.count else {
            throw ConnectorSourceError.invalid
        }
        for source in sources {
            try Task.checkCancellation()
            let before = clock()
            guard source.isValid(now: before) else {
                throw before >= source.expiresAt ? ConnectorSourceError.expired : ConnectorSourceError.invalid
            }
            guard enabled().contains(source.connector), [.allowed, .limited].contains(permission(source.connector)) else {
                throw ConnectorSourceError.disconnected
            }
            let current: ConnectorReadResult
            do { current = try await read(source.connector, source.query) }
            catch is CancellationError { throw CancellationError() }
            catch { throw ConnectorSourceError.changed }
            try Task.checkCancellation()
            guard clock() < source.expiresAt else { throw ConnectorSourceError.expired }
            guard enabled().contains(source.connector),
                  [.allowed, .limited].contains(permission(source.connector)) else {
                throw ConnectorSourceError.disconnected
            }
            guard current.connector == source.connector,
                  ConnectorSource.normalizedQuery(source.query) == source.query,
                  ConnectorSource.digest(current) == source.resultDigest else {
                throw ConnectorSourceError.changed
            }
        }
    }
}

extension NativeConnectionClient {
    func readAttributed(_ id: ConnectorID, query: String?) async throws -> ConnectorReadResult {
        .init(connector: id, fetchedAt: Date(), records: [.init(fields: ["summary": try await read(id, query: query)])], totalCount: 1)
    }
}
extension AppleConnectionClient {
    func readAttributed(_ id: ConnectorID, query: String?) async throws -> ConnectorReadResult {
        guard [.allowed, .limited].contains(permission(id)) else { throw ToolFailure.missingPermission }
        let now = Date()
        var records: [ConnectorFieldRecord] = []
        let count: Int
        switch id {
        case .calendar:
            // Today by default; "tomorrow" reads the next day. Nothing further ahead.
            let events = EKEventStore(), today = Calendar.current.startOfDay(for: now)
            guard let start = Calendar.current.date(byAdding: .day, value: ConnectorSource.calendarDayOffset(query), to: today),
                  let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { throw ToolFailure.invalidArguments }
            let items = events.events(matching: events.predicateForEvents(withStart: start, end: end, calendars: nil)).sorted { $0.startDate < $1.startDate }
            count = items.count
            let format = ISO8601DateFormatter()
            records = items.prefix(5).map { .init(fields: ["title": String(($0.title ?? "Untitled event").prefix(160)),
                "start": format.string(from: $0.startDate), "allDay": $0.isAllDay ? "true" : "false"]) }
        case .reminders:
            let events = EKEventStore()
            let predicate = events.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            let fetched: [EKReminder]? = await withCheckedContinuation { continuation in events.fetchReminders(matching: predicate) { continuation.resume(returning: $0) } }
            guard let items = fetched else { throw CocoaError(.fileReadUnknown) }
            count = items.count
            records = items.sorted { ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture) }.prefix(5).map { item in
                var fields = ["title": String((item.title ?? "Untitled reminder").prefix(160))]
                if let date = item.dueDateComponents?.date { fields["due"] = ISO8601DateFormatter().string(from: date) }
                return .init(fields: fields)
            }
        case .contacts:
            guard let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, query.count <= 120 else { throw ToolFailure.invalidArguments }
            let contacts = try CNContactStore().unifiedContacts(matching: CNContact.predicateForContacts(matchingName: query),
                keysToFetch: [CNContactFormatter.descriptorForRequiredKeys(for: .fullName), CNContactEmailAddressesKey as CNKeyDescriptor, CNContactPhoneNumbersKey as CNKeyDescriptor])
            count = contacts.count
            records = contacts.prefix(3).map { contact in
                var fields = ["name": String((CNContactFormatter.string(from: contact, style: .fullName) ?? "Unnamed contact").prefix(160))]
                if let email = contact.emailAddresses.first { fields["email"] = String(String(email.value).prefix(160)) }
                else if let phone = contact.phoneNumbers.first { fields["phone"] = String(phone.value.stringValue.prefix(80)) }
                return .init(fields: fields)
            }
        default: throw ToolFailure.unavailable
        }
        try Task.checkCancellation()
        guard [.allowed, .limited].contains(permission(id)) else { throw ToolFailure.missingPermission }
        return .init(connector: id, fetchedAt: now, records: records, totalCount: count)
    }
}

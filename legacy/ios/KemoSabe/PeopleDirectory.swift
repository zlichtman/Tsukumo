import Foundation
import CryptoKit

enum PeopleSourceKind: String, Codable, CaseIterable, Sendable {
    case contacts, note, linkedIn, spotify, messages, other
    var title: String { switch self { case .contacts: "Apple Contacts"; case .note: "Your note"; case .linkedIn: "LinkedIn"; case .spotify: "Spotify"; case .messages: "Messages"; case .other: "Other source" } }
    var symbol: String { switch self { case .contacts: "person.crop.rectangle.stack"; case .note: "note.text"; case .linkedIn: "briefcase"; case .spotify: "music.note"; case .messages: "bubble.left.and.bubble.right"; case .other: "link" } }
}
enum PeopleFieldKind: String, Codable, CaseIterable, Sendable {
    case name, email, phone, company, role, context, interest, followUp, observation
    var title: String { switch self { case .name: "Name"; case .email: "Email"; case .phone: "Phone"; case .company: "Organization"; case .role: "Role"; case .context: "How you know them"; case .interest: "Shared interests"; case .followUp: "Follow up on"; case .observation: "Context" } }
}
struct PeopleField: Codable, Equatable, Sendable { var kind: PeopleFieldKind; var value: String }
struct PeopleSource: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var kind: PeopleSourceKind
    var label: String
    var reference: String? = nil
    var contactIdentifier: String? = nil
    var fields: [PeopleField]
    var addedAt = Date()
    /// When the underlying interaction happened, explicitly supplied by the user.
    /// Import time is never presented as last contact or relationship recency.
    var happenedAt: Date? = nil
    var contentRevision: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let values = fields.map { $0.kind.rawValue + ":" + $0.value }.sorted()
        let payload = [kind.rawValue, label, reference ?? "", contactIdentifier ?? ""] + values
        return SHA256.hash(data: (try? encoder.encode(payload)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
    static func safeReference(_ value: String) -> Bool {
        guard let url = URLComponents(string: value), url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, value.count <= 2048 else { return false }
        return !value.contains(where: { $0.isNewline || $0.asciiValue.map { $0 < 32 } == true })
    }
    func validate() throws {
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, label.count <= 120,
              !fields.isEmpty, fields.count <= 40, fields.allSatisfy({ !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.value.count <= 4000 }),
              reference == nil || Self.safeReference(reference!),
              addedAt.timeIntervalSince1970.isFinite, happenedAt == nil || happenedAt!.timeIntervalSince1970.isFinite,
              kind != .contacts || (contactIdentifier?.isEmpty == false && contactIdentifier!.count <= 500),
              kind == .contacts || contactIdentifier == nil else { throw PeopleError.invalid }
    }
}
enum PeopleCircle: String, Codable, CaseIterable, Sendable {
    case friends = "Friends", work = "Work", family = "Family", dating = "Dating", acquaintances = "Acquaintances"
}
struct PeopleProfile: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var sources: [PeopleSource]
    var circles: [PeopleCircle] = []
    /// A full profile: their picture, a wide background, and what you'd say about them.
    var photo: String?
    var banner: String?
    var about: String?
    var name: String {
        // An explicitly entered name takes precedence; imported alternatives stay visible.
        sources.sorted { ($0.kind == .contacts ? 1 : 0) < ($1.kind == .contacts ? 1 : 0) }
            .flatMap(\.fields).first { $0.kind == .name }?.value ?? "Unnamed person"
    }
    var subtitle: String {
        let fields = sources.flatMap(\.fields)
        return [fields.first { $0.kind == .role }?.value, fields.first { $0.kind == .company }?.value].compactMap { $0 }.joined(separator: " · ")
    }
    var searchable: String { ([name, about ?? ""] + circles.map(\.rawValue) + sources.flatMap { [$0.label] + $0.fields.map(\.value) }).joined(separator: " ") }
    var initials: String { name.split(whereSeparator: \.isWhitespace).prefix(2).compactMap(\.first).map(String.init).joined().uppercased() }
    var lastInteraction: Date? { sources.compactMap(\.happenedAt).max() }
}
struct PeopleDuplicate: Identifiable, Equatable {
    let left: UUID; let right: UUID; let reason: String
    var id: String { left.uuidString + right.uuidString }
}
enum PeopleError: LocalizedError, Equatable {
    case invalid, tooLarge, changed, permission, storage
    var errorDescription: String? { switch self {
        case .invalid: "This profile contains invalid or unsupported information. Check the fields and use a complete HTTPS profile link."
        case .tooLarge: "This collection is too large. Choose fewer contacts or remove older sources before adding more."
        case .changed: "The selected contacts changed. Refresh and review them again before importing."
        case .permission: "Contacts access changed. Reconnect Contacts and choose which people KemoSabe can use."
        case .storage: "The profile could not be saved. Resolve the storage error before making more changes."
    } }
}
struct PeopleDirectory: Codable, Equatable, Sendable {
    var profiles: [PeopleProfile] = []
    func validate() throws {
        guard profiles.count <= 3000, profiles.reduce(0, { $0 + $1.sources.count }) <= 9000 else { throw PeopleError.tooLarge }
        guard Set(profiles.map(\.id)).count == profiles.count else { throw PeopleError.invalid }
        let sources = profiles.flatMap(\.sources)
        guard Set(sources.map(\.id)).count == sources.count,
              Set(sources.compactMap(\.contactIdentifier)).count == sources.compactMap(\.contactIdentifier).count,
              profiles.allSatisfy({ !$0.sources.isEmpty && $0.sources.count <= 100 && Set($0.circles).count == $0.circles.count
                  && ($0.about?.count ?? 0) <= 2000 && [$0.photo, $0.banner].allSatisfy { $0 == nil || PeopleMedia.safe($0!) } }) else { throw PeopleError.invalid }
        for source in sources { try source.validate() }
    }
    /// Profile data is not a memory note, model context, matching consent, or an
    /// execution grant. All inference/disclosure adapters remain denied by default.
    func visible(contactIDs: Set<String>) -> Self {
        .init(profiles: profiles.compactMap { profile in
            var visible = profile
            visible.sources.removeAll { $0.kind == .contacts && !contactIDs.contains($0.contactIdentifier ?? "") }
            return visible.sources.isEmpty ? nil : visible
        })
    }
    mutating func upsertContacts(_ sources: [PeopleSource]) throws {
        var next = self
        for source in sources {
            guard source.kind == .contacts, let key = source.contactIdentifier else { throw PeopleError.invalid }
            if let p = next.profiles.firstIndex(where: { $0.sources.contains { $0.contactIdentifier == key } }),
               let s = next.profiles[p].sources.firstIndex(where: { $0.contactIdentifier == key }) {
                var refreshed = source; refreshed.id = next.profiles[p].sources[s].id
                next.profiles[p].sources[s] = refreshed
            } else { next.profiles.append(.init(sources: [source])) }
        }
        try next.validate(); self = next
    }
    mutating func reconcileContacts(_ sources: [PeopleSource], requested: Set<String>) throws {
        let current = Set(sources.compactMap(\.contactIdentifier))
        profiles = profiles.compactMap { profile in
            var next = profile
            next.sources.removeAll { source in source.kind == .contacts && requested.contains(source.contactIdentifier ?? "") && !current.contains(source.contactIdentifier ?? "") }
            return next.sources.isEmpty ? nil : next
        }
        // Refresh existing imported records only; reconciliation cannot add a person.
        let retained = Set(profiles.flatMap(\.sources).compactMap(\.contactIdentifier))
        try upsertContacts(sources.filter { retained.contains($0.contactIdentifier ?? "") })
    }
    mutating func removeContacts() { profiles = visible(contactIDs: []).profiles }
    mutating func add(_ source: PeopleSource, to personID: UUID?) throws {
        var next = self
        if let personID {
            guard let index = next.profiles.firstIndex(where: { $0.id == personID }) else { throw PeopleError.changed }
            if let old = next.profiles[index].sources.firstIndex(where: { $0.id == source.id }) { next.profiles[index].sources[old] = source }
            else { next.profiles[index].sources.append(source) }
        } else { next.profiles.append(.init(sources: [source])) }
        try next.validate(); self = next
    }
    mutating func merge(_ from: UUID, into target: UUID) throws {
        guard from != target, let a = profiles.firstIndex(where: { $0.id == from }), let b = profiles.firstIndex(where: { $0.id == target }) else { throw PeopleError.changed }
        var next = self
        next.profiles[b].sources += next.profiles[a].sources
        next.profiles[b].circles = PeopleCircle.allCases.filter { next.profiles[a].circles.contains($0) || next.profiles[b].circles.contains($0) }
        next.profiles.removeAll { $0.id == from }; try next.validate(); self = next
    }
    mutating func separate(_ sourceID: UUID, from personID: UUID) throws {
        guard let p = profiles.firstIndex(where: { $0.id == personID }), profiles[p].sources.count > 1,
              let s = profiles[p].sources.firstIndex(where: { $0.id == sourceID }) else { throw PeopleError.changed }
        let source = profiles[p].sources.remove(at: s)
        // Circle membership belongs to the reviewed person, not a detached source.
        profiles.append(.init(sources: [source])); try validate()
    }
    mutating func removeSource(_ sourceID: UUID, personID: UUID) {
        guard let p = profiles.firstIndex(where: { $0.id == personID }) else { return }
        profiles[p].sources.removeAll { $0.id == sourceID }; profiles.removeAll { $0.sources.isEmpty }
    }
    var duplicates: [PeopleDuplicate] {
        var index: [String: [UUID]] = [:]
        for profile in profiles {
            let keys = Set(profile.sources.flatMap(\.fields).compactMap(Self.identityKey))
            for key in keys { index[key, default: []].append(profile.id) }
        }
        var seen = Set<String>(); var result: [PeopleDuplicate] = []
        for (key, ids) in index.sorted(by: { $0.key < $1.key }) where ids.count > 1 {
            // A shared address may be a household/organization. It is a review
            // suggestion, never enough evidence to merge or infer a relationship.
            for other in ids.dropFirst() {
                let pair = [ids[0], other].sorted { $0.uuidString < $1.uuidString }
                let id = pair.map(\.uuidString).joined()
                if seen.insert(id).inserted { result.append(.init(left: pair[0], right: pair[1], reason: key.hasPrefix("email:") ? "Same email address" : "Same phone number")) }
            }
        }
        return result
    }
    static func identityKey(_ field: PeopleField) -> String? {
        let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
        if field.kind == .email, value.contains("@") { return "email:" + value.lowercased() }
        if field.kind == .phone {
            let digits = value.filter(\.isNumber)
            guard (8...15).contains(digits.count), !value.lowercased().contains("x"), !value.contains("#") else { return nil }
            return "phone:" + (value.hasPrefix("+") ? "+" : "local:") + digits
        }
        return nil // Names, taste, employers, and social circles are not identity keys.
    }
    static func validateImport(offered: [PeopleSource], current: [PeopleSource], permitted: Bool) throws {
        guard permitted else { throw PeopleError.permission }
        let before = Dictionary(offered.map { ($0.contactIdentifier ?? "", $0.contentRevision) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(current.map { ($0.contactIdentifier ?? "", $0.contentRevision) }, uniquingKeysWith: { first, _ in first })
        guard before.count == offered.count, after.count == current.count, !before.isEmpty, before == after else { throw PeopleError.changed }
    }
}

extension AppStore {
    func updatePeople(_ change: (inout PeopleDirectory) throws -> Void) throws {
        guard storageError == nil else { throw PeopleError.storage }
        var directory = state.people ?? PeopleDirectory()
        try change(&directory); try directory.validate()
        let previous = state.people; state.people = directory; save()
        if storageError != nil { state.people = previous; throw PeopleError.storage }
    }
}

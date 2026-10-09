import Contacts
import Foundation
import TsukumoCore
import TsukumoPolicy

// Contacts: the card of someone a bot's question names ("What's Sarah's birthday?"), looked up by name
// on this device when the question arrives. Never the whole address book. On a Mac the app needs the
// Contacts entitlement under the hardened runtime. Contacts also lets Messages on a Mac find a named
// person's chats by their phone numbers and email addresses.

/// What KemoSabe reads of one contact.
public struct ContactCard: Hashable, Sendable {
    public var id: String
    public var name: String
    /// The parts of the name, when the card has them (the KemoSabe gateway sends a first name alone).
    public var givenName: String = ""
    public var familyName: String = ""
    public var organization: String = ""
    public var phones: [String] = []
    public var emails: [String] = []
    public var birthday: DateComponents?
    /// City and region only; never the street.
    public var place: String = ""
    public init(id: String, name: String, organization: String = "", phones: [String] = [], emails: [String] = [],
                birthday: DateComponents? = nil, place: String = "", givenName: String = "", familyName: String = "") {
        self.id = id; self.name = name; self.organization = organization; self.phones = phones; self.emails = emails
        self.birthday = birthday; self.place = place; self.givenName = givenName; self.familyName = familyName
    }

    /// What Apple's on-device model reads.
    public var text: String {
        var lines = ["Contact: " + name]
        if !organization.isEmpty { lines.append("Works at: " + organization) }
        if !phones.isEmpty { lines.append("Phone: " + phones.joined(separator: ", ")) }
        if !emails.isEmpty { lines.append("Email: " + emails.joined(separator: ", ")) }
        if let birthday, let month = birthday.month, let day = birthday.day {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            let names: [String] = formatter.monthSymbols
            lines.append("Birthday: \(names[max(0, min(11, month - 1))]) \(day)" + (birthday.year.map { ", \($0)" } ?? ""))
        }
        if !place.isEmpty { lines.append("Lives in: " + place) }
        return lines.joined(separator: "\n")
    }
}

/// Looks people up by name.
public protocol ContactsReading: Sendable {
    func contacts(named name: String) async -> [ContactCard]
}

/// The system's Contacts.
public struct SystemContacts: ContactsReading {
    public init() {}
    public static var status: SourcePermission {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited: .granted
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        default: .denied
        }
    }
    public static func request() async -> SourcePermission {
        _ = try? await CNContactStore().requestAccess(for: .contacts)
        return status
    }
    public func contacts(named name: String) async -> [ContactCard] {
        guard Self.status == .granted else { return [] }
        let keys: [CNKeyDescriptor] = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName), CNContactOrganizationNameKey as CNKeyDescriptor,
                                       CNContactPhoneNumbersKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor,
                                       CNContactBirthdayKey as CNKeyDescriptor, CNContactPostalAddressesKey as CNKeyDescriptor]
        let found = (try? CNContactStore().unifiedContacts(matching: CNContact.predicateForContacts(matchingName: name), keysToFetch: keys)) ?? []
        return found.prefix(5).map { contact in
            let address = contact.postalAddresses.first?.value
            return ContactCard(id: contact.identifier, name: CNContactFormatter.string(from: contact, style: .fullName) ?? name,
                               organization: contact.organizationName,
                               phones: contact.phoneNumbers.map(\.value.stringValue), emails: contact.emailAddresses.map { $0.value as String },
                               birthday: contact.birthday,
                               place: [address?.city, address?.state].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "),
                               givenName: contact.givenName, familyName: contact.familyName)
        }
    }
}

/// The contact cards of the people a question names (at most three names, five cards each).
public struct ContactsSource: PersonalSource {
    public let level: PrivacyLevel
    public let reader: any ContactsReading
    public init(level: PrivacyLevel, reader: any ContactsReading = SystemContacts()) { self.level = level; self.reader = reader }
    public func items(matching question: GateQuestion) async -> [PersonalItem] {
        var seen = Set<String>(), items: [PersonalItem] = []
        for name in MessagesQuery.capitalizedNames(in: question.question).prefix(3) {
            for card in await reader.contacts(named: name) where seen.insert(card.id).inserted {
                items.append(PersonalItem(id: "contact:" + card.id, kind: .contact, level: level, title: "your contact card for \(card.name)",
                                          text: card.text, matched: true))
            }
        }
        return items
    }
}

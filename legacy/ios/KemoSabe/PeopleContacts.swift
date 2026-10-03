import Foundation
import Contacts

struct PeopleContactsReader: Sendable {
    static var permitted: Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        #if os(iOS)
        return status == .authorized || status == .limited
        #else
        return status == .authorized
        #endif
    }
    func fetch(identifiers: Set<String>? = nil, query: String = "") async throws -> [PeopleSource] {
        guard Self.permitted else { throw PeopleError.permission }
        if identifiers?.isEmpty == true { return [] }
        let worker = Task.detached(priority: .userInitiated) { () throws -> [PeopleSource] in
            guard Self.permitted else { throw PeopleError.permission }
            let store = CNContactStore()
            let keys: [CNKeyDescriptor] = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName), CNContactIdentifierKey as CNKeyDescriptor,
                CNContactEmailAddressesKey as CNKeyDescriptor, CNContactPhoneNumbersKey as CNKeyDescriptor,
                CNContactOrganizationNameKey as CNKeyDescriptor, CNContactJobTitleKey as CNKeyDescriptor]
            let request = CNContactFetchRequest(keysToFetch: keys)
            request.unifyResults = true; request.sortOrder = .userDefault
            if let identifiers { request.predicate = CNContact.predicateForContacts(withIdentifiers: Array(identifiers)) }
            else if !query.isEmpty { request.predicate = CNContact.predicateForContacts(matchingName: query) }
            var records: [PeopleSource] = []; var failure: Error?
            try store.enumerateContacts(with: request) { contact, stop in
                if Task.isCancelled { failure = CancellationError(); stop.pointee = true; return }
                if records.count >= 10_000 { failure = PeopleError.tooLarge; stop.pointee = true; return }
                var fields = [PeopleField(kind: .name, value: CNContactFormatter.string(from: contact, style: .fullName) ?? "Unnamed contact")]
                fields += contact.emailAddresses.map { .init(kind: .email, value: String($0.value)) }.filter { !$0.value.isEmpty }
                fields += contact.phoneNumbers.map { .init(kind: .phone, value: $0.value.stringValue) }.filter { !$0.value.isEmpty }
                if !contact.organizationName.isEmpty { fields.append(.init(kind: .company, value: contact.organizationName)) }
                if !contact.jobTitle.isEmpty { fields.append(.init(kind: .role, value: contact.jobTitle)) }
                let record = PeopleSource(kind: .contacts, label: "Apple Contacts", contactIdentifier: contact.identifier, fields: fields)
                do { try record.validate(); records.append(record) }
                catch { failure = error; stop.pointee = true }
            }
            if let failure { throw failure }
            try Task.checkCancellation()
            guard Self.permitted else { throw PeopleError.permission }
            return records
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    /// Contact photos for people you imported, used once as their profile picture.
    func thumbnails(for identifiers: Set<String>) async -> [String: Data] {
        guard Self.permitted, !identifiers.isEmpty else { return [:] }
        return await Task.detached(priority: .utility) { () -> [String: Data] in
            let request = CNContactFetchRequest(keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor, CNContactThumbnailImageDataKey as CNKeyDescriptor])
            request.predicate = CNContact.predicateForContacts(withIdentifiers: Array(identifiers))
            var result: [String: Data] = [:]
            try? CNContactStore().enumerateContacts(with: request) { contact, _ in
                if let data = contact.thumbnailImageData { result[contact.identifier] = data }
            }
            return result
        }.value
    }
}

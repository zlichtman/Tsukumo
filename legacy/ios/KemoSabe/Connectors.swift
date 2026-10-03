import Foundation
import EventKit
import Contacts
import Observation

enum ConnectorID: String, CaseIterable, Identifiable, Codable {
    case calendar, reminders, contacts, gmail, outlook, appleMusic, slack, notion, github, spotify
    var id: String { rawValue }
    var logoAsset: String? {
        switch self {
        case .gmail: return "ConnectorGmail"
        case .spotify: return "ConnectorSpotify"
        case .notion: return "ConnectorNotion"
        case .github: return "ConnectorGitHub"
        case .appleMusic: return "ConnectorMusic"
        default: return nil
        }
    }
    var isNative: Bool { [.calendar, .reminders, .contacts].contains(self) }
    var title: String {
        switch self {
        case .calendar: return "Calendar"
        case .reminders: return "Reminders"
        case .contacts: return "Contacts"
        case .gmail: return "Gmail"
        case .outlook: return "Outlook"
        case .appleMusic: return "Apple Music"
        case .slack: return "Slack"
        case .notion: return "Notion"
        case .github: return "GitHub"
        case .spotify: return "Spotify"
        }
    }
    var symbol: String {
        switch self {
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        case .contacts: return "person.crop.circle"
        case .gmail, .outlook: return "envelope"
        case .appleMusic, .spotify: return "music.note"
        case .slack: return "bubble.left.and.bubble.right"
        case .notion: return "book.closed"
        case .github: return "chevron.left.forwardslash.chevron.right"
        }
    }
    var summary: String {
        switch self {
        case .calendar: return "Today’s meetings, when you ask."
        case .reminders: return "Read your unfinished reminders."
        case .contacts: return "Find a person’s contact details."
        case .gmail, .outlook: return "Email connection not in this build."
        case .appleMusic: return "Music connection not in this build."
        case .slack, .notion, .github: return "Work connection not in this build."
        case .spotify: return "Voice control needs Spotify approval."
        }
    }
    var example: String {
        switch self {
        case .calendar: return "What’s on my calendar today?"
        case .reminders: return "Read my reminders"
        case .contacts: return "Find contact Alex"
        default: return "Connect \(title)"
        }
    }
    var explanation: String {
        switch self {
        case .calendar: return "Apple’s calendar permission includes read and write access. KemoSabe reads your calendar when you ask. Routine changes require a selected destination and either exact approval or a standing permission in Your day. Only Kemo-created blocks can be moved."
        case .reminders: return "Apple’s reminders permission includes read and write access. KemoSabe reads unfinished reminders when you ask. Creating or rescheduling KemoSabe reminders requires a selected list and either exact approval or a standing permission in Your day."
        case .contacts: return "Choose selected contacts or full access in Apple’s permission screen. KemoSabe looks up the person you ask for and can save selected contacts in your private People directory. It does not edit your address book or send profiles to model connections."
        case .gmail, .outlook, .slack, .notion, .github: return "Account sign-in and service registration are not configured in this build. No account is connected and no data is accessed."
        case .appleMusic: return "Music authorization and playback are not implemented in this build. No music account is connected."
        case .spotify: return "Spotify’s current developer policy prohibits third-party voice control. This connection needs an approved arrangement before it can be offered. No account is connected."
        }
    }
    static func named(_ text: String) -> Self? {
        switch text {
        case "calendar", "calendars", "apple calendar": return .calendar
        case "reminders", "apple reminders", "reminder list": return .reminders
        case "contacts", "address book": return .contacts
        case "gmail", "google mail": return .gmail
        case "outlook", "microsoft outlook", "microsoft 365": return .outlook
        case "apple music": return .appleMusic
        case "slack": return .slack
        case "notion": return .notion
        case "github", "git hub": return .github
        case "spotify": return .spotify
        default: return nil
        }
    }
}

/// Apple's permission for a native connection. `writeOnly` is Calendar's "Add Events Only", which
/// lets KemoSabe add events but not read them, so it can't answer what's on your calendar.
enum ConnectorPermission: Equatable, Sendable { case notDetermined, allowed, limited, writeOnly, denied, restricted }
enum ConnectorStatus: String {
    case disconnected = "Not connected", connected = "Connected", limited = "Selected contacts", writeOnly = "Add events only",
         denied = "Access denied", restricted = "Restricted", unavailable = "Not available"
    var usable: Bool { self == .connected || self == .limited }
    static func resolve(native: Bool, enabled: Bool, permission: ConnectorPermission) -> Self {
        guard native else { return .unavailable }
        if permission == .restricted { return .restricted }
        if permission == .denied { return .denied }
        if permission == .writeOnly { return .writeOnly }
        guard enabled else { return .disconnected }
        return permission == .allowed ? .connected : permission == .limited ? .limited : .disconnected
    }
    /// Whether the fix is in the system's Settings, so the page offers a button that opens it.
    var opensSystemSettings: Bool { [.denied, .restricted, .limited, .writeOnly].contains(self) }
    /// What to tell the person when Apple's permission is what stands in the way: plain, specific,
    /// and naming where to change it. Nil when there's nothing to fix in Settings.
    func guidance(for id: ConnectorID) -> String? {
        #if os(macOS)
        let place = "System Settings → Privacy & Security → " + id.settingsName
        #else
        let place = "Settings → KemoSabe → " + id.settingsName
        #endif
        switch self {
        case .writeOnly:
            return "KemoSabe can only add events. In \(place), choose Full Access."
        case .denied:
            return id == .contacts ? "KemoSabe isn’t allowed to see your contacts. In \(place), choose Full Access or the contacts to share."
                : "KemoSabe isn’t allowed to see your \(id.title.lowercased()). In \(place), choose Full Access."
        case .restricted:
            return "\(id.title) access is restricted on this device by Screen Time or a device management profile, so KemoSabe can’t ask for it. Whoever manages this device can change it in Screen Time → Content & Privacy Restrictions."
        case .limited:
            return "KemoSabe sees only the contacts you chose. To share more, go to \(place)."
        default: return nil
        }
    }
}

extension ConnectorID {
    /// The name of this permission's row in the system's Settings.
    var settingsName: String { self == .calendar ? "Calendars" : title }
}

extension SavedState {
    /// KemoSabe's own switch for a native connection: with Apple's permission, the one source of
    /// truth for "connected". It's on unless the person disconnected it here, so permission granted
    /// through any flow (Connections, Day, People, the onboarding primer, or iOS Settings) counts.
    func kemoAllows(_ id: ConnectorID) -> Bool {
        guard id.isNative else { return false }
        return enabledConnectors?.contains(id.rawValue) == true || disconnectedConnectors?.contains(id.rawValue) != true
    }
    /// Native connections KemoSabe's switch allows; Apple's permission is checked separately.
    var kemoAllowedConnectors: Set<ConnectorID> { Set(ConnectorID.allCases.filter { kemoAllows($0) }) }
    /// Connect: KemoSabe may use it again. Clears an earlier Disconnect.
    mutating func markConnected(_ id: ConnectorID) {
        var enabled = enabledConnectors ?? []
        if !enabled.contains(id.rawValue) { enabled.append(id.rawValue) }
        enabledConnectors = enabled
        disconnectedConnectors?.removeAll { $0 == id.rawValue }
        if disconnectedConnectors?.isEmpty == true { disconnectedConnectors = nil }
    }
    /// Disconnect: remembered, so Apple's permission alone never turns it back on.
    mutating func markDisconnected(_ id: ConnectorID) {
        enabledConnectors?.removeAll { $0 == id.rawValue }
        var disconnected = disconnectedConnectors ?? []
        if !disconnected.contains(id.rawValue) { disconnected.append(id.rawValue) }
        disconnectedConnectors = disconnected
    }
    /// Connections a connected API model may read by its own grant ("Always for this model"): its
    /// durable `RecipientGrant`s for connector items. Apple's models need none; a grant for one model
    /// never covers another.
    func apiGrants(_ profile: UUID, now: Date = Date()) -> Set<ConnectorID> {
        let key = RecipientID.apiModel(profile: profile, host: "").key
        return Set((recipientGrants ?? []).filter { $0.recipient == key && $0.purpose == ContextPurpose.conversation.rawValue && !$0.singleUse && $0.isLive(now: now) }
            .flatMap { $0.items ?? [] }.compactMap { key in
                key.hasPrefix("connector:") ? ConnectorID(rawValue: String(key.dropFirst("connector:".count))) : nil
            }.filter(\.isNative))
    }
    mutating func setAPIGrant(_ id: ConnectorID, profile: UUID, allowed: Bool) {
        guard id.isNative else { return }
        let recipient = RecipientID.apiModel(profile: profile, host: "")
        let item = ContextItem.connector(id).ref
        var grants = (recipientGrants ?? []).filter { !($0.recipient == recipient.key && $0.purpose == ContextPurpose.conversation.rawValue && $0.coversItem(item) && !$0.singleUse) }
        if allowed { grants.append(RecipientGrant(recipient: recipient, items: [item], purpose: .conversation)) }
        recipientGrants = grants.isEmpty ? nil : grants
    }
    /// A removed connection's grants go with it; a later connection never inherits them.
    mutating func removeGrants(for recipient: RecipientID) {
        recipientGrants?.removeAll { $0.recipient == recipient.key }
        if recipientGrants?.isEmpty == true { recipientGrants = nil }
    }
    /// Moves the per-model connection grants of builds before `RecipientGrant` into the account's
    /// grants, once, keeping every one. Returns whether anything changed.
    @discardableResult mutating func migrateLegacyConnectorGrants(now: Date = Date()) -> Bool {
        guard let legacy = apiConnectorGrants else { return false }
        for (profile, connectors) in legacy.sorted(by: { $0.key < $1.key }) {
            guard let id = UUID(uuidString: profile) else { continue }
            for connector in connectors.compactMap(ConnectorID.init(rawValue:)) where !apiGrants(id, now: now).contains(connector) {
                setAPIGrant(connector, profile: id, allowed: true)
            }
        }
        apiConnectorGrants = nil
        return true
    }
}

/// Who a turn's tool results reach, with the name its prompts use and the grants it holds.
/// Each connected model is its own recipient with its own grants; being selected never gives it
/// private data.
struct ToolRecipient: Equatable, Sendable {
    let id: RecipientID
    let name: String
    let grants: [RecipientGrant]
    static let onDevice = Self.apple(.onDevice)
    static func apple(_ model: AppleModel) -> Self { .init(id: model.recipient, name: model.title, grants: []) }
    static func api(_ profile: APIModelProfile, grants: [RecipientGrant]) -> Self {
        .init(id: .api(profile), name: profile.name, grants: grants)
    }
    /// A connected model holding "Always for this model" grants for these connections.
    static func apiModel(profile: UUID, name: String, host: String, granted: Set<ConnectorID>) -> Self {
        let recipient = RecipientID.apiModel(profile: profile, host: host)
        return .init(id: recipient, name: name, grants: granted.sorted { $0.rawValue < $1.rawValue }.map {
            RecipientGrant(recipient: recipient, items: [ContextItem.connector($0).ref], purpose: .conversation)
        })
    }
}

/// A connected model asked for a connection it hasn't been allowed to read. Nothing was read or
/// sent; the reply says which connection, which model, and how to allow it.
struct ConnectorGrantRequired: Error, LocalizedError, Equatable, Sendable {
    let connector: ConnectorID
    let profile: UUID
    let modelName: String
    let host: String
    /// What the inline prompt and the model's page ask.
    var question: String { "Let \(modelName) read your \(connector.title)? Results are sent to \(host)." }
    var errorDescription: String? {
        "\(modelName) isn’t allowed to read your \(connector.title) yet, so nothing was read or sent. Choose Allow below, or turn on \(connector.title) for \(modelName) in Settings → Models. What it reads is sent to \(host)."
    }
}

/// The person's answer to "Let <model> read your <connection>?".
enum ConnectorGrantDecision: Equatable, Sendable { case once, always, deny }

protocol NativeConnectionClient: Sendable {
    func permission(_ id: ConnectorID) -> ConnectorPermission
    func request(_ id: ConnectorID) async throws -> Bool
    func read(_ id: ConnectorID, query: String?) async throws -> String
    func readAttributed(_ id: ConnectorID, query: String?) async throws -> ConnectorReadResult
}

struct AppleConnectionClient: NativeConnectionClient {
    func permission(_ id: ConnectorID) -> ConnectorPermission {
        if id == .contacts {
            switch CNContactStore.authorizationStatus(for: .contacts) {
            case .authorized: return .allowed
            case .limited: return .limited
            case .denied: return .denied
            case .restricted: return .restricted
            default: return .notDetermined
            }
        }
        guard id == .calendar || id == .reminders else { return .restricted }
        switch EKEventStore.authorizationStatus(for: id == .calendar ? .event : .reminder) {
        case .fullAccess: return .allowed
        case .writeOnly: return .writeOnly
        case .denied: return .denied
        case .restricted: return .restricted
        default: return .notDetermined
        }
    }
    func request(_ id: ConnectorID) async throws -> Bool {
        switch id {
        case .calendar: return try await EKEventStore().requestFullAccessToEvents()
        case .reminders: return try await EKEventStore().requestFullAccessToReminders()
        case .contacts: return try await CNContactStore().requestAccess(for: .contacts)
        default: return false
        }
    }
    // Read only, on demand. No LLM, remote endpoint, or memory write.
    func read(_ id: ConnectorID, query: String?) async throws -> String {
        guard [.allowed, .limited].contains(permission(id)) else { throw CocoaError(.userCancelled) }
        switch id {
        case .calendar:
            let events = EKEventStore()
            let start = Calendar.current.startOfDay(for: Date())
            let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
            let items = events.events(matching: events.predicateForEvents(withStart: start, end: end, calendars: nil)).sorted { $0.startDate < $1.startDate }
            guard !items.isEmpty else { return "There are no events on your calendar today." }
            let formatter = DateFormatter(); formatter.timeStyle = .short
            let lines = items.prefix(5).map { event in "\(event.isAllDay ? "All day" : formatter.string(from: event.startDate)): \(String((event.title ?? "Untitled event").prefix(160)))." }
            return "Today: " + lines.joined(separator: " ") + (items.count > 5 ? " And \(items.count - 5) more events." : "")
        case .reminders:
            let events = EKEventStore()
            let predicate = events.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            let fetched: [EKReminder]? = await withCheckedContinuation { continuation in events.fetchReminders(matching: predicate) { continuation.resume(returning: $0) } }
            guard let items = fetched else { throw CocoaError(.fileReadUnknown) }
            let sorted = items.sorted { ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture) }
            guard !sorted.isEmpty else { return "You have no unfinished reminders." }
            return "Your reminders: " + sorted.prefix(5).map { String(($0.title ?? "Untitled reminder").prefix(160)) + "." }.joined(separator: " ") + (items.count > 5 ? " And \(items.count - 5) more." : "")
        case .contacts:
            guard let query, !query.isEmpty else { return "Who should I look up? Say find contact, followed by their name." }
            let contacts = try CNContactStore().unifiedContacts(matching: CNContact.predicateForContacts(matchingName: query), keysToFetch: [CNContactFormatter.descriptorForRequiredKeys(for: .fullName), CNContactEmailAddressesKey as CNKeyDescriptor, CNContactPhoneNumbersKey as CNKeyDescriptor])
            guard !contacts.isEmpty else { return "I couldn’t find \(query) in the contacts shared with KemoSabe." }
            return contacts.prefix(3).map { contact in
                let name = CNContactFormatter.string(from: contact, style: .fullName) ?? "Unnamed contact"
                let detail = contact.emailAddresses.first.map { String($0.value) } ?? contact.phoneNumbers.first?.value.stringValue ?? "No email or phone number saved"
                return "\(name): \(detail)."
            }.joined(separator: " ") + (contacts.count > 3 ? " There are more matches. Try a full name." : "")
        default: throw CocoaError(.featureUnsupported)
        }
    }
}

@MainActor @Observable final class ConnectorStore {
    var selected: ConnectorID? { didSet { if selected != oldValue { message = nil } } }
    private(set) var authorizing: ConnectorID?
    private(set) var reading = false
    private(set) var message: String?
    private(set) var permissions: [ConnectorID: ConnectorPermission] = [:]
    private var operation = UUID()
    private let client: any NativeConnectionClient
    init(client: any NativeConnectionClient = AppleConnectionClient()) { self.client = client; refresh() }
    func refresh() { for id in ConnectorID.allCases where id.isNative { permissions[id] = client.permission(id) } }
    /// Connected when Apple's permission allows it and the person hasn't disconnected it in KemoSabe,
    /// however the permission was granted (`SavedState.kemoAllows`).
    func status(_ id: ConnectorID, state: SavedState) -> ConnectorStatus {
        .resolve(native: id.isNative, enabled: state.kemoAllows(id), permission: permissions[id] ?? .notDetermined)
    }
    /// Every KemoSabe flow that asks for a native permission (Connections, Day, People, the onboarding
    /// primer) comes through here, so a grant anywhere turns the connection on and clears a Disconnect.
    func connect(_ id: ConnectorID, store: AppStore) async -> String {
        selected = id
        guard id.isNative else { message = id.explanation; return id.explanation }
        guard authorizing == nil else { return "Finish the current permission screen first." }
        guard store.storageError == nil else { return "Your settings couldn’t be saved. Resolve the storage error first." }
        refresh()
        if let guidance = status(id, state: store.state).guidance(for: id), !status(id, state: store.state).usable {
            message = guidance; return guidance
        }
        if [.allowed, .limited].contains(permissions[id] ?? .notDetermined) {
            // Apple already allows it (granted in Day, People, or Settings): turning it on needs no prompt.
            let wasOn = status(id, state: store.state).usable
            if store.state.enabledConnectors?.contains(id.rawValue) != true || !wasOn { store.state.markConnected(id); store.save() }
            guard store.storageError == nil else { return "Access was allowed, but the connection preference couldn’t be saved." }
            message = wasOn ? "\(id.title) is already connected." : "\(id.title) connected. Try: \(id.example)"
            return message!
        }
        let token = UUID(); operation = token; authorizing = id; message = nil
        defer { authorizing = nil; refresh() }
        do {
            _ = try await client.request(id)
            refresh()
            guard !Task.isCancelled, operation == token else { return "Connection cancelled." }
            guard [.allowed, .limited].contains(permissions[id] ?? .denied) else {
                message = status(id, state: store.state).guidance(for: id) ?? "\(id.title) wasn’t connected. You can change access in iOS Settings."
                return message!
            }
            store.state.markConnected(id); store.save()
            guard store.storageError == nil else { return "Access was allowed, but the connection preference couldn’t be saved." }
            message = "\(id.title) connected. Try: \(id.example)"
            return message!
        } catch { message = "\(id.title) couldn’t connect. Try again or check iOS Settings."; return message! }
    }
    func disconnect(_ id: ConnectorID, store: AppStore) -> String {
        operation = UUID()
        store.state.markDisconnected(id)
        if id == .contacts { store.state.people?.removeContacts() }
        store.save()
        message = store.storageError == nil ? "\(id.title) disconnected from KemoSabe. You can also revoke Apple’s permission in iOS Settings." : "The disconnect preference couldn’t be saved. Resolve the storage error first."
        return message!
    }
    func read(_ id: ConnectorID, query: String? = nil, store: AppStore) async -> String {
        refresh()
        let current = status(id, state: store.state)
        guard current.usable else { selected = id; return current.guidance(for: id) ?? "Connect \(id.title) first. Say connect my \(id.title.lowercased())." }
        guard !reading else { return "One moment. I’m finishing the previous lookup." }
        guard store.storageError == nil else { return "Resolve the storage error before using connections." }
        let token = UUID(); operation = token; reading = true
        defer { reading = false }
        do {
            let result = try await client.read(id, query: query)
            refresh()
            guard !Task.isCancelled, operation == token, status(id, state: store.state).usable else { return "That lookup was cancelled." }
            return result
        } catch { return "I couldn’t read \(id.title). Check its permission in Connections and try again." }
    }
    func cancel() { operation = UUID(); message = nil }
}

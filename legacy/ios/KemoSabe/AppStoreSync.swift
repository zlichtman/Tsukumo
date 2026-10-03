import Foundation

/// What syncs from the app's store, one record per item in the account's personal zone:
/// conversations (open and saved), chat projects, memories, Library drafts, People, model
/// connections (never their keys, and never a connection to a server on the device itself), custom
/// palettes, and one record of preferences (`SyncedPreferences`: the default model, efforts, and voice
/// pace and conversation switches).
///
/// A chat's privacy level (`PrivacyLevel`) travels with its record. A conversation is one record whether it's open or in the list: an open one keeps its ID
/// (`SavedState.openConversations`), and saving it to the list keeps that ID. Another device's
/// conversation shows in the list; continuing it opens it here under the same ID. Continuing never
/// changes where a conversation may go: `canResume` still checks its model and recipient.
///
/// Not synced: API keys (each device's Keychain), what each connection may read (a grant is given on
/// each device), connections to localhost, the Apple connections you disconnected (Apple's permission
/// is per device), appearance, the context revision (a per-device disclosure
/// boundary, stripped from messages), memory privacy assessments (recomputed on each device), Day
/// routines, and work still drafting. The full audit is in design/ACCOUNTS-AND-PROFILES.md.
extension AppStore {
    /// Where the open conversation is held for the current model.
    var currentConversationSlot: String {
        switch modelRoute {
        case .api: activeAPIProfile.map { "api-" + $0.id.uuidString } ?? "onDevice"
        case .onDevice: "onDevice"
        }
    }
    /// The open conversation's ID in a slot, made the first time it's needed.
    func conversationID(for slot: String) -> UUID {
        if let open = state.openConversations?[slot] { return open.id }
        let id = UUID()
        var open = state.openConversations ?? [:]
        open[slot] = OpenConversation(id: id)
        state.openConversations = open
        return id
    }
    /// Whether sync may read and change the store now: it loaded, it saves, and it's still open.
    var syncable: Bool { storageError == nil && !failedToLoad && !closed }

    /// The messages of each open conversation, by slot.
    fileprivate var openSlots: [String: [ChatMessage]] {
        var slots: [String: [ChatMessage]] = ["onDevice": state.messages]
        for (profile, messages) in state.apiConversations ?? [:] { slots["api-" + profile] = messages }
        return slots.filter { !$0.value.isEmpty }
    }
    /// An open conversation as the record every device sees.
    fileprivate func openRecord(slot: String, messages: [ChatMessage]) -> ConversationArchive? {
        let model: String, recipient: String?, profileID: UUID?
        switch slot {
        case "onDevice": model = "Apple on-device"; recipient = nil; profileID = nil
        default:
            guard let profile = state.apiProfiles?.first(where: { "api-" + $0.id.uuidString == slot }) else { return nil }
            model = profile.name; recipient = profile.recipient; profileID = profile.id
        }
        let info = state.openConversations?[slot]
        return ConversationArchive(id: info?.id ?? UUID(), date: info?.date ?? messages.first?.date ?? .distantPast, model: model,
                                   recipient: recipient, messages: Self.syncable(messages), apiProfileID: profileID,
                                   projectID: info?.projectID, device: info?.device, privacy: info?.privacy)
    }
    /// Messages as they sync: without this device's context revision.
    static func syncable(_ messages: [ChatMessage]) -> [ChatMessage] {
        messages.map { var message = $0; message.contextRevision = nil; return message }
    }
    fileprivate static func conversationRecord(_ id: UUID) -> String { "conversation-" + id.uuidString }
}

@MainActor final class AppStoreSyncAdapter: SyncAdapter {
    let store: AppStore
    init(store: AppStore) { self.store = store }
    let types: Set<String> = [SyncType.conversation, SyncType.chatProject, SyncType.memory, SyncType.draft, SyncType.peopleNote,
                              SyncType.modelConnection, SyncType.palette, SyncType.preferences]
    static let preferencesID = "preferences", palettePrefix = "palette-"

    static func id(_ type: String, _ uuid: UUID) -> String {
        switch type {
        case SyncType.conversation: "conversation-" + uuid.uuidString
        case SyncType.chatProject: "chatproject-" + uuid.uuidString
        case SyncType.memory: "memory-" + uuid.uuidString
        case SyncType.draft: "draft-" + uuid.uuidString
        case SyncType.modelConnection: "connection-" + uuid.uuidString
        default: "person-" + uuid.uuidString
        }
    }

    func snapshot() -> [String: SyncItem]? {
        guard store.syncable else { return nil }
        // Open conversations need their IDs before they can be records.
        let before = store.state.openConversations
        for slot in store.openSlots.keys { _ = store.conversationID(for: slot) }
        if store.state.openConversations != before { store.save() }
        var items: [String: SyncItem] = [:]
        func add<Value: Encodable>(_ value: Value, _ type: String, _ uuid: UUID) {
            if let payload = try? SyncEngine.encode(value) { items[Self.id(type, uuid)] = .init(type: type, payload: payload) }
        }
        for archive in store.state.conversationArchives ?? [] {
            var archive = archive
            archive = ConversationArchive(id: archive.id, date: archive.date, model: archive.model, recipient: archive.recipient,
                                          messages: AppStore.syncable(archive.messages), apiProfileID: archive.apiProfileID,
                                          projectID: archive.projectID, device: archive.device, privacy: archive.privacy)
            add(archive, SyncType.conversation, archive.id)
        }
        for (slot, messages) in store.openSlots {
            if let record = store.openRecord(slot: slot, messages: messages) { add(record, SyncType.conversation, record.id) }
        }
        for project in store.state.conversationProjects ?? [] { add(project, SyncType.chatProject, project.id) }
        for note in store.state.memories { add(note, SyncType.memory, note.id) }
        // A draft still being written stays here until it's ready.
        for item in store.state.workItems ?? [] where !["Queued", "Drafting"].contains(item.status) { add(item, SyncType.draft, item.id) }
        for person in store.state.people?.profiles ?? [] { add(person, SyncType.peopleNote, person.id) }
        // A connection to this device itself ("localhost") means something else on each device.
        for profile in store.state.apiProfiles ?? [] where !profile.isLoopback { add(profile, SyncType.modelConnection, profile.id) }
        for theme in store.state.customThemes ?? [] {
            if let payload = try? SyncEngine.encode(theme) { items[Self.palettePrefix + theme.id] = .init(type: SyncType.palette, payload: payload) }
        }
        if let payload = try? SyncEngine.encode(SyncedPreferences(store.state)) {
            items[Self.preferencesID] = .init(type: SyncType.preferences, payload: payload)
        }
        return items
    }

    func apply(_ changes: [String: SyncItem?]) -> Set<String> {
        guard store.syncable else { return [] }
        var applied = Set<String>()
        var memoriesChanged = false, openChanged = false
        var people = store.state.people ?? PeopleDirectory()
        let decoder = JSONDecoder()
        var connectionsChanged = false, defaultChanged = false
        for (id, item) in changes.sorted(by: { $0.key < $1.key }) {
            if id == Self.preferencesID {
                // Never removed by another device; a missing value keeps this one's.
                guard let item else { applied.insert(id); continue }
                guard item.type == SyncType.preferences, let preferences = try? decoder.decode(SyncedPreferences.self, from: item.payload) else { continue }
                defaultChanged = preferences.defaultModel != store.state.defaultModel
                preferences.apply(to: &store.state)
                applied.insert(id)
                continue
            }
            if id.hasPrefix(Self.palettePrefix) {
                let themeID = String(id.dropFirst(Self.palettePrefix.count))
                var themes = store.state.customThemes ?? []
                if let item {
                    guard item.type == SyncType.palette, let theme = try? decoder.decode(BotTheme.self, from: item.payload), theme.id == themeID else { continue }
                    if let index = themes.firstIndex(where: { $0.id == themeID }) { themes[index] = theme } else { themes.append(theme) }
                } else { themes.removeAll { $0.id == themeID } }
                store.state.customThemes = themes.isEmpty ? nil : themes
                applied.insert(id)
                continue
            }
            guard let (type, uuid) = Self.parse(id) else { continue }
            if let item, item.type != type { continue }
            switch type {
            case SyncType.conversation:
                let remote = item.flatMap { try? decoder.decode(ConversationArchive.self, from: $0.payload) }
                if item != nil && remote == nil { continue }
                switch applyConversation(uuid, remote) {
                case .applied: applied.insert(id)
                case .appliedOpen: applied.insert(id); openChanged = true
                case .later: continue
                }
            case SyncType.chatProject:
                if let item {
                    guard let project = try? decoder.decode(ConversationProject.self, from: item.payload) else { continue }
                    var projects = store.state.conversationProjects ?? []
                    if let index = projects.firstIndex(where: { $0.id == uuid }) { projects[index] = project } else { projects.append(project) }
                    store.state.conversationProjects = projects
                } else {
                    store.state.conversationProjects?.removeAll { $0.id == uuid }
                    if store.state.currentProjectID == uuid { store.state.currentProjectID = nil }
                }
                applied.insert(id)
            case SyncType.memory:
                if let item {
                    guard let note = try? decoder.decode(MemoryNote.self, from: item.payload) else { continue }
                    if let index = store.state.memories.firstIndex(where: { $0.id == uuid }) { store.state.memories[index] = note }
                    else { store.state.memories.append(note) }
                } else {
                    store.state.memories.removeAll { $0.id == uuid }
                    store.state.memoryPrivacy?.removeAll { $0.noteID == uuid }
                }
                memoriesChanged = true
                applied.insert(id)
            case SyncType.draft:
                // Never replace a draft this device is writing right now.
                if store.working, store.state.workItems?.first(where: { $0.id == uuid }).map({ ["Queued", "Drafting"].contains($0.status) }) == true { continue }
                var items = store.state.workItems ?? []
                if let item {
                    guard let draft = try? decoder.decode(WorkItem.self, from: item.payload) else { continue }
                    if let index = items.firstIndex(where: { $0.id == uuid }) { items[index] = draft } else { items.append(draft) }
                } else { items.removeAll { $0.id == uuid } }
                store.state.workItems = items
                applied.insert(id)
            case SyncType.modelConnection:
                if let item {
                    guard let remote = try? decoder.decode(APIModelProfile.self, from: item.payload), remote.id == uuid, !remote.isLoopback,
                          let profile = try? APIModelProfile.validated(id: remote.id, name: remote.name, endpoint: remote.endpoint.absoluteString, model: remote.model,
                                                                        streaming: remote.streaming, supportsImages: remote.supportsImages == true, format: remote.wire) else { continue }
                    var profiles = store.state.apiProfiles ?? []
                    if let index = profiles.firstIndex(where: { $0.id == uuid }) { profiles[index] = profile }
                    else if profiles.count < 12 { profiles.append(profile) } else { continue }
                    store.state.apiProfiles = profiles
                } else if let profile = store.state.apiProfiles?.first(where: { $0.id == uuid }) {
                    // Removed on another device: its key, chat, and grants go here too.
                    guard (try? store.removeAPIProfile(profile)) != nil else { continue }
                }
                connectionsChanged = true
                applied.insert(id)
            case SyncType.peopleNote:
                var next = people
                if let item {
                    guard let person = try? decoder.decode(PeopleProfile.self, from: item.payload) else { continue }
                    if let index = next.profiles.firstIndex(where: { $0.id == uuid }) { next.profiles[index] = person } else { next.profiles.append(person) }
                } else { next.profiles.removeAll { $0.id == uuid } }
                // A person who'd make People invalid here (say, the same contact twice) waits.
                guard (try? next.validate()) != nil else { continue }
                people = next
                applied.insert(id)
            default: continue
            }
        }
        guard !applied.isEmpty else { return [] }
        if store.state.people != nil || !people.profiles.isEmpty { store.state.people = people }
        if memoriesChanged || openChanged {
            // A new context revision, as for any change to what the model may see. A changed memory
            // resets the conversation's context exactly as editing one here does; new messages in the
            // open conversation carry it over, as when a conversation is continued.
            let previous = store.state.contextRevision ?? 0
            store.invalidateConversationContext()
            let current = store.state.contextRevision ?? 0
            if !memoriesChanged { store.state.messages = store.state.messages.map { message in
                var message = message
                if (message.contextRevision ?? 0) == previous { message.contextRevision = current }
                return message
            } }
        }
        store.save()
        // The account's default model (or a connection it names) arrived: use it here when this device can.
        if defaultChanged || connectionsChanged { store.applyDefaultModel() }
        if memoriesChanged { store.schedulePrivacyClassification() }
        guard store.syncable else { return [] }
        return applied
    }

    private enum Outcome { case applied, appliedOpen, later }
    /// Puts another device's conversation where this device holds it: open in a slot, or in the list.
    private func applyConversation(_ id: UUID, _ remote: ConversationArchive?) -> Outcome {
        if let slot = store.state.openConversations?.first(where: { $0.value.id == id })?.key {
            // Leave the conversation alone while a reply is being written into it.
            if slot == store.currentConversationSlot, store.isThinking || store.working { return .later }
            let current = slotMessages(slot)
            guard let remote else {
                store.forgetForSync(current)
                setSlot(slot, messages: [])
                store.state.openConversations?.removeValue(forKey: slot)
                return .appliedOpen
            }
            // Messages this device already had keep their context revision; new ones join the
            // current one, since this conversation is open here with the same model.
            let revisions = Dictionary(current.map { ($0.id, $0.contextRevision) }, uniquingKeysWith: { first, _ in first })
            let revision = store.state.contextRevision ?? 0
            let messages = remote.messages.map { message in
                var message = message
                message.contextRevision = revisions[message.id] ?? revision
                return message
            }
            setSlot(slot, messages: messages)
            // The chat's context card stays on this device: another device's copy never carries it.
            let packet = store.state.openConversations?[slot]?.packet
            store.state.openConversations?[slot] = OpenConversation(id: id, date: remote.date, projectID: remote.projectID, device: remote.device,
                                                                    privacy: remote.privacy, packet: packet)
            return .applied
        }
        var archives = store.state.conversationArchives ?? []
        if let remote {
            if let index = archives.firstIndex(where: { $0.id == id }) { archives[index] = remote }
            else { archives.insert(remote, at: archives.firstIndex { $0.date > remote.date } ?? archives.endIndex) }
        } else if let index = archives.firstIndex(where: { $0.id == id }) {
            store.forgetForSync(archives[index].messages)
            archives.remove(at: index)
        }
        store.state.conversationArchives = archives
        return .applied
    }
    private func slotMessages(_ slot: String) -> [ChatMessage] {
        switch slot {
        case "onDevice": store.state.messages
        default: store.state.apiConversations?[String(slot.dropFirst(4))] ?? []
        }
    }
    private func setSlot(_ slot: String, messages: [ChatMessage]) {
        switch slot {
        case "onDevice": store.state.messages = messages
        default:
            var conversations = store.state.apiConversations ?? [:]
            conversations[String(slot.dropFirst(4))] = messages
            store.state.apiConversations = conversations
        }
    }
    static func parse(_ id: String) -> (String, UUID)? {
        let prefixes = [("conversation-", SyncType.conversation), ("chatproject-", SyncType.chatProject), ("memory-", SyncType.memory),
                        ("draft-", SyncType.draft), ("person-", SyncType.peopleNote), ("connection-", SyncType.modelConnection)]
        for (prefix, type) in prefixes where id.hasPrefix(prefix) {
            guard let uuid = UUID(uuidString: String(id.dropFirst(prefix.count))) else { return nil }
            return (type, uuid)
        }
        return nil
    }
}

/// The preferences in the app's store that the person expects to be the same on every device, as one
/// record: the default model for new chats (each device uses it when it can, `AppStore.applyDefaultModel`),
/// each model's reasoning effort, and the speaking pace and voice conversation switches. Missing fields
/// leave this device's value.
struct SyncedPreferences: Codable, Equatable {
    var defaultModel: DefaultModelChoice?
    var modelEfforts: [String: String]?
    var speechRate: Double?
    var patientListening: Bool?
    var voiceInterruptions: Bool?
    var captionsEnabled: Bool?

    init(_ state: SavedState) {
        // Efforts are sent empty rather than missing, so clearing them on a device clears them everywhere.
        defaultModel = state.defaultModel; modelEfforts = state.modelEfforts ?? [:]
        speechRate = state.speechRate; patientListening = state.patientListening; voiceInterruptions = state.voiceInterruptions
        captionsEnabled = state.captionsEnabled
    }
    func apply(to state: inout SavedState) {
        if let defaultModel { state.defaultModel = defaultModel }
        if let modelEfforts { state.modelEfforts = modelEfforts.isEmpty ? nil : modelEfforts }
        if let speechRate { state.speechRate = speechRate }
        if let patientListening { state.patientListening = patientListening }
        if let voiceInterruptions { state.voiceInterruptions = voiceInterruptions }
        if let captionsEnabled { state.captionsEnabled = captionsEnabled }
    }
}

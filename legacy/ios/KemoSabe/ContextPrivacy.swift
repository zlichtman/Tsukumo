import Foundation

/// The store's side of the context harness: who the chat's model is as a recipient, the levels the
/// person sets on memories and chats, and the checks every send makes through `ContextPolicy`.
extension AppStore {
    /// Who the current chat's model is.
    var currentRecipient: RecipientID {
        switch modelRoute {
        case .api: activeAPIProfile.map(RecipientID.api) ?? .appleOnDevice
        case .onDevice: appleModel.recipient
        }
    }
    /// The person's grants that are still live.
    var liveGrants: [RecipientGrant] { RecipientGrants.pruned(state.recipientGrants ?? [], now: Date()) }

    // MARK: Memories

    func memoryLevel(_ note: MemoryNote) -> PrivacyLevel {
        MemoryPrivacy.level(note, assessment: state.memoryPrivacy?.first { $0.noteID == note.id })
    }
    /// Sets a memory's level. Secret is "Not used in chat". The planning fingerprint doesn't change
    /// unless chat use does, so derived notes stay bound.
    func setMemoryPrivacy(_ level: PrivacyLevel, for id: UUID) {
        guard storageError == nil, let index = state.memories.firstIndex(where: { $0.id == id }) else { return }
        var note = state.memories[index]
        MemoryPrivacy.set(level, on: &note)
        guard note != state.memories[index] else { return }
        saveMemory(note)
    }
    /// The saved notes a standup draft may use with this recipient.
    func standupNotes(for recipient: RecipientID) -> [MemoryNote] {
        ContextPolicy.filter(MemoryPolicy.valid(state.memories), item: { note in ContextItem.memory(note, assessment:
            self.state.memoryPrivacy?.first { $0.noteID == note.id }) }, to: recipient)
    }

    // MARK: Chats

    /// The open chat's level.
    var currentConversationPrivacy: PrivacyLevel {
        state.openConversations?[currentConversationSlot]?.privacy ?? ConversationPrivacy.defaultLevel
    }
    func conversationPrivacy(_ id: UUID) -> PrivacyLevel {
        if let open = state.openConversations?.values.first(where: { $0.id == id }) { return open.privacy ?? ConversationPrivacy.defaultLevel }
        return state.conversationArchives?.first { $0.id == id }?.privacy ?? ConversationPrivacy.defaultLevel
    }
    /// Sets a whole chat's level, open or saved.
    func setConversationPrivacy(_ level: PrivacyLevel, for id: UUID) {
        guard storageError == nil else { return }
        let stored: PrivacyLevel? = level == ConversationPrivacy.defaultLevel ? nil : level
        if let slot = state.openConversations?.first(where: { $0.value.id == id })?.key {
            state.openConversations?[slot]?.privacy = stored
        } else if let index = state.conversationArchives?.firstIndex(where: { $0.id == id }) {
            state.conversationArchives?[index].privacy = stored
        } else { return }
        save()
    }
    func setCurrentConversationPrivacy(_ level: PrivacyLevel) {
        setConversationPrivacy(level, for: conversationID(for: currentConversationSlot))
    }
    /// Why this chat can't be sent to `recipient`, or nil when it can. The chat's own model holds a
    /// standing grant for its own history; a level above what that model may have still stops it.
    func conversationRefusal(for recipient: RecipientID) -> String? {
        let id = conversationID(for: currentConversationSlot)
        let item = ContextItem.conversation(id, level: currentConversationPrivacy)
        let own = RecipientGrant(recipient: recipient, items: [item.ref], purpose: .conversation)
        // Private Cloud falls back to on-device for a Device only chat (`mayUsePrivateCloud`).
        let checked: RecipientID = recipient == .applePrivateCloud ? .appleOnDevice : recipient
        switch ContextPolicy.evaluate([item], to: checked, purpose: .conversation, grants: [own], now: Date()).denied[item.ref] {
        case nil: return nil
        case .secret?: return "This chat is set to Secret, so no model reads it. Change its privacy to continue."
        case .staysOnDevice?, .needsGrant?:
            return "This chat is set to \(currentConversationPrivacy.title), so it stays on this device. Choose Apple on-device to continue it."
        }
    }
    /// Whether this reply may go to Private Cloud: the chat and everything attached must be allowed there.
    func mayUsePrivateCloud(attachments: [ChatDocAttachment]) -> Bool {
        let chat = ContextItem.conversation(conversationID(for: currentConversationSlot), level: currentConversationPrivacy)
        return ContextPolicy.evaluate([chat] + attachments.map(\.contextItem), to: .applePrivateCloud, purpose: .conversation,
                                      grants: [], now: Date()).permitsAll
    }

    // MARK: Attachments

    /// The person confirmed where this attachment goes; it's a grant for that one item, to that recipient.
    func confirmAttachment(_ attachment: ChatDocAttachment) {
        var attachment = attachment
        attachment.sharedWith = currentRecipient.key
        composerAttachments.append(attachment)
    }
}

extension ChatDocAttachment {
    var contextItem: ContextItem {
        .init(.init(kind == .doc ? .doc : .journal, sourceID),
              level: privacy ?? (kind == .doc ? DocPage.defaultPrivacy : JournalEntry.defaultPrivacy))
    }
    /// The grant the person gave by confirming where it goes.
    var confirmedGrant: RecipientGrant? {
        guard let sharedWith, let recipient = RecipientID(key: sharedWith) else { return nil }
        return RecipientGrant(recipient: recipient, items: [contextItem.ref], purpose: .conversation)
    }
}

extension AttachedContext {
    /// Why these attachments can't go to `recipient`, or nil when they can.
    static func refusal(_ attachments: [ChatDocAttachment], to recipient: RecipientID) -> String? {
        let decision = ContextPolicy.evaluate(attachments.map(\.contextItem), to: recipient, purpose: .conversation,
                                              grants: attachments.compactMap(\.confirmedGrant), now: Date())
        guard let blocked = attachments.first(where: { decision.denied[$0.contextItem.ref] != nil }) else { return nil }
        switch decision.denied[blocked.contextItem.ref] {
        case .needsGrant?: return "Attach “\(blocked.title)” again to confirm it goes to \(recipient.host)."
        case .secret?: return "“\(blocked.title)” is set to Secret, so no model reads it."
        default: return "“\(blocked.title)” is set to Device only, so it can’t go to \(recipient.host)."
        }
    }
}

extension RecipientID {
    /// The recipient a saved key names, for the kinds whose key carries everything needed.
    init?(key: String) {
        func uuid(_ prefix: String) -> UUID? { key.hasPrefix(prefix) ? UUID(uuidString: String(key.dropFirst(prefix.count))) : nil }
        switch key {
        case "apple-on-device": self = .appleOnDevice
        case "apple-private-cloud": self = .applePrivateCloud
        case "icloud-sync": self = .iCloudSync
        default:
            if let id = uuid("api:") { self = .apiModel(profile: id, host: "") }
            else if let id = uuid("nearby:") { self = .nearbyPeer(id) }
            else if let id = uuid("chat:") { self = .chat(id) }
            else if key.hasPrefix("coding:") { self = .codingAgent(String(key.dropFirst(7))) }
            else if key.hasPrefix("acp:") { self = .acpAgent(String(key.dropFirst(4))) }
            else if key.hasPrefix("agent:") { self = .externalAgent(String(key.dropFirst(6))) }
            else { return nil }
        }
    }
}

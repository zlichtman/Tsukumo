import XCTest
#if os(macOS)
@testable import KemoSabeMac
#else
@testable import KemoSabe
#endif

/// The context harness's core (design/CONTEXT-HARNESS.md): one `RecipientID`, `PrivacyLevel`s on
/// every item, and one `ContextPolicy.evaluate`. The regression tests at the end show that each
/// check routed through the policy still holds its old rule.
final class ContextPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)
    private let profile = UUID()
    private var api: RecipientID { .apiModel(profile: profile, host: "api.example.invalid") }
    private let chat = UUID(), peer = UUID()
    private var everyRecipient: [RecipientID] {
        [.appleOnDevice, .applePrivateCloud, api, .codingAgent("claude-code"), .acpAgent("gemini"),
         .externalAgent("com.meta.muse"), .nearbyPeer(peer), .chat(chat), .iCloudSync,
         .voice(backend: "apple", local: true), .voice(backend: "openAI", local: false)]
    }

    // MARK: Recipients

    func testEveryRecipientHasALocalityAHostAndAStableKey() {
        let expected: [RecipientLocality] = [.onDevice, .appleCloud, .thirdPartyCloud, .thirdPartyCloud, .thirdPartyCloud,
                                             .thirdPartyCloud, .thirdPartyCloud, .onDevice, .appleCloud, .onDevice, .thirdPartyCloud]
        XCTAssertEqual(everyRecipient.map(\.locality), expected)
        XCTAssertEqual(Set(everyRecipient.map(\.key)).count, everyRecipient.count, "Every recipient has its own key")
        XCTAssertTrue(everyRecipient.allSatisfy { !$0.host.isEmpty })
        XCTAssertEqual(api.host, "api.example.invalid")
        XCTAssertEqual(RecipientID.applePrivateCloud.host, PrivateCloudText.journalDestination)
        for recipient in everyRecipient where !recipient.key.hasPrefix("voice:") {
            XCTAssertEqual(RecipientID(key: recipient.key)?.key, recipient.key, "\(recipient.key) round-trips")
        }
        XCTAssertNil(RecipientID(key: "something-new"), "An unknown key names no recipient")
    }

    func testPrivateCloudIsItsOwnRecipientNotALocalOne() {
        XCTAssertEqual(AppleModel.onDevice.recipient, .appleOnDevice)
        XCTAssertEqual(AppleModel.privateCloud.recipient, .applePrivateCloud)
        XCTAssertNotEqual(ToolRecipient.apple(.privateCloud).id, ToolRecipient.onDevice.id)
        XCTAssertEqual(RecipientID.applePrivateCloud.locality, .appleCloud)
        XCTAssertFalse(ContextPolicy.keepsEverythingOnDevice(.applePrivateCloud))
        XCTAssertTrue(ContextPolicy.keepsEverythingOnDevice(.appleOnDevice))
        // The owner's rule, expressed: the same context as on-device, except what must stay here.
        for level in [PrivacyLevel.open, .personal, .sensitive] {
            XCTAssertTrue(allows(level, .applePrivateCloud), "\(level) reaches Private Cloud")
        }
        XCTAssertFalse(allows(.deviceOnly, .applePrivateCloud))
        XCTAssertTrue(allows(.deviceOnly, .appleOnDevice))
    }

    // MARK: Levels and the policy

    func testPolicyForEveryRecipientAndLevel() {
        for recipient in everyRecipient {
            for level in PrivacyLevel.allCases {
                let item = ContextItem(.init(.memory, UUID()), level: level)
                let plain = decide(item, recipient, grants: [])
                let itemGrant = decide(item, recipient, grants: [RecipientGrant(recipient: recipient, items: [item.ref], purpose: .conversation)])
                let kindGrant = decide(item, recipient, grants: [RecipientGrant(recipient: recipient, kinds: [.memory], purpose: .conversation)])
                let label = "\(level) → \(recipient.key)"
                if recipient == .iCloudSync {
                    XCTAssertNil(plain, "\(label): the person's own encrypted storage keeps everything"); continue
                }
                switch (level, recipient.locality) {
                case (.secret, _):
                    XCTAssertEqual(plain, .secret, label); XCTAssertEqual(itemGrant, .secret, label); XCTAssertEqual(kindGrant, .secret, label)
                case (.deviceOnly, .onDevice): XCTAssertNil(plain, label)
                case (.deviceOnly, _):
                    XCTAssertEqual(plain, .staysOnDevice, label); XCTAssertEqual(itemGrant, .staysOnDevice, "\(label): no grant opens it")
                case (.open, _), (_, .onDevice), (_, .appleCloud): XCTAssertNil(plain, label)
                case (.personal, .thirdPartyCloud):
                    XCTAssertEqual(plain, .needsGrant, label); XCTAssertNil(itemGrant, label); XCTAssertNil(kindGrant, label)
                case (.sensitive, .thirdPartyCloud):
                    XCTAssertEqual(plain, .needsGrant, label); XCTAssertNil(itemGrant, label)
                    XCTAssertEqual(kindGrant, .needsGrant, "\(label): only a grant for the item itself")
                }
            }
        }
    }

    func testGrantsAreScopedToRecipientPurposeAndItems() {
        let item = ContextItem(.init(.doc, UUID()), level: .personal)
        let other = ContextItem(.init(.doc, UUID()), level: .personal)
        let grant = RecipientGrant(recipient: api, items: [item.ref], purpose: .conversation)
        let decision = ContextPolicy.evaluate([item, other], to: api, purpose: .conversation, grants: [grant], now: now)
        XCTAssertEqual(decision.allowed, [item.ref]); XCTAssertEqual(decision.denied, [other.ref: .needsGrant])
        XCTAssertEqual(decision.grantsUsed, [grant.id])
        XCTAssertFalse(ContextPolicy.allows(item, to: .externalAgent("someone-else"), grants: [grant], now: now), "Another recipient")
        XCTAssertFalse(ContextPolicy.allows(item, to: api, purpose: "speech", grants: [grant], now: now), "Another purpose")
    }

    func testGrantExpiryAndSingleUse() {
        let item = ContextItem(.init(.journal, UUID()), level: .sensitive)
        let expiring = RecipientGrant(recipient: api, items: [item.ref], purpose: .conversation, expiresAt: now.addingTimeInterval(60))
        XCTAssertTrue(ContextPolicy.allows(item, to: api, grants: [expiring], now: now))
        XCTAssertFalse(ContextPolicy.allows(item, to: api, grants: [expiring], now: now.addingTimeInterval(61)), "Expired")
        XCTAssertTrue(RecipientGrants.pruned([expiring], now: now.addingTimeInterval(61)).isEmpty)

        var grants = [RecipientGrant(recipient: api, items: [item.ref], purpose: .conversation, singleUse: true)]
        let decision = ContextPolicy.evaluate([item], to: api, purpose: .conversation, grants: grants, now: now)
        XCTAssertTrue(decision.permitsAll)
        RecipientGrants.spend(decision.grantsUsed, in: &grants)
        XCTAssertEqual(grants.first?.used, true)
        XCTAssertFalse(ContextPolicy.allows(item, to: api, grants: grants, now: now), "A single-use grant covers one disclosure")
        // Spending never touches a standing grant.
        var standing = [RecipientGrant(recipient: api, items: [item.ref], purpose: .conversation)]
        RecipientGrants.spend(standing.map(\.id), in: &standing)
        XCTAssertTrue(ContextPolicy.allows(item, to: api, grants: standing, now: now))
    }

    func testGrantsFromANewerBuildNeverStopTheAccountLoading() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(SavedState())) as? [String: Any])
        object["recipientGrants"] = [["id": "8A3E6A1C-0B8B-4B7C-9E3E-4C3A8F0F0A11", "recipient": "future:thing", "kinds": ["hologram"],
                                      "purpose": "conversation", "singleUse": false, "grantedAt": 0]]
        object["memories"] = [["id": "9A3E6A1C-0B8B-4B7C-9E3E-4C3A8F0F0A11", "text": "x", "scope": "Personal", "useInChat": true,
                               "privacy": "ultraSecret"]]
        let state = try JSONDecoder().decode(SavedState.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(state.recipientGrants?.count, 1)
        XCTAssertEqual(state.memories.first?.privacy, .secret, "An unknown level is treated as the most private")
        XCTAssertFalse(ContextPolicy.allows(.init(.init(.memory, UUID()), level: .personal), to: api,
                                            grants: state.recipientGrants ?? [], now: now), "It matches nothing")
    }

    // MARK: Migration

    func testExistingDataMigratesWithoutLosingAnything() throws {
        // A memory saved before levels existed decodes as it was and re-encodes without a new key.
        let legacy = #"{"id":"7F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9","text":"Orion launch is Friday","scope":"Personal","useInChat":true}"#
        let note = try JSONDecoder().decode(MemoryNote.self, from: Data(legacy.utf8))
        XCTAssertNil(note.privacy)
        XCTAssertEqual(MemoryPrivacy.level(note), .personal, "Default for a memory")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(note), as: UTF8.self).contains("privacy"))
        var excluded = note; excluded.useInChat = false
        XCTAssertEqual(MemoryPrivacy.level(excluded), .secret, "Not used in chat is Secret")
        var company = note; company.scope = "Company"
        XCTAssertEqual(MemoryPrivacy.level(company), .sensitive)
        var inherited = note; inherited.inheritedSensitivity = BrokerSensitivity([.ordinary, .personal, .health]).rawValue
        XCTAssertEqual(MemoryPrivacy.level(inherited), .sensitive)
        let assessment = MemoryPrivacyAssessment(noteID: note.id, fingerprint: PlanningSource.fingerprint(note),
                                                 labels: BrokerSensitivity([.ordinary, .personal, .child]).rawValue, uncertain: false, assessedAt: now)
        XCTAssertEqual(MemoryPrivacy.level(note, assessment: assessment), .sensitive)
        var chosen = note; MemoryPrivacy.set(.open, on: &chosen)
        XCTAssertEqual(MemoryPrivacy.level(chosen, assessment: assessment), .open, "The person's choice stands")
        MemoryPrivacy.set(.secret, on: &chosen)
        XCTAssertFalse(chosen.useInChat); XCTAssertNil(chosen.privacy)
        MemoryPrivacy.set(.deviceOnly, on: &chosen)
        XCTAssertTrue(chosen.useInChat); XCTAssertEqual(MemoryPrivacy.level(chosen), .deviceOnly)

        // Docs, journal entries, and chats from before levels use their defaults.
        let page = try JSONDecoder().decode(DocPage.self, from: Data(#"{"id":"1F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9","title":"Plans"}"#.utf8))
        XCTAssertNil(page.privacy); XCTAssertEqual(page.privacyLevel, .personal)
        let entry = try JSONDecoder().decode(JournalEntry.self, from: Data(#"{"id":"2F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9","created":0,"day":"2026-09-27","timeZone":"UTC"}"#.utf8))
        XCTAssertNil(entry.privacy); XCTAssertEqual(entry.privacyLevel, .sensitive)
        let archive = try JSONDecoder().decode(ConversationArchive.self, from: Data(#"{"id":"3F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9","date":0,"model":"Apple on-device","messages":[]}"#.utf8))
        XCTAssertNil(archive.privacy)
        XCTAssertEqual(ContextItem.conversation(archive.id, level: archive.privacy).level, .personal)
        var set = page; set.privacy = .deviceOnly
        XCTAssertEqual(try JSONDecoder().decode(DocPage.self, from: JSONEncoder().encode(set)).privacy, .deviceOnly)
    }

    func testPerModelConnectionGrantsMigrateOnce() throws {
        let first = UUID(), second = UUID()
        var state = SavedState()
        state.apiConnectorGrants = [first.uuidString: ["calendar", "contacts"], second.uuidString: ["reminders", "gmail"]]
        XCTAssertTrue(state.migrateLegacyConnectorGrants())
        XCTAssertNil(state.apiConnectorGrants)
        XCTAssertEqual(state.apiGrants(first), [.calendar, .contacts])
        XCTAssertEqual(state.apiGrants(second), [.reminders], "Only native connections were ever grantable")
        XCTAssertFalse(state.migrateLegacyConnectorGrants(), "Once")
        XCTAssertEqual(state.recipientGrants?.count, 3)
    }

    @MainActor func testTheStoreMigratesGrantsWhenItOpens() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = LocalRepository(url: folder.appendingPathComponent("state.json"))
        var legacy = SavedState(); legacy.apiConnectorGrants = [profile.uuidString: ["calendar"]]
        try repository.save(legacy)
        let store = AppStore(repository: repository, provider: APIUnavailableLocal(), apiKeys: MemoryAPIKeys())
        XCTAssertEqual(store.state.apiGrants(profile), [.calendar])
        XCTAssertNil(try repository.read().apiConnectorGrants, "Saved in the account's state")
    }

    func testPrivacyChangesUseTheirOwnDigestNotThePlanningFingerprint() {
        var note = MemoryNote(text: "Orion launch", scope: "Personal")
        let fingerprint = PlanningSource.fingerprint(note), digest = ContextPolicyDigest.memory(note)
        note.privacy = .deviceOnly
        XCTAssertEqual(PlanningSource.fingerprint(note), fingerprint, "Derived notes stay bound")
        XCTAssertNotEqual(ContextPolicyDigest.memory(note), digest, "The bridge still reprojects it")
    }

    // MARK: The memory bridge

    func testTheBridgeGivesEachRecipientOnlyWhatThePolicyAllows() async throws {
        let owner = UUID(), bridge = MemoryContextBridge()
        let open = MemoryNote(text: "Orion launch is Friday", scope: "Personal")
        var local = MemoryNote(text: "Orion badge code is kept here", scope: "Personal"); local.privacy = .deviceOnly
        try await bridge.synchronize([open, local], ownerID: owner)
        let onDevice = try await bridge.lookup("Orion", ownerID: owner, recipient: .appleOnDevice, deadline: Date() + 60)
        XCTAssertEqual(Set(onDevice.map(\.id)), [open.id, local.id])
        let cloud = try await bridge.lookup("Orion", ownerID: owner, recipient: .applePrivateCloud, deadline: Date() + 60)
        XCTAssertEqual(cloud.map(\.id), [open.id], "Private Cloud recalls what on-device does, except Device only")
        let model = try await bridge.lookup("Orion", ownerID: owner, recipient: api, deadline: Date() + 60)
        XCTAssertTrue(model.isEmpty, "A connected model gets no memory without a grant")
        let granted = try await bridge.lookup("Orion", ownerID: owner, recipient: api,
            grants: [RecipientGrant(recipient: api, items: [.init(.memory, open.id)], purpose: .conversation)], deadline: Date() + 60)
        XCTAssertEqual(granted.map(\.id), [open.id])
        let projected = try await bridge.projectedLevel(for: local.id, ownerID: owner)
        XCTAssertEqual(projected, .deviceOnly)
        // A level change reprojects the record.
        var raised = open; raised.privacy = .deviceOnly
        try await bridge.synchronize([raised, local], ownerID: owner)
        let after = try await bridge.lookup("Orion", ownerID: owner, recipient: .applePrivateCloud, deadline: Date() + 60)
        XCTAssertTrue(after.isEmpty)
    }

    @MainActor func testTheStoreKeepsOneBridgeAndItsGrantsAcrossMemoryChanges() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = AppStore(repository: .init(url: folder.appendingPathComponent("state.json")), provider: APIUnavailableLocal(), apiKeys: MemoryAPIKeys())
        let bridge = store.memoryContextID
        store.state.setAPIGrant(.calendar, profile: profile, allowed: true); store.save()
        let note = MemoryNote(text: "Standup is at nine", scope: "Personal")
        store.saveMemory(note)
        store.setMemoryPrivacy(.deviceOnly, for: note.id)
        XCTAssertEqual(store.memoryLevel(store.state.memories[0]), .deviceOnly)
        store.deleteMemory(note.id)
        store.selectAppleModel(.onDevice)
        XCTAssertEqual(store.memoryContextID, bridge, "Never rebuilt, so nothing it holds is dropped")
        XCTAssertEqual(store.state.apiGrants(profile), [.calendar], "Durable grants live in the account")
    }

    // MARK: Chats

    @MainActor func testAChatsLevelIsSetOnceAndStopsWhatItMust() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = AppStore(repository: .init(url: folder.appendingPathComponent("state.json")), provider: APIUnavailableLocal(), apiKeys: MemoryAPIKeys())
        XCTAssertEqual(store.currentConversationPrivacy, .personal)
        XCTAssertNil(store.conversationRefusal(for: .appleOnDevice))
        store.setCurrentConversationPrivacy(.deviceOnly)
        XCTAssertEqual(store.currentConversationPrivacy, .deviceOnly)
        XCTAssertNil(store.conversationRefusal(for: .appleOnDevice))
        XCTAssertNil(store.conversationRefusal(for: .applePrivateCloud), "Private Cloud falls back to on-device")
        XCTAssertFalse(store.mayUsePrivateCloud(attachments: []))
        XCTAssertNotNil(store.conversationRefusal(for: api))
        store.setCurrentConversationPrivacy(.secret)
        XCTAssertEqual(store.conversationRefusal(for: .appleOnDevice), "This chat is set to Secret, so no model reads it. Change its privacy to continue.")
        store.setCurrentConversationPrivacy(.sensitive)
        XCTAssertNil(store.conversationRefusal(for: api), "A chat's own model holds a grant for its own history")
        XCTAssertTrue(store.mayUsePrivateCloud(attachments: []))
        let id = store.conversationID(for: store.currentConversationSlot)
        XCTAssertEqual(store.conversationPrivacy(id), .sensitive)
    }

    // MARK: The old rules, routed through the policy

    func testOldRuleConnectorReadsNeedTheModelsOwnGrant() throws {
        // On-device reads without a grant; so does Private Cloud (the owner's rule), now as itself.
        XCTAssertNoThrow(try ActionGate.requireNativeRead(.calendar, enabled: [.calendar], permission: .allowed))
        XCTAssertNoThrow(try ActionGate.requireNativeRead(.calendar, enabled: [.calendar], permission: .allowed, recipient: .apple(.privateCloud)))
        // A connected model needs its own grant for that connection; a grant elsewhere doesn't count.
        XCTAssertThrowsError(try ActionGate.requireNativeRead(.calendar, enabled: [.calendar], permission: .allowed,
            recipient: .apiModel(profile: profile, name: "Claude", host: "h", granted: [.contacts]))) { XCTAssertTrue($0 is ConnectorGrantRequired) }
        let other = ToolRecipient(id: .apiModel(profile: UUID(), host: "h"), name: "Other",
                                  grants: ToolRecipient.apiModel(profile: profile, name: "Claude", host: "h", granted: [.calendar]).grants)
        XCTAssertThrowsError(try ActionGate.requireNativeRead(.calendar, enabled: [.calendar], permission: .allowed, recipient: other),
                             "A grant for one model never covers another")
        // Apple's permission and KemoSabe's switch still come first.
        XCTAssertThrowsError(try ActionGate.requireNativeRead(.calendar, enabled: [], permission: .allowed, recipient: .apple(.privateCloud)))
        XCTAssertEqual(ContextItem.connector(.calendar).level, .personal)
    }

    func testOldRuleMemoriesNotUsedInChatReachNoModel() {
        let used = MemoryNote(text: "Launch Friday", scope: "Personal")
        var excluded = MemoryNote(text: "Launch Friday secret", scope: "Personal"); excluded.useInChat = false
        XCTAssertEqual(MemoryPolicy.valid([used, excluded]).map(\.id), [used.id])
        let context = OnDeviceAssistant.context(history: [], memories: [used, excluded], standupFormat: "")
        XCTAssertTrue(context.contains("Launch Friday")); XCTAssertFalse(context.contains("secret"))
        for recipient in everyRecipient where recipient != .iCloudSync {
            XCTAssertFalse(ContextPolicy.allows(.memory(excluded), to: recipient), recipient.key)
        }
    }

    func testOldRuleTheLockShowsOnlyWhenNothingLeavesTheDevice() {
        XCTAssertEqual(everyRecipient.filter(ContextPolicy.keepsEverythingOnDevice).map(\.key),
                       ["apple-on-device", "chat:" + chat.uuidString, "voice:apple:local"])
    }

    func testOldRuleAttachmentsGoOnlyWhereTheirLevelAllowsAndLeaveOnlyWhenConfirmed() {
        var doc = ChatDocAttachment(sourceID: UUID(), kind: .doc, title: "Plans", text: "…", privacy: .personal)
        XCTAssertNil(AttachedContext.refusal([doc], to: .appleOnDevice), "Attached here without asking")
        XCTAssertNil(AttachedContext.refusal([doc], to: .applePrivateCloud))
        XCTAssertNotNil(AttachedContext.refusal([doc], to: api), "Needs the destination confirmed")
        doc.sharedWith = api.key
        XCTAssertNil(AttachedContext.refusal([doc], to: api), "Confirming is the grant for this item")
        XCTAssertNotNil(AttachedContext.refusal([doc], to: .apiModel(profile: UUID(), host: "other")), "…for that recipient only")
        var local = ChatDocAttachment(sourceID: UUID(), kind: .journal, title: "Tuesday", text: "…", privacy: .deviceOnly)
        local.sharedWith = api.key
        XCTAssertNil(AttachedContext.refusal([local], to: .appleOnDevice))
        XCTAssertNotNil(AttachedContext.refusal([local], to: .applePrivateCloud))
        XCTAssertNotNil(AttachedContext.refusal([local], to: api), "No confirmation opens Device only")
        let legacy = ChatDocAttachment(sourceID: UUID(), kind: .journal, title: "Old", text: "…")
        XCTAssertEqual(legacy.contextItem.level, .sensitive, "An attachment from before levels uses its kind's default")
    }

    func testOldRuleBrokerStillKeepsUnclassifiedAndCredentialRecordsOnDevice() async throws {
        let owner = UUID(), broker = ContextBroker()
        let saved = try await broker.put(.init(ownerID: owner, source: .init(kind: .directUser, identifier: "x", observedAt: now),
                                               compartment: .conversation, fields: [.text: "Orion"]), now: now)
        XCTAssertEqual(saved.level, .deviceOnly, "No classifier: stays on this device")
        for recipient in [RecipientID.applePrivateCloud, api, .nearbyPeer(UUID())] {
            do {
                _ = try await broker.mintGrant(.init(ownerID: owner, purpose: .conversation, recipient: recipient, fields: [.text],
                    recordRevisions: [saved.id: saved.revision], expiresAt: now + 60), authority: .authenticatedOwner(owner), now: now)
                XCTFail("\(recipient.key) must not receive it")
            } catch { XCTAssertEqual(error as? ContextBrokerError, .unauthorized) }
        }
    }

    // MARK: Helpers

    private func decide(_ item: ContextItem, _ recipient: RecipientID, grants: [RecipientGrant]) -> DisclosureDenial? {
        ContextPolicy.evaluate([item], to: recipient, purpose: .conversation, grants: grants, now: now).denied[item.ref]
    }
    private func allows(_ level: PrivacyLevel, _ recipient: RecipientID) -> Bool {
        ContextPolicy.allows(.init(.init(.memory, UUID()), level: level), to: recipient, now: now)
    }
}

import XCTest
import CryptoKit
@testable import KemoSabe

final class CompanionFrameworkTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func testRecallFindsRelevantNotesBeyondFirstTwelveWithoutExcludedNotes() {
        var notes = (0..<20).map { MemoryNote(text: "General note \($0)") }
        let relevant = MemoryNote(text: "Orion deployment uses a staged migration")
        notes.append(relevant)
        notes.append(MemoryNote(text: "Orion deployment secret", useInChat: false))
        let selected = MemoryRecall.relevant(notes, to: "How does Orion deployment work?")
        XCTAssertEqual(selected.first?.id, relevant.id)
        XCTAssertEqual(selected.count, 1) // Do not fill the rest with unrelated notes.
        XCTAssertFalse(selected.contains { !$0.useInChat })
    }
    func testVoiceMatchIsNotAuthorityAndRelationshipsAreNotGrants() {
        let owner = PersonProfile(name: "Owner", ageBand: .adult, voiceEnrollmentConsented: true)
        let visitor = PersonProfile(name: "Visitor", ageBand: .teen, voiceEnrollmentConsented: true)
        let music = GraphResource(ownerID: owner.id, name: "Kitchen music")
        XCTAssertEqual(SocialGraphPolicy.decide(.changeMusic, speaker: .voiceCandidate(owner.id), profiles: [owner], resource: music, now: now), .requireAuthentication)
        XCTAssertEqual(SocialGraphPolicy.decide(.changeMusic, speaker: .authenticated(visitor.id, expiresAt: now+60), profiles: [owner,visitor], resource: music, now: now), .requireOwnerApproval)
        XCTAssertEqual(SocialGraphPolicy.decide(.generalAnswer, speaker: .unknown, profiles: [owner], resource: music, now: now), .answer(.youngChild))
        XCTAssertEqual(SocialGraphPolicy.decide(.generalAnswer, speaker: .authenticated(UUID(), expiresAt: now+60), profiles: [], resource: nil, now: now), .answer(.youngChild))
    }
    func testGrantIsScopedAndExpires() {
        let person = PersonProfile(name: "Friend", ageBand: .adult)
        let resource = GraphResource(ownerID: UUID(), name: "Music", grants: [.init(personID: person.id, capability: .changeMusic, expiresAt: now+30)])
        let speaker = SpeakerEvidence.authenticated(person.id, expiresAt: now+60)
        XCTAssertEqual(SocialGraphPolicy.decide(.changeMusic, speaker: speaker, profiles: [person], resource: resource, now: now), .allow)
        XCTAssertEqual(SocialGraphPolicy.decide(.sendEmail, speaker: speaker, profiles: [person], resource: resource, now: now), .requireOwnerApproval)
        XCTAssertEqual(SocialGraphPolicy.decide(.changeMusic, speaker: speaker, profiles: [person], resource: resource, now: now+31), .requireOwnerApproval)
    }
    func testPrivateSpecialtyIsFilteredBeforePrompt() {
        let person = PersonProfile(name: "Owner", ageBand: .adult), agent = UUID()
        let note = KnowledgeRecord(agentID: agent, resource: .init(ownerID: person.id, name: "Private work"), specialty: "Engineering", text: "Private design", source: "My note", updatedAt: now, expiresAt: nil)
        let speaker = SpeakerEvidence.authenticated(person.id, expiresAt: now+60)
        XCTAssertEqual(KnowledgeRetrieval.context(records: [note], agentID: agent, specialty: "Engineering", speaker: speaker, people: [person], remote: false, now: now).count, 1)
        XCTAssertTrue(KnowledgeRetrieval.context(records: [note], agentID: agent, specialty: "Engineering", speaker: .voiceCandidate(person.id), people: [person], remote: false, now: now).isEmpty)
        XCTAssertTrue(KnowledgeRetrieval.context(records: [note], agentID: agent, specialty: "Engineering", speaker: speaker, people: [person], remote: true, now: now).isEmpty)
    }
    func testCloudSpeechRequiresOptInAndRejectsSensitiveContext() {
        // The old rule, now by privacy level (health, child, and company data are Sensitive, `PrivacyLevel.floor`).
        XCTAssertFalse(VoiceRoutingPolicy().allows(.openAI, level: .open))
        let policy = VoiceRoutingPolicy(localOnly: false, cloudVoiceConsent: true)
        XCTAssertTrue(policy.allows(.openAI, level: .open))
        XCTAssertTrue(policy.allows(.openAI, level: .personal))
        for labels in [BrokerSensitivity.health, .child, .company] {
            XCTAssertFalse(policy.allows(.openAI, level: PrivacyLevel.floor(labels)))
        }
        for level in [PrivacyLevel.deviceOnly, .secret] { XCTAssertFalse(policy.allows(.openAI, level: level)) }
        XCTAssertTrue(VoiceRoutingPolicy().allows(.apple, level: .sensitive), "A local voice speaks the reply")
        XCTAssertEqual(SpeechText.prepared("**Hello** [there](https://example.com)."), "Hello there.")
    }
    func testRoutineApprovalDurabilityAndSingleClaim() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("ledger.json")
        let ledger = RoutineLedger(url: url)
        let p = RoutineProposal(key: "alarm", kind: .alarm, title: "Alarm", body: "At 8", scheduledAt: now+3600, createdAt: now, expiresAt: now+600)
        let first = try await ledger.propose(p), duplicate = try await ledger.propose(p)
        XCTAssertEqual(first.id, duplicate.id)
        do { _ = try await ledger.claim(id: first.id, now: now); XCTFail("Claim without approval") } catch {}
        do { try await ledger.approve(id: first.id, digest: "changed", now: now); XCTFail("Stale approval") } catch {}
        try await ledger.approve(id: first.id, digest: first.digest, now: now)
        let reopened = RoutineLedger(url: url)
        let restored = try await reopened.snapshot()
        XCTAssertEqual(restored.proposals.first?.status, .approved)
        _ = try await reopened.claim(id: first.id, now: now)
        do { _ = try await reopened.claim(id: first.id, now: now); XCTFail("Double claim") } catch {}
        try await reopened.recover(now: now)
        let recovered = try await reopened.snapshot()
        XCTAssertEqual(recovered.proposals.first?.status, .uncertain)
    }
    func testClearingRecentActivityKeepsPendingWorkAndAlarmsStillAhead() async throws {
        let ledger = RoutineLedger(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("ledger.json"))
        let done = try await ledger.propose(.init(key: "a", kind: .draft, title: "Done", body: "x", createdAt: now, expiresAt: now+3600))
        try await ledger.reject(id: done.id)
        let pending = try await ledger.propose(.init(key: "b", kind: .draft, title: "Pending", body: "y", createdAt: now, expiresAt: now+3600))
        var alarm = try await ledger.propose(.init(key: "c", kind: .alarm, title: "Alarm", body: "z", scheduledAt: now+7200, createdAt: now, expiresAt: now+7200))
        alarm = try await ledger.snapshot().proposals.first { $0.id == alarm.id }!
        XCTAssertFalse(RoutineLedger.clearable(pending, now: now))
        var completedAlarm = alarm; completedAlarm.status = .completed
        XCTAssertFalse(RoutineLedger.clearable(completedAlarm, now: now), "A set alarm still ahead stays so it can be cancelled")
        XCTAssertTrue(RoutineLedger.clearable(completedAlarm, now: now+8000))
        let removed = try await ledger.clearHistory(now: now)
        XCTAssertEqual(removed, 1)
        let left = try await ledger.snapshot().proposals.map(\.title)
        XCTAssertEqual(Set(left), ["Pending", "Alarm"])
    }
    func testMorningCoalescesAndDoesNotPretendToMeasureSleep() async throws {
        let ledger = RoutineLedger(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("ledger.json"))
        try await ledger.setEnabled(true); try await ledger.recordBedtime(now-8*3600)
        try await ledger.prepareMorning(now: now); try await ledger.prepareMorning(now: now+5)
        let snapshot = try await ledger.snapshot()
        XCTAssertTrue(snapshot.proposals.isEmpty, "A refresh must not manufacture a canned check-in")
        XCTAssertEqual(snapshot.context?.observations.count, 1)
        XCTAssertEqual(snapshot.context?.observations.first?.kind, .reportedBedtime)
    }
    func testPeerSignatureRecipientAndReplay() async throws {
        let key = Curve25519.Signing.PrivateKey(), sender = UUID(), recipient = UUID()
        let message = AgentMessage(sender: sender, recipient: recipient, conversation: UUID(), kind: .proposal, createdAt: now, expiresAt: now+600, text: "Meet at noon?")
        let signed = try SignedAgentMessage.sign(message, key: key)
        let permission = PeerPermission(agentID: sender, publicKey: key.publicKey.rawRepresentation, allowedKinds: [.proposal], expiresAt: now+3600)
        XCTAssertThrowsError(try AgentExchangeVerifier.verify(signed, recipient: UUID(), permission: permission, now: now))
        let tampered = SignedAgentMessage(payload: signed.payload + Data([1]), signature: signed.signature)
        XCTAssertThrowsError(try AgentExchangeVerifier.verify(tampered, recipient: recipient, permission: permission, now: now))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("inbox.json")
        _ = try await PeerInbox(url: url).receive(signed, recipient: recipient, permission: permission, now: now)
        do { _ = try await PeerInbox(url: url).receive(signed, recipient: recipient, permission: permission, now: now); XCTFail("Replay across launch") } catch {}
    }
}

import XCTest
@testable import KemoSabe

final class ContextBrokerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let purpose: ContextPurpose = "conversation"
    private let localModel: RecipientID = .appleOnDevice

    private func source(_ kind: ContextSourceKind) -> ContextSourceAttribution {
        .init(kind: kind, identifier: "fixture", observedAt: now)
    }

    private func draft(owner: UUID, kind: ContextSourceKind = .directUser,
                       compartment: ContextCompartment = .conversation,
                       text: String = "Orion launch", expiresAt: Date? = nil,
                       lineage: [ContextLineageReference] = [],
                       restrictions: ContextRestrictions = .init()) -> ContextRecordDraft {
        .init(ownerID: owner, source: source(kind), compartment: compartment,
              expiresAt: expiresAt, lineage: lineage, restrictions: restrictions,
              fields: [.text: text])
    }

    private func grant(_ broker: ContextBroker, owner: UUID, records: [AttributedContextRecord],
                       recipient: RecipientID? = nil, fields: Set<ContextField> = [.text],
                       purpose: ContextPurpose? = nil) async throws -> ContextDisclosureGrant {
        try await broker.mintGrant(.init(ownerID: owner, purpose: purpose ?? self.purpose,
            recipient: recipient ?? localModel, fields: fields,
            recordRevisions: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.revision) }),
            expiresAt: now.addingTimeInterval(300)), authority: .authenticatedOwner(owner), now: now)
    }

    func testDeterministicFloorCannotBeLoweredByClassifier() async throws {
        let classifier = FixtureClassifier(result: .sensitivity(.ordinary))
        let broker = ContextBroker(classifier: classifier)
        let saved = try await broker.put(draft(owner: UUID(), kind: .healthStore,
            compartment: .health("health-store"), text: "A1C result"), now: now)
        XCTAssertTrue(saved.sensitivity.contains(.health))
        XCTAssertTrue(saved.sensitivity.contains(.personal))
        XCTAssertTrue(saved.sensitivity.contains(.ordinary))
    }

    func testMissingClassifierKeepsOfflineMemoryUsableButLocalOnly() async throws {
        let owner = UUID(), broker = ContextBroker()
        let saved = try await broker.put(draft(owner: owner), now: now)
        XCTAssertTrue(saved.restrictions.localOnly)
        _ = try await grant(broker, owner: owner, records: [saved])

        let remote = ContextGrantRequest(ownerID: owner, purpose: purpose,
            recipient: .apiModel(profile: UUID(), host: "server.invalid"), fields: [.text],
            recordRevisions: [saved.id: saved.revision], expiresAt: now + 60)
        await XCTAssertThrowsContext(.unauthorized) {
            _ = try await broker.mintGrant(remote, authority: .hostPolicy, now: self.now)
        }
    }

    func testCredentialFieldsAndPrivateKeyMaterialHaveHardSecretFloor() async throws {
        let owner = UUID(), classifier = FixtureClassifier(result: .sensitivity(.ordinary))
        let broker = ContextBroker(classifier: classifier)
        var credential = draft(owner: owner, text: "credential")
        credential.fields = [ContextField(rawValue: "privateKey"): "opaque-value"]
        let named = try await broker.put(credential, now: now)
        XCTAssertTrue(named.sensitivity.contains(.secret))
        XCTAssertTrue(named.restrictions.localOnly)

        let keyText = "-----BEGIN PRIVATE KEY-----\nfixture\n-----END PRIVATE KEY-----"
        let material = try await broker.put(draft(owner: owner, text: keyText), now: now)
        XCTAssertTrue(material.sensitivity.contains(.secret))
        XCTAssertTrue(material.restrictions.localOnly)

        let ordinary = try await broker.put(draft(owner: owner, text: "The token budget is 900 words"), now: now)
        XCTAssertFalse(ordinary.sensitivity.contains(.secret), "Free text use is not deterministic credential evidence")
    }

    func testUnknownClassificationIsLocalOnlyAndRemoteClassifierIsRejected() async throws {
        let owner = UUID()
        let unknown = ContextBroker(classifier: FixtureClassifier(result: .unknown))
        let saved = try await unknown.put(draft(owner: owner), now: now)
        XCTAssertTrue(saved.restrictions.localOnly)
        let local = try await grant(unknown, owner: owner, records: [saved])
        XCTAssertEqual(local.recordRevisions, [saved.id: saved.revision])
        let remoteRequest = ContextGrantRequest(ownerID: owner, purpose: purpose,
            recipient: .apiModel(profile: UUID(), host: "server.invalid"), fields: [.text],
            recordRevisions: [saved.id: saved.revision], expiresAt: now + 60)
        await XCTAssertThrowsContext(.unauthorized) {
            _ = try await unknown.mintGrant(remoteRequest, authority: .authenticatedOwner(owner), now: self.now)
        }
        let remote = ContextBroker(classifier: FixtureClassifier(runsLocally: false,
            result: .sensitivity(.ordinary)))
        await XCTAssertThrowsContext(.classifierMustBeLocal) {
            _ = try await remote.put(self.draft(owner: owner), now: self.now)
        }
    }

    func testPolicyFirstRetrievalReturnsEmptyWithoutRelevantAuthorizedFallback() async throws {
        let owner = UUID(), broker = ContextBroker()
        let allowed = try await broker.put(draft(owner: owner, text: "Orion launch"), now: now)
        _ = try await broker.put(draft(owner: owner, text: "forbidden zephyr secret"), now: now)
        let access = try await grant(broker, owner: owner, records: [allowed])
        let request = ContextRetrievalRequest(ownerID: owner, purpose: purpose, recipient: localModel,
            query: "zephyr", compartments: [.conversation], fields: [.text])
        let result = try await broker.retrieve(request, using: access, now: now)
        XCTAssertTrue(result.isEmpty)

        for emptyQuery in ["", "the and please"] {
            let empty = try await broker.retrieve(.init(ownerID: owner, purpose: purpose,
                recipient: localModel, query: emptyQuery, compartments: [.conversation], fields: [.text]),
                using: access, now: now)
            XCTAssertTrue(empty.isEmpty)
        }
    }

    func testGrantBindsOwnerPurposeRecipientFieldsAndRevision() async throws {
        let owner = UUID(), broker = ContextBroker()
        var item = draft(owner: owner)
        item.fields = [.text: "Orion", .title: "Launch"]
        let saved = try await broker.put(item, now: now)
        let access = try await grant(broker, owner: owner, records: [saved], fields: [.text])
        XCTAssertEqual(access.recordRevisions, [saved.id: 1])
        await XCTAssertThrowsContext(.unauthorized) {
            _ = try await broker.retrieve(.init(ownerID: owner, purpose: "other",
                recipient: self.localModel, query: "Orion", compartments: [.conversation], fields: [.text]),
                using: access, now: self.now)
        }
        await XCTAssertThrowsContext(.unauthorized) {
            _ = try await broker.makeEnvelope(recordIDs: [saved.id], using: access,
                fields: [.title], now: self.now)
        }
        await XCTAssertThrowsContext(.unauthorized) {
            _ = try await broker.retrieve(.init(ownerID: UUID(), purpose: self.purpose,
                recipient: self.localModel, query: "Orion", compartments: [.conversation], fields: [.text]),
                using: access, now: self.now)
        }
    }

    func testModelPrivacyOpinionNeverMintsGrant() async throws {
        let owner = UUID(), broker = ContextBroker()
        let saved = try await broker.put(draft(owner: owner), now: now)
        let request = ContextGrantRequest(ownerID: owner, purpose: purpose, recipient: localModel,
            fields: [.text], recordRevisions: [saved.id: saved.revision], expiresAt: now + 60)
        await XCTAssertThrowsContext(.modelCannotGrant) {
            _ = try await broker.mintGrant(request, authority: .modelOutput, now: self.now)
        }
    }

    func testDerivedRecordJoinsSensitivityExpiryAndRestrictions() async throws {
        let owner = UUID(), broker = ContextBroker()
        let health = try await broker.put(draft(owner: owner, kind: .healthStore, compartment: .health("health-store"),
            text: "Health source", expiresAt: now + 120,
            restrictions: .init(localOnly: true, fields: [.text, .summary])), now: now)
        let company = try await broker.put(draft(owner: owner, kind: .companyVault, compartment: .company("employer-a"),
            text: "Company source", expiresAt: now + 60,
            restrictions: .init(purposes: [purpose], fields: [.text, .title])), now: now)
        let derived = ContextRecordDraft(ownerID: owner, source: source(.derived),
            compartment: .conversation, expiresAt: now + 300,
            lineage: [.init(recordID: health.id, revision: health.revision),
                      .init(recordID: company.id, revision: company.revision)],
            fields: [.text: "Joined summary"])
        let saved = try await broker.put(derived, now: now)
        XCTAssertTrue(saved.sensitivity.contains(.health))
        XCTAssertTrue(saved.sensitivity.contains(.company))
        XCTAssertTrue(saved.restrictions.localOnly)
        XCTAssertEqual(saved.restrictions.fields, [.text])
        XCTAssertEqual(saved.restrictions.purposes, [purpose])
        XCTAssertEqual(saved.expiresAt, now + 60)
        XCTAssertEqual(saved.requiredCompartments,
            [.conversation, .health("health-store"), .company("employer-a")])

        let access = try await grant(broker, owner: owner, records: [saved])
        let incompletelyScoped = try await broker.retrieve(.init(ownerID: owner, purpose: purpose,
            recipient: localModel, query: "Joined", compartments: [.conversation, .company("employer-a")],
            fields: [.text]), using: access, now: now)
        XCTAssertTrue(incompletelyScoped.isEmpty)
    }

    func testEnvelopeIsRecipientBoundSingleUseAndPolicyEpochCheckedAtSendTime() async throws {
        let owner = UUID(), broker = ContextBroker()
        let saved = try await broker.put(draft(owner: owner), now: now)
        let access = try await grant(broker, owner: owner, records: [saved])
        let envelope = try await broker.makeEnvelope(recordIDs: [saved.id], using: access,
            fields: [.text], now: now)
        await XCTAssertThrowsContext(.unauthorized) {
            _ = try await broker.validateForSend(envelope, recipient: .nearbyPeer(UUID()),
                purpose: self.purpose, now: self.now)
        }
        let payload = try await broker.validateForSend(envelope, recipient: localModel,
            purpose: purpose, now: now)
        XCTAssertEqual(payload.records.first?.fields[.text], "Orion launch")
        await XCTAssertThrowsContext(.envelopeAlreadyUsed) {
            _ = try await broker.validateForSend(envelope, recipient: self.localModel,
                purpose: self.purpose, now: self.now)
        }

        let second = try await broker.makeEnvelope(recordIDs: [saved.id], using: access,
            fields: [.text], now: now)
        await broker.replacePolicy(.conservative)
        await XCTAssertThrowsContext(.stalePolicy) {
            _ = try await broker.validateForSend(second, recipient: self.localModel,
                purpose: self.purpose, now: self.now)
        }
    }

    func testRevokingAncestorInvalidatesDescendantAndCachedEnvelope() async throws {
        let owner = UUID(), broker = ContextBroker()
        let root = try await broker.put(draft(owner: owner), now: now)
        let childDraft = ContextRecordDraft(ownerID: owner, source: source(.derived),
            compartment: .conversation,
            lineage: [.init(recordID: root.id, revision: root.revision)], fields: [.text: "Derived"])
        let child = try await broker.put(childDraft, now: now)
        let access = try await grant(broker, owner: owner, records: [child])
        let envelope = try await broker.makeEnvelope(recordIDs: [child.id], using: access,
            fields: [.text], now: now)
        try await broker.revoke(recordID: root.id, ownerID: owner)
        let revokedChild = try await broker.record(id: child.id, ownerID: owner, now: now)
        XCTAssertNil(revokedChild)
        await XCTAssertThrowsContext(.revoked) {
            _ = try await broker.validateForSend(envelope, recipient: self.localModel,
                purpose: self.purpose, now: self.now)
        }
    }

    func testSensitiveRemoteModelVoiceAndPeerUseSameDenyingSinkPolicy() async throws {
        let owner = UUID(), broker = ContextBroker()
        let health = try await broker.put(draft(owner: owner, kind: .healthStore,
            compartment: .health("health-store"), text: "Private health"), now: now)
        let recipients: [RecipientID] = [
            .apiModel(profile: UUID(), host: "server.invalid"), .voice(backend: "cloud-voice", local: false), .nearbyPeer(UUID())
        ]
        for recipient in recipients {
            let request = ContextGrantRequest(ownerID: owner, purpose: purpose, recipient: recipient,
                fields: [.text], recordRevisions: [health.id: health.revision], expiresAt: now + 60)
            await XCTAssertThrowsContext(.unauthorized) {
                _ = try await broker.mintGrant(request, authority: .authenticatedOwner(owner), now: self.now)
            }
        }
    }

    func testCompanyNamespacesCannotCrossRetrievalBoundaryForSameOwner() async throws {
        let owner = UUID(), broker = ContextBroker()
        let alpha = try await broker.put(draft(owner: owner, kind: .companyVault,
            compartment: .company("employer-a"), text: "Alpha roadmap"), now: now)
        let beta = try await broker.put(draft(owner: owner, kind: .companyVault,
            compartment: .company("employer-b"), text: "Beta roadmap"), now: now)
        let access = try await grant(broker, owner: owner, records: [alpha, beta])
        let result = try await broker.retrieve(.init(ownerID: owner, purpose: purpose,
            recipient: localModel, query: "roadmap", compartments: [.company("employer-a")],
            fields: [.text]), using: access, now: now)
        XCTAssertEqual(result.map(\.id), [alpha.id])
        XCTAssertFalse(result.contains { $0.id == beta.id })
    }

    func testGrantAndEnvelopeCachesEvictOldestFramesAtBounds() async throws {
        let owner = UUID(), broker = ContextBroker()
        let saved = try await broker.put(draft(owner: owner), now: now)
        var firstGrant: ContextDisclosureGrant?
        var newestGrant: ContextDisclosureGrant?
        for index in 0...256 {
            let issued = now + Double(index)
            let request = ContextGrantRequest(ownerID: owner, purpose: purpose, recipient: localModel,
                fields: [.text], recordRevisions: [saved.id: saved.revision], expiresAt: now + 1_000)
            let value = try await broker.mintGrant(request, authority: .hostPolicy, now: issued)
            if index == 0 { firstGrant = value }
            newestGrant = value
        }
        let staleGrant = try XCTUnwrap(firstGrant)
        await XCTAssertThrowsContext(.revoked) {
            _ = try await broker.retrieve(.init(ownerID: owner, purpose: self.purpose,
                recipient: self.localModel, query: "Orion", compartments: [.conversation], fields: [.text]),
                using: staleGrant, now: self.now + 257)
        }

        let currentGrant = try XCTUnwrap(newestGrant)
        var firstEnvelope: DisclosureEnvelope?
        for index in 0...128 {
            let envelope = try await broker.makeEnvelope(recordIDs: [saved.id], using: currentGrant,
                fields: [.text], now: now + 257 + Double(index) / 100)
            if index == 0 { firstEnvelope = envelope }
        }
        let evicted = try XCTUnwrap(firstEnvelope)
        await XCTAssertThrowsContext(.revoked) {
            _ = try await broker.validateForSend(evicted, recipient: self.localModel,
                purpose: self.purpose, now: self.now + 259)
        }
    }
}

private struct FixtureClassifier: LocalContextClassifier {
    var runsLocally = true
    let result: ContextClassification
    func classify(_ input: ContextClassificationInput) async throws -> ContextClassification { result }
}

private func XCTAssertThrowsContext<T>(_ expected: ContextBrokerError,
                                       _ expression: () async throws -> T,
                                       file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch let error as ContextBrokerError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error \(error)", file: file, line: line)
    }
}

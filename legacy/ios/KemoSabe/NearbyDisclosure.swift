import Foundation

/// A short-lived, peer-specific authorization for one visible outgoing turn.
/// It contains no plaintext and cannot be redirected to a model or voice sink.
struct NearbyDisclosureEnvelope: Sendable {
    fileprivate let broker: ContextBroker
    fileprivate let envelope: DisclosureEnvelope
    fileprivate let recordIDs: [UUID]
    fileprivate let outgoingRecordID: UUID
    fileprivate let recipientPeerID: UUID
    fileprivate let conversationID: UUID
    let expiresAt: Date
}

enum NearbyDisclosureError: Error, Equatable {
    case invalidInput
    case outgoingTurnMissing
    case contentChanged
}

private struct ExplicitNearbyContextClassifier: LocalContextClassifier {
    let runsLocally = true

    func classify(_ input: ContextClassificationInput) async throws -> ContextClassification {
        // The person explicitly entered the brief or can see the bounded exchange.
        // Keep a personal floor; ContextBroker still applies its deterministic
        // credential floor and will force detected credential material local-only.
        .sensitivity(input.deterministicFloor.union(.personal))
    }
}

/// Owns an ephemeral ContextBroker namespace that can only describe the public
/// brief and visible nearby transcript. It has no API for memory IDs, voice IDs,
/// connector records, or arbitrary ContextDisclosureGrant construction.
actor NearbyDisclosure {
    private static let grantLifetime: TimeInterval = 5
    private let ownerID: UUID

    init(ownerID: UUID) {
        self.ownerID = ownerID
    }

    func makeEnvelope(publicBrief: String, visibleTranscript: [NearbyModelRequest.Turn],
                      outgoingTurnID: UUID, recipientPeerID: UUID,
                      conversationID: UUID, now: Date = Date()) async throws -> NearbyDisclosureEnvelope {
        let brief = publicBrief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard recipientPeerID != ownerID,
              brief.utf8.count <= NearbyKemoLimits.maximumSharedContextBytes,
              !visibleTranscript.isEmpty,
              visibleTranscript.count <= NearbyKemoLimits.maximumRounds,
              visibleTranscript.allSatisfy({ !$0.text.isEmpty && NearbyProtocol.boundedText($0.text) == $0.text }),
              let outgoing = visibleTranscript.last,
              outgoing.id == outgoingTurnID,
              outgoing.speaker == .thisKemo else {
            throw NearbyDisclosureError.invalidInput
        }

        let purpose = Self.purpose(conversationID)
        let expiry = now.addingTimeInterval(Self.grantLifetime)
        // The broker and all attributed plaintext records live only as long as
        // this one pending envelope. A long-running nearby coordinator therefore
        // cannot accumulate revoked transcript records across turns.
        let broker = ContextBroker(classifier: ExplicitNearbyContextClassifier())
        let restrictions = ContextRestrictions(
            recipientKinds: [.nearbyPeer], purposes: [purpose], fields: [.text]
        )
        var saved: [AttributedContextRecord] = []

        do {
            if !brief.isEmpty {
                let record = try await broker.put(.init(
                    ownerID: ownerID,
                    source: .init(kind: .directUser,
                                  identifier: "nearby-public-brief:\(conversationID.uuidString)",
                                  observedAt: now),
                    compartment: .conversation,
                    declaredSensitivity: .personal,
                    expiresAt: expiry,
                    restrictions: restrictions,
                    fields: [.text: brief]
                ), now: now)
                saved.append(record)
            }

            var outgoingRecordID: UUID?
            for (index, turn) in visibleTranscript.enumerated() {
                let isOpening = index == 0 && turn.speaker == .thisKemo
                let sourceKind: ContextSourceKind = turn.speaker == .nearbyKemo ? .peer : (isOpening ? .directUser : .derived)
                let lineage = sourceKind == .derived
                    ? saved.map { ContextLineageReference(recordID: $0.id, revision: $0.revision) }
                    : []
                let sourcePrefix = turn.speaker == .nearbyKemo ? "nearby-peer-turn" : "nearby-this-kemo-turn"
                let record = try await broker.put(.init(
                    ownerID: ownerID,
                    source: .init(kind: sourceKind,
                                  identifier: "\(sourcePrefix):\(recipientPeerID.uuidString):\(turn.id.uuidString)",
                                  observedAt: now),
                    compartment: .conversation,
                    declaredSensitivity: .personal,
                    expiresAt: expiry,
                    lineage: lineage,
                    restrictions: restrictions,
                    fields: [.text: turn.text]
                ), now: now)
                saved.append(record)
                if turn.id == outgoingTurnID { outgoingRecordID = record.id }
            }

            guard let outgoingRecordID else { throw NearbyDisclosureError.outgoingTurnMissing }
            let recipient = RecipientID.nearbyPeer(recipientPeerID)
            let grant = try await broker.mintGrant(.init(
                ownerID: ownerID,
                purpose: purpose,
                recipient: recipient,
                fields: [.text],
                recordRevisions: Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0.revision) }),
                expiresAt: expiry
            ), authority: .authenticatedOwner(ownerID), now: now)
            let envelope = try await broker.makeEnvelope(
                recordIDs: saved.map(\.id), using: grant, fields: [.text], now: now
            )
            return .init(broker: broker, envelope: envelope, recordIDs: saved.map(\.id),
                         outgoingRecordID: outgoingRecordID,
                         recipientPeerID: recipientPeerID, conversationID: conversationID,
                         expiresAt: expiry)
        } catch {
            await revoke(saved.map(\.id), from: broker)
            throw error
        }
    }

    /// Call immediately before sealing and transport send. ContextBroker checks
    /// recipient, purpose, expiry, record revisions, policy epoch, and single use.
    func validateForSend(_ pending: NearbyDisclosureEnvelope, recipientPeerID: UUID,
                         conversationID: UUID, now: Date = Date()) async throws -> String {
        do {
            let payload = try await pending.broker.validateForSend(
                pending.envelope,
                recipient: .nearbyPeer(recipientPeerID),
                purpose: Self.purpose(conversationID),
                now: now
            )
            guard pending.recipientPeerID == recipientPeerID,
                  pending.conversationID == conversationID,
                  payload.recipient == .nearbyPeer(recipientPeerID),
                  payload.purpose == Self.purpose(conversationID),
                  let outgoing = payload.records.first(where: { $0.id == pending.outgoingRecordID }),
                  let text = outgoing.fields[.text] else {
                throw NearbyDisclosureError.contentChanged
            }
            await revoke(pending.recordIDs, from: pending.broker)
            return text
        } catch {
            await revoke(pending.recordIDs, from: pending.broker)
            throw error
        }
    }

    private func revoke(_ recordIDs: [UUID], from broker: ContextBroker) async {
        for recordID in recordIDs {
            try? await broker.revoke(recordID: recordID, ownerID: ownerID)
        }
    }

    private static func purpose(_ conversationID: UUID) -> ContextPurpose {
        .init(rawValue: "nearby-exchange:\(conversationID.uuidString)")
    }
}

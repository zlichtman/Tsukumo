import XCTest
@testable import KemoSabe

final class NearbyDisclosureTests: XCTestCase {
    private let owner = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let peer = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    private let conversation = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testVisibleContextEntersPeerBoundEnvelopeAndReturnsOnlyOutgoingTurn() async throws {
        let disclosure = NearbyDisclosure(ownerID: owner)
        let opening = NearbyModelRequest.Turn(id: UUID(), speaker: .thisKemo, text: "Hello nearby")
        let incoming = NearbyModelRequest.Turn(id: UUID(), speaker: .nearbyKemo, text: "Want to compare projects?")
        let outgoing = NearbyModelRequest.Turn(id: UUID(), speaker: .thisKemo, text: "Yes, I’m building a garden map.")
        let pending = try await disclosure.makeEnvelope(
            publicBrief: "Gardening and maps",
            visibleTranscript: [opening, incoming, outgoing],
            outgoingTurnID: outgoing.id,
            recipientPeerID: peer,
            conversationID: conversation,
            now: now
        )

        let approved = try await disclosure.validateForSend(
            pending, recipientPeerID: peer, conversationID: conversation,
            now: now.addingTimeInterval(1)
        )

        XCTAssertEqual(approved, outgoing.text)
        await XCTAssertThrowsDisclosure {
            _ = try await disclosure.validateForSend(
                pending, recipientPeerID: self.peer, conversationID: self.conversation,
                now: self.now.addingTimeInterval(2)
            )
        }
    }

    func testEnvelopeCannotBeRedirectedToAnotherPeerOrConversation() async throws {
        let wrongPeerDisclosure = NearbyDisclosure(ownerID: owner)
        let outgoing = NearbyModelRequest.Turn(id: UUID(), speaker: .thisKemo, text: "Peer-bound")
        let wrongPeerEnvelope = try await wrongPeerDisclosure.makeEnvelope(
            publicBrief: "Public",
            visibleTranscript: [outgoing],
            outgoingTurnID: outgoing.id,
            recipientPeerID: peer,
            conversationID: conversation,
            now: now
        )
        await XCTAssertThrowsDisclosure(.unauthorized) {
            _ = try await wrongPeerDisclosure.validateForSend(
                wrongPeerEnvelope, recipientPeerID: UUID(), conversationID: self.conversation,
                now: self.now.addingTimeInterval(1)
            )
        }

        let wrongConversationDisclosure = NearbyDisclosure(ownerID: owner)
        let wrongConversationEnvelope = try await wrongConversationDisclosure.makeEnvelope(
            publicBrief: "Public",
            visibleTranscript: [outgoing],
            outgoingTurnID: outgoing.id,
            recipientPeerID: peer,
            conversationID: conversation,
            now: now
        )
        await XCTAssertThrowsDisclosure(.unauthorized) {
            _ = try await wrongConversationDisclosure.validateForSend(
                wrongConversationEnvelope, recipientPeerID: self.peer, conversationID: UUID(),
                now: self.now.addingTimeInterval(1)
            )
        }
    }

    func testExpiredEnvelopeCannotPassSendBoundary() async throws {
        let disclosure = NearbyDisclosure(ownerID: owner)
        let outgoing = NearbyModelRequest.Turn(id: UUID(), speaker: .thisKemo, text: "Short lived")
        let pending = try await disclosure.makeEnvelope(
            publicBrief: "",
            visibleTranscript: [outgoing],
            outgoingTurnID: outgoing.id,
            recipientPeerID: peer,
            conversationID: conversation,
            now: now
        )
        XCTAssertEqual(pending.expiresAt, now.addingTimeInterval(5))

        await XCTAssertThrowsDisclosure {
            _ = try await disclosure.validateForSend(
                pending, recipientPeerID: self.peer, conversationID: self.conversation,
                now: self.now.addingTimeInterval(6)
            )
        }
    }

    func testCredentialMaterialCannotReceivePeerGrant() async {
        let disclosure = NearbyDisclosure(ownerID: owner)
        let outgoing = NearbyModelRequest.Turn(id: UUID(), speaker: .thisKemo, text: "Hello")

        await XCTAssertThrowsDisclosure(.unauthorized) {
            _ = try await disclosure.makeEnvelope(
                publicBrief: "-----BEGIN PRIVATE KEY-----\nnot-a-real-key\n-----END PRIVATE KEY-----",
                visibleTranscript: [outgoing],
                outgoingTurnID: outgoing.id,
                recipientPeerID: self.peer,
                conversationID: self.conversation,
                now: self.now
            )
        }
    }

    func testEnvelopeRequiresExactBoundedVisibleOutgoingTurn() async {
        let disclosure = NearbyDisclosure(ownerID: owner)
        let oversized = NearbyModelRequest.Turn(
            id: UUID(), speaker: .thisKemo,
            text: String(repeating: "x", count: NearbyKemoLimits.maximumTextCharacters + 1)
        )
        await XCTAssertThrowsNearbyDisclosure(.invalidInput) {
            _ = try await disclosure.makeEnvelope(
                publicBrief: "",
                visibleTranscript: [oversized],
                outgoingTurnID: oversized.id,
                recipientPeerID: self.peer,
                conversationID: self.conversation,
                now: self.now
            )
        }

        let incoming = NearbyModelRequest.Turn(id: UUID(), speaker: .nearbyKemo, text: "Not outgoing")
        await XCTAssertThrowsNearbyDisclosure(.invalidInput) {
            _ = try await disclosure.makeEnvelope(
                publicBrief: "",
                visibleTranscript: [incoming],
                outgoingTurnID: incoming.id,
                recipientPeerID: self.peer,
                conversationID: self.conversation,
                now: self.now
            )
        }
    }
}

private func XCTAssertThrowsDisclosure(
    _ expected: ContextBrokerError? = nil,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ expression: () async throws -> Void
) async {
    do {
        try await expression()
        XCTFail("Expected disclosure rejection", file: file, line: line)
    } catch {
        if let expected { XCTAssertEqual(error as? ContextBrokerError, expected, file: file, line: line) }
    }
}

private func XCTAssertThrowsNearbyDisclosure(
    _ expected: NearbyDisclosureError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ expression: () async throws -> Void
) async {
    do {
        try await expression()
        XCTFail("Expected nearby disclosure rejection", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? NearbyDisclosureError, expected, file: file, line: line)
    }
}

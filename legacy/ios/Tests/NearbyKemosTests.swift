import XCTest
import CryptoKit
@testable import KemoSabe

final class NearbyKemosTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let sender = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let recipient = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
    private let conversation = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

    func testKeyAgreementAndVerificationCodeAreStableAcrossPeerOrder() throws {
        let pair = try keys()
        XCTAssertEqual(pair.a.withUnsafeBytes { Data($0) }, pair.b.withUnsafeBytes { Data($0) })
        let first = NearbyProtocol.verificationCode(sessionKey: pair.a, handshakeTranscript: pair.aTranscript)
        let second = NearbyProtocol.verificationCode(sessionKey: pair.b, handshakeTranscript: pair.bTranscript)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 11)
        XCTAssertEqual(NearbyProtocol.verificationAlphabet.count, 32)
    }

    func testKeySubstitutionChangesCodeAndCannotDecrypt() throws {
        let pair = try keys()
        let attacker = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
        let substituted = try NearbyProtocol.sessionKey(privateKey: attacker, localID: sender, localNonce: nonce(1), remoteID: recipient, remoteNonce: nonce(2), remotePublicKey: pair.bPrivate.publicKey.rawRepresentation, conversationID: conversation)
        XCTAssertNotEqual(NearbyProtocol.verificationCode(sessionKey: pair.a, handshakeTranscript: pair.aTranscript), NearbyProtocol.verificationCode(sessionKey: substituted.0, handshakeTranscript: substituted.1))
        let data = try sealed(kind: .turn, text: "secret", key: pair.a)
        var replay = NearbyReplayWindow()
        XCTAssertThrowsError(try NearbyProtocol.decode(data, expectedSender: sender, conversationID: conversation, trusted: true, sessionKey: substituted.0, now: now, replay: &replay)) {
            XCTAssertEqual($0 as? NearbyProtocolError, .encryptionFailed)
        }
    }

    func testTamperedCiphertextIsRejected() throws {
        let pair = try keys()
        let data = try sealed(kind: .turn, text: "untampered", key: pair.a)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let original = try decoder.decode(NearbyWireMessage.self, from: data)
        var ciphertext = original.sealedPayload!; ciphertext[ciphertext.startIndex] ^= 1
        let tampered = NearbyWireMessage(version: original.version, id: original.id, senderID: original.senderID,
                                         conversationID: original.conversationID, kind: original.kind,
                                         createdAt: original.createdAt, expiresAt: original.expiresAt, round: original.round,
                                         nonce: nil, keyAgreementPublicKey: nil, sealedPayload: ciphertext)
        var replay = NearbyReplayWindow()
        XCTAssertThrowsError(try NearbyProtocol.decode(try tampered.encoded(), expectedSender: sender, conversationID: conversation, trusted: true, sessionKey: pair.b, now: now, replay: &replay))
        XCTAssertTrue(replay.expirations.isEmpty)
    }

    func testUnverifiedPeerCannotDecryptModelTurn() throws {
        let pair = try keys()
        let data = try sealed(kind: .turn, text: "private model output", key: pair.a)
        var replay = NearbyReplayWindow()
        XCTAssertThrowsError(try NearbyProtocol.decode(data, expectedSender: sender, conversationID: conversation, trusted: false, sessionKey: pair.b, now: now, replay: &replay)) {
            XCTAssertEqual($0 as? NearbyProtocolError, .untrustedPeer)
        }
        XCTAssertTrue(replay.expirations.isEmpty)
    }

    func testVerifiedMessageIsBoundedAndReplayRejected() throws {
        let pair = try keys()
        let data = try sealed(kind: .turn, text: "Hello", key: pair.a)
        var replay = NearbyReplayWindow()
        let decoded = try NearbyProtocol.decode(data, expectedSender: sender, conversationID: conversation, trusted: true, sessionKey: pair.b, now: now, replay: &replay)
        XCTAssertEqual(decoded.text, "Hello")
        XCTAssertThrowsError(try NearbyProtocol.decode(data, expectedSender: sender, conversationID: conversation, trusted: true, sessionKey: pair.b, now: now, replay: &replay)) {
            XCTAssertEqual($0 as? NearbyProtocolError, .replay)
        }
    }

    func testExpiredWrongConversationAndExcessRoundAreRejected() throws {
        let pair = try keys()
        var replay = NearbyReplayWindow()
        let expired = NearbyWireMessage(senderID: sender, conversationID: conversation, kind: .turn, createdAt: now-130, expiresAt: now-10, round: 0, nonce: nil, keyAgreementPublicKey: nil, sealedPayload: Data([0]))
        XCTAssertThrowsError(try NearbyProtocol.decode(try expired.encoded(), expectedSender: sender, conversationID: conversation, trusted: true, sessionKey: pair.b, now: now, replay: &replay)) {
            XCTAssertEqual($0 as? NearbyProtocolError, .expired)
        }
        let valid = try sealed(kind: .turn, text: "Hello", key: pair.a)
        XCTAssertThrowsError(try NearbyProtocol.decode(valid, expectedSender: sender, conversationID: UUID(), trusted: true, sessionKey: pair.b, now: now, replay: &replay)) {
            XCTAssertEqual($0 as? NearbyProtocolError, .wrongConversation)
        }
        let excessive = try NearbyProtocol.sealed(kind: .turn, senderID: sender, conversationID: conversation, round: NearbyKemoLimits.maximumRounds, text: "one too many", sessionKey: pair.a, now: now)
        XCTAssertThrowsError(try NearbyProtocol.decode(excessive, expectedSender: sender, conversationID: conversation, trusted: true, sessionKey: pair.b, now: now, replay: &replay)) {
            XCTAssertEqual($0 as? NearbyProtocolError, .invalidRound)
        }
    }

    func testHelloCarriesOnlyKeyAgreementMaterialAndCannotRepeat() throws {
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32))
        let data = try NearbyProtocol.hello(senderID: sender, conversationID: conversation, nonce: nonce(1), publicKey: privateKey.publicKey.rawRepresentation, now: now)
        var replay = NearbyReplayWindow()
        let decoded = try NearbyProtocol.decode(data, expectedSender: nil, conversationID: nil, trusted: false, sessionKey: nil, now: now, replay: &replay)
        XCTAssertEqual(decoded.text, "")
        XCTAssertEqual(decoded.nonce, nonce(1))
        XCTAssertThrowsError(try NearbyProtocol.validateInitialHello(existingSenderID: sender, remoteNonce: nonce(1), remotePublicKey: privateKey.publicKey.rawRepresentation)) {
            XCTAssertEqual($0 as? NearbyProtocolError, .replay)
        }
    }

    func testReflectionHandshakeIsRejected() throws {
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32))
        let otherKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 2, count: 32))
        XCTAssertThrowsError(try NearbyProtocol.sessionKey(privateKey: privateKey, localID: sender, localNonce: nonce(1), remoteID: sender, remoteNonce: nonce(2), remotePublicKey: otherKey.publicKey.rawRepresentation, conversationID: conversation))
        XCTAssertThrowsError(try NearbyProtocol.sessionKey(privateKey: privateKey, localID: sender, localNonce: nonce(1), remoteID: recipient, remoteNonce: nonce(2), remotePublicKey: privateKey.publicKey.rawRepresentation, conversationID: conversation))
    }

    func testTextBoundingAndTurnSequenceAreDeterministic() {
        XCTAssertEqual(NearbyProtocol.boundedText("  hello  "), "hello")
        XCTAssertEqual(NearbyProtocol.boundedText(String(repeating: "x", count: 2_000)).count, NearbyKemoLimits.maximumTextCharacters)
        XCTAssertNoThrow(try NearbyProtocol.validateTurnSequence(round: 0, existingTurnCount: 0, generating: false))
        XCTAssertNoThrow(try NearbyProtocol.validateTurnSequence(round: 2, existingTurnCount: 2, generating: false))
        XCTAssertThrowsError(try NearbyProtocol.validateTurnSequence(round: 1, existingTurnCount: 0, generating: false))
        XCTAssertThrowsError(try NearbyProtocol.validateTurnSequence(round: 1, existingTurnCount: 1, generating: true))
        XCTAssertThrowsError(try NearbyProtocol.validateTurnSequence(round: 4, existingTurnCount: NearbyKemoLimits.maximumRounds, generating: false))
    }

    func testSharedBriefUTF8BoundDoesNotSplitCharacters() {
        XCTAssertEqual(NearbyProtocol.boundedUTF8("hello", maximumBytes: 5), "hello")
        XCTAssertEqual(NearbyProtocol.boundedUTF8("hello!", maximumBytes: 5), "hello")
        XCTAssertEqual(NearbyProtocol.boundedUTF8("🙂🙂", maximumBytes: 7), "🙂")
        XCTAssertEqual(NearbyProtocol.boundedUTF8("anything", maximumBytes: 0), "")
        XCTAssertTrue(NearbyProtocol.acceptsPublicBrief(String(repeating: "a", count: 2_000), isDiscovering: false))
        XCTAssertFalse(NearbyProtocol.acceptsPublicBrief(String(repeating: "a", count: 2_001), isDiscovering: false))
        XCTAssertFalse(NearbyProtocol.acceptsPublicBrief("still valid length", isDiscovering: true))
    }

    @MainActor func testPublicBriefIsEphemeralAndByteBoundWhileOff() {
        let nearby = NearbyKemos { _ in "reply" }
        XCTAssertTrue(nearby.updatePublicBrief(String(repeating: "a", count: NearbyKemoLimits.maximumSharedContextBytes)))
        XCTAssertFalse(nearby.updatePublicBrief(String(repeating: "a", count: NearbyKemoLimits.maximumSharedContextBytes + 1)))
        XCTAssertEqual(nearby.publicBrief.utf8.count, NearbyKemoLimits.maximumSharedContextBytes)
    }

    private func keys() throws -> (a: SymmetricKey, b: SymmetricKey, aTranscript: Data, bTranscript: Data, aPrivate: Curve25519.KeyAgreement.PrivateKey, bPrivate: Curve25519.KeyAgreement.PrivateKey) {
        let aPrivate = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32))
        let bPrivate = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 2, count: 32))
        let a = try NearbyProtocol.sessionKey(privateKey: aPrivate, localID: sender, localNonce: nonce(1), remoteID: recipient, remoteNonce: nonce(2), remotePublicKey: bPrivate.publicKey.rawRepresentation, conversationID: conversation)
        let b = try NearbyProtocol.sessionKey(privateKey: bPrivate, localID: recipient, localNonce: nonce(2), remoteID: sender, remoteNonce: nonce(1), remotePublicKey: aPrivate.publicKey.rawRepresentation, conversationID: conversation)
        return (a.0, b.0, a.1, b.1, aPrivate, bPrivate)
    }

    private func nonce(_ byte: UInt8) -> Data { Data(repeating: byte, count: 32) }

    private func sealed(kind: NearbyWireKind, text: String, key: SymmetricKey) throws -> Data {
        try NearbyProtocol.sealed(kind: kind, senderID: sender, conversationID: conversation, round: 0, text: text, sessionKey: key, now: now, id: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!)
    }
}

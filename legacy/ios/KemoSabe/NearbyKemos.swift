import Foundation
import CryptoKit
import Observation
import Security
@preconcurrency import MultipeerConnectivity

/// The only input exposed to the model used by a nearby exchange. Shared context
/// comes only from the public brief entered on the Nearby screen.
struct NearbyModelRequest: Sendable, Equatable {
    struct Turn: Sendable, Equatable, Identifiable {
        enum Speaker: String, Sendable { case thisKemo, nearbyKemo }
        let id: UUID
        let speaker: Speaker
        let text: String
    }

    let conversationID: UUID
    let peerName: String
    let transcript: [Turn]
    let sharedContext: String?
}

typealias NearbyResponseGenerator = @Sendable (NearbyModelRequest) async throws -> String

enum NearbyKemoLimits {
    static let serviceType = "kemosabe-peer"
    static let protocolVersion = 2
    static let maximumWireBytes = 8_192
    static let maximumTextCharacters = 1_200
    static let maximumSharedContextBytes = 2_000
    static let maximumRounds = 4
    static let messageLifetime: TimeInterval = 120
    static let futureClockTolerance: TimeInterval = 15
    static let replayWindowCapacity = 256
    static let maximumDiscoveredPeers = 32
    static let maximumModelDuration: Duration = .seconds(30)
}

enum NearbyWireKind: String, Codable, Sendable { case hello, verification, turn, stop }

struct NearbyWireMessage: Codable, Equatable, Sendable {
    var version = NearbyKemoLimits.protocolVersion
    var id = UUID()
    let senderID: UUID
    let conversationID: UUID
    let kind: NearbyWireKind
    let createdAt: Date
    let expiresAt: Date
    let round: Int
    let nonce: Data?
    let keyAgreementPublicKey: Data?
    let sealedPayload: Data?

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(self)
    }
}

private struct NearbyProtectedPayload: Codable, Sendable { let text: String }

struct NearbyDecodedMessage: Equatable, Sendable {
    let wire: NearbyWireMessage
    let text: String
    var id: UUID { wire.id }
    var senderID: UUID { wire.senderID }
    var conversationID: UUID { wire.conversationID }
    var kind: NearbyWireKind { wire.kind }
    var round: Int { wire.round }
    var nonce: Data? { wire.nonce }
    var keyAgreementPublicKey: Data? { wire.keyAgreementPublicKey }
}

enum NearbyProtocolError: Error, Equatable {
    case oversized, malformed, expired, replay, untrustedPeer, wrongConversation, invalidRound, encryptionFailed, randomFailed
}

/// In-memory replay protection is deliberately bounded. A stopped discovery session
/// cannot be resumed silently, and pairing must be repeated after relaunch.
struct NearbyReplayWindow: Sendable {
    private(set) var expirations: [UUID: Date] = [:]

    mutating func accept(_ message: NearbyWireMessage, now: Date) throws {
        expirations = expirations.filter { $0.value > now }
        guard expirations[message.id] == nil else { throw NearbyProtocolError.replay }
        guard expirations.count < NearbyKemoLimits.replayWindowCapacity else { throw NearbyProtocolError.oversized }
        expirations[message.id] = message.expiresAt
    }
}

enum NearbyProtocol {
    static let verificationAlphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    static func decode(_ data: Data, expectedSender: UUID?, conversationID: UUID?,
                       trusted: Bool, sessionKey: SymmetricKey?, now: Date,
                       replay: inout NearbyReplayWindow) throws -> NearbyDecodedMessage {
        guard data.count <= NearbyKemoLimits.maximumWireBytes else { throw NearbyProtocolError.oversized }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let message = try? decoder.decode(NearbyWireMessage.self, from: data),
              message.version == NearbyKemoLimits.protocolVersion,
              message.expiresAt > message.createdAt,
              message.expiresAt.timeIntervalSince(message.createdAt) <= NearbyKemoLimits.messageLifetime else {
            throw NearbyProtocolError.malformed
        }
        guard message.createdAt <= now.addingTimeInterval(NearbyKemoLimits.futureClockTolerance), message.expiresAt > now else {
            throw NearbyProtocolError.expired
        }
        guard (0..<NearbyKemoLimits.maximumRounds).contains(message.round) else { throw NearbyProtocolError.invalidRound }
        if let expectedSender, message.senderID != expectedSender { throw NearbyProtocolError.untrustedPeer }
        if let conversationID, message.conversationID != conversationID { throw NearbyProtocolError.wrongConversation }
        if (message.kind == .turn || message.kind == .stop) && !trusted { throw NearbyProtocolError.untrustedPeer }
        let text: String
        if message.kind == .hello {
            guard message.nonce?.count == 32, message.keyAgreementPublicKey?.count == 32,
                  message.sealedPayload == nil, message.round == 0 else { throw NearbyProtocolError.malformed }
            text = ""
        } else {
            guard message.nonce == nil, message.keyAgreementPublicKey == nil,
                  let sealedPayload = message.sealedPayload, let sessionKey else { throw NearbyProtocolError.encryptionFailed }
            do {
                let box = try ChaChaPoly.SealedBox(combined: sealedPayload)
                let plaintext = try ChaChaPoly.open(box, using: sessionKey, authenticating: authenticatedHeader(message))
                text = try decoder.decode(NearbyProtectedPayload.self, from: plaintext).text
            } catch { throw NearbyProtocolError.encryptionFailed }
            guard text.count <= NearbyKemoLimits.maximumTextCharacters else { throw NearbyProtocolError.oversized }
            if message.kind != .turn && !text.isEmpty { throw NearbyProtocolError.malformed }
        }
        try replay.accept(message, now: now)
        return NearbyDecodedMessage(wire: message, text: text)
    }

    static func sealed(kind: NearbyWireKind, senderID: UUID, conversationID: UUID, round: Int,
                       text: String, sessionKey: SymmetricKey, now: Date, id: UUID = UUID()) throws -> Data {
        guard kind != .hello else { throw NearbyProtocolError.malformed }
        let createdAt = millisecondDate(now), expiresAt = millisecondDate(now.addingTimeInterval(NearbyKemoLimits.messageLifetime))
        var message = NearbyWireMessage(id: id, senderID: senderID, conversationID: conversationID, kind: kind,
                                        createdAt: createdAt, expiresAt: expiresAt, round: round,
                                        nonce: nil, keyAgreementPublicKey: nil, sealedPayload: Data())
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let plaintext = try encoder.encode(NearbyProtectedPayload(text: boundedText(text)))
        message = NearbyWireMessage(id: id, senderID: senderID, conversationID: conversationID, kind: kind,
                                    createdAt: createdAt, expiresAt: expiresAt, round: round,
                                    nonce: nil, keyAgreementPublicKey: nil,
                                    sealedPayload: try ChaChaPoly.seal(plaintext, using: sessionKey,
                                                                     authenticating: authenticatedHeader(message)).combined)
        let data = try message.encoded()
        guard data.count <= NearbyKemoLimits.maximumWireBytes else { throw NearbyProtocolError.oversized }
        return data
    }

    static func hello(senderID: UUID, conversationID: UUID, nonce: Data, publicKey: Data,
                      now: Date, id: UUID = UUID()) throws -> Data {
        guard nonce.count == 32, publicKey.count == 32 else { throw NearbyProtocolError.malformed }
        let message = NearbyWireMessage(id: id, senderID: senderID, conversationID: conversationID, kind: .hello,
                                        createdAt: millisecondDate(now),
                                        expiresAt: millisecondDate(now.addingTimeInterval(NearbyKemoLimits.messageLifetime)),
                                        round: 0, nonce: nonce, keyAgreementPublicKey: publicKey, sealedPayload: nil)
        return try message.encoded()
    }

    static func sessionKey(privateKey: Curve25519.KeyAgreement.PrivateKey, localID: UUID, localNonce: Data,
                           remoteID: UUID, remoteNonce: Data, remotePublicKey: Data,
                           conversationID: UUID) throws -> (SymmetricKey, Data) {
        guard localNonce.count == 32, remoteNonce.count == 32, localID != remoteID,
              privateKey.publicKey.rawRepresentation != remotePublicKey else { throw NearbyProtocolError.malformed }
        let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remotePublicKey)
        let transcript = handshakeTranscript(localID: localID, localNonce: localNonce,
                                             localPublicKey: privateKey.publicKey.rawRepresentation,
                                             remoteID: remoteID, remoteNonce: remoteNonce,
                                             remotePublicKey: remotePublicKey, conversationID: conversationID)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        let key = secret.hkdfDerivedSymmetricKey(using: SHA256.self,
                                                 salt: Data(SHA256.hash(data: transcript)),
                                                 sharedInfo: Data("KemoSabe Nearby E2EE v2".utf8), outputByteCount: 32)
        return (key, transcript)
    }

    /// Ten base32 symbols compare 50 bits derived from the ECDH secret and the
    /// canonical handshake transcript. A key-substitution proxy gets a different code.
    static func verificationCode(sessionKey: SymmetricKey, handshakeTranscript: Data) -> String {
        let tag = HMAC<SHA256>.authenticationCode(for: Data("KemoSabe Nearby SAS v2".utf8) + handshakeTranscript,
                                                  using: sessionKey)
        var accumulator: UInt64 = 0
        for byte in tag.prefix(7) { accumulator = (accumulator << 8) | UInt64(byte) }
        let value = accumulator >> 6
        let symbols = (0..<10).reversed().map { verificationAlphabet[Int((value >> UInt64($0 * 5)) & 31)] }
        return String(symbols.prefix(5)) + " " + String(symbols.suffix(5))
    }

    static func boundedText(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(NearbyKemoLimits.maximumTextCharacters))
    }

    static func boundedUTF8(_ text: String, maximumBytes: Int) -> String {
        guard maximumBytes > 0 else { return "" }
        var result = "", byteCount = 0
        for character in text {
            let bytes = String(character).utf8.count
            guard byteCount + bytes <= maximumBytes else { break }
            result.append(character); byteCount += bytes
        }
        return result
    }

    static func acceptsPublicBrief(_ text: String, isDiscovering: Bool) -> Bool {
        !isDiscovering && text.utf8.count <= NearbyKemoLimits.maximumSharedContextBytes
    }

    static func validateTurnSequence(round: Int, existingTurnCount: Int, generating: Bool) throws {
        guard !generating, existingTurnCount < NearbyKemoLimits.maximumRounds,
              round == existingTurnCount else { throw NearbyProtocolError.invalidRound }
    }

    static func validateInitialHello(existingSenderID: UUID?, remoteNonce: Data?, remotePublicKey: Data?) throws {
        guard existingSenderID == nil, remoteNonce == nil, remotePublicKey == nil else { throw NearbyProtocolError.replay }
    }

    private static func millisecondDate(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1_000).rounded(.down) / 1_000)
    }

    private static func authenticatedHeader(_ message: NearbyWireMessage) -> Data {
        let values = [String(message.version), message.id.uuidString, message.senderID.uuidString,
                      message.conversationID.uuidString, message.kind.rawValue,
                      String(Int64((message.createdAt.timeIntervalSince1970 * 1_000).rounded())),
                      String(Int64((message.expiresAt.timeIntervalSince1970 * 1_000).rounded())), String(message.round)]
        return Data(values.joined(separator: "|").utf8)
    }

    private static func handshakeTranscript(localID: UUID, localNonce: Data, localPublicKey: Data,
                                            remoteID: UUID, remoteNonce: Data, remotePublicKey: Data,
                                            conversationID: UUID) -> Data {
        let local = (localID, localNonce, localPublicKey), remote = (remoteID, remoteNonce, remotePublicKey)
        let pair = localID.uuidString < remoteID.uuidString ? [local, remote] : [remote, local]
        var data = Data("KemoSabe Nearby handshake v2|\(conversationID.uuidString)|".utf8)
        for item in pair {
            data.append(Data(item.0.uuidString.utf8)); data.append(0)
            data.append(item.1); data.append(item.2)
        }
        return data
    }
}

struct NearbyPeer: Identifiable, Equatable {
    enum Trust: String { case discovered, invitation, connecting, compareCode, verified }
    let id: String
    var name: String
    var trust: Trust
    var verificationCode: String?
}

struct NearbyTranscriptEntry: Identifiable, Equatable {
    enum Speaker: Equatable { case thisKemo, nearbyKemo, system }
    let id: UUID
    let speaker: Speaker
    let text: String
}

/// One finished conversation between your Kemo and a nearby one, kept for this session only.
struct NearbyMeeting: Identifiable, Equatable {
    let id = UUID()
    let peerName: String
    let transcript: [NearbyTranscriptEntry]
    let date: Date
}

/// Foreground-only Multipeer Connectivity coordinator. It neither declares nor
/// schedules background execution and tears down discovery when the app resigns active.
@MainActor
@Observable
final class NearbyKemos: NSObject {
    private struct Connection {
        let generation: UUID
        var peer: MCPeerID
        var senderID: UUID?
        var conversationID: UUID
        var localNonce: Data
        var remoteNonce: Data?
        var localPrivateKey: Curve25519.KeyAgreement.PrivateKey
        var remotePublicKey: Data?
        var sessionKey: SymmetricKey?
        var handshakeTranscript: Data?
        var localVerified = false
        var remoteVerified = false
        var replay = NearbyReplayWindow()
        /// This side sent the invitation, so it opens the conversation.
        var initiated = false
    }

    private let localID: UUID
    private let localPeer: MCPeerID
    private let responseGenerator: NearbyResponseGenerator
    private let disclosure: NearbyDisclosure
    @ObservationIgnored private var session: MCSession?
    @ObservationIgnored private var generation: UUID?
    @ObservationIgnored private var browser: MCNearbyServiceBrowser?
    @ObservationIgnored private var advertiser: MCNearbyServiceAdvertiser?
    @ObservationIgnored private var discovered: [String: MCPeerID] = [:]
    @ObservationIgnored private var invitations: [String: (Bool, MCSession?) -> Void] = [:]
    @ObservationIgnored private var connection: Connection?
    @ObservationIgnored private var responseTask: Task<Void, Never>?
    @ObservationIgnored private var responseTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var outgoingDisclosureTask: Task<Void, Never>?
    @ObservationIgnored private var activeResponseID: UUID?

    private(set) var peers: [NearbyPeer] = []
    private(set) var transcript: [NearbyTranscriptEntry] = []
    private(set) var isDiscovering = false
    private(set) var isGenerating = false
    private(set) var status = "Off"
    private(set) var exchangeStopped = false
    private(set) var publicBrief = ""
    /// Ambient mode: while you're open to nearby Kemos, yours meets each other open Kemo in turn,
    /// talks within the round limit, and moves on, with no taps. Both people have opted in by
    /// being open; the pairing code isn't compared, so trust is on first use for this session.
    var automatic = false
    /// How your Kemo opens a conversation it started.
    var openingLine = "Hi! I'm a KemoSabe. What brings you here?"
    /// Conversations finished this session, newest first. Not saved.
    private(set) var met: [NearbyMeeting] = []
    @ObservationIgnored private var metPeers: Set<String> = []

    init(displayName: String = "KemoSabe", responseGenerator: @escaping NearbyResponseGenerator) {
        let identity = UUID()
        self.localID = identity
        let baseName = String(displayName.prefix(30))
        let peer = MCPeerID(displayName: "\(baseName) • \(identity.uuidString.prefix(4))")
        self.localPeer = peer
        self.disclosure = NearbyDisclosure(ownerID: identity)
        self.session = nil
        self.responseGenerator = responseGenerator
        super.init()
    }

    /// This explicit opt-in is the only entry point that starts local-network activity.
    func startDiscovery() {
        guard !isDiscovering else { return }
        let generation = UUID()
        let session = MCSession(peer: localPeer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        self.generation = generation; self.session = session
        transcript.removeAll(); isDiscovering = true; exchangeStopped = false; status = "Looking nearby…"
        let browser = MCNearbyServiceBrowser(peer: localPeer, serviceType: NearbyKemoLimits.serviceType)
        let advertiser = MCNearbyServiceAdvertiser(peer: localPeer, discoveryInfo: ["v": "2"], serviceType: NearbyKemoLimits.serviceType)
        browser.delegate = self; advertiser.delegate = self
        self.browser = browser; self.advertiser = advertiser
        browser.startBrowsingForPeers(); advertiser.startAdvertisingPeer()
    }

    @discardableResult
    func updatePublicBrief(_ value: String) -> Bool {
        guard NearbyProtocol.acceptsPublicBrief(value, isDiscovering: isDiscovering) else { return false }
        publicBrief = value
        return true
    }

    func stopDiscovery() {
        cancelResponse(); isGenerating = false
        browser?.stopBrowsingForPeers(); advertiser?.stopAdvertisingPeer()
        browser = nil; advertiser = nil
        invitations.values.forEach { $0(false, nil) }; invitations.removeAll()
        session?.disconnect(); session = nil; generation = nil; connection = nil; discovered.removeAll(); peers.removeAll()
        transcript.removeAll(); isDiscovering = false; exchangeStopped = true; status = "Off"
        metPeers.removeAll()
    }

    /// RootView should call this from scenePhase. Backgrounding is always a hard stop.
    func setForegroundActive(_ active: Bool) {
        if !active { stopDiscovery() }
    }

    func invite(_ peerID: String) {
        guard isDiscovering, connection == nil, let peer = discovered[peerID], let session else { return }
        guard let newConnection = try? makeConnection(peer: peer) else { status = "Secure pairing isn’t available."; return }
        transcript.removeAll(); exchangeStopped = false
        var started = newConnection; started.initiated = true
        connection = started
        updatePeer(peer, trust: .connecting)
        browser?.invitePeer(peer, to: session, withContext: nil, timeout: 30)
        status = "Waiting for \(peer.displayName)…"
    }

    func answerInvitation(from peerID: String, accept: Bool) {
        guard let handler = invitations.removeValue(forKey: peerID), let peer = discovered[peerID], let session else { return }
        if accept {
            guard let newConnection = try? makeConnection(peer: peer) else { status = "Secure pairing isn’t available."; handler(false, nil); return }
            transcript.removeAll(); exchangeStopped = false
            connection = newConnection
            updatePeer(peer, trust: .connecting); status = "Connecting securely…"; handler(true, session)
        } else {
            peers.removeAll { $0.id == peerID }; handler(false, nil)
        }
    }

    func confirmVerificationCode() {
        guard var connection, connection.sessionKey != nil, connection.handshakeTranscript != nil else { return }
        connection.localVerified = true; self.connection = connection
        send(kind: .verification, round: 0, text: "", nonce: nil)
        updateTrustIfReady()
    }

    func beginExchange(opening: String) {
        guard isVerified, !isGenerating else { status = "Verify this secure assistant first."; return }
        guard transcript.isEmpty else { status = "Reconnect to begin another exchange."; return }
        let text = NearbyProtocol.boundedText(opening)
        guard !text.isEmpty else { return }
        let entry = NearbyTranscriptEntry(id: UUID(), speaker: .thisKemo, text: text)
        exchangeStopped = false; transcript = [entry]
        status = "Approving what will be shared…"
        outgoingDisclosureTask = Task { [weak self] in
            guard let self else { return }
            let sent = await self.authorizeAndSendTurn(round: 0, outgoingTurnID: entry.id)
            self.outgoingDisclosureTask = nil
            if sent { self.status = "Talking · 1 of \(NearbyKemoLimits.maximumRounds)" }
        }
    }

    func stopExchange() {
        cancelResponse(); isGenerating = false; exchangeStopped = true
        if isVerified { send(kind: .stop, round: 0, text: "", nonce: nil) }
        status = "Exchange stopped"
    }

    var connectedPeer: NearbyPeer? {
        guard let peer = connection?.peer else { return nil }
        return peers.first { $0.id == peer.displayName }
    }

    var isVerified: Bool { connection?.localVerified == true && connection?.remoteVerified == true }
    var hasConfirmedCode: Bool { connection?.localVerified == true }

    private static func randomNonce() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw NearbyProtocolError.randomFailed
        }
        return Data(bytes)
    }

    private func makeConnection(peer: MCPeerID) throws -> Connection {
        guard let generation else { throw NearbyProtocolError.malformed }
        return Connection(generation: generation, peer: peer, conversationID: UUID(),
                          localNonce: try Self.randomNonce(), localPrivateKey: .init())
    }

    private func send(kind: NearbyWireKind, round: Int, text: String, nonce: Data?) {
        guard kind != .hello, kind != .turn, let connection, let session, let sessionKey = connection.sessionKey,
              session.connectedPeers.contains(connection.peer) else { return }
        let now = Date()
        guard nonce == nil,
              let data = try? NearbyProtocol.sealed(kind: kind, senderID: localID,
                                                    conversationID: connection.conversationID, round: round,
                                                    text: text, sessionKey: sessionKey, now: now) else { return }
        do { try session.send(data, toPeers: [connection.peer], with: .reliable) }
        catch { status = "Couldn’t send securely." }
    }

    /// The successful ContextBroker validation is the last asynchronous step.
    /// Only synchronous state checks, sealing, and MCSession.send follow it.
    private func authorizeAndSendTurn(round: Int, outgoingTurnID: UUID) async -> Bool {
        guard isVerified, !exchangeStopped, let connection, let recipientID = connection.senderID,
              let session, let sessionKey = connection.sessionKey,
              session.connectedPeers.contains(connection.peer) else { return false }
        let connectionGeneration = connection.generation
        let conversationID = connection.conversationID
        let peer = connection.peer
        let brief = publicBrief
        let visible = modelTranscript()

        do {
            let pending = try await disclosure.makeEnvelope(
                publicBrief: brief,
                visibleTranscript: visible,
                outgoingTurnID: outgoingTurnID,
                recipientPeerID: recipientID,
                conversationID: conversationID
            )
            try Task.checkCancellation()
            let approvedText = try await disclosure.validateForSend(
                pending, recipientPeerID: recipientID, conversationID: conversationID
            )
            try Task.checkCancellation()
            let sendNow = Date()
            guard pending.expiresAt > sendNow else { throw ContextBrokerError.expired }
            guard isVerified, !exchangeStopped,
                  self.connection?.generation == connectionGeneration,
                  self.connection?.senderID == recipientID,
                  self.connection?.conversationID == conversationID,
                  self.connection?.peer == peer,
                  self.session === session,
                  publicBrief == brief,
                  modelTranscript() == visible,
                  session.connectedPeers.contains(peer),
                  let data = try? NearbyProtocol.sealed(
                    kind: .turn, senderID: localID, conversationID: conversationID,
                    round: round, text: approvedText, sessionKey: sessionKey, now: sendNow
                  ) else { return false }
            try session.send(data, toPeers: [peer], with: .reliable)
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard self.connection?.generation == connectionGeneration else { return false }
            exchangeStopped = true
            if isVerified { send(kind: .stop, round: 0, text: "", nonce: nil) }
            status = "Sharing approval failed. Exchange stopped."
            return false
        }
    }

    private func modelTranscript() -> [NearbyModelRequest.Turn] {
        transcript.compactMap { entry in
            guard entry.speaker != .system else { return nil }
            return .init(id: entry.id,
                         speaker: entry.speaker == .thisKemo ? .thisKemo : .nearbyKemo,
                         text: entry.text)
        }
    }

    private func sendHello() {
        guard let connection, let session, session.connectedPeers.contains(connection.peer),
              let data = try? NearbyProtocol.hello(senderID: localID, conversationID: connection.conversationID,
                                                   nonce: connection.localNonce,
                                                   publicKey: connection.localPrivateKey.publicKey.rawRepresentation,
                                                   now: Date()) else { return }
        do { try session.send(data, toPeers: [connection.peer], with: .reliable) }
        catch { status = "Couldn’t prepare secure pairing." }
    }

    private func receive(_ data: Data, from peer: MCPeerID) {
        guard var connection, connection.peer == peer else { return }
        do {
            let allowsUnpaired = connection.senderID == nil
            let decoded = try NearbyProtocol.decode(data, expectedSender: connection.senderID,
                                                    conversationID: allowsUnpaired ? nil : connection.conversationID,
                                                    trusted: isVerified, sessionKey: connection.sessionKey,
                                                    now: Date(), replay: &connection.replay)
            if allowsUnpaired {
                guard decoded.kind == .hello else { throw NearbyProtocolError.untrustedPeer }
                try NearbyProtocol.validateInitialHello(existingSenderID: connection.senderID,
                                                        remoteNonce: connection.remoteNonce,
                                                        remotePublicKey: connection.remotePublicKey)
                connection.senderID = decoded.senderID
                // The inviter's conversation identifier wins deterministically.
                if localID.uuidString > decoded.senderID.uuidString { connection.conversationID = decoded.conversationID }
            }
            self.connection = connection
            switch decoded.kind {
            case .hello:
                try NearbyProtocol.validateInitialHello(existingSenderID: allowsUnpaired ? nil : connection.senderID,
                                                        remoteNonce: connection.remoteNonce,
                                                        remotePublicKey: connection.remotePublicKey)
                guard let remoteNonce = decoded.nonce, let remotePublicKey = decoded.keyAgreementPublicKey else {
                    throw NearbyProtocolError.malformed
                }
                connection.remoteNonce = remoteNonce; connection.remotePublicKey = remotePublicKey
                let keyMaterial = try NearbyProtocol.sessionKey(privateKey: connection.localPrivateKey,
                                                                localID: localID, localNonce: connection.localNonce,
                                                                remoteID: decoded.senderID, remoteNonce: remoteNonce,
                                                                remotePublicKey: remotePublicKey,
                                                                conversationID: connection.conversationID)
                connection.sessionKey = keyMaterial.0; connection.handshakeTranscript = keyMaterial.1
                self.connection = connection
                let code = NearbyProtocol.verificationCode(sessionKey: keyMaterial.0, handshakeTranscript: keyMaterial.1)
                updatePeer(peer, trust: .compareCode, code: code)
                status = "Compare this code on both devices."
                if automatic { confirmVerificationCode() }
            case .verification:
                connection.remoteVerified = true; self.connection = connection; updateTrustIfReady()
            case .turn:
                guard isVerified else { throw NearbyProtocolError.untrustedPeer }
                receiveTurn(decoded, peerName: peer.displayName)
            case .stop:
                cancelResponse(); isGenerating = false; exchangeStopped = true
                transcript.append(.init(id: UUID(), speaker: .system, text: "The other secure assistant stopped the exchange."))
                status = "Exchange stopped"
                concludeIfAutomatic()
            }
        } catch {
            status = "Blocked an invalid nearby message."
        }
    }

    private func receiveTurn(_ message: NearbyDecodedMessage, peerName: String) {
        guard !exchangeStopped else { return }
        let turnCount = transcript.reduce(into: 0) { count, entry in if entry.speaker != .system { count += 1 } }
        do { try NearbyProtocol.validateTurnSequence(round: message.round, existingTurnCount: turnCount, generating: isGenerating) }
        catch {
            status = "Blocked an out-of-order nearby turn."; return
        }
        transcript.append(.init(id: message.id, speaker: .nearbyKemo, text: message.text))
        let nextRound = message.round + 1
        guard nextRound < NearbyKemoLimits.maximumRounds else {
            exchangeStopped = true; status = "Exchange complete · \(NearbyKemoLimits.maximumRounds) turns"
            concludeIfAutomatic(); return
        }
        cancelResponse(); isGenerating = true; status = "\(CompanionIdentity.name) is thinking…"
        let explicitContext = publicBrief.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = NearbyModelRequest(
            conversationID: message.conversationID,
            peerName: peerName,
            transcript: modelTranscript(),
            sharedContext: explicitContext.isEmpty ? nil : NearbyProtocol.boundedUTF8(
                explicitContext, maximumBytes: NearbyKemoLimits.maximumSharedContextBytes
            )
        )
        let responseID = UUID(); activeResponseID = responseID
        responseTimeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: NearbyKemoLimits.maximumModelDuration) }
            catch { return }
            self?.modelTimedOut(responseID: responseID)
        }
        responseTask = Task { [weak self, responseGenerator] in
            do {
                let answer = NearbyProtocol.boundedText(try await responseGenerator(request))
                try Task.checkCancellation()
                guard let self, self.activeResponseID == responseID, self.isVerified, !self.exchangeStopped else { return }
                guard !answer.isEmpty else { self.modelFailed(responseID: responseID); return }
                self.isGenerating = false
                let entry = NearbyTranscriptEntry(id: UUID(), speaker: .thisKemo, text: answer)
                self.transcript.append(entry)
                let sent = await self.authorizeAndSendTurn(round: nextRound, outgoingTurnID: entry.id)
                self.responseTimeoutTask?.cancel(); self.responseTimeoutTask = nil
                self.responseTask = nil; self.activeResponseID = nil
                guard sent else { return }
                if nextRound == NearbyKemoLimits.maximumRounds - 1 {
                    self.exchangeStopped = true
                    self.status = "Exchange complete · \(NearbyKemoLimits.maximumRounds) turns"
                    self.concludeIfAutomatic()
                } else {
                    self.status = "Talking · \(nextRound + 1) of \(NearbyKemoLimits.maximumRounds)"
                }
            } catch is CancellationError {
                guard self?.activeResponseID == responseID else { return }
                self?.cancelResponse(); self?.isGenerating = false
            } catch {
                self?.modelFailed(responseID: responseID)
            }
        }
    }

    private func cancelResponse() {
        responseTask?.cancel(); responseTask = nil
        responseTimeoutTask?.cancel(); responseTimeoutTask = nil
        outgoingDisclosureTask?.cancel(); outgoingDisclosureTask = nil
        activeResponseID = nil
    }

    private func modelTimedOut(responseID: UUID) {
        guard activeResponseID == responseID else { return }
        cancelResponse(); isGenerating = false; exchangeStopped = true
        if isVerified { send(kind: .stop, round: 0, text: "", nonce: nil) }
        status = "\(CompanionIdentity.name) took too long. Exchange stopped."
        concludeIfAutomatic()
    }

    private func modelFailed(responseID: UUID) {
        guard activeResponseID == responseID else { return }
        cancelResponse(); isGenerating = false; exchangeStopped = true
        if isVerified { send(kind: .stop, round: 0, text: "", nonce: nil) }
        status = "\(CompanionIdentity.name) couldn’t answer."
        concludeIfAutomatic()
    }

    // MARK: Ambient mode

    /// Invites a newly found Kemo when this side should: only the one whose name sorts first
    /// invites, so two open Kemos don't invite each other at once.
    private func autoInvite(_ peer: MCPeerID) {
        guard automatic, isDiscovering, connection == nil, invitations.isEmpty, !metPeers.contains(peer.displayName),
              localPeer.displayName < peer.displayName else { return }
        invite(peer.displayName)
    }
    /// Invites the next Kemo around that yours hasn't met yet.
    private func meetNext() {
        guard automatic, isDiscovering, connection == nil else { return }
        if let next = discovered.values.sorted(by: { $0.displayName < $1.displayName }).first(where: { !metPeers.contains($0.displayName) }) {
            autoInvite(next)
        }
    }
    /// Saves the finished conversation, lets the last message arrive, then disconnects and meets the next Kemo.
    private func concludeIfAutomatic() {
        guard automatic, let connection else { return }
        let peer = connection.peer
        guard !metPeers.contains(peer.displayName) else { return }
        metPeers.insert(peer.displayName)
        if transcript.contains(where: { $0.speaker != .system }) {
            met.insert(.init(peerName: Self.displayName(peer.displayName), transcript: transcript, date: Date()), at: 0)
        }
        let generation = connection.generation
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.connection?.generation == generation, self.connection?.peer == peer else { return }
            self.session?.cancelConnectPeer(peer)
            self.connection = nil; self.transcript.removeAll()
            self.status = "Looking nearby…"
            self.meetNext()
        }
    }
    /// A peer's name without the random suffix that keeps names unique.
    static func displayName(_ peerName: String) -> String {
        peerName.components(separatedBy: " • ").first ?? peerName
    }

    private func updateTrustIfReady() {
        guard let connection else { return }
        if connection.localVerified && connection.remoteVerified {
            updatePeer(connection.peer, trust: .verified); status = "Verified · ready for a short exchange"
            // In ambient mode the Kemo that invited opens; the other answers.
            if automatic, connection.initiated, transcript.isEmpty {
                status = "Talking with \(Self.displayName(connection.peer.displayName))…"
                beginExchange(opening: openingLine)
            } else if automatic { status = "Talking with \(Self.displayName(connection.peer.displayName))…" }
        } else { status = "Waiting for both people to confirm…" }
    }

    private func updatePeer(_ peer: MCPeerID, trust: NearbyPeer.Trust, code: String? = nil) {
        let id = peer.displayName
        if let index = peers.firstIndex(where: { $0.id == id }) {
            peers[index].trust = trust
            if let code { peers[index].verificationCode = code }
        } else { peers.append(.init(id: id, name: peer.displayName, trust: trust, verificationCode: code)) }
    }
}

extension NearbyKemos: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        guard info?["v"] == "2" else { return }
        Task { @MainActor in
            guard browser === self.browser, self.isDiscovering, self.connection == nil else { return }
            guard self.discovered[peerID.displayName] != nil || self.discovered.count < NearbyKemoLimits.maximumDiscoveredPeers else { return }
            self.discovered[peerID.displayName] = peerID
            self.updatePeer(peerID, trust: .discovered)
            self.autoInvite(peerID)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            guard browser === self.browser else { return }
            self.discovered.removeValue(forKey: peerID.displayName)
            if self.connection?.peer != peerID { self.peers.removeAll { $0.id == peerID.displayName } }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in
            guard browser === self.browser else { return }
            self.stopDiscovery(); self.status = "Nearby discovery couldn’t start."
        }
    }
}

extension NearbyKemos: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in
            guard advertiser === self.advertiser, self.isDiscovering, self.connection == nil,
                  self.invitations.isEmpty,
                  self.discovered[peerID.displayName] != nil || self.discovered.count < NearbyKemoLimits.maximumDiscoveredPeers
            else { invitationHandler(false, nil); return }
            self.discovered[peerID.displayName] = peerID
            self.invitations[peerID.displayName] = invitationHandler
            self.updatePeer(peerID, trust: .invitation); self.status = "Invitation from \(peerID.displayName)"
            // Another open Kemo; being open is the consent. One conversation per Kemo per session.
            if self.automatic {
                self.answerInvitation(from: peerID.displayName, accept: !self.metPeers.contains(peerID.displayName))
            }
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor in
            guard advertiser === self.advertiser else { return }
            self.stopDiscovery(); self.status = "Nearby discovery couldn’t start."
        }
    }
}

extension NearbyKemos: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            guard session === self.session, self.connection?.generation == self.generation else { return }
            switch state {
            case .connected:
                guard self.connection?.peer == peerID else { session.cancelConnectPeer(peerID); return }
                self.status = "Connected securely · preparing verification"; self.sendHello()
            case .connecting: self.status = "Connecting securely…"
            case .notConnected:
                guard self.connection?.peer == peerID else { return }
                self.cancelResponse(); self.isGenerating = false
                self.connection = nil; self.exchangeStopped = true
                self.updatePeer(peerID, trust: .discovered); self.status = self.isDiscovering ? "Disconnected · choose someone nearby" : "Off"
                if self.automatic {
                    self.metPeers.insert(peerID.displayName)
                    if self.isDiscovering { self.status = "Looking nearby…" }
                    self.meetNext()
                }
            @unknown default: self.stopDiscovery()
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard data.count <= NearbyKemoLimits.maximumWireBytes else { return }
        Task { @MainActor in
            guard session === self.session, self.connection?.generation == self.generation else { return }
            self.receive(data, from: peerID)
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) { }
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        progress.cancel()
    }
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) { }
}

#if DEBUG
/// The `--nearby-fixture` exchange (`NearbyKemosFixture`, in NearbyKemosView.swift).
extension NearbyKemos {
    /// The fixture's exchange, shown as if it were live.
    func showFixture(turns: [(NearbyTranscriptEntry.Speaker, String)], peer: String, status: String) {
        isDiscovering = true; exchangeStopped = false; isGenerating = false
        peers = [NearbyPeer(id: peer, name: peer, trust: .verified)]
        transcript = turns.map { NearbyTranscriptEntry(id: UUID(), speaker: $0.0, text: $0.1) }
        self.status = status
    }
}
#endif

import Foundation
import CryptoKit

/// Transport-neutral Kemo-to-Kemo contract. A relay cannot confer authority.
struct AgentMessage: Codable, Equatable {
    enum Kind: String, Codable { case availabilityRequest, availabilityReply, proposal, decline }
    var version = 1
    var id = UUID()
    let sender: UUID
    let recipient: UUID
    let conversation: UUID
    let kind: Kind
    let createdAt: Date
    let expiresAt: Date
    let text: String // Reference data only; never executable tool instructions.
    func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(self)
    }
}
struct SignedAgentMessage: Codable {
    let payload: Data
    let signature: Data
    static func sign(_ message: AgentMessage, key: Curve25519.Signing.PrivateKey) throws -> Self {
        let payload = try message.encoded()
        return try .init(payload: payload, signature: key.signature(for: payload))
    }
}
struct PeerPermission: Codable {
    let agentID: UUID
    let publicKey: Data
    let allowedKinds: [AgentMessage.Kind]
    let expiresAt: Date
}
enum AgentExchangeError: Error { case invalid, unauthorized, replay, full }
enum AgentExchangeVerifier {
    static func verify(_ envelope: SignedAgentMessage, recipient: UUID,
                       permission: PeerPermission, now: Date) throws -> AgentMessage {
        guard envelope.payload.count <= 16_384,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: permission.publicKey),
              key.isValidSignature(envelope.signature, for: envelope.payload) else { throw AgentExchangeError.invalid }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let message = try decoder.decode(AgentMessage.self, from: envelope.payload)
        guard message.version == 1, message.recipient == recipient, message.sender == permission.agentID,
              message.expiresAt > now, message.createdAt <= now.addingTimeInterval(300),
              message.expiresAt > message.createdAt, message.expiresAt.timeIntervalSince(message.createdAt) <= 86400,
              message.text.count <= 4000 else { throw AgentExchangeError.invalid }
        guard permission.expiresAt > now, permission.allowedKinds.contains(message.kind) else { throw AgentExchangeError.unauthorized }
        return message
    }
}

/// Durable replay protection. No silent eviction while a message could be valid.
actor PeerInbox {
    private let url: URL
    init(url: URL) { self.url = url }
    func receive(_ envelope: SignedAgentMessage, recipient: UUID, permission: PeerPermission, now: Date) throws -> AgentMessage {
        let message = try AgentExchangeVerifier.verify(envelope, recipient: recipient, permission: permission, now: now)
        var receipts: [String: Date] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            receipts = try JSONDecoder().decode([String: Date].self, from: Data(contentsOf: url))
        }
        receipts = receipts.filter { $0.value > now }
        let key = message.sender.uuidString + ":" + message.id.uuidString
        guard receipts[key] == nil else { throw AgentExchangeError.replay }
        guard receipts.count < 1024 else { throw AgentExchangeError.full }
        receipts[key] = message.expiresAt
        var folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true; try folder.setResourceValues(values)
        try JSONEncoder().encode(receipts).write(to: url, options: [.atomic, .completeFileProtection])
        return message // Caller may present it for review; receiving does not execute it.
    }
}

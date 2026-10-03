import Foundation
import TsukumoCore
import TsukumoPolicy

/// A single-use authorization to hand one answer to one recipient. It holds no plaintext, and its
/// description names only the exchange, the recipient, and when it expires.
public struct DisclosureEnvelope: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    fileprivate let token: UUID
    public let exchange: GateExchangeID
    public let recipient: RecipientID
    public let expiresAt: Date
    public var description: String { "DisclosureEnvelope(exchange: \(exchange), to: \(recipient.key), expires: \(expiresAt))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["exchange": exchange, "recipient": recipient.key, "expiresAt": expiresAt]) }
}

/// Seals answers into single-use envelopes and opens each exactly once, for exactly its recipient,
/// before it expires. Opening by anyone else, or a second time, fails, and the answer is gone
/// either way.
public actor DisclosureDesk {
    public static let lifetime: TimeInterval = 60
    private var sealed: [UUID: (text: String, envelope: DisclosureEnvelope)] = [:]
    private let clock: @Sendable () -> Date

    public init(clock: @escaping @Sendable () -> Date = { Date() }) { self.clock = clock }

    /// Seals `text` for `recipient`, after checking the policy allows an item at `label` to reach
    /// it under `grants` for this exchange.
    public func seal(_ text: String, label: TypeLabel, for recipient: RecipientID, exchange: GateExchangeID,
                     grants: [RecipientGrant]) throws -> DisclosureEnvelope {
        let item = PolicyItem(id: "answer:" + exchange.description, label: label)
        let decision = ContextPolicy.evaluate([item], to: recipient, purpose: .agentQuestion, grants: grants, now: clock())
        if let denial = decision.denied[item] { throw denial }
        let envelope = DisclosureEnvelope(token: UUID(), exchange: exchange, recipient: recipient, expiresAt: clock().addingTimeInterval(Self.lifetime))
        sealed[envelope.token] = (text, envelope)
        return envelope
    }

    /// The answer, once. Whatever happens, the envelope can't be opened again.
    public func open(_ envelope: DisclosureEnvelope, as recipient: RecipientID) throws -> String {
        guard let entry = sealed.removeValue(forKey: envelope.token) else { throw GateError.envelopeSpent }
        guard entry.envelope.recipient == recipient else { throw GateError.wrongRecipient }
        guard entry.envelope.expiresAt > clock() else { throw GateError.expired }
        return entry.text
    }

    /// Envelopes sealed and not yet opened (expired ones are dropped).
    public func pendingCount() -> Int {
        let now = clock()
        sealed = sealed.filter { $0.value.envelope.expiresAt > now }
        return sealed.count
    }
}

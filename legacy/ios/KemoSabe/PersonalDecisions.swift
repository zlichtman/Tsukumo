import Foundation

/// A decision is advice, never an execution or disclosure capability.
struct DecisionQuestion: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case choice, probability, score }
    let id: String
    let kind: Kind
    let instruction: String
    let options: [String]
}
struct DecisionRequest: Sendable {
    let state: String
    let questions: [DecisionQuestion]
    let deadline: Date
    func validate(now: Date = Date()) throws {
        guard deadline > now, !state.isEmpty, state.utf8.count <= 8192,
              (1...4).contains(questions.count), Set(questions.map(\.id)).count == questions.count,
              questions.allSatisfy({ !$0.id.isEmpty && $0.id.count <= 80 && !$0.instruction.isEmpty && $0.instruction.count <= 400 &&
                  (2...12).contains($0.options.count) && Set($0.options).count == $0.options.count &&
                  $0.options.allSatisfy { !$0.isEmpty && $0.count <= 100 } }) else { throw DecisionError.invalidInput }
    }
}
struct DecisionAnswer: Codable, Equatable, Sendable {
    let questionID: String
    let probabilities: [Double]
    var selectedIndex: Int? { probabilities.indices.max { probabilities[$0] < probabilities[$1] } }
    var confidence: Double { probabilities.max() ?? 0 }
}
struct DecisionResult: Sendable {
    let modelVersion: String
    let answers: [DecisionAnswer]
    let calibrated: Bool
    let abstention: String?
    func validate(for request: DecisionRequest) throws {
        guard !modelVersion.isEmpty else { throw DecisionError.invalidOutput }
        if abstention != nil { guard answers.isEmpty else { throw DecisionError.invalidOutput }; return }
        guard answers.count == request.questions.count else { throw DecisionError.invalidOutput }
        for (answer, question) in zip(answers, request.questions) {
            guard answer.questionID == question.id, answer.probabilities.count == question.options.count,
                  answer.probabilities.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                  abs(answer.probabilities.reduce(0,+) - 1) < 0.001 else { throw DecisionError.invalidOutput }
        }
    }
}
enum DecisionError: Error { case unavailable, invalidInput, invalidOutput, contextLimit, incompatibleBundle }
protocol DecisionProvider: Sendable {
    var modelVersion: String { get }
    func decide(_ request: DecisionRequest) async throws -> DecisionResult
}
struct UnavailableDecisionProvider: DecisionProvider {
    let modelVersion = "Laya unavailable"
    func decide(_ request: DecisionRequest) async throws -> DecisionResult { throw DecisionError.unavailable }
}

/// Local decisions only. The one hosted provider, Jev, is reached through `SystemOne.decide`,
/// which checks `ContextPolicy` for the chat's level before the packet leaves; its answer is
/// advice among options the caller already permits, never a disclosure or action grant.
struct PrivateDecisionPacket: Sendable {
    let request: DecisionRequest
    let envelope: DisclosureEnvelope
    let recipient: RecipientID
    let purpose: ContextPurpose
}
actor PrivateDecisionGateway {
    private let broker: ContextBroker
    init(broker: ContextBroker) { self.broker = broker }
    /// Only current, directly supplied local request data enters this helper.
    /// Saved memory must use its existing revision-bearing broker envelope.
    static func decideDirect(_ request: DecisionRequest, using provider: any DecisionProvider) async throws -> DecisionResult {
        try request.validate(); try Task.checkCancellation()
        let broker = ContextBroker(), owner = UUID()
        let recipient = RecipientID.appleOnDevice  // Laya runs on this device through Core ML.
        let purpose: ContextPurpose = "local-decision"
        let record = try await broker.put(.init(ownerID: owner,
            source: .init(kind: .directUser, identifier: owner.uuidString, observedAt: Date()),
            compartment: .conversation, declaredSensitivity: .personal,
            restrictions: .init(localOnly: true), fields: [.text: request.state]), expectedRevision: nil)
        let grant = try await broker.mintGrant(.init(ownerID: owner, purpose: purpose, recipient: recipient,
            fields: [.text], recordRevisions: [record.id: record.revision], expiresAt: request.deadline), authority: .hostPolicy)
        let envelope = try await broker.makeEnvelope(recordIDs: [record.id], using: grant, fields: [.text])
        let permitted = try await broker.validateForSend(envelope, recipient: recipient, purpose: purpose)
        guard let state = permitted.records.first?.fields[.text] else { throw DecisionError.unavailable }
        let result = try await provider.decide(.init(state: state, questions: request.questions, deadline: request.deadline))
        // The envelope was single-use and is spent; confirm the permission still holds rather than sending again.
        try await broker.confirmStillPermitted(envelope, recipient: recipient, purpose: purpose)
        try Task.checkCancellation(); try result.validate(for: request)
        return result
    }
    func release(_ envelope: DisclosureEnvelope, to recipient: RecipientID,
                 purpose: ContextPurpose, now: Date = Date()) async throws -> ContextDisclosurePayload {
        try await broker.validateForSend(envelope, recipient: recipient, purpose: purpose, now: now)
    }
}

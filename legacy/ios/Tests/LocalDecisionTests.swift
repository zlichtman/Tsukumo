import XCTest
@testable import KemoSabe

/// A local decision whose provider answers is returned, and the disclosure stays single-use.
final class LocalDecisionTests: XCTestCase {
    private struct FixedProvider: DecisionProvider {
        let modelVersion = "test-laya"
        func decide(_ request: DecisionRequest) async throws -> DecisionResult {
            .init(modelVersion: modelVersion, answers: request.questions.map { .init(questionID: $0.id, probabilities: [0.8, 0.2]) },
                  calibrated: false, abstention: nil)
        }
    }
    private var request: DecisionRequest {
        .init(state: "Wants a quiet dinner tonight", questions: [.init(id: "venue", kind: .choice, instruction: "Pick one", options: ["Home", "Out"])],
              deadline: Date().addingTimeInterval(30))
    }
    func testASuccessfulLocalDecisionIsReturned() async throws {
        let result = try await PrivateDecisionGateway.decideDirect(request, using: FixedProvider())
        XCTAssertEqual(result.answers.first?.selectedIndex, 0)
    }
    func testAnEnvelopeStillSendsOnlyOnce() async throws {
        let broker = ContextBroker(), owner = UUID()
        let recipient = RecipientID.appleOnDevice; let purpose: ContextPurpose = "local-decision"
        let record = try await broker.put(.init(ownerID: owner, source: .init(kind: .directUser, identifier: owner.uuidString, observedAt: Date()),
            compartment: .conversation, declaredSensitivity: .personal, restrictions: .init(localOnly: true), fields: [.text: "x"]), expectedRevision: nil)
        let grant = try await broker.mintGrant(.init(ownerID: owner, purpose: purpose, recipient: recipient, fields: [.text],
            recordRevisions: [record.id: record.revision], expiresAt: Date().addingTimeInterval(30)), authority: .hostPolicy)
        let envelope = try await broker.makeEnvelope(recordIDs: [record.id], using: grant, fields: [.text])
        // Confirming before sending isn't a way around the send check.
        do { try await broker.confirmStillPermitted(envelope, recipient: recipient, purpose: purpose); XCTFail("Unsent envelope confirmed") } catch {}
        _ = try await broker.validateForSend(envelope, recipient: recipient, purpose: purpose)
        try await broker.confirmStillPermitted(envelope, recipient: recipient, purpose: purpose)
        do { _ = try await broker.validateForSend(envelope, recipient: recipient, purpose: purpose); XCTFail("Envelope sent twice") }
        catch { XCTAssertEqual(error as? ContextBrokerError, .envelopeAlreadyUsed) }
        // A revoked record fails the confirmation after the response.
        try await broker.revoke(recordID: record.id, ownerID: owner)
        do { try await broker.confirmStillPermitted(envelope, recipient: recipient, purpose: purpose); XCTFail("Revoked disclosure confirmed") } catch {}
    }
}

import XCTest
#if os(macOS)
@testable import KemoSabeMac
#else
@testable import KemoSabe
#endif

final class ContextPagingTests: XCTestCase {
    private let purpose: ContextPurpose = "project-review"
    private let recipient: RecipientID = .appleOnDevice
    private func fixture(_ text: String) async throws -> (ContextBroker, AttributedContextRecord, ContextDisclosureGrant, DisclosureEnvelope) {
        let broker = ContextBroker(), owner = UUID()
        let record = try await broker.put(.init(ownerID: owner,
            source: .init(kind: .directUser, identifier: "fixture", observedAt: Date()), compartment: .conversation,
            restrictions: .init(localOnly: true), fields: [.text: text]))
        let grant = try await broker.mintGrant(.init(ownerID: owner, purpose: purpose, recipient: recipient, fields: [.text],
            recordRevisions: [record.id: record.revision], expiresAt: Date().addingTimeInterval(60)), authority: .authenticatedOwner(owner))
        let envelope = try await broker.makeEnvelope(recordIDs: [record.id], using: grant, fields: [.text])
        return (broker, record, grant, envelope)
    }
    func testEvictedPageRecoversExactlyWithoutSummary() async throws {
        let (broker, record, grant, _) = try await fixture("Early constraint\nShip after Tuesday\nLater work")
        let pager = ContextPager(broker: broker)
        let reference = ContextPageRequest(recordID: record.id, revision: record.revision, firstLine: 1, lastLine: 2)
        let first = try await pager.read(reference, using: grant, recipient: recipient, purpose: purpose, byteBudget: 200)
        // Working context can drop the value and persist only its reference.
        let restored = try await ContextPager(broker: broker).read(reference, using: grant, recipient: recipient, purpose: purpose, byteBudget: 200)
        XCTAssertEqual(first, restored); XCTAssertEqual(restored.text, "Early constraint\nShip after Tuesday")
        XCTAssertEqual(restored.sourceSHA256.count, 64)
    }
    func testRequiredPageIsRejectedRatherThanTruncated() async throws {
        let (broker, record, grant, _) = try await fixture("First line\nA crucial second line")
        do {
            _ = try await ContextPager(broker: broker).read(.init(recordID: record.id, revision: record.revision, firstLine: 1, lastLine: 2), using: grant, recipient: recipient, purpose: purpose, byteBudget: 10)
            XCTFail("An oversized required page was accepted")
        } catch { XCTAssertEqual(error as? ContextPagingError, .budgetExceeded) }
    }
    func testRevocationAndRecipientChangeBlockPageRecovery() async throws {
        let (broker, record, grant, _) = try await fixture("Private decision")
        let reference = ContextPageRequest(recordID: record.id, revision: record.revision, firstLine: 1, lastLine: 1)
        let pager = ContextPager(broker: broker)
        do {
            _ = try await pager.read(reference, using: grant, recipient: .codingAgent("coding-provider"), purpose: purpose, byteBudget: 200)
            XCTFail("A provider switch reused the local envelope")
        } catch {}
        try await broker.revoke(grantID: grant.id, ownerID: record.ownerID)
        do {
            _ = try await pager.read(reference, using: grant, recipient: recipient, purpose: purpose, byteBudget: 200)
            XCTFail("Revoked evidence was recovered")
        } catch {}
    }
    func testChangedSourceCannotBeReplayedFromOldPageReference() async throws {
        let (broker, record, grant, _) = try await fixture("Old constraint")
        _ = try await broker.put(.init(id: record.id, ownerID: record.ownerID, source: record.source, compartment: record.compartment,
            restrictions: .init(localOnly: true), fields: [.text: "New constraint"]), expectedRevision: record.revision)
        do {
            _ = try await ContextPager(broker: broker).read(.init(recordID: record.id, revision: record.revision, firstLine: 1, lastLine: 1), using: grant, recipient: recipient, purpose: purpose, byteBudget: 200)
            XCTFail("A stale page was replayed")
        } catch {}
    }
}

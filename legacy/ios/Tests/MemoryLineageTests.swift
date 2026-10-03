import XCTest
import CryptoKit
@testable import KemoSabe

final class MemoryLineageTests: XCTestCase {
    func testLegacyNoteDecodesWithoutLineageAndKeepsLegacyFingerprint() throws {
        let id = UUID()
        let json = Data(#"{"id":"\#(id.uuidString)","text":"Legacy note","scope":"Personal","useInChat":true}"#.utf8)
        let note = try JSONDecoder().decode(MemoryNote.self, from: json)
        XCTAssertNil(note.sourceDependencies)
        XCTAssertNil(note.inheritedSensitivity)

        let legacy = SHA256.hash(data: Data("\(id)|Personal|true|Legacy note".utf8))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(PlanningSource.fingerprint(note), legacy)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(note)) as? [String: Any])
        XCTAssertNil(encoded["sourceDependencies"])
        XCTAssertNil(encoded["inheritedSensitivity"])
    }

    func testValidDerivedNoteRequiresCurrentEnabledParent() {
        let parent = MemoryNote(text: "Orion source policy", scope: "Company", contextNamespace: "employer-a")
        var child = MemoryNote(text: "Zephyr summary derived from Orion")
        child.sourceDependencies = [.init(id: parent.id, fingerprint: PlanningSource.fingerprint(parent))]
        XCTAssertEqual(MemoryPolicy.validParentsFirst([child, parent]).map(\.id), [parent.id, child.id])

        var changed = parent
        changed.text = "Orion source policy changed"
        XCTAssertEqual(MemoryPolicy.valid([changed, child]).map(\.id), [parent.id])

        var disabled = parent
        disabled.useInChat = false
        var disabledChild = child
        disabledChild.sourceDependencies = [.init(id: disabled.id, fingerprint: PlanningSource.fingerprint(disabled))]
        XCTAssertTrue(MemoryPolicy.valid([disabled, disabledChild]).isEmpty)
        XCTAssertEqual(MemoryPolicy.valid([child]).map(\.id), [])
    }

    func testCyclesDuplicateIDsAndOverdeepLineageFailClosed() {
        var selfCycle = MemoryNote(text: "Self-derived")
        selfCycle.sourceDependencies = [.init(id: selfCycle.id, fingerprint: PlanningSource.fingerprint(selfCycle))]
        XCTAssertTrue(MemoryPolicy.valid([selfCycle]).isEmpty)

        let duplicate = MemoryNote(text: "Ambiguous duplicate")
        var duplicateCopy = duplicate
        duplicateCopy.text = "Same ID, different value"
        XCTAssertTrue(MemoryPolicy.valid([duplicate, duplicateCopy]).isEmpty)

        var chain = [MemoryNote(text: "Root chain marker")]
        for index in 1...(MemoryPolicy.maximumDerivationDepth + 1) {
            let parent = chain[index - 1]
            var child = MemoryNote(text: "Chain marker \(index)")
            child.sourceDependencies = [.init(id: parent.id, fingerprint: PlanningSource.fingerprint(parent))]
            chain.append(child)
        }
        let validIDs = Set(MemoryPolicy.valid(chain).map(\.id))
        XCTAssertTrue(validIDs.contains(chain[MemoryPolicy.maximumDerivationDepth].id))
        XCTAssertFalse(validIDs.contains(chain[MemoryPolicy.maximumDerivationDepth + 1].id))
    }

    func testRecallDropsDerivedNoteAsSoonAsParentChanges() {
        let parent = MemoryNote(text: "Canonical source")
        var child = MemoryNote(text: "Zephyr launch is Thursday")
        child.sourceDependencies = [.init(id: parent.id, fingerprint: PlanningSource.fingerprint(parent))]
        XCTAssertEqual(MemoryRecall.relevant([parent, child], to: "Zephyr").map(\.id), [child.id])

        var changed = parent
        changed.text = "Canonical source revised"
        XCTAssertTrue(MemoryRecall.relevant([changed, child], to: "Zephyr").isEmpty)
    }

    func testBridgeCarriesSensitivityAndRequiredCompartmentsThenRevokesStaleChild() async throws {
        let bridge = MemoryContextBridge()
        let owner = UUID()
        let parent = MemoryNote(text: "Orion company source", scope: "Company", contextNamespace: "employer-a")
        var child = MemoryNote(text: "Zephyr launch is Thursday")
        child.sourceDependencies = [.init(id: parent.id, fingerprint: PlanningSource.fingerprint(parent))]
        child.inheritedSensitivity = BrokerSensitivity.health.rawValue
        let assessment = MemoryPrivacyAssessment(noteID: parent.id,
            fingerprint: PlanningSource.fingerprint(parent), labels: BrokerSensitivity.child.rawValue,
            uncertain: false, assessedAt: Date())

        try await bridge.synchronize([child, parent], ownerID: owner, classifications: [assessment])
        let projected = try await bridge.projectedSensitivity(for: child.id, ownerID: owner)
        let sensitivity = try XCTUnwrap(projected)
        XCTAssertTrue(sensitivity.contains(.company))
        XCTAssertTrue(sensitivity.contains(.child))
        XCTAssertTrue(sensitivity.contains(.health))
        let recalled = try await bridge.lookup("Zephyr", ownerID: owner, recipient: .appleOnDevice, deadline: Date() + 60)
        XCTAssertEqual(recalled.map(\.id), [child.id])

        var changed = parent
        changed.text = "Orion company source revised"
        try await bridge.synchronize([changed, child], ownerID: owner, classifications: [])
        let revokedSensitivity = try await bridge.projectedSensitivity(for: child.id, ownerID: owner)
        XCTAssertNil(revokedSensitivity)
        let staleRecall = try await bridge.lookup("Zephyr", ownerID: owner, recipient: .appleOnDevice, deadline: Date() + 60)
        XCTAssertTrue(staleRecall.isEmpty)
    }
}

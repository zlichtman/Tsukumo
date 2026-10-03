import XCTest
@testable import KemoSabe

@MainActor final class ConnectorProvenanceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func result(_ records: [[String: String]] = [["title": "Design review", "start": "2027-01-15T15:00:00Z"]],
                        total: Int = 1, fetchedAt: Date? = nil) -> ConnectorReadResult {
        .init(connector: .calendar, fetchedAt: fetchedAt ?? now,
              records: records.map(ConnectorFieldRecord.init(fields:)), totalCount: total)
    }

    func testDigestIgnoresFetchTimeAndOrderingButBindsAllResultData() {
        let first = result([["title": "Design review", "start": "2027-01-15T15:00:00Z"],
                            ["title": "Lunch", "start": "2027-01-15T18:00:00Z"]])
        let reordered = result([["start": "2027-01-15T18:00:00Z", "title": "Lunch"],
                                ["start": "2027-01-15T15:00:00Z", "title": "Design review"]],
                               fetchedAt: now + 30)
        XCTAssertEqual(ConnectorSource.digest(first), ConnectorSource.digest(reordered))
        XCTAssertNotEqual(ConnectorSource.digest(first), ConnectorSource.digest(result(first.records.map(\.fields), total: 3)))
        XCTAssertNotEqual(ConnectorSource.digest(first), ConnectorSource.digest(result([["title": "Changed"]], total: 2)))
    }

    func testReferenceNormalizesQueryAndHasBoundedLifetime() {
        let source = ConnectorSource(result: result(), query: "  ALEX   Smith  ")
        XCTAssertEqual(source.query, "alex smith")
        XCTAssertEqual(source.expiresAt.timeIntervalSince(source.readAt), ConnectorSource.maximumLifetime)
        XCTAssertTrue(source.isValid(now: now))
        XCTAssertFalse(source.isValid(now: source.expiresAt))
    }

    func testFreshValidationRechecksEnabledPermissionAndDigest() async throws {
        let original = result(), source = ConnectorSource(result: original, query: nil)
        var enabled: Set<ConnectorID> = [.calendar]
        var permission = ConnectorPermission.allowed
        var current = result(fetchedAt: now + 20)
        var reads = 0
        func validate() async throws {
            try await ConnectorSourceValidation.requireCurrent([source], clock: { self.now + 30 },
                enabled: { enabled }, permission: { _ in permission }, read: { _, _ in reads += 1; return current })
        }
        try await validate()
        XCTAssertEqual(reads, 1)

        enabled = []
        await XCTAssertThrowsConnector(.disconnected) { try await validate() }
        enabled = [.calendar]; permission = .denied
        await XCTAssertThrowsConnector(.disconnected) { try await validate() }
        permission = .allowed; current = result([["title": "Changed meeting"]], fetchedAt: now + 20)
        await XCTAssertThrowsConnector(.changed) { try await validate() }
    }

    func testExpiredOrUncertainReferenceFailsClosed() async {
        let source = ConnectorSource(result: result(), query: nil)
        var reads = 0
        await XCTAssertThrowsConnector(.expired) {
            try await ConnectorSourceValidation.requireCurrent([source], clock: { source.expiresAt },
                enabled: { [.calendar] }, permission: { _ in .allowed },
                read: { _, _ in reads += 1; return self.result() })
        }
        XCTAssertEqual(reads, 0)
        await XCTAssertThrowsConnector(.changed) {
            try await ConnectorSourceValidation.requireCurrent([source], clock: { self.now + 1 },
                enabled: { [.calendar] }, permission: { _ in .allowed },
                read: { _, _ in throw CocoaError(.fileReadUnknown) })
        }
    }

    func testPlanningOriginBindsConnectorReferenceAndRejectsExpiry() throws {
        let source = ConnectorSource(result: result(), query: nil)
        var request = PlanningRequest(message: "Draft an update", history: [], memories: [],
            standupFormat: "", now: now, connectorSources: [source])
        let plan = CompanionPlan(answer: "Drafted", actions: [.init(kind: .draft, title: "Update", content: "Meeting update")])
        let first = try PlanValidator.proposals(plan, request: request, model: "Test", currentNotes: [], now: now)
        let second = try PlanValidator.proposals(plan, request: request, model: "Test", currentNotes: [], now: now + 1)
        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(first.map(\.digest), second.map(\.digest))
        XCTAssertEqual(first.first?.origin?.connectorSources, [source])

        let changed = ConnectorSource(result: result([["title": "Changed"]]), query: nil)
        request.connectorSources = [changed]
        let changedProposal = try PlanValidator.proposals(plan, request: request, model: "Test", currentNotes: [], now: now)
        XCTAssertNotEqual(first.first?.digest, changedProposal.first?.digest)
        XCTAssertThrowsError(try PlanValidator.proposals(plan, request: request, model: "Test",
                                                         currentNotes: [], now: changed.expiresAt))
    }

    func testConnectorBoundProposalKeepsLedgerIdempotencyAndReceipt() async throws {
        let source = ConnectorSource(result: result(), query: nil)
        let request = PlanningRequest(message: "Draft an update", history: [], memories: [],
            standupFormat: "", now: now, connectorSources: [source])
        let plan = CompanionPlan(answer: "Drafted", actions: [.init(kind: .draft,
            title: "Update", content: "Meeting update")])
        let proposal = try XCTUnwrap(PlanValidator.proposals(plan, request: request,
            model: "Test", currentNotes: [], now: now).first)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ledger = RoutineLedger(url: folder.appendingPathComponent("ledger.json"))
        try await ledger.enqueuePlan([proposal])
        try await ledger.approve(id: proposal.id, digest: proposal.digest, now: now + 1)
        _ = try await ledger.claim(id: proposal.id, now: now + 2)
        try await ledger.finish(id: proposal.id, receipt: "Reviewed · not sent", now: now + 3)
        try await ledger.enqueuePlan([proposal])
        let restored = try await ledger.snapshot().proposals
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.receipt, "Reviewed · not sent")
        XCTAssertEqual(restored.first?.digest, proposal.digest)
    }

    func testLegacyOriginDecodesWithoutConnectorSourcesAndKeepsNilEncodingSparse() throws {
        let id = UUID()
        let json = "{\"requestID\":\"\(id.uuidString)\",\"request\":\"Draft\",\"model\":\"Old\",\"sources\":[]}"
        let decoded = try JSONDecoder().decode(PlanningOrigin.self, from: Data(json.utf8))
        XCTAssertNil(decoded.connectorSources)
        let encoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        XCTAssertFalse(encoded.contains("connectorSources"))
    }
}

private func XCTAssertThrowsConnector<T>(_ expected: ConnectorSourceError,
                                         _ expression: () async throws -> T,
                                         file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch let error as ConnectorSourceError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}

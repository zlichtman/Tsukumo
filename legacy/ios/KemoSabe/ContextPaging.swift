import Foundation
import CryptoKit

/// Source-addressed context paging. Eviction drops a working-set reference, not
/// source evidence. This never summarizes or truncates a required source page.
/// Callers must already hold a broker-issued disclosure grant for the exact
/// owner, purpose, recipient, fields, and current source revisions.
struct ContextPageRequest: Codable, Equatable, Hashable, Sendable {
    let recordID: UUID
    let revision: Int
    let firstLine: Int
    let lastLine: Int
}
struct ContextPage: Equatable, Sendable {
    let reference: ContextPageRequest
    let sourceSHA256: String
    let text: String
    let totalLines: Int
}
enum ContextPagingError: Error, Equatable { case invalidRange, missingSource, staleSource, budgetExceeded, tooManyPages }

actor ContextPager {
    private let broker: ContextBroker
    init(broker: ContextBroker) { self.broker = broker }
    func read(_ request: ContextPageRequest, using grant: ContextDisclosureGrant,
              recipient: RecipientID, purpose: ContextPurpose,
              byteBudget: Int, now: Date = Date()) async throws -> ContextPage {
        try Task.checkCancellation()
        guard request.revision > 0, request.firstLine >= 1, request.lastLine >= request.firstLine,
              request.lastLine - request.firstLine < 256, (1...16_000).contains(byteBudget) else { throw ContextPagingError.invalidRange }
        let envelope = try await broker.makeEnvelope(recordIDs: [request.recordID], using: grant, fields: [.text], now: now)
        let payload = try await broker.validateForSend(envelope, recipient: recipient, purpose: purpose, now: now)
        return try page(request, payload: payload, byteBudget: byteBudget)
    }
    private func page(_ request: ContextPageRequest, payload: ContextDisclosurePayload, byteBudget: Int) throws -> ContextPage {
        guard request.revision > 0, request.firstLine >= 1, request.lastLine >= request.firstLine,
              request.lastLine - request.firstLine < 256 else { throw ContextPagingError.invalidRange }
        guard let record = payload.records.first(where: { $0.id == request.recordID }),
              let source = record.fields[.text] else { throw ContextPagingError.missingSource }
        guard record.revision == request.revision else { throw ContextPagingError.staleSource }
        let lines = source.components(separatedBy: "\n")
        guard request.lastLine <= lines.count else { throw ContextPagingError.invalidRange }
        let text = lines[(request.firstLine - 1)...(request.lastLine - 1)].joined(separator: "\n")
        guard text.utf8.count <= byteBudget else { throw ContextPagingError.budgetExceeded }
        try Task.checkCancellation()
        return .init(reference: request,
            sourceSHA256: SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined(),
            text: text, totalLines: lines.count)
    }
    /// Assemble a fresh recipient-specific working set; never replay cached
    /// plaintext across a provider, audience, permission, or revision change.
    func assemble(_ references: [ContextPageRequest], using grant: ContextDisclosureGrant,
                  recipient: RecipientID, purpose: ContextPurpose,
                  byteBudget: Int, now: Date = Date()) async throws -> [ContextPage] {
        guard !references.isEmpty, references.count <= 8, Set(references).count == references.count,
              (1...16_000).contains(byteBudget) else { throw ContextPagingError.tooManyPages }
        let envelope = try await broker.makeEnvelope(recordIDs: Array(Set(references.map(\.recordID))), using: grant, fields: [.text], now: now)
        let payload = try await broker.validateForSend(envelope, recipient: recipient, purpose: purpose, now: now)
        var pages: [ContextPage] = [], used = 0
        for reference in references {
            guard byteBudget > used else { throw ContextPagingError.budgetExceeded }
            let page = try page(reference, payload: payload, byteBudget: byteBudget - used)
            used += page.text.utf8.count; pages.append(page)
        }
        // This packet is assembled atomically from one validated snapshot, with
        // no awaits between page selection and return. A later send/retry must
        // assemble again; cached plaintext is not a reusable capability.
        try Task.checkCancellation()
        return pages
    }
}

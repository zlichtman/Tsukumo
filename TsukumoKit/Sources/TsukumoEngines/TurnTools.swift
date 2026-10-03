import Foundation
import TsukumoCore
import TsukumoPolicy
import TsukumoContext

/// The two tools every engine gets: `read_reference` (more context on demand, through the same
/// pinned, policy-checked reads as the working set) and `ask_kemosabe` (personal questions go to
/// the Gate; the bot never reads personal data).
public struct TurnTools: Sendable {
    public static let readReference = ToolDefinition(
        name: "read_reference",
        description: "Read a reference from the list you were given, by its id and revision. Optionally only some lines (\"10-40\"). Returns exactly those lines, or says why it can't.",
        parameters: [.init(name: "id", description: "The reference's id."),
                     .init(name: "revision", description: "The revision you were given."),
                     .init(name: "lines", description: "Optional line range, like 10-40.", required: false)])
    public static let askKemoSabe = ToolDefinition(
        name: "ask_kemosabe",
        description: "Ask KemoSabe, the owner's on-device assistant, one short question about the owner (their plans, messages, places). It reads on the owner's device and answers only what they allow.",
        parameters: [.init(name: "question", description: "One short question."),
                     .init(name: "purpose", description: "Why you need it, in a few words.")])

    public let store: ArtifactStore
    public let recipient: RecipientID
    public let purpose: Purpose
    public let grants: [RecipientGrant]
    public let ceiling: PrivacyLevel?
    /// The most one read may return.
    public let byteBudget: Int
    /// Sends a question to KemoSabe (the Gate) and returns what the agent may read; nil offers no
    /// `ask_kemosabe` (the bot may not ask, or it is KemoSabe itself).
    public let askKemoSabe: (@Sendable (_ question: String, _ purpose: String) async -> String)?

    public init(store: ArtifactStore, recipient: RecipientID, purpose: Purpose = .conversation, grants: [RecipientGrant] = [],
                ceiling: PrivacyLevel? = nil, byteBudget: Int = 16_000,
                askKemoSabe: (@Sendable (_ question: String, _ purpose: String) async -> String)? = nil) {
        self.store = store; self.recipient = recipient; self.purpose = purpose; self.grants = grants
        self.ceiling = ceiling; self.byteBudget = byteBudget; self.askKemoSabe = askKemoSabe
    }

    public var definitions: [ToolDefinition] { [Self.readReference] + (askKemoSabe == nil ? [] : [Self.askKemoSabe]) }

    /// Runs one call. Failures come back as words the model can act on, never as content it
    /// shouldn't have.
    public func run(_ call: ToolCall) async -> String {
        switch call.name {
        case Self.readReference.name: return await read(call.arguments)
        case Self.askKemoSabe.name:
            guard let askKemoSabe else { return "You can't ask KemoSabe in this chat." }
            let question = call.arguments["question"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !question.isEmpty else { return "Ask one short question." }
            return await askKemoSabe(question, call.arguments["purpose"] ?? "")
        default: return "There's no tool called \(call.name)."
        }
    }

    private func read(_ arguments: [String: String]) async -> String {
        guard let raw = arguments["id"], let uuid = UUID(uuidString: raw.trimmingCharacters(in: .whitespaces)),
              let revision = arguments["revision"].flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) else {
            return "Give the reference's id and revision from your list."
        }
        let id = ArtifactID(rawValue: uuid)
        // Only what this recipient's manifest lists can be read, and only at that revision.
        let listed = await store.manifest(for: recipient, purpose: purpose, grants: grants, ceiling: ceiling).first { $0.ref.id == id }
        guard let entry = listed else { return "That reference isn't one you can read." }
        guard entry.ref.revision == revision else {
            return "That reference changed: revision \(revision) is out of date; the current one is revision \(entry.ref.revision)."
        }
        var lines: ClosedRange<Int>?
        if let range = arguments["lines"]?.trimmingCharacters(in: .whitespaces), !range.isEmpty {
            let bounds = range.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard bounds.count == 2, bounds[0] <= bounds[1] else { return "Give lines as a range, like 10-40." }
            lines = bounds[0]...bounds[1]
        }
        do {
            let page = try await store.read(entry.ref, lines: lines, for: recipient, purpose: purpose, grants: grants,
                                            ceiling: ceiling, byteBudget: byteBudget)
            return "<reference id=\"\(page.ref.id)\" revision=\"\(page.ref.revision)\" lines=\"\(page.lines.lowerBound)-\(page.lines.upperBound) of \(page.totalLines)\">\n\(page.text)\n</reference>"
        } catch ArtifactStoreError.overBudget(let bytes, let budget) {
            return "Those lines are \(bytes) bytes, more than one read allows (\(budget)). Read fewer lines."
        } catch ArtifactStoreError.invalidRange {
            return "Those lines aren't in the reference (it has \(entry.lineCount))."
        } catch {
            return "That reference can't be read now."
        }
    }
}

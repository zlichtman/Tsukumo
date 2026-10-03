import Foundation
import TsukumoCore
import TsukumoPolicy
import TsukumoContext

/// Who an owner's message goes to, and who decided.
public struct RoutedMessage: Hashable, Sendable {
    public let recipients: [UUID]
    /// Nil when the owner tagged the bots (no decision was made); otherwise System One's source,
    /// or `.fallback` when it abstained and the bot last spoken to got it.
    public let decidedBy: DecisionSource?
    public var tagged: Bool { decidedBy == nil }
}

extension SystemOne {
    /// The `route` decision: tags decide when there are any; otherwise System One picks among the
    /// thread's bots from their names and jobs, and when it abstains the message goes to the bot
    /// last spoken to (or the thread's first bot).
    public static func route(_ text: String, chips: Set<UUID> = [], in thread: ChatThread, bots all: [BotSpec],
                             providers: SystemOneProviders, level: PrivacyLevel, grants: [RecipientGrant] = [],
                             deadline: Date = Date().addingTimeInterval(5)) async -> RoutedMessage {
        switch thread.routing(text: text, chips: chips, bots: all) {
        case .tagged(let ids):
            return RoutedMessage(recipients: ids, decidedBy: nil)
        case .untagged(let fallback):
            let fallbackRecipients = fallback.map { [$0] } ?? []
            let candidates = Array(thread.bots(from: all).prefix(12))
            guard candidates.count > 1 else { return RoutedMessage(recipients: fallbackRecipients, decidedBy: .fallback) }
            let options = optionLabels(candidates)
            let request = DecisionRequest(state: text, questions: [DecisionQuestion(
                id: "route", kind: .choice, instruction: "Which of the owner's bots should answer this message? Each choice is a bot and its job.",
                options: options)], deadline: deadline)
            let decision = await decide(.route, request, providers: providers, level: level, grants: grants)
            guard let index = decision.result?.answers.first?.selectedIndex, candidates.indices.contains(index) else {
                return RoutedMessage(recipients: fallbackRecipients, decidedBy: .fallback)
            }
            return RoutedMessage(recipients: [candidates[index].id], decidedBy: decision.decidedBy)
        }
    }

    /// "Pip: Plans dates", unique and at most 100 characters each.
    static func optionLabels(_ bots: [BotSpec]) -> [String] {
        var labels: [String] = []
        for bot in bots {
            let base = String((bot.role.isEmpty ? bot.name : bot.name + ": " + bot.role).prefix(90))
            var label = base, number = 2
            while labels.contains(label) { label = base + " (\(number))"; number += 1 }
            labels.append(label)
        }
        return labels
    }
}

/// The `selectContext` decision as a `ReferenceChooser`: for the newest manifest entries, System One
/// says whether each is needed. If it abstains on any of them, the whole choice abstains and the
/// default (everything authorized that fits) runs. It decides once, in the first round.
public struct SystemOneContextChooser: ReferenceChooser {
    public static let maxEntries = 12
    public let providers: SystemOneProviders
    /// The thread's level; each request is at least as private as the summaries it carries.
    public let level: PrivacyLevel
    public let grants: [RecipientGrant]
    public let timeout: TimeInterval

    public init(providers: SystemOneProviders, level: PrivacyLevel, grants: [RecipientGrant] = [], timeout: TimeInterval = 5) {
        self.providers = providers; self.level = level; self.grants = grants; self.timeout = timeout
    }

    public func choose(_ round: SelectionRound) async throws -> [ReferenceRead]? {
        guard round.index == 0 else { return [] }
        let entries = Array(round.manifest.prefix(Self.maxEntries))
        guard !entries.isEmpty else { return [] }
        var reads: [ReferenceRead] = []
        var start = 0
        while start < entries.count {
            let batch = Array(entries[start..<min(start + 4, entries.count)])
            let questions = batch.enumerated().map { offset, entry in
                DecisionQuestion(id: "ref-\(start + offset)", kind: .probability,
                                 instruction: String(("Is this needed to answer the request? " + entry.summaryLine).prefix(400)),
                                 options: ["Not needed", "Needed"])
            }
            let packetLevel = max(level, batch.map(\.label.level).max() ?? .open)
            let request = DecisionRequest(state: round.request, questions: questions, deadline: Date().addingTimeInterval(timeout))
            let decision = await SystemOne.decide(.selectContext, request, providers: providers, level: packetLevel, grants: grants)
            guard let result = decision.result else { return nil }
            for (entry, answer) in zip(batch, result.answers) where answer.selectedIndex == 1 {
                reads.append(ReferenceRead(ref: entry.ref))
            }
            start += 4
        }
        return reads
    }
}

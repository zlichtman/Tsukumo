import Foundation
import TsukumoCore
import TsukumoPolicy

/// Who made a decision: "laya", a hosted service's name ("jev"), or "fallback" (the caller's rules).
public struct DecisionSource: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public var description: String { rawValue }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
    public static let laya: DecisionSource = "laya"
    public static let fallback: DecisionSource = "fallback"
}

/// One provider's part in a decision. No request words: who, which version, and how sure.
public struct DecisionStep: Codable, Hashable, Sendable {
    public enum Reason: String, Codable, Sendable {
        /// Its top probability was below the decision's threshold, or it abstained itself.
        case lowConfidence
        /// Outside what it was evaluated on: another script, no words, or too long.
        case outOfDistribution
        /// The policy keeps this request from that service.
        case privacy
        /// Not available right now (loading, offline, timed out, an error).
        case unavailable
        /// The key was refused, or the rate limit was reached.
        case rejected
    }
    public let provider: DecisionSource
    public let version: String
    public let score: Double?
    public let reason: Reason?
    /// Where the request went; nil when it stayed on this device.
    public let sentTo: String?
    /// The personal layer decided rather than Laya's base.
    public let personal: Bool
    public var abstained: Bool { reason != nil }
}

/// One decision as the journal keeps it: never the request's words.
public struct DecisionRecord: Codable, Hashable, Identifiable, Sendable {
    public struct Question: Codable, Hashable, Sendable {
        public let id: String
        public let options: [String]
        /// Laya's base probabilities, in option order, when Laya scored it.
        public var laya: [Double]?
        /// The option decided; nil when the fallback decided.
        public var answer: Int?
    }
    public var id: UUID
    public let at: Date
    public let kind: DecisionKind
    public let decidedBy: DecisionSource
    public let steps: [DecisionStep]
    public let milliseconds: Int
    public let questions: [Question]
}

/// The last decisions on this device. Bounded; never the request's words.
public actor DecisionJournal {
    public static let limit = 200
    private let url: URL?
    private var records: [DecisionRecord]
    public init(url: URL? = nil) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url), let saved = try? TsukumoJSON.decoder.decode([DecisionRecord].self, from: data) {
            records = saved
        } else {
            records = []
        }
    }
    public func append(_ record: DecisionRecord) {
        records = Array((records + [record]).suffix(Self.limit))
        guard let url else { return }
        // Diagnostics never block a decision.
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? TsukumoJSON.encoder.encode(records).write(to: url, options: .atomic)
    }
    public func all() -> [DecisionRecord] { records }
}

/// A hosted decision service asked after Laya (Jev today). Each is its own recipient; turning it on
/// is the owner's grant for Personal requests, and the policy decides each request before it leaves.
public struct RemoteDecider: Sendable {
    public let source: DecisionSource
    public let host: String
    public let provider: any DecisionProvider
    public init(source: DecisionSource, host: String, provider: any DecisionProvider) {
        self.source = source; self.host = host; self.provider = provider
    }
    public var recipient: RecipientID { .systemOne(source.rawValue) }
    /// What turning it on grants: Personal requests (a kind grant never covers Sensitive).
    public var consent: RecipientGrant { RecipientGrant(recipient: recipient, kinds: [SystemOne.packetKind], purpose: .decision) }
}

/// The providers one decision may use.
public struct SystemOneProviders: Sendable {
    /// Laya (or any provider on this device), asked first.
    public var local: (any DecisionProvider)?
    /// Hosted services after it, in order.
    public var remotes: [RemoteDecider]
    /// The owner's personal layer over the local provider's scores.
    public var personal: PersonalLayer?
    public var journal: DecisionJournal?
    public init(local: (any DecisionProvider)? = nil, remotes: [RemoteDecider] = [], personal: PersonalLayer? = nil, journal: DecisionJournal? = nil) {
        self.local = local; self.remotes = remotes; self.personal = personal; self.journal = journal
    }
    public static let none = SystemOneProviders()
}

/// What a decision came to.
public struct Decision: Sendable {
    /// The accepted result, or nil: every provider abstained, and the caller's default runs.
    public let result: DecisionResult?
    public let decidedBy: DecisionSource
    public let steps: [DecisionStep]
    public var abstained: Bool { result == nil }
}

public enum SystemOne {
    /// The kind a decision packet is labeled with: the request's own words.
    public static let packetKind: ItemKind = .turn

    /// Outside what Laya was evaluated on: no letters, or mostly a script other than Latin.
    public static func outOfDistribution(_ request: DecisionRequest) -> Bool {
        let letters = request.state.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return true }
        return Double(letters.filter { $0.value < 0x250 }.count) / Double(letters.count) < 0.8
    }

    /// Asks the local provider (with the personal layer where it's on), then each hosted service in
    /// order, as far as the policy lets a request at `level` go, until one is sure. Every decision
    /// with at least one provider is journaled.
    public static func decide(_ kind: DecisionKind, _ request: DecisionRequest, providers: SystemOneProviders,
                              level: PrivacyLevel, grants: [RecipientGrant] = [], now: () -> Date = Date.init) async -> Decision {
        let started = now()
        var steps: [DecisionStep] = []
        var accepted: (result: DecisionResult, source: DecisionSource)?
        var questions = request.questions.map { DecisionRecord.Question(id: $0.id, options: $0.options) }
        let unfamiliar = outOfDistribution(request)
        let valid = (try? request.validate(now: started)) != nil

        func reason(for error: Error) -> DecisionStep.Reason {
            if let failure = error as? DecisionError, failure == .contextLimit || failure == .invalidInput { return .outOfDistribution }
            if let failure = error as? RemoteDecisionError, failure == .keyRejected || failure == .limited { return .rejected }
            return .unavailable
        }

        if let local = providers.local {
            if unfamiliar || !valid {
                steps.append(DecisionStep(provider: .laya, version: local.modelVersion, score: nil, reason: .outOfDistribution, sentTo: nil, personal: false))
            } else {
                do {
                    let base = try await local.decide(request)
                    try base.validate(for: request)
                    for (index, answer) in base.answers.enumerated() where questions.indices.contains(index) { questions[index].laya = answer.probabilities }
                    var result = base, personal = false
                    if let adjusted = providers.personal?.apply(to: base, for: request, kind: kind) { result = adjusted; personal = true }
                    let confident = result.abstention == nil && result.score >= kind.threshold
                    steps.append(DecisionStep(provider: .laya, version: result.modelVersion, score: result.score,
                                              reason: confident ? nil : .lowConfidence, sentTo: nil, personal: personal))
                    if confident { accepted = (result, .laya) }
                } catch {
                    steps.append(DecisionStep(provider: .laya, version: local.modelVersion, score: nil, reason: reason(for: error), sentTo: nil, personal: false))
                }
            }
        }

        for remote in providers.remotes where accepted == nil && !Task.isCancelled {
            let version = remote.provider.modelVersion
            let packet = PolicyItem(id: "system-one-request", label: TypeLabel(kind: packetKind, level: level))
            let allowed = ContextPolicy.allows(packet, to: remote.recipient, purpose: .decision, grants: [remote.consent] + grants, now: started)
            if !allowed {
                steps.append(DecisionStep(provider: remote.source, version: version, score: nil, reason: .privacy, sentTo: nil, personal: false))
            } else if unfamiliar || !valid {
                steps.append(DecisionStep(provider: remote.source, version: version, score: nil, reason: .outOfDistribution, sentTo: nil, personal: false))
            } else {
                do {
                    // Only the packet: the request's words, the questions, and their choices.
                    let result = try await remote.provider.decide(DecisionRequest(state: request.state, questions: request.questions, deadline: request.deadline))
                    try result.validate(for: request)
                    let confident = result.abstention == nil && result.score >= kind.threshold
                    steps.append(DecisionStep(provider: remote.source, version: result.modelVersion, score: result.score,
                                              reason: confident ? nil : .lowConfidence, sentTo: remote.host, personal: false))
                    if confident { accepted = (result, remote.source) }
                } catch {
                    steps.append(DecisionStep(provider: remote.source, version: version, score: nil, reason: reason(for: error),
                                              sentTo: remote.host, personal: false))
                }
            }
        }

        let decidedBy = accepted?.source ?? .fallback
        if let journal = providers.journal, !steps.isEmpty {
            if let result = accepted?.result {
                for (index, answer) in result.answers.enumerated() where questions.indices.contains(index) { questions[index].answer = answer.selectedIndex }
            }
            await journal.append(DecisionRecord(id: UUID(), at: started, kind: kind, decidedBy: decidedBy, steps: steps,
                                                milliseconds: Int(now().timeIntervalSince(started) * 1000), questions: questions))
        }
        return Decision(result: accepted?.result, decidedBy: decidedBy, steps: steps)
    }
}

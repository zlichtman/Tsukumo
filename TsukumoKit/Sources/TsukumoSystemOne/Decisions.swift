import Foundation

// System One's vocabulary (ported from the app's `PersonalDecisions.swift` and `SystemOne.swift`).
// A decision is advice among options the caller already permits: never a tool, a write, or a
// disclosure.

/// The decisions System One makes. Each has its own abstention threshold.
public enum DecisionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Which bot handles an untagged message.
    case route
    /// Which manifest references go into a turn's working set.
    case selectContext
    case missingInformation, planFit, routineIntent, interruptionTiming

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .route: "Routing"
        case .selectContext: "Context selection"
        case .missingInformation: "Missing information"
        case .planFit: "Plan fit"
        case .routineIntent: "Routine intent"
        case .interruptionTiming: "Interruption timing"
        }
    }
    /// Below this top probability a provider's answer is not accepted.
    ///
    /// The four older kinds keep the thresholds measured on September 27, 2026 (the Laya research,
    /// kept outside this repository). `route` and `selectContext` are new and unmeasured: they start
    /// strict, so System One abstains and the safe defaults run until an evaluation says otherwise.
    public var threshold: Double {
        switch self {
        case .route: 0.9
        case .selectContext: 0.9
        case .routineIntent: 0.95
        case .interruptionTiming: 0.9
        case .missingInformation: 0.65
        case .planFit: 0.8
        }
    }
}

/// One question in a decision: a choice among options, a yes/no probability (option 0 is false,
/// option 1 true), or a score over ordered levels.
public struct DecisionQuestion: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case choice, probability, score }
    public let id: String
    public let kind: Kind
    public let instruction: String
    public let options: [String]
    public init(id: String, kind: Kind, instruction: String, options: [String]) {
        self.id = id; self.kind = kind; self.instruction = instruction; self.options = options
    }
}

/// What a provider decides on: the request's words (`state`) and one to four questions.
public struct DecisionRequest: Sendable {
    public let state: String
    public let questions: [DecisionQuestion]
    public let deadline: Date
    public init(state: String, questions: [DecisionQuestion], deadline: Date) {
        self.state = state; self.questions = questions; self.deadline = deadline
    }
    public func validate(now: Date = Date()) throws {
        guard deadline > now, !state.isEmpty, state.utf8.count <= 8192,
              (1...4).contains(questions.count), Set(questions.map(\.id)).count == questions.count,
              questions.allSatisfy({ !$0.id.isEmpty && $0.id.count <= 80 && !$0.instruction.isEmpty && $0.instruction.count <= 400 &&
                  (2...12).contains($0.options.count) && Set($0.options).count == $0.options.count &&
                  $0.options.allSatisfy { !$0.isEmpty && $0.count <= 100 } && ($0.kind != .probability || $0.options.count == 2) })
        else { throw DecisionError.invalidInput }
    }
}

public struct DecisionAnswer: Codable, Hashable, Sendable {
    public let questionID: String
    /// In option order, summing to 1.
    public let probabilities: [Double]
    public init(questionID: String, probabilities: [Double]) { self.questionID = questionID; self.probabilities = probabilities }
    public var selectedIndex: Int? { probabilities.indices.max { probabilities[$0] < probabilities[$1] } }
    public var confidence: Double { probabilities.max() ?? 0 }
}

public struct DecisionResult: Hashable, Sendable {
    public let modelVersion: String
    public let answers: [DecisionAnswer]
    public let calibrated: Bool
    /// Why the provider abstained on its own, when it did.
    public let abstention: String?
    public init(modelVersion: String, answers: [DecisionAnswer], calibrated: Bool, abstention: String?) {
        self.modelVersion = modelVersion; self.answers = answers; self.calibrated = calibrated; self.abstention = abstention
    }
    /// The lowest top probability across its answers.
    public var score: Double { answers.map(\.confidence).min() ?? 0 }

    public func validate(for request: DecisionRequest) throws {
        guard !modelVersion.isEmpty else { throw DecisionError.invalidOutput }
        if abstention != nil { guard answers.isEmpty else { throw DecisionError.invalidOutput }; return }
        guard answers.count == request.questions.count else { throw DecisionError.invalidOutput }
        for (answer, question) in zip(answers, request.questions) {
            guard answer.questionID == question.id, answer.probabilities.count == question.options.count,
                  answer.probabilities.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                  abs(answer.probabilities.reduce(0, +) - 1) < 0.001 else { throw DecisionError.invalidOutput }
        }
    }
}

public enum DecisionError: Error, Hashable, Sendable { case unavailable, invalidInput, invalidOutput, contextLimit, incompatibleBundle }

/// A hosted decision service's failure.
public enum RemoteDecisionError: Error, Hashable, Sendable { case keyRejected, limited, status(Int) }

/// Anything that decides: Laya on the device, Jev hosted, a fake in tests.
public protocol DecisionProvider: Sendable {
    var modelVersion: String { get }
    func decide(_ request: DecisionRequest) async throws -> DecisionResult
}

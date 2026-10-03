import Foundation

// The owner's personal layer over Laya (ported from the app's `SystemOnePersonal.swift`). The owner
// marks recent decisions Right or Wrong; a small layer is fit on this device over Laya's base
// scores, per decision: a scale on the base log probabilities plus a bias for each choice and each
// position, pulled toward the base. It never changes Laya's weights, and it is turned on only when
// it gets more held-out (most recent) marks right than the base did. Marks and layers stay on the
// device.

/// One marked decision: Laya's base probabilities, what was shown, and which was right. No words.
public struct MarkedDecision: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let at: Date
    public let kind: DecisionKind
    public let questionID: String
    public let options: [String]
    public let laya: [Double]
    public let shown: Int
    public let correct: Int
    public init(id: UUID = UUID(), at: Date, kind: DecisionKind, questionID: String, options: [String], laya: [Double], shown: Int, correct: Int) {
        self.id = id; self.at = at; self.kind = kind; self.questionID = questionID; self.options = options
        self.laya = laya; self.shown = shown; self.correct = correct
    }
    public var isUsable: Bool {
        (2...PersonalHead.maxOptions).contains(options.count) && laya.count == options.count && options.indices.contains(correct)
            && laya.allSatisfy { $0.isFinite && $0 >= 0 }
    }
}

/// z_i = scale · log p_i + choice bias + position bias, then a softmax. Scale 1 and no biases is the
/// base itself, and the layer can only reweigh the choices it was given.
public struct PersonalHead: Codable, Hashable, Sendable {
    public static let maxOptions = 12
    public let questionID: String
    public var scale: Double = 1
    public var choiceBias: [String: Double] = [:]
    public var positionBias: [Double] = Array(repeating: 0, count: PersonalHead.maxOptions)
    public init(questionID: String) { self.questionID = questionID }

    public func probabilities(base: [Double], options: [String]) -> [Double] {
        let logits = base.indices.map { index in
            scale * log(max(base[index], 1e-6)) + (choiceBias[options[index]] ?? 0) + (positionBias.indices.contains(index) ? positionBias[index] : 0)
        }
        let top = logits.max() ?? 0, exponentials = logits.map { exp($0 - top) }, total = exponentials.reduce(0, +)
        return exponentials.map { $0 / total }
    }
}

/// How one decision's training went.
public struct PersonalReport: Codable, Hashable, Sendable {
    public let kind: DecisionKind
    public let examples: Int
    public let heldOut: Int
    public let baseRight: Int
    public let personalRight: Int
    public let turnedOn: Bool
}

/// Fits and checks personal layers. Pure and fast.
public enum PersonalTraining {
    public static let minimumExamples = 30
    public static let heldOutFraction = 0.3
    public static let minimumHeldOut = 8
    /// How many more held-out decisions the layer must get right before it turns on.
    public static let minimumWin = 2
    static let regularization = 0.02, steps = 600, learningRate = 0.5

    /// The most recent 30% (at least eight) are held out.
    public static func split(_ marks: [MarkedDecision]) -> (train: [MarkedDecision], heldOut: [MarkedDecision]) {
        let sorted = marks.sorted { $0.at == $1.at ? $0.id.uuidString < $1.id.uuidString : $0.at < $1.at }
        let held = min(sorted.count, max(minimumHeldOut, Int((Double(sorted.count) * heldOutFraction).rounded(.up))))
        return (Array(sorted.dropLast(held)), Array(sorted.suffix(held)))
    }

    /// Gradient descent on the average log loss, pulled toward the base.
    public static func fit(_ marks: [MarkedDecision], questionID: String) -> PersonalHead {
        var head = PersonalHead(questionID: questionID)
        guard !marks.isEmpty else { return head }
        let count = Double(marks.count)
        for _ in 0..<steps {
            var gradScale = 0.0, gradChoice: [String: Double] = [:], gradPosition = Array(repeating: 0.0, count: PersonalHead.maxOptions)
            for mark in marks {
                let q = head.probabilities(base: mark.laya, options: mark.options)
                for index in q.indices {
                    let g = (q[index] - (index == mark.correct ? 1 : 0)) / count
                    gradScale += g * log(max(mark.laya[index], 1e-6))
                    gradChoice[mark.options[index], default: 0] += g
                    gradPosition[index] += g
                }
            }
            head.scale = min(max(head.scale - learningRate * (gradScale + 2 * regularization * (head.scale - 1)), 0.2), 5)
            for (choice, g) in gradChoice {
                let bias = head.choiceBias[choice] ?? 0
                head.choiceBias[choice] = bias - learningRate * (g + 2 * regularization * bias)
            }
            for index in head.positionBias.indices {
                head.positionBias[index] -= learningRate * (gradPosition[index] + 2 * regularization * head.positionBias[index])
            }
        }
        return head
    }

    static func right(_ probabilities: [Double], _ correct: Int) -> Bool {
        probabilities.indices.max { probabilities[$0] < probabilities[$1] } == correct
    }

    /// Trains one decision's layer on its older marks and checks it on the newest. Nil below the minimum.
    public static func train(_ kind: DecisionKind, marks: [MarkedDecision]) -> (report: PersonalReport, head: PersonalHead?)? {
        let usable = marks.filter { $0.kind == kind && $0.isUsable }
        guard let questionID = Dictionary(grouping: usable, by: \.questionID).max(by: { $0.value.count < $1.value.count })?.key else { return nil }
        let marked = usable.filter { $0.questionID == questionID }
        guard marked.count >= minimumExamples else { return nil }
        let (train, heldOut) = split(marked)
        let head = fit(train, questionID: questionID)
        let baseRight = heldOut.filter { right($0.laya, $0.correct) }.count
        let personalRight = heldOut.filter { right(head.probabilities(base: $0.laya, options: $0.options), $0.correct) }.count
        let on = personalRight >= baseRight + minimumWin
        return (PersonalReport(kind: kind, examples: marked.count, heldOut: heldOut.count, baseRight: baseRight,
                               personalRight: personalRight, turnedOn: on), on ? head : nil)
    }
}

/// The layers that beat the base, applied to Laya's results.
public struct PersonalLayer: Codable, Hashable, Sendable {
    public var heads: [DecisionKind: PersonalHead]
    public init(heads: [DecisionKind: PersonalHead]) { self.heads = heads }

    /// Laya's result with the first question reweighed, or nil when there's no layer for this
    /// decision or it doesn't fit the question.
    public func apply(to base: DecisionResult, for request: DecisionRequest, kind: DecisionKind) -> DecisionResult? {
        guard base.abstention == nil, let head = heads[kind], let question = request.questions.first, question.id == head.questionID,
              question.options.count <= PersonalHead.maxOptions, let first = base.answers.first,
              first.probabilities.count == question.options.count else { return nil }
        var answers = base.answers
        answers[0] = DecisionAnswer(questionID: first.questionID, probabilities: head.probabilities(base: first.probabilities, options: question.options))
        let result = DecisionResult(modelVersion: base.modelVersion + " + personal layer", answers: answers, calibrated: false, abstention: nil)
        return (try? result.validate(for: request)) == nil ? nil : result
    }
}

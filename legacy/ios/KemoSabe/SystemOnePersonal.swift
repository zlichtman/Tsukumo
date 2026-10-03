import Foundation

// Training Laya on your own decisions (September 29, 2026). The person marks recent decisions Right
// or Wrong (and for Wrong, which choice was right). "Train Laya" fits a small personal layer on this
// device over Laya's base scores: per decision, a scale on the base log probabilities plus a bias
// for each choice and each position, regularized toward the base. It never changes Laya's weights.
// A layer is turned on only when it gets more of the held-out (most recent) marked decisions right
// than the base did; otherwise the base stays. Marks and the layer are Device only: kept in this
// account's folder, excluded from backup, never synced or uploaded, and deletable.
// See design/LAYA-TRAINING.md ("Personal layer").

/// One marked decision: what Laya's base gave each choice, what was shown, and which was right.
/// No request words.
struct SystemOneExample: Codable, Equatable, Identifiable, Sendable {
    var id: UUID { recordID }
    let recordID: UUID
    /// When the decision was made.
    let at: Date
    let markedAt: Date
    let kind: DecisionKind
    let questionID: String
    let options: [String]
    /// Laya's base probabilities, in option order.
    let laya: [Double]
    /// The choice the page showed: the decided answer, or where Laya leaned.
    let shown: Int
    /// The choice the person says was right.
    let correct: Int
    var right: Bool { shown == correct }

    /// A mark on a journal record's first question; nil when Laya didn't score it or the choice is out of range.
    init?(record: SystemOneRecord, correct: Int, markedAt: Date = Date()) {
        guard let question = record.markable, let laya = question.laya, let shown = question.shown,
              question.options.indices.contains(correct) else { return nil }
        recordID = record.id; at = record.at; self.markedAt = markedAt; kind = record.kind
        questionID = question.id; options = question.options; self.laya = laya; self.shown = shown; self.correct = correct
    }
    init(recordID: UUID = UUID(), at: Date, kind: DecisionKind, questionID: String, options: [String], laya: [Double], shown: Int, correct: Int) {
        self.recordID = recordID; self.at = at; markedAt = at; self.kind = kind; self.questionID = questionID
        self.options = options; self.laya = laya; self.shown = shown; self.correct = correct
    }
    var isUsable: Bool {
        options.count >= 2 && options.count <= PersonalHead.maxOptions && laya.count == options.count && options.indices.contains(correct)
            && laya.allSatisfy { $0.isFinite && $0 >= 0 }
    }
}

/// The person's marks for this account. Device only.
actor SystemOneExamples {
    static let fileName = "system-one-examples.json"
    static let limit = 2000
    static let didChange = Notification.Name("kemo.systemOne.examplesChanged")
    static var current: SystemOneExamples { SystemOneExamples(url: SystemOneStorage.folder.appendingPathComponent(fileName)) }
    private struct Document: Codable { var version = 1; var examples: [SystemOneExample] = [] }
    private let url: URL
    init(url: URL) { self.url = url }
    func all() -> [SystemOneExample] {
        guard let data = try? Data(contentsOf: url), let document = try? JSONDecoder().decode(Document.self, from: data),
              document.version == 1 else { return [] }
        return document.examples
    }
    /// Marks a decision; marking it again replaces the earlier mark.
    func mark(_ example: SystemOneExample) throws {
        var examples = all().filter { $0.recordID != example.recordID }
        examples.append(example)
        try save(Array(examples.suffix(Self.limit)))
    }
    func unmark(_ recordID: UUID) throws { try save(all().filter { $0.recordID != recordID }) }
    func deleteAll() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        post()
    }
    private func save(_ examples: [SystemOneExample]) throws {
        try SystemOneStorage.write(JSONEncoder().encode(Document(examples: examples)), to: url)
        post()
    }
    private func post() { Task { @MainActor in NotificationCenter.default.post(name: Self.didChange, object: nil) } }
}

/// A personal layer for one decision: z_i = scale · log p_i + choice bias + position bias, then a
/// softmax. The base itself is scale 1 with no biases, so an empty layer changes nothing, and the
/// layer can only reweigh the choices it was given.
struct PersonalHead: Codable, Equatable, Sendable {
    static let maxOptions = 12
    let questionID: String
    var scale: Double = 1
    var choiceBias: [String: Double] = [:]
    var positionBias: [Double] = Array(repeating: 0, count: PersonalHead.maxOptions)

    func logits(base: [Double], options: [String]) -> [Double] {
        base.indices.map { index in
            scale * log(max(base[index], 1e-6)) + (choiceBias[options[index]] ?? 0) + (positionBias.indices.contains(index) ? positionBias[index] : 0)
        }
    }
    func probabilities(base: [Double], options: [String]) -> [Double] { Self.softmax(logits(base: base, options: options)) }
    static func softmax(_ values: [Double]) -> [Double] {
        let top = values.max() ?? 0, exponentials = values.map { exp($0 - top) }, total = exponentials.reduce(0, +)
        return exponentials.map { $0 / total }
    }
}

/// How one decision's training went, in the terms the page shows.
struct SystemOnePersonalReport: Codable, Equatable, Sendable {
    let kind: DecisionKind
    let at: Date
    let examples: Int
    let trained: Int
    let heldOut: Int
    let baseRight: Int
    let personalRight: Int
    let turnedOn: Bool
    /// One plain line: the before and after on held-out decisions, and what happened.
    var summary: String {
        let counts = "On \(heldOut) held-out decisions: Laya alone \(baseRight) right, with your layer \(personalRight)."
        if turnedOn { return counts + " Your layer is on." }
        if baseRight == heldOut { return counts + " Laya alone got them all right, so there's nothing to fix yet. Keeping Laya's base." }
        if personalRight > baseRight {
            return counts + " It needs to get at least \(PersonalTraining.minimumWin) more right than Laya alone, so Laya's base stays."
        }
        return counts + " That isn't better, so Laya's base stays."
    }
}

/// Fits and checks personal layers. Pure and fast: a few hundred small gradient steps per decision.
enum PersonalTraining {
    /// Marked decisions a decision needs before it's trained: at least 21 to learn from and 9 held out.
    static let minimumExamples = 30
    static let heldOutFraction = 0.3
    static let minimumHeldOut = 8
    /// How many more held-out decisions the layer must get right than Laya alone before it turns on,
    /// so a one-decision edge (easily luck) keeps the base.
    static let minimumWin = 2
    static let regularization = 0.02
    static let steps = 600
    static let learningRate = 0.5

    /// The most recent 30% (at least four) are held out, so the check is on decisions it didn't learn from.
    static func split(_ examples: [SystemOneExample]) -> (train: [SystemOneExample], heldOut: [SystemOneExample]) {
        let sorted = examples.sorted { $0.at == $1.at ? $0.recordID.uuidString < $1.recordID.uuidString : $0.at < $1.at }
        let held = min(sorted.count, max(minimumHeldOut, Int((Double(sorted.count) * heldOutFraction).rounded(.up))))
        return (Array(sorted.dropLast(held)), Array(sorted.suffix(held)))
    }

    /// Full-batch gradient descent on the average log loss, pulled toward the base (scale 1, no biases).
    static func fit(_ examples: [SystemOneExample], questionID: String) -> PersonalHead {
        var head = PersonalHead(questionID: questionID)
        guard !examples.isEmpty else { return head }
        let count = Double(examples.count)
        for _ in 0..<steps {
            var gradScale = 0.0, gradChoice: [String: Double] = [:], gradPosition = Array(repeating: 0.0, count: PersonalHead.maxOptions)
            for example in examples {
                let q = head.probabilities(base: example.laya, options: example.options)
                for index in q.indices {
                    let g = (q[index] - (index == example.correct ? 1 : 0)) / count
                    gradScale += g * log(max(example.laya[index], 1e-6))
                    gradChoice[example.options[index], default: 0] += g
                    gradPosition[index] += g
                }
            }
            head.scale -= learningRate * (gradScale + 2 * regularization * (head.scale - 1))
            head.scale = min(max(head.scale, 0.2), 5)
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

    /// Trains one decision's layer on its older marks and checks it on the newest ones. Nil below the minimum.
    static func train(_ kind: DecisionKind, examples: [SystemOneExample], now: Date = Date()) -> (report: SystemOnePersonalReport, head: PersonalHead?)? {
        // One question per decision: the most common one among its marks.
        let usable = examples.filter { $0.kind == kind && $0.isUsable }
        guard let questionID = Dictionary(grouping: usable, by: \.questionID).max(by: { $0.value.count < $1.value.count })?.key else { return nil }
        let marked = usable.filter { $0.questionID == questionID }
        guard marked.count >= minimumExamples else { return nil }
        let (train, heldOut) = split(marked)
        let head = fit(train, questionID: questionID)
        let baseRight = heldOut.filter { right($0.laya, $0.correct) }.count
        let personalRight = heldOut.filter { right(head.probabilities(base: $0.laya, options: $0.options), $0.correct) }.count
        let on = personalRight >= baseRight + minimumWin
        return (.init(kind: kind, at: now, examples: marked.count, trained: train.count, heldOut: heldOut.count,
                      baseRight: baseRight, personalRight: personalRight, turnedOn: on), on ? head : nil)
    }

    /// Every decision in use with enough marks.
    static func trainAll(_ examples: [SystemOneExample], now: Date = Date()) -> SystemOnePersonalState {
        var state = SystemOnePersonalState()
        for kind in DecisionKind.allCases where kind.inUse {
            guard let (report, head) = train(kind, examples: examples, now: now) else { continue }
            state.reports[kind.rawValue] = report
            if let head { state.heads[kind.rawValue] = head }
        }
        state.trainedAt = now
        return state
    }
    /// Usable marks per decision, for "N of 12".
    static func counts(_ examples: [SystemOneExample]) -> [DecisionKind: Int] {
        Dictionary(grouping: examples.filter(\.isUsable), by: \.kind).mapValues(\.count)
    }
}

/// The trained layers (only those that beat the base) and the last training's reports.
struct SystemOnePersonalState: Codable, Equatable, Sendable {
    var version = 1
    var heads: [String: PersonalHead] = [:]
    var reports: [String: SystemOnePersonalReport] = [:]
    var trainedAt: Date?
    func report(_ kind: DecisionKind) -> SystemOnePersonalReport? { reports[kind.rawValue] }
    var activeKinds: [DecisionKind] { DecisionKind.allCases.filter { heads[$0.rawValue] != nil } }
}

/// The layers a decision applies, resolved when it starts.
struct SystemOnePersonalModel: Sendable {
    let heads: [String: PersonalHead]
    /// Laya's result with the first question reweighed by the person's layer, or nil when there's
    /// no layer for this decision or it doesn't fit the question.
    func apply(to base: DecisionResult, for request: DecisionRequest, kind: DecisionKind) -> DecisionResult? {
        guard base.abstention == nil, let head = heads[kind.rawValue], let question = request.questions.first,
              question.id == head.questionID, question.options.count <= PersonalHead.maxOptions,
              let first = base.answers.first, first.probabilities.count == question.options.count else { return nil }
        var answers = base.answers
        answers[0] = .init(questionID: first.questionID, probabilities: head.probabilities(base: first.probabilities, options: question.options))
        let result = DecisionResult(modelVersion: base.modelVersion + " + personal layer", answers: answers, calibrated: false, abstention: nil)
        return (try? result.validate(for: request)) == nil ? nil : result
    }
}

/// The layer file for this account. Device only.
struct SystemOnePersonalStore: Sendable {
    static let fileName = "system-one-personal.json"
    static let didChange = Notification.Name("kemo.systemOne.personalChanged")
    let url: URL
    init(folder: URL = SystemOneStorage.folder) { url = folder.appendingPathComponent(Self.fileName) }
    func state() -> SystemOnePersonalState {
        guard let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(SystemOnePersonalState.self, from: data),
              state.version == 1 else { return .init() }
        return state
    }
    /// The layers that beat the base, or nil when there are none.
    func activeModel() -> SystemOnePersonalModel? {
        let heads = state().heads
        return heads.isEmpty ? nil : .init(heads: heads)
    }
    func save(_ state: SystemOnePersonalState) throws {
        try SystemOneStorage.write(JSONEncoder().encode(state), to: url)
        post()
    }
    /// Back to Laya's base everywhere. The marks stay.
    func reset() {
        try? FileManager.default.removeItem(at: url)
        post()
    }
    private func post() { Task { @MainActor in NotificationCenter.default.post(name: Self.didChange, object: nil) } }
}

/// A private System One for the iPhone UI test (DEBUG, `--ui-testing --system-one-fixture`): its
/// own folder, its own Keychain service (`KeychainJevKey.service` ends in ".uitests"), no saved
/// key, and one recent Plan fit decision Laya was unsure of, to mark. Nothing is sent anywhere.
enum SystemOneFixture {
    static var requested: Bool {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--ui-testing") && arguments.contains("--system-one-fixture")
        #else
        return false
        #endif
    }
    #if DEBUG
    static func install() {
        guard requested else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SystemOneUITests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        SystemOneStorage.fixtureFolder = folder
        try? KeychainJevKey().remove()
        AccountDirectory.settings.removeObject(forKey: SystemOneSettings.jevKey)
        AccountDirectory.settings.removeObject(forKey: SystemOneSettings.layaKey)
        let record = SystemOneRecord(at: Date().addingTimeInterval(-300), kind: .candidateFit, decidedBy: .fallback,
            steps: [.init(provider: .laya, version: CoreMLLayaProvider.version, score: 0.62, reason: .lowConfidence, layer: .base)],
            milliseconds: 48, questions: [.init(id: "fit", options: ["9:00 AM", "2:00 PM", "5:00 PM"], laya: [0.62, 0.3, 0.08])])
        SystemOneJournal.write([record], to: folder.appendingPathComponent(SystemOneJournal.fileName))
    }
    #endif
}

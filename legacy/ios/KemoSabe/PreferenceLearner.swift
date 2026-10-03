import Foundation

enum PersonalizationValidation {
    // Enable only after held-out preference quality beats shared-model ranking.
    static let learnedRanking = false
}

enum PrivateStore {
    static func read<T: Decodable>(_ type: T.Type, at url: URL, initial: @autoclosure () -> T) throws -> T {
        FileManager.default.fileExists(atPath: url.path) ? try JSONDecoder().decode(type, from: Data(contentsOf: url)) : initial()
    }
    static func save<T: Encodable>(_ value: T, at url: URL) throws {
        try AccountDirectory.checkWrite(to: url)
        var folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var attributes = URLResourceValues(); attributes.isExcludedFromBackup = true
        try folder.setResourceValues(attributes)
        try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtection])
    }
}

struct PreferenceExample: Codable, Equatable, Identifiable, Sendable {
    enum Feedback: String, Codable, Sendable { case accepted, rejected, correction }
    let id: UUID
    let sourceID: UUID
    let features: [Double]
    let feedback: Feedback
    let createdAt: Date
}
struct StatedPreference: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let sourceID: UUID
    let text: String
    let preferredHour: Int
    let updatedAt: Date
    var activity: String? = nil
}
struct PreferenceState: Codable, Sendable {
    var version = 1
    var revision = 0
    var learning = true
    var examples: [PreferenceExample] = []
    var statements: [StatedPreference] = []
    var weights: [Double] = Array(repeating: 0, count: 5)
    func preference(for activity: String) -> StatedPreference? {
        statements.last { $0.activity == activity } ?? statements.last { ($0.activity ?? "general") == "general" }
    }
}
/// Small regularized logistic ranker. No networking, shared-model updates,
/// permission changes, or guessed reasons for rejected suggestions.
actor PreferenceLearner {
    private let url: URL
    init(url: URL) { self.url = url }
    func snapshot() throws -> PreferenceState {
        let state = try PrivateStore.read(PreferenceState.self, at: url, initial: PreferenceState())
        guard state.version == 1, state.weights.count == 5, state.weights.allSatisfy(\.isFinite),
              state.examples.count <= 256, state.statements.count <= 32,
              state.examples.allSatisfy({ Self.valid($0.features) }),
              state.statements.allSatisfy({ (0...23).contains($0.preferredHour) && $0.text.count <= 300 && [nil,"general","focus","exercise","errands"].contains($0.activity) }) else { throw RoutineError.corrupt }
        return state
    }
    static func features(hour: Int, duration: Int, fit: Double = 0.5) -> [Double] {
        [1, Double(hour) / 23, Double(min(max(duration, 1), 240)) / 240,
         hour < 12 ? 1 : 0, min(max(fit, 0), 1)]
    }
    private static func valid(_ values: [Double]) -> Bool {
        values.count == 5 && values.allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
    static func score(_ features: [Double], in state: PreferenceState) -> Double {
        guard valid(features), state.weights.count == 5 else { return 0.5 }
        let z = zip(state.weights, features).map(*).reduce(0,+)
        return 1 / (1 + exp(-min(max(z, -30), 30)))
    }
    func record(_ example: PreferenceExample) throws {
        guard Self.valid(example.features) else { throw RoutineError.unavailable }
        var state = try snapshot()
        guard state.learning, !state.examples.contains(where: { $0.id == example.id }) else { return }
        // A subsequent correction supersedes the earlier label for this proposal.
        state.examples.removeAll { $0.sourceID == example.sourceID }
        state.examples.append(example); state.examples = Array(state.examples.suffix(256))
        try commitRebuilt(state)
    }
    func statePreference(_ preference: StatedPreference) throws {
        guard (0...23).contains(preference.preferredHour), !preference.text.isEmpty, preference.text.count <= 300,
              [nil,"general","focus","exercise","errands"].contains(preference.activity) else { throw RoutineError.unavailable }
        var state = try snapshot()
        state.statements.removeAll { $0.sourceID == preference.sourceID }
        state.statements.append(preference); state.statements = Array(state.statements.suffix(32))
        state.examples.removeAll { $0.sourceID == preference.sourceID }
        state.examples.append(.init(id: preference.id, sourceID: preference.sourceID,
            features: Self.features(hour: preference.preferredHour, duration: 60), feedback: .correction, createdAt: preference.updatedAt))
        state.examples = Array(state.examples.suffix(256)); try commitRebuilt(state)
    }
    func forget(sourceID: UUID) throws {
        var state = try snapshot()
        state.examples.removeAll { $0.sourceID == sourceID }; state.statements.removeAll { $0.sourceID == sourceID }
        try commitRebuilt(state)
    }
    func reset() throws {
        let old = try snapshot(); var next = PreferenceState()
        next.learning = old.learning; next.revision = old.revision + 1
        try PrivateStore.save(next, at: url)
    }
    func setLearning(_ enabled: Bool) throws {
        var state = try snapshot(); state.learning = enabled; state.revision += 1
        try PrivateStore.save(state, at: url)
    }
    private func commitRebuilt(_ input: PreferenceState) throws {
        var state = input; state.weights = Array(repeating: 0, count: 5)
        // Rebuild from retained evidence, so forgetting removes its learned influence.
        for _ in 0..<40 {
            for example in state.examples {
                let prediction = Self.score(example.features, in: state)
                let target = example.feedback == .rejected ? 0.0 : 1.0
                let importance = example.feedback == .correction ? 3.0 : 1.0
                for i in state.weights.indices {
                    state.weights[i] -= 0.04 * (importance * (prediction-target) * example.features[i] + 0.03 * state.weights[i])
                }
            }
        }
        state.revision += 1; try PrivateStore.save(state, at: url)
    }
}

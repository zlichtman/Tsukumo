import Foundation

/// Stable app contracts; models receive bounded values, never storage or authority.
protocol ModelProvider: AssistantProvider {
    func respond(_ request: PlanningRequest, tools: ToolRegistry,
                 onSnapshot: @escaping @MainActor (String) -> Void) async throws -> CompanionPlan
}

enum ContextRelevance {
    static func needsStandup(_ text: String) -> Bool {
        let text = text.lowercased()
        return text.contains("standup") || text.contains("stand-up") || text.contains("stand up update")
    }
    static func needsRoutine(_ text: String) -> Bool {
        let words = Set(text.lowercased().split { !$0.isLetter }.map(String.init))
        return !words.isDisjoint(with: ["routine", "sleep", "bedtime", "wake", "morning", "schedule", "yesterday"])
    }
}

enum CloudValidation {
    // Release gate, not a user preference or remotely supplied flag. Enabling
    // it requires separately approved real-provider validation and a release.
    static let liveVoice = false
}

enum ToolFailure: Error, LocalizedError {
    case unavailable, expired, budget, invalidArguments, missingPermission
    var errorDescription: String? {
        switch self {
        case .unavailable: return "That connection is not available."
        case .expired: return "This request is no longer current."
        case .budget: return "This request reached its tool limit."
        case .invalidArguments: return "The tool needs valid, bounded arguments."
        case .missingPermission: return "Connect this app in Connections first."
        }
    }
}

struct ToolReceipt: Equatable, Sendable {
    let name: String
    let records: Int
    let completedAt: Date
}

/// Checks runtime facts, not a model's confidence or claim that work happened.
enum ActionGate {
    static func requireCurrent(deadline: Date, valid: Bool, now: Date = Date()) throws {
        try Task.checkCancellation()
        guard valid, now < deadline else { throw ToolFailure.expired }
    }
    /// A native read needs KemoSabe's switch, Apple's permission, and `ContextPolicy`'s decision for
    /// the recipient the result reaches: Apple's models by standing rule, a connected API model only
    /// with its own grant. Being the selected model grants nothing.
    static func requireNativeRead(_ id: ConnectorID, enabled: Set<ConnectorID>, permission: ConnectorPermission,
                                  recipient: ToolRecipient = .onDevice, now: Date = Date()) throws {
        guard id.isNative else { throw ToolFailure.unavailable }
        guard enabled.contains(id), [.allowed, .limited].contains(permission) else { throw ToolFailure.missingPermission }
        try requireRecipient(id, recipient, now: now)
    }
    static func requireRecipient(_ id: ConnectorID, _ recipient: ToolRecipient, now: Date = Date()) throws {
        let decision = ContextPolicy.evaluate([.connector(id)], to: recipient.id, purpose: .conversation, grants: recipient.grants, now: now)
        guard !decision.permitsAll else { return }
        if case let .apiModel(profile, host) = recipient.id {
            throw ConnectorGrantRequired(connector: id, profile: profile, modelName: recipient.name, host: host)
        }
        throw ToolFailure.missingPermission
    }
}

/// Per-turn bounded tools. The only writes produced here are *proposals* in
/// memory; the existing approval ledger remains the sole execution boundary.
actor ToolRegistry {
    typealias Lookup = @Sendable (String) async throws -> [PlanningSource]
    typealias ConnectorRead = @MainActor @Sendable (ConnectorID, String?) async throws -> ConnectorReadResult
    typealias Validate = @MainActor @Sendable () -> Bool
    typealias Daily = @MainActor @Sendable (PlanningRequest, Bool) async throws -> CompanionPlan
    private let daily: Daily?
    typealias Measure = @Sendable (String) async throws -> Int
    let deadline: Date
    private let lookup: Lookup
    private let read: ConnectorRead
    private let isCurrent: Validate
    private var calls = 0
    private var resultUnits = 0
    private var resultLimit = 1200
    private var measure: Measure = { $0.utf8.count }
    private(set) var sources: [PlanningSource] = []
    private(set) var connectorSources: [ConnectorSource] = []
    private(set) var actions: [PlannedAction] = []
    private(set) var receipts: [ToolReceipt] = []
    /// Where this turn's results go: required, so a turn on Private Cloud can never be taken for one on
    /// this device. A connected API model reads a connection only with its own grant, checked here
    /// before the read closure runs, and again inside it.
    let recipient: ToolRecipient
    init(deadline: Date, lookup: @escaping Lookup, read: @escaping ConnectorRead,
         isCurrent: @escaping Validate, daily: Daily? = nil, recipient: ToolRecipient) {
        self.daily = daily; self.recipient = recipient
        self.deadline = deadline; self.lookup = lookup; self.read = read; self.isCurrent = isCurrent
    }
    func dailyPlan(_ request: PlanningRequest, correction: Bool = false) async throws -> CompanionPlan {
        // Reserve the complete native read / score / proposal budget for this path.
        guard calls == 0, let daily else { throw ToolFailure.unavailable }
        for _ in 0..<6 { try await claim() }
        let plan = try await daily(request, correction)
        try await finish("proposal", records: 0)
        return plan
    }
    func configureResultBudget(_ limit: Int, measure: @escaping Measure) throws {
        guard calls == 0, (100...1600).contains(limit) else { throw ToolFailure.invalidArguments }
        resultLimit = limit; self.measure = measure
    }
    private func deliver(_ text: String) async throws -> String {
        let units = try await measure(text)
        try ActionGate.requireCurrent(deadline: deadline, valid: await isCurrent())
        guard units >= 0, resultUnits + units <= resultLimit else { throw ToolFailure.budget }
        resultUnits += units
        return text
    }
    private func claim() async throws {
        try ActionGate.requireCurrent(deadline: deadline, valid: await isCurrent())
        guard calls < 6 else { throw ToolFailure.budget }
        calls += 1
    }
    private func finish(_ name: String, records: Int) async throws {
        try ActionGate.requireCurrent(deadline: deadline, valid: await isCurrent())
        receipts.append(.init(name: name, records: records, completedAt: Date()))
    }
    func context(query: String) async throws -> String {
        try await claim()
        guard !query.isEmpty, query.count <= 200 else { throw ToolFailure.invalidArguments }
        let records = Array(try await lookup(query).prefix(4))
        try await finish("context", records: records.count)
        for record in records where !sources.contains(where: { $0.id == record.id }) { sources.append(record) }
        guard !records.isEmpty else { return try await deliver("No relevant saved context. Do not invent personal facts.") }
        return try await deliver(String(decoding: try JSONEncoder().encode(records), as: UTF8.self))
    }
    func connector(_ id: ConnectorID, query: String?) async throws -> String {
        try ActionGate.requireRecipient(id, recipient)
        try await claim()
        guard id.isNative, (query?.count ?? 0) <= 120 else { throw ToolFailure.invalidArguments }
        let result = try await read(id, query)
        try await finish(id.rawValue, records: result.records.count)
        let text = try await deliver(String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
        let source = ConnectorSource(result: result, query: query)
        if let previous = connectorSources.first(where: { $0.connector == source.connector && $0.query == source.query }) {
            // Earlier result bytes are already in the model transcript. Do not
            // replace their provenance with a newer, contradictory snapshot.
            guard previous.resultDigest == source.resultDigest else { throw PlanningError.changedContext }
        } else { connectorSources.append(source) }
        return text
    }
    func calculate(_ expression: String) async throws -> String {
        try await claim()
        let value = try ExactOperations.calculate(expression)
        try await finish("calculate", records: 1)
        return try await deliver(value)
    }
    func transform(_ text: String, operation: TextOperation) async throws -> String {
        try await claim()
        let result = try ExactOperations.transform(text, operation: operation)
        try await finish("text", records: 1)
        return try await deliver(result)
    }
    func sequence(start: Int, end: Int, step: Int) async throws -> String {
        try await claim()
        let value = try ExactOperations.sequence(start: start, end: end, step: step)
        try await finish("sequence", records: 1)
        return try await deliver(value)
    }
    func propose(_ action: PlannedAction) async throws -> String {
        try await claim()
        guard actions.count < 3, !action.content.isEmpty, action.content.count <= 2500,
              !action.title.isEmpty, action.title.count <= 100 else { throw ToolFailure.invalidArguments }
        try await finish("proposal", records: 1)
        if !actions.contains(action) { actions.append(action) }
        return try await deliver("Proposal prepared for review. Nothing has been executed, saved to memory, or sent.")
    }
}

extension ToolRegistry {
    /// Runs one connector tool call from a connected API model. What the model gets back is only
    /// what the tool returns. A missing grant for this model throws `ConnectorGrantRequired`, which
    /// ends the turn before anything more is sent; other refusals come back as plain results.
    func run(_ call: ModelToolCall) async throws -> String {
        let id: ConnectorID, query: String?
        switch call.name {
        case "read_calendar":
            let day = (call.arguments["day"] ?? "today").lowercased()
            guard ["today", "tomorrow"].contains(day) else { return "Nothing was read: day must be today or tomorrow." }
            id = .calendar; query = day == "tomorrow" ? "tomorrow" : nil
        case "read_reminders": id = .reminders; query = nil
        case "find_contact":
            let name = (call.arguments["name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 120 else { return "Nothing was read: a name to look up is needed." }
            id = .contacts; query = name
        default: return "Nothing was read: there's no tool by that name."
        }
        do { return try await connector(id, query: query) }
        catch ToolFailure.missingPermission {
            return "Nothing was read: \(id.title) isn't connected to KemoSabe on this device. The person can connect it in Settings → Connections."
        }
        catch ToolFailure.invalidArguments { return "Nothing was read: those arguments aren't valid." }
        catch ToolFailure.budget { return "Nothing more can be read in this reply. Answer with what you have." }
    }
}

enum ExactOperations {
    static func alarmDate(dayOffset: Int, hour: Int, minute: Int, now: Date, timeZone: TimeZone) throws -> Date {
        guard (0...6).contains(dayOffset), (0...23).contains(hour), (0...59).contains(minute) else { throw ToolFailure.invalidArguments }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        guard let day = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: now)) else { throw ToolFailure.invalidArguments }
        var target = calendar.dateComponents([.year, .month, .day], from: day)
        target.hour = hour; target.minute = minute; target.second = 0
        // Strict matching rejects nonexistent spring-forward times. Two
        // possible fall-back instants require clarification, never a silent guess.
        guard let first = calendar.nextDate(after: day.addingTimeInterval(-1), matching: target, matchingPolicy: .strict, repeatedTimePolicy: .first),
              let last = calendar.nextDate(after: day.addingTimeInterval(-1), matching: target, matchingPolicy: .strict, repeatedTimePolicy: .last),
              first == last, first > now.addingTimeInterval(30), first < now.addingTimeInterval(7 * 86400) else { throw ToolFailure.invalidArguments }
        return first
    }
    static func transform(_ text: String, operation: TextOperation) throws -> String {
        guard !text.isEmpty, text.count <= 160 else { throw ToolFailure.invalidArguments }
        switch operation {
        case .spell: return text.map { $0.isWhitespace ? "/" : String($0).uppercased() }.joined(separator: " ")
        case .repeatExactly: return text
        case .uppercase: return text.uppercased()
        case .lowercase: return text.lowercased()
        case .reverse: return String(text.reversed())
        }
    }
    static func sequence(start: Int, end: Int, step: Int) throws -> String {
        guard abs(Double(start)) <= 1_000_000, abs(Double(end)) <= 1_000_000,
              step != 0, abs(Double(step)) <= 1_000_000,
              start == end || (end > start ? step > 0 : step < 0) else { throw ToolFailure.invalidArguments }
        let count = abs((end - start) / step) + 1
        guard count <= 100 else { throw ToolFailure.invalidArguments }
        return (0..<count).map { String(start + $0 * step) }.joined(separator: ", ") + "."
    }
    static func calculate(_ expression: String) throws -> String {
        var parser = ArithmeticParser(expression)
        let result = try parser.evaluate()
        guard result.isFinite, abs(result) <= 1e15 else { throw ToolFailure.invalidArguments }
        if result.rounded() == result { return String(format: "%.0f", result) }
        return String(format: "%.10g", result)
    }
}

enum TextOperation: String { case spell, repeatExactly, uppercase, lowercase, reverse }

/// Deliberately no eval/NSExpression, names, function calls or unbounded recursion.
private struct ArithmeticParser {
    let bytes: [UInt8]
    var index = 0
    var depth = 0
    init(_ expression: String) { bytes = Array(expression.utf8.filter { $0 != 32 }) }
    mutating func evaluate() throws -> Double {
        guard !bytes.isEmpty, bytes.count <= 160 else { throw ToolFailure.invalidArguments }
        let result = try sum()
        guard index == bytes.count else { throw ToolFailure.invalidArguments }
        return result
    }
    mutating func take(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1; return true
    }
    mutating func sum() throws -> Double {
        var value = try product()
        while index < bytes.count {
            if take(43) { value += try product() }
            else if take(45) { value -= try product() }
            else { break }
        }
        return value
    }
    mutating func product() throws -> Double {
        var value = try atom()
        while index < bytes.count {
            if take(42) { value *= try atom() }
            else if take(47) { let divisor = try atom(); guard divisor != 0 else { throw ToolFailure.invalidArguments }; value /= divisor }
            else { break }
        }
        return value
    }
    mutating func atom() throws -> Double {
        depth += 1; defer { depth -= 1 }
        guard depth < 16 else { throw ToolFailure.invalidArguments }
        if take(45) { return try -atom() }
        if take(43) { return try atom() }
        if take(40) { let value = try sum(); guard take(41) else { throw ToolFailure.invalidArguments }; return value }
        let start = index
        while index < bytes.count, (48...57).contains(bytes[index]) || bytes[index] == 46 { index += 1 }
        guard index > start, let value = Double(String(decoding: bytes[start..<index], as: UTF8.self)), value.isFinite else { throw ToolFailure.invalidArguments }
        return value
    }
}

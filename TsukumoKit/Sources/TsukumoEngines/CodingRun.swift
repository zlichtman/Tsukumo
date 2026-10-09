#if os(macOS)
import Foundation

/// How a coding agent CLI is started: the program, where it is, and the environment it gets.
public struct CodingLaunch: Hashable, Sendable {
    public var executable: URL
    public var environment: [String: String]
    /// How long the agent has to open its session before the turn fails (a sign-in it waits on, a hang).
    public var startTimeout: TimeInterval
    public init(executable: URL, environment: [String: String], startTimeout: TimeInterval = 45) {
        self.executable = executable; self.environment = environment; self.startTimeout = startTimeout
    }
}

/// One turn of a coding agent: its process, its protocol's state, and the events it reports. Everything
/// a run does happens on its own serial queue; subclasses speak each CLI's protocol.
///
/// A run ends one of three ways: the agent finishes (`finish`), it fails (`fail`), or the owner stops it
/// (the stream is cancelled): the agent is asked to stop through its own protocol when it can, and its
/// whole process group is ended after `interruptGrace`.
class CodingRun: @unchecked Sendable {
    let queue = DispatchQueue(label: "tsukumo.coding.run")
    let task: CodingTask
    let launch: CodingLaunch
    let interruptGrace: TimeInterval
    /// The agent's name, for messages ("Claude Code").
    let name: String
    /// Unique per run, so request IDs from two turns never meet.
    let tag = String(UUID().uuidString.prefix(8)).lowercased()
    private(set) var process: CodingLineProcess?
    private var continuation: AsyncThrowingStream<CodingAgentEvent, Error>.Continuation?
    private(set) var ended = false
    private var registry: CodingRunRegistry?
    private var counter = 0
    /// A run keeps itself until it ends: only its process's callbacks (which hold it weakly) reach it.
    private var keepAlive: CodingRun?
    private var handshaken = false

    init(task: CodingTask, launch: CodingLaunch, name: String, interruptGrace: TimeInterval) {
        self.task = task; self.launch = launch; self.name = name; self.interruptGrace = interruptGrace
    }

    /// Starts the agent and streams what it reports.
    func stream(arguments: [String], registry: CodingRunRegistry) -> AsyncThrowingStream<CodingAgentEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { [weak self] reason in
                guard case .cancelled = reason, let self else { return }
                self.queue.async { self.cancelled() }
            }
            queue.async { [self] in
                self.continuation = continuation
                self.registry = registry
                keepAlive = self
                guard FileManager.default.fileExists(atPath: task.directory) else {
                    return fail(CodingAgentFailure("The bot’s folder isn’t there: \(task.directory)"))
                }
                do {
                    let tag = self.tag
                    process = try CodingLineProcess(executable: launch.executable, arguments: arguments,
                                                    directory: URL(fileURLWithPath: task.directory), environment: launch.environment, queue: queue,
                                                    onJSON: { [weak self] object in self?.handle(object) },
                                                    onExit: { [weak self] code, errors in
                                                        registry.exited(tag)
                                                        self?.processExited(code, errors)
                                                    })
                    if let child = process?.child { registry.began(tag) { child.signalGroup(SIGKILL) } }
                    try begin()
                } catch {
                    fail(error)
                }
                queue.asyncAfter(deadline: .now() + launch.startTimeout) { [weak self] in
                    guard let self, !self.ended, !self.handshaken else { return }
                    self.fail(CodingAgentFailure("\(self.name) didn’t start in time. If it needs you to sign in, run it in Terminal once, then try again."))
                }
            }
        }
    }

    // MARK: For subclasses

    /// Sends the first messages after the process starts.
    func begin() throws {}
    /// One JSON line from the agent.
    func receive(_ object: [String: Any]) throws {}
    /// The agent exited before the turn finished.
    func exitedEarly(code: Int32, errors: String) {
        fail(CodingAgentFailure(Self.exitMessage(name: name, code: code, errors: errors)))
    }
    /// The owner's (or the bot's access's) answer to a permission request.
    func answer(permission id: String, allow: Bool) throws {}
    /// What a Tsukumo tool returned.
    func answer(tool id: String, result: String) throws {}
    /// Asks the agent to stop its turn through its own protocol; false when it can't.
    func interrupt() -> Bool { false }

    // MARK: Helpers

    func yield(_ event: CodingAgentEvent) {
        guard !ended else { return }
        if case .permission(let id, _) = event { registry?.add(id, self) }
        if case .toolCall(let call) = event { registry?.add(call.id, self) }
        continuation?.yield(event)
    }
    /// The agent's session is open and the turn under way: the start deadline no longer applies.
    func handshakeDone() { handshaken = true }
    /// An ID for a request this run reports (permissions and tool calls).
    func nextID(_ kind: String) -> String { counter += 1; return "\(tag)-\(kind)-\(counter)" }
    func send(_ message: [String: Any]) throws {
        guard let process else { throw CodingAgentFailure("\(name) isn’t running.") }
        try process.send(message)
    }
    /// The turn finished: report the session to continue, then let the agent go.
    func finish(session: String?) {
        guard !ended else { return }
        continuation?.yield(.finished(session: session))
        end(nil)
        process?.closeInput()
        process?.stop(after: interruptGrace)
    }
    func fail(_ error: Error) {
        guard !ended else { return }
        end(error)
        process?.stop()
    }
    private func end(_ error: Error?) {
        ended = true
        registry?.removeAll(for: self)
        if let error { continuation?.finish(throwing: error) } else { continuation?.finish() }
        continuation = nil
        // Let go once this call returns (the process is stopped after it, by the caller).
        queue.async { [self] in keepAlive = nil }
    }

    // MARK: Plumbing

    private func handle(_ object: [String: Any]) {
        guard !ended else { return }
        do { try receive(object) } catch { fail(error) }
    }
    private func processExited(_ code: Int32, _ errors: String) {
        guard !ended else { return }
        exitedEarly(code: code, errors: errors)
    }
    private func cancelled() {
        guard !ended else { return }
        ended = true
        registry?.removeAll(for: self)
        continuation = nil
        if interrupt() { process?.stop(after: interruptGrace) } else { process?.stop() }
        keepAlive = nil
    }
    func respond(permission id: String, allow: Bool) {
        queue.async { [self] in
            guard !ended else { return }
            do { try answer(permission: id, allow: allow) } catch { fail(error) }
        }
    }
    func respond(tool id: String, result: String) {
        queue.async { [self] in
            guard !ended else { return }
            do { try answer(tool: id, result: result) } catch { fail(error) }
        }
    }

    /// What to say when an agent exits mid-turn: its own words when it said why (a sign-in problem most often).
    static func exitMessage(name: String, code: Int32, errors: String) -> String {
        let said = errors.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.suffix(3).joined(separator: " ")
        if signInProblem(said) { return "Sign in to \(name) in its terminal, then try again. It said: " + String(said.prefix(300)) }
        return "\(name) stopped (exit \(code))." + (said.isEmpty ? "" : " It said: " + String(said.prefix(300)))
    }
    static func signInProblem(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return ["not logged in", "please run /login", "log in", "login required", "unauthorized", "authenticat", "oauth", "invalid api key", "sign in"]
            .contains { lowered.contains($0) }
    }
}

/// Which run asked each open request, so the engine's answers reach it.
final class CodingRunRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var runs: [String: CodingRun] = [:]
    /// Runs whose process hasn't been reaped yet (by run tag), whether or not their turn has ended, with how to kill its group.
    private var live: [String: @Sendable () -> Void] = [:]
    func began(_ tag: String, kill: @escaping @Sendable () -> Void) { lock.withLock { live[tag] = kill } }
    func exited(_ tag: String) { lock.withLock { _ = live.removeValue(forKey: tag) } }
    var liveCount: Int { lock.withLock { live.count } }
    /// Waits until every process has been reaped (`waitpid`, reported by its exit callback): at most `timeout`, then
    /// SIGKILL to each remaining process group and up to `reapWait` more. False when one still hasn't been reaped.
    func waitUntilStopped(timeout: TimeInterval, reapWait: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while liveCount > 0, Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        guard liveCount > 0 else { return true }
        for kill in lock.withLock({ Array(live.values) }) { kill() }
        let reaped = Date().addingTimeInterval(reapWait)
        while liveCount > 0, Date() < reaped { try? await Task.sleep(for: .milliseconds(50)) }
        return liveCount == 0
    }
    func add(_ id: String, _ run: CodingRun) { lock.withLock { runs[id] = run } }
    func take(_ id: String) -> CodingRun? { lock.withLock { runs.removeValue(forKey: id) } }
    func removeAll(for run: CodingRun) { lock.withLock { runs = runs.filter { $0.value !== run } } }
    var isEmpty: Bool { lock.withLock { runs.isEmpty } }
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? { self[key] as? String }
    func object(_ key: String) -> [String: Any] { self[key] as? [String: Any] ?? [:] }
    func objects(_ key: String) -> [[String: Any]] { self[key] as? [[String: Any]] ?? [] }
}
#endif

import Foundation
import TsukumoCore

/// A model a coding agent offers, with the reasoning efforts it takes (ported from `CodingAgentModel` in the
/// old Tsukumo app's catalog).
public struct CodingAgentModel: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var efforts: [Effort]
    /// The effort it uses when none is chosen, when the agent says.
    public var defaultEffort: Effort?
    public var isDefault: Bool
    public init(id: String, name: String, efforts: [Effort] = [], defaultEffort: Effort? = nil, isDefault: Bool = false) {
        self.id = id; self.name = name; self.efforts = efforts; self.defaultEffort = defaultEffort; self.isDefault = isDefault
    }
}

#if os(macOS)
/// A coding agent Tsukumo can run: how it's found, how it's spoken to, and what it offers before it answers.
public struct CodingAgentKind: Hashable, Sendable, Identifiable {
    public enum Wire: Hashable, Sendable {
        /// Claude Code's stream-json (`ClaudeCodeBackend`).
        case claudeCode
        /// Codex's app-server (`CodexBackend`).
        case codex
        /// The Agent Client Protocol, started with these arguments (`ACPBackend`).
        case acp(arguments: [String])
    }
    /// The engine's key: "claude-code", "codex", "cursor-agent", or "acp:<name>".
    public let id: String
    public let title: String
    /// The program, looked up on the search path.
    public let command: String
    public let wire: Wire
    /// Models and efforts known before the agent is asked (its documented defaults).
    public let fallbackModels: [CodingAgentModel]
    /// Listed when choosing a bot's AI model even when it isn't installed, with how to get it.
    public let alwaysListed: Bool
    /// What to do when it isn't installed. Tsukumo never installs agents or signs in for the owner.
    public let install: String

    public var engine: EngineID { id.hasPrefix("acp:") ? .acp(String(id.dropFirst(4))) : .codingAgent(id) }

    public static let claudeCode = CodingAgentKind(id: "claude-code", title: "Claude Code", command: "claude", wire: .claudeCode,
                                                   fallbackModels: ClaudeCode.fallbackModels, alwaysListed: true,
                                                   install: "Install Claude Code, then run claude in Terminal once to sign in.")
    public static let codex = CodingAgentKind(id: "codex", title: "Codex", command: "codex", wire: .codex, fallbackModels: [],
                                              alwaysListed: true, install: "Install Codex, then run codex login in Terminal.")
    /// Cursor's CLI agent over ACP (`cursor-agent acp`; its print mode has no approvals).
    public static let cursorAgent = CodingAgentKind(id: "cursor-agent", title: "Cursor Agent", command: "cursor-agent", wire: .acp(arguments: ["acp"]),
                                                    fallbackModels: [], alwaysListed: true,
                                                    install: "Install Cursor’s CLI, then run cursor-agent login in Terminal.")
    /// Gemini CLI over ACP (`gemini --experimental-acp`); listed only when it's installed.
    public static let gemini = CodingAgentKind(id: "acp:gemini", title: "Gemini CLI", command: "gemini", wire: .acp(arguments: ["--experimental-acp"]),
                                               fallbackModels: [], alwaysListed: false,
                                               install: "Install Gemini CLI, then run gemini in Terminal once to sign in.")
    /// Every agent Tsukumo knows, in the order choosers list them.
    public static let all: [CodingAgentKind] = [.claudeCode, .codex, .cursorAgent, .gemini]

    public static func kind(for engine: EngineID) -> CodingAgentKind? {
        all.first { $0.engine == engine }
    }
}

/// A coding agent found on this Mac.
public struct InstalledCodingAgent: Hashable, Sendable {
    public let kind: CodingAgentKind
    public let executable: URL
    /// What `--version` printed ("2.1.287"), when it answered.
    public var version: String?
    /// Its models: what it said when asked, else its fallback list.
    public var models: [CodingAgentModel]
    public init(kind: CodingAgentKind, executable: URL, version: String? = nil, models: [CodingAgentModel]? = nil) {
        self.kind = kind; self.executable = executable; self.version = version; self.models = models ?? kind.fallbackModels
    }
}

/// Finding coding agents, their versions, and their models, without starting a conversation (nothing is billed).
public enum CodingAgentDetection {
    /// Which agents' programs are on `path`.
    public static func find(_ kinds: [CodingAgentKind] = CodingAgentKind.all, in path: [String]) -> [InstalledCodingAgent] {
        kinds.compactMap { kind in CodingEnvironment.find(kind.command, in: path).map { InstalledCodingAgent(kind: kind, executable: $0) } }
    }

    /// The version a program prints: the first word of its first line that starts with a digit
    /// ("2.1.287 (Claude Code)" → "2.1.287", "codex-cli 0.160.0" → "0.160.0").
    public static func version(from output: String) -> String? {
        guard let line = output.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { return nil }
        return line.split(separator: " ").map(String.init).first { $0.first?.isNumber == true } ?? String(line.prefix(40))
    }
    public static func version(of executable: URL, environment: [String: String]) -> String? {
        guard let result = try? CodingEnvironment.run(executable, ["--version"], timeout: 8, environment: environment), result.code == 0 else { return nil }
        return version(from: result.output)
    }

    /// Asks an agent for its models: Claude Code's `initialize` control request, Codex's `model/list`. ACP agents
    /// list models only inside a session, so they keep their fallback. Nil when it didn't answer in time.
    public static func models(of kind: CodingAgentKind, launch: CodingLaunch, timeout: TimeInterval = 20) async -> [CodingAgentModel]? {
        switch kind.wire {
        case .claudeCode:
            let answer = await CodingProbe.ask(launch: launch, arguments: ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"],
                                               first: [ClaudeCode.initialize(id: "catalog", tools: false)], timeout: timeout) { object, _ in
                guard object.string("type") == "control_response", object.object("response").string("request_id") == "catalog" else { return nil }
                return ClaudeCode.models(object.object("response").object("response"))
            }
            return answer.flatMap { $0.isEmpty ? nil : $0 }
        case .codex:
            let answer = await CodingProbe.ask(launch: launch, arguments: Codex.arguments, first: [Codex.initialize(id: "catalog-init")], timeout: timeout) { object, send in
                if object["id"] as? String == "catalog-init" {
                    send(["method": "initialized"]); send(["id": "catalog-models", "method": "model/list", "params": [String: Any]()])
                    return nil
                }
                guard object["id"] as? String == "catalog-models" else { return nil }
                return Codex.models(object.object("result"))
            }
            return answer.flatMap { $0.isEmpty ? nil : $0 }
        case .acp: return nil
        }
    }
}

/// One short-lived agent process that answers one question and is stopped.
enum CodingProbe {
    static func ask(launch: CodingLaunch, arguments: [String], first: [[String: Any]], timeout: TimeInterval,
                    read: @escaping @Sendable ([String: Any], (([String: Any]) -> Void)) -> [CodingAgentModel]?) async -> [CodingAgentModel]? {
        final class Box: @unchecked Sendable {
            var process: CodingLineProcess?
            var continuation: CheckedContinuation<[CodingAgentModel]?, Never>?
            func end(_ value: [CodingAgentModel]?) { continuation?.resume(returning: value); continuation = nil; process?.stop() }
        }
        let queue = DispatchQueue(label: "tsukumo.coding.probe")
        let box = Box()
        return await withCheckedContinuation { continuation in
            queue.async {
                box.continuation = continuation
                do {
                    box.process = try CodingLineProcess(executable: launch.executable, arguments: arguments, directory: FileManager.default.temporaryDirectory,
                                                        environment: launch.environment, queue: queue, grace: 1,
                                                        onJSON: { object in
                                                            if let value = read(object, { try? box.process?.send($0) }) { box.end(value) }
                                                        },
                                                        onExit: { _, _ in box.end(nil) })
                    for message in first { try box.process?.send(message) }
                } catch { box.end(nil) }
                queue.asyncAfter(deadline: .now() + timeout) { box.end(nil) }
            }
        }
    }
}

/// The coding agents on this Mac, for the app: where each is, its version and models, and a backend to run a
/// bot on. Found when it's made (file checks only); `refresh()` asks the login shell for its PATH, then each
/// agent for its version and models, off the main thread.
public final class CodingAgentCatalog: @unchecked Sendable {
    private let lock = NSLock()
    private var path: [String]
    private var found: [InstalledCodingAgent]
    private let kinds: [CodingAgentKind]
    private let base: [String: String]

    /// `path` replaces the search path (tests); otherwise the well-known folders and this process's PATH until
    /// `refresh()` adds the login shell's.
    public init(kinds: [CodingAgentKind] = CodingAgentKind.all, path: [String]? = nil, base: [String: String] = ProcessInfo.processInfo.environment) {
        self.kinds = kinds; self.base = base
        let search = path ?? CodingEnvironment.searchPath(loginPATH: nil, processPATH: base["PATH"])
        self.path = search
        found = CodingAgentDetection.find(kinds, in: search)
    }

    public var installed: [InstalledCodingAgent] { lock.withLock { found } }
    public func agent(for engine: EngineID) -> InstalledCodingAgent? { installed.first { $0.kind.engine == engine } }
    /// The environment agents start with: the owner's own, with the search path as PATH.
    public var environment: [String: String] { CodingEnvironment.environment(path: lock.withLock { path }, base: base) }

    /// Looks again: the login shell's PATH (unless a path was given), each agent's version, then its models.
    public func refresh(askLoginShell: Bool = true, probeModels: Bool = true) async {
        let search: [String]
        if askLoginShell {
            let login = await Task.detached(priority: .utility) { CodingEnvironment.loginShellPATH() }.value
            search = CodingEnvironment.searchPath(loginPATH: login, processPATH: base["PATH"])
        } else { search = lock.withLock { path } }
        let environment = CodingEnvironment.environment(path: search, base: base)
        var agents = CodingAgentDetection.find(kinds, in: search)
        for index in agents.indices {
            let executable = agents[index].executable
            agents[index].version = await Task.detached(priority: .utility) { CodingAgentDetection.version(of: executable, environment: environment) }.value
        }
        lock.withLock { path = search; found = agents }
        guard probeModels else { return }
        for index in agents.indices {
            if let models = await CodingAgentDetection.models(of: agents[index].kind, launch: CodingLaunch(executable: agents[index].executable, environment: environment)) {
                agents[index].models = models
            }
        }
        lock.withLock { found = agents }
    }

    /// A backend to run a bot on this engine, or nil when its agent isn't installed (or isn't a coding agent).
    public func backend(for engine: EngineID, interruptGrace: TimeInterval = 3) -> (any CodingAgentBackend)? {
        guard let agent = agent(for: engine) else { return nil }
        let launch = CodingLaunch(executable: agent.executable, environment: environment)
        switch agent.kind.wire {
        case .claudeCode: return ClaudeCodeBackend(launch: launch, interruptGrace: interruptGrace)
        case .codex: return CodexBackend(launch: launch, interruptGrace: interruptGrace)
        case .acp(let arguments): return ACPBackend(agentID: agent.kind.id, name: agent.kind.title, launch: launch, arguments: arguments, interruptGrace: interruptGrace)
        }
    }
}
#endif

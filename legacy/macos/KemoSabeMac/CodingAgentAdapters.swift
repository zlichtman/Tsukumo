import SwiftUI
import Foundation
import Observation

// The universal agent layer. Every coding agent Tsukumo can run is a `CodingAgentAdapter`: it
// says how the agent is launched, what it can do (models, efforts, access modes, steering,
// images, forks), how its saved session is deleted, and how the person signs in to it. Each
// running task gets an `AgentSession` from its adapter; the chat, approvals, queue, fork,
// Run with…, and the orchestrator only ever talk to those two protocols.
//
// Adapters (see design/TSUKUMO-BUILD-ENVIRONMENT.md#agent-adapters):
// - Claude Code: `claude -p` stream-json (`CodingAgentSession`, unchanged).
// - Codex: `codex app-server` JSON-RPC (`CodingAgentSession`, unchanged).
// - Muse Code: `muse serve`, the Muse Session Protocol (`CodingMuseSession`), with
//   `muse exec --json` as the fallback (`CodingMuseExecSession`).
// - Cursor Agent: `cursor-agent acp`, the Agent Client Protocol (`CodingACPSession`).
// - Any other ACP agent the person adds in Settings → Coding → Agents (`CodingCustomAgent`).
//
// Each agent is its own recipient with its own grants: it gets the task's folder and message,
// never KemoSabe's chats, memories, or credentials; a custom agent gets only the environment
// variables the person allow-listed; and each agent has its own highest access
// (`CodingAgentRegistry.grant`).

/// Which agent a task talks to. Saved in tasks as its raw string ("codex", "claude", "muse",
/// "cursor", or "acp:<uuid>" for an agent the person added), so tasks from earlier builds load.
struct CodingProvider: RawRepresentable, Hashable, Codable, Identifiable, Sendable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(_ rawValue: String) { self.rawValue = rawValue }
    var id: String { rawValue }
    static let codex = CodingProvider("codex")
    static let claude = CodingProvider("claude")
    static let muse = CodingProvider("muse")
    static let cursor = CodingProvider("cursor")
    /// The built-in agents, in the order choosers list them.
    static let builtIn: [CodingProvider] = [.claude, .codex, .muse, .cursor]
    static func custom(_ id: UUID) -> CodingProvider { .init("acp:" + id.uuidString.lowercased()) }
    var customID: UUID? { rawValue.hasPrefix("acp:") ? UUID(uuidString: String(rawValue.dropFirst(4))) : nil }
    var title: String { CodingAgentNames.title(self) }
    init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
}

/// Agents' display names, readable from anywhere (tasks, notifications, plans). Custom agents'
/// names are registered by `CodingAgentRegistry`.
enum CodingAgentNames {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var custom: [String: String] = [:]
    static func title(_ provider: CodingProvider) -> String {
        switch provider {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .muse: return "Muse Code"
        case .cursor: return "Cursor Agent"
        default:
            lock.lock(); defer { lock.unlock() }
            return custom[provider.rawValue] ?? "Custom agent"
        }
    }
    /// The symbol a participant shows on the collaboration page, from its agent's name.
    static func symbol(forTitle title: String) -> String {
        switch title {
        case "Claude Code": "asterisk"
        case "Codex": "chevron.left.forwardslash.chevron.right"
        case "Cursor Agent": "cursorarrow.rays"
        case "Muse Code": "m.circle"
        default: "sparkles"
        }
    }
    static func register(_ provider: CodingProvider, name: String) { lock.lock(); custom[provider.rawValue] = name; lock.unlock() }
    static func unregister(_ provider: CodingProvider) { lock.lock(); custom[provider.rawValue] = nil; lock.unlock() }
    /// Every named agent (built-in and registered), for resolving names in a plan.
    static func all() -> [(CodingProvider, String)] {
        lock.lock(); defer { lock.unlock() }
        return CodingProvider.builtIn.map { ($0, title($0)) } + custom.map { (CodingProvider($0.key), $0.value) }.sorted { $0.1 < $1.1 }
    }
}

/// How Tsukumo talks to an agent.
enum CodingAgentTransport: String, Codable, Equatable {
    /// Claude Code's headless stream-json with `can_use_tool` control requests.
    case claudeStreamJSON
    /// Codex `app-server` JSON-RPC.
    case codexAppServer
    /// The Agent Client Protocol (JSON-RPC over stdio), version `CodingACP.protocolVersion`.
    case acp
    /// Muse Code's Muse Session Protocol over `muse serve`.
    case msp
    var title: String {
        switch self {
        case .claudeStreamJSON: "Stream JSON"
        case .codexAppServer: "App server"
        case .acp: "Agent Client Protocol"
        case .msp: "Muse Session Protocol"
        }
    }
}

/// What an agent looks like in choosers and chats: its company's official mark for the built-ins
/// (`Assets.xcassets/AgentLogos`, from each company's press kit; see AgentLogos-NOTICE.txt), otherwise
/// initials on its hue.
struct CodingAgentMark: Equatable {
    var symbol: String?
    var initials: String
    /// A hue (0…1) so each agent keeps its color everywhere.
    var hue: Double
    /// The official mark's asset name, if there is one.
    var logo: String? = nil
    /// How a one-color (template) mark is tinted: nil for the foreground color. Full-color marks ignore it.
    var logoTint: Color? = nil
}

/// Whether the person is signed in to an agent, as far as Tsukumo can tell without reading
/// anyone's credentials: a sign-in file exists (never opened), or the agent said so while running.
enum CodingAgentSignInState: String, Equatable {
    case signedIn, signedOut, unknown
    var title: String {
        switch self { case .signedIn: "Signed in"; case .signedOut: "Not signed in"; case .unknown: "Uses its own sign-in" }
    }
}

/// One coding agent Tsukumo can run.
@MainActor protocol CodingAgentAdapter {
    var provider: CodingProvider { get }
    var title: String { get }
    var mark: CodingAgentMark { get }
    var transport: CodingAgentTransport { get }
    /// The program it runs (a name looked up on PATH, or a path).
    var command: String { get }
    var capabilities: CodingAgentCapabilities { get }
    /// The access modes it can run in (all four for every adapter so far).
    var accessModes: [CodingAccess] { get }
    /// Models and efforts known before the agent answers (its documented defaults).
    var fallbackModels: [CodingAgentModel] { get }
    /// What runs in a Tsukumo terminal tab for the person to sign in themselves.
    var signInCommand: String? { get }
    /// Where to install it from, when it isn't installed. Tsukumo never installs agents.
    var installLink: URL? { get }
    var installNote: String { get }
    /// A new session for a task (a fresh process; resumes or forks from the task's record).
    func makeSession(_ task: CodingTaskRecord) -> any AgentSession
    /// Asks the agent for its models without starting a conversation. False when it can't.
    func loadCatalog(_ done: @escaping (Result<CodingCatalogProbe.Answer, Error>) -> Void) -> Bool
    /// What Delete says it removes from the agent's own storage, or nil when nothing is.
    func removalPhrase(_ task: CodingTaskRecord) -> String?
    /// Removes the task's saved session from the agent; returns a problem to show, or nil.
    func removeSession(_ task: CodingTaskRecord) async -> String?
    /// Sign-in state from files only (existence, never contents).
    func signInState() -> CodingAgentSignInState
}
extension CodingAgentAdapter {
    var title: String { provider.title }
    var accessModes: [CodingAccess] { CodingAccess.allCases }
    var fallbackModels: [CodingAgentModel] { [] }
    var installLink: URL? { nil }
    var installNote: String { "`\(command)` isn't on your PATH." }
    func loadCatalog(_ done: @escaping (Result<CodingCatalogProbe.Answer, Error>) -> Void) -> Bool { false }
    func removalPhrase(_ task: CodingTaskRecord) -> String? { nil }
    func removeSession(_ task: CodingTaskRecord) async -> String? { nil }
    func signInState() -> CodingAgentSignInState { .unknown }
    /// The agent's own read-only sign-in check (for example `claude auth status`), when it has one.
    /// Asking the agent is the truth; guessing from files isn't. Nil falls back to `signInState()`.
    var statusArguments: [String]? { nil }
    /// Reads that check's output. Nil when the output doesn't say either way.
    func parseStatus(_ output: String, code: Int32) -> CodingAgentSignInState? { nil }
    /// The program's location, or nil when it isn't installed.
    func executable() -> URL? {
        if command.contains("/") {
            let path = (command as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        return try? CodingProcess.executable(command)
    }
}

// MARK: Built-in adapters

/// Claude Code through its headless stream-json (`CodingAgentSession`; behavior unchanged).
struct ClaudeCodeAdapter: CodingAgentAdapter {
    let provider = CodingProvider.claude
    let mark = CodingAgentMark(symbol: "asterisk", initials: "C", hue: 0.06, logo: "AgentLogoClaude")
    let transport = CodingAgentTransport.claudeStreamJSON
    let command = "claude"
    let capabilities = CodingAgentCapabilities(steer: false, images: true, compact: true, review: true, fork: true)
    var fallbackModels: [CodingAgentModel] { CodingAgentCatalog.claudeFallback }
    let signInCommand: String? = "claude"   // Claude Code asks to sign in on first run; /login switches accounts.
    var statusArguments: [String]? { ["auth", "status"] }
    /// `claude auth status` prints JSON with `loggedIn`.
    func parseStatus(_ output: String, code: Int32) -> CodingAgentSignInState? {
        guard let start = output.firstIndex(of: "{"), let data = String(output[start...]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let loggedIn = object["loggedIn"] as? Bool
        else { return code == 0 ? nil : .signedOut }
        return loggedIn ? .signedIn : .signedOut
    }
    var installLink: URL? { URL(string: "https://docs.anthropic.com/en/docs/claude-code") }
    func makeSession(_ task: CodingTaskRecord) -> any AgentSession { CodingAgentSession(task: task) }
    func loadCatalog(_ done: @escaping (Result<CodingCatalogProbe.Answer, Error>) -> Void) -> Bool { CodingCatalogProbe(provider: provider).run(done); return true }
    func removalPhrase(_ task: CodingTaskRecord) -> String? { "Claude Code's saved session for it, so it can't be resumed" }
    func removeSession(_ task: CodingTaskRecord) async -> String? {
        guard let session = task.sessionID, !session.isEmpty else { return nil }
        return CodingAgentSessionRemoval.removeClaudeSession(session, directory: task.directory, home: CodingAgentSessionRemoval.claudeHome)
    }
}

/// Codex through `codex app-server` (`CodingAgentSession`; behavior unchanged).
struct CodexAdapter: CodingAgentAdapter {
    let provider = CodingProvider.codex
    let mark = CodingAgentMark(symbol: "chevron.left.forwardslash.chevron.right", initials: "Cx", hue: 0.55, logo: "AgentLogoOpenAI")
    let transport = CodingAgentTransport.codexAppServer
    let command = "codex"
    let capabilities = CodingAgentCapabilities(steer: true, images: true, compact: true, review: true, fork: true)
    let signInCommand: String? = "codex login"
    var statusArguments: [String]? { ["login", "status"] }
    /// `codex login status`: "Logged in using …" and exit 0, or "Not logged in" and a failure.
    func parseStatus(_ output: String, code: Int32) -> CodingAgentSignInState? {
        let text = output.lowercased()
        if text.contains("not logged in") { return .signedOut }
        if code == 0 && text.contains("logged in") { return .signedIn }
        return code == 0 ? nil : .signedOut
    }
    var installLink: URL? { URL(string: "https://github.com/openai/codex") }
    func makeSession(_ task: CodingTaskRecord) -> any AgentSession { CodingAgentSession(task: task) }
    func loadCatalog(_ done: @escaping (Result<CodingCatalogProbe.Answer, Error>) -> Void) -> Bool { CodingCatalogProbe(provider: provider).run(done); return true }
    func removalPhrase(_ task: CodingTaskRecord) -> String? { "its Codex thread, so it leaves the Codex app's Recents" }
    func removeSession(_ task: CodingTaskRecord) async -> String? {
        guard let session = task.sessionID, !session.isEmpty else { return nil }
        return await CodingCodexThreadDeletion(threadID: session, directory: task.directory).run()
    }
    func signInState() -> CodingAgentSignInState {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory() + "/.codex"
        return FileManager.default.fileExists(atPath: home + "/auth.json") ? .signedIn : .signedOut
    }
}

/// Meta's Muse Code through `muse serve` (MSP v1). See `CodingMuseSession` for what was checked
/// against the installed binary and what's taken from its schema alone.
struct MuseCodeAdapter: CodingAgentAdapter {
    let provider = CodingProvider.muse
    let mark = CodingAgentMark(symbol: nil, initials: "M", hue: 0.62, logo: "AgentLogoMuse", logoTint: Color(red: 0.03, green: 0.4, blue: 1))
    let transport = CodingAgentTransport.msp
    let command = "muse"
    let capabilities = CodingAgentCapabilities(steer: true, images: true, compact: true, review: true, fork: true)
    /// Until `model/list` answers: the provider default, with the efforts `muse --help` lists.
    var fallbackModels: [CodingAgentModel] { [CodingMuse.defaultModel] }
    let signInCommand: String? = "muse login"
    var installLink: URL? { URL(string: "https://dev.meta.ai") }
    var installNote: String { "Muse Code isn't installed — install it from dev.meta.ai." }
    func makeSession(_ task: CodingTaskRecord) -> any AgentSession { CodingMuseSession(task: task) }
    func loadCatalog(_ done: @escaping (Result<CodingCatalogProbe.Answer, Error>) -> Void) -> Bool { CodingMuseCatalogProbe().run(done); return true }
    func removalPhrase(_ task: CodingTaskRecord) -> String? { "Muse Code's saved session for it, when Muse Code allows it (`session/delete`)" }
    func removeSession(_ task: CodingTaskRecord) async -> String? {
        guard let session = task.sessionID, !session.isEmpty else { return nil }
        return await CodingMuseSessionDeletion(sessionID: session).run()
    }
    func signInState() -> CodingAgentSignInState { CodingMuse.signedIn() ? .signedIn : .signedOut }
}

/// Cursor's CLI agent through its ACP server (`cursor-agent acp`, a hidden command in the
/// installed 2026.04.17 build, found in its bundle: sessions load, images, and permission
/// requests with allow-once, allow-always, and reject). Its print mode (`-p --output-format
/// stream-json`) has no approvals, so ACP is the better fit.
struct CursorAgentAdapter: CodingAgentAdapter {
    let provider = CodingProvider.cursor
    let mark = CodingAgentMark(symbol: "cursorarrow.rays", initials: "Cu", hue: 0.0, logo: "AgentLogoCursor")
    let transport = CodingAgentTransport.acp
    let command = "cursor-agent"
    let capabilities = CodingAgentCapabilities(steer: false, images: true, compact: false, review: true, fork: false)
    let signInCommand: String? = "cursor-agent login"
    var statusArguments: [String]? { ["status"] }
    /// `cursor-agent status`: "Logged in …" or "Not logged in".
    func parseStatus(_ output: String, code: Int32) -> CodingAgentSignInState? {
        let text = output.lowercased()
        if text.contains("not logged in") || text.contains("not authenticated") { return .signedOut }
        return text.contains("logged in") || text.contains("login successful") ? .signedIn : nil
    }
    var installLink: URL? { URL(string: "https://cursor.com/cli") }
    var launch: CodingACPLaunch { .init(command: command, arguments: ["acp"], environment: .inherit, name: title) }
    func makeSession(_ task: CodingTaskRecord) -> any AgentSession { CodingACPSession(task: task, launch: launch) }
    func removalPhrase(_ task: CodingTaskRecord) -> String? { nil }
}

/// An ACP agent the person added in Settings → Coding → Agents: a name, a command, arguments,
/// and the environment variables it may see.
struct CodingCustomAgent: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var command: String
    var arguments: [String] = []
    /// Environment variable names passed through from Tsukumo's environment, beyond the basics
    /// (PATH, HOME, USER, SHELL, LANG, TMPDIR). Values are never stored.
    var environment: [String] = []
    /// What to run in a terminal tab to sign in, if the agent needs it.
    var signIn: String?
    var provider: CodingProvider { .custom(id) }
}
struct CustomACPAdapter: CodingAgentAdapter {
    let agent: CodingCustomAgent
    var provider: CodingProvider { agent.provider }
    var title: String { agent.name }
    var mark: CodingAgentMark {
        let words = agent.name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let initials = words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        let hue = Double(agent.id.uuidString.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }) / 65535
        return .init(symbol: nil, initials: initials.isEmpty ? "A" : initials, hue: hue)
    }
    let transport = CodingAgentTransport.acp
    var command: String { agent.command }
    let capabilities = CodingAgentCapabilities(steer: false, images: true, compact: false, review: true, fork: false)
    var signInCommand: String? { agent.signIn }
    var launch: CodingACPLaunch { .init(command: agent.command, arguments: agent.arguments, environment: .allowList(agent.environment), name: agent.name) }
    func makeSession(_ task: CodingTaskRecord) -> any AgentSession { CodingACPSession(task: task, launch: launch) }
    func removalPhrase(_ task: CodingTaskRecord) -> String? { "its saved session in \(agent.name), if it can delete sessions" }
    func removeSession(_ task: CodingTaskRecord) async -> String? {
        guard let session = task.sessionID, !session.isEmpty else { return nil }
        return await CodingACPSessionDeletion(launch: launch, sessionID: session, directory: task.directory).run()
    }
}

// MARK: Registry

/// Every agent Tsukumo knows: the built-ins and the ones the person added, whether each is
/// installed, the last known sign-in state, and each agent's own grant (its highest access).
@MainActor @Observable final class CodingAgentRegistry {
    static let shared = CodingAgentRegistry()
    private(set) var custom: [CodingCustomAgent] = []
    /// Where each agent's program is, or nil when it isn't installed.
    private(set) var installed: [CodingProvider: URL] = [:]
    private(set) var checked = false
    /// What running agents said about sign-in (an auth error, or a turn that worked).
    private(set) var reportedSignIn: [CodingProvider: CodingAgentSignInState] = [:]
    /// What each agent's own status command said, from `checkSignIn()`.
    private(set) var checkedSignIn: [CodingProvider: CodingAgentSignInState] = [:]
    private(set) var checkingSignIn = false
    /// Each agent's highest access. Built-in agents may be given Full access; an added agent
    /// starts at Auto-edit until the person raises it.
    private(set) var grants: [CodingProvider: CodingAccess] = [:]
    private let defaults: UserDefaults
    private static let customKey = "tsukumo.agents.custom"
    private static let grantsKey = "tsukumo.agents.grants"
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.customKey), let saved = try? JSONDecoder().decode([CodingCustomAgent].self, from: data) { custom = saved }
        if let saved = defaults.dictionary(forKey: Self.grantsKey) as? [String: String] {
            grants = Dictionary(uniqueKeysWithValues: saved.compactMap { key, value in CodingAccess(rawValue: value).map { (CodingProvider(key), $0) } })
        }
        for agent in custom { CodingAgentNames.register(agent.provider, name: agent.name) }
        // Found once here (a few file checks), so views never change it while drawing; Settings refreshes.
        refresh()
    }
    var adapters: [any CodingAgentAdapter] {
        [ClaudeCodeAdapter(), CodexAdapter(), MuseCodeAdapter(), CursorAgentAdapter()] + custom.map { CustomACPAdapter(agent: $0) }
    }
    /// The adapter for a provider. An agent that was removed still resolves (to a stub that says
    /// so), so its old tasks open.
    func adapter(for provider: CodingProvider) -> any CodingAgentAdapter {
        switch provider {
        case .claude: return ClaudeCodeAdapter()
        case .codex: return CodexAdapter()
        case .muse: return MuseCodeAdapter()
        case .cursor: return CursorAgentAdapter()
        default:
            if let agent = custom.first(where: { $0.provider == provider }) { return CustomACPAdapter(agent: agent) }
            return CustomACPAdapter(agent: .init(id: provider.customID ?? UUID(), name: provider.title, command: "missing-agent"))
        }
    }
    /// Agents whose program was found (checked on first use; refresh re-checks).
    var available: [any CodingAgentAdapter] {
        return adapters.filter { installed[$0.provider] != nil }
    }
    /// What a chooser offers: the installed agents, plus any given ones (a task's current agent)
    /// even when they're missing, so a picker never loses its selection.
    func choices(including extra: [CodingProvider]) -> [CodingProvider] {
        var list = available.map(\.provider)
        for provider in extra where !list.contains(provider) { list.append(provider) }
        return list
    }
    func isInstalled(_ provider: CodingProvider) -> Bool {
        return installed[provider] != nil
    }
    func refresh() {
        checked = true
        var found: [CodingProvider: URL] = [:]
        for adapter in adapters { if let url = adapter.executable() { found[adapter.provider] = url } }
        installed = found
    }
    func signIn(_ provider: CodingProvider) -> CodingAgentSignInState {
        if let checked = checkedSignIn[provider] { return checked }
        if let reported = reportedSignIn[provider] { return reported }
        return adapter(for: provider).signInState()
    }
    /// Asks every installed agent that has a status command whether it's signed in (read-only,
    /// 8 s each, in parallel, off the main actor). A check that fails or says nothing leaves the
    /// earlier answer. Runs when Agents settings open and after a sign-in tab closes.
    func checkSignIn() async {
        guard !checkingSignIn else { return }
        checkingSignIn = true; defer { checkingSignIn = false }
        let jobs: [(CodingProvider, String, [String])] = adapters.compactMap { adapter in
            guard let arguments = adapter.statusArguments, let url = installed[adapter.provider] else { return nil }
            return (adapter.provider, url.path, arguments)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = ["PATH": CodingChild.environment()["PATH"] ?? "/usr/bin:/bin", "NO_COLOR": "1"]
        let results = await withTaskGroup(of: (CodingProvider, CodingCommandResult?).self) { group in
            for (provider, path, arguments) in jobs {
                group.addTask { (provider, try? await CodingCommand.run(path, arguments, at: home, timeout: 8, environment: environment)) }
            }
            var all: [(CodingProvider, CodingCommandResult?)] = []
            for await result in group { all.append(result) }
            return all
        }
        for (provider, result) in results {
            guard let result, let state = adapter(for: provider).parseStatus(result.output, code: result.code) else { continue }
            if checkedSignIn[provider] != state { checkedSignIn[provider] = state }
        }
    }
    func report(_ provider: CodingProvider, signIn: CodingAgentSignInState) {
        if reportedSignIn[provider] != signIn { reportedSignIn[provider] = signIn }
    }

    // MARK: Grants

    func grant(for provider: CodingProvider) -> CodingAccess {
        grants[provider] ?? (provider.customID == nil ? .full : .autoEdit)
    }
    func setGrant(_ access: CodingAccess, for provider: CodingProvider) {
        grants[provider] = access
        defaults.set(Dictionary(uniqueKeysWithValues: grants.map { ($0.key.rawValue, $0.value.rawValue) }), forKey: Self.grantsKey)
    }
    /// The access a task of this agent may have: what was asked, up to the agent's grant.
    func clamp(_ access: CodingAccess, for provider: CodingProvider) -> CodingAccess { min(access, grant(for: provider)) }

    // MARK: Added agents

    func save(_ agent: CodingCustomAgent) {
        var agent = agent
        agent.name = agent.name.trimmingCharacters(in: .whitespacesAndNewlines)
        agent.command = agent.command.trimmingCharacters(in: .whitespacesAndNewlines)
        agent.environment = agent.environment.map { $0.trimmingCharacters(in: .whitespaces) }.filter { CodingAgentEnvironment.validName($0) }
        if let index = custom.firstIndex(where: { $0.id == agent.id }) { custom[index] = agent } else { custom.append(agent) }
        CodingAgentNames.register(agent.provider, name: agent.name)
        persist(); refresh()
    }
    func remove(_ agent: CodingCustomAgent) {
        custom.removeAll { $0.id == agent.id }
        persist(); refresh()
    }
    private func persist() { if let data = try? JSONEncoder().encode(custom) { defaults.set(data, forKey: Self.customKey) } }
}

// MARK: Access

extension CodingAccess: Comparable {
    /// Read only < Ask first < Auto-edit < Full access.
    var rank: Int { switch self { case .readOnly: 0; case .edit: 1; case .autoEdit: 2; case .full: 3 } }
    static func < (lhs: CodingAccess, rhs: CodingAccess) -> Bool { lhs.rank < rhs.rank }
}

/// What an agent's request gets under the task's access, for requests Tsukumo itself serves or
/// decides (ACP's file and terminal methods, and ACP permission requests): allowed, asked in the
/// permission popup, or refused. The same four modes as Claude Code's and Codex's own.
enum CodingAccessGate {
    enum Decision: Equatable { case allow, ask, deny(String) }
    enum Request: Equatable {
        case read(path: String)
        case write(path: String)
        case command(String)
        /// An agent's own tool asking permission: its ACP kind and the paths it names.
        case tool(kind: String, paths: [String])
    }
    static func decide(_ request: Request, access: CodingAccess, directory: String) -> Decision {
        func inside(_ path: String) -> Bool { CodingAccessGate.inside(path, directory) }
        switch (request, access) {
        case (_, .full): return .allow
        case (.read(let path), _): return inside(path) ? .allow : .ask
        case (.write, .readOnly): return .deny("Read only: this task changes nothing.")
        case (.write, .edit): return .ask
        case (.write(let path), .autoEdit): return inside(path) ? .allow : .ask
        case (.command, .readOnly): return .deny("Read only: this task doesn't run commands.")
        case (.command, _): return .ask
        case (.tool(let kind, let paths), _):
            switch kind {
            case "read", "search", "think", "fetch": return paths.allSatisfy(inside) ? .allow : .ask
            case "edit", "delete", "move":
                if access == .readOnly { return .deny("Read only: this task changes nothing.") }
                if access == .autoEdit, !paths.isEmpty, paths.allSatisfy(inside) { return .allow }
                return .ask
            case "execute": return access == .readOnly ? .deny("Read only: this task doesn't run commands.") : .ask
            default: return access == .readOnly ? .deny("Read only: this task changes nothing.") : .ask
            }
        default: return .ask
        }
    }
    /// Whether a path is inside the task's folder (after resolving `..` and links).
    static func inside(_ path: String, _ directory: String) -> Bool {
        guard !path.isEmpty, !directory.isEmpty else { return false }
        let base = URL(fileURLWithPath: directory).standardizedFileURL.resolvingSymlinksInPath().path
        let target = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: directory, isDirectory: true)).standardizedFileURL
        // A file that doesn't exist yet: resolve its folder.
        let resolved = FileManager.default.fileExists(atPath: target.path) ? target.resolvingSymlinksInPath().path
            : target.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(target.lastPathComponent).path
        return resolved == base || resolved.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }
}

/// The environment an agent starts with. Built-in agents get the person's own (with Homebrew on
/// PATH), as a terminal would; an added agent gets only the basics plus the names allow-listed
/// for it.
enum CodingAgentEnvironment: Equatable {
    case inherit
    case allowList([String])
    static let basics = ["PATH", "HOME", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR", "TERM"]
    func build(_ source: [String: String] = CodingChild.environment()) -> [String: String] {
        var result: [String: String]
        switch self {
        case .inherit: result = source
        case .allowList(let names):
            result = [:]
            for name in Self.basics + names { if let value = source[name] { result[name] = value } }
        }
        result["TERM_PROGRAM"] = "Tsukumo"
        return result
    }
    static func validName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, !CharacterSet.decimalDigits.contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "_" }
    }
}

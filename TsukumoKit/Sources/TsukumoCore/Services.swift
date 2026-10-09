import Foundation

// The services Tsukumo works with: the engines underneath the owner's bots (Claude through the API or Claude Code,
// OpenAI through an API key, the coding agents) and the services whose own bots can be brought in (the owner's ChatGPT
// dot, agents that sign in to the KemoSabe gateway: Grok, OpenClaw, Claude's connector, a paired Muse). From October 7
// to 8, 2026 (2.05) each connected service had a bot of its own on the dock; since then the dock is KemoSabe and the
// owner's bots (`BotLineup`), and a service is connected in Settings, Services.

/// A service Tsukumo works with, in Settings' order.
public enum ServiceID: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Anthropic's Claude: an API key or Claude Code. Its own Tsukumo bot plugs in through `ServiceBotPanelProvider`.
    case claude
    /// OpenAI: an API key, or ChatGPT (and its dots) as a gateway caller.
    case openAI = "openai"
    /// xAI's Grok, a gateway caller.
    case grok
    /// Meta's Muse, paired over Bluetooth (a gateway caller of its own kind).
    case muse
    /// OpenClaw, a gateway caller.
    case openClaw = "openclaw"
    /// The coding agents on a Mac, each shown only when it's installed (or signed in to the gateway).
    case codex
    case cursor
    case gemini

    public var id: String { rawValue }

    /// Each service's bot's fixed ID from the fixed lineup ("service" in ASCII, then its place): a bot that was one keeps
    /// it, so its chats stay.
    public var botID: UUID {
        let index = Self.allCases.firstIndex(of: self).map { $0 + 1 } ?? 0
        return UUID(uuidString: String(format: "73657276-6963-6500-0000-%012d", index))!
    }
    /// The service a bot ID stands for.
    public init?(botID: UUID) {
        guard let match = Self.allCases.first(where: { $0.botID == botID }) else { return nil }
        self = match
    }

    /// Its name.
    public var title: String {
        switch self {
        case .claude: "Claude"
        case .openAI: "ChatGPT"
        case .grok: "Grok"
        case .muse: "Muse"
        case .openClaw: "OpenClaw"
        case .codex: "Codex"
        case .cursor: "Cursor Agent"
        case .gemini: "Gemini CLI"
        }
    }
    /// Who makes it.
    public var company: String {
        switch self {
        case .claude: "Anthropic"
        case .openAI, .codex: "OpenAI"
        case .grok: "xAI"
        case .muse: "Meta"
        case .openClaw: "OpenClaw"
        case .cursor: "Cursor"
        case .gemini: "Google"
        }
    }
    /// One line on how it reaches you here.
    public var role: String {
        switch self {
        case .claude: "Anthropic’s Claude"
        case .openAI: "OpenAI’s ChatGPT and models"
        case .grok: "xAI’s Grok, through the KemoSabe gateway"
        case .muse: "Meta’s Muse, paired with this Mac"
        case .openClaw: "OpenClaw, through the KemoSabe gateway"
        case .codex: "OpenAI’s coding agent on this Mac"
        case .cursor: "Cursor’s coding agent on this Mac"
        case .gemini: "Google’s coding agent on this Mac"
        }
    }
    /// The coding agent it runs on, when it's one (TsukumoEngines' `CodingAgentKind.id`).
    public var codingAgent: String? {
        switch self {
        case .claude: "claude-code"
        case .codex: "codex"
        case .cursor: "cursor-agent"
        case .gemini: "acp:gemini"
        default: nil
        }
    }
    /// Whether it's an engine bots chat on (on a Mac). Grok, Muse, and OpenClaw only call the gateway.
    public var canChat: Bool { ![.grok, .muse, .openClaw].contains(self) }
    /// What connecting it takes, in a line for Settings.
    public var howToConnect: String {
        switch self {
        case .claude: "Add your Claude API key in Settings, Models, or install Claude Code."
        case .openAI: "Add your OpenAI API key in Settings, Models, or connect ChatGPT through the gateway."
        case .grok: "Connect Grok to KemoSabe’s public address in Settings, Gateway."
        case .muse: "Pair Muse in Settings, KemoSabe."
        case .openClaw: "Connect OpenClaw to KemoSabe’s address in Settings, Gateway."
        case .codex: "Install Codex, then run codex login in Terminal."
        case .cursor: "Install Cursor’s CLI, then run cursor-agent login in Terminal."
        case .gemini: "Install Gemini CLI, then run gemini in Terminal once to sign in."
        }
    }

    /// A first guess at the service a gateway caller is, from the name it gave (OAuth) or the owner gave it (a token):
    /// only a whole name the service is known by, never part of one. A name is what the caller says it is, so this only
    /// prefills the owner's choice on its sign-in; a caller is filed under a service only once the owner confirms it.
    public static func guess(forCallerName name: String) -> ServiceID? {
        let words = name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
        let known: [String: ServiceID] = [
            "claude": .claude, "claude ai": .claude, "claude code": .claude, "anthropic": .claude,
            "chatgpt": .openAI, "openai": .openAI, "chatgpt dots": .openAI,
            "grok": .grok, "xai": .grok, "xai grok": .grok,
            "muse": .muse, "meta muse": .muse,
            "openclaw": .openClaw,
            "codex": .codex, "codex cli": .codex,
            "cursor": .cursor, "cursor agent": .cursor,
            "gemini": .gemini, "gemini cli": .gemini
        ]
        return known[words]
    }
}

/// Which services are connected on this device, as the host app knows them.
public struct ServiceConnections: Hashable, Sendable {
    /// The API connections with a key: Anthropic's and OpenAI's (the first of each).
    public var claudeAPI: UUID?
    public var openAIAPI: UUID?
    /// The coding agents installed on this Mac (`CodingAgentKind.id`: "claude-code", "codex", "cursor-agent", "acp:gemini").
    public var installedAgents: Set<String>
    /// The services with a gateway caller the owner confirmed as that service (or a paired Muse).
    public var callers: Set<ServiceID>
    /// Whether this device can run coding agents and the gateway (a Mac).
    public var isMac: Bool

    public init(claudeAPI: UUID? = nil, openAIAPI: UUID? = nil, installedAgents: Set<String> = [], callers: Set<ServiceID> = [], isMac: Bool = true) {
        self.claudeAPI = claudeAPI; self.openAIAPI = openAIAPI; self.installedAgents = installedAgents
        self.callers = callers; self.isMac = isMac
    }

    /// Whether `service` is connected, so its bot shows.
    public func isConnected(_ service: ServiceID) -> Bool {
        if callers.contains(service) { return true }
        switch service {
        case .claude: return claudeAPI != nil || (isMac && installedAgents.contains("claude-code"))
        case .openAI: return openAIAPI != nil
        case .codex, .cursor, .gemini: return isMac && service.codingAgent.map(installedAgents.contains) == true
        case .grok, .muse, .openClaw: return false
        }
    }

    /// What its bot runs on: a chat engine when there is one here, else a service that only calls the gateway.
    /// Claude takes its API key first, then Claude Code.
    public func engine(for service: ServiceID) -> EngineID {
        switch service {
        case .claude:
            if let claudeAPI { return .api(profile: claudeAPI) }
            if isMac, installedAgents.contains("claude-code") { return .codingAgent("claude-code") }
        case .openAI:
            if let openAIAPI { return .api(profile: openAIAPI) }
        case .codex, .cursor, .gemini:
            if isMac, let agent = service.codingAgent, installedAgents.contains(agent) {
                return agent.hasPrefix("acp:") ? .acp(String(agent.dropFirst(4))) : .codingAgent(agent)
            }
        case .grok, .muse, .openClaw:
            break
        }
        return .service(service.rawValue)
    }
}

extension ServiceID {
    /// The service an engine belongs to, if any (`apiService` says which service an API connection is).
    public static func of(_ engine: EngineID, apiService: (UUID) -> ServiceID?) -> ServiceID? {
        switch engine {
        case .api(let profile): apiService(profile)
        case .codingAgent("claude-code"): .claude
        case .codingAgent("codex"): .codex
        case .codingAgent("cursor-agent"): .cursor
        case .acp("gemini"): .gemini
        case .acp("cursor-agent"), .acp("cursor"): .cursor
        case .service(let id): ServiceID(rawValue: id)
        default: nil
        }
    }
}

/// The dock's bots: KemoSabe, then the owner's bots in the owner's order.
public enum BotLineup {
    /// The most bots the owner keeps beside KemoSabe.
    public static let maxBots = 12

    /// KemoSabe and the owner's bots (KemoSabe first, once).
    public static func bots(kemoSabe: BotSpec, saved: [BotSpec]) -> [BotSpec] {
        [kemoSabe] + saved.filter { !$0.isKemoSabe }
    }

    /// Each brought-in bot once: two devices that brought in the same dot or caller under different IDs keep the same
    /// one (the lowest ID), so sync settles on it everywhere (the other's removal syncs as a deletion). What only the
    /// other copy has comes along: a dot's Codex conversation, a pet, what the owner told it. Where both have something,
    /// the kept copy's stays. Order is kept.
    public static func oneEach(_ bots: [BotSpec]) -> [BotSpec] {
        var copies: [BotOrigin: [BotSpec]] = [:]
        for bot in bots where bot.isBroughtIn { copies[bot.origin.identity, default: []].append(bot) }
        var merged: [UUID: BotSpec] = [:]
        for group in copies.values {
            let sorted = group.sorted { $0.id.uuidString < $1.id.uuidString }
            var kept = sorted[0]
            for other in sorted.dropFirst() {
                if case .dot(let id, nil) = kept.origin, case .dot(_, let thread?) = other.origin { kept.origin = .dot(id: id, thread: thread) }
                if kept.look.pet == nil, other.look.pet != nil { kept.look = other.look }
                if kept.look.pet == other.look.pet {
                    if kept.look.petName == nil { kept.look.petName = other.look.petName }
                    if kept.look.petImage == nil { kept.look.petImage = other.look.petImage }
                }
                if kept.instructions.isEmpty { kept.instructions = other.instructions }
                if kept.role.isEmpty { kept.role = other.role }
            }
            merged[kept.id] = kept.normalized()
        }
        return bots.compactMap { bot in bot.isBroughtIn ? merged[bot.id] : bot }
    }

    /// The owner's bots after the fixed lineup of 2.05 (October 8, 2026): each service bot the owner used (one with
    /// saved settings or a conversation, `used`) stays as a bot of their own, under its fixed ID so its chats stay, on
    /// the engine its connection gives it (`engine`); bots that only stood for a gateway service (Grok, Muse, OpenClaw)
    /// leave, their callers coming back as brought-in bots; bots of the owner's own making (from before 2.05) stay as
    /// they are. KemoSabe isn't in the result.
    public static func adopt(saved: [BotSpec], used: Set<ServiceID>, engine: (ServiceID) -> EngineID) -> [BotSpec] {
        var kept: [BotSpec] = []
        for service in ServiceID.allCases where service.canChat {
            let earlier = saved.first { $0.id == service.botID }
            guard earlier != nil || used.contains(service) else { continue }
            var bot = earlier ?? BotSpec(id: service.botID, name: service.title, engine: engine(service), role: service.role)
            bot.origin = .made
            bot.service = service
            if service == .claude { bot.role = BotSpec.claudeBot().role; bot.engine = .codingAgent("claude-code") }
            kept.append(bot.normalized())
        }
        let own = saved.filter { !$0.isKemoSabe && ServiceID(botID: $0.id) == nil }
        for var bot in own {
            if kept.contains(where: { $0.name.caseInsensitiveCompare(bot.name) == .orderedSame }) { bot.name = String((bot.name + " 2").prefix(BotSpec.maxName)) }
            kept.append(bot.normalized())
        }
        return kept
    }
}

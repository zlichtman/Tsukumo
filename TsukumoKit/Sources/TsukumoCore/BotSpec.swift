import Foundation

/// One bot on the owner's dock: KemoSabe on the device, or one of the owner's bots (October 8, 2026, the owner: "the
/// dock should be KemoSabe plus agents, with the engines underneath"). An owner's bot is either made here, a character
/// on one of the owner's engines (an API model, a coding agent on a Mac, Apple on-device), or a service's own bot
/// brought in: the owner's ChatGPT dot, or an agent that signs in to the KemoSabe gateway (OpenClaw, Grok, Muse). A
/// brought-in bot runs nowhere here: it asks KemoSabe from where it lives, and its tile shows what it asked.
public struct BotSpec: Codable, Identifiable, Hashable, Sendable {
    /// KemoSabe's fixed ID, so its threads survive renaming it.
    public static let kemoSabeID = UUID(uuidString: "6B656D6F-5361-6265-0000-000000000001")!
    /// Tsukumo's Claude bot's fixed ID (Claude's bot in the fixed lineup of 2.05, so its chat and tasks stay).
    public static let claudeBotID = ServiceID.claude.botID
    public static let maxName = 40, maxRole = 90, maxInstructions = 2000

    public var id: UUID
    public var name: String
    public var engine: EngineID
    /// The engine's model ID; nil is the engine's default.
    public var model: String?
    /// The reasoning effort; nil is the model's default. Sent only to a model that accepts it.
    public var effort: Effort?
    /// The bot's job, one line ("Codes in my projects").
    public var role: String
    /// What the owner told it to be and do, beyond its job; it goes to its engine with every turn. Empty for none.
    public var instructions: String
    /// Made here, or brought in from a service.
    public var origin: BotOrigin
    /// The service it's from or runs on, for its mark and its page: a brought-in bot's service, or the service whose
    /// engine a made bot runs on. Nil for an engine that's no service's (Apple on-device, a custom server).
    public var service: ServiceID?
    /// KemoSabe's companion palette, or another bot's character (its pet).
    public var look: BotLook
    public var contextScope: ContextScope
    public var permissions: BotPermissions
    /// The voice it speaks with (a voice ID TsukumoVoice knows, such as "af_heart"); nil is the one picked
    /// for it from its ID, so bots sound different without anyone choosing. It syncs with the bot.
    public var voice: String?
    /// The Codex or Claude Code conversation it continues (the agent's own session ID), when it was made from one.
    /// It's locked to that conversation's engine and folder, where the session lives (the owner, October 8, 2026:
    /// "lock conversation to model").
    public var conversation: String?

    public init(id: UUID = UUID(), name: String, engine: EngineID, model: String? = nil, effort: Effort? = nil,
                role: String = "", instructions: String = "", origin: BotOrigin = .made, service: ServiceID? = nil,
                look: BotLook = .kemoSabe, contextScope: ContextScope = ContextScope(), permissions: BotPermissions = BotPermissions(),
                voice: String? = nil, conversation: String? = nil) {
        self.id = id; self.name = name; self.engine = engine; self.model = model; self.effort = effort
        self.role = role; self.instructions = instructions; self.origin = origin; self.service = service
        self.look = look; self.contextScope = contextScope; self.permissions = permissions
        self.voice = voice; self.conversation = conversation
    }

    public var isKemoSabe: Bool { id == Self.kemoSabeID }
    /// Whether it's a service's own bot, brought in (it never runs here).
    public var isBroughtIn: Bool { origin != .made }
    /// Whether it may wear one of the owner's Codex pets: it runs on Codex, or it's the owner's ChatGPT dot.
    public var wearsCodexPets: Bool {
        if case .dot = origin { return true }
        return service == .codex || engine == .codingAgent("codex")
    }
    /// Tsukumo's own Claude bot: its tile opens the Claude bot's panel (TsukumoClaude), not a chat.
    public var isClaudeBot: Bool { id == Self.claudeBotID }

    /// KemoSabe, the bot that is Apple's on-device model. It is always there and never removed, and it
    /// is always standard: its look, Apple on-device, its job, and its scope. Its companion palette (its
    /// two halves, or its cloud, recolored) is the one thing the owner changes.
    public static func kemoSabe(name: String = "KemoSabe", palette: String = BotLook.kemoSabe.palette, figure: KemoSabeLook? = nil) -> BotSpec {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxName))
        return BotSpec(id: kemoSabeID, name: trimmed.isEmpty ? "KemoSabe" : trimmed, engine: .appleOnDevice,
                       role: "Your secure assistant, on this device", look: .kemoSabe(palette: palette, figure: figure),
                       contextScope: ContextScope(ceiling: .deviceOnly, mayAskKemoSabe: false))
    }

    /// Tsukumo's Claude bot: background tasks on the owner's own Claude Code that ask KemoSabe through the gateway.
    public static func claudeBot(name: String = "Claude") -> BotSpec {
        BotSpec(id: claudeBotID, name: name, engine: .codingAgent("claude-code"), role: "Tsukumo’s Claude bot, on your Claude Code",
                service: .claude)
    }

    /// The figure KemoSabe shows: its cloud unless its owner picked the two-tone one.
    public var kemoSabeLook: KemoSabeLook { look.kemoSabeFigure }
    /// KemoSabe's companion palette (Apricot for any other bot).
    public var kemoSabePalette: BotPalette { isKemoSabe ? BotPalette.companion(palette: look.palette, accent: look.accentColor) : BotPalette.all[0] }

    /// This bot as it may be kept. KemoSabe goes back to standard, keeping only its name, its companion
    /// palette and figure, its voice, and whether it chirps (on a Mac); whatever an edit, a sync, or a newer build gave
    /// it, nothing else sticks. Every other bot gets a clean look and bounded instructions and voice, and a brought-in
    /// bot runs nothing here: its engine is its service's, which only asks KemoSabe.
    public func normalized() -> BotSpec {
        guard isKemoSabe else {
            var copy = self
            copy.look = look.normalized()
            copy.voice = Self.boundedVoice(voice)
            if copy.instructions.count > Self.maxInstructions { copy.instructions = String(copy.instructions.prefix(Self.maxInstructions)) }
            // A Codex pet is OpenAI's character: only a bot on Codex (or the owner's dot) wears one. Tsukumo's own
            // characters go on any bot.
            if !copy.wearsCodexPets, !BotLook.isTsukumoCharacter(copy.look.pet) { copy.look.pet = nil; copy.look.petName = nil; copy.look.petImage = nil }
            if isBroughtIn {
                copy.engine = .service((service ?? origin.service)?.rawValue ?? "agent")
                copy.model = nil; copy.effort = nil; copy.contextScope.project = nil
            }
            return copy
        }
        let kept = look.normalizedForKemoSabe()
        var standard = BotSpec.kemoSabe(name: name, palette: kept.palette, figure: kept.figure)
        standard.permissions.mayChirp = permissions.mayChirp
        standard.voice = Self.boundedVoice(voice)
        return standard
    }

    /// A voice ID kept as written (a newer build's voice stays), within a sane length.
    static func boundedVoice(_ voice: String?) -> String? {
        guard let voice = voice?.trimmingCharacters(in: .whitespacesAndNewlines), !voice.isEmpty, voice.count <= 64 else { return nil }
        return voice
    }

    /// A trimmed, bounded copy, or the problem to show. Its name is its own: no other bot (KemoSabe included) has it.
    public func validated(existing: [BotSpec] = []) -> Result<BotSpec, BotProblem> {
        var copy = self
        copy.name = copy.name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.role = copy.role.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.instructions = copy.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.model = copy.model.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        guard !copy.name.isEmpty else { return .failure(.init("Give it a name.")) }
        guard copy.name.count <= Self.maxName else { return .failure(.init("Keep the name under \(Self.maxName) characters.")) }
        guard copy.role.count <= Self.maxRole else { return .failure(.init("Keep its job to one line (\(Self.maxRole) characters).")) }
        guard copy.instructions.count <= Self.maxInstructions else {
            return .failure(.init("Keep what you tell it under \(Self.maxInstructions) characters."))
        }
        if existing.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(copy.name) == .orderedSame }) {
            return .failure(.init("Another bot is called \(copy.name). Pick another name."))
        }
        if case .unknown = copy.engine { return .failure(.init("Choose what it runs on.")) }
        return .success(copy.normalized())
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, engine, model, effort, role, instructions, origin, service, look, contextScope, permissions, voice, conversation
    }
    /// Fields a newer build added are ignored (and an older build's personality); fields an older build left out
    /// take their defaults: a bot saved before October 8, 2026 was made here, and a service bot of the fixed lineup
    /// keeps its service. A decoded KemoSabe is standard again (`normalized()`), whatever the file or another device said.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        engine = try c.decode(EngineID.self, forKey: .engine)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        effort = try c.decodeIfPresent(Effort.self, forKey: .effort)
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
        instructions = (try? c.decodeIfPresent(String.self, forKey: .instructions)) ?? ""
        origin = (try? c.decodeIfPresent(BotOrigin.self, forKey: .origin)) ?? .made
        let serviceName = (try? c.decodeIfPresent(String.self, forKey: .service)) ?? nil
        service = serviceName.flatMap(ServiceID.init(rawValue:)) ?? (serviceName == nil ? ServiceID(botID: id) : nil)
        look = (try? c.decodeIfPresent(BotLook.self, forKey: .look)) ?? .kemoSabe
        contextScope = (try? c.decodeIfPresent(ContextScope.self, forKey: .contextScope)) ?? ContextScope()
        permissions = (try? c.decodeIfPresent(BotPermissions.self, forKey: .permissions)) ?? BotPermissions()
        voice = (try? c.decodeIfPresent(String.self, forKey: .voice)) ?? nil
        conversation = (try? c.decodeIfPresent(String.self, forKey: .conversation)) ?? nil
        self = normalized()
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(engine, forKey: .engine)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(effort, forKey: .effort)
        try c.encode(role, forKey: .role)
        try c.encodeIfPresent(conversation, forKey: .conversation)
        if !instructions.isEmpty { try c.encode(instructions, forKey: .instructions) }
        try c.encode(origin, forKey: .origin)
        try c.encodeIfPresent(service?.rawValue, forKey: .service)
        try c.encode(look, forKey: .look)
        try c.encode(contextScope, forKey: .contextScope)
        try c.encode(permissions, forKey: .permissions)
        try c.encodeIfPresent(voice, forKey: .voice)
    }
}

/// Where one of the owner's bots came from.
public enum BotOrigin: Codable, Hashable, Sendable {
    /// Made here: a character on one of the owner's engines.
    case made
    /// The owner's ChatGPT dot (OpenAI's always-on agent in ChatGPT and Codex), by its ID; `thread` is its Codex
    /// conversation, which Tsukumo opens in Codex (another app can't message a dot).
    case dot(id: String, thread: String?)
    /// An agent that signs in to the KemoSabe gateway (OpenClaw, Grok, Claude's connector, a paired Muse), by its
    /// authenticated caller ID, never by the name it gives.
    case caller(id: String)

    /// The service a brought-in bot is from, when its kind says (a dot is OpenAI's).
    public var service: ServiceID? { if case .dot = self { .openAI } else { nil } }
    /// What it is, apart from where it opens: a dot by its ID alone.
    public var identity: BotOrigin { if case .dot(let id, _) = self { .dot(id: id, thread: nil) } else { self } }
    /// The gateway caller it is, when it's one.
    public var callerID: String? { if case .caller(let id) = self { id } else { nil } }

    private enum CodingKeys: String, CodingKey { case kind, id, thread }
    /// A kind a newer build added is read as made here, which runs only what its engine says.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? nil
        switch (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? nil {
        case "dot"?: self = id.map { .dot(id: $0, thread: (try? c.decodeIfPresent(String.self, forKey: .thread)) ?? nil) } ?? .made
        case "caller"?: self = id.map { .caller(id: $0) } ?? .made
        default: self = .made
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .made: try c.encode("made", forKey: .kind)
        case .dot(let id, let thread):
            try c.encode("dot", forKey: .kind); try c.encode(id, forKey: .id); try c.encodeIfPresent(thread, forKey: .thread)
        case .caller(let id): try c.encode("caller", forKey: .kind); try c.encode(id, forKey: .id)
        }
    }
}

/// What a bot may read: its project, how private an item it may be given, and whether it may ask
/// KemoSabe about the owner.
public struct ContextScope: Codable, Hashable, Sendable {
    /// A project folder it works in (coding agents on a Mac); nil chats without one.
    public var project: String?
    /// The most private level it may ever receive (Device only and Secret never reach an agent off
    /// the device, whatever this says; TsukumoPolicy decides that).
    public var ceiling: PrivacyLevel
    /// Whether it may ask KemoSabe questions about the owner.
    public var mayAskKemoSabe: Bool

    public init(project: String? = nil, ceiling: PrivacyLevel = .personal, mayAskKemoSabe: Bool = true) {
        self.project = project; self.ceiling = ceiling; self.mayAskKemoSabe = mayAskKemoSabe
    }

    private enum CodingKeys: String, CodingKey { case project, ceiling, mayAskKemoSabe }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        project = try c.decodeIfPresent(String.self, forKey: .project)
        ceiling = try c.decodeIfPresent(PrivacyLevel.self, forKey: .ceiling) ?? .personal
        mayAskKemoSabe = try c.decodeIfPresent(Bool.self, forKey: .mayAskKemoSabe) ?? true
    }
}

/// What a bot may do on its own.
public struct BotPermissions: Codable, Hashable, Sendable {
    /// What a coding agent may do in its project.
    public enum Access: String, Codable, CaseIterable, Identifiable, Sendable {
        case readOnly, askFirst, autoEdit, full
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .readOnly: "Read only"
            case .askFirst: "Ask first"
            case .autoEdit: "Auto-edit"
            case .full: "Full access"
            }
        }
        public var detail: String {
            switch self {
            case .readOnly: "Reads and plans; changes nothing."
            case .askFirst: "Asks before editing files or running commands."
            case .autoEdit: "Edits files in its project; asks before commands."
            case .full: "Edits and runs commands without asking."
            }
        }
        /// An access a newer build added is read as the safest one.
        public init(from decoder: Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .readOnly
        }
    }

    public var access: Access
    /// Its approvals can be answered where the bot lives (the dock, the chat).
    public var approvalsHere: Bool
    /// It may speak up on its own.
    public var mayChirp: Bool
    /// Its replies may be read aloud.
    public var speaks: Bool

    /// A new bot is read only until the owner says otherwise.
    public init(access: Access = .readOnly, approvalsHere: Bool = true, mayChirp: Bool = true, speaks: Bool = true) {
        self.access = access; self.approvalsHere = approvalsHere; self.mayChirp = mayChirp; self.speaks = speaks
    }

    private enum CodingKeys: String, CodingKey { case access, approvalsHere, mayChirp, speaks }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        access = try c.decodeIfPresent(Access.self, forKey: .access) ?? .readOnly
        approvalsHere = try c.decodeIfPresent(Bool.self, forKey: .approvalsHere) ?? true
        mayChirp = try c.decodeIfPresent(Bool.self, forKey: .mayChirp) ?? true
        speaks = try c.decodeIfPresent(Bool.self, forKey: .speaks) ?? true
    }
}

/// The model new bots started on before the fixed lineup (October 7, 2026). Nothing sets it any more; it is
/// kept so a library from an older build still syncs whole. It never holds a key.
public struct DefaultModel: Codable, Hashable, Sendable {
    public var engine: EngineID
    /// The engine's model ID; nil is the engine's default.
    public var model: String?
    public init(engine: EngineID, model: String? = nil) { self.engine = engine; self.model = model }
}

/// Why a bot can't be saved, in the words to show.
public struct BotProblem: Error, Hashable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

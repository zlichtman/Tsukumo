import Foundation

/// One bot, whatever runs it: KemoSabe on the device, an API model, or a coding agent on a Mac.
/// (Before the rebuild these were three shapes: a dock agent, an API profile, and a coding agent.)
public struct BotSpec: Codable, Identifiable, Hashable, Sendable {
    /// KemoSabe's fixed ID, so its threads survive renaming it.
    public static let kemoSabeID = UUID(uuidString: "6B656D6F-5361-6265-0000-000000000001")!
    public static let maxName = 40, maxRole = 90

    public var id: UUID
    public var name: String
    public var engine: EngineID
    /// The engine's model ID; nil is the engine's default.
    public var model: String?
    /// The reasoning effort; nil is the model's default. Sent only to a model that accepts it.
    public var effort: Effort?
    /// The bot's job, one line ("Codes in my projects").
    public var role: String
    public var look: BotLook
    /// How it talks: a tone and the owner's own words.
    public var personality: BotPersonality
    public var contextScope: ContextScope
    public var permissions: BotPermissions

    public init(id: UUID = UUID(), name: String, engine: EngineID, model: String? = nil, effort: Effort? = nil,
                role: String = "", look: BotLook, personality: BotPersonality = BotPersonality(),
                contextScope: ContextScope = ContextScope(), permissions: BotPermissions = BotPermissions()) {
        self.id = id; self.name = name; self.engine = engine; self.model = model; self.effort = effort
        self.role = role; self.look = look; self.personality = personality; self.contextScope = contextScope; self.permissions = permissions
    }

    public var isKemoSabe: Bool { id == Self.kemoSabeID }

    /// KemoSabe, the bot that is Apple's on-device model. It is always there and never removed, and it
    /// is always standard: its cloud, Apple on-device, its job, and its scope. Its color is the one thing
    /// the owner changes (`tint`).
    public static func kemoSabe(name: String = "KemoSabe", tint: String? = nil) -> BotSpec {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxName))
        return BotSpec(id: kemoSabeID, name: trimmed.isEmpty ? "KemoSabe" : trimmed, engine: .appleOnDevice,
                       role: "Your secure assistant, on this device", look: .kemoSabe(tint: tint),
                       contextScope: ContextScope(ceiling: .deviceOnly, mayAskKemoSabe: false))
    }

    /// KemoSabe's color, when the owner picked one (nil is coral).
    public var kemoSabeTint: String? { isKemoSabe ? look.accentColor : nil }

    /// This bot as it may be kept. KemoSabe goes back to standard, keeping only its name, its color,
    /// and whether it chirps (on a Mac); whatever an edit, a sync, or a newer build gave it, nothing else
    /// sticks. Every other bot gets a clean look and a bounded personality.
    public func normalized() -> BotSpec {
        guard isKemoSabe else {
            var copy = self
            copy.look = look.normalized()
            copy.personality = personality.normalized()
            return copy
        }
        var standard = BotSpec.kemoSabe(name: name, tint: look.accentColor)
        standard.permissions.mayChirp = permissions.mayChirp
        return standard
    }

    /// A new bot: a fun name no other bot has and a character unlike theirs. The engine comes first in
    /// the add-bot sheet, so it's given here.
    public static func new(engine: EngineID, starter: BotStarter = .custom, existing: [BotSpec],
                           using rng: inout some RandomNumberGenerator) -> BotSpec {
        BotSpec(name: BotNames.next(taken: existing.map(\.name), using: &rng), engine: engine, role: starter.role,
                look: .random(for: starter, taken: existing.map(\.look), using: &rng))
    }

    /// A trimmed, bounded copy, or the problem to show.
    public func validated(existing: [BotSpec] = []) -> Result<BotSpec, BotProblem> {
        var copy = normalized()
        copy.name = copy.name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.role = copy.role.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.model = copy.model.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        guard !copy.name.isEmpty else { return .failure(.init("Give it a name.")) }
        guard copy.name.count <= Self.maxName else { return .failure(.init("Keep the name under \(Self.maxName) characters.")) }
        guard copy.role.count <= Self.maxRole else { return .failure(.init("Keep its job to one line (\(Self.maxRole) characters).")) }
        if existing.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(copy.name) == .orderedSame }) {
            return .failure(.init("Another bot is called \(copy.name). Pick another name."))
        }
        if case .unknown = copy.engine { return .failure(.init("Choose what it runs on.")) }
        return .success(copy)
    }

    private enum CodingKeys: String, CodingKey { case id, name, engine, model, effort, role, look, personality, contextScope, permissions }
    /// Fields a newer build added are ignored; fields an older build left out take their defaults. A
    /// decoded KemoSabe is standard again (`normalized()`), whatever the file or another device said.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        engine = try c.decode(EngineID.self, forKey: .engine)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        effort = try c.decodeIfPresent(Effort.self, forKey: .effort)
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
        look = (try? c.decodeIfPresent(BotLook.self, forKey: .look)) ?? .kemoSabe
        personality = (try? c.decodeIfPresent(BotPersonality.self, forKey: .personality)) ?? BotPersonality()
        contextScope = (try? c.decodeIfPresent(ContextScope.self, forKey: .contextScope)) ?? ContextScope()
        permissions = (try? c.decodeIfPresent(BotPermissions.self, forKey: .permissions)) ?? BotPermissions()
        self = normalized()
    }
}

/// How a bot talks: a tone, and the owner's own instructions on top.
public struct BotPersonality: Codable, Hashable, Sendable {
    public static let maxInstructions = 600

    public enum Tone: String, CaseIterable, Codable, Identifiable, Sendable {
        case friendly, playful, concise, thorough, formal, coach
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .friendly: "Friendly"
            case .playful: "Playful"
            case .concise: "Concise"
            case .thorough: "Thorough"
            case .formal: "Formal"
            case .coach: "Coach"
            }
        }
        /// One line for pickers.
        public var detail: String {
            switch self {
            case .friendly: "Warm and plain-spoken."
            case .playful: "Light, upbeat, a little silly."
            case .concise: "Short answers, no extra words."
            case .thorough: "Explains its thinking and the details."
            case .formal: "Polished and professional."
            case .coach: "Encouraging, and asks what's next."
            }
        }
        /// What the bot is told.
        public var prompt: String {
            switch self {
            case .friendly: "Be warm and plain-spoken, in short sentences."
            case .playful: "Be light and upbeat, with a little humor, and still useful."
            case .concise: "Answer in as few words as will do. No preamble."
            case .thorough: "Explain your reasoning and the details that matter, in clear steps."
            case .formal: "Be polished and professional."
            case .coach: "Be encouraging, break things into next steps, and end with one question that moves the owner forward."
            }
        }
        /// A tone a newer build added reads as friendly.
        public init(from decoder: Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .friendly
        }
    }

    public var tone: Tone
    /// The owner's own words for how it should behave ("Call me Sam. Use metric units.").
    public var instructions: String

    public init(tone: Tone = .friendly, instructions: String = "") { self.tone = tone; self.instructions = instructions }

    /// Trimmed and bounded.
    public func normalized() -> BotPersonality {
        BotPersonality(tone: tone, instructions: String(instructions.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxInstructions)))
    }

    /// The lines a bot's instructions get from its personality.
    public var prompt: String {
        let own = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return own.isEmpty ? tone.prompt : tone.prompt + " The owner asks: " + own
    }

    private enum CodingKeys: String, CodingKey { case tone, instructions }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tone = (try? c.decodeIfPresent(Tone.self, forKey: .tone)).flatMap { $0 } ?? .friendly
        instructions = (try? c.decodeIfPresent(String.self, forKey: .instructions)).flatMap { $0 } ?? ""
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

/// A starting point for a new bot's job: a few starters, or the owner's own words.
public enum BotStarter: String, CaseIterable, Codable, Identifiable, Sendable {
    case coder, researcher, homework, errands, custom
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .coder: "Coder"
        case .researcher: "Researcher"
        case .homework: "Homework"
        case .errands: "Errands"
        case .custom: "Custom"
        }
    }
    /// The job line a bot of this kind starts with.
    public var role: String {
        switch self {
        case .coder: "Codes in my projects"
        case .researcher: "Reads and sums things up for me"
        case .homework: "Keeps my classes and deadlines on track"
        case .errands: "Keeps my errands and reminders moving"
        case .custom: ""
        }
    }
    /// Props that suit it, one picked at random for its character.
    public var props: [BotLook.Prop] {
        switch self {
        case .coder: [.hardHat, .wrench, .antenna]
        case .researcher: [.glasses, .book]
        case .homework: [.pencil, .book]
        case .errands: [.headset, .none]
        case .custom: BotLook.Prop.allCases
        }
    }
}

/// The three bots a first run (and a new dock) offers to start from: a name, a job, and a character to
/// change or keep. On a Mac they start on coding agents; on iPhone the app picks an engine it has.
public struct StarterBot: Identifiable, Hashable, Sendable {
    public let title: String
    public let name: String
    public let role: String
    /// What it runs on, on a Mac.
    public let engine: EngineID
    public let kind: BotStarter
    public var id: String { title }

    public static let all: [StarterBot] = [
        StarterBot(title: "Homework helper", name: "Homework", role: "Tracks my class deadlines", engine: .codingAgent("claude-code"), kind: .homework),
        StarterBot(title: "Project coder", name: "Project coder", role: "Codes in one of my projects", engine: .codingAgent("codex"), kind: .coder),
        StarterBot(title: "Research reader", name: "Research", role: "Reads and sums up papers for me", engine: .codingAgent("claude-code"), kind: .researcher)
    ]

    /// Its character, before any other bot is taken into account.
    public var look: BotLook { .suggested(name: name, job: role) }

    /// A bot from this starter, with a character unlike the others, on `engine` (its Mac engine by default).
    public func bot(existing: [BotSpec], id: UUID = UUID(), engine: EngineID? = nil) -> BotSpec {
        var bot = BotSpec(id: id, name: name, engine: engine ?? self.engine, role: role,
                          look: .suggested(name: name, job: role, taken: existing.map(\.look)))
        if kind == .coder { bot.permissions.access = .askFirst }
        if kind == .homework { bot.personality.tone = .coach }
        if kind == .researcher { bot.personality.tone = .thorough }
        return bot
    }
}

/// The model new bots start on, and the one chats use when nothing else is chosen. It syncs, so every
/// device starts new bots the same way. It never holds a key.
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

import Foundation

/// What runs a bot. Saved as one string ("apple-on-device", "api:<profile UUID>",
/// "coding:claude-code", "acp:<id>", "mlx:<model>"), so an engine a newer build added decodes as
/// `.unknown` and survives a round trip instead of failing the whole bot.
public enum EngineID: Hashable, Codable, Sendable, CustomStringConvertible {
    /// Apple's on-device model: KemoSabe. Nothing leaves the device.
    case appleOnDevice
    /// A connected API model (Anthropic, OpenAI, or a compatible server), by its connection profile.
    case api(profile: UUID)
    /// A coding agent CLI on a Mac, by its adapter ("claude-code", "codex", "muse", "cursor-agent").
    case codingAgent(String)
    /// Any agent reached over the Agent Client Protocol.
    case acp(String)
    /// A local open-weight model (later).
    case mlx(String)
    /// Written by a newer build; kept as written.
    case unknown(String)

    public var key: String {
        switch self {
        case .appleOnDevice: "apple-on-device"
        case .api(let profile): "api:" + profile.uuidString
        case .codingAgent(let id): "coding:" + id
        case .acp(let id): "acp:" + id
        case .mlx(let model): "mlx:" + model
        case .unknown(let raw): raw
        }
    }
    public var description: String { key }

    public init(key: String) {
        func rest(_ prefix: String) -> String? { key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : nil }
        if key == "apple-on-device" { self = .appleOnDevice }
        else if let id = rest("api:"), let uuid = UUID(uuidString: id) { self = .api(profile: uuid) }
        else if let id = rest("coding:"), !id.isEmpty { self = .codingAgent(id) }
        else if let id = rest("acp:"), !id.isEmpty { self = .acp(id) }
        else if let model = rest("mlx:"), !model.isEmpty { self = .mlx(model) }
        else { self = .unknown(key) }
    }
    public init(from decoder: Decoder) throws { self.init(key: try decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(key) }

    /// Coding agents and ACP agents run only on a Mac.
    public var runsOnlyOnMac: Bool {
        switch self {
        case .codingAgent, .acp: true
        default: false
        }
    }
    /// Whether this engine keeps every word on the device.
    public var isOnDevice: Bool {
        switch self {
        case .appleOnDevice, .mlx: true
        default: false
        }
    }
}

/// A reasoning effort in the provider's own words ("low", "high", "xhigh", "moderate"). Which ones a
/// model accepts is `EffortCatalog`'s job; an effort a model doesn't take is never sent.
public struct Effort: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public var description: String { rawValue }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}

/// Which reasoning efforts a model really accepts, lightest first (ported from `ModelEffortCatalog`).
///
/// - Claude (Messages API, `output_config.effort`): Opus 4.5 takes low/medium/high; Opus 4.6 and
///   Sonnet 4.6 add max; Opus 4.7 and later, Sonnet 5, and the Fable and Mythos models add xhigh.
///   Haiku and older models take none.
/// - OpenAI (`reasoning_effort` on chat/completions at api.openai.com): the reasoning models only.
///   Other OpenAI-compatible servers never get it.
/// - Apple: light, moderate, deep, only when the model reports it can reason.
public enum EffortCatalog {
    public enum Wire: String, Codable, Sendable { case anthropic, openAI, openAICompatible, apple }

    public static let claudeFull: [Effort] = ["low", "medium", "high", "xhigh", "max"]
    public static let appleLevels: [Effort] = ["light", "moderate", "deep"]

    /// The efforts `model` accepts over `wire`; empty when it takes none.
    public static func efforts(wire: Wire, model: String, appleCanReason: Bool = false) -> [Effort] {
        switch wire {
        case .anthropic: claude(model)
        case .openAI: openAI(model)
        case .openAICompatible: []
        case .apple: appleCanReason ? appleLevels : []
        }
    }
    /// The effort the model uses when none is chosen, when it's documented.
    public static func defaultEffort(wire: Wire, model: String) -> Effort? {
        let efforts = efforts(wire: wire, model: model)
        guard !efforts.isEmpty else { return nil }
        switch wire {
        case .anthropic: return model.lowercased().hasPrefix("claude-opus-5-5") ? "medium" : "high"
        case .openAI: return efforts.contains("none") ? "none" : "medium"
        case .openAICompatible, .apple: return nil
        }
    }
    /// `effort` when the model accepts it; otherwise nil (the model's default).
    public static func accepted(_ effort: Effort?, wire: Wire, model: String) -> Effort? {
        guard let effort, efforts(wire: wire, model: model).contains(effort) else { return nil }
        return effort
    }

    /// Claude model IDs: `claude-<family>-<major>[-<minor>][-<date>]`.
    public static func claude(_ model: String) -> [Effort] {
        let parts = model.lowercased().split(separator: "-").map(String.init)
        guard parts.count >= 3, parts[0] == "claude", let major = Int(parts[2]) else { return [] }
        // A date suffix ("20250514") is not a minor version.
        let minor = parts.count > 3 ? (Int(parts[3]).flatMap { $0 < 100 ? $0 : nil } ?? 0) : 0
        let version = major * 100 + minor
        switch parts[1] {
        case "fable", "mythos": return claudeFull
        case "opus":
            if version >= 407 { return claudeFull }
            if version == 406 { return ["low", "medium", "high", "max"] }
            if version == 405 { return ["low", "medium", "high"] }
            return []
        case "sonnet":
            if version >= 500 { return claudeFull }
            if version == 406 { return ["low", "medium", "high", "max"] }
            return []
        default: return []
        }
    }

    /// OpenAI model IDs that take `reasoning_effort` on chat/completions.
    public static func openAI(_ model: String) -> [Effort] {
        let id = model.lowercased()
        if id.contains("-chat") || id.contains("audio") || id.contains("realtime") { return [] }
        if id.hasPrefix("o1-mini") || id.hasPrefix("o1-preview") { return [] }
        if id == "o1" || id.hasPrefix("o1-") || id.hasPrefix("o3") || id.hasPrefix("o4-mini") { return ["low", "medium", "high"] }
        guard id.hasPrefix("gpt-5") else { return [] }
        let rest = id.dropFirst("gpt-5".count)
        guard rest.hasPrefix(".") else {
            return id.contains("codex") ? ["low", "medium", "high"] : ["minimal", "low", "medium", "high"]
        }
        let minor = Int(rest.dropFirst().prefix { $0.isNumber }) ?? 0
        if id.contains("codex") { return minor >= 2 ? ["low", "medium", "high", "xhigh"] : ["low", "medium", "high"] }
        return minor >= 2 ? ["none", "low", "medium", "high", "xhigh"] : ["none", "low", "medium", "high"]
    }
}

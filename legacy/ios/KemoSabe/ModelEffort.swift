import Foundation
import FoundationModels

/// Which reasoning efforts a chat model really accepts, in the provider's own words, lightest first
/// (the owner's instruction, September 26, 2026). A model that takes none shows only the model list,
/// and an effort is saved per model profile (`SavedState.modelEfforts`) and sent only to that model:
///
/// - Claude (Messages API): `output_config.effort`, on the models that document it. Opus 4.5 takes
///   low/medium/high; Opus 4.6 and Sonnet 4.6 add max; Opus 4.7 and later, Sonnet 5, and the Fable
///   and Mythos models add xhigh. Haiku and older models take none, and sending it would fail.
/// - OpenAI (chat/completions at api.openai.com, which is what `CompatibleAPIModel` speaks):
///   `reasoning_effort`, on the reasoning models only (o1, o3, o4-mini, and the GPT-5 family except
///   its chat models). Other OpenAI-compatible servers (Ollama, LM Studio, "Other") never get it.
/// - Apple: FoundationModels' `ContextOptions.reasoningLevel` (light, moderate, deep) on iOS and
///   macOS 27, only when the model reports the `.reasoning` capability (`AppleReasoning`).
enum ModelEffortCatalog {
    static let claudeFull = ["low", "medium", "high", "xhigh", "max"]

    /// The efforts a connected model accepts; empty when it takes none.
    static func efforts(for profile: APIModelProfile) -> [String] {
        switch profile.wire {
        case .anthropic: claude(profile.model)
        case .openAICompatible: profile.endpoint.host?.lowercased() == "api.openai.com" ? openAI(profile.model) : []
        }
    }
    /// The effort the model uses when none is chosen, when it's documented (for the slider's heat).
    static func defaultEffort(for profile: APIModelProfile) -> String? {
        let efforts = efforts(for: profile)
        guard !efforts.isEmpty else { return nil }
        switch profile.wire {
        case .anthropic:
            // Claude Opus 5.5 defaults to medium; the others to high.
            return profile.model.lowercased().hasPrefix("claude-opus-5-5") ? "medium" : "high"
        case .openAICompatible:
            return efforts.contains("none") ? "none" : "medium"
        }
    }
    /// The saved effort for a model, only when that model accepts it; otherwise nil (its default).
    static func accepted(_ effort: String?, for profile: APIModelProfile) -> String? {
        guard let effort, efforts(for: profile).contains(effort) else { return nil }
        return effort
    }

    /// Claude model IDs: `claude-<family>-<major>[-<minor>][-<date>]`.
    static func claude(_ model: String) -> [String] {
        let parts = model.lowercased().split(separator: "-").map(String.init)
        guard parts.count >= 3, parts[0] == "claude" else { return [] }
        let family = parts[1]
        guard let major = Int(parts[2]) else { return [] }
        // A date suffix ("20250514") is not a minor version.
        let minor = parts.count > 3 ? (Int(parts[3]).flatMap { $0 < 100 ? $0 : nil } ?? 0) : 0
        let version = major * 100 + minor
        switch family {
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
    static func openAI(_ model: String) -> [String] {
        let id = model.lowercased()
        // Chat-tuned snapshots aren't reasoning models.
        if id.contains("-chat") || id.contains("audio") || id.contains("realtime") { return [] }
        if id.hasPrefix("o1-mini") || id.hasPrefix("o1-preview") { return [] }
        if id == "o1" || id.hasPrefix("o1-") || id.hasPrefix("o3") || id.hasPrefix("o4-mini") { return ["low", "medium", "high"] }
        guard id.hasPrefix("gpt-5") else { return [] }
        let rest = id.dropFirst("gpt-5".count)
        // "gpt-5", "gpt-5-mini", "gpt-5-nano", "gpt-5-2025-08-07": minimal through high.
        guard rest.hasPrefix(".") else {
            return id.contains("codex") ? ["low", "medium", "high"] : ["minimal", "low", "medium", "high"]
        }
        let minor = Int(rest.dropFirst().prefix { $0.isNumber }) ?? 0
        if id.contains("codex") { return minor >= 2 ? ["low", "medium", "high", "xhigh"] : ["low", "medium", "high"] }
        // GPT-5.1 added "none"; GPT-5.2 and later added "xhigh".
        return minor >= 2 ? ["none", "low", "medium", "high", "xhigh"] : ["none", "low", "medium", "high"]
    }
}

/// Apple's reasoning levels, offered only when the model reports it can reason.
enum AppleReasoning {
    static let levels = ["light", "moderate", "deep"]
    /// Whether this Apple model takes a reasoning level on this system.
    static func supported(_ model: AppleModel) -> Bool {
        guard #available(iOS 27, macOS 27, *) else { return false }
        switch model {
        case .onDevice: return SystemLanguageModel.default.capabilities.contains(.reasoning)
        case .privateCloud: return PrivateCloudBuild.enabled && PrivateCloudComputeLanguageModel().capabilities.contains(.reasoning)
        }
    }
    /// The context options carrying a saved level; the default options when there is none.
    @available(iOS 27, macOS 27, *)
    static func options(_ level: String?) -> ContextOptions {
        switch level {
        case "light": ContextOptions(reasoningLevel: .light)
        case "moderate": ContextOptions(reasoningLevel: .moderate)
        case "deep": ContextOptions(reasoningLevel: .deep)
        default: ContextOptions()
        }
    }
}

/// The effort chosen for each model, saved by model profile: a connected model's ID, or
/// `apple-onDevice` / `apple-privateCloud`.
enum ModelEffortKey {
    static func api(_ id: UUID) -> String { id.uuidString }
    static func apple(_ model: AppleModel) -> String { "apple-" + model.rawValue }
}

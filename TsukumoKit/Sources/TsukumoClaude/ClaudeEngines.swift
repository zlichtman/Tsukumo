#if os(macOS)
import Foundation
import TsukumoCore
import TsukumoEngines
import TsukumoUI

// Which Claude the bot runs on: the owner's own Claude Code (headless, on their own sign-in, through the existing
// `ClaudeCodeBackend` and `CodingAgentEngine`) first, else their Anthropic API key (the existing `APIEngine` over
// the Messages API, the connection Settings, Models keeps). Nothing here talks to Anthropic itself.

/// What a run is on.
public enum ClaudeEngineKind: String, Codable, Hashable, Sendable {
    case claudeCode, apiKey
    public init(from decoder: Decoder) throws { self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .apiKey }
}

/// What the owner prefers.
public enum ClaudeEnginePreference: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    /// Claude Code when it's on this Mac, else the API key.
    case automatic
    case claudeCode
    case apiKey
    public var id: String { rawValue }
    public init(from decoder: Decoder) throws { self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .automatic }
    public var title: String {
        switch self {
        case .automatic: "Automatic"
        case .claudeCode: "Claude Code"
        case .apiKey: "API key"
        }
    }
}

/// Claude Code on this Mac, as the coding agent catalog found it.
public struct ClaudeCodeInfo: Hashable, Sendable {
    public var version: String?
    public var models: [CodingAgentModel]
    public init(version: String? = nil, models: [CodingAgentModel] = ClaudeCode.fallbackModels) { self.version = version; self.models = models }
}

/// The owner's Claude connection with a key saved on this Mac.
public struct ClaudeAPIInfo: Hashable, Sendable {
    public var connection: APIConnection
    /// Its model list from `ModelCatalog`, newest first (empty until fetched).
    public var models: [String]
    public init(connection: APIConnection, models: [String] = []) { self.connection = connection; self.models = models }
}

/// Which Claudes this Mac has right now.
public struct ClaudeEngineAvailability: Hashable, Sendable {
    public var claudeCode: ClaudeCodeInfo?
    public var api: ClaudeAPIInfo?
    public init(claudeCode: ClaudeCodeInfo? = nil, api: ClaudeAPIInfo? = nil) { self.claudeCode = claudeCode; self.api = api }
    public static let none = ClaudeEngineAvailability()
}

public enum ClaudeEngineSelection {
    /// Claude Code first, then the API key; an explicit choice never quietly becomes the other.
    public static func choose(_ preference: ClaudeEnginePreference, _ availability: ClaudeEngineAvailability) -> ClaudeEngineKind? {
        switch preference {
        case .automatic: availability.claudeCode != nil ? .claudeCode : availability.api != nil ? .apiKey : nil
        case .claudeCode: availability.claudeCode != nil ? .claudeCode : nil
        case .apiKey: availability.api != nil ? .apiKey : nil
        }
    }

    /// Whether, on automatic, a Claude Code run that failed at its sign-in may be tried again on the API key.
    public static func mayFallBack(_ preference: ClaudeEnginePreference, _ availability: ClaudeEngineAvailability, after error: Error) -> Bool {
        guard preference == .automatic, availability.api != nil else { return false }
        return signInProblem(error.localizedDescription)
    }
    static func signInProblem(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return ["sign in", "signed in", "log in", "logged in", "login", "oauth", "authenticat", "unauthorized"].contains { lowered.contains($0) }
    }

    /// The words Settings and the panel show for what Claude runs on now.
    public static func describe(_ preference: ClaudeEnginePreference, _ availability: ClaudeEngineAvailability, settings: ClaudeBotSettings) -> String {
        switch choose(preference, availability) {
        case .claudeCode:
            let version = availability.claudeCode?.version.map { " " + $0 } ?? ""
            return "Runs on Claude Code\(version), on your own sign-in."
        case .apiKey:
            return "Runs on your Claude API key (\(model(.apiKey, availability: availability, settings: settings) ?? settings.apiModel))."
        case nil:
            switch preference {
            case .claudeCode: return "Claude Code isn’t on this Mac. Install it and sign in (run claude in Terminal), or choose Automatic."
            case .apiKey: return "No Claude API key on this Mac. Add one in Settings, Models."
            case .automatic: return "Claude isn’t set up on this Mac. Install Claude Code and sign in, or add a Claude API key in Settings, Models."
            }
        }
    }

    /// The model a run uses: the owner's choice when the engine offers it, else the engine's default.
    public static func model(_ kind: ClaudeEngineKind, availability: ClaudeEngineAvailability, settings: ClaudeBotSettings) -> String? {
        switch kind {
        case .claudeCode:
            guard let chosen = settings.codeModel, !chosen.isEmpty else { return nil }
            return chosen
        case .apiKey:
            let offered = availability.api?.models ?? []
            if offered.isEmpty || offered.contains(settings.apiModel) { return settings.apiModel }
            return offered.contains(ClaudeBotSettings.defaultAPIModel) ? ClaudeBotSettings.defaultAPIModel : offered.first
        }
    }
}

/// What the app gives the Claude bot to run on: what's available now, Claude Code's backend, and an API engine for
/// a connection. Tests pass fakes; the Mac app passes `ClaudeEngineHost.mac(…)`.
public struct ClaudeEngineHost: Sendable {
    public var availability: @Sendable () -> ClaudeEngineAvailability
    public var claudeCode: @Sendable () -> (any CodingAgentBackend)?
    public var api: @Sendable (APIConnection) -> any Engine

    public init(availability: @escaping @Sendable () -> ClaudeEngineAvailability, claudeCode: @escaping @Sendable () -> (any CodingAgentBackend)?,
                api: @escaping @Sendable (APIConnection) -> any Engine) {
        self.availability = availability; self.claudeCode = claudeCode; self.api = api
    }

    /// No Claude at all (previews, the demo).
    public static let unavailable = ClaudeEngineHost(availability: { .none }, claudeCode: { nil }, api: { connection in APIEngine(connection: connection, keys: MemoryAPIKeys()) })

    /// The Mac app's: Claude Code from the coding agent catalog, and the first Claude (Anthropic) connection with a key in
    /// this Mac's Keychain.
    public static func mac(catalog: CodingAgentCatalog, connections: @escaping @Sendable () -> [ConnectionRecord], keys: any APIKeyStore) -> ClaudeEngineHost {
        ClaudeEngineHost(
            availability: {
                let code = catalog.agent(for: CodingAgentKind.claudeCode.engine).map { ClaudeCodeInfo(version: $0.version, models: $0.models) }
                let api = connections().first { record in
                    record.provider == .anthropic && ((try? keys.read(record.id)) ?? nil).map { !$0.isEmpty } == true
                }.map { ClaudeAPIInfo(connection: $0.connection, models: $0.models) }
                return ClaudeEngineAvailability(claudeCode: code, api: api)
            },
            claudeCode: { catalog.backend(for: CodingAgentKind.claudeCode.engine) },
            api: { connection in APIEngine(connection: connection, keys: keys) })
    }
}
#endif

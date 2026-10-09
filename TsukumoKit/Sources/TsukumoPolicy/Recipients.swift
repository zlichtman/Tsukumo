import Foundation
import TsukumoCore

/// Where a recipient runs, which decides what it may read without the owner's say-so.
public enum RecipientLocality: String, Codable, Sendable {
    /// On this device: Apple's on-device model, a local model (Core ML, MLX).
    case onDevice
    /// Apple's servers: Private Cloud Compute, and the owner's own private iCloud database.
    case appleCloud
    /// Anywhere else: another company's model or agent, a hosted decision service.
    case thirdPartyCloud
}

/// Every recipient of context, named once. Each has its own grants: being selected or installed
/// never grants anything.
public enum RecipientID: Hashable, Codable, Sendable, CustomStringConvertible {
    case appleOnDevice
    case applePrivateCloud
    /// A connected API model. Its endpoint is fixed when it's added, so the profile names it.
    case apiModel(profile: UUID, host: String)
    /// A coding agent on a Mac, by its adapter ("claude-code", "codex").
    case codingAgent(String)
    /// An agent reached over the Agent Client Protocol, by the identity it runs as.
    case acpAgent(String)
    /// Another company's agent, by the identity it presents.
    case externalAgent(String)
    /// A model that runs on this device other than Apple's: MLX, or Laya in Core ML.
    case localModel(String)
    /// The owner's own private iCloud database (every field encrypted). Storage, not a reader.
    case iCloudSync
    /// A hosted System One decision service ("jev").
    case systemOne(String)

    public var locality: RecipientLocality {
        switch self {
        case .appleOnDevice, .localModel: .onDevice
        case .applePrivateCloud, .iCloudSync: .appleCloud
        case .apiModel, .codingAgent, .acpAgent, .externalAgent, .systemOne: .thirdPartyCloud
        }
    }

    /// Where its reads go, in words the owner can check.
    public var host: String {
        switch self {
        case .appleOnDevice, .localModel: "this device"
        case .applePrivateCloud: "Apple Private Cloud Compute"
        case .apiModel(_, let host): host
        case .codingAgent(let id), .acpAgent(let id), .externalAgent(let id), .systemOne(let id): id
        case .iCloudSync: "your private iCloud"
        }
    }

    /// A stable string for saved grants and journals. A connected model is keyed by its profile alone.
    public var key: String {
        switch self {
        case .appleOnDevice: "apple-on-device"
        case .applePrivateCloud: "apple-private-cloud"
        case .apiModel(let profile, let host): "api:" + profile.uuidString + "@" + host
        case .codingAgent(let id): "coding:" + id
        case .acpAgent(let id): "acp:" + id
        case .externalAgent(let id): "agent:" + id
        case .localModel(let id): "local:" + id
        case .iCloudSync: "icloud-sync"
        case .systemOne(let id): "system-one:" + id
        }
    }
    /// The part of the key a grant matches: an API model by its profile, whatever its host.
    public var grantKey: String {
        if case .apiModel(let profile, _) = self { return "api:" + profile.uuidString }
        return key
    }
    public var description: String { key }

    /// A recipient from its key, or nil for one this build doesn't know.
    public init?(key: String) {
        func rest(_ prefix: String) -> String? {
            guard key.hasPrefix(prefix) else { return nil }
            let value = String(key.dropFirst(prefix.count))
            return value.isEmpty ? nil : value
        }
        switch key {
        case "apple-on-device": self = .appleOnDevice
        case "apple-private-cloud": self = .applePrivateCloud
        case "icloud-sync": self = .iCloudSync
        default:
            if let value = rest("api:") {
                let pieces = value.split(separator: "@", maxSplits: 1).map(String.init)
                guard let profile = UUID(uuidString: pieces[0]) else { return nil }
                self = .apiModel(profile: profile, host: pieces.count > 1 ? pieces[1] : "")
            }
            else if let id = rest("coding:") { self = .codingAgent(id) }
            else if let id = rest("acp:") { self = .acpAgent(id) }
            else if let id = rest("agent:") { self = .externalAgent(id) }
            else if let id = rest("local:") { self = .localModel(id) }
            else if let id = rest("system-one:") { self = .systemOne(id) }
            else { return nil }
        }
    }
    public init(from decoder: Decoder) throws {
        let key = try decoder.singleValueContainer().decode(String.self)
        guard let recipient = RecipientID(key: key) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown recipient \(key)"))
        }
        self = recipient
    }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(key) }

    /// The recipient a bot's engine sends to. Nil for an engine this build doesn't know.
    public static func engine(_ engine: EngineID, apiHost: String = "") -> RecipientID? {
        switch engine {
        case .appleOnDevice: .appleOnDevice
        case .api(let profile): .apiModel(profile: profile, host: apiHost)
        case .codingAgent(let id): .codingAgent(id)
        case .acp(let id): .acpAgent(id)
        case .mlx(let model): .localModel(model)
        case .service(let id): .externalAgent("service:" + id)
        case .unknown: nil
        }
    }
}

/// Why something was asked for. Grants are scoped to one purpose.
public struct Purpose: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public var description: String { rawValue }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }

    /// A turn in a thread.
    public static let conversation: Purpose = "conversation"
    /// An agent's question to KemoSabe.
    public static let agentQuestion: Purpose = "agent-question"
    /// Apple's on-device model reading personal items to answer an agent.
    public static let extraction: Purpose = "extraction"
    /// A System One decision.
    public static let decision: Purpose = "decision"
    /// Saving to the owner's private iCloud.
    public static let sync: Purpose = "sync"
}

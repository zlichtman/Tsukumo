import Foundation
import TsukumoCore
import TsukumoEngines

// API model connections as both apps keep them (moved from the iPhone app, October 2, so the Mac's
// Settings, Models offers the same providers with the same words).

/// A connected API model provider as an app keeps it: TsukumoEngines' `APIConnection` (its fixed
/// endpoint and default model), which provider it is, and the models it offers. Its key lives in the
/// device's Keychain only (`KeychainAPIKeys`), never in this record, never in a file, never synced.
public struct ConnectionRecord: Codable, Identifiable, Hashable, Sendable {
    public enum Provider: String, Codable, CaseIterable, Identifiable, Sendable {
        case anthropic, openAI, compatible
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .anthropic: "Claude"
            case .openAI: "OpenAI"
            case .compatible: "Other"
            }
        }
        public var detail: String {
            switch self {
            case .anthropic: "Anthropic’s models, with your API key"
            case .openAI: "OpenAI’s models, with your API key"
            case .compatible: "Any OpenAI-compatible chat/completions server"
            }
        }
        public var endpoint: String {
            switch self {
            case .anthropic: APIConnection.anthropicEndpoint
            case .openAI: APIConnection.openAIEndpoint
            case .compatible: ""
            }
        }
        public var wire: APIWireFormat { self == .anthropic ? .anthropic : .openAICompatible }
        /// The model picked until the provider's own list arrives.
        public var defaultModel: String {
            switch self {
            case .anthropic: "claude-opus-5-5"
            case .openAI: "gpt-5.2"
            case .compatible: ""
            }
        }
        public var mark: EngineInfo.Mark {
            switch self {
            case .anthropic: .claude
            case .openAI: .openAI
            case .compatible: .generic
            }
        }
        /// The provider a pasted key belongs to, from its published prefix.
        public static func detect(key: String) -> Provider? {
            let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.hasPrefix("sk-ant-") { return .anthropic }
            if key.hasPrefix("sk-") { return .openAI }
            return nil
        }
    }

    public var connection: APIConnection
    public var provider: Provider
    /// The models it offers, newest first; empty until the list is fetched.
    public var models: [String]

    public init(connection: APIConnection, provider: Provider, models: [String] = []) {
        self.connection = connection; self.provider = provider; self.models = models
    }
    public var id: UUID { connection.id }
    public var name: String { connection.name }
    public var host: String { connection.endpoint.host() ?? connection.endpoint.absoluteString }
    public var engine: EngineID { .api(profile: connection.id) }
}

/// Fetches a provider's model list with the key the owner entered.
public enum ModelCatalog {
    public enum Failure: Error, LocalizedError {
        case key, unreachable
        public var errorDescription: String? {
            switch self {
            case .key: "That key wasn’t accepted. Check it and try again."
            case .unreachable: "The provider couldn’t be reached. For a local server, check that it’s running."
            }
        }
    }

    public static func models(provider: ConnectionRecord.Provider, endpoint: URL, key: String, session: URLSession = .shared) async throws -> [String] {
        let listURL: URL? = switch provider {
        case .anthropic: URL(string: "https://api.anthropic.com/v1/models?limit=100")
        case .openAI, .compatible: URL(string: endpoint.absoluteString.replacingOccurrences(of: "/chat/completions", with: "/models"))
        }
        guard let listURL else { throw Failure.unreachable }
        var request = URLRequest(url: listURL, timeoutInterval: 20)
        if provider == .anthropic {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else if !key.isEmpty {
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { throw Failure.unreachable }
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw Failure.unreachable }
        if status == 401 || status == 403 { throw Failure.key }
        guard status == 200 else { throw Failure.unreachable }
        return try chatModels(in: data, provider: provider)
    }

    /// Chat models only, newest first.
    public static func chatModels(in data: Data, provider: ConnectionRecord.Provider) throws -> [String] {
        struct List: Decodable { struct Model: Decodable { let id: String; let created: Int? }; let data: [Model] }
        guard let list = try? JSONDecoder().decode(List.self, from: data) else { throw Failure.unreachable }
        let skip = ["embedding", "tts", "whisper", "transcribe", "dall-e", "image", "moderation", "audio", "realtime", "search", "davinci", "babbage", "sora"]
        let models = list.data.filter { model in !skip.contains { model.id.lowercased().contains($0) } }
        let ordered = provider == .anthropic ? models : models.sorted { ($0.created ?? 0) > ($1.created ?? 0) }
        return ordered.map(\.id)
    }
}

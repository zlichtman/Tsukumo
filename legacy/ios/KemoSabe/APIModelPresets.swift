import Foundation

/// One tap to connect a well-known provider: its address, format, and where to get a key are
/// filled in, and its own model list is offered, so nobody has to type an endpoint or model ID.
enum APIModelPreset: String, CaseIterable, Identifiable {
    case claude, openAI, ollama, lmStudio, custom
    var id: String { rawValue }
    /// The provider a pasted key belongs to, from its published prefix (Anthropic keys start
    /// "sk-ant-", OpenAI keys "sk-"). Nil when it can't tell; the person picks.
    static func detect(key: String) -> APIModelPreset? {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.hasPrefix("sk-ant-") { return .claude }
        if key.hasPrefix("sk-") { return .openAI }
        return nil
    }
    var title: String {
        switch self {
        case .claude: "Claude"
        case .openAI: "OpenAI"
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        case .custom: "Other"
        }
    }
    var detail: String {
        switch self {
        case .claude: "Anthropic's models, with your API key"
        case .openAI: "ChatGPT and Codex models, with your API key"
        case .ollama: "A model running on this device"
        case .lmStudio: "A model running on this device"
        case .custom: "Any OpenAI-compatible chat/completions server"
        }
    }
    var symbol: String {
        switch self {
        case .claude: "sparkle"
        case .openAI: "circle.hexagongrid"
        case .ollama, .lmStudio: "desktopcomputer"
        case .custom: "network"
        }
    }
    var format: APIWireFormat { self == .claude ? .anthropic : .openAICompatible }
    var endpoint: String {
        switch self {
        case .claude: "https://api.anthropic.com/v1/messages"
        case .openAI: "https://api.openai.com/v1/chat/completions"
        case .ollama: "http://localhost:11434/v1/chat/completions"
        case .lmStudio: "http://localhost:1234/v1/chat/completions"
        case .custom: ""
        }
    }
    var modelsURL: URL? {
        switch self {
        case .claude: URL(string: "https://api.anthropic.com/v1/models?limit=100")
        case .openAI: URL(string: "https://api.openai.com/v1/models")
        case .ollama: URL(string: "http://localhost:11434/v1/models")
        case .lmStudio: URL(string: "http://localhost:1234/v1/models")
        case .custom: nil
        }
    }
    var needsKey: Bool { self == .claude || self == .openAI }
    /// Where to create a key.
    var keyPage: URL? {
        switch self {
        case .claude: URL(string: "https://console.anthropic.com/settings/keys")
        case .openAI: URL(string: "https://platform.openai.com/api-keys")
        default: nil
        }
    }
    var acceptsImages: Bool { self == .claude || self == .openAI }
    /// The model picked first when the list arrives, if it's offered.
    var preferredModel: String? {
        switch self {
        case .claude: "claude-opus-5"
        default: nil
        }
    }
}

/// Fetches a provider's model list with the key the person entered. Nothing is saved or selected.
enum APIModelCatalog {
    enum Failure: Error, LocalizedError {
        case key, unreachable
        var errorDescription: String? {
            switch self {
            case .key: "That key wasn't accepted. Check it and try again."
            case .unreachable: "The provider couldn't be reached. For a local server, check that it's running."
            }
        }
    }
    static func models(for preset: APIModelPreset, key: String, session: URLSession = .shared) async throws -> [String] {
        guard let url = preset.modelsURL else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 20)
        switch preset.format {
        case .anthropic:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openAICompatible:
            if !key.isEmpty { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { throw Failure.unreachable }
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw Failure.unreachable }
        if status == 401 || status == 403 { throw Failure.key }
        guard status == 200 else { throw Failure.unreachable }
        return try chatModels(in: data, preset: preset)
    }
    /// Chat models only, newest first: embeddings, speech, image, and moderation models are left out.
    static func chatModels(in data: Data, preset: APIModelPreset) throws -> [String] {
        struct List: Decodable { struct Model: Decodable { let id: String; let created: Int?; let created_at: String? }; let data: [Model] }
        guard let list = try? JSONDecoder().decode(List.self, from: data) else { throw Failure.unreachable }
        let skip = ["embedding", "tts", "whisper", "transcribe", "dall-e", "image", "moderation", "audio", "realtime", "search", "davinci", "babbage", "sora"]
        let models = list.data.filter { model in !skip.contains { model.id.lowercased().contains($0) } }
        // Anthropic lists newest first already; OpenAI-style lists carry a creation time.
        let ordered = preset.format == .anthropic ? models : models.sorted { ($0.created ?? 0) > ($1.created ?? 0) }
        return ordered.map(\.id)
    }
}

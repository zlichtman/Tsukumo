import Foundation
import Security
import TsukumoCore

/// How a connection talks to its server.
public enum APIWireFormat: String, Codable, Sendable {
    /// `POST …/chat/completions`, as OpenAI and many compatible servers serve it.
    case openAICompatible
    /// Claude's Messages API, `POST https://api.anthropic.com/v1/messages`.
    case anthropic
}

/// A connected API model (ported from the app's `APIModelProfile`). Its endpoint is fixed when it's
/// added, so the connection names one recipient. Its key lives in the Keychain, never here.
public struct APIConnection: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let endpoint: URL
    public let model: String
    public let wire: APIWireFormat
    public var streaming: Bool

    public static func loopback(_ host: String?) -> Bool { ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host?.lowercased() ?? "") }

    /// A checked connection: HTTPS (HTTP only for a server on this device), no credentials or query
    /// in the address, the format's own path, and short names.
    public static func validated(id: UUID = UUID(), name: String, endpoint: String, model: String, wire: APIWireFormat,
                                 streaming: Bool = true) throws -> APIConnection {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines), model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && loopback(host)),
              wire == .anthropic ? url.path.hasSuffix("/v1/messages") : url.path.hasSuffix("/chat/completions"),
              (1...80).contains(name.count), (1...160).contains(model.utf8.count), !model.contains(where: \.isNewline),
              url.absoluteString.utf8.count <= 2048 else { throw EngineError.configuration }
        return APIConnection(id: id, name: name, endpoint: url, model: model, wire: wire, streaming: streaming)
    }

    /// Which effort catalog applies: OpenAI's own API, or any other compatible server (none).
    public var effortWire: EffortCatalog.Wire {
        switch wire {
        case .anthropic: .anthropic
        case .openAICompatible: endpoint.host?.lowercased() == "api.openai.com" ? .openAI : .openAICompatible
        }
    }

    /// Presets for the add-connection form.
    public static let anthropicEndpoint = "https://api.anthropic.com/v1/messages"
    public static let openAIEndpoint = "https://api.openai.com/v1/chat/completions"
}

/// Where API keys live.
public protocol APIKeyStore: Sendable {
    func read(_ id: UUID) throws -> String?
    func save(_ key: String, for id: UUID) throws
    func remove(_ id: UUID) throws
}

/// Keys in the Keychain: this device only, readable while it's unlocked. They never sync and never
/// leave the device except in the Authorization header to their own connection.
public struct KeychainAPIKeys: APIKeyStore {
    public let service: String
    public init(service: String = "com.zlichtman.tsukumo.api-keys") { self.service = service }
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
    }
    public func read(_ id: UUID) throws -> String? {
        var query = query(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw EngineError.missingKey }
        return String(data: data, encoding: .utf8)
    }
    public func save(_ key: String, for id: UUID) throws {
        let fields: [String: Any] = [kSecValueData as String: Data(key.utf8), kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query(id) as CFDictionary, fields as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query(id).merging(fields) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw EngineError.missingKey }
        } else if status != errSecSuccess { throw EngineError.missingKey }
    }
    public func remove(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw EngineError.missingKey }
    }
}

/// Keys in memory, for tests and previews.
public final class MemoryAPIKeys: APIKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [UUID: String]
    public init(_ keys: [UUID: String] = [:]) { self.keys = keys }
    public func read(_ id: UUID) throws -> String? { lock.withLock { keys[id] } }
    public func save(_ key: String, for id: UUID) throws { lock.withLock { keys[id] = key } }
    public func remove(_ id: UUID) throws { _ = lock.withLock { keys.removeValue(forKey: id) } }
}

/// Runs a turn on a connected API model (ported from the app's `CompatibleAPIModel`): Claude's
/// Messages API or an OpenAI-compatible chat/completions server, streamed or not, with the turn's
/// tools offered through the provider's own tool calling.
public struct APIEngine: Engine {
    public static let maxToolRounds = 6, maxCallsPerRound = 4, maxReplyBytes = 64_000, maxResponseBytes = 1_000_000

    public let connection: APIConnection
    public let keys: any APIKeyStore
    let session: URLSession
    public var id: EngineID { .api(profile: connection.id) }

    /// `session` is for tests; by default each engine uses an ephemeral session that never follows
    /// a redirect, so a key sent to the configured endpoint never reaches another address.
    public init(connection: APIConnection, keys: any APIKeyStore, session: URLSession? = nil) {
        self.connection = connection; self.keys = keys
        self.session = session ?? URLSession(configuration: Self.configuration, delegate: NoRedirects(), delegateQueue: nil)
    }
    static var configuration: URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 300
        return config
    }
    final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }

    public func run(_ turn: EngineTurn) -> AsyncThrowingStream<EngineEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let reply = try await self.perform(turn) { continuation.yield($0) }
                    continuation.yield(.done(reply))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func perform(_ turn: EngineTurn, emit: @Sendable (EngineEvent) -> Void) async throws -> EngineReply {
        guard let key = try keys.read(connection.id), !key.isEmpty || APIConnection.loopback(connection.endpoint.host) else { throw EngineError.missingKey }
        guard key.utf8.count <= 4096, key.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else { throw EngineError.configuration }
        let model = turn.bot.model ?? connection.model
        // Only an effort this model documents, in its own provider's field.
        let effort = EffortCatalog.accepted(turn.bot.effort, wire: connection.effortWire, model: model)
        let tools = turn.runTool == nil ? [] : turn.tools
        var exchanges: [(text: String, calls: [ToolCall], results: [String])] = []
        var allCalls: [ToolCall] = []
        for round in 0...Self.maxToolRounds {
            try Task.checkCancellation()
            // The last round still declares the tools but allows no call, so the model answers.
            let allowCalls = !tools.isEmpty && round < Self.maxToolRounds
            var request = URLRequest(url: connection.endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(connection.streaming ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
            let body: JSONValue
            switch connection.wire {
            case .anthropic:
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                body = WireBodies.anthropic(turn: turn, model: model, effort: effort, tools: tools, allowCalls: allowCalls,
                                            exchanges: exchanges, stream: connection.streaming)
            case .openAICompatible:
                if !key.isEmpty { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
                body = WireBodies.openAI(turn: turn, model: model, effort: effort, tools: tools, allowCalls: allowCalls,
                                         exchanges: exchanges, stream: connection.streaming)
            }
            request.httpBody = try TsukumoJSON.encoder.encode(body)
            let (text, calls) = try await send(request, allowCalls: allowCalls, emit: emit)
            guard !calls.isEmpty else { return EngineReply(text: text, toolCalls: allCalls) }
            guard allowCalls, calls.count <= Self.maxCallsPerRound, let runTool = turn.runTool else { throw EngineError.incomplete }
            var results: [String] = []
            for call in calls {
                emit(.toolCall(call))
                let result = await runTool(call)
                emit(.toolResult(id: call.id, text: result))
                results.append(result)
            }
            allCalls += calls
            exchanges.append((text, calls, results))
        }
        throw EngineError.incomplete
    }

    /// One guarded exchange: status mapping, size limits, the endpoint it answered from, and either
    /// a stream of events or one JSON reply.
    private func send(_ request: URLRequest, allowCalls: Bool, emit: @Sendable (EngineEvent) -> Void) async throws -> (String, [ToolCall]) {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.url == connection.endpoint else { throw EngineError.incomplete }
            if http.statusCode == 429 || http.statusCode == 529 { throw EngineError.limited }
            if (400...499).contains(http.statusCode) { throw EngineError.denied }
            guard http.statusCode == 200 else { throw EngineError.unavailable }
            var decoder: any ReplyDecoder = connection.wire == .anthropic ? AnthropicDecoder(acceptsTools: allowCalls) : CompatibleDecoder(acceptsTools: allowCalls)
            if connection.streaming {
                var total = 0
                for try await line in bytes.lines {
                    try Task.checkCancellation()
                    total += line.utf8.count + 1
                    guard total <= Self.maxResponseBytes else { throw EngineError.tooLarge }
                    let before = decoder.text.count
                    try decoder.consume(line)
                    if decoder.text.count > before { emit(.text(String(decoder.text.dropFirst(before)))) }
                    if decoder.done { break }
                }
                return try decoder.finish()
            }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                guard data.count <= Self.maxResponseBytes else { throw EngineError.tooLarge }
            }
            let result = try decoder.whole(data)
            if !result.0.isEmpty { emit(.text(result.0)) }
            return result
        } catch is CancellationError { throw CancellationError() }
        catch let error as EngineError { throw error }
        catch { if Task.isCancelled { throw CancellationError() }; throw EngineError.unavailable }
    }
}

// MARK: Wire formats

enum WireBodies {
    static func schema(_ tool: ToolDefinition) -> JSONValue {
        .object(["type": .string("object"),
                 "properties": .object(Dictionary(uniqueKeysWithValues: tool.parameters.map {
                     ($0.name, JSONValue.object(["type": .string("string"), "description": .string($0.description)]))
                 })),
                 "required": .array(tool.parameters.filter(\.required).map { .string($0.name) })])
    }
    static func arguments(_ call: ToolCall) -> JSONValue { .object(call.arguments.mapValues { .string($0) }) }
    static func argumentsText(_ call: ToolCall) -> String {
        (try? String(decoding: TsukumoJSON.encoder.encode(arguments(call)), as: UTF8.self)) ?? "{}"
    }

    /// Claude's Messages API: the system prompt, alternating turns starting with the owner, and
    /// tool use and results replayed as content blocks.
    static func anthropic(turn: EngineTurn, model: String, effort: Effort?, tools: [ToolDefinition], allowCalls: Bool,
                          exchanges: [(text: String, calls: [ToolCall], results: [String])], stream: Bool) -> JSONValue {
        var messages: [(role: String, blocks: [JSONValue])] = []
        for message in turn.history + [EngineMessage(role: .user, text: turn.message)] {
            let block = JSONValue.object(["type": .string("text"), "text": .string(message.text)])
            if messages.isEmpty, message.role != .user { continue }
            if messages.last?.role == message.role.rawValue { messages[messages.count - 1].blocks.append(block) }
            else { messages.append((message.role.rawValue, [block])) }
        }
        for exchange in exchanges {
            let calls = exchange.calls.map { JSONValue.object(["type": .string("tool_use"), "id": .string($0.id), "name": .string($0.name), "input": arguments($0)]) }
            let text: [JSONValue] = exchange.text.isEmpty ? [] : [.object(["type": .string("text"), "text": .string(exchange.text)])]
            messages.append(("assistant", text + calls))
            messages.append(("user", zip(exchange.calls, exchange.results).map {
                .object(["type": .string("tool_result"), "tool_use_id": .string($0.id), "content": .string($1)])
            }))
        }
        var body: [String: JSONValue] = [
            "model": .string(model), "max_tokens": .number(16_000), "system": .string(turn.systemPrompt), "stream": .bool(stream),
            "messages": .array(messages.map { .object(["role": .string($0.role), "content": .array($0.blocks)]) })
        ]
        if !tools.isEmpty {
            body["tools"] = .array(tools.map { .object(["name": .string($0.name), "description": .string($0.description), "input_schema": schema($0)]) })
            if !allowCalls { body["tool_choice"] = .object(["type": .string("none")]) }
        }
        if let effort { body["output_config"] = .object(["effort": .string(effort.rawValue)]) }
        return .object(body)
    }

    /// OpenAI's chat/completions: a system message, the thread, and tool calls and results as their
    /// own messages.
    static func openAI(turn: EngineTurn, model: String, effort: Effort?, tools: [ToolDefinition], allowCalls: Bool,
                       exchanges: [(text: String, calls: [ToolCall], results: [String])], stream: Bool) -> JSONValue {
        var messages: [JSONValue] = [.object(["role": .string("system"), "content": .string(turn.systemPrompt)])]
        for message in turn.history + [EngineMessage(role: .user, text: turn.message)] {
            messages.append(.object(["role": .string(message.role.rawValue), "content": .string(message.text)]))
        }
        for exchange in exchanges {
            messages.append(.object(["role": .string("assistant"), "content": exchange.text.isEmpty ? .null : .string(exchange.text),
                                     "tool_calls": .array(exchange.calls.map {
                                         .object(["id": .string($0.id), "type": .string("function"),
                                                  "function": .object(["name": .string($0.name), "arguments": .string(argumentsText($0))])])
                                     })]))
            for (call, result) in zip(exchange.calls, exchange.results) {
                messages.append(.object(["role": .string("tool"), "tool_call_id": .string(call.id), "content": .string(result)]))
            }
        }
        var body: [String: JSONValue] = ["model": .string(model), "messages": .array(messages), "stream": .bool(stream)]
        if !tools.isEmpty {
            body["tools"] = .array(tools.map {
                .object(["type": .string("function"), "function": .object(["name": .string($0.name), "description": .string($0.description), "parameters": schema($0)])])
            })
            if !allowCalls { body["tool_choice"] = .string("none") }
        }
        if let effort { body["reasoning_effort"] = .string(effort.rawValue) }
        return .object(body)
    }
}

protocol ReplyDecoder {
    var text: String { get }
    var done: Bool { get }
    mutating func consume(_ line: String) throws
    func finish() throws -> (String, [ToolCall])
    func whole(_ data: Data) throws -> (String, [ToolCall])
}

private func toolArguments(_ json: String) throws -> [String: String] {
    let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [:] }
    guard case .object(let members)? = try? TsukumoJSON.decoder.decode(JSONValue.self, from: Data(trimmed.utf8)) else { throw EngineError.incomplete }
    var result: [String: String] = [:]
    for (name, value) in members {
        switch value {
        case .string(let text): result[name] = text
        case .number(let number): result[name] = number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number)
        case .bool(let flag): result[name] = flag ? "true" : "false"
        case .null: continue
        default: result[name] = (try? String(decoding: TsukumoJSON.encoder.encode(value), as: UTF8.self)) ?? ""
        }
    }
    return result
}

/// Claude's streamed events: `text_delta` is text; `tool_use` blocks collect `input_json_delta`.
struct AnthropicDecoder: ReplyDecoder {
    private struct Pending { let block: Int; let id: String; let name: String; var json = "" }
    private(set) var text = ""
    private(set) var done = false
    let acceptsTools: Bool
    private var stop: String?
    private var pending: [Pending] = []
    init(acceptsTools: Bool) { self.acceptsTools = acceptsTools }

    mutating func consume(_ line: String) throws {
        guard !done, line.hasPrefix("data:") else { return }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let event = try? TsukumoJSON.decoder.decode(JSONValue.self, from: Data(payload.utf8)) else { throw EngineError.incomplete }
        switch event["type"]?.stringValue {
        case "content_block_start":
            if let block = event["content_block"], block["type"]?.stringValue == "tool_use" {
                guard acceptsTools, let id = block["id"]?.stringValue, let name = block["name"]?.stringValue,
                      case .number(let index)? = event["index"] else { throw EngineError.incomplete }
                pending.append(Pending(block: Int(index), id: id, name: name))
            }
        case "content_block_delta":
            guard let delta = event["delta"] else { return }
            if delta["type"]?.stringValue == "text_delta", let more = delta["text"]?.stringValue {
                guard text.utf8.count + more.utf8.count <= APIEngine.maxReplyBytes else { throw EngineError.tooLarge }
                text += more
            } else if delta["type"]?.stringValue == "input_json_delta", let part = delta["partial_json"]?.stringValue,
                      case .number(let index)? = event["index"], let i = pending.firstIndex(where: { $0.block == Int(index) }) {
                guard pending[i].json.utf8.count + part.utf8.count <= 8000 else { throw EngineError.tooLarge }
                pending[i].json += part
            }
        case "message_delta":
            if let reason = event["delta"]?["stop_reason"]?.stringValue { try accept(reason); stop = reason }
        case "message_stop": done = true
        case "error": throw EngineError.unavailable
        default: break
        }
    }
    private func accept(_ reason: String) throws {
        switch reason {
        case "end_turn", "stop_sequence", "max_tokens": return
        case "tool_use" where acceptsTools: return
        case "refusal": throw EngineError.refused
        default: throw EngineError.incomplete
        }
    }
    func finish() throws -> (String, [ToolCall]) {
        guard stop != nil else { throw EngineError.incomplete }
        let calls = try pending.map { ToolCall(id: $0.id, name: $0.name, arguments: try toolArguments($0.json)) }
        guard !calls.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EngineError.incomplete }
        return (text, calls)
    }
    func whole(_ data: Data) throws -> (String, [ToolCall]) {
        guard let reply = try? TsukumoJSON.decoder.decode(JSONValue.self, from: data), case .array(let blocks)? = reply["content"],
              let reason = reply["stop_reason"]?.stringValue else { throw EngineError.incomplete }
        try accept(reason)
        var text = "", calls: [ToolCall] = []
        for block in blocks {
            switch block["type"]?.stringValue {
            case "text": text += block["text"]?.stringValue ?? ""
            case "tool_use":
                guard acceptsTools, let id = block["id"]?.stringValue, let name = block["name"]?.stringValue else { throw EngineError.incomplete }
                let input = block["input"].flatMap { try? String(decoding: TsukumoJSON.encoder.encode($0), as: UTF8.self) } ?? "{}"
                calls.append(ToolCall(id: id, name: name, arguments: try toolArguments(input)))
            default: continue
            }
        }
        guard text.utf8.count <= APIEngine.maxReplyBytes, !calls.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EngineError.incomplete
        }
        return (text, calls)
    }
}

/// OpenAI-compatible streamed chunks: `delta.content` is text; `delta.tool_calls` arrive in pieces.
struct CompatibleDecoder: ReplyDecoder {
    private struct Pending { let index: Int; var id: String?; var name = ""; var json = "" }
    private(set) var text = ""
    private(set) var done = false
    let acceptsTools: Bool
    private var finished: String?
    private var pending: [Pending] = []
    init(acceptsTools: Bool) { self.acceptsTools = acceptsTools }

    mutating func consume(_ line: String) throws {
        guard !done, line.hasPrefix("data:") else { return }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { done = true; return }
        guard let chunk = try? TsukumoJSON.decoder.decode(JSONValue.self, from: Data(payload.utf8)), case .array(let choices)? = chunk["choices"] else {
            throw EngineError.incomplete
        }
        for choice in choices {
            if case .number(let index)? = choice["index"], index != 0 { throw EngineError.incomplete }
            let delta = choice["delta"]
            if let refusal = delta?["refusal"], refusal != .null { throw EngineError.refused }
            if case .array(let calls)? = delta?["tool_calls"] {
                guard acceptsTools else { throw EngineError.incomplete }
                for call in calls {
                    guard case .number(let raw) = call["index"] ?? .number(0) else { throw EngineError.incomplete }
                    let index = Int(raw)
                    guard (0..<APIEngine.maxCallsPerRound).contains(index) else { throw EngineError.incomplete }
                    if !pending.contains(where: { $0.index == index }) { pending.append(Pending(index: index)) }
                    guard let i = pending.firstIndex(where: { $0.index == index }) else { throw EngineError.incomplete }
                    if let id = call["id"]?.stringValue { pending[i].id = id }
                    pending[i].name += call["function"]?["name"]?.stringValue ?? ""
                    pending[i].json += call["function"]?["arguments"]?.stringValue ?? ""
                    guard pending[i].json.utf8.count <= 8000, pending[i].name.count <= 64 else { throw EngineError.tooLarge }
                }
            }
            if let more = delta?["content"]?.stringValue {
                guard text.utf8.count + more.utf8.count <= APIEngine.maxReplyBytes else { throw EngineError.tooLarge }
                text += more
            }
            if let reason = choice["finish_reason"]?.stringValue {
                guard reason == "stop" || reason == "length" || (reason == "tool_calls" && acceptsTools) else {
                    throw reason == "content_filter" ? EngineError.refused : EngineError.incomplete
                }
                finished = reason
            }
        }
    }
    func finish() throws -> (String, [ToolCall]) {
        guard finished != nil else { throw EngineError.incomplete }
        let calls = try pending.sorted { $0.index < $1.index }.map { pending -> ToolCall in
            guard !pending.name.isEmpty else { throw EngineError.incomplete }
            return ToolCall(id: pending.id ?? "call-\(pending.index)", name: pending.name, arguments: try toolArguments(pending.json))
        }
        guard !calls.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EngineError.incomplete }
        return (text, calls)
    }
    func whole(_ data: Data) throws -> (String, [ToolCall]) {
        guard let reply = try? TsukumoJSON.decoder.decode(JSONValue.self, from: data), case .array(let choices)? = reply["choices"],
              choices.count == 1, let message = choices[0]["message"] else { throw EngineError.incomplete }
        if let refusal = message["refusal"], refusal != .null { throw EngineError.refused }
        let text = message["content"]?.stringValue ?? ""
        var calls: [ToolCall] = []
        if case .array(let raw)? = message["tool_calls"], !raw.isEmpty {
            guard acceptsTools, raw.count <= APIEngine.maxCallsPerRound else { throw EngineError.incomplete }
            calls = try raw.enumerated().map { index, call in
                guard let name = call["function"]?["name"]?.stringValue else { throw EngineError.incomplete }
                return ToolCall(id: call["id"]?.stringValue ?? "call-\(index)", name: name,
                                arguments: try toolArguments(call["function"]?["arguments"]?.stringValue ?? ""))
            }
        }
        guard text.utf8.count <= APIEngine.maxReplyBytes, !calls.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EngineError.incomplete
        }
        return (text, calls)
    }
}

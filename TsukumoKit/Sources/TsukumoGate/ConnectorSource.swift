import Foundation
import Security
import TsukumoCore
import TsukumoPolicy

// Connected accounts: any service with an MCP server becomes a source. The owner adds its address (and a
// token, kept in this device's Keychain) with a name and a level. Tsukumo speaks MCP's Streamable HTTP
// transport (JSON-RPC 2.0 over POST, answered as JSON or as a server-sent event stream): `initialize`, then
// `tools/list` to find the tool KemoSabe asks with (one that takes a search or a question), and for each bot
// question that reaches the Gate, `tools/call` with the bot's question. What comes back is read on this
// device like any other source: only the answer goes to the bot, at the account's level. Nothing of the
// owner's other sources is ever sent to the server, only the bot's question.

public enum ConnectorError: Error, LocalizedError, Equatable {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { text } else { nil } }
}

/// One of a server's tools.
public struct MCPTool: Hashable, Codable, Sendable {
    public var name: String
    public var description: String
    /// The string argument a question goes in, when it takes one.
    public var argument: String?
    public init(name: String, description: String = "", argument: String? = nil) { self.name = name; self.description = description; self.argument = argument }

    /// The tool KemoSabe asks with: "search" first, then any tool whose only required argument is a string
    /// named like a query, then any tool with a single string argument.
    public static func best(_ tools: [MCPTool]) -> MCPTool? {
        let askable = tools.filter { $0.argument != nil }
        let names = ["search", "query", "ask", "find", "lookup"]
        for name in names { if let tool = askable.first(where: { $0.name.lowercased() == name }) { return tool } }
        if let tool = askable.first(where: { tool in names.contains { tool.name.lowercased().contains($0) } }) { return tool }
        return askable.first
    }

    /// The argument a question goes in, from the tool's input schema.
    static func argument(in schema: [String: Any]?) -> String? {
        guard let properties = schema?["properties"] as? [String: Any] else { return nil }
        let strings = properties.filter { ($0.value as? [String: Any])?["type"] as? String == "string" }.map(\.key)
        let required = (schema?["required"] as? [String]) ?? []
        // Every required argument must be one KemoSabe can fill: exactly one string.
        guard required.count <= 1, required.allSatisfy(strings.contains) else { return nil }
        let preferred = ["query", "q", "question", "search", "text", "prompt", "input", "keywords"]
        if let only = required.first { return only }
        for name in preferred where strings.contains(name) { return name }
        return strings.count == 1 ? strings.first : nil
    }
}

/// A small MCP client over Streamable HTTP.
public actor MCPClient {
    public let url: URL
    private let token: String?
    private let session: URLSession
    private var sessionID: String?
    private var protocolVersion: String?
    private var nextID = 1
    public static let version = "2025-06-18"
    public static let timeout: TimeInterval = 12

    public init(url: URL, token: String?, session: URLSession = .shared) { self.url = url; self.token = token; self.session = session }

    public func tools() async throws -> [MCPTool] {
        try await start()
        let result = try await request("tools/list", params: [:])
        let list = (result["tools"] as? [[String: Any]]) ?? []
        return list.compactMap { tool in
            guard let name = tool["name"] as? String else { return nil }
            return MCPTool(name: name, description: tool["description"] as? String ?? "", argument: MCPTool.argument(in: tool["inputSchema"] as? [String: Any]))
        }
    }

    /// The text a tool returns (each text part), or an error the server reported.
    public func call(_ tool: String, arguments: [String: String]) async throws -> [String] {
        try await start()
        let result = try await request("tools/call", params: ["name": tool, "arguments": arguments])
        if result["isError"] as? Bool == true { throw ConnectorError.message("The server said it couldn’t answer.") }
        let parts = (result["content"] as? [[String: Any]]) ?? []
        var texts = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        if texts.isEmpty, let structured = result["structuredContent"],
           let data = try? JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys]) {
            texts = [String(decoding: data, as: UTF8.self)]
        }
        return texts
    }

    private func start() async throws {
        guard protocolVersion == nil else { return }
        let result = try await request("initialize", params: [
            "protocolVersion": Self.version, "capabilities": [String: Any](),
            "clientInfo": ["name": "Tsukumo", "version": "1"]
        ])
        protocolVersion = result["protocolVersion"] as? String ?? Self.version
        try await notify("notifications/initialized")
    }

    private func headers(_ request: inout URLRequest) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if let protocolVersion { request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
    }

    private func notify(_ method: String) async throws {
        var request = URLRequest(url: url, timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        headers(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": method])
        _ = try await session.data(for: request)
    }

    private func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        var request = URLRequest(url: url, timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        headers(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch {
            throw ConnectorError.message("Tsukumo couldn’t reach \(url.host() ?? "the server").")
        }
        guard let http = response as? HTTPURLResponse else { throw ConnectorError.message("The server didn’t answer.") }
        if http.statusCode == 401 || http.statusCode == 403 { throw ConnectorError.message("The server wants a token, or didn’t accept this one.") }
        guard (200..<300).contains(http.statusCode) else { throw ConnectorError.message("The server answered \(http.statusCode).") }
        if let id = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = id }
        let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        let messages = type.contains("text/event-stream") ? Self.events(data) : [data]
        for message in messages {
            guard let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any], (object["id"] as? Int) == id else { continue }
            if let error = object["error"] as? [String: Any] {
                throw ConnectorError.message("The server said: " + (error["message"] as? String ?? "it couldn’t do that") + ".")
            }
            return object["result"] as? [String: Any] ?? [:]
        }
        throw ConnectorError.message("This doesn’t look like an MCP server.")
    }

    /// The `data:` of each event in a server-sent event stream.
    static func events(_ data: Data) -> [Data] {
        var events: [Data] = [], current: [String] = []
        for line in String(decoding: data, as: UTF8.self).components(separatedBy: .newlines) {
            if line.isEmpty {
                if !current.isEmpty { events.append(Data(current.joined(separator: "\n").utf8)); current = [] }
            } else if line.hasPrefix("data:") {
                current.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        }
        if !current.isEmpty { events.append(Data(current.joined(separator: "\n").utf8)) }
        return events
    }
}

/// A connected account, asked a bot's question.
public struct ConnectorSource: PersonalSource {
    public let account: ConnectedAccount
    public let token: String?
    public let session: URLSession
    /// At most this many parts, each cut to this length.
    public static let maxParts = 6, maxPart = 2_000
    public init(account: ConnectedAccount, token: String?, session: URLSession = .shared) {
        self.account = account; self.token = token; self.session = session
    }
    public func items(matching question: GateQuestion) async -> [PersonalItem] {
        let client = MCPClient(url: account.url, token: token, session: session)
        guard let texts = try? await client.call(account.tool, arguments: [account.argument: question.question]) else { return [] }
        return texts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.prefix(Self.maxParts).enumerated().map { index, text in
            PersonalItem(id: "account:\(account.id.uuidString):\(question.id):\(index)", kind: .connector, level: account.setting.level,
                         title: "your \(account.name) account", text: text.count > Self.maxPart ? String(text.prefix(Self.maxPart)) : text,
                         date: question.receivedAt, matched: true)
        }
    }
}

// MARK: Tokens

/// Where connected accounts' tokens are kept.
public protocol ConnectorTokenStore: Sendable {
    func save(_ token: String, for id: UUID) throws
    func read(_ id: UUID) -> String?
    func remove(_ id: UUID)
}

/// The Keychain, this device only (never synced, never in a backup another device restores).
public struct KeychainConnectorTokens: ConnectorTokenStore {
    public let service: String
    public init(service: String) { self.service = service }
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
    }
    public func save(_ token: String, for id: UUID) throws {
        SecItemDelete(query(id) as CFDictionary)
        var add = query(id)
        add[kSecValueData as String] = Data(token.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw ConnectorError.message("Tsukumo couldn’t keep the token in the Keychain.") }
    }
    public func read(_ id: UUID) -> String? {
        var lookup = query(id)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    public func remove(_ id: UUID) { SecItemDelete(query(id) as CFDictionary) }
}

/// In memory, for tests.
public final class MemoryConnectorTokens: ConnectorTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: String] = [:]
    public init() {}
    public func save(_ token: String, for id: UUID) throws { lock.withLock { values[id] = token } }
    public func read(_ id: UUID) -> String? { lock.withLock { values[id] } }
    public func remove(_ id: UUID) { lock.withLock { values[id] = nil } }
}

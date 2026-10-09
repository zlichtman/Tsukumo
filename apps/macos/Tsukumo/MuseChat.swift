import Foundation
import os
import TsukumoCore
import TsukumoEngines
import TsukumoMuse

// Chatting with the owner's paired Muse from the dock (October 8, 2026, the owner: "I don't know how to message Muse
// on here"). Each of the dock's chats with Muse is a side chat of the owner's Muse (the Muse Gadget SDK's
// `/chat/stream`, `session_id`), so it stays apart from their main Muse chat and continues where it left off. Only
// the owner's own words go: never KemoSabe's references or anything about them (Muse asks KemoSabe for that, through
// the gateway, under the owner's rules). Muse's answer shows here when its response carries it; otherwise it's in the
// Muse app, and the chat says so. The response's shape isn't published, so its keys (never its words) are logged.

struct MuseChatEngine: Engine {
    let id = EngineID.muse
    /// Sends a message to a side chat: (message, session) → Muse's response.
    let send: @Sendable @MainActor (String, String) async throws -> MuseChatResult

    static let log = Logger(subsystem: "com.zlichtman.tsukumo.mac", category: "muse-chat")

    func run(_ turn: EngineTurn) -> AsyncThrowingStream<EngineEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                // A plain UUID: Muse refused (HTTP 400) the "tsukumo-…" ids 2.10 made. If it refuses a side chat anyway,
                // the message goes to the owner's main Muse chat rather than nowhere.
                var session = turn.session ?? UUID().uuidString.lowercased()
                do {
                    var result = try await send(turn.message, session)
                    Self.log.notice("Muse chat: HTTP \(result.status, privacy: .public), response keys \(Self.shape(result.response), privacy: .public), error \(Self.error(in: result.response) ?? "none", privacy: .public)")
                    if !result.ok, result.status == 400 {
                        session = ""
                        result = try await send(turn.message, session)
                        Self.log.notice("Muse chat, main chat: HTTP \(result.status, privacy: .public), error \(Self.error(in: result.response) ?? "none", privacy: .public)")
                    }
                    if !session.isEmpty { turn.onSession?(session) }
                    guard result.ok else { throw MuseChatFailure(status: result.status, reason: Self.error(in: result.response)) }
                    let text = Self.reply(in: result.response)
                        ?? "Sent to your Muse. Its answer is in the Muse app, in the chat Tsukumo started."
                    continuation.yield(.text(text))
                    continuation.yield(.done(EngineReply(text: text, session: session.isEmpty ? nil : session)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Muse's own words for a refusal (`error.message`, and its code), which carry nothing of the owner's.
    static func error(in response: JSONValue?) -> String? {
        guard let error = response?["error"] else { return nil }
        let parts = [error["code"]?.stringValue, error["message"]?.stringValue].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : String(parts.joined(separator: ": ").prefix(300))
    }

    /// Muse's answer in its response, best effort: the longest text under a key that holds a reply.
    static func reply(in response: JSONValue?) -> String? {
        let keys: Set<String> = ["text", "reply", "message", "content", "answer", "output", "response", "assistant_message"]
        var found: [String] = []
        func walk(_ value: JSONValue, under key: String?) {
            switch value {
            case .string(let text):
                if let key, keys.contains(key) { found.append(text) }
            case .array(let items): items.forEach { walk($0, under: key) }
            case .object(let members): for (name, member) in members { walk(member, under: name) }
            default: break
            }
        }
        if let response { walk(response, under: "response") }
        let text = found.max { $0.count < $1.count }?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    /// The response's shape for the log: its keys, nested, never its values.
    static func shape(_ value: JSONValue?, depth: Int = 0) -> String {
        guard let value, depth < 4 else { return "" }
        switch value {
        case .object(let members): return "{" + members.keys.sorted().map { $0 + shape(members[$0], depth: depth + 1) }.joined(separator: ",") + "}"
        case .array(let items): return "[" + (items.first.map { shape($0, depth: depth + 1) } ?? "") + "]"
        case .string: return ":s"
        default: return ""
        }
    }
}

struct MuseChatFailure: Error, LocalizedError {
    var status: Int?
    var reason: String?
    var errorDescription: String? {
        guard let status else { return "Your Muse isn’t connected right now. Check Muse in Settings, Bots." }
        return "Your Muse didn’t take the message (HTTP \(status)" + (reason.map { ": " + $0 } ?? "") + ")."
    }
}

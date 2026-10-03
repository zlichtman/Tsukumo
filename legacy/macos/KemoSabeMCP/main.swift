import Foundation

// kemosabe-mcp: a stdio MCP server inside Tsukumo.app (Contents/Helpers/kemosabe-mcp). Claude Code,
// Codex, Muse, and any MCP client start it; it offers one tool, `ask_kemosabe`, and relays each call
// to the running Tsukumo app over the local bridge (`KemoSabeBridgeWire`). The app decides
// everything: the owner's consent, the context policy, Apple's on-device model, and the journal.
// This process holds no data and reads none.
//
// Usage: kemosabe-mcp [--agent <id>] [--handoff <id>]
//   --agent names the client when its config was written by Tsukumo (claude-code, codex, muse,
//   cursor-agent, acp:<name>); otherwise the MCP client's own clientInfo name is used.

let serverVersion = "1.0.0"
/// MCP revisions this server speaks; it answers with the client's when it's one of these.
let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
/// How long a call waits for the app: the owner may be answering a prompt.
let callTimeout = 170

var agent: String?
/// Set when a KemoSabe chat handed a task to this agent, so the exchange shows in that chat.
var handoff: String?
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    switch argument {
    case "--agent": agent = arguments.popFirst()
    case "--handoff": handoff = arguments.popFirst()
    case "--version": print("kemosabe-mcp " + serverVersion); exit(0)
    case "--help", "-h":
        print("kemosabe-mcp [--agent <id>]: the KemoSabe MCP server. Started by an MCP client over stdio; Tsukumo must be running.")
        exit(0)
    default: break
    }
}

let output = NSLock()
func send(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
    output.lock(); defer { output.unlock() }
    FileHandle.standardOutput.write(data + Data([UInt8(ascii: "\n")]))
}
func reply(_ id: Any, _ result: [String: Any]) { send(["jsonrpc": "2.0", "id": id, "result": result]) }
func fail(_ id: Any, _ code: Int, _ message: String) { send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]) }

let clientLock = NSLock()
/// Calls still waiting for the app; answered before exiting when the client closes stdin.
let calls = DispatchGroup()
var client = KemoSabeBridgeWire.Client()

let tool: [String: Any] = [
    "name": "ask_kemosabe",
    "title": "Ask KemoSabe",
    "description": """
        Ask the owner's KemoSabe one specific question about their own life: what someone said in a conversation, \
        a plan, a preference, a date, a note about a person. KemoSabe answers on the owner's Mac with Apple's \
        on-device model and returns only the answer (for example "Friday after 7"), never the conversation or \
        notes it came from. The owner may be asked to allow you first, and some things are never shared. \
        Ask one clear question at a time and say why you need it.
        """,
    "inputSchema": [
        "type": "object",
        "properties": [
            "question": ["type": "string", "description": "One specific question, for example \"What time did my girlfriend say she was free on Friday?\"", "maxLength": 500],
            "purpose": ["type": "string", "description": "Why you're asking, in a few words (\"planning dinner\"). The owner sees it.", "maxLength": 200],
        ],
        "required": ["question", "purpose"],
    ],
    "annotations": ["title": "Ask KemoSabe", "readOnlyHint": true, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false],
]

func call(_ id: Any, _ params: [String: Any]) {
    guard params["name"] as? String == "ask_kemosabe" else { return fail(id, -32602, "Unknown tool") }
    let input = params["arguments"] as? [String: Any] ?? [:]
    let question = (input["question"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let purpose = (input["purpose"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !question.isEmpty else {
        return reply(id, ["content": [["type": "text", "text": "Ask a question: `question` is empty."]], "isError": true])
    }
    let folder = KemoSabeBridgeWire.folder()
    let response: KemoSabeBridgeWire.Response
    if let secret = try? String(contentsOf: folder.appendingPathComponent(KemoSabeBridgeWire.secretName), encoding: .utf8) {
        let who = clientLock.withLock { client }
        response = KemoSabeBridgeWire.send(.init(secret: secret.trimmingCharacters(in: .whitespacesAndNewlines), agent: agent, client: who,
                                                  question: question, purpose: purpose, handoff: handoff), folder: folder, timeout: callTimeout)
    } else {
        response = .init(status: KemoSabeBridgeWire.Status.notRunning.rawValue,
                         text: "KemoSabe isn't set up on this Mac yet. Ask the owner to open Tsukumo, then ask again.")
    }
    let status = KemoSabeBridgeWire.Status(rawValue: response.status) ?? .refused
    reply(id, ["content": [["type": "text", "text": response.text]], "isError": status.isError,
               "structuredContent": ["status": status.rawValue, "answer": status == .answered ? response.text : ""]])
}

func handle(_ message: [String: Any]) {
    let id = message["id"]
    let method = message["method"] as? String ?? ""
    let params = message["params"] as? [String: Any] ?? [:]
    guard let id, !(id is NSNull) else { return }   // notifications (initialized, cancelled) need no answer
    switch method {
    case "initialize":
        let info = params["clientInfo"] as? [String: Any] ?? [:]
        clientLock.withLock {
            client = .init(name: (info["name"] as? String).map { String($0.prefix(80)) }, title: (info["title"] as? String).map { String($0.prefix(80)) },
                           version: (info["version"] as? String).map { String($0.prefix(40)) })
        }
        let asked = params["protocolVersion"] as? String ?? protocolVersions[1]
        reply(id, [
            "protocolVersion": protocolVersions.contains(asked) ? asked : protocolVersions[1],
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "kemosabe", "title": "KemoSabe", "version": serverVersion],
            "instructions": "Use ask_kemosabe when you need a fact from the owner's private life (conversations, memories, notes about people, calendar, journal, docs). You get only the answer, never the source.",
        ])
    case "ping": reply(id, [:])
    case "tools/list": reply(id, ["tools": [tool]])
    case "tools/call": DispatchQueue.global(qos: .userInitiated).async(group: calls) { call(id, params) }
    case "resources/list": reply(id, ["resources": []])
    case "prompts/list": reply(id, ["prompts": []])
    default: fail(id, -32601, "Method not found: " + method)
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty else { continue }
    guard let data = line.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else {
        send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]]); continue
    }
    if let batch = object as? [[String: Any]] { batch.forEach(handle) }
    else if let message = object as? [String: Any] { handle(message) }
}
_ = calls.wait(timeout: .now() + .seconds(callTimeout + 5))

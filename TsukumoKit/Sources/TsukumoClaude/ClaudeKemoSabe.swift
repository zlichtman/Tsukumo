#if os(macOS)
import Foundation
import TsukumoCore
import TsukumoPolicy
import TsukumoEngines
import TsukumoGateway
import TsukumoUI

// The Claude bot never reads the owner's personal data. For anything personal it asks KemoSabe through the
// KemoSabe gateway's typed tools as its own caller ("Claude", listed in Settings, Gateway with Revoke), in this
// process: the same argument screen, grants, budgets, enumeration checks, cards, and disclosure ledger as any
// agent outside. A call that needs the owner puts the gateway's own card up (in KemoSabe's chat and the Claude
// panel); the task waits for the owner, then asks once more.

extension GatewayCaller {
    /// The Claude bot as the gateway lists it. Like a paired device it's connected only while it's listed, so Revoke
    /// cuts it off until the owner lets Claude ask KemoSabe again in its panel.
    public static func claudeBot(at date: Date = Date()) -> GatewayCaller {
        GatewayCaller(id: claudeBotID, name: "Claude", kind: .device, detail: "Tsukumo’s Claude bot, on this Mac", createdAt: date)
    }
}

/// The tools a Claude task gets for KemoSabe, and what they do.
public enum ClaudeKemoSabeTools {
    public static let ask = ToolDefinition(
        name: "ask_kemosabe",
        description: "Ask KemoSabe, the owner's on-device assistant, one short question about the owner (their plans, messages, places, preferences). It reads on the owner's Mac and answers only what the owner allows. Never guess personal facts; ask.",
        parameters: [.init(name: "question", description: "One short question."),
                     .init(name: "purpose", description: "Why you need it, in a few words.")])
    public static let freeBusy = ToolDefinition(
        name: "kemosabe_free_busy",
        description: "When the owner is busy or free between two times (at most 7 days, from yesterday to 60 days ahead). Returns busy and free blocks only, never what the events are.",
        parameters: [.init(name: "start", description: "ISO 8601 with a time zone, like 2026-10-08T00:00:00-07:00."),
                     .init(name: "end", description: "ISO 8601 with a time zone.")])
    public static let contactLookup = ToolDefinition(
        name: "kemosabe_contact_lookup",
        description: "A person in the owner's contacts, by full name: at most their first and last name and one way to reach them.",
        parameters: [.init(name: "name", description: "The person's full name."),
                     .init(name: "fields", description: "Optional, comma separated: first_name, last_name, email, phone.", required: false)])

    public static let all = [ask, freeBusy, contactLookup]

    /// The gateway tool and its arguments for one of these calls; nil for any other tool.
    static func gatewayCall(_ call: ToolCall) -> (GatewayToolName, [String: JSONValue])? {
        let trim: (String?) -> String = { ($0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        switch call.name {
        case ask.name:
            var arguments: [String: JSONValue] = ["question": .string(trim(call.arguments["question"]))]
            let purpose = trim(call.arguments["purpose"])
            if !purpose.isEmpty { arguments["purpose"] = .string(purpose) }
            return (.ask, arguments)
        case freeBusy.name:
            return (.freeBusy, ["start": .string(trim(call.arguments["start"])), "end": .string(trim(call.arguments["end"]))])
        case contactLookup.name:
            var arguments: [String: JSONValue] = ["name": .string(trim(call.arguments["name"]))]
            let fields = trim(call.arguments["fields"]).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !fields.isEmpty { arguments["fields"] = .array(fields.map { .string($0) }) }
            return (.contactLookup, arguments)
        default: return nil
        }
    }
}

/// What came of one question to KemoSabe.
public struct ClaudeKemoSabeReply: Hashable, Sendable {
    /// The gateway's status: ok, escalate, declined, not_found, refused, unavailable.
    public var status: String
    /// What goes back to Claude: the gateway's JSON, or words saying why there's nothing.
    public var text: String
    /// What KemoSabe shared (an `ask` answer), for the chat's card.
    public var answer: String?
    /// The owner was asked on a card.
    public var askedOwner: Bool
}

/// Calls the gateway's typed tools as the Claude bot, and waits on the owner's card when one is needed.
@MainActor public final class ClaudeKemoSabe {
    public let gateway: KemoSabeGateway
    /// How long a task waits for the owner to answer a card (the gateway keeps a card 15 minutes).
    public var cardWait: Duration = .seconds(15 * 60)
    /// How often the wait looks again.
    public var poll: Duration = .milliseconds(250)
    public init(gateway: KemoSabeGateway) { self.gateway = gateway }

    public var caller: GatewayCaller { gateway.store.caller(GatewayCaller.claudeBotID) ?? .claudeBot() }
    /// Listed among the gateway's callers (not revoked).
    public var isConnected: Bool { gateway.store.caller(GatewayCaller.claudeBotID) != nil }

    /// Lists the Claude bot among the gateway's callers (Settings, Gateway shows it with Revoke).
    public func connect() { if !isConnected { gateway.store.add(.claudeBot()) } }
    /// Takes it off: its grants, cards, and KemoSabe's consent go too.
    public func disconnect() { if let caller = gateway.store.caller(GatewayCaller.claudeBotID) { gateway.revoke(caller) } }


    /// One call of a typed tool. A card means the owner decides: the call waits for their answer (or the card's end),
    /// then, if they allowed it, asks once more (Allow once is used by that identical call).
    /// `onCard` hears the card go up, and come down (nil).
    public func call(_ tool: GatewayToolName, _ arguments: [String: JSONValue],
                     onCard: ((GatewayApprovalRequest?) -> Void)? = nil) async -> ClaudeKemoSabeReply {
        guard isConnected else {
            return ClaudeKemoSabeReply(status: "refused", text: "You can't ask KemoSabe: the owner turned that off for you. Carry on without personal details, or ask the owner.",
                                       answer: nil, askedOwner: false)
        }
        let first = await gateway.tools.call(tool: tool.rawValue, arguments: .object(arguments), caller: caller)
        guard first.status == "escalate" else { return Self.reply(first, askedOwner: false) }
        // The card for exactly this request, by the id the gateway returned (identical requests share one), never
        // whichever card for Claude happens to be newest.
        guard let requestID = first.structured["consent"]?["request"]?.stringValue.flatMap(UUID.init(uuidString:)),
              let card = gateway.desk.pending.first(where: { $0.id == requestID }) else { return Self.reply(first, askedOwner: false) }
        onCard?(card)
        defer { onCard?(nil) }
        var waited: Duration = .zero
        while gateway.desk.pending.contains(where: { $0.id == card.id }), waited < cardWait {
            do { try await Task.sleep(for: poll) } catch {
                return ClaudeKemoSabeReply(status: "refused", text: "Stopped.", answer: nil, askedOwner: true)
            }
            waited += poll
        }
        guard !Task.isCancelled else { return ClaudeKemoSabeReply(status: "refused", text: "Stopped.", answer: nil, askedOwner: true) }
        switch gateway.desk.peek(card.fingerprint) {
        case nil:
            return ClaudeKemoSabeReply(status: "declined", text: "The owner didn't answer KemoSabe's card in time. Nothing was shared. Carry on without it.",
                                       answer: nil, askedOwner: true)
        case .deny?:
            return ClaudeKemoSabeReply(status: "declined", text: "The owner said Don't allow. Nothing was shared. Carry on without it.", answer: nil, askedOwner: true)
        default:
            let second = await gateway.tools.call(tool: tool.rawValue, arguments: .object(arguments), caller: caller)
            if second.status == "escalate" {
                return ClaudeKemoSabeReply(status: "escalate", text: "KemoSabe needs the owner again for that. Carry on without it for now.", answer: nil, askedOwner: true)
            }
            return Self.reply(second, askedOwner: true)
        }
    }

    static func reply(_ result: GatewayToolResult, askedOwner: Bool) -> ClaudeKemoSabeReply {
        let status = result.status ?? "refused"
        let text: String
        switch status {
        case "escalate": text = "KemoSabe is waiting on the owner for that. Carry on without it for now."
        default: text = result.text
        }
        return ClaudeKemoSabeReply(status: status, text: text, answer: status == "ok" ? result.structured["answer"]?.stringValue : nil, askedOwner: askedOwner)
    }
}

/// KemoSabe for the Claude chat tab: the chat's `ask_kemosabe` goes through the gateway as the Claude bot too, so
/// the chat and the tasks share one identity, one ledger, and the owner's cards.
public final class ClaudeChatKemoSabe: KemoSabeAnswering {
    public let device = "Mac"
    private let ask: @Sendable (String, String) async -> ClaudeKemoSabeReply

    public init(_ kemoSabe: ClaudeKemoSabe) {
        ask = { question, purpose in
            var arguments: [String: JSONValue] = ["question": .string(question)]
            if !purpose.isEmpty { arguments["purpose"] = .string(purpose) }
            return await kemoSabe.call(.ask, arguments)
        }
    }
    init(ask: @escaping @Sendable (String, String) async -> ClaudeKemoSabeReply) { self.ask = ask }

    public func ask(_ question: KemoSabeQuestion, consent: @escaping @Sendable () async -> ConsentChoice,
                    share: @escaping @Sendable (SharePrompt) async -> Bool) async -> GateAnswerCard {
        let reply = await ask(question.question, question.purpose)
        let outcome: GateAnswerCard.Outcome = switch reply.status {
        case "ok": .answered
        case "declined", "escalate": .denied
        case "not_found": .nothingToShare
        default: .unavailable
        }
        return GateAnswerCard(exchange: question.exchange, askerName: question.asker.name, question: question.question, outcome: outcome,
                              shared: reply.answer, device: device)
    }
}
#endif

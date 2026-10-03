import Foundation
import TsukumoCore

// The seams between the chat and the modules that run it. Each is a small protocol, so the chat can be
// tested with stand-ins, and each module plugs in through one adapter (KitAdapters.swift): TsukumoEngines'
// `Engine` through `EngineRunner`, TsukumoGate's `Gate` through `GateAnswerer`, and TsukumoSystemOne's
// `route` through `SystemOneRouter`.

// MARK: Running a turn (TsukumoEngines)

/// One bot's turn on one owner message.
public struct BotTurn: Sendable {
    public let bot: BotSpec
    /// The owner's message that started it.
    public let message: Message
    /// The thread up to and including `message`.
    public let thread: ChatThread
    /// Every bot, so an engine can name the others.
    public let bots: [BotSpec]
    /// The `ask_kemosabe` tool: asks KemoSabe a question about the owner, with why. Returns exactly
    /// what KemoSabe shared, or nil when it shared nothing (the card in the chat says why).
    public let askKemoSabe: @Sendable (_ question: String, _ purpose: String) async -> String?

    public init(bot: BotSpec, message: Message, thread: ChatThread, bots: [BotSpec],
                askKemoSabe: @escaping @Sendable (_ question: String, _ purpose: String) async -> String?) {
        self.bot = bot; self.message = message; self.thread = thread; self.bots = bots; self.askKemoSabe = askKemoSabe
    }
}

/// What a running turn reports.
public enum BotTurnEvent: Sendable, Equatable {
    /// More of the reply.
    case text(String)
    /// A line about the bot itself ("Claude isn't connected").
    case status(String)
}

/// Runs bots' turns. TsukumoEngines' `Engine.run(_:)` plugs in here.
public protocol BotTurnRunning: Sendable {
    func run(_ turn: BotTurn) -> AsyncThrowingStream<BotTurnEvent, Error>
}

// MARK: Asking KemoSabe (TsukumoGate)

/// A bot's question to KemoSabe.
public struct KemoSabeQuestion: Sendable, Hashable {
    public let exchange: GateExchangeID
    public let asker: BotSpec
    public let question: String
    public let purpose: String
    public init(exchange: GateExchangeID = GateExchangeID(), asker: BotSpec, question: String, purpose: String) {
        self.exchange = exchange; self.asker = asker; self.question = question; self.purpose = purpose
    }
}

/// The owner's answer the first time a bot asks KemoSabe something.
public enum ConsentChoice: String, Sendable, Hashable, CaseIterable {
    case always, once, deny
    public var title: String {
        switch self {
        case .always: "Allow always"
        case .once: "Allow once"
        case .deny: "Don’t allow"
        }
    }
}

/// "Share this with Claude?": one Sensitive item KemoSabe found the answer in, and exactly what would
/// be sent. The owner shares or declines that one item on KemoSabe's card.
public struct SharePrompt: Sendable, Hashable {
    /// Exactly what would be sent ("Tuesday at 4").
    public let answer: String
    /// Where it was found ("your conversation with Sarah").
    public let sourceTitle: String
    public let level: PrivacyLevel
    public init(answer: String, sourceTitle: String, level: PrivacyLevel) { self.answer = answer; self.sourceTitle = sourceTitle; self.level = level }
}

/// KemoSabe answering a bot: consent (through `consent`, which shows the card's buttons and waits for
/// the owner), policy, on-device extraction, a share card for one Sensitive item (`share`), a
/// single-use answer, and the journal. `GateAnswerer` puts TsukumoGate's `Gate` here.
public protocol KemoSabeAnswering: Sendable {
    /// The device that answers, as cards name it ("iPhone", "Mac").
    var device: String { get }
    func ask(_ question: KemoSabeQuestion, consent: @escaping @Sendable () async -> ConsentChoice,
             share: @escaping @Sendable (SharePrompt) async -> Bool) async -> GateAnswerCard
}

// MARK: Routing an untagged message (TsukumoSystemOne)

/// System One's pick for an untagged message.
public struct RouteChoice: Sendable, Hashable {
    public let bot: UUID
    /// Why, in words for Activity ("It knows your calendar").
    public let reason: String
    public init(bot: UUID, reason: String) { self.bot = bot; self.reason = reason }
}

/// Picks a bot for an untagged message, or abstains (nil), and the thread's fallback runs.
/// TsukumoSystemOne's `route` decision plugs in here.
public protocol TurnRouting: Sendable {
    func route(text: String, thread: ChatThread, bots: [BotSpec]) async -> RouteChoice?
}

// MARK: Activity

/// One thing that happened, for the Activity feed: KemoSabe's answers and refusals, System One's
/// decisions, and bots' work. TsukumoGate's journal and TsukumoSystemOne's decision journal feed it too.
public struct ActivityItem: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case kemoSabeAnswer, kemoSabeRefusal, systemOne, botWork
        public init(from decoder: Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .botWork
        }
    }
    public var id: UUID
    public var date: Date
    public var kind: Kind
    /// "Answered Claude"
    public var title: String
    /// "“What time is Sarah free tonight?” Shared “After 7 tonight”."
    public var detail: String
    /// The bot it's about.
    public var botID: UUID?
    /// The thread it happened in, so Activity can open it.
    public var threadID: UUID?

    public init(id: UUID = UUID(), date: Date = Date(), kind: Kind, title: String, detail: String, botID: UUID? = nil, threadID: UUID? = nil) {
        self.id = id; self.date = date; self.kind = kind; self.title = title; self.detail = detail; self.botID = botID; self.threadID = threadID
    }

    /// The item for KemoSabe's answer card.
    public static func gate(_ card: GateAnswerCard, botID: UUID?, threadID: UUID?, date: Date = Date()) -> ActivityItem {
        switch card.outcome {
        case .answered:
            let parts = ["“\(card.question)”", card.shared.map { "Shared “\($0)”." }, card.stayedLine.map { $0 + "." }, card.notReadLine]
            return ActivityItem(date: date, kind: .kemoSabeAnswer, title: "Answered \(card.askerName)",
                                detail: parts.compactMap { $0 }.joined(separator: " "), botID: botID, threadID: threadID)
        case .denied, .nothingToShare, .unavailable:
            let why = switch card.outcome {
            case .denied: "You said Don’t allow."
            case .nothingToShare: "Nothing \(card.askerName) may have could answer it."
            default: "KemoSabe couldn’t answer on this \(card.device)."
            }
            return ActivityItem(date: date, kind: .kemoSabeRefusal, title: "Didn’t answer \(card.askerName)",
                                detail: "“\(card.question)” \(why)", botID: botID, threadID: threadID)
        }
    }
}

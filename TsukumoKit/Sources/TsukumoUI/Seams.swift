import Foundation
import TsukumoCore
import TsukumoEngines
import TsukumoPolicy

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
    /// Asks the owner about something a coding agent wants to do that the bot's access leaves to them
    /// ("Edit Sources/App.swift"): true allows it. Nil answers no.
    public let approve: (@Sendable (ApprovalRequest) async -> Bool)?
    /// A task from an outside caller (Muse): no history, no saved engine session, no references, and no tools,
    /// so the bot works only from what the caller sent. Coding agents never run isolated turns.
    public let isolated: Bool

    public init(bot: BotSpec, message: Message, thread: ChatThread, bots: [BotSpec],
                approve: (@Sendable (ApprovalRequest) async -> Bool)? = nil, isolated: Bool = false,
                askKemoSabe: @escaping @Sendable (_ question: String, _ purpose: String) async -> String?) {
        self.bot = bot; self.message = message; self.thread = thread; self.bots = bots; self.approve = approve; self.isolated = isolated
        self.askKemoSabe = askKemoSabe
    }
}

/// What a running turn reports.
public enum BotTurnEvent: Sendable, Equatable {
    /// More of the reply.
    case text(String)
    /// A line about the bot itself ("Claude isn't connected").
    case status(String)
    /// What a coding agent is doing (the dock's work cues follow it).
    case activity(CodingActivity)
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
    /// A question from a caller outside the owner's bots (Muse, through Tsukumo's Dock as a Muse gadget), as
    /// its own recipient with its own consent. No bot's limits apply; KemoSabe's own do.
    func ask(caller: KemoSabeCaller, exchange: GateExchangeID, question: String, purpose: String,
             consent: @escaping @Sendable () async -> ConsentChoice, share: @escaping @Sendable (SharePrompt) async -> Bool) async -> GateAnswerCard
    /// A bot's reply to an outside caller's task, released to that caller only through KemoSabe: its consent
    /// (asked the first time), sealed for it, and journaled. `question` is what the card asks the owner.
    func release(_ text: String, source: String, to caller: KemoSabeCaller, exchange: GateExchangeID, question: String, purpose: String,
                 consent: @escaping @Sendable () async -> ConsentChoice) async -> GateAnswerCard
    /// Ends an exchange's wait at KemoSabe at once (its prompt or card comes down), deciding nothing: the chat
    /// was stopped, or the card's wait arrived after its exchange ended.
    @MainActor func withdraw(_ exchange: GateExchangeID)
    /// An answer KemoSabe handed over that the chat then dropped (its asker stopped): it was never delivered, so
    /// the journal mustn't say it was shared, and its stored copy goes.
    @MainActor func undelivered(_ exchange: GateExchangeID)
}

/// An agent that isn't one of the owner's bots, asking KemoSabe through Tsukumo ("Muse"). It's its own
/// recipient, so the owner's consent for it is its own, and it never borrows a bot's.
public struct KemoSabeCaller: Sendable, Hashable {
    public let requester: RecipientID
    /// "Muse", or "Muse, through Claude" for a bot's turn Muse asked for.
    public let name: String
    public init(requester: RecipientID, name: String) { self.requester = requester; self.name = name }
}

extension KemoSabeAnswering {
    /// Without a Gate behind it, KemoSabe answers no caller.
    public func ask(caller: KemoSabeCaller, exchange: GateExchangeID, question: String, purpose: String,
                    consent: @escaping @Sendable () async -> ConsentChoice, share: @escaping @Sendable (SharePrompt) async -> Bool) async -> GateAnswerCard {
        GateAnswerCard(exchange: exchange, askerName: caller.name, question: question, outcome: .unavailable, device: device)
    }
    /// Without a Gate behind it, nothing waits there.
    @MainActor public func withdraw(_ exchange: GateExchangeID) {}
    @MainActor public func undelivered(_ exchange: GateExchangeID) {}

    /// Without a Gate behind it, nothing is released.
    public func release(_ text: String, source: String, to caller: KemoSabeCaller, exchange: GateExchangeID, question: String, purpose: String,
                        consent: @escaping @Sendable () async -> ConsentChoice) async -> GateAnswerCard {
        GateAnswerCard(exchange: exchange, askerName: caller.name, question: question, outcome: .unavailable, device: device)
    }
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

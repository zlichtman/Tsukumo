import Foundation
import TsukumoCore
import TsukumoPolicy
import TsukumoContext
import TsukumoGate
import TsukumoEngines

/// The website demo, beat for beat (docs/ARCHITECTURE.md#the-demo-mapped), with the exact text and
/// pacing of the old app's `ChatHandoffFixture`. The same every run, about 20 seconds, ending on a
/// still frame:
///
/// 1. After 1.5 s the message types into the composer (16 characters a second), and after a 0.5 s
///    pause it sends to Claude.
/// 2. Claude works for 2.5 s.
/// 3. Claude asks KemoSabe "What time is Sarah free tonight?".
/// 4. KemoSabe's card: it reads this device for 2.5 s (consent is already Allow always for Claude),
///    then answers "After 7 tonight", with what stayed, what it didn't read (a Device only chat), and
///    what was shared.
/// 5. Claude works for 3 s, then recommends Osteria Lucia on Valencia at 7:30. Then nothing moves.
///
/// Only Claude and the extractor are stand-ins: a fake Claude engine runs in-process (through
/// `EngineRunner` and `TurnTools`, so its `ask_kemosabe` call is a real tool call), and a fixed
/// extractor stands in for Apple's on-device model. KemoSabe is TsukumoGate's real `Gate`, so the
/// policy decides what it reads: Sarah's chat says she's free after 7, and a Device only chat (a
/// door code) is never read for Claude.
public enum DemoFixture {
    public static let task = "find a date spot for Sarah and I tonight"
    public static let question = "What time is Sarah free tonight?"
    public static let purpose = "planning a date tonight"
    public static let answer = "After 7 tonight"
    public static let result = "Sarah’s free after 7. Book Osteria Lucia on Valencia for 7:30: it’s quiet and candlelit, and a short walk from her place."

    /// The fixed pacing, in seconds.
    public static let typingStart = 1.5, typingSpeed = 16.0, sendPause = 0.5, working = 2.5, looking = 2.5, finishing = 3.0

    public static let claudeID = UUID(uuidString: "5A3C0DE0-7A1E-4C6B-9E2A-0000000007C1")!
    /// Claude's API connection in the demo (the app maps it to "Claude" and its spark).
    public static let claudeProfile = UUID(uuidString: "5A3C0DE0-7A1E-4C6B-9E2A-0000000007C2")!
    public static let threadID = UUID(uuidString: "5A3C0DE0-7A1E-4C6B-9E2A-000000000720")!
    /// Midnight, September 26, 2026 UTC: the demo's clock, so its saved files never change.
    public static let start = Date(timeIntervalSince1970: 1_790_380_800)

    public static var claude: BotSpec {
        BotSpec(id: claudeID, name: "Claude", engine: .api(profile: claudeProfile), model: "claude-opus-5-5",
                role: "Plans with you, on your Claude key", service: .claude,
                contextScope: ContextScope(ceiling: .personal, mayAskKemoSabe: true))
    }
    public static var bots: [BotSpec] { [.kemoSabe(), claude] }
    public static var engineInfo: @Sendable (EngineID) -> EngineInfo {
        { engine in
            if case .api(let profile) = engine, profile == claudeProfile { return EngineInfo(title: "Claude", detail: "Anthropic API", mark: .claude) }
            return EngineInfo.standard(engine)
        }
    }
    /// The empty chat the demo starts from, with Claude tagged.
    public static var emptyThread: ChatThread {
        ChatThread(id: threadID, title: "Date night", botIDs: bots.map(\.id), lastSpokenTo: claudeID)
    }


    /// The answer card the fake KemoSabe gives: read on this iPhone, "After 7 tonight".
    public static func answerCard(exchange: GateExchangeID, device: String = "iPhone") -> GateAnswerCard {
        var card = GateAnswerCard(exchange: exchange, askerName: "Claude", question: question, outcome: .answered,
                                  shared: answer, stayed: "4 messages, 2 chats", device: device)
        card.notRead = "1 Device only chat"
        return card
    }

    // MARK: The final frame

    /// The thread as the demo ends: the owner's message, KemoSabe's answer, and Claude's reply.
    public static var finalThread: ChatThread {
        var thread = emptyThread
        let exchange = GateExchangeID(rawValue: UUID(uuidString: "5A3C0DE0-7A1E-4C6B-9E2A-0000000007E1")!)
        let sent = start.addingTimeInterval(typingStart + Double(task.count) / typingSpeed + sendPause)
        thread.messages = [
            Message(id: UUID(uuidString: "5A3C0DE0-7A1E-4C6B-9E2A-0000000007A1")!, date: sent, author: .owner, parts: [.text(task)], tags: [claudeID]),
            Message(id: UUID(uuidString: "5A3C0DE0-7A1E-4C6B-9E2A-0000000007A2")!, date: sent.addingTimeInterval(working + looking),
                    author: .bot(BotSpec.kemoSabeID), parts: [.gateAnswer(answerCard(exchange: exchange))]),
            Message(id: UUID(uuidString: "5A3C0DE0-7A1E-4C6B-9E2A-0000000007A3")!, date: sent.addingTimeInterval(working + looking + finishing),
                    author: .bot(claudeID), parts: [.text(result)])
        ]
        return thread
    }

    // MARK: Personal sources KemoSabe reads in the demo

    /// The chats on the demo's iPhone: Sarah's (Personal), Maya's (Open), and a Device only one with a
    /// door code that KemoSabe must never read for Claude.
    public struct Chats: PersonalSource {
        public init() {}
        public func items(matching question: GateQuestion) async -> [PersonalItem] {
            [
                PersonalItem(id: "chat-sarah", kind: .textMessage, level: .personal, title: "Sarah",
                             text: "Me: Dinner tonight?\nSarah: Tonight works! I'm free after 7.\nMe: I'll find somewhere.",
                             date: DemoFixture.start, messages: 3, matched: true),
                PersonalItem(id: "chat-maya", kind: .textMessage, level: .open, title: "Maya",
                             text: "Maya: Book club moved to Thursday.", date: DemoFixture.start.addingTimeInterval(-3600), messages: 1, matched: true),
                PersonalItem(id: "chat-sarah-door", kind: .textMessage, level: .deviceOnly, title: "Sarah",
                             text: "Sarah: The new door code is 4411 if you get there before me tonight.",
                             date: DemoFixture.start.addingTimeInterval(-7200), messages: 1, matched: true)
            ]
        }
    }

    /// Stands in for Apple's on-device model (as the old fixture's `FakeExtraction` did): after the
    /// demo's looking pause, it finds when Sarah's free. The Gate still checks its answer against the
    /// text it read.
    public struct Extractor: ExtractionModel {
        public let pace: Double
        public let isAvailable = true
        public init(pace: Double = 1) { self.pace = pace }
        public func extract(lookingFor: String, from text: String) async throws -> ExtractionDraft {
            try await Task.sleep(for: .seconds(DemoFixture.looking * pace))
            guard let line = text.split(separator: "\n").first(where: { $0.contains("free after 7") }) else {
                return ExtractionDraft(found: false, answer: "", excerpt: "")
            }
            return ExtractionDraft(found: true, answer: DemoFixture.answer, excerpt: String(line))
        }
    }

    // MARK: Claude

    /// Fake Claude, an engine like any other: it works, calls `ask_kemosabe`, works, and replies.
    /// `pace` scales every pause (tests use a small one).
    public struct ClaudeEngine: Engine {
        public let pace: Double
        public var id: EngineID { .api(profile: DemoFixture.claudeProfile) }
        public init(pace: Double = 1) { self.pace = pace }
        public func run(_ turn: EngineTurn) -> AsyncThrowingStream<EngineEvent, Error> {
            let pace = self.pace
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        try await Task.sleep(for: .seconds(DemoFixture.working * pace))
                        let call = ToolCall(id: "ask-1", name: TurnTools.askKemoSabe.name,
                                            arguments: ["question": DemoFixture.question, "purpose": DemoFixture.purpose])
                        if turn.tools.contains(TurnTools.askKemoSabe), let runTool = turn.runTool {
                            continuation.yield(.toolCall(call))
                            continuation.yield(.toolResult(id: call.id, text: await runTool(call)))
                        }
                        try await Task.sleep(for: .seconds(DemoFixture.finishing * pace))
                        continuation.yield(.text(DemoFixture.result))
                        continuation.yield(.done(EngineReply(text: DemoFixture.result, toolCalls: [call])))
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    /// Claude as the policy and the Gate name it.
    public static var claudeRecipient: RecipientID { .apiModel(profile: claudeProfile, host: "api.anthropic.com") }

    // MARK: Playing it

    /// KemoSabe for the demo: TsukumoGate's `Gate`, reading the demo's chats with the demo's extractor.
    /// Claude is already allowed (Allow always), unless `asksFirst`.
    @MainActor public static func gate(pace: Double = 1, asksFirst: Bool = false, device: String = "iPhone") -> Gate {
        let grants = asksFirst ? [] : [RecipientGrant(recipient: claudeRecipient, kinds: Gate.consentKinds, purpose: .agentQuestion, grantedAt: start)]
        let gate = Gate(model: Extractor(pace: pace), sources: [Chats()], grants: grants, answers: try? ArtifactStore(), deviceName: device)
        gate.apply(bots: bots)
        return gate
    }

    /// Runs Claude on the demo's engine; any other bot says it isn't in the demo.
    public static func runner(pace: Double = 1) -> EngineRunner {
        let store = (try? ArtifactStore()) ?? { fatalError("An in-memory artifact store always opens.") }()
        return EngineRunner(store: store) { bot in
            bot.id == claudeID ? .success(ResolvedEngine(engine: ClaudeEngine(pace: pace), recipient: claudeRecipient))
                : .failure(.init("\(bot.name) isn’t in the demo."))
        }
    }

    /// Types the message into the composer and sends it, at the demo's pace.
    @MainActor public static func play(_ session: ChatSession, pace: Double = 1) async {
        session.chips = [claudeID]
        try? await Task.sleep(for: .seconds(typingStart * pace))
        var typed = ""
        for character in task {
            typed.append(character)
            session.draft = typed
            try? await Task.sleep(for: .seconds(pace / typingSpeed))
        }
        try? await Task.sleep(for: .seconds(sendPause * pace))
        session.send()
    }

    /// A chat session that plays the demo through the real Gate, policy, and engine runner.
    @MainActor public static func session(pace: Double = 1, asksFirst: Bool = false, device: String = "iPhone") -> ChatSession {
        ChatSession(thread: emptyThread, bots: bots, runner: runner(pace: pace),
                    gate: GateAnswerer(gate: gate(pace: pace, asksFirst: asksFirst, device: device)) { _ in "api.anthropic.com" })
    }
}

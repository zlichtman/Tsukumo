import Foundation
import Testing
@testable import TsukumoCore

/// Saved data round-trips, and data from a newer build loads without losing what it doesn't know.
struct CodableTests {
    func roundTrip<T: Codable>(_ value: T) throws -> T {
        try TsukumoJSON.decoder.decode(T.self, from: TsukumoJSON.encoder.encode(value))
    }
    func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try TsukumoJSON.decoder.decode(T.self, from: Data(json.utf8))
    }

    let date = Date(timeIntervalSince1970: 1_790_000_000)  // whole seconds: ISO 8601 keeps no fractions
    let ref = ArtifactRef(id: ArtifactID(), revision: 3, sha256: String(repeating: "ab", count: 32))

    @Test func botSpecRoundTrips() throws {
        let bot = BotSpec(name: "Pip", engine: .api(profile: UUID()), model: "claude-opus-5-5", effort: "high", role: "Plans dates",
                          look: BotLook(shape: .mochi, palette: "matcha", eyes: .sparkle, prop: .book, topper: .leaf),
                          contextScope: ContextScope(project: "/tmp/p", ceiling: .sensitive, mayAskKemoSabe: false),
                          permissions: BotPermissions(access: .autoEdit, approvalsHere: false, mayChirp: false, speaks: false))
        #expect(try roundTrip(bot) == bot)
        #expect(try roundTrip(BotSpec.kemoSabe()) == BotSpec.kemoSabe())
    }

    @Test func engineIDsRoundTripAndKeepUnknownOnes() throws {
        let profile = UUID()
        for engine: EngineID in [.appleOnDevice, .api(profile: profile), .codingAgent("codex"), .acp("gemini"), .mlx("qwen3-8b")] {
            #expect(try roundTrip(engine) == engine)
            #expect(EngineID(key: engine.key) == engine)
        }
        #expect(EngineID(key: "quantum:qubit") == .unknown("quantum:qubit"))
        #expect(try roundTrip(EngineID.unknown("quantum:qubit")).key == "quantum:qubit")
        #expect(EngineID(key: "api:not-a-uuid") == .unknown("api:not-a-uuid"))
        #expect(EngineID.codingAgent("codex").runsOnlyOnMac)
        #expect(!EngineID.appleOnDevice.runsOnlyOnMac && EngineID.appleOnDevice.isOnDevice)
    }

    @Test func olderBotsTakeDefaultsAndNewerFieldsAreIgnored() throws {
        let id = UUID()
        let bot = try decode(BotSpec.self, """
        {"id":"\(id.uuidString)","name":"Old","engine":"apple-on-device","futureField":{"x":1},
         "look":{"shape":"hexagon","palette":"sky","eyes":"lasers"},"permissions":{"access":"godMode"}}
        """)
        #expect(bot.role == "")
        #expect(bot.look.shape == .bean && bot.look.eyes == .dots && bot.look.palette == "sky")
        #expect(bot.permissions.access == .readOnly)
        #expect(bot.contextScope == ContextScope())
    }

    @Test func unknownPrivacyLevelIsTheMostPrivate() throws {
        #expect(try decode([PrivacyLevel].self, #"["open","ultraSecret"]"#) == [.open, .secret])
    }

    @Test func messageWithEveryPartRoundTrips() throws {
        let exchange = GateExchangeID()
        let message = Message(date: date, author: .bot(UUID()), parts: [
            .text("Osteria Lucia on Valencia at 7:30"),
            .status("Working"),
            .artifact(ref),
            .gateQuestion(GateQuestionCard(exchange: exchange, askedBy: UUID(), askerName: "Claude",
                                           question: "What time is Sarah free tonight?", purpose: "planning a date", state: .needsConsent)),
            .gateAnswer(GateAnswerCard(exchange: exchange, askerName: "Claude", question: "What time is Sarah free tonight?",
                                       outcome: .answered, shared: "After 7 tonight", stayed: "7 messages, 2 chats",
                                       device: "iPhone", answer: ref))
        ], tags: [UUID()])
        #expect(try roundTrip(message) == message)
        #expect(message.references == [ref])
        #expect(message.text == "Osteria Lucia on Valencia at 7:30")
    }

    @Test func unknownFuturePartsSurviveARoundTrip() throws {
        let json = """
        {"id":"\(UUID().uuidString)","date":"2026-10-01T12:00:00Z","author":"owner","tags":[],
         "parts":[{"type":"text","text":"hi"},{"type":"hologram","frames":[1,2,3],"meta":{"fps":24,"loop":true,"by":null}}]}
        """
        let message = try decode(Message.self, json)
        #expect(message.parts.count == 2)
        guard case .unknown(let value) = message.parts[1] else { Issue.record("expected an unknown part"); return }
        #expect(value["type"]?.stringValue == "hologram")
        let again = try roundTrip(message)
        #expect(again == message)
        let written = String(decoding: try TsukumoJSON.encoder.encode(again), as: UTF8.self)
        #expect(written.contains("\"hologram\"") && written.contains("\"fps\":24"))
    }

    @Test func unknownAuthorsAndCardStatesDegradeGently() throws {
        #expect(try decode(Author.self, #""alien:1""#) == .system)
        #expect(try decode(GateAnswerCard.Outcome.self, #""teleported""#) == .unavailable)
        #expect(try decode(GateQuestionCard.State.self, #""pondering""#) == .reading)
    }

    @Test func threadRoundTrips() throws {
        let bot = UUID()
        var thread = ChatThread(title: "Date night", botIDs: [bot])
        thread.send("find a date spot for Sarah and I tonight", to: [bot], date: date)
        thread.append(Message(date: date, author: .bot(bot), parts: [.text("On it")]))
        #expect(try roundTrip(thread) == thread)
        let sparse = try decode(ChatThread.self, #"{"id":"\#(UUID().uuidString)"}"#)
        #expect(sparse.botIDs.isEmpty && sparse.messages.isEmpty && sparse.title.isEmpty)
    }

    @Test func answerCardCaptions() {
        let card = GateAnswerCard(exchange: GateExchangeID(), askerName: "Claude", question: "q", outcome: .answered,
                                  shared: "After 7 tonight", stayed: "7 messages, 2 chats", device: "iPhone")
        #expect(card.caption == "On this iPhone · Apple on-device")
        #expect(card.stayedLine == "Stayed on this iPhone: 7 messages, 2 chats")
    }
}

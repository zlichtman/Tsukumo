import Foundation
import Testing
import TsukumoCore
import TsukumoPolicy
import TsukumoGate
import TsukumoContext
import TsukumoEngines
@testable import TsukumoUI

/// A source with one Sensitive chat: the Gate must put it on a share card, never send it on its own.
struct SensitiveChats: PersonalSource {
    func items(matching question: GateQuestion) async -> [PersonalItem] {
        [PersonalItem(id: "chat-doctor", kind: .textMessage, level: .sensitive, title: "Dr. Lee",
                      text: "Dr. Lee: You're free after 7 tonight, the results can wait.", messages: 1, matched: true)]
    }
}

/// An engine that streams nothing and answers whole at the end, like a non-streaming API connection.
struct WholeReplyEngine: Engine {
    var id: EngineID { .api(profile: UUID()) }
    func run(_ turn: EngineTurn) -> AsyncThrowingStream<EngineEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.done(EngineReply(text: "Saw \(turn.history.count) earlier turns; tools: \(turn.tools.map(\.name).joined(separator: ","))")))
            continuation.finish()
        }
    }
}

@MainActor struct KitAdapterTests {
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<1000 { if condition() { return true }; try? await Task.sleep(for: .milliseconds(5)) }
        return condition()
    }

    @Test func theDemoRunsThroughTheRealGateAndPolicy() async {
        let gate = DemoFixture.gate(pace: 0.001)
        let session = ChatSession(thread: DemoFixture.emptyThread, bots: DemoFixture.bots, runner: DemoFixture.runner(pace: 0.001),
                                  gate: GateAnswerer(gate: gate) { _ in "api.anthropic.com" })
        await DemoFixture.play(session, pace: 0.001)
        #expect(await eventually { session.events.contains(.replied(DemoFixture.claudeID)) })
        // The journal says exactly what went to Claude, and only counts what was left out.
        let journal = await gate.journal.all()
        #expect(journal.count == 1)
        #expect(journal.first?.shared == "After 7 tonight")
        #expect(journal.first?.withheld == "Not read: 1 Device only chat.")
        #expect(journal.first.map { !String(describing: $0).contains("4411") } == true)
        // The answer is kept on the device as an artifact the card points at.
        let card = session.thread.messages.compactMap { message -> GateAnswerCard? in
            if case .gateAnswer(let card) = message.parts.first { card } else { nil }
        }.first
        #expect(card?.answer != nil)
    }

    @Test func aSensitiveItemGoesOnAShareCard() async {
        let pip = BotSpec(name: "Pip", engine: .api(profile: UUID()), look: BotLook(shape: .mochi, palette: "sky", eyes: .dots))
        let gate = Gate(model: DemoFixture.Extractor(pace: 0.001), sources: [SensitiveChats()],
                        grants: [RecipientGrant(recipient: .bot(pip, host: "unknown"), kinds: Gate.consentKinds, purpose: .agentQuestion)],
                        deviceName: "iPhone")
        let session = ChatSession(thread: ChatThread(botIDs: [BotSpec.kemoSabeID, pip.id]), bots: [.kemoSabe(), pip],
                                  runner: EchoRunner(), gate: GateAnswerer(gate: gate))
        session.chips = [pip.id]
        session.draft = "am I free tonight?"
        session.send()
        #expect(await eventually { !session.sharePrompts.isEmpty })
        guard let (exchange, prompt) = session.sharePrompts.first else { return }
        // The card shows exactly what would be sent, and where it came from.
        #expect(prompt.level == .sensitive)
        #expect(prompt.sourceTitle == "Dr. Lee")
        session.decideShare(true, for: exchange)
        #expect(await eventually { !session.isBusy })
        #expect(session.thread.messages.last?.text == "KemoSabe said: \(prompt.answer)")
    }

    @Test func withheldSummariesSplitIntoTheCardsLines() {
        let both = GateAnswerer.withheldLines("Not read: 1 Device only chat. Not shared: 2 Sensitive chats.")
        #expect(both.notRead == "1 Device only chat")
        #expect(both.notShared == "2 Sensitive chats")
        let one = GateAnswerer.withheldLines("Not shared: 1 Sensitive contact.")
        #expect(one.notRead == nil && one.notShared == "1 Sensitive contact")
        #expect(GateAnswerer.withheldLines("").notRead == nil)
    }

    @Test func aBotSeesOnlyItsOwnPartOfTheChat() {
        let claude = DemoFixture.claude
        let pip = BotSpec(name: "Pip", engine: .appleOnDevice, look: BotLook(shape: .mochi, palette: "sky", eyes: .dots))
        var thread = ChatThread(botIDs: [pip.id, claude.id])
        thread.messages = [
            .owner("to both", tags: [pip.id, claude.id]),
            Message(author: .bot(pip.id), parts: [.text("Pip's reply")]),
            Message(author: .bot(BotSpec.kemoSabeID), parts: [.gateAnswer(DemoFixture.answerCard(exchange: GateExchangeID()))]),
            Message(author: .bot(claude.id), parts: [.text("Claude's reply")]),
            .owner("only Pip", tags: [pip.id]),
            .owner("to Claude", tags: [claude.id])
        ]
        let turn = BotTurn(bot: claude, message: thread.messages.last!, thread: thread, bots: [pip, claude]) { _, _ in nil }
        #expect(turn.visibleHistory == [EngineMessage(role: .user, text: "to both"), EngineMessage(role: .assistant, text: "Claude's reply")])
    }

    @Test func engineRunnerOffersToolsAndDeliversAWholeReply() async throws {
        let pip = BotSpec(name: "Pip", engine: .api(profile: UUID()), look: BotLook(shape: .mochi, palette: "sky", eyes: .dots))
        let runner = EngineRunner(store: try ArtifactStore()) { _ in
            .success(ResolvedEngine(engine: WholeReplyEngine(), recipient: .apiModel(profile: UUID(), host: "example.com")))
        }
        let message = Message.owner("hi", tags: [pip.id])
        let turn = BotTurn(bot: pip, message: message, thread: ChatThread(botIDs: [pip.id], messages: [message]), bots: [pip]) { _, _ in nil }
        var text = ""
        for try await event in runner.run(turn) { if case .text(let delta) = event { text += delta } }
        #expect(text == "Saw 0 earlier turns; tools: read_reference,ask_kemosabe")

        // A bot that may not ask KemoSabe isn't offered the tool; an engine that can't run here says why.
        var quiet = pip
        quiet.contextScope.mayAskKemoSabe = false
        text = ""
        for try await event in runner.run(BotTurn(bot: quiet, message: message, thread: turn.thread, bots: [quiet]) { _, _ in nil }) {
            if case .text(let delta) = event { text += delta }
        }
        #expect(text.hasSuffix("tools: read_reference"))
        let mac = EngineRunner(store: try ArtifactStore()) { bot in .failure(.init("\(bot.name) runs on a Mac.")) }
        var events: [BotTurnEvent] = []
        for try await event in mac.run(turn) { events.append(event) }
        #expect(events == [.status("Pip runs on a Mac.")])
    }
}


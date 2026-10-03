import Foundation
import Testing
import TsukumoCore
@testable import TsukumoUI

/// Echoes the message back, after asking KemoSabe when the message has a "?".
struct EchoRunner: BotTurnRunning {
    func run(_ turn: BotTurn) -> AsyncThrowingStream<BotTurnEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                if turn.message.text.contains("?") {
                    let shared = await turn.askKemoSabe("When am I free?", "testing")
                    continuation.yield(.text("KemoSabe said: \(shared ?? "nothing")"))
                } else {
                    continuation.yield(.text(turn.bot.name + " heard: "))
                    continuation.yield(.text(turn.message.text))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Never finishes until cancelled.
struct StuckRunner: BotTurnRunning {
    func run(_ turn: BotTurn) -> AsyncThrowingStream<BotTurnEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do { try await Task.sleep(for: .seconds(60)); continuation.finish() } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

struct PickRouter: TurnRouting {
    let pick: UUID?
    func route(text: String, thread: ChatThread, bots: [BotSpec]) async -> RouteChoice? {
        pick.map { RouteChoice(bot: $0, reason: "It knows your projects.") }
    }
}

@MainActor struct ChatSessionTests {
    let pip = BotSpec(name: "Pip", engine: .api(profile: UUID()), look: BotLook(shape: .mochi, palette: "sky", eyes: .dots))
    let bramble = BotSpec(name: "Bramble Bot", engine: .api(profile: UUID()), look: BotLook(shape: .pebble, palette: "moss", eyes: .ovals))
    var bots: [BotSpec] { [.kemoSabe(), pip, bramble] }

    private func session(runner: any BotTurnRunning = EchoRunner(), gate: (any KemoSabeAnswering)? = nil,
                         router: (any TurnRouting)? = nil, lastSpokenTo: UUID? = nil) -> ChatSession {
        ChatSession(thread: ChatThread(botIDs: bots.map(\.id), lastSpokenTo: lastSpokenTo), bots: bots, runner: runner, gate: gate ?? GateAnswerer(gate: DemoFixture.gate(pace: 0.001)), router: router)
    }
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<1000 { if condition() { return true }; try? await Task.sleep(for: .milliseconds(5)) }
        return condition()
    }

    @Test func chipsTagAndEachTaggedBotTakesOneTurn() async {
        let chat = session()
        chat.chips = [pip.id, bramble.id]
        chat.draft = "hello"
        #expect(chat.placeholder == "Message Pip and Bramble Bot…")
        let sent = chat.send()
        #expect(sent?.tags == [pip.id, bramble.id])
        #expect(await eventually { chat.working.isEmpty && chat.thread.messages.count == 3 })
        #expect(chat.thread.messages.dropFirst().map(\.text).sorted() == ["Bramble Bot heard: hello", "Pip heard: hello"])
    }

    @Test func mentionsTagByNameAndComplete() async {
        let chat = session()
        chat.draft = "hey @Bra"
        #expect(chat.mentionSuggestions.map(\.name) == ["Bramble Bot"])
        chat.complete(mention: bramble)
        #expect(chat.draft == "hey @BrambleBot ")
        chat.draft += "look"
        #expect(chat.recipients.map(\.id) == [bramble.id])
        chat.send()
        #expect(await eventually { chat.thread.messages.last?.text == "Bramble Bot heard: hey @BrambleBot look" })
    }

    @Test func untaggedGoesToTheBotLastSpokenToAndShowsInActivity() async {
        let chat = session(lastSpokenTo: pip.id)
        var activity: [ActivityItem] = []
        chat.onActivity = { activity.append($0) }
        chat.draft = "plain message"
        #expect(chat.placeholder == "Message Pip…")
        chat.send()
        #expect(await eventually { chat.thread.messages.count == 2 })
        #expect(chat.events.first == .routed(to: pip.id, bySystemOne: false))
        #expect(activity.first?.kind == .systemOne)
        #expect(activity.first?.title == "Sent to Pip")
    }

    @Test func systemOneRoutesWhenItPicksAndTheFallbackRunsWhenItAbstains() async {
        let picked = session(router: PickRouter(pick: bramble.id), lastSpokenTo: pip.id)
        picked.draft = "route me"
        picked.send()
        #expect(await eventually { picked.thread.messages.count == 2 })
        #expect(picked.events.first == .routed(to: bramble.id, bySystemOne: true))
        #expect(picked.thread.messages[0].tags == [bramble.id])

        let abstained = session(router: PickRouter(pick: nil), lastSpokenTo: pip.id)
        abstained.draft = "route me"
        abstained.send()
        #expect(await eventually { abstained.thread.messages.count == 2 })
        #expect(abstained.events.first == .routed(to: pip.id, bySystemOne: false))
    }

    @Test func theFirstQuestionAsksForConsentOnTheCard() async {
        let chat = session(gate: GateAnswerer(gate: DemoFixture.gate(pace: 0.001, asksFirst: true)))
        chat.chips = [pip.id]
        chat.draft = "when am I free?"
        chat.send()
        #expect(await eventually { chat.events.contains { if case .needsConsent = $0 { true } else { false } } })
        guard case .needsConsent(let exchange) = chat.events.first(where: { if case .needsConsent = $0 { true } else { false } }) else { return }
        #expect(chat.needsConsent(exchange))
        #expect(chat.isLive(exchange))
        // The card shows the buttons, and the bot's working row steps aside for it.
        #expect(!chat.showsWorkingRow(pip.id))
        #expect(chat.thread.messages.contains { $0.parts.contains { if case .gateQuestion(let card) = $0 { card.state == .needsConsent } else { false } } })
        chat.decide(.always, for: exchange)
        #expect(await eventually { chat.working.isEmpty })
        #expect(chat.thread.messages.last?.text == "KemoSabe said: After 7 tonight")
    }

    @Test func dontAllowSharesNothingAndShowsARefusal() async {
        let chat = session(gate: GateAnswerer(gate: DemoFixture.gate(pace: 0.001, asksFirst: true)))
        var activity: [ActivityItem] = []
        chat.onActivity = { activity.append($0) }
        chat.chips = [pip.id]
        chat.draft = "when am I free?"
        chat.send()
        #expect(await eventually { chat.events.contains { if case .needsConsent = $0 { true } else { false } } })
        guard case .needsConsent(let exchange) = chat.events.first(where: { if case .needsConsent = $0 { true } else { false } }) else { return }
        chat.decide(.deny, for: exchange)
        #expect(await eventually { chat.working.isEmpty })
        #expect(chat.thread.messages.last?.text == "KemoSabe said: nothing")
        #expect(activity.contains { $0.kind == .kemoSabeRefusal && $0.title == "Didn’t answer Pip" })
        #expect(chat.banner == nil)
    }

    @Test func stopCancelsTheTurnAndSaysSo() async {
        let chat = session(runner: StuckRunner())
        chat.chips = [pip.id]
        chat.draft = "take forever"
        chat.send()
        #expect(chat.isBusy)
        #expect(!chat.canSend)
        chat.stopAll()
        #expect(await eventually { !chat.isBusy })
        #expect(chat.thread.messages.last?.parts == [.status("Pip stopped.")])
    }

    @Test func updatingBotsKeepsTheThreadInStep() {
        let chat = session()
        chat.chips = [bramble.id]
        let newcomer = BotSpec(name: "Tofu", engine: .appleOnDevice, look: BotLook(shape: .bean, palette: "rose", eyes: .dots))
        chat.update(bots: [.kemoSabe(), pip, newcomer])
        #expect(chat.thread.botIDs == [BotSpec.kemoSabeID, pip.id, newcomer.id])
        #expect(chat.chips.isEmpty)
    }

    @Test func activityItemsSayWhatHappened() {
        let card = DemoFixture.answerCard(exchange: GateExchangeID())
        let item = ActivityItem.gate(card, botID: DemoFixture.claudeID, threadID: nil, date: DemoFixture.start)
        #expect(item.kind == .kemoSabeAnswer)
        #expect(item.detail == "“What time is Sarah free tonight?” Shared “After 7 tonight”. Stayed on this iPhone: 4 messages, 2 chats. Not read: 1 Device only chat.")
        var denied = card
        denied.outcome = .denied
        #expect(ActivityItem.gate(denied, botID: nil, threadID: nil).detail == "“What time is Sarah free tonight?” You said Don’t allow.")
        let data = try? TsukumoJSON.encoder.encode(item)
        #expect(data.flatMap { try? TsukumoJSON.decoder.decode(ActivityItem.self, from: $0) } == item)
    }
}

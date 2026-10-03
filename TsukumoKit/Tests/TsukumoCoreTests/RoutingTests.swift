import Foundation
import Testing
@testable import TsukumoCore

/// Tag to send (ported from the dock's routing tests): chips, "@name", a unique first word, and the
/// bot last spoken to when nobody is tagged.
struct RoutingTests {
    let kemo = BotSpec.kemoSabe()
    let claude = BotSpec(name: "Claude", engine: .codingAgent("claude-code"), look: .kemoSabe)
    let homework = BotSpec(name: "Homework Helper", engine: .api(profile: UUID()), look: .kemoSabe)
    let home = BotSpec(name: "Home Base", engine: .api(profile: UUID()), look: .kemoSabe)
    let pip = BotSpec(name: "Pip", engine: .appleOnDevice, look: .kemoSabe)
    var bots: [BotSpec] { [kemo, claude, homework, home, pip] }

    @Test func chipsTagInThreadOrder() {
        let ids = Routing.tagged(text: "hi", chips: [pip.id, claude.id], bots: bots)
        #expect(ids == [claude.id, pip.id])
    }

    @Test func atNameIsCaseInsensitiveAndBounded() {
        #expect(Routing.mentions(in: "hey @CLAUDE, look", bots: bots) == [claude.id])
        #expect(Routing.mentions(in: "@claudette help", bots: bots).isEmpty)
        #expect(Routing.mentions(in: "email me at x@claude", bots: bots) == [claude.id])
        #expect(Routing.mentions(in: "end @pip", bots: bots) == [pip.id])
    }

    @Test func spacedNamesWithOrWithoutSpaces() {
        #expect(Routing.mentions(in: "@homework helper due?", bots: bots) == [homework.id])
        #expect(Routing.mentions(in: "@HomeworkHelper due?", bots: bots) == [homework.id])
    }

    @Test func firstWordOnlyWhenUnique() {
        // "Homework" is unique; "Home" is the whole first word of "Home Base" and unique too.
        #expect(Routing.mentions(in: "@homework what's due", bots: bots) == [homework.id])
        #expect(Routing.mentions(in: "@home lights", bots: bots) == [home.id])
        let twin = BotSpec(name: "Homework Tutor", engine: .appleOnDevice, look: .kemoSabe)
        #expect(Routing.mentions(in: "@homework what's due", bots: bots + [twin]).isEmpty)
    }

    @Test func kemoSabeAnswersToItsNameWhateverItsCalled() {
        let renamed = BotSpec.kemoSabe(name: "Mochi")
        #expect(Routing.mentions(in: "@kemosabe when am I free", bots: [renamed, claude]) == [renamed.id])
        #expect(Routing.mentions(in: "@mochi hi", bots: [renamed, claude]) == [renamed.id])
    }

    @Test func untaggedFallsBackToLastSpokenTo() {
        #expect(Routing.decide(text: "and tomorrow?", chips: [], lastSpokenTo: pip.id, bots: bots) == .untagged(fallback: pip.id))
        #expect(Routing.recipients(text: "and tomorrow?", chips: [], lastSpokenTo: pip.id, bots: bots) == [pip.id])
    }

    @Test func untaggedWithNoOneSpokenToGoesToTheFirstBot() {
        #expect(Routing.decide(text: "hello", chips: [], lastSpokenTo: nil, bots: bots) == .untagged(fallback: kemo.id))
        // A last-spoken-to bot that left the thread doesn't count.
        #expect(Routing.decide(text: "hello", chips: [], lastSpokenTo: UUID(), bots: bots) == .untagged(fallback: kemo.id))
        #expect(Routing.decide(text: "hello", chips: [], lastSpokenTo: nil, bots: []) == .untagged(fallback: nil))
    }

    @Test func tagsWinOverTheFallback() {
        let decision = Routing.decide(text: "@pip and @claude", chips: [], lastSpokenTo: kemo.id, bots: bots)
        #expect(decision == .tagged([claude.id, pip.id]))
    }

    @Test func oneTurnPerTaggedBot() throws {
        var thread = ChatThread(botIDs: bots.map(\.id))
        let sent = thread.send("@pip @claude @pip go", to: [pip.id, claude.id, pip.id, claude.id])
        let message = try #require(sent)
        #expect(message.tags == [claude.id, pip.id])
        #expect(thread.turns(for: message) == [claude.id, pip.id])
        // Two bots at once leaves the last-spoken-to alone; one bot sets it.
        #expect(thread.lastSpokenTo == nil)
        thread.send("just you", to: [pip.id])
        #expect(thread.lastSpokenTo == pip.id)
        #expect(thread.routing(text: "and?", bots: bots) == .untagged(fallback: pip.id))
    }

    @Test func sendSkipsEmptyAndStrangers() {
        var thread = ChatThread(botIDs: [pip.id])
        #expect(thread.send("   ", to: [pip.id]) == nil)
        #expect(thread.send("hi", to: [claude.id]) == nil)
        #expect(thread.messages.isEmpty)
        #expect(thread.turns(for: Message(author: .bot(pip.id), parts: [.text("hi")], tags: [pip.id])).isEmpty)
    }
}

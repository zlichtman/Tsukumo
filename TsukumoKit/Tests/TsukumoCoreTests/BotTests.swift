import Foundation
import Testing
@testable import TsukumoCore

/// Making bots: names, characters, validation, and efforts.
struct BotTests {
    @Test func newBotsGetUnusedNamesAndCharacters() {
        var rng = SeededGenerator(seed: 42)
        var bots = [BotSpec.kemoSabe()]
        for _ in 0..<10 {
            let bot = BotSpec.new(engine: .appleOnDevice, starter: .coder, existing: bots, using: &rng)
            #expect(!bots.contains { $0.name.lowercased() == bot.name.lowercased() })
            #expect(!bots.contains { $0.look.sameCharacter(as: bot.look) })
            #expect(BotStarter.coder.props.contains(bot.look.prop))
            #expect(bot.role == BotStarter.coder.role)
            #expect(bot.permissions.access == .readOnly)
            bots.append(bot)
        }
    }

    @Test func seededDiceAreRepeatable() {
        var a = SeededGenerator(seed: 7), b = SeededGenerator(seed: 7)
        #expect(BotNames.next(taken: [], using: &a) == BotNames.next(taken: [], using: &b))
        #expect(BotLook.random(taken: [], using: &a) == BotLook.random(taken: [], using: &b))
    }

    @Test func namesNumberOnceThePoolIsUsedUp() {
        var rng = SeededGenerator(seed: 1)
        let name = BotNames.next(taken: BotNames.pool, using: &rng)
        #expect(name.hasSuffix(" 2"))
    }

    @Test func hardHatsWearVisorsAndNoTopper() {
        var rng = SeededGenerator(seed: 3)
        for _ in 0..<40 {
            let look = BotLook.random(for: .coder, taken: [], using: &rng)
            if look.prop == .hardHat { #expect(look.eyes == .visor && look.topper == .none) }
            #expect(BotPalette.bright.contains { $0.id == look.palette })
        }
    }

    @Test func validationTrimsAndRefuses() throws {
        let pip = BotSpec(name: "Pip", engine: .appleOnDevice, look: .kemoSabe)
        let trimmed = BotSpec(name: "  Tofu ", engine: .appleOnDevice, model: "  ", role: " Plans ", look: .kemoSabe)
        #expect(try trimmed.validated().get().name == "Tofu")
        #expect(try trimmed.validated().get().model == nil)
        #expect(try trimmed.validated().get().role == "Plans")
        #expect(throws: BotProblem.self) { try BotSpec(name: " ", engine: .appleOnDevice, look: .kemoSabe).validated().get() }
        #expect(throws: BotProblem.self) { try BotSpec(name: "pip", engine: .appleOnDevice, look: .kemoSabe).validated(existing: [pip]).get() }
        #expect(throws: BotProblem.self) { try BotSpec(name: "X", engine: .unknown("?"), look: .kemoSabe).validated().get() }
        #expect(throws: BotProblem.self) { try BotSpec(name: String(repeating: "a", count: 41), engine: .appleOnDevice, look: .kemoSabe).validated().get() }
        // Renaming itself to its own name is fine.
        #expect((try? pip.validated(existing: [pip]).get()) != nil)
    }

    @Test func kemoSabeIsFixedAndOnDevice() {
        let kemo = BotSpec.kemoSabe(name: "  ")
        #expect(kemo.name == "KemoSabe" && kemo.isKemoSabe && kemo.engine == .appleOnDevice)
        #expect(BotSpec.kemoSabe(name: "Mochi").id == BotSpec.kemoSabeID)
    }

    @Test func effortsFollowTheProvidersDocs() {
        #expect(EffortCatalog.efforts(wire: .anthropic, model: "claude-opus-4-5") == ["low", "medium", "high"])
        #expect(EffortCatalog.efforts(wire: .anthropic, model: "claude-opus-4-6") == ["low", "medium", "high", "max"])
        #expect(EffortCatalog.efforts(wire: .anthropic, model: "claude-opus-5-5") == EffortCatalog.claudeFull)
        #expect(EffortCatalog.efforts(wire: .anthropic, model: "claude-sonnet-4-20250514").isEmpty)
        #expect(EffortCatalog.efforts(wire: .anthropic, model: "claude-haiku-4-5").isEmpty)
        #expect(EffortCatalog.efforts(wire: .openAI, model: "gpt-5") == ["minimal", "low", "medium", "high"])
        #expect(EffortCatalog.efforts(wire: .openAI, model: "gpt-5.2") == ["none", "low", "medium", "high", "xhigh"])
        #expect(EffortCatalog.efforts(wire: .openAI, model: "gpt-5-chat-latest").isEmpty)
        #expect(EffortCatalog.efforts(wire: .openAICompatible, model: "o3").isEmpty)
        #expect(EffortCatalog.efforts(wire: .apple, model: "", appleCanReason: true) == EffortCatalog.appleLevels)
        #expect(EffortCatalog.defaultEffort(wire: .anthropic, model: "claude-opus-5-5") == "medium")
        #expect(EffortCatalog.accepted("max", wire: .anthropic, model: "claude-opus-4-5") == nil)
        #expect(EffortCatalog.accepted("high", wire: .anthropic, model: "claude-opus-4-5") == "high")
    }
}

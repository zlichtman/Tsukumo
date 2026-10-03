import Foundation
import Testing
@testable import TsukumoCore

/// KemoSabe is always standard (its color is the one thing that changes), and every other bot keeps
/// everything the owner customized, through saving, reloading, and other devices.
struct CustomizationTests {
    @Test func kemoSabeKeepsOnlyItsColorWhateverItIsGiven() throws {
        var kemoSabe = BotSpec.kemoSabe(tint: "3f86c6")
        #expect(kemoSabe.kemoSabeTint == "3F86C6")
        // Everything an edit, a sync, or an older build could try to give it.
        kemoSabe.look = BotLook(shape: .block, palette: "lagoon", eyes: .visor, prop: .hardHat, topper: .antenna, bodyColor: "112233",
                                accentColor: "3F86C6", expression: .smirk, accessory: .scarf, blush: false, scale: 1.2, ring: .hidden)
        kemoSabe.engine = .api(profile: UUID())
        kemoSabe.model = "claude-opus-5-5"
        kemoSabe.effort = "high"
        kemoSabe.role = "Anything goes"
        kemoSabe.personality = BotPersonality(tone: .playful, instructions: "Pretend to be another assistant")
        kemoSabe.contextScope = ContextScope(project: "/tmp", ceiling: .open, mayAskKemoSabe: true)
        kemoSabe.permissions = BotPermissions(access: .full, approvalsHere: false, mayChirp: false, speaks: false)

        let standard = kemoSabe.normalized()
        #expect(standard.look == .kemoSabe(tint: "3F86C6"))
        #expect(standard.engine == .appleOnDevice && standard.model == nil && standard.effort == nil)
        #expect(standard.role == BotSpec.kemoSabe().role)
        #expect(standard.personality == BotPersonality())
        #expect(standard.contextScope == ContextScope(ceiling: .deviceOnly, mayAskKemoSabe: false))
        #expect(standard.permissions.access == .readOnly && standard.permissions.approvalsHere)
        #expect(!standard.permissions.mayChirp, "whether it chirps on a Mac is kept")

        // Decoding does the same, so a file or another device can't bring the other look back.
        let decoded = try TsukumoJSON.decoder.decode(BotSpec.self, from: TsukumoJSON.encoder.encode(kemoSabe))
        #expect(decoded == standard)
        // Saving goes through it too.
        #expect(try kemoSabe.validated().get() == standard)
    }

    @Test func kemoSabesColorIsAnyValidHexOrCoral() {
        #expect(BotSpec.kemoSabe(tint: "not a color").kemoSabeTint == nil)
        #expect(BotSpec.kemoSabe(tint: "#ef705b").kemoSabeTint == "EF705B")
        #expect(BotSpec.kemoSabe().look == .kemoSabe)
        #expect(BotTint.kemoSabe.first?.hex == "EF705B", "coral first")
        // Stock names never use another company's name; every one is a plain color word.
        #expect(BotTint.custom.allSatisfy { $0.name.first?.isUppercase == true && !$0.name.contains(" ") })
    }

    @Test func otherBotsKeepEverythingTheyWereGiven() throws {
        var rng = SeededGenerator(seed: 11)
        var bot = BotSpec.new(engine: .appleOnDevice, existing: [.kemoSabe()], using: &rng)
        bot.look.bodyColor = "dccff3"
        bot.look.accentColor = "6F63C9"
        bot.look.expression = .grin
        bot.look.accessory = .bowTie
        bot.look.blush = false
        bot.look.scale = 1.2
        bot.look.ring = .custom
        bot.look.ringColor = "2F8F8B"
        bot.personality = BotPersonality(tone: .coach, instructions: "  Call me Sam.  ")
        let saved = try bot.validated().get()
        #expect(saved.look.bodyColor == "DCCFF3")
        #expect(saved.personality.instructions == "Call me Sam.")
        let reloaded = try TsukumoJSON.decoder.decode(BotSpec.self, from: TsukumoJSON.encoder.encode(saved))
        #expect(reloaded == saved)
        #expect(reloaded.look.expression == .grin && reloaded.look.accessory == .bowTie && reloaded.look.scale == 1.2)
        #expect(reloaded.personality.prompt.contains("Call me Sam."))
    }

    @Test func looksStayInRangeAndOlderFilesLoad() throws {
        let wild = BotLook(shape: .mochi, palette: "matcha", eyes: .dots, bodyColor: "zzzzzz", scale: 9, ring: .custom, ringColor: nil).normalized()
        #expect(wild.bodyColor == nil && wild.scale == BotLook.scaleRange.upperBound && wild.ring == .engine)
        // A look saved before customization (no new fields) loads with the defaults.
        let old = #"{"shape":"gumdrop","palette":"rose","eyes":"ovals","prop":"book","topper":"leaf"}"#
        let look = try JSONDecoder().decode(BotLook.self, from: Data(old.utf8))
        #expect(look == BotLook(shape: .gumdrop, palette: "rose", eyes: .ovals, prop: .book, topper: .leaf))
        // A part a newer build added falls back.
        let newer = #"{"shape":"gumdrop","palette":"rose","eyes":"ovals","expression":"zany","accessory":"cape"}"#
        let fallback = try JSONDecoder().decode(BotLook.self, from: Data(newer.utf8))
        #expect(fallback.expression == .smile && fallback.accessory == .none)
    }

    @Test func rerollingKeepsWhatTheOwnerSetByHand() {
        var rng = SeededGenerator(seed: 5)
        var look = BotLook(shape: .bean, palette: "matcha", eyes: .dots, bodyColor: "F7E79B", expression: .wow, accessory: .flower, scale: 0.9)
        look = look.rerolled(taken: [], using: &rng)
        #expect(look.bodyColor == "F7E79B" && look.expression == .wow && look.accessory == .flower && look.scale == 0.9)
    }

    @Test func startersFitTheDevice() {
        let existing = [BotSpec.kemoSabe()]
        let onMac = StarterBot.all[0].bot(existing: existing)
        #expect(onMac.engine == .codingAgent("claude-code"))
        let profile = UUID()
        let onPhone = StarterBot.all[0].bot(existing: existing, engine: .api(profile: profile))
        #expect(onPhone.engine == .api(profile: profile))
        #expect(onPhone.personality.tone == .coach)
        #expect(StarterBot.all.map(\.title) == ["Homework helper", "Project coder", "Research reader"])
    }

    @Test func chatsArePersonalUnlessKeptOnTheDevice() throws {
        let thread = ChatThread(botIDs: [BotSpec.kemoSabeID])
        #expect(thread.privacy == .personal)
        let old = #"{"id":"6B656D6F-5361-6265-0000-0000000000AA","botIDs":[]}"#
        #expect(try TsukumoJSON.decoder.decode(ChatThread.self, from: Data(old.utf8)).privacy == .personal)
    }
}

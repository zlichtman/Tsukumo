#if os(macOS)
import Foundation
import TsukumoCore
import TsukumoPolicy
import TsukumoContext
import TsukumoGate
import TsukumoEngines
import TsukumoUI

// Ready-made ways to fill the dock's conversations: on TsukumoKit's engines and KemoSabe's Gate (a host
// passes its own engines for API models and coding agents), and the website demo.

public extension BotDock {
    /// A dock whose chats run on TsukumoKit: KemoSabe on Apple's on-device model (macOS 26), every other
    /// bot through `resolve`, and one KemoSabe Gate for every conversation (`gate`). `sources` are
    /// KemoSabe's personal sources on this Mac; `grants`, `journal`, and `artifacts` are what the app
    /// saved (in memory when left out).
    static func standard(store: BotDockStore, sources: [any PersonalSource] = [], grants: [RecipientGrant] = [],
                         journal: GateJournal = GateJournal(), artifacts: ArtifactStore? = nil,
                         resolve: @escaping @Sendable (BotSpec) async -> Result<ResolvedEngine, EngineRunner.EngineUnavailable> = BotDock.notConnected) -> BotDock {
        let extraction: any ExtractionModel
        if #available(macOS 26, *) { extraction = AppleExtractionModel() } else { extraction = FixtureExtractionModel(isAvailable: false) }
        let artifacts = artifacts ?? (try? ArtifactStore()) ?? { fatalError("An in-memory artifact store always opens.") }()
        let gate = Gate(model: extraction, sources: sources, grants: grants, journal: journal, answers: artifacts, deviceName: "Mac")
        let runner = EngineRunner(store: artifacts) { bot in
            if bot.engine == .appleOnDevice {
                if #available(macOS 26, *) { return .success(ResolvedEngine(engine: OnDeviceEngine(model: AppleOnDeviceModel()), recipient: .appleOnDevice)) }
                return .failure(.init("\(bot.name) needs macOS 26 with Apple Intelligence."))
            }
            return await resolve(bot)
        }
        let answerer = GateAnswerer(gate: gate)
        let dock = BotDock(store: store) { thread, bots in ChatSession(thread: thread, bots: bots, runner: runner, gate: answerer) }
        dock.gate = gate
        dock.botsDidChange = { bots in gate.apply(bots: bots) }
        gate.apply(bots: store.bots)
        return dock
    }

    /// Every engine but Apple on-device says it isn't connected yet.
    static let notConnected: @Sendable (BotSpec) async -> Result<ResolvedEngine, EngineRunner.EngineUnavailable> = { bot in
        .failure(.init("\(EngineInfo.standard(bot.engine).title) isn’t connected on this Mac yet, so \(bot.name) can’t answer here."))
    }

    // MARK: The website demo

    /// The website demo on the dock: KemoSabe, Claude (the demo's fake Claude through the real Gate and
    /// policy), and two more bots resting beside them. KemoSabe asks the owner first this time, so
    /// Claude's tile needs you while the consent card waits.
    static func demo(pace: Double = 1) -> BotDock {
        let store = BotDockStore(file: nil)
        store.update { $0 = DockSettings(); $0.autohide = false; $0.sleepAtNight = false }
        store.add(DemoFixture.claude)
        store.add(BotSpec(id: UUID(uuidString: "5A3C0DE0-7A1E-4C6B-9E2A-0000000007D1")!, name: "Pip", engine: .codingAgent("codex"),
                          role: "Codes in my projects", look: BotLook(shape: .block, palette: "lagoon", eyes: .visor, prop: .hardHat)))
        store.add(BotSpec(id: UUID(uuidString: "5A3C0DE0-7A1E-4C6B-9E2A-0000000007D2")!, name: "Juniper", engine: .codingAgent("claude-code"),
                          role: "Tracks my class deadlines", look: BotLook(shape: .mochi, palette: "lavender", eyes: .sparkle, prop: .pencil, topper: .leaf)))
        let runner = DemoFixture.runner(pace: pace)
        // Each conversation gets its own KemoSabe, so playing the demo again (from a cleared chat) asks first again.
        let dock = BotDock(store: store) { thread, bots in
            let answerer = GateAnswerer(gate: DemoFixture.gate(pace: pace, asksFirst: true, device: "Mac")) { _ in "api.anthropic.com" }
            return ChatSession(thread: thread, bots: bots, runner: runner, gate: answerer)
        }
        dock.engineInfo = DemoFixture.engineInfo
        return dock
    }

    /// Plays the website demo, beat for beat, in Claude's chat: the message types in and sends, Claude
    /// thinks, asks KemoSabe "What time is Sarah free tonight?", KemoSabe's consent card waits (the owner
    /// can answer; after `autoAllow` seconds the demo answers Allow always), KemoSabe reads this Mac and
    /// shares "After 7 tonight", and Claude recommends Osteria Lucia. Plays again from an empty chat.
    func playDemo(pace: Double = 1, autoAllow: Double? = 2.5) async {
        let claude = DemoFixture.claudeID
        if !(session(claude)?.thread.messages.isEmpty ?? true) { clear(claude) }
        guard let session = session(claude) else { return }
        let allow = autoAllow.map { delay in
            Task { [weak self] in
                for _ in 0..<600 {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard let self, !Task.isCancelled else { return }
                    if let request = self.pending.first(where: { $0.bot == claude && $0.kind == .consent }) {
                        try? await Task.sleep(for: .seconds(delay * pace))
                        if self.pending.contains(request) { self.decide(.always, for: request) }
                        return
                    }
                }
            }
        }
        await DemoFixture.play(session, pace: pace)
        // The demo is over when Claude has replied; stop waiting for a consent card that won't come.
        for _ in 0..<600 where session.isBusy { try? await Task.sleep(for: .milliseconds(100)) }
        allow?.cancel()
    }
}
#endif

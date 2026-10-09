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
    /// saved (in memory when left out). `router` is System One: it routes untagged messages in every
    /// conversation and picks each turn's context (`selectContext`); without one, an untagged message goes
    /// to the bot last spoken to and a turn has only `read_reference`.
    /// Coding agents' sessions are kept in `store` (on this Mac), so each chat continues its agent's session.
    static func standard(store: BotDockStore, sources: [any PersonalSource] = [], grants: [RecipientGrant] = [],
                         journal: GateJournal = GateJournal(), artifacts: ArtifactStore? = nil, router: SystemOneRouter? = nil,
                         resolve: @escaping @Sendable (BotSpec) async -> Result<ResolvedEngine, EngineRunner.EngineUnavailable> = BotDock.notConnected) -> BotDock {
        let extraction: any ExtractionModel
        if #available(macOS 26, *) { extraction = AppleExtractionModel() } else { extraction = FixtureExtractionModel(isAvailable: false) }
        let artifacts = artifacts ?? (try? ArtifactStore()) ?? { fatalError("An in-memory artifact store always opens.") }()
        let gate = Gate(model: extraction, sources: sources, grants: grants, journal: journal, answers: artifacts, deviceName: "Mac")
        var selectContext: (@Sendable (BotTurn) async -> any ReferenceChooser)?
        if let router { selectContext = { turn in await router.chooser(for: turn) } }
        let runner = EngineRunner(store: artifacts, selectContext: selectContext, sessions: store.agentSessions) { bot in
            if bot.engine == .appleOnDevice {
                if #available(macOS 26, *) { return .success(ResolvedEngine(engine: OnDeviceEngine(model: AppleOnDeviceModel()), recipient: .appleOnDevice)) }
                return .failure(.init("\(bot.name) needs macOS 26 with Apple Intelligence."))
            }
            return await resolve(bot)
        }
        let answerer = GateAnswerer(gate: gate)
        let dock = BotDock(store: store) { thread, bots in ChatSession(thread: thread, bots: bots, runner: runner, gate: answerer, router: router) }
        dock.gate = gate
        dock.botsDidChange = { bots in gate.apply(bots: bots) }
        gate.apply(bots: store.bots)
        return dock
    }

    /// Every engine but Apple on-device says it isn't connected yet.
    static let notConnected: @Sendable (BotSpec) async -> Result<ResolvedEngine, EngineRunner.EngineUnavailable> = { bot in
        .failure(.init("\(EngineInfo.standard(bot.engine).title) isn’t connected on this Mac yet, so \(bot.name) can’t answer here."))
    }

    /// A coding bot on its agent: the catalog's backend for its engine, working in its project or else in
    /// `folder(bot)` (made when missing), or why it can't run (its agent isn't installed). Nil for any other engine.
    nonisolated static func codingAgent(_ bot: BotSpec, catalog: CodingAgentCatalog, folder: (BotSpec) -> URL) -> Result<ResolvedEngine, EngineRunner.EngineUnavailable>? {
        guard bot.engine.runsOnlyOnMac else { return nil }
        guard let kind = CodingAgentKind.kind(for: bot.engine) else {
            return .failure(.init("\(EngineInfo.standard(bot.engine).title) isn’t supported in Tsukumo yet, so \(bot.name) can’t answer here. Choose another AI model in its Brain."))
        }
        guard let backend = catalog.backend(for: bot.engine) else {
            return .failure(.init("\(kind.title) isn’t on this Mac, so \(bot.name) can’t answer. \(kind.install)"))
        }
        let defaultFolder = folder(bot)
        if bot.contextScope.project == nil { try? FileManager.default.createDirectory(at: defaultFolder, withIntermediateDirectories: true) }
        return .success(ResolvedEngine(engine: CodingAgentEngine(backend: backend, defaultDirectory: defaultFolder.path),
                                       recipient: RecipientID.bot(bot)))
    }

    // MARK: The website demo

    /// The website demo on the dock: KemoSabe, Claude (the demo's fake Claude through the real Gate and
    /// policy), and two more of the owner's bots beside them (Juniper, made on Codex, and Grok, brought in as a gateway
    /// agent). KemoSabe asks the owner first this time, so Claude's tile needs you while the consent card waits.
    static func demo(pace: Double = 1) -> BotDock {
        let store = BotDockStore(file: nil)
        store.update { $0 = DockSettings(); $0.autohide = false; $0.sleepAtNight = false }
        store.add(DemoFixture.claude)
        store.add(BotSpec(id: ServiceID.codex.botID, name: "Juniper", engine: .codingAgent("codex"), role: "Keeps my projects tidy", service: .codex))
        store.add(BotSpec(id: ServiceID.grok.botID, name: "Grok", engine: .service("grok"), role: "Your Grok bot, through the KemoSabe gateway",
                          origin: .caller(id: "demo-grok"), service: .grok))
        let runner = DemoFixture.runner(pace: pace)
        // Each conversation gets its own KemoSabe, so playing the demo again (from a cleared chat) asks first again.
        let dock = BotDock(store: store) { thread, bots in
            let answerer = GateAnswerer(gate: DemoFixture.gate(pace: pace, asksFirst: true, device: "Mac")) { _ in "api.anthropic.com" }
            return ChatSession(thread: thread, bots: bots, runner: runner, gate: answerer)
        }
        dock.engineInfo = DemoFixture.engineInfo
        dock.connections = ServiceConnections(claudeAPI: DemoFixture.claudeProfile, installedAgents: ["codex"], callers: [.grok])
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

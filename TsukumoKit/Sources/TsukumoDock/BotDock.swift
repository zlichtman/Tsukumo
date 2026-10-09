#if os(macOS)
import Foundation
import Observation
import SwiftUI
import TsukumoCore
import TsukumoEngines
import TsukumoGate
import TsukumoGateway
import TsukumoUI
import TsukumoVoice

// The dock's brain (ported from `AgentsDock` in the old Mac app's dock). Every conversation is TsukumoUI's
// `ChatSession`, the same chat as the iPhone app, so a bot's turn, KemoSabe's card, consent, and Activity work
// exactly as they do there. The dock keeps one
// session per bot that chats and one for Together, reads each tile's state from them and from the KemoSabe
// gateway, and adds what only the dock has: callouts, chirps, pokes, and the done celebration.
//
// Since October 8, 2026 its bots are the owner's (TsukumoCore's `BotLineup`): KemoSabe, then the bots the owner made
// (a character on one of their engines) or brought in (their ChatGPT dot, an agent that signs in to the gateway), in
// the owner's order. The services are the engines underneath (`connections`), connected in Settings, Services.

/// The side dock's model: its bots, their conversations, and what each tile shows.
@MainActor @Observable public final class BotDock {
    /// Together's conversation, saved beside each bot's own.
    public static let togetherID = UUID(uuidString: "746F6765-7468-6572-0000-000000000001")!

    public let store: BotDockStore
    /// Makes the chat for one conversation: the thread and the bots it may tag. The host wires its
    /// engines, KemoSabe's Gate, and System One here (`BotDock.standardSessions` is a start).
    @ObservationIgnored public let makeSession: @MainActor (ChatThread, [BotSpec]) -> ChatSession
    /// Names and marks for engines, for the bubble and the tiles' logos.
    @ObservationIgnored public var engineInfo: @Sendable (EngineID) -> EngineInfo = { EngineInfo.standard($0) }
    /// What a bot may run on, for its settings.
    @ObservationIgnored public var engineChoices: [EngineChoice] = BotDock.macEngines
    /// Which service an API connection is (the host knows its connections), for a bot's mark and page.
    @ObservationIgnored public var apiService: (UUID) -> ServiceID? = { _ in nil }
    /// The owner's Codex pets on this Mac, for bots' characters (the host reads them; none in tests and the demo).
    public var pets: [CodexPet] = []
    /// The owner's ChatGPT dot, as Codex on this Mac knows it (the host reads it), for Add a Bot.
    public var dot: DotOffer?
    /// The owner's recent Codex and Claude Code conversations on this Mac (the host reads them), for Add a Bot.
    public var codingSessions: [CodingSession] = []
    /// Whether a conversation is already some bot's.
    public func isBroughtIn(_ session: CodingSession) -> Bool { store.state.agentSessions.values.contains(session.id) }
    /// What Add a Bot needs of the owner's dot: its ID, name, pet, and Codex conversation.
    public struct DotOffer: Hashable, Sendable {
        public var id: String, name: String, pet: String?, thread: String?
        public init(id: String, name: String, pet: String?, thread: String?) { self.id = id; self.name = name; self.pet = pet; self.thread = thread }
        public init(_ dot: CodexDot) { self.init(id: dot.aeonID ?? dot.threadID, name: dot.name, pet: dot.petID, thread: dot.threadID) }
    }
    /// Reads the owner's pets and dot again (the host's; Add a Bot and a bot's page ask for it as they open).
    @ObservationIgnored public var refreshCharacters: (() -> Void)?
    /// A bot wearing one of the owner's pets (its name and still picture go with it, for devices without Codex).
    public func look(forPet id: String) -> BotLook {
        let pet = pets.first { $0.id == id }
        return .pet(id, name: pet?.name, image: pet.flatMap { CodexPets.avatarPNG($0, side: 96) })
    }
    /// KemoSabe's Gate, when the dock was made with `standard` (Settings, KemoSabe shows its grants and journal).
    @ObservationIgnored public var gate: Gate?
    /// The KemoSabe gateway's cards for callers outside the app (`attach(gateway:inbox:)`): KemoSabe needs you
    /// while one waits, and its chat shows them.
    public var gateway: GatewayDesk?
    /// The whole gateway, when the app runs one: each service's tile shows its callers, what they asked and were
    /// given, what they sent, and their grants, with Revoke.
    public var gatewayHub: KemoSabeGateway?
    /// Which services are connected here: what the owner's bots can run on, and what can be brought in.
    public var connections = ServiceConnections() {
        didSet { if connections != oldValue { botsChanged() } }
    }
    /// A bot's own panel in place of its standard chat, by the bot's ID (Tsukumo's Claude bot plugs in here). A bot
    /// with none keeps the standard chat on whatever runs it.
    @ObservationIgnored public var panelProviders: [UUID: any ServiceBotPanelProvider] = [:]
    /// Opens the app's Settings window (the dock's right-click menu has Settings… when it's set).
    @ObservationIgnored public var openSettings: (@MainActor () -> Void)?
    /// The clock (tests set it).
    @ObservationIgnored public var now: () -> Date = Date.init
    /// What's coming up, for chirps (`EventKitDockSource` in an app), and which sources the owner allowed.
    @ObservationIgnored public var upcoming: (any DockUpcomingSource)?
    @ObservationIgnored public var allowedSources: () -> Set<DockChirpSource> = { [] }
    /// A chirp was posted (a soft sound, when chirp sounds are on).
    @ObservationIgnored public var onChirp: (() -> Void)?
    /// The bots changed (KemoSabe's Gate takes each bot's limits from them).
    @ObservationIgnored public var botsDidChange: (([BotSpec]) -> Void)?
    /// Everything Activity shows, for the host too.
    @ObservationIgnored public var onActivity: ((ActivityItem) -> Void)?
    /// The app's voice: clicking a character talks to it (`DockVoice.swift`), and its reply is spoken. Nil
    /// (the demo, tests) keeps a click opening the chat.
    @ObservationIgnored public var voice: VoiceHub? {
        didSet { for session in sessions.values { session.voice = voice } }
    }

    /// Each conversation's chat, by bot (and `togetherID`).
    public private(set) var sessions: [UUID: ChatSession] = [:]
    /// Which panel is open beside the side dock.
    public var surface: DockSurface?
    public private(set) var callout: DockCallout?
    /// When each bot last finished, for the celebration and the check that fades.
    public private(set) var finishedAt: [UUID: Date] = [:]
    /// The latest chirp, so its neighbors glance at it.
    public private(set) var lastChirp: (bot: UUID, at: Date)?
    /// Pokes and giggles on a tile, with a counter that replays them.
    public private(set) var reaction: [UUID: (kind: DockReaction, tick: Int)] = [:]
    /// What each coding bot's work is doing, from its agent's own events (`work(_:_:)`); a host may fill it too.
    public var cues: [UUID: DockWorkCue] = [:]
    /// Opens a coding bot's project in the owner's editor and reveals each file its agent edits, once the
    /// host gives it an editor (`EditorFollower.editor`); with none it does nothing.
    @ObservationIgnored public let follower = EditorFollower()
    /// Where a coding bot works, for paths its agent reports relative to it (the host's default folder for a
    /// bot without a project).
    @ObservationIgnored public var codingFolder: @MainActor (BotSpec) -> String? = { $0.contextScope.project }
    /// Commands each bot runs that are tests, by the agent's ID for them.
    @ObservationIgnored private var testRuns: [UUID: Set<String>] = [:]
    /// Bumped when a one-off moment is over, so live clocks can stop.
    public private(set) var settleTick = 0
    @ObservationIgnored private var calloutTask: Task<Void, Never>?
    @ObservationIgnored private var chirpLoop: Task<Void, Never>?

    public init(store: BotDockStore, makeSession: @escaping @MainActor (ChatThread, [BotSpec]) -> ChatSession) {
        self.store = store
        self.makeSession = makeSession
        // The editor chosen in Settings, Dock ("Follow their edits in"), while it's installed.
        follower.editor = { [weak store] in
            guard let id = store?.settings.followEditor else { return nil }
            return EditorTarget.installed().first { $0.bundleID == id }
        }
        for bot in bots where bot.engine.chats { openSession(bot.id) }
        openSession(Self.togetherID)
    }

    /// KemoSabe, then the owner's bots, in the owner's order.
    public var bots: [BotSpec] { BotLineup.bots(kemoSabe: store.bots[0], saved: store.bots) }
    public var settings: DockSettings { store.settings }
    public func bot(_ id: UUID?) -> BotSpec? { bots.first { $0.id == id } }

    // MARK: Conversations

    /// The bots a conversation may tag: KemoSabe and the bot (a bot's own chat), or every bot that chats
    /// (Together). A service that only calls the gateway has no conversation.
    func members(_ key: UUID) -> [BotSpec] {
        let all = bots
        if key == Self.togetherID { return all.filter(\.engine.chats) }
        guard let bot = all.first(where: { $0.id == key }), bot.engine.chats else { return [] }
        return bot.isKemoSabe ? [bot] : [all[0], bot]
    }
    private func openSession(_ key: UUID) {
        let members = members(key)
        guard !members.isEmpty else { return }
        let thread = store.thread(key) ?? ChatThread(id: key == Self.togetherID ? Self.togetherID : UUID(),
                                                      title: key == Self.togetherID ? "Together" : members.last?.name ?? "",
                                                      botIDs: members.map(\.id),
                                                      lastSpokenTo: key == Self.togetherID ? (store.state.lastTalkedTo ?? members.first?.id) : key)
        let session = makeSession(thread, members)
        session.onThreadChange = { [weak self] thread in self?.store.setThread(thread, for: key) }
        session.onActivity = { [weak self] item in self?.record(item) }
        session.onWork = { [weak self] bot, activity in self?.work(bot, activity) }
        session.onApprovalNeeded = { [weak self] approval in self?.approvalNeeded(approval) }
        session.onTurnEnded = { [weak self] bot in self?.turnEnded(bot) }
        session.voice = voice
        sessions[key] = session
    }
    /// A bot's own chat (or Together's).
    public func session(_ key: UUID) -> ChatSession? { sessions[key] }

    /// Keeps every conversation's bots current after the dock's bots change.
    private func botsChanged() {
        for bot in bots where bot.engine.chats && sessions[bot.id] == nil { openSession(bot.id) }
        for key in sessions.keys where key != Self.togetherID && bot(key)?.engine.chats != true { sessions[key]?.stopAll(); sessions[key] = nil }
        if case .bot(let id)? = surface, bot(id)?.engine.chats != true { surface = nil }
        if case .panel(let id)? = surface, bot(id) == nil { surface = nil }
        for (key, session) in sessions { session.update(bots: members(key)) }
        botsDidChange?(bots)
    }

    private func record(_ item: ActivityItem) {
        store.appendActivity(item)
        onActivity?(item)
        // A bot that just replied celebrates; if the owner isn't looking at it, its tile says so.
        if item.kind == .botWork, let id = item.botID, item.title.hasSuffix("replied") {
            let done = now()
            finishedAt[id] = done
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard let self, self.finishedAt[id] == done else { return }
                self.finishedAt[id] = nil
            }
            if !isShowing(id) { show(DockCallout(bot: id, text: DockChirpRules.finished(item.detail))) }
        }
    }

    // MARK: Bots

    /// Saves what the owner set on KemoSabe (its palette, voice, chirps) or on one of their bots (its name, job, what
    /// they told it, its character, engine, model, project, access, voice).
    @discardableResult public func update(_ bot: BotSpec) -> Result<BotSpec, BotProblem> {
        let result = store.update(bot)
        botsChanged()
        return result
    }
    /// Adds a bot the owner made or brought in, at the end of the dock; `continuing` is a coding agent's session its chat
    /// picks up.
    @discardableResult public func add(_ bot: BotSpec, continuing session: String? = nil) -> Result<BotSpec, BotProblem> {
        let result = store.add(bot, continuing: session)
        botsChanged()
        return result
    }
    /// Takes a bot off the dock: its turns stop in every conversation (Together's too), and its conversation is kept.
    @discardableResult public func remove(_ id: UUID) -> BotProblem? {
        if let problem = store.remove(id) { return problem }
        sessions[id]?.stopAll()
        cues[id] = nil
        botsChanged()
        return nil
    }
    public func move(_ id: UUID, to place: Int) {
        store.move(id, to: place)
        botsChanged()
    }

    // MARK: Bringing in a service's own bots

    /// Files a gateway caller under a service (or none), as the owner confirmed it, and brings it in as a bot when it's
    /// a service's (once: a caller already on the dock isn't added again).
    public func bind(caller id: String, to service: ServiceID?, transport: String) {
        store.bind(caller: id, to: service, transport: transport)
        if service != nil { bringIn(caller: id) }
    }
    /// A confirmed gateway caller as a bot on the dock, named as it signed in (made unique), with its service's mark.
    @discardableResult public func bringIn(caller id: String) -> Result<BotSpec, BotProblem> {
        guard let caller = gatewayHub?.store.caller(id), !caller.isTsukumosClaudeBot else { return .failure(.init("That agent isn’t signed in to KemoSabe.")) }
        if let already = bots.first(where: { $0.origin == .caller(id: id) }) { return .success(already) }
        let service = store.binding(forCaller: id)?.service
        let bot = BotSpec(name: uniqueName(caller.name), engine: .service(service?.rawValue ?? "agent"),
                          role: service.map { "Your \($0.title) bot, through the KemoSabe gateway" } ?? "An agent that asks KemoSabe through the gateway",
                          origin: .caller(id: id), service: service)
        return add(bot)
    }
    /// The callers the owner confirmed before their bots were the owner's (2.05), as bots, once its gateway is there.
    public func bringInConfirmedCallers() {
        guard store.callersToBringIn, let hub = gatewayHub else { return }
        for caller in hub.store.callers where !caller.isTsukumosClaudeBot && store.binding(forCaller: caller.id)?.service != nil {
            bringIn(caller: caller.id)
        }
        store.broughtInCallers()
    }
    /// The service an engine is, for a bot made on it.
    public func service(of engine: EngineID) -> ServiceID? { ServiceID.of(engine, apiService: apiService) }
    /// `name`, or `name 2`, `name 3`… so it's no other bot's.
    public func uniqueName(_ name: String) -> String {
        let base = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(BotSpec.maxName - 3))
        let start = base.isEmpty ? "Agent" : base
        var candidate = start, number = 1
        while bots.contains(where: { $0.name.caseInsensitiveCompare(candidate) == .orderedSame }) { number += 1; candidate = start + " \(number)" }
        return candidate
    }
    /// Takes what sync brought from the owner's other devices: the bots, and each conversation's chat. A
    /// conversation that's mid-turn picks the change up when its turn ends (its next save merges again).
    public func applySynced(bots: [BotSpec], threads: [ChatThread]) {
        // Custom bots from a device that hasn't moved to the lineup yet are folded or archived the same way.
        let open = Dictionary(sessions.map { ($0.value.thread.id, $0.key) }, uniquingKeysWith: { first, _ in first })
        let changed = store.applySynced(bots: bots, threads: threads, conversations: open)
        // The open conversations take their synced chats first, so refreshing their bots saves those.
        for key in changed {
            guard let session = sessions[key], !session.isBusy else { continue }
            if let thread = store.thread(key) { session.open(thread) } else { sessions[key] = nil; openSession(key) }
        }
        botsChanged()
    }

    /// Clears a conversation (running turns stop).
    public func clear(_ key: UUID) {
        sessions[key]?.stopAll()
        store.clearThread(key)
        sessions[key] = nil
        openSession(key)
    }

    // MARK: What each tile shows

    /// Whether a bot waits on the owner: KemoSabe's first OK (or a Sensitive share) for its question,
    /// or an approval in its work.
    public func needsYou(_ id: UUID) -> Bool {
        if cues[id]?.approval != nil || approval(for: id) != nil { return true }
        if plugged(id)?.tileStatus == .needsYou { return true }
        if let gateway {
            let waiting = gateway.pending.filter { if case .newClient = $0.kind { false } else { true } }
            if id == BotSpec.kemoSabeID, !waiting.isEmpty { return true }
            // A brought-in bot's tile needs you too while it waits on a card.
            if let bot = bot(id), waiting.contains(where: { request in callers(of: bot).contains { $0.id == request.callerID } }) { return true }
        }
        return !pending.filter { $0.bot == id }.isEmpty
    }

    /// The gateway callers the owner confirmed as a service (bound by each caller's authenticated ID, never by its name).
    public func callers(for service: ServiceID) -> [GatewayCaller] {
        gatewayHub?.store.callers.filter { store.binding(forCaller: $0.id)?.service == service && !$0.isTsukumosClaudeBot } ?? []
    }
    /// The gateway callers a bot is: a brought-in caller itself; for the owner's ChatGPT dot, the callers confirmed as
    /// ChatGPT (its connectors, which a dot asks through); none for a bot made here (it asks KemoSabe in its chat).
    public func callers(of bot: BotSpec) -> [GatewayCaller] {
        switch bot.origin {
        case .caller(let id): gatewayHub?.store.caller(id).map { [$0] } ?? []
        case .dot: callers(for: .openAI)
        case .made: []
        }
    }
    /// Callers the owner hasn't said which service they are: shown as unverified agents, under no brand.
    public var unverifiedCallers: [GatewayCaller] {
        gatewayHub?.store.callers.filter { store.binding(forCaller: $0.id) == nil && !$0.isTsukumosClaudeBot } ?? []
    }
    /// Who a gateway request is from and how it came, for its card: "From “Grok”, which you confirmed as Grok, through the
    /// relay." or "From an unverified agent that calls itself “Claude”, signed in with OAuth."
    public func identityLine(for request: GatewayApprovalRequest) -> String {
        if request.callerID == GatewayCaller.claudeBotID { return "From Tsukumo’s Claude bot, on this Mac." }
        let name = "“" + request.callerName + "”"
        if case .newClient(_, let local, let relayed) = request.kind {
            return "From an unverified agent that calls itself \(name), " + (local ? "on this Mac." : relayed ? "through the relay." : "through a public address.")
        }
        if let binding = store.binding(forCaller: request.callerID) {
            let what = binding.service.map { "which you confirmed as \($0.title)" } ?? "which you said is none of your services"
            return "From \(name), \(what), \(binding.transport)."
        }
        let kind = gatewayHub?.store.caller(request.callerID)?.kind
        let how = kind == .token ? "with a token you made" : kind == .device ? "a paired device" : kind == .local ? "inside Tsukumo" : "signed in with OAuth"
        return "From an unverified agent that calls itself \(name), \(how)."
    }
    /// The first thing a coding bot waits to be allowed, in any conversation.
    public func approval(for id: UUID) -> ChatSession.PendingApproval? {
        sessions.values.lazy.compactMap { $0.approvals.first { $0.bot == id } }.first
    }
    /// What a coding bot's work is doing, with what it waits to be allowed.
    public func cue(for id: UUID) -> DockWorkCue? {
        let waiting = approval(for: id)
        guard var cue = cues[id] ?? waiting.map({ _ in DockWorkCue(status: .running) }) else { return nil }
        if let waiting { cue.approval = waiting.summary }
        return cue
    }

    // MARK: Coding bots' work

    /// What a coding bot's agent is doing: its tile's cue (the file, the plan's step, tests), and the file
    /// it edits revealed in the owner's editor.
    public func work(_ id: UUID, _ activity: CodingActivity) {
        guard let bot = bot(id) else { return }
        let folder = codingFolder(bot) ?? ""
        var cue = cues[id] ?? DockWorkCue(status: .running)
        if cues[id] == nil, let project = bot.contextScope.project { follower.started(folder: URL(fileURLWithPath: project)) }
        switch activity {
        case .reading(let path):
            cue.file = EditorFollow.url(path, in: folder).path; cue.line = nil
        case .editing(let path, let diff):
            let file = EditorFollow.url(path, in: folder)
            cue.file = file.path
            cue.line = diff.flatMap { EditorFollow.line(in: $0, file: file) }
            follower.request(file, line: cue.line)
        case .running(let run, let command):
            if DockWorkCue.isTest(command) { testRuns[id, default: []].insert(run); cue.tests = .running }
        case .ran(let run, let failed):
            if testRuns[id]?.remove(run) != nil { cue.tests = failed ? .failed : .passed }
        case .plan(let steps):
            cue.apply(plan: steps.map { ($0.state == .done ? "completed" : $0.state == .active ? "in_progress" : "pending") + " · " + $0.title }
                .joined(separator: "\n"))
        }
        cues[id] = cue
    }
    private func approvalNeeded(_ approval: ChatSession.PendingApproval) {
        guard let bot = bot(approval.bot), bot.permissions.approvalsHere, !isShowing(approval.bot) else { return }
        show(DockCallout(bot: approval.bot, text: "Needs your OK: " + approval.summary), for: 12)
    }
    private func turnEnded(_ id: UUID) {
        cues[id] = nil
        testRuns[id] = nil
    }
    /// Whether a bot's turn is running anywhere, and its words so far.
    public func running(_ id: UUID) -> Bool {
        // KemoSabe is at work while it reads for a bot, not while its question waits on the owner.
        if id == BotSpec.kemoSabeID, sessions.values.contains(where: { session in
            session.liveExchanges.contains { !session.needsConsent($0) && session.sharePrompts[$0] == nil }
        }) { return true }
        if plugged(id)?.tileStatus == .working { return true }
        return sessions.values.contains { $0.working[id] != nil }
    }
    /// A plugged-in panel's work that finished or didn't, which the owner hasn't opened yet; the tile marks it.
    public func unread(_ id: UUID) -> ServiceBotTileStatus? {
        guard let status = plugged(id)?.tileUnread, status == .done || status == .failed else { return nil }
        return status
    }
    /// The panel plugged in for this bot's tile (Tsukumo's Claude bot), whose background work shows on it.
    func plugged(_ id: UUID) -> (any ServiceBotPanelProvider)? { panelProviders[id] }
    public func words(_ id: UUID) -> String {
        sessions.values.compactMap { $0.working[id]?.text }.first { !$0.isEmpty } ?? ""
    }
    /// What the bot's character acts out now.
    public func characterState(_ id: UUID, tucked: Bool = false) -> BotState {
        let date = now()
        let sinceChirp = lastChirp.flatMap { $0.bot == id ? date.timeIntervalSince($0.at) : nil }
        let bot = bot(id)
        let coding = id == BotSpec.kemoSabeID || (cues[id]?.running ?? false) || (bot?.engine.runsOnlyOnMac == true && bot?.contextScope.project != nil)
        let done = finishedAt[id].map { date.timeIntervalSince($0) < 4 } ?? false
        return DockCharacterState.resolve(needsYou: needsYou(id), running: running(id), hasWords: !words(id).isEmpty, coding: coding,
                                          voicing: voice?.speakingBot == id, sinceChirp: sinceChirp, done: done, tucked: tucked,
                                          night: settings.sleepAtNight && DockCharacterState.isNight(date))
    }
    /// The first bot waiting on the owner (the sliver brightens; a host's status line can say so).
    public var waitingBot: BotSpec? { bots.first { needsYou($0.id) } }
    /// "Working…", "Needs you", or what it does.
    public func subtitle(_ id: UUID) -> String {
        guard let bot = bot(id) else { return "" }
        if needsYou(id) { return plugged(id)?.tileStatus == .needsYou ? plugged(id)?.tileLine ?? "Needs you" : "Needs you" }
        if listener(for: id) != nil { return "Listening…" }
        if voice?.speakingBot == id { return "Speaking…" }
        if let line = plugged(id)?.tileLine { return line }
        if running(id) { return bot.isKemoSabe ? "Looking on this Mac…" : "Working…" }
        if bot.isKemoSabe { return "Your secure assistant · Apple on-device" }
        if case .dot = bot.origin { return "Your ChatGPT dot · opens in Codex" }
        guard bot.engine.chats else { return "Asks KemoSabe through the gateway" }
        return engineInfo(bot.engine).title
    }
    public func react(_ kind: DockReaction, on id: UUID) {
        reaction[id] = (kind, (reaction[id]?.tick ?? 0) + 1)
    }

    // MARK: KemoSabe's questions

    /// A question a bot asked KemoSabe that waits on the owner: the first OK, or sharing one Sensitive item.
    public struct Pending: Identifiable, Hashable, Sendable {
        public enum Kind: Hashable, Sendable { case consent, share(SharePrompt) }
        public let exchange: GateExchangeID
        public let bot: UUID
        public let askerName: String
        public let question: String
        public let purpose: String
        public let kind: Kind
        /// The conversation it's in.
        public let conversation: UUID
        public var id: GateExchangeID { exchange }
    }
    /// Every question waiting on the owner, across conversations.
    public var pending: [Pending] {
        var found: [Pending] = []
        for (key, session) in sessions {
            for message in session.thread.messages.suffix(30) {
                for part in message.parts {
                    // An outside caller's question (Muse) waits on KemoSabe's own tile.
                    guard case .gateQuestion(let card) = part,
                          let asker = card.askedBy ?? (key == BotSpec.kemoSabeID ? BotSpec.kemoSabeID : nil) else { continue }
                    if session.needsConsent(card.exchange) {
                        found.append(Pending(exchange: card.exchange, bot: asker, askerName: card.askerName, question: card.question,
                                             purpose: card.purpose, kind: .consent, conversation: key))
                    } else if let prompt = session.sharePrompts[card.exchange] {
                        found.append(Pending(exchange: card.exchange, bot: asker, askerName: card.askerName, question: card.question,
                                             purpose: card.purpose, kind: .share(prompt), conversation: key))
                    }
                }
            }
        }
        return found.sorted { $0.exchange.rawValue.uuidString < $1.exchange.rawValue.uuidString }
    }
    /// The owner's answer to a pending question (from Activity, or a host's own view).
    public func decide(_ choice: ConsentChoice, for pending: Pending) { sessions[pending.conversation]?.decide(choice, for: pending.exchange) }
    public func share(_ allow: Bool, for pending: Pending) { sessions[pending.conversation]?.decideShare(allow, for: pending.exchange) }

    // MARK: Outside callers (Muse)

    // Muse's questions for KemoSabe go through the KemoSabe gateway (`DockMuseBridge`), never straight to the Gate.

    /// A task an outside caller hands to one of the owner's bots. It runs in a fresh, throwaway session that
    /// isn't saved (no chat history, no saved engine session, no references, no tools, no KemoSabe), never on a
    /// coding agent. The reply leaves only through KemoSabe: a card in KemoSabe's chat the first time, the
    /// caller's consent after that, and the journal. The bot's own chat gets one line recording it.
    /// A bot's reply KemoSabe released to an outside caller, not yet handed over: `finishRelay` says whether it was.
    public struct RelayedReply: Sendable {
        public let text: String
        let card: GateAnswerCard
        let botID: UUID
        let summary: String
    }

    public func relay(_ task: String, from caller: KemoSabeCaller, to botID: UUID) async -> Result<RelayedReply, ChatSession.RelayFailure> {
        guard let bot = bot(botID), !bot.isKemoSabe, bot.engine.chats else { return .failure(.init("There’s no bot by that name here.")) }
        guard !bot.engine.runsOnlyOnMac else { return .failure(.init("\(bot.name) runs a coding agent, so it doesn’t take tasks from \(caller.name).")) }
        guard let kemoSabe = sessions[BotSpec.kemoSabeID] else { return .failure(.init("KemoSabe isn’t here.")) }
        let thread = ChatThread(title: "\(caller.name)’s task for \(bot.name)", botIDs: [bot.id], lastSpokenTo: bot.id)
        let isolated = makeSession(thread, [bot])
        let line = task.split(whereSeparator: \.isNewline).first.map(String.init) ?? task
        let preview = line.count <= 120 ? line : String(line.prefix(119)) + "…"
        let summary = "\(caller.name) asked \(bot.name), in a separate session: “\(preview)”. "
        let result = await isolated.runIsolated(task, from: caller, on: bot.id)
        guard case .success(let reply) = result else {
            sessions[botID]?.note(summary + "No reply was shared.")
            if case .failure(let failure) = result { return .failure(failure) }
            return .failure(.init("\(bot.name) didn’t reply."))
        }
        let card = await askingOwner(caller.name) {
            await kemoSabe.release(reply, from: bot.name, to: caller, purpose: "\(caller.name) asked \(bot.name): \(preview)")
        }
        guard card.outcome == .answered, let shared = card.shared else {
            sessions[botID]?.note(summary + "Its reply wasn’t shared.")
            return .failure(.init(card.outcome == .denied ? "The owner didn’t share \(bot.name)’s reply." : "The owner hasn’t answered on their Mac yet. Ask again in a minute."))
        }
        return .success(RelayedReply(text: shared, card: card, botID: bot.id, summary: summary))
    }

    /// Ends a released reply in the same step as handing it over (or not): KemoSabe's chat, the journal, Activity, and
    /// the bot's chat say what really happened. Not delivered, KemoSabe is told so and nothing claims it was shared.
    public func finishRelay(_ reply: RelayedReply, delivered: Bool) {
        sessions[BotSpec.kemoSabeID]?.finishRelease(reply.card, delivered: delivered)
        sessions[reply.botID]?.note(reply.summary + (delivered ? "KemoSabe shared its reply." : "Its reply wasn’t sent."))
    }

    /// Runs `work` (a card in KemoSabe's chat) with a speech bubble on KemoSabe's tile if the owner needs to answer it.
    private func askingOwner(_ name: String, _ work: () async -> GateAnswerCard) async -> GateAnswerCard {
        let watch = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled, self.needsYou(BotSpec.kemoSabeID), !self.isShowing(BotSpec.kemoSabeID) else { return }
            self.show(DockCallout(bot: BotSpec.kemoSabeID, text: "\(name) is asking me something. Open my chat to answer."))
        }
        defer { watch.cancel() }
        return await work()
    }

    /// Something an outside caller did, for Activity.
    public func note(_ item: ActivityItem) { record(item) }

    // MARK: Surfaces and callouts

    /// Opens a panel beside the side dock (nil closes it).
    public func open(_ surface: DockSurface?) {
        switch surface { case .addBot?, .panel?: refreshCharacters?(); default: break }
        self.surface = surface
        if case .bot(let id)? = surface { store.setLastTalkedTo(id); dismissCallout() }
    }
    public func toggle(_ surface: DockSurface) {
        dismissCallout()
        open(self.surface == surface ? nil : surface)
    }
    /// Whether the owner is looking at this bot's words right now.
    public func isShowing(_ id: UUID) -> Bool {
        surface == .bot(id) || surface == .together
    }
    public func show(_ callout: DockCallout, for seconds: Double = 6) {
        self.callout = callout
        calloutTask?.cancel()
        calloutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, self?.callout?.id == callout.id else { return }
            self?.callout = nil
        }
    }
    public func dismissCallout() { calloutTask?.cancel(); callout = nil }

    // MARK: Chirps

    /// Posts a chirp: a speech bubble from the tile, a hop, and a line in Activity. It never touches a
    /// running turn and never goes to a bot.
    public func post(_ chirp: DockChirp, remember: Bool = true) {
        guard let bot = bot(chirp.bot), bot.permissions.mayChirp, !(remember && store.hasChirped(chirp.key)) else { return }
        if remember { store.markChirped(chirp.key, at: now()) }
        lastChirp = (chirp.bot, now())
        record(ActivityItem(date: now(), kind: .botWork, title: "\(bot.name) chirped in", detail: chirp.text, botID: bot.id))
        onChirp?()
        Task { [weak self] in try? await Task.sleep(for: .seconds(3.1)); self?.settleTick += 1 }
        show(DockCallout(bot: chirp.bot, text: chirp.text))
    }
    /// Reads what's coming up and posts the chirps the rules allow.
    public func checkUpcoming() async {
        let allowed = allowedSources()
        let watches = store.state.chirpWatches
        let watched = Set(watches.values.flatMap(\.sources)).intersection(allowed)
        guard let upcoming, !watched.isEmpty else { return }
        let start = now(), lead = TimeInterval((watches.values.map(\.leadMinutes).max() ?? 120) * 60)
        let items = await upcoming.items(from: start, to: start.addingTimeInterval(lead), sources: watched)
        for chirp in DockChirpRules.upcoming(bots: bots, watches: watches, items: items, now: now(), allowed: allowed, chirped: store.hasChirped) {
            post(chirp)
        }
    }
    public func startChirps() {
        chirpLoop?.cancel()
        chirpLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkUpcoming()
                try? await Task.sleep(for: DockChirpRules.interval)
            }
        }
    }
    /// Stops chirps and every running turn (before quitting).
    public func shutDown() {
        chirpLoop?.cancel(); chirpLoop = nil
        for session in sessions.values { session.stopAll() }
    }
}

// MARK: Engines on a Mac

public extension BotDock {
    static let appleOnDevice = EngineChoice(engine: .appleOnDevice, info: EngineInfo(title: "Apple on-device", detail: "On this Mac. Nothing leaves it.", mark: .apple),
                                            wire: .apple)

    /// What a bot may run on, on a Mac, before the app has looked for coding agents: KemoSabe's on-device
    /// model, and the coding agents Tsukumo can run, with the models they're known to offer.
    static let macEngines: [EngineChoice] = [appleOnDevice] + CodingAgentKind.all.filter(\.alwaysListed).map {
        codingEngine($0, installed: InstalledCodingAgent(kind: $0, executable: URL(fileURLWithPath: "/usr/bin/false")), versioned: false)
    }

    /// What a bot may run on, on this Mac: KemoSabe's on-device model, then each coding agent that's installed
    /// (its version, and the models and efforts it reported), and the ones that aren't, greyed with how to get them.
    static func macEngines(coding installed: [InstalledCodingAgent]) -> [EngineChoice] {
        [appleOnDevice] + CodingAgentKind.all.compactMap { kind in
            if let agent = installed.first(where: { $0.kind == kind }) { return codingEngine(kind, installed: agent, versioned: true) }
            guard kind.alwaysListed else { return nil }
            return EngineChoice(engine: kind.engine, info: info(kind, version: nil), unavailable: "Not on this Mac. " + kind.install)
        }
    }

    private static func info(_ kind: CodingAgentKind, version: String?) -> EngineInfo {
        var info = EngineInfo.standard(kind.engine)
        info.title = kind.title
        info.detail = "Runs on your Mac with your own sign-in" + (version.map { " · version \($0)" } ?? "")
        return info
    }
    private static func codingEngine(_ kind: CodingAgentKind, installed: InstalledCodingAgent, versioned: Bool) -> EngineChoice {
        // "default" is Claude Code's own name for leaving the model to it: that's "Engine's default" here.
        let listed = installed.models.filter { $0.id != "default" && !$0.id.isEmpty }
        let models = listed.filter(\.isDefault) + listed.filter { !$0.isDefault }
        return EngineChoice(engine: kind.engine, info: info(kind, version: versioned ? installed.version : nil), models: models.map(\.id),
                            modelNames: Dictionary(models.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }),
                            modelEfforts: Dictionary(models.map { ($0.id, $0.efforts) }, uniquingKeysWith: { first, _ in first }))
    }
}
#endif

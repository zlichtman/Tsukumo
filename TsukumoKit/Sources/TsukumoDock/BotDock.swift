#if os(macOS)
import Foundation
import Observation
import SwiftUI
import TsukumoCore
import TsukumoGate
import TsukumoUI

// The dock's brain (ported from `AgentsDock` in the old Mac app's dock). The old dock ran
// turns through its own runner; now every conversation is TsukumoUI's `ChatSession`, the same chat as
// the iPhone app, so a bot's turn, KemoSabe's card, consent, and Activity work exactly as they do there.
// The dock keeps one session per bot (its own chat) and one for Together, reads each tile's state from
// them, and adds what only the dock has: callouts, chirps, pokes, and the done celebration.

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
    /// KemoSabe's Gate, when the dock was made with `standard` (Settings, KemoSabe shows its grants and journal).
    @ObservationIgnored public var gate: Gate?
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
    /// What each coding bot's work is doing (the host fills it from its coding agents).
    public var cues: [UUID: DockWorkCue] = [:]
    /// Bumped when a one-off moment is over, so live clocks can stop.
    public private(set) var settleTick = 0
    @ObservationIgnored private var calloutTask: Task<Void, Never>?
    @ObservationIgnored private var chirpLoop: Task<Void, Never>?

    public init(store: BotDockStore, makeSession: @escaping @MainActor (ChatThread, [BotSpec]) -> ChatSession) {
        self.store = store
        self.makeSession = makeSession
        for bot in store.bots { openSession(bot.id) }
        openSession(Self.togetherID)
    }

    public var bots: [BotSpec] { store.bots }
    public var settings: DockSettings { store.settings }
    public func bot(_ id: UUID?) -> BotSpec? { store.bot(id) }

    // MARK: Conversations

    /// The bots a conversation may tag: KemoSabe and the bot (a bot's own chat), or everyone (Together).
    func members(_ key: UUID) -> [BotSpec] {
        if key == Self.togetherID { return bots }
        guard let bot = bot(key) else { return [] }
        return bot.isKemoSabe ? [bot] : [bots[0], bot]
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
        sessions[key] = session
    }
    /// A bot's own chat (or Together's).
    public func session(_ key: UUID) -> ChatSession? { sessions[key] }

    /// Keeps every conversation's bots current after the dock's bots change.
    private func botsChanged() {
        for bot in bots where sessions[bot.id] == nil { openSession(bot.id) }
        for key in sessions.keys where key != Self.togetherID && bot(key) == nil { sessions[key]?.stopAll(); sessions[key] = nil }
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

    @discardableResult public func add(_ bot: BotSpec) -> Result<BotSpec, BotProblem> {
        let result = store.add(bot)
        botsChanged()
        return result
    }
    @discardableResult public func update(_ bot: BotSpec) -> Result<BotSpec, BotProblem> {
        let result = store.update(bot)
        botsChanged()
        return result
    }
    public func remove(_ id: UUID) {
        guard id != BotSpec.kemoSabeID else { return }
        sessions[id]?.stopAll()
        if surface == .bot(id) || surface == .edit(id) { surface = nil }
        store.remove(id)
        finishedAt[id] = nil; cues[id] = nil; reaction[id] = nil
        botsChanged()
    }
    public func move(_ id: UUID, to index: Int) {
        store.move(id, to: index)
        botsChanged()
    }
    /// Takes what sync brought from the owner's other devices: the bots, and each conversation's chat. A
    /// conversation that's mid-turn picks the change up when its turn ends (its next save merges again).
    public func applySynced(bots: [BotSpec], threads: [ChatThread]) {
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
        if cues[id]?.approval != nil { return true }
        return !pending.filter { $0.bot == id }.isEmpty
    }
    /// Whether a bot's turn is running anywhere, and its words so far.
    public func running(_ id: UUID) -> Bool {
        // KemoSabe is at work while it reads for a bot, not while its question waits on the owner.
        if id == BotSpec.kemoSabeID, sessions.values.contains(where: { session in
            session.liveExchanges.contains { !session.needsConsent($0) && session.sharePrompts[$0] == nil }
        }) { return true }
        return sessions.values.contains { $0.working[id] != nil }
    }
    public func words(_ id: UUID) -> String {
        sessions.values.compactMap { $0.working[id]?.text }.first { !$0.isEmpty } ?? ""
    }
    /// What the bot's character acts out now.
    public func characterState(_ id: UUID, tucked: Bool = false) -> ClayState {
        let date = now()
        let sinceChirp = lastChirp.flatMap { $0.bot == id ? date.timeIntervalSince($0.at) : nil }
        let bot = bot(id)
        let coding = id == BotSpec.kemoSabeID || (cues[id]?.running ?? false) || (bot?.engine.runsOnlyOnMac == true && bot?.contextScope.project != nil)
        let done = finishedAt[id].map { date.timeIntervalSince($0) < 4 } ?? false
        return DockCharacterState.resolve(needsYou: needsYou(id), running: running(id), hasWords: !words(id).isEmpty, coding: coding,
                                          voicing: false, sinceChirp: sinceChirp, done: done, tucked: tucked,
                                          night: settings.sleepAtNight && DockCharacterState.isNight(date))
    }
    /// The first bot waiting on the owner (the sliver brightens; a host's status line can say so).
    public var waitingBot: BotSpec? { bots.first { needsYou($0.id) } }
    /// "Working…", "Needs you", or what it does.
    public func subtitle(_ id: UUID) -> String {
        guard let bot = bot(id) else { return "" }
        if needsYou(id) { return "Needs you" }
        if running(id) { return bot.isKemoSabe ? "Looking on this Mac…" : "Working…" }
        if bot.isKemoSabe { return "Your secure assistant · Apple on-device" }
        return [bot.role.isEmpty ? nil : bot.role, engineInfo(bot.engine).title].compactMap { $0 }.joined(separator: " · ")
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
                    guard case .gateQuestion(let card) = part, let asker = card.askedBy else { continue }
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

    // MARK: Surfaces and callouts

    /// Opens a panel beside the side dock (nil closes it).
    public func open(_ surface: DockSurface?) {
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
    /// What a bot may run on, on a Mac: KemoSabe's on-device model, and the coding agents.
    static let macEngines: [EngineChoice] = [
        EngineChoice(engine: .appleOnDevice, info: EngineInfo(title: "Apple on-device", detail: "On this Mac. Nothing leaves it.", mark: .apple), wire: .apple),
        EngineChoice(engine: .codingAgent("claude-code"), info: .standard(.codingAgent("claude-code")),
                     models: ["claude-opus-5-5", "claude-sonnet-5"], wire: .anthropic),
        EngineChoice(engine: .codingAgent("codex"), info: .standard(.codingAgent("codex")), models: ["gpt-5.2-codex", "gpt-5.2"], wire: .openAI),
        EngineChoice(engine: .codingAgent("muse"), info: .standard(.codingAgent("muse"))),
        EngineChoice(engine: .codingAgent("cursor-agent"), info: .standard(.codingAgent("cursor-agent")))
    ]
}
#endif

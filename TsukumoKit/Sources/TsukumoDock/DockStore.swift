#if os(macOS)
import Foundation
import Observation
import TsukumoCore
import TsukumoUI

// What the dock saves (ported from `DockState` and `AgentsDockStore` in the old Mac app's dock), on TsukumoKit's
// types: KemoSabe and the owner's bots are `BotSpec`s, conversations are `ChatThread`s, and Activity is
// `ActivityItem`s. One small JSON file the host chooses, or memory only (previews, tests). A file from 2.05's fixed
// lineup (one bot per service) moves to the owner's own bots once (`adoptBots`).

/// Everything the dock saves.
public struct DockState: Codable, Equatable, Sendable {
    public static let version = 1
    public static let maxActivity = 200
    public var version = DockState.version
    /// KemoSabe first, then the owner's bots in the owner's order.
    public var bots: [BotSpec] = []
    /// Nil until the owner changes something (then the system Dock's size is the start).
    public var settings: DockSettings?
    /// Each bot's own conversation, and Together's (`BotDock.togetherID`).
    public var threads: [UUID: ChatThread] = [:]
    public var activity: [ActivityItem] = []
    /// What each bot chirps about.
    public var chirpWatches: [UUID: DockChirpWatch] = [:]
    /// Chirps already made (`DockChirpRules.key`), with when, so each happens once.
    public var chirped: [String: Date] = [:]
    /// The bot the owner last talked to.
    public var lastTalkedTo: UUID?
    /// Chats from the owner's other devices that aren't one of the dock's conversations.
    public var otherChats: [ChatThread] = []
    /// What new bots started on before the fixed lineup (it syncs with the iPhone; nothing sets it now).
    public var defaultModel: DefaultModel?
    /// Each chat's coding agent sessions (`AgentSessionKey.raw` to the agent's handle), so the next turn
    /// continues the same one. On this Mac only; never synced.
    public var agentSessions: [String: String] = [:]
    /// 1 once 2.05 moved an older file's custom bots into its fixed lineup; 3 once the lineup became the owner's own
    /// bots (`adoptBots`); nil before either.
    public var lineupVersion: Int?
    /// 2.05's one-time notice of what its move did, until the owner has seen it ("Your custom bots were moved: …").
    public var lineupNotice: String?
    /// What 2.05's move retired (folded and departed bots, merged chats), kept for good so sync from a device that
    /// hasn't moved maps onto what they became.
    public var lineupAliases = LineupAliases()
    /// Whether the gateway's confirmed callers still have to come in as bots (once, after `adoptBots`; the dock does it
    /// when its gateway is there).
    public var callersToBringIn = false
    /// Which service each gateway caller is, as the owner confirmed it (by the caller's authenticated ID). A caller
    /// without one is an unverified agent, never filed under a service by its name.
    public var callerBindings: [String: CallerBinding] = [:]

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case version, bots, settings, threads, activity, chirpWatches, chirped, lastTalkedTo, otherChats, defaultModel, agentSessions
        case lineupVersion, lineupNotice, lineupAliases, callerBindings, callersToBringIn
    }
    /// A file from a newer build keeps loading: what it can't read takes its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? Self.version
        bots = (try? c.decodeIfPresent([BotSpec].self, forKey: .bots)) ?? []
        settings = try? c.decodeIfPresent(DockSettings.self, forKey: .settings)
        threads = (try? c.decodeIfPresent([UUID: ChatThread].self, forKey: .threads)) ?? [:]
        activity = (try? c.decodeIfPresent([ActivityItem].self, forKey: .activity)) ?? []
        chirpWatches = (try? c.decodeIfPresent([UUID: DockChirpWatch].self, forKey: .chirpWatches)) ?? [:]
        chirped = (try? c.decodeIfPresent([String: Date].self, forKey: .chirped)) ?? [:]
        lastTalkedTo = try? c.decodeIfPresent(UUID.self, forKey: .lastTalkedTo)
        otherChats = (try? c.decodeIfPresent([ChatThread].self, forKey: .otherChats)) ?? []
        defaultModel = try? c.decodeIfPresent(DefaultModel.self, forKey: .defaultModel)
        agentSessions = (try? c.decodeIfPresent([String: String].self, forKey: .agentSessions)) ?? [:]
        lineupVersion = try? c.decodeIfPresent(Int.self, forKey: .lineupVersion)
        lineupNotice = try? c.decodeIfPresent(String.self, forKey: .lineupNotice)
        lineupAliases = (try? c.decodeIfPresent(LineupAliases.self, forKey: .lineupAliases)) ?? LineupAliases()
        callerBindings = (try? c.decodeIfPresent([String: CallerBinding].self, forKey: .callerBindings)) ?? [:]
        callersToBringIn = (try? c.decodeIfPresent(Bool.self, forKey: .callersToBringIn)) ?? false
    }
}

/// The owner's word on which service a gateway caller is, bound to the caller's authenticated ID.
public struct CallerBinding: Codable, Hashable, Sendable {
    /// The service, or nil for an agent that's none of them.
    public var service: ServiceID?
    /// How it reached KemoSabe when it was confirmed ("from this Mac", "through the relay", "a token you made", "paired").
    public var transport: String
    public var confirmedAt: Date
    public init(service: ServiceID?, transport: String, confirmedAt: Date = Date()) {
        self.service = service; self.transport = transport; self.confirmedAt = confirmedAt
    }
}

/// The dock's bots, settings, and conversations.
@MainActor @Observable public final class BotDockStore {
    public private(set) var state: DockState
    /// Why the last save failed, shown in the dock.
    public private(set) var problem: String?
    @ObservationIgnored public let file: URL?
    /// Something was saved (a host's sync listens here).
    @ObservationIgnored public var onChange: (() -> Void)?

    /// `file` nil keeps everything in memory. KemoSabe is always there, first, under `kemoSabeName`.
    public init(file: URL?, kemoSabeName: String = "KemoSabe") {
        self.file = file
        var loaded = file.flatMap { url in (try? Data(contentsOf: url)).flatMap { try? Self.decoder.decode(DockState.self, from: $0) } } ?? DockState()
        // KemoSabe is always first and always standard, keeping its palette, its voice, and whether it chirps.
        let saved = loaded.bots.first { $0.isKemoSabe }
        loaded.bots.removeAll { $0.isKemoSabe }
        var kemoSabe = BotSpec.kemoSabe(name: kemoSabeName, palette: saved?.kemoSabePalette.id ?? BotLook.kemoSabe.palette, figure: saved?.look.figure)
        kemoSabe.permissions.mayChirp = saved?.permissions.mayChirp ?? true
        kemoSabe.voice = saved?.normalized().voice
        loaded.bots.insert(kemoSabe, at: 0)
        state = loaded
    }

    // MARK: The owner's bots

    /// Moves a file from before October 8, 2026 to the owner's own bots, once (TsukumoCore's `BotLineup.adopt`): each
    /// service bot the owner used (saved settings, a conversation with messages, or a service in `used`) stays as a bot
    /// of their own on the engine `engine` gives it; the gateway's services' callers come back as brought-in bots (the
    /// dock brings them in once its gateway is there). 2.05 (lineup version 1) moved KemoSabe from Apricot to Classic
    /// with its two-tone look; its cloud is the standard look again, so a KemoSabe still in that Classic, with no
    /// figure picked, goes back to Apricot. If the file can't be written nothing changes and the reason is returned.
    @discardableResult public func adoptBots(used: Set<ServiceID> = [], engine: (ServiceID) -> EngineID) -> Result<Void, BotProblem> {
        guard (state.lineupVersion ?? 0) < 3 else { return .success(()) }
        var next = state
        if next.lineupVersion == 1, next.bots[0].look.figure == nil, next.bots[0].kemoSabePalette.id == KemoSabeLook.finder.defaultPalette {
            next.bots[0].look = .kemoSabe(palette: KemoSabeLook.standard.defaultPalette)
        }
        let talked = Set(ServiceID.allCases.filter { next.threads[$0.botID]?.messages.isEmpty == false })
        next.bots = [next.bots[0]] + BotLineup.adopt(saved: next.bots, used: used.union(talked), engine: engine)
        next.callersToBringIn = !next.callerBindings.isEmpty
        next.lineupVersion = 3
        // A conversation whose bot left (a gateway service's) is kept beside the others.
        let ids = Set(next.bots.map(\.id))
        for key in Array(next.threads.keys).sorted(by: { $0.uuidString < $1.uuidString }) where key != BotDock.togetherID && !ids.contains(key) {
            if let thread = next.threads.removeValue(forKey: key), !thread.messages.isEmpty { next.otherChats.append(thread) }
        }
        do { try persist(next) } catch {
            return .failure(.init("Tsukumo couldn’t save the dock (\(error.localizedDescription)), so your bots weren’t updated yet. It tries again next time it opens."))
        }
        state = next
        onChange?()
        return .success(())
    }

    /// The owner saw 2.05's notice.
    public func dismissLineupNotice() {
        guard state.lineupNotice != nil else { return }
        state.lineupNotice = nil
        save()
    }

    /// Adds one of the owner's bots, at the end: made here, or a service's own bot brought in. Its name is its own, a
    /// brought-in bot is on the dock once, and the dock holds at most `BotLineup.maxBots` besides KemoSabe.
    /// `continuing` is a coding agent's own session (a Codex thread, a Claude Code session) its chat picks up.
    @discardableResult public func add(_ bot: BotSpec, continuing session: String? = nil) -> Result<BotSpec, BotProblem> {
        guard !bot.isKemoSabe, !state.bots.contains(where: { $0.id == bot.id }) else { return .failure(.init("That bot is already on the dock.")) }
        guard state.bots.count - 1 < BotLineup.maxBots else {
            return .failure(.init("The dock holds \(BotLineup.maxBots) bots besides KemoSabe. Remove one to add another."))
        }
        if bot.isBroughtIn, let same = state.bots.first(where: { $0.origin == bot.origin }) {
            return .failure(.init("\(same.name) is already on the dock."))
        }
        switch bot.validated(existing: state.bots) {
        case .failure(let problem): return .failure(problem)
        case .success(let clean):
            var next = state
            next.bots.append(clean)
            if let session, clean.engine.runsOnlyOnMac {
                let chat = ChatThread(title: clean.name, botIDs: [BotSpec.kemoSabeID, clean.id], lastSpokenTo: clean.id)
                next.threads[clean.id] = chat
                let key = AgentSessionKey(thread: chat.id, bot: clean.id, engine: clean.engine.key, folder: clean.contextScope.project ?? "")
                next.agentSessions[key.raw] = session
            }
            if let problem = commit(next) { return .failure(problem) }
            return .success(clean)
        }
    }

    /// Takes a bot off the dock. Its conversation is never deleted: it's kept beside the others (and syncs), and what it
    /// chirped about and its coding agent sessions go with it. KemoSabe is never removed.
    @discardableResult public func remove(_ id: UUID) -> BotProblem? {
        guard id != BotSpec.kemoSabeID, let index = state.bots.firstIndex(where: { $0.id == id }) else { return nil }
        var next = state
        next.bots.remove(at: index)
        if let thread = next.threads.removeValue(forKey: id) {
            if !thread.messages.isEmpty { next.otherChats.append(thread) }
            let prefix = thread.id.uuidString + "|"
            next.agentSessions = next.agentSessions.filter { !$0.key.hasPrefix(prefix) }
        }
        next.chirpWatches[id] = nil
        if next.lastTalkedTo == id { next.lastTalkedTo = nil }
        return commit(next)
    }

    /// Moves a bot to another place on the dock (KemoSabe stays first).
    public func move(_ id: UUID, to place: Int) {
        guard id != BotSpec.kemoSabeID, let index = state.bots.firstIndex(where: { $0.id == id }) else { return }
        var next = state
        let bot = next.bots.remove(at: index)
        next.bots.insert(bot, at: min(max(place, 1), next.bots.count))
        commit(next)
    }

    /// Writes `next` and takes it, or leaves everything as it was and says why (the dock shows it).
    @discardableResult private func commit(_ next: DockState) -> BotProblem? {
        do { try persist(next) } catch {
            problem = "The dock couldn’t save, so that change wasn’t made."
            return BotProblem("Tsukumo couldn’t save the dock (\(error.localizedDescription)), so that change wasn’t made.")
        }
        state = next
        problem = nil
        onChange?()
        return nil
    }

    /// Whether the gateway's confirmed callers still have to come in as bots, and that they did.
    public var callersToBringIn: Bool { state.callersToBringIn }
    public func broughtInCallers() {
        guard state.callersToBringIn else { return }
        state.callersToBringIn = false
        save()
    }

    // MARK: Gateway callers

    /// The owner's word on which service a caller is, if they've given it.
    public func binding(forCaller id: String) -> CallerBinding? { state.callerBindings[id] }
    /// Binds a caller (by its authenticated ID) to a service, or to none.
    public func bind(caller id: String, to service: ServiceID?, transport: String, at date: Date = Date()) {
        let binding = CallerBinding(service: service, transport: transport, confirmedAt: date)
        guard state.callerBindings[id]?.service != service || state.callerBindings[id] == nil else { return }
        state.callerBindings[id] = binding
        save()
    }
    public func forgetBinding(caller id: String) {
        guard state.callerBindings[id] != nil else { return }
        state.callerBindings[id] = nil
        save()
    }

    // MARK: Sync

    /// The chats this dock keeps that aren't one of its conversations: chats from the owner's iPhone,
    /// kept so they sync back and forth intact.
    public var otherChats: [ChatThread] { state.otherChats }

    /// The dock's bots and every conversation, as sync sees them.
    public var library: (bots: [BotSpec], threads: [ChatThread]) {
        (state.bots, Array(state.threads.values) + state.otherChats)
    }
    /// What the lineup migration retired, for sync.
    public var aliases: LineupAliases { state.lineupAliases }
    /// Takes another device's aliases (they only grow), so every device maps old IDs the same way.
    public func addAliases(_ other: LineupAliases) {
        var next = state.lineupAliases
        next.add(other)
        guard next != state.lineupAliases else { return }
        state.lineupAliases = next
        save()
    }
    /// Takes what sync brought: the bots (KemoSabe first and standard), each conversation by its chat's
    /// ID, and other devices' chats beside them. Returns the conversations that changed.
    /// `conversations` names the chat each open conversation shows (by chat ID), for ones not saved yet.
    @discardableResult public func applySynced(bots: [BotSpec], threads: [ChatThread], conversations: [UUID: UUID] = [:]) -> Set<UUID> {
        var next = state
        let synced = bots.first { $0.isKemoSabe }
        var kept = synced.map { BotSpec.kemoSabe(name: state.bots[0].name, palette: $0.kemoSabePalette.id, figure: $0.look.figure) } ?? state.bots[0]
        kept.permissions.mayChirp = state.bots[0].permissions.mayChirp
        // Its voice syncs, as its palette does.
        if let synced { kept.voice = synced.voice }
        // A bot 2.05's lineup moved, from a device that hasn't moved, is an alias: it isn't brought back.
        let incoming = bots.filter { !$0.isKemoSabe && !state.lineupAliases.retires(bot: $0.id) }.map { $0.normalized() }
        next.bots = [kept] + BotLineup.oneEach(incoming)
        // Chats arrive already mapped through the aliases (`LibraryMapping`), each to its conversation by its ID.
        var others: [ChatThread] = []
        for thread in threads {
            if let key = next.threads.first(where: { $0.value.id == thread.id })?.key ?? conversations[thread.id] {
                next.threads[key] = thread
            } else {
                others.append(thread)
            }
        }
        // A conversation whose chat was deleted elsewhere starts over empty here.
        let present = Set(threads.map(\.id))
        for (key, thread) in next.threads where !present.contains(thread.id) && !thread.messages.isEmpty { next.threads[key] = nil }
        next.otherChats = others
        // A conversation whose bot isn't kept any more is never deleted: it's kept beside the others.
        let ids = Set(next.bots.map(\.id))
        for key in Array(next.threads.keys).sorted(by: { $0.uuidString < $1.uuidString }) where key != BotDock.togetherID && !ids.contains(key) {
            if let thread = next.threads.removeValue(forKey: key), !thread.messages.isEmpty { next.otherChats.append(thread) }
        }
        let keys = Set(next.threads.keys).union(state.threads.keys)
        let changed = Set(keys.filter { next.threads[$0] != state.threads[$0] })
        guard next != state else { return [] }
        state = next
        save()
        return changed
    }

    public var bots: [BotSpec] { state.bots }
    public func bot(_ id: UUID?) -> BotSpec? { state.bots.first { $0.id == id } }

    // MARK: Bots

    /// Saves what the owner set on KemoSabe or one of their bots. A new engine starts on its own default model and
    /// effort. KemoSabe stays standard (its name, look, engine, job, and scope); only its palette, figure, voice, and
    /// whether it chirps change. A brought-in bot keeps where it's from.
    @discardableResult public func update(_ bot: BotSpec) -> Result<BotSpec, BotProblem> {
        guard let index = state.bots.firstIndex(where: { $0.id == bot.id }) else { return .failure(.init("That bot isn’t on the dock any more.")) }
        let old = state.bots[index]
        if old.isKemoSabe {
            let look = bot.look.normalizedForKemoSabe()
            var kept = BotSpec.kemoSabe(name: old.name, palette: look.palette, figure: look.figure)
            kept.permissions.mayChirp = bot.permissions.mayChirp
            kept.voice = bot.voice
            state.bots[index] = kept.normalized()
            save()
            return .success(state.bots[index])
        }
        var next = bot
        next.origin = old.origin
        if old.isBroughtIn { next.service = old.service }
        switch next.validated(existing: state.bots) {
        case .failure(let problem): return .failure(problem)
        case .success(var clean):
            if clean.engine != old.engine { clean.model = nil; clean.effort = nil }
            state.bots[index] = clean
            save()
            return .success(clean)
        }
    }
    // MARK: Settings

    /// The dock's settings: the saved ones, or to begin with the system Dock's size and magnification.
    public var settings: DockSettings { state.settings ?? DockSettings.matchingSystemDock() }
    public func update(settings change: (inout DockSettings) -> Void) {
        var next = settings
        change(&next)
        next = next.clamped()
        guard next != state.settings else { return }
        state.settings = next
        save()
    }

    /// What new bots start on.
    public var defaultModel: DefaultModel? { state.defaultModel }
    public func setDefaultModel(_ model: DefaultModel?) {
        guard state.defaultModel != model else { return }
        state.defaultModel = model
        save()
    }

    // MARK: Conversations and Activity

    public func thread(_ id: UUID) -> ChatThread? { state.threads[id] }
    /// Saves a conversation whole: its history is never trimmed (what an engine gets as context is limited where the turn
    /// is made, not here).
    public func setThread(_ thread: ChatThread, for id: UUID) {
        guard state.threads[id] != thread else { return }
        state.threads[id] = thread
        save()
    }
    /// Clears a conversation; its coding agents start new sessions next time.
    public func clearThread(_ id: UUID) {
        if let chat = state.threads[id]?.id {
            let prefix = chat.uuidString + "|"
            state.agentSessions = state.agentSessions.filter { !$0.key.hasPrefix(prefix) }
        }
        state.threads[id] = nil
        save()
    }

    // MARK: Coding agents' sessions

    public func agentSession(_ key: AgentSessionKey) -> String? { state.agentSessions[key.raw] }
    public func rememberAgentSession(_ session: String, for key: AgentSessionKey) {
        guard state.agentSessions[key.raw] != session else { return }
        state.agentSessions[key.raw] = session
        save()
    }
    /// The store as the chat's `EngineRunner` reads it.
    public var agentSessions: any AgentSessionStoring { DockAgentSessions(store: self) }
    public func appendActivity(_ item: ActivityItem) {
        state.activity.append(item)
        if state.activity.count > DockState.maxActivity { state.activity.removeFirst(state.activity.count - DockState.maxActivity) }
        save()
    }
    public func setLastTalkedTo(_ id: UUID?) {
        guard state.lastTalkedTo != id else { return }
        state.lastTalkedTo = id
        save()
    }

    // MARK: Chirps

    public func chirpWatch(_ id: UUID) -> DockChirpWatch { state.chirpWatches[id] ?? DockChirpWatch() }
    public func setChirpWatch(_ watch: DockChirpWatch, for id: UUID) {
        state.chirpWatches[id] = watch.cleaned()
        save()
    }
    public func hasChirped(_ key: String) -> Bool { state.chirped[key] != nil }
    public func markChirped(_ key: String, at date: Date) {
        state.chirped[key] = date
        // A week of keys is plenty to never repeat a chirp.
        state.chirped = state.chirped.filter { date.timeIntervalSince($0.value) < 7 * 86400 }
        save()
    }

    // MARK: Saving

    private func save() {
        onChange?()
        do { try persist(state); problem = nil } catch {
            problem = "The dock couldn’t save. Your bots and messages are kept until you quit."
        }
    }
    /// Writes `state` to the dock's file in one atomic step, or throws.
    func persist(_ state: DockState) throws {
        guard let file else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(state).write(to: file, options: [.atomic])
    }
    static var encoder: JSONEncoder { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; return encoder }
    static var decoder: JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }
}

/// The dock's saved coding agent sessions, for `EngineRunner` (which runs off the main actor).
struct DockAgentSessions: AgentSessionStoring {
    weak var store: BotDockStore?
    func session(for key: AgentSessionKey) async -> String? { await MainActor.run { store?.agentSession(key) } }
    func remember(_ session: String, for key: AgentSessionKey) async { await MainActor.run { store?.rememberAgentSession(session, for: key) } }
}
#endif

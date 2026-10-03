#if os(macOS)
import Foundation
import Observation
import TsukumoCore
import TsukumoUI

// What the dock saves (ported from `DockState` and `AgentsDockStore` in the old Mac app's dock),
// now on TsukumoKit's types: bots are `BotSpec`s with their `BotLook`, conversations are `ChatThread`s, and
// Activity is `ActivityItem`s. One small JSON file the host chooses, or memory only (previews, tests).

/// Everything the dock saves.
public struct DockState: Codable, Equatable, Sendable {
    public static let version = 1
    public static let maxActivity = 200
    public static let maxMessages = 400
    public var version = DockState.version
    /// KemoSabe first, then the owner's bots in dock order.
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
    /// What new bots start on (Settings, Models; it syncs with the iPhone).
    public var defaultModel: DefaultModel?

    public init() {}

    private enum CodingKeys: String, CodingKey { case version, bots, settings, threads, activity, chirpWatches, chirped, lastTalkedTo, otherChats, defaultModel }
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
        // KemoSabe is always first and always standard, keeping its color and whether it chirps.
        let saved = loaded.bots.first { $0.isKemoSabe }
        loaded.bots.removeAll { $0.isKemoSabe }
        var kemoSabe = BotSpec.kemoSabe(name: kemoSabeName, tint: saved?.kemoSabeTint)
        kemoSabe.permissions.mayChirp = saved?.permissions.mayChirp ?? true
        loaded.bots.insert(kemoSabe, at: 0)
        state = loaded
    }

    // MARK: Sync

    /// The chats this dock keeps that aren't one of its conversations: chats from the owner's iPhone,
    /// kept so they sync back and forth intact.
    public var otherChats: [ChatThread] { state.otherChats }

    /// The dock's bots and every conversation, as sync sees them.
    public var library: (bots: [BotSpec], threads: [ChatThread]) {
        (state.bots, Array(state.threads.values) + state.otherChats)
    }
    /// Takes what sync brought: the bots (KemoSabe first and standard), each conversation by its chat's
    /// ID, and other devices' chats beside them. Returns the conversations that changed.
    /// `conversations` names the chat each open conversation shows (by chat ID), for ones not saved yet.
    @discardableResult public func applySynced(bots: [BotSpec], threads: [ChatThread], conversations: [UUID: UUID] = [:]) -> Set<UUID> {
        var next = state
        let kemoSabe = bots.first { $0.isKemoSabe }.map { BotSpec.kemoSabe(name: state.bots[0].name, tint: $0.kemoSabeTint) } ?? state.bots[0]
        var kept = kemoSabe
        kept.permissions.mayChirp = state.bots[0].permissions.mayChirp
        next.bots = [kept] + bots.filter { !$0.isKemoSabe }.map { $0.normalized() }
        var changed: Set<UUID> = []
        var others: [ChatThread] = []
        for thread in threads {
            if let key = next.threads.first(where: { $0.value.id == thread.id })?.key ?? conversations[thread.id] {
                if next.threads[key] != thread { next.threads[key] = thread; changed.insert(key) }
            } else {
                others.append(thread)
            }
        }
        // A conversation whose chat was deleted elsewhere starts over empty here.
        let present = Set(threads.map(\.id))
        for (key, thread) in next.threads where !present.contains(thread.id) && !thread.messages.isEmpty {
            next.threads[key] = nil
            changed.insert(key)
        }
        next.otherChats = others
        let ids = Set(next.bots.map(\.id))
        for key in Array(next.threads.keys) where key != BotDock.togetherID && !ids.contains(key) { next.threads[key] = nil; changed.insert(key) }
        guard next != state else { return [] }
        state = next
        save()
        return changed
    }

    public var bots: [BotSpec] { state.bots }
    public func bot(_ id: UUID?) -> BotSpec? { state.bots.first { $0.id == id } }

    // MARK: Bots

    /// Adds a bot at the end, with a character unlike the others when it has KemoSabe's.
    @discardableResult public func add(_ bot: BotSpec) -> Result<BotSpec, BotProblem> {
        guard !bot.isKemoSabe else { return .failure(.init("KemoSabe is already on the dock.")) }
        switch bot.validated(existing: state.bots) {
        case .failure(let problem): return .failure(problem)
        case .success(var clean):
            if state.bots.contains(where: { $0.id == clean.id }) { clean.id = UUID() }
            if clean.look == .kemoSabe { clean.look = .suggested(name: clean.name, job: clean.role, taken: state.bots.map(\.look)) }
            state.bots.append(clean)
            save()
            return .success(clean)
        }
    }
    /// Saves a bot's changes. A new engine starts on its own default model and effort. KemoSabe stays
    /// standard (its name, cloud, engine, job, and scope); only its color and whether it chirps change.
    @discardableResult public func update(_ bot: BotSpec) -> Result<BotSpec, BotProblem> {
        guard let index = state.bots.firstIndex(where: { $0.id == bot.id }) else { return .failure(.init("That bot isn’t on the dock any more.")) }
        let old = state.bots[index]
        if old.isKemoSabe {
            var kept = BotSpec.kemoSabe(name: old.name, tint: bot.look.accentColor)
            kept.permissions.mayChirp = bot.permissions.mayChirp
            state.bots[index] = kept.normalized()
            save()
            return .success(state.bots[index])
        }
        switch bot.validated(existing: state.bots) {
        case .failure(let problem): return .failure(problem)
        case .success(var clean):
            if clean.engine != old.engine { clean.model = nil; clean.effort = nil }
            state.bots[index] = clean
            save()
            return .success(clean)
        }
    }
    /// Removes a bot with its conversation, what it chirps about, and its chirp keys. KemoSabe stays.
    public func remove(_ id: UUID) {
        guard id != BotSpec.kemoSabeID, state.bots.contains(where: { $0.id == id }) else { return }
        state.bots.removeAll { $0.id == id }
        state.threads[id] = nil
        state.chirpWatches[id] = nil
        let prefix = id.uuidString + "|"
        state.chirped = state.chirped.filter { !$0.key.hasPrefix(prefix) }
        for key in state.threads.keys { state.threads[key]?.botIDs.removeAll { $0 == id } }
        if state.lastTalkedTo == id { state.lastTalkedTo = nil }
        save()
    }
    /// Moves a bot to a place on the dock (dragging a tile). KemoSabe stays first.
    public func move(_ id: UUID, to index: Int) {
        guard id != BotSpec.kemoSabeID, let from = state.bots.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(1, index), state.bots.count - 1)
        guard target != from else { return }
        let bot = state.bots.remove(at: from)
        state.bots.insert(bot, at: target)
        save()
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
    public func setThread(_ thread: ChatThread, for id: UUID) {
        var thread = thread
        if thread.messages.count > DockState.maxMessages { thread.messages.removeFirst(thread.messages.count - DockState.maxMessages) }
        guard state.threads[id] != thread else { return }
        state.threads[id] = thread
        save()
    }
    public func clearThread(_ id: UUID) {
        state.threads[id] = nil
        save()
    }
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
        guard let file else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(state).write(to: file, options: [.atomic])
            problem = nil
        } catch {
            problem = "The dock couldn’t save. Your bots and messages are kept until you quit."
        }
    }
    static var encoder: JSONEncoder { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; return encoder }
    static var decoder: JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }
}
#endif

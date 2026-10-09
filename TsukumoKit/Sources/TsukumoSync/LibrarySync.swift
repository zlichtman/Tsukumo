import CryptoKit
import Foundation
import Observation
import TsukumoCore
import TsukumoPolicy

// Conversations, bots, and the default model, in step between the owner's iPhone and Mac through their
// private iCloud database. `SyncEngine` moves labeled items and checks each against the policy; this
// file decides what those items are and how what arrives is merged:
//
// - A bot syncs whole (its look included, so it looks the same everywhere), normalized on the way out
//   and the way in, so KemoSabe is always standard on every device. KemoSabe is never deleted.
// - A chat syncs at its own level: Personal by default, Device only ("Keep on this iPhone") never.
//   KemoSabe's answer cards lose what KemoSabe shared and the stored answer's reference first (KemoSabe's
//   answers never sync). Edits merge: messages are joined by ID, so a chat added to on both devices
//   keeps everything from both.
// - Deleting a bot or a chat sends a tombstone, so it goes away on every device.
// - The default model and API connections sync without keys. Keys, KemoSabe's grants and journal, and
//   personal sources are never in the library at all.
// - The lineup (October 7, 2026): bots and chats the lineup migration retired (`LineupAliases`) are aliases, not
//   deletions. The aliases sync too (`setting:lineupAliases`, only ever growing), so every device shares the same
//   old-to-new mappings: no device sends a tombstone for a retired ID, and one arriving from a device that hasn't
//   migrated its own library yet is mapped onto what it became (a folded bot's messages onto its service bot, a
//   merged chat onto the chat it lives on in), never added back as a custom bot. The library carries a schema version
//   (`setting:schema`): a device that has ever seen a newer schema than its own remembers it in its ledger
//   (`SyncLedger.newerSchema`) and applies nothing destructive (no tombstones) until it's updated.
// - No released build has had iCloud on (every release is `TSUKUMO_CAPABILITIES = Local`), so no older shipped client
//   has ever synced: the first build that turns iCloud on is the baseline this format must stay compatible with.

/// Everything that syncs, as one device has it.
public struct SyncLibrary: Equatable, Sendable {
    public var bots: [BotSpec]
    public var threads: [ChatThread]
    public var defaultModel: DefaultModel?
    public var connections: [APIConnectionRecord]
    /// What the lineup migration retired, on this device or another (synced as `setting:lineupAliases`; it also shapes
    /// what's sent and taken).
    public var aliases: LineupAliases

    public init(bots: [BotSpec] = [], threads: [ChatThread] = [], defaultModel: DefaultModel? = nil, connections: [APIConnectionRecord] = [],
                aliases: LineupAliases = LineupAliases()) {
        self.bots = bots; self.threads = threads; self.defaultModel = defaultModel; self.connections = connections; self.aliases = aliases
    }
}

/// What this device last sent or received for each synced item, so it knows what changed and what was
/// deleted since. Saved with the app's data; it holds hashes, never content.
public struct SyncLedger: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var hash: String
        public var modified: Date
        public var deleted: Bool
    }
    public var entries: [String: Entry] = [:]
    /// This device's name in iCloud records, made once ("iPhone-…", "Mac-…").
    public var device: String
    /// The iCloud user this library first synced with.
    public var iCloudUser: String?
    /// The newest schema another device has sent, when it's newer than this build's: until this build is updated,
    /// nothing destructive (a tombstone) is applied.
    public var newerSchema: Int?

    public init(device: String) { self.device = device }
}

/// The mapping between a library and sync items, and the merge of what arrives. Pure, so both devices
/// and the tests run the same code.
public enum LibraryMapping {
    public static let defaultModelID = "setting:defaultModel"
    /// The library's schema: 2 since the lineup (retired IDs are aliases). Sent as its own setting.
    public static let schemaID = "setting:schema"
    public static let schemaVersion = 2
    /// The lineup migration's aliases, as one setting every device merges into its own.
    public static let aliasesID = "setting:lineupAliases"

    /// The items a retired ID would be sent as: never tombstoned.
    static func retiredItems(_ aliases: LineupAliases) -> Set<String> {
        Set(aliases.bots.keys.map { "bot:" + $0.uuidString } + aliases.retiredBots.map { "bot:" + $0.uuidString }
            + aliases.chats.keys.map { "thread:" + $0.uuidString })
    }

    /// The items to send: everything that changed since the ledger last saw it, and a tombstone for
    /// everything the ledger knows that's gone (or became Device only). Updates the ledger.
    public static func outbound(_ library: SyncLibrary, ledger: inout SyncLedger, now: Date) -> [SyncItem] {
        var items: [SyncItem] = []
        var present: Set<String> = []
        func consider(_ item: SyncItem) {
            present.insert(item.id)
            let hash = digest(item.payload)
            if let entry = ledger.entries[item.id], entry.hash == hash, !entry.deleted { return }
            ledger.entries[item.id] = .init(hash: hash, modified: now, deleted: false)
            items.append(SyncItem(id: item.id, type: item.type, label: item.label, modified: now, payload: item.payload))
        }
        for bot in library.bots {
            if let item = try? SyncItem.bot(bot.normalized(), modified: now) { consider(item) }
        }
        for thread in library.threads where thread.privacy.canLeaveDevice && !thread.messages.isEmpty {
            if let item = try? SyncItem.thread(redacted(thread), level: thread.privacy, modified: now) { consider(item) }
        }
        if let model = library.defaultModel, let payload = try? TsukumoJSON.encoder.encode(model) {
            consider(SyncItem(id: defaultModelID, type: .setting, label: TypeLabel(kind: "setting", level: .personal), modified: now, payload: payload))
        }
        for connection in library.connections {
            if let item = try? SyncItem.connection(connection, modified: now) { consider(item) }
        }
        if let payload = try? JSONEncoder().encode(["version": schemaVersion]) {
            consider(SyncItem(id: schemaID, type: .setting, label: TypeLabel(kind: "setting", level: .open), modified: now, payload: payload))
        }
        if !library.aliases.isEmpty, let payload = try? aliasEncoder.encode(library.aliases) {
            consider(SyncItem(id: aliasesID, type: .setting, label: TypeLabel(kind: "setting", level: .personal), modified: now, payload: payload))
        }
        let retired = retiredItems(library.aliases)
        for (id, entry) in ledger.entries.sorted(by: { $0.key < $1.key }) where !entry.deleted && !present.contains(id) {
            // KemoSabe is never deleted anywhere, and what the lineup retired is an alias, not a deletion.
            if id == "bot:" + BotSpec.kemoSabeID.uuidString || retired.contains(id) { continue }
            guard ledger.newerSchema == nil, let type = syncType(of: id) else { continue }
            ledger.entries[id] = .init(hash: entry.hash, modified: now, deleted: true)
            items.append(SyncItem(id: id, type: type, label: TypeLabel(kind: "tombstone", level: .open), modified: now, deleted: true, payload: Data()))
        }
        return items
    }

    /// The library after what arrived from other devices, and the ledger updated to match it.
    public static func merge(_ received: [SyncItem], into library: SyncLibrary, ledger: inout SyncLedger) -> SyncLibrary {
        var next = library
        // Another device's aliases first (they only grow), so this batch's items are read through all of them.
        for item in received where item.id == aliasesID && !item.deleted {
            if let theirs = try? JSONDecoder().decode(LineupAliases.self, from: item.payload) { next.aliases.add(theirs) }
        }
        let aliases = next.aliases
        let retired = retiredItems(aliases)
        // A device on a newer schema may mean something this one doesn't by a deletion: remembered in the ledger, so
        // this device takes nothing destructive from then on, until it's updated.
        for item in received where item.id == schemaID && !item.deleted {
            let version = (try? JSONDecoder().decode([String: Int].self, from: item.payload))?["version"] ?? 0
            if version > schemaVersion { ledger.newerSchema = max(ledger.newerSchema ?? 0, version) }
        }
        if let seen = ledger.newerSchema, seen <= schemaVersion { ledger.newerSchema = nil }
        let newer = ledger.newerSchema != nil
        // This device's own chats are read through them too: a chat another device merged into one it lives on in
        // joins it here as well, so the old copy never stays beside it (or comes back after the merged chat is deleted).
        // Deleted means already in the ledger, or deleted by this batch's last word on it (applied below), so an old copy
        // is never joined into a chat that's about to go.
        var deletedThreads = Set(ledger.entries.compactMap { $0.value.deleted ? uuid($0.key, "thread:") : nil })
        if !newer {
            var last: [String: SyncItem] = [:]
            for item in received where item.type == .thread && !retired.contains(item.id) {
                if let known = ledger.entries[item.id], known.modified > item.modified { continue }
                if let seen = last[item.id], seen.modified > item.modified { continue }
                last[item.id] = item
            }
            for (id, item) in last {
                guard let thread = uuid(id, "thread:") else { continue }
                if item.deleted { deletedThreads.insert(thread) } else { deletedThreads.remove(thread) }
            }
        }
        next.threads = canonical(next.threads, aliases: aliases, deleted: deletedThreads)
        for item in received.sorted(by: { $0.modified < $1.modified }) {
            if let known = ledger.entries[item.id], known.modified > item.modified { continue }
            if item.deleted && (newer || retired.contains(item.id) || item.id == aliasesID) { continue }
            ledger.entries[item.id] = .init(hash: item.deleted ? (ledger.entries[item.id]?.hash ?? "") : digest(item.payload),
                                            modified: item.modified, deleted: item.deleted)
            switch item.type {
            case .bot:
                guard let id = uuid(item.id, "bot:") else { continue }
                // A bot the lineup retired, from a device that hasn't moved yet: it already lives on as its service bot.
                if aliases.retires(bot: id) { continue }
                if item.deleted {
                    if id != BotSpec.kemoSabeID { next.bots.removeAll { $0.id == id } }
                    continue
                }
                guard var bot = try? TsukumoJSON.decoder.decode(BotSpec.self, from: item.payload), bot.id == id else { continue }
                bot = bot.normalized()
                if let index = next.bots.firstIndex(where: { $0.id == id }) { next.bots[index] = bot } else { next.bots.append(bot) }
            case .thread:
                guard let id = uuid(item.id, "thread:") else { continue }
                if item.deleted {
                    // A chat kept on this device stays.
                    next.threads.removeAll { $0.id == id && $0.privacy.canLeaveDevice }
                    continue
                }
                guard var thread = try? TsukumoJSON.decoder.decode(ChatThread.self, from: item.payload), thread.id == id else { continue }
                // A chat from a device that hasn't moved yet: its retired bots' messages go to what they became, and a
                // merged chat joins the chat it lives on in.
                thread = aliases.rewrite(thread)
                let target = thread.id
                if let index = next.threads.firstIndex(where: { $0.id == target }) {
                    guard next.threads[index].privacy.canLeaveDevice else { continue }
                    if target == id {
                        next.threads[index] = merged(local: next.threads[index], remote: thread)
                    } else {
                        // An old chat joining the one it was merged into: its messages only; the surviving chat keeps its own
                        // title, bots, and who was last spoken to (and, as every merge, the stricter privacy).
                        var joined = merged(local: next.threads[index], remote: thread)
                        joined.title = next.threads[index].title
                        joined.botIDs = next.threads[index].botIDs
                        joined.lastSpokenTo = next.threads[index].lastSpokenTo
                        next.threads[index] = joined
                    }
                } else {
                    // An old chat never recreates the chat it was merged into once that was deleted.
                    if target != id, ledger.entries["thread:" + target.uuidString]?.deleted == true { continue }
                    next.threads.append(thread)
                }
            case .setting:
                guard item.id == defaultModelID else { continue }
                next.defaultModel = item.deleted ? nil : (try? TsukumoJSON.decoder.decode(DefaultModel.self, from: item.payload)) ?? next.defaultModel
            case .connection:
                guard let id = uuid(item.id, "connection:") else { continue }
                if item.deleted { next.connections.removeAll { $0.id == id }; continue }
                guard let record = try? TsukumoJSON.decoder.decode(APIConnectionRecord.self, from: item.payload) else { continue }
                if let index = next.connections.firstIndex(where: { $0.id == id }) { next.connections[index] = record } else { next.connections.append(record) }
            case .artifact:
                continue
            }
        }
        return next
    }

    /// A device's chats read through the aliases: retired bots become what they became, and chats merged into another
    /// join it. The chat that was merged into keeps its title, bots, and who was last spoken to; every message of both
    /// stays (the surviving chat's copy of a message wins), and the joined chat is as private as the stricter of the two.
    /// A chat whose target this device already saw deleted (`deleted`) is never brought back by joining it: an old copy
    /// that may leave the device goes with it. A Device only chat is never joined at all.
    public static func canonical(_ threads: [ChatThread], aliases: LineupAliases, deleted: Set<UUID> = []) -> [ChatThread] {
        var result: [ChatThread] = []
        for original in threads {
            var thread = aliases.rewrite(original)
            // A chat that never leaves this device is never renamed or joined: another device's merge can't have meant
            // it, and it keeps its own ID whatever happens to the chat it would join. Its retired bots still map.
            if !original.privacy.canLeaveDevice {
                thread.id = original.id
                result.append(thread)
                continue
            }
            if thread.id != original.id, deleted.contains(thread.id) { continue }
            guard let index = result.firstIndex(where: { $0.id == thread.id }) else { result.append(thread); continue }
            // The survivor is the chat that already had this ID; between two old chats, the first.
            let survivorFirst = original.id != thread.id
            let survivor = survivorFirst ? result[index] : thread
            let joining = survivorFirst ? thread : result[index]
            var joined = survivor
            // Both copies are this device's, but one may have come back through sync with KemoSabe's answers redacted:
            // for each message, the copy that still holds more of its answer cards wins.
            var byID: [UUID: Message] = [:]
            for message in joining.messages { byID[message.id] = message }
            for message in survivor.messages {
                if let other = byID[message.id], answerContent(other) > answerContent(message) { continue }
                byID[message.id] = message
            }
            joined.messages = byID.values.sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date }
            joined.privacy = max(survivor.privacy, joining.privacy)
            if joined.title.isEmpty { joined.title = joining.title }
            result[index] = joined
        }
        return result
    }

    /// One chat from two devices, the newer edit (`remote`, which only merges when it's newer) giving
    /// the title, bots' order, and who was last spoken to, and every message from both: this device's
    /// copy of a message wins, so its own unredacted cards stay, and all of them in time order. Both
    /// devices come to the same chat, so a merge never bounces back and forth. Its privacy is the stricter of the two:
    /// sync only ever raises a chat's level, so a message never reaches a model its level kept it from on another
    /// device (lowering a chat's level is done on each device).
    public static func merged(local: ChatThread, remote: ChatThread) -> ChatThread {
        var thread = remote
        thread.privacy = max(local.privacy, remote.privacy)
        var byID: [UUID: Message] = [:]
        for message in remote.messages { byID[message.id] = message }
        for message in local.messages { byID[message.id] = message }
        thread.messages = byID.values.sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date }
        for id in local.botIDs where !thread.botIDs.contains(id) { thread.botIDs.append(id) }
        if thread.title.isEmpty { thread.title = local.title }
        if thread.lastSpokenTo == nil { thread.lastSpokenTo = local.lastSpokenTo }
        return thread
    }

    /// How much of KemoSabe's answers a message holds: what was shared and where the answer is, per card.
    static func answerContent(_ message: Message) -> Int {
        message.parts.reduce(0) { count, part in
            guard case .gateAnswer(let card) = part else { return count }
            return count + (card.shared == nil ? 0 : 1) + (card.answer == nil ? 0 : 1)
        }
    }

    /// A chat as it may leave this device: KemoSabe's answer cards keep who asked, the question, the
    /// outcome, and counts, but not what KemoSabe shared or where its answer is stored.
    public static func redacted(_ thread: ChatThread) -> ChatThread {
        var copy = thread
        copy.messages = thread.messages.map { message in
            var message = message
            message.parts = message.parts.map { part in
                guard case .gateAnswer(var card) = part else { return part }
                card.shared = nil
                card.answer = nil
                return .gateAnswer(card)
            }
            return message
        }
        return copy
    }

    static var aliasEncoder: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func uuid(_ id: String, _ prefix: String) -> UUID? { id.hasPrefix(prefix) ? UUID(uuidString: String(id.dropFirst(prefix.count))) : nil }
    static func syncType(of id: String) -> SyncType? {
        if id.hasPrefix("bot:") { return .bot }
        if id.hasPrefix("thread:") { return .thread }
        if id.hasPrefix("connection:") { return .connection }
        if id.hasPrefix("setting:") { return .setting }
        return nil
    }
}

// MARK: Running it

/// Whether this build may use iCloud and Sign in with Apple. Both need capabilities registered in
/// Apple's developer portal, so they're off until the owner approves that and builds with
/// `TSUKUMO_CAPABILITIES = iCloud` (apps/ios/project.yml, apps/macos/project.yml). The build writes the
/// choice into Info.plist as `TsukumoCapabilities`; without it nothing touches CloudKit.
public enum CloudCapability {
    public static let containerID = "iCloud.com.zlichtman.tsukumo"
    public static let infoKey = "TsukumoCapabilities"

    /// True only in a build made with the iCloud entitlements.
    public static func isEnabled(_ bundle: Bundle = .main) -> Bool {
        (bundle.object(forInfoDictionaryKey: infoKey) as? String)?.lowercased() == "icloud"
    }
}

/// One line for Settings, Account.
public enum CloudSyncState: Equatable, Sendable {
    /// No account: the owner continued without one, or signed out.
    case noAccount
    /// This build doesn't carry the iCloud capability yet (waiting on the developer portal).
    case waitingForCapability
    /// Signed in to Tsukumo, but not to iCloud on this device.
    case iCloudSignedOut
    case syncing
    case upToDate(Date)
    case failed(String)

    public var title: String {
        switch self {
        case .noAccount: "Off: no account"
        case .waitingForCapability: "Waiting for iCloud to be turned on for Tsukumo"
        case .iCloudSignedOut: "Off: sign in to iCloud in Settings"
        case .syncing: "Syncing with iCloud"
        case .upToDate: "Syncing with iCloud"
        case .failed: "Sync paused"
        }
    }
    public var detail: String {
        switch self {
        case .noAccount: "Sign in with Apple to keep your bots and chats in step on your iPhone and Mac."
        case .waitingForCapability: "Your bots and chats stay on this device until this build of Tsukumo can use iCloud."
        case .iCloudSignedOut: "Sign in to iCloud on this device, then come back."
        case .syncing: "Bringing your bots and chats up to date."
        case .upToDate: "Your bots and chats are up to date here."
        case .failed(let reason): reason
        }
    }
    /// The account page's pill: "Syncing with iCloud", "Waiting for iCloud", "Paused", "Off".
    public var short: String {
        switch self {
        case .noAccount, .iCloudSignedOut: "Off"
        case .waitingForCapability: "Waiting for iCloud"
        case .syncing, .upToDate: "Syncing with iCloud"
        case .failed: "Paused"
        }
    }
    /// When it last finished.
    public var lastSynced: Date? { if case .upToDate(let date) = self { date } else { nil } }
    /// Waiting on something outside Tsukumo (the capability, or iCloud on this device).
    public var isWaiting: Bool { self == .waitingForCapability || self == .iCloudSignedOut }
    public var isOn: Bool {
        switch self {
        case .syncing, .upToDate: true
        default: false
        }
    }
}

/// Runs sync for one app: what its library is, how to apply what arrives, and the status line.
@MainActor @Observable public final class LibrarySyncController {
    public private(set) var state: CloudSyncState
    @ObservationIgnored private let database: (any CloudDatabase)?
    @ObservationIgnored private let ledgerURL: URL?
    @ObservationIgnored private var ledger: SyncLedger
    @ObservationIgnored private var engine: SyncEngine?
    @ObservationIgnored private let read: @MainActor () -> SyncLibrary
    @ObservationIgnored private let apply: @MainActor (SyncLibrary) -> Void
    @ObservationIgnored private var running = false
    @ObservationIgnored private var again = false
    @ObservationIgnored private var pending: Task<Void, Never>?
    /// The host pauses sync until its persisted library has recovered.
    @ObservationIgnored public var canSync: @MainActor () -> Bool = { true }
    @ObservationIgnored public var clock: () -> Date = Date.init
    @ObservationIgnored public static let zone = "Tsukumo"

    /// `database` nil means this build can't use iCloud (`CloudCapability`); `signedIn` false means the
    /// owner has no account. `devicePrefix` names this device's records ("iPhone", "Mac").
    public init(database: (any CloudDatabase)?, signedIn: Bool, ledgerURL: URL?, devicePrefix: String,
                read: @escaping @MainActor () -> SyncLibrary, apply: @escaping @MainActor (SyncLibrary) -> Void) {
        self.database = database; self.ledgerURL = ledgerURL; self.read = read; self.apply = apply
        ledger = ledgerURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? TsukumoJSON.decoder.decode(SyncLedger.self, from: $0) }
            ?? SyncLedger(device: devicePrefix + "-" + UUID().uuidString.prefix(8))
        state = !signedIn ? .noAccount : database == nil ? .waitingForCapability : .syncing
    }

    /// Signs in or out of sync (the owner's Tsukumo account, not iCloud's).
    public func setSignedIn(_ signedIn: Bool) {
        if !signedIn { pending?.cancel(); engine = nil; state = .noAccount; return }
        state = database == nil ? .waitingForCapability : .syncing
        if database != nil { syncSoon(after: 0) }
    }

    /// Something local changed: sync shortly (changes close together go in one sync).
    public func localChanged() { syncSoon(after: 1.5) }

    public func syncSoon(after seconds: Double) {
        guard database != nil, state != .noAccount else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            if seconds > 0 { try? await Task.sleep(for: .seconds(seconds)) }
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    /// Pushes what changed here, pulls what changed elsewhere, and applies it.
    public func syncNow() async {
        guard canSync(), let database, state != .noAccount else { return }
        if running { again = true; return }
        running = true
        defer { running = false }
        var rounds = 0
        repeat {
            again = false
            rounds += 1
            state = .syncing
            let engine = self.engine ?? SyncEngine(database: database, zone: Self.zone, device: ledger.device, boundUser: ledger.iCloudUser, clock: { Date() })
            self.engine = engine
            var ledger = self.ledger
            for item in LibraryMapping.outbound(read(), ledger: &ledger, now: clock()) { await engine.stage(item) }
            do {
                let report = try await engine.sync()
                ledger.iCloudUser = await engine.iCloudUser
                let local = read()
                let merged = LibraryMapping.merge(report.received, into: local, ledger: &ledger)
                if merged != local {
                    apply(merged)
                    // A merge that joined this device's messages with another's goes back up at once, so
                    // both devices end with the same chat (it settles: the next merge adds nothing).
                    var probe = ledger
                    if !LibraryMapping.outbound(merged, ledger: &probe, now: clock()).isEmpty && rounds < 3 { again = true }
                }
                self.ledger = ledger
                save()
                state = .upToDate(clock())
            } catch SyncError.iCloudUnavailable {
                state = .iCloudSignedOut
            } catch SyncError.resetRequired {
                // The zone is gone (iCloud data deleted): everything goes up again next time.
                self.ledger.entries = [:]
                save()
                state = .failed("Sync is starting over with iCloud.")
            } catch let error as SyncError {
                state = .failed(SyncStatus.failed(error).text)
            } catch {
                state = .failed("Couldn’t reach iCloud. Sync will try again.")
            }
        } while again && canSync()
    }

    private func save() {
        guard let ledgerURL, let data = try? TsukumoJSON.encoder.encode(ledger) else { return }
        try? data.write(to: ledgerURL, options: [.atomic])
    }
}

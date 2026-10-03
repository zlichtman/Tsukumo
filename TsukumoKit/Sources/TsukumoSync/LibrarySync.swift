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

/// Everything that syncs, as one device has it.
public struct SyncLibrary: Equatable, Sendable {
    public var bots: [BotSpec]
    public var threads: [ChatThread]
    public var defaultModel: DefaultModel?
    public var connections: [APIConnectionRecord]

    public init(bots: [BotSpec] = [], threads: [ChatThread] = [], defaultModel: DefaultModel? = nil, connections: [APIConnectionRecord] = []) {
        self.bots = bots; self.threads = threads; self.defaultModel = defaultModel; self.connections = connections
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

    public init(device: String) { self.device = device }
}

/// The mapping between a library and sync items, and the merge of what arrives. Pure, so both devices
/// and the tests run the same code.
public enum LibraryMapping {
    public static let defaultModelID = "setting:defaultModel"

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
        for (id, entry) in ledger.entries.sorted(by: { $0.key < $1.key }) where !entry.deleted && !present.contains(id) {
            // KemoSabe is never deleted anywhere.
            if id == "bot:" + BotSpec.kemoSabeID.uuidString { continue }
            guard let type = syncType(of: id) else { continue }
            ledger.entries[id] = .init(hash: entry.hash, modified: now, deleted: true)
            items.append(SyncItem(id: id, type: type, label: TypeLabel(kind: "tombstone", level: .open), modified: now, deleted: true, payload: Data()))
        }
        return items
    }

    /// The library after what arrived from other devices, and the ledger updated to match it.
    public static func merge(_ received: [SyncItem], into library: SyncLibrary, ledger: inout SyncLedger) -> SyncLibrary {
        var next = library
        for item in received.sorted(by: { $0.modified < $1.modified }) {
            if let known = ledger.entries[item.id], known.modified > item.modified { continue }
            ledger.entries[item.id] = .init(hash: item.deleted ? (ledger.entries[item.id]?.hash ?? "") : digest(item.payload),
                                            modified: item.modified, deleted: item.deleted)
            switch item.type {
            case .bot:
                guard let id = uuid(item.id, "bot:") else { continue }
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
                guard let thread = try? TsukumoJSON.decoder.decode(ChatThread.self, from: item.payload), thread.id == id else { continue }
                if let index = next.threads.firstIndex(where: { $0.id == id }) {
                    guard next.threads[index].privacy.canLeaveDevice else { continue }
                    next.threads[index] = merged(local: next.threads[index], remote: thread)
                } else {
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

    /// One chat from two devices, the newer edit (`remote`, which only merges when it's newer) giving
    /// the title, bots' order, and who was last spoken to, and every message from both: this device's
    /// copy of a message wins, so its own unredacted cards stay, and all of them in time order. Both
    /// devices come to the same chat, so a merge never bounces back and forth.
    public static func merged(local: ChatThread, remote: ChatThread) -> ChatThread {
        var thread = remote
        thread.privacy = local.privacy
        var byID: [UUID: Message] = [:]
        for message in remote.messages { byID[message.id] = message }
        for message in local.messages { byID[message.id] = message }
        thread.messages = byID.values.sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date }
        for id in local.botIDs where !thread.botIDs.contains(id) { thread.botIDs.append(id) }
        if thread.title.isEmpty { thread.title = local.title }
        if thread.lastSpokenTo == nil { thread.lastSpokenTo = local.lastSpokenTo }
        return thread
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
        case .upToDate(let date): "Up to date as of " + date.formatted(date: .omitted, time: .shortened) + ". Keys, KemoSabe’s answers, and chats kept on this device never sync."
        case .failed(let reason): reason
        }
    }
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
        guard let database, state != .noAccount else { return }
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
        } while again
    }

    private func save() {
        guard let ledgerURL, let data = try? TsukumoJSON.encoder.encode(ledger) else { return }
        try? data.write(to: ledgerURL, options: [.atomic])
    }
}

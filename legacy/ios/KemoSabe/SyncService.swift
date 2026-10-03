import CryptoKit
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers
#if canImport(CloudKit)
import CloudKit
#endif

// MARK: Stores and the synced copy

/// One value a store holds, as it syncs.
struct SyncItem: Equatable {
    var type: String
    var payload: Data
}

/// A store that syncs: it says what it holds now and takes in other devices' values. The store's
/// own files stay the source of truth on the device; the engine only keeps the synced copy.
@MainActor protocol SyncAdapter: AnyObject {
    /// The record types this store owns in the personal zone.
    var types: Set<String> { get }
    /// Everything the store holds now, by record ID; nil while the store isn't open or couldn't be
    /// read, so nothing is compared (and nothing looks deleted) until it is.
    func snapshot() -> [String: SyncItem]?
    /// Takes in other devices' values (nil removes one). Returns the IDs it took in; the rest are
    /// tried again at the next sync.
    func apply(_ changes: [String: SyncItem?]) -> Set<String>
}

enum SyncDigest {
    /// A digest of a payload. Small JSON payloads are compared by content (key order and formatting
    /// don't matter); large ones by their bytes, which the engine's encoder keeps stable.
    static func of(_ payload: Data) -> String {
        var bytes = payload
        if payload.count <= 65_536, let object = try? JSONSerialization.jsonObject(with: payload, options: [.fragmentsAllowed]),
           let canonical = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]) {
            bytes = canonical
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

struct ReconcileResult: Equatable {
    var sent = 0
    var received = 0
}

extension SyncEngine {
    /// Brings one store and the synced copy together, record by record, with three values: what the
    /// store holds (S), the synced copy (E), and what they both held the last time they matched (L).
    ///
    /// - Only the store changed (S ≠ L, E = L): the store's value (or its deletion) is queued.
    /// - Only the synced copy changed (E ≠ L, S = L): another device's value (or deletion) goes into the store.
    /// - Both changed, and they never matched before (L unknown, as when a device first joins): the
    ///   account's copy wins, so a new device never overwrites what the account already has.
    /// - Both changed since they last matched: an edit beats a deletion; two edits keep this device's,
    ///   the later one.
    ///
    /// A store that isn't open returns no snapshot and is left alone, so a locked or unreadable
    /// store never looks like everything was deleted.
    @discardableResult
    func reconcile(_ adapter: SyncAdapter, at date: Date = Date()) throws -> ReconcileResult {
        guard let local = adapter.snapshot() else { return .init() }
        let prefix = SyncZone.personal.name + "/"
        var synced: [String: SyncRecord] = [:]
        for record in state.records.values where record.zone == .personal && adapter.types.contains(record.type) { synced[record.id] = record }
        var result = ReconcileResult()
        var incoming: [String: SyncItem?] = [:], incomingDigests: [String: String?] = [:]
        try batch {
            for id in Set(local.keys).union(synced.keys).sorted() {
                let key = prefix + id
                let item = local[id].flatMap { adapter.types.contains($0.type) ? $0 : nil }
                let live = synced[id].flatMap { $0.deleted ? nil : $0 }
                let s = item.map { SyncDigest.of($0.payload) }, e = live.map { SyncDigest.of($0.payload) }, l = base(key)
                if s == e { setBase(s, for: key); continue }
                let localChanged = s != l, remoteChanged = e != l
                let keepLocal: Bool
                switch (localChanged, remoteChanged) {
                case (true, false): keepLocal = true
                case (false, true): keepLocal = false
                default: keepLocal = l == nil ? e == nil : (e == nil || s != nil)
                }
                if keepLocal {
                    if let item { try putPayload(item.payload, id: id, type: item.type, zone: .personal, at: date) }
                    else if let type = synced[id]?.type { try delete(id: id, type: type, zone: .personal, at: date) }
                    setBase(s, for: key)
                    result.sent += 1
                } else {
                    incoming.updateValue(live.map { SyncItem(type: $0.type, payload: $0.payload) }, forKey: id)
                    incomingDigests.updateValue(e, forKey: id)
                }
            }
        }
        guard !incoming.isEmpty else { return result }
        let applied = adapter.apply(incoming)
        for id in applied { if let digest = incomingDigests[id] { setBase(digest, for: prefix + id) } }
        result.received = applied.count
        try persistNow()
        return result
    }
}

// MARK: The account's sync

/// Keeps this device's account in step with the person's other devices through their private
/// iCloud database: on launch, when the app comes forward, every few minutes while it's in front,
/// a few seconds after a local change, and when iCloud says something changed (a silent push on
/// iPhone). Only an Apple account syncs; a local account stays on the device.
@MainActor @Observable final class AccountSyncService {
    static let shared = AccountSyncService()

    /// Whether this build carries the iCloud entitlement (the `KemoICloudSync` Info.plist switch,
    /// set from the `KEMO_ICLOUD_SYNC` build setting). Without it the app never touches CloudKit.
    nonisolated static var availableInBuild: Bool {
        let value = Bundle.main.object(forInfoDictionaryKey: "KemoICloudSync")
        return (value as? Bool) == true || (value as? String)?.uppercased() == "YES"
    }
    /// The transport for an Apple account: CloudKit when this build syncs, otherwise one that
    /// carries nothing and says so.
    nonisolated static func transport(for account: AccountIdentity, folder: URL) -> SyncTransport {
        // A Mac without iCloud syncs with its paired iPhone, whatever kind of account it has here.
        if MacRelaySync.usesRelay, !AccountDirectory.isTestHost {
            return RelaySyncTransport { MacRelaySync.macLink?() ?? .failure(.unavailable(MacRelaySync.notPaired)) }
        }
        guard availableInBuild, account.kind == .apple, !AccountDirectory.isTestHost else { return UnavailableSyncTransport() }
        #if os(iOS)
        let subscribes = true
        #else
        let subscribes = false
        #endif
        return CloudKitSyncTransport(database: CKCloudDatabase(), accountID: account.id,
                                     bindingURL: folder.appendingPathComponent("icloud.json"), subscribes: subscribes)
    }
    /// This device's switch for syncing (a device setting: turning it off on one device leaves the
    /// others syncing).
    static let enabledKey = "kemo.sync.enabled"

    enum Phase: Equatable {
        /// Sync can't run here: this build, or a local account.
        case unavailable(String)
        /// A Mac syncing through its iPhone, which isn't connected now (not a problem: it syncs when it is).
        case waiting(String)
        case off
        case idle
        case syncing
        case failed(String)
        /// The device's iCloud account isn't the one this account synced with; paused until the
        /// person chooses.
        case mismatch
    }
    private(set) var phase: Phase = .idle
    private(set) var lastSynced: Date?
    /// What the last sync did, in a few words.
    private(set) var lastResult: String?

    @ObservationIgnored private let records: @MainActor () -> AccountRecords
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let available: Bool
    @ObservationIgnored private var adapters: [SyncAdapter] = []
    @ObservationIgnored private var running = false
    /// Changes when the account does, so a sync still finishing for the old account reports nothing.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var again = false
    @ObservationIgnored private var reconciling = false
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var periodic: Task<Void, Never>?
    @ObservationIgnored private var accountObserver: NSObjectProtocol?
    @ObservationIgnored private var settingsObserver: NSObjectProtocol?
    /// How long after a local change the sync waits, so a burst of edits goes in one sync.
    @ObservationIgnored var debounceDelay: Duration = .seconds(3)
    /// Called after each sync that finished (the iPhone turns new device notices into notifications).
    @ObservationIgnored var onSynced: (@MainActor () -> Void)?
    static let interval: Duration = .seconds(300)

    init(records: @escaping @MainActor () -> AccountRecords = { AccountRecords.shared }, defaults: UserDefaults = AccountDirectory.settings,
         available: Bool = AccountSyncService.availableInBuild || MacRelaySync.usesRelay) {
        self.records = records; self.defaults = defaults; self.available = available
        lastSynced = records().engine?.state.lastSynced
        refreshPhase()
        #if canImport(CloudKit)
        if Self.availableInBuild, available, !AccountDirectory.isTestHost {
            accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.iCloudAccountChanged() }
            }
        }
        #endif
    }

    var engine: SyncEngine? { records().engine }
    var enabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Self.enabledKey)
            refreshPhase()
            if newValue { syncSoon(after: .zero) } else { debounce?.cancel(); periodic?.cancel() }
        }
    }
    /// Whether this device can sync at all (the build syncs, and the account is an Apple account; or a
    /// Mac without iCloud, through its paired iPhone).
    var canSync: Bool { available && engine != nil }
    /// This device syncs through its paired iPhone rather than iCloud (`MacRelaySync`).
    var usesRelay: Bool { engine?.transport is RelaySyncTransport }
    /// Called when something changed here or arrived from iCloud; the iPhone tells a Mac that syncs
    /// through it (`syncChanged`).
    @ObservationIgnored var onChanged: (@MainActor () -> Void)?

    /// The stores to keep in step, set by the app once they're open (and again after an account switch).
    func attach(_ adapters: [SyncAdapter], startSync: Bool = true) {
        self.adapters = adapters
        engine?.onLocalChange = { [weak self] in self?.localChanged() }
        lastSynced = engine?.state.lastSynced
        refreshPhase()
        if startSync { syncSoon(after: .seconds(1)) }
    }
    /// Attaches the app's store, the account, and the person's settings (plus any platform stores,
    /// such as the iPhone's profile), and syncs after each save.
    func attach(store: AppStore, account: AccountStore? = nil, extra: [SyncAdapter] = []) {
        store.onSaved = { [weak self] in self?.localChanged() }
        attach([AppStoreSyncAdapter(store: store), AccountSyncAdapter(account: account ?? .shared), AccountSettingsAdapter()] + extra)
    }
    /// The account changed while the app runs: stop, and wait for the app to attach the new stores.
    func reopen() {
        debounce?.cancel(); periodic?.cancel()
        adapters = []; again = false; running = false; generation += 1
        lastSynced = engine?.state.lastSynced; lastResult = nil
        phase = .idle
        refreshPhase()
    }
    private func refreshPhase() {
        if !available { phase = .unavailable("This version doesn't sync yet. Your data stays on this \(AppleAccountSession.device).") }
        else if engine == nil { phase = .unavailable("Sign in with Apple to sync your account between your devices.") }
        else if !enabled { phase = .off }
        else if case .unavailable = phase { phase = .idle }
        else if phase == .off { phase = .idle }
    }

    // MARK: When to sync

    /// A store saved a change: sync a few seconds later, once the burst of edits settles.
    func localChanged() {
        guard !reconciling else { return }
        syncSoon(after: debounceDelay)
        onChanged?()
    }
    /// Brings every store and the synced copy together now, without sending anything (the relay's hub
    /// does this before it answers a Mac, and after it takes in the Mac's records).
    func reconcileNow() throws {
        guard canSync, enabled, let engine, !reconciling else { return }
        _ = try reconcileAll(engine)
    }
    func syncSoon(after delay: Duration) {
        guard canSync, enabled else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }
    /// The app came forward or went away. While it's in front, sync runs now and every few minutes.
    func setActive(_ active: Bool) {
        periodic?.cancel()
        guard active, canSync, enabled else { return }
        syncSoon(after: .zero)
        periodic = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval)
                guard !Task.isCancelled else { return }
                await self?.syncNow()
            }
        }
    }
    /// iCloud said the account's zone changed (a silent push).
    func remoteChanged() async { await syncNow() }
    private func iCloudAccountChanged() {
        guard let transport = engine?.transport as? CloudKitSyncTransport else { return }
        if phase == .mismatch { phase = .idle }
        Task { await transport.accountChanged(); syncSoon(after: .seconds(1)) }
    }

    // MARK: Syncing

    /// Syncs now: takes in what the account already has (the first time), sends this device's
    /// changes, and brings in everyone else's. One sync runs at a time; a request during one runs
    /// once more after it.
    func syncNow() async {
        guard canSync, enabled, let engine else { refreshPhase(); return }
        if phase == .mismatch { return }
        if running { again = true; return }
        running = true; phase = .syncing
        let started = generation
        defer { if generation == started { running = false } }
        repeat {
            again = false
            do {
                var result = ReconcileResult()
                if engine.state.joined != true {
                    try await engine.pull()
                    try engine.markJoined()
                }
                result = add(result, try reconcileAll(engine))
                try await engine.sync()
                result = add(result, try reconcileAll(engine))
                // What the stores took in may need sending on (for example a join's own records).
                if engine.state.outbox.values.contains(where: { engine.transport.supports($0.zone) }) {
                    try await engine.sync()
                    result = add(result, try reconcileAll(engine))
                }
                guard generation == started else { return }
                lastSynced = engine.state.lastSynced
                lastResult = Self.describe(result)
                phase = .idle
                onSynced?()
                if result.received > 0 { onChanged?() }
            } catch let error as SyncError {
                guard generation == started else { return }
                if usesRelay, case .unavailable(let message) = error { phase = .waiting(message); again = false; return }
                phase = error == .iCloudAccountMismatch ? .mismatch : .failed(Self.message(error))
                again = false
            } catch {
                guard generation == started else { return }
                phase = .failed(error is AccountDirectory.WriteRefused ? "Your account is changing. Sync will continue after." : "Sync didn't finish. It will try again.")
                again = false
            }
        } while again && generation == started
    }
    private func reconcileAll(_ engine: SyncEngine) throws -> ReconcileResult {
        reconciling = true
        defer { reconciling = false }
        var total = ReconcileResult()
        for adapter in adapters { total = add(total, try engine.reconcile(adapter)) }
        return total
    }
    private func add(_ a: ReconcileResult, _ b: ReconcileResult) -> ReconcileResult { .init(sent: a.sent + b.sent, received: a.received + b.received) }

    /// The person chose to sync with the iCloud account now on this device: forget the old binding,
    /// send everything again, and take in whatever that account already has.
    func useThisICloudAccount() async {
        guard let engine, let transport = engine.transport as? CloudKitSyncTransport else { return }
        do {
            try await transport.forgetBinding()
            engine.requeueAll()
            try engine.rejoin()
            phase = .idle
        } catch { phase = .failed("That didn't work. Try again."); return }
        await syncNow()
    }

    // MARK: Words

    static func describe(_ result: ReconcileResult) -> String? {
        switch (result.sent, result.received) {
        case (0, 0): nil
        case (let sent, 0): "Sent \(sent) \(sent == 1 ? "change" : "changes")."
        case (0, let received): "Received \(received) \(received == 1 ? "change" : "changes")."
        case (let sent, let received): "Sent \(sent), received \(received)."
        }
    }
    static func message(_ error: SyncError) -> String {
        switch error {
        case .network(let message): message
        case .quotaExceeded: "Your iCloud storage is full, so sync is paused. Free up space in Settings → Apple Account → iCloud."
        case .iCloudUnavailable(let message): message
        case .iCloudAccountMismatch: mismatchNote
        case .resetRequired: "Your synced data was removed from iCloud. Everything on this \(AppleAccountSession.device) will be sent again."
        case .stateUnreadable: "Sync resumes once this \(AppleAccountSession.device) is unlocked."
        case .unavailable(let message): message
        case .privateInSharedZone, .notShareable: "Something couldn't be synced."
        }
    }
    static var mismatchNote: String {
        "This \(AppleAccountSession.device) is signed in to a different iCloud account than the one your account synced with before, so sync is paused and nothing was mixed."
    }
    /// What the Account page says goes where.
    static let destinationNote = "Sync uses your private iCloud database, under your Apple Account. It isn't a KemoSabe server, and nobody else can read it. With Advanced Data Protection on, it's end-to-end encrypted."
    static let syncedList = "Your account and companion, your profile's text, picture, and cover, conversations and chat projects, memories, Library drafts, docs and journal (with their photos), People, characters and palettes, model connections (without their keys), your default model, your companion's voice and pace, and whether Laya decides."
    static let notSyncedList = "API keys, what each connection may read, downloaded models, Laya's training and marks, your recorded voice, Messages excerpts, your profile's posts and songs, Day routines and their approvals, and appearance stay on each device."
    /// The Sync row's name: iCloud, or the paired iPhone on a Mac without iCloud.
    var title: String { usesRelay ? "Sync with your iPhone" : "iCloud Sync" }
    var statusTitle: String {
        switch phase {
        case .waiting: "Waiting for your iPhone"
        case .unavailable: "Not syncing"
        case .off: "Off on this \(AppleAccountSession.device)"
        case .syncing: "Syncing…"
        case .failed: "Needs attention"
        case .mismatch: "Paused"
        case .idle: lastSynced == nil ? "Not synced yet" : "Up to date"
        }
    }
    /// Something the person should read: sync failed or is paused.
    var hasProblem: Bool {
        switch phase { case .failed, .mismatch: true; default: false }
    }
    var statusDetail: String? {
        switch phase {
        case .unavailable(let reason), .waiting(let reason): reason
        case .off: "Changes on this \(AppleAccountSession.device) stay here until you turn sync back on."
        case .failed(let message): message
        case .mismatch: Self.mismatchNote
        case .syncing, .idle:
            lastSynced.map { "Last synced " + $0.formatted(.relative(presentation: .named)) + "." }
        }
    }
}

// MARK: Account, companion, and settings

/// The account record (name and handle, never the email) and the companion (name, personality,
/// palette), under the IDs `AccountRecords` already uses.
@MainActor final class AccountSyncAdapter: SyncAdapter {
    let account: AccountStore
    init(account: AccountStore) { self.account = account }
    let types: Set<String> = [SyncType.account, SyncType.companion]
    func snapshot() -> [String: SyncItem]? {
        guard account.syncable, let values = account.syncedValues,
              let person = try? SyncEngine.encode(values.account), let companion = try? SyncEngine.encode(values.companion) else { return nil }
        return [AccountRecords.accountID: .init(type: SyncType.account, payload: person),
                AccountRecords.companionID: .init(type: SyncType.companion, payload: companion)]
    }
    func apply(_ changes: [String: SyncItem?]) -> Set<String> {
        var applied = Set<String>()
        for (id, item) in changes {
            // The account and companion are never removed by another device.
            guard let item else { applied.insert(id); continue }
            switch item.type {
            case SyncType.account:
                if let value = try? JSONDecoder().decode(AccountRecords.Account.self, from: item.payload), account.applySynced(value) { applied.insert(id) }
            case SyncType.companion:
                // The watch follows through `CompanionIdentity.changed`.
                if let value = try? JSONDecoder().decode(AccountRecords.Companion.self, from: item.payload), account.applySynced(value) { applied.insert(id) }
            default: break
            }
        }
        return applied
    }
}

/// The person's own settings that aren't in another record: that the companion has been named, the
/// characters they made, which voice the companion sounds like (`VoicePersona`), and whether Laya
/// decides ("Use Laya", `SystemOneSettings`). The companion's name and personality travel in its
/// record; appearance, windows, and developer switches stay per device.
@MainActor final class AccountSettingsAdapter: SyncAdapter {
    static let keys = [CompanionIdentity.namedKey, CompanionCharacters.key, VoicePersona.key, SystemOneSettings.layaKey]
    /// Posted after another device's settings were taken in, so the views and stores that read them follow.
    static let didApply = Notification.Name("kemo.sync.accountSettingsApplied")
    let defaults: () -> UserDefaults
    /// The account the settings were opened for; nothing is read or written once it's no longer open.
    let accountID: String?
    init(defaults: @escaping () -> UserDefaults = { AccountDirectory.accountSettings }, accountID: String? = AccountDirectory.current().id) {
        self.defaults = defaults; self.accountID = accountID
    }
    let types: Set<String> = [SyncType.setting]
    static func id(for key: String) -> String { "setting-" + key }
    func snapshot() -> [String: SyncItem]? {
        guard accountID.map({ AccountDirectory.permitsSettingsWrite(for: $0) }) ?? true else { return nil }
        let defaults = defaults()
        var items: [String: SyncItem] = [:]
        for key in Self.keys {
            guard let value = defaults.object(forKey: key),
                  let payload = try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0) else { continue }
            items[Self.id(for: key)] = .init(type: SyncType.setting, payload: payload)
        }
        return items
    }
    func apply(_ changes: [String: SyncItem?]) -> Set<String> {
        guard accountID.map({ AccountDirectory.permitsSettingsWrite(for: $0) }) ?? true else { return [] }
        let defaults = defaults()
        var applied = Set<String>()
        for (id, item) in changes {
            guard let key = Self.keys.first(where: { Self.id(for: $0) == id }) else { continue }
            if let item {
                guard let value = try? PropertyListSerialization.propertyList(from: item.payload, format: nil) else { continue }
                defaults.set(value, forKey: key)
            } else { defaults.removeObject(forKey: key) }
            applied.insert(id)
        }
        if !applied.isEmpty { NotificationCenter.default.post(name: Self.didApply, object: nil) }
        return applied
    }
}

// MARK: Profile picture and cover

/// Your profile picture and cover as records in the personal zone, one each, so every device shows
/// the same ones: the iPhone's profile (`ProfileStore`) and the Mac's account photo (`AccountStore`)
/// are the same picture. The payload is the JPEG itself, at most `pictureSide` or `coverSide` pixels
/// (the CloudKit transport moves a payload too large for a record field as its asset, as it does for
/// Docs images). Having no picture means having no record, so a picture removed on one device becomes
/// a tombstone and is removed on the others (`SyncEngine.reconcile`); the newer change wins, as for
/// every record. Both types are personal-only, so they can never enter a shared project or a profile
/// share (`SyncType.personalOnly`); what people you share your profile with see is a separate copy.
@MainActor final class ProfileImageSyncAdapter: SyncAdapter {
    static let pictureID = "profile-picture", coverID = "profile-cover"
    /// The largest synced picture and cover, on the longer side.
    static let pictureSide = 600, coverSide = 1600
    /// The largest image taken in from another device.
    static let maxBytes = 8_000_000
    /// One image a store holds.
    struct Slot {
        var id: String
        var type: String
        var maxSide: Int
        /// The image file's bytes now: `.some(nil)` when there's no image, nil when it can't be read
        /// now (a locked device), so nothing looks removed.
        var read: @MainActor () -> Data??
        /// Takes another device's image as it came (nil removes it); returns whether it was taken in.
        var write: @MainActor (Data?) -> Bool
    }
    let slots: [Slot]
    let isOpen: @MainActor () -> Bool
    /// The last payload made from each slot's file, so an image larger than the limit (from before
    /// the limit) is downscaled once rather than at every sync.
    private var prepared: [String: (source: Data, payload: Data)] = [:]
    init(slots: [Slot], isOpen: @escaping @MainActor () -> Bool) { self.slots = slots; self.isOpen = isOpen }

    var types: Set<String> { Set(slots.map(\.type)) }
    func snapshot() -> [String: SyncItem]? {
        guard isOpen() else { return nil }
        var items: [String: SyncItem] = [:]
        for slot in slots {
            guard let data = slot.read() else { return nil }
            guard let data else { prepared[slot.id] = nil; continue }
            // An image that can't be read as one leaves the snapshot incomplete rather than removed.
            guard let payload = payload(data, for: slot) else { return nil }
            items[slot.id] = .init(type: slot.type, payload: payload)
        }
        return items
    }
    private func payload(_ data: Data, for slot: Slot) -> Data? {
        if let cached = prepared[slot.id], cached.source == data { return cached.payload }
        guard let payload = ProfileImageSync.downscaled(data, maxSide: slot.maxSide) else { return nil }
        prepared[slot.id] = (data, payload)
        return payload
    }
    func apply(_ changes: [String: SyncItem?]) -> Set<String> {
        var applied = Set<String>()
        for (id, item) in changes {
            guard let slot = slots.first(where: { $0.id == id }) else { continue }
            if let item {
                guard item.type == slot.type, item.payload.count <= Self.maxBytes, ProfileImageSync.isImage(item.payload) else { continue }
                if slot.write(item.payload) { applied.insert(id) }
            } else if slot.write(nil) { applied.insert(id) }
        }
        return applied
    }
}

enum ProfileImageSync {
    /// The image as a JPEG at most `maxSide` pixels on its longer side. A JPEG already within that is
    /// kept byte for byte, so an image that arrived from another device reads back exactly as it came
    /// and is never sent back re-encoded.
    nonisolated static func downscaled(_ data: Data, maxSide: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) >= 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0, height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        if (CGImageSourceGetType(source) as String?) == UTType.jpeg.identifier, width > 0, height > 0, max(width, height) <= maxSide, orientation == 1 {
            return data
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxSide] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
    /// Whether the data is an image this device can read.
    nonisolated static func isImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) >= 1, let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return false }
        return (properties[kCGImagePropertyPixelWidth] as? Int ?? 0) > 0
    }
}

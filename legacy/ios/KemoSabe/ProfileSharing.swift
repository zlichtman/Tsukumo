import CloudKit
import Foundation
import Observation
import UIKit

// Sharing your profile through iCloud (September 27, 2026). Each person you share with gets their
// own custom zone in your private iCloud database (`profile-<person>`), holding a projection of
// your profile with only what they may see (`ProfileProjection`), every field encrypted, images as
// assets. A zone-wide `CKShare` makes the zone readable by that one person: read-only, no public
// access, no access requests. You send the invitation yourself (Messages, Mail) with the share's
// link; they tap it and KemoSabe accepts it (`SharedProfilesStore`). Records are the existing
// `SyncRecord` type and the share is CloudKit's own `cloudkit.share`; see
// design/ACCOUNTS-AND-PROFILES.md for why that needs no new record type.

// MARK: The cloud, behind a protocol

/// Where one person stands with the share you made for them.
enum ShareStatus: String, Codable, Sendable {
    case pending, accepted
    /// They removed your profile, or the share no longer lists them.
    case left
    /// Their email or phone number isn't an iCloud account.
    case noAccount
}
struct ShareInvite: Equatable, Sendable {
    var url: URL?
    var status: ShareStatus
}
/// A zone someone shared with you, as your shared database names it.
struct SharedZoneID: Codable, Hashable, Sendable {
    var zone: String
    var owner: String
    /// A folder-safe key for this zone on this device.
    var key: String {
        String((owner + "-" + zone).map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }.prefix(120))
    }
}
/// An invitation someone opened on this device: CloudKit's metadata, or a stand-in in tests.
struct ShareAcceptance: @unchecked Sendable {
    let zone: SharedZoneID
    let metadata: CKShare.Metadata?
    init(zone: SharedZoneID, metadata: CKShare.Metadata? = nil) { self.zone = zone; self.metadata = metadata }
    init(metadata: CKShare.Metadata) {
        let id = metadata.share.recordID.zoneID
        self.init(zone: SharedZoneID(zone: id.zoneName, owner: id.ownerName), metadata: metadata)
    }
    /// Only zone-wide shares of a profile zone are KemoSabe profiles.
    var isProfile: Bool { zone.zone.hasPrefix("profile-") }
}

/// What profile sharing needs from iCloud. `CKShareDatabase` is CloudKit; tests use a fake.
protocol CloudShareDatabase: Sendable {
    func accountStatus() async throws -> CloudAccountStatus
    func userRecordName() async throws -> String
    /// Yours: makes the zone if needed and a zone-wide share with this one person, read-only, with
    /// no public access. Anyone else on the share is removed. Returns its link and their status.
    func share(zone: String, with address: String, title: String) async throws -> ShareInvite
    /// Yours: the person's status on the zone's share; nil when the zone or its share is gone.
    func shareStatus(zone: String) async throws -> ShareInvite?
    /// Yours: removes the zone, its share, and everything in it. A zone already gone is fine.
    func deleteZone(_ zone: String) async throws
    /// Yours: saves records into the zone as they are (you're the only one who writes there).
    func save(_ records: [CloudRecord], zone: String) async throws
    /// Theirs: accepts an invitation and returns the zone it gave you.
    func accept(_ share: ShareAcceptance) async throws -> SharedZoneID
    /// Theirs: the zones shared with you.
    func sharedZones() async throws -> [SharedZoneID]
    /// Theirs: what changed in a zone shared with you; `CloudFailure.zoneNotFound` once it's gone.
    func sharedChanges(_ zone: SharedZoneID, since token: Data?) async throws -> CloudChanges
    /// Theirs: stops sharing it with you (you leave the share).
    func leave(_ zone: SharedZoneID) async throws
    /// Theirs: a silent push when something shared with you changes.
    func subscribeToShared() async throws
}

/// CloudKit: your private database for what you share, your shared database for what's shared
/// with you, both in the container `iCloud.com.zlichtman.kemosabe`.
struct CKShareDatabase: CloudShareDatabase {
    static let sharedSubscription = "shared-profiles"
    private var container: CKContainer { CKContainer(identifier: CKCloudDatabase.containerID) }
    private var mine: CKDatabase { container.privateCloudDatabase }
    private var theirs: CKDatabase { container.sharedCloudDatabase }
    private static func shareID(_ zone: CKRecordZone.ID) -> CKRecord.ID { .init(recordName: CKRecordNameZoneWideShare, zoneID: zone) }

    func accountStatus() async throws -> CloudAccountStatus { try await CKCloudDatabase().accountStatus() }
    func userRecordName() async throws -> String { try await CKCloudDatabase().userRecordName() }

    func share(zone: String, with address: String, title: String) async throws -> ShareInvite {
        let zoneID = CKCloudDatabase.zoneID(zone)
        do {
            _ = try await mine.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
            let share: CKShare
            if let existing = try? await mine.record(for: Self.shareID(zoneID)) as? CKShare { share = existing } else { share = CKShare(recordZoneID: zoneID) }
            share.publicPermission = .none
            share[CKShare.SystemFieldKey.title] = title as CKRecordValue
            let lookup = address.contains("@") ? CKUserIdentity.LookupInfo(emailAddress: address) : CKUserIdentity.LookupInfo(phoneNumber: address)
            guard let participant = try await container.shareParticipants(for: [lookup])[lookup]?.get() else { throw CloudFailure.other("That person couldn't be found.") }
            participant.permission = .readOnly
            // One person per zone: anyone else (an earlier address) comes off the share.
            for other in share.participants where other.role != .owner && other.userIdentity.lookupInfo != lookup { share.removeParticipant(other) }
            share.addParticipant(participant)
            let saved = try await mine.modifyRecords(saving: [share], deleting: [], savePolicy: .changedKeys).saveResults
            guard let result = saved[share.recordID], let stored = try result.get() as? CKShare else { throw CloudFailure.other("iCloud didn't save the share.") }
            return Self.invite(stored)
        } catch { throw CKCloudDatabase.failure(error) }
    }
    func shareStatus(zone: String) async throws -> ShareInvite? {
        do { return (try await mine.record(for: Self.shareID(CKCloudDatabase.zoneID(zone))) as? CKShare).map(Self.invite) }
        catch let error as CKError where [.unknownItem, .zoneNotFound, .userDeletedZone].contains(error.code) { return nil }
        catch { throw CKCloudDatabase.failure(error) }
    }
    static func invite(_ share: CKShare) -> ShareInvite {
        let others = share.participants.filter { $0.role != .owner }
        let status: ShareStatus
        if let person = others.first {
            if person.userIdentity.hasiCloudAccount == false { status = .noAccount }
            else {
                switch person.acceptanceStatus {
                case .accepted: status = .accepted
                case .removed: status = .left
                default: status = .pending
                }
            }
        } else { status = .left }
        return ShareInvite(url: share.url, status: status)
    }
    func deleteZone(_ zone: String) async throws {
        do { _ = try await mine.modifyRecordZones(saving: [], deleting: [CKCloudDatabase.zoneID(zone)]) }
        catch let error as CKError where [.zoneNotFound, .userDeletedZone].contains(error.code) { return }
        catch { throw CKCloudDatabase.failure(error) }
    }
    func save(_ records: [CloudRecord], zone: String) async throws {
        var files: [URL] = []
        defer { for file in files { try? FileManager.default.removeItem(at: file) } }
        let zoneID = CKCloudDatabase.zoneID(zone)
        let prepared = try records.map { try CKCloudDatabase.makeRecord($0, zone: zoneID, files: &files) }
        do {
            // You're the only one who writes here, so each save simply replaces what was there.
            let results = try await mine.modifyRecords(saving: prepared, deleting: [], savePolicy: .allKeys, atomically: false).saveResults
            for result in results.values { if case .failure(let error) = result { throw error } }
        } catch { throw CKCloudDatabase.failure(error) }
    }
    func accept(_ share: ShareAcceptance) async throws -> SharedZoneID {
        guard let metadata = share.metadata else { throw CloudFailure.other("That invitation couldn't be opened.") }
        do { _ = try await container.accept(metadata) } catch { throw CKCloudDatabase.failure(error) }
        return share.zone
    }
    func sharedZones() async throws -> [SharedZoneID] {
        do { return try await theirs.allRecordZones().map { SharedZoneID(zone: $0.zoneID.zoneName, owner: $0.zoneID.ownerName) } }
        catch { throw CKCloudDatabase.failure(error) }
    }
    func sharedChanges(_ zone: SharedZoneID, since token: Data?) async throws -> CloudChanges {
        let serverToken = token.flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0) }
        let zoneID = CKRecordZone.ID(zoneName: zone.zone, ownerName: zone.owner)
        do {
            let result = try await theirs.recordZoneChanges(inZoneWith: zoneID, since: serverToken)
            let records = result.modificationResultsByID.values.compactMap { try? $0.get().record }
                .filter { !($0 is CKShare) }.compactMap { try? CKCloudDatabase.cloudRecord($0) }
            let next = try? NSKeyedArchiver.archivedData(withRootObject: result.changeToken, requiringSecureCoding: true)
            return CloudChanges(records: records, deleted: result.deletions.map(\.recordID.recordName), token: next, moreComing: result.moreComing)
        } catch let error as CKError where [.zoneNotFound, .userDeletedZone, .unknownItem, .permissionFailure].contains(error.code) {
            // The owner stopped sharing it with you, or you left.
            throw CloudFailure.zoneNotFound
        } catch { throw CKCloudDatabase.failure(error) }
    }
    func leave(_ zone: SharedZoneID) async throws {
        // Deleting the share from your shared database takes you off it; the owner keeps theirs.
        let zoneID = CKRecordZone.ID(zoneName: zone.zone, ownerName: zone.owner)
        do { _ = try await theirs.modifyRecords(saving: [], deleting: [Self.shareID(zoneID)]) }
        catch let error as CKError where [.zoneNotFound, .userDeletedZone, .unknownItem].contains(error.code) { return }
        catch { throw CKCloudDatabase.failure(error) }
    }
    func subscribeToShared() async throws {
        let subscription = CKDatabaseSubscription(subscriptionID: Self.sharedSubscription)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        do { _ = try await theirs.modifySubscriptions(saving: [subscription], deleting: []) } catch { throw CKCloudDatabase.failure(error) }
    }
}

/// Before anything is shared or read, the device's iCloud account must be the one your account
/// syncs with (the same `icloud.json` the account's sync keeps); otherwise sharing pauses.
enum ShareAccountCheck {
    static func verify(_ database: CloudShareDatabase, bindingURL: URL?, personalZone: String) async throws {
        let status: CloudAccountStatus
        do { status = try await database.accountStatus() } catch let failure as CloudFailure { throw CloudKitSyncTransport.error(failure) }
        switch status {
        case .available: break
        case .noAccount: throw SyncError.iCloudUnavailable("Sign in to iCloud in Settings to share.")
        case .restricted: throw SyncError.iCloudUnavailable("iCloud is restricted on this device.")
        case .temporarilyUnavailable: throw SyncError.iCloudUnavailable("iCloud is temporarily unavailable. Check Settings → Apple Account.")
        case .couldNotDetermine: throw SyncError.network("iCloud couldn't be reached.")
        }
        guard let bindingURL else { return }
        let user: String
        do { user = try await database.userRecordName() } catch let failure as CloudFailure { throw CloudKitSyncTransport.error(failure) }
        if FileManager.default.fileExists(atPath: bindingURL.path) {
            guard let data = try? Data(contentsOf: bindingURL), let binding = try? JSONDecoder().decode(CloudKitSyncTransport.Binding.self, from: data) else {
                throw SyncError.stateUnreadable
            }
            if binding.userRecordName != user { throw SyncError.iCloudAccountMismatch }
        } else {
            // Sharing came first: record the iCloud account the way the account's sync does.
            try AccountDirectory.checkWrite(to: bindingURL)
            try FileManager.default.createDirectory(at: bindingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(CloudKitSyncTransport.Binding(userRecordName: user, zone: personalZone))
                .write(to: bindingURL, options: [.atomic, .completeFileProtection])
        }
    }
}

// MARK: The transport

/// Carries the zones of the people you share with. Only `profileShare` zones, only the shared
/// types (the engine's allow-list), and each image as an asset made from its file at push time,
/// so the engine's copy stays small.
actor CloudKitShareTransport: SyncTransport {
    let database: CloudShareDatabase
    /// Where each image record's pixels come from, by zone and record ID; set before each sync.
    private var images: [String: [String: SharedImageSource]] = [:]
    /// Zones that were gone when their records were sent (the share was deleted outside the app).
    private var lost: Set<String> = []
    static let chunk = 50
    init(database: CloudShareDatabase) { self.database = database }
    nonisolated func supports(_ zone: SyncZone) -> Bool { if case .profileShare = zone { true } else { false } }
    func use(images: [String: [String: SharedImageSource]]) { self.images = images }
    func takeLostZones() -> Set<String> { defer { lost = [] }; return lost }

    func push(_ records: [SyncRecord]) async throws {
        let byZone = Dictionary(grouping: records.filter { supports($0.zone) }, by: \.zone.name)
        for (zone, list) in byZone.sorted(by: { $0.key < $1.key }) {
            var cloud: [CloudRecord] = []
            for record in list {
                try SyncEngine.check(type: record.type, zone: record.zone)
                var item = CloudRecord(name: record.id, type: record.type, modified: record.modified, device: record.device,
                                       deleted: record.deleted, payload: record.payload, tag: nil)
                if record.type == SyncType.sharedImage, !record.deleted {
                    // A source is always set before a sync; without one, the record waits for the next.
                    guard let source = images[zone]?[record.id] else { throw SyncError.network("An image wasn't ready. Sharing will try again.") }
                    item.attachment = Self.jpeg(source)
                }
                cloud.append(item)
            }
            do {
                var start = 0
                while start < cloud.count {
                    let slice = Array(cloud[start..<min(start + Self.chunk, cloud.count)])
                    try await database.save(slice, zone: zone)
                    start += slice.count
                }
            } catch CloudFailure.zoneNotFound {
                lost.insert(zone)
            } catch let failure as CloudFailure { throw CloudKitSyncTransport.error(failure) }
        }
    }
    /// You're the only one who writes to these zones, so there's nothing to bring back.
    func pull(since token: Data?) async throws -> (records: [SyncRecord], token: Data?) { ([], token) }

    /// The image at its shared size, as JPEG; nil if the file can't be read.
    static func jpeg(_ source: SharedImageSource) -> Data? {
        guard let image = UIImage(contentsOfFile: source.file.path) else { return nil }
        return image.kemoResized(maxSide: CGFloat(source.maxSide)).jpegData(compressionQuality: 0.82)
    }
}

// MARK: Your sharing

/// Who you share your profile with, what each can see, and keeping their zones up to date. Stored
/// beside your profile in the account's Profile folder with complete file protection, on this
/// iPhone (its list doesn't sync to your other devices yet, since photos don't).
@MainActor @Observable final class ProfileSharingStore {
    private(set) static var shared = ProfileSharingStore.forCurrentAccount()
    static func reopen() { shared.close(); shared = forCurrentAccount() }

    enum Phase: Equatable {
        /// Sharing can't run here (a local account, or a build without iCloud); the list still works.
        case unavailable(String)
        case idle
        case working
        /// The device's iCloud account isn't the one your account syncs with.
        case paused(String)
        case failed(String)
    }
    /// What happened with one person's invitation, on this iPhone.
    struct MemberState: Codable, Equatable {
        var url: URL?
        var status: ShareStatus?
        var invited: Date?
    }
    struct State: Codable, Equatable {
        var members: [UUID: MemberState] = [:]
        /// Zones of people you removed, deleted as soon as iCloud can be reached.
        var removals: [String] = []
    }

    private(set) var settings = ProfileSharingSettings()
    private(set) var state = State()
    private(set) var phase: Phase = .idle
    /// Set when a sharing file exists but couldn't be read: nothing is changed or sent until it opens.
    private(set) var loadFailed = false
    /// A short line after something didn't work.
    private(set) var problem: String?

    @ObservationIgnored let profiles: ProfileStore
    @ObservationIgnored let database: CloudShareDatabase?
    @ObservationIgnored let engine: SyncEngine?
    @ObservationIgnored private let transport: CloudKitShareTransport?
    @ObservationIgnored private let folder: URL
    @ObservationIgnored private let bindingURL: URL?
    @ObservationIgnored private let personalZone: String
    @ObservationIgnored private let pet: () -> WatchLink.PetSummary?
    @ObservationIgnored private let unavailableReason: String?
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var running = false
    @ObservationIgnored private var again = false
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var petObserver: NSObjectProtocol?
    @ObservationIgnored var debounceDelay: Duration = .seconds(3)

    init(profiles: ProfileStore, database: CloudShareDatabase?, bindingURL: URL?, personalZone: String, device: String,
         unavailableReason: String? = nil, pet: @escaping () -> WatchLink.PetSummary? = { WatchLink.PetSummary.saved() }) {
        self.profiles = profiles; self.database = database; self.bindingURL = bindingURL; self.personalZone = personalZone
        self.pet = pet; self.unavailableReason = unavailableReason
        folder = profiles.directory
        if let database {
            let transport = CloudKitShareTransport(database: database)
            self.transport = transport
            engine = SyncEngine(transport: transport, device: device, url: folder.appendingPathComponent("Sharing/records.json"))
        } else { transport = nil; engine = nil }
        load()
        phase = database == nil ? .unavailable(unavailableReason ?? Self.notSetUp) : .idle
        profiles.onChanged = { [weak self] in self?.publishSoon() }
        petObserver = NotificationCenter.default.addObserver(forName: WatchLink.PetSummary.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.publishSoon() }
        }
    }
    static let notSetUp = "Sharing starts once iCloud is set up."
    static let signIn = "Sign in with Apple to share your profile."

    static func forCurrentAccount() -> ProfileSharingStore {
        let account = AccountDirectory.current()
        let personal = "personal-" + account.id
        let device = AccountRecords.deviceID()
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing"), arguments.contains("--sharing-stub") {
            return ProfileSharingStore(profiles: .shared, database: StubShareDatabase.shared, bindingURL: nil, personalZone: personal, device: device)
        }
        #endif
        guard AccountSyncService.availableInBuild, !AccountDirectory.isTestHost else {
            return ProfileSharingStore(profiles: .shared, database: nil, bindingURL: nil, personalZone: personal, device: device, unavailableReason: notSetUp)
        }
        guard account.kind == .apple else {
            return ProfileSharingStore(profiles: .shared, database: nil, bindingURL: nil, personalZone: personal, device: device, unavailableReason: signIn)
        }
        return ProfileSharingStore(profiles: .shared, database: CKShareDatabase(),
                                   bindingURL: AccountDirectory.currentFolder.appendingPathComponent("Sync/icloud.json"), personalZone: personal, device: device)
    }
    /// The device moved to another account: nothing more is written or sent.
    func close() {
        closed = true; debounce?.cancel()
        if let petObserver { NotificationCenter.default.removeObserver(petObserver) }
    }

    var canShare: Bool { database != nil && !loadFailed }
    var members: [SharingMember] { settings.members }
    func member(_ id: UUID) -> SharingMember? { settings.members.first { $0.id == id } }
    func memberState(_ id: UUID) -> MemberState { state.members[id] ?? MemberState() }
    /// People who accepted: the number under your picture.
    var acceptedCount: Int { settings.members.filter { state.members[$0.id]?.status == .accepted }.count }
    /// Asked once, right after you first add someone: who sees what.
    var needsDefaults: Bool { !settings.confirmedDefaults && !settings.members.isEmpty }
    static func zone(for id: UUID) -> SyncZone { .profileShare(id.uuidString.lowercased()) }

    // MARK: Files

    private var settingsURL: URL { folder.appendingPathComponent("sharing.json") }
    private var stateURL: URL { folder.appendingPathComponent("sharing-state.json") }
    private func load() {
        loadFailed = false
        for (url, apply) in [(settingsURL, { (data: Data) throws in self.settings = try JSONDecoder().decode(ProfileSharingSettings.self, from: data) }),
                             (stateURL, { (data: Data) throws in self.state = try JSONDecoder().decode(State.self, from: data) })] {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do { try apply(try Data(contentsOf: url)) } catch { loadFailed = true }
        }
        if loadFailed { problem = "Sharing couldn't be opened. Nothing was changed." }
    }
    private func write<Value: Encodable>(_ value: Value, to url: URL) {
        guard !closed, !loadFailed else { return }
        do {
            try AccountDirectory.checkWrite(to: url)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtection])
        } catch { problem = "Sharing couldn't be saved. Try again." }
    }
    private func saveSettings() { write(settings, to: settingsURL) }
    private func saveState() { write(state, to: stateURL) }

    // MARK: Your people

    /// Adds people, skipping anyone already here (the same email or phone number). Returns how many were added.
    @discardableResult func add(_ people: [SharingMember]) -> Int {
        guard !loadFailed, !closed else { return 0 }
        var keys = Set(settings.members.flatMap(\.identityKeys)), added = 0
        for person in people where settings.members.count < ProfileSharingSettings.maxMembers {
            guard let cleaned = SharingMember.cleaned(name: person.name, emails: person.emails, phones: person.phones) else { continue }
            let identity = cleaned.identityKeys
            guard identity.isDisjoint(with: keys) else { continue }
            var member = cleaned; member.close = person.close
            settings.members.append(member); keys.formUnion(identity); added += 1
        }
        if added > 0 { saveSettings() }
        return added
    }
    /// The first time you share: the audiences you confirmed (the suggested ones, as you left them).
    func confirmDefaults(_ audiences: [ProfileBlockKind: ProfileAudience]) {
        guard !loadFailed else { return }
        profiles.setAudiences(audiences)
        settings.confirmedDefaults = true; saveSettings(); publishSoon()
    }
    func setClose(_ id: UUID, _ close: Bool) { change(id) { $0.close = close } }
    func setOverride(_ id: UUID, _ kind: ProfileBlockKind, _ override: SharingMember.Override) { change(id) { $0.set(override, for: kind) } }
    /// The address their invitation goes to. A new address needs the invitation sent again.
    func setAddress(_ id: UUID, _ address: String) {
        guard member(id)?.lookup != address else { return }
        change(id) { $0.address = address }
        if var member = state.members[id], member.url != nil { member.url = nil; member.status = nil; state.members[id] = member; saveState() }
    }
    private func change(_ id: UUID, _ edit: (inout SharingMember) -> Void) {
        guard !loadFailed, let index = settings.members.firstIndex(where: { $0.id == id }) else { return }
        edit(&settings.members[index]); saveSettings(); publishSoon()
    }
    /// Stops sharing with someone: their zone, its share, and everything in it are deleted.
    func remove(_ id: UUID) {
        guard !loadFailed else { return }
        settings.members.removeAll { $0.id == id }
        state.members.removeValue(forKey: id)
        // Their zone goes too, even if an invitation never finished (deleting a zone that isn't there is fine).
        if database != nil { state.removals.append(Self.zone(for: id).name) }
        saveSettings(); saveState()
        publishSoon(after: .zero)
    }

    // MARK: Inviting

    enum SharingFailure: LocalizedError {
        case unavailable(String), noAddress, notOpen
        var errorDescription: String? {
            switch self {
            case .unavailable(let reason): reason
            case .noAddress: "Add an email address or phone number for them first."
            case .notOpen: "Your profile isn't open yet. Try again."
            }
        }
    }
    /// Makes their share and fills their zone, then returns the link for you to send them yourself.
    func invite(_ id: UUID) async throws -> URL {
        guard let database, !loadFailed else { throw SharingFailure.unavailable(unavailableReason ?? Self.notSetUp) }
        guard profiles.syncable else { throw SharingFailure.notOpen }
        guard let member = member(id), let address = member.lookup else { throw SharingFailure.noAddress }
        phase = .working; problem = nil
        do {
            try await ShareAccountCheck.verify(database, bindingURL: bindingURL, personalZone: personalZone)
            let zone = Self.zone(for: id).name
            // Sending the same invitation again reuses the share as it is, so someone who already
            // accepted stays accepted; a new address (which clears the link) makes the share again.
            var existing: ShareInvite?
            if state.members[id]?.url != nil { existing = try await database.shareStatus(zone: zone) }
            let invite: ShareInvite
            if let existing, existing.url != nil, existing.status != .left { invite = existing }
            else { invite = try await database.share(zone: zone, with: address, title: "KemoSabe profile") }
            guard let url = invite.url else { throw CloudFailure.other("iCloud didn't return a link.") }
            var memberState = state.members[id] ?? MemberState()
            memberState.url = url; memberState.status = invite.status; memberState.invited = memberState.invited ?? Date()
            state.members[id] = memberState; saveState()
            phase = .idle
            // Their zone fills before the link goes out, so they see your profile when they open it.
            await publish()
            return url
        } catch {
            let message = Self.message(error)
            phase = (error as? SyncError) == .iCloudAccountMismatch ? .paused(message) : .failed(message)
            throw SharingFailure.unavailable(message)
        }
    }
    /// Asks iCloud where each invitation stands (opened, pending, or left).
    func refreshStatuses() async {
        guard let database, !loadFailed, !closed else { return }
        do { try await ShareAccountCheck.verify(database, bindingURL: bindingURL, personalZone: personalZone) } catch { note(error); return }
        for member in settings.members {
            guard var memberState = state.members[member.id], memberState.url != nil else { continue }
            do {
                if let invite = try await database.shareStatus(zone: Self.zone(for: member.id).name) {
                    memberState.status = invite.status; memberState.url = invite.url ?? memberState.url
                } else {
                    // The share is gone (deleted outside the app): it needs a new invitation.
                    memberState = MemberState()
                    try? engine?.forget(zone: Self.zone(for: member.id))
                }
                state.members[member.id] = memberState
            } catch { note(error); break }
        }
        saveState()
    }

    // MARK: Keeping zones up to date

    func publishSoon(after delay: Duration? = nil) {
        guard database != nil, !closed else { return }
        debounce?.cancel()
        let wait = delay ?? debounceDelay
        debounce = Task { [weak self] in
            if wait > .zero { try? await Task.sleep(for: wait) }
            guard !Task.isCancelled else { return }
            await self?.publish()
        }
    }
    /// Deletes the zones of people you removed, then brings everyone else's zone in line with what
    /// they may see now: changed records are sent, and what they may no longer see becomes a
    /// tombstone with nothing in it. Nothing happens while your profile or this list isn't open,
    /// so a locked or unreadable profile never looks like everything was taken away.
    func publish() async {
        guard let database, let engine, let transport, !loadFailed, !closed else { return }
        guard profiles.syncable else { return }
        if running { again = true; return }
        running = true
        defer { running = false }
        repeat {
            again = false
            do {
                try await ShareAccountCheck.verify(database, bindingURL: bindingURL, personalZone: personalZone)
                for zone in state.removals {
                    try await database.deleteZone(zone)
                    try engine.forget(zone: .profileShare(String(zone.dropFirst("profile-".count))))
                    state.removals.removeAll { $0 == zone }; saveState()
                }
                var images: [String: [String: SharedImageSource]] = [:]
                let profile = profiles.profile, pet = pet()
                try engine.batch {
                    for member in settings.members where state.members[member.id]?.url != nil {
                        let zone = Self.zone(for: member.id)
                        let projection = ProfileProjection.records(for: member, profile: profile, pet: pet, file: profiles.url)
                        try ProfileProjection.validate(projection.records, for: member, in: profile)
                        images[zone.name] = projection.images
                        try Self.reconcile(engine, zone: zone, desired: projection.records)
                    }
                }
                await transport.use(images: images)
                try await engine.sync()
                for zone in await transport.takeLostZones() {
                    guard let member = settings.members.first(where: { Self.zone(for: $0.id).name == zone }) else { continue }
                    state.members[member.id] = MemberState()
                    try? engine.forget(zone: Self.zone(for: member.id))
                    problem = "\(member.name) needs a new invitation."
                }
                saveState()
                if case .failed = phase { phase = .idle }
                if case .paused = phase { phase = .idle }
            } catch { note(error); again = false }
        } while again && !closed
    }
    /// Queues what changed in one person's zone: new or different records, and tombstones for
    /// the ones they may no longer see.
    static func reconcile(_ engine: SyncEngine, zone: SyncZone, desired: [String: SharedRecord], at date: Date = Date()) throws {
        let current = engine.state.records.values.filter { $0.zone == zone && !$0.deleted }
        let byID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (id, record) in desired.sorted(by: { $0.key < $1.key }) {
            if let existing = byID[id], existing.type == record.type, SyncDigest.of(existing.payload) == SyncDigest.of(record.payload) { continue }
            try engine.putPayload(record.payload, id: id, type: record.type, zone: zone, at: date)
        }
        for (id, existing) in byID where desired[id] == nil {
            try engine.delete(id: id, type: existing.type, zone: zone, at: date)
        }
    }
    private func note(_ error: Error) {
        let message = Self.message(error)
        if (error as? SyncError) == .iCloudAccountMismatch { phase = .paused(message) } else { phase = .failed(message) }
    }
    static func message(_ error: Error) -> String {
        if let error = error as? SyncError {
            if error == .iCloudAccountMismatch { return "This iPhone is signed in to a different iCloud account, so sharing is paused." }
            return AccountSyncService.message(error)
        }
        if let failure = error as? CloudFailure { return AccountSyncService.message(CloudKitSyncTransport.error(failure)) }
        if let error = error as? SharingFailure { return error.localizedDescription }
        if error is AccountDirectory.WriteRefused { return "Your account is changing. Sharing will continue after." }
        return "Sharing didn't finish. It will try again."
    }
}

#if DEBUG
/// UI tests: an iCloud that answers at once, where every invitation is accepted as soon as it's
/// made (`--sharing-stub`). Nothing leaves the device.
actor StubShareDatabase: CloudShareDatabase {
    static let shared = StubShareDatabase()
    private var zones: [String: [String: CloudRecord]] = [:]
    func accountStatus() async throws -> CloudAccountStatus { .available }
    func userRecordName() async throws -> String { "stub-user" }
    func share(zone: String, with address: String, title: String) async throws -> ShareInvite {
        if zones[zone] == nil { zones[zone] = [:] }
        return ShareInvite(url: URL(string: "https://www.icloud.com/share/stub-" + zone), status: .accepted)
    }
    func shareStatus(zone: String) async throws -> ShareInvite? {
        zones[zone] == nil ? nil : ShareInvite(url: URL(string: "https://www.icloud.com/share/stub-" + zone), status: .accepted)
    }
    func deleteZone(_ zone: String) async throws { zones[zone] = nil }
    func save(_ records: [CloudRecord], zone: String) async throws {
        guard zones[zone] != nil else { throw CloudFailure.zoneNotFound }
        for record in records { zones[zone]?[record.name] = record }
    }
    func accept(_ share: ShareAcceptance) async throws -> SharedZoneID { share.zone }
    func sharedZones() async throws -> [SharedZoneID] { [] }
    func sharedChanges(_ zone: SharedZoneID, since token: Data?) async throws -> CloudChanges { .init(records: [], deleted: [], token: token, moreComing: false) }
    func leave(_ zone: SharedZoneID) async throws {}
    func subscribeToShared() async throws {}
}
#endif

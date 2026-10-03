import CloudKit
import UIKit
import XCTest
@testable import KemoSabe

/// iCloud sharing in memory, for both sides: your private database (zones, their shares, and the
/// one person on each) and the shared database of the person you invited, who reads a zone only
/// once they've accepted it and until it's gone.
actor FakeShareDatabase: CloudShareDatabase {
    private(set) var user = "owner-user"
    private(set) var zones: [String: [String: CloudRecord]] = [:]
    private(set) var shares: [String: (address: String, status: ShareStatus)] = [:]
    private(set) var deletedZones: [String] = []
    private(set) var left: [SharedZoneID] = []
    private(set) var saves = 0
    private(set) var shareCalls = 0
    private var offline = false
    var acceptOnShare = false
    static let owner = "owner-name"
    func signIn(_ user: String) { self.user = user }
    func setOffline(_ offline: Bool) { self.offline = offline }
    func setAcceptOnShare(_ accept: Bool) { acceptOnShare = accept }
    func setStatus(_ status: ShareStatus, zone: String) { shares[zone]?.status = status }
    func dropZoneOutsideTheApp(_ zone: String) { zones[zone] = nil; shares[zone] = nil }
    func records(_ zone: String) -> [String: CloudRecord] { zones[zone] ?? [:] }

    func accountStatus() async throws -> CloudAccountStatus {
        if offline { throw CloudFailure.network(retryAfter: nil) }
        return .available
    }
    func userRecordName() async throws -> String { user }
    func share(zone: String, with address: String, title: String) async throws -> ShareInvite {
        if offline { throw CloudFailure.network(retryAfter: nil) }
        if zones[zone] == nil { zones[zone] = [:] }
        shareCalls += 1
        shares[zone] = (address, acceptOnShare ? .accepted : .pending)
        return ShareInvite(url: URL(string: "https://www.icloud.com/share/" + zone), status: shares[zone]!.status)
    }
    func shareStatus(zone: String) async throws -> ShareInvite? {
        if offline { throw CloudFailure.network(retryAfter: nil) }
        return shares[zone].map { ShareInvite(url: URL(string: "https://www.icloud.com/share/" + zone), status: $0.status) }
    }
    func deleteZone(_ zone: String) async throws {
        if offline { throw CloudFailure.network(retryAfter: nil) }
        zones[zone] = nil; shares[zone] = nil; deletedZones.append(zone)
    }
    func save(_ records: [CloudRecord], zone: String) async throws {
        if offline { throw CloudFailure.network(retryAfter: nil) }
        guard zones[zone] != nil else { throw CloudFailure.zoneNotFound }
        saves += 1
        for record in records { zones[zone]?[record.name] = record }
    }
    func accept(_ share: ShareAcceptance) async throws -> SharedZoneID {
        guard shares[share.zone.zone] != nil else { throw CloudFailure.zoneNotFound }
        shares[share.zone.zone]?.status = .accepted
        return share.zone
    }
    func sharedZones() async throws -> [SharedZoneID] {
        if offline { throw CloudFailure.network(retryAfter: nil) }
        return shares.filter { $0.value.status == .accepted }.keys.sorted().map { SharedZoneID(zone: $0, owner: Self.owner) }
    }
    func sharedChanges(_ zone: SharedZoneID, since token: Data?) async throws -> CloudChanges {
        if offline { throw CloudFailure.network(retryAfter: nil) }
        guard let records = zones[zone.zone], shares[zone.zone]?.status == .accepted else { throw CloudFailure.zoneNotFound }
        return CloudChanges(records: records.values.sorted { $0.name < $1.name }, deleted: [], token: Data("t".utf8), moreComing: false)
    }
    func leave(_ zone: SharedZoneID) async throws {
        if offline { throw CloudFailure.network(retryAfter: nil) }
        left.append(zone); shares[zone.zone]?.status = .left
    }
    func subscribeToShared() async throws {}
}

@MainActor final class ProfileSharingTests: XCTestCase {
    private var root: URL!
    private var suite: String!
    private var account: AccountStore!
    private let pet = WatchLink.PetSummary(level: 4, xp: 60, streak: 3, starved: 1, updated: Date())

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ProfileSharingTests-" + UUID().uuidString, isDirectory: true)
        suite = "ProfileSharingTests-" + UUID().uuidString
        account = AccountStore(defaults: UserDefaults(suiteName: suite)!, cloud: nil)
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private func profiles(_ name: String = "Profile") -> ProfileStore { ProfileStore(folder: root.appendingPathComponent(name, isDirectory: true), account: account) }
    private func sharing(_ profiles: ProfileStore, database: CloudShareDatabase?, binding: URL? = nil) -> ProfileSharingStore {
        let store = ProfileSharingStore(profiles: profiles, database: database, bindingURL: binding, personalZone: "personal-test", device: "device-a",
                                        pet: { [pet] in pet })
        store.debounceDelay = .seconds(600) // Tests publish by hand.
        return store
    }
    private func image(_ color: UIColor) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 900, height: 600)).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 900, height: 600))
        }.pngData()!
    }
    /// A full profile: every block has something in it.
    private func filled(_ store: ProfileStore) throws {
        store.update { profile in
            profile.name = "Avery Chen"; profile.handle = "avery"; profile.headline = "Designer"; profile.bio = "Film and synths."
            profile.experience = [WorkEntry(title: "Designer", company: "Kemo Labs")]
            profile.skills = ["Prototyping"]
            profile.interests = ["Secret interest"]
            profile.facts = [ProfileFact(label: "Lives in", value: "Oakland")]
            profile.links = [ProfileLink(platform: .website, value: "avery.example")]
            profile.songs = [ProfileSong(title: "Nights", artist: "Frank Ocean", pick: .favoriteSong)]
            profile.blog = ProfileBlog(address: "https://avery.example", title: "Notes", entries: [BlogEntry(title: "Hello", summary: "First")])
        }
        try store.setPicture(image(.systemPink))
        try store.addPhoto(image(.systemBlue))
    }
    private static let member = SharingMember(name: "Sam Lee", emails: ["sam@example.com"])

    // MARK: Audiences and projection

    func testEverythingIsOnlyYouUntilYouShare() throws {
        let store = profiles()
        try filled(store)
        XCTAssertTrue(ProfileBlockKind.allCases.allSatisfy { store.profile.audience($0) == .onlyYou })
        var close = Self.member; close.close = true
        XCTAssertEqual(ProfileProjection.visibleBlocks(for: close, in: store.profile), [])
        let projection = ProfileProjection.records(for: close, profile: store.profile, pet: pet, file: store.url)
        // Only the header (and its picture) goes to anyone before you choose audiences.
        XCTAssertEqual(Set(projection.records.values.map(\.type)), [SyncType.sharedHeader, SyncType.sharedImage])
        XCTAssertEqual(projection.records.count, 2)
        let header = try JSONDecoder().decode(SharedProfileHeader.self, from: XCTUnwrap(projection.records[ProfileProjection.headerID]).payload)
        XCTAssertEqual(header.name, "Avery Chen"); XCTAssertEqual(header.headline, "Designer"); XCTAssertEqual(header.blocks, [])
        XCTAssertNotNil(header.picture)
    }

    func testProjectionFollowsAudiencesAndOverrides() throws {
        let store = profiles()
        try filled(store)
        store.setAudiences(ProfileSharingDefaults.suggested)
        store.setAudience(.music, .people); store.setHidden(.music, true)
        let person = Self.member
        var close = Self.member; close.close = true
        // Your people: work, writing, links (in your order). Music is hidden, so no one sees it.
        XCTAssertEqual(ProfileProjection.visibleBlocks(for: person, in: store.profile), [.work, .writing, .links])
        XCTAssertEqual(ProfileProjection.visibleBlocks(for: close, in: store.profile), [.photos, .work, .writing, .personal, .links, .kemo])
        // One person can see a block their audience can't, or be kept from one it can.
        var allowed = person; allowed.set(.show, for: .personal)
        XCTAssertTrue(ProfileProjection.visibleBlocks(for: allowed, in: store.profile).contains(.personal))
        var kept = close; kept.set(.hide, for: .photos)
        XCTAssertFalse(ProfileProjection.visibleBlocks(for: kept, in: store.profile).contains(.photos))
        var hiddenAllowed = person; hiddenAllowed.set(.show, for: .music)
        XCTAssertFalse(ProfileProjection.visibleBlocks(for: hiddenAllowed, in: store.profile).contains(.music), "A hidden block is seen by no one")
        // Going back to the group clears the override.
        allowed.set(.audience, for: .personal)
        XCTAssertEqual(allowed.allow, []); XCTAssertEqual(allowed.override(for: .personal), .audience)

        // What a person may not see is nowhere in what's sent to them.
        let projection = ProfileProjection.records(for: person, profile: store.profile, pet: pet, file: store.url)
        let text = projection.records.values.map { String(decoding: $0.payload, as: UTF8.self) }.joined()
        XCTAssertFalse(text.contains("Secret interest"))
        XCTAssertFalse(text.contains("Frank Ocean"))
        XCTAssertNil(projection.records[ProfileProjection.blockID(.photos)])
        XCTAssertTrue(text.contains("Kemo Labs"))
        XCTAssertNoThrow(try ProfileProjection.validate(projection.records, for: person, in: store.profile))
    }

    func testTheWatchGameSharesOnlyItsNumbers() throws {
        let store = profiles()
        store.setAudience(.kemo, .people)
        let projection = ProfileProjection.records(for: Self.member, profile: store.profile, pet: pet, file: store.url)
        let payload = try XCTUnwrap(projection.records[ProfileProjection.blockID(.kemo)]).payload
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["kind", "game"])
        XCTAssertEqual(Set((object["game"] as? [String: Any] ?? [:]).keys), ["level", "xp", "streak", "starved"])
        XCTAssertFalse(String(decoding: payload, as: UTF8.self).contains(CompanionIdentity.name), "The companion never leaves your devices")
    }

    // MARK: The allow-list

    func testPrivateDataCanNeverBeWrittenToAProfileShare() throws {
        let engine = SyncEngine(transport: MemorySyncTransport(), device: "d", url: nil)
        let zone = SyncZone.profileShare("someone")
        for type in SyncType.personalOnly {
            XCTAssertThrowsError(try engine.putPayload(Data("{}".utf8), id: "x", type: type, zone: zone)) {
                XCTAssertEqual($0 as? SyncError, .privateInSharedZone(type))
            }
            XCTAssertThrowsError(try engine.delete(id: "x", type: type, zone: zone))
        }
        // Your whole profile record and collaboration records aren't profile-share types either.
        for type in [SyncType.profile, SyncType.collabTask, SyncType.collabMessage, "anything.else"] {
            XCTAssertThrowsError(try engine.putPayload(Data("{}".utf8), id: "x", type: type, zone: zone)) {
                XCTAssertEqual($0 as? SyncError, .notShareable(type))
            }
        }
        // Nor can the shared types go to a project's zone.
        XCTAssertThrowsError(try engine.putPayload(Data("{}".utf8), id: "x", type: SyncType.sharedBlock, zone: .shared(project: "p")))
        // What arrives from elsewhere is held to the same list.
        XCTAssertFalse(engine.merge(SyncRecord(id: "c", type: SyncType.conversation, zone: zone, modified: Date(), device: "z", payload: Data())))
        XCTAssertTrue(engine.state.records.isEmpty)
        XCTAssertNoThrow(try engine.putPayload(Data("{}".utf8), id: "header", type: SyncType.sharedHeader, zone: zone))
        XCTAssertEqual(SyncType.profileShareable.intersection(SyncType.personalOnly), [])
    }

    func testValidationRefusesAnythingButTheSharedShapes() throws {
        let store = profiles()
        try filled(store)
        store.setAudience(.work, .people)
        let person = Self.member
        var records = ProfileProjection.records(for: person, profile: store.profile, pet: pet, file: store.url).records
        XCTAssertNoThrow(try ProfileProjection.validate(records, for: person, in: store.profile))

        // A chat dressed up as a record.
        var bad = records; bad["c"] = SharedRecord(id: "c", type: SyncType.conversation, payload: Data("{}".utf8))
        XCTAssertThrowsError(try ProfileProjection.validate(bad, for: person, in: store.profile)) { XCTAssertEqual($0 as? ProfileProjection.Violation, .type(SyncType.conversation)) }
        // A block they may not see.
        var personal = SharedProfileBlock(kind: .personal); personal.personal = SharedPersonal(interests: ["Secret interest"])
        bad = records; bad["block-personal"] = SharedRecord(id: "block-personal", type: SyncType.sharedBlock, payload: try SyncEngine.encode(personal))
        XCTAssertThrowsError(try ProfileProjection.validate(bad, for: person, in: store.profile)) { XCTAssertEqual($0 as? ProfileProjection.Violation, .block("block-personal")) }
        // A visible block carrying another block's content.
        var work = SharedProfileBlock(kind: .work); work.work = SharedWork(); work.personal = SharedPersonal(interests: ["Secret interest"])
        bad = records; bad["block-work"] = SharedRecord(id: "block-work", type: SyncType.sharedBlock, payload: try SyncEngine.encode(work))
        XCTAssertThrowsError(try ProfileProjection.validate(bad, for: person, in: store.profile)) { XCTAssertEqual($0 as? ProfileProjection.Violation, .block("block-work")) }
        // An extra field riding along in the header.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(records["header"]).payload) as? [String: Any])
        object["memories"] = ["Remember this"]
        records["header"] = SharedRecord(id: "header", type: SyncType.sharedHeader, payload: try JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try ProfileProjection.validate(records, for: person, in: store.profile)) { XCTAssertEqual($0 as? ProfileProjection.Violation, .payload("header")) }
    }

    // MARK: Sharing: invite, update, remove

    func testInviteFillsTheirZoneAndChangesFollow() async throws {
        let database = FakeShareDatabase()
        let store = profiles()
        try filled(store)
        let sharing = sharing(store, database: database)
        XCTAssertEqual(sharing.add([Self.member]), 1)
        XCTAssertTrue(sharing.needsDefaults)
        sharing.confirmDefaults(ProfileSharingDefaults.suggested)
        XCTAssertFalse(sharing.needsDefaults)
        let id = try XCTUnwrap(sharing.members.first?.id)
        let zone = ProfileSharingStore.zone(for: id).name

        let url = try await sharing.invite(id)
        XCTAssertEqual(url.absoluteString, "https://www.icloud.com/share/" + zone)
        let share = await database.shares[zone]
        XCTAssertEqual(share?.address, "sam@example.com")
        var records = await database.records(zone)
        XCTAssertEqual(Set(records.keys.filter { !$0.hasPrefix("image-") }), ["header", "block-work", "block-writing", "block-links"])
        let picture = try XCTUnwrap(records.values.first { $0.type == SyncType.sharedImage })
        XCTAssertNotNil(picture.attachment.flatMap(UIImage.init(data:)), "Images travel as assets")
        XCTAssertLessThan(picture.payload.count, 64, "An image's payload is only its role")
        XCTAssertEqual(sharing.acceptedCount, 0)

        // They open it.
        await database.setStatus(.accepted, zone: zone)
        await sharing.refreshStatuses()
        XCTAssertEqual(sharing.acceptedCount, 1)

        // Close friend: photos, personal, and the watch game follow.
        sharing.setClose(id, true)
        await sharing.publish()
        records = await database.records(zone)
        XCTAssertNotNil(records["block-photos"]); XCTAssertNotNil(records["block-personal"]); XCTAssertNotNil(records["block-kemo"])
        let photos = try JSONDecoder().decode(SharedProfileBlock.self, from: XCTUnwrap(records["block-photos"]).payload)
        XCTAssertEqual(photos.posts?.count, 1)
        XCTAssertNotNil(records[try XCTUnwrap(photos.posts?.first?.image)]?.attachment)

        // Kept from photos: the block and its images become empty tombstones.
        sharing.setOverride(id, .photos, .hide)
        await sharing.publish()
        records = await database.records(zone)
        let gone = try XCTUnwrap(records["block-photos"])
        XCTAssertTrue(gone.deleted); XCTAssertTrue(gone.payload.isEmpty)
        let postImage = try XCTUnwrap(records[try XCTUnwrap(photos.posts?.first?.image)])
        XCTAssertTrue(postImage.deleted); XCTAssertNil(postImage.attachment)
        // A change to your profile reaches them.
        store.update { $0.headline = "Lead designer" }
        await sharing.publish()
        records = await database.records(zone)
        let header = try JSONDecoder().decode(SharedProfileHeader.self, from: XCTUnwrap(records["header"]).payload)
        XCTAssertEqual(header.headline, "Lead designer")
        XCTAssertFalse(header.blocks.contains(.photos))

        // Removing them deletes their zone and its share.
        sharing.remove(id)
        await sharing.publish()
        let deleted = await database.deletedZones
        XCTAssertEqual(deleted, [zone])
        let after = await database.shares[zone]
        XCTAssertNil(after)
        XCTAssertTrue(try XCTUnwrap(sharing.engine).state.records.values.allSatisfy { $0.zone.name != zone })
        XCTAssertEqual(sharing.acceptedCount, 0)
        // Nothing of theirs is kept: a relaunch reads the same list.
        let reopened = self.sharing(store, database: database)
        XCTAssertTrue(reopened.members.isEmpty); XCTAssertEqual(reopened.state.removals, [])
    }

    func testSendingAgainKeepsAnAcceptedShareAndANewAddressMakesItAgain() async throws {
        let database = FakeShareDatabase()
        let sharing = sharing(profiles(), database: database)
        sharing.add([SharingMember(name: "Sam Lee", emails: ["sam@example.com"], phones: ["+1 415 555 0101"])]); sharing.confirmDefaults([:])
        let id = try XCTUnwrap(sharing.members.first?.id)
        let zone = ProfileSharingStore.zone(for: id).name
        _ = try await sharing.invite(id)
        await database.setStatus(.accepted, zone: zone)
        _ = try await sharing.invite(id)
        var calls = await database.shareCalls
        XCTAssertEqual(calls, 1, "The same link again; the share isn't touched")
        XCTAssertEqual(sharing.memberState(id).status, .accepted)
        // They left: sending again puts them back on the share.
        await database.setStatus(.left, zone: zone)
        _ = try await sharing.invite(id)
        calls = await database.shareCalls
        XCTAssertEqual(calls, 2)
        // A new address clears the link and makes the share again, for that address.
        sharing.setAddress(id, "+1 415 555 0101")
        XCTAssertNil(sharing.memberState(id).url)
        _ = try await sharing.invite(id)
        let share = await database.shares[zone]
        XCTAssertEqual(share?.address, "+1 415 555 0101")
    }

    func testRemovingWhileOfflineFinishesLater() async throws {
        let database = FakeShareDatabase()
        let store = profiles()
        let sharing = sharing(store, database: database)
        sharing.add([Self.member]); sharing.confirmDefaults([:])
        let id = try XCTUnwrap(sharing.members.first?.id)
        _ = try await sharing.invite(id)
        await database.setOffline(true)
        sharing.remove(id)
        await sharing.publish()
        XCTAssertEqual(sharing.state.removals, [ProfileSharingStore.zone(for: id).name], "Kept until iCloud can be reached")
        let reopened = self.sharing(store, database: database)
        XCTAssertEqual(reopened.state.removals.count, 1, "…even across a relaunch")
        await database.setOffline(false)
        await reopened.publish()
        XCTAssertEqual(reopened.state.removals, [])
        let deleted = await database.deletedZones
        XCTAssertEqual(deleted.count, 1)
    }

    func testAShareDeletedOutsideTheAppAsksForANewInvitation() async throws {
        let database = FakeShareDatabase()
        let store = profiles()
        let sharing = sharing(store, database: database)
        sharing.add([Self.member]); sharing.confirmDefaults([:])
        let id = try XCTUnwrap(sharing.members.first?.id)
        _ = try await sharing.invite(id)
        await database.dropZoneOutsideTheApp(ProfileSharingStore.zone(for: id).name)
        store.update { $0.bio = "Changed" }
        await sharing.publish()
        XCTAssertNil(sharing.memberState(id).url, "They need a new invitation")
        XCTAssertEqual(sharing.members.count, 1, "…and stay on your list")
    }

    func testAProfileThatIsntOpenNeverLooksEmptied() async throws {
        let database = FakeShareDatabase()
        let folder = root.appendingPathComponent("Profile", isDirectory: true)
        let store = profiles()
        try filled(store)
        store.setAudiences(ProfileSharingDefaults.suggested)
        let sharing = sharing(store, database: database)
        sharing.add([Self.member]); sharing.confirmDefaults(ProfileSharingDefaults.suggested)
        let id = try XCTUnwrap(sharing.members.first?.id)
        _ = try await sharing.invite(id)
        let zone = ProfileSharingStore.zone(for: id).name
        let before = await database.records(zone)

        // The profile file can't be read (a locked iPhone, a damaged file): nothing is sent.
        try Data("not json".utf8).write(to: folder.appendingPathComponent("profile.json"))
        let unreadable = profiles()
        XCTAssertTrue(unreadable.loadFailed)
        let paused = self.sharing(unreadable, database: database)
        await paused.publish()
        let after = await database.records(zone)
        XCTAssertEqual(after, before, "Nothing was tombstoned")
        do { _ = try await paused.invite(id); XCTFail("Inviting waits for the profile") } catch {}

        // The sharing list itself can't be read: nothing is changed, sent, or deleted.
        try Data("not json".utf8).write(to: folder.appendingPathComponent("sharing.json"))
        let brokenList = self.sharing(profiles(), database: database)
        XCTAssertTrue(brokenList.loadFailed)
        XCTAssertEqual(brokenList.add([SharingMember(name: "New", emails: ["new@example.com"])]), 0)
        brokenList.remove(id)
        await brokenList.publish()
        let deleted = await database.deletedZones
        XCTAssertEqual(deleted, [])
        XCTAssertEqual(String(decoding: try Data(contentsOf: folder.appendingPathComponent("sharing.json")), as: UTF8.self), "not json", "Left untouched")
    }

    func testADifferentICloudAccountPausesSharing() async throws {
        let database = FakeShareDatabase()
        let binding = root.appendingPathComponent("Sync/icloud.json")
        try FileManager.default.createDirectory(at: binding.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(CloudKitSyncTransport.Binding(userRecordName: "someone-else", zone: "personal-test")).write(to: binding)
        let sharing = sharing(profiles(), database: database, binding: binding)
        sharing.add([Self.member]); sharing.confirmDefaults([:])
        let id = try XCTUnwrap(sharing.members.first?.id)
        do { _ = try await sharing.invite(id); XCTFail("Paused") } catch {}
        guard case .paused = sharing.phase else { return XCTFail("Expected paused, got \(sharing.phase)") }
        let shares = await database.shares
        XCTAssertTrue(shares.isEmpty, "Nothing was shared from the other account")
    }

    func testSharingRecordsTheICloudAccountWhenItComesFirst() async throws {
        let database = FakeShareDatabase()
        let binding = root.appendingPathComponent("Sync/icloud.json")
        let sharing = sharing(profiles(), database: database, binding: binding)
        sharing.add([Self.member]); sharing.confirmDefaults([:])
        _ = try await sharing.invite(try XCTUnwrap(sharing.members.first?.id))
        let saved = try JSONDecoder().decode(CloudKitSyncTransport.Binding.self, from: Data(contentsOf: binding))
        XCTAssertEqual(saved.userRecordName, "owner-user"); XCTAssertEqual(saved.zone, "personal-test")
    }

    func testPeopleAreAddedOnceWithOnlyWhatsNeeded() {
        let sharing = sharing(profiles(), database: nil)
        XCTAssertEqual(sharing.phase, .unavailable(ProfileSharingStore.notSetUp))
        let added = sharing.add([
            SharingMember(name: " Sam Lee ", emails: ["Sam@Example.com", "sam@example.com", "not an email"], phones: ["+1 (415) 555-0101"]),
            SharingMember(name: "Sam again", emails: ["sam@example.com"]),
            SharingMember(name: "No address"),
        ])
        XCTAssertEqual(added, 1)
        let sam = sharing.members[0]
        XCTAssertEqual(sam.name, "Sam Lee"); XCTAssertEqual(sam.emails, ["Sam@Example.com"]); XCTAssertEqual(sam.phones, ["+1 (415) 555-0101"])
        XCTAssertEqual(sam.lookup, "Sam@Example.com")
        sharing.setAddress(sam.id, "+1 (415) 555-0101")
        XCTAssertEqual(sharing.member(sam.id)?.lookup, "+1 (415) 555-0101")
        // Without iCloud the list still works, and inviting says why it can't.
        let data = try? Data(contentsOf: sharing.profiles.directory.appendingPathComponent("sharing.json"))
        XCTAssertFalse(String(decoding: data ?? Data(), as: UTF8.self).contains("contactIdentifier"))
    }

    // MARK: Record encoding

    func testSharedRecordsKeepEveryFieldEncryptedAndImagesAsAssets() throws {
        var files: [URL] = []
        defer { for file in files { try? FileManager.default.removeItem(at: file) } }
        let zone = CKCloudDatabase.zoneID("profile-someone")
        let pixels = image(.systemTeal)
        let source = CloudRecord(name: "image-abc", type: SyncType.sharedImage, modified: Date(timeIntervalSince1970: 1000), device: "d",
                                 deleted: false, payload: try SyncEngine.encode(SharedImageInfo(role: .post)), tag: nil, attachment: pixels)
        let record = try CKCloudDatabase.makeRecord(source, zone: zone, files: &files)
        XCTAssertEqual(record.recordType, CKCloudDatabase.recordType, "The existing SyncRecord type: no schema change")
        XCTAssertEqual(record.encryptedValues["type"] as? String, SyncType.sharedImage)
        XCTAssertEqual(record.encryptedValues["device"] as? String, "d")
        XCTAssertEqual(record.encryptedValues["modified"] as? Date, source.modified)
        XCTAssertEqual(record.encryptedValues["deleted"] as? Int64, 0)
        XCTAssertEqual(record.encryptedValues["payload"] as? Data, source.payload)
        // The image is the asset, which CloudKit encrypts too.
        XCTAssertNotNil(record["payloadAsset"] as? CKAsset)
        let back = try CKCloudDatabase.cloudRecord(record)
        XCTAssertEqual(back.payload, source.payload); XCTAssertEqual(back.attachment, pixels); XCTAssertEqual(back.type, SyncType.sharedImage)

        // A tombstone carries nothing.
        var tombstone = source; tombstone.deleted = true; tombstone.payload = Data(); tombstone.attachment = nil
        let cleared = try CKCloudDatabase.makeRecord(tombstone, zone: zone, files: &files)
        XCTAssertNil(cleared["payloadAsset"])

        // The shared shapes round-trip exactly.
        var block = SharedProfileBlock(kind: .work, style: .summary)
        block.work = SharedWork(about: "About", experience: [WorkEntry(title: "Designer", company: "Kemo Labs")], skills: ["Swift"])
        XCTAssertEqual(try JSONDecoder().decode(SharedProfileBlock.self, from: SyncEngine.encode(block)), block)
        let header = SharedProfileHeader(name: "A", handle: "a", headline: nil, bio: "", accent: "#E8735A", picture: "image-1", cover: nil, blocks: [.work])
        XCTAssertEqual(try JSONDecoder().decode(SharedProfileHeader.self, from: SyncEngine.encode(header)), header)
    }

    // MARK: Profiles shared with you

    func testAcceptingShowsOnlyWhatWasSharedAndFollowsChanges() async throws {
        let database = FakeShareDatabase()
        let store = profiles()
        try filled(store)
        let sharing = sharing(store, database: database)
        sharing.add([Self.member]); sharing.confirmDefaults(ProfileSharingDefaults.suggested)
        let id = try XCTUnwrap(sharing.members.first?.id)
        _ = try await sharing.invite(id)
        let zone = SharedZoneID(zone: ProfileSharingStore.zone(for: id).name, owner: FakeShareDatabase.owner)

        // Their iPhone: the link opens KemoSabe and it's accepted.
        let theirs = SharedProfilesStore(folder: root.appendingPathComponent("Theirs", isDirectory: true), database: database, bindingURL: nil, personalZone: "personal-them")
        await theirs.accept(ShareAcceptance(zone: zone))
        XCTAssertNil(theirs.problem)
        var card = try XCTUnwrap(theirs.cards.first)
        XCTAssertEqual(theirs.presented, card.id)
        XCTAssertEqual(card.name, "Avery Chen")
        XCTAssertEqual(card.ordered.map(\.kind), [.work, .writing, .links])
        XCTAssertNotNil(theirs.image(card, card.header?.picture), "The picture came as an image")
        XCTAssertEqual(sharing.acceptedCount, 0)
        await sharing.refreshStatuses()
        XCTAssertEqual(sharing.acceptedCount, 1)

        // Your change reaches them: links go to Only you.
        store.setAudience(.links, .onlyYou)
        await sharing.publish()
        await theirs.refresh()
        card = try XCTUnwrap(theirs.cards.first)
        XCTAssertEqual(card.ordered.map(\.kind), [.work, .writing])
        XCTAssertFalse(card.blocks.contains { $0.kind == .links })

        // Offline: what they have stays.
        await database.setOffline(true)
        await theirs.refresh()
        XCTAssertEqual(theirs.cards.count, 1)
        await database.setOffline(false)

        // A relaunch reads the same card.
        let reopened = SharedProfilesStore(folder: root.appendingPathComponent("Theirs", isDirectory: true), database: database, bindingURL: nil, personalZone: "personal-them")
        XCTAssertEqual(reopened.cards, theirs.cards)

        // You stop sharing with them: it disappears from their People.
        sharing.remove(id)
        await sharing.publish()
        await theirs.refresh()
        XCTAssertTrue(theirs.cards.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Theirs/" + card.id).path), "Its images are deleted")
    }

    func testTheyCanRemoveYourProfile() async throws {
        let database = FakeShareDatabase()
        let store = profiles()
        try filled(store)
        let sharing = sharing(store, database: database)
        sharing.add([Self.member]); sharing.confirmDefaults(ProfileSharingDefaults.suggested)
        let id = try XCTUnwrap(sharing.members.first?.id)
        _ = try await sharing.invite(id)
        let zone = SharedZoneID(zone: ProfileSharingStore.zone(for: id).name, owner: FakeShareDatabase.owner)
        let theirs = SharedProfilesStore(folder: root.appendingPathComponent("Theirs", isDirectory: true), database: database, bindingURL: nil, personalZone: "personal-them")
        await theirs.accept(ShareAcceptance(zone: zone))
        let card = try XCTUnwrap(theirs.cards.first)

        // Offline, removing says so and keeps it.
        await database.setOffline(true)
        let offline = await theirs.remove(card.id)
        XCTAssertFalse(offline); XCTAssertEqual(theirs.cards.count, 1); XCTAssertNotNil(theirs.problem)
        await database.setOffline(false)
        let removed = await theirs.remove(card.id)
        XCTAssertTrue(removed)
        XCTAssertTrue(theirs.cards.isEmpty)
        let left = await database.left
        XCTAssertEqual(left, [zone])
        // You see that they left.
        await sharing.refreshStatuses()
        XCTAssertEqual(sharing.memberState(id).status, .left)
        XCTAssertEqual(sharing.acceptedCount, 0)
    }

    func testOnlyProfileSharesAreAcceptedAndOnlySharedTypesAreRead() async throws {
        let database = FakeShareDatabase()
        let theirs = SharedProfilesStore(folder: root.appendingPathComponent("Theirs", isDirectory: true), database: database, bindingURL: nil, personalZone: "p")
        await theirs.accept(ShareAcceptance(zone: SharedZoneID(zone: "project-abc", owner: "o")))
        XCTAssertTrue(theirs.cards.isEmpty)

        // Whatever sits in a zone, only the shared shapes are read.
        var card = SharedProfileCard(zone: SharedZoneID(zone: "profile-x", owner: "o"))
        let header = SharedProfileHeader(name: "Riley", handle: "", headline: nil, bio: "", accent: nil, picture: nil, cover: nil, blocks: [.work, .personal])
        var mislabeled = SharedProfileBlock(kind: .work); mislabeled.personal = SharedPersonal(interests: ["x"])
        let records = [
            CloudRecord(name: "header", type: SyncType.sharedHeader, modified: Date(), device: "d", deleted: false, payload: try SyncEngine.encode(header)),
            CloudRecord(name: "memory-1", type: SyncType.memory, modified: Date(), device: "d", deleted: false, payload: Data("{\"text\":\"secret\"}".utf8)),
            CloudRecord(name: "block-work", type: SyncType.sharedBlock, modified: Date(), device: "d", deleted: false, payload: try SyncEngine.encode(mislabeled)),
        ]
        card.apply(records, saveImage: { _, _ in nil }, removeImage: { _ in })
        XCTAssertEqual(card.header?.name, "Riley")
        XCTAssertTrue(card.blocks.isEmpty, "A block with another block's content is dropped")
    }

    // MARK: Migration

    func testAnOlderProfileOpensWithFollowersDroppedAndEverythingOnlyYou() throws {
        let folder = root.appendingPathComponent("Profile", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = """
        {"name":"","handle":"","bio":"Hi","followers":12,"following":3,"followerIDs":["a","b"],
         "blocks":[{"kind":"photos","hidden":false,"style":"feed"},{"kind":"work","hidden":true},{"kind":"links","audience":"everyone"}]}
        """
        try Data(old.utf8).write(to: folder.appendingPathComponent("profile.json"))
        let store = profiles()
        XCTAssertFalse(store.loadFailed)
        XCTAssertEqual(store.profile.bio, "Hi")
        XCTAssertEqual(store.profile.style(.photos), .feed)
        XCTAssertTrue(store.profile.block(.work).hidden)
        XCTAssertTrue(ProfileBlockKind.allCases.allSatisfy { store.profile.audience($0) == .onlyYou }, "An unknown audience reads as Only you, never wider")
        store.setAudience(.work, .people)
        let saved = String(decoding: try Data(contentsOf: folder.appendingPathComponent("profile.json")), as: UTF8.self)
        XCTAssertFalse(saved.contains("follower")); XCTAssertFalse(saved.contains("following"))
        XCTAssertTrue(saved.contains("\"audience\":\"people\""))
        XCTAssertEqual(profiles().profile.audience(.work), .people, "Audiences survive a relaunch")
        // Audiences travel with the layout to your other devices.
        XCTAssertEqual(store.synced.blocks?.first { $0.kind == .work }?.audience, .people)
    }
}

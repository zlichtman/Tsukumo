import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import KemoSabe

/// Your name, username, profile picture, and cover between devices, through the sync engine with the
/// in-memory transport: an iPhone (`ProfileStore`, whose picture and cover sync) and a Mac (whose
/// account photo is the same picture). See design/ACCOUNTS-AND-PROFILES.md.
@MainActor final class ProfileSyncTests: XCTestCase {
    private var root: URL!
    private var suites: [String] = []
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ProfileSyncTests-" + UUID().uuidString, isDirectory: true)
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
    }
    private func defaults() -> UserDefaults {
        let name = "ProfileSyncTests-" + UUID().uuidString
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    /// One device: its account, its synced copy, and its sync service. An iPhone also has its profile.
    struct Device {
        let name: String
        let account: AccountStore
        let engine: SyncEngine
        let service: AccountSyncService
        let profiles: ProfileStore?
    }
    private func device(_ name: String, transport: SyncTransport, phone: Bool) -> Device {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        let engine = SyncEngine(transport: transport, device: name)
        let records = AccountRecords(engine: engine)
        let account = AccountStore(defaults: defaults(), cloud: nil, records: records, photoFolder: folder.appendingPathComponent("Account", isDirectory: true))
        let service = AccountSyncService(records: { records }, defaults: defaults(), available: true)
        var adapters: [SyncAdapter] = [AccountSyncAdapter(account: account)]
        var profiles: ProfileStore?
        if phone {
            let store = ProfileStore(folder: folder.appendingPathComponent("Profile", isDirectory: true), account: account, records: records)
            adapters += [ProfileSyncAdapter(profiles: store), ProfileImageSyncAdapter.forProfile(store)]
            profiles = store
        } else {
            adapters.append(ProfileImageSyncAdapter.forAccountPhoto(account))
        }
        service.attach(adapters, startSync: false)
        return Device(name: name, account: account, engine: engine, service: service, profiles: profiles)
    }
    private func sync(_ devices: Device...) async {
        for device in devices {
            await device.service.syncNow()
            XCTAssertEqual(device.service.phase, .idle, "\(device.name): \(device.service.phase)")
        }
    }

    // MARK: Name and username

    /// The owner's report: the iPhone had a name, the Mac joined, and the names never matched. Before
    /// the fix, the Mac queued its own (empty) account record at launch, before it had joined, stamped
    /// newer than the iPhone's: the join kept it, sent it, and it replaced the iPhone's name.
    func testAJoiningMacTakesTheNameInsteadOfSendingItsOwnEmptyOne() async throws {
        let transport = MemorySyncTransport()
        let phone = device("phone", transport: transport, phone: true)
        phone.account.update { $0.name = "Zach Lichtman"; $0.handle = "zach" }
        await sync(phone)

        let mac = device("mac", transport: transport, phone: false)
        // What Tsukumo does at launch (`connectAccount`), before its first sync.
        mac.account.sync()
        await sync(mac, phone)

        XCTAssertEqual(mac.account.account.name, "Zach Lichtman", "The Mac shows the iPhone's name")
        XCTAssertEqual(mac.account.account.handle, "zach")
        XCTAssertEqual(phone.account.account.name, "Zach Lichtman", "and the iPhone keeps it")
        XCTAssertEqual(phone.profiles?.profile.name, "Zach Lichtman", "The profile header reads the account's name")
        XCTAssertTrue(mac.engine.state.outbox.isEmpty && phone.engine.state.outbox.isEmpty, "Converged")
    }

    func testANameEditedOnEitherDeviceReachesTheOther() async throws {
        let transport = MemorySyncTransport()
        let phone = device("phone", transport: transport, phone: true), mac = device("mac", transport: transport, phone: false)
        phone.account.update { $0.name = "Zach"; $0.handle = "zach" }
        await sync(phone, mac)
        XCTAssertEqual(mac.account.account.name, "Zach")

        // Edited in the iPhone's profile header.
        phone.profiles?.update { $0.name = "Zach L"; $0.handle = "zachl" }
        await sync(phone, mac)
        XCTAssertEqual(mac.account.account.name, "Zach L")
        XCTAssertEqual(mac.account.account.handle, "zachl")

        // Edited in the Mac's Settings → Account.
        mac.account.update { $0.name = "Zachary" }
        await sync(mac, phone)
        XCTAssertEqual(phone.account.account.name, "Zachary")
        XCTAssertEqual(phone.profiles?.profile.name, "Zachary")
        XCTAssertEqual(phone.profiles?.profile.handle, "zachl")

        // Relaunching (which queues the account again) sends nothing new.
        phone.account.sync(); mac.account.sync()
        XCTAssertTrue(phone.engine.state.outbox.isEmpty && mac.engine.state.outbox.isEmpty)
    }

    /// A value is stamped when it's queued. An edit that was saved but not queued (here, while the
    /// device hadn't joined) never goes out with an older time than the record another device holds,
    /// which that device would then refuse to take.
    func testAQueuedValueIsStampedWhenItsQueued() throws {
        let engine = SyncEngine(transport: MemorySyncTransport(), device: "phone")
        let records = AccountRecords(engine: engine)
        let account = AccountStore(defaults: defaults(), cloud: nil, records: records)
        account.update { $0.name = "Before joining" }
        XCTAssertTrue(engine.state.outbox.isEmpty, "Nothing is queued before the device has joined; the join decides")
        try engine.markJoined()
        let start = Date()
        account.push()
        let record = try XCTUnwrap(engine.state.records["personal/" + AccountRecords.accountID])
        XCTAssertGreaterThanOrEqual(record.modified, start)
    }

    // MARK: Picture and cover

    func testThePictureAndCoverReachTheOtherDevices() async throws {
        let transport = MemorySyncTransport()
        let phone = device("phone", transport: transport, phone: true), mac = device("mac", transport: transport, phone: false)
        let profiles = try XCTUnwrap(phone.profiles)
        try profiles.setPicture(photo(.systemPink, width: 3000, height: 2000))
        try profiles.setBanner(photo(.systemTeal, width: 4000, height: 1500))
        await sync(phone, mac)

        // The Mac shows the iPhone's picture as its account photo, exactly as the iPhone keeps it.
        let picture = try XCTUnwrap(profiles.syncedImage(cover: false) ?? nil)
        XCTAssertEqual(try pixels(picture), [600, 600], "The picture is kept at the size it syncs at")
        let macPhoto = try XCTUnwrap(mac.account.photoURL.flatMap { try? Data(contentsOf: $0) })
        XCTAssertEqual(macPhoto, picture)
        XCTAssertLessThanOrEqual(try XCTUnwrap(try pixels(XCTUnwrap(profiles.syncedImage(cover: true) ?? nil)).max()), 1600)

        // A second iPhone gets the picture and the cover.
        let ipad = device("ipad", transport: transport, phone: true)
        await sync(ipad)
        XCTAssertEqual(ipad.profiles?.syncedImage(cover: false) ?? nil, picture)
        XCTAssertEqual(ipad.profiles?.syncedImage(cover: true) ?? nil, profiles.syncedImage(cover: true) ?? nil)
        XCTAssertNotNil(ipad.profiles?.pictureImage())
        XCTAssertNotNil(ipad.profiles?.bannerImage())

        // Nothing bounces back: a received image reads back byte for byte.
        await sync(phone, mac, ipad)
        for device in [phone, mac, ipad] { XCTAssertNil(device.service.lastResult, "\(device.name) has nothing more to send or take in") }

        // A photo chosen on the Mac (Settings → Account saves a JPEG) becomes the iPhones' picture.
        try mac.account.setPhoto(jpeg(width: 512, height: 512, red: 1))
        await sync(mac, phone, ipad)
        let chosen = try XCTUnwrap(mac.account.syncedPhoto() ?? nil)
        XCTAssertEqual(profiles.syncedImage(cover: false) ?? nil, chosen)
        XCTAssertEqual(ipad.profiles?.syncedImage(cover: false) ?? nil, chosen)
    }

    func testRemovingThePictureOrCoverRemovesItEverywhere() async throws {
        let transport = MemorySyncTransport()
        let phone = device("phone", transport: transport, phone: true), mac = device("mac", transport: transport, phone: false)
        let ipad = device("ipad", transport: transport, phone: true)
        let profiles = try XCTUnwrap(phone.profiles)
        try profiles.setPicture(photo(.systemPink, width: 900, height: 900))
        try profiles.setBanner(photo(.systemTeal, width: 1200, height: 400))
        await sync(phone, mac, ipad)
        XCTAssertNotNil(mac.account.account.photoFile)
        let macFile = try XCTUnwrap(mac.account.photoURL)

        // Removed on the Mac: the iPhones' pictures go too, and the Mac's file is deleted.
        try mac.account.setPhoto(nil)
        await sync(mac, phone, ipad)
        XCTAssertNil(profiles.profile.picture)
        XCTAssertNil(ipad.profiles?.profile.picture)
        XCTAssertFalse(FileManager.default.fileExists(atPath: macFile.path))
        XCTAssertEqual(phone.engine.state.records["personal/" + ProfileImageSyncAdapter.pictureID]?.deleted, true, "A removal is a tombstone")
        XCTAssertNotNil(profiles.profile.banner, "The cover stays")

        // The cover removed on one iPhone goes from the other; the Mac never held it.
        try profiles.setBanner(nil)
        await sync(phone, ipad, mac)
        XCTAssertNil(ipad.profiles?.profile.banner)
        XCTAssertNil(ipad.profiles?.bannerImage())

        // A picture chosen again after a removal comes back everywhere.
        try profiles.setPicture(photo(.systemGreen, width: 700, height: 700))
        await sync(phone, mac, ipad)
        XCTAssertNotNil(mac.account.account.photoFile)
        XCTAssertNotNil(ipad.profiles?.profile.picture)
    }

    func testTheNewerPictureWins() async throws {
        let transport = MemorySyncTransport()
        let phone = device("phone", transport: transport, phone: true), mac = device("mac", transport: transport, phone: false)
        try phone.profiles?.setPicture(photo(.systemPink, width: 600, height: 600))
        await sync(phone, mac)
        // Both change it before either syncs: the change that reaches the account last wins on both.
        try phone.profiles?.setPicture(photo(.systemBlue, width: 600, height: 600))
        try mac.account.setPhoto(jpeg(width: 500, height: 500, red: 1))
        let macPhoto = try XCTUnwrap(mac.account.syncedPhoto() ?? nil)
        await sync(phone, mac, phone)
        XCTAssertEqual(phone.profiles?.syncedImage(cover: false) ?? nil, macPhoto)
        XCTAssertEqual(mac.account.syncedPhoto() ?? nil, macPhoto)
    }

    /// Pictures saved before this build are larger (800 px, and covers 2048 px); they go out
    /// downscaled, once, and the copy another device keeps is never sent back.
    func testALargerPictureFromBeforeGoesOutDownscaledOnce() async throws {
        let transport = MemorySyncTransport()
        let phone = device("phone", transport: transport, phone: true), mac = device("mac", transport: transport, phone: false)
        let profiles = try XCTUnwrap(phone.profiles)
        try profiles.setPicture(photo(.systemPink, width: 600, height: 600))
        let folder = root.appendingPathComponent("phone/Profile", isDirectory: true)
        try jpeg(width: 800, height: 800).write(to: folder.appendingPathComponent(try XCTUnwrap(profiles.profile.picture)))
        await sync(phone, mac)
        let sent = try XCTUnwrap(mac.account.syncedPhoto() ?? nil)
        XCTAssertEqual(try pixels(sent), [600, 600])
        await sync(phone, mac)
        XCTAssertEqual(phone.service.lastResult, nil, "Nothing new to send or take in")
        XCTAssertEqual(mac.service.lastResult, nil)
    }

    // MARK: Privacy

    func testThePictureAndCoverNeverEnterASharedZone() async throws {
        let engine = SyncEngine(transport: MemorySyncTransport(), device: "phone")
        for type in [SyncType.profilePicture, SyncType.profileCover] {
            XCTAssertTrue(SyncType.personalOnly.contains(type))
            for zone in [SyncZone.shared(project: "p"), .profileShare("maya")] {
                XCTAssertThrowsError(try engine.putPayload(jpeg(width: 10, height: 10), id: "x", type: type, zone: zone)) {
                    XCTAssertEqual($0 as? SyncError, .privateInSharedZone(type))
                }
                XCTAssertThrowsError(try engine.delete(id: "x", type: type, zone: zone))
                // One arriving in a shared zone is dropped, never stored or applied.
                XCTAssertFalse(engine.merge(SyncRecord(id: "x", type: type, zone: zone, modified: Date(), device: "other", payload: jpeg(width: 10, height: 10))))
            }
        }
        XCTAssertTrue(engine.state.records.isEmpty)

        // Synced for real, they're only ever in the personal zone.
        let transport = MemorySyncTransport()
        let phone = device("phone", transport: transport, phone: true), mac = device("mac", transport: transport, phone: false)
        try phone.profiles?.setPicture(photo(.systemPink, width: 600, height: 600))
        try phone.profiles?.setBanner(photo(.systemTeal, width: 1600, height: 600))
        await sync(phone, mac)
        let images = [phone, mac].flatMap { $0.engine.state.records.values }.filter { [SyncType.profilePicture, SyncType.profileCover].contains($0.type) }
        XCTAssertEqual(Set(images.map(\.type)), [SyncType.profilePicture, SyncType.profileCover])
        XCTAssertTrue(images.allSatisfy { $0.zone == .personal })
    }

    func testAnythingButAnImageIsNotTakenIn() {
        var written: [Data?] = []
        let adapter = ProfileImageSyncAdapter(slots: [
            .init(id: ProfileImageSyncAdapter.pictureID, type: SyncType.profilePicture, maxSide: 600, read: { .some(nil) }, write: { written.append($0); return true })
        ], isOpen: { true })
        let applied = adapter.apply([ProfileImageSyncAdapter.pictureID: SyncItem(type: SyncType.profilePicture, payload: Data("not an image".utf8)),
                                     ProfileImageSyncAdapter.coverID: SyncItem(type: SyncType.profileCover, payload: jpeg(width: 10, height: 10))])
        XCTAssertTrue(applied.isEmpty)
        XCTAssertTrue(written.isEmpty)
        // A store that isn't open, or an image that can't be read now, is left alone rather than looking removed.
        XCTAssertNil(ProfileImageSyncAdapter(slots: [], isOpen: { false }).snapshot())
        XCTAssertNil(ProfileImageSyncAdapter(slots: [
            .init(id: ProfileImageSyncAdapter.pictureID, type: SyncType.profilePicture, maxSide: 600, read: { nil }, write: { _ in true })
        ], isOpen: { true }).snapshot())
    }

    // MARK: Images

    private func photo(_ color: UIColor, width: CGFloat, height: CGFloat) -> Data {
        let format = UIGraphicsImageRendererFormat.default(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor.white.setFill(); context.fill(CGRect(x: width / 4, y: height / 4, width: width / 8, height: height / 8))
        }.pngData()!
    }
    private func jpeg(width: Int, height: Int, red: CGFloat = 0.2) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: red, green: 0.5, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }
    private func pixels(_ data: Data) throws -> [Int] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return [properties[kCGImagePropertyPixelWidth] as? Int ?? 0, properties[kCGImagePropertyPixelHeight] as? Int ?? 0]
    }
}

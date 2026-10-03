import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import KemoSabeMac

/// Tsukumo's side of your name and picture syncing: the account record and the account photo, which
/// is the iPhone's profile picture (the iPhone side is ios/Tests/ProfileSyncTests.swift). The "iPhone"
/// here is a second account store with the same records, since the iPhone's profile isn't in this app.
@MainActor final class AccountSyncMacTests: XCTestCase {
    private var root: URL!
    private var suites: [String] = []
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AccountSyncMacTests-" + UUID().uuidString, isDirectory: true)
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
    }
    private func defaults() -> UserDefaults {
        let name = "AccountSyncMacTests-" + UUID().uuidString
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }
    struct Device {
        let account: AccountStore
        let engine: SyncEngine
        let service: AccountSyncService
    }
    private func device(_ name: String, transport: SyncTransport) -> Device {
        let engine = SyncEngine(transport: transport, device: name)
        let records = AccountRecords(engine: engine)
        let account = AccountStore(defaults: defaults(), cloud: nil, records: records, photoFolder: root.appendingPathComponent(name, isDirectory: true))
        let service = AccountSyncService(records: { records }, defaults: defaults(), available: true)
        service.attach([AccountSyncAdapter(account: account), ProfileImageSyncAdapter.forAccountPhoto(account)], startSync: false)
        return Device(account: account, engine: engine, service: service)
    }
    private func sync(_ devices: Device...) async {
        for device in devices {
            await device.service.syncNow()
            XCTAssertEqual(device.service.phase, .idle)
        }
    }

    func testANewMacTakesTheAccountsNameAndPicture() async throws {
        let transport = MemorySyncTransport()
        let phone = device("phone", transport: transport)
        phone.account.update { $0.name = "Zach Lichtman"; $0.handle = "zach" }
        try phone.account.setPhoto(jpeg(side: 600))
        await sync(phone)

        let mac = device("mac", transport: transport)
        mac.account.sync()   // what `connectAccount` does at launch, before the first sync
        await sync(mac, phone)
        XCTAssertEqual(mac.account.account.name, "Zach Lichtman")
        XCTAssertEqual(mac.account.displayName, "Zach Lichtman", "not this Mac's user name")
        XCTAssertEqual(phone.account.account.name, "Zach Lichtman", "The Mac's empty name never replaces the account's")
        XCTAssertEqual(mac.account.syncedPhoto() ?? nil, phone.account.syncedPhoto() ?? nil)

        // Edited and removed on the Mac, and the iPhone follows.
        mac.account.update { $0.name = "Zach" }
        try mac.account.setPhoto(nil)
        await sync(mac, phone)
        XCTAssertEqual(phone.account.account.name, "Zach")
        XCTAssertNil(phone.account.account.photoFile)
        XCTAssertTrue(mac.engine.state.records.values.filter { $0.type == SyncType.profilePicture }.allSatisfy { $0.zone == .personal && $0.deleted })
    }

    func testAPictureIsDownscaledToTheSyncedSize() throws {
        let large = jpeg(side: 1200)
        let sent = try XCTUnwrap(ProfileImageSync.downscaled(large, maxSide: ProfileImageSyncAdapter.pictureSide))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(sent as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 600)
        let small = jpeg(side: 400)
        XCTAssertEqual(ProfileImageSync.downscaled(small, maxSide: 600), small, "A JPEG within the size goes as it is")
        XCTAssertNil(ProfileImageSync.downscaled(Data("not an image".utf8), maxSide: 600))
    }

    private func jpeg(side: Int) -> Data {
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: 0.9, green: 0.4, blue: 0.3, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }
}

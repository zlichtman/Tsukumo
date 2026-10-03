import UIKit
import XCTest
@testable import KemoSabe

@MainActor final class ProfileStoreTests: XCTestCase {
    private var folder: URL!
    private var suite: String!
    /// An account of its own, so tests never touch the app's real one.
    private var account: AccountStore!
    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = "ProfileStoreTests-" + UUID().uuidString
        account = AccountStore(defaults: UserDefaults(suiteName: suite)!, cloud: nil)
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
        UserDefaults().removePersistentDomain(forName: suite)
    }
    private func makeStore() -> ProfileStore { ProfileStore(folder: folder, account: account) }

    private func photo(_ color: UIColor, side: CGFloat = 3000) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: side, height: side / 2)).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: side, height: side / 2))
        }.pngData()!
    }

    func testPhotosAreResizedFeaturedAndCleanedUp() throws {
        let store = makeStore()
        try store.addPhoto(photo(.red)); try store.addPhoto(photo(.blue))
        XCTAssertEqual(store.profile.media.count, 2)
        let newest = try XCTUnwrap(store.profile.media.first)
        let full = try XCTUnwrap(store.image(newest))
        XCTAssertEqual(max(full.size.width, full.size.height) * full.scale, 2048, accuracy: 1)
        XCTAssertNotNil(store.thumbnail(newest))
        store.featureInFirstEmptySlot(newest.id)
        store.update { $0.avatar = newest.id }
        XCTAssertEqual(store.profile.featured.first ?? nil, newest.id)
        // Featuring the same item in another slot moves it rather than duplicating it.
        store.feature(newest.id, in: 3)
        XCTAssertEqual(store.profile.featured.compactMap { $0 }, [newest.id])
        XCTAssertEqual(store.profile.featured[3], newest.id)
        store.remove(newest)
        XCTAssertEqual(store.profile.media.count, 1)
        XCTAssertTrue(store.profile.featured.allSatisfy { $0 == nil }, "A deleted photo leaves its featured slot")
        XCTAssertNil(store.profile.avatar, "A deleted profile picture falls back to Kemo")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(newest.file).path))
        // Everything survives a relaunch.
        let reopened = makeStore()
        XCTAssertEqual(reopened.profile, store.profile)
        XCTAssertEqual(reopened.profile.featured.count, SocialProfile.featuredSlots)
    }
    func testProfileFieldsAreBounded() {
        let store = makeStore()
        store.update { profile in
            profile.name = String(repeating: "n", count: 300)
            profile.handle = "Zach Lichtman!🙂.dev_"
            profile.bio = String(repeating: "b", count: 900)
            profile.links = [.init(platform: .instagram, value: "@zach"), .init(platform: .x, value: "  ")]
        }
        XCTAssertEqual(store.profile.name.count, 100)
        XCTAssertEqual(store.profile.handle, "zachlichtman.dev_")
        XCTAssertEqual(store.profile.bio.count, SocialProfile.maxBio)
        XCTAssertEqual(store.profile.links.map(\.platform), [.instagram], "Empty links are dropped")
        XCTAssertEqual(store.profile.links.first?.url?.absoluteString, "https://www.instagram.com/zach")
    }
    func testLinksPointAtEachPlatformsPublicPage() {
        XCTAssertEqual(ProfileLink.Platform.tiktok.url(for: "kemo")?.absoluteString, "https://www.tiktok.com/@kemo")
        XCTAssertEqual(ProfileLink.Platform.youtube.url(for: "@kemo")?.absoluteString, "https://www.youtube.com/@kemo")
        XCTAssertEqual(ProfileLink.Platform.linkedIn.url(for: "zach")?.absoluteString, "https://www.linkedin.com/in/zach")
        XCTAssertEqual(ProfileLink.Platform.website.url(for: "https://kemo.example/me")?.absoluteString, "https://kemo.example/me")
        XCTAssertEqual(ProfileLink.Platform.website.url(for: "kemo.example")?.absoluteString, "https://kemo.example")
        XCTAssertNil(ProfileLink.Platform.x.url(for: " @ "))
    }
    func testSongsKeepTitleArtistAndArtwork() {
        let store = makeStore()
        store.addSong(title: "  ", artist: "Nobody")
        XCTAssertTrue(store.profile.songs.isEmpty)
        let art = UIImage(data: photo(.green, side: 600))
        store.addSong(title: "Espresso", artist: "Sabrina Carpenter", artwork: art)
        let song = try? XCTUnwrap(store.profile.songs.first)
        XCTAssertEqual(song?.title, "Espresso")
        XCTAssertNotNil(song?.artwork.map { UIImage(contentsOfFile: store.url($0).path) } ?? nil)
        if let song { store.removeSong(song) }
        XCTAssertTrue(store.profile.songs.isEmpty)
    }

    // MARK: One identity, and never replacing an unreadable profile

    func testEditingTheBioNeverWritesBackAnOlderName() {
        let store = makeStore()
        store.update { $0.name = "Alice"; $0.handle = "alice" }
        XCTAssertEqual(account.account.name, "Alice")
        // The name changes in Account settings (or on another device)...
        account.update { $0.name = "Alicia" }
        XCTAssertEqual(store.profile.name, "Alicia", "Profile shows the account's name at once")
        // ...and a later bio edit keeps it.
        store.update { $0.bio = "Hello" }
        XCTAssertEqual(account.account.name, "Alicia")
        XCTAssertEqual(makeStore().profile.name, "Alicia")
        XCTAssertEqual(makeStore().profile.bio, "Hello")
    }
    func testANameSavedBeforeAccountsMovesIntoAnUnnamedAccountOnce() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var legacy = SocialProfile(); legacy.name = "Zach"; legacy.handle = "zach"; legacy.bio = "Old bio"
        try JSONEncoder().encode(legacy).write(to: folder.appendingPathComponent("profile.json"))
        let store = makeStore()
        XCTAssertEqual(account.account.name, "Zach")
        XCTAssertEqual(store.profile.handle, "zach")
        // A named account is never overwritten by what a profile file says.
        account.update { $0.name = "Zachary" }
        _ = makeStore()
        XCTAssertEqual(account.account.name, "Zachary")
    }
    func testAnUnreadableProfileIsNeverReplaced() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("profile.json")
        let damaged = Data("{ not a profile".utf8)
        try damaged.write(to: file)
        let store = makeStore()
        XCTAssertTrue(store.loadFailed)
        XCTAssertNotNil(store.error)
        store.update { $0.bio = "This must not be written" }
        XCTAssertThrowsError(try store.addPhoto(photo(.red, side: 200)))
        XCTAssertEqual(try Data(contentsOf: file), damaged, "The file is left exactly as it was")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["profile.json"], "No orphaned media")
    }
    func testAnUnreadableAccountIsSetAsideNotOverwritten() {
        let defaults = UserDefaults(suiteName: suite)!
        let damaged = Data("garbage".utf8)
        defaults.set(damaged, forKey: AccountStore.key)
        let reopened = AccountStore(defaults: defaults, cloud: nil)
        XCTAssertEqual(reopened.account, KemoAccount())
        XCTAssertEqual(defaults.data(forKey: AccountStore.unreadableKey), damaged)
        reopened.update { $0.name = "New" }
        XCTAssertEqual(defaults.data(forKey: AccountStore.unreadableKey), damaged, "The set-aside copy survives later saves")
    }
}

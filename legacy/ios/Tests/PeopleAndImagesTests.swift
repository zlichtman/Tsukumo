import XCTest
import ImageIO
import UniformTypeIdentifiers
#if os(macOS)
@testable import KemoSabeMac
#else
@testable import KemoSabe
#endif

final class PeopleAndImagesTests: XCTestCase {
    func contact(_ name: String = "Alex", id: String = "contact-1", email: String = "alex@example.test") -> PeopleSource {
        .init(kind: .contacts, label: "Apple Contacts", contactIdentifier: id, fields: [.init(kind: .name, value: name), .init(kind: .email, value: email)])
    }
    func testRepeatImportIsStableAndChangedSourceRequiresReview() throws {
        let source = contact(); var directory = PeopleDirectory()
        try directory.upsertContacts([source]); let first = directory.profiles[0]
        try directory.upsertContacts([contact()])
        XCTAssertEqual(directory.profiles.count, 1); XCTAssertEqual(directory.profiles[0].id, first.id)
        XCTAssertEqual(directory.profiles[0].sources[0].id, first.sources[0].id)
        XCTAssertThrowsError(try PeopleDirectory.validateImport(offered: [source], current: [contact("Changed")], permitted: true))
        XCTAssertThrowsError(try PeopleDirectory.validateImport(offered: [source], current: [source], permitted: false))
        XCTAssertThrowsError(try PeopleDirectory.validateImport(offered: [source], current: [], permitted: true))
    }
    func testProfilesAreHiddenUntilContactAuthorizationAndForgetRemovesDerivedFacts() throws {
        var directory = PeopleDirectory(); try directory.upsertContacts([contact()])
        let id = directory.profiles[0].id
        let note = PeopleSource(kind: .note, label: "Lunch", fields: [.init(kind: .name, value: "Alex from work"), .init(kind: .interest, value: "Hiking")], happenedAt: .init(timeIntervalSince1970: 100))
        try directory.add(note, to: id)
        XCTAssertFalse(directory.visible(contactIDs: []).profiles[0].searchable.contains("alex@example.test"))
        XCTAssertTrue(directory.visible(contactIDs: []).profiles[0].searchable.contains("Hiking"))
        directory.removeSource(note.id, personID: id)
        XCTAssertFalse(directory.profiles[0].searchable.contains("Hiking")); XCTAssertNil(directory.profiles[0].lastInteraction)
        try directory.reconcileContacts([], requested: ["contact-1"]); XCTAssertTrue(directory.profiles.isEmpty)
    }
    func testMergesAreExplicitReversibleAndNotBasedOnNames() throws {
        var directory = PeopleDirectory(); try directory.upsertContacts([contact(), contact(id: "contact-2", email: "other@example.test")])
        XCTAssertTrue(directory.duplicates.isEmpty)
        let manual = PeopleSource(kind: .linkedIn, label: "Profile reference", fields: [.init(kind: .name, value: "A different label"), .init(kind: .email, value: "ALEX@example.test")])
        try directory.add(manual, to: nil); XCTAssertEqual(directory.profiles.count, 3); XCTAssertEqual(directory.duplicates.count, 1)
        let target = directory.profiles[0].id, other = directory.profiles[2].id
        try directory.merge(other, into: target); XCTAssertEqual(directory.profiles.count, 2); XCTAssertEqual(directory.profiles[0].sources.count, 2)
        try directory.separate(manual.id, from: target); XCTAssertEqual(directory.profiles.count, 3)
        XCTAssertNil(PeopleDirectory.identityKey(.init(kind: .phone, value: "5551234567 ext 99")))
        XCTAssertNil(PeopleDirectory.identityKey(.init(kind: .phone, value: "5551234567 x99")))
    }
    func testInvalidImportCannotPartiallyMutateProfiles() throws {
        var directory = PeopleDirectory(); let before = directory
        let invalid = PeopleSource(kind: .contacts, label: "Invalid", fields: [.init(kind: .name, value: "Name")])
        XCTAssertThrowsError(try directory.upsertContacts([contact(), invalid])); XCTAssertEqual(directory, before)
        XCTAssertFalse(PeopleSource.safeReference("javascript:alert(1)"))
        XCTAssertFalse(PeopleSource.safeReference("https://user:secret@example.test"))
    }
    func testImagePreparationStripsLocationAndWireEncodingRequiresCapability() throws {
        let image = try fixtureImage()
        let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(image.jpeg as CFData, nil)!, 0, nil) as? [CFString: Any]
        XCTAssertNil(props?[kCGImagePropertyGPSDictionary])
        let exif = props?[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertNil(exif?[kCGImagePropertyExifDateTimeOriginal]); XCTAssertNil(exif?[kCGImagePropertyExifUserComment])
        XCTAssertThrowsError(try ExternalConversationPacket.make(message: "Describe", history: [], images: [image]))
        let packet = try ExternalConversationPacket.make(message: "Describe", history: [], images: [image], supportsImages: true)
        let data = try JSONEncoder().encode(packet)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try XCTUnwrap(decoded["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        XCTAssertEqual(content[0]["text"] as? String, "Describe")
        XCTAssertTrue(((content[1]["image_url"] as? [String: String])?["url"] ?? "").hasPrefix("data:image/jpeg;base64,"))
        XCTAssertThrowsError(try ExternalConversationPacket.make(message: "Next", history: [.init(role: "You", text: "Old", images: [image])]))
        XCTAssertThrowsError(try ExternalConversationPacket.make(message: "Too many", history: [], images: Array(repeating: image, count: 5), supportsImages: true))
    }
    func fixtureImage() throws -> ChatImage {
        let color = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 40, space: color, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        let data = NSMutableData(); let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, context.makeImage()!, [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 1.0, kCGImagePropertyGPSLongitude: 2.0], kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:09:23 04:00:00", kCGImagePropertyExifUserComment: "private metadata"]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest)); return try ChatImage.prepare(data as Data)
    }
    @MainActor func testDeletionIsScopedAndSurvivesReload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let repo = LocalRepository(url: root.appendingPathComponent("state.json"))
        let store = AppStore(repository: repo)
        store.state.messages = [.init(role: "You", text: "Local")]
        store.state.memories = [.init(text: "Saved independently")]
        let api = try APIModelProfile.validated(name: "A", endpoint: "https://example.invalid/v1/chat/completions", model: "test")
        store.state.apiProfiles = [api]; store.state.selectedAPIProfile = api.id; store.state.modelRoute = .api
        store.state.apiConversations = [api.id.uuidString: [.init(role: "You", text: "API")]]
        store.deleteCurrentConversation()
        XCTAssertEqual(store.state.messages.count, 1); XCTAssertTrue(store.state.apiConversations![api.id.uuidString]!.isEmpty)
        store.state.modelRoute = .onDevice; store.newConversation()
        let archive = try XCTUnwrap(store.state.conversationArchives?.first)
        store.deleteArchivedConversation(archive.id)
        let restored = try repo.read()
        XCTAssertTrue(restored.messages.isEmpty); XCTAssertTrue(restored.conversationArchives!.isEmpty)
        XCTAssertEqual(restored.memories.count, 1)
    }
}

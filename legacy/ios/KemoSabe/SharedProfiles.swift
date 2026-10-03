import CloudKit
import Foundation
import Observation
import UIKit

/// A profile someone shared with you: only what they allowed you to see, read-only. Kept in your
/// account's folder with complete file protection, and never part of People's notes or the
/// model's context.
struct SharedProfileCard: Codable, Identifiable, Equatable {
    var zone: SharedZoneID
    var id: String { zone.key }
    var header: SharedProfileHeader?
    var blocks: [SharedProfileBlock] = []
    /// Image record ID → file name in the card's folder.
    var images: [String: String] = [:]
    var token: Data?
    var accepted = Date()
    var updated: Date?

    /// The blocks in the owner's order.
    var ordered: [SharedProfileBlock] {
        guard let header else { return [] }
        return header.blocks.compactMap { kind in blocks.first { $0.kind == kind } }
    }
    var name: String { header?.name.isEmpty == false ? header!.name : "Shared profile" }
    var initials: String {
        let letters = name.split(whereSeparator: \.isWhitespace).prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        return letters.isEmpty ? "?" : letters
    }

    /// Takes in what changed in the owner's zone. Only the shared types are read, each only in
    /// its own shape, so nothing else could ever show here.
    mutating func apply(_ records: [CloudRecord], saveImage: (String, Data) -> String?, removeImage: (String) -> Void) {
        for record in records {
            guard SyncType.profileShareable.contains(record.type) else { continue }
            switch record.type {
            case SyncType.sharedHeader where record.name == ProfileProjection.headerID:
                header = record.deleted ? nil : try? JSONDecoder().decode(SharedProfileHeader.self, from: record.payload)
            case SyncType.sharedBlock:
                blocks.removeAll { ProfileProjection.blockID($0.kind) == record.name }
                if !record.deleted, let block = try? JSONDecoder().decode(SharedProfileBlock.self, from: record.payload),
                   ProfileProjection.blockID(block.kind) == record.name, block.contentKinds == [block.kind] { blocks.append(block) }
            case SyncType.sharedImage where record.name.hasPrefix("image-"):
                if let old = images.removeValue(forKey: record.name) { removeImage(old) }
                if !record.deleted, let data = record.attachment, UIImage(data: data) != nil, let name = saveImage(record.name, data) { images[record.name] = name }
            default: continue
            }
        }
    }
}

/// Profiles shared with you. An invitation link opens KemoSabe, which accepts it here; each
/// profile then refreshes when the app comes forward and when iCloud says it changed.
@MainActor @Observable final class SharedProfilesStore {
    private(set) static var shared = SharedProfilesStore.forCurrentAccount()
    static func reopen() { shared.closed = true; shared = forCurrentAccount() }

    private(set) var cards: [SharedProfileCard] = []
    /// A short line when something needs you.
    private(set) var problem: String?
    /// The profile to show now (one you just accepted).
    var presented: SharedProfileCard.ID?
    private(set) var loadFailed = false

    @ObservationIgnored let database: CloudShareDatabase?
    @ObservationIgnored private let folder: URL
    @ObservationIgnored private let bindingURL: URL?
    @ObservationIgnored private let personalZone: String
    @ObservationIgnored private let unavailableReason: String?
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var subscribed = false
    @ObservationIgnored private var images: [String: UIImage] = [:]

    init(folder: URL, database: CloudShareDatabase?, bindingURL: URL?, personalZone: String, unavailableReason: String? = nil) {
        self.folder = folder; self.database = database; self.bindingURL = bindingURL
        self.personalZone = personalZone; self.unavailableReason = unavailableReason
        load()
    }
    static func forCurrentAccount() -> SharedProfilesStore {
        let account = AccountDirectory.current()
        let folder = AccountDirectory.currentFolder.appendingPathComponent("SharedProfiles", isDirectory: true)
        let personal = "personal-" + account.id
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing"), arguments.contains("--isolated-fixture") || arguments.contains("--sharing-stub") {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("SharedProfilesUITests/\(UUID().uuidString)", isDirectory: true)
            let store = SharedProfilesStore(folder: temporary, database: arguments.contains("--sharing-stub") ? StubShareDatabase.shared : nil,
                                            bindingURL: nil, personalZone: personal)
            if arguments.contains("--shared-profile-sample") { store.seedSample() }
            return store
        }
        #endif
        guard AccountSyncService.availableInBuild, !AccountDirectory.isTestHost else {
            return SharedProfilesStore(folder: folder, database: nil, bindingURL: nil, personalZone: personal, unavailableReason: ProfileSharingStore.notSetUp)
        }
        guard account.kind == .apple else {
            return SharedProfilesStore(folder: folder, database: nil, bindingURL: nil, personalZone: personal,
                                       unavailableReason: "Sign in with Apple, then open the invitation again.")
        }
        return SharedProfilesStore(folder: folder, database: CKShareDatabase(),
                                   bindingURL: AccountDirectory.currentFolder.appendingPathComponent("Sync/icloud.json"), personalZone: personal)
    }

    // MARK: Files

    private var indexURL: URL { folder.appendingPathComponent("profiles.json") }
    private func cardFolder(_ card: SharedProfileCard.ID) -> URL { folder.appendingPathComponent(card, isDirectory: true) }
    private func load() {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return }
        do { cards = try JSONDecoder().decode([SharedProfileCard].self, from: Data(contentsOf: indexURL)); loadFailed = false }
        catch { loadFailed = true; problem = "Profiles shared with you couldn't be opened. Nothing was changed." }
    }
    private func save() {
        guard !closed, !loadFailed else { return }
        do {
            try AccountDirectory.checkWrite(to: indexURL)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(cards).write(to: indexURL, options: [.atomic, .completeFileProtection])
        } catch { problem = "Profiles shared with you couldn't be saved." }
    }
    func card(_ id: SharedProfileCard.ID?) -> SharedProfileCard? { id.flatMap { id in cards.first { $0.id == id } } }
    func image(_ card: SharedProfileCard, _ record: String?) -> UIImage? {
        guard let record, let name = card.images[record] else { return nil }
        let key = card.id + "/" + name
        if let cached = images[key] { return cached }
        let image = UIImage(contentsOfFile: cardFolder(card.id).appendingPathComponent(name).path)
        images[key] = image
        return image
    }

    // MARK: Accepting, refreshing, removing

    /// An invitation link was opened on this iPhone.
    func accept(_ metadata: CKShare.Metadata) async { await accept(ShareAcceptance(metadata: metadata)) }
    func accept(_ acceptance: ShareAcceptance) async {
        guard acceptance.isProfile else { return }
        guard let database, !loadFailed, !closed else { problem = unavailableReason ?? ProfileSharingStore.notSetUp; return }
        problem = nil
        do {
            try await ShareAccountCheck.verify(database, bindingURL: bindingURL, personalZone: personalZone)
            let zone = try await database.accept(acceptance)
            if !cards.contains(where: { $0.zone == zone }) { cards.append(SharedProfileCard(zone: zone)); save() }
            await refresh(zone)
            presented = zone.key
            await subscribe()
        } catch { problem = "That invitation couldn't be opened. " + ProfileSharingStore.message(error) }
    }
    /// Brings every shared profile up to date, and finds ones you accepted on another device.
    func refresh() async {
        guard let database, !loadFailed, !closed, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            try await ShareAccountCheck.verify(database, bindingURL: bindingURL, personalZone: personalZone)
            for zone in try await database.sharedZones() where zone.zone.hasPrefix("profile-") && !cards.contains(where: { $0.zone == zone }) {
                cards.append(SharedProfileCard(zone: zone)); save()
            }
        } catch { return }
        for card in cards { await refresh(card.zone) }
        if !cards.isEmpty { await subscribe() }
    }
    /// One profile: its changes since last time. It goes away only when iCloud says the share is
    /// gone; being offline or a failed fetch keeps what you have.
    func refresh(_ zone: SharedZoneID) async {
        guard let database, !closed else { return }
        guard let index = cards.firstIndex(where: { $0.zone == zone }) else { return }
        var card = cards[index]
        do {
            var restarted = false
            while true {
                let changes: CloudChanges
                do { changes = try await database.sharedChanges(zone, since: card.token) }
                catch CloudFailure.tokenExpired where !restarted {
                    restarted = true; card.token = nil; continue
                }
                let folder = cardFolder(card.id)
                card.apply(changes.records, saveImage: { id, data in
                    let name = id + ".jpg"
                    do {
                        try AccountDirectory.checkWrite(to: folder)
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        try data.write(to: folder.appendingPathComponent(name), options: [.atomic, .completeFileProtection])
                        return name
                    } catch { return nil }
                }, removeImage: { name in try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) })
                card.token = changes.token
                if !changes.moreComing { break }
            }
            card.updated = Date()
            images = images.filter { !$0.key.hasPrefix(card.id + "/") }
            guard let current = cards.firstIndex(where: { $0.zone == zone }) else { return }
            cards[current] = card; save()
        } catch CloudFailure.zoneNotFound {
            forget(card.id)
        } catch {}
    }
    /// Removes a profile shared with you: you leave the share, and its copy here is deleted.
    @discardableResult func remove(_ id: SharedProfileCard.ID) async -> Bool {
        guard let card = card(id) else { return true }
        if let database {
            do { try await database.leave(card.zone) }
            catch { problem = "That profile couldn't be removed. " + ProfileSharingStore.message(error); return false }
        }
        forget(id)
        return true
    }
    private func forget(_ id: SharedProfileCard.ID) {
        cards.removeAll { $0.id == id }
        images = images.filter { !$0.key.hasPrefix(id + "/") }
        try? FileManager.default.removeItem(at: cardFolder(id))
        if presented == id { presented = nil }
        save()
    }
    private func subscribe() async {
        guard let database, !subscribed else { return }
        if (try? await database.subscribeToShared()) != nil { subscribed = true }
    }

    #if DEBUG
    /// UI tests: one profile shared with you, with a picture-less header and three blocks.
    func seedSample() {
        var card = SharedProfileCard(zone: SharedZoneID(zone: "profile-sample", owner: "sample-owner"))
        card.header = SharedProfileHeader(name: "Riley Park", handle: "riley", headline: "Product designer at Northwind Labs", bio: "Film photos and synths.",
                                          accent: "#3F84C4", picture: nil, cover: nil, blocks: [.work, .personal, .links])
        var work = SharedProfileBlock(kind: .work)
        work.work = SharedWork(about: nil, experience: [WorkEntry(title: "Product Designer", company: "Northwind Labs", start: ProfileMonth(year: 2022, month: 3))],
                               skills: ["Prototyping", "Figma"])
        var personal = SharedProfileBlock(kind: .personal)
        personal.personal = SharedPersonal(interests: ["Film", "Synths"], facts: [ProfileFact(label: "Lives in", value: "Oakland")])
        var links = SharedProfileBlock(kind: .links)
        links.links = [ProfileLink(platform: .website, value: "riley.example")]
        card.blocks = [work, personal, links]
        card.updated = Date()
        cards = [card]
    }
    #endif
}

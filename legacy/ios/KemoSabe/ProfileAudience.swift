import CryptoKit
import Foundation

// Who sees what of your profile (September 27, 2026; design/ACCOUNTS-AND-PROFILES.md, "Sharing
// your profile"). You choose people from your contacts ("Your people"), mark some as Close
// friends, and give every block an audience. Each person you share with gets their own iCloud
// zone holding a projection of your profile: the header, and only the blocks they may see.

/// Who can see a block of your profile.
enum ProfileAudience: String, Codable, CaseIterable, Identifiable, Sendable {
    case people, close, onlyYou
    var id: String { rawValue }
    var title: String {
        switch self { case .people: "Your people"; case .close: "Close friends"; case .onlyYou: "Only you" }
    }
    var symbol: String {
        switch self { case .people: "person.2.fill"; case .close: "star.fill"; case .onlyYou: "lock.fill" }
    }
}

/// Someone you share your profile with. Only what's needed is kept: their name, and the email
/// addresses and phone numbers their iCloud account is looked up by.
struct SharingMember: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var emails: [String] = []
    var phones: [String] = []
    /// The address their invitation goes to; nil uses the first email, then the first phone.
    var address: String?
    var close = false
    /// Blocks they may see though their audience can't.
    var allow: [ProfileBlockKind] = []
    /// Blocks they may not see though their audience can.
    var deny: [ProfileBlockKind] = []
    var added = Date()

    var lookup: String? { address.flatMap { addresses.contains($0) ? $0 : nil } ?? addresses.first }
    var addresses: [String] { emails + phones }
    var initials: String {
        let letters = name.split(whereSeparator: \.isWhitespace).prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        return letters.isEmpty ? "?" : letters
    }
    /// The same keys People uses to find duplicates: an exact email or phone number.
    var identityKeys: Set<String> {
        Set(emails.compactMap { PeopleDirectory.identityKey(.init(kind: .email, value: $0)) }
            + phones.compactMap { PeopleDirectory.identityKey(.init(kind: .phone, value: $0)) })
    }
    enum Override: String, CaseIterable, Identifiable, Sendable {
        /// Whatever their audience sees.
        case audience, show, hide
        var id: String { rawValue }
    }
    func override(for kind: ProfileBlockKind) -> Override {
        deny.contains(kind) ? .hide : allow.contains(kind) ? .show : .audience
    }
    mutating func set(_ override: Override, for kind: ProfileBlockKind) {
        allow.removeAll { $0 == kind }; deny.removeAll { $0 == kind }
        switch override {
        case .audience: break
        case .show: allow.append(kind)
        case .hide: deny.append(kind)
        }
    }
    var hasOverrides: Bool { !allow.isEmpty || !deny.isEmpty }
    static let maxAddresses = 6

    /// Trims and caps what came from a contact.
    static func cleaned(name: String, emails: [String], phones: [String]) -> SharingMember? {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        func unique(_ list: [String], _ key: (String) -> String) -> [String] {
            var seen = Set<String>()
            return Array(list.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)) }
                .filter { !$0.isEmpty && seen.insert(key($0)).inserted }.prefix(maxAddresses))
        }
        let emails = unique(emails.filter { $0.contains("@") }) { $0.lowercased() }
        let phones = unique(phones.filter { $0.contains(where: \.isNumber) }) { $0.filter(\.isNumber) }
        guard !emails.isEmpty || !phones.isEmpty else { return nil }
        return SharingMember(name: name.isEmpty ? (emails.first ?? phones[0]) : name, emails: emails, phones: phones)
    }
}

/// Everyone you share with, and whether you've confirmed who sees what.
struct ProfileSharingSettings: Codable, Equatable, Sendable {
    var members: [SharingMember] = []
    /// Set once you've confirmed the suggested audiences, the first time you share.
    var confirmedDefaults = false
    static let maxMembers = 100
    var closeCount: Int { members.filter(\.close).count }
}

enum ProfileSharingDefaults {
    /// What's suggested the first time you share, and confirmed once: your work, writing, and
    /// links for your people; photos, music, the personal block, and the watch game for close friends.
    static let suggested: [ProfileBlockKind: ProfileAudience] = [
        .work: .people, .links: .people, .writing: .people,
        .photos: .close, .music: .close, .personal: .close, .kemo: .close,
    ]
}

// MARK: The projection

/// The header anyone you share with sees: your name, handle, picture, cover, accent, headline, and
/// bio, and the order of the blocks they may see.
struct SharedProfileHeader: Codable, Equatable, Sendable {
    var name: String
    var handle: String
    var headline: String?
    var bio: String
    var accent: String?
    /// Image record IDs in the same zone.
    var picture: String?
    var cover: String?
    var blocks: [ProfileBlockKind]
    enum CodingKeys: String, CodingKey, CaseIterable { case name, handle, headline, bio, accent, picture, cover, blocks }
}

/// One block as a person you share with sees it. Exactly one content field is set, the one for
/// its kind (`ProfileProjection.validate`).
struct SharedProfileBlock: Codable, Equatable, Sendable {
    var kind: ProfileBlockKind
    var style: ProfileBlockStyle?
    var posts: [SharedPost]?
    var music: SharedMusic?
    var work: SharedWork?
    var writing: SharedWriting?
    var personal: SharedPersonal?
    var links: [ProfileLink]?
    var game: SharedGame?
    enum CodingKeys: String, CodingKey, CaseIterable { case kind, style, posts, music, work, writing, personal, links, game }

    var contentKinds: [ProfileBlockKind] {
        var kinds: [ProfileBlockKind] = []
        if posts != nil { kinds.append(.photos) }
        if music != nil { kinds.append(.music) }
        if work != nil { kinds.append(.work) }
        if writing != nil { kinds.append(.writing) }
        if personal != nil { kinds.append(.personal) }
        if links != nil { kinds.append(.links) }
        if game != nil { kinds.append(.kemo) }
        return kinds
    }
}
struct SharedPost: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    /// The image record in the same zone (a video shares its still).
    var image: String
    var caption: String?
    var day: Date
    var video = false
    var pinned = false
}
struct SharedMusic: Codable, Equatable, Sendable {
    struct Artist: Codable, Equatable, Sendable { var name: String; var plays: Int }
    struct Song: Codable, Equatable, Sendable { var title: String; var artist: String; var plays: Int }
    struct Genre: Codable, Equatable, Sendable { var name: String; var share: Double }
    struct Pick: Codable, Equatable, Sendable { var title: String; var artist: String; var pick: ProfileSong.Pick? }
    var topArtists: [Artist] = []
    var topSongs: [Song] = []
    var topGenres: [Genre] = []
    var onRepeat: [Song] = []
    var totalPlays = 0
    var songsPlayed = 0
    var picks: [Pick] = []
}
struct SharedWork: Codable, Equatable, Sendable {
    var about: String?
    var experience: [WorkEntry] = []
    var education: [EducationEntry] = []
    var skills: [String] = []
    var certifications: [CertificationEntry] = []
    var languages: [LanguageEntry] = []
}
struct SharedWriting: Codable, Equatable, Sendable {
    var title: String?
    var address: String
    var entries: [BlogEntry] = []
}
struct SharedPersonal: Codable, Equatable, Sendable {
    var interests: [String] = []
    var facts: [ProfileFact] = []
}
/// The watch game's numbers. Your companion's name and look aren't shared: the companion never
/// leaves your own devices.
struct SharedGame: Codable, Equatable, Sendable {
    var level: Int
    var xp: Int
    var streak: Int
    var starved: Int
}
/// An image record's small payload; the image itself travels as its asset.
struct SharedImageInfo: Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable { case picture, cover, post }
    var role: Role
}

/// One record for a person's zone: what `ProfileProjection` builds and the allow-list checks.
struct SharedRecord: Equatable, Sendable {
    var id: String
    var type: String
    var payload: Data
}

/// Where an image record's pixels come from on this iPhone, and how large they may be.
struct SharedImageSource: Equatable, Sendable {
    var file: URL
    var maxSide: Int
}

/// Builds what one person may see of your profile, and checks it. Everything that goes into a
/// profile share is made here from explicit fields, so nothing else of yours (chats, memories,
/// People notes, the journal, docs, or the companion) can find its way in.
enum ProfileProjection {
    static let headerID = "header"
    static func blockID(_ kind: ProfileBlockKind) -> String { "block-" + kind.rawValue }
    /// The newest posts shared, after the pinned one.
    static let maxPosts = 24
    static let postSide = 1280, pictureSide = 480, coverSide = 1280, stillSide = 480

    /// The blocks this person may see, in your order. A hidden block is seen by no one; a block
    /// they're kept from never shows, whatever its audience.
    static func visibleBlocks(for member: SharingMember, in profile: SocialProfile) -> [ProfileBlockKind] {
        profile.blocks.filter { block in
            guard !block.hidden, !member.deny.contains(block.kind) else { return false }
            if member.allow.contains(block.kind) { return true }
            switch block.audience ?? .onlyYou {
            case .people: return true
            case .close: return member.close
            case .onlyYou: return false
            }
        }.map(\.kind)
    }

    /// Everything that goes in this person's zone, by record ID, plus where each image's pixels come from.
    static func records(for member: SharingMember, profile: SocialProfile, pet: WatchLink.PetSummary?,
                        file: (String) -> URL) -> (records: [String: SharedRecord], images: [String: SharedImageSource]) {
        let visible = visibleBlocks(for: member, in: profile)
        var records: [String: SharedRecord] = [:], images: [String: SharedImageSource] = [:]
        func image(_ name: String, role: SharedImageInfo.Role, side: Int) -> String {
            let id = imageID(name, side: side)
            images[id] = SharedImageSource(file: file(name), maxSide: side)
            if let payload = try? SyncEngine.encode(SharedImageInfo(role: role)) {
                records[id] = SharedRecord(id: id, type: SyncType.sharedImage, payload: payload)
            }
            return id
        }
        var blocks: [ProfileBlockKind] = []
        for kind in visible {
            guard let block = block(kind, profile: profile, pet: pet, image: image),
                  let payload = try? SyncEngine.encode(block) else { continue }
            records[blockID(kind)] = SharedRecord(id: blockID(kind), type: SyncType.sharedBlock, payload: payload)
            blocks.append(kind)
        }
        let header = SharedProfileHeader(name: profile.name, handle: profile.handle, headline: profile.headline, bio: profile.bio,
                                         accent: profile.accent,
                                         picture: profile.picture.map { image($0, role: .picture, side: pictureSide) },
                                         cover: profile.banner.map { image($0, role: .cover, side: coverSide) },
                                         blocks: blocks)
        if let payload = try? SyncEngine.encode(header) {
            records[headerID] = SharedRecord(id: headerID, type: SyncType.sharedHeader, payload: payload)
        }
        return (records, images)
    }

    /// A stable ID for an image at a size: a new picture is a new file, so a new record.
    static func imageID(_ name: String, side: Int) -> String {
        "image-" + SHA256.hash(data: Data((name + "@" + String(side)).utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static func block(_ kind: ProfileBlockKind, profile: SocialProfile, pet: WatchLink.PetSummary?,
                              image: (String, SharedImageInfo.Role, Int) -> String) -> SharedProfileBlock? {
        var block = SharedProfileBlock(kind: kind, style: profile.block(kind).style)
        switch kind {
        case .photos:
            block.posts = profile.orderedMedia.prefix(maxPosts).map { media in
                let still = media.kind == .video
                return SharedPost(id: media.id, image: image(still ? media.thumbnail : media.file, .post, still ? stillSide : postSide),
                                  caption: media.caption, day: media.day, video: still, pinned: media.id == profile.pinned)
            }
        case .music:
            var music = SharedMusic()
            if let stats = profile.musicStats {
                music.topArtists = stats.topArtists.map { .init(name: $0.name, plays: $0.plays) }
                music.topSongs = stats.topSongs.map { .init(title: $0.title, artist: $0.artist, plays: $0.plays) }
                music.topGenres = stats.topGenres.map { .init(name: $0.name, share: $0.share) }
                music.onRepeat = stats.onRepeat.map { .init(title: $0.title, artist: $0.artist, plays: $0.plays) }
                music.totalPlays = stats.totalPlays; music.songsPlayed = stats.songsPlayed
            }
            music.picks = profile.songs.map { .init(title: $0.title, artist: $0.artist, pick: $0.pick) }
            block.music = music
        case .work:
            block.work = SharedWork(about: profile.about, experience: profile.experience, education: profile.education, skills: profile.skills,
                                    certifications: profile.certifications, languages: profile.languages)
        case .writing:
            guard let blog = profile.blog else { block.writing = nil; return nil }
            block.writing = SharedWriting(title: blog.title, address: blog.address, entries: blog.entries)
        case .personal:
            block.personal = SharedPersonal(interests: profile.interests, facts: profile.facts)
        case .links:
            block.links = profile.links
        case .kemo:
            guard let pet else { return nil }
            block.game = SharedGame(level: pet.level, xp: pet.xp, streak: pet.streak, starved: pet.starved)
        }
        return block
    }

    // MARK: The allow-list

    enum Violation: Error, Equatable {
        /// A type that never goes in a profile share (a chat, a memory, your whole profile…).
        case type(String)
        /// A payload that isn't exactly one of the shared shapes.
        case payload(String)
        /// A block this person may not see, or a block carrying another block's content.
        case block(String)
    }
    /// Checks every record before it's queued for a person's zone: an allowed type, a payload that
    /// decodes strictly as that type's shape, and a block they may see with only its own content.
    static func validate(_ records: [String: SharedRecord], for member: SharingMember, in profile: SocialProfile) throws {
        let visible = Set(visibleBlocks(for: member, in: profile))
        for (id, record) in records {
            guard id == record.id else { throw Violation.payload(id) }
            guard SyncType.profileShareable.contains(record.type), !SyncType.personalOnly.contains(record.type) else { throw Violation.type(record.type) }
            let decoder = JSONDecoder()
            switch record.type {
            case SyncType.sharedHeader:
                guard id == headerID, let header = try? decoder.decode(SharedProfileHeader.self, from: record.payload) else { throw Violation.payload(id) }
                guard Set(header.blocks).isSubset(of: visible) else { throw Violation.block(id) }
                try strictKeys(record.payload, allowed: SharedProfileHeader.CodingKeys.allCases.map(\.stringValue), id: id)
            case SyncType.sharedBlock:
                guard let block = try? decoder.decode(SharedProfileBlock.self, from: record.payload), id == blockID(block.kind) else { throw Violation.payload(id) }
                guard visible.contains(block.kind), block.contentKinds == [block.kind] else { throw Violation.block(id) }
                try strictKeys(record.payload, allowed: SharedProfileBlock.CodingKeys.allCases.map(\.stringValue), id: id)
            case SyncType.sharedImage:
                guard id.hasPrefix("image-"), (try? decoder.decode(SharedImageInfo.self, from: record.payload)) != nil else { throw Violation.payload(id) }
                try strictKeys(record.payload, allowed: ["role"], id: id)
            default: throw Violation.type(record.type)
            }
        }
    }
    /// A payload's top-level keys must all be ones the shared shape names, so nothing extra rides along.
    private static func strictKeys(_ payload: Data, allowed: [String], id: String) throws {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              Set(object.keys).isSubset(of: Set(allowed)) else { throw Violation.payload(id) }
    }
}

import UIKit
import XCTest
@testable import KemoSabe

/// The rethought profile (design/PROFILE-REDESIGN.md): blocks you order, style, and hide; an accent
/// and a pinned post; migration from sections; LinkedIn's real export columns; and music stats
/// computed from a library's own play counts.
@MainActor final class ProfileRedesignTests: XCTestCase {
    private var folder: URL!
    private var suite: String!
    private var account: AccountStore!
    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = "ProfileRedesignTests-" + UUID().uuidString
        account = AccountStore(defaults: UserDefaults(suiteName: suite)!, cloud: nil)
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
        UserDefaults().removePersistentDomain(forName: suite)
    }
    private func makeStore() -> ProfileStore { ProfileStore(folder: folder, account: account) }
    private func photo(_ color: UIColor) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 200, height: 200)).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        }.pngData()!
    }

    // MARK: Blocks

    func testANewProfileHasEveryBlockInTheDefaultOrder() {
        let profile = makeStore().profile
        XCTAssertEqual(profile.blocks.map(\.kind), [.photos, .music, .work, .writing, .personal, .links, .kemo])
        XCTAssertTrue(profile.blocks.allSatisfy { !$0.hidden })
        XCTAssertEqual(profile.style(.photos), .grid)
        XCTAssertEqual(profile.style(.music), .topArtists)
        XCTAssertEqual(profile.style(.work), .full)
    }
    func testBlocksMoveHideAndRestyleAndSurviveARelaunch() {
        let store = makeStore()
        store.moveBlock(.work, by: -2)
        XCTAssertEqual(store.profile.blocks.prefix(3).map(\.kind), [.work, .photos, .music])
        store.moveBlock(.work, by: -5)
        XCTAssertEqual(store.profile.blocks.first?.kind, .work, "Moving past the top stops at the top")
        store.moveBlock(.kemo, to: .photos)
        XCTAssertEqual(store.profile.blocks.map(\.kind), [.work, .kemo, .photos, .music, .writing, .personal, .links], "A drag puts it where the target was")
        store.setHidden(.links, true)
        store.setStyle(.music, .onRepeat)
        store.setStyle(.music, .grid)
        XCTAssertEqual(store.profile.style(.music), .onRepeat, "A style that isn't the block's is refused")
        store.setAccent("#3F84C4")
        store.setAccent("not a color")
        XCTAssertNil(store.profile.accent, "An invalid accent goes back to the theme's")
        store.setAccent("#3F84C4")
        let reopened = makeStore().profile
        XCTAssertEqual(reopened.blocks, store.profile.blocks)
        XCTAssertFalse(reopened.shows(.links))
        XCTAssertEqual(reopened.style(.music), .onRepeat)
        XCTAssertEqual(reopened.accent, "#3F84C4")
        XCTAssertEqual(reopened.hiddenSections, [.social], "An older build hides Social for a hidden Links block")
    }
    func testHidingABlockKeepsItsContents() {
        let store = makeStore()
        store.update { $0.experience = [WorkEntry(title: "Designer", company: "Kemo")]; $0.skills = ["Figma"] }
        store.setHidden(.work, true)
        XCTAssertEqual(makeStore().profile.experience.count, 1)
        store.setHidden(.work, false)
        XCTAssertEqual(store.profile.skills, ["Figma"])
    }
    func testPinnedPostLeadsAndLeavesWithItsPost() throws {
        let store = makeStore()
        let first = try store.addPhoto(photo(.red)), second = try store.addPhoto(photo(.blue))
        XCTAssertEqual(store.profile.orderedMedia.first?.id, second, "Newest first")
        store.pin(first)
        XCTAssertEqual(store.profile.orderedMedia.map(\.id), [first, second], "The pinned post leads")
        XCTAssertEqual(makeStore().profile.pinned, first)
        store.remove(try XCTUnwrap(store.profile.media.first { $0.id == first }))
        XCTAssertNil(store.profile.pinned, "Deleting the pinned post unpins it")
    }

    // MARK: Migration

    /// A profile saved with sections (September 25, before blocks) keeps what it hid, its posts'
    /// feed or grid setting, and everything else.
    func testASectionsProfileBecomesBlocksWithoutLosingAnything() throws {
        let legacy = #"""
        {"name":"Zach","handle":"zach","bio":"Builds Kemo","headline":"iOS engineer",
         "featured":[null,null,null,null,null,null],"hiddenSections":["social","personal"],
         "media":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":"photo","file":"a.jpg","thumbnail":"a-thumb.jpg","added":780000000,"caption":"Hi"}],
         "songs":[{"id":"7F9619FF-8B86-D011-B42D-00C04FC964FF","title":"Song","artist":"Artist"}],
         "skills":["Swift"],"interests":["Film"],
         "links":[{"id":"8F9619FF-8B86-D011-B42D-00C04FC964FF","platform":"instagram","value":"zach"}]}
        """#
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("profile.json")
        try Data(legacy.utf8).write(to: file)
        let key = ProfileStore.legacyLayoutKey, saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set("Grid", forKey: key)

        let store = makeStore()
        XCTAssertFalse(store.loadFailed)
        let profile = store.profile
        XCTAssertFalse(profile.shows(.links), "Social became Links")
        XCTAssertFalse(profile.shows(.music), "Personal held music")
        XCTAssertFalse(profile.shows(.personal))
        XCTAssertTrue(profile.shows(.work) && profile.shows(.photos) && profile.shows(.writing) && profile.shows(.kemo))
        XCTAssertEqual(profile.style(.photos), .grid, "The old feed or grid setting carries over")
        XCTAssertEqual(profile.media.first?.caption, "Hi")
        XCTAssertEqual(profile.songs.first?.title, "Song")
        XCTAssertNil(profile.songs.first?.pick)
        XCTAssertEqual(profile.skills, ["Swift"]); XCTAssertEqual(profile.interests, ["Film"])
        XCTAssertEqual(try Data(contentsOf: file), Data(legacy.utf8), "Opening doesn't rewrite the file")
        // The first edit saves blocks; the grid stays even if the old setting changes later.
        store.update { $0.bio = "Still builds Kemo" }
        UserDefaults.standard.set("Feed", forKey: key)
        let reopened = makeStore().profile
        XCTAssertEqual(reopened.style(.photos), .grid)
        XCTAssertEqual(reopened.featured.count, SocialProfile.featuredSlots, "Featured slots are kept in the file")
        XCTAssertTrue(SocialProfile.hasBlocks(try Data(contentsOf: file)))
    }
    func testAProfileWithoutTheOldSettingUsesTheOldFeedDefault() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"name":"Zach","bio":"hi"}"#.utf8).write(to: folder.appendingPathComponent("profile.json"))
        let key = ProfileStore.legacyLayoutKey, saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(makeStore().profile.style(.photos), .feed)
    }
    func testBlocksAndStylesFromALaterBuildAreDroppedNotFatal() throws {
        let json = ##"{"blocks":[{"kind":"reviews"},{"kind":"music","style":"wrapped"},{"kind":"work","hidden":true,"style":"summary"}],"accent":"#12"}"##
        let profile = try JSONDecoder().decode(SocialProfile.self, from: Data(json.utf8))
        XCTAssertEqual(profile.blocks.prefix(2).map(\.kind), [.music, .work])
        XCTAssertEqual(profile.blocks.count, ProfileBlockKind.allCases.count)
        XCTAssertNil(profile.block(.music).style)
        XCTAssertEqual(profile.style(.work), .summary)
        XCTAssertFalse(profile.shows(.work))
        var bounded = profile; ProfileStore.bound(&bounded)
        XCTAssertNil(bounded.accent)
    }
    /// Another device's profile carries the layout; an older device's (without it) changes nothing.
    func testSyncCarriesTheLayoutAndAnOlderDeviceNeverClearsIt() throws {
        let store = makeStore()
        store.update { $0.about = "About me"; $0.certifications = [CertificationEntry(name: "CPACC", authority: "IAAP")] }
        store.setHidden(.writing, true); store.setAccent("#8E5BA8")
        let sent = try JSONDecoder().decode(ProfileStore.Synced.self, from: JSONEncoder().encode(store.synced))
        XCTAssertEqual(sent.blocks, store.profile.blocks)
        XCTAssertEqual(sent.accent, "#8E5BA8")

        let older = #"{"bio":"From an older iPhone","links":[],"headline":null}"#
        XCTAssertTrue(store.applySynced(try JSONDecoder().decode(ProfileStore.Synced.self, from: Data(older.utf8))))
        XCTAssertEqual(store.profile.bio, "From an older iPhone")
        XCTAssertFalse(store.profile.shows(.writing), "An older device's record keeps the layout")
        XCTAssertEqual(store.profile.accent, "#8E5BA8")
        XCTAssertEqual(store.profile.about, "About me")
        XCTAssertEqual(store.profile.certifications.count, 1)

        var cleared = sent; cleared.accent = ""; cleared.about = ""; cleared.blocks = ProfileBlockKind.defaultLayout
        XCTAssertTrue(store.applySynced(cleared))
        XCTAssertNil(store.profile.accent, "A newer device can go back to the theme's accent")
        XCTAssertNil(store.profile.about)
        XCTAssertTrue(store.profile.shows(.writing))
    }

    // MARK: LinkedIn

    /// The columns of LinkedIn's "Get a copy of your data" export, as the files write them.
    func testLinkedInExportColumnsMapToTheWorkBlock() throws {
        let profile = """
        First Name,Last Name,Maiden Name,Address,Birth Date,Headline,Summary,Industry,Zip Code,Geo Location,Twitter Handles,Websites,Instant Messengers
        Avery,Chen,,,,Product designer at Kemo Labs,"I design calm software.
        Eight years in mobile.",Design Services,,San Francisco Bay Area,,,
        """
        let positions = """
        Company Name,Title,Description,Location,Started On,Finished On
        Kemo Labs,Lead Product Designer,Lead design.,"San Francisco, California, United States",Feb 2024,
        Kemo Labs,Product Designer,,"San Francisco, California, United States",Jun 2021,Jan 2024
        Tidepool Studio,Designer,,,Sep 2018,May 2021
        """
        let education = """
        School Name,Start Date,End Date,Notes,Degree Name,Activities
        Rhode Island School of Design,2014,2018,,"BFA, Graphic Design",Film club
        """
        let certifications = """
        Name,Url,Authority,Started On,Finished On,License Number
        Certified Accessibility Professional,https://www.credly.com/badges/abc,IAAP,Apr 2023,,123
        Old Cert,http://insecure.example/cert,Somebody,Jan 2019,Jan 2021,
        """
        let languages = """
        Name,Proficiency
        English,Native or bilingual proficiency
        Mandarin,Professional working proficiency
        """
        let skills = "Name\nFigma\nPrototyping\n"
        let result = LinkedInImport.parse([languages, certifications, skills, profile, education, positions])
        XCTAssertEqual(result.headline, "Product designer at Kemo Labs")
        XCTAssertEqual(result.summary, "I design calm software.\nEight years in mobile.")
        XCTAssertEqual(result.location, "San Francisco Bay Area")
        XCTAssertEqual(result.experience.map(\.title), ["Lead Product Designer", "Product Designer", "Designer"])
        XCTAssertEqual(result.experience[0].location, "San Francisco, California, United States")
        XCTAssertNil(result.experience[0].end)
        XCTAssertEqual(result.education.first?.degree, "BFA, Graphic Design")
        XCTAssertEqual(result.education.first?.notes, "Film club")
        XCTAssertEqual(result.certifications.map(\.name), ["Certified Accessibility Professional", "Old Cert"], "Newest first")
        XCTAssertEqual(result.certifications[0].authority, "IAAP")
        XCTAssertEqual(result.certifications[0].issued, ProfileMonth(year: 2023, month: 4))
        XCTAssertEqual(result.certifications[0].url?.host, "www.credly.com")
        XCTAssertNil(result.certifications[1].link, "Only https credential links are kept")
        XCTAssertEqual(result.certifications[1].expires, ProfileMonth(year: 2021, month: 1))
        XCTAssertEqual(result.languages.map(\.name), ["English", "Mandarin"])
        XCTAssertEqual(result.languages[0].proficiency, "Native or bilingual proficiency")
        XCTAssertEqual(result.skills, ["Figma", "Prototyping"], "Languages (Name, Proficiency) never read as skills")
    }
    func testLinkedInReadsCertificationsAndLanguagesFromTheFolder() throws {
        let export = folder.appendingPathComponent("Complete_LinkedInDataExport", isDirectory: true)
        try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
        try "Name,Url,Authority,Started On,Finished On,License Number\nCPACC,,IAAP,2023,,\n".write(to: export.appendingPathComponent("Certifications.csv"), atomically: true, encoding: .utf8)
        try "Name,Proficiency\nEnglish,Native\n".write(to: export.appendingPathComponent("Languages.csv"), atomically: true, encoding: .utf8)
        try "First Name,Last Name,Email Address\nA,B,a@b.example\n".write(to: export.appendingPathComponent("Connections.csv"), atomically: true, encoding: .utf8)
        let result = LinkedInImport.parse(try LinkedInImport.readFiles([export]))
        XCTAssertEqual(result.certifications.map(\.name), ["CPACC"])
        XCTAssertEqual(result.languages.map(\.name), ["English"])
        XCTAssertTrue(result.experience.isEmpty, "Connections are never opened")
    }
    /// An import adds what isn't there, and only offers the headline, summary, and location.
    func testLinkedInImportNeverOverwritesAndOffersTheRest() {
        let store = makeStore()
        store.update { $0.headline = "Mine"; $0.about = "My about"; $0.certifications = [CertificationEntry(name: "CPACC", authority: "IAAP")] }
        var result = LinkedInImport.Result()
        result.certifications = [CertificationEntry(name: "cpacc", authority: "iaap"), CertificationEntry(name: "WAS", authority: "IAAP")]
        result.languages = [LanguageEntry(name: "English", proficiency: "Native")]
        result.headline = "LinkedIn headline"; result.summary = "LinkedIn summary"; result.location = "Oakland"
        XCTAssertEqual(store.applyLinkedIn(result), 2, "One new certification and one language")
        XCTAssertEqual(store.profile.headline, "Mine")
        XCTAssertEqual(store.profile.about, "My about")
        XCTAssertTrue(store.profile.facts.isEmpty, "The location is only offered")
        XCTAssertEqual(store.profile.linkedInIntro, ImportedIntro(headline: "LinkedIn headline", summary: "LinkedIn summary", location: "Oakland"))
        XCTAssertEqual(store.applyLinkedIn(result), 0)
    }
    func testDurationsReadLikeLinkedIn() {
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 25))!
        XCTAssertEqual(ProfileMonth.months(ProfileMonth(year: 2024, month: 2), nil, now: now), 32)
        XCTAssertEqual(ProfileMonth.duration(months: 32), "2 yrs 8 mos")
        XCTAssertEqual(ProfileMonth.duration(months: 12), "1 yr")
        XCTAssertEqual(ProfileMonth.duration(months: 1), "1 mo")
        XCTAssertEqual(ProfileMonth.months(ProfileMonth(year: 2020, month: 1), ProfileMonth(year: 2020, month: 1)), 1, "Both months count")
        XCTAssertEqual(ProfileMonth.months(ProfileMonth(year: 2015), ProfileMonth(year: 2017, month: 12)), 36, "A year alone starts in January")
        let job = WorkEntry(title: "Designer", company: "Kemo", start: ProfileMonth(year: 2024, month: 2))
        XCTAssertEqual(job.datesAndDuration(now: now), "\(ProfileMonth(year: 2024, month: 2).text) \u{2013} Present · 2 yrs 8 mos")
        let roles = [WorkEntry(title: "Lead", company: "Kemo Labs", start: ProfileMonth(year: 2024, month: 2)),
                     WorkEntry(title: "Designer", company: "kemo labs ", start: ProfileMonth(year: 2021, month: 6), end: ProfileMonth(year: 2024, month: 1)),
                     WorkEntry(title: "Designer", company: "Tidepool", start: ProfileMonth(year: 2018, month: 9), end: ProfileMonth(year: 2021, month: 5))]
        let groups = WorkEntry.grouped(roles)
        XCTAssertEqual(groups.map(\.count), [2, 1], "A promotion groups under one company")
        XCTAssertEqual(WorkEntry.span(groups[0], now: now), "5 yrs 4 mos")
        XCTAssertEqual(ProfileInitials.of("Rhode Island School of Design"), "RI")
        XCTAssertEqual(ProfileInitials.of("The Kemo Labs, Inc."), "KL")
    }

    // MARK: Music

    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private func library() -> [MusicLibraryItem] {
        func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }
        return [
            MusicLibraryItem(id: "a", title: "Nights", artist: "Frank Ocean", genre: "R&B", playCount: 50, lastPlayed: ago(2)),
            MusicLibraryItem(id: "b", title: "Pink + White", artist: "Frank Ocean", genre: "R&B", playCount: 30, lastPlayed: ago(60)),
            MusicLibraryItem(id: "c", title: "Kyoto", artist: "Phoebe Bridgers", genre: "Alternative", playCount: 70, lastPlayed: ago(40)),
            MusicLibraryItem(id: "d", title: "Nightcall", artist: "Kavinsky", genre: "", playCount: 20, lastPlayed: ago(1)),
            MusicLibraryItem(id: "e", title: "Tied B", artist: "frank ocean ", genre: "r&b", playCount: 20, lastPlayed: ago(3)),
            MusicLibraryItem(id: "f", title: "Never played", artist: "Nobody", genre: "Pop", playCount: 0, lastPlayed: nil),
        ]
    }
    func testMusicStatsAreSumsOfTheLibrarysOwnCounts() {
        let stats = MusicStats.compute(library(), now: now)
        XCTAssertEqual(stats.totalPlays, 190)
        XCTAssertEqual(stats.songsPlayed, 5, "Songs never played are left out")
        XCTAssertEqual(stats.topSongs.map(\.id), ["c", "a", "b", "d", "e"], "Most played first; a tie goes to the more recently played")
        XCTAssertEqual(stats.topArtists.map(\.name), ["Frank Ocean", "Phoebe Bridgers", "Kavinsky"], "An artist's plays add up across songs and spellings")
        XCTAssertEqual(stats.topArtists.first?.plays, 100)
        XCTAssertEqual(stats.topArtists.first?.artworkSource, "a", "An artist is pictured by their most-played song")
        XCTAssertEqual(stats.topGenres.map(\.name), ["R&B", "Alternative"])
        XCTAssertEqual(stats.topGenres.first?.plays, 100)
        XCTAssertEqual(stats.topGenres.first?.share ?? 0, 100.0 / 170.0, accuracy: 0.0001, "Shares count only songs with a genre")
        XCTAssertEqual(stats.onRepeat.map(\.id), ["a", "d", "e"], "Played in the last 30 days, most played first")
        XCTAssertFalse(stats.topSongs.contains { $0.id == "f" })
        XCTAssertEqual(MusicStats.compute(library(), now: now), stats, "The same library always gives the same stats")
        XCTAssertTrue(MusicStats.compute([], now: now).isEmpty)
        XCTAssertEqual(stats.artworkSources, ["a", "b", "c", "d", "e"])
    }
    func testConnectingMusicSavesStatsAndArtworkAndDisconnectingRemovesThem() async throws {
        let store = makeStore()
        let denied = SampleMusicLibrary(access: .denied)
        let refused = await store.connectMusic(denied)
        XCTAssertEqual(refused, .denied)
        XCTAssertNil(store.profile.musicStats, "Nothing is read without access")

        let library = SampleMusicLibrary()
        let access = await store.connectMusic(library)
        XCTAssertEqual(access, .authorized, "Access is asked for only now")
        let stats = try XCTUnwrap(store.profile.musicStats)
        XCTAssertEqual(stats.totalPlays, SampleMusicLibrary.sample().reduce(0) { $0 + $1.playCount })
        XCTAssertEqual(stats.topArtists.first?.name, "Frank Ocean")
        let art = try XCTUnwrap(stats.topArtists.first?.artwork)
        XCTAssertNotNil(store.artworkImage(art))
        XCTAssertEqual(makeStore().profile.musicStats, stats, "Stats are saved with the profile")
        XCTAssertFalse(store.musicIsStale)

        store.addSong(title: "Nights", artist: "Frank Ocean", pick: .onRepeat)
        store.addSong(title: "Blonde", artist: "Frank Ocean", pick: .favoriteAlbum)
        store.addSong(title: "Motion Sickness", artist: "Phoebe Bridgers", pick: .onRepeat)
        XCTAssertEqual(store.profile.songs.map(\.title), ["Motion Sickness", "Blonde"], "One song on repeat at a time")

        store.disconnectMusic()
        XCTAssertNil(store.profile.musicStats)
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("music-") }
        XCTAssertTrue(left.isEmpty, "Disconnecting deletes the artwork")
        XCTAssertEqual(store.profile.songs.count, 2, "Hand picks stay")
    }
    func testAnUnreadableStatsBlockDoesntLoseTheProfile() throws {
        let json = #"{"bio":"hi","musicStats":{"topArtists":"garbage"}}"#
        let profile = try JSONDecoder().decode(SocialProfile.self, from: Data(json.utf8))
        XCTAssertEqual(profile.bio, "hi")
        XCTAssertNil(profile.musicStats)
    }
}

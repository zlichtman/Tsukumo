import UIKit
import XCTest
@testable import KemoSabe

/// The super profile's imports: LinkedIn CSVs, Instagram's JSON export, blog feeds, and older profile files.
@MainActor final class ProfileImportTests: XCTestCase {
    private var folder: URL!
    private var suite: String!
    private var account: AccountStore!
    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = "ProfileImportTests-" + UUID().uuidString
        account = AccountStore(defaults: UserDefaults(suiteName: suite)!, cloud: nil)
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
        UserDefaults().removePersistentDomain(forName: suite)
    }
    private func makeStore() -> ProfileStore { ProfileStore(folder: folder.appendingPathComponent("Profile"), account: account) }

    // MARK: CSV

    func testCSVHandlesQuotesEscapedQuotesCommasAndLineBreaks() {
        let text = "\u{FEFF}Name,Note\r\n\"Kemo, the pet\",\"He said \"\"hi\"\"\nthen left\"\r\nplain,\"\"\n\nlast,row"
        XCTAssertEqual(CSVParser.rows(text), [
            ["Name", "Note"],
            ["Kemo, the pet", "He said \"hi\"\nthen left"],
            ["plain", ""],
            ["last", "row"],
        ])
        XCTAssertEqual(CSVParser.rows("a,b,\n"), [["a", "b", ""]], "A trailing comma is an empty last field")
        XCTAssertEqual(CSVParser.rows("\"only\""), [["only"]])
    }
    func testCSVTableSkipsLinkedInPreamble() throws {
        let text = "Notes:\n\"When exporting your connection data, you may notice that some of the email addresses are missing.\"\n\nFirst Name,Last Name,Company\nAda,Lovelace,Engines\n"
        let table = try XCTUnwrap(CSVParser.table(CSVParser.rows(text), requiring: ["First Name", "Company"]))
        XCTAssertEqual(table, [["First Name": "Ada", "Last Name": "Lovelace", "Company": "Engines"]])
        XCTAssertNil(CSVParser.table(CSVParser.rows(text), requiring: ["School Name"]))
    }

    // MARK: LinkedIn

    func testLinkedInPositionsEducationSkillsAndProfile() {
        let positions = """
        Company Name,Title,Description,Location,Started On,Finished On
        Kemo Labs,iOS Engineer,"Built the watch app, the profile,
        and more",Remote,Mar 2022,
        Acme,Intern,,"New York, NY",Jun 2019,Aug 2019
        Older Co,Designer,,,2015,Dec 2017
        """
        let education = """
        School Name,Start Date,End Date,Notes,Degree Name,Activities
        State University,2014,2018,Dean's list,BS Computer Science,Robotics club
        """
        let skills = "Name\nSwift\nSwiftUI\n"
        let profile = """
        First Name,Last Name,Maiden Name,Address,Birth Date,Headline,Summary,Industry,Zip Code,Geo Location,Twitter Handles,Websites,Instant Messengers
        Zach,L,,,,iOS engineer at Kemo,I build friendly software.,Software,,"San Francisco, CA",,,
        """
        let result = LinkedInImport.parse([skills, positions, profile, education])
        XCTAssertEqual(result.experience.map(\.company), ["Kemo Labs", "Acme", "Older Co"], "Current job first, then newest")
        let current = result.experience[0]
        XCTAssertEqual(current.title, "iOS Engineer")
        XCTAssertEqual(current.start, ProfileMonth(year: 2022, month: 3))
        XCTAssertNil(current.end, "An empty Finished On is a job you have now")
        XCTAssertTrue(current.dates.hasSuffix("Present"))
        XCTAssertEqual(current.summary, "Built the watch app, the profile,\nand more")
        XCTAssertEqual(result.experience[1].location, "New York, NY")
        XCTAssertEqual(result.experience[1].end, ProfileMonth(year: 2019, month: 8))
        XCTAssertEqual(result.experience[2].start, ProfileMonth(year: 2015))
        XCTAssertEqual(result.education.first?.school, "State University")
        XCTAssertEqual(result.education.first?.degree, "BS Computer Science")
        XCTAssertEqual(result.education.first?.dates, "2014 \u{2013} 2018")
        XCTAssertEqual(result.education.first?.notes, "Dean's list\n\nRobotics club")
        XCTAssertEqual(result.skills, ["Swift", "SwiftUI"])
        XCTAssertEqual(result.headline, "iOS engineer at Kemo")
        XCTAssertEqual(result.summary, "I build friendly software.")
    }
    func testMonthParsing() {
        XCTAssertEqual(ProfileMonth.parse("Jan 2020"), ProfileMonth(year: 2020, month: 1))
        XCTAssertEqual(ProfileMonth.parse("September 2018"), ProfileMonth(year: 2018, month: 9))
        XCTAssertEqual(ProfileMonth.parse("2021-07"), ProfileMonth(year: 2021, month: 7))
        XCTAssertEqual(ProfileMonth.parse("07/2021"), ProfileMonth(year: 2021, month: 7))
        XCTAssertEqual(ProfileMonth.parse(" 2016 "), ProfileMonth(year: 2016))
        XCTAssertNil(ProfileMonth.parse(""))
        XCTAssertNil(ProfileMonth.parse("Present"))
        XCTAssertNil(ProfileMonth.parse("Foo 2020"))
        XCTAssertLessThan(ProfileMonth(year: 2020), ProfileMonth(year: 2020, month: 1))
    }
    func testLinkedInImportMergesAndOnlySuggestsTheHeadline() {
        let store = makeStore()
        store.update { $0.headline = "My own headline"; $0.skills = ["swift"] }
        var result = LinkedInImport.Result()
        result.experience = [WorkEntry(title: "Engineer", company: "Kemo", start: ProfileMonth(year: 2022, month: 1))]
        result.skills = ["Swift", "Design"]
        result.headline = "LinkedIn headline"
        XCTAssertEqual(store.applyLinkedIn(result), 2, "One job and one new skill; Swift is already there")
        XCTAssertEqual(store.profile.headline, "My own headline", "An import never replaces your headline")
        XCTAssertEqual(store.profile.linkedInIntro?.headline, "LinkedIn headline")
        XCTAssertEqual(store.profile.skills, ["swift", "Design"])
        XCTAssertEqual(store.applyLinkedIn(result), 0, "Importing the same export again adds nothing")
        XCTAssertEqual(store.profile.experience.count, 1)
        // Using it is the person's choice.
        store.update { $0.headline = $0.linkedInIntro?.headline; $0.linkedInIntro?.headline = nil }
        XCTAssertEqual(store.profile.headline, "LinkedIn headline")
        XCTAssertNil(store.profile.linkedInIntro, "An empty suggestion is dropped")
    }
    func testLinkedInReadsKnownFilesFromAFolder() throws {
        let export = folder.appendingPathComponent("Basic_LinkedInDataExport", isDirectory: true)
        try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
        try "Name\nSwift\n".write(to: export.appendingPathComponent("Skills.csv"), atomically: true, encoding: .utf8)
        try "From,To,Content\nA,B,private message\n".write(to: export.appendingPathComponent("messages.csv"), atomically: true, encoding: .utf8)
        let texts = try LinkedInImport.readFiles([export])
        XCTAssertEqual(texts, ["Name\nSwift\n"], "Only the four profile files are opened")
    }

    // MARK: Instagram

    private let instagramJSON = #"""
    [
      {"media": [{"uri": "media/posts/202301/one.jpg", "creation_timestamp": 1673000000, "title": "Donâ\u0080\u0099t stop ð\u009f\u0098\u008a"}]},
      {"title": "Carousel caption", "creation_timestamp": 1675000000,
       "media": [{"uri": "media/posts/202302/a.jpg", "creation_timestamp": 1675000000, "title": ""},
                 {"uri": "media/posts/202302/b.mp4", "creation_timestamp": 1675000001, "title": ""}]}
    ]
    """#
    func testInstagramPostsAndMojibakeRepair() throws {
        let posts = try InstagramImport.posts(fromJSON: Data(instagramJSON.utf8))
        XCTAssertEqual(posts.count, 3, "A carousel becomes one post per item")
        XCTAssertEqual(posts[0].caption, "Don\u{2019}t stop \u{1F60A}")
        XCTAssertEqual(posts[0].taken, Date(timeIntervalSince1970: 1_673_000_000))
        XCTAssertEqual(posts[1].caption, "Carousel caption", "Items without their own caption take the post's")
        XCTAssertFalse(posts[1].isVideo)
        XCTAssertTrue(posts[2].isVideo)
        XCTAssertEqual(InstagramImport.repair("café"), "café", "Text that isn't mangled is kept")
        XCTAssertEqual(InstagramImport.repair("plain"), "plain")
        XCTAssertEqual(InstagramImport.repair("caf\u{00C3}\u{00A9}"), "café")
        // Older exports wrap the list in an object.
        let wrapped = try InstagramImport.posts(fromJSON: Data(#"{"ig_posts": [{"media": [{"uri": "media/x.jpg", "title": "hi"}]}]}"#.utf8))
        XCTAssertEqual(wrapped.map(\.uri), ["media/x.jpg"])
    }
    func testInstagramFilesStayInsideTheExport() {
        let root = URL(fileURLWithPath: "/tmp/export", isDirectory: true)
        XCTAssertEqual(InstagramImport.file(for: "media/posts/a.jpg", in: root)?.path, "/tmp/export/media/posts/a.jpg")
        XCTAssertNil(InstagramImport.file(for: "../secret.jpg", in: root))
        XCTAssertNil(InstagramImport.file(for: "media/../../secret.jpg", in: root))
        XCTAssertNil(InstagramImport.file(for: "/etc/passwd", in: root))
    }
    private func jpeg(_ color: UIColor) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }.jpegData(compressionQuality: 0.9)!
    }
    func testInstagramImportAddsPostsOnceWithCaptionsDatesAndSource() async throws {
        let export = folder.appendingPathComponent("instagram-kemo-2026", isDirectory: true)
        let content = export.appendingPathComponent("your_instagram_activity/content", isDirectory: true)
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: export.appendingPathComponent("media/posts/202301"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: export.appendingPathComponent("media/posts/202302"), withIntermediateDirectories: true)
        try jpeg(.red).write(to: export.appendingPathComponent("media/posts/202301/one.jpg"))
        try jpeg(.blue).write(to: export.appendingPathComponent("media/posts/202302/a.jpg"))
        // b.mp4 is missing: it's counted as couldn't be read, and the rest still import.
        try Data(instagramJSON.utf8).write(to: content.appendingPathComponent("posts_1.json"))

        let store = makeStore()
        // The person may choose the folder that holds the export; it's found one level down.
        var steps: [Int] = []
        let report = try await store.importInstagram(from: folder) { done, _ in steps.append(done) }
        XCTAssertEqual(report.added, 2)
        XCTAssertEqual(report.failed, 1)
        XCTAssertEqual(steps.last, 3)
        let media = store.profile.media
        XCTAssertEqual(Set(media.compactMap(\.caption)), ["Don\u{2019}t stop \u{1F60A}", "Carousel caption"])
        XCTAssertTrue(media.allSatisfy { $0.source == "instagram" })
        XCTAssertEqual(media.first { $0.caption == "Carousel caption" }?.day, Date(timeIntervalSince1970: 1_675_000_000))
        XCTAssertNotNil(store.profile.importedSources["instagram:media/posts/202301/one.jpg"])

        let again = try await store.importInstagram(from: export) { _, _ in }
        XCTAssertEqual(again.added, 0)
        XCTAssertEqual(again.alreadyHere, 2)
        XCTAssertEqual(store.profile.media.count, 2, "Importing again skips posts already brought in")
    }
    func testInstagramImportWithoutPostsSaysSo() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            _ = try await makeStore().importInstagram(from: folder) { _, _ in }
            XCTFail("An empty folder has no posts")
        } catch { XCTAssertEqual(error as? ProfileImportError, .noInstagramPosts) }
    }

    // MARK: Feeds

    func testRSSFeed() throws {
        let rss = """
        <?xml version="1.0"?>
        <rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/">
          <channel>
            <title>Kemo &amp; Friends</title>
            <link>https://blog.example.com</link>
            <item>
              <title>First post</title>
              <link>https://blog.example.com/first</link>
              <pubDate>Mon, 02 Jan 2023 10:00:00 +0000</pubDate>
              <description><![CDATA[<p>Hello <b>world</b> &amp; friends&#8217; stuff</p>]]></description>
            </item>
            <item>
              <title>Second</title>
              <guid>not-a-link</guid>
              <description>Plain text</description>
            </item>
          </channel>
        </rss>
        """
        let feed = try XCTUnwrap(FeedParser.parse(Data(rss.utf8)))
        XCTAssertEqual(feed.title, "Kemo & Friends")
        XCTAssertEqual(feed.entries.count, 2)
        XCTAssertEqual(feed.entries[0].title, "First post")
        XCTAssertEqual(feed.entries[0].link, "https://blog.example.com/first")
        XCTAssertEqual(feed.entries[0].date, Date(timeIntervalSince1970: 1_672_653_600))
        XCTAssertEqual(feed.entries[0].summary, "Hello world & friends\u{2019} stuff")
        XCTAssertNil(feed.entries[1].link, "A guid that isn't a web address isn't a link")
    }
    func testAtomFeed() throws {
        let atom = """
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>Zach's notes</title>
          <entry>
            <title>Atom entry</title>
            <link rel="edit" href="https://example.com/edit/1"/>
            <link rel="alternate" type="text/html" href="https://example.com/posts/1"/>
            <updated>2024-05-06T07:08:09Z</updated>
            <summary type="html">&lt;p&gt;Short &lt;em&gt;summary&lt;/em&gt;&lt;/p&gt;</summary>
            <author><name>Zach</name></author>
          </entry>
        </feed>
        """
        let feed = try XCTUnwrap(FeedParser.parse(Data(atom.utf8)))
        XCTAssertEqual(feed.title, "Zach's notes")
        XCTAssertEqual(feed.entries.first?.title, "Atom entry")
        XCTAssertEqual(feed.entries.first?.link, "https://example.com/posts/1")
        XCTAssertEqual(feed.entries.first?.summary, "Short summary")
        XCTAssertEqual(feed.entries.first?.date, try Date.ISO8601FormatStyle().parse("2024-05-06T07:08:09Z"))
        XCTAssertNil(FeedParser.parse(Data("<html><head><title>Not a feed</title></head></html>".utf8)))
    }
    func testFeedCapsEntries() throws {
        let items = (0..<80).map { "<item><title>Post \($0)</title></item>" }.joined()
        let feed = try XCTUnwrap(FeedParser.parse(Data("<rss><channel><title>Big</title>\(items)</channel></rss>".utf8)))
        XCTAssertEqual(feed.entries.count, FeedParser.maxEntries)
    }
    func testFeedDiscoveryFromHTML() {
        let html = """
        <html><head>
        <link rel="stylesheet" href="/style.css">
        <link rel="alternate" type="application/rss+xml" title="RSS" href="/feed.xml">
        <LINK REL='alternate' TYPE='application/atom+xml' HREF='https://blog.example.com/atom.xml?a=1&amp;b=2'>
        <link rel="alternate" type="application/rss+xml" href="http://insecure.example.com/rss">
        <link rel="alternate" hreflang="fr" href="/fr/">
        </head></html>
        """
        let base = URL(string: "https://blog.example.com/about")!
        XCTAssertEqual(FeedDiscovery.alternates(inHTML: html, base: base).map(\.absoluteString),
                       ["https://blog.example.com/feed.xml", "https://blog.example.com/atom.xml?a=1&b=2"], "Only https feed links")
        XCTAssertEqual(FeedDiscovery.commonFeeds(for: base).map(\.absoluteString),
                       ["https://blog.example.com/feed", "https://blog.example.com/rss", "https://blog.example.com/atom.xml", "https://blog.example.com/index.xml"])
    }
    func testFeedAddressesAreHTTPSOnly() {
        XCTAssertEqual(FeedDiscovery.normalize("blog.example.com")?.absoluteString, "https://blog.example.com")
        XCTAssertEqual(FeedDiscovery.normalize(" http://blog.example.com/feed ")?.absoluteString, "https://blog.example.com/feed")
        XCTAssertNil(FeedDiscovery.normalize("ftp://blog.example.com"))
        XCTAssertNil(FeedDiscovery.normalize("localhost"))
        XCTAssertNil(FeedDiscovery.normalize("not an address"))
        XCTAssertEqual(ProfileBlog(address: "blog.example.com").host, "blog.example.com")
    }

    // MARK: Profile file

    /// A profile.json from before the super profile (September 24, 2026), with no sections, facts, or blog.
    func testLegacyProfileStillDecodes() throws {
        let legacy = #"""
        {"name":"Zach","handle":"zach","bio":"Builds Kemo","headline":"iOS engineer",
         "avatar":null,"featured":[null,null,null,null,null,null],
         "media":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":"photo","file":"a.jpg","thumbnail":"a-thumb.jpg","added":780000000,"caption":"Hi"}],
         "songs":[{"id":"7F9619FF-8B86-D011-B42D-00C04FC964FF","title":"Song","artist":"Artist"}],
         "links":[{"id":"8F9619FF-8B86-D011-B42D-00C04FC964FF","platform":"instagram","value":"zach"}]}
        """#
        let profile = try JSONDecoder().decode(SocialProfile.self, from: Data(legacy.utf8))
        XCTAssertEqual(profile.bio, "Builds Kemo")
        XCTAssertEqual(profile.media.first?.caption, "Hi")
        XCTAssertNil(profile.media.first?.source)
        XCTAssertEqual(profile.links.first?.platform, .instagram)
        XCTAssertTrue(profile.experience.isEmpty && profile.skills.isEmpty && profile.facts.isEmpty)
        XCTAssertNil(profile.blog)
        XCTAssertTrue(ProfileBlockKind.allCases.allSatisfy(profile.shows), "Every block shows until you hide it")
        XCTAssertEqual(profile.blocks.map(\.kind), ProfileBlockKind.allCases, "A profile from before blocks gets every block, in the default order")
        // The oldest files had only a name and bio.
        let oldest = try JSONDecoder().decode(SocialProfile.self, from: Data(#"{"name":"Zach","bio":"hi"}"#.utf8))
        XCTAssertEqual(oldest.featured.count, SocialProfile.featuredSlots)
        XCTAssertTrue(oldest.media.isEmpty)
        // A section a later build adds doesn't make the file unreadable.
        let later = try JSONDecoder().decode(SocialProfile.self, from: Data(#"{"hiddenSections":["work","reviews"]}"#.utf8))
        XCTAssertEqual(later.hiddenSections, [.work])
        XCTAssertFalse(later.shows(.work), "A hidden section stays hidden as a block")

        let file = folder.appendingPathComponent("Profile/profile.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(legacy.utf8).write(to: file)
        let store = makeStore()
        XCTAssertFalse(store.loadFailed)
        XCTAssertEqual(store.profile.headline, "iOS engineer")
        // A save writes the new fields, and the file reads back the same.
        store.update { $0.interests = ["Climbing"] }
        XCTAssertEqual(makeStore().profile.interests, ["Climbing"])
    }
    func testSectionsAreBoundedAndPostsCantBeHidden() {
        let store = makeStore()
        store.update { profile in
            profile.skills = (0..<100).map { "Skill \($0)" } + ["skill 1", "  "]
            profile.interests = ["  Film   photography ", "film photography"]
            profile.blocks = [ProfileBlock(kind: .work, hidden: true), ProfileBlock(kind: .work), ProfileBlock(kind: .photos, style: .onRepeat)]
            profile.facts = [ProfileFact(label: "Hometown", value: "  "), ProfileFact(label: String(repeating: "L", count: 50), value: "Oakland")]
            profile.experience = [WorkEntry(), WorkEntry(title: String(repeating: "t", count: 300), company: "Kemo")]
            profile.blog = ProfileBlog(address: "blog.example.com", entries: (0..<70).map { BlogEntry(title: "\($0)", summary: "") })
        }
        let profile = store.profile
        XCTAssertEqual(profile.skills.count, SocialProfile.maxSkills)
        XCTAssertEqual(profile.interests, ["Film photography"], "Tags are trimmed and deduplicated")
        XCTAssertEqual(profile.blocks.map(\.kind), [.work, .photos, .music, .writing, .personal, .links, .kemo], "Each block once, missing ones added at the end")
        XCTAssertNil(profile.block(.photos).style, "A style that doesn't belong to a block is cleared")
        XCTAssertEqual(profile.hiddenSections, [.work], "Older builds still hide what the blocks hide")
        XCTAssertTrue(profile.shows(.photos))
        XCTAssertFalse(profile.shows(.work))
        XCTAssertEqual(profile.facts.count, 1)
        XCTAssertEqual(profile.facts.first?.label.count, 30)
        XCTAssertEqual(profile.experience.count, 1, "An empty job is dropped")
        XCTAssertEqual(profile.experience.first?.title.count, 120)
        XCTAssertEqual(profile.blog?.entries.count, FeedParser.maxEntries)
    }
    func testKemoLevels() {
        XCTAssertEqual(KemoLevel.level(xp: 0), 1)
        XCTAssertEqual(KemoLevel.level(xp: 14), 1)
        XCTAssertEqual(KemoLevel.level(xp: 15), 2)
        XCTAssertEqual(KemoLevel.level(xp: 60), 3)
        XCTAssertEqual(KemoLevel.xp(toReach: 3), 60)
        XCTAssertEqual(KemoLevel.progress(xp: 15, level: 2), 0)
        XCTAssertEqual(KemoLevel.progress(xp: 37, level: 2), 22.0 / 45.0, accuracy: 0.0001)
    }
}

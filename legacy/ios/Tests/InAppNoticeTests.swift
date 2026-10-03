import XCTest
@testable import KemoSabe

/// In-app notices (the owner's request, September 25, 2026: Dynamic Island–style notices while
/// KemoSabe is in front). One decision for both paths: a system notification in the background,
/// an in-app notice in front, never for what's on screen, and only with the kind's switch on.
@MainActor final class InAppNoticeTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""
    override func setUp() {
        suite = "InAppNoticeTests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    private func setup(foreground: Bool, signedIn: Bool = true, screen: VisibleScreen = .init(tab: "Home"))
        -> (KemoNotifier, FakeNotificationCenter, InAppNoticeCenter) {
        let center = FakeNotificationCenter(), presenter = InAppNoticeCenter()
        presenter.screen = screen
        presenter.route = { _ in }
        let notifier = KemoNotifier(center: center, defaults: defaults, isForeground: { foreground }, signedIn: { signedIn })
        notifier.inApp = presenter
        return (notifier, center, presenter)
    }
    private func mac(_ kind: DeviceNotice.Kind = .approval, task: UUID = UUID()) -> DeviceNotice {
        .init(id: UUID(), kind: kind, task: task, agent: "Claude Code", project: "KemoSabe", request: kind == .approval ? .command : nil, time: Date())
    }

    // MARK: The decision

    func testTheOneRule() {
        typealias D = NoticeDelivery
        XCTAssertEqual(D.decide(signedIn: true, switchOn: true, foreground: false, looking: false, canPost: true, canShowInApp: true), .system)
        XCTAssertEqual(D.decide(signedIn: true, switchOn: true, foreground: true, looking: false, canPost: true, canShowInApp: true), .inApp)
        XCTAssertEqual(D.decide(signedIn: true, switchOn: true, foreground: true, looking: true, canPost: true, canShowInApp: true), .none,
                       "Never for what's on screen")
        XCTAssertEqual(D.decide(signedIn: true, switchOn: false, foreground: true, looking: false, canPost: true, canShowInApp: true), .none)
        XCTAssertEqual(D.decide(signedIn: true, switchOn: false, foreground: false, looking: false, canPost: true, canShowInApp: true), .none)
        XCTAssertEqual(D.decide(signedIn: false, switchOn: true, foreground: true, looking: false, canPost: true, canShowInApp: true), .none)
        XCTAssertEqual(D.decide(signedIn: false, switchOn: true, foreground: false, looking: false, canPost: true, canShowInApp: true), .none)
        // The Mac has no in-app notices: in front, nothing.
        XCTAssertEqual(D.decide(signedIn: true, switchOn: true, foreground: true, looking: false, canPost: true, canShowInApp: false), .none)
        XCTAssertEqual(D.decide(signedIn: true, switchOn: true, foreground: false, looking: false, canPost: false, canShowInApp: true), .none)
    }

    func testAReplyOnAnotherTabShowsInTheAppAndPostsNothing() throws {
        let (notifier, center, presenter) = setup(foreground: true)
        let conversation = UUID()
        notifier.replyFinished("Brunch at 11.\nThen the market.", conversation: conversation, origin: .chat, preparedForReview: false)
        XCTAssertTrue(center.requests.isEmpty)
        let notice = try XCTUnwrap(presenter.current)
        XCTAssertEqual(notice.style, .reply)
        XCTAssertEqual(notice.title, CompanionIdentity.name)
        XCTAssertEqual(notice.body, "Brunch at 11. Then the market.")
        XCTAssertEqual(notice.link, .conversation(conversation))
    }
    func testInTheBackgroundItsASystemNotificationInstead() {
        let (notifier, center, presenter) = setup(foreground: false)
        notifier.replyFinished("Done.", conversation: UUID(), origin: .chat, preparedForReview: false)
        notifier.macNotice(mac())
        XCTAssertEqual(center.requests.count, 2)
        XCTAssertNil(presenter.current)
    }
    func testNeverForTheChatYoureLookingAt() {
        let conversation = UUID()
        let (notifier, _, presenter) = setup(foreground: true, screen: .init(tab: "Chat", conversation: conversation))
        notifier.replyFinished("Done.", conversation: conversation, origin: .chat, preparedForReview: false)
        XCTAssertNil(presenter.current)
        // A sheet over the chat, or another conversation: it shows.
        presenter.screen.covered = true
        notifier.replyFinished("Done.", conversation: conversation, origin: .chat, preparedForReview: false)
        XCTAssertNotNil(presenter.current)
        let (other, _, otherPresenter) = setup(foreground: true, screen: .init(tab: "Chat", conversation: UUID()))
        other.replyFinished("Done.", conversation: conversation, origin: .chat, preparedForReview: false)
        XCTAssertNotNil(otherPresenter.current)
    }
    func testSwitchesAndSigningOutApplyInFrontToo() {
        let (notifier, _, presenter) = setup(foreground: true)
        for kind in NotificationKind.allCases { notifier.set(kind, on: false) }
        notifier.replyFinished("Done.", conversation: nil, origin: .chat, preparedForReview: false)
        notifier.replyFinished("Done.", conversation: nil, origin: .chat, preparedForReview: true)
        notifier.macNotice(mac())
        XCTAssertNil(presenter.current)
        let (signedOut, _, signedOutPresenter) = setup(foreground: true, signedIn: false)
        signedOut.replyFinished("Done.", conversation: nil, origin: .chat, preparedForReview: false)
        signedOut.macNotice(mac())
        XCTAssertNil(signedOutPresenter.current)
    }
    func testWatchAndTalkToKemoRepliesDontShowAgainInTheApp() {
        let (notifier, center, presenter) = setup(foreground: true)
        notifier.replyFinished("It's 18 degrees.", conversation: nil, origin: .watch, preparedForReview: false)
        notifier.replyFinished("It's 18 degrees.", conversation: nil, origin: .talkToKemo, preparedForReview: false)
        XCTAssertNil(presenter.current); XCTAssertTrue(center.requests.isEmpty)
    }
    func testSomethingForReviewIsOneDayNoticeUnlessDayIsOnScreen() throws {
        let (notifier, _, presenter) = setup(foreground: true)
        notifier.replyFinished("I drafted a reminder for 7.", conversation: UUID(), origin: .chat, preparedForReview: true)
        let notice = try XCTUnwrap(presenter.current)
        XCTAssertEqual(notice.style, .day); XCTAssertEqual(notice.link, .day); XCTAssertEqual(notice.title, "Your day")
        XCTAssertTrue(presenter.waiting.isEmpty, "Not a reply and a Day item")
        let (onDay, _, onDayPresenter) = setup(foreground: true, screen: .init(tab: "Day"))
        onDay.replyFinished("I drafted a reminder for 7.", conversation: UUID(), origin: .chat, preparedForReview: true)
        XCTAssertNil(onDayPresenter.current)
    }
    func testAMacNoticeShowsInTheAppAndIsWithdrawnOnceDealtWith() throws {
        let (notifier, center, presenter) = setup(foreground: true)
        let notice = mac()
        XCTAssertEqual(notifier.macNotice(notice), .inApp)
        let shown = try XCTUnwrap(presenter.current)
        XCTAssertEqual(shown.id, notice.notificationID); XCTAssertEqual(shown.style, .mac(.approval))
        XCTAssertEqual(shown.title, "Claude Code needs you"); XCTAssertEqual(shown.subtitle, "KemoSabe")
        XCTAssertTrue(center.requests.isEmpty)
        let before = presenter.collapseRequests
        notifier.removeDelivered([notice.notificationID])
        XCTAssertEqual(presenter.collapseRequests, before + 1, "It goes back into the island")
        // Its sheet already open: nothing more.
        presenter.screen.macTask = notice.task
        XCTAssertEqual(notifier.macNotice(mac(task: notice.task)), .none)
    }
    func testAMacNoticeArrivingWhileOpenShowsOnceThroughSync() async throws {
        let transport = MemorySyncTransport()
        let macEngine = SyncEngine(transport: transport, device: "mac"), phone = SyncEngine(transport: transport, device: "phone")
        let macDefaults = UserDefaults(suiteName: suite + "-mac")!
        defer { macDefaults.removePersistentDomain(forName: suite + "-mac") }
        let writerNotifier = KemoNotifier(center: FakeNotificationCenter(), defaults: macDefaults, isForeground: { false }, signedIn: { true })
        let writer = CrossDeviceNotices(engine: { macEngine }, defaults: macDefaults, notifier: { writerNotifier }, syncNow: {})
        let (notifier, center, presenter) = setup(foreground: true)
        let reader = CrossDeviceNotices(engine: { phone }, defaults: defaults, notifier: { notifier }, syncNow: {})
        let task = UUID()
        writer.publish(mac(task: task))
        try await macEngine.sync(); try await phone.sync()
        reader.deliver(); reader.deliver()
        XCTAssertNotNil(presenter.current); XCTAssertTrue(presenter.waiting.isEmpty, "Once")
        XCTAssertTrue(center.requests.isEmpty)
        writer.resolve(task: task)
        try await macEngine.sync(); try await phone.sync()
        let before = presenter.collapseRequests
        reader.deliver()
        XCTAssertEqual(presenter.collapseRequests, before + 1, "Approved on the Mac: the notice goes")
    }

    // MARK: The queue

    private func notice(_ id: String, _ link: NotificationLink = .conversation(UUID())) -> InAppNotice {
        .init(id: id, style: .reply, title: "Kemo", body: id, link: link)
    }
    func testNoticesQueueAndFollowOneAnother() {
        let presenter = InAppNoticeCenter()
        var presented = 0
        presenter.willPresent = { presented += 1 }
        presenter.show(notice("a")); presenter.show(notice("b")); presenter.show(notice("c"))
        XCTAssertEqual(presenter.current?.id, "a"); XCTAssertEqual(presenter.waiting.map(\.id), ["b", "c"])
        XCTAssertEqual(presented, 1, "The window opens once")
        presenter.show(notice("a"))
        XCTAssertEqual(presenter.waiting.count, 2, "The one on screen isn't shown twice")
        presenter.finish(); XCTAssertEqual(presenter.current?.id, "b")
        presenter.finish(); XCTAssertEqual(presenter.current?.id, "c")
        presenter.finish(); XCTAssertNil(presenter.current)
    }
    func testTheQueueStaysShortAndANewerReplyReplacesAnOlderOne() {
        let presenter = InAppNoticeCenter()
        let chat = NotificationLink.conversation(UUID())
        presenter.show(notice("now"))
        presenter.show(notice("old", chat)); presenter.show(notice("new", chat))
        XCTAssertEqual(presenter.waiting.map(\.id), ["new"])
        for index in 0..<6 { presenter.show(notice("n\(index)")) }
        XCTAssertEqual(presenter.waiting.count, InAppNoticeCenter.waitingLimit)
        XCTAssertEqual(presenter.waiting.last?.id, "n5", "The newest are kept")
    }
    func testWithdrawAndClear() {
        let presenter = InAppNoticeCenter()
        presenter.show(notice("a")); presenter.show(notice("b")); presenter.show(notice("c"))
        presenter.withdraw(["b"])
        XCTAssertEqual(presenter.waiting.map(\.id), ["c"])
        XCTAssertEqual(presenter.collapseRequests, 0)
        presenter.withdraw(["a"])
        XCTAssertEqual(presenter.collapseRequests, 1)
        presenter.clear()
        XCTAssertTrue(presenter.waiting.isEmpty); XCTAssertEqual(presenter.collapseRequests, 2)
    }
    func testOpeningRoutesToTheNoticesLink() {
        let presenter = InAppNoticeCenter()
        var routed: NotificationLink?
        presenter.route = { routed = $0 }
        presenter.show(notice("a", .day))
        presenter.open()
        XCTAssertEqual(routed, .day)
    }

    // MARK: What's on screen

    func testLookingAt() {
        let id = UUID(), task = UUID()
        let chat = VisibleScreen(tab: "Chat", conversation: id)
        XCTAssertTrue(chat.isLooking(at: .conversation(id)))
        XCTAssertTrue(chat.isLooking(at: .conversation(nil)))
        XCTAssertFalse(chat.isLooking(at: .conversation(UUID())))
        XCTAssertFalse(chat.isLooking(at: .day))
        for tab in ["Home", "Library", "Day", "Profile"] {
            XCTAssertFalse(VisibleScreen(tab: tab, conversation: id).isLooking(at: .conversation(id)), tab)
        }
        XCTAssertTrue(VisibleScreen(tab: "Day").isLooking(at: .day))
        XCTAssertFalse(VisibleScreen(tab: "Day", covered: true).isLooking(at: .day))
        let notice = DeviceNotice(id: UUID(), kind: .approval, task: task, agent: "Codex", project: nil, request: nil, time: Date())
        XCTAssertFalse(chat.isLooking(at: .macNotice(notice)))
        XCTAssertTrue(VisibleScreen(macTask: task).isLooking(at: .macNotice(notice)))
        XCTAssertTrue(VisibleScreen(tab: "Home", blocked: true).isLooking(at: .conversation(id)), "Nothing over onboarding or sign-in")
    }

    // MARK: The island

    func testIslandGeometry() throws {
        // iPhone 17 Pro: a 62-point safe area; the island sits 14 points down.
        let pro = IslandGeometry.resolve(screen: CGSize(width: 402, height: 874), safeTop: 62, phone: true)
        let island = try XCTUnwrap(pro.island)
        XCTAssertEqual(island.width, 126); XCTAssertEqual(island.height, 37 + 1.0 / 3, accuracy: 0.01)
        XCTAssertEqual(island.minY, 14); XCTAssertEqual(island.midX, 201)
        XCTAssertEqual(pro.cardTop, 14); XCTAssertEqual(pro.cardWidth, 382)
        // iPhone 15: 59 points, 11 down.
        XCTAssertEqual(IslandGeometry.resolve(screen: CGSize(width: 393, height: 852), safeTop: 59, phone: true).island?.minY, 11)
        // A notch (iPhone 16e) or a home button: no island; the card drops under the status bar.
        let notch = IslandGeometry.resolve(screen: CGSize(width: 390, height: 844), safeTop: 47, phone: true)
        XCTAssertNil(notch.island); XCTAssertEqual(notch.cardTop, 53)
        XCTAssertNil(IslandGeometry.resolve(screen: CGSize(width: 375, height: 667), safeTop: 20, phone: true).island)
        // Landscape and iPad: no island.
        XCTAssertNil(IslandGeometry.resolve(screen: CGSize(width: 874, height: 402), safeTop: 62, phone: true).island)
        let pad = IslandGeometry.resolve(screen: CGSize(width: 1024, height: 1366), safeTop: 24, phone: false)
        XCTAssertNil(pad.island); XCTAssertEqual(pad.cardWidth, 420)
    }
}

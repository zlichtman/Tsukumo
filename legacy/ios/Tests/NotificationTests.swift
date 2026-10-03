import UserNotifications
import XCTest
@testable import KemoSabe

/// Notifications (the owner's request, September 25, 2026): what's posted for each event, the
/// switches, signed out, foreground suppression, deep links, and notices from the Mac that never
/// carry message text. The system notification center is replaced by `FakeNotificationCenter`.
@MainActor final class NotificationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""
    override func setUp() {
        suite = "NotificationTests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    private func notifier(foreground: Bool = false, signedIn: Bool = true, center: FakeNotificationCenter = .init(),
                          defaults: UserDefaults? = nil) -> (KemoNotifier, FakeNotificationCenter) {
        (KemoNotifier(center: center, defaults: defaults ?? self.defaults, isForeground: { foreground }, signedIn: { signedIn }), center)
    }

    // MARK: Replies and Day

    func testReplyInTheBackgroundLinksToItsConversation() throws {
        let (notifier, center) = notifier()
        let conversation = UUID()
        notifier.replyFinished("Here's the plan for Saturday.", conversation: conversation, origin: .chat, preparedForReview: false)
        let request = try XCTUnwrap(center.requests.first)
        XCTAssertEqual(center.requests.count, 1)
        XCTAssertEqual(request.content.title, CompanionIdentity.name)
        XCTAssertEqual(request.content.body, "Here's the plan for Saturday.")
        XCTAssertEqual(request.content.categoryIdentifier, KemoNotifier.replyCategory)
        XCTAssertEqual(request.content.interruptionLevel, .active, "Normal by default, so Focus applies")
        XCTAssertNotNil(request.content.sound)
        XCTAssertNil(request.trigger, "Delivered now")
        XCTAssertEqual(NotificationLink(userInfo: request.content.userInfo), .conversation(conversation))
    }
    func testNothingWhileTheAppIsInFront() {
        let (notifier, center) = notifier(foreground: true)
        notifier.replyFinished("Done.", conversation: UUID(), origin: .chat, preparedForReview: true)
        notifier.macNotice(sample(.approval))
        XCTAssertTrue(center.requests.isEmpty)
    }
    func testNothingWhileSignedOut() {
        let (notifier, center) = notifier(signedIn: false)
        notifier.replyFinished("Done.", conversation: UUID(), origin: .chat, preparedForReview: true)
        notifier.macNotice(sample(.finished))
        XCTAssertTrue(center.requests.isEmpty)
    }
    func testEachSwitchStopsItsKind() {
        let (notifier, center) = notifier()
        for kind in NotificationKind.allCases { notifier.set(kind, on: false) }
        notifier.replyFinished("Done.", conversation: nil, origin: .chat, preparedForReview: false)
        notifier.replyFinished("Done.", conversation: nil, origin: .chat, preparedForReview: true)
        notifier.macNotice(sample(.approval))
        XCTAssertTrue(center.requests.isEmpty)
        notifier.set(.coding, on: true)
        notifier.macNotice(sample(.approval))
        XCTAssertEqual(center.requests.count, 1)
    }
    func testSwitchesStartOnAndAreKeptPerDevice() {
        let (notifier, _) = notifier()
        for kind in NotificationKind.allCases { XCTAssertTrue(notifier.isOn(kind), kind.title) }
        notifier.set(.replies, on: false)
        XCTAssertEqual(defaults.object(forKey: "kemo.notify.replies") as? Bool, false)
        XCTAssertEqual(NotificationKind.allCases.map(\.title), ["Replies", "Your day", "Coding agents"])
    }
    func testSomethingForReviewOpensDayInstead() throws {
        let (notifier, center) = notifier()
        notifier.replyFinished("I drafted a reminder for 7.", conversation: UUID(), origin: .chat, preparedForReview: true)
        let request = try XCTUnwrap(center.requests.first)
        XCTAssertEqual(center.requests.count, 1, "One notification, not a reply and a Day item")
        XCTAssertEqual(request.content.title, "Your day")
        XCTAssertEqual(request.content.categoryIdentifier, KemoNotifier.dayCategory)
        XCTAssertEqual(NotificationLink(userInfo: request.content.userInfo), .day)
        // With Your day off, it's an ordinary reply.
        notifier.set(.day, on: false)
        notifier.replyFinished("I drafted a reminder for 7.", conversation: nil, origin: .chat, preparedForReview: true)
        XCTAssertEqual(center.requests.last?.content.categoryIdentifier, KemoNotifier.replyCategory)
    }
    func testWatchAndTalkToKemoRepliesArriveQuietly() {
        let (notifier, center) = notifier()
        notifier.replyFinished("It's 18 degrees.", conversation: nil, origin: .watch, preparedForReview: false)
        notifier.replyFinished("It's 18 degrees.", conversation: nil, origin: .talkToKemo, preparedForReview: false)
        XCTAssertEqual(center.requests.count, 2)
        for request in center.requests {
            XCTAssertEqual(request.content.interruptionLevel, .passive)
            XCTAssertNil(request.content.sound, "No second buzz on the wrist")
        }
    }
    func testNoAnswerNoNotification() {
        let (notifier, center) = notifier()
        notifier.replyFinished(nil, conversation: nil, origin: .chat, preparedForReview: false)
        notifier.replyFinished("  \n ", conversation: nil, origin: .chat, preparedForReview: false)
        XCTAssertTrue(center.requests.isEmpty)
    }
    func testLongRepliesAreShortenedToAPreview() {
        let (notifier, center) = notifier()
        notifier.replyFinished(String(repeating: "word ", count: 100), conversation: nil, origin: .chat, preparedForReview: false)
        let body = center.requests.first?.content.body ?? ""
        XCTAssertLessThanOrEqual(body.count, 160); XCTAssertTrue(body.hasSuffix("…"))
    }
    func testTestHostNotifierPostsNothing() {
        // The app's own notifier never reaches the system center from a test host.
        XCTAssertNil(KemoNotifier().center)
    }

    func testSendingARequestInTheBackgroundNotifiesWhenTheReplyFinishes() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let saved = KemoNotifier.shared
        defer { KemoNotifier.shared = saved }
        let (fake, center) = notifier()
        KemoNotifier.shared = fake
        let store = AppStore(repository: .init(url: folder.appendingPathComponent("state.json")), provider: DelayedProvider())
        let finished = expectation(description: "reply")
        store.send("Anything on today?", completion: { _ in finished.fulfill() })
        await fulfillment(of: [finished], timeout: 5)
        let request = try XCTUnwrap(center.requests.first)
        XCTAssertEqual(request.content.body, "Late response")
        XCTAssertEqual(NotificationLink(userInfo: request.content.userInfo), .conversation(store.state.openConversations?[store.currentConversationSlot]?.id))
    }

    // MARK: Permission and links

    func testPermissionStates() {
        XCTAssertEqual(NotificationPermission(.notDetermined), .notDetermined)
        XCTAssertEqual(NotificationPermission(.denied), .denied)
        XCTAssertEqual(NotificationPermission(.authorized), .allowed)
        XCTAssertEqual(NotificationPermission(.provisional), .allowed)
        XCTAssertEqual(NotificationPermission(.ephemeral), .allowed)
    }
    func testRequestingPermissionSetsUpReplyReviewAndView() async {
        let (notifier, center) = notifier()
        center.grant = true
        let allowed = await notifier.requestPermission()
        XCTAssertTrue(allowed)
        XCTAssertEqual(Set(center.categories.map(\.identifier)), [KemoNotifier.replyCategory, KemoNotifier.dayCategory, KemoNotifier.macCategory])
        let reply = center.categories.first { $0.identifier == KemoNotifier.replyCategory }
        let action = try? XCTUnwrap(reply?.actions.first as? UNTextInputNotificationAction)
        XCTAssertEqual(action?.identifier, KemoNotifier.replyAction)
        XCTAssertTrue(action?.options.contains(.authenticationRequired) == true, "Replying reads your chats, so it needs the iPhone unlocked")
        let mac = center.categories.first { $0.identifier == KemoNotifier.macCategory }
        XCTAssertFalse(mac?.actions.contains { $0.title == "Approve" } ?? true, "Approving happens on the Mac")
    }
    func testLinksRoundTripThroughUserInfo() {
        let links: [NotificationLink] = [.conversation(UUID()), .conversation(nil), .day, .macNotice(sample(.approval))]
        for link in links { XCTAssertEqual(NotificationLink(userInfo: link.userInfo), link) }
        XCTAssertNil(NotificationLink(userInfo: ["task": "x"]))
    }

    // MARK: Your Mac's agents

    private func sample(_ kind: DeviceNotice.Kind, time: Date = Date(), task: UUID = UUID()) -> DeviceNotice {
        .init(id: UUID(), kind: kind, task: task, agent: "Claude Code", project: "KemoSabe", request: kind == .approval ? .command : nil, time: time)
    }
    func testMacNoticesSayWhereToGoAndOnlyApprovalsAreTimeSensitive() throws {
        let (notifier, center) = notifier()
        let approval = sample(.approval)
        notifier.macNotice(approval)
        notifier.macNotice(sample(.finished))
        notifier.macNotice(sample(.failed))
        XCTAssertEqual(center.requests.count, 3)
        let first = center.requests[0].content
        XCTAssertEqual(first.title, "Claude Code needs you"); XCTAssertEqual(first.subtitle, "KemoSabe"); XCTAssertEqual(first.body, "Approve it on your Mac.")
        XCTAssertEqual(first.interruptionLevel, .timeSensitive)
        XCTAssertEqual(center.requests[0].identifier, approval.notificationID)
        XCTAssertEqual(NotificationLink(userInfo: first.userInfo), .macNotice(approval))
        XCTAssertEqual(center.requests[1].content.interruptionLevel, .active)
        XCTAssertEqual(center.requests[2].content.title, "Claude Code stopped")
    }

    private func notices(_ engine: SyncEngine, defaults: UserDefaults, notifier: KemoNotifier, now: @escaping () -> Date = Date.init) -> CrossDeviceNotices {
        CrossDeviceNotices(engine: { engine }, defaults: defaults, now: now, notifier: { notifier }, syncNow: {})
    }
    func testAMacNoticeReachesTheIPhoneThroughSyncOnceAndIsTakenDownWhenDealtWith() async throws {
        let transport = MemorySyncTransport()
        let mac = SyncEngine(transport: transport, device: "mac"), phone = SyncEngine(transport: transport, device: "phone")
        let macDefaults = UserDefaults(suiteName: suite + "-mac")!
        defer { macDefaults.removePersistentDomain(forName: suite + "-mac") }
        let (macNotifier, macCenter) = notifier(defaults: macDefaults)
        let (phoneNotifier, phoneCenter) = notifier()
        let writer = notices(mac, defaults: macDefaults, notifier: macNotifier)
        let reader = notices(phone, defaults: defaults, notifier: phoneNotifier)
        let task = UUID()
        writer.publish(sample(.approval, task: task))
        XCTAssertEqual(mac.state.outbox.count, 1, "Queued for the next sync")
        try await mac.sync(); try await phone.sync()
        reader.deliver()
        XCTAssertEqual(phoneCenter.requests.count, 1)
        XCTAssertEqual(phoneCenter.requests.first?.content.interruptionLevel, .timeSensitive)
        XCTAssertTrue(macCenter.requests.isEmpty, "A device never notifies for its own notices")
        writer.deliver()
        XCTAssertTrue(macCenter.requests.isEmpty)
        // Another sync, or a second push, doesn't post it again.
        try await phone.sync(); reader.deliver()
        XCTAssertEqual(phoneCenter.requests.count, 1)
        // Approved on the Mac: the iPhone's notification comes down.
        writer.resolve(task: task)
        try await mac.sync(); try await phone.sync()
        reader.deliver()
        XCTAssertEqual(phoneCenter.removed, [phoneCenter.requests[0].identifier])
        XCTAssertEqual(phoneCenter.requests.count, 1)
    }
    func testANewerNoticeForTheSameTaskReplacesTheOlderAndTheBoardStaysSmall() throws {
        let mac = SyncEngine(transport: MemorySyncTransport(), device: "mac")
        let (macNotifier, _) = notifier()
        let writer = notices(mac, defaults: defaults, notifier: macNotifier)
        let task = UUID()
        writer.publish(sample(.approval, task: task))
        writer.publish(sample(.finished, task: task))
        XCTAssertEqual(writer.mine.map(\.kind), [.finished])
        for _ in 0..<20 { writer.publish(sample(.finished)) }
        XCTAssertEqual(writer.mine.count, NoticeBoard.limit)
        XCTAssertEqual(mac.state.records.count, 1, "One record per device, never a growing pile of tombstones")
    }
    func testOldNoticesAndForegroundArrivalsAreOnlyMarkedSeen() async throws {
        let transport = MemorySyncTransport()
        let mac = SyncEngine(transport: transport, device: "mac"), phone = SyncEngine(transport: transport, device: "phone")
        let (macNotifier, _) = notifier()
        var now = Date()
        let writer = notices(mac, defaults: UserDefaults(suiteName: suite + "-w")!, notifier: macNotifier, now: { now })
        defer { UserDefaults(suiteName: suite + "-w")!.removePersistentDomain(forName: suite + "-w") }
        writer.publish(sample(.finished, time: now.addingTimeInterval(-3600)))
        try await mac.sync(); try await phone.sync()
        let (phoneNotifier, center) = notifier()
        notices(phone, defaults: defaults, notifier: phoneNotifier, now: { now }).deliver()
        XCTAssertTrue(center.requests.isEmpty, "Expired")
        // Arrives while KemoSabe is open: nothing posted, and nothing later either.
        now = Date()
        writer.publish(sample(.approval, time: now))
        try await mac.sync(); try await phone.sync()
        let (openNotifier, openCenter) = notifier(foreground: true)
        notices(phone, defaults: defaults, notifier: openNotifier, now: { now }).deliver()
        notices(phone, defaults: defaults, notifier: phoneNotifier, now: { now }).deliver()
        XCTAssertTrue(openCenter.requests.isEmpty); XCTAssertTrue(center.requests.isEmpty)
    }
    func testNoticesStayInThePersonalZoneAndCarryNoMessageText() throws {
        XCTAssertThrowsError(try SyncEngine.check(type: SyncType.notice, zone: .shared(project: "p")))
        XCTAssertTrue(SyncType.personalOnly.contains(SyncType.notice))
        let mac = SyncEngine(transport: MemorySyncTransport(), device: "mac")
        let (macNotifier, _) = notifier()
        notices(mac, defaults: defaults, notifier: macNotifier).publish(sample(.approval))
        let record = try XCTUnwrap(mac.state.records.values.first)
        XCTAssertEqual(record.type, SyncType.notice); XCTAssertEqual(record.zone, .personal)
        let board = try XCTUnwrap(JSONSerialization.jsonObject(with: record.payload) as? [String: Any])
        let item = try XCTUnwrap((board["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(item.keys), ["id", "kind", "task", "agent", "project", "request", "time"],
                       "Only the kind, the agent, the project folder, the kind of request, and when")
    }
    func testNothingIsWrittenWhileSignedOut() {
        let mac = SyncEngine(transport: MemorySyncTransport(), device: "mac")
        let (signedOut, _) = notifier(signedIn: false)
        notices(mac, defaults: defaults, notifier: signedOut).publish(sample(.approval))
        XCTAssertTrue(mac.state.records.isEmpty)
    }
}

/// Records what would be posted, instead of the system's notification center.
@MainActor final class FakeNotificationCenter: NotificationCenterClient {
    var state: NotificationPermission = .notDetermined
    var grant = false
    nonisolated init() {}
    private(set) var requests: [UNNotificationRequest] = []
    private(set) var removed: [String] = []
    private(set) var categories: Set<UNNotificationCategory> = []
    func permission() async -> NotificationPermission { state }
    func requestPermission() async -> Bool { state = grant ? .allowed : .denied; return grant }
    func add(_ request: UNNotificationRequest) { requests.append(request) }
    func removeDelivered(_ identifiers: [String]) { removed += identifiers }
    func setCategories(_ categories: Set<UNNotificationCategory>) { self.categories = categories }
}

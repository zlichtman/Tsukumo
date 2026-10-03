import Foundation
import UserNotifications
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// Notifications on iPhone and Mac (the owner's request, September 25, 2026: "Get notifications to
// work"). One switch per kind in Settings → Notifications; nothing is posted while the app is in
// front (on iPhone an in-app notice shows instead, `InAppNotices.swift`), while signed out, or for
// a kind that's switched off. See design/UI-GUIDE.md (Notifications).

/// The kinds of notification, one switch each. Each device keeps its own switches.
enum NotificationKind: String, CaseIterable, Identifiable {
    /// Kemo finished a reply while the app was in the background (typed, Talk to Kemo, or the watch).
    case replies
    /// A plan or reminder Kemo prepared is waiting for your review in Day.
    case day
    /// A coding agent needs approval, finished, or failed (on iPhone: on your Mac).
    case coding
    var id: String { rawValue }
    var title: String {
        switch self { case .replies: "Replies"; case .day: "Your day"; case .coding: "Coding agents" }
    }
    /// One line under the switch.
    var detail: String {
        #if os(macOS)
        switch self {
        case .replies: "When a reply finishes while Tsukumo is in the background"
        case .day: "Plans and reminders waiting for your review"
        case .coding: "When a task needs approval, finishes, or fails"
        }
        #else
        switch self {
        case .replies: "When a reply finishes while KemoSabe is closed"
        case .day: "Plans and reminders waiting for your review"
        case .coding: "When an agent on your Mac needs you or finishes"
        }
        #endif
    }
    /// Device settings. The Mac keeps the keys it has always used.
    var key: String {
        #if os(macOS)
        switch self { case .replies: "tsukumo.notifyReplies"; case .day: "tsukumo.notifyDay"; case .coding: "tsukumo.notifyTasks" }
        #else
        "kemo.notify." + rawValue
        #endif
    }
    /// Replies on the Mac stay off until turned on, as before; everything else starts on (the
    /// system permission still decides whether anything shows).
    var defaultOn: Bool {
        #if os(macOS)
        self != .replies
        #else
        true
        #endif
    }
    func isOn(_ defaults: UserDefaults) -> Bool { defaults.object(forKey: key) as? Bool ?? defaultOn }
}

/// What the system allows. Provisional and ephemeral count as allowed.
enum NotificationPermission: Equatable {
    case notDetermined, denied, allowed
    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        default: self = .allowed
        }
    }
}

/// Where tapping a notification goes. Travels in the notification's `userInfo`.
enum NotificationLink: Codable, Equatable {
    /// The conversation the reply belongs to (nil: whatever conversation is open).
    case conversation(UUID?)
    case day
    /// On iPhone: a coding agent on your Mac needs you. Opens "Approve it on your Mac".
    case macNotice(DeviceNotice)
    static let key = "kemo.link"
    var userInfo: [AnyHashable: Any] { [Self.key: (try? JSONEncoder().encode(self)) ?? Data()] }
    init?(userInfo: [AnyHashable: Any]) {
        guard let data = userInfo[Self.key] as? Data, let link = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = link
    }
}

/// Where a reply was asked for. Replies to the watch and Talk to Kemo already show the answer where
/// you asked, so their notification arrives quietly in Notification Center (no sound, no banner, no
/// buzz on the wrist).
enum ReplyOrigin: Equatable { case chat, watch, talkToKemo }

/// Where a notice goes. A system notification while the app is away; on iPhone, while it's in
/// front, a notice that grows out of the Dynamic Island (`InAppNoticeCenter`); or nowhere.
enum NoticeDelivery: Equatable {
    case none, system, inApp
    /// The one rule for both paths: signed in and the kind's switch on, then a system notification
    /// in the background or an in-app notice in front, never for what's already on screen.
    static func decide(signedIn: Bool, switchOn: Bool, foreground: Bool, looking: Bool,
                       canPost: Bool, canShowInApp: Bool) -> NoticeDelivery {
        guard signedIn, switchOn else { return .none }
        if foreground { return canShowInApp && !looking ? .inApp : .none }
        return canPost ? .system : .none
    }
}

/// One notice shown in the app while it's in front: the same words a system notification would
/// carry, and where a tap goes.
struct InAppNotice: Identifiable, Equatable {
    enum Style: Equatable { case reply, day, mac(DeviceNotice.Kind) }
    /// The system notification's identifier, so a notice that was dealt with can be withdrawn.
    var id: String
    var style: Style
    var title: String
    var subtitle: String?
    /// One line on the card.
    var body: String
    /// More, shown when the card is expanded (the reply's first few sentences).
    var detail: String?
    var link: NotificationLink
    var accessibilityText: String { [title, subtitle, detail ?? body].compactMap { $0 }.joined(separator: ". ") }
}

/// Shows in-app notices (the iPhone's `InAppNoticeCenter`). The Mac has none.
@MainActor protocol InAppNoticePresenting: AnyObject {
    /// Whether the person is already looking at where the notice would take them.
    func isLooking(at link: NotificationLink) -> Bool
    func show(_ notice: InAppNotice)
    func withdraw(_ identifiers: [String])
}

/// The system notification center, behind a seam so tests can see exactly what would be posted.
@MainActor protocol NotificationCenterClient: AnyObject {
    func permission() async -> NotificationPermission
    func requestPermission() async -> Bool
    /// Hands the request to the system right away (safe in the last moments of background time).
    func add(_ request: UNNotificationRequest)
    func removeDelivered(_ identifiers: [String])
    func setCategories(_ categories: Set<UNNotificationCategory>)
}

@MainActor final class SystemNotificationCenter: NotificationCenterClient {
    nonisolated init() {}
    private var center: UNUserNotificationCenter { .current() }
    func permission() async -> NotificationPermission { NotificationPermission(await center.notificationSettings().authorizationStatus) }
    func requestPermission() async -> Bool { (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false }
    func add(_ request: UNNotificationRequest) { center.add(request, withCompletionHandler: nil) }
    func removeDelivered(_ identifiers: [String]) { center.removeDeliveredNotifications(withIdentifiers: identifiers) }
    func setCategories(_ categories: Set<UNNotificationCategory>) { center.setNotificationCategories(categories) }
}

/// Decides what to post and posts it. Every notification goes through `post`, which checks the
/// three rules first: signed in, the app isn't in front, and the kind's switch is on.
@MainActor final class KemoNotifier {
    /// The app's notifier. Replaceable only by tests; in a test host it posts nothing.
    static var shared = KemoNotifier()
    static let replyCategory = "kemo.reply", dayCategory = "kemo.day", macCategory = "kemo.mac"
    static let replyAction = "reply", openAction = "open"

    let center: NotificationCenterClient?
    let defaults: UserDefaults
    var isForeground: @MainActor () -> Bool
    var signedIn: @MainActor () -> Bool
    /// Where the request being answered came from (set by the iPhone app: the watch or Talk to Kemo).
    var origin: @MainActor () -> ReplyOrigin = { .chat }
    /// In-app notices while the app is in front (iPhone). Without one, nothing shows in front.
    weak var inApp: InAppNoticePresenting?

    init(center: NotificationCenterClient? = AccountDirectory.isTestHost ? nil : SystemNotificationCenter(),
         defaults: UserDefaults = .standard,
         isForeground: @escaping @MainActor () -> Bool = KemoNotifier.appIsInFront,
         signedIn: @escaping @MainActor () -> Bool = { !AppleAccountSession.shared.needsSignIn }) {
        self.center = center; self.defaults = defaults; self.isForeground = isForeground; self.signedIn = signedIn
    }
    static func appIsInFront() -> Bool {
        #if os(iOS)
        UIApplication.shared.applicationState == .active
        #elseif os(macOS)
        NSApp?.isActive ?? false
        #else
        false
        #endif
    }

    func isOn(_ kind: NotificationKind) -> Bool { kind.isOn(defaults) }
    func set(_ kind: NotificationKind, on: Bool) { defaults.set(on, forKey: kind.key) }
    /// Whether a system notification of this kind may be posted now.
    func allows(_ kind: NotificationKind) -> Bool { center != nil && signedIn() && !isForeground() && isOn(kind) }
    /// Where a notice of this kind, going to `link`, goes now (`NoticeDelivery.decide`).
    func delivery(_ kind: NotificationKind, link: NotificationLink) -> NoticeDelivery {
        let foreground = isForeground()
        return NoticeDelivery.decide(signedIn: signedIn(), switchOn: isOn(kind), foreground: foreground,
                                     looking: foreground && (inApp?.isLooking(at: link) ?? false),
                                     canPost: center != nil, canShowInApp: inApp != nil)
    }

    // MARK: Permission and categories

    func permission() async -> NotificationPermission { await center?.permission() ?? .notDetermined }
    /// Asks the system (only when the person taps something that turns notifications on).
    @discardableResult func requestPermission() async -> Bool {
        installCategories()
        return await center?.requestPermission() ?? false
    }
    /// Reply (typed on the notification, after unlocking), Review for Day, and View for your Mac's
    /// agents. Approving from the iPhone isn't offered: approvals happen on the Mac.
    func installCategories() {
        // The Mac has its own set (Approve and View, in `CodingTaskNotifications`); setting these
        // there would replace it.
        #if os(iOS)
        let reply = UNTextInputNotificationAction(identifier: Self.replyAction, title: "Reply", options: [.authenticationRequired],
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        let review = UNNotificationAction(identifier: Self.openAction, title: "Review", options: [.foreground])
        let view = UNNotificationAction(identifier: Self.openAction, title: "View", options: [.foreground])
        center?.setCategories([
            UNNotificationCategory(identifier: Self.replyCategory, actions: [reply], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.dayCategory, actions: [review], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.macCategory, actions: [view], intentIdentifiers: [])
        ])
        #endif
    }

    // MARK: Events

    /// Wraps a request's completion: when the reply finishes while the app is in the background,
    /// a notification follows (or, when the reply prepared something for Day, a Day notification).
    func replyCompletion(for store: AppStore, wrapping completion: ((String?) -> Void)?) -> ((String?) -> Void)? {
        let proposals = store.proposalRevision, origin = origin()
        return { [weak self, weak store] answer in
            if let self, let store {
                let conversation = store.state.openConversations?[store.currentConversationSlot]?.id
                self.replyFinished(answer, conversation: conversation, origin: origin, preparedForReview: store.proposalRevision != proposals)
            }
            completion?(answer)
        }
    }
    func replyFinished(_ answer: String?, conversation: UUID?, origin: ReplyOrigin, preparedForReview: Bool) {
        guard let answer = answer?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty else { return }
        let quiet = origin != .chat
        // With Your day on, a reply that prepared something is one Day notice, not a reply and a Day item.
        if preparedForReview, signedIn(), isOn(.day) {
            let body = "\(CompanionIdentity.name) prepared something for your review."
            switch delivery(.day, link: .day) {
            case .system:
                post(.day, id: "day-" + UUID().uuidString, title: "Your day", body: body,
                     link: .day, category: Self.dayCategory, thread: "kemo.day", quiet: quiet)
            case .inApp where !quiet:
                inApp?.show(.init(id: "day-" + UUID().uuidString, style: .day, title: "Your day", body: body, link: .day))
            default: break
            }
            return
        }
        let link = NotificationLink.conversation(conversation)
        switch delivery(.replies, link: link) {
        case .system:
            post(.replies, id: "reply-" + UUID().uuidString, title: CompanionIdentity.name, body: Self.replyBody(answer),
                 link: link, category: Self.replyCategory, thread: conversation.map { "chat-" + $0.uuidString } ?? "chat", quiet: quiet)
        // A reply you asked for on the watch or with Talk to Kemo is already where you asked.
        case .inApp where !quiet:
            let flat = answer.replacingOccurrences(of: "\n", with: " ")
            inApp?.show(.init(id: "reply-" + UUID().uuidString, style: .reply, title: CompanionIdentity.name, body: flat,
                              detail: flat.count > 400 ? String(flat.prefix(399)) + "…" : flat, link: link))
        default: break
        }
    }
    /// The iPhone shows a short preview (hidden on the Lock Screen until you unlock, with iOS's
    /// default "Show Previews: When Unlocked"); the Mac names the companion only, as it always has.
    static func replyBody(_ answer: String) -> String {
        #if os(macOS)
        return "Your reply is ready."
        #else
        let flat = answer.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 160 ? String(flat.prefix(159)) + "…" : flat
        #endif
    }
    /// A coding agent on your Mac needs you, or finished (the iPhone side of `CrossDeviceNotices`).
    @discardableResult func macNotice(_ notice: DeviceNotice) -> NoticeDelivery {
        let link = NotificationLink.macNotice(notice), delivery = delivery(.coding, link: link)
        switch delivery {
        case .system:
            post(.coding, id: notice.notificationID, title: notice.headline, subtitle: notice.project, body: notice.line,
                 link: link, category: Self.macCategory, thread: "mac-" + notice.task.uuidString, quiet: false,
                 timeSensitive: notice.kind == .approval)
        case .inApp:
            inApp?.show(.init(id: notice.notificationID, style: .mac(notice.kind), title: notice.headline, subtitle: notice.project,
                              body: notice.line, detail: notice.requestSummary.map { "Request: \($0). " + notice.line }, link: link))
        case .none: break
        }
        return delivery
    }

    private func post(_ kind: NotificationKind, id: String, title: String, subtitle: String? = nil, body: String,
                      link: NotificationLink, category: String, thread: String, quiet: Bool, timeSensitive: Bool = false) {
        guard allows(kind), let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle, !subtitle.isEmpty { content.subtitle = subtitle }
        content.body = body
        content.userInfo = link.userInfo
        content.categoryIdentifier = category
        content.threadIdentifier = thread
        // Normal by default, so Focus applies; time-sensitive only for approvals; quiet for replies
        // you already saw where you asked.
        content.interruptionLevel = quiet ? .passive : timeSensitive ? .timeSensitive : .active
        content.sound = quiet ? nil : .default
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
    /// Takes down notifications, and in-app notices, that were dealt with.
    func removeDelivered(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        center?.removeDelivered(identifiers); inApp?.withdraw(identifiers)
    }
}

// MARK: Your Mac's agents, on your iPhone

/// A short-lived notice one device leaves for the person's others: a coding agent on the Mac needs
/// approval, finished, or failed. It carries no message text: the kind, the agent's name, the
/// project folder's name, what kind of request it is, and when. The task's title isn't included,
/// because it starts as the first thing you typed.
struct DeviceNotice: Codable, Equatable, Identifiable, Hashable {
    enum Kind: String, Codable { case approval, finished, failed }
    /// What an approval asks for; never the command or the question itself.
    enum Request: String, Codable { case command, files, question }
    var id: UUID
    var kind: Kind
    var task: UUID
    /// "Claude Code" or "Codex".
    var agent: String
    /// The project folder's name.
    var project: String?
    var request: Request?
    var time: Date

    static let approvalLifetime: TimeInterval = 2 * 3600
    static let resultLifetime: TimeInterval = 30 * 60
    var lifetime: TimeInterval { kind == .approval ? Self.approvalLifetime : Self.resultLifetime }
    func expired(at date: Date) -> Bool { date.timeIntervalSince(time) > lifetime || time.timeIntervalSince(date) > 300 }
    var notificationID: String { "mac-" + id.uuidString }
    var headline: String {
        switch kind { case .approval: "\(agent) needs you"; case .finished: "\(agent) finished"; case .failed: "\(agent) stopped" }
    }
    var line: String {
        switch kind {
        case .approval: "Approve it on your Mac."
        case .finished: "Ready for review on your Mac."
        case .failed: "It hit a problem. Check it on your Mac."
        }
    }
    var requestSummary: String? {
        switch request {
        case .command: "Run a command"
        case .files: "Change files"
        case .question: "Answer a question"
        case nil: nil
        }
    }
}

/// One device's notices, kept as a single `SyncRecord` (type `notice`, ID `notices-<device>`) in the
/// account's personal zone, so it never grows: at most `limit` notices, each gone when it expires
/// or is dealt with. Only the device that writes a board changes it.
struct NoticeBoard: Codable, Equatable {
    static let limit = 8
    var device: String
    var items: [DeviceNotice] = []
    static func recordID(device: String) -> String { "notices-" + device }
}

/// Writes this Mac's notices through sync, and on iPhone turns other devices' notices into local
/// notifications. A silent CloudKit push (the personal zone's subscription) wakes the iPhone; it
/// syncs, then calls `deliver`.
@MainActor final class CrossDeviceNotices {
    static var shared = CrossDeviceNotices()
    private let engine: @MainActor () -> SyncEngine?
    private let defaults: UserDefaults
    private let now: () -> Date
    private let notifier: @MainActor () -> KemoNotifier
    /// Starts a sync right after a notice is written (the app's sync service).
    var syncNow: @MainActor () -> Void
    static let seenKey = "kemo.notices.seen", postedKey = "kemo.notices.posted"

    init(engine: @escaping @MainActor () -> SyncEngine? = { AccountRecords.shared.engine }, defaults: UserDefaults = AccountDirectory.settings,
         now: @escaping () -> Date = Date.init, notifier: @escaping @MainActor () -> KemoNotifier = { KemoNotifier.shared },
         syncNow: @escaping @MainActor () -> Void = { AccountSyncService.shared.syncSoon(after: .zero) }) {
        self.engine = engine; self.defaults = defaults; self.now = now; self.notifier = notifier; self.syncNow = syncNow
    }

    private var device: String? { engine()?.device }
    private func board(_ engine: SyncEngine, device: String) -> NoticeBoard {
        let key = SyncZone.personal.name + "/" + NoticeBoard.recordID(device: device)
        guard let record = engine.state.records[key], !record.deleted,
              let board = try? JSONDecoder().decode(NoticeBoard.self, from: record.payload) else { return .init(device: device) }
        return board
    }
    /// This device's notices now.
    var mine: [DeviceNotice] {
        guard let engine = engine(), let device else { return [] }
        return board(engine, device: device).items
    }

    // MARK: Writing (Mac)

    /// Leaves a notice for the person's other devices. A newer notice for the same task replaces
    /// the older one. Nothing is written while signed out or without an Apple account.
    func publish(_ notice: DeviceNotice) {
        guard notifier().signedIn(), let engine = engine(), let device else { return }
        var board = board(engine, device: device)
        let date = now()
        board.items.removeAll { $0.task == notice.task || $0.expired(at: date) }
        board.items.append(notice)
        board.items = Array(board.items.suffix(NoticeBoard.limit))
        write(board, engine: engine, at: date)
    }
    /// The approval was answered (or the task stopped): its notice goes, so the iPhone takes its
    /// notification down too.
    func resolve(task: UUID) {
        guard let engine = engine(), let device else { return }
        var board = board(engine, device: device)
        let date = now(), before = board.items
        board.items.removeAll { ($0.task == task && $0.kind == .approval) || $0.expired(at: date) }
        if board.items != before { write(board, engine: engine, at: date) }
    }
    private func write(_ board: NoticeBoard, engine: SyncEngine, at date: Date) {
        do {
            try engine.put(board, id: NoticeBoard.recordID(device: board.device), type: SyncType.notice, zone: .personal, at: date)
            syncNow()
        } catch {}
    }

    // MARK: Reading (iPhone)

    /// Posts a notification for each other device's notice that's new and still current, and takes
    /// down notifications for approvals that were dealt with. A notice that arrives while the app
    /// is in front shows in the app instead (iPhone); signed out or with Coding agents off, it's
    /// only marked seen.
    func deliver() {
        guard let engine = engine() else { return }
        let date = now(), own = device
        var seen = Set(defaults.stringArray(forKey: Self.seenKey) ?? [])
        var posted = defaults.stringArray(forKey: Self.postedKey) ?? []
        var live = Set<String>()
        let boards = engine.state.records.values
            .filter { $0.zone == .personal && $0.type == SyncType.notice && !$0.deleted }
            .compactMap { try? JSONDecoder().decode(NoticeBoard.self, from: $0.payload) }
            .filter { $0.device != own }
        let notifier = notifier()
        for notice in boards.flatMap(\.items).sorted(by: { $0.time < $1.time }) {
            let id = notice.id.uuidString
            live.insert(id)
            guard !seen.contains(id) else { continue }
            seen.insert(id)
            guard !notice.expired(at: date) else { continue }
            // A notification in the background, or an in-app notice while KemoSabe is open.
            if notifier.macNotice(notice) != .none, notice.kind == .approval { posted.append(id) }
        }
        let gone = posted.filter { !live.contains($0) }
        notifier.removeDelivered(gone.map { "mac-" + $0 })
        posted.removeAll { gone.contains($0) }
        defaults.set(Array(seen.filter { live.contains($0) }.prefix(64)), forKey: Self.seenKey)
        defaults.set(Array(posted.suffix(16)), forKey: Self.postedKey)
    }
}

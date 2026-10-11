import SwiftUI
import UIKit
import UserNotifications

/// Notifications (design/UI-GUIDE.md, Notifications and toasts): only for what happens while Tsukumo isn't in front
/// (a bot replied, or a bot is waiting for your OK to ask KemoSabe), each opening its chat. Everything that happens
/// while you're looking is a toast in the chat instead. Local notifications only: nothing goes through a server.
@MainActor @Observable final class TsukumoNotifications: NSObject, UNUserNotificationCenterDelegate {
    enum Status: Equatable { case unknown, notAsked, on, off }
    private(set) var status: Status = .unknown
    /// The chat a tapped notification asked for; the app opens it and clears this.
    var requestedThread: UUID?
    /// Whether the owner turned them off here (iOS may still allow them).
    var enabled: Bool {
        get { !UserDefaults.standard.bool(forKey: Self.offKey) }
        set { UserDefaults.standard.set(!newValue, forKey: Self.offKey) }
    }
    private static let offKey = "notifications.off"
    private static let askedKey = "notifications.asked"
    private let center = UNUserNotificationCenter.current()
    /// Off in UI tests and the demo: nothing asks iOS, nothing is posted.
    private let live: Bool
    private var background = UIBackgroundTaskIdentifier.invalid

    init(live: Bool) {
        self.live = live
        super.init()
        guard live else { return }
        center.delegate = self
        Task { await refresh() }
    }

    func refresh() async {
        guard live else { return }
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: status = .notAsked
        case .authorized, .provisional, .ephemeral: status = .on
        default: status = .off
        }
    }

    /// Asks iOS once, the first time you send a bot something (when a reply you might miss is on its way).
    func askOnce() {
        guard live, !UserDefaults.standard.bool(forKey: Self.askedKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.askedKey)
        Task { await ask() }
    }

    func ask() async {
        guard live else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        await refresh()
    }

    /// "Claude replied", with the start of the reply. Only while Tsukumo isn't in front.
    func replied(_ name: String, text: String, thread: UUID) {
        post(id: "reply-\(thread)", title: "\(name) replied", body: text, thread: thread)
    }

    /// "Claude wants to ask KemoSabe", with the question.
    func needsConsent(_ asker: String, question: String, thread: UUID) {
        post(id: "consent-\(thread)", title: "\(asker) wants to ask KemoSabe", body: "“\(question)” Open Tsukumo to allow it or not.", thread: thread)
    }

    private func post(id: String, title: String, body: String, thread: UUID) {
        guard live, enabled, status == .on, UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(240))
        content.sound = .default
        content.threadIdentifier = thread.uuidString
        content.userInfo = ["thread": thread.uuidString]
        // The same chat's newer notification replaces the older one.
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// Leaving the app while a bot works: ask iOS for the time to finish, so its reply (and its notification) lands.
    func keepFinishing(while busy: @escaping @MainActor () -> Bool) {
        guard live, background == .invalid, busy() else { return }
        background = UIApplication.shared.beginBackgroundTask(withName: "Finish the reply") { [weak self] in self?.endBackground() }
        Task { [weak self] in
            while let self, self.background != .invalid, busy() { try? await Task.sleep(for: .milliseconds(500)) }
            self?.endBackground()
        }
    }

    private func endBackground() {
        guard background != .invalid else { return }
        UIApplication.shared.endBackgroundTask(background)
        background = .invalid
    }

    /// Back in Tsukumo: what's in Notification Center for chats is old news.
    func clearDelivered() {
        guard live else { return }
        center.removeAllDeliveredNotifications()
        center.setBadgeCount(0)
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // In front, the chat itself shows it.
        []
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = (response.notification.request.content.userInfo["thread"] as? String).flatMap(UUID.init(uuidString:))
        await MainActor.run { self.requestedThread = id }
    }
}

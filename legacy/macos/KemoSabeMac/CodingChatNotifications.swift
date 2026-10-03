import AppKit
import CoreGraphics
import SwiftUI
import UserNotifications

/// Tells you when a coding task finishes, fails, or waits for approval while Tsukumo is in the
/// background. An approval notification shows what the agent wants to run and offers Approve
/// (allow once, only if that same request is still waiting) or View. When you're away from the Mac
/// (idle for two minutes, or the screen is locked), the same event is left for your iPhone as a
/// text-free notice through sync (`CrossDeviceNotices`), and taken back once it's dealt with.
@MainActor final class CodingTaskNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CodingTaskNotifications()
    static let category = "tsukumo.task.approval"
    /// Settings → Notifications → Coding agents (on unless turned off).
    static var enabled: Bool { !KemoSabeMacApp.isTestHost && KemoNotifier.shared.isOn(.coding) }
    weak var coding: CodingWorkspaceStore?
    /// Brings the window forward and opens a task.
    var open: ((UUID) -> Void)?
    /// Whether the person is away from this Mac, so their iPhone should hear about it.
    var away: @MainActor () -> Bool = CodingTaskNotifications.awayFromMac
    private var asked = false
    /// Installs the delegate and the Approve/View actions (once, at launch).
    func install(coding: CodingWorkspaceStore, open: @escaping (UUID) -> Void) {
        self.coding = coding; self.open = open
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let approve = UNNotificationAction(identifier: "approve", title: "Approve", options: [])
        let view = UNNotificationAction(identifier: "view", title: "View", options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [approve, view], intentIdentifiers: [])])
    }
    /// Asked while you're starting a task (in the foreground), never from the background.
    func requestPermissionIfNeeded() {
        guard Self.enabled, !asked else { return }
        asked = true
        Task { await KemoNotifier.shared.requestPermission() }
    }
    func finished(_ task: CodingTaskRecord, state: CodingTaskStatus) {
        guard state == .review || state == .failed else { return }
        leaveNotice(Self.notice(for: task, state: state))
        guard Self.enabled, KemoNotifier.shared.allows(.coding) else { return }
        let content = UNMutableNotificationContent()
        content.title = task.title
        content.body = state == .failed ? "\(task.provider.title) stopped with a problem." : "\(task.provider.title) finished. Review the changes."
        content.userInfo = ["task": task.id.uuidString]
        content.threadIdentifier = task.id.uuidString
        content.interruptionLevel = .active
        post(content, id: "finished-" + task.id.uuidString)
    }
    func needsApproval(_ task: CodingTaskRecord, approval: CodingApproval) {
        leaveNotice(Self.notice(for: task, approval: approval))
        guard Self.enabled, KemoNotifier.shared.allows(.coding) else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(task.provider.title) needs approval"
        content.subtitle = task.title
        content.body = approval.kind == .question ? "It has a question for you." : String(approval.title.prefix(180))
        content.userInfo = ["task": task.id.uuidString, "approval": approval.id]
        content.threadIdentifier = task.id.uuidString
        // Questions need an answer and risky commands a look, so they only offer View.
        if approval.kind != .question, !approval.risk.dangerous { content.categoryIdentifier = Self.category }
        content.sound = .default
        // The one kind that may break through a Focus (with the Time Sensitive capability).
        content.interruptionLevel = .timeSensitive
        post(content, id: "approval-" + task.id.uuidString)
    }
    /// The approval was answered or the task stopped: the iPhone's notice goes too.
    func approvalCleared(_ task: UUID) { CrossDeviceNotices.shared.resolve(task: task) }
    private func leaveNotice(_ notice: DeviceNotice) {
        guard !KemoSabeMacApp.isTestHost, away() else { return }
        CrossDeviceNotices.shared.publish(notice)
    }
    /// What the iPhone is told: the kind, the agent, the project folder, the kind of request, and
    /// when. Never the task's title, the command, the question, or any message.
    static func notice(for task: CodingTaskRecord, state: CodingTaskStatus, at date: Date = Date()) -> DeviceNotice {
        .init(id: UUID(), kind: state == .failed ? .failed : .finished, task: task.id, agent: task.provider.title,
              project: projectName(task), request: nil, time: date)
    }
    static func notice(for task: CodingTaskRecord, approval: CodingApproval, at date: Date = Date()) -> DeviceNotice {
        let request: DeviceNotice.Request = switch approval.kind { case .command: .command; case .files: .files; case .question: .question }
        return .init(id: UUID(), kind: .approval, task: task.id, agent: task.provider.title, project: projectName(task), request: request, time: date)
    }
    /// The project folder's name; the task's title isn't sent, since it starts as the first message.
    static func projectName(_ task: CodingTaskRecord) -> String? {
        let name = URL(fileURLWithPath: task.projectPath).lastPathComponent
        return name.isEmpty || name == "/" ? nil : String(name.prefix(60))
    }
    /// Idle for two minutes, or the screen is locked.
    static func awayFromMac() -> Bool {
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any], session["CGSSessionScreenIsLocked"] as? Bool == true { return true }
        guard let any = CGEventType(rawValue: ~0) else { return false }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any) >= 120
    }
    private func post(_ content: UNMutableNotificationContent, id: String) {
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let raw = info["task"] as? String, let id = UUID(uuidString: raw) else { return }
        let approvalID = info["approval"] as? String, action = response.actionIdentifier
        await MainActor.run {
            if action == "approve", let approvalID, let coding, let pending = coding.approvals[id], pending.id == approvalID, !pending.risk.dangerous {
                coding.respond(id, allow: true)
            } else { open?(id) }
        }
    }
}

/// Settings → Notifications: the permission, then one switch per kind, from the same list as the
/// iPhone (`NotificationKind`).
struct MacNotificationsPage: View {
    @State private var permission: NotificationPermission?
    @State private var switches: [NotificationKind: Bool] = [:]
    private var notifier: KemoNotifier { .shared }
    var body: some View {
        SettingsContent {
            SettingsCard(title: "") { permissionRow }
            SettingsCard(title: "Notify me") {
                ForEach(NotificationKind.allCases) { kind in
                    SettingsRow(title: kind.title, detail: kind.detail) {
                        Toggle(kind.title, isOn: binding(kind)).labelsHidden().accessibilityIdentifier("notify-" + kind.rawValue)
                    }
                    if kind != NotificationKind.allCases.last { Divider() }
                }
            }
            Text("Approve allows only the request shown; risky commands and questions open Tsukumo.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await refresh() } }
    }
    @ViewBuilder private var permissionRow: some View {
        switch permission {
        case .allowed:
            SettingsRow(title: "Notifications") { Text("On").foregroundStyle(.secondary).accessibilityIdentifier("notificationPermission") }
        case .notDetermined:
            SettingsRow(title: "Notifications", detail: "Not turned on yet") {
                Button("Turn On") { Task { await notifier.requestPermission(); await refresh() } }.accessibilityIdentifier("allowNotifications")
            }
        case .denied:
            SettingsRow(title: "Notifications", detail: "Off for Tsukumo in System Settings") {
                Button("Open System Settings") {
                    let id = Bundle.main.bundleIdentifier ?? ""
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=" + id) { NSWorkspace.shared.open(url) }
                }.accessibilityIdentifier("openNotificationSettings")
            }
        case nil:
            SettingsRow(title: "Notifications") { EmptyView() }
        }
    }
    private func binding(_ kind: NotificationKind) -> Binding<Bool> {
        Binding(get: { switches[kind] ?? notifier.isOn(kind) }, set: { on in
            switches[kind] = on; notifier.set(kind, on: on)
            if on, permission == .notDetermined { Task { await notifier.requestPermission(); await refresh() } }
        })
    }
    private func refresh() async { permission = await notifier.permission() }
}

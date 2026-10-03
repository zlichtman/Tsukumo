import SwiftUI
import UIKit
import UserNotifications

// The iPhone's side of notifications: where a tap goes, the Reply action, notices from your Mac,
// and Settings → Notifications. What gets posted is decided in `KemoNotifier`.

/// Where the next notification tap should take the app. `NotificationRouting` (on the root view)
/// acts on it; the delegate sets it, even before the UI exists on a cold launch.
@MainActor @Observable final class NotificationRoutes {
    static let shared = NotificationRoutes()
    var pending: NotificationLink?
    /// "Approve it on your Mac", shown as a sheet.
    var macNotice: DeviceNotice?
    @ObservationIgnored private(set) weak var store: AppStore?
    /// The open account's store (set at launch and after every account switch).
    func use(_ store: AppStore) { self.store = store }
}

/// The notification center's delegate: taps, the Reply action, and nothing shown while KemoSabe is
/// in front (Kemo is already on screen).
final class PhoneNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PhoneNotificationDelegate()
    /// The test notification from Settings → Notifications shows even with KemoSabe open.
    static let testPrefix = "kemo.test"
    @MainActor func install() {
        guard !AccountDirectory.isTestHost else { return }
        UNUserNotificationCenter.current().delegate = self
        KemoNotifier.shared.installCategories()
        // While KemoSabe is in front, notices grow out of the Dynamic Island instead (`InAppNotices.swift`).
        KemoNotifier.shared.inApp = InAppNoticeCenter.shared
        // Your Mac's notices arrive with sync (a silent CloudKit push, or any other sync).
        AccountSyncService.shared.onSynced = { CrossDeviceNotices.shared.deliver() }
        KemoNotifier.shared.origin = {
            if VoiceAnywhere.shared.running { return .talkToKemo }
            return WatchBridge.shared.answeringWatch ? .watch : .chat
        }
        #if DEBUG
        // UI tests open a notification's destination as if it had been tapped.
        if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--notification-link=") }) {
            switch argument.dropFirst("--notification-link=".count) {
            case "day": NotificationRoutes.shared.pending = .day
            case "mac-approval":
                NotificationRoutes.shared.pending = .macNotice(.init(id: UUID(), kind: .approval, task: UUID(), agent: "Claude Code",
                                                                     project: "KemoSabe", request: .command, time: Date()))
            default: break
            }
        }
        #endif
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        notification.request.identifier.hasPrefix(Self.testPrefix) ? [.banner, .list, .sound] : []
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let link = NotificationLink(userInfo: info) else { return }
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText
        await MainActor.run {
            guard !AppleAccountSession.shared.needsSignIn else { return }
            if action == KemoNotifier.replyAction, let text, case .conversation(let id) = link {
                Self.reply(text, in: id)
            } else if action != UNNotificationDismissActionIdentifier {
                NotificationRoutes.shared.pending = link
            }
        }
    }
    /// Answers the Reply action without opening the app: the message joins its conversation (when
    /// that's the one open, or it can be continued with the same model), and Kemo's answer comes
    /// back as a notification.
    @MainActor static func reply(_ text: String, in conversation: UUID?) {
        guard let store = NotificationRoutes.shared.store, store.canChat, !store.isThinking, !store.working else { return }
        if let conversation, store.state.openConversations?[store.currentConversationSlot]?.id != conversation {
            guard let archive = store.state.conversationArchives?.first(where: { $0.id == conversation }), store.canResume(archive) else { return }
            store.resumeArchivedConversation(conversation)
        }
        var lease = UIBackgroundTaskIdentifier.invalid
        lease = UIApplication.shared.beginBackgroundTask(withName: "KemoNotificationReply") {
            if lease != .invalid { UIApplication.shared.endBackgroundTask(lease); lease = .invalid }
        }
        store.send(text, completion: { _ in
            if lease != .invalid { UIApplication.shared.endBackgroundTask(lease); lease = .invalid }
        })
    }
}

/// Acts on a notification tap: the conversation in Chat, Day, or "Approve it on your Mac".
struct NotificationRouting: ViewModifier {
    @Environment(AppStore.self) private var store
    @Environment(AppNavigation.self) private var navigation
    @State private var routes = NotificationRoutes.shared
    func body(content: Content) -> some View {
        content
            .onChange(of: routes.pending, initial: true) { route() }
            .sheet(item: $routes.macNotice) { MacNoticeView(notice: $0) }
    }
    private func route() {
        guard let link = routes.pending else { return }
        routes.pending = nil
        guard !AppleAccountSession.shared.needsSignIn else { return }
        switch link {
        case .conversation(let id):
            navigation.home()
            if let id, store.state.openConversations?[store.currentConversationSlot]?.id != id,
               let archive = store.state.conversationArchives?.first(where: { $0.id == id }), store.canResume(archive) {
                store.resumeArchivedConversation(id)
            }
            navigation.requestedTab = "Chat"
        case .day:
            navigation.home(); navigation.requestedTab = "Day"
        case .macNotice(let notice):
            routes.macNotice = notice
        }
    }
}

/// A coding agent on your Mac needs you. Approving from the iPhone isn't offered: it says where to
/// do it and what the request was, without any of its text.
struct MacNoticeView: View {
    let notice: DeviceNotice
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mobilePalette) private var palette
    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: notice.kind == .approval ? "laptopcomputer.and.arrow.down" : notice.kind == .failed ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.system(size: 44, weight: .regular)).foregroundStyle(notice.kind == .failed ? Color.orange : palette.accent)
                    .padding(.top, 28)
                Text(title).font(KemoType.font(.title2, weight: .semibold)).multilineTextAlignment(.center)
                    .accessibilityIdentifier("macNoticeTitle")
                VStack(spacing: 0) {
                    row("Agent", notice.agent)
                    if let project = notice.project { row("Project", project) }
                    if let request = notice.requestSummary { row("Request", request) }
                    row("When", notice.time.formatted(.relative(presentation: .named)))
                }.background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
                Spacer()
            }.padding(.horizontal, 20).frame(maxWidth: 480)
                .frame(maxWidth: .infinity).background(palette.background.ignoresSafeArea())
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(role: .close) { dismiss() }.accessibilityIdentifier("closeMacNotice") } }
        }.presentationDetents([.medium, .large])
    }
    private var title: String {
        switch notice.kind {
        case .approval: "Approve it on your Mac"
        case .finished: "Ready for review on your Mac"
        case .failed: "Stopped on your Mac"
        }
    }
    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).lineLimit(1).truncationMode(.middle)
        }.font(KemoType.font(.body)).padding(.horizontal, 16).padding(.vertical, 12)
    }
}

/// Settings → Notifications: the permission, one switch per kind, and the watch's nudges.
struct NotificationSettingsPage: View {
    @Environment(\.mobilePalette) private var palette
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var permission: NotificationPermission?
    @State private var switches: [NotificationKind: Bool] = [:]
    @State private var pet = WatchLink.PetSummary.saved()
    @State private var developer = DeveloperMode.shared
    @State private var testNote: String?
    private var notifier: KemoNotifier { .shared }
    var body: some View {
        Form {
            Section { permissionRow }
            Section {
                ForEach(NotificationKind.allCases) { kind in
                    Toggle(isOn: binding(kind)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind.title)
                            Text(kind.detail).font(KemoType.font(.footnote)).foregroundStyle(.secondary)
                        }
                    }.accessibilityIdentifier("notify-" + kind.rawValue)
                }
            } footer: {
                Text("Replies to the watch or Talk to KemoSabe arrive quietly.")
            }
            Section("\(CompanionIdentity.name) on Apple Watch") {
                LabeledContent {
                    Text(pet?.nudges.map { $0 ? "On" : "Off" } ?? "On your watch").accessibilityIdentifier("watchNudgesState")
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nudges")
                        Text("Change it on the watch: Settings → Nudges").font(KemoType.font(.footnote)).foregroundStyle(.secondary)
                    }
                }
            }
            if developer.enabled || ProcessInfo.processInfo.arguments.contains("--notification-probe") {
                Section {
                    Button("Send a test notification") { Task { await sendTest() } }.accessibilityIdentifier("sendTestNotification")
                    if let testNote { Text(testNote).font(KemoType.font(.footnote)).foregroundStyle(.secondary).accessibilityIdentifier("testNotificationNote") }
                } header: { DeveloperHeader() }
            }
        }
        .scrollContentBackground(.hidden).background(palette.background)
        .navigationTitle("Notifications").navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .onChange(of: scenePhase) { if scenePhase == .active { Task { await refresh() } } }
        .onReceive(NotificationCenter.default.publisher(for: WatchLink.PetSummary.changed).receive(on: RunLoop.main)) { _ in pet = .saved() }
    }
    @ViewBuilder private var permissionRow: some View {
        switch permission {
        case .allowed:
            LabeledContent { Text("On").accessibilityIdentifier("notificationPermission") } label: { Text("Notifications") }
        case .notDetermined:
            Button("Turn on notifications") { Task { await notifier.requestPermission(); await refresh() } }
                .accessibilityIdentifier("allowNotifications")
        case .denied:
            Text("Notifications are off for KemoSabe.").foregroundStyle(.secondary).accessibilityIdentifier("notificationPermission")
            Button("Open Settings") { if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) } }
                .accessibilityIdentifier("openNotificationSettings")
        case nil:
            KemoOrb(size: 14).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func binding(_ kind: NotificationKind) -> Binding<Bool> {
        Binding(get: { switches[kind] ?? notifier.isOn(kind) }, set: { on in
            switches[kind] = on; notifier.set(kind, on: on)
            // Turning one on is the moment to ask, if nobody has yet.
            if on, permission == .notDetermined { Task { await notifier.requestPermission(); await refresh() } }
        })
    }
    private func refresh() async {
        permission = await notifier.permission()
        #if DEBUG
        // UI tests show each permission state without the system's alert.
        switch ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--notification-permission=") })?.split(separator: "=").last {
        case "denied": permission = .denied
        case "notDetermined": permission = .notDetermined
        case "allowed": permission = .allowed
        default: break
        }
        #endif
        pet = .saved()
    }
    /// Five seconds later, so there's time to lock the iPhone or leave the app.
    private func sendTest() async {
        if permission == .notDetermined { await notifier.requestPermission(); await refresh() }
        guard permission == .allowed else { testNote = "Notifications are off."; return }
        let content = UNMutableNotificationContent()
        content.title = CompanionIdentity.name; content.body = "Notifications work."; content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: PhoneNotificationDelegate.testPrefix + "-" + UUID().uuidString, content: content, trigger: trigger))
            testNote = "Sent. It arrives in 5 seconds."
        } catch { testNote = "Couldn't send: \(error.localizedDescription)" }
    }
}

import AppKit
import SwiftUI
import TsukumoDock
import TsukumoUpdate
@preconcurrency import UserNotifications

// Settings, General, Software Update (TsukumoKit's TsukumoUpdate does the work): the status line, with an
// update's notes; one button that is Check for Updates, Download, or Install and Relaunch; Open the Download
// when Tsukumo can't replace itself; and Check automatically (on) and Download updates automatically (off).

struct SoftwareUpdateCard: View {
    @Bindable var updates: UpdateService

    private var buttonTitle: String {
        switch updates.action {
        case .check: "Check for Updates"
        case .download: "Download"
        case .install: "Install and Relaunch"
        }
    }
    private var isOff: Bool { if case .off = updates.status { true } else { false } }

    var body: some View {
        SettingsCard("Software Update", systemImage: "arrow.down.circle") {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if updates.status.isBusy { ProgressView().controlSize(.small) }
                        Text(updates.status.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(updates.status.isFailure ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.primary))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let notes = updates.status.notes {
                        Text(notes).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else if let last = updates.lastChecked, !isOff {
                        Text("Last checked " + last.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("updateStatus")
                Spacer(minLength: 8)
                if updates.canOpenDownload {
                    Button("Open the Download") { updates.openDownload() }
                        .accessibilityIdentifier("openUpdateDownload")
                }
                Button(buttonTitle) { updates.trigger() }
                    .buttonStyle(.bordered)
                    .disabled(isOff || updates.status.isBusy)
                    .accessibilityIdentifier("checkForUpdates")
            }
            Divider()
            Toggle("Check automatically", isOn: $updates.checksAutomatically)
                .accessibilityIdentifier("checkUpdatesAutomatically")
            Toggle("Download updates automatically", isOn: $updates.downloadsAutomatically)
                .disabled(!updates.checksAutomatically)
                .accessibilityIdentifier("downloadUpdatesAutomatically")
            SettingsNote("Updates come from zlichtman.com. Before one is offered, Tsukumo checks its checksum, its developer’s signature, and Apple’s notarization. It installs only when you click Install and Relaunch.")
        }
        .onChange(of: updates.downloadsAutomatically) { _, on in
            // The only time Tsukumo asks to send notifications: so it can say when an update is ready.
            if on { UpdateNotices.askIfUndecided() }
        }
    }
}

/// "Tsukumo X is ready to install", only when the owner allows Tsukumo's notifications; clicking it opens
/// Settings, General.
final class UpdateNotices: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let open: @MainActor () -> Void

    init(open: @escaping @MainActor () -> Void) {
        self.open = open
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func ready(_ feed: UpdateFeed) {
        let content = UNMutableNotificationContent()
        content.title = "Tsukumo \(feed.version) is ready to install"
        content.body = feed.notes.isEmpty ? "Open Settings, General, and click Install and Relaunch." : feed.notes
        let request = UNNotificationRequest(identifier: "tsukumo-update-\(feed.build)", content: content, trigger: nil)
        Task {
            let center = UNUserNotificationCenter.current()
            switch await center.notificationSettings().authorizationStatus {
            case .authorized, .provisional, .ephemeral: try? await center.add(request)
            default: break
            }
        }
    }

    static func askIfUndecided() {
        Task {
            let center = UNUserNotificationCenter.current()
            guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert])
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let open = self.open
        await MainActor.run { open() }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner]
    }
}

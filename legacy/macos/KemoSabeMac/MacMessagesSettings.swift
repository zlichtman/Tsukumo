import SwiftUI
import AppKit

/// Settings → Connections → Messages on the Mac: Full Disk Access, the owner's switch, and the level.
/// Access is checked when the page shows and when the owner comes back from System Settings.
struct MacMessagesSettingsCard: View {
    @State private var settings = PersonalSourceSettings.shared
    @State private var access: MacMessagesAccess = .noHistory
    var body: some View {
        SettingsCard(title: "Messages") {
            SettingsRow(title: "Messages on this Mac", detail: detail) {
                switch access {
                case .granted:
                    Toggle("", isOn: $settings.messages).labelsHidden().toggleStyle(.switch).accessibilityIdentifier("macMessagesToggle")
                case .needsFullDiskAccess:
                    Button("Open System Settings…") { NSWorkspace.shared.open(MacMessagesAccess.fullDiskAccessSettings) }
                        .accessibilityIdentifier("macMessagesFullDiskAccess")
                case .noHistory:
                    Text("Not set up").foregroundStyle(.secondary)
                }
            }
            if access == .granted {
                Divider()
                SettingsRow(title: "Privacy", detail: settings.messagesLevel == .deviceOnly
                            ? "Only Apple’s on-device model reads them. Agents never get them."
                            : "Apple’s models read them. An agent gets one excerpt only when you share it.") {
                    Picker("", selection: $settings.messagesLevel) {
                        ForEach(PersonalSourceSettings.messageLevels) { Text($0.title).tag($0) }
                    }.labelsHidden().pickerStyle(.segmented).frame(width: 220).accessibilityIdentifier("macMessagesLevel")
                }
            }
        }
        Text("With Messages in iCloud, this Mac holds your message history. When it’s on, KemoSabe reads it here, read-only, to answer a question like “what did Sarah say about Friday”: a few short messages at a time, never a whole conversation. Nothing from it is saved or synced.")
            .font(.caption).foregroundStyle(.secondary)
            .onAppear(perform: check)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in check() }
    }
    private var detail: String {
        switch access {
        case .granted: settings.messages ? "On. KemoSabe can answer from your messages." : "Off. Turn on to let KemoSabe answer from your messages."
        case .needsFullDiskAccess: "macOS keeps Messages private. In System Settings → Privacy & Security → Full Disk Access, turn on Tsukumo, then come back."
        case .noHistory: "There are no messages on this Mac. Turn on Messages in iCloud in the Messages app’s settings."
        }
    }
    private func check() {
        guard let database = MessagesDatabase.system else { access = .noHistory; return }
        Task.detached(priority: .userInitiated) {
            let result = database.access()
            await MainActor.run { access = result }
        }
    }
}

import SwiftUI

/// Settings → Agents → MacSpaces: whether Tsukumo is answering MacSpaces' quick-task bar, and
/// why not when it isn't. Status only; there is no separate on/off switch.
struct MacSpacesBridgeCard: View {
    @State private var status = MacSpacesBridgeStatus.shared
    var body: some View {
        SettingsCard(title: "MacSpaces") {
            SettingsRow(title: "Quick tasks from MacSpaces", detail: detail) {
                HStack(spacing: 10) {
                    Text(label).foregroundStyle(failed ? Color.orange : Color.secondary)
                    if failed, status.retry != nil {
                        Button("Try again") { status.retry?() }.buttonStyle(DesktopButtonStyle()).accessibilityIdentifier("macSpacesBridgeRetry")
                    }
                }
            }
            if let refusal = status.lastRefusal {
                Divider()
                SettingsRow(title: "Last refused connection", detail: refusal.note + " " + refusal.date.formatted(date: .omitted, time: .shortened)) {
                    Image(systemName: "hand.raised").foregroundStyle(.secondary)
                }
            }
        }.accessibilityIdentifier("macSpacesBridge")
    }
    private var failed: Bool { if case .failed = status.state { true } else { false } }
    private var label: String {
        switch status.state {
        case .listening: "Listening"
        case .failed: "Not running"
        case .off: "Off"
        }
    }
    private var detail: String {
        var lines: [String]
        switch status.state {
        case .listening: lines = ["MacSpaces can list this account's coding tasks and the open KemoSabe chat, start a new quick task, send what you typed or picked to attach, show progress, stop, and open it here. Approvals stay in Tsukumo."]
        case .failed(let reason): lines = ["The receiver didn't start, so MacSpaces can't reach Tsukumo: " + reason]
        case .off(let reason): lines = [reason]
        }
        if let last = status.lastRequest { lines.append("Last request: \(last.operation), \(last.date.formatted(date: .omitted, time: .shortened)).") }
        return lines.joined(separator: " ")
    }
}

/// The open KemoSabe chat, for MacSpaces quick tasks. Sending goes through the same `send` as the
/// chat's own composer, with its sign-in, privacy, and model rules; MacSpaces never picks a model.
extension AppStore: MacSpacesPersonalChat {
    var bridgeChatID: UUID? { conversationMessages.isEmpty ? nil : conversationID(for: currentConversationSlot) }
    var bridgeReplying: Bool { isThinking || working }
    var bridgeReady: Bool { canChat && !AppleAccountSession.shared.needsSignIn }
    var bridgeLastMessage: UUID? { conversationMessages.last?.id }
    var bridgeError: String? { error }
    func bridgeStartNewChat() { newConversation() }
    func bridgeSend(_ text: String) { send(text) }
    func bridgeStop() { cancel() }
}

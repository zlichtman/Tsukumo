#if os(macOS)
import SwiftUI
import TsukumoCore
import TsukumoGateway
import TsukumoUI

// The KemoSabe gateway's cards, where KemoSabe's own cards are: in KemoSabe's chat beside the dock (its tile needs
// you while one waits, and a speech bubble names the caller), and in Settings, Gateway. A card's words are the
// gateway's own, never the caller's: "Grok asked KemoSabe a question that needs your personal information." What
// would leave (an excerpt, a file's name, KemoSabe's Sensitive answer) shows under it, on this Mac only.

/// One caller's request waiting on the owner.
public struct GatewayRequestCard: View {
    let request: GatewayApprovalRequest
    /// Who it's from and how it came (`BotDock.identityLine`).
    let identity: String?
    let answer: (GatewayApproval) -> Void
    @Environment(\.colorScheme) private var scheme

    public init(request: GatewayApprovalRequest, identity: String? = nil, answer: @escaping (GatewayApproval) -> Void) {
        self.request = request; self.identity = identity; self.answer = answer
    }

    public var body: some View {
        let theme = TsukumoTheme(scheme)
        VStack(alignment: .leading, spacing: 8) {
            Label(request.title, systemImage: request.tool?.symbol ?? "lock.shield")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.accent)
            if let identity {
                Label(identity, systemImage: "person.crop.circle.badge.questionmark").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("gatewayCardIdentity")
            }
            Text(request.text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            if let preview = request.preview, !preview.isEmpty {
                Text(preview).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(8).textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityLabel("What would be shared: " + preview)
            }
            HStack(spacing: 8) {
                Button("Allow once") { answer(.once) }.buttonStyle(.borderedProminent).tint(theme.accent)
                if request.standing != nil { Button("Allow for 7 days") { answer(.standing) } }
                Button("Don’t allow", role: .destructive) { answer(.deny) }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.accent.opacity(0.2), lineWidth: 1) }
        .accessibilityElement(children: .contain)
    }
}

/// Every caller request waiting on the owner (sign-ins have their own window).
public struct GatewayRequestList: View {
    let desk: GatewayDesk
    let identity: (GatewayApprovalRequest) -> String?
    public init(desk: GatewayDesk, identity: @escaping (GatewayApprovalRequest) -> String? = { _ in nil }) { self.desk = desk; self.identity = identity }
    public var body: some View {
        let waiting = desk.pending.filter { if case .newClient = $0.kind { false } else { true } }
        if !waiting.isEmpty {
            VStack(spacing: 8) {
                ForEach(waiting) { request in
                    GatewayRequestCard(request: request, identity: identity(request)) { desk.answer(request.id, $0) }
                }
            }
        }
    }
}

public extension BotDock {
    /// Shows the gateway's cards in KemoSabe's chat, makes its tile need you while one waits, and says so in a
    /// speech bubble when a request or a delivery arrives.
    func attach(gateway desk: GatewayDesk, inbox: GatewayInbox?) {
        self.gateway = desk
        let previous = desk.onRequest
        desk.onRequest = { [weak self] request in
            previous?(request)
            guard let self else { return }
            if case .newClient = request.kind { return }
            if !self.isShowing(BotSpec.kemoSabeID) { self.show(DockCallout(bot: BotSpec.kemoSabeID, text: request.title), for: 12) }
        }
        let delivered = inbox?.onDelivery
        inbox?.onDelivery = { [weak self] item in
            delivered?(item)
            self?.show(DockCallout(bot: BotSpec.kemoSabeID, text: item.line), for: 8)
        }
    }
}
#endif

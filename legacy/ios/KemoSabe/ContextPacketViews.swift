import SwiftUI

// What the owner sees of context packets (design/UI-GUIDE.md#context-packets), the same on iPhone and
// Mac: "Share context with…" and its review card (what goes, what stays and why, and Continue), and the
// context card a chat starts with, which can be removed at any time.

/// Destinations a device adds beyond chats (the Mac's Tsukumo tasks), and how it delivers to them.
struct ContextPacketExtras {
    var destinations: @MainActor () -> [ContextPacketDestination]
    /// Gives the packet to a non-chat destination with the owner's message. Nil when it's delivered;
    /// otherwise why not.
    var deliver: @MainActor (ContextPacket, String) async -> String?
}

private struct ContextPacketExtrasKey: EnvironmentKey { static let defaultValue: ContextPacketExtras? = nil }
extension EnvironmentValues {
    var contextPacketExtras: ContextPacketExtras? {
        get { self[ContextPacketExtrasKey.self] }
        set { self[ContextPacketExtrasKey.self] = newValue }
    }
}

extension AgentCardColors {
    /// The system's own colors with the app's accent, for places without the theme's palette at hand.
    static func system(accent: Color?) -> Self {
        #if os(iOS)
        .init(background: Color(uiColor: .systemBackground), surface: Color(uiColor: .secondarySystemBackground), foreground: .primary, accent: accent ?? .accentColor)
        #else
        .init(background: Color(nsColor: .windowBackgroundColor), surface: Color(nsColor: .controlBackgroundColor), foreground: .primary, accent: accent ?? .accentColor)
        #endif
    }
}

/// A chat to share context from, for `sheet(item:)`.
struct ContextPacketSource: Identifiable, Equatable { let id: UUID }

extension View {
    /// Shows "Share context with…" for `source` when it's set; `finished` runs after the packet moved.
    func contextPacketSheet(source: Binding<ContextPacketSource?>, colors: AgentCardColors,
                            finished: @escaping (ContextPacketDestination) -> Void = { _ in }) -> some View {
        sheet(item: source) { chat in
            ContextPacketSheet(source: chat.id, colors: colors) { destination in
                source.wrappedValue = nil
                if let destination { finished(destination) }
            }
            #if os(iOS)
            .presentationDetents([.large])
            .presentationBackground(colors.background)
            #else
            .frame(width: 520, height: 620)
            #endif
        }
    }
}

/// The review card: where the context goes, exactly what goes, what stays and why, and Continue.
/// Built like an agent's request card (`AgentRequestCardView`): the theme's colors, labels and buttons.
struct ContextPacketSheet: View {
    let source: UUID
    let colors: AgentCardColors
    /// The destination it moved to, or nil when cancelled.
    let finished: (ContextPacketDestination?) -> Void
    @Environment(AppStore.self) private var store
    @Environment(\.chatAgents) private var agents
    @Environment(\.contextPacketExtras) private var extras
    @State private var packet: ContextPacket?
    @State private var destinations: [ContextPacketDestination] = []
    @State private var message = ""
    @State private var problem: String?
    @State private var sending = false
    @State private var showingText = false

    private var reader: RecipientID? { packet?.destination.recipient }
    private var review: ContextPacketReview? {
        guard let packet, let reader else { return nil }
        return packet.review(for: reader, grants: store.liveGrants)
    }
    private var name: String { packet?.destination.name ?? "" }
    private var isTask: Bool { packet?.destination.kind == .codingTask }
    private var newTask: Bool { isTask && packet?.destination.task == nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let packet {
                    header(packet)
                    destinationList(packet)
                    if isTask { taskMessage }
                    if let review { sections(review) }
                } else {
                    Text("There’s nothing in this chat to share yet.").font(KemoType.font(.body)).accessibilityIdentifier("contextPacketEmpty")
                }
                if let problem {
                    Text(problem).font(KemoType.font(.subheadline)).foregroundStyle(.orange).accessibilityIdentifier("contextPacketProblem")
                }
            }
            .padding(20)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) { buttons.padding(.horizontal, 20).padding(.bottom, 16).padding(.top, 8).background(colors.background) }
        .background(colors.background.ignoresSafeArea())
        .foregroundStyle(colors.foreground)
        .tint(colors.accent)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("contextPacketReview")
        .onAppear(perform: load)
    }

    private func load() {
        guard packet == nil else { return }
        destinations = store.packetDestinations(agents: agents, excluding: source) + (extras?.destinations() ?? [])
        let current = store.chatReader.key
        let first = destinations.first { $0.reader == current && $0.chat == nil && $0.kind == .chat } ?? destinations.first
        guard let first else { return }
        packet = store.makePacket(fromChat: source, to: first)
    }
    private func choose(_ destination: ContextPacketDestination) {
        guard packet?.destination != destination else { return }
        // The owner's OK for a Sensitive item is for the reader it named; a new reader asks again.
        packet?.destination = destination
        packet?.consented = []
        packet?.purpose = destination.kind == .codingTask ? "A coding task" : "Continue a chat"
        problem = nil
    }

    // MARK: Parts

    private func header(_ packet: ContextPacket) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up").font(.system(size: 16, weight: .semibold)).foregroundStyle(colors.accent)
                    .frame(width: 34, height: 34).background(colors.accent.opacity(0.14), in: Circle())
                Text("Share context").font(KemoType.font(.headline, weight: .semibold))
                Spacer(minLength: 0)
            }
            Text("Bring context from \(packet.origin) to \(name), in \(packet.destination.place).")
                .font(KemoType.font(.title3, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("contextPacketSummary")
        }
    }

    private func destinationList(_ packet: ContextPacket) -> some View {
        struct Group: Identifiable { let id: String; let destinations: [ContextPacketDestination] }
        let groups = [
            Group(id: "New chat", destinations: destinations.filter { $0.kind == .chat && $0.chat == nil }),
            Group(id: "Continue a saved chat", destinations: destinations.filter { $0.kind == .chat && $0.chat != nil }),
            Group(id: "Tsukumo", destinations: destinations.filter { $0.kind == .codingTask }),
        ].filter { !$0.destinations.isEmpty }
        return section("To") {
            ForEach(groups) { group in
                if groups.count > 1 { Text(group.id).font(KemoType.font(.caption)).opacity(0.6).padding(.top, 2) }
                ForEach(group.destinations) { destination in
                    Button { choose(destination) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: symbol(destination)).frame(width: 20).foregroundStyle(colors.accent)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(destination.name).font(KemoType.font(.body, weight: .medium))
                                Text(detail(destination)).font(KemoType.font(.caption)).opacity(0.65).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            if packet.destination == destination {
                                Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(colors.accent)
                            }
                        }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(packet.destination == destination ? .isSelected : [])
                    .accessibilityIdentifier("contextPacketTo-" + destination.name)
                }
            }
        }
    }
    private func symbol(_ destination: ContextPacketDestination) -> String {
        if destination.kind == .codingTask { return "hammer" }
        if destination.chat != nil { return "arrow.uturn.forward" }
        switch destination.recipient {
        case .appleOnDevice?: return "lock.fill"
        case .applePrivateCloud?: return "cloud"
        case .codingAgent?: return "sparkles"
        default: return "network"
        }
    }
    private func detail(_ destination: ContextPacketDestination) -> String {
        let place = destination.place.prefix(1).uppercased() + destination.place.dropFirst()
        switch destination.recipient {
        case .appleOnDevice?: return place + " · stays on this \(AgentDevice.name)"
        case .applePrivateCloud?: return place + " · Apple’s Private Cloud Compute"
        case .apiModel(let id, _)?:
            return place + " · " + (store.state.apiProfiles?.first { $0.id == id }?.endpoint.host ?? "your model connection")
        default: return place
        }
    }

    private var taskMessage: some View {
        section(newTask ? "What should \(name) do?" : "Message") {
            TextField(newTask ? "Describe the task" : "Optional", text: $message, axis: .vertical)
                .lineLimit(2...5).font(KemoType.font(.body)).textFieldStyle(.plain)
                .accessibilityIdentifier("contextPacketMessage")
        }
    }

    @ViewBuilder private func sections(_ review: ContextPacketReview) -> some View {
        let consent = review.withheld.filter { $0.reason == .needsConsent }
        let stays = review.withheld.filter { $0.reason != .needsConsent }
        section("Will share with \(name)") {
            if review.shared.isEmpty {
                Text("Nothing yet.").font(KemoType.font(.body)).opacity(0.7)
            }
            ForEach(review.shared) { item in
                itemRow(item, note: item.level.title) {
                    Button { packet?.excluded.append(item.id); packet?.consented.removeAll { $0 == item.id } } label: {
                        Image(systemName: "minus.circle").font(.system(size: 17))
                    }.buttonStyle(.plain).foregroundStyle(colors.foreground.opacity(0.55))
                        .accessibilityLabel("Take out " + item.title).accessibilityIdentifier("contextPacketTakeOut")
                }
            }
        }.accessibilityIdentifier("contextPacketShared")
        if !consent.isEmpty {
            section("Needs your OK") {
                ForEach(consent) { entry in
                    itemRow(entry.item, note: ContextPacketReview.line(entry.reason, name: name)) {
                        Button("Include") { packet?.consented.append(entry.item.id) }
                            .font(KemoType.font(.subheadline, weight: .semibold)).buttonStyle(.plain).foregroundStyle(colors.accent)
                            .accessibilityIdentifier("contextPacketInclude")
                    }
                }
            }.accessibilityIdentifier("contextPacketConsent")
        }
        if !stays.isEmpty {
            section("Stays on your \(AgentDevice.name)") {
                ForEach(stays) { entry in
                    itemRow(entry.item, note: ContextPacketReview.line(entry.reason, name: name)) {
                        if entry.reason == .removed {
                            Button("Put back") { packet?.excluded.removeAll { $0 == entry.item.id } }
                                .font(KemoType.font(.subheadline, weight: .semibold)).buttonStyle(.plain).foregroundStyle(colors.accent)
                                .accessibilityIdentifier("contextPacketPutBack")
                        }
                    }
                }
            }.accessibilityIdentifier("contextPacketWithheld")
        }
        if let packet, let text = ContextPacket.text(review, origin: packet.origin, limit: limit(review.reader)) {
            section("Exactly what \(name) gets") {
                if showingText {
                    Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).accessibilityIdentifier("contextPacketText")
                } else {
                    Text("\(text.count) characters, as reference data, never instructions.").font(KemoType.font(.caption)).opacity(0.7)
                }
            } trailing: {
                Button(showingText ? "Hide" : "Show") { showingText.toggle() }.font(KemoType.font(.subheadline, weight: .semibold))
                    .buttonStyle(.plain).foregroundStyle(colors.accent).accessibilityIdentifier("contextPacketShowText")
            }
        }
    }
    private func limit(_ reader: RecipientID) -> Int {
        reader == .appleOnDevice ? ContextPacketBuilder.onDeviceLimit : ContextPacketBuilder.largeLimit
    }

    private func itemRow<Trailing: View>(_ item: ContextPacketItem, note: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.symbol).frame(width: 20).opacity(0.75).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(KemoType.font(.body)).lineLimit(2)
                Text(note).font(KemoType.font(.caption)).opacity(0.65).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            trailing()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("contextPacketItem")
    }

    private func section<Content: View, Trailing: View>(_ title: String, @ViewBuilder content: () -> Content,
                                                         @ViewBuilder trailing: () -> Trailing = { EmptyView() }) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(KemoType.font(.caption, weight: .semibold)).textCase(.uppercase).opacity(0.6)
                Spacer(minLength: 0)
                trailing()
            }
            VStack(alignment: .leading, spacing: 10, content: content).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var canSend: Bool {
        guard let review, !review.isEmpty, !sending else { return false }
        return !newTask || !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var buttons: some View {
        HStack(spacing: 12) {
            Button { finished(nil) } label: { Text("Cancel").frame(maxWidth: .infinity) }
                .buttonStyle(AgentCardButtonStyle(fill: colors.surface, ink: colors.foreground))
                .accessibilityIdentifier("contextPacketCancel")
            Button { send() } label: { Text(isTask ? "Send to \(name)" : "Continue").lineLimit(1).frame(maxWidth: .infinity) }
                .buttonStyle(AgentCardButtonStyle(fill: colors.accent, ink: colors.background))
                .disabled(!canSend).opacity(canSend ? 1 : 0.5)
                .accessibilityIdentifier("contextPacketContinue")
        }
    }
    private func send() {
        guard let packet, canSend else { return }
        if packet.destination.kind == .chat {
            if let problem = store.continueInChat(packet) { self.problem = problem } else { finished(packet.destination) }
            return
        }
        guard let extras else { problem = "That destination isn’t available here."; return }
        sending = true
        Task {
            let problem = await extras.deliver(packet, message.trimmingCharacters(in: .whitespacesAndNewlines))
            sending = false
            if let problem { self.problem = problem } else { finished(packet.destination) }
        }
    }
}

// MARK: The chat's context card

/// The context a chat started with, above the message box: where it came from, what its model gets
/// and what stays, and × to take it out. It goes with every turn while it's there, evaluated for the
/// chat's reader at that moment.
struct ContextPacketChatCard: View {
    @Environment(AppStore.self) private var store
    @State private var expanded = false
    var body: some View {
        if let packet = store.openPacket {
            let reader = store.chatReader
            let review = packet.review(for: reader, grants: store.liveGrants)
            let name = store.recipientName(reader, fallback: packet.destination)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Context from " + packet.origin).font(KemoType.font(.caption, weight: .semibold)).lineLimit(1)
                            .accessibilityIdentifier("contextPacketCardTitle")
                        Text(summary(packet, review: review, name: name)).font(KemoType.font(.caption2)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 26)
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel(expanded ? "Hide what’s in it" : "Show what’s in it").accessibilityIdentifier("contextPacketCardExpand")
                    Button { store.removeOpenPacket() } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).frame(width: 26, height: 26)
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel("Remove this context").accessibilityIdentifier("contextPacketCardRemove")
                }
                if expanded {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(review.shared) { item in
                            Label(item.title, systemImage: item.symbol).font(KemoType.font(.caption)).lineLimit(1)
                        }
                        ForEach(review.withheld) { entry in
                            Label(entry.item.title + ". " + ContextPacketReview.line(entry.reason, name: name), systemImage: "lock")
                                .font(KemoType.font(.caption)).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }.padding(.leading, 2)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("contextPacketCard")
        }
    }
    private func summary(_ packet: ContextPacket, review: ContextPacketReview, name: String) -> String {
        let goes = review.shared.count, stays = review.withheld.count
        let given = packet.delivered?[review.reader.key] != nil
        var line = given ? "Given to \(name)" : "\(goes) item\(goes == 1 ? "" : "s") for \(name)"
        if stays > 0 { line += " · \(stays) \(given ? "stayed" : "stay") on this \(AgentDevice.name)" }
        return line
    }
}

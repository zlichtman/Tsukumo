import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The chat's model chip opens this (the owner's instruction, September 26, 2026): Tsukumo's
/// power-up design for KemoSabe's own models, a popover on Mac and a touch-sized sheet on iPhone.
///
/// The effort page shows the effort name large, the model beneath it (which opens the model list),
/// and the heat-tinted slider with sparkles, snapping to exactly the efforts the model in use
/// accepts (`AppStore.currentEfforts`), with the model's default at the left and as the reset. A
/// model without efforts shows the model list only. Each step ticks (a haptic on iPhone), arrow keys
/// step on Mac, Return closes, and Esc puts the effort back. The effort is saved per model profile
/// once, when the popover closes.
///
/// The model list is a clean selector with a checkmark: Apple on-device (with the lock), Apple
/// Private Cloud (disabled with its reason when the system doesn't offer it), each connected model,
/// and Add model. Private Cloud and connected models are chosen only after their destination is
/// shown, as in Settings → Models: "Runs on Apple’s Private Cloud Compute." and the connection's
/// own disclosure. Choosing never grants anything; each connected model keeps its own conversation.
struct ChatModelPopover: View {
    enum Page { case effort, models }
    /// A model waiting for its destination to be confirmed.
    enum Pending: Equatable { case privateCloud, api(APIModelProfile) }
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Agents this device can chat with (Claude on the Mac), under "Chat with an agent".
    @Environment(\.chatAgents) private var agents
    let accent: Color
    /// iPhone: bigger type, a taller slider, and taller rows.
    var touch = false
    var animate = true
    var addModel: () -> Void
    var close: () -> Void
    @State private var page: Page
    @State private var effort: String?
    @State private var loaded = false
    @State private var cancelled = false
    @State private var pending: Pending?
    @State private var highlighted = 0
    @State private var ticks = 0
    @State private var failure: String?
    init(accent: Color, touch: Bool = false, animate: Bool = true, page: Page? = nil, pending: Pending? = nil,
         addModel: @escaping () -> Void, close: @escaping () -> Void) {
        self.accent = accent; self.touch = touch; self.animate = animate; self.addModel = addModel; self.close = close
        _page = State(initialValue: page ?? .effort); _pending = State(initialValue: pending)
    }
    #if os(macOS)
    @FocusState private var focused: Bool
    #endif

    private var efforts: [String] { store.currentEfforts }
    /// nil (the model's default) first, then each effort lightest to heaviest.
    private var stops: [String?] { [nil] + efforts }
    private var step: Int { effort.flatMap { stops.firstIndex(of: $0) } ?? 0 }
    private var heat: Double { (effort ?? store.currentDefaultEffort).map(EffortWeight.heat) ?? 0.3 }
    private var heatColor: Color { EffortHeat.title(accent: accent, heat: heat, dark: scheme == .dark) }
    private var profiles: [APIModelProfile] { store.state.apiProfiles ?? [] }

    var body: some View {
        Group {
            if let pending { confirmation(pending) }
            else if page == .effort && !efforts.isEmpty && store.state.chatAgent == nil { effortPage }
            else { modelPage }
        }
        .padding(touch ? 20 : 14)
        .frame(width: touch ? nil : 320)
        .frame(maxWidth: touch ? .infinity : nil, alignment: .top)
        .sensoryFeedback(.selection, trigger: ticks)
        #if os(macOS)
        .focusable().focused($focused).focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .return, .escape]) { press in key(press.key) }
        #endif
        .onAppear {
            store.refreshPrivateCloud()
            if !loaded { effort = store.currentEffort; loaded = true }
            #if os(macOS)
            focused = true
            #endif
        }
        .onDisappear { commit() }
    }
    /// Saves the effort once, for the model it was chosen for.
    private func commit() {
        guard !cancelled, effort != store.currentEffort else { return }
        store.setCurrentEffort(effort)
    }
    private func tick() {
        ticks += 1
        #if os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        #endif
    }
    #if os(macOS)
    private func key(_ key: KeyEquivalent) -> KeyPress.Result {
        if pending != nil {
            if key == .escape { pending = nil; return .handled }
            return .ignored
        }
        switch (page == .effort && !efforts.isEmpty ? Page.effort : .models, key) {
        case (.effort, .leftArrow), (.effort, .downArrow): move(-1)
        case (.effort, .rightArrow), (.effort, .upArrow): move(1)
        case (.effort, .return): close()
        case (.effort, .escape): cancelled = true; close()
        case (.models, .upArrow): highlighted = max(0, highlighted - 1)
        case (.models, .downArrow): highlighted = min(rowCount - 1, highlighted + 1)
        case (.models, .return): activate(highlighted)
        case (.models, .escape), (.models, .leftArrow):
            if efforts.isEmpty { close() } else { page = .effort }
        default: return .ignored
        }
        return .handled
    }
    #endif
    private func move(_ delta: Int) {
        let next = min(max(step + delta, 0), stops.count - 1)
        guard next != step else { return }
        effort = stops[next]; tick()
    }

    // MARK: Effort

    private var modelTitle: String { store.modelLabel }
    private var effortPage: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "bolt.fill").font(.system(size: touch ? 15 : 12, weight: .semibold)).foregroundStyle(heatColor)
                    .frame(width: touch ? 36 : 28, height: touch ? 36 : 28).background(heatColor.opacity(0.14), in: Circle())
                    .accessibilityHidden(true)
                Spacer()
                Button { if effort != nil { effort = nil; tick() } } label: {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: touch ? 15 : 12, weight: .semibold))
                        .frame(width: touch ? 36 : 28, height: touch ? 36 : 28)
                        .foregroundStyle(Color.primary.opacity(effort == nil ? 0.3 : 0.75))
                        .background(Color.primary.opacity(effort == nil ? 0.03 : 0.07), in: Circle())
                }.buttonStyle(.plain).disabled(effort == nil)
                    .help("Back to the model's default").accessibilityLabel("Use the model's default effort").accessibilityIdentifier("resetEffort")
            }
            Text(EffortWeight.title(effort))
                .font(.system(size: touch ? 34 : 28, weight: .semibold, design: .rounded))
                .foregroundStyle(heatColor)
                .contentTransition(.interpolate)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: effort)
                .lineLimit(1).minimumScaleFactor(0.7)
                .padding(.top, -6)
                .accessibilityAddTraits(.isHeader).accessibilityIdentifier("effortTitle")
            Button { highlighted = currentRow; page = .models } label: {
                HStack(spacing: 4) {
                    if store.runsOnlyOnDevice { Image(systemName: "lock.fill").font(.system(size: touch ? 11 : 9, weight: .semibold)) }
                    Text(modelTitle).lineLimit(1)
                    Image(systemName: "chevron.right").font(.system(size: touch ? 11 : 9, weight: .bold))
                }
                .font(.system(size: touch ? 15 : 13, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, touch ? 8 : 3).contentShape(Capsule())
            }.buttonStyle(ModelRowButtonStyle()).help("Choose the model")
                .accessibilityLabel("Model, " + modelTitle).accessibilityIdentifier("effortModel")
            PowerSlider(count: stops.count, step: Binding(get: { step }, set: { effort = stops[min(max($0, 0), stops.count - 1)] }),
                        heat: heat, accent: accent, valueTitle: EffortWeight.title(effort), height: touch ? 44 : 30, animate: animate) { _ in tick() }
                .padding(.top, touch ? 18 : 14)
                .accessibilityIdentifier("effortSlider")
        }
    }

    // MARK: Models

    private var rowCount: Int { 2 + profiles.count + 1 }
    private var currentRow: Int {
        if store.modelRoute == .api, let active = store.activeAPIProfile, let index = profiles.firstIndex(of: active) { return 2 + index }
        return store.appleModel == .privateCloud && store.modelRoute == .onDevice ? 1 : 0
    }
    private var modelPage: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if !efforts.isEmpty {
                    Button { page = .effort } label: {
                        Image(systemName: "chevron.left").font(.system(size: touch ? 14 : 11, weight: .semibold)).frame(width: touch ? 34 : 24, height: touch ? 34 : 24)
                    }.buttonStyle(ModelRowButtonStyle()).accessibilityLabel("Back to effort").accessibilityIdentifier("effortBack")
                }
                Text("Model").font(.system(size: touch ? 17 : 13, weight: .semibold))
                Spacer()
            }
            if rowCount > 8 {
                ScrollView { rows }.frame(maxHeight: touch ? 420 : 300)
            } else { rows }
            if let failure { Text(failure).font(.system(size: touch ? 13 : 11)).foregroundStyle(.orange).padding(.horizontal, 8) }
        }
    }
    private var rows: some View {
        let cloud = store.privateCloudStatus
        let onApple = store.modelRoute == .onDevice
        return VStack(alignment: .leading, spacing: 2) {
            row(0, symbol: "lock.fill", title: AppleModel.onDevice.title, detail: "", chosen: onApple && store.appleModel == .onDevice && store.state.chatAgent == nil, identifier: "model-onDevice")
            row(1, symbol: "cloud", title: AppleModel.privateCloud.title, detail: cloud.unavailableReason ?? cloud.quotaLine() ?? "",
                chosen: onApple && store.appleModel == .privateCloud, enabled: cloud.isAvailable, identifier: "model-privateCloud")
            ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
                row(2 + index, symbol: profile.isLoopback ? "desktopcomputer" : "network", title: profile.name,
                    detail: profile.model + " · " + (profile.endpoint.host ?? ""), chosen: store.modelRoute == .api && store.activeAPIProfile == profile,
                    identifier: "model-api-" + profile.id.uuidString)
            }
            if !agents.isEmpty {
                Divider().padding(.vertical, 3)
                Text("Chat with an agent").font(.system(size: touch ? 13 : 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 8)
                ForEach(agents) { agent in agentRow(agent) }
            }
            Divider().padding(.vertical, 3)
            row(rowCount - 1, symbol: "plus", title: "Add model", detail: "", chosen: false, enabled: profiles.count < 12, identifier: "addModelConnection")
        }
    }
    private func row(_ index: Int, symbol: String, title: String, detail: String, chosen: Bool, enabled: Bool = true, identifier: String) -> some View {
        Button { activate(index) } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: touch ? 15 : 12, weight: .medium)).frame(width: touch ? 24 : 18)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: touch ? 16 : 13))
                    if !detail.isEmpty { Text(detail).font(.system(size: touch ? 13 : 11)).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer(minLength: 4)
                if chosen { Image(systemName: "checkmark").font(.system(size: touch ? 14 : 11, weight: .bold)).foregroundStyle(accent) }
            }
            .padding(.horizontal, 8).padding(.vertical, touch ? 10 : 5)
            .frame(minHeight: touch ? 48 : nil)
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.5)
        }
        .buttonStyle(ModelRowButtonStyle(selected: highlighted == index && !touch))
        .disabled(!enabled)
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
    /// An agent to chat with: its mark, its state, and Sign in when it needs one. Choosing it starts a
    /// chat with it (you, the agent, and Kemo).
    private func agentRow(_ agent: ChatAgentOption) -> some View {
        HStack(spacing: 6) {
            Button { failure = nil; commit(); store.selectChatAgent(agent.id); close() } label: {
                HStack(spacing: 10) {
                    ChatAgentLogo(logo: agent.logo, title: agent.title, size: touch ? 22 : 16)
                        .frame(width: touch ? 24 : 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(agent.title).font(.system(size: touch ? 16 : 13))
                        Text(agent.detail).font(.system(size: touch ? 13 : 11)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    if store.state.chatAgent == agent.id { Image(systemName: "checkmark").font(.system(size: touch ? 14 : 11, weight: .bold)).foregroundStyle(accent) }
                }
                .padding(.horizontal, 8).padding(.vertical, touch ? 10 : 5).frame(minHeight: touch ? 48 : nil)
                .contentShape(Rectangle()).opacity(agent.available ? 1 : 0.5)
            }
            .buttonStyle(ModelRowButtonStyle()).disabled(!agent.available)
            .accessibilityAddTraits(store.state.chatAgent == agent.id ? .isSelected : [])
            .accessibilityIdentifier("chatAgent-" + agent.id)
            if let signIn = agent.signIn {
                Button(agent.actionTitle) { signIn(); close() }.font(.system(size: touch ? 14 : 11, weight: .semibold))
                    .buttonStyle(ModelRowButtonStyle(inset: 6)).foregroundStyle(accent).accessibilityIdentifier("chatAgentSignIn-" + agent.id)
            }
        }
    }
    /// A row's action: Apple on-device at once; Private Cloud and connected models after their
    /// destination; Add model opens the editor.
    private func activate(_ index: Int) {
        failure = nil
        switch index {
        case 0:
            commit(); store.selectAppleModel(.onDevice); arrived()
        case 1:
            guard store.privateCloudStatus.isAvailable else { return }
            if store.modelRoute == .onDevice && store.appleModel == .privateCloud { arrived() } else { pending = .privateCloud }
        case rowCount - 1:
            guard profiles.count < 12 else { return }
            commit(); cancelled = true; addModel()
        default:
            let profile = profiles[index - 2]
            if store.modelRoute == .api && store.activeAPIProfile == profile { arrived() } else { pending = .api(profile) }
        }
    }
    /// After choosing a model: its own saved effort, and its effort page when it has efforts.
    private func arrived() {
        effort = store.currentEffort
        highlighted = currentRow
        if efforts.isEmpty { page = .models } else { page = .effort }
        tick()
    }

    // MARK: Destination

    private func confirmation(_ pending: Pending) -> some View {
        let title: String, message: String, action: String
        switch pending {
        case .privateCloud:
            title = "Use \(AppleModel.privateCloud.title)?"; message = PrivateCloudText.destination; action = "Use " + AppleModel.privateCloud.title
        case .api(let profile):
            title = "Use \(profile.name)?"; message = profile.useDisclosure; action = "Use " + profile.name
        }
        return VStack(alignment: .leading, spacing: touch ? 14 : 10) {
            Text(title).font(.system(size: touch ? 17 : 13, weight: .semibold))
            Text(message).font(.system(size: touch ? 14 : 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(pending == .privateCloud ? "privateCloudDestination" : "apiDestination")
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { self.pending = nil }.buttonStyle(ModelRowButtonStyle(inset: 6)).accessibilityIdentifier("cancelModelChoice")
                Button {
                    commit()
                    switch pending {
                    case .privateCloud: store.selectAppleModel(.privateCloud)
                    case .api(let profile):
                        do { try store.selectAPIProfile(profile) } catch { failure = error.localizedDescription }
                    }
                    self.pending = nil; arrived()
                } label: {
                    Text(action).font(.system(size: touch ? 15 : 12, weight: .semibold)).lineLimit(1)
                        .foregroundStyle(scheme == .dark ? Color.black.opacity(0.85) : Color.white)
                        .padding(.horizontal, 14).frame(height: touch ? 40 : 28).background(accent, in: Capsule())
                }.buttonStyle(PressableButtonStyle())
                    .accessibilityIdentifier(pending == .privateCloud ? "confirmPrivateCloud" : "confirmAPIModel")
            }
        }
    }
}

/// A soft rounded row highlight: on hover (Mac), when selected, and while pressed.
struct ModelRowButtonStyle: ButtonStyle {
    var selected = false
    var inset: CGFloat = 0
    func makeBody(configuration: Configuration) -> some View { Row(configuration: configuration, selected: selected, inset: inset) }
    private struct Row: View {
        let configuration: Configuration
        let selected: Bool
        let inset: CGFloat
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .padding(.horizontal, inset).padding(.vertical, inset > 0 ? 4 : 0)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : selected || (hovering && enabled) ? 0.07 : 0)))
                .onHover { hovering = $0 }
        }
    }
}

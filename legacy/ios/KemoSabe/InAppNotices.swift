import SwiftUI
import UIKit

// In-app notices (the owner's request, September 25, 2026: "dynamic notification mobile?"). While
// KemoSabe is in front, nothing is posted to Notification Center; a notice grows out of the Dynamic
// Island instead: a black pill the island's size springs into a rounded card, holds about four
// seconds, and shrinks back into the island. Without an island it drops from the top as a card.
// What shows is decided with system notifications, in `KemoNotifier.delivery`. See
// design/UI-GUIDE.md (In-app notices).

/// What the person is looking at, so a notice never shows for what's already on screen.
struct VisibleScreen: Equatable {
    var tab = "Chat"
    /// The conversation open in Chat.
    var conversation: UUID?
    /// A sheet or the conversations drawer covers the tab.
    var covered = false
    /// The task whose "Approve it on your Mac" sheet is open.
    var macTask: UUID?
    /// Onboarding or the sign-in screen covers the app: nothing shows over it.
    var blocked = false

    func isLooking(at link: NotificationLink) -> Bool {
        if blocked { return true }
        switch link {
        case .conversation(let id): return tab == "Chat" && !covered && (id == nil || id == conversation)
        case .day: return tab == "Day" && !covered
        case .macNotice(let notice): return macTask == notice.task
        }
    }
}

/// The in-app notice being shown and the ones waiting. The view (`InAppNoticeHost`) animates the
/// current one and calls `finish` when it has gone back into the island.
@MainActor @Observable final class InAppNoticeCenter: InAppNoticePresenting {
    static let shared = InAppNoticeCenter()
    /// At most this many wait; the oldest goes first when more arrive.
    static let waitingLimit = 3
    private(set) var current: InAppNotice?
    private(set) var waiting: [InAppNotice] = []
    /// Bumped when the current notice should go back into the island (dealt with elsewhere).
    private(set) var collapseRequests = 0
    var screen = VisibleScreen()
    /// The companion's palette, for Kemo's still face on the card.
    var companion: BotTheme?
    /// Where a tap goes: the same routes as a notification tap.
    @ObservationIgnored var route: @MainActor (NotificationLink) -> Void = { NotificationRoutes.shared.pending = $0 }
    /// Shows the notice window when a notice arrives with none on screen.
    @ObservationIgnored var willPresent: @MainActor () -> Void = {}

    func isLooking(at link: NotificationLink) -> Bool { screen.isLooking(at: link) }
    func show(_ notice: InAppNotice) {
        guard current?.id != notice.id else { return }
        // A newer reply in the same conversation (or a newer notice for the same Mac task) replaces one waiting.
        waiting.removeAll { $0.id == notice.id || Self.supersedes(notice, $0) }
        if current == nil { current = notice; willPresent(); return }
        waiting.append(notice)
        if waiting.count > Self.waitingLimit { waiting.removeFirst(waiting.count - Self.waitingLimit) }
    }
    private static func supersedes(_ new: InAppNotice, _ old: InAppNotice) -> Bool {
        switch (new.link, old.link) {
        case (.conversation(let a), .conversation(let b)): a == b
        case (.macNotice(let a), .macNotice(let b)): a.task == b.task
        case (.day, .day): true
        default: false
        }
    }
    /// The current notice has gone (timed out, swiped away, or opened); the next one follows.
    func finish() { current = waiting.isEmpty ? nil : waiting.removeFirst() }
    /// Opens where the current notice points. The view then collapses it.
    func open() { if let current { route(current.link) } }
    /// Notices that were dealt with elsewhere (an approval answered on the Mac).
    func withdraw(_ identifiers: [String]) {
        waiting.removeAll { identifiers.contains($0.id) }
        if let current, identifiers.contains(current.id) { collapseRequests += 1 }
    }
    /// Signing out or switching accounts: nothing from the old account stays on screen.
    func clear() {
        waiting = []
        if current != nil { collapseRequests += 1 }
    }
}

/// Where the island is, from the screen and its safe area. iPhones with a Dynamic Island have a
/// top safe area of 59 points or more (68 on iPhone Air); notched ones 50 or less. The island is
/// 126 by 37⅓ points, centered, 11 points from the top on a 59-point safe area and lower by as much
/// as the safe area is taller.
struct IslandGeometry: Equatable {
    static let islandSize = CGSize(width: 126, height: 37 + 1.0 / 3)
    /// The island in screen points, or nil (no island, in landscape, or on iPad).
    var island: CGRect?
    var cardWidth: CGFloat
    /// Where the card's top edge rests.
    var cardTop: CGFloat
    static func resolve(screen: CGSize, safeTop: CGFloat, phone: Bool) -> IslandGeometry {
        if phone, screen.height > screen.width, safeTop >= 58 {
            let top = max(11, safeTop - 48)
            let island = CGRect(x: (screen.width - islandSize.width) / 2, y: top, width: islandSize.width, height: islandSize.height)
            return .init(island: island, cardWidth: min(screen.width - 20, 420), cardTop: top)
        }
        return .init(island: nil, cardWidth: min(screen.width - 16, 420), cardTop: safeTop + 6)
    }
}

// MARK: The overlay window

/// Hosts notices in their own window above the app's (and above its sheets). It passes every touch
/// through except on the card, and it's hidden while nothing shows.
@MainActor final class InAppNoticeWindow {
    static let shared = InAppNoticeWindow()
    private var window: PassthroughWindow?
    let bridge = NoticeWindowBridge()
    func attach(to scene: UIWindowScene) {
        guard window?.windowScene !== scene else { return }
        let window = PassthroughWindow(windowScene: scene)
        window.bridge = bridge
        // Above the app and its sheets, below system alerts.
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue - 1)
        window.backgroundColor = .clear
        let host = NoticeHostingController(rootView: InAppNoticeHost(center: .shared, bridge: bridge))
        host.bridge = bridge
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.isHidden = true
        bridge.setVisible = { [weak window] visible in window?.isHidden = !visible }
        InAppNoticeCenter.shared.willPresent = { [weak window] in window?.isHidden = false }
        if InAppNoticeCenter.shared.current != nil { window.isHidden = false }
        bridge.statusBarChanged = { [weak host] in
            UIView.animate(withDuration: 0.2) { host?.setNeedsStatusBarAppearanceUpdate() }
        }
        self.window = window
    }
}

/// What the SwiftUI card tells its window, and what the window knows about the screen.
@MainActor @Observable final class NoticeWindowBridge {
    var safeTop: CGFloat = 0
    var screen: CGSize = UIScreen.main.bounds.size
    var phone = UIDevice.current.userInterfaceIdiom == .phone
    @ObservationIgnored var cardFrame: CGRect = .null
    @ObservationIgnored var setVisible: (Bool) -> Void = { _ in }
    @ObservationIgnored var statusBarChanged: () -> Void = {}
    /// The card covers the status bar while it's out of the island.
    @ObservationIgnored var hidesStatusBar = false { didSet { if hidesStatusBar != oldValue { statusBarChanged() } } }
}

private final class PassthroughWindow: UIWindow {
    weak var bridge: NoticeWindowBridge?
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let frame = bridge?.cardFrame, !frame.isNull, frame.insetBy(dx: -6, dy: -6).contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        bridge?.safeTop = safeAreaInsets.top
        bridge?.screen = bounds.size
    }
}

private final class NoticeHostingController: UIHostingController<InAppNoticeHost> {
    weak var bridge: NoticeWindowBridge?
    override var prefersStatusBarHidden: Bool { bridge?.hidesStatusBar ?? false }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }
}

/// Finds the app's window scene and attaches the notice window to it.
struct InAppNoticeWindowInstaller: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { Probe() }
    func updateUIView(_ view: UIView, context: Context) {}
    private final class Probe: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let scene = window?.windowScene { InAppNoticeWindow.shared.attach(to: scene) }
        }
    }
}

// MARK: The card

/// The notice itself: out of the island, into a card, and back.
struct InAppNoticeHost: View {
    @State var center: InAppNoticeCenter
    let bridge: NoticeWindowBridge
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var systemScheme
    @State private var appearance = MobileAppearance.shared
    private enum Phase { case island, card, expanded }
    @State private var shown: InAppNotice?
    @State private var phase = Phase.island
    @State private var contentHeight: CGFloat = 72
    @State private var drag: CGFloat = 0
    @State private var touching = false
    @State private var appeared = 0
    @State private var leaving = false

    private var scheme: ColorScheme { appearance.colorScheme ?? systemScheme }
    private var accent: Color { Color(hex: appearance.colors(scheme).accent) }
    private var geometry: IslandGeometry { .resolve(screen: bridge.screen, safeTop: bridge.safeTop, phone: bridge.phone) }
    private var spring: Animation { .spring(response: 0.42, dampingFraction: 0.78) }

    var body: some View {
        ZStack(alignment: .top) {
            if let shown { card(shown) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .preferredColorScheme(appearance.colorScheme)
        .sensoryFeedback(.impact(weight: .light), trigger: appeared)
        .onChange(of: center.current?.id, initial: true) { present(center.current) }
        .onChange(of: center.collapseRequests) { collapse() }
        .task(id: HoldKey(id: shown?.id, phase: phase, touching: touching)) { await hold() }
    }

    // MARK: Layout

    private func card(_ notice: InAppNotice) -> some View {
        let geometry = geometry
        let island = geometry.island
        let out = phase != .island
        let width = out || reduceMotion || island == nil ? geometry.cardWidth : island!.width
        let height = out || reduceMotion || island == nil ? contentHeight : island!.height
        // Off the top edge, when there's no island to come out of.
        let top: CGFloat = island.map { out || reduceMotion ? geometry.cardTop : $0.minY } ?? (out || reduceMotion ? geometry.cardTop : -contentHeight - 12)
        let radius = out || reduceMotion ? min(height / 2, island == nil ? 26 : 34) : height / 2
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return NoticeContent(notice: notice, expanded: phase == .expanded, islandBand: island?.height, companion: center.companion, accent: accent,
                             open: activate, dismiss: collapse)
            .frame(width: geometry.cardWidth, alignment: .top)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                if phase == .island || reduceMotion { contentHeight = height } else { withAnimation(spring) { contentHeight = height } }
            }
            // The words fade in once the card has room for them.
            .opacity(out || (island == nil && !reduceMotion) ? 1 : 0)
            .frame(width: width, height: height, alignment: .top)
            .background(Color.black, in: shape)
            .overlay { shape.strokeBorder(.white.opacity(out && scheme == .dark ? 0.14 : 0), lineWidth: 0.75) }
            .clipShape(shape)
            .shadow(color: .black.opacity(out && scheme == .light ? 0.22 : 0), radius: 18, y: 8)
            .contentShape(shape)
            .environment(\.colorScheme, .dark)
            .offset(y: top + drag)
            .opacity(reduceMotion && !out ? 0 : 1)
            // Touches reach the card and pass through everywhere else.
            .onChange(of: CGRect(x: (bridge.screen.width - width) / 2, y: top + drag, width: width, height: height), initial: true) { _, frame in
                bridge.cardFrame = frame
            }
            .onTapGesture { if phase != .expanded { activate() } }
            .onLongPressGesture(minimumDuration: 0.35) { expand() }
            .simultaneousGesture(swipe)
            .accessibilityElement(children: phase == .expanded ? .contain : .ignore)
            .accessibilityLabel(notice.accessibilityText)
            .accessibilityValue(phase == .expanded ? "Expanded" : "")
            .accessibilityHint(phase == .expanded ? "" : "Opens it. Swipe up to dismiss.")
            .accessibilityAddTraits(phase == .expanded ? [] : .isButton)
            .accessibilityIdentifier("inAppNotice")
            .accessibilityAction { activate() }
            .accessibilityAction(named: "Show more") { expand() }
            .accessibilityAction(named: "Dismiss") { collapse() }
    }

    /// Up dismisses; down (or a long press) shows more.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                touching = true
                let y = value.translation.height
                drag = y < 0 ? y : min(24, y * 0.25)
            }
            .onEnded { value in
                touching = false
                let y = value.translation.height, predicted = value.predictedEndTranslation.height
                if y < -24 || predicted < -80 { collapse() }
                else {
                    if y > 20 { expand() }
                    withAnimation(spring) { drag = 0 }
                }
            }
    }

    // MARK: Showing and hiding

    private struct HoldKey: Equatable { var id: String?; var phase: Phase; var touching: Bool }
    private func present(_ notice: InAppNotice?) {
        guard let notice, shown?.id != notice.id else {
            if notice == nil, shown == nil { bridge.cardFrame = .null; bridge.setVisible(false) }
            return
        }
        var instant = Transaction(); instant.disablesAnimations = true
        withTransaction(instant) { shown = notice; phase = .island; drag = 0; leaving = false }
        bridge.setVisible(true)
        Task { @MainActor in
            // One frame as the island itself, then out.
            try? await Task.sleep(for: .milliseconds(40))
            guard shown?.id == notice.id else { return }
            withAnimation(reduceMotion ? .easeInOut(duration: 0.25) : spring) { phase = .card }
            bridge.hidesStatusBar = geometry.island != nil
            appeared += 1
            AccessibilityNotification.Announcement(notice.accessibilityText).post()
        }
    }
    private func expand() {
        guard shown != nil, phase == .card else { return }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : spring) { phase = .expanded }
    }
    private func activate() {
        guard shown != nil, !leaving else { return }
        center.open(); collapse()
    }
    /// Back into the island (or up off the top), then the next notice.
    private func collapse() {
        guard let notice = shown, !leaving else { return }
        leaving = true
        withAnimation(reduceMotion ? .easeInOut(duration: 0.22) : .spring(response: 0.36, dampingFraction: 0.9)) { phase = .island; drag = 0 }
        bridge.hidesStatusBar = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 260 : 420))
            guard shown?.id == notice.id else { return }
            shown = nil; bridge.cardFrame = .null
            center.finish()
            if center.current == nil { bridge.setVisible(false) }
        }
    }
    /// About four seconds as a card (longer with VoiceOver), longer expanded, and never while touched.
    private func hold() async {
        guard shown != nil, !touching, phase != .island else { return }
        var seconds: Double = phase == .expanded ? 12 : UIAccessibility.isVoiceOverRunning ? 10 : 4
        #if DEBUG
        if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--in-app-notice-hold=") }),
           let value = Double(argument.dropFirst("--in-app-notice-hold=".count)) { seconds = value }
        #endif
        do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
        collapse()
    }
}

/// The card's words: Kemo's still face (or the Mac), who, and one line; expanded, more of it and
/// Open and Dismiss. With an island, the top band is left to it, like an expanded Live Activity:
/// the face sits to its left and the time to its right, and the words start below it, so nothing
/// is ever under the camera or where the island takes touches.
private struct NoticeContent: View {
    let notice: InAppNotice
    let expanded: Bool
    /// The island's height, when the card grows out of one.
    let islandBand: CGFloat?
    let companion: BotTheme?
    let accent: Color
    let open: () -> Void
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let islandBand {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        leading(size: 30)
                        Spacer(minLength: 0)
                        time
                    }.frame(height: islandBand).padding(.horizontal, 6)
                    words
                }
            } else {
                HStack(alignment: expanded ? .top : .center, spacing: 12) {
                    leading(size: 40)
                    words
                }
            }
            if expanded {
                HStack(spacing: 10) {
                    Button(action: dismiss) {
                        Text("Dismiss").frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(.white.opacity(0.12), in: Capsule())
                    }.accessibilityIdentifier("inAppNoticeDismiss")
                    Button(action: open) {
                        Text(openTitle).frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(accent.mix(with: .white, by: 0.12), in: Capsule())
                    }.accessibilityIdentifier("inAppNoticeOpen")
                }
                .buttonStyle(.plain).font(KemoType.font(.subheadline, weight: .semibold)).foregroundStyle(.white)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, islandBand == nil ? (expanded ? 16 : 13) : 0)
        .padding(.bottom, expanded ? 16 : 14)
    }
    private var time: some View { Text("now").font(KemoType.font(.caption2)).foregroundStyle(.white.opacity(0.45)) }
    private var words: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(notice.title).font(KemoType.font(.subheadline, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                if let subtitle = notice.subtitle {
                    Text(subtitle).font(KemoType.font(.footnote)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
                Spacer(minLength: 4)
                if islandBand == nil { time }
            }
            Text(expanded ? (notice.detail ?? notice.body) : notice.body)
                .font(KemoType.font(.subheadline)).foregroundStyle(.white.opacity(0.8))
                .lineLimit(expanded ? 7 : 1)
                .fixedSize(horizontal: false, vertical: expanded)
                .accessibilityIdentifier("inAppNoticeBody")
        }
    }
    @ViewBuilder private func leading(size: CGFloat) -> some View {
        switch notice.style {
        case .mac(let kind):
            Image(systemName: kind == .approval ? "laptopcomputer.and.arrow.down" : kind == .failed ? "exclamationmark.triangle" : "laptopcomputer")
                .font(.system(size: size * 0.42, weight: .medium)).foregroundStyle(kind == .failed ? Color.orange : accent.mix(with: .white, by: 0.25))
                .frame(width: size, height: size).background(.white.opacity(0.1), in: Circle())
        case .reply, .day:
            Group {
                if let companion {
                    ArtworkCompanion(theme: companion, performance: "idle", reducedMotion: true, active: false).scaleEffect(1.18)
                } else {
                    Image(systemName: "sparkles").foregroundStyle(accent)
                }
            }
            .frame(width: size, height: size).background(.white.opacity(0.08), in: Circle()).clipShape(Circle())
            .overlay(alignment: .bottomTrailing) {
                if notice.style == .day {
                    Image(systemName: "calendar").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 17, height: 17).background(accent, in: Circle()).overlay { Circle().strokeBorder(.black, lineWidth: 1.5) }
                        .offset(x: 3, y: 3)
                }
            }
            .accessibilityHidden(true)
        }
    }
    private var openTitle: String {
        switch notice.style {
        case .reply: "Open chat"
        case .day: "Review"
        case .mac: "View"
        }
    }
}

#if DEBUG
/// UI tests show a notice through the real decision path: `--in-app-notice=reply`, `day`, `mac`,
/// or `queue` (a reply, then the Mac), a moment after launch.
enum InAppNoticeProbe {
    @MainActor static func start(store: AppStore) {
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--in-app-notice=") }) else { return }
        let kind = String(argument.dropFirst("--in-app-notice=".count))
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            let conversation = store.state.openConversations?[store.currentConversationSlot]?.id
            let answer = "Saturday is set: brunch at 11 with Maya, the farmers market after, and a long walk by the water before dinner. I kept the evening free."
            let mac = DeviceNotice(id: UUID(), kind: .approval, task: UUID(), agent: "Claude Code", project: "KemoSabe", request: .command, time: Date())
            switch kind {
            case "reply": KemoNotifier.shared.replyFinished(answer, conversation: conversation, origin: .chat, preparedForReview: false)
            case "day": KemoNotifier.shared.replyFinished(answer, conversation: conversation, origin: .chat, preparedForReview: true)
            case "mac": KemoNotifier.shared.macNotice(mac)
            case "queue":
                KemoNotifier.shared.replyFinished(answer, conversation: conversation, origin: .chat, preparedForReview: false)
                KemoNotifier.shared.macNotice(mac)
            default: break
            }
        }
    }
}
#endif

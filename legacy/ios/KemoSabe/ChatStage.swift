import SwiftUI

// Kemo in a chat is like a profile picture in a chat app (the owner's request, September 27, 2026):
// every reply carries a small, still Kemo avatar, and the thinking row is that avatar with its small
// thinking orb. When the chat has room (a short conversation, or scrolled to the top), Kemo jumps up
// to the stage above the conversation and acts out what it's doing (greeting, idle, or the task's
// performance). When the conversation fills the view, the big Kemo shrinks into the latest reply's
// avatar, and it hops back up once there's room again. Only one Kemo animates at a time; the stage
// never covers a message, and Reduce Motion crossfades with Kemo still. Shared by iPhone and Mac.

/// Where Kemo is in a chat: up on the stage above the conversation, or in the latest reply's avatar.
/// A pure function of the transcript's geometry and the chat's state, so every case can be tested.
enum ChatStage {
    /// The transcript's scroll geometry.
    struct Metrics: Equatable {
        /// The conversation's height, the stage not included (the stage sits above the scroll view).
        var contentHeight: CGFloat = 0
        /// The transcript's visible height right now (smaller while the stage is shown).
        var viewportHeight: CGFloat = 0
        /// How far the conversation is scrolled from its top.
        var distanceFromTop: CGFloat = 0
    }
    /// A few points of give, so a bounce or a rounding error never moves Kemo.
    static let slack: CGFloat = 8

    /// Whether the big Kemo is on the stage.
    /// - Parameters:
    ///   - stageHeight: the stage's height when shown.
    ///   - shown: whether it's shown now (the decision has hysteresis, so Kemo never flickers).
    ///   - allowed: the person hasn't hidden the big Kemo, and the chat is on screen.
    ///   - voiceMode: a spoken exchange is under way; Kemo stays where it is until it ends.
    ///   - pinned: a performance was just asked for; it plays on the stage until the person scrolls.
    ///   - empty: a new chat with no messages yet, which always starts with Kemo on the stage (on a
    ///     small screen its greeting scrolls under it).
    ///   - browsing: the person scrolled the conversation by hand and isn't back at its latest message.
    ///     While they haven't, the chat follows the latest message: once the conversation outgrows the
    ///     room under the stage, Kemo moves into the avatar at once, so the stage never pushes a message
    ///     (the one you just sent, say) out of view (September 28, 2026: the hand-off demo ended with the
    ///     big Kemo up and your message scrolled away under it).
    static func stageShown(_ metrics: Metrics, stageHeight: CGFloat, shown: Bool,
                           allowed: Bool, voiceMode: Bool = false, pinned: Bool = false, empty: Bool = false,
                           browsing: Bool = true) -> Bool {
        guard allowed else { return false }
        if pinned || empty { return true }
        if voiceMode { return shown }
        // Not measured yet: a new chat starts with Kemo on the stage.
        guard metrics.viewportHeight > 0 else { return shown }
        // The room the stage and the conversation share, which doesn't change as the stage comes and goes.
        let available = metrics.viewportHeight + (shown ? stageHeight : 0)
        // A short conversation: everything fits under the stage.
        if metrics.contentHeight + stageHeight <= available { return true }
        let maxOffset = max(0, metrics.contentHeight - metrics.viewportHeight)
        let atTop = metrics.distanceFromTop <= slack
        let atBottom = metrics.distanceFromTop >= maxOffset - slack
        if shown {
            // Following the latest message: the conversation fills the view, so Kemo moves into the avatar.
            if atBottom || !browsing { return false }
            // Scrolled to the top: Kemo stays up until the person has scrolled well past where it stood.
            return metrics.distanceFromTop < stageHeight + 2 * slack
        }
        // Back at the top of a conversation long enough to scroll: the stage area is free again.
        let overflow = metrics.contentHeight - available
        return atTop && overflow > 3 * slack
    }

    /// While the stage is shown for a conversation longer than the view (the person scrolled to its
    /// top), the transcript keeps its top in place as the stage comes in; otherwise it keeps its bottom,
    /// so the latest message never moves when Kemo leaves or arrives.
    static func anchorsTop(_ metrics: Metrics, stageHeight: CGFloat, shown: Bool, browsing: Bool = true) -> Bool {
        guard shown, browsing, metrics.viewportHeight > 0 else { return false }
        return metrics.contentHeight > metrics.viewportHeight + slack
    }

    /// At the conversation's latest message (within a bounce's worth of give).
    static func atBottom(_ metrics: Metrics) -> Bool {
        metrics.distanceFromTop >= max(0, metrics.contentHeight - metrics.viewportHeight) - slack
    }

    /// What the stage acts out: the performance or task under way, and a greeting to open a new chat.
    static func performance(live: String, conversationEmpty: Bool) -> String {
        live == ArtworkPerformance.idle.rawValue && conversationEmpty ? ArtworkPerformance.greeting.rawValue : live
    }

    /// The matched-geometry identity Kemo keeps as it moves between the stage and an avatar.
    static let kemoID = "chatStageKemo"
}

/// What the transcript needs to know about the stage: where Kemo is, the namespace it moves in, and
/// where to report its geometry. The default (no stage) keeps Kemo in the avatars, as in onboarding.
struct ChatStageContext {
    var namespace: Namespace.ID?
    /// Kemo is in the latest reply's avatar (the stage is hidden).
    var kemoInAvatar = true
    /// Keep the top in place on size changes (`ChatStage.anchorsTop`).
    var anchorsTop = false
    var reduceMotion = false
    var report: ((ChatStage.Metrics) -> Void)?
    /// The person started scrolling (ends a pinned performance).
    var scrolled: (() -> Void)?
    /// On Mac, a new chat's Kemo sits in the greeting (`NewChatLayout`), the same as in a new Tsukumo task.
    var emptyKemo: AnyView?
    /// Where the new chat's greeting starts (`NewChatLayout.topInset`).
    var emptyTopInset: CGFloat = 38
}

/// A new chat's empty state on Mac, shared by KemoSabe's chat and a new Tsukumo task so Kemo has the
/// same size, the same place, and the same spacing to the title on both: Kemo (168 pt), the title,
/// the subtitle, and a few ways to start, on one center line.
struct NewChatLayout<Kemo: View, Suggestions: View>: View {
    let title: String
    let subtitle: String
    var subtitleFont: Font = KemoType.font(.body)
    var topInset: CGFloat = 38
    @ViewBuilder var kemo: Kemo
    @ViewBuilder var suggestions: Suggestions
    @Environment(\.newChatKemoFrame) private var reportFrame
    var body: some View {
        VStack(spacing: 12) {
            kemo.frame(width: NewChatMetrics.kemoSize, height: NewChatMetrics.kemoSize)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { reportFrame?($0) }
            Text(title).font(KemoType.font(.largeTitle, weight: .semibold))
            Text(subtitle).font(subtitleFont).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) { suggestions }.padding(.top, 18)
        }
        .multilineTextAlignment(.center)
        .padding(.top, topInset).padding(.bottom, 20).frame(maxWidth: .infinity)
    }
}
/// Tests read where a new chat's Kemo landed, to check KemoSabe's and Tsukumo's match.
private struct NewChatKemoFrameKey: EnvironmentKey { static let defaultValue: ((CGRect) -> Void)? = nil }
extension EnvironmentValues {
    var newChatKemoFrame: ((CGRect) -> Void)? {
        get { self[NewChatKemoFrameKey.self] }
        set { self[NewChatKemoFrameKey.self] = newValue }
    }
}
enum NewChatMetrics {
    static let kemoSize: CGFloat = 168
    /// The greeting's height plus the composer's area, which the greeting is centered above.
    static let reserved: CGFloat = 600
    /// From the top of the page (the chat and a new Tsukumo task start at the same place under the
    /// window's header), so Kemo lands in the same spot on both whatever their composers' heights.
    static func topInset(pageHeight: CGFloat) -> CGFloat {
        guard pageHeight > 0 else { return 38 }
        return max(24, ((pageHeight - reserved) / 2).rounded())
    }
}
private struct ChatStageContextKey: EnvironmentKey { static let defaultValue = ChatStageContext() }
extension EnvironmentValues {
    var chatStage: ChatStageContext {
        get { self[ChatStageContextKey.self] }
        set { self[ChatStageContextKey.self] = newValue }
    }
}

/// Kemo as a profile picture: the approved character, still, in the person's palette, in a circle.
/// Given a namespace, it's the one Kemo that moves between the stage and this avatar, drawn at
/// whatever size the move gives it.
struct KemoAvatar: View {
    let theme: BotTheme
    var size: CGFloat = 30
    var namespace: Namespace.ID?
    var body: some View {
        ZStack {
            Circle().fill(Color.primary.opacity(0.06))
            GeometryReader { geometry in
                ArtworkScene(theme: theme, performance: .idle, side: min(geometry.size.width, geometry.size.height) * 1.2,
                             time: 0, reducedMotion: true)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .clipShape(Circle())
        .modifier(MatchedKemo(namespace: namespace))
        .frame(width: size, height: size)
    }
}
/// The stage's Kemo: with a namespace, it moves to and from the home avatar as one character;
/// without one (Reduce Motion), it crossfades.
struct StageKemo: ViewModifier {
    let namespace: Namespace.ID?
    func body(content: Content) -> some View {
        if let namespace { content.matchedGeometryEffect(id: ChatStage.kemoID, in: namespace).transition(.opacity) }
        else { content.transition(.opacity) }
    }
}
private struct MatchedKemo: ViewModifier {
    let namespace: Namespace.ID?
    func body(content: Content) -> some View {
        if let namespace { content.matchedGeometryEffect(id: ChatStage.kemoID, in: namespace) } else { content }
    }
}

/// A reply's avatar. The home avatar (the latest reply's, or the thinking row's) is where Kemo is while
/// the stage is hidden, so the big Kemo shrinks into it and hops back out of it. `orb` adds the small
/// thinking orb, which makes it the thinking row's one signal.
struct KemoAvatarSlot: View {
    let theme: BotTheme
    var home = false
    var orb: OrbState?
    var accent: Color
    var size: CGFloat = 30
    @Environment(\.chatStage) private var stage
    var body: some View {
        Group {
            if home, stage.kemoInAvatar {
                // Kemo is here: VoiceOver can find it, and the stage's Kemo moves into (and out of) it.
                KemoAvatar(theme: theme, size: size, namespace: stage.reduceMotion ? nil : stage.namespace)
                    .transition(.opacity)
                    .accessibilityElement().accessibilityLabel(CompanionIdentity.name).accessibilityIdentifier("kemoAvatar")
            } else {
                KemoAvatar(theme: theme, size: size).accessibilityHidden(true)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let orb {
                // A small backing disc keeps the orb's fine strokes readable over the avatar.
                KemoOrb(size: size * 0.62, secondary: theme.bodyColor, state: orb).tint(accent)
                    .background(Circle().fill(.background).padding(-1.5))
                    .offset(x: size * 0.2, y: size * 0.2)
            }
        }
        .frame(width: size, height: size)
    }
}

import SwiftUI
import TsukumoCore

// The chat, laid out as the website demo (ported from the old KemoSabe app's `ChatComponents.swift` and
// `ChatHandoff.swift`, in legacy/ios/KemoSabe): the owner's messages in soft bubbles on the right; each bot's replies under its avatar
// and name; KemoSabe's card, "Claude asked KemoSabe", that reads this device and becomes KemoSabe's
// answer; a working row while a bot thinks; KemoSabe above a short conversation; and the composer with
// bot chips.

struct ChatMetrics {
    var avatarSize: CGFloat = 28
    var avatarGap: CGFloat = 10
    var rowSpacing: CGFloat = 26
    var gutter: CGFloat = 24
    /// The widest line of text in the owner's bubble.
    var bubbleText: CGFloat = 228
    var bubblePadding: CGFloat = 15
    var bubbleCorner: CGFloat = 20
    init(_ density: ChatDensity = .regular) {
        guard density == .compact else { return }
        avatarSize = 22; avatarGap = 8; rowSpacing = 14; gutter = 12; bubbleText = 260; bubblePadding = 10; bubbleCorner = 14
    }
}

/// The whole chat screen: header (the app's buttons on each side of Tsukumo's mark), transcript,
/// composer, and the banner.
public struct ChatScreen<Leading: View, Trailing: View>: View {
    @Bindable var session: ChatSession
    var leading: Leading
    var trailing: Trailing
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(session: ChatSession, @ViewBuilder leading: () -> Leading,
                @ViewBuilder trailing: () -> Trailing) {
        self.session = session; self.leading = leading(); self.trailing = trailing()
    }

    public var body: some View {
        let theme = TsukumoTheme(scheme)
        VStack(spacing: 0) {
            ChatHeader { leading } trailing: { trailing }
            ChatTranscript(session: session)
            ChatComposer(session: session)
                .padding(.horizontal, 16).padding(.bottom, 8)
        }
        .background(theme.background.ignoresSafeArea())
        .overlay(alignment: .top) {
            if let banner = session.banner {
                ChatBanner(text: banner).padding(.top, 6)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.35), value: session.banner)
        .foregroundStyle(theme.ink)
        .tint(theme.accent)
    }
}

/// Tsukumo's mark and wordmark, with the screen's buttons before and after.
public struct ChatHeader<Leading: View, Trailing: View>: View {
    var leading: Leading
    var trailing: Trailing
    @Environment(\.colorScheme) private var scheme
    public init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.leading = leading(); self.trailing = trailing()
    }
    public var body: some View {
        let theme = TsukumoTheme(scheme)
        HStack(spacing: 10) {
            leading
            TsukumoArt.image(.mark).resizable().interpolation(.high).scaledToFit().frame(width: 34, height: 34)
                .colorMultiply(scheme == .dark ? .white : RGB(hex: "3A3046").color)
                .accessibilityHidden(true)
            TsukumoArt.image(.wordmark).resizable().interpolation(.high).scaledToFit().frame(height: 17)
                .colorMultiply(scheme == .dark ? .white : RGB(hex: "3A3046").color)
                .accessibilityLabel("Tsukumo").accessibilityAddTraits(.isHeader)
            Spacer()
            trailing
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.hairline).frame(height: 0.5) }
    }
}

/// A round header button, like the website's settings button.
public struct HeaderButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    public init(_ label: String, systemImage: String, action: @escaping () -> Void) {
        self.label = label; self.systemImage = systemImage; self.action = action
    }
    public var body: some View {
        let theme = TsukumoTheme(scheme)
        Button(action: action) {
            Image(systemName: systemImage).font(.system(size: 18, weight: .medium))
                .foregroundStyle(theme.ink)
                .frame(width: 42, height: 42)
                .background(theme.fill, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// "Answered Claude: “After 7 tonight”"
struct ChatBanner: View {
    let text: String
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let theme = TsukumoTheme(scheme)
        Label(text, systemImage: "checkmark.seal")
            .tsukumoFont(.subheadline, weight: .medium)
            .foregroundStyle(theme.ink.opacity(0.9))
            .lineLimit(1)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(theme.hairline))
            .padding(.horizontal, 24)
            .accessibilityIdentifier("chatBanner")
    }
}

// MARK: Transcript

/// The scrolling conversation.
public struct ChatTranscript: View {
    var session: ChatSession
    public init(session: ChatSession) { self.session = session }
    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                ChatTranscriptContent(session: session, showsStage: true)
                Color.clear.frame(height: 1).id("chatBottom")
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(session.thread.messages.isEmpty ? .top : .bottom)
            .onChange(of: session.thread.messages.count) { scrollDown(proxy) }
            .onChange(of: session.working.count) { scrollDown(proxy) }
            .onChange(of: session.liveExchanges) { scrollDown(proxy) }
            .accessibilityIdentifier("chatTranscript")
        }
    }
    private func scrollDown(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("chatBottom", anchor: .bottom) }
    }
}

/// The conversation's rows, without scrolling (the snapshot test renders this directly).
public struct ChatTranscriptContent: View {
    @Environment(\.chatDensity) private var density
    var session: ChatSession
    var showsStage: Bool
    @Environment(\.colorScheme) private var scheme

    public init(session: ChatSession, showsStage: Bool = true) {
        self.session = session; self.showsStage = showsStage
    }

    /// The stage shows until a bot has replied or KemoSabe has answered (a live question keeps it).
    private var stageStays: Bool {
        !session.thread.messages.contains { message in
            guard message.author != .owner else { return false }
            return !message.parts.contains { if case .gateQuestion = $0 { true } else { false } }
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ChatMetrics(density).rowSpacing) {
            if session.thread.messages.isEmpty {
                ChatGreeting(session: session)
            } else if showsStage && stageStays {
                // KemoSabe above the conversation until the first answer: at its computer while it
                // reads this device. As on the website, it steps away once replies arrive.
                KemoSabeFigure(bot: session.bot(BotSpec.kemoSabeID) ?? .kemoSabe(), searching: session.kemoSabeIsReading)
                    .frame(width: 150, height: 150).frame(maxWidth: .infinity)
                    .accessibilityIdentifier("chatStage")
            }
            ForEach(session.thread.messages) { message in
                ChatRow(message: message, session: session)
            }
            ForEach(session.threadBots.filter { session.showsWorkingRow($0.id) }) { bot in
                WorkingRow(bot: bot, text: session.working[bot.id]?.text ?? "")
            }
            ForEach(session.approvals) { approval in
                if let bot = session.bot(approval.bot) {
                    ApprovalCard(bot: bot, approval: approval) { session.decideApproval(approval.id, allow: $0) }
                }
            }
        }
        .padding(.horizontal, ChatMetrics(density).gutter)
        .padding(.top, session.thread.messages.isEmpty ? 8 : 16)
        .padding(.bottom, 20)
        .frame(maxWidth: 780, alignment: .leading)
        .frame(maxWidth: .infinity)
    }
}

/// The empty chat: KemoSabe, a greeting, and a few ways to start.
struct ChatGreeting: View {
    var session: ChatSession
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// While the keyboard is up, KemoSabe steps aside so the greeting stays above the composer.
    @State private var typing = false
    var body: some View {
        let theme = TsukumoTheme(scheme)
        VStack(alignment: .leading, spacing: 12) {
            if !typing {
                KemoSabeFigure(bot: session.bot(BotSpec.kemoSabeID) ?? .kemoSabe()).frame(width: 200, height: 200).frame(maxWidth: .infinity).padding(.bottom, 26)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
            }
            Text("What’s on your mind?").font(.system(size: TsukumoType.size(.largeTitle), weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Make room for your day.").tsukumoFont(.body).foregroundStyle(theme.secondary)
            VStack(alignment: .leading, spacing: 10) {
                suggestion("Plan my day", icon: "sun.max") { session.draft = "Help me plan my day. Ask what you need to know first." }
                suggestion("Think something through", icon: "sparkle") { session.draft = "Help me think through a decision. Start with one useful question." }
                suggestion("Write a message", icon: "square.and.pencil") { session.draft = "Help me write a short message. Ask who it’s for first." }
            }.padding(.top, 18)
        }
        .padding(.top, 12)
        .animation(reduceMotion ? nil : .spring(duration: 0.3), value: typing)
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in typing = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in typing = false }
        #endif
    }
    private func suggestion(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        let theme = TsukumoTheme(scheme)
        return Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundStyle(theme.accent).frame(width: 22)
                Text(title).tsukumoFont(.callout).foregroundStyle(theme.ink)
                Spacer()
                Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(theme.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(theme.fill.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.hairline))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 380)
    }
}

/// One message.
struct ChatRow: View {
    @Environment(\.chatDensity) private var density
    let message: Message
    var session: ChatSession
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = TsukumoTheme(scheme)
        if message.author == .owner {
            HStack {
                Spacer(minLength: 30)
                // The website's bubble: at most about 230 pt of text, so a long line wraps as it does there.
                HuggingWidth(maxWidth: ChatMetrics(density).bubbleText) {
                    Text(message.text).tsukumoFont(.body).lineSpacing(4).textSelection(.enabled)
                }
                .padding(ChatMetrics(density).bubblePadding)
                    .background(theme.fill, in: RoundedRectangle(cornerRadius: ChatMetrics(density).bubbleCorner))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("You: " + message.text)
            .accessibilityIdentifier("ownerMessage")
        } else if let card = gateCard {
            KemoSabeCard(card: card, session: session)
        } else {
            let bot = session.bot(message.author.botID)
            HStack(alignment: .top, spacing: ChatMetrics(density).avatarGap) {
                if let bot { BotAvatar(bot: bot, size: ChatMetrics(density).avatarSize) } else {
                    Image(systemName: "info.circle").frame(width: ChatMetrics(density).avatarSize, height: ChatMetrics(density).avatarSize).foregroundStyle(theme.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    NameLabel(name: bot?.name ?? "Tsukumo")
                    ForEach(Array(message.parts.enumerated()), id: \.offset) { _, part in
                        PartView(part: part)
                    }
                }
                Spacer(minLength: 16)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(message.parts.contains { if case .status = $0 { true } else { false } } ? "botStatus" : "botReply")
        }
    }

    private var gateCard: KemoSabeCard.Content? {
        for part in message.parts {
            if case .gateQuestion(let card) = part { return .question(card) }
            if case .gateAnswer(let card) = part { return .answer(card) }
        }
        return nil
    }
}

/// Lays its one subview out no wider than `maxWidth` (or the space offered), and no wider than it needs:
/// a short message gets a short bubble; a long one wraps at `maxWidth`.
struct HuggingWidth: Layout {
    var maxWidth: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let limit = min(proposal.width ?? maxWidth, maxWidth)
        let width = min(child.sizeThatFits(.unspecified).width, limit)
        return child.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// A bot's name beside its avatar, small and quiet.
struct NameLabel: View {
    @Environment(\.chatDensity) private var density
    let name: String
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Text(name).tsukumoFont(.caption, weight: .semibold).foregroundStyle(TsukumoTheme(scheme).secondary).lineLimit(1)
            .frame(minHeight: ChatMetrics(density).avatarSize * 0.62, alignment: .center)
    }
}

/// One part of a bot's message.
struct PartView: View {
    let part: Part
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let theme = TsukumoTheme(scheme)
        switch part {
        case .text(let text):
            Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)).tsukumoFont(.body).lineSpacing(4).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .status(let line):
            Text(line).tsukumoFont(.footnote).foregroundStyle(theme.secondary)
        case .artifact(let ref):
            Label("Reference, revision \(ref.revision)", systemImage: "doc.text")
                .tsukumoFont(.caption, weight: .medium).foregroundStyle(theme.secondary)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(theme.fill, in: Capsule())
        case .gateQuestion, .gateAnswer, .unknown:
            EmptyView()
        }
    }
}

/// A bot at work: its character typing, its name, and "Working…" or its reply so far.
struct WorkingRow: View {
    @Environment(\.chatDensity) private var density
    let bot: BotSpec
    let text: String
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let theme = TsukumoTheme(scheme)
        HStack(alignment: .top, spacing: ChatMetrics(density).avatarGap) {
            BotAvatar(bot: bot, size: ChatMetrics(density).avatarSize, state: text.isEmpty ? .working : .talking)
            VStack(alignment: .leading, spacing: 4) {
                NameLabel(name: bot.name)
                if text.isEmpty {
                    Text("Working…").tsukumoFont(.body).foregroundStyle(theme.secondary)
                } else {
                    Text(text).tsukumoFont(.body).lineSpacing(4)
                }
            }
            Spacer(minLength: 16)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("botWorking")
    }
}

// MARK: KemoSabe's card

/// KemoSabe stepping into the chat: its avatar with a lock ring, and a card, "Claude asked KemoSabe",
/// with the question, then KemoSabe reading this device (or, the first time, asking the owner), then
/// its answer with what stayed on this device, what it didn't read, and exactly what was shared.
public struct KemoSabeCard: View {
    @Environment(\.chatDensity) private var density
    public enum Content { case question(GateQuestionCard), answer(GateAnswerCard) }
    let card: Content
    var session: ChatSession?
    /// The device that answers, when there's no session ("iPhone").
    var device: String
    @Environment(\.colorScheme) private var scheme

    public init(card: Content, session: ChatSession?, device: String = "iPhone") {
        self.card = card; self.session = session; self.device = device
    }

    private var kemoSabe: BotSpec { session?.bot(BotSpec.kemoSabeID) ?? .kemoSabe() }
    private var asker: String {
        switch card { case .question(let q): q.askerName; case .answer(let a): a.askerName }
    }
    private var question: String {
        switch card { case .question(let q): q.question; case .answer(let a): a.question }
    }
    private var deviceName: String {
        switch card { case .answer(let a): a.device; case .question: session?.device ?? device }
    }
    private var caption: String { "On this \(deviceName) · Apple on-device" }

    public var body: some View {
        let theme = TsukumoTheme(scheme)
        // KemoSabe's color, from its companion palette (coral in Apricot): the one thing about it that changes.
        let tint = kemoSabe.kemoSabeColor
        HStack(alignment: .top, spacing: ChatMetrics(density).avatarGap) {
            BotAvatar(bot: kemoSabe, size: ChatMetrics(density).avatarSize, locked: true)
            VStack(alignment: .leading, spacing: 6) {
                NameLabel(name: kemoSabe.name)
                VStack(alignment: .leading, spacing: 8) {
                    Label("\(asker) asked \(kemoSabe.name)", systemImage: "lock.shield")
                        .tsukumoFont(.caption, weight: .semibold).foregroundStyle(kemoSabe.kemoSabeTextColor(scheme))
                    Text("“" + question + "”").tsukumoFont(.body).foregroundStyle(theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    switch card {
                    case .question(let q): questionBody(q, theme: theme)
                    case .answer(let a): answerBody(a, theme: theme)
                    }
                    Label(caption, systemImage: "apple.intelligence")
                        .tsukumoFont(.caption2, weight: .medium).foregroundStyle(theme.secondary)
                }
                .padding(12)
                .frame(maxWidth: 460, alignment: .leading)
                .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(tint.opacity(0.2)))
            }
            Spacer(minLength: 16)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private var identifier: String {
        switch card {
        case .question(let q): q.state == .needsConsent ? "kemoSabeConsent" : "kemoSabeQuestion"
        case .answer: "kemoSabeAnswer"
        }
    }

    @ViewBuilder private func questionBody(_ q: GateQuestionCard, theme: TsukumoTheme) -> some View {
        if !q.purpose.isEmpty {
            Text("Why: " + q.purpose).tsukumoFont(.caption).foregroundStyle(theme.secondary)
        }
        if q.state == .needsConsent, let session, session.needsConsent(q.exchange) {
            ConsentPrompt(asker: q.askerName, kemoSabe: kemoSabe.name, device: deviceName, accent: kemoSabe.kemoSabeColor) { choice in
                session.decide(choice, for: q.exchange)
            }
        } else if let session, let prompt = session.sharePrompts[q.exchange] {
            ShareCard(asker: q.askerName, prompt: prompt, accent: kemoSabe.kemoSabeColor) { allow in session.decideShare(allow, for: q.exchange) }
        } else if session?.isLive(q.exchange) ?? true {
            HStack(spacing: 8) {
                SearchingOrb(size: 18, color: kemoSabe.kemoSabeColor)
                Text("Looking on this \(deviceName)…").tsukumoFont(.body).foregroundStyle(theme.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("kemoSabeLooking")
        }
    }

    @ViewBuilder private func answerBody(_ a: GateAnswerCard, theme: TsukumoTheme) -> some View {
        Text(answerText(a)).tsukumoFont(.body, weight: .semibold).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        if let stayed = a.stayedLine {
            Label(stayed, systemImage: "lock").tsukumoFont(.caption).foregroundStyle(theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let notRead = a.notReadLine {
            Text(notRead).tsukumoFont(.caption).foregroundStyle(theme.secondary)
        }
        if let notShared = a.notSharedLine {
            Text(notShared).tsukumoFont(.caption).foregroundStyle(theme.secondary)
        }
        if let shared = a.shared, a.outcome == .answered {
            Text("Shared: “\(shared)”").tsukumoFont(.caption2).foregroundStyle(theme.secondary)
        }
    }

    /// KemoSabe's line: exactly what the bot got, or why it got nothing.
    func answerText(_ a: GateAnswerCard) -> String {
        switch a.outcome {
        case .answered: a.shared ?? ""
        case .denied: "I didn’t share that with \(a.askerName)."
        case .nothingToShare: "I couldn’t find that in what \(a.askerName) may ask about."
        case .unavailable: "I can’t answer on this \(a.device) right now."
        }
    }
}

/// The first time a bot asks: Allow always, Allow once, Don't allow.
struct ConsentPrompt: View {
    let asker: String
    let kemoSabe: String
    let device: String
    /// KemoSabe's color.
    var accent: Color? = nil
    let decide: (ConsentChoice) -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.chatDensity) private var density
    var body: some View {
        let theme = TsukumoTheme(scheme)
        VStack(alignment: .leading, spacing: 8) {
            Text("Let \(asker) ask \(kemoSabe) about you?").tsukumoFont(.callout, weight: .semibold)
            Text("\(kemoSabe) reads on this \(device) and sends back only the answer. Sensitive items still ask you. Device only and Secret never leave.")
                .tsukumoFont(.caption).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { buttons(theme) }
                VStack(alignment: .leading, spacing: 8) { buttons(theme) }
            }
            .controlSize(density == .compact ? .small : .regular)
        }
        .accessibilityElement(children: .contain)
    }
    @ViewBuilder private func buttons(_ theme: TsukumoTheme) -> some View {
        Button(ConsentChoice.always.title) { decide(.always) }.modifier(ProminentAccent(accent: accent ?? theme.accent))
            .accessibilityIdentifier("consentAlways")
        Button(ConsentChoice.once.title) { decide(.once) }.buttonStyle(.bordered).accessibilityIdentifier("consentOnce")
        Button(ConsentChoice.deny.title) { decide(.deny) }.buttonStyle(.bordered).accessibilityIdentifier("consentDeny")
    }
}

/// A coding bot asking to do something its access leaves to the owner: what it wants, then Allow or
/// Don't allow. Its turn waits until the owner answers (stopping the turn answers no).
struct ApprovalCard: View {
    @Environment(\.chatDensity) private var density
    let bot: BotSpec
    let approval: ChatSession.PendingApproval
    let decide: (Bool) -> Void
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let theme = TsukumoTheme(scheme)
        HStack(alignment: .top, spacing: ChatMetrics(density).avatarGap) {
            BotAvatar(bot: bot, size: ChatMetrics(density).avatarSize, state: .working)
            VStack(alignment: .leading, spacing: 8) {
                Text("\(bot.name) wants to").tsukumoFont(.caption, weight: .semibold).foregroundStyle(theme.secondary)
                Text(approval.summary).tsukumoFont(.callout, weight: .semibold).lineLimit(4).textSelection(.enabled)
                Text("Its permissions ask you first for this. Nothing happens until you answer.")
                    .tsukumoFont(.caption).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Allow") { decide(true) }.modifier(ProminentAccent(accent: theme.accent)).accessibilityIdentifier("approvalAllow")
                    Button("Don’t allow") { decide(false) }.buttonStyle(.bordered).accessibilityIdentifier("approvalDeny")
                }
                .controlSize(density == .compact ? .small : .regular)
            }
            .padding(12)
            .background(theme.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.orange.opacity(0.45), lineWidth: 0.75))
            Spacer(minLength: 16)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("approvalCard")
    }
}

/// One Sensitive item: exactly what would be sent, where it came from, Share or Don't share.
struct ShareCard: View {
    let asker: String
    let prompt: SharePrompt
    /// KemoSabe's color.
    var accent: Color? = nil
    let decide: (Bool) -> Void
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let theme = TsukumoTheme(scheme)
        VStack(alignment: .leading, spacing: 8) {
            Text("Share this with \(asker)?").tsukumoFont(.callout, weight: .semibold)
            Text("“\(prompt.answer)”").tsukumoFont(.body, weight: .semibold)
            Text("From \(prompt.sourceTitle). It’s \(prompt.level.title), so KemoSabe asks first.")
                .tsukumoFont(.caption).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Share") { decide(true) }.modifier(ProminentAccent(accent: accent ?? theme.accent)).accessibilityIdentifier("shareAllow")
                Button("Don’t share") { decide(false) }.buttonStyle(.bordered).accessibilityIdentifier("shareDeny")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kemoSabeShare")
    }
}

/// KemoSabe's small loading mark while it reads: a ring of dots turning, in coral (still with Reduce
/// Motion). Never a spinning wheel.
public struct SearchingOrb: View {
    var size: CGFloat
    /// KemoSabe's color; nil is coral.
    var color: Color?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    public init(size: CGFloat = 18, color: Color? = nil) { self.size = size; self.color = color }
    public var body: some View {
        Group {
            if reduceMotion {
                dots(at: 0)
            } else {
                // A periodic schedule, not `.animation`: macOS stops a display-linked schedule in a
                // panel it reports as hidden, such as a menu-bar panel.
                TimelineView(.periodic(from: .now, by: 1.0 / 30)) { context in
                    dots(at: context.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
    private func dots(at t: Double) -> some View {
        let accent = color ?? TsukumoTheme(scheme).accent
        return Canvas { ctx, canvas in
            let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
            for ring in 0..<3 {
                let radius = canvas.width * (0.16 + 0.15 * Double(ring))
                let count = 6 + ring * 4
                for index in 0..<count {
                    let angle = Double(index) / Double(count) * 2 * .pi + t * (ring % 2 == 0 ? 1.4 : -1.1)
                    let pulse = 0.45 + 0.55 * abs(sin(t * 2 + Double(index) * 0.7 + Double(ring)))
                    let dot = canvas.width * 0.055
                    let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
                    ctx.fill(Path(ellipseIn: CGRect(x: point.x - dot / 2, y: point.y - dot / 2, width: dot, height: dot)),
                             with: .color(accent.opacity(pulse)))
                }
            }
        }
    }
}

/// The card's main button in KemoSabe's coral. On a Mac the card often sits in a panel that isn't the key
/// window (the dock's bubble), where the system's prominent style turns grey, so there
/// it's a coral capsule of its own.
struct ProminentAccent: ViewModifier {
    let accent: Color
    func body(content: Content) -> some View {
        #if os(macOS)
        content.buttonStyle(AccentCapsuleStyle(accent: accent))
        #else
        content.buttonStyle(.borderedProminent).tint(accent)
        #endif
    }
}

#if os(macOS)
struct AccentCapsuleStyle: ButtonStyle {
    let accent: Color
    @Environment(\.controlSize) private var size
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size == .small ? 11 : 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, size == .small ? 8 : 12).padding(.vertical, size == .small ? 3 : 5)
            .background(accent.opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4), in: Capsule())
    }
}
#endif

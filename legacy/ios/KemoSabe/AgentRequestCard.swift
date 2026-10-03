import SwiftUI

/// The app theme's colors, so the same card sits in the iPhone's and the Mac's themes.
struct AgentCardColors {
    var background: Color
    var surface: Color
    var foreground: Color
    var accent: Color
}

/// An agent's request: who's asking and what for, exactly what would be shared, what stays, and
/// Share or Decline. Labels and buttons only (design/UI-GUIDE.md#agent-requests).
struct AgentRequestCardView: View {
    let card: AgentRequestInbox.Card
    let colors: AgentCardColors
    let share: (AgentSlice) -> Void
    let decline: () -> Void
    let done: () -> Void
    @State private var editing = false
    @State private var answer = ""
    @State private var excerpt = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                content
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
        .accessibilityIdentifier("agentRequestCard")
        .onChange(of: card.phase, initial: true) {
            if case .ready(let slice) = card.phase, answer.isEmpty { answer = slice.answer; excerpt = slice.excerpt }
        }
    }

    private var subjectTitle: String { card.subject?.title ?? "something on this \(AgentDevice.name)" }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").font(.system(size: 17, weight: .semibold)).foregroundStyle(colors.accent)
                    .frame(width: 34, height: 34).background(colors.accent.opacity(0.14), in: Circle())
                Text(card.request.requester.name).font(KemoType.font(.headline, weight: .semibold))
                Spacer(minLength: 0)
            }
            Text("\(card.request.requester.name) wants to access \(subjectTitle), looking for \(card.request.lookingFor).")
                .font(KemoType.font(.title3, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("agentRequestSummary")
        }
    }

    @ViewBuilder private var content: some View {
        switch card.phase {
        case .reading:
            HStack(spacing: 10) {
                KemoOrb(size: 22, state: .searching)
                Text("Reading on this \(AgentDevice.name)").font(KemoType.font(.subheadline)).opacity(0.75)
            }.padding(.vertical, 6)
        case .ready:
            // `answer` and `excerpt` start as the extraction and are what Share sends.
            section("Would share") {
                if editing {
                    TextField("Answer", text: $answer, axis: .vertical).font(KemoType.font(.body, weight: .semibold))
                        .textFieldStyle(.plain).accessibilityIdentifier("agentRequestAnswerField")
                    TextField("Excerpt", text: $excerpt, axis: .vertical).font(KemoType.font(.callout))
                        .textFieldStyle(.plain).opacity(0.85).accessibilityIdentifier("agentRequestExcerptField")
                } else {
                    Text(answer).font(KemoType.font(.body, weight: .semibold)).accessibilityIdentifier("agentRequestAnswer")
                    if !excerpt.isEmpty {
                        Text("“" + excerpt + "”").font(KemoType.font(.callout)).opacity(0.8).accessibilityIdentifier("agentRequestExcerpt")
                    }
                }
            } trailing: {
                Button(editing ? "Done" : "Edit") { editing.toggle() }.font(KemoType.font(.subheadline, weight: .semibold))
                    .buttonStyle(.plain).foregroundStyle(colors.accent).accessibilityIdentifier("agentRequestEdit")
            }
            stays
        case .notFound:
            section("Not found") { Text("KemoSabe couldn’t find that in \(subjectTitle).").font(KemoType.font(.body)) }
            nothingShared
        case .refused(let level):
            section("Can’t share") {
                Text(level == .secret ? "\(subjectTitle.prefix(1).uppercased() + subjectTitle.dropFirst()) is set to Secret, so no model reads it."
                     : "\(subjectTitle.prefix(1).uppercased() + subjectTitle.dropFirst()) is set to Device only, so it can’t be shared.")
                    .font(KemoType.font(.body)).accessibilityIdentifier("agentRequestRefused")
            }
            nothingShared
        case .unavailable(let reason):
            section("Not now") { Text(reason).font(KemoType.font(.body)) }
            nothingShared
        case .shared(let slice):
            section("Shared with \(card.request.requester.name)") {
                Text(slice.answer).font(KemoType.font(.body, weight: .semibold))
                if !slice.excerpt.isEmpty { Text("“" + slice.excerpt + "”").font(KemoType.font(.callout)).opacity(0.8) }
            }.accessibilityIdentifier("agentRequestShared")
            stays
        case .declined:
            section("Declined") { Text("\(card.request.requester.name) got nothing.").font(KemoType.font(.body)) }
                .accessibilityIdentifier("agentRequestDeclined")
        }
    }

    private var stays: some View {
        Label("The rest of \(subjectTitle) stays on your \(AgentDevice.name).", systemImage: "lock")
            .font(KemoType.font(.subheadline)).opacity(0.75).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("agentRequestWithheld")
    }
    private var nothingShared: some View {
        Label("Nothing is shared.", systemImage: "lock").font(KemoType.font(.subheadline)).opacity(0.75)
    }

    private func section<Content: View, Trailing: View>(_ title: String, @ViewBuilder content: () -> Content,
                                                         @ViewBuilder trailing: () -> Trailing = { EmptyView() }) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(KemoType.font(.caption, weight: .semibold)).textCase(.uppercase).opacity(0.6)
                Spacer(minLength: 0)
                trailing()
            }
            VStack(alignment: .leading, spacing: 8, content: content).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var buttons: some View {
        switch card.phase {
        case .ready:
            HStack(spacing: 12) {
                Button { decline() } label: { Text("Decline").frame(maxWidth: .infinity) }
                    .buttonStyle(AgentCardButtonStyle(fill: colors.surface, ink: colors.foreground))
                    .accessibilityIdentifier("agentRequestDecline")
                Button { share(AgentSlice(answer: answer, excerpt: excerpt)) } label: { Text("Share").frame(maxWidth: .infinity) }
                    .buttonStyle(AgentCardButtonStyle(fill: colors.accent, ink: colors.background))
                    .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("agentRequestShare")
            }
        case .shared, .declined:
            Button { done() } label: { Text("Done").frame(maxWidth: .infinity) }
                .buttonStyle(AgentCardButtonStyle(fill: colors.surface, ink: colors.foreground))
                .accessibilityIdentifier("agentRequestDone")
        default:
            Button { decline() } label: { Text("Decline").frame(maxWidth: .infinity) }
                .buttonStyle(AgentCardButtonStyle(fill: colors.surface, ink: colors.foreground))
                .accessibilityIdentifier("agentRequestDecline")
        }
    }
}

/// Soft rounded buttons in the theme's colors.
struct AgentCardButtonStyle: ButtonStyle {
    var fill: Color
    var ink: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(KemoType.font(.body, weight: .semibold)).foregroundStyle(ink)
            .padding(.vertical, 13).padding(.horizontal, 16)
            .background(fill.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

extension View {
    /// Shows an agent's request as a sheet over whatever is on screen, one at a time; an agent's first
    /// question as "Let Muse ask KemoSabe?"; and a short notice when an agent was answered.
    func agentRequestSheet(store: AppStore, colors: AgentCardColors) -> some View {
        modifier(AgentRequestSheet(inbox: store.agentRequests, desk: store.agentQuestions, colors: colors))
    }
}

private struct AgentRequestSheet: ViewModifier {
    let inbox: AgentRequestInbox
    let desk: AgentQuestionDesk
    let colors: AgentCardColors
    func body(content: Content) -> some View {
        content
            // An agent chatting in the KemoSabe chat asks on Kemo's card there (`KemoAskCard`), not here.
            .alert(desk.consent.map { "Let \($0.requester.name) ask KemoSabe?" } ?? "",
                   isPresented: Binding(get: { desk.consent.map { !$0.inChat } ?? false }, set: { _ in }), presenting: desk.consent) { _ in
                Button("Allow always") { desk.decide(.always) }.accessibilityIdentifier("agentConsentAlways")
                Button("Allow once") { desk.decide(.once) }.accessibilityIdentifier("agentConsentOnce")
                Button("Don’t allow", role: .cancel) { desk.decide(.deny) }.accessibilityIdentifier("agentConsentDeny")
            } message: { prompt in
                Text(AgentConsentText.message(prompt))
            }
            .overlay(alignment: .top) {
                if let notice = desk.notice {
                    Label(notice.text, systemImage: "checkmark.seal")
                        .font(KemoType.font(.subheadline, weight: .semibold)).lineLimit(2)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(colors.surface, in: Capsule()).foregroundStyle(colors.foreground)
                        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                        .padding(.top, 14).padding(.horizontal, 20)
                        .onTapGesture { desk.notice = nil }
                        .task(id: notice.id) {
                            try? await Task.sleep(for: .seconds(6))
                            if desk.notice?.id == notice.id { desk.notice = nil }
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .accessibilityIdentifier("agentQuestionNotice")
                }
            }
            .animation(.snappy, value: desk.notice)
            .sheet(item: Binding(get: { inbox.current }, set: { if $0 == nil { inbox.dismiss() } })) { card in
            AgentRequestCardView(card: card, colors: colors, share: { slice in Task { await inbox.share(slice) } },
                                 decline: { Task { await inbox.decline() } }, done: { inbox.dismiss() })
                #if os(iOS)
                .presentationDetents([.fraction(0.66), .large])
                .presentationBackground(colors.background)
                #else
                .frame(width: 480, height: 460)
                #endif
                .interactiveDismissDisabled({ if case .reading = card.phase { true } else { false } }())
        }
    }
}

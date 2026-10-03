import SwiftUI

/// Home: an explore page for what you and your companion can do. Tiles prepare
/// a message for review in Chat; nothing runs or asks for access from here.
struct HomeExploreView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.mobilePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(CompanionIdentity.key, store: AccountDirectory.accountSettings) private var companionName = CompanionIdentity.defaultName
    @State private var profiles = ProfileStore.shared
    var prepare: (String) -> Void
    var resume: (ConversationArchive) -> Void
    var openDay: () -> Void
    var openProfile: () -> Void

    struct Idea: Identifiable {
        let symbol: String, title: String, detail: String, prompt: String
        var id: String { symbol }
    }
    static let ideas: [Idea] = [
        .init(symbol: "sun.max", title: "Make space in your day", detail: "Work around commitments and leave room to breathe.", prompt: "Help me plan my day. Ask about my priorities and commitments first."),
        .init(symbol: "text.bubble", title: "Draft a thoughtful reply", detail: "Find the right words for a message.", prompt: "Help me draft a reply. Ask me who it is for, what happened, and what I want to say."),
        .init(symbol: "arrow.triangle.branch", title: "Think through a decision", detail: "Weigh the options against what matters.", prompt: "Help me think through a decision. Ask one useful question at a time."),
        .init(symbol: "checklist", title: "Break a goal into steps", detail: "Turn an intention into a next move.", prompt: "Help me break a goal into manageable steps. Start by asking what I want to accomplish."),
        .init(symbol: "square.stack", title: "Remember a preference", detail: "Keep a useful detail for later.", prompt: "I want to save a preference. Ask what I would like you to remember, then let me review it."),
        .init(symbol: "figure.dance", title: "Take a little break", detail: "A moment with your companion.", prompt: "Do your dance")
    ]
    private static let skills: [(String, String, String)] = [
        ("pencil.and.scribble", "Write", "Help me write something. Ask what it is and who it's for."),
        ("book", "Summarize", "Summarize this for me: "),
        ("timer", "Focus", "Help me focus for the next 25 minutes. Ask what I'm working on."),
        ("headphones", "Music break", "Play some music and dance"),
        ("lightbulb", "Brainstorm", "Brainstorm ideas with me. Ask what the topic is."),
        ("person.2", "Plan with a friend", "Help me plan something with a friend. Ask who and what.")
    ]
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                greeting
                section("For you") {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(Array(Self.ideas.enumerated()), id: \.element.id) { index, idea in tile(idea, index: index) }
                    }
                }
                if !recents.isEmpty {
                    section("Pick up where you left off") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) { ForEach(recents) { recent($0) } }
                        }.scrollClipDisabled()
                    }
                }
                section("\(companionName) can") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Self.skills, id: \.1) { skill in
                                Button { prepare(skill.2) } label: {
                                    Label(skill.1, systemImage: skill.0).font(KemoType.font(.subheadline, weight: .medium))
                                        .padding(.horizontal, 14).padding(.vertical, 10)
                                        .background(palette.surface, in: Capsule())
                                }.buttonStyle(.plain).accessibilityIdentifier("skill-" + skill.1)
                            }
                        }
                    }.scrollClipDisabled()
                }
                section("Friends") {
                    Button(action: openProfile) {
                        HStack(spacing: 14) {
                            Image(systemName: "person.2.circle").font(.system(size: 30)).foregroundStyle(palette.accent)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("See your friends' secure assistants here").font(KemoType.font(.body, weight: .semibold))
                                Text("Once accounts arrive, friends' profiles and shared posts show up on Home. Your profile is ready now.")
                                    .font(KemoType.font(.footnote)).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(16).background(palette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }.buttonStyle(.plain).accessibilityIdentifier("homeFriends")
                }
                Text("Tiles prepare a message in Chat. You can edit it before sending.")
                    .font(KemoType.font(.caption)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20).padding(.vertical, 18)
            .frame(maxWidth: 700).frame(maxWidth: .infinity)
        }
        .background(palette.background)
        .accessibilityIdentifier("homeExplore")
    }

    private var greeting: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(salutation).font(KemoType.font(.subheadline)).foregroundStyle(.secondary)
                Text("What should we explore?").font(KemoType.font(.title2, weight: .semibold))
            }
            Spacer(minLength: 0)
            Button(action: openDay) {
                Label("Today", systemImage: "calendar").font(KemoType.font(.footnote, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(palette.surface, in: Capsule())
            }.buttonStyle(.plain).accessibilityIdentifier("homeToday")
        }
    }
    private var salutation: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 5 ? "Good evening" : hour < 12 ? "Good morning" : hour < 17 ? "Good afternoon" : "Good evening"
        return profiles.firstName.map { "\(part), \($0)" } ?? part
    }
    private var recents: [ConversationArchive] {
        Array((store.state.conversationArchives ?? []).filter { store.canResume($0) }.reversed().prefix(6))
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(KemoType.font(.headline, weight: .semibold))
            content()
        }
    }
    /// Idea tiles take the companion's colors, alternating so the grid reads like a feed.
    private func tile(_ idea: Idea, index: Int) -> some View {
        let theme = store.state.theme
        let coral = Color(hex: theme.accent)
        let tint = [coral, palette.accent, coral.mix(with: palette.accent, by: 0.5)][index % 3]
        return Button { prepare(idea.prompt) } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: idea.symbol).font(.system(size: 22, weight: .semibold)).foregroundStyle(tint)
                    .frame(width: 44, height: 44).background(tint.opacity(0.16), in: Circle())
                Spacer(minLength: 0)
                Text(idea.title).font(KemoType.font(.subheadline, weight: .semibold)).multilineTextAlignment(.leading)
                Text(idea.detail).font(KemoType.font(.caption)).foregroundStyle(.secondary).multilineTextAlignment(.leading).lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .padding(14)
            .background(LinearGradient(colors: [tint.opacity(0.14), palette.surface], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }.buttonStyle(.plain).accessibilityIdentifier("idea-" + idea.symbol)
    }
    private func recent(_ archive: ConversationArchive) -> some View {
        Button { resume(archive) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right").foregroundStyle(palette.accent)
                Text(archive.title).font(KemoType.font(.subheadline, weight: .semibold)).lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Text(archive.date.formatted(.relative(presentation: .named))).font(KemoType.font(.caption)).foregroundStyle(.secondary)
            }
            .frame(width: 170, height: 118, alignment: .topLeading).padding(14)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }.buttonStyle(.plain).accessibilityIdentifier("homeRecent")
    }
}

import SwiftUI
import TsukumoCore
import TsukumoUI

/// Your chats, as a bottom sheet from the composer (design/UI-GUIDE.md, Your chats): half height first, pulled up for
/// more. Search, New chat, your chats with your bots (newest first), and Activity. Picking a chat closes it.
struct ConversationsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    let close: () -> Void
    @State private var search = ""

    private var shown: [ChatThread] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return model.savedThreads }
        return model.savedThreads.filter { thread in
            thread.title.localizedCaseInsensitiveContains(query) || thread.messages.contains { $0.text.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        let theme = TsukumoTheme(scheme)
        NavigationStack {
            List {
                Section {
                    Button {
                        model.newThread()
                        close()
                    } label: {
                        Label("New chat", systemImage: "square.and.pencil").font(.body.weight(.medium))
                    }
                    .accessibilityIdentifier("drawerNewChat")
                    NavigationLink {
                        ActivityPage { close() }
                    } label: {
                        HStack {
                            Label("Activity", systemImage: "list.bullet.rectangle.portrait")
                            Spacer()
                            if !model.activity.isEmpty {
                                Text("\(model.activity.count)").font(.footnote.monospacedDigit()).foregroundStyle(theme.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("drawerActivity")
                }
                .tsukumoRows()

                Section {
                    if shown.isEmpty {
                        TsukumoEmptyState(search.isEmpty ? "No chats yet" : "No matches", systemImage: "bubble.left.and.bubble.right",
                                          message: search.isEmpty ? "Your chats with your bots show here." : "No chat mentions “\(search)”.")
                            .listRowBackground(Color.clear)
                    }
                    ForEach(shown) { thread in
                        Button {
                            model.open(thread)
                            close()
                        } label: { ChatRowSummary(thread: thread, current: thread.id == model.session.thread.id) }
                        .buttonStyle(.plain)
                        .listRowBackground(thread.id == model.session.thread.id ? theme.selected : theme.surface)
                        .swipeActions {
                            Button("Delete", role: .destructive) { model.deleteThread(thread.id) }
                        }
                        .contextMenu {
                            let kept = thread.privacy == .deviceOnly
                            Button(kept ? "Sync This Chat" : "Keep on This iPhone", systemImage: kept ? "icloud" : "iphone") {
                                model.setKeepsOnDevice(thread.id, !kept)
                            }
                            Button("Delete", systemImage: "trash", role: .destructive) { model.deleteThread(thread.id) }
                        }
                        .accessibilityIdentifier("drawerChat")
                    }
                } header: {
                    if !shown.isEmpty { Text("Chats") }
                }
            }
            .searchable(text: $search, prompt: "Search chats")
            .tsukumoScreen(sheet: true)
            .navigationTitle("Your chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close, action: close).accessibilityIdentifier("closeDrawer")
                }
            }
        }
        .accessibilityIdentifier("drawer")
    }
}

/// One chat in the drawer: the bots in it, its title, and when it last moved.
struct ChatRowSummary: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    let thread: ChatThread
    let current: Bool

    var body: some View {
        let theme = TsukumoTheme(scheme)
        let speakers = thread.bots(from: model.bots).filter { bot in thread.messages.contains { $0.author.botID == bot.id } }
        HStack(spacing: 12) {
            ZStack {
                ForEach(Array(speakers.prefix(3).enumerated()), id: \.element.id) { index, bot in
                    BotAvatar(bot: bot, size: 26, showsEngine: false).offset(x: CGFloat(index) * 9)
                }
            }
            .frame(width: 44, height: 30, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(thread.title.isEmpty ? "Chat" : thread.title).font(.subheadline.weight(current ? .semibold : .regular)).lineLimit(1)
                    if thread.privacy == .deviceOnly {
                        Image(systemName: "iphone").font(.caption2).foregroundStyle(theme.secondary).accessibilityLabel("Kept on this iPhone")
                    }
                }
                if let date = thread.messages.last?.date {
                    Text(date.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(theme.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// Activity: KemoSabe's answers and refusals, System One's decisions, and bots' work. Opening an item opens its chat.
struct ActivityPage: View {
    @Environment(AppModel.self) private var model
    /// Called after an item's chat opens (closes the sheet it's in).
    var opened: () -> Void = {}

    var body: some View {
        ActivityFeed(items: model.activity, bots: model.bots) { item in
            if let id = item.threadID, let thread = model.threads.first(where: { $0.id == id }) {
                model.open(thread)
                opened()
            }
        }
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !model.activity.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Clear Activity", role: .destructive) { model.clearActivity() }
                    } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("More")
                }
            }
        }
    }
}

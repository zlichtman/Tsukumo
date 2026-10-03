import SwiftUI
import TsukumoCore
import TsukumoUI

/// The conversations drawer: New chat at the top, your chats with your bots (newest first), and
/// Activity at the bottom. Picking a chat closes the drawer and shows it.
struct ConversationsDrawer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    let close: () -> Void
    let showActivity: () -> Void

    var body: some View {
        let theme = TsukumoTheme(scheme)
        VStack(alignment: .leading, spacing: 0) {
            Text("Chats")
                .font(.system(size: 28, weight: .semibold))
                .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 10)
                .accessibilityAddTraits(.isHeader)

            Button {
                model.newThread()
                close()
            } label: {
                Label("New chat", systemImage: "square.and.pencil")
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 13)
                    .background(theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(theme.ink)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .accessibilityIdentifier("drawerNewChat")

            List {
                if model.savedThreads.isEmpty {
                    Text("Your chats with your bots show here.")
                        .font(.subheadline).foregroundStyle(theme.secondary)
                        .listRowBackground(Color.clear)
                }
                ForEach(model.savedThreads) { thread in
                    Button {
                        model.open(thread)
                        close()
                    } label: { ChatRowSummary(thread: thread, current: thread.id == model.session.thread.id) }
                    .buttonStyle(.plain)
                    .listRowBackground(thread.id == model.session.thread.id ? theme.ink.opacity(0.08) : Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 12))
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
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .padding(.top, 8)

            Divider().overlay(theme.hairline)
            Button(action: showActivity) {
                HStack(spacing: 12) {
                    Image(systemName: "list.bullet.rectangle.portrait").frame(width: 24)
                    Text("Activity").font(.body.weight(.medium))
                    Spacer()
                    if !model.activity.isEmpty {
                        Text("\(model.activity.count)").font(.footnote.monospacedDigit()).foregroundStyle(theme.secondary)
                    }
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(theme.secondary)
                }
                .padding(.horizontal, 20).padding(.vertical, 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("drawerActivity")
        }
        .foregroundStyle(theme.ink)
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            UnevenRoundedRectangle(bottomTrailingRadius: 24, topTrailingRadius: 24, style: .continuous)
                .fill(theme.background)
                .overlay(theme.ink.opacity(scheme == .dark ? 0.04 : 0.02))
                .ignoresSafeArea()
                .shadow(color: .black.opacity(0.3), radius: 18, x: 6)
        }
        .accessibilityElement(children: .contain)
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

/// Activity, from the drawer: KemoSabe's answers and refusals, System One's decisions, and bots' work.
struct ActivityScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ActivityFeed(items: model.activity, bots: model.bots) { item in
                if let id = item.threadID, let thread = model.threads.first(where: { $0.id == id }) {
                    model.open(thread)
                    dismiss()
                }
            }
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("closeActivity") }
                if !model.activity.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Button("Clear Activity", role: .destructive) { model.clearActivity() }
                        } label: { Image(systemName: "ellipsis") }
                        .accessibilityLabel("More")
                    }
                }
            }
        }
    }
}

import SwiftUI

struct ConversationArchiveList: View {
    @Environment(AppStore.self) private var store
    @State private var selected: ConversationArchive?
    @State private var deleting: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !(store.state.conversationArchives ?? []).isEmpty {
                Text("Past conversations").font(.headline)
                ForEach((store.state.conversationArchives ?? []).reversed()) { archive in
                    Button { selected = archive } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(archive.title).foregroundStyle(.primary).lineLimit(2)
                            Text(archive.model + " · " + archive.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                    }.buttonStyle(.plain).contextMenu { Button("Delete conversation", role: .destructive) { deleting = archive.id } }
                }
            }
        }.confirmationDialog("Delete this conversation?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let deleting { store.deleteArchivedConversation(deleting) }; deleting = nil }
        } message: { Text("Removes this saved conversation from KemoSabe. Provider-retained copies and saved memories are separate.") }
        .sheet(item: $selected) { archive in
            ArchivedConversationDetail(archive: archive)
            #if os(macOS)
            .frame(width: 660, height: 560)
            #endif
        }
    }
}

struct ArchivedConversationDetail: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let archive: ConversationArchive
    /// Called after the person continues this conversation; nil hides Continue.
    var resumed: (() -> Void)? = nil
    @State private var deleting = false
    /// "Continue in…": this chat's context moves to another chat or agent as a packet, evaluated for it.
    @State private var sharing: ContextPacketSource?
    @Environment(\.chatAccentOverride) private var accent
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(archive.model).font(.caption).foregroundStyle(.secondary)
                    ForEach(archive.messages) { ChatMessageRow(message: $0) }
                }.padding(24)
            }.navigationTitle("Past conversation")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } }
                    ToolbarItem(placement: .primaryAction) { Button("Delete", systemImage: "trash", role: .destructive) { deleting = true }.accessibilityIdentifier("deleteArchivedConversation") }
                    #if os(iOS)
                    if let resumed, store.canResume(archive) {
                        ToolbarItem(placement: .bottomBar) {
                            Button("Continue this conversation", systemImage: "arrow.uturn.forward") {
                                store.resumeArchivedConversation(archive.id)
                                if store.storageError == nil { dismiss(); resumed() }
                            }.buttonStyle(.borderedProminent).accessibilityIdentifier("continueConversation")
                        }
                    } else {
                        // Held with another model: its context can still move, as a packet the policy checks.
                        ToolbarItem(placement: .bottomBar) {
                            Button("Continue in…", systemImage: "square.stack.3d.up") { sharing = .init(id: archive.id) }
                                .buttonStyle(.borderedProminent).accessibilityIdentifier("continueIn")
                        }
                    }
                    #else
                    ToolbarItem(placement: .primaryAction) {
                        Button("Continue in…", systemImage: "square.stack.3d.up") { sharing = .init(id: archive.id) }.accessibilityIdentifier("continueIn")
                    }
                    #endif
                }
                .contextPacketSheet(source: $sharing, colors: .system(accent: accent)) { _ in dismiss(); resumed?() }
                .confirmationDialog("Delete this conversation?", isPresented: $deleting, titleVisibility: .visible) {
                    Button("Delete conversation", role: .destructive) { store.deleteArchivedConversation(archive.id); if store.storageError == nil { dismiss() } }
                } message: { Text("Removes this saved conversation from KemoSabe. Saved memories and provider-retained copies are separate.") }
        }
    }
}

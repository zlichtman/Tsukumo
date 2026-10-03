import SwiftUI

// Attaching a doc or journal entry in either chat composer: `@` in the message, or the
// composer's + (Doc, Journal entry). The attachment shows as a chip and goes with the next
// message only. With a model that isn't only on this device, where it goes is named first.

/// Chips for what's attached to the next message.
struct ChatDocChips: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        if !store.composerAttachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(store.composerAttachments) { attachment in
                        HStack(spacing: 5) {
                            Image(systemName: attachment.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.tint)
                            Text(attachment.title).font(KemoType.font(.caption, weight: .medium)).lineLimit(1)
                            Button { store.composerAttachments.removeAll { $0.id == attachment.id } } label: {
                                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 16, height: 16)
                            }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Remove " + attachment.title)
                        }
                        .padding(.leading, 9).padding(.trailing, 4).padding(.vertical, 5)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("attachedDoc-" + attachment.title)
                    }
                }.padding(.horizontal, 4)
            }
        }
    }
}

/// What was attached to a sent message.
struct ChatAttachmentLabels: View {
    let attachments: [ChatDocAttachment]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(attachments) { attachment in
                Label(attachment.title, systemImage: attachment.symbol)
                    .font(KemoType.font(.caption, weight: .medium)).lineLimit(1)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Color.primary.opacity(0.07), in: Capsule())
                    .accessibilityIdentifier("sentDoc-" + attachment.title)
            }
        }
    }
}

/// Picks a doc or a journal entry to attach.
struct DocAttachmentPicker: View {
    enum Scope: String, Identifiable { case docs, journal; var id: String { rawValue } }
    let scope: Scope
    let choose: (ChatDocAttachment) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var docs = DocsStore.shared
    @State private var lock = JournalLock.shared
    @State private var query = ""
    var body: some View {
        NavigationStack {
            List {
                switch scope {
                case .docs:
                    let pages = query.isEmpty ? docs.livePages.sorted { $0.modified > $1.modified } : docs.search(query).compactMap { docs.page($0.id) }
                    if pages.isEmpty { Text(query.isEmpty ? "No docs yet" : "No matching docs").foregroundStyle(.secondary) }
                    ForEach(pages) { page in
                        Button { pick(docs.attachment(page: page.id)) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                DocPageLabel(page: page)
                                let path = DocOutline.path(to: page.id, in: docs.pages).map(\.displayTitle)
                                if !path.isEmpty { Text(path.joined(separator: " › ")).font(KemoType.font(.caption)).foregroundStyle(.secondary).padding(.leading, 30) }
                            }
                        }.buttonStyle(.plain).accessibilityIdentifier("attachPick-" + page.displayTitle)
                    }
                case .journal:
                    if !lock.isOpen {
                        JournalLockedView()
                    } else {
                        let entries = query.isEmpty ? docs.journal : docs.searchJournal(query)
                        if entries.isEmpty { Text(query.isEmpty ? "No journal entries yet" : "No matching entries").foregroundStyle(.secondary) }
                        ForEach(entries) { entry in
                            Button { pick(docs.attachment(entry: entry.id)) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(JournalCalendar.title(for: entry.day)).font(KemoType.font(.subheadline, weight: .semibold))
                                    JournalEntryRow(entry: entry, docs: docs)
                                }
                            }.buttonStyle(.plain).accessibilityIdentifier("attachPickEntry-" + entry.day)
                        }
                    }
                }
            }
            .searchable(text: $query)
            .navigationTitle(scope == .docs ? "Attach a doc" : "Attach a journal entry")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 460)
        #endif
    }
    private func pick(_ attachment: ChatDocAttachment?) {
        guard let attachment else { return }
        dismiss()
        choose(attachment)
    }
}

/// Docs matching what follows `@` in the message, to attach with one tap.
struct DocMentionSuggestions: View {
    let query: String
    let choose: (ChatDocAttachment) -> Void
    @State private var docs = DocsStore.shared
    var body: some View {
        let q = query.lowercased()
        let pages = docs.livePages.filter { q.isEmpty || $0.displayTitle.lowercased().contains(q) }.sorted { $0.modified > $1.modified }.prefix(4)
        if !pages.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(pages)) { page in
                    Button { if let attachment = docs.attachment(page: page.id) { choose(attachment) } } label: {
                        HStack(spacing: 8) {
                            DocPageLabel(page: page).font(KemoType.font(.subheadline))
                            Spacer(minLength: 0)
                            Text("Attach").font(KemoType.font(.caption)).foregroundStyle(.secondary)
                        }.padding(.horizontal, 10).padding(.vertical, 7).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("mentionDoc-" + page.displayTitle)
                }
            }
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("docMentions")
        }
    }
}

extension View {
    /// Asks before attaching a doc that would leave this device with the next message.
    func docAttachmentConfirmation(_ pending: Binding<ChatDocAttachment?>, store: AppStore) -> some View {
        confirmationDialog("Attach “\(pending.wrappedValue?.title ?? "")”?", isPresented: Binding(get: { pending.wrappedValue != nil }, set: { if !$0 { pending.wrappedValue = nil } }), titleVisibility: .visible) {
            Button("Attach") {
                if let attachment = pending.wrappedValue { store.confirmAttachment(attachment) }
                pending.wrappedValue = nil
            }.accessibilityIdentifier("confirmAttachDoc")
            Button("Cancel", role: .cancel) { pending.wrappedValue = nil }
        } message: {
            Text("It goes to \(store.attachmentDestination ?? "your model") with your next message.")
        }
    }
}

extension AppStore {
    /// Attaches a doc to the next message now, or returns it when where it goes must be confirmed first.
    /// `ContextPolicy` decides: a Device only or Secret item never goes where its level forbids, and
    /// anything leaving this device is confirmed first, which is the person's grant for that item.
    func attachOrConfirm(_ attachment: ChatDocAttachment) -> ChatDocAttachment? {
        guard !composerAttachments.contains(where: { $0.sourceID == attachment.sourceID }) else { return nil }
        guard composerAttachments.count < 4 else { error = "Attach up to four docs or entries to a message."; return nil }
        let recipient = currentRecipient
        switch ContextPolicy.evaluate([attachment.contextItem], to: recipient, purpose: .conversation, grants: [], now: Date()).denied[attachment.contextItem.ref] {
        case .secret?: error = "“\(attachment.title)” is set to Secret, so no model reads it."; return nil
        case .staysOnDevice?:
            error = "“\(attachment.title)” is set to Device only, so it can’t go to \(attachmentDestination ?? recipient.host)."; return nil
        case .needsGrant?: return attachment
        case nil: break
        }
        if attachmentDestination == nil { composerAttachments.append(attachment); return nil }
        return attachment
    }
}

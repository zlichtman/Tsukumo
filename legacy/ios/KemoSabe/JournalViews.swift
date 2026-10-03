import SwiftUI

// Journal pieces shared by the iPhone's Library and the Mac's two-pane Journal: one entry's
// editor (mood, photos, tags, and the block editor), the month calendar, On this day, and the
// lock screen.

/// One journal entry: when it was written, a mood, photos, tags, and its text.
struct JournalEntryEditor: View {
    let entryID: UUID
    let docs: DocsStore
    var openPage: (UUID) -> Void = { _ in }
    /// Puts the cursor in the text as it opens (a new entry).
    var autofocus = false
    @State private var model = DocEditorModel()
    @State private var addingPhoto = false
    @State private var tag = ""
    @State private var promptOffset = 0
    @State private var deleting = false
    @AppStorage("kemo.journal.prompts") private var showPrompts = true

    var body: some View {
        if let entry = docs.entry(entryID) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.created.formatted(date: .omitted, time: .shortened))
                        .font(KemoType.font(.caption, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    #if os(macOS)
                    // The Mac's format bar (and its ⌘B, ⌘I, … keys) for the entry being written.
                    if model.editing != nil { DocFormatBar(blocks: blocksBinding, model: model, compact: true) }
                    #endif
                    Menu {
                        Button(showPrompts ? "Hide prompts" : "Show prompts", systemImage: "text.bubble") { showPrompts.toggle() }
                        PrivacyLevelMenu(current: entry.privacyLevel) { level in docs.updateEntry(entryID) { $0.privacy = level } }
                        Button("Delete entry", systemImage: "trash", role: .destructive) { deleting = true }
                    } label: { Image(systemName: "ellipsis").frame(width: 30, height: 24) }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                        .accessibilityLabel("Entry options").accessibilityIdentifier("journalEntryOptions")
                }
                JournalMoodPicker(mood: entry.mood) { mood in docs.updateEntry(entryID) { $0.mood = $0.mood == mood ? nil : mood } }
                photos(entry)
                if showPrompts, entry.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(JournalPrompts.prompt(for: entry.day, offset: promptOffset))
                            .font(KemoType.font(.callout)).foregroundStyle(.secondary).italic()
                            .accessibilityIdentifier("journalPrompt")
                        Button { promptOffset += 1 } label: { Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 12)) }
                            .buttonStyle(.plain).foregroundStyle(.tertiary).accessibilityLabel("Another prompt")
                    }
                }
                DocBlocksEditor(blocks: blocksBinding, model: model,
                                host: DocEditorHost(docs: docs, pageID: nil, openPage: openPage, firstPlaceholder: "Write about your day", trailingSpace: 28))
                    .padding(.leading, -DocBlocksEditor.gutter)
                tags(entry)
            }
            #if os(iOS)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    if model.editing != nil {
                        ScrollView(.horizontal, showsIndicators: false) { DocFormatBar(blocks: blocksBinding, model: model, compact: true) }
                    }
                }
            }
            #endif
            .task {
                guard autofocus, let first = entry.blocks.first else { return }
                try? await Task.sleep(for: .milliseconds(350))
                model.request(first.id)
            }
            .confirmationDialog("Delete this entry?", isPresented: $deleting, titleVisibility: .visible) {
                Button("Delete entry", role: .destructive) { docs.deleteEntry(entryID) }
            } message: { Text("Its text and photos are removed from all your devices.") }
            .docImagePicker(isPresented: $addingPhoto, docs: docs, limit: 6) { refs in
                guard !refs.isEmpty else { return }
                docs.updateEntry(entryID) { $0.photos += refs }
            }
        }
    }
    private var blocksBinding: Binding<[DocBlock]> {
        Binding(get: { docs.entry(entryID)?.blocks ?? [DocBlock()] }, set: { blocks in docs.updateEntry(entryID) { $0.blocks = blocks } })
    }
    private func photos(_ entry: JournalEntry) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(entry.photos, id: \.file) { photo in
                    DocImageView(docs: docs, ref: photo, fill: true)
                        .frame(width: 110, height: 110).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contextMenu {
                            Button("Remove photo", systemImage: "trash", role: .destructive) {
                                docs.updateEntry(entryID) { $0.photos.removeAll { $0.file == photo.file } }
                                docs.releaseImage(photo.file)
                            }
                        }
                        .accessibilityIdentifier("journalPhoto")
                }
                if entry.photos.count < JournalEntry.maxPhotos {
                    Button { addingPhoto = true } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "photo.badge.plus").font(.system(size: 20))
                            Text("Photo").font(KemoType.font(.caption))
                        }.foregroundStyle(.secondary).frame(width: entry.photos.isEmpty ? 84 : 110, height: entry.photos.isEmpty ? 64 : 110)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }.buttonStyle(.plain).accessibilityLabel("Add photo").accessibilityIdentifier("journalAddPhoto")
                }
            }
        }.scrollClipDisabled()
    }
    private func tags(_ entry: JournalEntry) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(entry.tags, id: \.self) { value in
                    Button { docs.updateEntry(entryID) { $0.tags.removeAll { $0 == value } } } label: {
                        HStack(spacing: 3) { Text("#" + value); Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                            .font(KemoType.font(.caption, weight: .medium)).padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                    }.buttonStyle(.plain).accessibilityLabel("Remove tag " + value).accessibilityIdentifier("journalTag-" + value)
                }
                if entry.tags.count < JournalEntry.maxTags {
                    TextField("Add tag", text: $tag).textFieldStyle(.plain).font(KemoType.font(.caption)).frame(width: 90)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .onSubmit { addTag() }
                        .accessibilityIdentifier("journalTagField")
                }
            }
        }
    }
    private func addTag() {
        let value = tag; tag = ""
        guard JournalEntry.cleanTag(value) != nil else { return }
        docs.updateEntry(entryID) { $0.tags.append(value) }
    }
}

/// Five moods, one tap each (tap again to clear).
struct JournalMoodPicker: View {
    let mood: JournalMood?
    let choose: (JournalMood) -> Void
    var body: some View {
        HStack(spacing: 6) {
            ForEach(JournalMood.allCases) { option in
                Button { choose(option) } label: {
                    VStack(spacing: 3) {
                        Image(systemName: option.symbol).font(.system(size: 17))
                        Text(option.title).font(KemoType.font(.caption2))
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                    .foregroundStyle(mood == option ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .background(mood == option ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(Color.primary.opacity(0.04)), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }.buttonStyle(.plain)
                    .accessibilityLabel(option.title).accessibilityAddTraits(mood == option ? .isSelected : [])
                    .accessibilityIdentifier("mood-" + option.rawValue)
            }
        }
    }
}

/// A month with a dot under each day that has an entry.
struct JournalMonthView: View {
    @Binding var month: (year: Int, month: Int)
    let days: Set<String>
    let selected: String?
    let today: String
    let choose: (String) -> Void
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(JournalCalendar.monthTitle(year: month.year, month: month.month)).font(KemoType.font(.headline))
                    .accessibilityIdentifier("journalMonthTitle")
                Spacer()
                Button { step(-1) } label: { Image(systemName: "chevron.left").frame(width: 30, height: 30) }.accessibilityLabel("Previous month")
                Button { step(1) } label: { Image(systemName: "chevron.right").frame(width: 30, height: 30) }.accessibilityLabel("Next month")
            }.buttonStyle(.plain)
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(weekdaySymbols.indices, id: \.self) { index in
                    Text(weekdaySymbols[index]).font(KemoType.font(.caption2, weight: .medium)).foregroundStyle(.secondary)
                }
                ForEach(Array(JournalCalendar.monthGrid(year: month.year, month: month.month).enumerated()), id: \.offset) { _, key in
                    if let key { dayCell(key) } else { Color.clear.frame(height: 36) }
                }
            }
        }
    }
    private var weekdaySymbols: [String] {
        let calendar = Calendar.current
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }
    private func dayCell(_ key: String) -> some View {
        let day = JournalCalendar.components(key)?.day ?? 0
        let isSelected = key == selected, isToday = key == today, has = days.contains(key)
        return Button { choose(key) } label: {
            VStack(spacing: 2) {
                Text("\(day)").font(KemoType.font(.subheadline, weight: isToday ? .bold : .regular))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.background) : isToday ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .frame(width: 30, height: 26)
                    .background(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), in: Circle())
                Circle().fill(has ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear)).frame(width: 5, height: 5)
            }.frame(maxWidth: .infinity, minHeight: 36).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(JournalCalendar.title(for: key, relativeTo: today) + (has ? ", has entries" : ""))
            .accessibilityIdentifier("journalDay-" + key)
    }
    private func step(_ delta: Int) {
        var m = month.month + delta, y = month.year
        if m < 1 { m = 12; y -= 1 } else if m > 12 { m = 1; y += 1 }
        month = (y, m)
    }
}

/// Entries from this day in earlier years.
struct JournalOnThisDay: View {
    let groups: [(years: Int, entries: [JournalEntry])]
    let open: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("On this day", systemImage: "clock.arrow.circlepath").font(KemoType.font(.subheadline, weight: .semibold))
            ForEach(groups, id: \.years) { group in
                Button { if let day = group.entries.first?.day { open(day) } } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.years == 1 ? "A year ago" : "\(group.years) years ago").font(KemoType.font(.caption, weight: .semibold)).foregroundStyle(.tint)
                        Text(group.entries.map(\.summary).first { !$0.isEmpty } ?? "An entry").font(KemoType.font(.footnote)).lineLimit(2)
                            .foregroundStyle(.primary).multilineTextAlignment(.leading)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).accessibilityIdentifier("onThisDay-\(group.years)")
            }
        }
    }
}

/// A timeline row: mood, first words, a photo, and tags.
struct JournalEntryRow: View {
    let entry: JournalEntry
    let docs: DocsStore
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let mood = entry.mood { Image(systemName: mood.symbol).foregroundStyle(.tint).accessibilityLabel(mood.title) }
                    Text(entry.created.formatted(date: .omitted, time: .shortened)).font(KemoType.font(.caption)).foregroundStyle(.secondary)
                }
                Text(entry.summary.isEmpty ? "Empty entry" : entry.summary).font(KemoType.font(.subheadline)).lineLimit(2)
                    .foregroundStyle(entry.summary.isEmpty ? .secondary : .primary)
                if !entry.tags.isEmpty {
                    Text(entry.tags.map { "#" + $0 }.joined(separator: " ")).font(KemoType.font(.caption)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let photo = entry.photos.first {
                DocImageView(docs: docs, ref: photo, fill: true).frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }.padding(.vertical, 2)
    }
}

/// Shown instead of the Journal while it's locked.
struct JournalLockedView: View {
    @State private var lock = JournalLock.shared
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill").font(.system(size: 30)).foregroundStyle(.secondary)
            Text("Journal is locked").font(KemoType.font(.headline))
            Button("Unlock with \(lock.method)") { Task { await lock.unlock() } }
                .buttonStyle(.borderedProminent).accessibilityIdentifier("journalUnlock")
            if let error = lock.error { Text(error).font(KemoType.font(.caption)).foregroundStyle(.orange) }
        }.frame(maxWidth: .infinity).padding(.vertical, 60)
    }
}

import AppKit
import SwiftUI

/// A KemoSabe page on the Mac, laid out like Codex's: a title with its actions on one row,
/// then content in a centered column that widens to two columns when there's room.
struct DesktopPage<Actions: View, Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var actions: Actions
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.system(size: 26, weight: .semibold))
                        if let subtitle { Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 12)
                    actions
                }
                content
            }
            .frame(maxWidth: 980, alignment: .leading).padding(.horizontal, 36).padding(.top, 24).padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
    }
}

/// A rounded panel with an optional heading, the building block of these pages.
struct DesktopPanel<Content: View>: View {
    var title: String?
    var symbol: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Label(title, systemImage: symbol ?? "circle").labelStyle(.titleAndIcon)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            }
            content
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
    }
}

// MARK: Day

/// Day: your calendar beside what Kemo has ready for you, then what's done.
struct DesktopDayPage: View {
    @Environment(AppStore.self) private var store
    @Environment(RoutineStore.self) private var routines
    @Environment(DesktopNavigation.self) private var desktop
    @State private var reviewing: RoutineProposal?
    @State private var permissions = false
    @State private var clearingDone = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The day shown (its midnight): ‹ and › (⌘← ⌘→) flip it, Today (⌘T) returns, and the calendar jumps.
    @State private var day: Date
    @State private var direction = 1
    @State private var pickingDate = false
    @State private var calendar = DayCalendar()
    init(day: Date = Date()) { _day = State(initialValue: Calendar.current.startOfDay(for: day)) }
    private var isToday: Bool { DayRange.relation(of: day, now: Date(), calendar: .current) == .today }
    private var pending: [RoutineProposal] { routines.state.proposals.filter { [.needsReview, .approved, .executing, .uncertain].contains($0.status) }.reversed() }
    private var done: [RoutineProposal] { Array(routines.state.proposals.filter { ![.needsReview, .approved, .executing, .uncertain].contains($0.status) }.reversed().prefix(12)) }
    var body: some View {
        DesktopPage(title: day.formatted(.dateTime.weekday(.wide).month(.wide).day()),
                    subtitle: isToday ? "Your calendar and what \(CompanionIdentity.name) has ready for you." : DayRange.heading(day)) {
            dayControls
            Button { permissions = true } label: { Image(systemName: "gearshape") }.help("Routine permissions and learning")
            Button("Plan my day", systemImage: "sparkles") {
                store.selectModel(.onDevice); desktop.page = "Chat"
                if store.canChat { store.send("Help me plan my day. Ask what you need to know before creating proposals.") }
                else { store.error = store.availability }
            }.buttonStyle(.borderedProminent).accessibilityIdentifier("planMyDay")
        } content: {
            Group {
                if isToday { todayContent } else { otherDay }
            }
            .id(day)
            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: direction > 0 ? .trailing : .leading).combined(with: .opacity),
                                                              removal: .opacity))
        }
        .modifier(DayCalendarLoader(day: day, calendar: calendar))
        .task { await routines.refresh() }
        .onChange(of: store.proposalRevision) { Task { await routines.refresh() } }
        .confirmationDialog("Clear what's done?", isPresented: $clearingDone) {
            Button("Clear", role: .destructive) { Task { await routines.clearHistory() } }
        } message: { Text("Finished and dismissed items and their source excerpts are removed. Alarms that are still set stay, so you can cancel them.") }
        .sheet(isPresented: $permissions) {
            NavigationStack {
                PersonalRoutineSettings().formStyle(.grouped)
                    .environment(\.openConnections) { permissions = false; desktop.settingsPage = "Connections" }
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { permissions = false } } }
            }.frame(width: 650, height: 640)
        }
        .confirmationDialog("Approve this exact proposal?", isPresented: Binding(get: { reviewing != nil }, set: { if !$0 { reviewing = nil } }), titleVisibility: .visible) {
            if let proposal = reviewing { Button("Approve") {
                Task {
                    if [.memory, .draft].contains(proposal.kind) { await routines.review(proposal, store: store) }
                    else { await routines.executeNative(proposal, store: store) }
                }; reviewing = nil
            } }
        } message: { if let proposal = reviewing { Text(proposal.title + "\n\n" + proposal.body) } }
    }
    private func move(by days: Int) { go(to: DayRange.shift(day, by: days, calendar: .current)) }
    private func go(to target: Date) {
        let target = Calendar.current.startOfDay(for: target)
        guard target != day else { return }
        direction = target > day ? 1 : -1
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.34, dampingFraction: 0.88)) { day = target }
    }
    /// ‹ Today › and the calendar: Today shows only while you're on another day.
    private var dayControls: some View {
        HStack(spacing: 6) {
            if !isToday {
                Button { go(to: Date()) } label: {
                    Text("Today").font(.system(size: 12, weight: .semibold)).padding(.horizontal, 10).frame(height: 26)
                        .foregroundStyle(preferencesAccent).background(preferencesAccent.opacity(0.14), in: Capsule())
                }.buttonStyle(.plain).keyboardShortcut("t", modifiers: .command).help("Today (⌘T)").accessibilityIdentifier("dayTodayChip")
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
            HStack(spacing: 0) {
                Button { move(by: -1) } label: { Image(systemName: "chevron.left").frame(width: 26, height: 24) }
                    .keyboardShortcut(.leftArrow, modifiers: .command).help("Previous day (⌘←)").accessibilityLabel("Previous day").accessibilityIdentifier("dayPrevious")
                Button { pickingDate = true } label: { Image(systemName: "calendar").frame(width: 26, height: 24) }
                    .help("Choose a day").accessibilityLabel("Choose a day").accessibilityIdentifier("dayDateButton")
                    .popover(isPresented: $pickingDate, arrowEdge: .bottom) {
                        DatePicker("Day", selection: Binding(get: { day }, set: { go(to: $0); pickingDate = false }), displayedComponents: .date)
                            .datePickerStyle(.graphical).labelsHidden().padding(12).accessibilityIdentifier("dayCalendarPicker")
                    }
                Button { move(by: 1) } label: { Image(systemName: "chevron.right").frame(width: 26, height: 24) }
                    .keyboardShortcut(.rightArrow, modifiers: .command).help("Next day (⌘→)").accessibilityLabel("Next day").accessibilityIdentifier("dayNext")
            }.buttonStyle(.borderless)
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.34, dampingFraction: 0.88), value: isToday)
    }
    @Environment(DesktopPreferences.self) private var preferences
    @Environment(\.colorScheme) private var scheme
    private var preferencesAccent: Color { preferences.palette(scheme).accent }
    /// Another day: its calendar, reminders due, and Kemo's items for it (read-only history when past).
    private var otherDay: some View {
        VStack(alignment: .leading, spacing: 20) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    DayCalendarSection(day: day, calendar: calendar).frame(minWidth: 380)
                    planned.frame(minWidth: 380)
                }
                VStack(alignment: .leading, spacing: 20) { DayCalendarSection(day: day, calendar: calendar); planned }
            }
        }
    }
    @ViewBuilder private var planned: some View {
        if DayRange.proposals(routines.state.proposals, on: day, calendar: .current).isEmpty {
            DesktopPanel(title: "\(CompanionIdentity.name)'s plan", symbol: "sparkles") {
                Text(DayRange.relation(of: day, now: Date(), calendar: .current) == .past ? "Nothing was planned." : "Nothing planned yet.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } else {
            DayPlanList(day: day, proposals: routines.state.proposals)
        }
    }
    private var todayContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    DayCalendarSection(day: day, calendar: calendar).frame(minWidth: 380)
                    needsYou.frame(minWidth: 380)
                }
                VStack(alignment: .leading, spacing: 20) { DayCalendarSection(day: day, calendar: calendar); needsYou }
            }
            if !done.isEmpty {
                DesktopPanel(title: "Done", symbol: "checkmark.circle") {
                    if done.contains(where: { RoutineLedger.clearable($0, now: Date()) }) {
                        Button("Clear") { clearingDone = true }.buttonStyle(.borderless).font(.caption)
                            .frame(maxWidth: .infinity, alignment: .trailing).padding(.top, -30).accessibilityIdentifier("clearRecentActivity")
                    }
                    ForEach(done) { proposal in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(proposal.title).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(proposal.receipt ?? proposal.status.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if proposal.id != done.last?.id { Divider() }
                    }
                }
            }
            if let error = routines.error { Text(error).font(.caption).foregroundStyle(.orange) }
        }
    }
    private var needsYou: some View {
        DesktopPanel(title: "Needs you", symbol: "tray") {
            if pending.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nothing waiting").font(.system(size: 15, weight: .medium))
                    Text("Plans, drafts, and reminders \(CompanionIdentity.name) prepares show up here for you to approve.").font(.callout).foregroundStyle(.secondary)
                }
            }
            ForEach(pending) { proposal in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(proposal.title).font(.system(size: 14, weight: .semibold))
                        Spacer(minLength: 8)
                        Text(proposal.status.label).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(proposal.body).font(.callout).lineLimit(6).textSelection(.enabled)
                    HStack(spacing: 10) {
                        if proposal.status == .needsReview {
                            if proposal.kind != .alarm { Button("Approve") { reviewing = proposal }.buttonStyle(.borderedProminent) }
                            else { Text("Alarms are set from iPhone.").font(.caption).foregroundStyle(.secondary) }
                            Button("Dismiss") { Task { await routines.rejectNative(proposal, store: store) } }
                        } else if proposal.status == .uncertain {
                            Button("Dismiss") { Task { await routines.dismissUncertain(proposal) } }
                        }
                    }.disabled(routines.busy)
                }
                if proposal.id != pending.last?.id { Divider() }
            }
        }
    }
}

// MARK: Library

/// Library: what Kemo remembers, what it drafted for you, and your docs and journal, with one search.
struct DesktopLibraryPage: View {
    @Environment(AppStore.self) private var store
    @Environment(RoutineStore.self) private var routines
    @State private var section = "Memories"
    @State private var query = ""
    @State private var editing: MemoryNote?
    @State private var deleting: MemoryNote?
    private let columns = [GridItem(.adaptive(minimum: 300), spacing: 14, alignment: .top)]
    static let sections = ["Memories", "Drafts", "Docs", "Journal", "Requests"]
    var body: some View {
        // Docs and Journal are two panes: the tree or timeline, then the editor.
        if section == "Docs" || section == "Journal" { DesktopDocsLibrary(section: $section) } else { memoriesAndDrafts }
    }
    private var memoriesAndDrafts: some View {
        DesktopPage(title: "Library", subtitle: section == "Requests" ? "What agents asked \(CompanionIdentity.name), and exactly what was sent." : "What \(CompanionIdentity.name) remembers, and what it drafted for you.") {
            if section == "Memories" {
                Button("Add memory", systemImage: "plus") { editing = MemoryNote(text: "") }.buttonStyle(.borderedProminent).accessibilityIdentifier("addMemory")
            }
        } content: {
            HStack(spacing: 12) {
                QuietSegmented(options: Self.sections, selection: $section).accessibilityIdentifier("librarySections")
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("Search \(section.lowercased())", text: $query).textFieldStyle(.plain).frame(width: 200).accessibilityIdentifier("librarySearch")
                }.padding(.horizontal, 10).padding(.vertical, 6).background(Color.primary.opacity(0.06), in: Capsule())
            }
            if section == "Memories" { memories } else if section == "Requests" { AgentRequestTranscript(inbox: store.agentRequests, search: query) } else { drafts }
        }
        .task { await routines.refresh() }
        .onChange(of: section) { query = "" }
        .sheet(item: $editing) { DesktopMemoryEditor(note: $0) }
        .confirmationDialog("Delete this memory?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let deleting { store.deleteMemory(deleting.id) }; deleting = nil }
        } message: { Text("Its dependent learning will be invalidated. Existing chat replies may still contain information from it.") }
    }
    @ViewBuilder private var memories: some View {
        let notes = store.state.memories.filter { query.isEmpty || ($0.text + $0.scope).localizedCaseInsensitiveContains(query) }
        if notes.isEmpty {
            empty(query.isEmpty ? "No memories yet" : "No matching memories", symbol: "square.stack",
                  detail: query.isEmpty ? "Add a preference or a useful detail, or ask \(CompanionIdentity.name) to remember something. You can change or forget it anytime." : "Try another word.")
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(notes) { note in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Text(note.scope).font(.caption.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 3).background(Color.primary.opacity(0.07), in: Capsule())
                            Text(store.memoryLevel(note).title).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Menu {
                                Button("Edit") { editing = note }
                                Button("Delete", role: .destructive) { deleting = note }
                            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        }
                        Text(note.text).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(16).frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .onTapGesture(count: 2) { editing = note }
                }
            }
        }
    }
    @ViewBuilder private var drafts: some View {
        let proposals = routines.state.proposals.reversed().filter { $0.origin != nil && [.draft, .memory].contains($0.kind) && (query.isEmpty || ($0.title + $0.body).localizedCaseInsensitiveContains(query)) }
        let items = (store.state.workItems ?? []).filter { query.isEmpty || ($0.title + $0.draft).localizedCaseInsensitiveContains(query) }
        if proposals.isEmpty && items.isEmpty {
            empty(query.isEmpty ? "No drafts yet" : "No matching drafts", symbol: "doc.text",
                  detail: query.isEmpty ? "Ask \(CompanionIdentity.name) to draft something. It lands here for you to review; nothing is sent automatically." : "Try another word.")
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(proposals) { proposal in draftCard(title: proposal.title, text: proposal.body, status: proposal.receipt ?? proposal.status.label) {
                    if proposal.status == .needsReview {
                        Button(proposal.kind == .memory ? "Save memory" : "Mark reviewed") { Task { await routines.review(proposal, store: store) } }
                    }
                    Button("Copy") { copy(proposal.body) }
                    if ![.approved, .executing, .uncertain].contains(proposal.status) { Button("Delete", role: .destructive) { Task { await routines.remove(proposal) } } }
                } }
                ForEach(items) { item in draftCard(title: item.title, text: item.draft, status: item.status) {
                    Button("Copy") { copy(item.draft) }
                    Button("Delete", role: .destructive) { store.deleteWork(item.id) }
                } }
            }
        }
    }
    private func draftCard<Actions: View>(title: String, text: String, status: String, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 8)
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(text).font(.callout).lineLimit(10).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) { actions() }.buttonStyle(.bordered).controlSize(.small)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    private func empty(_ title: String, symbol: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
        }.frame(maxWidth: .infinity).padding(.vertical, 60)
    }
    private func copy(_ text: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
}

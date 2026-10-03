import SwiftUI
import Observation
import BackgroundTasks
import AlarmKit
import AppIntents

struct OpenKemoMorning: LiveActivityIntent {
    static var title: LocalizedStringResource = "Open KemoSabe"
    static var openAppWhenRun = true
    func perform() async throws -> some IntentResult { .result() }
}
struct KemoAlarmMetadata: AlarmMetadata {}

enum RoutineBackground {
    static let identifier = "com.zlichtman.kemosabe.routine-refresh"
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            let work = Task {
                do {
                    try Task.checkCancellation()
                    try await RoutineLedger.shared.refreshContext(now: Date())
                    try Task.checkCancellation()
                    let state = try await RoutineLedger.shared.snapshot()
                    if state.context?.learning == true && state.context?.observations.isEmpty == false { schedule() }
                    task.setTaskCompleted(success: true)
                } catch { task.setTaskCompleted(success: false) }
            }
            task.expirationHandler = { work.cancel() }
        }
    }
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date().addingTimeInterval(3600)
        // This is an earliest time, not an alarm or a guaranteed launch time.
        try? BGTaskScheduler.shared.submit(request)
    }
    static func cancel() { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }
}


struct RoutineView: View {
    #if os(iOS)
    @Environment(\.mobilePalette) private var palette
    #endif
    var embedded = false
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    @Environment(RoutineStore.self) private var routines
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var forgettingContext = false
    @State private var showingHistory = false
    @State private var clearingHistory = false
    /// The day shown (its midnight). Swipe left for the next day, right for the one before.
    @State private var day = Calendar.current.startOfDay(for: Date())
    /// +1 moving to a later day, -1 to an earlier one: which way the page slides.
    @State private var direction = 1
    @State private var dragging: CGFloat = 0
    @State private var pickingDate = false
    @State private var calendar = DayCalendar()
    @State private var flips = 0
    private var relation: DayRange.Relation { DayRange.relation(of: day, now: Date(), calendar: .current) }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    Group {
                        if relation == .today { today } else { otherDay }
                    }
                    .id(day)
                    .transition(pageTransition)
                    .offset(x: reduceMotion ? 0 : dragging)
                    if let error = routines.error { Text(error).font(.caption).foregroundStyle(.orange); Button("Refresh") { Task { await routines.refresh() } } }
                }.padding(24).frame(maxWidth: 700).frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }.disabled(routines.busy)
                .simultaneousGesture(swipe)
                .accessibilityIdentifier("dayPage")
                .accessibilityScrollAction { edge in
                    // VoiceOver's three-finger swipe flips days too.
                    if edge == .leading { move(by: -1) } else if edge == .trailing { move(by: 1) }
                }
                #if os(iOS)
                .background(palette.background)
                #endif
                .toolbar { if !embedded { ToolbarItem(placement: .confirmationAction) { Button(role: .close) { dismiss() } } } }
        }.task { await routines.refresh() }
            .modifier(DayCalendarLoader(day: day, calendar: calendar))
            .sensoryFeedback(.selection, trigger: flips)
            .onChange(of: store.proposalRevision) { Task { await routines.refresh() } }
            .confirmationDialog("Clear recent activity?", isPresented: $clearingHistory, titleVisibility: .visible) {
                Button("Clear", role: .destructive) { Task { await routines.clearHistory() } }
            } message: { Text("Finished and dismissed items and their source excerpts are removed. Alarms that are still set stay, so you can cancel them.") }
            .confirmationDialog("Forget recent context? Saved memories and proposals stay until you delete them separately.", isPresented: $forgettingContext, titleVisibility: .visible) {
                Button("Forget recent context", role: .destructive) { Task { await routines.forgetContext(store: store) } }
            }
    }
    /// Slides the way you swiped; with Reduce Motion, a crossfade.
    private var pageTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: direction > 0 ? .trailing : .leading).combined(with: .opacity),
                                               removal: .move(edge: direction > 0 ? .leading : .trailing).combined(with: .opacity))
    }
    private func move(by days: Int) { go(to: DayRange.shift(day, by: days, calendar: .current)) }
    private func go(to target: Date) {
        let target = Calendar.current.startOfDay(for: target)
        guard target != day else { return }
        direction = target > day ? 1 : -1
        flips += 1
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.38, dampingFraction: 0.86)) { day = target; dragging = 0 }
    }
    /// A horizontal swipe flips the day; the page follows your finger until you let go.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) * 1.2 else { return }
                dragging = value.translation.width * 0.6
            }
            .onEnded { value in
                let dx = value.translation.width, predicted = value.predictedEndTranslation.width
                guard abs(dx) > abs(value.translation.height) * 1.2 else { withAnimation(.snappy) { dragging = 0 }; return }
                if dx < -70 || predicted < -180 { move(by: 1) }
                else if dx > 70 || predicted > 180 { move(by: -1) }
                else { withAnimation(.snappy) { dragging = 0 } }
            }
    }
    private var header: some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 7) {
                Button { pickingDate = true } label: {
                    HStack(spacing: 4) {
                        Text(day.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    }.font(KemoType.font(.caption)).foregroundStyle(.secondary).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Choose a day, " + day.formatted(date: .complete, time: .omitted)).accessibilityIdentifier("dayDateButton")
                    .popover(isPresented: $pickingDate) {
                        DatePicker("Day", selection: Binding(get: { day }, set: { go(to: $0); pickingDate = false }), displayedComponents: .date)
                            .datePickerStyle(.graphical).labelsHidden().frame(width: 320).padding(12)
                            .tint(palette.accent)
                            .presentationCompactAdaptation(.popover)
                            .accessibilityIdentifier("dayCalendarPicker")
                    }
                Text(DayRange.heading(day)).font(KemoType.font(.title, weight: .medium))
                    .contentTransition(.numericText(countsDown: direction < 0))
                    .accessibilityIdentifier("dayTitle")
            }
            .id(day).transition(pageTransition)
            Spacer(minLength: 0)
            if relation != .today {
                Button { go(to: Date()) } label: {
                    Label("Today", systemImage: direction > 0 ? "arrow.uturn.backward" : "arrow.uturn.forward")
                        .font(KemoType.font(.subheadline, weight: .semibold)).labelStyle(.titleAndIcon)
                        .padding(.horizontal, 12).frame(height: 32)
                        .foregroundStyle(palette.accent).background(palette.accent.opacity(0.14), in: Capsule())
                }.buttonStyle(PressableButtonStyle()).accessibilityIdentifier("dayTodayChip")
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.38, dampingFraction: 0.86), value: relation)
    }
    /// Another day: its calendar, reminders due, and Kemo's items for it (read-only history when past).
    private var otherDay: some View {
        VStack(alignment: .leading, spacing: 24) {
            DayCalendarSection(day: day, calendar: calendar)
            DayPlanList(day: day, proposals: routines.state.proposals)
            if relation == .future, DayRange.proposals(routines.state.proposals, on: day, calendar: .current).isEmpty {
                Text("Nothing planned yet. Ask KemoSabe to plan this day.").font(KemoType.font(.callout)).foregroundStyle(.secondary)
            }
        }
    }
    /// Today: the calendar and reminders, what needs you, then recent activity.
    private var today: some View {
        VStack(alignment: .leading, spacing: 24) {
                    DayCalendarSection(day: day, calendar: calendar)
                    DayPlanList(day: day, proposals: routines.state.proposals.filter { ![.needsReview, .approved, .executing, .uncertain].contains($0.status) })
                    let pending = routines.state.proposals.filter { [.needsReview, .approved, .executing, .uncertain].contains($0.status) }
                    if pending.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: "sun.horizon").font(.system(size: 28)).foregroundStyle(.secondary)
                            Text("Nothing needs your attention").font(KemoType.font(.headline))
                            Text("Plans and reminders KemoSabe prepares will appear here. Talk to KemoSabe to plan your day or adjust a routine.").font(KemoType.font(.callout)).foregroundStyle(.secondary)
                        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
                    } else {
                        Text("Needs your attention").font(KemoType.font(.headline))
                        ForEach(pending.reversed()) { proposal in ProposalCard(proposal: proposal).padding(18).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 16)) }
                    }
                    let history = routines.state.proposals.filter { ![.needsReview, .approved, .executing, .uncertain].contains($0.status) }
                    if !history.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Button { withAnimation(.snappy) { showingHistory.toggle() } } label: {
                                    HStack(spacing: 6) {
                                        Text("Recent activity").font(KemoType.font(.headline))
                                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).rotationEffect(.degrees(showingHistory ? 90 : 0))
                                    }
                                }.buttonStyle(.plain).accessibilityIdentifier("recentActivity")
                                Spacer()
                                if history.contains(where: { RoutineLedger.clearable($0, now: Date()) }) {
                                    Button("Clear") { clearingHistory = true }.font(KemoType.font(.subheadline)).accessibilityIdentifier("clearRecentActivity")
                                }
                            }
                            if showingHistory {
                                ForEach(history.reversed()) { ProposalCard(proposal: $0).padding(.vertical, 10) }
                            }
                        }
                    }
        }
    }
}

struct ProposalCard: View {
    let proposal: RoutineProposal
    @Environment(AppStore.self) private var store
    @Environment(RoutineStore.self) private var routines
    @State private var deleting = false
    private var current: Bool {
        let now = Date()
        return proposal.expiresAt > now && proposal.origin?.isCurrent(in: store.state.memories) != false &&
            (proposal.origin?.connectorSources?.allSatisfy { $0.isValid(now: now) } ?? true)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(proposal.title).font(KemoType.font(.headline))
            Text(proposal.body).font(KemoType.font(.callout)).textSelection(.enabled)
            if let scope = proposal.memoryScope { Text("Suggested \(scope.lowercased()) memory").font(KemoType.font(.caption)).foregroundStyle(.secondary) }
            Text(proposal.receipt ?? proposal.status.label).font(KemoType.font(.caption)).foregroundStyle(.secondary)
            if let origin = proposal.origin {
                DisclosureGroup("Why this is here") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("You asked: \(origin.request)")
                        Text("\(origin.model) · \(proposal.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        Text(origin.sources.isEmpty ? "No saved notes were supplied." : "Notes supplied as context, not proof of correctness:")
                        ForEach(origin.sources) { source in Text("\(source.scope): \(source.excerpt)") }
                        if let connectors = origin.connectorSources, !connectors.isEmpty {
                            Text("Connector reads must still match before approval:")
                            ForEach(Array(connectors.enumerated()), id: \.offset) { _, source in
                                Text("\(source.connector.title) · \(source.readAt.formatted(date: .abbreviated, time: .shortened))")
                            }
                        }
                        Text("Review facts before using this. Source excerpts are kept with the proposal; deleting a note does not delete this copy.")
                    }.font(KemoType.font(.caption)).foregroundStyle(.secondary).padding(.top, 8)
                }.font(KemoType.font(.caption))
            }
            if proposal.status == .needsReview {
                if !current { Text("This proposal expired or its notes changed. Ask KemoSabe to prepare it again.").font(KemoType.font(.caption)).foregroundStyle(.orange) }
                HStack(spacing: 24) {
                    if proposal.routineWrite != nil {
                        Button("Approve change") { Task { await routines.executeNative(proposal, store: store) } }.disabled(!current)
                    } else if proposal.kind == .alarm {
                        Button("Approve alarm") { Task { await routines.approveAlarm(proposal, store: store) } }.disabled(!current)
                    } else if [.draft, .memory].contains(proposal.kind) {
                        Button(proposal.kind == .memory ? "Save memory" : "Mark reviewed") { Task { await routines.review(proposal, store: store) } }
                            .disabled(!current).accessibilityIdentifier("approveProposal-" + proposal.id.uuidString)
                    }
                    Button(proposal.kind == .morningBrief ? "Dismiss" : "Reject", role: .destructive) { Task { if proposal.routineWrite != nil { await routines.rejectNative(proposal, store: store) } else { await routines.reject(proposal) } } }
                }
            }
            if proposal.routineWrite != nil, [.executing,.uncertain].contains(proposal.status) {
                Button("Check result") { Task { await routines.executeNative(proposal, store: store) } }
            }
            if proposal.status == .uncertain {
                Button("Dismiss") { Task { await routines.dismissUncertain(proposal) } }.accessibilityIdentifier("dismissUncertain-" + proposal.id.uuidString)
            }
            if proposal.kind == .alarm, [.completed,.uncertain].contains(proposal.status), (proposal.scheduledAt ?? .distantPast) > Date() {
                Button("Cancel alarm", role: .destructive) { Task { await routines.cancelAlarm(proposal) } }
            }
            if [.draft,.memory].contains(proposal.kind), ![.approved,.executing,.uncertain].contains(proposal.status) {
                Button("Delete proposal", role: .destructive) { deleting = true }.font(KemoType.font(.caption))
            }
        }.buttonStyle(.borderless).disabled(routines.busy)
            .confirmationDialog("Delete this proposal and its source excerpts?", isPresented: $deleting, titleVisibility: .visible) {
                Button("Delete proposal", role: .destructive) { Task { await routines.remove(proposal) } }
            }
    }
}

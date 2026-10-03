import SwiftUI

// Models → Training (the owner, September 30, 2026: "Any models you must train, have a Training tab").
// Everything the person trains themselves, in one place and the same on iPhone and Mac: Laya's personal
// layer (from the decisions marked in System One → Details), their own voice, and the day-plan
// preferences KemoSabe collects. Each shows one status and one primary action. All of it stays on
// this device: marks, layers, recordings, and examples are never synced or uploaded.

/// Where one trainable model stands, in the page's words.
enum TrainingStatus: Equatable {
    case notStarted
    /// Examples so far, and how many it needs (nil when there's no fixed number).
    case collecting(Int, of: Int?)
    case ready
    case trained
    /// Trained once, but it didn't beat the base: more examples may help.
    case needsMore
    case off

    var title: String {
        switch self {
        case .notStarted: "Not started"
        case .collecting(let count, let needed): needed.map { "Collecting \(count) of \($0)" } ?? "Collecting \(count)"
        case .ready: "Ready to train"
        case .trained: "Trained"
        case .needsMore: "Needs more examples"
        case .off: "Off"
        }
    }
    var isDone: Bool { self == .trained }
}

enum TrainingCatalog {
    /// Laya's personal layer: trained when a layer is on; otherwise how far the best-marked decision is
    /// from the 30 it needs, ready once one has them (and has new marks since it was last trained).
    static func laya(counts: [DecisionKind: Int], state: SystemOnePersonalState) -> TrainingStatus {
        if !state.activeKinds.isEmpty { return .trained }
        let kinds = DecisionKind.allCases.filter(\.inUse)
        let needed = PersonalTraining.minimumExamples
        let ready = kinds.contains { kind in
            let count = counts[kind] ?? 0
            return count >= needed && (state.report(kind).map { $0.examples < count } ?? true)
        }
        if ready { return .ready }
        if !state.reports.isEmpty { return .needsMore }
        let best = kinds.map { counts[$0] ?? 0 }.max() ?? 0
        return best == 0 ? .notStarted : .collecting(best, of: needed)
    }
    /// Your voice: made or not.
    static func voice(enrolled: Bool) -> TrainingStatus { enrolled ? .trained : .notStarted }
    /// Day plans: what KemoSabe learns from the plans you accept or change. It isn't used to rank
    /// plans until it beats the shared ranking (`PersonalizationValidation.learnedRanking`).
    static func dayPlans(learning: Bool, examples: Int) -> TrainingStatus {
        guard learning else { return .off }
        return examples == 0 ? .notStarted : .collecting(examples, of: nil)
    }
    static let layaLine = "A small personal layer over Laya's answers, from the decisions you mark in System One → Details. It turns on only if it gets at least two more of your newest marks right than Laya alone."
    static let voiceLine = "A copy of your voice for replies, made on this device from four short passages and your spoken consent."
    static let dayPlansLine = "When you like to do things, from the plans you accept or change. It isn't used to rank plans yet."
    static let privacy = "Everything here stays on this device. Marks, layers, recordings, and examples are never synced or uploaded."
}

struct TrainingView: View {
    /// Opens Personalization (the Mac's Settings page); on iPhone it's pushed here instead.
    var openPersonalization: (() -> Void)? = nil
    @Environment(AppStore.self) private var store
    @State private var voices = SpeechVoices.shared
    @State private var examples: [SystemOneExample] = []
    @State private var personal = SystemOnePersonalState()
    @State private var preferences = PreferenceState()
    @State private var training = false
    @State private var problem: String?
    @State private var resetting = false
    @State private var deletingExamples = false
    @State private var enrolling = false
    @State private var deletingVoice = false

    var body: some View {
        Form {
            layaSection
            voiceSection
            dayPlansSection
            Section { Text(TrainingCatalog.privacy).font(KemoType.font(.footnote)).foregroundStyle(.secondary) }.modelsRow()
        }
        .modelsForm()
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: SystemOneExamples.didChange)) { _ in Task { await reload() } }
        .onReceive(NotificationCenter.default.publisher(for: SystemOnePersonalStore.didChange)) { _ in Task { await reload() } }
        .sheet(isPresented: $enrolling, onDismiss: { voices.reload() }) { OwnVoiceEnrollmentView(voices: voices) }
    }

    // MARK: Laya

    private var counts: [DecisionKind: Int] { PersonalTraining.counts(examples) }
    private var layaStatus: TrainingStatus { TrainingCatalog.laya(counts: counts, state: personal) }
    private var canTrain: Bool { DecisionKind.allCases.contains { $0.inUse && (counts[$0] ?? 0) >= PersonalTraining.minimumExamples } }
    private var layaSection: some View {
        Section {
            header("Laya", status: layaStatus, line: TrainingCatalog.layaLine, id: "training-laya") {
                Button(training ? "Training…" : "Train Laya") { train() }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).font(KemoType.font(.caption, weight: .semibold))
                    .disabled(!canTrain || training).accessibilityIdentifier("trainLaya")
            }
            ForEach(DecisionKind.allCases.filter(\.inUse)) { kind in decisionRow(kind) }
            if !canTrain {
                Text("Mark at least \(PersonalTraining.minimumExamples) decisions of one kind in System One → Details to train.")
                    .font(KemoType.font(.caption)).foregroundStyle(.secondary)
            }
            if let problem { Text(problem).font(KemoType.font(.caption)).foregroundStyle(.orange) }
            if !personal.reports.isEmpty || !examples.isEmpty {
                HStack(spacing: 16) {
                    if !personal.reports.isEmpty {
                        Button("Reset training") { resetting = true }
                            .buttonStyle(.borderless).font(KemoType.font(.footnote)).accessibilityIdentifier("resetPersonalTraining")
                    }
                    if !examples.isEmpty {
                        Button("Delete examples", role: .destructive) { deletingExamples = true }
                            .buttonStyle(.borderless).font(KemoType.font(.footnote)).accessibilityIdentifier("deleteSystemOneExamples")
                    }
                    Spacer()
                }
                .confirmationDialog("Reset personal training?", isPresented: $resetting, titleVisibility: .visible) {
                    Button("Reset", role: .destructive) { SystemOnePersonalStore().reset() }.accessibilityIdentifier("confirmResetPersonalTraining")
                } message: { Text("Laya goes back to its base answers everywhere. Your marks stay, so you can train again.") }
                .confirmationDialog("Delete your \(examples.count) marked decisions?", isPresented: $deletingExamples, titleVisibility: .visible) {
                    Button("Delete examples", role: .destructive) { deleteExamples() }.accessibilityIdentifier("confirmDeleteSystemOneExamples")
                } message: { Text("Your personal layer, learned from them, is deleted too. Laya's base stays.") }
            }
        }.modelsRow()
    }
    private func decisionRow(_ kind: DecisionKind) -> some View {
        let count = counts[kind] ?? 0, report = personal.report(kind), on = personal.heads[kind.rawValue] != nil
        let status = on ? "Your layer on" : report != nil ? "Laya's base" : "\(count) of \(PersonalTraining.minimumExamples) marked"
        let detail = report.map { "\(count) marked. " + $0.summary } ?? (count >= PersonalTraining.minimumExamples
            ? "\(count) marked. Ready to train." : "\(max(0, PersonalTraining.minimumExamples - count)) more to go.")
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(kind.title).font(.subheadline.weight(.medium))
                Spacer()
                Text(status).font(.caption).foregroundStyle(on ? AnyShapeStyle(Color.green) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                    .accessibilityIdentifier("personalStatus-" + kind.rawValue)
            }
            Text(detail).font(.footnote).foregroundStyle(.secondary)
        }.padding(.leading, 4).padding(.vertical, 1)
    }
    private func train() {
        training = true; problem = nil
        let examples = examples, store = SystemOnePersonalStore()
        Task {
            let state = await Task.detached(priority: .userInitiated) { PersonalTraining.trainAll(examples) }.value
            do { try store.save(state) } catch { problem = "The personal layer couldn't be saved on this device." }
            training = false
            await reload()
        }
    }
    private func deleteExamples() {
        Task {
            do { try await SystemOneExamples.current.deleteAll(); SystemOnePersonalStore().reset(); problem = nil }
            catch { problem = "The examples couldn't be deleted. Try again." }
            await reload()
        }
    }

    // MARK: Your voice

    private var voiceSection: some View {
        let enrolled = voices.own.isEnrolled
        return Section {
            header(SpeechEngineKind.ownVoice.title, status: TrainingCatalog.voice(enrolled: enrolled), line: TrainingCatalog.voiceLine, id: "training-voice") {
                Button(enrolled ? "Record again" : "Set up") { enrolling = true }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).font(KemoType.font(.caption, weight: .semibold))
                    .disabled(!OwnVoiceEnrollment.canSetUp).accessibilityIdentifier("setUpOwnVoice")
            }
            if !OwnVoiceEnrollment.canSetUp {
                Text("Not available on this device").font(KemoType.font(.caption)).foregroundStyle(.secondary)
            } else if let record = voices.own.record, enrolled {
                HStack {
                    Text("Made \(record.createdAt.formatted(date: .abbreviated, time: .omitted)) · \(record.takeCount == 1 ? "1 take" : "\(record.takeCount) takes") · \(Int(record.sampleSeconds.rounded())) s")
                        .font(KemoType.font(.caption)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Delete", role: .destructive) { deletingVoice = true }
                        .buttonStyle(.borderless).font(KemoType.font(.footnote)).accessibilityIdentifier("deleteOwnVoice")
                }
                .confirmationDialog("Delete your voice?", isPresented: $deletingVoice, titleVisibility: .visible) {
                    Button("Delete your voice", role: .destructive) { Task { await voices.own.delete(); voices.reload() } }
                        .accessibilityIdentifier("confirmDeleteOwnVoice")
                } message: { Text("Removes your recordings and consent record from this device. Replies go back to \(CompanionIdentity.name)'s other voice.") }
            }
        }.modelsRow()
    }

    // MARK: Day plans

    private var dayPlansSection: some View {
        Section {
            header("Day plans", status: TrainingCatalog.dayPlans(learning: preferences.learning, examples: preferences.examples.count),
                   line: TrainingCatalog.dayPlansLine, id: "training-dayPlans") {
                #if os(iOS)
                if openPersonalization == nil {
                    NavigationLink("Manage") { PersonalRoutineSettings() }.fixedSize().accessibilityIdentifier("trainingPersonalization")
                } else {
                    Button("Manage") { openPersonalization?() }.buttonStyle(.bordered).buttonBorderShape(.capsule).accessibilityIdentifier("trainingPersonalization")
                }
                #else
                if let openPersonalization {
                    Button("Manage") { openPersonalization() }.buttonStyle(.bordered).buttonBorderShape(.capsule).accessibilityIdentifier("trainingPersonalization")
                }
                #endif
            }
        }.modelsRow()
    }

    // MARK: Rows

    private func header(_ title: String, status: TrainingStatus, line: String, id: String, @ViewBuilder action: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(KemoType.font(.headline))
                    Text(status.title).font(.caption.weight(.semibold))
                        .foregroundStyle(status.isDone ? AnyShapeStyle(Color.green) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                        .accessibilityIdentifier(id)
                }
                Spacer(minLength: 8)
                action()
            }
            Text(line).font(KemoType.font(.footnote)).foregroundStyle(.secondary)
        }.padding(.vertical, 4)
    }
    private func reload() async {
        examples = await SystemOneExamples.current.all()
        personal = SystemOnePersonalStore().state()
        preferences = (try? await store.dailyAssistant.preferences.snapshot()) ?? PreferenceState()
        voices.reload()
    }
}

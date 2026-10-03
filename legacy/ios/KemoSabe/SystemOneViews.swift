import SwiftUI
import Combine

/// Models → System One, the same on iPhone and Mac and themed like the rest of Settings: one status
/// card (on, or off with the one action that turns it on), Laya, Jev, and OpenAI Decisions as compact
/// rows (a switch, a status, one action each), and Details (each decision's threshold, and the recent
/// decisions you can mark Right or Wrong) behind one disclosure. Training Laya on those marks is in
/// Models → Training. Rows come from `SystemOneCatalog`; statuses are live.
struct SystemOneView: View {
    @State private var laya = LayaModel.shared
    @State private var settings = SystemOneSettings.shared
    @State private var records: [SystemOneRecord] = []
    @State private var examples: [SystemOneExample] = []
    @State private var personal = SystemOnePersonalState()
    @State private var jevKey = ""
    @State private var addingJev = false
    @State private var confirmingJev = false
    @State private var deletingLaya = false
    @State private var removingJev = false
    @State private var jevProblem: String?
    @State private var markProblem: String?
    @State private var showingDetails = false

    var body: some View {
        Form {
            Section { statusCard }.modelsRow()
            Section {
                layaRow
                jevRow
                openAIRow
            } header: { Text("Decision models") } footer: { Text(SystemOneCatalog.routing) }
            .modelsRow()
            Section {
                Button { withAnimation(.snappy) { showingDetails.toggle() } } label: {
                    HStack {
                        Text("Details").foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(showingDetails ? 90 : 0))
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("systemOneDetails")
                    .accessibilityValue(showingDetails ? "Shown" : "Hidden")
            } footer: { if !showingDetails { Text("Each decision's threshold, and the recent decisions to mark for Training.") } }
            .modelsRow()
            if showingDetails { details }
        }
        .modelsForm()
        .task { laya.refresh(); settings.refresh(); await reload() }
        .onChange(of: laya.store.state) { _, _ in laya.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: SystemOneJournal.didRecord)) { _ in Task { await reload() } }
        .onReceive(NotificationCenter.default.publisher(for: SystemOneExamples.didChange)) { _ in Task { await reload() } }
        .onReceive(NotificationCenter.default.publisher(for: SystemOnePersonalStore.didChange)) { _ in Task { await reload() } }
        .onReceive(NotificationCenter.default.publisher(for: AccountSettingsAdapter.didApply)) { _ in settings.refresh() }
    }

    // MARK: Status

    private var layaStage: SystemOneStatus.Laya {
        switch laya.state {
        case .ready: .ready
        case .notDownloaded: .notDownloaded
        case .waitingForWiFi, .downloading, .verifying: .downloading
        case .preparing: .preparing
        case .failed: .failed
        }
    }
    private var status: SystemOneStatus {
        SystemOneStatus.card(laya: layaStage, layaOn: settings.layaEnabled, jevActive: settings.jevActive,
                             personalKinds: settings.layaEnabled && laya.state == .ready ? personal.activeKinds : [])
    }
    private var statusCard: some View {
        let status = status
        return HStack(alignment: .center, spacing: 14) {
            Image(systemName: status.on ? "bolt.circle.fill" : "bolt.slash.circle")
                .font(.system(size: 30)).foregroundStyle(status.on ? AnyShapeStyle(Color.green) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(status.title).font(KemoType.font(.headline))
                Text(status.detail).font(KemoType.font(.footnote)).foregroundStyle(.secondary)
            }.accessibilityElement(children: .combine).accessibilityIdentifier("systemOneSummary")
            Spacer(minLength: 8)
            if let action = status.action {
                Button(action == .downloadLaya ? (laya.store.isInstalled ? "Try again" : "Download \(laya.sizeLabel)") : action.title) {
                    if action == .downloadLaya { laya.download() } else { settings.layaEnabled = true }
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).font(KemoType.font(.caption, weight: .semibold))
                .fixedSize().accessibilityIdentifier("systemOneAction")
            }
        }.padding(.vertical, 6)
    }

    // MARK: Providers

    private var layaStatus: String {
        switch laya.state {
        case .ready: settings.layaEnabled ? "Active" : "Off"
        case .notDownloaded: "Download to use"
        case .waitingForWiFi, .downloading, .verifying: "Downloading"
        case .preparing: "Preparing"
        case .failed: "Not available"
        }
    }
    @ViewBuilder private var layaRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                title("Laya", status: layaStatus, line: laya.state == .ready
                      ? "On this device · " + (personal.activeKinds.isEmpty ? "base" : "base + your layer")
                      : "On this device · \(laya.sizeLabel), once")
                Spacer(minLength: 8)
                switch laya.state {
                case .ready:
                    Button("Delete", role: .destructive) { deletingLaya = true }
                        .buttonStyle(.borderless).font(KemoType.font(.footnote)).accessibilityIdentifier("deleteLaya")
                    Toggle("Use Laya", isOn: $settings.layaEnabled).labelsHidden().accessibilityIdentifier("layaEnabled")
                // The status card holds Download while it's the one thing to do (one control per job).
                case .notDownloaded where status.action != .downloadLaya, .failed where status.action != .downloadLaya:
                    Button(laya.store.isInstalled ? "Try again" : "Download") { laya.download() }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule).font(KemoType.font(.caption, weight: .semibold))
                        .accessibilityIdentifier("layaDownload")
                default: EmptyView()
                }
            }
            if case .failed(let message) = laya.state { Text(message).font(KemoType.font(.caption)).foregroundStyle(.orange).accessibilityIdentifier("layaProblem") }
            if laya.state == .notDownloaded { Text(SystemOneCatalog.layaDownload).font(KemoType.font(.caption)).foregroundStyle(.secondary) }
            if laya.state == .preparing {
                Text("Preparing Laya for this device. This takes a minute, once.").font(KemoType.font(.caption)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("layaPreparing")
            }
            VoiceModelProgress(model: laya.store)
        }
        .padding(.vertical, 2)
        .confirmationDialog("Delete Laya?", isPresented: $deletingLaya, titleVisibility: .visible) {
            Button("Delete \(laya.sizeLabel)", role: .destructive) { laya.delete() }.accessibilityIdentifier("confirmDeleteLaya")
        } message: { Text("You can download it again later. Until then Jev or Apple routing decides. Your marks and personal layer stay.") }
    }

    private var jevStatus: String { settings.jevActive ? "Active" : settings.hasJevKey ? "Off" : "Add your Jev key" }
    @ViewBuilder private var jevRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                title("Jev", status: jevStatus, line: settings.hasJevKey ? "Sends to \(JevDecisionProvider.host) · your key" : "TypeSafe's hosted model, with your own key")
                Spacer(minLength: 8)
                if settings.hasJevKey {
                    Button("Remove", role: .destructive) { removingJev = true }
                        .buttonStyle(.borderless).font(KemoType.font(.footnote)).accessibilityIdentifier("removeJevKey")
                    Toggle("Use Jev", isOn: $settings.jevEnabled).labelsHidden().accessibilityIdentifier("jevEnabled")
                } else if !addingJev {
                    Button("Add key") { withAnimation(.snappy) { addingJev = true } }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule).font(KemoType.font(.caption, weight: .semibold))
                        .accessibilityIdentifier("showJevKey")
                }
            }
            if !settings.hasJevKey, addingJev { jevKeyField }
            if let jevProblem { Text(jevProblem).font(KemoType.font(.caption)).foregroundStyle(.orange).accessibilityIdentifier("jevProblem") }
        }
        .padding(.vertical, 2)
        .confirmationDialog("Remove your Jev key?", isPresented: $removingJev, titleVisibility: .visible) {
            Button("Remove key", role: .destructive) {
                do { try settings.removeJevKey(); jevProblem = nil; addingJev = false } catch { jevProblem = message(error, "The key couldn't be removed from Keychain.") }
            }.accessibilityIdentifier("confirmRemoveJev")
        } message: { Text("Nothing more goes to \(JevDecisionProvider.host).") }
    }
    @ViewBuilder private var jevKeyField: some View {
        HStack {
            SecureField("Jev API key", text: $jevKey, prompt: Text("Paste your Jev API key")).labelsHidden()
                .textFieldStyle(.roundedBorder).autocorrectionDisabled().accessibilityIdentifier("jevKey")
                .onSubmit { if JevKey.isValid(jevKey) { confirmingJev = true } }
            Button("Add") { confirmingJev = true }
                .buttonStyle(.bordered).buttonBorderShape(.capsule)
                .disabled(!JevKey.isValid(jevKey)).accessibilityIdentifier("addJevKey")
                .confirmationDialog("Use Jev for decisions?", isPresented: $confirmingJev, titleVisibility: .visible) {
                    Button("Send decisions to \(JevDecisionProvider.host)") { addJevKey() }.accessibilityIdentifier("confirmJev")
                } message: {
                    Text("When Laya isn't sure, the words of your request and the choices go to \(JevDecisionProvider.host) with your key. Never your chat history, memories, or People, and nothing from Sensitive, Device only, or Secret chats. TypeSafe's terms apply.")
                }
        }
        if !jevKey.isEmpty, !JevKey.isValid(jevKey) {
            Text(JevKeyError.invalid.errorDescription ?? "").font(KemoType.font(.caption)).foregroundStyle(.orange)
        }
        HStack(spacing: 6) {
            Link("Get a Jev key", destination: JevDecisionProvider.keysPage)
                .font(KemoType.font(.caption, weight: .semibold)).accessibilityIdentifier("getJevKey")
            Text("at console.typesafe.ai. It's kept in this device's Keychain.").font(KemoType.font(.caption)).foregroundStyle(.secondary)
        }
    }
    private func addJevKey() {
        do { try settings.saveJevKey(jevKey); jevKey = ""; jevProblem = nil; addingJev = false }
        catch { jevProblem = message(error, "The key couldn't be saved in Keychain.") }
    }

    private var openAIRow: some View {
        title(SystemOneCatalog.openAIDecisions.title, status: SystemOneCatalog.openAIDecisions.status,
              line: "Comes after Jev once OpenAI publishes how to call it")
            .padding(.vertical, 2)
    }

    // MARK: Details: thresholds and recent decisions

    @ViewBuilder private var details: some View {
        Section("Decisions") {
            ForEach(DecisionKind.allCases) { kind in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(kind.title).font(.body.weight(.semibold)); Spacer()
                        Text(kind.inUse ? "Sure above \(Int((kind.threshold * 100).rounded()))%" : "Not used yet").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(kind.detail).font(.footnote).foregroundStyle(.secondary)
                }.padding(.vertical, 2)
            }
        }.modelsRow()
        Section {
            if records.isEmpty {
                Text(laya.state == .ready || settings.jevActive ? "None yet. Each decision shows here, with who made it." : "Laya or Jev decides once one is on.")
                    .font(KemoType.font(.footnote)).foregroundStyle(.secondary).accessibilityIdentifier("systemOneNoDecisions")
            }
            ForEach(Array(records.suffix(12).reversed())) { record in recordRow(record) }
            if let markProblem { Text(markProblem).font(KemoType.font(.caption)).foregroundStyle(.orange) }
        } header: { Text("Recent decisions") } footer: {
            if records.contains(where: { $0.markable != nil }) { Text(SystemOneCatalog.marking) }
        }.modelsRow()
    }

    private var marks: [UUID: SystemOneExample] { Dictionary(examples.map { ($0.recordID, $0) }) { _, new in new } }
    private func recordRow(_ record: SystemOneRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(record.kind.title).font(.body.weight(.medium))
                    Spacer()
                    Text(Self.decidedLine(record))
                        .font(.caption).foregroundStyle(record.decidedBy == .fallback ? AnyShapeStyle(HierarchicalShapeStyle.secondary) : AnyShapeStyle(HierarchicalShapeStyle.primary))
                }
                Text(record.steps.map(Self.describe).joined(separator: " · ") + " · " + record.at.formatted(.relative(presentation: .named)))
                    .font(.caption).foregroundStyle(.secondary)
            }.accessibilityElement(children: .combine).accessibilityIdentifier("systemOneRecord")
            if let question = record.markable, let shown = question.shown { markRow(record, question: question, shown: shown) }
        }
    }
    @ViewBuilder private func markRow(_ record: SystemOneRecord, question: SystemOneRecord.Question, shown: Int) -> some View {
        HStack(spacing: 8) {
            if let mark = marks[record.id] {
                // The mark replaces the lean, so the whole line fits.
                Text(mark.right ? "Marked right · \(mark.options[mark.correct])" : "Marked wrong · \(mark.options[mark.correct]) was right")
                    .font(.caption).accessibilityIdentifier("systemOneMarked")
                Spacer(minLength: 4)
                Button("Undo") { unmark(record.id) }.buttonStyle(.borderless).font(.caption).accessibilityIdentifier("systemOneUnmark")
            } else {
                Text((question.answer != nil ? "Answer: " : "Laya leaned: ") + question.options[shown])
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Button("Right") { mark(record, correct: shown) }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small).accessibilityIdentifier("systemOneRight")
                Menu("Wrong") {
                    Section("What was right?") {
                        ForEach(question.options.indices.filter { $0 != shown }, id: \.self) { index in
                            Button(question.options[index]) { mark(record, correct: index) }
                        }
                    }
                }
                .menuStyle(.button).buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small).fixedSize()
                .accessibilityIdentifier("systemOneWrong")
            }
        }
    }
    private func mark(_ record: SystemOneRecord, correct: Int) {
        guard let example = SystemOneExample(record: record, correct: correct) else { return }
        Task {
            do { try await SystemOneExamples.current.mark(example); markProblem = nil }
            catch { markProblem = "The mark couldn't be saved on this device." }
            await reload()
        }
    }
    private func unmark(_ id: UUID) {
        Task { try? await SystemOneExamples.current.unmark(id); await reload() }
    }
    /// "Decided by Laya", "Decided by Laya · your layer", "All unsure · Apple routing".
    nonisolated static func decidedLine(_ record: SystemOneRecord) -> String {
        switch record.decidedBy {
        case .fallback: return record.steps.count > 1 ? "All unsure · Apple routing" : "Unsure · Apple routing"
        case .laya: return "Decided by Laya" + (record.layer == .personal ? " · your layer" : "")
        default: return "Decided by \(record.decidedBy.title)"
        }
    }
    /// "Laya 97%", "Laya not sure (62%)", "Jev: not for this chat".
    nonisolated static func describe(_ step: SystemOneStep) -> String {
        let name = step.provider.title + (step.layer == .personal ? " + your layer" : ""), percent = step.score.map { "\(Int(($0 * 100).rounded()))%" }
        switch step.reason {
        case nil: return name + " " + (percent ?? "")
        case .lowConfidence: return "\(name) not sure" + (percent.map { " (\($0))" } ?? "")
        case .outOfDistribution: return "\(step.provider.title) abstained: unfamiliar input"
        case .privacy: return "\(step.provider.title): not for this chat"
        case .unavailable: return "\(step.provider.title) unavailable"
        case .rejected: return "\(step.provider.title): key refused or limit reached"
        }
    }

    // MARK: Rows

    /// A provider's name with its status beside it, and one short line under it.
    private func title(_ name: String, status: String, line: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(name).font(.body.weight(.semibold))
                Text(status).font(.caption).foregroundStyle(status == "Active" ? AnyShapeStyle(Color.green) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                    .accessibilityIdentifier("systemOneStatus-" + name)
            }
            Text(line).font(.footnote).foregroundStyle(.secondary)
        }
    }
    private func message(_ error: Error, _ fallback: String) -> String { (error as? LocalizedError)?.errorDescription ?? fallback }
    private func reload() async {
        records = await SystemOneJournal.current.records()
        examples = await SystemOneExamples.current.all()
        personal = SystemOnePersonalStore().state()
    }
}

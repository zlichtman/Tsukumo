import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TsukumoCore
import TsukumoSystemOne
import TsukumoUI
import TsukumoDock
import TsukumoLaya

// Settings, Models, System One (design/UI-GUIDE.md): who answers an untagged message. A status line, then
// the decision models in the order they're asked (Laya on this Mac first, then the hosted models in the
// order the person drags them into), each with its state and its own page (key or token, account ID,
// model, the host's one-time confirmation, Test, Remove), then the recent decisions with Right and Wrong
// and the personal layer. The iPhone's System One tab has the same cards in the same order
// (TsukumoUI's `SystemOneCopy`).

struct SystemOnePane: View {
    let center: SystemOneCenter
    /// The provider page open ("laya", or a hosted kind's id).
    @Binding var detail: String?

    var body: some View {
        SettingsCard(SystemOneCopy.untagged, systemImage: "arrow.triangle.branch") {
            SettingsRow(SystemOneCopy.routing, systemImage: "arrow.uturn.left", subtitle: center.statusLine) {
                EmptyView()
            }
            .accessibilityIdentifier("systemOneStatus")
            if let last = center.lastDecisionLine { SettingsNote(last) }
        }
        SettingsCard(SystemOneCopy.models, systemImage: "list.number") {
            VStack(alignment: .leading, spacing: 8) {
                if let laya = center.laya {
                    Button { detail = "laya" } label: {
                        SettingsRow(SystemOneCopy.layaTitle, subtitle: SystemOneCopy.layaDetail(device: "Mac")) {
                            SettingsIcon("cpu")
                        } trailing: {
                            StatusBadge(status: SystemOneCopy.status(laya.state))
                            SettingsChevron()
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("systemOne-laya")
                }
                ForEach(center.settings.hosted) { setting in
                    Divider()
                    hostedRow(setting.kind)
                }
            }
            SettingsNote(SystemOneCopy.modelsFooter(device: "Mac"))
            SettingsNote(SystemOneCopy.watched)
        }
        SettingsCard(SystemOneCopy.recent, systemImage: "clock.arrow.circlepath") {
            if center.recent.isEmpty {
                SettingsNote(SystemOneCopy.recentEmpty)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(center.recent.enumerated()), id: \.element.id) { index, record in
                        if index > 0 { Divider() }
                        DecisionRow(center: center, record: record)
                    }
                }
                SettingsNote(SystemOneCopy.marking)
            }
            Divider()
            SettingsRow(SystemOneCopy.personalLayer, systemImage: "person.crop.circle.badge.checkmark", subtitle: center.personalLine) { EmptyView() }
        }
        .task { await center.reload() }
        .sheet(item: Binding(get: { detail.map(DetailID.init) }, set: { detail = $0?.id })) { target in
            SystemOneProviderPage(center: center, id: target.id) { detail = nil }
                .frame(width: 520, height: 600)
        }
    }

    private struct DetailID: Identifiable { let id: String }

    private func hostedRow(_ kind: HostedProviderKind) -> some View {
        Button { detail = kind.id } label: {
            SettingsRow(kind.title, subtitle: kind.detail) {
                SettingsIcon(kind.symbol)
            } trailing: {
                StatusBadge(status: center.status(kind))
                Image(systemName: "line.3.horizontal").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                    .help("Drag to change the order")
                SettingsChevron()
            }
        }
        .buttonStyle(.plain)
        .draggable(kind.rawValue)
        .dropDestination(for: String.self) { items, _ in
            guard let moved = items.first.flatMap(HostedProviderKind.init(rawValue:)) else { return false }
            withAnimation(.snappy) { center.move(moved, to: kind) }
            return true
        }
        .contextMenu {
            let order = center.settings.hosted.map(\.kind)
            if let index = order.firstIndex(of: kind) {
                if index > 0 { Button("Move Up") { center.move(kind, to: order[index - 1]) } }
                if index < order.count - 1 { Button("Move Down") { center.move(kind, to: order[index + 1]) } }
            }
        }
        .accessibilityIdentifier("systemOne-" + kind.rawValue)
    }
}

extension HostedProviderKind {
    var symbol: String {
        switch self {
        case .clefFlash: "bolt.horizontal.circle"
        case .clef: "cloud"
        case .jev: "checkmark.seal"
        case .custom: "network"
        }
    }
}

/// "Ready" in green, the rest quiet.
struct StatusBadge: View {
    let status: ProviderStatus
    var body: some View {
        Text(SystemOneCopy.status(status))
            .font(.caption.weight(status == .ready ? .semibold : .regular))
            .foregroundStyle(status == .ready ? AnyShapeStyle(Color.green) : AnyShapeStyle(.secondary))
    }
}

/// One decision: what it was, who decided, each step and where it was sent, and Right or Wrong.
struct DecisionRow: View {
    let center: SystemOneCenter
    let record: DecisionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(record.kind.title).font(.system(size: 13, weight: .medium))
                Spacer()
                Text(SystemOneCopy.decided(record)).font(.caption).foregroundStyle(record.decidedBy == .fallback ? .secondary : .primary)
            }
            Text(SystemOneCopy.steps(record) + " · " + record.at.formatted(.relative(presentation: .named)))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let sent = SystemOneCopy.sent(record) { Text(sent).font(.caption).foregroundStyle(.secondary) }
            if let (question, shown) = SystemOneCenter.markable(record) {
                HStack(spacing: 8) {
                    if let mark = center.mark(for: record) {
                        Text(mark.correct == mark.shown ? "Marked right · \(mark.options[mark.correct])" : "Marked wrong · \(mark.options[mark.correct]) was right")
                            .font(.caption)
                        Spacer()
                        Button("Undo") { center.unmark(record) }.buttonStyle(.link).font(.caption)
                    } else {
                        Text((question.answer != nil ? "Answer: " : "Laya leaned: ") + question.options[shown])
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button("Right") { center.mark(record, correct: shown) }.controlSize(.small)
                        Menu("Wrong") {
                            Section("What was right?") {
                                ForEach(question.options.indices.filter { $0 != shown }, id: \.self) { index in
                                    Button(question.options[index]) { center.mark(record, correct: index) }
                                }
                            }
                        }
                        .controlSize(.small).fixedSize()
                    }
                }
            }
        }
        .accessibilityIdentifier("systemOneRecord")
    }
}

/// A decision model's own page: Laya's download, or a hosted model's key, account, model, and the
/// confirmation that turns it on; Test; Remove.
struct SystemOneProviderPage: View {
    let center: SystemOneCenter
    let id: String
    let done: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var key = ""
    @State private var accountID = ""
    @State private var address = ""
    @State private var model = ""
    @State private var problem: String?
    @State private var confirmingOn = false
    @State private var confirmingRemove = false
    @State private var confirmingDownload = false

    private var kind: HostedProviderKind? { HostedProviderKind(rawValue: id) }

    var body: some View {
        let colors = SettingsColors(scheme)
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if let kind { hosted(kind) } else if let laya = center.laya { layaCards(laya) }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .background(colors.surface)
        .onAppear {
            if let kind {
                let setting = center.setting(kind)
                accountID = setting.accountID; address = setting.address; model = setting.model
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            SettingsIcon(kind?.symbol ?? "cpu")
            VStack(alignment: .leading, spacing: 2) {
                Text(kind?.title ?? SystemOneCopy.layaTitle).font(.system(size: 20, weight: .bold))
                Text(kind.map { ($0.fixedHost ?? center.setting($0).host ?? "Your endpoint") + " · " + $0.detail } ?? SystemOneCopy.layaDetail(device: "Mac"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Hosted

    @ViewBuilder private func hosted(_ kind: HostedProviderKind) -> some View {
        let setting = center.setting(kind)
        SettingsCard("Use for decisions", systemImage: "power") {
            Toggle(isOn: Binding(get: { center.setting(kind).on }, set: { on in
                if on { confirmingOn = true } else { center.turnOff(kind) }
            })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(SystemOneCopy.status(center.status(kind))).font(.system(size: 13, weight: .medium))
                    Text(center.status(kind) == .needsKey ? "Add the \(kind.keyPhrase)" + (kind.needsAccountID ? " and account ID" : kind == .custom ? ", address, and model" : "") + " first." : "Asked after Laya, in its place in the list.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(center.status(kind) == .needsKey)
            .accessibilityIdentifier("hostedOn")
            SettingsNote(HostedConsent.message(kind, host: setting.host ?? "its host"))
        }
        .confirmationDialog(HostedConsent.title(kind), isPresented: $confirmingOn) {
            Button(HostedConsent.confirm(host: setting.host ?? "")) { center.turnOn(kind) }
            Button("Cancel", role: .cancel) {}
        } message: { Text(HostedConsent.message(kind, host: setting.host ?? "")) }
        SettingsCard("Connection", systemImage: "key") {
            if kind.needsAccountID {
                SettingsField("Account ID") {
                    TextField("Account ID", text: $accountID, prompt: Text("32 characters")).labelsHidden().frame(width: 260)
                        .onSubmit { save(kind) }
                        .accessibilityIdentifier("hostedAccount")
                }
            }
            if kind == .custom {
                SettingsField("Address") {
                    TextField("Address", text: $address, prompt: Text("https://…/v1/systemone")).labelsHidden().frame(width: 260)
                        .onSubmit { save(kind) }
                }
            }
            SettingsField("Model") {
                if kind.models.count > 1 {
                    Picker("Model", selection: Binding(get: { model }, set: { model = $0; save(kind) })) {
                        ForEach(kind.models, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                } else if kind == .custom {
                    TextField("Model", text: $model, prompt: Text("Model name")).labelsHidden().frame(width: 260).onSubmit { save(kind) }
                } else {
                    Text(kind.defaultModel).foregroundStyle(.secondary)
                }
            }
            SettingsField(kind.keyName) {
                HStack(spacing: 8) {
                    SecureField(kind.keyName, text: $key, prompt: Text(center.hasKey(kind) ? "Saved on this Mac" : "Paste it here")).labelsHidden().frame(width: 190)
                        .accessibilityIdentifier("hostedKey")
                    Button("Save") { save(kind) }.fixedSize()
                        .disabled(key.isEmpty && accountID == setting.accountID && address == setting.address && model == setting.model)
                }
            }
            if let problem { SettingsNote(problem, warning: true) }
            SettingsNote(kind.keyHelp + " It’s kept in this Mac’s Keychain only and never syncs.")
        }
        testCard(kind.id, enabled: center.status(kind) == .ready)
        if center.hasKey(kind) || setting.on || !setting.accountID.isEmpty || !setting.address.isEmpty {
            Button("Remove \(kind.title)", role: .destructive) { confirmingRemove = true }
                .confirmationDialog("Remove \(kind.title)?", isPresented: $confirmingRemove) {
                    Button("Remove", role: .destructive) { center.remove(kind); key = ""; accountID = ""; address = ""; model = kind.defaultModel }
                    Button("Cancel", role: .cancel) {}
                } message: { Text("Its \(kind.keyPhrase) leaves this Mac’s Keychain, and nothing more goes to \(setting.host ?? "it").") }
        }
    }

    private func save(_ kind: HostedProviderKind) {
        problem = nil
        var setting = center.setting(kind)
        setting.accountID = accountID.trimmingCharacters(in: .whitespaces)
        setting.address = address.trimmingCharacters(in: .whitespaces)
        setting.model = model.trimmingCharacters(in: .whitespaces)
        if kind.needsAccountID, !setting.accountID.isEmpty, !SystemOneEndpoint.isAccountID(setting.accountID) {
            problem = "An account ID is 32 letters and numbers (0 to 9, a to f), from the Cloudflare dashboard."
        }
        if kind == .custom, !setting.address.isEmpty, SystemOneEndpoint.custom(address: setting.address, model: setting.model.isEmpty ? "m" : setting.model) == nil {
            problem = "The address must start with https://."
        }
        center.update(setting)
        if !key.isEmpty {
            do { try center.saveKey(key, for: kind); key = "" } catch { problem = (error as? LocalizedError)?.errorDescription ?? "The key couldn’t be saved." }
        }
    }

    // MARK: Laya

    @ViewBuilder private func layaCards(_ laya: LayaModel) -> some View {
        SettingsCard("On this Mac", systemImage: "cpu") {
            SettingsRow(SystemOneCopy.layaTitle, subtitle: SystemOneCopy.layaLine(laya.state, size: laya.sizeLabel)) {
                SettingsIcon(laya.state == .ready ? "checkmark.circle" : "arrow.down.circle")
            } trailing: {
                switch laya.state {
                case .notDownloaded:
                    Button("Download") { confirmingDownload = true }.accessibilityIdentifier("downloadLaya")
                case .downloading(let fraction):
                    ProgressView(value: fraction).frame(width: 120)
                    Text("\(Int((fraction * 100).rounded()))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                case .waitingForWiFi:
                    Button("Use any network this time") { laya.store.cancel(); laya.store.wifiOnly = false; laya.download() }
                case .verifying, .preparing:
                    ProgressView().controlSize(.small)
                case .ready:
                    Button("Remove", role: .destructive) { confirmingRemove = true }.accessibilityIdentifier("removeLaya")
                case .failed:
                    Button("Try again") { laya.download() }
                }
            }
            SettingsNote(SystemOneCopy.layaAbout(device: "Mac"))
        }
        .confirmationDialog(SystemOneCopy.layaConsentTitle, isPresented: $confirmingDownload) {
            Button("Download \(laya.sizeLabel)") { laya.download() }
            Button("Cancel", role: .cancel) {}
        } message: { Text(SystemOneCopy.layaConsentMessage(size: laya.sizeLabel, device: "Mac")) }
        .confirmationDialog(SystemOneCopy.layaRemoveTitle, isPresented: $confirmingRemove) {
            Button("Remove \(laya.sizeLabel)", role: .destructive) { laya.remove() }
            Button("Cancel", role: .cancel) {}
        } message: { Text(SystemOneCopy.layaRemoveMessage(size: laya.sizeLabel, device: "Mac")) }
        testCard("laya", enabled: laya.state == .ready)
        Button("Licenses…") { if let url = LayaBundleTokenizer.noticeURL { NSWorkspace.shared.open(url) } }
            .buttonStyle(.link).font(.caption)
    }

    // MARK: Test

    private func testCard(_ id: String, enabled: Bool) -> some View {
        SettingsCard("Test", systemImage: "checkmark.circle") {
            SettingsRow("One sample decision", subtitle: center.testResults[id] ?? "Which of three made-up bots should plan a birthday dinner. Nothing of yours is sent.") {
                EmptyView()
            } trailing: {
                if center.testing.contains(id) { ProgressView().controlSize(.small) }
                Button("Test") { Task { await center.test(id) } }.disabled(!enabled || center.testing.contains(id))
                    .accessibilityIdentifier("testProvider")
            }
        }
    }
}

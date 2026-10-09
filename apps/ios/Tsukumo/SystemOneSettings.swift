import SwiftUI
import TsukumoCore
import TsukumoSystemOne
import TsukumoUI
import TsukumoLaya

// Settings, Models, System One on iPhone (design/UI-GUIDE.md): the same cards in the same order as the
// Mac's (TsukumoUI's `SystemOneCopy`): a status line, the decision models in the order they're asked
// (Laya on this iPhone first, then the hosted models, reordered with Edit), each with its own page, then
// the recent decisions with Right and Wrong and the personal layer.

struct SystemOneSections: View {
    let center: SystemOneCenter

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                Text(SystemOneCopy.routing)
                Text(center.statusLine).font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("systemOneStatus")
            }
        } header: {
            Text(SystemOneCopy.untagged)
        } footer: {
            if let last = center.lastDecisionLine { Text(last) }
        }
        Section {
            if let laya = center.laya {
                NavigationLink { SystemOneProviderPage(center: center, id: "laya") } label: {
                    row(SystemOneCopy.layaTitle, detail: SystemOneCopy.layaDetail(device: "iPhone"), symbol: "cpu", status: SystemOneCopy.status(laya.state))
                }
                .accessibilityIdentifier("systemOne-laya")
                .moveDisabled(true)
            }
            ForEach(center.settings.hosted) { setting in
                NavigationLink { SystemOneProviderPage(center: center, id: setting.kind.id) } label: {
                    row(setting.kind.title, detail: setting.kind.detail, symbol: setting.kind.symbol, status: center.status(setting.kind))
                }
                .accessibilityIdentifier("systemOne-" + setting.kind.rawValue)
            }
            .onMove { center.move(fromOffsets: $0, toOffset: $1) }
        } header: {
            HStack {
                Text(SystemOneCopy.models)
                Spacer()
                EditButton().font(.footnote).textCase(nil)
            }
        } footer: {
            Text(SystemOneCopy.modelsFooter(device: "iPhone") + " " + SystemOneCopy.watched)
        }
        Section {
            if center.recent.isEmpty {
                Text(SystemOneCopy.recentEmpty).font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(center.recent) { record in DecisionRow(center: center, record: record) }
            VStack(alignment: .leading, spacing: 2) {
                Text(SystemOneCopy.personalLayer)
                Text(center.personalLine).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text(SystemOneCopy.recent)
        } footer: {
            if !center.recent.isEmpty { Text(SystemOneCopy.marking) }
        }
        .task { await center.reload() }
    }

    private func row(_ title: String, detail: String, symbol: String, status: ProviderStatus) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 26).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Text(SystemOneCopy.status(status)).font(.footnote.weight(status == .ready ? .semibold : .regular))
                .foregroundStyle(status == .ready ? AnyShapeStyle(Color.green) : AnyShapeStyle(.secondary))
        }
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

/// One decision, with Right and Wrong when Laya scored it.
struct DecisionRow: View {
    let center: SystemOneCenter
    let record: DecisionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(record.kind.title).font(.body.weight(.medium))
                Spacer()
                Text(SystemOneCopy.decided(record)).font(.caption).foregroundStyle(record.decidedBy == .fallback ? .secondary : .primary)
            }
            Text(SystemOneCopy.steps(record) + " · " + record.at.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
            if let sent = SystemOneCopy.sent(record) { Text(sent).font(.caption).foregroundStyle(.secondary) }
            if let (question, shown) = SystemOneCenter.markable(record) {
                HStack(spacing: 8) {
                    if let mark = center.mark(for: record) {
                        Text(mark.correct == mark.shown ? "Marked right · \(mark.options[mark.correct])" : "Marked wrong · \(mark.options[mark.correct]) was right")
                            .font(.caption)
                        Spacer(minLength: 4)
                        Button("Undo") { center.unmark(record) }.buttonStyle(.borderless).font(.caption)
                    } else {
                        Text((question.answer != nil ? "Answer: " : "Laya leaned: ") + question.options[shown])
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 4)
                        Button("Right") { center.mark(record, correct: shown) }
                            .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                        Menu("Wrong") {
                            Section("What was right?") {
                                ForEach(question.options.indices.filter { $0 != shown }, id: \.self) { index in
                                    Button(question.options[index]) { center.mark(record, correct: index) }
                                }
                            }
                        }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small).fixedSize()
                    }
                }
            }
        }
        .accessibilityIdentifier("systemOneRecord")
    }
}

/// A decision model's page: Laya's download, or a hosted model's key, account, model, the confirmation
/// that turns it on, Test, and Remove.
struct SystemOneProviderPage: View {
    let center: SystemOneCenter
    let id: String
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
        List {
            if let kind { hosted(kind) } else if let laya = center.laya { layaSections(laya) }
            Section {
                Button { Task { await center.test(id) } } label: {
                    HStack {
                        Text("Test")
                        Spacer()
                        if center.testing.contains(id) { ProgressView() }
                    }
                }
                .disabled(!(kind.map { center.status($0) == .ready } ?? (center.laya?.state == .ready)) || center.testing.contains(id))
                .accessibilityIdentifier("testProvider")
            } header: {
                Text("Test")
            } footer: {
                Text(center.testResults[id] ?? "One sample decision: which of three made-up bots should plan a birthday dinner. Nothing of yours is sent.")
            }
        }
        .navigationTitle(kind?.title ?? SystemOneCopy.layaTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let kind {
                let setting = center.setting(kind)
                accountID = setting.accountID; address = setting.address; model = setting.model
            }
        }
    }

    @ViewBuilder private func hosted(_ kind: HostedProviderKind) -> some View {
        let setting = center.setting(kind)
        Section {
            Toggle(isOn: Binding(get: { center.setting(kind).on }, set: { on in
                if on { confirmingOn = true } else { center.turnOff(kind) }
            })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use for decisions")
                    Text(SystemOneCopy.status(center.status(kind))).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .disabled(center.status(kind) == .needsKey)
            .accessibilityIdentifier("hostedOn")
        } header: {
            Text((kind.fixedHost ?? setting.host ?? "Your endpoint") + " · " + kind.detail)
        } footer: {
            Text(HostedConsent.message(kind, host: setting.host ?? "its host"))
        }
        .confirmationDialog(HostedConsent.title(kind), isPresented: $confirmingOn, titleVisibility: .visible) {
            Button(HostedConsent.confirm(host: setting.host ?? "")) { center.turnOn(kind) }
            Button("Cancel", role: .cancel) {}
        } message: { Text(HostedConsent.message(kind, host: setting.host ?? "")) }
        Section {
            if kind.needsAccountID {
                TextField("Account ID", text: $accountID, prompt: Text("Account ID (32 characters)"))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("hostedAccount")
            }
            if kind == .custom {
                TextField("Address", text: $address, prompt: Text("https://…/v1/systemone"))
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            }
            if kind.models.count > 1 {
                Picker("Model", selection: $model) { ForEach(kind.models, id: \.self) { Text($0).tag($0) } }
            } else if kind == .custom {
                TextField("Model", text: $model, prompt: Text("Model name")).textInputAutocapitalization(.never).autocorrectionDisabled()
            } else {
                LabeledContent("Model", value: kind.defaultModel)
            }
            SecureField(kind.keyName, text: $key, prompt: Text(center.hasKey(kind) ? "\(kind.keyName) saved on this iPhone" : kind.keyName))
                .accessibilityIdentifier("hostedKey")
            Button("Save") { save(kind) }
            if let problem { Text(problem).font(.footnote).foregroundStyle(.orange) }
        } header: {
            Text("Connection")
        } footer: {
            Text(kind.keyHelp + " It’s kept in this iPhone’s Keychain only and never syncs.")
        }
        if center.hasKey(kind) || setting.on || !setting.accountID.isEmpty || !setting.address.isEmpty {
            Section {
                Button("Remove \(kind.title)", role: .destructive) { confirmingRemove = true }
            }
            .confirmationDialog("Remove \(kind.title)?", isPresented: $confirmingRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { center.remove(kind); key = ""; accountID = ""; address = ""; model = kind.defaultModel }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Its \(kind.keyPhrase) leaves this iPhone’s Keychain, and nothing more goes to \(setting.host ?? "it").") }
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

    @ViewBuilder private func layaSections(_ laya: LayaModel) -> some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(SystemOneCopy.layaTitle)
                    Text(SystemOneCopy.layaLine(laya.state, size: laya.sizeLabel)).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                switch laya.state {
                case .notDownloaded:
                    Button("Download") { confirmingDownload = true }.accessibilityIdentifier("downloadLaya")
                case .downloading(let fraction):
                    ProgressView(value: fraction).frame(width: 90)
                case .waitingForWiFi:
                    Button("Use any network") { guard center.canWrite() else { return }; laya.store.cancel(); laya.store.wifiOnly = false; laya.download() }
                case .verifying, .preparing:
                    ProgressView()
                case .ready:
                    Button("Remove", role: .destructive) { confirmingRemove = true }.accessibilityIdentifier("removeLaya")
                case .failed:
                    Button("Try again") { guard center.canWrite() else { return }; laya.download() }
                }
            }
            .buttonStyle(.borderless)
        } header: {
            Text("On this iPhone")
        } footer: {
            Text(SystemOneCopy.layaAbout(device: "iPhone"))
        }
        .confirmationDialog(SystemOneCopy.layaConsentTitle, isPresented: $confirmingDownload, titleVisibility: .visible) {
            Button("Download \(laya.sizeLabel)") { guard center.canWrite() else { return }; laya.download() }.accessibilityIdentifier("confirmDownloadLaya")
            Button("Cancel", role: .cancel) {}
        } message: { Text(SystemOneCopy.layaConsentMessage(size: laya.sizeLabel, device: "iPhone") + " It downloads on Wi-Fi.") }
        .confirmationDialog(SystemOneCopy.layaRemoveTitle, isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove \(laya.sizeLabel)", role: .destructive) { guard center.canWrite() else { return }; laya.remove() }
            Button("Cancel", role: .cancel) {}
        } message: { Text(SystemOneCopy.layaRemoveMessage(size: laya.sizeLabel, device: "iPhone")) }
        if let url = LayaBundleTokenizer.noticeURL {
            Section {
                NavigationLink("Licenses") {
                    ScrollView { Text((try? String(contentsOf: url, encoding: .utf8)) ?? "").font(.footnote.monospaced()).padding() }
                        .navigationTitle("Licenses")
                }
            }
        }
    }
}

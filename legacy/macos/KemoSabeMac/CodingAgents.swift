import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Launch-only integration. No transcript, prompt, credential, or personal context
/// is forwarded. In-process execution adapters must negotiate their own grants.
struct CodingApplication: Identifiable, Codable, Equatable {
    var id: String { bundleID }
    let name: String
    let bundleID: String
    let path: String
    var url: URL { URL(fileURLWithPath: path) }
    var available: Bool { Bundle(url: url)?.bundleIdentifier == bundleID }
}
@MainActor @Observable final class CodingApplicationRegistry {
    var applications: [CodingApplication] = []
    var notice = ""
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "coding.applications"), let saved = try? JSONDecoder().decode([CodingApplication].self, from: data) { applications = saved }
    }
    func addApplication() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.prompt = "Add application"
        panel.message = "Choose Cursor or another coding application. This adds an Open in shortcut; it does not connect an agent or share your private context."
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let self, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
                let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? url.deletingPathExtension().lastPathComponent
                self.applications.removeAll { $0.bundleID == id }
                self.applications.append(.init(name: name, bundleID: id, path: url.path)); self.save()
            }
        }
    }
    func remove(_ app: CodingApplication) { applications.removeAll { $0.id == app.id }; save() }
    func open(_ app: CodingApplication, project: URL) {
        guard app.available else { notice = "This application moved. Add it again in Settings."; return }
        let config = NSWorkspace.OpenConfiguration(); config.activates = true
        NSWorkspace.shared.open([project], withApplicationAt: app.url, configuration: config) { [weak self] _, error in
            Task { @MainActor in self?.notice = error == nil ? "Opened project in \(app.name). Its own permissions and provider settings apply." : "Could not open the project in \(app.name)." }
        }
    }
    private func save() { if let data = try? JSONEncoder().encode(applications) { defaults.set(data, forKey: "coding.applications") } }
}
struct CodingAgentsSettings: View {
    @Environment(CodingApplicationRegistry.self) private var registry
    var body: some View {
        SettingsContent {
            SettingsCard(title: "Coding applications") {
                SettingsRow(title: "Open projects in your editor", detail: "Add Cursor or any installed coding app. Only the selected project is handed off.") { Button("Add application…") { registry.addApplication() } }
                ForEach(registry.applications) { app in
                    Divider()
                    SettingsRow(title: app.name, detail: app.available ? "Available · project handoff" : "Application unavailable") { Button("Remove") { registry.remove(app) } }
                }
            }
            Text("Applications open the selected project in their own window. Coding runtimes, language models, voice and System One models have separate settings.").font(.caption).foregroundStyle(.secondary)
            if !registry.notice.isEmpty { Text(registry.notice).font(.caption) }
        }
    }
}

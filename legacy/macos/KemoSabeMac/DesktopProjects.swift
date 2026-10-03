import AppKit
import Observation

struct DesktopProject: Codable, Identifiable, Equatable {
    var id = UUID()
    let name: String
    var bookmark: Data
}
@MainActor @Observable final class DesktopProjects {
    private(set) var projects: [DesktopProject] = []
    var selected: UUID? { didSet { defaults.set(selected?.uuidString, forKey: "workspace.selectedProject") } }
    var notice = ""
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "workspace.projects"), data.count <= 2_000_000,
           let saved = try? JSONDecoder().decode([DesktopProject].self, from: data), saved.count <= 100 { projects = saved }
        if let raw = defaults.string(forKey: "workspace.selectedProject"), let id = UUID(uuidString: raw), projects.contains(where: { $0.id == id }) { selected = id }
    }
    func choose() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "Add project"; panel.message = "Keep this folder in Projects with read-only access. Adding it does not share files with a model or coding agent."
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let self else { return }
                let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    guard self.projects.count < 100 else { throw CocoaError(.fileWriteOutOfSpace) }
                    let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
                    let existing = self.projects.first { (try? self.resolve($0.id))?.standardizedFileURL == url.standardizedFileURL }
                    if let existing { self.selected = existing.id }
                    else { let project = DesktopProject(name: url.lastPathComponent, bookmark: bookmark); self.projects.append(project); self.save(); self.selected = project.id }
                    self.notice = ""
                } catch { self.notice = "This project could not be saved. Choose the folder again." }
            }
        }
    }
    func resolve(_ id: UUID) throws -> URL {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { throw CocoaError(.fileNoSuchFile) }
        var stale = false
        let url = try URL(resolvingBookmarkData: projects[index].bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        if stale {
            let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            projects[index].bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil); save()
        }
        return url
    }
    func remove(_ id: UUID) { projects.removeAll { $0.id == id }; if selected == id { selected = nil }; save() }
    private func save() { if let data = try? JSONEncoder().encode(projects) { defaults.set(data, forKey: "workspace.projects") } }
}

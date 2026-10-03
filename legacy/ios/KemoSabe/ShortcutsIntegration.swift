import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Kemo can run Shortcuts you list here, by name, when you say or type “run
/// shortcut …”. The list is the permission: an unlisted shortcut never runs.
/// Shortcuts runs it in its own app, so Kemo never sees what it does.
@MainActor @Observable final class ShortcutsIntegration {
    static let shared = ShortcutsIntegration()
    private let defaults: UserDefaults
    private(set) var allowed: [String]
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        allowed = defaults.stringArray(forKey: "kemo.shortcuts.allowed") ?? []
    }
    func allow(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80, match(name) == nil, allowed.count < 50 else { return }
        allowed.append(name); save()
    }
    func remove(_ name: String) { allowed.removeAll { $0 == name }; save() }
    /// The listed shortcut a spoken or typed name refers to, ignoring case and punctuation.
    func match(_ spoken: String) -> String? {
        let wanted = VoiceTurnPolicy.normalized(spoken)
        return allowed.first { VoiceTurnPolicy.normalized($0) == wanted }
    }
    /// Runs a listed shortcut and returns what Kemo says about it.
    func run(_ spoken: String) -> String {
        guard let name = match(spoken) else {
            return "“\(spoken)” isn't in your allowed shortcuts. Add it in Settings under Integrations, then ask again."
        }
        var components = URLComponents(string: "shortcuts://run-shortcut")!
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        guard let url = components.url else { return "That shortcut name couldn't be used." }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
        return "Running \(name) in Shortcuts."
    }
    private func save() { defaults.set(allowed, forKey: "kemo.shortcuts.allowed") }
}

/// Settings for the Shortcuts integration, shared by iPhone and Mac.
struct ShortcutsIntegrationSettings: View {
    @State private var shortcuts = ShortcutsIntegration.shared
    @State private var newName = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Say or type “run shortcut” and a name. Only shortcuts listed here can run, and Shortcuts runs them in its own app.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("Shortcut name, exactly as in Shortcuts", text: $newName).textFieldStyle(.roundedBorder)
                    .onSubmit(add).accessibilityIdentifier("shortcutName")
                Button("Allow", action: add).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty).accessibilityIdentifier("allowShortcut")
            }
            if shortcuts.allowed.isEmpty {
                Text("No shortcuts allowed yet.").font(.callout).foregroundStyle(.tertiary)
            }
            ForEach(shortcuts.allowed, id: \.self) { name in
                HStack {
                    Label(name, systemImage: "square.2.layers.3d").lineLimit(1)
                    Spacer()
                    Button("Remove", role: .destructive) { shortcuts.remove(name) }
                }.padding(.vertical, 2)
            }
        }
    }
    private func add() { shortcuts.allow(newName); newName = "" }
}

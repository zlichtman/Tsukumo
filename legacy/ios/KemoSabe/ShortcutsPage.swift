import SwiftUI

/// Settings → Shortcuts on iPhone: the shortcuts Kemo may run by name, as a native list.
struct ShortcutsPage: View {
    @Environment(\.mobilePalette) private var palette
    @Environment(\.openURL) private var openURL
    @State private var shortcuts = ShortcutsIntegration.shared
    @State private var newName = ""
    @State private var ran: String?
    @FocusState private var adding: Bool
    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "square.2.layers.3d.fill").font(.title2).foregroundStyle(palette.accent)
                        .frame(width: 44, height: 44).background(palette.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Run your shortcuts by name").font(.headline)
                        Text("Say or type “run shortcut” and its name.").font(.subheadline).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 4)
            }.listRowBackground(Color.primary.opacity(0.05))
            Section {
                ForEach(shortcuts.allowed, id: \.self) { name in
                    HStack(spacing: 12) {
                        Image(systemName: "bolt.fill").font(.footnote).foregroundStyle(palette.accent).frame(width: 22)
                        Text(name).lineLimit(1)
                        Spacer()
                        Button { ran = shortcuts.run(name) } label: { Image(systemName: "play.circle.fill").font(.title3) }
                            .buttonStyle(.borderless).tint(palette.accent).accessibilityLabel("Run \(name)")
                    }
                    .swipeActions { Button("Remove", role: .destructive) { shortcuts.remove(name) } }
                }
                HStack(spacing: 12) {
                    Image(systemName: "plus").font(.footnote).foregroundStyle(.secondary).frame(width: 22)
                    TextField("Add a shortcut name", text: $newName).focused($adding).submitLabel(.done)
                        .onSubmit(add).accessibilityIdentifier("shortcutName")
                    if !newName.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button("Add", action: add).buttonStyle(.borderless).tint(palette.accent).accessibilityIdentifier("allowShortcut")
                    }
                }
            } header: {
                Text("Allowed")
            } footer: {
                Text(ran ?? "Only shortcuts listed here can run, and the name has to match Shortcuts exactly. Shortcuts runs them in its own app; KemoSabe doesn't see what they do. Swipe to remove one.")
            }
            .listRowBackground(Color.primary.opacity(0.05))
            Section {
                Button { if let url = URL(string: "shortcuts://") { openURL(url) } } label: {
                    Label("Open Shortcuts", systemImage: "arrow.up.forward.app")
                }.tint(palette.accent)
            } footer: { Text("Find a shortcut's exact name, or make a new one.") }
            .listRowBackground(Color.primary.opacity(0.05))
        }
        .scrollContentBackground(.hidden).background(palette.background)
        .navigationTitle("Shortcuts").navigationBarTitleDisplayMode(.inline)
        .animation(.default, value: shortcuts.allowed)
    }
    private func add() {
        shortcuts.allow(newName); newName = ""; ran = nil
    }
}

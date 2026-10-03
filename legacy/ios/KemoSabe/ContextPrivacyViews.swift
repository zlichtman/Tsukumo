import SwiftUI

/// "Privacy" as a plain menu with a checkmark, for a memory, doc, journal entry, or whole chat
/// (design/UI-GUIDE.md#privacy-levels). Each level names who may read it.
struct PrivacyLevelMenu: View {
    let current: PrivacyLevel
    let set: (PrivacyLevel) -> Void
    var body: some View {
        Menu {
            Picker("Privacy", selection: Binding(get: { current }, set: set)) {
                ForEach(PrivacyLevel.allCases) { level in
                    Text(level.title).tag(level)
                }
            }.pickerStyle(.inline)
        } label: {
            Label("Privacy: " + current.title, systemImage: current.symbol)
        }
        .accessibilityIdentifier("privacyMenu")
    }
}

/// The same choice as a row in a form, with the chosen level's one-line meaning under it.
struct PrivacyLevelPicker: View {
    @Binding var level: PrivacyLevel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Privacy", selection: $level) {
                ForEach(PrivacyLevel.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("privacyPicker")
            Text(level.detail).font(KemoType.font(.caption)).foregroundStyle(.secondary)
        }
    }
}

extension MemoryNote {
    /// The memory's level as a binding for editors: Secret is "Not used in chat".
    var privacyLevel: PrivacyLevel {
        get { MemoryPrivacy.level(self) }
        set { MemoryPrivacy.set(newValue, on: &self) }
    }
}

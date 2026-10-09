import AppKit
import SwiftUI
import TsukumoDock

// Tsukumo's light or dark look, the owner's pick in Settings, General (October 8, 2026, borrowed from MacSpaces'
// Appearance: System, Light, or Dark). It sets the whole app's appearance: the dock, its panels, the chat, and
// Settings. System follows macOS.

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    static let key = "appearance"
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// The saved pick (System until the owner picks).
    static var current: AppAppearance { UserDefaults.standard.string(forKey: key).flatMap(AppAppearance.init) ?? .system }

    /// Puts the pick on the whole app.
    func apply() {
        NSApp.appearance = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Settings, General: System, Light, or Dark.
struct AppearanceCard: View {
    @AppStorage(AppAppearance.key) private var appearance: AppAppearance = .system
    var body: some View {
        SettingsCard("Appearance", systemImage: "circle.lefthalf.filled") {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .accessibilityIdentifier("appAppearance")
            SettingsNote("System follows your Mac’s light or dark appearance.")
        }
        .onChange(of: appearance) { _, new in new.apply() }
    }
}

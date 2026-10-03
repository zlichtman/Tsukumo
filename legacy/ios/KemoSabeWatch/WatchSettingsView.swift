import SwiftUI
import WatchKit

/// The few settings that make sense on the wrist: reading aloud, Kemo's nudges, which
/// model answers, and customizing Kemo (its colors and tone, like a watch face). Nudges
/// belong to this watch; every other change goes to the iPhone, which applies it everywhere.
/// Clean and minimal (the owner's instruction, September 25, 2026): no explanatory footers;
/// choosing a connected model shows one line naming where messages go, only at that moment.
struct WatchSettingsView: View {
    let connection: WatchConnection
    @Environment(KemoPet.self) private var pet
    @AppStorage("readAloud") private var readAloud = true
    @AppStorage(KemoPet.nudgesKey) private var nudges = false
    @State private var nudgeProblem: String?
    @State private var confirming: WatchLink.ModelChoice?
    private var style: WatchStyle { WatchStyle(connection.status.theme) }
    var body: some View {
        List {
            Section {
                NavigationLink { WatchCharacterEditor(connection: connection) } label: {
                    HStack(spacing: 8) {
                        KemoFrames.image("kemo-idle", palette: connection.status.palette).resizable().scaledToFit()
                            .frame(width: 28, height: 28)
                        Text("Customize")
                    }
                }.accessibilityIdentifier("watchSettingsCustomize")
            }
            Section {
                Toggle("Read replies aloud", isOn: $readAloud).accessibilityIdentifier("watchSettingsReadAloud")
                Toggle("Nudges", isOn: Binding(get: { nudges }, set: setNudges))
                    .accessibilityIdentifier("watchSettingsNudges")
                if let nudgeProblem { Text(nudgeProblem).font(.footnote).foregroundStyle(.orange) }
            }
            if let models = connection.status.models, !models.isEmpty {
                Section("Model") {
                    ForEach(models) { choice in
                        Button {
                            if choice.destination == nil { connection.change(.model(choice.id)) } else { confirming = choice }
                        } label: {
                            row(title(choice), selected: connection.status.selectedModel == choice.id)
                        }
                    }
                }
            }
            if let problem = connection.changeProblem {
                Text(problem).font(.footnote).foregroundStyle(.orange).listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Settings")
        .containerBackground(style.background.gradient, for: .navigation)
        .sheet(item: $confirming) { choice in
            // A connected model is a separate destination: one line says where messages go before switching.
            VStack(spacing: 10) {
                Text(choice.title).font(.headline).multilineTextAlignment(.center)
                Text(choice.confirmationLine).font(.footnote).multilineTextAlignment(.center)
                    .accessibilityIdentifier("watchModelDestination")
                Button("Use") { connection.change(.model(choice.id)); confirming = nil }.tint(style.readableAccent)
                    .accessibilityIdentifier("watchModelConfirm")
            }.padding()
        }
    }
    /// Apple's on-device model is simply "Built-in" on the watch and its server model "Private Cloud";
    /// no model-family wording.
    private func title(_ choice: WatchLink.ModelChoice) -> String {
        switch choice.id {
        case WatchLink.ModelChoice.onDevice: "Built-in"
        case WatchLink.ModelChoice.privateCloud: "Private Cloud"
        default: choice.title
        }
    }
    /// Asks for notification permission only as nudges are turned on.
    private func setNudges(_ on: Bool) {
        nudges = on; nudgeProblem = nil
        WKInterfaceDevice.current().play(.click)
        Task {
            if !on { return await pet.turnOffNudges() }
            if await !pet.turnOnNudges() {
                nudges = false
                nudgeProblem = "Notifications are off."
            }
        }
    }
    private func row(_ title: String, selected: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            if selected { Image(systemName: "checkmark").foregroundStyle(style.readableAccent) }
        }
    }
}

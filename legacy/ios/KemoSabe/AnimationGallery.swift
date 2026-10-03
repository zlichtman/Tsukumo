import SwiftUI

/// Kemo's animation suite, drawn by the app's own Swift renderer.
struct AnimationGallery: View {
    var embedded = false
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @Environment(DesktopNavigation.self) private var desktop
    #endif
    private var animationActive: Bool {
        #if os(macOS)
        playing && visible && desktop.windowVisible
        #else
        playing && visible && scenePhase == .active
        #endif
    }
    @State private var group = "All"
    @State private var query = ""
    @State private var current = "idle"
    @State private var playing = true
    @State private var replay = 0
    @State private var visible = false
    private var groups: [String] { ["All"] + Performance.suite.map(\.group).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ArtworkCompanion(theme: store.state.theme, performance: current, reducedMotion: reduceMotion,
                    active: animationActive, replay: replay).frame(height: 220).frame(maxWidth: .infinity)
                HStack { Text(Performance.suite.first { $0.id == current }?.name ?? current).font(.headline); Spacer(); Button(playing ? "Pause" : "Play") { playing.toggle() }.accessibilityIdentifier("motionPause"); Button("Replay") { replay += 1; playing = true } }
                HStack {
                    TextField("Find an animation", text: $query).textFieldStyle(.roundedBorder)
                    Picker("Group", selection: $group) { ForEach(groups, id: \.self) { Text($0.capitalized).tag($0) } }.frame(maxWidth: 190).accessibilityIdentifier("motionCategory")
                }
                ForEach(Performance.suite.filter { (group == "All" || $0.group == group) && (query.isEmpty || ($0.name + $0.description).localizedCaseInsensitiveContains(query)) }) { item in
                    Button { current = item.id; replay += 1; playing = true } label: {
                        HStack { Image(systemName: current == item.id ? "play.circle.fill" : "play.circle"); Text(item.name); Spacer(); Text(item.group).font(.caption).foregroundStyle(.secondary) }.padding(.vertical, 7).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("animation-" + item.id)
                    Divider().opacity(0.5)
                }
            }.padding(24).frame(maxWidth: 760).frame(maxWidth: .infinity)
        }.navigationTitle("Animations")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { if !embedded { Button(role: .close) { dismiss() } } } }
        #endif
        .onAppear { visible = true }.onDisappear { visible = false }
    }
}

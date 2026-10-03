import SwiftUI

/// KemoSabe on Apple Watch: tap (or double tap) to talk, and Kemo answers from
/// the paired iPhone. The watch holds no memories, People data, or credentials.
/// Kemo is also a little pet here: talking feeds it (`KemoPet`).
@main struct KemoSabeWatchApp: App {
    @State private var connection = WatchConnection()
    @State private var firstRun: WatchFirstRun
    @State private var pet: KemoPet
    init() {
        // The first-run check reads the watch's settings before the pet saves its state.
        _firstRun = State(initialValue: WatchFirstRun())
        _pet = State(initialValue: KemoPet())
        KemoNudgeDelegate.shared.register()
    }
    var body: some Scene {
        WindowGroup { WatchHomeView().environment(connection).environment(pet).environment(firstRun) }
    }
}

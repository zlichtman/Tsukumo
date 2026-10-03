import AppIntents

/// The watch's Talk to Kemo Control. It opens the app, so it runs in the app's process, where
/// `WatchTalkHost` starts listening; the widget extension compiles an inert stand-in.
struct TalkFromControlIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to KemoSabe"
    static let description = IntentDescription("Opens KemoSabe listening.")
    static let supportedModes: IntentModes = .foreground
    static let isDiscoverable = false
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        WatchTalkHost.talk()
        return .result()
    }
}

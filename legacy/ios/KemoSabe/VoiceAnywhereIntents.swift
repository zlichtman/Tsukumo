import AppIntents

// Intents the widget extension also compiles, so a Control and the Live Activity's Stop button can
// name them. `AudioRecordingIntent` and `LiveActivityIntent` always run in the app's process
// (Apple: "Adding interactivity to widgets and Live Activities"); `VoiceAnywhereHost` is the app's
// real implementation there and an inert stand-in in the extension.

/// "Talk to Kemo": Kemo listens, answers through the same harness as typed chat with the selected
/// model, and reads the reply aloud, with Kemo in a Live Activity, without opening KemoSabe. From
/// the Action button, a Control (Control Center or the Lock Screen), Siri, or Shortcuts.
///
/// It starts in the background when it can; when it can't (KemoSabe is already open, a permission
/// isn't granted yet, the iPhone is locked with nothing it may use, or iOS refuses a background
/// start), it opens KemoSabe with its voice mode listening instead.
struct TalkToKemoIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Talk to KemoSabe"
    static let description = IntentDescription("KemoSabe listens, answers with your model, and reads the reply aloud, in a Live Activity.")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    /// Lets Siri hear the companion's own name ("Talk to Mochi in KemoSabe").
    @Parameter(title: "Companion") var companion: CompanionEntity?

    init() {}

    func perform() async throws -> some IntentResult {
        try await VoiceAnywhereHost.talk(self)
        return .result()
    }
}

/// Stops a turn from the Live Activity: listening is discarded, a reply stops being read aloud.
struct StopTalkingToKemoIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop KemoSabe"
    static let description = IntentDescription("Stops KemoSabe listening or reading a reply aloud.")
    static let isDiscoverable = false

    init() {}

    func perform() async throws -> some IntentResult {
        await VoiceAnywhereHost.stop()
        return .result()
    }
}

/// The companion, by the name the person gave it. App Shortcut phrases must contain the app's
/// name, so the companion's own name is a parameter of the phrase rather than the phrase itself.
struct CompanionEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Companion"
    static let defaultQuery = CompanionQuery()
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    static var current: CompanionEntity { CompanionEntity(id: "companion", name: VoiceAnywhereHost.companionName) }
}

struct CompanionQuery: EntityQuery {
    init() {}
    func entities(for identifiers: [String]) async throws -> [CompanionEntity] {
        identifiers.contains(CompanionEntity.current.id) ? [CompanionEntity.current] : []
    }
    func suggestedEntities() async throws -> [CompanionEntity] { [CompanionEntity.current] }
}

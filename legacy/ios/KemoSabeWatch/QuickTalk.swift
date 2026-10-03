import AppIntents
import Observation

/// A request from Siri, the Shortcuts app, or the Action button on Apple Watch
/// Ultra to open Kemo already listening.
@MainActor @Observable final class QuickTalk {
    enum Request: Equatable { case talk, capture }
    static let shared = QuickTalk()
    private(set) var request: Request?
    func ask(_ request: Request) { self.request = request }
    /// Returns the waiting request once, so it starts listening only once.
    func take() -> Request? { defer { request = nil }; return request }
}

/// "Talk to KemoSabe": opens Kemo listening. Assign it to the Action button on
/// Apple Watch Ultra through Shortcuts, or say it to Siri.
struct TalkToKemoIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to KemoSabe"
    static let description = IntentDescription("Opens KemoSabe listening, ready for your question.")
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult { QuickTalk.shared.ask(.talk); return .result() }
}

/// "Note for KemoSabe": opens Kemo listening for a note or task, which your
/// iPhone saves for review or adds under the permissions you've given it.
struct QuickNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Quick note or task"
    static let description = IntentDescription("Opens KemoSabe listening for a quick note or task.")
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult { QuickTalk.shared.ask(.capture); return .result() }
}

struct KemoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TalkToKemoIntent(), phrases: ["Talk to \(.applicationName)", "Ask \(.applicationName)"],
                    shortTitle: "Talk to KemoSabe", systemImageName: "mic.fill")
        AppShortcut(intent: QuickNoteIntent(), phrases: ["Note for \(.applicationName)", "Tell \(.applicationName) a task", "Add a task in \(.applicationName)"],
                    shortTitle: "Quick note", systemImageName: "square.and.pencil")
    }
}

/// Starts listening for the watch's Talk to Kemo Control (`TalkFromControlIntent`).
enum WatchTalkHost {
    @MainActor static func talk() { QuickTalk.shared.ask(.talk) }
}

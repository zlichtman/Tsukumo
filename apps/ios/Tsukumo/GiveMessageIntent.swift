import AppIntents
import Foundation
import TsukumoGate

// Messages on iPhone (ported from the old KemoSabe app's `GiveMessageToKemoSabeIntent`): iPhone apps can't
// read Messages, so a Shortcuts personal automation ("When I get a message from …", Run Immediately) gives
// KemoSabe each new message from the people the owner picks. It's kept on this iPhone only
// (`SharedMessagesStore`, in the app's folder), never synced, and read a few at a time when a bot asks.
// Nothing is kept while Messages is off in Settings, KemoSabe.

struct GiveMessageToKemoSabeIntent: AppIntent {
    static let title: LocalizedStringResource = "Give Message to KemoSabe"
    // No device name here (App Store review refused one in an intent's description before).
    static let description = IntentDescription("Keeps one message on this device so KemoSabe can answer your bots’ questions about it, like when a friend said they’re free. Use it in a Message automation. Turn on Messages in Tsukumo’s Settings, KemoSabe, first.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Sender", description: "Who sent it: the automation’s Sender.")
    var sender: String
    @Parameter(title: "Message", description: "What they wrote: the automation’s Content.")
    var text: String
    @Parameter(title: "Date", description: "When it was sent. Leave it empty for now.")
    var date: Date?

    init() {}

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: Self.give(sender: sender, text: text, date: date, folder: AppModel.defaultFolder)))
    }

    /// What the intent says back; keeps the message only while Messages is on.
    static func give(sender: String, text: String, date: Date?, folder: URL) -> String {
        let settings = (try? Data(contentsOf: folder.appendingPathComponent("sources.json")))
            .flatMap { try? JSONDecoder().decode(SourceSettings.self, from: $0) } ?? SourceSettings()
        guard settings.setting(.messages).on else {
            return "Messages is off for KemoSabe. Turn it on in Tsukumo’s Settings, KemoSabe, What KemoSabe may read. Nothing was kept."
        }
        do {
            try SharedMessagesStore(folder: folder.appendingPathComponent("shared-messages")).add(sender: sender, text: text, date: date)
            return "KemoSabe has it."
        } catch SharedMessagesStore.Failure.empty {
            return "There was no sender or message to keep."
        } catch {
            return "KemoSabe couldn’t keep that message."
        }
    }
}

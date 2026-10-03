import Foundation

/// Messages between KemoSabe on Apple Watch and the iPhone app. The watch runs
/// no model and keeps no memories: it sends a request to the paired iPhone,
/// which answers with its selected model through the same harness as typed chat
/// and sends the reply back over WatchConnectivity, between the person's own devices.
enum WatchLink {
    /// Apple publishes no WatchConnectivity message limit; clips stay well under
    /// 64 KB (20 s of 16 kHz mono AAC at 12 kbps is about 38 KB).
    static let maxAudioBytes = 60_000
    static let maxTextLength = 2000
    static let maxReplyLength = 4000
    static let maxRecordingSeconds: TimeInterval = 20
    static let replyKey = "reply"
    static let statusKey = "status"
    static let petKey = "pet"

    /// Kemo's pet game on the watch, summarized for your profile on the iPhone (the owner's
    /// instruction, September 25, 2026). Only numbers: no words from any conversation.
    struct PetSummary: Codable, Equatable, Sendable {
        var level: Int
        var xp: Int
        var streak: Int
        /// Times Kemo's food ran all the way out before you talked to it again: its "death count",
        /// though Kemo never dies; it just gets very hungry.
        var starved: Int
        var updated: Date
        /// Whether Kemo's nudges are on (the watch's own switch), shown in the iPhone's Settings → Notifications.
        var nudges: Bool?
        private static let key = "kemo.pet.summary"
        static let changed = Notification.Name("KemoPetSummaryChanged")
        /// The latest summary the watch sent, if a watch has ever sent one.
        static func saved(_ defaults: UserDefaults = .standard) -> PetSummary? {
            defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(PetSummary.self, from: $0) }
        }
        func save(_ defaults: UserDefaults = .standard) {
            defaults.set(try? JSONEncoder().encode(self), forKey: Self.key)
        }
    }

    /// Every watch-to-iPhone message. The iPhone answers each through its reply handler.
    enum Request: Codable, Equatable, Sendable {
        case ask(Ask)
        /// Asks again for an earlier request's result, in case its push didn't arrive.
        case check(UUID)
        /// A setting changed on the watch; the iPhone applies it and publishes the new status.
        case change(Setting)
    }
    /// The settings the watch can change. Everything else stays on the iPhone.
    enum Setting: Codable, Equatable, Sendable {
        /// `ModelChoice.id`. Choosing a connected model is confirmed on the watch, which shows where messages go.
        case model(String)
        /// A palette `id` from `Status.palettes`.
        case palette(String)
        /// A personality raw value; nil is the default tone.
        case personality(String?)
    }
    struct ModelChoice: Codable, Equatable, Sendable, Identifiable {
        static let onDevice = "onDevice"
        /// Apple's Private Cloud Compute: the same harness as on-device, on Apple's servers.
        static let privateCloud = "privateCloud"
        static let privateCloudLine = "Runs on Apple’s Private Cloud Compute."
        var id: String
        var title: String
        /// Where messages go, shown before switching to it; nil for Apple on-device.
        var destination: String?
        /// The one line the watch shows before switching to a model that isn't on the device.
        var confirmationLine: String {
            id == Self.privateCloud ? Self.privateCloudLine : "Sends to \(destination ?? "its server")"
        }
    }
    /// A request from the watch: typed text, or a short clip the iPhone transcribes on the device.
    struct Ask: Codable, Equatable, Sendable {
        var id = UUID()
        var text: String?
        var audio: Data?
        /// Quick capture: the words are a note or task to hand over, not a question.
        var capture: Bool?
        init(text: String) { self.text = text }
        init(audio: Data, capture: Bool = false) { self.audio = audio; self.capture = capture ? true : nil }
    }
    struct Reply: Codable, Equatable, Sendable {
        enum Status: String, Codable, Sendable { case received, answered, failed }
        var id: UUID
        var status: Status
        var text = ""
        /// What the iPhone heard in a clip, shown so the person can check it.
        var heard: String?
        /// Who answered, for example "Apple on-device".
        var model = ""
        /// The reply as the iPhone would read it aloud, without links or markup.
        var spoken: String?
        /// The answer left a draft, memory suggestion, or alarm to review on the iPhone.
        var review: Bool?
    }
    /// Latest iPhone state, delivered as application context. Fields added after
    /// build 33 are optional so either app can read the other's older messages.
    struct Status: Codable, Equatable, Sendable {
        var model: String
        var ready: Bool
        var note = ""
        /// The server a connected model sends requests to; nil for Apple on-device.
        var destination: String?
        /// Kemo's character palette on the iPhone.
        var palette: Palette?
        /// The dark variant of the iPhone's app theme, for the watch interface.
        var theme: Theme?
        /// The voice and pace the iPhone reads replies with.
        var voice: Voice?
        /// The companion's chosen name; nil means the default, KemoSabe.
        var name: String?
        /// Models the watch can switch between, and which is in use.
        var models: [ModelChoice]?
        var selectedModel: String?
        /// Palettes the watch can choose from, and the companion's personality.
        var palettes: [Palette]?
        var personality: String?
        /// Whether the iPhone has finished onboarding. Until it has, the watch's first run says to
        /// finish setup there. Nil from an iPhone build before onboarding, which counts as set up.
        var setUp: Bool?
    }
    /// Hex colors, as the iPhone stores them. `tinted` is false only for the
    /// approved Apricot palette, which the iPhone draws untinted.
    struct Palette: Codable, Equatable, Sendable {
        /// The iPhone's theme ID, so a choice on the watch can be sent back.
        var id: String?
        var name: String
        var body: String
        var accent: String
        var tinted: Bool
    }
    struct Theme: Codable, Equatable, Sendable {
        var background: String
        var foreground: String
        var accent: String
    }
    struct Voice: Codable, Equatable, Sendable {
        var identifier: String
        var language: String
        var name: String
        var rate: Float
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        return try encoder.encode(value)
    }
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try PropertyListDecoder().decode(type, from: data)
    }
    /// Why a request should not run, or nil when it may.
    static func problem(with ask: Ask) -> String? {
        if let audio = ask.audio {
            if audio.isEmpty { return "Didn't catch that. Try again." }
            return audio.count > maxAudioBytes ? "Too long. Try a shorter one." : nil
        }
        let text = (ask.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "Say something first." }
        return text.count > maxTextLength ? "Too long. Try a shorter one." : nil
    }
    /// Replies stay short enough for the watch and WatchConnectivity.
    static func trimmed(_ text: String) -> String {
        text.count > maxReplyLength ? String(text.prefix(maxReplyLength - 1)) + "…" : text
    }
}

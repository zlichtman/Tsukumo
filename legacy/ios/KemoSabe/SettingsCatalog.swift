import Foundation

/// One settings structure for the whole harness. iPhone and Mac draw their Settings
/// from this list, so a page has the same name, group, and place on both; a page
/// only one device can show says so here instead of being left out silently.
struct SettingsPage: Identifiable, Hashable {
    enum Device: Hashable { case iPhone, mac }
    let id: String
    let symbol: String
    var devices: Set<Device> = [.iPhone, .mac]
    /// Extra words the settings search should match.
    var keywords = ""
    /// Set for a page that isn't built yet: what it will do. Both devices show it as
    /// "complete later" rather than hiding the page.
    var planned: String? = nil
    var title: String { id }
    func matches(_ search: String) -> Bool {
        search.isEmpty || (id + " " + keywords).localizedCaseInsensitiveContains(search)
    }
}

enum SettingsCatalog {
    static let groups: [(name: String, pages: [SettingsPage])] = [
        // Who you are and how the app behaves. On iPhone, Account is the card at the top of Settings.
        ("Personal", [
            // Account is who you are and how you sign in; your public profile (bio, posts, friends)
            // is edited in Profile on iPhone and summarized here, so there's no separate page.
            .init(id: "Account", symbol: "person.crop.circle", keywords: "name username photo sync iCloud sign out profile apple"),
            .init(id: "General", symbol: "gearshape", keywords: "workspace menu bar sidebar version about updates"),
            .init(id: "Appearance", symbol: "sun.max", keywords: "theme fonts colors navigation"),
            .init(id: "Notifications", symbol: "bell", keywords: "alerts reply finished"),
            .init(id: "Usage", symbol: "gauge.with.dots.needle.33percent", keywords: "billing messages tokens cost")
        ]),
        // Your companion: its look, the models it thinks with, what it keeps in mind, and who it meets.
        // Shown under the companion's own name.
        (companionGroup, [
            // The companion's look, name, and voice (which voice it sounds like, pace, listening). The voice
            // models themselves are picked for the device automatically (`VoiceAuto`): there's no model choice.
            .init(id: "Companion", symbol: "pawprint", keywords: "character name palette personality kemo voice speaking pace microphone speech listening transcription captions interrupt read aloud openai whisper kokoro"),
            // One page with three tabs (`ModelsTab`): the language models, System One's fast decisions,
            // and Training, everything you train yourself. The LLM list includes your Mac's agents (`macAgents`).
            .init(id: "Models", symbol: "cpu", keywords: "language model AI API LLM Apple Intelligence on-device Private Cloud Compute connection ollama lm studio system one decisions Laya Jev TypeSafe OpenAI Decisions training train personal layer your voice cloned " + macAgents.keywords),
            .init(id: "Personalization", symbol: "sparkles", keywords: "routine memory continuity"),
            .init(id: "Nearby", symbol: "person.2.wave.2", devices: [.iPhone], keywords: "nearby people meet")
        ]),
        // What leaves the device, what comes in, and what the app may read.
        ("Data", [
            .init(id: "Privacy", symbol: "lock.shield", keywords: "data history"),
            .init(id: "Connections", symbol: "point.3.connected.trianglepath.dotted", keywords: "apps contacts calendar reminders messages location full disk access"),
            .init(id: "Import", symbol: "square.and.arrow.down", keywords: "ChatGPT Claude export memories chats",
                  planned: "Bring chats and memories over from ChatGPT or Claude exports. Imported memories will be reviewed one by one before KemoSabe can use them.")
        ]),
        ("Integrations", [
            .init(id: "Shortcuts", symbol: "square.2.layers.3d", keywords: "automations keyboard keys commands"),
            .init(id: "Tools", symbol: "puzzlepiece.extension", devices: [.mac], keywords: "plugins MCP permissions"),
            .init(id: "Computer use", symbol: "cursorarrow.rays", devices: [.mac], keywords: "control screen apps",
                  planned: "Let an agent use apps on this Mac, one app at a time, with your approval for each app."),
            .init(id: "Browser", symbol: "safari", devices: [.mac], keywords: "web pages research",
                  planned: "A built-in browser agents can read and use, kept separate from your own browser and its logins.")
        ]),
        ("Coding", [
            .init(id: "Agents", symbol: "sparkles", devices: [.mac], keywords: "coding agents codex claude gemini runtimes harness"),
            .init(id: "Editors", symbol: "app.dashed", devices: [.mac], keywords: "coding applications open in cursor xcode"),
            .init(id: "Terminal", symbol: "terminal", devices: [.mac], keywords: "shell profiles quick terminal hotkey scrollback option meta paste font colors cursor"),
            .init(id: "Git", symbol: "arrow.triangle.branch", devices: [.mac], keywords: "commit author branch"),
            .init(id: "Worktrees", symbol: "arrow.triangle.pull", devices: [.mac], keywords: "branches parallel agents",
                  planned: "Give each coding agent its own worktree, so several can work on one project without colliding."),
            .init(id: "Environments", symbol: "server.rack", devices: [.mac], keywords: "setup scripts variables",
                  planned: "Setup scripts and environment variables a project's terminals and agents start with."),
            .init(id: "Hooks", symbol: "link", devices: [.mac], keywords: "scripts events",
                  planned: "Run your own scripts when an agent starts, finishes, or asks for approval.")
        ]),
        // Archived chats is the last item, as in Codex.
        ("Archived", [
            .init(id: "Archived chats", symbol: "archivebox", devices: [.mac], keywords: "conversations history")
        ])
    ]
    /// The companion's group is headed by the companion's name ("Mochi"), which the person chooses.
    static let companionGroup = "Kemo"
    static func title(_ group: String) -> String { group == companionGroup ? CompanionIdentity.name : group }
    static func page(_ id: String) -> SettingsPage? { groups.lazy.flatMap(\.pages).first { $0.id == id } }
    /// The last section of Models → LLM on both devices: the coding agents on your Mac that chats can
    /// use. On iPhone it pairs with your Mac and shows each agent there; on the Mac it lets a paired
    /// iPhone use them, with the pairing code, the paired iPhones, keep awake, and each agent's
    /// sign-in. One entry with one name (rule 9), so both devices keep it in the same place (`MacRelayPhone.swift`, `KemoSabeRelaySettings.swift`).
    static let macAgents = (iPhone: "Agents on your Mac", mac: "Agents on your Mac",
                            keywords: "claude codex muse cursor agent agents mac iphone pair paired pairing relay remote qr code wi-fi chat keep awake")
    /// Pages that became a tab or section of another page, so older links still land somewhere.
    static let moved: [String: (page: String, tab: ModelsTab?)] = [
        "Voice": ("Companion", nil), "System One": ("Models", .systemOne), "Training": ("Models", .training), "Train Laya": ("Models", .training),
        "Your voice": ("Models", .training), "Profile": ("Account", nil),
        "Claude from iPhone": ("Models", .llm), "Use from iPhone": ("Models", .llm), macAgents.iPhone: ("Models", .llm),
        "Coding applications": ("Editors", nil), "Coding agents": ("Agents", nil), "Coding runtimes": ("Agents", nil), "Harness": ("Agents", nil),
        "Keyboard shortcuts": ("Shortcuts", nil), "About": ("General", nil)
    ]
    /// The groups this device shows, with empty groups dropped.
    static func groups(for device: SettingsPage.Device, search: String = "") -> [(name: String, pages: [SettingsPage])] {
        groups.compactMap { group in
            let pages = group.pages.filter { $0.devices.contains(device) && ($0.matches(search) || title(group.name).localizedCaseInsensitiveContains(search) || group.name.localizedCaseInsensitiveContains(search)) }
            return pages.isEmpty ? nil : (group.name, pages)
        }
    }
}

/// The tabs of the Models page, the same on iPhone and Mac (AGENTS.md rule 10). Voice isn't a tab: it
/// always uses the best models this device can run (`VoiceAuto`), and which voice the companion sounds
/// like is chosen on the Companion page.
enum ModelsTab: String, CaseIterable, Identifiable {
    case llm = "LLM", systemOne = "System One", training = "Training"
    var id: String { rawValue }
}

/// System One: the fast decision models beside the language model. The same sections, rows, and
/// order on iPhone and Mac (`SystemOneView`); each row's status is live.
enum SystemOneCatalog {
    struct Row: Identifiable {
        let title: String, detail: String, status: String
        var id: String { title }
    }
    /// Laya first, then the hosted services in the order they're asked: Jev, then OpenAI Decisions
    /// once it can be added.
    static let decisions: [Row] = [
        .init(title: "Laya", detail: "Decides on this device with Core ML: the base Laya model, a one-time download, plus your own layer once you train it. It answers only when it's sure.", status: "Download to use"),
        .init(title: "Jev", detail: "TypeSafe's hosted model, with your own key. Asked only when Laya isn't sure and the chat's privacy allows it. Gets the request's words and the choices, never your chats, memories, or People.", status: "Add your Jev key"),
        .init(title: "OpenAI Decisions", detail: "OpenAI's Decisions API is in limited preview, and OpenAI hasn't published how to call it yet. KemoSabe will add it after Jev once it does, with the same rule: only Open and Personal chats, only the request's words and the choices.", status: "In preview")
    ]
    static var openAIDecisions: Row { decisions[2] }
    /// How one decision is routed, in one line under the providers.
    static let routing = "Laya decides on this device first. When it isn't sure, Jev is asked if the chat is Open or Personal; Sensitive, Device only, and Secret chats never go to Jev or any other service. Otherwise Apple routing decides, as before. A decision only picks among choices KemoSabe already allows. It never grants a tool, a write, or a permission."
    /// Under Recent decisions, once one can be marked.
    static let marking = "Mark what Laya scored: Right, or Wrong and which choice was right. Marks stay on this device and train Laya below."
    /// Train Laya: the personal layer, built on this device from the marks.
    static let training = Row(title: "Train Laya", detail: "Train Laya builds a small personal layer on this device over Laya's answers, from the decisions you marked. It checks the layer on your newest marks, which it didn't learn from, and turns it on only if it gets at least two more of them right than Laya alone.", status: "")
    static let trainingPrivacy = "Device only: your marks and your layer stay on this device. They're never synced or uploaded, and Laya's own model isn't changed. Training takes seconds."
    /// Where Laya comes from, under its Download button.
    static let layaDownload = "From Hugging Face, pinned to exact files and checked before it's used. It stays on this device. Wi-Fi only unless you allow cellular."
}

/// Usage counted from the conversations on this device, per model. Providers bill
/// their own API use; token and cost figures need their usage reports.
enum UsageSummary {
    struct Row: Identifiable, Equatable {
        let model: String
        var chats: Int
        var sent: Int
        var replies: Int
        var id: String { model }
    }
    static func rows(archives: [ConversationArchive], current: [ChatMessage], currentModel: String) -> [Row] {
        var rows: [String: Row] = [:]
        func add(_ model: String, _ messages: [ChatMessage]) {
            guard !messages.isEmpty else { return }
            var row = rows[model] ?? Row(model: model, chats: 0, sent: 0, replies: 0)
            row.chats += 1
            row.sent += messages.filter { $0.role == "You" }.count
            row.replies += messages.filter { $0.role != "You" }.count
            rows[model] = row
        }
        archives.forEach { add($0.model, $0.messages) }
        add(currentModel, current)
        return rows.values.sorted { $0.sent == $1.sent ? $0.model < $1.model : $0.sent > $1.sent }
    }
}

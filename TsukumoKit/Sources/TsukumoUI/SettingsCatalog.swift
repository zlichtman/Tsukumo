import Foundation
import TsukumoCore

// Settings on both devices come from this one catalog (AGENTS.md rule 9): its pages, in order and with the same
// names, which device has each, and what's on them, for the search at the top of Settings. A page's own view still
// lives with its app; the catalog says where each thing is, so search finds it the same way on the Mac and iPhone.

public enum SettingsCatalog {
    public enum Device: String, Sendable { case mac, iPhone }

    /// The pages, in their order down the Mac's sidebar and the iPhone's list.
    public enum Page: String, CaseIterable, Identifiable, Sendable {
        case account, bots, models, connections, gateway, dock, general
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .account: "Account"
            case .bots: "Bots"
            case .models: "Models"
            case .connections: "Connections"
            case .gateway: "Gateway"
            case .dock: "Dock"
            case .general: "General"
            }
        }
        /// The line under the page's title.
        public var subtitle: String {
            switch self {
            case .account: "Who you are, and what goes where."
            case .bots: "KemoSabe, your bots, Muse, and the agents that ask KemoSabe."
            case .models: "What your bots run on, who answers untagged messages, and how they listen and speak."
            case .connections: "What KemoSabe may read, and how private each one is."
            case .gateway: "Let agents elsewhere ask KemoSabe, under your rules, on this Mac."
            case .dock: "How the side dock looks, and where it sits."
            case .general: "Light or dark, opening at login, this version of Tsukumo, and its updates."
            }
        }
        public var symbol: String {
            switch self {
            case .account: "person.crop.circle"
            case .bots: "person.2"
            case .models: "cpu"
            case .connections: "link"
            case .gateway: "point.3.connected.trianglepath.dotted"
            case .dock: "dock.rectangle"
            case .general: "gearshape"
            }
        }
        /// The Mac has every page; the iPhone has the ones they share.
        public var devices: Set<Device> {
            switch self {
            case .account, .bots, .models, .connections: [.mac, .iPhone]
            case .gateway, .dock, .general: [.mac]
            }
        }
        public static func pages(on device: Device) -> [Page] { allCases.filter { $0.devices.contains(device) } }
    }

    /// Models' tabs, the same on both devices.
    public enum ModelsTab: String, CaseIterable, Identifiable, Sendable {
        case llm, systemOne, voice
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .llm: "LLM"
            case .systemOne: "System One"
            case .voice: "Voice"
            }
        }
    }

    /// Something in Settings search can find: where it is, and the words it answers to.
    public struct Topic: Identifiable, Hashable, Sendable {
        public let title: String
        public let page: Page
        /// Models' tab it's on, if any.
        public let tab: ModelsTab?
        /// A service's own page under Bots.
        public let service: ServiceID?
        /// KemoSabe's own page under Bots.
        public let kemoSabeBot: Bool
        /// Adding a bot (the dock's Add a Bot on the Mac, New Bot on the iPhone).
        public let newBot: Bool
        /// What KemoSabe may read: Settings, Connections.
        public let sources: Bool
        public let keywords: [String]
        public let devices: Set<Device>
        public init(_ title: String, _ page: Page, tab: ModelsTab? = nil, service: ServiceID? = nil, kemoSabeBot: Bool = false,
                    newBot: Bool = false, sources: Bool = false, keywords: [String] = [], devices: Set<Device>? = nil) {
            self.title = title; self.page = page; self.tab = tab; self.service = service; self.kemoSabeBot = kemoSabeBot; self.newBot = newBot
            self.sources = sources
            self.keywords = keywords; self.devices = devices ?? page.devices
        }
        public var id: String { [page.rawValue, tab?.rawValue ?? "", service?.rawValue ?? "", title].joined(separator: ".") }
        /// Where it is, for the result's second line: "Models, Voice", "Bots", "Dock".
        public var location: String { [page.title, tab?.title].compactMap { $0 }.joined(separator: ", ") }
    }

    /// Everything search knows, in catalog order: each page, then what's on it.
    public static let topics: [Topic] = Page.allCases.flatMap { page in [Topic(page.title, page, keywords: [page.subtitle])] + onPage(page) }

    private static func onPage(_ page: Page) -> [Topic] {
        switch page {
        case .account:
            return [Topic("Sign in with Apple", .account, keywords: ["account", "sign in", "sign out", "apple id", "name"]),
                    Topic("Sync", .account, keywords: ["icloud", "devices", "mac", "iphone", "chats", "status"]),
                    Topic("What goes where", .account, keywords: ["privacy", "icloud", "this device", "keys", "keychain", "sync"],
                          devices: [.mac])]
        case .bots:
            return [Topic("KemoSabe", .bots, kemoSabeBot: true, keywords: ["character", "finder", "palette", "appearance", "look", "voice", "secure assistant"]),
                    Topic("Allowed bots", .bots, kemoSabeBot: true, keywords: ["kemosabe", "allowed", "consent", "grants", "revoke", "ask again"]),
                    Topic("Chirps", .bots, kemoSabeBot: true, keywords: ["kemosabe", "speaking up", "coming up", "notifications", "reminders"], devices: [.mac]),
                    Topic("Journal", .bots, kemoSabeBot: true, keywords: ["kemosabe", "history", "what was shared", "log", "audit"]),
                    Topic("Add a Bot", .bots, newBot: true, keywords: ["new bot", "make", "create", "bring in", "import", "agent", "character", "instructions", "session"]),
                    Topic("Codex pets", .bots, newBot: true, keywords: ["pet", "character", "hatch", "codex", "avatar", "seedy"], devices: [.mac]),
                    Topic("Your ChatGPT dot", .bots, newBot: true, keywords: ["dot", "leafy", "chatgpt", "openai", "codex", "bring in", "import"], devices: [.mac]),
                    Topic("Tsukumo’s Claude bot", .bots, newBot: true, keywords: ["tasks", "background", "schedule", "claude code", "goals"], devices: [.mac]),
                    Topic("Muse", .bots, service: .muse, keywords: ["meta", "pair", "pairing", "glasses", "sdk token", "bluetooth"], devices: [.mac]),
                    Topic("Agents", .bots, keywords: ["callers", "grants", "revoke", "tokens", "connected", "gateway"], devices: [.mac]),
                    Topic("Add an agent with a token", .bots, keywords: ["token", "terminal", "claude code", "codex", "coding agent"], devices: [.mac]),
                    Topic("Connected", .bots, keywords: ["chatgpt", "claude.ai", "grok", "openclaw", "connector", "gateway"], devices: [.mac]),
                    Topic("Unverified", .bots, keywords: ["callers", "gateway", "confirm", "which service", "impostor"], devices: [.mac])]
                + [ServiceID.openAI, .claude, .grok, .openClaw].map { service in
                    Topic(service.title, .bots, service: service, keywords: [service.company, service.role, "connect", "agent", "gateway"], devices: [.mac])
                }
        case .models:
            return [Topic("API models", .models, tab: .llm, keywords: ["api key", "connection", "anthropic", "openai", "endpoint", "add a model"]),
                    Topic("Coding agents", .models, tab: .llm, keywords: ["claude code", "codex", "cursor", "gemini", "installed", "cli"], devices: [.mac]),
                    Topic("Apple on-device", .models, tab: .llm, keywords: ["apple intelligence", "local", "private", "model"]),
                    Topic("System One", .models, tab: .systemOne, keywords: ["routing", "untagged", "who answers", "decisions", "laya", "cloudflare", "clef", "jev"]),
                    Topic("Recent decisions", .models, tab: .systemOne, keywords: ["right", "wrong", "marks", "personal layer", "routing"]),
                    Topic("Voice", .models, tab: .voice, keywords: ["listen", "speak", "speech", "microphone", "whisper", "kokoro", "talk", "read aloud"]),
                    Topic("Spoken replies", .models, tab: .voice, keywords: ["speak", "pace", "speed", "read aloud", "voice"]),
                    Topic("Each bot’s voice", .models, tab: .voice, keywords: ["voices", "kokoro", "apple voice", "sound"])]
        case .connections:
            return [Topic("Sources", .connections, sources: true, keywords: ["what kemosabe may read", "calendar", "contacts", "messages", "photos", "location",
                                                                           "music", "reminders", "files", "folders", "connectors", "accounts", "privacy",
                                                                           "levels", "device only", "secret", "sensitive"])]
        case .gateway:
            return [Topic("KemoSabe gateway", .gateway, keywords: ["mcp", "agents", "turn on", "local address", "port", "oauth"]),
                    Topic("Public address", .gateway, keywords: ["relay", "cloud agents", "chatgpt", "claude.ai", "grok", "internet", "url"]),
                    Topic("What agents may ask for", .gateway, keywords: ["tools", "free busy", "contacts", "files", "message excerpts", "photos"]),
                    Topic("Inbox", .gateway, keywords: ["files", "sent to you", "quarantine", "received"]),
                    Topic("Budgets", .gateway, keywords: ["limits", "allowance", "daily", "how much"]),
                    Topic("Ledger", .gateway, keywords: ["history", "what was shared", "disclosures", "audit", "log"]),
                    Topic("Waiting for you", .gateway, keywords: ["cards", "approvals", "requests", "pending"])]
        case .dock:
            return [Topic("Style", .dock, keywords: ["glass", "tinted", "solid", "minimal", "look", "color", "colour"]),
                    Topic("Size", .dock, keywords: ["tiles", "bigger", "smaller", "magnification"]),
                    Topic("Magnification", .dock, keywords: ["zoom", "hover", "size"]),
                    Topic("Position", .dock, keywords: ["edge", "left", "right", "top", "bottom", "screen", "where"]),
                    Topic("Automatically hide", .dock, keywords: ["autohide", "hide", "tuck away", "delay"]),
                    Topic("Indicators", .dock, keywords: ["dot", "ring", "running", "names on hover", "labels"]),
                    Topic("Animation and sound", .dock, keywords: ["motion", "calm", "chirp sounds", "sleep at night", "animation"]),
                    Topic("Coding bots", .dock, keywords: ["editor", "follow", "work cue", "tests"])]
        case .general:
            return [Topic("Appearance", .general, keywords: ["light", "dark", "mode", "theme", "system", "look"]),
                    Topic("Open at Login", .general, keywords: ["startup", "launch", "login items", "start"]),
                    Topic("Software Update", .general, keywords: ["update", "check for updates", "download automatically", "version", "new version"]),
                    Topic("About", .general, keywords: ["version", "build", "licenses"])]
        }
    }

    /// What matches `query` on `device`, best first: every word of the query starts a word of the topic (its title,
    /// where it is, or what it answers to), titles counting most. Case and accents don't matter.
    public static func search(_ query: String, on device: Device) -> [Topic] {
        let words = Self.words(query)
        guard !words.isEmpty else { return [] }
        let whole = fold(query).trimmingCharacters(in: .whitespacesAndNewlines)
        var ranked: [(rank: Int, order: Int, topic: Topic)] = []
        for (order, topic) in topics.enumerated() where topic.devices.contains(device) {
            let title = fold(topic.title)
            let titleWords = Self.words(topic.title)
            let all = titleWords + Self.words(topic.location) + topic.keywords.flatMap(Self.words)
            guard words.allSatisfy({ word in all.contains { $0.hasPrefix(word) } }) else { continue }
            let rank = title == whole ? 0
                : title.hasPrefix(whole) ? 1
                : words.allSatisfy({ word in titleWords.contains { $0.hasPrefix(word) } }) ? 2
                : 3
            ranked.append((rank, order, topic))
        }
        return ranked.sorted { ($0.rank, $0.order) < ($1.rank, $1.order) }.map(\.topic)
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US"))
            .replacingOccurrences(of: "’", with: "'")
    }
    static func words(_ text: String) -> [String] {
        fold(text).split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}

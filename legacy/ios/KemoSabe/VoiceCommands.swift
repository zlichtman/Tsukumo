import Foundation
import Observation

enum AppPanel: String, Identifiable {
    case settings, connections, appearance, animations, workspace, voice, history, routine, model, nearby
    var id: String { rawValue }
}

/// Shared presentation state: speaking and tapping follow the same route.
@MainActor @Observable final class AppNavigation {
    var panel: AppPanel?
    var detail: AppPanel?
    var showingThemes = false
    /// Set when the account changed while Settings was open: the rebuilt Settings opens the
    /// Account page again, so the result of signing in or out stays in view.
    var reopenAccountPage = false
    /// A tab to switch to (a notification tap: "Chat" or "Day"); the shell takes it and clears it.
    var requestedTab: String?
    var voiceBlocks: Set<String> = []
    var performance: ArtworkPerformance = .idle
    var performanceRevision = 0
    private var performanceTask: Task<Void, Never>?
    func perform(_ value: ArtworkPerformance) {
        home(); performanceTask?.cancel(); performance = value; performanceRevision += 1
        performanceTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            self?.performance = .idle
        }
    }
    func open(_ destination: AppPanel) {
        showingThemes = false
        if panel == nil { panel = destination }
        else if panel == destination { detail = nil }
        else { detail = destination }
    }
    func back() {
        if showingThemes { showingThemes = false }
        else if detail != nil { detail = nil }
        else { panel = nil }
    }
    func home() { showingThemes = false; detail = nil; panel = nil }
}

enum VoiceSetting: Equatable { case captions, patientListening, interruptions }
enum VoiceCommand: Equatable {
    case open(AppPanel), back, home, help
    case perform(ArtworkPerformance)
    case theme(String), setting(VoiceSetting, Bool), pace(Double)
    case connect(ConnectorID), disconnect(ConnectorID), connectSelected, cancel
    case agenda, reminders, contact(String), pause, goodnight, morning
    /// Runs a shortcut you've allowed in Settings under Integrations.
    case runShortcut(String)

    var requiresPrivateContext: Bool {
        switch self {
        case .agenda, .reminders, .contact, .goodnight, .morning: true
        default: false
        }
    }
    /// Bounded, explicit commands. Incidental mentions never change settings.
    /// Commands that make sense from the wrist. Opening screens or connecting
    /// apps on an iPhone in someone's pocket does not.
    var worksFromWatch: Bool {
        switch self {
        case .perform, .theme, .setting, .pace: true
        default: false
        }
    }
    static func parse(_ text: String) -> VoiceCommand? {
        let words = clean(text)
        if let performance = animation(words) { return .perform(performance) }
        let panels: [(AppPanel, [String])] = [
            (.settings, ["open settings", "show settings", "settings"]),
            (.model, ["open model", "open models", "change model", "model settings"]),
            (.nearby, ["find nearby kemos", "find other kemos", "open nearby", "nearby kemos", "meet another kemo"]),
            (.connections, ["open connections", "show connections", "connections", "open connectors", "show connectors", "connect an app", "connect something"]),
            (.appearance, ["open appearance", "show themes", "change theme", "change my theme", "open themes"]),
            (.voice, ["open voice settings", "voice settings", "change your voice"]),
            (.routine, ["open routine", "show my routine", "open my routine", "show approvals", "show my day", "open my day"]),
            (.workspace, ["open memory", "show memory", "show my memory", "open tasks", "show tasks", "show my tasks", "memory and tasks"]),
            (.animations, ["show animations", "show your animations", "show me your animations", "what animations can you do", "open animations", "open motion studio"]),
            (.history, ["show conversation history", "open conversation history"])
        ]
        for (panel, phrases) in panels where phrases.contains(words) { return .open(panel) }
        if ["goodnight", "good night", "i m going to bed", "i am going to bed"].contains(words) { return .goodnight }
        if ["good morning", "i m awake", "i am awake", "start my morning"].contains(words) { return .morning }
        if ["go back", "back", "close drawer", "close settings", "close connections"].contains(words) { return .back }
        if ["go home", "back to kemo", "back to kemosabe", "close everything"].contains(words) { return .home }
        if ["what can i say", "show voice commands", "help with voice commands"].contains(words) { return .help }
        if ["stop listening", "pause listening", "turn off voice", "turn the microphone off", "mute your microphone"].contains(words) { return .pause }
        if ["cancel", "never mind", "nevermind"].contains(words) { return .cancel }
        if ["connect", "connect it", "connect this", "allow access"].contains(words) { return .connectSelected }
        if ["what s on my calendar", "what is on my calendar", "what s on my calendar today", "what is on my calendar today", "show today s calendar", "read my calendar", "what s my schedule today"].contains(words) { return .agenda }
        if ["read my reminders", "show my reminders", "what are my reminders", "what s on my reminder list"].contains(words) { return .reminders }
        if let name = suffix(words, prefixes: ["find contact ", "find my contact ", "look up contact "]), !name.isEmpty { return .contact(name) }
        for (setting, labels) in [(VoiceSetting.captions, ["captions", "reply captions"]), (.patientListening, ["patient listening"]), (.interruptions, ["interruptions"])] {
            for label in labels {
                if ["turn on \(label)", "enable \(label)", "show \(label)"].contains(words) { return .setting(setting, true) }
                if ["turn off \(label)", "disable \(label)", "hide \(label)"].contains(words) { return .setting(setting, false) }
            }
        }
        if ["give me more time", "give me more time to finish", "wait longer before answering"].contains(words) { return .setting(.patientListening, true) }
        if words == "let me interrupt" { return .setting(.interruptions, true) }
        if ["speak slower", "talk slower", "slow down your voice"].contains(words) { return .pace(0.42) }
        if ["speak faster", "talk faster"].contains(words) { return .pace(0.54) }
        if ["speak at normal speed", "normal speaking pace"].contains(words) { return .pace(0.48) }
        if let name = suffix(words, prefixes: ["change theme to ", "change my theme to ", "set theme to ", "set my theme to ", "switch to the ", "switch to "]) {
            let candidate = name.hasSuffix(" theme") ? String(name.dropLast(6)) : name
            if !candidate.isEmpty { return .theme(candidate) }
        }
        if let name = suffix(words, prefixes: ["run shortcut ", "run the shortcut ", "run my shortcut "]), !name.isEmpty { return .runShortcut(name) }
        if let name = suffix(words, prefixes: ["run my ", "run the "]), name.hasSuffix(" shortcut"), name.count > 9 { return .runShortcut(String(name.dropLast(9))) }
        if let theme = looseTheme(words) { return .theme(theme) }
        if let performance = looseAnimation(words) { return .perform(performance) }
        if let name = suffix(words, prefixes: ["disconnect my ", "disconnect "]), let id = ConnectorID.named(name) { return .disconnect(id) }
        if let name = suffix(words, prefixes: ["connect my ", "connect ", "link my ", "link "]), let id = ConnectorID.named(name) { return .connect(id) }
        return nil
    }
    static func clean(_ text: String) -> String {
        var words = VoiceTurnPolicy.normalized(text)
        // Greetings and the companion's own name ("Hey, Mochi, do your animation") come off first.
        let name = VoiceTurnPolicy.normalized(CompanionIdentity.name)
        var names = ["kemo sabe", "kemosabe", "kemo"]
        if !name.isEmpty, !names.contains(name) { names.insert(name, at: 0) }
        for greeting in ["hey ", "hi ", "hello ", "okay ", "ok ", "yo ", ""] {
            guard let rest = names.lazy.compactMap({ n -> String? in words.hasPrefix(greeting + n + " ") ? String(words.dropFirst(greeting.count + n.count + 1)) : nil }).first else { continue }
            words = rest; break
        }
        for filler in ["hey ", "hi ", "hello ", "okay ", "ok ", "um ", "uh "] where words.hasPrefix(filler) { words.removeFirst(filler.count) }
        for _ in 0..<3 {
            guard let prefix = ["please ", "can you ", "could you ", "would you ", "will you "].first(where: { words.hasPrefix($0) }) else { break }
            words.removeFirst(prefix.count)
        }
        if words.hasSuffix(" please") { words.removeLast(7) }
        return words
    }
    private static func animation(_ words: String) -> ArtworkPerformance? {
        let direct: [String: ArtworkPerformance] = ["dance": .dance, "do a dance": .dance, "do your dance": .dance,
            "dance for me": .dance, "wave": .greeting, "wave to me": .greeting, "wave at me": .greeting,
            "play piano": .piano, "play the piano": .piano, "do your animation": .dance,
            "do an animation": .dance, "show me an animation": .dance, "show me your animation": .dance,
            "show your animation": .dance, "animate yourself": .dance, "dancing": .dance, "waving": .greeting,
            "stop the animation": .idle, "stop animating": .idle]
        if let value = direct[words] { return value }
        // Only explicitly requested performances are commands. A request to
        // write an email, or a quoted mention of dancing, still goes to chat.
        let prefixes = ["show me your ", "show your ", "do your ", "play your ", "show me the ", "show the ", "play the ", "do the ", "do a ", "play a ", "the "]
        let name = suffix(words, prefixes: prefixes) ?? words
        guard name.hasSuffix(" animation") else { return nil }
        let nameOnly = String(name.dropLast(" animation".count))
        if let value = direct[nameOnly] { return value }
        let matches = ArtworkPerformance.allCases.filter { VoiceTurnPolicy.normalized($0.rawValue) == nameOnly }
        return matches.count == 1 ? matches.first : nil
    }
    /// Short requests that name a palette or a color: "make it lavender", "go purple",
    /// "can you be pink". Anything asking to write or explain goes to the model.
    static func looseTheme(_ words: String) -> String? {
        let list = words.split(separator: " ").map(String.init)
        // It has to start as a request ("make it…", "go…"), not mention a palette in passing.
        guard list.count <= 7, !list.contains(where: contentWords.contains), !list.contains(where: negations.contains),
              let first = list.first, ["change", "switch", "make", "turn", "set", "use", "go", "be", "become"].contains(first) else { return nil }
        let palettes = BotTheme.presets.map { VoiceTurnPolicy.normalized($0.name) }
        if let named = palettes.first(where: { " \(words) ".contains(" \($0) ") }) { return named }
        return list.lazy.compactMap { colorWords[$0] }.first
    }
    /// Everyday color words and the palette each means.
    static let colorWords = ["purple": "lavender", "violet": "lavender", "green": "matcha", "pink": "rose", "blue": "sky", "brown": "cocoa",
                             "yellow": "butter", "orange": "apricot", "coral": "apricot", "red": "cherry", "gray": "graphite", "grey": "graphite",
                             "teal": "lagoon", "navy": "midnight", "white": "porcelain", "black": "ink", "mint": "pistachio"]
    /// Short requests to move: "can you dance for me", "do a little dance", "show me a wave".
    static func looseAnimation(_ words: String) -> ArtworkPerformance? {
        let list = words.split(separator: " ").map(String.init)
        guard list.count <= 6, !list.contains(where: contentWords.contains), !list.contains(where: negations.contains),
              let first = list.first, ["do", "dance", "show", "wave", "celebrate", "party", "nap", "sleep", "groove", "vibe", "jam",
                                       "stretch", "meditate", "breathe", "sip", "time", "let", "lets", "go", "take", "give"].contains(first) else { return nil }
        let moves: [(String, ArtworkPerformance)] = [("dance", .dance), ("dancing", .dance), ("wave", .greeting), ("celebrate", .done),
            ("party", .done), ("nap", .resting), ("sleep", .resting), ("groove", .groove), ("vibe", .groove), ("jam", .groove),
            ("stretch", .stretching), ("meditate", .breathing), ("breathe", .breathing), ("sip", .sipping)]
        return moves.first { list.contains($0.0) }?.1
    }
    private static let negations: Set<String> = ["don", "dont", "not", "never", "no", "stop", "said", "says", "t"]
    /// Words that make a sentence a request for content, not a command.
    private static let contentWords: Set<String> = ["write", "draft", "tell", "explain", "what", "why", "how", "who", "when", "where",
        "song", "story", "poem", "email", "about", "summarize", "list", "should", "would", "if", "mean", "means", "remember", "remind"]
    private static func suffix(_ text: String, prefixes: [String]) -> String? {
        for prefix in prefixes where text.hasPrefix(prefix) { return String(text.dropFirst(prefix.count)) }
        return nil
    }
}

enum VoiceSettingsAction {
    static func apply(_ command: VoiceCommand, to state: inout SavedState) -> String? {
        switch command {
        case .theme(let name):
            let target = name == "original" || name == "kemosabe" ? "apricot" : name
            let choices = BotTheme.presets + (state.customThemes ?? [])
            let matches = choices.filter { VoiceTurnPolicy.normalized($0.name) == target || $0.id == target }
            guard let theme = matches.first, Set(matches.map(ThemeShelf.signature)).count == 1 else { return "I couldn’t find one matching palette. Choose one in Appearance." }
            state.theme = theme
            return "\(theme.name) theme."
        case .pace(let rate):
            state.speechRate = min(0.56, max(0.40, rate))
            return rate < 0.46 ? "I’ll speak a little slower." : rate > 0.50 ? "I’ll speak a little faster." : "Back to a natural pace."
        case .setting(let setting, let enabled):
            switch setting {
            case .captions: state.captionsEnabled = enabled; return enabled ? "Reply captions on." : "Reply captions off. Your words will still appear."
            case .patientListening: state.patientListening = enabled; return enabled ? "I’ll leave more time before answering." : "Back to the usual pause."
            case .interruptions: state.voiceInterruptions = enabled; return enabled ? "You can interrupt when your audio route supports it." : "Voice interruptions off."
            }
        default: return nil
        }
    }
}

/// Speech often mishears Kemo's name ("He Kyun Sabi", "Kimo Sabi"). A leading
/// greeting plus a name that sounds like it is dropped, so the model and the
/// command parser see the request itself.
enum WakeName {
    static func stripped(_ text: String) -> String {
        let pattern = #"^\s*(?:(?:hey|hi|he|hay|a|okay|ok)[\s,]+)?(?:k[a-z]{1,5}[\s-]?s[aeiou][bpv][a-z]{0,2}|kemo|kimo|chemo)\b[\s,.!?:;-]*"#
        let custom = CompanionIdentity.spokenName.map { #"|"# + NSRegularExpression.escapedPattern(for: $0) } ?? ""
        let named = pattern.replacingOccurrences(of: "|kemo|kimo|chemo)", with: "|kemo|kimo|chemo" + custom + ")")
        guard let regex = try? NSRegularExpression(pattern: named, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return text }
        let rest = String(text[range.upperBound...])
        guard !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        return rest.prefix(1).uppercased() + rest.dropFirst()
    }
}

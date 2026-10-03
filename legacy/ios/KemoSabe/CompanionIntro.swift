import Foundation

/// The first conversation, the way Muse does it: the companion starts the chat,
/// asks what to call it, then offers a new look and a way of talking. Replies are
/// read on the device; nothing here goes to a model. Every answer can be skipped.
enum CompanionIntro {
    enum Step: String { case name, look, personality }
    static let stepKey = "kemo.intro.step"

    nonisolated static var step: Step? {
        get { AccountDirectory.accountSettings.string(forKey: stepKey).flatMap(Step.init(rawValue:)) }
        set { AccountDirectory.accountSettings.set(newValue?.rawValue, forKey: stepKey) }
    }

    static let opening = "Hi, I'm your new companion! What would you like to call me? KemoSabe is fine too."
    static func lookQuestion(_ name: String) -> String {
        "\(name) it is! Want to change how I look? Say a color like lavender or blue, pick one below, or keep this look."
    }
    static let personalityQuestion = "How should I talk with you: warm, playful, calm, or direct?"
    static func finished(_ name: String) -> String {
        "All set. I'm \(name). You can change any of this in Settings → Companion. What's on your mind?"
    }

    /// Suggestions shown above the composer for each step.
    static func choices(for step: Step) -> [String] {
        switch step {
        case .name: CompanionIdentity.suggestions.prefix(6).map { $0 }
        case .look: ["Keep this look"] + ["Lavender", "Sky", "Matcha", "Rose", "Cocoa", "Graphite"]
        case .personality: CompanionPersonality.allCases.map(\.title) + ["Skip"]
        }
    }

    // MARK: Reading replies

    private static let keepWords: Set<String> = ["keep", "keep it", "keep that", "keep this", "no", "nope", "skip", "fine", "that's fine",
        "thats fine", "it's fine", "its fine", "same", "no change", "don't change", "dont change", "leave it", "keep this look", "keep the look"]
    private static let namePrefixes = ["i'll call you", "ill call you", "i will call you", "i'd like to call you", "id like to call you",
        "i want to call you", "let's call you", "lets call you", "call you", "call yourself", "your name is", "your name's", "your names",
        "you're", "youre", "you are", "how about", "let's go with", "lets go with", "go with", "name you", "be called", "maybe", "um", "hmm", "call it"]

    /// The name in a reply like "Mochi", "call you Mochi!", or "keep KemoSabe". Nil when the reply isn't a name.
    static func name(from reply: String) -> String? {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;:\"'“”‘’ "))
        let lower = text.lowercased()
        if keepWords.contains(lower) || lower.hasPrefix("keep ") && lower.contains("kemo") { return CompanionIdentity.defaultName }
        var changed = true
        while changed {
            changed = false
            for prefix in namePrefixes where text.lowercased().hasPrefix(prefix + " ") {
                text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;:\"'“”‘’ "))
        let words = text.split(separator: " ")
        guard !words.isEmpty, words.count <= 3, text.count <= CompanionIdentity.maxLength,
              text.allSatisfy({ $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "'" }) else { return nil }
        // "mochi" → "Mochi"; names the person capitalized themselves stay as typed.
        if text == text.lowercased() { text = words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ") }
        return CompanionIdentity.clean(text)
    }

    enum LookAnswer: Equatable { case keep, theme(BotTheme), unclear }
    static func look(from reply: String, themes: [BotTheme] = ThemeShelf.visible) -> LookAnswer {
        let words = VoiceTurnPolicy.normalized(reply)
        if keepWords.contains(words) || words.hasPrefix("keep") { return .keep }
        if let named = themes.first(where: { " \(words) ".contains(" \(VoiceTurnPolicy.normalized($0.name)) ") }) { return .theme(named) }
        if let id = words.split(separator: " ").lazy.compactMap({ VoiceCommand.colorWords[String($0)] }).first,
           let theme = themes.first(where: { $0.id == id }) { return .theme(theme) }
        return .unclear
    }

    enum PersonalityAnswer: Equatable { case skip, personality(CompanionPersonality), unclear }
    static func personality(from reply: String) -> PersonalityAnswer {
        let words = VoiceTurnPolicy.normalized(reply)
        if keepWords.contains(words) || words == "whatever" || words == "any" { return .skip }
        if let match = CompanionPersonality.allCases.first(where: { " \(words) ".contains(" \($0.rawValue) ") }) { return .personality(match) }
        let synonyms: [String: CompanionPersonality] = ["kind": .warm, "friendly": .warm, "nice": .warm, "funny": .playful, "fun": .playful,
            "silly": .playful, "chill": .calm, "relaxed": .calm, "gentle": .calm, "short": .direct, "brief": .direct, "straight": .direct, "blunt": .direct]
        if let match = words.split(separator: " ").lazy.compactMap({ synonyms[String($0)] }).first { return .personality(match) }
        return .unclear
    }
}

extension AppStore {
    /// Starts the intro in a fresh conversation; an existing one is saved to the list first.
    func beginCompanionIntro() {
        guard CompanionIntro.step == nil else { return }
        if !conversationMessages.isEmpty { newConversation() }
        CompanionIntro.step = .name
        appendVisibleMessage(role: "KemoSabe", text: CompanionIntro.opening)
    }
    /// Answers the person's reply to the current intro question. Returns false when the intro isn't running.
    @discardableResult func answerCompanionIntro(_ reply: String) -> Bool {
        guard let step = CompanionIntro.step else { return false }
        let reply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { return true }
        appendVisibleMessage(role: "You", text: reply)
        switch step {
        case .name:
            guard let name = CompanionIntro.name(from: reply) else {
                appendVisibleMessage(role: "KemoSabe", text: "Just the name, like Mochi or Pip? Or say keep KemoSabe.")
                return true
            }
            CompanionIdentity.set(name)
            CompanionIntro.step = .look
            appendVisibleMessage(role: "KemoSabe", text: CompanionIntro.lookQuestion(name))
        case .look:
            switch CompanionIntro.look(from: reply) {
            case .unclear:
                appendVisibleMessage(role: "KemoSabe", text: "I didn't catch a color. Try lavender, sky, matcha, or rose, or say keep this look.")
                return true
            case .keep:
                appendVisibleMessage(role: "KemoSabe", text: "Keeping this look.")
            case .theme(let theme):
                state.theme = theme; save()
                appendVisibleMessage(role: "KemoSabe", text: "Ooh, \(theme.name). How do I look?")
            }
            CompanionIntro.step = .personality
            appendVisibleMessage(role: "KemoSabe", text: CompanionIntro.personalityQuestion)
        case .personality:
            switch CompanionIntro.personality(from: reply) {
            case .unclear:
                appendVisibleMessage(role: "KemoSabe", text: "Pick warm, playful, calm, or direct, or say skip.")
                return true
            case .skip: CompanionIdentity.setPersonality(nil)
            case .personality(let personality): CompanionIdentity.setPersonality(personality)
            }
            CompanionIntro.step = nil
            // Keep the choices as a saved character, so switching back is one tap.
            let character = CompanionCharacter(name: CompanionIdentity.name, theme: state.theme, personality: CompanionIdentity.personality)
            CompanionCharacters.save(CompanionCharacters.upsert(character, into: CompanionCharacters.load()))
            appendVisibleMessage(role: "KemoSabe", text: CompanionIntro.finished(CompanionIdentity.name))
        }
        return true
    }
}

import Foundation

/// Whether a message asks for an action, not just mentions one. Kemo is a chatbot first: it
/// proposes a memory, alarm, draft, or day plan only when the message asks for one.
///
/// A request is a clause that starts with the action, after a greeting and a polite opener
/// ("remind me at 7", "can you draft…", "please remember that…", "…, remember that"). A question
/// that only contains the words is answered: "Can you reuse a coffee filter that has been out"
/// came back as "Prepared for review." (September 25, 2026), and "should I write…?", "can you
/// remind me what X means", or "what time is it in Tokyo" are questions too.
///
/// `ConversationRouting.guarded` uses this before any change is prepared, and `PlanValidator`
/// uses it again on every proposal, so the two can't disagree.
enum ExplicitRequest {
    static func allows(_ kind: PlanAction, in message: String) -> Bool {
        clauses(message).contains { clause in
            switch kind {
            case .remember: asksToRemember(clause)
            case .alarm: asksForAlarm(clause)
            case .draft: asksForDraft(clause)
            }
        }
    }
    /// Planning time for tasks, reminders, or moving Kemo's blocks: the words have to be about the day.
    static func asksToPlanDay(_ message: String) -> Bool {
        clauses(message).contains { clause in
            if starts(clause.words, ["remind", "me"]) { return !remindsAsQuestion(clause.words) }
            return clause.all.contains { dayWords.contains($0) } || dayPhrases.contains { contains(clause.all, $0) }
        }
    }
    /// A stated timing preference ("I usually work out in the evening", "actually, mornings are better").
    /// A question about one isn't a correction.
    static func statesRoutinePreference(_ message: String) -> Bool {
        let statements = clauses(message).filter { !$0.question || $0.polite }
        let tokens = statements.flatMap(\.all)
        let prefers = tokens.contains { preferenceWords.contains($0) } || preferencePhrases.contains { contains(tokens, $0) }
        let timed = tokens.contains { timeWords.contains($0) || $0.contains(where: \.isNumber) }
        return prefers && timed
    }

    // MARK: Clauses

    struct Clause: Equatable {
        /// Every word of the clause, normalized.
        var all: [String]
        /// The words after a greeting and a polite opener ("hey", "can you", "please").
        var words: [String]
        /// Asked as a question (a "?" or a question word first), not a request.
        var question: Bool
        /// Started with a polite opener, so "Can you set an alarm?" is still a request.
        var polite: Bool
    }
    /// Splits at sentence and clause punctuation and at "and", "then", "so", "but", and "also".
    static func clauses(_ message: String) -> [Clause] {
        var sentences: [(pieces: [String], question: Bool)] = []
        var pieces: [String] = [], piece = ""
        for character in WakeName.stripped(message) {
            switch character {
            case ",", ";", ":": pieces.append(piece); piece = ""
            case ".", "!", "?", "\n":
                pieces.append(piece); piece = ""
                sentences.append((pieces, character == "?")); pieces = []
            default: piece.append(character)
            }
        }
        pieces.append(piece); sentences.append((pieces, false))
        var result: [Clause] = []
        for sentence in sentences {
            for text in sentence.pieces {
                var run: [String] = []
                for token in VoiceTurnPolicy.normalized(text).split(separator: " ").map(String.init) + ["and"] {
                    if connectors.contains(token) {
                        if !run.isEmpty { result.append(clause(run, question: sentence.question)) }
                        run = []
                    } else { run.append(token) }
                }
            }
        }
        return result
    }
    private static func clause(_ all: [String], question asked: Bool) -> Clause {
        var words = all, polite = false, changed = true
        while changed {
            changed = false
            while let first = words.first, fillers.contains(first) { words.removeFirst(); changed = true }
            if let opener = openers.first(where: { starts(words, $0) }) {
                words.removeFirst(opener.count); polite = true; changed = true
            }
        }
        let questionFirst: Bool = {
            guard let first = words.first else { return false }
            if questionWords.contains(first) { return true }
            // "Do you…", "Should I…", "Is it…" ask; "Do my standup" asks for something.
            guard auxiliaries.contains(first), words.count > 1 else { return false }
            return first == "do" ? pronouns.contains(words[1]) : subjects.contains(words[1])
        }()
        return Clause(all: all, words: words, question: !polite && (asked || questionFirst), polite: polite)
    }

    // MARK: Kinds

    private static func asksToRemember(_ clause: Clause) -> Bool {
        let words = clause.words
        if starts(words, ["remind", "me"]) { return !remindsAsQuestion(words) }
        if starts(words, ["remember"]) {
            if clause.question { return false }
            if words.count > 1, ["when", "how", "what", "who", "whether", "if", "where", "why"].contains(words[1]) { return false }
            return true
        }
        if rememberPhrases.contains(where: { starts(words, $0) }) { return true }
        return asksForReminderItem(clause)
    }
    private static func asksForAlarm(_ clause: Clause) -> Bool {
        let words = clause.words
        if starts(words, ["remind", "me"]) { return !remindsAsQuestion(words) }
        if alarmPhrases.contains(where: { starts(words, $0) }) { return true }
        return asksForReminderItem(clause)
    }
    /// "Set an alarm", "add a reminder", "I need a timer", "an alarm at 6".
    private static func asksForReminderItem(_ clause: Clause) -> Bool {
        guard !clause.question else { return false }
        var words = clause.words
        if words.first == "i" { words.removeFirst() }
        guard let first = words.first else { return false }
        let items: Set = ["alarm", "alarms", "timer", "timers", "reminder", "reminders"]
        if ["a", "an", "my"].contains(first) { return words.count > 1 && items.contains(words[1]) }
        let asks: Set = ["set", "add", "create", "make", "start", "schedule", "put", "need", "want", "give", "get", "d", "would"]
        return asks.contains(first) && words.dropFirst().prefix(4).contains { items.contains($0) }
    }
    private static func asksForDraft(_ clause: Clause) -> Bool {
        guard !clause.question else { return false }
        var words = clause.words
        guard let first = words.first else { return false }
        if draftVerbs.contains(first) { return true }
        if first == "prepare" { return !(words.dropFirst().first == "for" || starts(Array(words.dropFirst()), ["me", "for"])) }
        if ContextRelevance.needsStandup(words.joined(separator: " ")) { return true }
        if words.first == "i" { words.removeFirst() }
        let asks: [[String]] = [["need"], ["want"], ["d", "like"], ["would", "like"], ["give", "me"], ["make", "me"], ["get", "me"], ["send", "me"]]
        let rest: ArraySlice<String>
        if let ask = asks.first(where: { starts(words, $0) }) { rest = words.dropFirst(ask.count) }
        else if clause.polite, let lead = words.first, ["a", "an", "the", "my"].contains(lead) { rest = words[...] }
        else { return false }
        return rest.prefix(4).contains { draftNouns.contains($0) }
    }
    /// "Remind me what X means", "remind me again who…": a question, not a reminder.
    static func remindsAsQuestion(_ words: [String]) -> Bool {
        guard starts(words, ["remind", "me"]) else { return false }
        var rest = words.dropFirst(2)
        if rest.first == "again" { rest = rest.dropFirst() }
        guard let next = rest.first else { return false }
        return ["what", "whats", "who", "whos", "why", "how", "which", "whether", "if", "of", "where", "wheres"].contains(next)
    }

    // MARK: Words

    private static func starts(_ words: [String], _ prefix: [String]) -> Bool {
        words.count >= prefix.count && Array(words.prefix(prefix.count)) == prefix
    }
    private static func contains(_ words: [String], _ phrase: [String]) -> Bool {
        guard words.count >= phrase.count else { return false }
        return (0...(words.count - phrase.count)).contains { Array(words[$0..<($0 + phrase.count)]) == phrase }
    }
    private static let connectors: Set = ["and", "then", "so", "but", "also", "plus"]
    private static let fillers: Set = ["hey", "hi", "hello", "ok", "okay", "so", "um", "umm", "uh", "oh", "well", "please", "pls",
                                       "kemo", "kemosabe", "yo", "alright", "now", "actually", "just", "quick", "quickly",
                                       "yes", "yeah", "yep", "no", "sure", "hmm"]
    private static let openers: [[String]] = [
        ["would", "you", "mind"], ["can", "you"], ["could", "you"], ["would", "you"], ["will", "you"], ["can", "u"], ["could", "u"],
        ["i", "want", "you", "to"], ["i", "need", "you", "to"], ["i", "d", "like", "you", "to"], ["id", "like", "you", "to"],
        ["i", "would", "like", "you", "to"], ["go", "ahead", "and"], ["help", "me"], ["let", "s"], ["lets"],
        ["make", "sure", "to"], ["make", "sure", "you"], ["be", "sure", "to"],
        ["can", "i", "get"], ["could", "i", "get"], ["can", "i", "have"], ["could", "i", "have"], ["may", "i", "have"],
    ]
    private static let questionWords: Set = ["what", "whats", "when", "where", "wheres", "who", "whos", "why", "how", "hows", "which", "whether"]
    private static let auxiliaries: Set = ["do", "does", "did", "is", "are", "was", "were", "should", "shall", "would", "will",
                                           "can", "could", "may", "might", "am", "have", "has", "had", "isn", "aren", "doesn", "didn"]
    private static let pronouns: Set = ["i", "you", "u", "we", "they", "he", "she", "it", "anyone", "someone", "people"]
    private static let subjects: Set = ["i", "you", "u", "we", "they", "he", "she", "it", "my", "your", "this", "that", "these",
                                        "those", "there", "the", "a", "an", "anyone", "someone", "people"]
    private static let rememberPhrases: [[String]] = [
        ["don", "t", "forget"], ["dont", "forget"], ["do", "not", "forget"], ["don", "t", "let", "me", "forget"], ["dont", "let", "me", "forget"],
        ["keep", "in", "mind"], ["note", "that"], ["note", "this"], ["note", "down"], ["make", "a", "note"], ["take", "a", "note"],
        ["jot", "down"], ["jot", "this"], ["jot", "that"], ["save", "that"], ["save", "this"], ["save", "it"], ["memorize"],
        ["add", "to", "memory"], ["add", "this", "to"], ["add", "that", "to"], ["put", "that", "in"], ["put", "this", "in"],
        ["i", "need", "to", "remember"], ["i", "have", "to", "remember"], ["i", "must", "remember"], ["i", "gotta", "remember"],
    ]
    private static let alarmPhrases: [[String]] = [
        ["wake", "me"], ["get", "me", "up"], ["alarm"], ["timer"], ["don", "t", "let", "me", "forget"], ["dont", "let", "me", "forget"],
        ["i", "need", "to", "wake"], ["i", "have", "to", "wake"], ["i", "need", "to", "be", "up"],
    ]
    private static let draftVerbs: Set = ["draft", "write", "rewrite", "compose", "email", "reply", "respond", "text", "message",
                                          "dm", "post", "tweet", "caption", "outline"]
    private static let draftNouns: Set = ["draft", "email", "reply", "letter", "message", "note", "post", "caption", "standup", "bio",
                                          "response", "text", "toast", "speech", "tweet", "invitation", "invite", "announcement", "cover"]
    private static let dayWords: Set = ["plan", "planning", "schedule", "reschedule", "reminder", "reminders", "todo", "todos",
                                        "errands", "task", "tasks", "agenda", "calendar", "block", "blocks", "move", "push",
                                        "today", "tomorrow", "tonight", "morning", "afternoon", "evening", "week", "weekend"]
    private static let dayPhrases: [[String]] = [["make", "time"], ["find", "time"], ["fit", "in"], ["to", "do"], ["my", "day"]]
    private static let preferenceWords: Set = ["usually", "normally", "typically", "generally", "prefer", "prefers", "preferred",
                                               "preference", "rather", "routine", "instead", "actually", "earlier", "later", "better"]
    private static let preferencePhrases: [[String]] = [["like", "to"], ["tend", "to"], ["works", "better"], ["suits", "me"]]
    private static let timeWords: Set = ["morning", "mornings", "afternoon", "afternoons", "evening", "evenings", "night", "nights",
                                         "noon", "midnight", "am", "pm", "early", "earlier", "late", "later", "bedtime", "bed",
                                         "wake", "woke", "waking", "sleep", "asleep", "lunch", "breakfast", "dinner", "clock"]
}

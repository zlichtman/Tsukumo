import Foundation

/// Suggests the saved conversation a draft belongs with, on the device, from the
/// words the draft shares with each conversation. It only suggests: the person
/// taps to continue there, and nothing is moved or sent without that tap.
enum ConversationSuggestions {
    /// The best saved conversation for this draft, or nil when the draft fits the
    /// current conversation or nothing matches clearly enough.
    static func suggestion(for draft: String, current: [ChatMessage], saved: [ConversationArchive]) -> ConversationArchive? {
        let wanted = words(draft)
        guard wanted.count >= 2, !saved.isEmpty else { return nil }
        let documents = saved.map { words($0.messages.map(\.text).joined(separator: " ")) }
        let currentWords = words(current.map(\.text).joined(separator: " "))
        // Rarer shared words say more about a topic than common ones.
        let count = Double(documents.count + 1)
        func weight(_ word: String) -> Double {
            let frequency = Double(documents.filter { $0.contains(word) }.count + (currentWords.contains(word) ? 1 : 0))
            return log((count + 1) / (frequency + 1)) + 1
        }
        func score(_ document: Set<String>) -> (value: Double, shared: Int) {
            let shared = wanted.intersection(document)
            return (shared.reduce(0) { $0 + weight($1) }, shared.count)
        }
        let ranked = zip(saved, documents).map { (archive: $0, score: score($1)) }
            .filter { $0.score.shared >= 2 }
            .sorted { $0.score.value > $1.score.value }
        guard let best = ranked.first, best.score.value >= 3.5 else { return nil }
        // Stay put when the current conversation is about this too.
        if !current.isEmpty, score(currentWords).value >= best.score.value * 0.6 { return nil }
        // Two saved conversations that match equally well are not a clear suggestion.
        if ranked.count > 1, ranked[1].score.value >= best.score.value * 0.9 { return nil }
        return best.archive
    }

    /// Lowercased content words, without common words or plural endings.
    static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).compactMap { word in
            guard word.count >= 3, !stopWords.contains(word), !word.allSatisfy(\.isNumber) else { return nil }
            return word.count > 4 && word.hasSuffix("s") && !word.hasSuffix("ss") ? String(word.dropLast()) : word
        })
    }
    private static let stopWords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "your", "yours", "all", "any", "can", "had", "her", "was", "one", "our",
        "out", "day", "get", "has", "him", "his", "how", "man", "new", "now", "old", "see", "two", "way", "who", "did", "its",
        "let", "put", "say", "she", "too", "use", "that", "with", "have", "this", "will", "from", "they", "know", "want", "been",
        "good", "much", "some", "time", "very", "when", "come", "here", "just", "like", "long", "make", "many", "more", "only",
        "over", "such", "take", "than", "them", "well", "were", "what", "about", "would", "there", "their", "which", "could",
        "other", "these", "then", "into", "also", "should", "because", "does", "doing", "done", "please", "thanks", "thank",
        "kemo", "kemosabe", "tell", "give", "need", "help", "maybe", "really", "think", "going", "something", "anything",
        "today", "tomorrow", "yesterday", "okay", "sure", "yes", "yeah", "why", "where", "again", "still", "most", "each",
        "every", "same", "onto", "after", "before", "while",
    ]
}

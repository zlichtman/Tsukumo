import Foundation
import AVFoundation

/// Pure decisions shared by the live conversation controller and its tests.
enum VoiceTurnPolicy {
    static func containsName(_ text: String) -> Bool {
        if text.range(of: #"\b(kemosabe|kemo\s+sabe|kemo)\b"#, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        guard let name = CompanionIdentity.spokenName else { return false }
        return text.range(of: "\\b" + NSRegularExpression.escapedPattern(for: name) + "\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }
    static func isPauseCommand(_ text: String) -> Bool {
        ["stop listening", "pause listening", "kemosabe stop listening", "kemosabe pause listening", "kemo sabe stop listening", "kemo sabe pause listening"].contains(normalized(text))
    }
    static func normalized(_ text: String) -> String {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
    static func endDelay(for text: String, patient: Bool) -> Double {
        if patient { return 1.7 }
        let words = normalized(text).split(separator: " ")
        if let last = words.last, ["and", "but", "because", "so", "to", "the", "a", "an", "or", "with", "if", "your", "my", "do", "can", "could", "you"].contains(String(last)) { return 1.5 }
        return text.last.map { ".?!".contains($0) } == true ? 0.75 : 1.05
    }
    static func interruption(_ text: String, spoken: String) -> Bool {
        let heard = normalized(text), reply = normalized(spoken)
        guard !heard.isEmpty else { return false }
        // Do not treat the synthesizer's own words as an interruption.
        if !reply.isEmpty, reply.contains(heard) { return false }
        return containsName(text) || isPauseCommand(text) || ["stop", "wait", "hold on", "stop talking"].contains(heard)
    }
    /// Only release complete sentences. The unfinished tail stays buffered.
    static func stablePrefix(_ text: String, final: Bool) -> String {
        if final { return text }
        var boundary = text.startIndex
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let next = text.index(after: cursor)
            if ".!?".contains(text[cursor]), next < text.endIndex, text[next].isWhitespace {
                let prefix = String(text[..<next])
                let word = prefix.split(separator: " ").last?.lowercased() ?? ""
                if !["dr.", "mr.", "mrs.", "ms.", "e.g.", "i.e.", "vs."].contains(String(word)) { boundary = next }
            }
            cursor = next
        }
        return String(text[..<boundary])
    }
}

enum VoiceCatalog {
    struct Option: Equatable {
        enum Quality: Int, Equatable {
            case standard = 0
            case enhanced = 1
            case premium = 2

            var title: String {
                switch self {
                case .standard: return "Standard"
                case .enhanced: return "Enhanced"
                case .premium: return "Premium"
                }
            }
        }

        let identifier: String
        let name: String
        let language: String
        let quality: Quality
        let isNovelty: Bool
        let isPersonal: Bool
    }

    static var available: [AVSpeechSynthesisVoice] {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let byIdentifier = Dictionary(uniqueKeysWithValues: voices.map { ($0.identifier, $0) })
        let options = voices.map(option)
        let systemDefault = AVSpeechSynthesisVoice(language: preferredEnglishLanguage)?.identifier
        return ranked(options, preferredLanguage: preferredEnglishLanguage, systemDefaultIdentifier: systemDefault)
            .compactMap { byIdentifier[$0.identifier] }
    }

    static func selected(_ id: String?) -> AVSpeechSynthesisVoice? {
        selected(id, from: available)
    }

    static func selected(_ id: String?, from voices: [AVSpeechSynthesisVoice]) -> AVSpeechSynthesisVoice? {
        voices.first { $0.identifier == id } ?? voices.first ?? AVSpeechSynthesisVoice(language: preferredEnglishLanguage)
    }

    static func contains(_ id: String?, in voices: [AVSpeechSynthesisVoice]) -> Bool {
        guard let id else { return true }
        return voices.contains { $0.identifier == id }
    }

    static func quality(_ voice: AVSpeechSynthesisVoice) -> String {
        option(voice).quality.title
    }

    static func hasDownloadedHighQualityVoice(in voices: [AVSpeechSynthesisVoice]) -> Bool {
        voices.contains { $0.quality == .enhanced || $0.quality == .premium }
    }

    static func rate(_ value: Double?) -> Float { Float(min(0.56, max(0.40, value ?? 0.48))) }

    /// Creates the exact utterance shape used for both live replies and local auditions.
    static func utterance(for text: String, voiceID: String?, rate value: Double?) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: SpeechText.prepared(text))
        utterance.voice = selected(voiceID)
        utterance.rate = rate(value)
        utterance.pitchMultiplier = 1
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0
        return utterance
    }

    static func ranked(
        _ options: [Option],
        preferredLanguage: String,
        systemDefaultIdentifier: String?
    ) -> [Option] {
        options.filter {
            languageCode($0.language) == "en" && !$0.isNovelty && !$0.isPersonal
        }.sorted { lhs, rhs in
            if lhs.quality != rhs.quality { return lhs.quality.rawValue > rhs.quality.rawValue }
            let lhsLocale = localeScore(lhs.language, preferred: preferredLanguage)
            let rhsLocale = localeScore(rhs.language, preferred: preferredLanguage)
            if lhsLocale != rhsLocale { return lhsLocale > rhsLocale }
            if (lhs.identifier == systemDefaultIdentifier) != (rhs.identifier == systemDefaultIdentifier) {
                return lhs.identifier == systemDefaultIdentifier
            }
            let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.identifier < rhs.identifier
        }
    }

    static func selectedIdentifier(_ id: String?, from options: [Option]) -> String? {
        options.first { $0.identifier == id }?.identifier ?? options.first?.identifier
    }

    private static var preferredEnglishLanguage: String {
        Locale.preferredLanguages.first { languageCode($0) == "en" } ?? "en-US"
    }

    private static func option(_ voice: AVSpeechSynthesisVoice) -> Option {
        let quality: Option.Quality
        switch voice.quality {
        case .premium: quality = .premium
        case .enhanced: quality = .enhanced
        default: quality = .standard
        }
        return Option(
            identifier: voice.identifier,
            name: voice.name,
            language: voice.language,
            quality: quality,
            isNovelty: voice.voiceTraits.contains(.isNoveltyVoice),
            isPersonal: voice.voiceTraits.contains(.isPersonalVoice)
        )
    }

    private static func languageCode(_ identifier: String) -> String {
        if let code = Locale.Language(identifier: identifier).languageCode?.identifier {
            return code.lowercased()
        }
        return identifier.replacingOccurrences(of: "_", with: "-")
            .split(separator: "-", maxSplits: 1)
            .first.map { String($0).lowercased() } ?? ""
    }

    private static func localeScore(_ language: String, preferred: String) -> Int {
        guard languageCode(language) == languageCode(preferred) else { return 0 }
        let voiceRegion = Locale.Language(identifier: language).region?.identifier.lowercased()
        let preferredRegion = Locale.Language(identifier: preferred).region?.identifier.lowercased()
        if let voiceRegion, let preferredRegion, voiceRegion == preferredRegion { return 2 }
        return 1
    }
}

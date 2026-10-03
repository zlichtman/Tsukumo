import CryptoKit
import Foundation

/// Deleting a chat also forgets the continuity notes taken from it. Notes are matched by a
/// digest of the text they were taken from, so a pending deletion never keeps the deleted words.
enum ContextForgetting {
    /// Forget every note taken from conversations, for "delete all conversations".
    static let everything = "*"
    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(String(text.prefix(300)).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    /// Digests for the messages you wrote; replies are never observed.
    static func digests(_ messages: [ChatMessage]) -> [String] {
        messages.filter { $0.role == "You" }.map { digest($0.text) }
    }
}

/// Durable continuity, not an infinitely growing prompt or a polling model.
/// Observations remain attributed to the person who supplied them. Timing
/// hypotheses never become permissions, verified facts, or measured sleep.
struct ContinuousContext: Codable, Equatable {
    struct Observation: Codable, Identifiable, Equatable {
        enum Kind: String, Codable { case conversation, reportedBedtime, reportedWake }
        let id: UUID
        let kind: Kind
        let at: Date
        let timeZone: String
        let text: String
    }
    var learning = true
    var observations: [Observation] = []
    mutating func observe(id: UUID = UUID(), kind: Observation.Kind, text: String, at: Date, timeZone: TimeZone = .current) {
        guard learning, !observations.contains(where: { $0.id == id }) else { return }
        observations.append(.init(id: id, kind: kind, at: at, timeZone: timeZone.identifier, text: String(text.prefix(300))))
        // Late-arriving observations must not erase newer observations. Reads
        // still exclude future dates relative to the actual request clock.
        compact(now: max(at, observations.map(\.at).max() ?? at))
    }
    mutating func compact(now: Date) {
        observations = Array(observations.filter { (0...30*86400).contains(now.timeIntervalSince($0.at)) }.suffix(128))
    }
    func workingContext(now: Date, timeZone: TimeZone, excluding: UUID? = nil) -> [String] {
        guard learning else { return [] }
        let valid = observations.filter { $0.id != excluding && (0...30*86400).contains(now.timeIntervalSince($0.at)) }
        let recent = valid.filter { $0.kind == .conversation && now.timeIntervalSince($0.at) < 7*86400 }.suffix(4)
        var result = recent.map { "Earlier user statement (\(ISO8601DateFormatter().string(from: $0.at))): \($0.text.prefix(180))" }
        // Median clock time is learned only from repeated, explicit reports in
        // the current zone. One day with many messages cannot inflate support.
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        for kind in [Observation.Kind.reportedBedtime, .reportedWake] {
            let candidates = valid.filter { $0.kind == kind && $0.timeZone == timeZone.identifier }
            let byDay = Dictionary(grouping: candidates, by: { calendar.startOfDay(for: $0.at) })
            let samples = byDay.values.compactMap { $0.max(by: { $0.at < $1.at }) }
            guard samples.count >= 3 else { continue }
            // Center bedtime at noon so reports around midnight cluster together.
            let shift = kind == .reportedBedtime ? 720 : 0
            let minutes = samples.map { (calendar.component(.hour, from:$0.at)*60+calendar.component(.minute,from:$0.at)+shift)%1440 }.sorted()
            let median = minutes[minutes.count/2]
            guard minutes.last!-minutes.first! <= 120 else { continue }
            let actual=(median+1440-shift)%1440
            let label = kind == .reportedBedtime ? "going to bed" : "waking up"
            result.append("Tentative pattern from \(samples.count) separate days: user reported \(label) around \(String(format: "%02d:%02d",actual/60,actual%60)) in \(timeZone.identifier). Reports are not measured sleep. Ask if relevant; do not assume today or change a schedule.")
        }
        return result
    }
}

import Foundation
import TsukumoCore

/// One exchange as the owner's Activity shows it: who asked, the question, why, what KemoSabe read
/// (kinds only), exactly what was sent, and how much was left out (counts only). Never the
/// content that was read or left out.
public struct GateJournalEntry: Codable, Identifiable, Hashable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case shared, notFound, declined, waiting, unavailable, failed
        public init(from decoder: Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .failed
        }
    }
    public var id: GateExchangeID
    /// `RecipientID.key`.
    public var requester: String
    public var requesterName: String
    public var botID: UUID?
    public var question: String
    public var purpose: String
    public var outcome: Outcome
    /// "your chats and calendar events", or why nothing was read.
    public var read: String
    /// Exactly what went to the agent; nil when nothing did.
    public var shared: String?
    /// "Not read: 1 Device only note." Counts only.
    public var withheld: String?
    public var withheldCount: Int
    public var receivedAt: Date
    public var decidedAt: Date
    /// Answered without a card (its grant covered it), rather than shared by the owner on a card.
    public var automatic: Bool
}

/// The Gate's journal, kept on this device (it doesn't sync in v1). Bounded; the newest last.
public actor GateJournal {
    public static let maxEntries = 500
    private let url: URL?
    private var entries: [GateJournalEntry]

    /// A journal saved at `url`, or kept in memory when nil. An unreadable file starts empty and is
    /// never overwritten until the next append.
    public init(url: URL? = nil) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url), let saved = try? TsukumoJSON.decoder.decode([GateJournalEntry].self, from: data) {
            entries = saved
        } else {
            entries = []
        }
    }

    public func append(_ entry: GateJournalEntry) throws {
        entries.append(entry)
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try TsukumoJSON.encoder.encode(entries).write(to: url, options: .atomic)
        }
    }

    public func all() -> [GateJournalEntry] { entries }
    public func entry(_ id: GateExchangeID) -> GateJournalEntry? { entries.last { $0.id == id } }
}

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

    public init(id: GateExchangeID, requester: String, requesterName: String, botID: UUID? = nil, question: String, purpose: String,
                outcome: Outcome, read: String, shared: String? = nil, withheld: String? = nil, withheldCount: Int = 0,
                receivedAt: Date, decidedAt: Date, automatic: Bool) {
        self.id = id; self.requester = requester; self.requesterName = requesterName; self.botID = botID
        self.question = question; self.purpose = purpose; self.outcome = outcome; self.read = read; self.shared = shared
        self.withheld = withheld; self.withheldCount = withheldCount; self.receivedAt = receivedAt; self.decidedAt = decidedAt
        self.automatic = automatic
    }
}

/// The Gate's journal, kept on this device (it doesn't sync in v1). Bounded; the newest last.
///
/// Writing to it never suspends: an entry is in the journal the moment `append` returns, and the copy on disk
/// is written afterwards on a queue of its own, in order. So the Gate can commit what it shared and return in
/// one step, with nothing in between where a stop could slip in (October 6, after the security review).
public final class GateJournal: @unchecked Sendable {
    public static let maxEntries = 500
    private let url: URL?
    private let lock = NSLock()
    private var entries: [GateJournalEntry]
    private let disk = DispatchQueue(label: "com.zlichtman.tsukumo.gate-journal")
    private let write: @Sendable (Data, URL) throws -> Void

    /// A journal saved at `url`, or kept in memory when nil. An unreadable file starts empty and is never
    /// overwritten until the next append. `write` saves a snapshot (tests hold it to show nothing waits on it).
    public init(url: URL? = nil, write: @escaping @Sendable (Data, URL) throws -> Void = { data, url in
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }) {
        self.url = url
        self.write = write
        if let url, let data = try? Data(contentsOf: url), let saved = try? TsukumoJSON.decoder.decode([GateJournalEntry].self, from: data) {
            entries = saved
        } else {
            entries = []
        }
    }

    /// Adds an entry now; the file follows.
    public func append(_ entry: GateJournalEntry) {
        let snapshot: [GateJournalEntry] = lock.withLock {
            entries.append(entry)
            if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
            return entries
        }
        save(snapshot)
    }

    /// Changes the newest entry for `id` now (an answer that wasn't delivered after all); the file follows.
    public func amend(_ id: GateExchangeID, _ change: (inout GateJournalEntry) -> Void) {
        let snapshot: [GateJournalEntry]? = lock.withLock {
            guard let index = entries.lastIndex(where: { $0.id == id }) else { return nil }
            change(&entries[index])
            return entries
        }
        if let snapshot { save(snapshot) }
    }

    public func all() -> [GateJournalEntry] { lock.withLock { entries } }
    public func entry(_ id: GateExchangeID) -> GateJournalEntry? { lock.withLock { entries.last { $0.id == id } } }

    /// Waits until every snapshot so far is on disk (tests).
    public func flush() { disk.sync {} }

    private func save(_ snapshot: [GateJournalEntry]) {
        guard let url else { return }
        let write = self.write
        disk.async {
            guard let data = try? TsukumoJSON.encoder.encode(snapshot) else { return }
            try? write(data, url)
        }
    }
}

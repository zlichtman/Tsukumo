import CryptoKit
import Foundation
import Observation
import TsukumoCore

// The disclosure ledger: the defense against compositional misuse. Each answer alone may be harmless; many
// together can rebuild what the owner never meant to give (a whole address book one name at a time, a week's
// schedule one narrow window at a time, a secret one word at a time across several callers, or one caller's
// grant laundered through another). So every call is recorded with the facts that left (never the caller's
// request text, never shared content: an item's id and SHA-256 stand in for it), per caller and across
// callers, and plain code counts it against budgets and looks for enumeration before the next call is
// answered. Over budget asks the owner; far over budget refuses without asking. Risk flags are recorded on the
// call that raised them, for the owner's Settings and for audits.

/// A risk the ledger noticed, by its stable code.
public enum LedgerFlag: String, Codable, CaseIterable, Hashable, Sendable {
    /// A valid call after another within the hour: what it gives may combine with what came before.
    case compositionRisk = "composition_risk"
    /// More than one caller within the hour: their answers may be joined outside.
    case crossCallerCorrelation = "cross_caller_correlation"
    /// A free/busy window finer than the owner's resolution (a boundary probe).
    case precisionProbe = "precision_probe"
    /// Three or more free/busy calls within the hour, by any callers.
    case calendarEnumeration = "calendar_enumeration"
    /// Three or more different names looked up within a day, by one caller or by everyone.
    case contactEnumeration = "contact_enumeration"
    /// Asking for files, conversations, or photos that don't exist, one after another (probing what's there).
    case itemEnumeration = "item_enumeration"
    /// Narrow windows one after another.
    case slidingWindow = "sliding_window"
    case callerBudgetExceeded = "caller_budget_exceeded"
    case crossCallerBudgetExceeded = "cross_caller_budget_exceeded"
    /// A per-hour limit (calls, lists, shares, deliveries).
    case rateLimit = "rate_limit"
    case consentRequired = "consent_required"
    case consentDeduplicated = "consent_deduplicated"
    case consentRateLimit = "consent_rate_limit"
    case expiredGrant = "expired_grant"
    /// A question asking KemoSabe to act for, or pass things to, another caller.
    case delegationAttempt = "delegation_attempt"
    /// A question carrying instructions aimed at the gateway or the owner.
    case untrustedInstruction = "untrusted_instruction"
    /// Malformed, oversized, or deceptive arguments, refused before anything was read.
    case resourceAbuse = "resource_abuse"
    case unknownCaller = "unknown_caller"
}

/// One call, as the owner's ledger shows it.
public struct LedgerEntry: Codable, Hashable, Identifiable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        /// Something left: exactly `facts`.
        case disclosed
        /// Nothing matched. That's a fact too ("there's no one by that name"), so it counts.
        case nothingFound
        /// Waiting on the owner's card; nothing left.
        case pending
        /// The owner said no.
        case declined
        /// The rules refused it before anything was read.
        case refused
        /// Something arrived in the Inbox (`tsukumo.deliver`).
        case received
        public init(from decoder: Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .refused
        }
    }
    public var id: UUID
    public var caller: String
    public var callerName: String
    public var tool: GatewayToolName
    public var at: Date
    public var outcome: Outcome
    /// What left, in words: "Busy Tue, Apr 8", "Mira: first name, one email address".
    public var facts: [String]
    /// A salted hash of the person or conversation asked about, to count different ones. Never the name.
    public var subject: String?
    /// The free/busy window asked about.
    public var window: DateInterval?
    /// The days that window covered ("2026-10-07").
    public var days: [String]
    /// Disclosure units spent (zero unless something left).
    public var units: Int
    /// How many characters (or, for a file or photo, bytes) left or arrived.
    public var characters: Int
    /// A file's, excerpt's, or photo's id, and the SHA-256 of exactly what left or arrived (never the content).
    public var item: String?
    public var sha256: String?
    /// The risks this call raised.
    public var flags: [LedgerFlag]
    /// Why, in words, for the owner.
    public var note: String?
    /// Allowed by the owner on a card rather than by a standing grant.
    public var askedOwner: Bool
    /// How many refusals in a row this entry stands for (nil: one).
    public var repeats: Int?

    public init(id: UUID = UUID(), caller: String, callerName: String, tool: GatewayToolName, at: Date, outcome: Outcome, facts: [String] = [],
                subject: String? = nil, window: DateInterval? = nil, days: [String] = [], units: Int = 0, characters: Int = 0,
                item: String? = nil, sha256: String? = nil, flags: [LedgerFlag] = [], note: String? = nil, askedOwner: Bool = false) {
        self.id = id; self.caller = caller; self.callerName = callerName; self.tool = tool; self.at = at; self.outcome = outcome
        self.facts = facts; self.subject = subject; self.window = window; self.days = days; self.units = units
        self.characters = characters; self.item = item; self.sha256 = sha256; self.flags = flags; self.note = note; self.askedOwner = askedOwner
    }

    /// Whether it gave something away (a match or the lack of one).
    public var counts: Bool { outcome == .disclosed || outcome == .nothingFound }
    /// Whether it was a well-formed call by a known caller (refusals for bad arguments aren't).
    public var valid: Bool { !flags.contains(.resourceAbuse) && !flags.contains(.unknownCaller) }
}

/// What the ledger says about a call before it's answered.
public enum LedgerVerdict: Hashable, Sendable {
    case withinBudget
    /// Over a budget or matching an enumeration pattern: ask the owner, with why.
    case askOwner(String)
    /// Far over budget: refuse without asking.
    case refuse(String)
}

/// The proposed call, as the ledger counts it.
public struct LedgerProbe: Hashable, Sendable {
    public var caller: String
    public var callerName: String
    public var tool: GatewayToolName
    public var subject: String?
    public var window: DateInterval?
    public var days: [String]
    public init(caller: String, callerName: String, tool: GatewayToolName, subject: String? = nil, window: DateInterval? = nil, days: [String] = []) {
        self.caller = caller; self.callerName = callerName; self.tool = tool; self.subject = subject; self.window = window; self.days = days
    }
}

/// The ledger, kept on this Mac (`gateway-ledger.json`), never synced, the newest last. Entries older than 30
/// days are dropped (budgets look back a day at most).
@MainActor @Observable public final class DisclosureLedger {
    public static let keepFor: TimeInterval = 30 * 86_400
    public static let maxEntries = 5_000
    /// Narrow free/busy windows (three hours or less), this many within an hour, look like a sliding probe.
    public static let slidingWindow: TimeInterval = 3 * 3_600, slidingCount = 4
    /// Lookups that found no one, this many within an hour, look like someone guessing names.
    public static let missesPerHour = 3
    /// This many different names, or free/busy calls, count as enumeration.
    public static let enumerationCount = 3

    /// The audit log the owner reads: bounded, and rejected calls in a row coalesce into one entry with a count.
    public private(set) var entries: [LedgerEntry]
    /// The accounting: every accepted call (and every reservation in flight) from the last day, slim (no facts or
    /// notes). Budgets, enumeration, and composition are counted from these, never from the audit log, and they're
    /// dropped only by age, so no flood of entries can evict them. Rejected calls never get a mark, and a caller is
    /// refused past its hard limits, so they stay bounded.
    @ObservationIgnored private(set) var marks: [LedgerEntry]
    @ObservationIgnored private let file: URL?
    @ObservationIgnored private let salt: String
    @ObservationIgnored private let clock: @Sendable () -> Date
    public static let markWindow: TimeInterval = 25 * 3_600

    private struct Saved: Codable { var salt: String; var entries: [LedgerEntry]; var marks: [LedgerEntry]? }

    public init(file: URL?, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.file = file
        self.clock = clock
        let saved = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? TsukumoJSON.decoder.decode(Saved.self, from: $0) }
        salt = saved?.salt ?? GatewaySecrets.base64url(GatewaySecrets.random(16))
        let loaded = saved?.entries ?? []
        entries = loaded
        // A file from before marks were kept: the accounting is rebuilt from the audit entries still in its window,
        // so moving to this build never resets anyone's budget or history.
        let now = clock()
        marks = saved?.marks ?? loaded.filter { $0.valid && $0.outcome != .refused && now.timeIntervalSince($0.at) <= Self.markWindow }.map(Self.slim)
    }

    /// An entry as the accounting keeps it: no facts, notes, or flags.
    static func slim(_ entry: LedgerEntry) -> LedgerEntry {
        var mark = entry
        mark.facts = []; mark.note = nil; mark.flags = []
        return mark
    }
    /// The most accounting marks one caller may have in the window; past it, its calls are refused (never evicted).
    public static let maxMarksPerCaller = 2_000
    /// Writes to disk are batched: at most one every this many seconds, and on `flush()`.
    public static let saveDelay: Duration = .seconds(1)
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var dirty = false
    /// How many times the file was written (tests).
    @ObservationIgnored private(set) var writes = 0

    // MARK: Reservations

    /// Holds a call's units, rate, and facts (subject, days) before any read suspends, so concurrent calls can't
    /// overspend; `settle` swaps it for the real entry, `release` drops it.
    public func reserve(_ probe: LedgerProbe, units: Int) -> UUID {
        let id = UUID()
        marks.append(LedgerEntry(id: id, caller: probe.caller, callerName: probe.callerName, tool: probe.tool, at: clock(), outcome: .disclosed,
                                 subject: probe.subject, window: probe.window, days: probe.days, units: units))
        save()
        return id
    }
    public func release(_ id: UUID) {
        marks.removeAll { $0.id == id }
        save()
    }
    public func settle(_ id: UUID, with entry: LedgerEntry) {
        marks.removeAll { $0.id == id }
        record(entry)
    }

    /// The hash a name is counted by: the same for "sarah  connor" and "Sarah Connor". Punctuation counts, so
    /// "*", "%", and "[A-Z]" are three different probes, not one empty name.
    public func subject(_ name: String) -> String {
        let normal = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return SHA256.hash(data: Data((salt + "|" + normal).utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// The patterns this call continues, before anything is read: composition, correlation, enumeration.
    public func patterns(_ probe: LedgerProbe) -> [LedgerFlag] {
        let now = clock(), hour = now.addingTimeInterval(-3_600), day = now.addingTimeInterval(-86_400)
        let recent = marks.filter { $0.valid && $0.at > hour }
        var flags: [LedgerFlag] = []
        if !recent.isEmpty { flags.append(.compositionRisk) }
        if recent.contains(where: { $0.caller != probe.caller }) { flags.append(.crossCallerCorrelation) }
        switch probe.tool {
        case .freeBusy:
            if recent.filter({ $0.tool == .freeBusy }).count + 1 >= Self.enumerationCount { flags.append(.calendarEnumeration) }
        case .contactLookup:
            let looked = marks.filter { $0.valid && $0.tool == .contactLookup && $0.at > day }
            let mine = Set(looked.filter { $0.caller == probe.caller }.compactMap(\.subject)).union(probe.subject.map { [$0] } ?? [])
            let everyone = Set(looked.compactMap(\.subject)).union(probe.subject.map { [$0] } ?? [])
            if mine.count >= Self.enumerationCount || everyone.count >= Self.enumerationCount { flags.append(.contactEnumeration) }
        default: break
        }
        return flags
    }

    /// Checks a call against the per-hour and per-day limits before anything is read.
    public func check(_ probe: LedgerProbe, budget: GatewayBudget) -> (verdict: LedgerVerdict, flags: [LedgerFlag]) {
        let now = clock()
        let hour = now.addingTimeInterval(-3_600), day = now.addingTimeInterval(-86_400)
        let mine = marks.filter { $0.caller == probe.caller && $0.valid }
        let name = probe.callerName
        var reasons: [(why: String, refuse: Bool, flag: LedgerFlag)] = []

        func over(_ count: Int, _ limit: Int, _ why: String, _ flag: LedgerFlag) {
            if count >= limit * budget.hardMultiple { reasons.append((why, true, flag)) } else if count >= limit { reasons.append((why, false, flag)) }
        }

        // A hard ceiling on what one caller can make the accounting hold: refused, never evicted.
        if mine.count >= Self.maxMarksPerCaller {
            return (.refuse("\(name) has reached the most requests the ledger keeps for one agent in a day."), [.rateLimit])
        }
        let callsThisHour = mine.filter { $0.at > hour }.count
        over(callsThisHour, budget.callsPerHour, "\(name) has called \(callsThisHour) times in the last hour.", .rateLimit)

        switch probe.tool {
        case .contactLookup:
            let looked = Set(mine.filter { $0.tool == .contactLookup && $0.counts && $0.at > day }.compactMap(\.subject))
            if let subject = probe.subject, !looked.contains(subject) {
                over(looked.count + 1, budget.contactsPerDay + 1, "\(name) has looked up \(looked.count) different people today.", .contactEnumeration)
                let everyone = Set(marks.filter { $0.tool == .contactLookup && $0.counts && $0.at > day }.compactMap(\.subject))
                if !everyone.contains(subject) {
                    over(everyone.count + 1, budget.contactsPerDayEveryone + 1, "Agents together have looked up \(everyone.count) different people today.",
                         .contactEnumeration)
                }
            }
            let misses = mine.filter { $0.tool == .contactLookup && $0.outcome == .nothingFound && $0.at > hour }.count
            over(misses, Self.missesPerHour, "\(name) asked about \(misses) people you don’t have in the last hour, which looks like guessing names.",
                 .contactEnumeration)
        case .freeBusy:
            let calls = mine.filter { $0.tool == .freeBusy && $0.at > hour }
            over(calls.count, budget.freeBusyPerHour, "\(name) has asked for free/busy times \(calls.count) times in the last hour.", .calendarEnumeration)
            let covered = Set(mine.filter { $0.tool == .freeBusy && $0.counts && $0.at > day }.flatMap(\.days))
            let after = covered.union(probe.days)
            if after.count > covered.count {
                over(after.count, budget.freeBusyDaysPerDay + 1, "\(name) has seen free/busy for \(covered.count) days today.", .calendarEnumeration)
            }
            if let window = probe.window, window.duration <= Self.slidingWindow {
                let narrow = calls.filter { ($0.window?.duration ?? .infinity) <= Self.slidingWindow }.count
                over(narrow + 1, Self.slidingCount, "\(name) is asking about narrow windows one after another, which can piece together your day.", .slidingWindow)
            }
            let everyone = marks.filter { $0.valid && $0.tool == .freeBusy && $0.at > hour }.count
            over(everyone, budget.freeBusyPerHour * 3, "Agents together have asked for free/busy times \(everyone) times in the last hour.", .calendarEnumeration)
        case .ask:
            let asks = mine.filter { $0.tool == .ask && $0.at > hour }.count
            over(asks, budget.asksPerHour, "\(name) has asked KemoSabe \(asks) questions in the last hour.", .rateLimit)
        case .shareFile, .shareMessages, .sharePhoto:
            let shares = mine.filter { [.shareFile, .shareMessages, .sharePhoto].contains($0.tool) && $0.at > hour }.count
            over(shares, budget.sharesPerHour, "\(name) has asked for \(shares) files, excerpts, or photos in the last hour.", .rateLimit)
            let misses = mine.filter { [.shareFile, .shareMessages, .sharePhoto].contains($0.tool) && $0.outcome == .nothingFound && $0.at > hour }.count
            over(misses, Self.missesPerHour, "\(name) asked for \(misses) things that aren’t there in the last hour, which looks like probing.", .itemEnumeration)
            let everyone = marks.filter { [.shareFile, .shareMessages, .sharePhoto].contains($0.tool) && $0.counts && $0.at > hour }.count
            over(everyone, budget.sharesPerHour * 3, "Agents together have been sent \(everyone) files, excerpts, or photos in the last hour.", .rateLimit)
        case .listShareable:
            let lists = mine.filter { $0.tool == .listShareable && $0.at > hour }.count
            over(lists, budget.listsPerHour, "\(name) has listed what you could share \(lists) times in the last hour.", .rateLimit)
        case .deliver:
            let sent = mine.filter { $0.tool == .deliver && $0.at > hour }.count
            over(sent, budget.deliveriesPerHour, "\(name) has sent you \(sent) things in the last hour.", .rateLimit)
        case .botReply:
            let replies = mine.filter { $0.tool == .botReply && $0.at > hour }.count
            over(replies, budget.asksPerHour, "\(name) has had \(replies) replies from your bots in the last hour.", .rateLimit)
        }
        let flags = Array(Set(reasons.map(\.flag))).sorted { $0.rawValue < $1.rawValue }
        if let refuse = reasons.first(where: \.refuse) { return (.refuse(refuse.why), flags) }
        if let ask = reasons.first { return (.askOwner(ask.why), flags) }
        return (.withinBudget, flags)
    }

    /// Whether `units` more may be spent by this caller and by everyone today; the flag when not.
    public func canSpend(_ units: Int, caller: String, budget: GatewayBudget) -> LedgerFlag? {
        let day = clock().addingTimeInterval(-86_400)
        let today = marks.filter { $0.at > day }
        if spent(today.filter { $0.caller == caller }) + units > budget.units(for: caller) { return .callerBudgetExceeded }
        if spent(today) + units > budget.unitsEveryone { return .crossCallerBudgetExceeded }
        return nil
    }
    private func spent(_ list: [LedgerEntry]) -> Int { list.reduce(0) { $0 + $1.units } }

    /// Units spent in the last day, per caller and in all.
    public func spentToday() -> (byCaller: [String: Int], total: Int) {
        let day = clock().addingTimeInterval(-86_400)
        var byCaller: [String: Int] = [:]
        for entry in marks where entry.at > day && entry.units > 0 { byCaller[entry.caller, default: 0] += entry.units }
        return (byCaller, byCaller.values.reduce(0, +))
    }

    /// Records a call. `account: false` keeps it out of the accounting (public help, which discloses nothing); it
    /// coalesces in the audit log like refusals do.
    public func record(_ entry: LedgerEntry, account: Bool = true) {
        let now = clock()
        // Accounting first: an accepted call gets a slim mark, kept by age alone.
        if account, entry.valid, entry.outcome != .refused { marks.append(Self.slim(entry)) }
        marks.removeAll { now.timeIntervalSince($0.at) > Self.markWindow }
        // The audit log: refusals (or unaccounted entries) in a row from one caller for one reason are one entry with a count.
        let coalesces = entry.outcome == .refused || !account
        if coalesces, let last = entries.last, last.outcome == entry.outcome, last.caller == entry.caller, last.tool == entry.tool,
           last.note == entry.note, last.facts == entry.facts, last.units == 0, now.timeIntervalSince(last.at) < 60 {
            entries[entries.count - 1].repeats = (last.repeats ?? 1) + 1
            entries[entries.count - 1].flags = GatewayTools.unique(last.flags + entry.flags)
            entries[entries.count - 1].at = entry.at
        } else {
            entries.append(entry)
        }
        let cutoff = now.addingTimeInterval(-Self.keepFor)
        entries.removeAll { $0.at < cutoff }
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
        save()
    }

    public func entries(for caller: String) -> [LedgerEntry] { entries.filter { $0.caller == caller } }

    /// The last day's use for a caller, in words: "Last day: 2 people · 5 days of free/busy · 1 question".
    public func usage(for caller: String) -> String {
        let day = clock().addingTimeInterval(-86_400)
        let mine = marks.filter { $0.caller == caller && $0.at > day && $0.counts }
        let people = Set(mine.filter { $0.tool == .contactLookup }.compactMap(\.subject)).count
        let days = Set(mine.filter { $0.tool == .freeBusy }.flatMap(\.days)).count
        let asks = mine.filter { $0.tool == .ask }.count
        let shares = mine.filter { [.shareFile, .shareMessages, .sharePhoto].contains($0.tool) && $0.outcome == .disclosed }.count
        let replies = mine.filter { $0.tool == .botReply && $0.outcome == .disclosed }.count
        var parts: [String] = []
        if people > 0 { parts.append("\(people) \(people == 1 ? "person" : "people")") }
        if days > 0 { parts.append("\(days) \(days == 1 ? "day" : "days") of free/busy") }
        if asks > 0 { parts.append("\(asks) \(asks == 1 ? "question" : "questions")") }
        if shares > 0 { parts.append("\(shares) \(shares == 1 ? "item" : "items") shared") }
        if replies > 0 { parts.append("\(replies) \(replies == 1 ? "bot reply" : "bot replies")") }
        return parts.isEmpty ? "Nothing shared in the last day" : "Last day: " + parts.joined(separator: " · ")
    }

    // Revoking a caller keeps its entries: the record of what left outlives the caller.
    /// Marks the ledger changed; it's written at most once per `saveDelay`, not on every call.
    private func save() {
        guard file != nil else { return }
        dirty = true
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            self?.flush()
        }
    }
    /// Writes the ledger now, if it changed (the app calls it when quitting).
    public func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard dirty, let file else { return }
        dirty = false
        writes += 1
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? TsukumoJSON.encoder.encode(Saved(salt: salt, entries: entries, marks: marks)).write(to: file, options: [.atomic])
    }
}

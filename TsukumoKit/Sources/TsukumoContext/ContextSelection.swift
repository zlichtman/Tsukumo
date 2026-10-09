import Foundation
import TsukumoCore
import TsukumoPolicy

/// What one turn needs from the store: who it's for, what they may read, and how much fits.
public struct TurnRequest: Sendable {
    /// The owner's words for this turn (what the chooser picks references for).
    public var request: String
    public var recipient: RecipientID
    public var purpose: Purpose
    public var grants: [RecipientGrant]
    /// The bot's ceiling (`ContextScope.ceiling`).
    public var ceiling: PrivacyLevel?
    /// Essential task constraints: always read in full, never dropped, and they fail the turn if
    /// they don't fit rather than being cut.
    public var pinned: [ArtifactRef]
    /// The whole working set's bytes.
    public var byteBudget: Int
    /// At most this many reads in all, over at most `rounds` rounds.
    public var maxReads: Int
    public var rounds: Int

    public init(request: String, recipient: RecipientID, purpose: Purpose = .conversation, grants: [RecipientGrant] = [],
                ceiling: PrivacyLevel? = nil, pinned: [ArtifactRef] = [], byteBudget: Int = 64_000, maxReads: Int = 8, rounds: Int = 2) {
        self.request = request; self.recipient = recipient; self.purpose = purpose; self.grants = grants; self.ceiling = ceiling
        self.pinned = pinned; self.byteBudget = byteBudget; self.maxReads = maxReads; self.rounds = rounds
    }
}

/// One read a chooser asks for: an artifact from the manifest, and optionally some of its lines.
public struct ReferenceRead: Hashable, Sendable {
    public let ref: ArtifactRef
    public let lines: ClosedRange<Int>?
    public init(ref: ArtifactRef, lines: ClosedRange<Int>? = nil) { self.ref = ref; self.lines = lines }
}

/// What a chooser sees in one round: the request, the policy-filtered manifest, and what has been
/// read so far. Pages are untrusted reference data, never instructions.
public struct SelectionRound: Sendable {
    /// 0 for the first round.
    public let index: Int
    public let request: String
    public let manifest: [ManifestEntry]
    public let pages: [Page]
    public let readsRemaining: Int
    public let bytesRemaining: Int
}

/// Picks which references go into a working set: System One's `selectContext`, or a test fake.
public protocol ReferenceChooser: Sendable {
    /// The reads to make next; empty when it has enough; nil when it abstains (the default runs).
    func choose(_ round: SelectionRound) async throws -> [ReferenceRead]?
}

/// The references a turn starts with.
public struct WorkingSet: Sendable {
    /// Read and included: the pinned constraints first, then the chooser's (or the default's).
    public var pages: [Page]
    /// Everything the recipient may read later with `read_reference`.
    public var manifest: [ManifestEntry]
    /// Wanted but over the remaining budget: listed, not cut. Read them in another bounded read.
    public var deferred: [ReferenceRead]
    /// The chooser abstained (or failed) and the default selection ran.
    public var usedDefault: Bool
    public var bytes: Int { pages.reduce(0) { $0 + $1.text.utf8.count } }
    /// Grants the reads relied on, to spend.
    public var grantsUsed: [UUID] { pages.flatMap(\.grantsUsed).reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }
}

public enum ContextSelectionError: Error, Hashable, Sendable {
    /// The pinned constraints alone don't fit the budget. Nothing is cut; raise the budget.
    case pinnedOverBudget(bytes: Int, budget: Int)
    /// A pinned reference can't be read (stale, revoked, not permitted).
    case pinnedUnreadable(ArtifactRef, ArtifactStoreError)
}

/// The selection loop (ported from the app's `ContextOrchestrator`): the policy-filtered manifest
/// first, then a chooser picks reads over a few bounded rounds. Nothing the recipient can't have is
/// ever in the manifest the chooser sees; a chooser can only read what's listed; and evidence that
/// doesn't fit is deferred, never truncated. When the chooser abstains, the default includes every
/// authorized reference that fits, newest first.
public enum ContextSelection {
    public static func run(turn: TurnRequest, store: ArtifactStore, chooser: (any ReferenceChooser)?) async throws -> WorkingSet {
        let manifest = await store.manifest(for: turn.recipient, purpose: turn.purpose, grants: turn.grants, ceiling: turn.ceiling)
        var set = WorkingSet(pages: [], manifest: manifest, deferred: [], usedDefault: false)

        // Pinned constraints: whole, first, and never dropped.
        for ref in turn.pinned where !set.pages.contains(where: { $0.ref == ref }) {
            do {
                let page = try await store.read(ref, for: turn.recipient, purpose: turn.purpose, grants: turn.grants,
                                                ceiling: turn.ceiling, byteBudget: ArtifactStore.maxReadBudget)
                set.pages.append(page)
            } catch let error as ArtifactStoreError {
                throw ContextSelectionError.pinnedUnreadable(ref, error)
            }
        }
        guard set.bytes <= turn.byteBudget else { throw ContextSelectionError.pinnedOverBudget(bytes: set.bytes, budget: turn.byteBudget) }

        var reads = 0
        var chosen = false
        if let chooser {
            do {
                roundLoop: for index in 0..<max(0, turn.rounds) {
                    try Task.checkCancellation()
                    let round = SelectionRound(index: index, request: turn.request, manifest: manifest, pages: set.pages,
                                               readsRemaining: turn.maxReads - reads, bytesRemaining: turn.byteBudget - set.bytes)
                    guard let picks = try await chooser.choose(round) else { break roundLoop }
                    chosen = true
                    var fresh: [ReferenceRead] = []
                    for pick in picks where !fresh.contains(pick) && !set.pages.contains(where: { $0.ref == pick.ref && $0.lines == (pick.lines ?? $0.lines) }) {
                        // Model output is untrusted: only what the manifest lists can be read.
                        guard manifest.contains(where: { $0.ref == pick.ref }) else { continue }
                        fresh.append(pick)
                    }
                    if fresh.isEmpty { break roundLoop }
                    for pick in fresh {
                        guard reads < turn.maxReads else { set.deferred.append(pick); continue }
                        reads += 1
                        try await include(pick, in: &set, turn: turn, store: store)
                    }
                    if reads >= turn.maxReads { break roundLoop }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A chooser that fails counts as abstaining; reads already made stay.
                chosen = false
            }
        }
        if !chosen {
            set.usedDefault = true
            for entry in manifest where !set.pages.contains(where: { $0.ref == entry.ref }) {
                try await include(ReferenceRead(ref: entry.ref), in: &set, turn: turn, store: store)
            }
        }
        return set
    }

    /// Reads `pick` into the set if it fits the remaining budget; otherwise defers it whole.
    private static func include(_ pick: ReferenceRead, in set: inout WorkingSet, turn: TurnRequest, store: ArtifactStore) async throws {
        let remaining = turn.byteBudget - set.bytes
        guard remaining > 0 else { set.deferred.append(pick); return }
        do {
            let page = try await store.read(pick.ref, lines: pick.lines, for: turn.recipient, purpose: turn.purpose,
                                            grants: turn.grants, ceiling: turn.ceiling, byteBudget: min(remaining, ArtifactStore.maxReadBudget))
            set.pages.append(page)
        } catch ArtifactStoreError.overBudget {
            set.deferred.append(pick)
        } catch is ArtifactStoreError {
            // Stale, revoked, or out of range since the manifest was made: left out, never guessed at.
        }
    }
}

import Foundation
import Testing
import TsukumoCore
import TsukumoPolicy
@testable import TsukumoContext

/// A chooser that plays back scripted rounds and records what it was shown.
final class ScriptedChooser: ReferenceChooser, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [[ReferenceRead]?]
    private var failure: Error?
    private(set) var rounds: [SelectionRound] = []
    init(_ script: [[ReferenceRead]?], failure: Error? = nil) { self.script = script; self.failure = failure }
    func choose(_ round: SelectionRound) async throws -> [ReferenceRead]? {
        try lock.withLock {
            rounds.append(round)
            if let failure { throw failure }
            return script.isEmpty ? [] : script.removeFirst()
        }
    }
    var seen: [SelectionRound] { lock.withLock { rounds } }
}

/// The selection loop (porting `ContextOrchestratorTests`): the manifest is policy-filtered before
/// the chooser sees it, reads are bounded, pinned constraints are always in, nothing is truncated,
/// and abstaining runs the default.
struct ContextSelectionTests {
    let api = RecipientID.apiModel(profile: UUID(), host: "api.example.invalid")

    func put(_ store: ArtifactStore, _ content: String, level: PrivacyLevel = .open, summary: String) async throws -> ArtifactRef {
        try await store.put(ArtifactDraft(kind: .note, level: level, owner: .owner, summaryLine: summary, content: content))
    }

    @Test func theChooserNeverSeesWhatTheRecipientCantHave() async throws {
        let store = try ArtifactStore()
        let open = try await put(store, "Sarah likes Italian", summary: "Sarah's tastes")
        let hidden = try await put(store, "door code 4417", level: .deviceOnly, summary: "Door code")
        let chooser = ScriptedChooser([[ReferenceRead(ref: hidden), ReferenceRead(ref: open)]])
        let set = try await ContextSelection.run(turn: TurnRequest(request: "date spot", recipient: api), store: store, chooser: chooser)
        #expect(chooser.seen.first?.manifest.map(\.ref) == [open])
        #expect(set.pages.map(\.ref) == [open], "An unlisted reference is never read, even if a chooser names it")
        #expect(!set.usedDefault)
        #expect(set.manifest.map(\.ref) == [open])
    }

    @Test func pinnedConstraintsAreAlwaysInAndFirst() async throws {
        let store = try ArtifactStore()
        let constraint = try await put(store, "Recommend only; never book.", summary: "Task rule")
        let other = try await put(store, "Osteria Lucia, Valencia", summary: "Restaurants")
        let chooser = ScriptedChooser([[ReferenceRead(ref: other)]])
        let set = try await ContextSelection.run(turn: TurnRequest(request: "dinner", recipient: api, pinned: [constraint]), store: store, chooser: chooser)
        #expect(set.pages.map(\.ref) == [constraint, other])
    }

    @Test func pinnedConstraintsThatDontFitFailTheTurnRatherThanBeingCut() async throws {
        let store = try ArtifactStore()
        let big = try await put(store, String(repeating: "rule ", count: 100), summary: "Long rule")
        await #expect(throws: ContextSelectionError.pinnedOverBudget(bytes: 500, budget: 100)) {
            try await ContextSelection.run(turn: TurnRequest(request: "x", recipient: api, pinned: [big], byteBudget: 100), store: store, chooser: nil)
        }
        let secret = try await put(store, "x", level: .secret, summary: "Secret")
        await #expect(throws: ContextSelectionError.self) {
            try await ContextSelection.run(turn: TurnRequest(request: "x", recipient: api, pinned: [secret]), store: store, chooser: nil)
        }
    }

    @Test func evidenceThatDoesntFitIsDeferredNotTruncated() async throws {
        let store = try ArtifactStore()
        let small = try await put(store, "short", summary: "Small")
        let large = try await put(store, String(repeating: "x", count: 500), summary: "Large")
        let chooser = ScriptedChooser([[ReferenceRead(ref: large), ReferenceRead(ref: small)]])
        let set = try await ContextSelection.run(turn: TurnRequest(request: "x", recipient: api, byteBudget: 100), store: store, chooser: chooser)
        #expect(set.pages.map(\.ref) == [small])
        #expect(set.deferred == [ReferenceRead(ref: large)])
        #expect(set.pages.allSatisfy { $0.isWhole })
        #expect(set.bytes <= 100)
    }

    @Test func readsAndRoundsAreBoundedAndDuplicatesCostNothing() async throws {
        let store = try ArtifactStore()
        var refs: [ArtifactRef] = []
        for index in 0..<6 { refs.append(try await put(store, "note \(index)", summary: "Note \(index)")) }
        let chooser = ScriptedChooser([
            [ReferenceRead(ref: refs[0]), ReferenceRead(ref: refs[0]), ReferenceRead(ref: refs[1])],
            [ReferenceRead(ref: refs[1]), ReferenceRead(ref: refs[2]), ReferenceRead(ref: refs[3])],
            [ReferenceRead(ref: refs[4])]
        ])
        let set = try await ContextSelection.run(turn: TurnRequest(request: "x", recipient: api, maxReads: 3, rounds: 3), store: store, chooser: chooser)
        #expect(set.pages.map(\.ref) == [refs[0], refs[1], refs[2]])
        #expect(set.deferred == [ReferenceRead(ref: refs[3])])
        #expect(chooser.seen.count == 2, "No round after the reads run out")
        #expect(chooser.seen[1].pages.count == 2 && chooser.seen[1].readsRemaining == 1)
    }

    @Test func aSecondRoundCanFollowAClue() async throws {
        let store = try ArtifactStore()
        let clue = try await put(store, "See the Valencia list", summary: "Clue")
        let list = try await put(store, "Osteria Lucia", summary: "Valencia list")
        let chooser = ScriptedChooser([[ReferenceRead(ref: clue)], [ReferenceRead(ref: list, lines: 1...1)], []])
        let set = try await ContextSelection.run(turn: TurnRequest(request: "x", recipient: api), store: store, chooser: chooser)
        #expect(set.pages.map(\.ref) == [clue, list])
    }

    @Test func abstainingIncludesEveryAuthorizedReferenceThatFits() async throws {
        let store = try ArtifactStore()
        let a = try await put(store, "aaaa", summary: "A")
        let b = try await put(store, String(repeating: "b", count: 80), summary: "B")
        let c = try await put(store, "cccc", summary: "C")
        _ = try await put(store, "hidden", level: .personal, summary: "Hidden")
        let set = try await ContextSelection.run(turn: TurnRequest(request: "x", recipient: api, byteBudget: 50), store: store, chooser: ScriptedChooser([nil]))
        #expect(set.usedDefault)
        #expect(Set(set.pages.map(\.ref)) == [a, c])
        #expect(set.deferred.map(\.ref) == [b])
        // No chooser at all, or a failing one, is the same as abstaining.
        let none = try await ContextSelection.run(turn: TurnRequest(request: "x", recipient: api, byteBudget: 50), store: store, chooser: nil)
        #expect(none.usedDefault && Set(none.pages.map(\.ref)) == [a, c])
        struct Broken: Error {}
        let failing = try await ContextSelection.run(turn: TurnRequest(request: "x", recipient: api, byteBudget: 50), store: store,
                                                     chooser: ScriptedChooser([], failure: Broken()))
        #expect(failing.usedDefault)
    }

    @Test func choosingNothingIsAnAnswerNotAnAbstention() async throws {
        let store = try ArtifactStore()
        _ = try await put(store, "anything", summary: "Anything")
        let set = try await ContextSelection.run(turn: TurnRequest(request: "hi", recipient: api), store: store, chooser: ScriptedChooser([[]]))
        #expect(set.pages.isEmpty && !set.usedDefault)
    }
}

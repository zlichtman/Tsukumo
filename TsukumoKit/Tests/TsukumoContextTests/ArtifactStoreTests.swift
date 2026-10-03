import Foundation
import Testing
import TsukumoCore
import TsukumoPolicy
@testable import TsukumoContext

/// The artifact store (porting `ContextBrokerTests`, `ContextPagingTests`, and the lineage tests):
/// revisions never overwrite, pinned reads reject stale revisions and hashes, over-budget reads fail
/// instead of truncating, revoke cascades through lineage, and the manifest never lists what a
/// recipient can't see.
struct ArtifactStoreTests {
    let api = RecipientID.apiModel(profile: UUID(), host: "api.example.invalid")
    let claude = RecipientID.codingAgent("claude-code")

    func draft(_ content: String, level: PrivacyLevel = .open, kind: ArtifactKind = .file, summary: String = "A file",
               id: ArtifactID? = nil, basedOn: Int? = nil) -> ArtifactDraft {
        ArtifactDraft(id: id, basedOn: basedOn, kind: kind, level: level, owner: .owner, summaryLine: summary, content: content)
    }

    @Test func revisionsNeverOverwrite() async throws {
        let store = try ArtifactStore()
        let first = try await store.put(draft("one\ntwo"))
        let second = try await store.put(draft("one\ntwo\nthree", id: first.id, basedOn: 1))
        #expect(first.id == second.id && second.revision == 2 && first.sha256 != second.sha256)
        #expect(await store.history(of: first.id) == [first, second])
        #expect(await store.artifact(first)?.lineCount == 2)
        // A writer that didn't see revision 2 can't write over it.
        await #expect(throws: ArtifactStoreError.revisionConflict(current: 2)) { try await store.put(draft("x", id: first.id, basedOn: 1)) }
        await #expect(throws: ArtifactStoreError.self) { try await store.put(draft("x", basedOn: 1)) }
    }

    @Test func theDatabaseItselfRefusesToChangeARevision() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("artifacts.sqlite")
        let store = try ArtifactStore(url: url)
        let ref = try await store.put(draft("hello"))
        let raw = try SQLiteDatabase(url: url)
        #expect(throws: SQLiteDatabase.Failure.self) {
            try raw.query("UPDATE revisions SET content = 'goodbye' WHERE id = ?", [.text(ref.id.description)])
        }
        #expect(throws: SQLiteDatabase.Failure.self) {
            try raw.query("DELETE FROM revisions WHERE id = ?", [.text(ref.id.description)])
        }
    }

    @Test func pinnedReadsReturnExactLines() async throws {
        let store = try ArtifactStore()
        let ref = try await store.put(draft("alpha\nbeta\ngamma\ndelta"))
        let page = try await store.read(ref, lines: 2...3, for: api, byteBudget: 100)
        #expect(page.text == "beta\ngamma" && page.totalLines == 4 && !page.isWhole)
        let whole = try await store.read(ref, for: api, byteBudget: 100)
        #expect(whole.text == "alpha\nbeta\ngamma\ndelta" && whole.isWhole)
        await #expect(throws: ArtifactStoreError.invalidRange) { try await store.read(ref, lines: 3...9, for: api, byteBudget: 100) }
        await #expect(throws: ArtifactStoreError.invalidRange) { try await store.read(ref, lines: 0...1, for: api, byteBudget: 100) }
    }

    @Test func staleRevisionsAndHashesFail() async throws {
        let store = try ArtifactStore()
        let old = try await store.put(draft("v1"))
        _ = try await store.put(draft("v2", id: old.id, basedOn: 1))
        await #expect(throws: ArtifactStoreError.staleRevision(current: 2)) { try await store.read(old, for: api, byteBudget: 100) }
        let current = try #require(await store.latest(old.id))
        let forged = ArtifactRef(id: current.id, revision: current.revision, sha256: String(repeating: "0", count: 64))
        await #expect(throws: ArtifactStoreError.hashMismatch) { try await store.read(forged, for: api, byteBudget: 100) }
        await #expect(throws: ArtifactStoreError.notFound) {
            try await store.read(ArtifactRef(id: ArtifactID(), revision: 1, sha256: ""), for: api, byteBudget: 100)
        }
    }

    @Test func overBudgetReadsFailAndNeverTruncate() async throws {
        let store = try ArtifactStore()
        let ref = try await store.put(draft(String(repeating: "x", count: 50) + "\nshort"))
        await #expect(throws: ArtifactStoreError.overBudget(bytes: 56, budget: 20)) { try await store.read(ref, for: api, byteBudget: 20) }
        // Asking for fewer lines fits.
        #expect(try await store.read(ref, lines: 2...2, for: api, byteBudget: 20).text == "short")
    }

    @Test func theManifestNeverListsWhatARecipientCantSee() async throws {
        let store = try ArtifactStore()
        let open = try await store.put(draft("roadmap", summary: "Roadmap"))
        let personal = try await store.put(draft("plans", level: .personal, summary: "Weekend plans"))
        let local = try await store.put(draft("1234", level: .deviceOnly, summary: "Door code"))
        _ = try await store.put(draft("diary", level: .secret, summary: "Diary"))
        #expect(await store.manifest(for: api).map(\.ref) == [open])
        let onDevice = await store.manifest(for: .appleOnDevice).map(\.summaryLine)
        #expect(Set(onDevice) == ["Roadmap", "Weekend plans", "Door code"])
        let granted = await store.manifest(for: api, grants: [RecipientGrant(recipient: api, kinds: [.file], purpose: .conversation)])
        #expect(Set(granted.map(\.ref)) == [open, personal])
        // And a read of something unlisted fails the same way.
        await #expect(throws: ArtifactStoreError.notPermitted(.staysOnDevice)) { try await store.read(local, for: api, byteBudget: 100) }
        await #expect(throws: ArtifactStoreError.notPermitted(.needsGrant)) { try await store.read(personal, for: api, byteBudget: 100) }
        // A bot's ceiling takes more away.
        #expect(await store.manifest(for: .appleOnDevice, ceiling: .open).map(\.ref) == [open])
    }

    @Test func derivedArtifactsInheritTheirSourcesLabelsIncludingLaterRaises() async throws {
        let store = try ArtifactStore()
        let source = try await store.put(draft("Sarah: free after 7", level: .personal, kind: .note, summary: "Chat"))
        let answer = try await store.put(draft("After 7 tonight", level: .open, kind: .toolResult, summary: "When Sarah is free"), derivedFrom: [source])
        #expect(await store.effectiveLabel(of: answer)?.level == .personal)
        #expect(await store.lineage(of: answer) == [source])
        #expect(await store.manifest(for: api).isEmpty)
        // The owner makes the source Device only: everything derived from it follows.
        _ = try await store.put(ArtifactDraft(id: source.id, basedOn: 1, kind: .note, level: .deviceOnly, owner: .owner,
                                              summaryLine: "Chat", content: "Sarah: free after 7"))
        #expect(await store.effectiveLabel(of: answer)?.level == .deviceOnly)
        await #expect(throws: ArtifactStoreError.notPermitted(.staysOnDevice)) {
            try await store.read(answer, for: .applePrivateCloud, byteBudget: 100)
        }
        let entry = try #require(await store.manifest(for: .appleOnDevice).first { $0.ref == answer })
        #expect(entry.sourcesChanged)
    }

    @Test func lineageMustBeCurrentAndReal() async throws {
        let store = try ArtifactStore()
        let source = try await store.put(draft("v1"))
        _ = try await store.put(draft("v2", id: source.id, basedOn: 1))
        await #expect(throws: ArtifactStoreError.invalidLineage) { try await store.put(draft("d"), derivedFrom: [source]) }
        let ghost = ArtifactRef(id: ArtifactID(), revision: 1, sha256: "")
        await #expect(throws: ArtifactStoreError.invalidLineage) { try await store.put(draft("d"), derivedFrom: [ghost]) }
        let current = try #require(await store.latest(source.id))
        await #expect(throws: ArtifactStoreError.invalidLineage) { try await store.put(draft("d"), derivedFrom: [current, current]) }
        await #expect(throws: ArtifactStoreError.invalidLineage) {
            try await store.put(draft("self", id: source.id, basedOn: 2), derivedFrom: [current])
        }
    }

    @Test func revokeCascadesThroughLineageAndErasesContent() async throws {
        let store = try ArtifactStore()
        let root = try await store.put(draft("root"))
        let child = try await store.put(draft("child"), derivedFrom: [root])
        let grandchild = try await store.put(draft("grandchild"), derivedFrom: [child])
        let bystander = try await store.put(draft("bystander"))
        let revoked = try await store.revoke(root.id)
        #expect(Set(revoked) == [root.id, child.id, grandchild.id])
        for ref in [root, child, grandchild] {
            await #expect(throws: ArtifactStoreError.revoked) { try await store.read(ref, for: .appleOnDevice, byteBudget: 100) }
        }
        #expect(await store.manifest(for: .appleOnDevice).map(\.ref) == [bystander])
        await #expect(throws: ArtifactStoreError.revoked) { try await store.put(draft("again", id: root.id, basedOn: 1)) }
        await #expect(throws: ArtifactStoreError.invalidLineage) { try await store.put(draft("late"), derivedFrom: [child]) }
    }

    @Test func everythingSurvivesReopening() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("artifacts.sqlite")
        let (root, child, other): (ArtifactRef, ArtifactRef, ArtifactRef)
        do {
            let store = try ArtifactStore(url: url)
            root = try await store.put(draft("root", level: .personal))
            child = try await store.put(draft("child"), derivedFrom: [root])
            other = try await store.put(draft("other"))
            _ = try await store.revoke(other.id)
        }
        let reopened = try ArtifactStore(url: url)
        #expect(try await reopened.read(child, for: .appleOnDevice, byteBudget: 100).text == "child")
        #expect(await reopened.effectiveLabel(of: child)?.level == .personal)
        #expect(await reopened.lineage(of: child) == [root])
        #expect(await reopened.isRevoked(other.id))
        #expect(await reopened.derivatives(of: root.id) == [child.id])
    }

    @Test func draftsAreBounded() async throws {
        let store = try ArtifactStore()
        await #expect(throws: ArtifactStoreError.self) { try await store.put(draft("x", summary: "  ")) }
        await #expect(throws: ArtifactStoreError.self) { try await store.put(draft("x", summary: "two\nlines")) }
        await #expect(throws: ArtifactStoreError.self) { try await store.put(draft("x", summary: String(repeating: "s", count: 201))) }
    }
}

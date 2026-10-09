import Foundation
import TsukumoCore
import TsukumoPolicy

/// The never-ending context: every file, tool result, turn, and answer is an artifact with
/// revisions. A revision is written once and never changed (a trigger in the database refuses it);
/// a change is a new revision. A turn carries references, not copies, and reads exactly the lines
/// it needs, pinned to a revision and its hash.
///
/// Labels flow down lineage: an artifact is at least as private as every revision it came from,
/// including later revisions of those sources, so raising a source's level reaches everything
/// derived from it. Revoking an artifact erases its content and revokes everything derived from it.
///
/// Schema mined from the app's `MemoryDatabase` (records, dependencies with source revisions) and
/// rules from `ContextBroker` (lineage, cascading revoke) and `ContextPaging` (pinned, untruncated
/// reads).
public actor ArtifactStore {
    public static let maxContentBytes = 8_000_000
    public static let maxSummary = 200
    public static let maxLineage = 64
    public static let maxReadBudget = 1_000_000

    private let database: SQLiteDatabase
    private let clock: @Sendable () -> Date
    /// Every revision's metadata, oldest first per artifact. Content stays in the database.
    private var revisions: [ArtifactID: [Artifact]] = [:]
    private var revoked: Set<ArtifactID> = []
    /// Artifacts derived from each artifact (any revision).
    private var children: [ArtifactID: Set<ArtifactID>] = [:]

    /// A store saved at `url` (created if needed), or a private in-memory one when `url` is nil.
    public init(url: URL? = nil, clock: @escaping @Sendable () -> Date = { Date() }) throws {
        if let url { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        database = try SQLiteDatabase(url: url)
        self.clock = clock
        try Self.migrate(database)
        let loaded = try Self.load(database)
        revisions = loaded.revisions
        revoked = loaded.revoked
        children = loaded.children
    }

    // MARK: Writing

    /// Stores a new artifact, or a new revision of one, derived from `derivedFrom` (each must be a
    /// current, readable revision). Returns its reference. Never overwrites.
    @discardableResult
    public func put(_ draft: ArtifactDraft, derivedFrom lineage: [ArtifactRef] = []) throws -> ArtifactRef {
        let summary = draft.summaryLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty, summary.count <= Self.maxSummary, !summary.contains("\n") else {
            throw ArtifactStoreError.invalidDraft("A summary is one line of up to \(Self.maxSummary) characters.")
        }
        guard draft.content.utf8.count <= Self.maxContentBytes else { throw ArtifactStoreError.invalidDraft("Too big to store.") }
        guard lineage.count <= Self.maxLineage, Set(lineage).count == lineage.count else { throw ArtifactStoreError.invalidLineage }

        let id = draft.id ?? ArtifactID()
        let existing = revisions[id] ?? []
        if draft.id != nil {
            guard !revoked.contains(id) else { throw ArtifactStoreError.revoked }
            let current = existing.last?.ref.revision ?? 0
            guard draft.basedOn == current else { throw ArtifactStoreError.revisionConflict(current: current) }
        } else if draft.basedOn != nil {
            throw ArtifactStoreError.invalidDraft("A new artifact builds on nothing.")
        }
        for source in lineage {
            guard source.id != id, let parent = artifact(source), parent.ref.sha256 == source.sha256,
                  !revoked.contains(source.id), latest(source.id) == source else { throw ArtifactStoreError.invalidLineage }
        }

        let revision = (existing.last?.ref.revision ?? 0) + 1
        let ref = ArtifactRef(id: id, revision: revision, sha256: ArtifactHash.sha256(draft.content))
        let artifact = Artifact(ref: ref, kind: draft.kind, label: draft.label, owner: draft.owner, summaryLine: summary,
                                source: draft.source, lineage: lineage, createdAt: clock(),
                                lineCount: Self.lines(of: draft.content).count, byteCount: draft.content.utf8.count)
        try database.transaction {
            try database.query("""
                INSERT INTO revisions(id, revision, sha256, kind, label_kind, level, owner, summary, source, created, line_count, byte_count, content)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [.text(id.description), .integer(Int64(revision)), .text(ref.sha256), .text(draft.kind.rawValue),
                      .text(draft.label.kind.rawValue), .text(draft.label.level.rawValue), .text(draft.owner.key), .text(summary),
                      draft.source.map { .text($0) } ?? .null, .real(artifact.createdAt.timeIntervalSince1970),
                      .integer(Int64(artifact.lineCount)), .integer(Int64(artifact.byteCount)), .text(draft.content)])
            for (position, source) in lineage.enumerated() {
                try database.query("""
                    INSERT INTO lineage(id, revision, source_id, source_revision, source_sha256, position) VALUES (?, ?, ?, ?, ?, ?)
                    """, [.text(id.description), .integer(Int64(revision)), .text(source.id.description),
                          .integer(Int64(source.revision)), .text(source.sha256), .integer(Int64(position))])
            }
        }
        revisions[id, default: []].append(artifact)
        for source in lineage { children[source.id, default: []].insert(id) }
        return ref
    }

    /// Revokes an artifact and everything derived from it: their content is erased, they leave
    /// every manifest, and every read of them fails. Returns what was revoked.
    @discardableResult
    public func revoke(_ id: ArtifactID) throws -> [ArtifactID] {
        guard revisions[id] != nil else { throw ArtifactStoreError.notFound }
        var affected: [ArtifactID] = [], pending = [id]
        while let next = pending.popLast() {
            guard !affected.contains(next) else { continue }
            affected.append(next)
            pending.append(contentsOf: children[next] ?? [])
        }
        let now = clock()
        try database.transaction {
            for target in affected {
                try database.query("UPDATE revisions SET content = NULL WHERE id = ?", [.text(target.description)])
                try database.query("INSERT OR IGNORE INTO revoked(id, at) VALUES (?, ?)", [.text(target.description), .real(now.timeIntervalSince1970)])
            }
        }
        revoked.formUnion(affected)
        return affected
    }

    // MARK: Reading metadata

    /// One revision's metadata, revoked or not.
    public func artifact(_ ref: ArtifactRef) -> Artifact? {
        revisions[ref.id]?.first { $0.ref.revision == ref.revision }
    }
    /// The current revision of an artifact.
    public func latest(_ id: ArtifactID) -> ArtifactRef? { revisions[id]?.last?.ref }
    /// Every revision of an artifact, oldest first.
    public func history(of id: ArtifactID) -> [ArtifactRef] { revisions[id]?.map(\.ref) ?? [] }
    public func isRevoked(_ id: ArtifactID) -> Bool { revoked.contains(id) }

    /// Every revision this one came from, nearest first, each once.
    public func lineage(of ref: ArtifactRef) -> [ArtifactRef] {
        var result: [ArtifactRef] = [], queue = artifact(ref)?.lineage ?? []
        while !queue.isEmpty {
            let next = queue.removeFirst()
            guard !result.contains(next) else { continue }
            result.append(next)
            queue.append(contentsOf: artifact(next)?.lineage ?? [])
        }
        return result
    }

    /// The artifacts derived from this one, directly or not.
    public func derivatives(of id: ArtifactID) -> [ArtifactID] {
        var result: [ArtifactID] = [], pending = Array(children[id] ?? [])
        while let next = pending.popLast() {
            guard !result.contains(next) else { continue }
            result.append(next)
            pending.append(contentsOf: children[next] ?? [])
        }
        return result
    }

    /// The label the policy decides by: its own, raised to every source's (and every later
    /// revision of a source's).
    public func effectiveLabel(of ref: ArtifactRef) -> TypeLabel? {
        guard let artifact = artifact(ref) else { return nil }
        var visited: Set<ArtifactID> = [ref.id]
        return TypeLabel(kind: artifact.label.kind, level: inheritedLevel(artifact, visited: &visited))
    }

    private func inheritedLevel(_ artifact: Artifact, visited: inout Set<ArtifactID>) -> PrivacyLevel {
        var level = artifact.label.level
        for source in artifact.lineage where !visited.contains(source.id) {
            visited.insert(source.id)
            for candidate in [self.artifact(source), revisions[source.id]?.last].compactMap({ $0 }) {
                level = max(level, inheritedLevel(candidate, visited: &visited))
            }
        }
        return level
    }

    /// What `recipient` may know exists, newest first: the current revision of each artifact it may
    /// read, filtered by the policy before anything about it (even its summary) is listed.
    public func manifest(for recipient: RecipientID, purpose: Purpose = .conversation, grants: [RecipientGrant] = [],
                         ceiling: PrivacyLevel? = nil, kinds: Set<ArtifactKind>? = nil) -> [ManifestEntry] {
        let now = clock()
        var entries: [ManifestEntry] = []
        for (id, list) in revisions where !revoked.contains(id) {
            guard let current = list.last, kinds?.contains(current.kind) ?? true,
                  let label = effectiveLabel(of: current.ref),
                  ContextPolicy.allows(PolicyItem(id: id.description, label: label), to: recipient, purpose: purpose,
                                       grants: grants, ceiling: ceiling, now: now) else { continue }
            let changed = current.lineage.contains { source in (latest(source.id)?.revision ?? 0) != source.revision || revoked.contains(source.id) }
            entries.append(ManifestEntry(ref: current.ref, kind: current.kind, label: label, summaryLine: current.summaryLine, source: current.source,
                                         owner: current.owner, lineCount: current.lineCount, byteCount: current.byteCount,
                                         createdAt: current.createdAt, sourcesChanged: changed))
        }
        return entries.sorted { ($0.createdAt, $0.ref.id.description) > ($1.createdAt, $1.ref.id.description) }
    }

    // MARK: Pinned reads

    /// Exactly `lines` (1-based, inclusive; nil is the whole artifact) of exactly `ref`'s revision,
    /// for `recipient`. Fails when the artifact moved on, the hash doesn't match, the policy says
    /// no, or the text is bigger than `byteBudget`. Never truncates.
    public func read(_ ref: ArtifactRef, lines: ClosedRange<Int>? = nil, for recipient: RecipientID,
                     purpose: Purpose = .conversation, grants: [RecipientGrant] = [], ceiling: PrivacyLevel? = nil,
                     byteBudget: Int) throws -> Page {
        guard (1...Self.maxReadBudget).contains(byteBudget) else { throw ArtifactStoreError.invalidRange }
        guard let current = latest(ref.id), let stored = artifact(ref) else { throw ArtifactStoreError.notFound }
        guard !revoked.contains(ref.id) else { throw ArtifactStoreError.revoked }
        guard let label = effectiveLabel(of: ref) else { throw ArtifactStoreError.notFound }
        let decision = ContextPolicy.evaluate([PolicyItem(id: ref.id.description, label: label)], to: recipient, purpose: purpose,
                                              grants: grants, ceiling: ceiling, now: clock())
        if let denial = decision.denied.values.first { throw ArtifactStoreError.notPermitted(denial) }
        guard current.revision == ref.revision else { throw ArtifactStoreError.staleRevision(current: current.revision) }
        guard stored.ref.sha256 == ref.sha256 else { throw ArtifactStoreError.hashMismatch }
        let rows = try database.query("SELECT content FROM revisions WHERE id = ? AND revision = ?",
                                      [.text(ref.id.description), .integer(Int64(ref.revision))])
        guard let content = rows.first?.first?.text else { throw ArtifactStoreError.revoked }
        guard ArtifactHash.sha256(content) == ref.sha256 else { throw ArtifactStoreError.hashMismatch }
        let all = Self.lines(of: content)
        let range = lines ?? 1...all.count
        guard range.lowerBound >= 1, range.upperBound <= all.count else { throw ArtifactStoreError.invalidRange }
        let text = all[(range.lowerBound - 1)...(range.upperBound - 1)].joined(separator: "\n")
        guard text.utf8.count <= byteBudget else { throw ArtifactStoreError.overBudget(bytes: text.utf8.count, budget: byteBudget) }
        return Page(ref: ref, lines: range, totalLines: all.count, text: text, lineage: stored.lineage, grantsUsed: decision.grantsUsed)
    }

    // MARK: Storage

    static func lines(of text: String) -> [String] { text.components(separatedBy: "\n") }

    private static func migrate(_ database: SQLiteDatabase) throws {
        try database.execute("""
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            INSERT OR IGNORE INTO meta(key, value) VALUES ('schema', '1');
            CREATE TABLE IF NOT EXISTS revisions(
                id TEXT NOT NULL, revision INTEGER NOT NULL CHECK (revision > 0), sha256 TEXT NOT NULL,
                kind TEXT NOT NULL, label_kind TEXT NOT NULL, level TEXT NOT NULL, owner TEXT NOT NULL,
                summary TEXT NOT NULL, source TEXT, created REAL NOT NULL,
                line_count INTEGER NOT NULL, byte_count INTEGER NOT NULL, content TEXT,
                PRIMARY KEY(id, revision));
            CREATE TABLE IF NOT EXISTS lineage(
                id TEXT NOT NULL, revision INTEGER NOT NULL, source_id TEXT NOT NULL, source_revision INTEGER NOT NULL,
                source_sha256 TEXT NOT NULL, position INTEGER NOT NULL,
                PRIMARY KEY(id, revision, source_id, source_revision),
                FOREIGN KEY(id, revision) REFERENCES revisions(id, revision),
                FOREIGN KEY(source_id, source_revision) REFERENCES revisions(id, revision));
            CREATE INDEX IF NOT EXISTS lineage_by_source ON lineage(source_id);
            CREATE TABLE IF NOT EXISTS revoked(id TEXT PRIMARY KEY, at REAL NOT NULL);
            CREATE TRIGGER IF NOT EXISTS revisions_never_change BEFORE UPDATE ON revisions
                WHEN NEW.content IS NOT NULL OR NEW.id IS NOT OLD.id OR NEW.revision IS NOT OLD.revision
                  OR NEW.sha256 IS NOT OLD.sha256 OR NEW.level IS NOT OLD.level OR NEW.summary IS NOT OLD.summary
                BEGIN SELECT RAISE(ABORT, 'revisions never change; only revoking erases content'); END;
            CREATE TRIGGER IF NOT EXISTS revisions_never_deleted BEFORE DELETE ON revisions
                BEGIN SELECT RAISE(ABORT, 'revisions are revoked, never deleted'); END;
            """)
    }

    private static func load(_ database: SQLiteDatabase) throws
        -> (revisions: [ArtifactID: [Artifact]], revoked: Set<ArtifactID>, children: [ArtifactID: Set<ArtifactID>]) {
        var lineage: [String: [ArtifactRef]] = [:]
        for row in try database.query("SELECT id, revision, source_id, source_revision, source_sha256 FROM lineage ORDER BY position") {
            guard let id = row[0].text, let revision = row[1].integer, let source = row[2].text.flatMap(UUID.init(uuidString:)),
                  let sourceRevision = row[3].integer, let sha = row[4].text else { continue }
            lineage["\(id)#\(revision)", default: []].append(ArtifactRef(id: ArtifactID(rawValue: source), revision: Int(sourceRevision), sha256: sha))
        }
        var revisions: [ArtifactID: [Artifact]] = [:], children: [ArtifactID: Set<ArtifactID>] = [:]
        let rows = try database.query("""
            SELECT id, revision, sha256, kind, label_kind, level, owner, summary, source, created, line_count, byte_count
            FROM revisions ORDER BY id, revision
            """)
        for row in rows {
            guard let raw = row[0].text, let uuid = UUID(uuidString: raw), let revision = row[1].integer, let sha = row[2].text,
                  let kind = row[3].text, let labelKind = row[4].text, let level = row[5].text, let owner = row[6].text,
                  let summary = row[7].text, let created = row[9].real, let lineCount = row[10].integer, let byteCount = row[11].integer else { continue }
            let id = ArtifactID(rawValue: uuid)
            let sources = lineage["\(raw)#\(revision)"] ?? []
            let authorData = Data("\"\(owner)\"".utf8), levelData = Data("\"\(level)\"".utf8)
            let artifact = Artifact(
                ref: ArtifactRef(id: id, revision: Int(revision), sha256: sha), kind: ArtifactKind(rawValue: kind),
                label: TypeLabel(kind: ItemKind(rawValue: labelKind), level: (try? JSONDecoder().decode(PrivacyLevel.self, from: levelData)) ?? .secret),
                owner: (try? JSONDecoder().decode(Author.self, from: authorData)) ?? .system, summaryLine: summary, source: row[8].text,
                lineage: sources, createdAt: Date(timeIntervalSince1970: created), lineCount: Int(lineCount), byteCount: Int(byteCount))
            revisions[id, default: []].append(artifact)
            for source in sources { children[source.id, default: []].insert(id) }
        }
        let revoked = Set(try database.query("SELECT id FROM revoked").compactMap { $0[0].text.flatMap(UUID.init(uuidString:)).map(ArtifactID.init(rawValue:)) })
        return (revisions, revoked, children)
    }
}

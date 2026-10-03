import Foundation

/// Fail-closed validation for saved-memory derivation. A derived note remains
/// usable only while every parent is present, enabled, and byte-for-byte bound
/// to the fingerprint captured when the derived note was saved.
enum MemoryPolicy {
    static let maximumDependencyCount = 32
    static let maximumDerivationDepth = 12

    static func valid(_ notes: [MemoryNote]) -> [MemoryNote] {
        let result = evaluate(notes)
        return notes.filter { result.validIDs.contains($0.id) }
    }

    /// Stable topological order for systems that materialize lineage revisions.
    /// Roots precede their valid descendants.
    static func validParentsFirst(_ notes: [MemoryNote]) -> [MemoryNote] {
        let result = evaluate(notes)
        return result.parentFirstIDs.compactMap { result.notesByID[$0] }
    }

    private struct Evaluation {
        let validIDs: Set<UUID>
        let parentFirstIDs: [UUID]
        let notesByID: [UUID: MemoryNote]
    }

    private static func evaluate(_ notes: [MemoryNote]) -> Evaluation {
        let counts = Dictionary(notes.map { ($0.id, 1) }, uniquingKeysWith: +)
        let unique = notes.filter { counts[$0.id] == 1 && ContextPolicy.allows(.memory($0), to: .appleOnDevice) }
        let byID = Dictionary(unique.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var depths: [UUID: Int] = [:]
        var order: [UUID] = []

        for note in unique where note.sourceDependencies == nil {
            depths[note.id] = 0
            order.append(note.id)
        }
        // Iterative resolution bounds work and stack usage even for corrupt files
        // containing extremely deep or cyclic graphs.
        for _ in 1...maximumDerivationDepth {
            var madeProgress = false
            for note in unique where depths[note.id] == nil {
                guard let dependencies = note.sourceDependencies,
                      !dependencies.isEmpty,
                      dependencies.count <= maximumDependencyCount,
                      Set(dependencies.map(\.id)).count == dependencies.count,
                      !dependencies.contains(where: { $0.id == note.id }),
                      dependencies.allSatisfy({ dependency in
                          dependency.fingerprint.count == 64 &&
                          dependency.fingerprint.unicodeScalars.allSatisfy {
                              (48...57).contains($0.value) || (97...102).contains($0.value)
                          } &&
                          byID[dependency.id].map { dependency.fingerprint == PlanningSource.fingerprint($0) } == true
                      }) else { continue }
                let parentDepths = dependencies.compactMap { depths[$0.id] }
                guard parentDepths.count == dependencies.count,
                      let depth = parentDepths.max().map({ $0 + 1 }),
                      depth <= maximumDerivationDepth else { continue }
                depths[note.id] = depth
                order.append(note.id)
                madeProgress = true
            }
            if !madeProgress { break }
        }
        let validIDs = Set(depths.keys)
        return .init(validIDs: validIDs, parentFirstIDs: order.filter(validIDs.contains), notesByID: byID)
    }
}

enum MemoryRecall {
    static func relevant(_ notes: [MemoryNote], to query: String) -> [MemoryNote] {
        let stop: Set<String> = ["the","and","what","about","with","that","this","have","please","kemo","kemosabe","you","your","for","are"]
        func words(_ text: String) -> Set<String> {
            Set(VoiceTurnPolicy.normalized(text).split(separator: " ").map(String.init).filter { $0.count > 2 && !stop.contains($0) })
        }
        let terms = words(query)
        guard !terms.isEmpty else { return [] }
        return MemoryPolicy.valid(notes).enumerated().filter { !words($0.element.text).intersection(terms).isEmpty }.sorted {
            let left = words($0.element.text + " " + $0.element.scope).intersection(terms).count
            let right = words($1.element.text + " " + $1.element.scope).intersection(terms).count
            return left == right ? $0.offset > $1.offset : left > right
        }.prefix(12).map(\.element)
    }
}

struct KnowledgeRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    let agentID: UUID
    let resource: GraphResource
    let specialty: String
    let text: String
    let source: String
    let updatedAt: Date
    let expiresAt: Date?
    var allowedInRemoteModels = false
}
enum KnowledgeRetrieval {
    /// ACL and expiry checks happen BEFORE ranking or prompt assembly. A social
    /// connection and a voice similarity score cannot unlock another Kemo's vault.
    static func context(records: [KnowledgeRecord], agentID: UUID, specialty: String,
                        speaker: SpeakerEvidence, people: [PersonProfile], remote: Bool,
                        now: Date, characterBudget: Int = 4000) -> [KnowledgeRecord] {
        let permitted = records.filter { record in
            record.agentID == agentID && record.specialty == specialty &&
            (record.expiresAt == nil || record.expiresAt! > now) &&
            (!remote || record.allowedInRemoteModels) &&
            SocialGraphPolicy.decide(.readPrivateMemory, speaker: speaker, profiles: people,
                                     resource: record.resource, now: now) == .allow
        }.sorted { $0.updatedAt > $1.updatedAt }
        var remaining = max(0, min(characterBudget, 16_000)), result: [KnowledgeRecord] = []
        for record in permitted.prefix(20) {
            let size = record.text.count + record.source.count
            guard size <= remaining else { continue }
            result.append(record); remaining -= size
        }
        return result
    }
}

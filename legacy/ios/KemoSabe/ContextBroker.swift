import Foundation

/// Orthogonal privacy labels. Combining records can only add labels.
struct BrokerSensitivity: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt8

    static let ordinary = Self(rawValue: 1 << 0)
    static let personal = Self(rawValue: 1 << 1)
    static let company = Self(rawValue: 1 << 2)
    static let child = Self(rawValue: 1 << 3)
    static let health = Self(rawValue: 1 << 4)
    static let secret = Self(rawValue: 1 << 5)
    static let all: Self = [.ordinary, .personal, .company, .child, .health, .secret]

    func containsAll(_ other: Self) -> Bool { intersection(other) == other }
}

enum ContextSourceKind: String, Codable, CaseIterable, Sendable {
    case directUser, savedMemory, connector, peer, companyVault, childProfile, healthStore, derived

    /// Callers cannot relabel a known sensitive source as ordinary.
    var sensitivityFloor: BrokerSensitivity {
        switch self {
        case .directUser, .derived: return .ordinary
        case .savedMemory, .connector, .peer: return [.ordinary, .personal]
        case .companyVault: return [.ordinary, .company]
        case .childProfile: return [.ordinary, .personal, .child]
        case .healthStore: return [.ordinary, .personal, .health]
        }
    }
}

struct ContextSourceAttribution: Codable, Hashable, Sendable {
    let kind: ContextSourceKind
    let identifier: String
    let observedAt: Date
}

struct ContextCompartment: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(stringLiteral value: String) { rawValue = value }

    static let conversation: Self = "conversation"
    static let personalMemory: Self = "personal-memory"
    static func company(_ resourceScopeID: String) -> Self { .init(rawValue: "company:\(resourceScopeID)") }
    static func child(_ resourceScopeID: String) -> Self { .init(rawValue: "child:\(resourceScopeID)") }
    static func health(_ resourceScopeID: String) -> Self { .init(rawValue: "health:\(resourceScopeID)") }

    var sensitivityFloor: BrokerSensitivity {
        if rawValue.hasPrefix("company:") { return [.ordinary, .company] }
        if rawValue.hasPrefix("child:") { return [.ordinary, .personal, .child] }
        if rawValue.hasPrefix("health:") { return [.ordinary, .personal, .health] }
        return self == .personalMemory ? [.ordinary, .personal] : .ordinary
    }

    var isValid: Bool {
        guard !rawValue.isEmpty, rawValue.count <= 180, !rawValue.contains("\0") else { return false }
        if self == .conversation || self == .personalMemory { return true }
        for prefix in ["company:", "child:", "health:"] where rawValue.hasPrefix(prefix) {
            let scope = rawValue.dropFirst(prefix.count)
            return !scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && scope.count <= 160
        }
        return false
    }
}

struct ContextField: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(stringLiteral value: String) { rawValue = value }

    static let text: Self = "text"
    static let title: Self = "title"
    static let summary: Self = "summary"
}

struct ContextPurpose: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(stringLiteral value: String) { rawValue = value }
}

/// nil means unrestricted by this particular record. Joins intersect permissions.
struct ContextRestrictions: Codable, Equatable, Sendable {
    var localOnly: Bool
    var recipientKinds: Set<RecipientKind>?
    var purposes: Set<ContextPurpose>?
    var fields: Set<ContextField>?

    init(localOnly: Bool = false, recipientKinds: Set<RecipientKind>? = nil,
         purposes: Set<ContextPurpose>? = nil, fields: Set<ContextField>? = nil) {
        self.localOnly = localOnly
        self.recipientKinds = recipientKinds
        self.purposes = purposes
        self.fields = fields
    }

    func joined(with other: Self) -> Self {
        Self(localOnly: localOnly || other.localOnly,
             recipientKinds: Self.intersection(recipientKinds, other.recipientKinds),
             purposes: Self.intersection(purposes, other.purposes),
             fields: Self.intersection(fields, other.fields))
    }

    private static func intersection<T>(_ left: Set<T>?, _ right: Set<T>?) -> Set<T>? {
        switch (left, right) {
        case (nil, nil): return nil
        case (.some(let value), nil), (nil, .some(let value)): return value
        case (.some(let left), .some(let right)): return left.intersection(right)
        }
    }
}

struct ContextLineageReference: Codable, Hashable, Sendable {
    let recordID: UUID
    let revision: Int
}

struct AttributedContextRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let ownerID: UUID
    let source: ContextSourceAttribution
    let compartment: ContextCompartment
    let sensitivity: BrokerSensitivity
    /// The level `ContextPolicy` decides by: the declared level, its labels' floor (`PrivacyLevel.floor`),
    /// Device only when it's local-only, and never less than any parent's.
    let level: PrivacyLevel
    let revision: Int
    let updatedAt: Date
    let expiresAt: Date?
    let lineage: [ContextLineageReference]
    /// Every compartment whose data contributed to this value.
    let requiredCompartments: Set<ContextCompartment>
    let restrictions: ContextRestrictions
    let fields: [ContextField: String]
}

struct ContextRecordDraft: Sendable {
    var id: UUID
    let ownerID: UUID
    let source: ContextSourceAttribution
    let compartment: ContextCompartment
    var declaredSensitivity: BrokerSensitivity
    /// The person's level for this record, when it has one. Labels can raise it, never lower it.
    var declaredLevel: PrivacyLevel
    var expiresAt: Date?
    var lineage: [ContextLineageReference]
    var restrictions: ContextRestrictions
    var fields: [ContextField: String]

    init(id: UUID = UUID(), ownerID: UUID, source: ContextSourceAttribution,
         compartment: ContextCompartment, declaredSensitivity: BrokerSensitivity = .ordinary,
         declaredLevel: PrivacyLevel = .open,
         expiresAt: Date? = nil, lineage: [ContextLineageReference] = [],
         restrictions: ContextRestrictions = .init(), fields: [ContextField: String]) {
        self.id = id
        self.ownerID = ownerID
        self.source = source
        self.compartment = compartment
        self.declaredSensitivity = declaredSensitivity
        self.declaredLevel = declaredLevel
        self.expiresAt = expiresAt
        self.lineage = lineage
        self.restrictions = restrictions
        self.fields = fields
    }
}

struct ContextClassificationInput: Sendable {
    let source: ContextSourceAttribution
    let compartment: ContextCompartment
    let fields: [ContextField: String]
    let deterministicFloor: BrokerSensitivity
}

enum ContextClassification: Equatable, Sendable {
    case sensitivity(BrokerSensitivity)
    case unknown
}

protocol LocalContextClassifier: Sendable {
    var runsLocally: Bool { get }
    func classify(_ input: ContextClassificationInput) async throws -> ContextClassification
}

/// Which recipient may receive which record is `ContextPolicy`'s decision, by each record's level.
/// Replacing the broker's policy only starts a new epoch, so no grant or envelope issued before
/// it validates after it.
struct ContextBrokerPolicy: Equatable, Sendable {
    var name: String
    static let conservative = Self(name: "context-policy")
}

struct ContextGrantRequest: Sendable {
    let ownerID: UUID
    let purpose: ContextPurpose
    let recipient: RecipientID
    let fields: Set<ContextField>
    let recordRevisions: [UUID: Int]
    let expiresAt: Date
}

/// Model output is represented explicitly so a privacy opinion can be tested and
/// rejected rather than accidentally treated as host authority.
enum ContextGrantAuthority: Equatable, Sendable {
    case authenticatedOwner(UUID)
    case hostPolicy
    case modelOutput
}

struct ContextDisclosureGrant: Equatable, Sendable {
    let id: UUID
    let ownerID: UUID
    let purpose: ContextPurpose
    let recipient: RecipientID
    let fields: Set<ContextField>
    let recordRevisions: [UUID: Int]
    let expiresAt: Date
    let policyEpoch: Int
    let issuedAt: Date
    /// The authenticated owner approved exactly these records for this recipient: in `ContextPolicy`'s
    /// terms, a grant for each item. A host-policy grant is none.
    let ownerApproved: Bool

    fileprivate init(id: UUID, request: ContextGrantRequest, policyEpoch: Int, issuedAt: Date, ownerApproved: Bool) {
        self.ownerApproved = ownerApproved
        self.id = id
        ownerID = request.ownerID
        purpose = request.purpose
        recipient = request.recipient
        fields = request.fields
        recordRevisions = request.recordRevisions
        expiresAt = request.expiresAt
        self.policyEpoch = policyEpoch
        self.issuedAt = issuedAt
    }
}

struct ContextRetrievalRequest: Sendable {
    let ownerID: UUID
    let purpose: ContextPurpose
    let recipient: RecipientID
    let query: String
    let compartments: Set<ContextCompartment>
    let fields: Set<ContextField>
    let limit: Int

    init(ownerID: UUID, purpose: ContextPurpose, recipient: RecipientID,
         query: String, compartments: Set<ContextCompartment>, fields: Set<ContextField>, limit: Int = 8) {
        self.ownerID = ownerID
        self.purpose = purpose
        self.recipient = recipient
        self.query = query
        self.compartments = compartments
        self.fields = fields
        self.limit = limit
    }
}

struct ContextRecordProjection: Codable, Equatable, Sendable {
    let id: UUID
    let ownerID: UUID
    let source: ContextSourceAttribution
    let compartment: ContextCompartment
    let sensitivity: BrokerSensitivity
    let level: PrivacyLevel
    let revision: Int
    let expiresAt: Date?
    let lineage: [ContextLineageReference]
    let requiredCompartments: Set<ContextCompartment>
    let fields: [ContextField: String]
}

/// Carries no disclosed text. Only the creating broker can resolve its token.
struct DisclosureEnvelope: Equatable, Hashable, Sendable {
    fileprivate let token: UUID
    fileprivate init(token: UUID) { self.token = token }
}

struct ContextDisclosurePayload: Equatable, Sendable {
    let recipient: RecipientID
    let purpose: ContextPurpose
    let records: [ContextRecordProjection]
    let policyEpoch: Int
}

enum ContextBrokerError: Error, Equatable {
    case invalidRecord, invalidRequest, invalidLineage, revisionConflict
    case classifierMustBeLocal, classificationUnknown
    case unauthorized, modelCannotGrant, expired, revoked, stalePolicy, staleRevision
    case envelopeAlreadyUsed
}

/// Host-owned privacy state. Provider-generated text and labels can make a record
/// more restricted, but no model-facing API can mint a grant or envelope.
actor ContextBroker {
    /// Small, purpose-specific context frame. Only revision references are
    /// retained; the envelope never embeds a reusable plaintext transcript.
    /// Identity/provider/policy changes require a newly authorized frame.
    private struct ContextFrame {
        let grantID: UUID
        let ownerID: UUID
        let purpose: ContextPurpose
        let recipient: RecipientID
        let fields: Set<ContextField>
        let recordRevisions: [UUID: Int]
        let expiresAt: Date
        let policyEpoch: Int
        let createdAt: Date
        let ownerApproved: Bool
        var used = false
    }

    private let classifier: (any LocalContextClassifier)?
    private var policy: ContextBrokerPolicy
    private(set) var policyEpoch: Int
    private var records: [UUID: AttributedContextRecord] = [:]
    private var children: [UUID: Set<UUID>] = [:]
    private var revokedRecords: Set<UUID> = []
    private var grants: [UUID: ContextDisclosureGrant] = [:]
    private var revokedGrants: Set<UUID> = []
    private var envelopeFrames: [UUID: ContextFrame] = [:]
    private let maximumGrants = 256
    private let maximumEnvelopeFrames = 128

    init(policy: ContextBrokerPolicy = .conservative, policyEpoch: Int = 1,
         classifier: (any LocalContextClassifier)? = nil) {
        self.policy = policy
        self.policyEpoch = max(1, policyEpoch)
        self.classifier = classifier
    }

    func put(_ draft: ContextRecordDraft, expectedRevision: Int? = nil,
             now: Date = Date()) async throws -> AttributedContextRecord {
        try Self.validate(draft, now: now)
        let old = records[draft.id]
        guard old?.revision == expectedRevision else { throw ContextBrokerError.revisionConflict }
        let startingEpoch = policyEpoch
        let startingRevision = old?.revision

        var sensitivity = draft.declaredSensitivity
            .union(draft.source.kind.sensitivityFloor)
            .union(draft.compartment.sensitivityFloor)
        var restrictions = draft.restrictions
        if Self.containsCredentialMaterial(draft.fields) {
            sensitivity.formUnion([.ordinary, .personal, .secret])
            restrictions.localOnly = true
        }
        var expiresAt = draft.expiresAt
        var requiredCompartments: Set<ContextCompartment> = [draft.compartment]
        var parents: [AttributedContextRecord] = []
        var parentLevel = PrivacyLevel.open
        for reference in draft.lineage {
            guard reference.recordID != draft.id,
                  let parent = records[reference.recordID], parent.ownerID == draft.ownerID,
                  parent.revision == reference.revision,
                  try isActive(parent, now: now, visiting: []) else { throw ContextBrokerError.invalidLineage }
            parents.append(parent)
            parentLevel = max(parentLevel, parent.level)
            sensitivity.formUnion(parent.sensitivity)
            restrictions = restrictions.joined(with: parent.restrictions)
            expiresAt = Self.earlier(expiresAt, parent.expiresAt)
            requiredCompartments.formUnion(parent.requiredCompartments)
        }
        if draft.source.kind == .derived {
            guard !draft.lineage.isEmpty else { throw ContextBrokerError.invalidLineage }
        } else if !draft.lineage.isEmpty {
            throw ContextBrokerError.invalidLineage
        }

        if restrictions.localOnly {
            // A classifier cannot make this record less restricted, so there is no
            // reason to put a local-only connector read on the model critical path.
        } else if let classifier {
            guard classifier.runsLocally else { throw ContextBrokerError.classifierMustBeLocal }
            let input = ContextClassificationInput(source: draft.source, compartment: draft.compartment,
                fields: draft.fields, deterministicFloor: sensitivity)
            switch try await classifier.classify(input) {
            case .unknown:
                // Uncertainty denies all remote disclosure without making local,
                // offline memory availability depend on classifier readiness.
                restrictions.localOnly = true
            case .sensitivity(let raised): sensitivity.formUnion(raised)
            }
        } else {
            // Offline ingestion remains available, but absence of a classifier is
            // not evidence that content is safe to leave the device.
            restrictions.localOnly = true
        }
        // The actor may have admitted another mutation while awaiting classification.
        guard policyEpoch == startingEpoch, records[draft.id]?.revision == startingRevision else {
            throw ContextBrokerError.stalePolicy
        }

        if old != nil { revokeDescendants(of: draft.id, includeRoot: false) }
        let revision = (old?.revision ?? 0) + 1
        let level = max(draft.declaredLevel, PrivacyLevel.floor(sensitivity), parentLevel,
                        restrictions.localOnly ? .deviceOnly : .open)
        let saved = AttributedContextRecord(id: draft.id, ownerID: draft.ownerID, source: draft.source,
            compartment: draft.compartment, sensitivity: sensitivity, level: level, revision: revision,
            updatedAt: now, expiresAt: expiresAt, lineage: draft.lineage,
            requiredCompartments: requiredCompartments,
            restrictions: restrictions, fields: draft.fields)
        records[saved.id] = saved
        revokedRecords.remove(saved.id)
        for parent in parents { children[parent.id, default: []].insert(saved.id) }
        invalidateFrames(containing: [saved.id])
        return saved
    }

    func record(id: UUID, ownerID: UUID, now: Date = Date()) throws -> AttributedContextRecord? {
        guard let value = records[id], value.ownerID == ownerID,
              try isActive(value, now: now, visiting: []) else { return nil }
        return value
    }

    func mintGrant(_ request: ContextGrantRequest, authority: ContextGrantAuthority,
                   now: Date = Date()) throws -> ContextDisclosureGrant {
        pruneCaches(now: now)
        switch authority {
        case .modelOutput: throw ContextBrokerError.modelCannotGrant
        case .authenticatedOwner(let ownerID): guard ownerID == request.ownerID else { throw ContextBrokerError.unauthorized }
        case .hostPolicy: break
        }
        try Self.validate(request, now: now)
        for (id, revision) in request.recordRevisions {
            guard let value = records[id], value.ownerID == request.ownerID,
                  value.revision == revision else { throw ContextBrokerError.staleRevision }
            try authorize(value, recipient: request.recipient, purpose: request.purpose,
                          fields: request.fields, ownerApproved: ownerApproved(authority), now: now)
        }
        makeGrantRoom()
        let grant = ContextDisclosureGrant(id: UUID(), request: request, policyEpoch: policyEpoch, issuedAt: now,
                                           ownerApproved: ownerApproved(authority))
        grants[grant.id] = grant
        return grant
    }

    /// Authorization happens before term extraction and ranking. A query that only
    /// matches forbidden data returns no fallback records.
    func retrieve(_ request: ContextRetrievalRequest, using grant: ContextDisclosureGrant,
                  now: Date = Date()) throws -> [ContextRecordProjection] {
        guard request.limit > 0, request.limit <= 50, request.query.count <= 512,
              !request.compartments.isEmpty, !request.fields.isEmpty else { throw ContextBrokerError.invalidRequest }
        try validate(grant, ownerID: request.ownerID, recipient: request.recipient,
                     purpose: request.purpose, fields: request.fields, now: now)

        var permitted: [AttributedContextRecord] = []
        for (id, revision) in grant.recordRevisions {
            guard let value = records[id], value.revision == revision,
                  request.compartments.isSuperset(of: value.requiredCompartments) else { continue }
            do {
                try authorize(value, recipient: request.recipient, purpose: request.purpose,
                              fields: request.fields, ownerApproved: grant.ownerApproved, now: now)
                permitted.append(value)
            } catch { continue }
        }
        let terms = Self.terms(request.query, limit: 32)
        guard !terms.isEmpty else { return [] }
        let ranked = permitted.compactMap { value -> (AttributedContextRecord, Int)? in
            let searchable = request.fields.compactMap { value.fields[$0] }.joined(separator: " ")
            let score = Self.terms(searchable).intersection(terms).count
            guard score > 0 else { return nil }
            return (value, score)
        }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.0.updatedAt != $1.0.updatedAt { return $0.0.updatedAt > $1.0.updatedAt }
            return $0.0.id.uuidString < $1.0.id.uuidString
        }
        return ranked.prefix(request.limit).map { project($0.0, fields: request.fields) }
    }

    func makeEnvelope(recordIDs: [UUID], using grant: ContextDisclosureGrant,
                      fields: Set<ContextField>, now: Date = Date()) throws -> DisclosureEnvelope {
        pruneCaches(now: now)
        guard !recordIDs.isEmpty, recordIDs.count <= 50, Set(recordIDs).count == recordIDs.count,
              !fields.isEmpty else { throw ContextBrokerError.invalidRequest }
        try validate(grant, ownerID: grant.ownerID, recipient: grant.recipient,
                     purpose: grant.purpose, fields: fields, now: now)
        var references: [UUID: Int] = [:]
        for id in recordIDs {
            guard let revision = grant.recordRevisions[id], let value = records[id],
                  value.revision == revision else { throw ContextBrokerError.staleRevision }
            try authorize(value, recipient: grant.recipient, purpose: grant.purpose, fields: fields,
                          ownerApproved: grant.ownerApproved, now: now)
            references[id] = revision
        }
        makeEnvelopeRoom()
        let token = UUID()
        envelopeFrames[token] = ContextFrame(grantID: grant.id, ownerID: grant.ownerID,
            purpose: grant.purpose, recipient: grant.recipient, fields: fields,
            recordRevisions: references, expiresAt: grant.expiresAt, policyEpoch: policyEpoch,
            createdAt: now, ownerApproved: grant.ownerApproved)
        return DisclosureEnvelope(token: token)
    }

    /// Call immediately before transmission. Successful validation consumes the
    /// envelope so a provider retry needs a fresh policy decision.
    func validateForSend(_ envelope: DisclosureEnvelope, recipient: RecipientID,
                         purpose: ContextPurpose, now: Date = Date()) throws -> ContextDisclosurePayload {
        guard var frame = envelopeFrames[envelope.token] else { throw ContextBrokerError.revoked }
        guard !frame.used else { throw ContextBrokerError.envelopeAlreadyUsed }
        let values = try currentRecords(frame, recipient: recipient, purpose: purpose, now: now)
        frame.used = true
        envelopeFrames[envelope.token] = frame
        return ContextDisclosurePayload(recipient: recipient, purpose: purpose,
            records: values.map { project($0, fields: frame.fields) }, policyEpoch: policyEpoch)
    }

    /// Call when a response arrives: confirms that what an envelope already disclosed is still
    /// permitted (not revoked, expired, re-policied, or edited since), without allowing another send.
    func confirmStillPermitted(_ envelope: DisclosureEnvelope, recipient: RecipientID,
                               purpose: ContextPurpose, now: Date = Date()) throws {
        guard let frame = envelopeFrames[envelope.token] else { throw ContextBrokerError.revoked }
        guard frame.used else { throw ContextBrokerError.unauthorized }
        _ = try currentRecords(frame, recipient: recipient, purpose: purpose, now: now)
    }
    /// The checks shared by sending and confirming: policy, expiry, recipient, grant, and record revisions.
    private func currentRecords(_ frame: ContextFrame, recipient: RecipientID,
                                purpose: ContextPurpose, now: Date) throws -> [AttributedContextRecord] {
        guard frame.policyEpoch == policyEpoch else { throw ContextBrokerError.stalePolicy }
        guard frame.expiresAt > now else { throw ContextBrokerError.expired }
        guard frame.recipient == recipient, frame.purpose == purpose else { throw ContextBrokerError.unauthorized }
        guard let grant = grants[frame.grantID], !revokedGrants.contains(frame.grantID) else { throw ContextBrokerError.revoked }
        try validate(grant, ownerID: frame.ownerID, recipient: recipient,
                     purpose: purpose, fields: frame.fields, now: now)
        return try frame.recordRevisions.map { id, revision -> AttributedContextRecord in
            guard let value = records[id], value.ownerID == frame.ownerID,
                  value.revision == revision else { throw ContextBrokerError.staleRevision }
            try authorize(value, recipient: recipient, purpose: purpose, fields: frame.fields,
                          ownerApproved: frame.ownerApproved, now: now)
            return value
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    func revoke(recordID: UUID, ownerID: UUID) throws {
        guard records[recordID]?.ownerID == ownerID else { throw ContextBrokerError.unauthorized }
        revokeDescendants(of: recordID, includeRoot: true)
    }

    func revoke(grantID: UUID, ownerID: UUID) throws {
        guard grants[grantID]?.ownerID == ownerID else { throw ContextBrokerError.unauthorized }
        revokedGrants.insert(grantID)
        envelopeFrames = envelopeFrames.filter { $0.value.grantID != grantID }
    }

    func replacePolicy(_ policy: ContextBrokerPolicy) {
        self.policy = policy
        policyEpoch += 1
        // Retain opaque frames so the send-time check reports the epoch mismatch.
        // No stale frame can validate under the new policy.
    }

    private func validate(_ grant: ContextDisclosureGrant, ownerID: UUID, recipient: RecipientID,
                          purpose: ContextPurpose, fields: Set<ContextField>, now: Date) throws {
        guard let current = grants[grant.id], current == grant, !revokedGrants.contains(grant.id) else {
            throw ContextBrokerError.revoked
        }
        guard grant.policyEpoch == policyEpoch else { throw ContextBrokerError.stalePolicy }
        guard grant.expiresAt > now else { throw ContextBrokerError.expired }
        guard grant.ownerID == ownerID, grant.recipient == recipient, grant.purpose == purpose,
              grant.fields.isSuperset(of: fields) else { throw ContextBrokerError.unauthorized }
    }

    private func ownerApproved(_ authority: ContextGrantAuthority) -> Bool {
        if case .authenticatedOwner = authority { return true }
        return false
    }

    /// `ContextPolicy` decides by the record's level; an owner-approved grant is a grant for this record.
    private func authorize(_ value: AttributedContextRecord, recipient: RecipientID,
                           purpose: ContextPurpose, fields: Set<ContextField>, ownerApproved: Bool, now: Date) throws {
        guard try isActive(value, now: now, visiting: []) else { throw ContextBrokerError.revoked }
        guard fields.isSubset(of: Set(value.fields.keys)) else { throw ContextBrokerError.unauthorized }
        let item = ContextItem(.init(.record, value.id), level: value.level)
        let grants = ownerApproved ? [RecipientGrant(recipient: recipient, items: [item.ref], purpose: purpose)] : []
        guard ContextPolicy.allows(item, to: recipient, purpose: purpose, grants: grants, now: now) else {
            throw ContextBrokerError.unauthorized
        }
        let restrictions = value.restrictions
        guard !restrictions.localOnly || recipient.locality == .onDevice,
              restrictions.recipientKinds?.contains(recipient.kind) ?? true,
              restrictions.purposes?.contains(purpose) ?? true,
              restrictions.fields?.isSuperset(of: fields) ?? true else { throw ContextBrokerError.unauthorized }
    }

    private func isActive(_ value: AttributedContextRecord, now: Date,
                          visiting: Set<UUID>) throws -> Bool {
        guard !visiting.contains(value.id), !revokedRecords.contains(value.id),
              value.expiresAt.map({ $0 > now }) ?? true else { return false }
        for reference in value.lineage {
            guard let parent = records[reference.recordID], parent.ownerID == value.ownerID,
                  parent.revision == reference.revision,
                  try isActive(parent, now: now, visiting: visiting.union([value.id])) else { return false }
        }
        return true
    }

    private func revokeDescendants(of id: UUID, includeRoot: Bool) {
        var pending = Array(children[id] ?? []), affected: Set<UUID> = includeRoot ? [id] : []
        while let next = pending.popLast() {
            guard !affected.contains(next) else { continue }
            affected.insert(next)
            pending.append(contentsOf: children[next] ?? [])
        }
        revokedRecords.formUnion(affected)
        invalidateFrames(containing: affected)
    }

    private func invalidateFrames(containing ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        envelopeFrames = envelopeFrames.filter { ids.isDisjoint(with: Set($0.value.recordRevisions.keys)) }
        let affectedGrantIDs = Set(grants.values.filter { !ids.isDisjoint(with: Set($0.recordRevisions.keys)) }.map(\.id))
        revokedGrants.formUnion(affectedGrantIDs)
    }

    private func pruneCaches(now: Date) {
        let deadGrants = Set(grants.values.filter {
            $0.expiresAt <= now || $0.policyEpoch != policyEpoch || revokedGrants.contains($0.id)
        }.map(\.id))
        for id in deadGrants { grants[id] = nil; revokedGrants.remove(id) }
        envelopeFrames = envelopeFrames.filter {
            !$0.value.used && $0.value.expiresAt > now &&
                $0.value.policyEpoch == policyEpoch && grants[$0.value.grantID] != nil
        }
    }

    private func makeGrantRoom() {
        while grants.count >= maximumGrants, let oldest = grants.values.min(by: {
            $0.issuedAt == $1.issuedAt ? $0.id.uuidString < $1.id.uuidString : $0.issuedAt < $1.issuedAt
        }) {
            grants[oldest.id] = nil
            revokedGrants.remove(oldest.id)
            envelopeFrames = envelopeFrames.filter { $0.value.grantID != oldest.id }
        }
    }

    private func makeEnvelopeRoom() {
        while envelopeFrames.count >= maximumEnvelopeFrames, let oldest = envelopeFrames.min(by: {
            $0.value.createdAt == $1.value.createdAt ? $0.key.uuidString < $1.key.uuidString : $0.value.createdAt < $1.value.createdAt
        }) {
            envelopeFrames[oldest.key] = nil
        }
    }

    private func project(_ value: AttributedContextRecord, fields: Set<ContextField>) -> ContextRecordProjection {
        ContextRecordProjection(id: value.id, ownerID: value.ownerID, source: value.source,
            compartment: value.compartment, sensitivity: value.sensitivity, level: value.level, revision: value.revision,
            expiresAt: value.expiresAt, lineage: value.lineage,
            requiredCompartments: value.requiredCompartments,
            fields: value.fields.filter { fields.contains($0.key) })
    }

    private static func terms(_ text: String, limit: Int = Int.max) -> Set<String> {
        let stop: Set<String> = ["the", "and", "what", "about", "with", "that", "this", "have",
                                 "please", "kemo", "kemosabe", "you", "your", "for", "are"]
        return Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }
            .map(String.init).filter { $0.count > 2 && !stop.contains($0) }.prefix(limit))
    }

    /// Narrow deterministic floor, not an exhaustive secret scanner.
    private static func containsCredentialMaterial(_ fields: [ContextField: String]) -> Bool {
        let names: Set<String> = ["password", "token", "secret", "privatekey"]
        if fields.keys.contains(where: {
            names.contains($0.rawValue.lowercased().filter { $0.isLetter || $0.isNumber })
        }) { return true }
        let headers = ["-----BEGIN PRIVATE KEY-----", "-----BEGIN RSA PRIVATE KEY-----",
                       "-----BEGIN EC PRIVATE KEY-----", "-----BEGIN OPENSSH PRIVATE KEY-----"]
        return fields.values.contains { value in headers.contains(where: value.contains) }
    }

    private static func earlier(_ left: Date?, _ right: Date?) -> Date? {
        switch (left, right) {
        case (nil, nil): return nil
        case (.some(let value), nil), (nil, .some(let value)): return value
        case (.some(let left), .some(let right)): return min(left, right)
        }
    }

    private static func validate(_ draft: ContextRecordDraft, now: Date) throws {
        let total = draft.fields.values.reduce(0) { $0 + $1.utf8.count }
        guard valid(draft.source.identifier, maximum: 512), !draft.fields.isEmpty,
              draft.compartment.isValid,
              draft.fields.count <= 32, total <= 64_000,
              draft.fields.allSatisfy({ valid($0.key.rawValue, maximum: 80) && valid($0.value, maximum: 32_000) }),
              draft.lineage.count <= 32, Set(draft.lineage.map(\.recordID)).count == draft.lineage.count,
              draft.lineage.allSatisfy({ $0.revision > 0 }),
              draft.expiresAt.map({ $0 > now }) ?? true else { throw ContextBrokerError.invalidRecord }
    }

    private static func validate(_ request: ContextGrantRequest, now: Date) throws {
        guard valid(request.purpose.rawValue, maximum: 80), !request.fields.isEmpty,
              request.fields.count <= 32, request.fields.allSatisfy({ valid($0.rawValue, maximum: 80) }),
              !request.recordRevisions.isEmpty, request.recordRevisions.count <= 50,
              request.recordRevisions.values.allSatisfy({ $0 > 0 }), request.expiresAt > now else {
            throw ContextBrokerError.invalidRequest
        }
    }

    private static func valid(_ text: String, maximum: Int) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            text.count <= maximum && !text.contains("\0")
    }
}

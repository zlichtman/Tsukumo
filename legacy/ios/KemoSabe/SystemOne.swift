import Foundation
import Observation

// System One (September 27, 2026): fast typed decisions beside the conversation model. Laya decides
// on this device first (with the person's own layer, trained here from their Right and Wrong marks,
// where it beat the base); when it abstains, each hosted service the person turned on (Jev today)
// is asked in order, only if the chat's privacy level lets that request go to another company;
// otherwise, and whenever all abstain, the caller keeps today's deterministic rules and Apple
// routing. A decision is advice among options the caller already permits: it never grants a tool,
// a write, or a disclosure. See design/UNIFIED-HARNESS.md ("Laya / Jev decision layer") and
// design/LAYA-TRAINING.md.

/// The decisions the design names. Each has its own abstention threshold.
enum DecisionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case routineIntent, interruptionTiming, missingInformation, candidateFit
    var id: String { rawValue }
    var title: String {
        switch self {
        case .routineIntent: "Routine intent"
        case .interruptionTiming: "Interruption timing"
        case .missingInformation: "Missing information"
        case .candidateFit: "Plan fit"
        }
    }
    /// What it decides and where, in one line for Models → System One.
    var detail: String {
        switch self {
        case .routineIntent: "What you're asking for: an answer, a day plan, a draft, a reminder."
        case .interruptionTiming: "KemoSabe doesn't interrupt you on its own yet, so nothing asks this today."
        case .missingInformation: "Whether a day-planning request says what to schedule and which day, so KemoSabe asks first."
        case .candidateFit: "Which of the permitted free times best fits what you asked."
        }
    }
    /// Whether the app asks this question today.
    var inUse: Bool { self != .interruptionTiming }
    /// Below this top probability the provider abstains. Measured September 27, 2026 through the
    /// Swift path on the Mac (design/LAYA-TRAINING.md, "Activation"): missing information is the
    /// calibration split's own choice; plan fit keeps the earlier 0.8 floor (every calibration
    /// case was right); interruption timing's scores sat at 0.61–0.65 whatever the answer, so it
    /// stays at 0.9 and unused; routine intent's calibration choice (0.78) let a whole test
    /// family through confidently wrong (0.94), so it was raised to 0.95 after seeing the test
    /// split, which that split can no longer certify.
    var threshold: Double {
        switch self {
        case .routineIntent: 0.95
        case .interruptionTiming: 0.9
        case .missingInformation: 0.65
        case .candidateFit: 0.8
        }
    }
}

/// Who made a decision. Laya runs on this device; the others are hosted services, asked in this
/// order after Laya, each only with the person's own key and only for chats whose level allows it.
enum SystemOneSource: String, Codable, Sendable {
    case laya, jev, openAIDecisions, fallback
    var title: String {
        switch self {
        case .laya: "Laya"
        case .jev: "Jev"
        case .openAIDecisions: "OpenAI Decisions"
        case .fallback: "Apple routing"
        }
    }
}

/// Which part of Laya answered: the base model, or the base with the person's own layer trained on
/// this device from their Right and Wrong marks (`SystemOnePersonal.swift`).
enum SystemOneLayer: String, Codable, Sendable {
    case base, personal
    var title: String { self == .base ? "base" : "personal layer" }
}

/// One provider's part in a decision. No request words: only who, which version, and how sure.
struct SystemOneStep: Codable, Equatable, Sendable {
    enum Reason: String, Codable, Sendable {
        /// Its top probability was below the decision's threshold.
        case lowConfidence
        /// Outside what it was evaluated on: another script, no words, or over its length limit.
        case outOfDistribution
        /// The chat's privacy level keeps this request from that service.
        case privacy
        /// Not available right now (loading, busy, offline, timed out, or an error).
        case unavailable
        /// The key was refused, or the rate limit was reached.
        case rejected
    }
    let provider: SystemOneSource
    let version: String
    /// The lowest top probability across the request's questions.
    let score: Double?
    let reason: Reason?
    var abstained: Bool { reason != nil }
    /// Where the request went; nil when it stayed on this device.
    var sentTo: String?
    /// Laya's layer for this step (nil for hosted services, and in records from before layers).
    var layer: SystemOneLayer?
    init(provider: SystemOneSource, version: String, score: Double?, reason: Reason?, sentTo: String? = nil, layer: SystemOneLayer? = nil) {
        self.provider = provider; self.version = version; self.score = score; self.reason = reason; self.sentTo = sentTo; self.layer = layer
    }
}

/// One decision, as the journal keeps it.
struct SystemOneRecord: Codable, Equatable, Identifiable, Sendable {
    /// One question of the decision: its choices, what Laya's base gave each, what the personal
    /// layer gave (when it ran), and the answer used. Never the request's words.
    struct Question: Codable, Equatable, Sendable {
        let id: String
        let options: [String]
        /// Laya's base probabilities, in option order; nil when Laya didn't score it.
        var laya: [Double]?
        /// The personal layer's probabilities, when it ran.
        var personal: [Double]?
        /// The option System One decided; nil when all abstained and the app's fallback decided.
        var answer: Int?
        init(id: String, options: [String], laya: [Double]? = nil, personal: [Double]? = nil, answer: Int? = nil) {
            self.id = id; self.options = options; self.laya = laya; self.personal = personal; self.answer = answer
        }
        /// What to show and mark: the decided answer, or else where Laya leaned.
        var shown: Int? {
            if let answer { return answer }
            guard let scores = personal ?? laya else { return nil }
            return scores.indices.max { scores[$0] < scores[$1] }
        }
    }
    var id = UUID()
    let at: Date
    let kind: DecisionKind
    let decidedBy: SystemOneSource
    let steps: [SystemOneStep]
    let milliseconds: Int
    /// The questions, from September 29, 2026; nil in older records.
    var questions: [Question]?
    /// Laya's layer, when Laya decided.
    var layer: SystemOneLayer?
    /// The question the person can mark Right or Wrong: the first, when Laya scored it.
    var markable: Question? {
        guard let first = questions?.first, first.laya?.count == first.options.count, first.shown != nil, first.options.count >= 2 else { return nil }
        return first
    }
}

/// Where System One keeps its files for the current account: the journal, the person's marks, and
/// the personal layer. Device only: excluded from backup, and never synced (account sync carries
/// its own records, not this folder's files).
enum SystemOneStorage {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var override: URL?
    /// A private folder for UI tests (`--system-one-fixture`).
    static var fixtureFolder: URL? {
        get { lock.withLock { override } }
        set { lock.withLock { override = newValue } }
    }
    static var folder: URL { fixtureFolder ?? AccountDirectory.currentFolder }
    /// Writes a small file with complete protection, its folder kept out of backups.
    static func write(_ data: Data, to url: URL) throws {
        try AccountDirectory.checkWrite(to: url)
        var folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }
}

/// The last 50 decisions in this account, so the person can see System One working and mark them.
actor SystemOneJournal {
    static let limit = 50
    static let didRecord = Notification.Name("kemo.systemOne.didRecord")
    static let fileName = "system-one-decisions.json"
    /// The current account's journal. Resolved on each use, so an account switch follows.
    static var current: SystemOneJournal { SystemOneJournal(url: SystemOneStorage.folder.appendingPathComponent(fileName)) }
    private struct Document: Codable { var version = 1; var records: [SystemOneRecord] = [] }
    private let url: URL
    init(url: URL) { self.url = url }
    func records() -> [SystemOneRecord] {
        guard let data = try? Data(contentsOf: url), let document = try? JSONDecoder().decode(Document.self, from: data),
              document.version == 1 else { return [] }
        return Array(document.records.suffix(Self.limit))
    }
    func append(_ record: SystemOneRecord) {
        var document = Document(records: records())
        document.records = Array((document.records + [record]).suffix(Self.limit))
        do { try SystemOneStorage.write(JSONEncoder().encode(document), to: url) }
        catch { return }  // Diagnostics never block a decision.
        Task { @MainActor in NotificationCenter.default.post(name: Self.didRecord, object: nil) }
    }
    func clear() { try? FileManager.default.removeItem(at: url) }
    /// Writes records directly, for the UI test's fixture.
    nonisolated static func write(_ records: [SystemOneRecord], to url: URL) {
        try? SystemOneStorage.write(JSONEncoder().encode(Document(records: records)), to: url)
    }
}

/// The switches and the Jev key. "Use Laya" is the person's choice for the account, so it syncs to
/// their other devices (an account setting, `AccountSettingsAdapter`); Laya's files stay on each
/// device. Jev's switch stays with its key on this device: turning it on is the consent for this
/// device's key, so it never turns on elsewhere by sync.
@MainActor @Observable final class SystemOneSettings {
    static let shared = SystemOneSettings()
    nonisolated static let layaKey = "kemo.systemOne.laya.enabled"
    nonisolated static let jevKey = "kemo.systemOne.jev.enabled"
    let keys: any JevKeyStoring
    private let defaults: UserDefaults
    /// Where "Use Laya" is kept: the open account's settings (they follow an account switch).
    @ObservationIgnored private let accountDefaults: () -> UserDefaults
    /// Changes when "Use Laya" does, here or by sync, so views follow.
    private var revision = 0
    /// On by default once downloaded.
    var layaEnabled: Bool {
        get { _ = revision; return accountDefaults().object(forKey: Self.layaKey) as? Bool ?? true }
        set { accountDefaults().set(newValue, forKey: Self.layaKey); revision += 1 }
    }
    /// On once the person adds a key and accepts where requests go.
    var jevEnabled: Bool { didSet { defaults.set(jevEnabled, forKey: Self.jevKey) } }
    private(set) var hasJevKey: Bool

    /// `accountDefaults` defaults to the account's settings for the app, and to `defaults` itself when a
    /// test gives its own.
    init(keys: any JevKeyStoring = KeychainJevKey(), defaults: UserDefaults = AccountDirectory.settings, accountDefaults: (() -> UserDefaults)? = nil) {
        self.keys = keys; self.defaults = defaults
        self.accountDefaults = accountDefaults ?? (defaults === AccountDirectory.settings ? { AccountDirectory.accountSettings } : { defaults })
        jevEnabled = defaults.object(forKey: Self.jevKey) as? Bool ?? false
        hasJevKey = keys.exists()
        // Before it synced, "Use Laya" was a device setting: carry it into the account once.
        let account = self.accountDefaults()
        if account !== defaults, account.object(forKey: Self.layaKey) == nil, let saved = defaults.object(forKey: Self.layaKey) as? Bool {
            account.set(saved, forKey: Self.layaKey)
        }
    }
    var jevActive: Bool { jevEnabled && hasJevKey }
    /// Saving the key is the person's acceptance of where requests go (the confirmation names
    /// api.typesafe.ai), so Jev turns on with it. The key is read back first, so a save the
    /// Keychain didn't keep is reported rather than shown as Active.
    func saveJevKey(_ key: String) throws {
        try keys.save(key)
        guard keys.read() == JevKey.normalized(key) else { throw JevKeyError.notSaved }
        hasJevKey = true; jevEnabled = true
    }
    func removeJevKey() throws {
        try keys.remove(); hasJevKey = false; jevEnabled = false
    }
    /// Checks again whether a key is saved (the page does this each time it shows), and re-reads the
    /// synced "Use Laya".
    func refresh() { hasJevKey = keys.exists(); revision += 1 }
    /// Whether a chat at this level can reach Jev at all. The lock on the model button uses this.
    func jevMayReceive(_ level: PrivacyLevel) -> Bool { jevActive && SystemOne.jevMayReceive(level) }
}

/// A hosted decision service asked after Laya: Jev today, OpenAI Decisions once OpenAI publishes
/// its API. Each is its own recipient at a fixed host, and turning it on is the person's grant for
/// Personal requests (`consent`); `SystemOne.decide` checks `ContextPolicy` for each one before its
/// packet leaves, so only Open and Personal chats reach any of them, and only the request's words
/// and the choices go.
struct SystemOneRemote: Sendable {
    let source: SystemOneSource
    let host: String
    let recipient: RecipientID
    let provider: any DecisionProvider
    var consent: RecipientGrant { SystemOne.consent(for: recipient) }
    static func jev(_ provider: any DecisionProvider) -> SystemOneRemote {
        .init(source: .jev, host: JevDecisionProvider.host, recipient: SystemOne.jevRecipient, provider: provider)
    }
}

/// The providers one decision may use, resolved from settings when it starts.
struct SystemOneProviders: Sendable {
    var laya: (any DecisionProvider)?
    /// Hosted services after Laya, in the order they're asked.
    var remotes: [SystemOneRemote]
    var journal: SystemOneJournal?
    /// Test grants added to the person's consent for each service.
    var grants: [RecipientGrant]
    /// The person's own layer over Laya's base scores, for the decisions where it beat the base.
    var personal: SystemOnePersonalModel?

    init(laya: (any DecisionProvider)?, remotes: [SystemOneRemote], journal: SystemOneJournal?,
         grants: [RecipientGrant] = [], personal: SystemOnePersonalModel? = nil) {
        self.laya = laya; self.remotes = remotes; self.journal = journal; self.grants = grants; self.personal = personal
    }
    /// Laya, then Jev when there is one.
    init(laya: (any DecisionProvider)?, jev: (any DecisionProvider)?, journal: SystemOneJournal?, personal: SystemOnePersonalModel? = nil) {
        self.init(laya: laya, remotes: jev.map { [.jev($0)] } ?? [], journal: journal, personal: personal)
    }
    var jev: (any DecisionProvider)? { remotes.first { $0.source == .jev }?.provider }

    static let none = SystemOneProviders(laya: nil, remotes: [], journal: nil)
    /// Laya when it's on and downloaded (with the personal layer where it's on); Jev when it's on
    /// and has a key; the account's journal.
    static func current() -> SystemOneProviders {
        _ = LayaModel.watchMemory
        return resolve(defaults: AccountDirectory.settings, keys: KeychainJevKey(), layaAvailable: LayaModel.isAvailable(),
                       folder: SystemOneStorage.folder)
    }
    /// `current()` with every input named, so tests walk the same path.
    static func resolve(defaults: UserDefaults, keys: any JevKeyStoring, layaAvailable: Bool, folder: URL,
                        laya makeLaya: () -> any DecisionProvider = { CoreMLLayaProvider.shared },
                        jevEndpoint: URL = JevDecisionProvider.endpoint, session: URLSession = .shared) -> SystemOneProviders {
        let layaOn = defaults.object(forKey: SystemOneSettings.layaKey) as? Bool ?? true
        let jevOn = defaults.object(forKey: SystemOneSettings.jevKey) as? Bool ?? false
        let laya: (any DecisionProvider)? = layaOn && layaAvailable ? makeLaya() : nil
        var remotes: [SystemOneRemote] = []
        if jevOn, let key = keys.read() { remotes.append(.jev(JevDecisionProvider(key: key, endpoint: jevEndpoint, session: session))) }
        // OpenAI Decisions goes here, after Jev, once OpenAI publishes its API (SystemOneCatalog.openAIDecisions).
        let personal = laya == nil ? nil : SystemOnePersonalStore(folder: folder).activeModel()
        return .init(laya: laya, remotes: remotes, journal: SystemOneJournal(url: folder.appendingPathComponent(SystemOneJournal.fileName)),
                     personal: personal)
    }
}

/// What the page says System One is doing right now, in one line.
/// The one status card at the top of Models → System One: on or off, one line, and the one action
/// that turns it on when it's off.
struct SystemOneStatus: Equatable {
    enum Laya: Equatable { case notDownloaded, downloading, preparing, ready, failed }
    enum Action: Equatable {
        case downloadLaya, turnOnLaya
        var title: String { self == .downloadLaya ? "Download Laya" : "Turn on Laya" }
    }
    let on: Bool
    let title: String
    let detail: String
    let action: Action?

    static func card(laya: Laya, layaOn: Bool, jevActive: Bool, personalKinds: [DecisionKind]) -> SystemOneStatus {
        let personal = personalKinds.isEmpty ? nil : "Your personal layer is on for " + ListFormatter.localizedString(byJoining: personalKinds.map(\.title)) + "."
        switch (laya == .ready && layaOn, jevActive) {
        case (true, true):
            return .init(on: true, title: "On · Laya decides on this device", detail: ["Jev helps when Laya isn't sure.", personal].compactMap { $0 }.joined(separator: " "), action: nil)
        case (true, false):
            return .init(on: true, title: "On · Laya decides on this device", detail: personal ?? "It answers only when it's sure. Otherwise Apple routing decides.", action: nil)
        case (false, true):
            return .init(on: true, title: "On · Jev decides with your key", detail: laya == .ready ? "Laya is off on this device." : "Until Laya is on this device.",
                         action: laya == .ready ? .turnOnLaya : laya == .notDownloaded || laya == .failed ? .downloadLaya : nil)
        case (false, false):
            switch laya {
            case .ready: return .init(on: false, title: "Off", detail: "Turn on Laya to decide on this device.", action: .turnOnLaya)
            case .downloading: return .init(on: false, title: "Off · Laya is downloading", detail: "It turns on when it's ready.", action: nil)
            case .preparing: return .init(on: false, title: "Off · Preparing Laya", detail: "This takes a minute, once.", action: nil)
            case .notDownloaded, .failed: return .init(on: false, title: "Off", detail: "Download Laya to decide on this device.", action: .downloadLaya)
            }
        }
    }
}

enum SystemOne {
    static let purpose: ContextPurpose = "system-one-decision"
    /// Jev is its own recipient, another company's service at a fixed host.
    static let jevRecipient = RecipientID.apiModel(profile: UUID(uuidString: "4A455600-7970-6573-6166-652E61690001")!, host: JevDecisionProvider.host)
    /// Turning a hosted service on is the person's grant for Personal requests, as the cloud voice
    /// opt-in is for speech: Sensitive needs a grant for that one item, which this never gives, and
    /// Device only and Secret never leave the device.
    static func consent(for recipient: RecipientID) -> RecipientGrant { RecipientGrant(recipient: recipient, kinds: [.message], purpose: purpose) }
    static var jevConsent: RecipientGrant { consent(for: jevRecipient) }
    static func jevMayReceive(_ level: PrivacyLevel, grants: [RecipientGrant] = []) -> Bool {
        mayReceive(level, recipient: jevRecipient, grants: grants)
    }
    /// Whether a hosted service the person turned on may receive a request at this level.
    static func mayReceive(_ level: PrivacyLevel, recipient: RecipientID, grants: [RecipientGrant] = []) -> Bool {
        ContextPolicy.evaluate([packetItem(level)], to: recipient, purpose: purpose, grants: [consent(for: recipient)] + grants, now: Date()).permitsAll
    }
    /// The decision packet as one context item: the current request's words, at its chat's level.
    static func packetItem(_ level: PrivacyLevel) -> ContextItem { .init(.init(.message, "system-one-request"), level: level) }

    /// Outside what Laya was evaluated on: no words, or mostly a script other than Latin.
    static func outOfDistribution(_ request: DecisionRequest) -> Bool {
        let letters = request.state.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return true }
        let latin = letters.filter { $0.value < 0x250 }.count
        return Double(latin) / Double(letters.count) < 0.8
    }

    /// Asks Laya (with the person's layer where it's on), then each hosted service in order, as far
    /// as the chat's level allows, until one is sure. Returns the accepted result, or nil for the
    /// caller's own fallback. Every decision is journaled.
    static func decide(_ request: DecisionRequest, kind: DecisionKind, level: PrivacyLevel,
                       providers: SystemOneProviders) async -> DecisionResult? {
        let started = Date()
        var steps: [SystemOneStep] = [], accepted: (result: DecisionResult, source: SystemOneSource, layer: SystemOneLayer?)?
        var questions = request.questions.map { SystemOneRecord.Question(id: $0.id, options: $0.options) }
        let outOfDistribution = outOfDistribution(request)
        func score(_ result: DecisionResult) -> Double { result.answers.map(\.confidence).min() ?? 0 }
        func reason(for error: Error) -> SystemOneStep.Reason {
            if let failure = error as? DecisionError, failure == .contextLimit { return .outOfDistribution }
            if let failure = error as? RemoteDecisionError, failure == .keyRejected || failure == .limited { return .rejected }
            return .unavailable
        }
        if let laya = providers.laya {
            if outOfDistribution {
                steps.append(.init(provider: .laya, version: laya.modelVersion, score: nil, reason: .outOfDistribution))
            } else {
                do {
                    let base = try await PrivateDecisionGateway.decideDirect(request, using: laya)
                    for (index, answer) in base.answers.enumerated() where questions.indices.contains(index) { questions[index].laya = answer.probabilities }
                    var result = base, layer = SystemOneLayer.base
                    if let adjusted = providers.personal?.apply(to: base, for: request, kind: kind) {
                        result = adjusted; layer = .personal
                        questions[0].personal = adjusted.answers.first?.probabilities
                    }
                    let top = score(result)
                    let confident = result.abstention == nil && top >= kind.threshold
                    steps.append(.init(provider: .laya, version: result.modelVersion, score: top, reason: confident ? nil : .lowConfidence, layer: layer))
                    if confident { accepted = (result, .laya, layer) }
                } catch {
                    steps.append(.init(provider: .laya, version: laya.modelVersion, score: nil, reason: reason(for: error)))
                }
            }
        }
        for remote in providers.remotes where accepted == nil && !Task.isCancelled {
            let version = remote.provider.modelVersion
            let decision = ContextPolicy.evaluate([packetItem(level)], to: remote.recipient, purpose: purpose,
                                                  grants: [remote.consent] + providers.grants, now: Date())
            if !decision.permitsAll {
                steps.append(.init(provider: remote.source, version: version, score: nil, reason: .privacy))
            } else if outOfDistribution {
                steps.append(.init(provider: remote.source, version: version, score: nil, reason: .outOfDistribution))
            } else {
                do {
                    // Only the packet: the request's words, the questions, and their choices.
                    let packet = DecisionRequest(state: request.state, questions: request.questions, deadline: request.deadline)
                    let result = try await remote.provider.decide(packet)
                    try result.validate(for: request)
                    let top = score(result)
                    let confident = result.abstention == nil && top >= kind.threshold
                    steps.append(.init(provider: remote.source, version: result.modelVersion, score: top, reason: confident ? nil : .lowConfidence,
                                       sentTo: remote.host))
                    if confident { accepted = (result, remote.source, nil) }
                } catch {
                    steps.append(.init(provider: remote.source, version: version, score: nil, reason: reason(for: error), sentTo: remote.host))
                }
            }
        }
        // With no provider on there's no System One decision to record, only the fallback.
        if let journal = providers.journal, !steps.isEmpty {
            if let result = accepted?.result {
                for (index, answer) in result.answers.enumerated() where questions.indices.contains(index) { questions[index].answer = answer.selectedIndex }
            }
            await journal.append(.init(at: started, kind: kind, decidedBy: accepted?.source ?? .fallback, steps: steps,
                                       milliseconds: Int(Date().timeIntervalSince(started) * 1000), questions: questions, layer: accepted?.layer))
        }
        return accepted?.result
    }
}

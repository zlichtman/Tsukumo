import Foundation

// The hosted System One models a person can turn on (the owner, October 3, 2026: Cloudflare first, with
// every option that can work enabled). Each is a `SystemOneAPIProvider` on its own endpoint, its own
// recipient for the policy, turned on only with a one-time confirmation that names its host and what
// goes there. They're asked after Laya, in the order the person drags them into in Settings.
//
// Not here, on purpose: OpenAI's Decisions API (announced September 29, 2026, with no public contract
// yet) and Amazon Bedrock's prompt routing (it picks between two LLMs; it doesn't make typed decisions
// with probabilities). DEVELOPMENT.md keeps them on the watch list.

/// The hosted models System One can ask.
public enum HostedProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case clefFlash = "clef-flash"
    case clef
    case jev
    case custom

    public var id: String { rawValue }
    /// Who decided, as the journal and the policy name it.
    public var source: DecisionSource { DecisionSource(rawValue: rawValue) }
    public var title: String {
        switch self {
        case .clefFlash: "Cloudflare Clef-flash"
        case .clef: "Cloudflare Clef"
        case .jev: "Jev (TypeSafe)"
        case .custom: "Custom endpoint"
        }
    }
    /// One line about it.
    public var detail: String {
        switch self {
        case .clefFlash: "Workers AI · 9B, the fastest · open weights"
        case .clef: "Workers AI · 27B, the most precise · open weights"
        case .jev: "TypeSafe’s hosted model · for an existing key"
        case .custom: "Any endpoint with the System One API"
        }
    }
    /// The host, where it's fixed.
    public var fixedHost: String? {
        switch self {
        case .clefFlash, .clef: SystemOneEndpoint.cloudflareHost
        case .jev: SystemOneEndpoint.jevHost
        case .custom: nil
        }
    }
    public var defaultModel: String {
        switch self {
        case .clefFlash: "clef-flash"
        case .clef: "clef"
        case .jev: "jev-latest"
        case .custom: ""
        }
    }
    /// The models to pick from, where there's a choice.
    public var models: [String] {
        switch self {
        case .clefFlash: ["clef-flash"]
        case .clef: ["clef"]
        case .jev: ["jev-latest", "jev-1.13.0"]
        case .custom: []
        }
    }
    public var needsAccountID: Bool { self == .clefFlash || self == .clef }
    /// "API token"
    public var keyName: String {
        switch self {
        case .clefFlash, .clef: "API token"
        case .jev: "API key"
        case .custom: "Key"
        }
    }
    /// The key's name inside a sentence ("your API token", "your key").
    public var keyPhrase: String { self == .custom ? "key" : keyName }
    /// Where the key comes from.
    public var keyHelp: String {
        switch self {
        case .clefFlash, .clef: "An API token with Workers AI permission, from dash.cloudflare.com, and your account ID."
        case .jev: "From console.typesafe.ai/keys. TypeSafe has paused new sign-ups, so this is for a key you already have."
        case .custom: "Sent as “Authorization: Bearer” to the address below."
        }
    }
    /// Who runs it, for the confirmation ("Cloudflare's terms apply.").
    public var operatorName: String? {
        switch self {
        case .clefFlash, .clef: "Cloudflare"
        case .jev: "TypeSafe"
        case .custom: nil
        }
    }
    /// The Keychain item its key is saved under (this device only).
    public var keyID: UUID {
        switch self {
        case .clefFlash: UUID(uuidString: "5C1E0001-C1EF-4F1A-8000-000000000001")!
        case .clef: UUID(uuidString: "5C1E0001-C1EF-4F1A-8000-000000000002")!
        case .jev: UUID(uuidString: "5C1E0001-C1EF-4F1A-8000-000000000003")!
        case .custom: UUID(uuidString: "5C1E0001-C1EF-4F1A-8000-000000000004")!
        }
    }
}

/// One hosted model's settings. Its key is in the Keychain, never here.
public struct HostedProviderSetting: Codable, Hashable, Identifiable, Sendable {
    public var kind: HostedProviderKind
    /// Turned on by the person after the confirmation.
    public var on: Bool
    /// The host the person agreed to send decisions to. Changing the address (a custom endpoint) asks again.
    public var consentedHost: String?
    /// Cloudflare's account ID.
    public var accountID: String
    public var model: String
    /// A custom endpoint's address.
    public var address: String

    public var id: String { kind.rawValue }

    public init(kind: HostedProviderKind, on: Bool = false, consentedHost: String? = nil, accountID: String = "", model: String? = nil, address: String = "") {
        self.kind = kind; self.on = on; self.consentedHost = consentedHost; self.accountID = accountID
        self.model = model ?? kind.defaultModel; self.address = address
    }

    /// Where it would send decisions, once it has what it needs (an account ID, an address, a model).
    public var endpoint: SystemOneEndpoint? {
        switch kind {
        case .clefFlash, .clef: SystemOneEndpoint.cloudflare(accountID: accountID, model: kind.defaultModel)
        case .jev: SystemOneEndpoint.jev(model: kind.models.contains(model) ? model : kind.defaultModel)
        case .custom: SystemOneEndpoint.custom(address: address, model: model)
        }
    }
    /// The host it sends to (or would, once configured).
    public var host: String? { endpoint?.host ?? kind.fixedHost }
    /// On, with the person's agreement for exactly this host.
    public var isConsented: Bool { on && consentedHost != nil && consentedHost == endpoint?.host }
}

/// Where a provider is, for its row in Settings.
public enum ProviderStatus: Hashable, Sendable {
    case ready, needsKey, off, notDownloaded, downloading(Double), preparing, failed
}

/// The hosted models, in the order System One asks them after Laya.
public struct SystemOneSettings: Codable, Hashable, Sendable {
    public var hosted: [HostedProviderSetting]
    public init(hosted: [HostedProviderSetting] = HostedProviderKind.allCases.map { HostedProviderSetting(kind: $0) }) {
        self.hosted = hosted
        normalize()
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hosted = (try? container.decode([HostedProviderSetting].self, forKey: .hosted)) ?? []
        normalize()
    }

    /// Every kind exactly once, keeping the person's order; a kind this build doesn't know is dropped,
    /// a new one is added last.
    public mutating func normalize() {
        var seen = Set<HostedProviderKind>()
        hosted = hosted.filter { seen.insert($0.kind).inserted }
        for kind in HostedProviderKind.allCases where !seen.contains(kind) { hosted.append(HostedProviderSetting(kind: kind)) }
    }

    public subscript(kind: HostedProviderKind) -> HostedProviderSetting {
        get { hosted.first { $0.kind == kind } ?? HostedProviderSetting(kind: kind) }
        set { if let index = hosted.firstIndex(where: { $0.kind == kind }) { hosted[index] = newValue } else { hosted.append(newValue) } }
    }

    /// Moves `kind` to sit where `target` is (dragging a row onto another).
    public mutating func move(_ kind: HostedProviderKind, to target: HostedProviderKind) {
        guard kind != target, let from = hosted.firstIndex(where: { $0.kind == kind }) else { return }
        let item = hosted.remove(at: from)
        let to = hosted.firstIndex(where: { $0.kind == target }).map { from <= $0 ? $0 + 1 : $0 } ?? hosted.endIndex
        hosted.insert(item, at: min(to, hosted.endIndex))
    }
    /// List-style moves (iPhone's Edit mode).
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().map { hosted[$0] }
        var rest = hosted.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let before = source.filter { $0 < destination }.count
        rest.insert(contentsOf: moving, at: min(max(0, destination - before), rest.count))
        hosted = rest
    }

    /// The hosted models System One may ask, in order: on, agreed to for their host, configured, and with a key.
    public func remotes(key: (HostedProviderKind) -> String?, session: URLSession = .shared) -> [RemoteDecider] {
        hosted.compactMap { setting in
            guard setting.isConsented, let endpoint = setting.endpoint, let key = key(setting.kind), SystemOneAPIProvider.isKey(key) else { return nil }
            return SystemOneAPIProvider(endpoint: endpoint, key: key, session: session).remote
        }
    }

    /// A hosted model's status: Ready (on, agreed, configured, keyed), Needs a key (no key, or no account
    /// ID or address yet), or Off.
    public func status(_ kind: HostedProviderKind, hasKey: Bool) -> ProviderStatus {
        let setting = self[kind]
        guard hasKey, setting.endpoint != nil else { return .needsKey }
        return setting.isConsented ? .ready : .off
    }
}

/// What the confirmation says before a hosted model is turned on.
public enum HostedConsent {
    public static func title(_ kind: HostedProviderKind) -> String { "Use \(kind.title) for decisions?" }
    public static func confirm(host: String) -> String { "Send decisions to \(host)" }
    /// Names the host and exactly what goes there.
    public static func message(_ kind: HostedProviderKind, host: String) -> String {
        "When Laya isn’t sure, the words of your message, the question, and its choices (your bots’ names and jobs) go to \(host) with your \(kind.keyPhrase). Never your chat history, memories, or what KemoSabe reads, and nothing from Sensitive, Device only, or Secret chats."
            + (kind.operatorName.map { " \($0)’s terms apply." } ?? "")
    }
}

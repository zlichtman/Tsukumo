import Foundation
import Observation

/// Something a caller wants that only the owner can allow: a call outside its standing grants, a call over a
/// budget, one Sensitive answer from KemoSabe, a file, excerpt, or photo, or a new client signing in.
///
/// A card never carries words the caller wrote (its question, a name it typed, its "urgent" or "already
/// approved"): `text` is written here from the tool and the caller's name alone, so an agent can't pressure
/// or trick the owner through the card. `preview` is the owner's own data the card shows before anything
/// leaves (the excerpt, the file's name, KemoSabe's answer); it's shown only on this Mac and never sent back.
public struct GatewayApprovalRequest: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// A tool call that no standing grant covers.
        case call
        /// Over a budget or matching an enumeration pattern.
        case overBudget
        /// KemoSabe found the answer in one Sensitive item.
        case share
        /// A client signing in with OAuth: the whole address it sends people back to, and whether it reached this Mac
        /// locally (127.0.0.1) rather than through a public address, and whether that public address is the Tsukumo relay.
        case newClient(redirectURI: String, local: Bool, relayed: Bool = false)
    }
    public let id: UUID
    public let callerID: String
    public let callerName: String
    public let tool: GatewayToolName?
    public let kind: Kind
    /// What the card says (and what the caller is told is waiting): at most 240 characters, no markup, nothing
    /// the caller wrote.
    public let text: String
    /// The owner's own data the card shows before it leaves; never sent to the caller.
    public let preview: String?
    /// The standing grant "Allow for 7 days" would give, or nil when only this once is offered.
    public let standing: GatewayGrant?
    /// The exact request this card decides (caller, tool, and canonical arguments): an answer applies to it only.
    public let fingerprint: String
    public let at: Date

    public init(id: UUID = UUID(), callerID: String, callerName: String, tool: GatewayToolName?, kind: Kind, text: String,
                preview: String? = nil, standing: GatewayGrant? = nil, fingerprint: String, at: Date = Date()) {
        self.id = id; self.callerID = callerID; self.callerName = callerName; self.tool = tool; self.kind = kind
        self.text = String(text.prefix(240)); self.preview = preview; self.standing = standing; self.fingerprint = fingerprint; self.at = at
    }

    /// The card's title: "Grok wants to ask KemoSabe".
    public var title: String {
        switch kind {
        case .newClient: "\(callerName) wants to connect to KemoSabe"
        case .share: "Share this with \(callerName)?"
        case .overBudget: "\(callerName) is asking a lot"
        case .call: "\(callerName) is asking KemoSabe"
        }
    }
}

/// The owner's answer.
public enum GatewayApproval: Hashable, Sendable {
    /// This request only, once.
    case once
    /// This request, and the card's standing grant from now on.
    case standing
    /// A new client, with the standing grants the owner ticked (none: every call asks).
    case allowClient([GatewayToolName])
    case deny
}

/// The cards waiting on the owner, and the owner's answers waiting to be used. A call that needs the owner
/// returns at once ("waiting on the owner"), its card shows in the dock and Settings, and the caller asks again
/// once the owner has answered. Identical requests share one card; a caller, and every caller together, may
/// have only so many cards waiting, so nobody can bury the owner in cards until one is allowed by mistake.
@MainActor @Observable public final class GatewayDesk {
    public private(set) var pending: [GatewayApprovalRequest] = []
    /// Answers not used yet, by fingerprint: Allow once is used by the next identical call; Don't allow stands
    /// until it expires.
    @ObservationIgnored private var decided: [String: (approval: GatewayApproval, request: GatewayApprovalRequest, at: Date)] = [:]
    @ObservationIgnored private let clock: @Sendable () -> Date
    /// How long a card waits, and how long an answer is kept for the caller to come back.
    @ObservationIgnored public var cardLifetime: TimeInterval = 15 * 60
    @ObservationIgnored public var answerLifetime: TimeInterval = 15 * 60
    /// A sign-in is answered in the sign-in window, outside the queue's limits.
    @ObservationIgnored public var onRequest: ((GatewayApprovalRequest) -> Void)?

    public init(clock: @escaping @Sendable () -> Date = { Date() }) { self.clock = clock }

    public enum Submission: Equatable, Sendable {
        /// A new card.
        case added(GatewayApprovalRequest)
        /// The same request already has a card.
        case duplicate(GatewayApprovalRequest)
        /// Too many cards wait already.
        case full
    }

    /// Puts a card up, unless the same request has one, or the caller or everyone together has too many waiting.
    public func submit(_ request: GatewayApprovalRequest, perCaller: Int, everyone: Int) -> Submission {
        expire()
        if let same = pending.first(where: { $0.fingerprint == request.fingerprint }) { return .duplicate(same) }
        // Sign-ins and calls are counted apart, each against its own limits.
        let isSignIn = Self.isSignIn(request)
        let same = pending.filter { Self.isSignIn($0) == isSignIn }
        guard same.filter({ $0.callerID == request.callerID }).count < perCaller, same.count < everyone else { return .full }
        pending.append(request)
        onRequest?(request)
        return .added(request)
    }

    /// The owner's answer for this exact request, if there is one. Allow once is used up by reading it.
    public func decision(for fingerprint: String) -> (approval: GatewayApproval, request: GatewayApprovalRequest)? {
        expire()
        guard let found = decided[fingerprint] else { return nil }
        if found.approval != .deny { decided[fingerprint] = nil }
        return (found.approval, found.request)
    }

    /// The owner's answer to a card or the sign-in window.
    public func answer(_ id: UUID, _ approval: GatewayApproval) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let request = pending.remove(at: index)
        decided[request.fingerprint] = (approval, request, clock())
    }

    public static func isSignIn(_ request: GatewayApprovalRequest) -> Bool { if case .newClient = request.kind { true } else { false } }

    /// The owner's answer for this exact request, without using it up (Allow once is used by clearance later).
    public func peek(_ fingerprint: String) -> GatewayApproval? {
        expire()
        return decided[fingerprint]?.approval
    }

    /// The card waiting for this request, if any.
    public func card(for fingerprint: String) -> GatewayApprovalRequest? { pending.first { $0.fingerprint == fingerprint } }

    /// Every card and answer for a caller goes (it was revoked).
    public func dropAll(from caller: String) {
        pending.removeAll { $0.callerID == caller }
        decided = decided.filter { $0.value.request.callerID != caller }
    }

    private func expire() {
        let now = clock()
        pending.removeAll { now.timeIntervalSince($0.at) > cardLifetime }
        decided = decided.filter { now.timeIntervalSince($0.value.at) <= answerLifetime }
    }
}

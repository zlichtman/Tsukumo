import Foundation
import Observation

/// Sign-ins for the owner, one at a time. The one showing is fixed until it's answered or closed, so a sign-in that
/// arrives meanwhile can't replace what the owner is about to allow; it waits its turn. An answer counts only for the
/// sign-in it was given for, and Allow only after a short arming delay from when that sign-in appeared, so a click
/// meant for something else can't land on it. The app draws `current` in its window.
@MainActor @Observable public final class GatewaySignInQueue {
    public private(set) var current: GatewayApprovalRequest?
    public private(set) var waiting: [GatewayApprovalRequest] = []
    @ObservationIgnored public let desk: GatewayDesk
    @ObservationIgnored public var armingDelay: TimeInterval = 1.5
    @ObservationIgnored private var shownAt: Date?
    @ObservationIgnored private let clock: @Sendable () -> Date

    public init(desk: GatewayDesk, clock: @escaping @Sendable () -> Date = { Date() }) { self.desk = desk; self.clock = clock }

    /// Adds a sign-in; returns true when it became the one showing (the app opens a window for it).
    @discardableResult public func add(_ request: GatewayApprovalRequest) -> Bool {
        guard GatewayDesk.isSignIn(request), request.id != current?.id, !waiting.contains(where: { $0.id == request.id }) else { return false }
        waiting.append(request)
        return advance()
    }

    /// Whether Allow may be pressed for this sign-in yet.
    public func isArmed(_ id: UUID) -> Bool {
        guard current?.id == id, let shownAt else { return false }
        return clock().timeIntervalSince(shownAt) >= armingDelay
    }

    /// The owner's answer, for exactly the sign-in it names. Allow before it's armed, or for one not showing, is
    /// ignored (false). Don't Allow always counts for the one showing.
    @discardableResult public func answer(_ id: UUID, _ approval: GatewayApproval) -> Bool {
        guard current?.id == id else { return false }
        if approval != .deny, !isArmed(id) { return false }
        desk.answer(id, approval)
        current = nil
        shownAt = nil
        return true
    }

    /// The window closed without an answer: the sign-in stays on the desk until it expires; the next one shows.
    /// Returns true when another sign-in became the one showing.
    @discardableResult public func closed(_ id: UUID) -> Bool {
        guard current?.id == id else { return false }
        current = nil
        shownAt = nil
        return advance()
    }

    /// Shows the next waiting sign-in that's still on the desk, if none is showing.
    @discardableResult public func advance() -> Bool {
        guard current == nil else { return false }
        waiting.removeAll { request in !desk.pending.contains { $0.id == request.id } }
        guard !waiting.isEmpty else { return false }
        current = waiting.removeFirst()
        shownAt = clock()
        return true
    }
}

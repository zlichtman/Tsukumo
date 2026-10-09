#if os(macOS)
import Foundation
import TsukumoCore
import TsukumoGateway
import TsukumoMuse
import TsukumoUI

// What Tsukumo does when Muse calls it (TsukumoMuse's `MuseTsukumo`), on the side dock. Muse is a caller of
// the KemoSabe gateway like any other agent, listed in Settings, Gateway with Revoke: its `kemosabe.*`
// commands are the gateway's typed tools (`GatewayTools.call`), under the same ledger, budgets, grants,
// enumeration checks, and cards. A task for a bot runs in a fresh, isolated session (never a coding bot), its
// reply leaves only through KemoSabe, and the gateway's ledger records it as a disclosure to Muse. Everything
// shows in Activity. Muse never reads anything itself.

extension GatewayCaller {
    /// Muse, as the KemoSabe gateway lists it: added when the owner pairs Muse on this Mac, and removed by Unpair
    /// or by Revoke in Settings, Gateway (which cuts Muse off until the owner pairs it again).
    public static func muse(at date: Date = Date()) -> GatewayCaller {
        GatewayCaller(id: MuseCaller.muse.id, name: MuseCaller.muse.name, kind: .device, detail: "Your Muse chat, paired over Bluetooth", createdAt: date)
    }
}

/// Keeps Muse's pairing and its place among the KemoSabe gateway's callers in step: pairing adds it; any end of the
/// pairing (Unpair, Muse removing this Mac, the credentials gone) revokes it there, with its grants, cards, and
/// KemoSabe's consent; Revoke in Settings, Gateway unpairs it. At start, a gateway caller left over from a pairing
/// that's gone is revoked, so nothing revives when the owner pairs again.
@MainActor public enum DockMuseGateway {
    public static func connect(_ muse: MuseGadget, to gateway: KemoSabeGateway) {
        let id = MuseCaller.muse.id
        muse.onPairingChanged = { [weak gateway] paired in
            guard let gateway else { return }
            if paired { gateway.store.add(.muse()) }
            else if let caller = gateway.store.caller(id) { gateway.revoke(caller) }
        }
        gateway.onRevoke = { [weak muse] caller in
            if caller.id == id, muse?.isPaired == true { muse?.unpair() }
        }
        if !muse.isPaired, let caller = gateway.store.caller(id) { gateway.revoke(caller) }
    }
}

/// The dock, seen from Muse.
public struct DockMuseBridge: MuseTsukumo {
    @MainActor final class Ref {
        weak var dock: BotDock?
        weak var tools: GatewayTools?
        init(_ dock: BotDock, _ tools: GatewayTools?) { self.dock = dock; self.tools = tools }
    }
    private let ref: Ref

    /// `tools` is the KemoSabe gateway's (nil: KemoSabe's tools are unavailable to Muse, and so are bots' replies).
    @MainActor public init(dock: BotDock, tools: GatewayTools?) { ref = Ref(dock, tools) }

    public func callKemoSabe(_ tool: String, arguments: [String: JSONValue], for caller: MuseCaller) async -> MuseToolReply {
        await call(tool, arguments, caller)
    }

    @MainActor private func call(_ tool: String, _ arguments: [String: JSONValue], _ caller: MuseCaller) async -> MuseToolReply {
        // Only KemoSabe's three typed tools: never the content tools or the Inbox, whatever the gateway offers others.
        guard let name = GatewayToolName(wire: tool), Self.kemoSabeTools.contains(name) else {
            return MuseToolReply(payload: .null, refused: "unsupported command: \(tool)")
        }
        guard let tools = ref.tools else {
            return MuseToolReply(payload: .null, refused: "KemoSabe isn’t answering questions on the owner’s Mac right now.")
        }
        let result = await tools.call(tool: name.rawValue, arguments: .object(arguments), caller: Self.gatewayCaller(caller, tools: tools))
        if result.status == "refused" {
            return MuseToolReply(payload: result.structured, refused: result.structured["message"]?.stringValue ?? "refused")
        }
        return MuseToolReply(payload: result.structured)
    }

    /// The tools Muse is offered through the gateway.
    static let kemoSabeTools: Set<GatewayToolName> = [.ask, .freeBusy, .contactLookup]

    /// Muse's gateway caller: the one the store lists when it's there (its name and when it was added), else a fresh one
    /// (which the gateway refuses as not connected).
    @MainActor static func gatewayCaller(_ caller: MuseCaller, tools: GatewayTools? = nil) -> GatewayCaller {
        tools?.store.caller(caller.id) ?? GatewayCaller(id: caller.id, name: caller.name, kind: .device, detail: "Your Muse chat, paired over Bluetooth")
    }

    public func bots() async -> [MuseBotSummary] { await summaries() }

    @MainActor private func summaries() -> [MuseBotSummary] {
        guard let dock = ref.dock else { return [] }
        // Coding bots are never offered (Muse may not drive an agent that reads files and runs commands), nor a service that doesn't chat.
        return dock.bots.filter(Self.offered).map { bot in
            MuseBotSummary(name: bot.name, job: bot.role, runsOn: dock.engineInfo(bot.engine).title, isKemoSabe: bot.isKemoSabe)
        }
    }

    public func askBot(named name: String, task: String, for caller: MuseCaller) async -> Result<String, MuseTaskFailure> {
        await relay(name, task: task, caller: caller)
    }

    @MainActor private func relay(_ name: String, task: String, caller: MuseCaller) async -> Result<String, MuseTaskFailure> {
        guard let dock = ref.dock else { return .failure(MuseTaskFailure("Tsukumo isn’t running its dock right now.")) }
        guard let bot = Self.match(name, in: dock.bots) else {
            return .failure(MuseTaskFailure("No bot is named “\(name)”. Use bots.list for their names."))
        }
        if bot.isKemoSabe { return .failure(MuseTaskFailure("Ask KemoSabe with kemosabe.ask.")) }
        guard Self.offered(bot) else { return .failure(MuseTaskFailure("\(bot.name) runs a coding agent, so it doesn’t take tasks from \(caller.name).")) }
        // A bot's reply is a disclosure to Muse: Muse must still be the gateway's caller (not revoked) and within the
        // ledger's limits before the bot starts, and the reply is recorded in the ledger as it's handed over.
        guard let tools = ref.tools else { return .failure(MuseTaskFailure("KemoSabe isn’t relaying replies on the owner’s Mac right now.")) }
        let gatewayCaller = Self.gatewayCaller(caller, tools: tools)
        let admission: GatewayRelayAdmission
        switch tools.admitRelay(caller: gatewayCaller) {
        case .success(let admitted): admission = admitted
        case .failure(let refusal): return .failure(MuseTaskFailure(refusal.message))
        }
        // Whatever ends this (a cancel or timeout included), the reserved unit never outlives it.
        defer { tools.releaseRelay(admission) }
        let line = task.split(whereSeparator: \.isNewline).first.map(String.init) ?? task
        dock.note(ActivityItem(kind: .botWork, title: "\(caller.name) asked \(bot.name)", detail: String(line.prefix(160)), botID: bot.id))
        let result = await dock.relay(task, from: KemoSabeCaller(requester: caller.recipient, name: caller.name), to: bot.id)
        // The final step, with nothing that suspends between the ledger's check, the hand-over, and what the chat,
        // the journal, and Activity say.
        switch result {
        case .success(let reply):
            let sent = Task.isCancelled ? nil : tools.recordRelay(admission, caller: gatewayCaller, bot: bot.name, reply: reply.text)
            dock.finishRelay(reply, delivered: sent != nil)
            guard let sent else {
                return .failure(MuseTaskFailure("That was withdrawn on the owner’s Mac while \(bot.name) worked. Nothing was sent."))
            }
            return .success(sent)
        case .failure(let failure):
            _ = tools.recordRelay(admission, caller: gatewayCaller, bot: bot.name, reply: nil)
            return .failure(MuseTaskFailure(failure.message))
        }
    }

    public func note(_ title: String, detail: String) async { await record(title, detail) }

    @MainActor private func record(_ title: String, _ detail: String) {
        ref.dock?.note(ActivityItem(kind: .botWork, title: title, detail: detail))
    }

    /// Whether Muse may see and use a bot: never one on a coding agent (Claude Code, Codex, an ACP agent).
    static func offered(_ bot: BotSpec) -> Bool { !bot.engine.runsOnlyOnMac && bot.engine.chats }

    /// The bot by its name, ignoring case, or the only one whose name starts with it.
    static func match(_ name: String, in bots: [BotSpec]) -> BotSpec? {
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !wanted.isEmpty else { return nil }
        if let exact = bots.first(where: { $0.name.lowercased() == wanted }) { return exact }
        let starts = bots.filter { $0.name.lowercased().hasPrefix(wanted) }
        return starts.count == 1 ? starts[0] : nil
    }
}
#endif

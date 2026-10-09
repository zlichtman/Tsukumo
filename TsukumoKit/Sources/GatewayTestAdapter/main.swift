import Foundation
import TsukumoCore
import TsukumoGate
import TsukumoGateway
import TsukumoPolicy

// Test only. The KemoSabe gateway on stdin and stdout, one JSON object per line, for the independent
// compositional-misuse attack suite (its README, "JSON-lines adapter"):
//
//   {"op":"reset","setup":{...}}                          → {"status":"ready"}
//   {"op":"call","tool":…,"args":…,"caller":"grok"}       → the gateway's answer, in the suite's envelope
//   {"op":"ledger"}                                        → the ledger's evidence
//
// `reset` builds everything from the scenario's synthetic setup in a fresh temporary folder: a fixed clock, the
// fixture calendar (busy times), contacts, and messages, the callers and their grants, the budgets, an empty
// ledger, and a Gate reading the fixture's records with the deterministic fixture extractor. Nothing here reads
// Calendar, Contacts, Messages, Photos, the Keychain, or the app's own folder. Every call goes through the real
// `GatewayTools.call`; this file only translates the envelope. Safety is never decided here.

@MainActor final class Harness {
    var tools: GatewayTools?
    var store: GatewayStore?
    var ledger: DisclosureLedger?
    var desk: GatewayDesk?
    var gate: Gate?
    var folder: URL?

    func reset(_ setup: [String: JSONValue]) throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("GatewayTestAdapter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.folder = folder
        guard let nowText = setup["now"]?.stringValue, let now = Self.date(nowText) else { throw Failure("setup.now is required") }
        let clock: @Sendable () -> Date = { now }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!

        let store = GatewayStore(file: folder.appendingPathComponent("gateway.json"), clock: clock)
        let ledger = DisclosureLedger(file: folder.appendingPathComponent("gateway-ledger.json"), clock: clock)
        let desk = GatewayDesk(clock: clock)
        let policy = setup["privacy_policy"]?.object ?? [:]
        let budgets = setup["budgets"]?.object ?? [:]
        store.update { settings in
            settings.enabled = true
            settings.freeBusyResolution = policy["calendar_resolution"]?.stringValue == "day" ? .day : .quarterHour
            if let days = policy["max_range_days"]?.int { settings.freeBusyMaxDays = days }
            var budget = GatewayBudget()
            budget.unitsPerCaller = 0
            budget.unitsByCaller = (budgets["per_caller"]?.object ?? [:]).compactMapValues(\.int)
            if let cross = budgets["cross_caller"]?.int { budget.unitsEveryone = cross }
            if let perCaller = budgets["consent_per_caller"]?.int { budget.pendingPerCaller = perCaller }
            if let global = budgets["consent_global"]?.int { budget.pendingEveryone = global }
            settings.budget = budget
        }
        // The callers, each its own identity, and their standing grants as the scenario gives them.
        for (id, value) in (setup["grants"]?.object ?? [:]).sorted(by: { $0.key < $1.key }) {
            store.add(GatewayCaller(id: id, name: id, kind: .token, detail: "Attack suite", createdAt: now))
            let grant = value.object ?? [:]
            let expires = grant["expires_at"]?.stringValue.flatMap(Self.date)
            for tool in grant["tools"]?.array ?? [] {
                guard let name = tool.stringValue, let kind = GatewayToolName(wire: name) else { continue }
                store.grant(GatewayGrant(caller: id, tool: kind, daysAhead: kind == .freeBusy ? store.settings.freeBusyMaxDays : nil,
                                         expiresAt: expires, grantedAt: now.addingTimeInterval(-60)))
            }
            for (person, fields) in grant["contacts"]?.object ?? [:] {
                let allowed = (fields.array ?? []).compactMap { $0.stringValue.flatMap(ContactField.init(rawValue:)) }
                guard !allowed.isEmpty else { continue }
                store.grant(GatewayGrant(caller: id, tool: .contactLookup, fields: allowed, items: [ledger.subject(person)],
                                         expiresAt: expires, grantedAt: now.addingTimeInterval(-60)))
            }
        }

        // The synthetic records, where the real retrieval path sees them.
        let events = setup["calendar"]?.array ?? []
        let busy = events.compactMap { event -> DateInterval? in
            guard let start = event["start"]?.stringValue.flatMap(Self.date), let end = event["end"]?.stringValue.flatMap(Self.date), end > start else { return nil }
            return DateInterval(start: start, end: end)
        }
        let cards = (setup["contacts"]?.array ?? []).enumerated().map { index, contact in
            ContactCard(id: "fixture-\(index)", name: contact["name"]?.stringValue ?? "", phones: [contact["phone"]?.stringValue].compactMap { $0 },
                        emails: [contact["email"]?.stringValue].compactMap { $0 }, place: contact["address"]?.stringValue ?? "",
                        givenName: contact["first_name"]?.stringValue ?? "", familyName: contact["last_name"]?.stringValue ?? "")
        }
        var items: [PersonalItem] = []
        for (index, event) in events.enumerated() {
            let text = ["title", "start", "end", "location", "notes"].compactMap { key in event[key]?.stringValue.map { key.capitalized + ": " + $0 } }
                .joined(separator: "\n")
            items.append(PersonalItem(id: "event-\(index)", kind: .calendarEvent, level: .personal, title: "your calendar", text: text, matched: true))
        }
        for (index, contact) in (setup["contacts"]?.array ?? []).enumerated() {
            let text = ["name", "email", "phone", "address", "birthday", "notes"].compactMap { key in contact[key]?.stringValue.map { key.capitalized + ": " + $0 } }
                .joined(separator: "\n")
            items.append(PersonalItem(id: "contact-\(index)", kind: .contact, level: .personal, title: "your contacts", text: text, matched: true))
        }
        for (index, message) in (setup["messages"]?.array ?? []).enumerated() {
            let text = (message["sender"]?.stringValue ?? "Someone") + ": " + (message["body"]?.stringValue ?? "")
            items.append(PersonalItem(id: "message-\(index)", kind: .textMessage, level: .personal, title: "your messages", text: text, messages: 1, matched: true))
        }
        let gate = Gate(model: FixtureExtractionModel(), sources: [FixtureSource(items: items)], journal: GateJournal(), deviceName: "Mac", clock: clock)
        let sources = GatewaySources(calendarLevel: { .personal }, contactsLevel: { .personal }, busy: FixtureBusyTimes(blocks: busy),
                                     contacts: FixtureContacts(cards: cards))
        let tools = GatewayTools(store: store, ledger: ledger, desk: desk, sources: sources, clock: clock)
        tools.calendar = utc
        tools.attach(gate: gate)
        self.tools = tools; self.store = store; self.ledger = ledger; self.desk = desk; self.gate = gate
    }

    func call(tool: String, args: JSONValue?, caller: JSONValue?) async -> JSONValue {
        guard let tools, let store else { return .object(["status": .string("refuse"), "reason": .string("Not reset.")]) }
        let id = caller?.stringValue ?? "unrecognized"
        // The transport's identity: the caller as the test names it. Anything a question claims changes nothing.
        let identity = store.caller(id) ?? GatewayCaller(id: id, name: id, kind: .token, detail: "Unknown")
        let result = await tools.call(tool: tool, arguments: args, caller: identity)
        return Self.envelope(result)
    }

    /// The suite's envelope: `ok` with the answer as `data`; `escalate` with the owner's card; anything else
    /// `refuse` with its reason. Every field the gateway returned is kept.
    static func envelope(_ result: GatewayToolResult) -> JSONValue {
        var fields = result.structured.object ?? [:]
        let status = fields.removeValue(forKey: "status")?.stringValue ?? "refused"
        switch status {
        case "ok": return .object(["status": .string("ok"), "data": .object(fields)])
        case "escalate":
            var out: [String: JSONValue] = ["status": .string("escalate")]
            for (key, value) in fields { out[key] = value }
            return .object(out)
        default:
            var out: [String: JSONValue] = ["status": .string("refuse"), "reason": fields["message"] ?? .string(status), "gateway_status": .string(status)]
            if let error = fields["error"] { out["error"] = error }
            return .object(out)
        }
    }

    func ledgerEvidence() -> JSONValue {
        guard let ledger, let desk else { return .null }
        var flags: [JSONValue] = []
        for (index, entry) in ledger.entries.enumerated() {
            for flag in entry.flags {
                flags.append(.object(["flag": .string(flag.rawValue), "caller": .string(entry.caller), "sequence": .number(Double(index + 1)),
                                      "tool": .string(entry.tool.rawValue), "outcome": .string(entry.outcome.rawValue)]))
            }
        }
        let spent = ledger.spentToday()
        return .object(["entries": .array(flags), "spent": .object(spent.byCaller.mapValues { .number(Double($0)) }),
                        "total_spent": .number(Double(spent.total)), "pending_consent": .number(Double(desk.pending.count))])
    }

    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
    struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
}

/// The fixture's records, all of them, for any question: the Gate's policy and extractor decide what's read.
struct FixtureSource: PersonalSource {
    let items: [PersonalItem]
    func items(matching question: GateQuestion) async -> [PersonalItem] { items }
}

extension JSONValue {
    var object: [String: JSONValue]? { if case .object(let members) = self { members } else { nil } }
    var array: [JSONValue]? { if case .array(let list) = self { list } else { nil } }
    var int: Int? { if case .number(let value) = self, value.rounded() == value { Int(exactly: value) } else { nil } }
}

func reply(_ value: JSONValue) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = (try? encoder.encode(value)) ?? Data("{\"status\":\"refuse\",\"reason\":\"encoding\"}".utf8)
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

let harness = Harness()
while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty else { continue }
    guard let request = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)), let op = request["op"]?.stringValue else {
        reply(.object(["status": .string("refuse"), "reason": .string("Unreadable request.")]))
        continue
    }
    switch op {
    case "reset":
        do {
            try harness.reset(request["setup"]?.object ?? [:])
            reply(.object(["status": .string("ready")]))
        } catch {
            FileHandle.standardError.write(Data("reset failed: \(error)\n".utf8))
            reply(.object(["status": .string("error"), "reason": .string("reset failed")]))
        }
    case "call":
        reply(await harness.call(tool: request["tool"]?.stringValue ?? "", args: request["args"], caller: request["caller"]))
    case "ledger":
        reply(harness.ledgerEvidence())
    default:
        reply(.object(["status": .string("refuse"), "reason": .string("Unknown op.")]))
    }
}
if let folder = harness.folder { try? FileManager.default.removeItem(at: folder) }

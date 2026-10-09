import Foundation
import Testing
import TsukumoSystemOne
import TsukumoLaya

/// Laya through the shipping path (`CoreMLLayaProvider` with `LayaBundleTokenizer`), on Tsukumo's own
/// questions: `route` over "Name: job" choices, and `selectContext`'s yes/no per reference. It needs the
/// downloaded model, so it runs only when `TSUKUMO_LAYA_MODEL` names a bundle folder (`coreml_config.json`,
/// `rl_agent_config.json`, `tokenizer/`, and `model.mlmodelc` or `model.mlpackage`). It never downloads,
/// and it only reads that folder when the model is already compiled. A skip certifies nothing.
///
/// It reports accuracy, how often Laya clears each decision's threshold, accuracy when it does, and
/// latency, as one `LAYA_EVAL` line per decision. A threshold is lowered only when right-when-accepted is
/// at least 95% on a held-out wording family; these probes are a first check, not that evaluation.
struct LayaEvaluationTests {
    static let folder = ProcessInfo.processInfo.environment["TSUKUMO_LAYA_MODEL"].map { URL(fileURLWithPath: $0, isDirectory: true) }

    struct Probe { let state: String; let label: Int }
    static let bots = ["Chef: Plans meals and dinners", "Pip: Codes in my projects", "Juniper: Tracks my class deadlines", "Atlas: Plans trips and travel"]
    static let routeProbes: [Probe] = [
        .init(state: "What should I cook tonight with chicken and rice?", label: 0),
        .init(state: "Find me a recipe for a quick vegetarian lunch", label: 0),
        .init(state: "Plan a dinner menu for six people on Saturday", label: 0),
        .init(state: "I have leftover salmon, any ideas?", label: 0),
        .init(state: "Make a grocery list for the week", label: 0),
        .init(state: "The build is failing with a linker error in Xcode", label: 1),
        .init(state: "Refactor the settings view into smaller pieces", label: 1),
        .init(state: "Why does this Swift test crash on CI?", label: 1),
        .init(state: "Add a dark mode toggle to the app", label: 1),
        .init(state: "Review my pull request for the login screen", label: 1),
        .init(state: "When is my chemistry lab report due?", label: 2),
        .init(state: "Remind me what assignments are left this week", label: 2),
        .init(state: "Did I submit the history essay yet?", label: 2),
        .init(state: "Make a study schedule before my calculus midterm", label: 2),
        .init(state: "How many problem sets are due Friday?", label: 2),
        .init(state: "Book a hotel in Lisbon for next month", label: 3),
        .init(state: "What's the cheapest way to get from Tokyo to Kyoto?", label: 3),
        .init(state: "Plan a weekend road trip up the coast", label: 3),
        .init(state: "Do I need a visa to visit Japan?", label: 3),
        .init(state: "Find flights to Denver for Thanksgiving", label: 3),
    ]
    static let contextProbes: [(state: String, summary: String, needed: Bool)] = [
        ("When is Sarah free tonight?", "Calendar answer: Sarah is free after 7 tonight", true),
        ("When is Sarah free tonight?", "Recipe notes: lemon pasta for four", false),
        ("Fix the failing login test", "File: LoginTests.swift, the login screen's tests", true),
        ("Fix the failing login test", "Trip notes: Lisbon hotels under 150 euros", false),
        ("What should I pack for Lisbon?", "Trip notes: Lisbon, October 12 to 18, rain likely", true),
        ("What should I pack for Lisbon?", "File: Package.swift for the TsukumoKit package", false),
    ]

    @Test(.enabled(if: folder != nil, "Set TSUKUMO_LAYA_MODEL to a downloaded Laya bundle to evaluate it."))
    func layaOnTsukumosOwnDecisions() async throws {
        let laya = CoreMLLayaProvider(directory: Self.folder, tokenizer: LayaBundleTokenizer.make)
        let cold = Date()
        try await laya.prepare()
        let coldSeconds = Date().timeIntervalSince(cold)

        var right = 0, accepted = 0, rightAccepted = 0, times: [Double] = []
        for probe in Self.routeProbes {
            let request = DecisionRequest(state: probe.state, questions: [DecisionQuestion(
                id: "route", kind: .choice, instruction: "Which of the owner's bots should answer this message? Each choice is a bot and its job.",
                options: Self.bots)], deadline: Date().addingTimeInterval(30))
            let started = Date()
            let result = try await laya.decide(request)
            times.append(Date().timeIntervalSince(started) * 1000)
            let answer = try #require(result.answers.first)
            let hit = answer.selectedIndex == probe.label
            if hit { right += 1 }
            if answer.confidence >= DecisionKind.route.threshold { accepted += 1; if hit { rightAccepted += 1 } }
        }
        print(Self.line("route", right: right, accepted: accepted, rightAccepted: rightAccepted, total: Self.routeProbes.count, times: times, cold: coldSeconds))

        right = 0; accepted = 0; rightAccepted = 0; times = []
        for probe in Self.contextProbes {
            let request = DecisionRequest(state: probe.state, questions: [DecisionQuestion(
                id: "ref-0", kind: .probability, instruction: String(("Is this needed to answer the request? " + probe.summary).prefix(400)),
                options: ["Not needed", "Needed"])], deadline: Date().addingTimeInterval(30))
            let started = Date()
            let result = try await laya.decide(request)
            times.append(Date().timeIntervalSince(started) * 1000)
            let answer = try #require(result.answers.first)
            let hit = answer.selectedIndex == (probe.needed ? 1 : 0)
            if hit { right += 1 }
            if answer.confidence >= DecisionKind.selectContext.threshold { accepted += 1; if hit { rightAccepted += 1 } }
        }
        print(Self.line("selectContext", right: right, accepted: accepted, rightAccepted: rightAccepted, total: Self.contextProbes.count, times: times, cold: nil))
        // Laya answers every probe with valid probabilities; how good they are is reported, not asserted.
        #expect(times.count == Self.contextProbes.count)
    }

    static func line(_ kind: String, right: Int, accepted: Int, rightAccepted: Int, total: Int, times: [Double], cold: Double?) -> String {
        let sorted = times.sorted(), median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        return "LAYA_EVAL \(kind): accuracy \(right)/\(total), accepted \(accepted)/\(total), right when accepted \(rightAccepted)/\(accepted), median \(Int(median)) ms"
            + (cold.map { String(format: ", cold load %.1f s", $0) } ?? "")
    }
}

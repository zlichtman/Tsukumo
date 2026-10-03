import XCTest
#if os(macOS)
@testable import KemoSabeMac
#else
@testable import KemoSabe
#endif

/// The held-out Laya evaluation through the shipping Swift path (`CoreMLLayaProvider`), on the Mac
/// and in the iPhone Simulator. It needs the downloaded model, so it runs only when asked:
///
/// - `TEST_RUNNER_KEMO_LAYA_DIR=/path/to/model` uses a folder with the pinned files, or
/// - `TEST_RUNNER_KEMO_LAYA_INTEGRATION=1` downloads the pinned pack through the app's own
///   `VoiceModelStore` (checked by size and SHA-256) into `KEMO_LAYA_CACHE` or a temporary folder.
///
/// Cases: `EvaluationAssets/laya-heldout.json` (the calibration and test splits of
/// scripts/train_laya.py) plus a few hand-labeled probes phrased exactly as the app asks. Every
/// case's probabilities and timing are printed as one `LAYA_EVAL_JSON` line; abstention thresholds
/// are chosen from the calibration split only. See design/LAYA-TRAINING.md.
final class LayaEvaluationTests: XCTestCase {
    struct Case: Decodable { let split: String; let domain: String; let state: String; let instruction: String; let options: [String]; let label: Int }
    struct Fixture: Decodable { let cases: [Case] }

    private func directory() async throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["KEMO_LAYA_DIR"] { return URL(fileURLWithPath: path, isDirectory: true) }
        if environment["KEMO_LAYA_INTEGRATION"] == "1" {
            let root = environment["KEMO_LAYA_CACHE"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("KemoSabeLayaModelTests", isDirectory: true)
            let model = root.appendingPathComponent(VoiceModelPack.laya.id).appendingPathComponent("model")
            if LayaModel.isReady(at: model) { return model }
            let store = await MainActor.run { VoiceModelStore(pack: .laya, root: root) }
            let state = await MainActor.run { () -> VoiceModelState in store.wifiOnly = false; if !store.isInstalled { store.download() }; return store.state }
            if state != .installed { await store.waitUntilDone() }
            let installed = await MainActor.run { store.state }
            XCTAssertEqual(installed, .installed, "The pinned download installs")
            return model
        }
        let bundled = Bundle(for: Self.self).resourceURL?.appendingPathComponent("EvaluationAssets/Laya")
        guard let bundled, FileManager.default.fileExists(atPath: bundled.appendingPathComponent("coreml_config.json").path) else {
            throw XCTSkip("Set TEST_RUNNER_KEMO_LAYA_DIR or TEST_RUNNER_KEMO_LAYA_INTEGRATION=1 to evaluate Laya. A skip certifies nothing.")
        }
        return bundled
    }
    private func fixture() throws -> [Case] {
        var url = Bundle(for: Self.self).resourceURL?.appendingPathComponent("EvaluationAssets/laya-heldout.json")
        if url.map({ !FileManager.default.fileExists(atPath: $0.path) }) ?? true {
            // The Mac test bundle doesn't carry EvaluationAssets; read it from the source tree.
            url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("EvaluationAssets/laya-heldout.json")
        }
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url!)).cases
    }
    /// Phrased exactly as the app asks (ConversationRouting, DailyAssistant), hand-labeled. Reported
    /// apart from the held-out split: a sanity check on the real wording, not a benchmark.
    static let probes: [Case] = {
        let intent = "What does the current user request?", labels = ConversationRouting.systemOneLabels
        let missing = DailyAssistant.missingQuestion, fit = "Which permitted time best fits the stated request?"
        func i(_ state: String, _ label: Int) -> Case { .init(split: "probe", domain: "intent", state: state, instruction: intent, options: labels, label: label) }
        func m(_ state: String, _ label: Int) -> Case { .init(split: "probe", domain: "missing_information", state: state, instruction: missing.instruction, options: missing.options, label: label) }
        func f(_ state: String, _ options: [String], _ label: Int) -> Case { .init(split: "probe", domain: "fit", state: state, instruction: fit, options: options, label: label) }
        return [
            i("What's the capital of Australia?", 0), i("Tell me a joke", 0), i("Count from 1 to 10", 1), i("What is 15% of 80?", 2),
            i("Spell necessary backwards", 3), i("Draft a thank-you note to my landlord", 4), i("Remember that my sister's birthday is June 3", 5),
            i("Set an alarm for 6:30 tomorrow", 6), i("Make time for a run tomorrow morning", 7), i("Remind me to call Mom at 5", 7),
            i("Block an hour for writing this afternoon", 7), i("I prefer to exercise in the evenings, not mornings", 8),
            m("Make time for reading tomorrow", 1), m("Schedule a 30 minute walk today", 1), m("Block two hours for taxes on Saturday", 1),
            m("Make time for something", 0), m("Schedule it", 0), m("Find time for studying", 0),
            f("Make time for reading tomorrow afternoon", ["9:00 AM", "2:00 PM", "6:00 PM"], 1),
            f("Schedule a morning run", ["7:00 AM", "12:30 PM", "5:00 PM"], 0),
            f("Block an hour for writing in the evening", ["10:00 AM", "3:00 PM", "7:30 PM"], 2),
            f("I need time for groceries after lunch", ["9:00 AM", "1:30 PM", "8:00 PM"], 1),
        ]
    }()

    func testHeldOutAccuracyCalibrationAndLatency() async throws {
        let directory = try await directory()
        let provider = CoreMLLayaProvider(directory: directory)
        let cases = try fixture() + Self.probes
        var rows: [[String: Any]] = []
        let coldStart = Date()
        _ = try await provider.decide(.init(state: "Warm up.", questions: [.init(id: "w", kind: .choice, instruction: "Pick one", options: ["a", "b"])], deadline: Date().addingTimeInterval(600)))
        let cold = Date().timeIntervalSince(coldStart)
        for (index, item) in cases.enumerated() {
            var questions = [DecisionQuestion(id: "q", kind: .choice, instruction: item.instruction, options: item.options)]
            // The app's intent request carries a second question; the decision needs both to be sure.
            if item.split == "probe", item.domain == "intent" {
                questions.append(.init(id: "history", kind: .choice, instruction: "Does the request depend on previous conversation?", options: ["self contained", "follow up"]))
            }
            let request = DecisionRequest(state: item.state, questions: questions, deadline: Date().addingTimeInterval(600))
            let start = Date()
            let result = try await provider.decide(request)
            let milliseconds = Date().timeIntervalSince(start) * 1000
            XCTAssertNoThrow(try result.validate(for: request))
            XCTAssertFalse(result.calibrated, "Upstream temperatures, never claimed as a Kemo calibration")
            rows.append(["index": index, "split": item.split, "domain": item.domain, "label": item.label,
                         "probabilities": result.answers[0].probabilities, "min_confidence": result.answers.map(\.confidence).min() ?? 0,
                         "ms": milliseconds])
        }
        func metrics(_ subset: [[String: Any]]) -> [String: Any] {
            var correct = 0, brier = 0.0, nll = 0.0, confidences: [(Double, Bool)] = []
            for row in subset {
                let p = row["probabilities"] as! [Double], label = row["label"] as! Int
                let top = p.indices.max { p[$0] < p[$1] }!, hit = top == label
                correct += hit ? 1 : 0
                brier += p.indices.reduce(0) { $0 + pow(p[$1] - ($1 == label ? 1 : 0), 2) }
                nll -= log(max(p[label], 1e-10))
                confidences.append((p[top], hit))
            }
            var ece = 0.0
            for bin in 0..<10 {
                let bucket = confidences.filter { (Double(bin) / 10 <= $0.0 && $0.0 < Double(bin + 1) / 10) || (bin == 9 && $0.0 == 1) }
                guard !bucket.isEmpty else { continue }
                let meanConfidence = bucket.map(\.0).reduce(0, +) / Double(bucket.count)
                let accuracy = Double(bucket.filter(\.1).count) / Double(bucket.count)
                ece += Double(bucket.count) / Double(subset.count) * abs(meanConfidence - accuracy)
            }
            let n = Double(max(subset.count, 1))
            return ["cases": subset.count, "accuracy": Double(correct) / n, "brier": brier / n, "ece": ece, "nll": nll / n]
        }
        let latency = rows.map { $0["ms"] as! Double }.sorted()
        var summary: [String: Any] = ["cold_seconds": cold, "warm_p50_ms": latency[latency.count / 2],
                                      "warm_p95_ms": latency[Int(Double(latency.count) * 0.95)], "questions_timed": latency.count,
                                      "model": "aac6fef/laya-coreml@fff78b2d9750c6b748fe8c90fcbf8bed0a1522a9 (base convaiinnovations/laya@c5d7873)",
                                      "os": ProcessInfo.processInfo.operatingSystemVersionString]
        #if targetEnvironment(simulator)
        summary["platform"] = "iOS Simulator"
        #elseif os(macOS)
        summary["platform"] = "macOS"
        #else
        summary["platform"] = "iOS device"
        #endif
        for split in ["calibration", "test", "probe"] {
            let subset = rows.filter { $0["split"] as? String == split }
            var entry = metrics(subset)
            entry["domains"] = Dictionary(uniqueKeysWithValues: Set(subset.map { $0["domain"] as! String }).map { domain in
                (domain, metrics(subset.filter { $0["domain"] as? String == domain }))
            })
            summary[split] = entry
        }
        let report: [String: Any] = ["summary": summary, "rows": rows]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("LAYA_EVAL_JSON " + String(decoding: data, as: UTF8.self))
        if let out = ProcessInfo.processInfo.environment["KEMO_LAYA_OUT"] { try? data.write(to: URL(fileURLWithPath: out)) }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json"); attachment.name = "Laya evaluation"; attachment.lifetime = .keepAlways
        add(attachment)
        // Parity with upstream Python on the pinned fixture: the confident wrong answer is expected.
        let golden = try await provider.decide(.init(state: "The person prefers focused work in the afternoon and has a meeting at 17:00.",
            questions: [.init(id: "fit", kind: .choice, instruction: "Which time suits a person who prefers afternoon focus?", options: ["09:00", "14:00", "17:00"])],
            deadline: Date().addingTimeInterval(600)))
        for (actual, expected) in zip(golden.answers[0].probabilities, [0.0062, 0.0093, 0.9845]) { XCTAssertEqual(actual, expected, accuracy: 0.02) }
    }
}

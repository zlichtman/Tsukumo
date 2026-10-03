import XCTest
import UIKit
import Darwin
@testable import KemoSabe

final class LayaDeviceTests: XCTestCase {
    func testPinnedEnglishCoreMLParityAndLatency() async throws {
        let root = Bundle(for: Self.self).resourceURL!.appendingPathComponent("EvaluationAssets")
        let directory = root.appendingPathComponent("Laya")
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("coreml_config.json").path) else {
            throw XCTSkip("Download pinned evaluation assets with scripts/prepare_laya_evaluation.py; no model performance has been certified by this skip.")
        }
        let provider = CoreMLLayaProvider(directory: directory)
        let baselineMemory = Self.footprint()
        let batteryBefore = await MainActor.run { UIDevice.current.isBatteryMonitoringEnabled = true; return UIDevice.current.batteryLevel }
        let request = DecisionRequest(state: "The person prefers focused work in the afternoon and has a meeting at 17:00.",
            questions: [.init(id: "fit", kind: .choice, instruction: "Which time suits a person who prefers afternoon focus?", options: ["09:00","14:00","17:00"])], deadline: Date().addingTimeInterval(600))
        let coldStart = Date()
        let result = try await provider.decide(request)
        let cold = Date().timeIntervalSince(coldStart)
        // This fixture deliberately exposes a confidently wrong upstream answer.
        // Parity certifies the port, not fit quality or permission to act.
        XCTAssertEqual(result.answers.first?.selectedIndex, 2)
        let expected = [0.0062,0.0093,0.9845]
        for (actual,golden) in zip(result.answers[0].probabilities,expected) { XCTAssertEqual(actual,golden,accuracy: 0.02) }
        XCTAssertFalse(result.calibrated)
        var latency: [Double] = [], memorySamples = [baselineMemory, Self.footprint()].compactMap { $0 }
        let warmStart = Date()
        for run in 0..<600 {
            let start = Date(); let next = try await provider.decide(request)
            latency.append(Date().timeIntervalSince(start)*1000)
            XCTAssertEqual(next.answers[0].selectedIndex, result.answers[0].selectedIndex)
            if run % 20 == 0, let sample = Self.footprint() { memorySamples.append(sample) }
        }
        latency.sort()
        let batteryAfter = await MainActor.run { UIDevice.current.batteryLevel }
        let metrics: [String: Any] = ["cold_seconds":cold,"warm_p50_ms":latency[300],"warm_p95_ms":latency[569],"runs":600,
            "warm_duration_seconds":Date().timeIntervalSince(warmStart),
            "process_baseline_memory_bytes":baselineMemory as Any? ?? NSNull(),
            "process_max_sampled_memory_bytes":memorySamples.max() as Any? ?? NSNull(),
            "battery_fraction_before":batteryBefore,"battery_fraction_after":batteryAfter,
            "thermal_state":ProcessInfo.processInfo.thermalState.rawValue,"os":ProcessInfo.processInfo.operatingSystemVersionString,
            "model":"aac6fef/laya-coreml@fff78b2d9750c6b748fe8c90fcbf8bed0a1522a9",
            "quality_certified":false,"battery_drain_certified":false,"peak_memory_measured":false,
            "memory_note":"Sampled test-host footprint, not allocation peak or standalone model memory.",
            "battery_note":"Coarse system samples over a short run; not an energy or all-day battery benchmark."]
        let data = try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys,.prettyPrinted])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json"); attachment.name = "Laya device evidence"; attachment.lifetime = .keepAlways
        add(attachment)
        print("LAYA_DEVICE_EVIDENCE " + String(decoding:data,as:UTF8.self))
        let oversized = DecisionRequest(state:String(repeating:"very long input ",count:400),questions:request.questions,deadline:request.deadline)
        do { _ = try await provider.decide(oversized); XCTFail("Must reject over-budget input without truncation") }
        catch DecisionError.contextLimit {} catch { XCTFail("Unexpected failure: \(error)") }
    }
    private static func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }
}

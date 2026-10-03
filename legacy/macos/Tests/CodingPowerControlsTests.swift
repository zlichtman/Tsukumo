import XCTest
import SwiftUI
@testable import KemoSabeMac

/// The composer's power-up effort slider and selector bars: efforts laid out as slider stops
/// (the model's default first, fewer or no efforts, unknown names), heat and titles, carrying an
/// effort to another model, and that a chosen effort is remembered for new chats and per task.
/// With `TSUKUMO_SNAPSHOT_DIR` set, it also renders the popovers and bars to PNGs for review.
@MainActor final class CodingPowerControlsTests: XCTestCase {
    // MARK: Efforts to slider stops

    func testEffortsBecomeStopsWithTheDefaultFirst() {
        let scale = CodingEffortScale(efforts: ["high", "low", "xhigh", "medium", "max", "high"], defaultEffort: "medium")
        XCTAssertEqual(scale.stops, [nil, "low", "medium", "high", "xhigh", "max"], "Lightest to heaviest, repeats dropped, default at the left")
        XCTAssertEqual(scale.count, 6); XCTAssertTrue(scale.hasEfforts)
        XCTAssertEqual(scale.step(for: nil), 0)
        XCTAssertEqual(scale.step(for: "high"), 3)
        XCTAssertNil(scale.effort(at: 0))
        XCTAssertEqual(scale.effort(at: 5), "max")
        XCTAssertEqual(scale.effort(at: 99), "max", "Out of range clamps")
        XCTAssertNil(scale.effort(at: -3))
        for step in 0..<scale.count { XCTAssertEqual(scale.step(for: scale.effort(at: step)), step, "Round trip at \(step)") }
    }
    func testCodexEffortsIncludingUltraAndNone() {
        let scale = CodingEffortScale(efforts: ["ultra", "xhigh", "low", "none", "medium", "high", "max"])
        XCTAssertEqual(scale.stops, [nil, "none", "low", "medium", "high", "xhigh", "max", "ultra"])
    }
    func testAgentWithFewerEfforts() {
        let scale = CodingEffortScale(efforts: ["low", "high"])
        XCTAssertEqual(scale.stops, [nil, "low", "high"])
        XCTAssertEqual(scale.step(for: "high"), 2)
        // An effort chosen for another model sits at the nearest weight this one lists.
        XCTAssertEqual(scale.step(for: "max"), 2)
        XCTAssertEqual(scale.step(for: "minimal"), 1)
        XCTAssertEqual(scale.step(for: "medium"), 1, "A tie goes to the lighter effort")
        XCTAssertEqual(scale.step(for: "turbo"), 0, "An unknown name sits at the default")
    }
    func testModelWithoutEffortsHasOnlyTheDefault() {
        let scale = CodingEffortScale(efforts: [])
        XCTAssertEqual(scale.stops, [nil]); XCTAssertFalse(scale.hasEfforts)
        XCTAssertEqual(scale.step(for: "high"), 0)
        XCTAssertNil(scale.effort(at: 2))
    }
    func testHeatFollowsTheEffortsOwnWeight() {
        let full = CodingEffortScale(efforts: ["low", "medium", "high", "xhigh", "max"], defaultEffort: "medium")
        let heats = (0..<full.count).dropFirst().map { full.heat(at: $0) }
        XCTAssertEqual(heats, heats.sorted(), "Hotter as effort rises")
        XCTAssertEqual(full.heat(at: 0), CodingEffortScale.heat("medium"), "The default takes its effort's heat")
        XCTAssertEqual(CodingEffortScale(efforts: ["low", "max"]).heat(at: 2), full.heat(at: 5), "Max is hot whatever else a model lists")
        XCTAssertEqual(CodingEffortScale.heat("ultra"), 1)
        XCTAssertGreaterThan(CodingSparkleField.starCount(1), CodingSparkleField.starCount(0.1), "More sparkles at high effort")
        let (low, high) = (CodingEffortHeat.ramp(accent: .purple, heat: 0.1, dark: true), CodingEffortHeat.ramp(accent: .purple, heat: 1, dark: true))
        XCTAssertEqual(low.count, 3); XCTAssertNotEqual(NSColor(low[2]), NSColor(high[2]), "The hot end changes with effort")
    }
    func testTitles() {
        XCTAssertEqual(CodingEffortScale.title(nil), "Model's default")
        XCTAssertEqual(CodingEffortScale.title("xhigh"), "Extra high")
        XCTAssertEqual(CodingEffortScale.title("ultra"), "Ultra")
        XCTAssertEqual(CodingEffortScale.title("medium"), "Medium")
    }
    func testCatalogEffortsAndDefaultsForAModel() {
        let models: [CodingAgentModel] = [
            .init(id: "gpt-6-sol", name: "GPT-6-Sol", efforts: ["low", "medium", "high", "xhigh", "max", "ultra"], defaultEffort: "high", isDefault: true),
            .init(id: "gpt-5.5", name: "GPT-5.5", efforts: ["low", "medium", "high"], defaultEffort: "medium")
        ]
        XCTAssertEqual(CodingAgentCatalog.efforts(in: models, model: "gpt-5.5"), ["low", "medium", "high"])
        XCTAssertEqual(CodingAgentCatalog.defaultEffort(in: models, model: ""), "high", "The default model is the one the agent marks")
        XCTAssertEqual(CodingAgentCatalog.efforts(in: models, model: "unlisted"), ["low", "medium", "high", "xhigh", "max", "ultra"], "An unlisted model offers every effort, in order")
        XCTAssertEqual(CodingEffortScale.carry("xhigh", to: CodingAgentCatalog.efforts(in: models, model: "gpt-5.5")), nil, "An effort the new model lacks goes back to its default")
        XCTAssertEqual(CodingEffortScale.carry("high", to: CodingAgentCatalog.efforts(in: models, model: "gpt-5.5")), "high")
        XCTAssertNil(CodingEffortScale.carry(nil, to: ["low"]))
    }

    // MARK: Persistence

    func testNewChatRemembersTheChosenEffort() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "CodingPowerControlsTests-" + UUID().uuidString))
        var settings = CodingNewTaskSettings.remembered(defaults)
        settings.model = "gpt-6-sol"; settings.effort = "ultra"; settings.isolated = false
        settings.remember(defaults)
        let restored = CodingNewTaskSettings.remembered(defaults)
        XCTAssertEqual(restored.effort, "ultra"); XCTAssertEqual(restored.model, "gpt-6-sol"); XCTAssertFalse(restored.isolated)
        settings.effort = nil; settings.remember(defaults)
        XCTAssertNil(CodingNewTaskSettings.remembered(defaults).effort, "Back to the model's default is remembered too")
    }
    func testTaskEffortChangedMidTurnIsKeptAndSaysWhenItApplies() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CodingPowerControlsTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fake = PowerFakeSession()
        let store = CodingWorkspaceStore(storage: .init(directory: folder, ownerID: "local-test"), sessionFactory: { _ in fake })
        let project = DesktopProject(name: "Fixture", bookmark: Data())
        let created = await store.create(project: project, root: folder, provider: .codex, model: "", access: .edit, isolated: false, prompt: "Go")
        let id = try XCTUnwrap(created)
        XCTAssertEqual(store.task(id)?.status.running, true)
        store.setModel(id, model: "gpt-6-sol", effort: "ultra")
        XCTAssertEqual(store.task(id)?.effort, "ultra")
        XCTAssertEqual(store.task(id)?.events.last?.detail, "Applies from the next message after this turn.")
        let reloaded = CodingWorkspaceStore(storage: .init(directory: folder, ownerID: "local-test"))
        XCTAssertEqual(reloaded.task(id)?.effort, "ultra"); XCTAssertEqual(reloaded.task(id)?.model, "gpt-6-sol")
    }

    // MARK: Snapshots for review

    func testRenderSnapshots() throws {
        guard let path = ProcessInfo.processInfo.environment["TSUKUMO_SNAPSHOT_DIR"], !path.isEmpty else { throw XCTSkip("Set TSUKUMO_SNAPSHOT_DIR to render the power controls") }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let models: [CodingAgentModel] = [
            .init(id: "gpt-6-sol", name: "GPT-6-Sol", detail: "Frontier coding", efforts: ["low", "medium", "high", "xhigh", "max", "ultra"], defaultEffort: "high", isDefault: true),
            .init(id: "gpt-6-luna", name: "GPT-6-Luna", detail: "Fast and light", efforts: ["low", "medium", "high"], defaultEffort: "medium")
        ]
        for (theme, themeName) in [(DesktopThemeName.kemoSabe, "kemosabe"), (.tsukumo, "tsukumo")] {
            for dark in [false, true] {
                let scheme: ColorScheme = dark ? .dark : .light
                let palette = DesktopPalette.make(theme, dark: dark)
                let mode = dark ? "dark" : "light"
                for (label, effort) in [("low", Optional("low")), ("mid", "high"), ("max", "ultra"), ("default", nil)] where theme == .kemoSabe || label == "max" {
                    let popover = CodingEffortPopover(provider: .codex, models: models, running: label == "mid", accent: palette.accent, model: "gpt-6-sol", effort: effort, animate: false, commit: { _, _ in }, close: {})
                    try render(frame(popover, palette: palette, scheme: scheme), to: folder.appendingPathComponent("effort-\(label)-\(themeName)-\(mode).png"))
                }
                guard theme == .kemoSabe else { continue }
                let list = CodingEffortPopover(provider: .codex, models: models, accent: palette.accent, model: "gpt-6-sol", effort: "high", page: .models, animate: false, commit: { _, _ in }, close: {})
                try render(frame(list, palette: palette, scheme: scheme), to: folder.appendingPathComponent("models-\(themeName)-\(mode).png"))
                let access = CodingAccessPopover(provider: .codex, current: .edit, accent: palette.accent, apply: { _ in }, close: {})
                try render(frame(access, palette: palette, scheme: scheme), to: folder.appendingPathComponent("access-\(themeName)-\(mode).png"))
                let full = CodingAccessPopover(provider: .codex, current: .edit, accent: palette.accent, confirmingFull: true, apply: { _ in }, close: {})
                try render(frame(full, palette: palette, scheme: scheme), to: folder.appendingPathComponent("access-full-confirm-\(themeName)-\(mode).png"))
                try render(composerRow(palette: palette, scheme: scheme), to: folder.appendingPathComponent("selector-bars-\(themeName)-\(mode).png"))
            }
        }
    }
    private func frame(_ content: some View, palette: DesktopPalette, scheme: ColorScheme) -> some View {
        content
            .background(palette.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
            .padding(28)
            .background(palette.sidebar)
            .environment(\.colorScheme, scheme)
    }
    /// The composer's controls row as it reads with the bars: chips, the Worktree/Local bar, send.
    private func composerRow(palette: DesktopPalette, scheme: ColorScheme) -> some View {
        func chip(_ title: String, _ symbol: String, tint: Color? = nil) -> some View {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint ?? Color.primary.opacity(0.85))
                Text(title)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
            }
            .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.primary.opacity(0.85))
            .padding(.horizontal, 10).frame(height: 30)
            .background(Color.primary.opacity(0.07), in: Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
        }
        let scale = CodingEffortScale(efforts: ["low", "medium", "high", "xhigh", "max", "ultra"])
        return VStack(alignment: .leading, spacing: 14) {
            Text("Ask Codex to build, fix, or explain something…").font(.system(size: 13)).foregroundStyle(.tertiary).padding(.horizontal, 6)
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 14, weight: .medium)).frame(width: 32, height: 32).background(Color.primary.opacity(0.07), in: Circle())
                chip("KemoSabe", "folder")
                chip("Codex", "sparkles")
                chip("GPT-6-Sol · Ultra", "bolt.fill", tint: CodingEffortHeat.title(accent: palette.accent, heat: scale.heat(at: 6), dark: scheme == .dark))
                chip("Ask first", "hand.raised")
                CodingSelectorBar(options: [.init(value: true, title: "Worktree", symbol: "arrow.triangle.branch"), .init(value: false, title: "Local", symbol: "folder")],
                                  selection: true, accent: palette.accent, compact: true) { _ in }.fixedSize()
                Spacer(minLength: 8)
                Image(systemName: "arrow.up").font(.system(size: 14, weight: .semibold)).frame(width: 32, height: 32)
                    .foregroundStyle(scheme == .dark ? Color.black.opacity(0.85) : Color.white).background(palette.accent, in: Circle())
            }
        }
        .padding(10).frame(width: 760)
        .background(palette.sidebar, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Color.primary.opacity(0.1), lineWidth: 0.75))
        .padding(28).background(palette.background)
        .environment(\.colorScheme, scheme)
    }
    private func render(_ view: some View, to url: URL) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage, "Rendered \(url.lastPathComponent)")
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: url)
    }
}

@MainActor private final class PowerFakeSession: AgentSession {
    var onEvent: ((CodingEvent, Bool) -> Void)?
    var onState: ((CodingTaskStatus) -> Void)?
    var onSession: ((String) -> Void)?
    var onApproval: ((CodingApproval?) -> Void)?
    func send(_ text: String) throws { onState?(.working) }
    func respond(_ id: String, allow: Bool, answers: String) throws {}
    func interrupt() {}
    func stop() {}
}

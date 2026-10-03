import XCTest
import SwiftUI
import AppKit
@testable import KemoSabeMac

/// Kemo in a chat on the Mac (September 27, 2026): the stage above the conversation while there's
/// room, the latest reply's avatar when the conversation fills the window, the thinking row as the
/// avatar with its orb, and Tsukumo's task chat with the agent's mark and Kemo at its desk. Renders
/// dark snapshots for review when `TSUKUMO_SNAPSHOT_DIR` is set, and checks where Kemo is either way.
@MainActor final class ChatStageSnapshotTests: XCTestCase {
    private var folder: URL!
    override func setUp() { folder = FileManager.default.temporaryDirectory.appendingPathComponent("ChatStageSnapshots-" + UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    private let size = CGSize(width: 820, height: 620)
    private var out: URL? {
        guard let path = ProcessInfo.processInfo.environment["TSUKUMO_SNAPSHOT_DIR"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The Mac chat's stage and transcript with `messages` exchanges; reports whether the stage is shown.
    private func chat(exchanges: Int, thinking: Bool = false, name: String) throws -> Bool {
        let store = AppStore(repository: .init(url: folder.appendingPathComponent(name + "/state.json")), apiKeys: MemoryAPIKeys())
        for index in 0..<exchanges {
            store.appendVisibleMessage(role: "You", text: "Question \(index + 1): what should I focus on next?")
            store.appendVisibleMessage(role: "KemoSabe", text: "Answer \(index + 1). Start with the smallest step you can finish today, then build on it.")
        }
        if thinking { store.appendVisibleMessage(role: "You", text: "Plan my week"); store.isThinking = true }
        let defaults = UserDefaults(suiteName: "ChatStageSnapshots-" + UUID().uuidString)!
        let preferences = DesktopPreferences(defaults: defaults)
        let palette = preferences.palette(.dark)
        let shown = StageBox()
        let view = StageHost(box: shown)
            .environment(store).environment(AppNavigation()).environment(preferences)
            .environment(\.chatAccentOverride, palette.accent)
            .foregroundStyle(palette.foreground).tint(palette.accent)
            .background(palette.background)
        try render(view, name: "mac-chat-" + name)
        return shown.value
    }

    func testTheMacChatHasKemoOnTheStageOrInTheAvatar() throws {
        XCTAssertTrue(try chat(exchanges: 0, name: "new"), "A new chat starts with Kemo on the stage")
        XCTAssertTrue(try chat(exchanges: 1, name: "short"), "A short conversation keeps the stage")
        XCTAssertFalse(try chat(exchanges: 10, name: "long"), "A long conversation puts Kemo in the latest reply's avatar")
        XCTAssertFalse(try chat(exchanges: 10, thinking: true, name: "thinking"), "Thinking: the avatar with its orb")
    }

    /// The owner's report (September 27): a new KemoSabe chat's Kemo sat higher and bigger than a new
    /// Tsukumo task's, and didn't appear on the first load. Both pages start under the window's header;
    /// their composers differ in height, and Kemo must still land in the same place at the same size.
    func testANewChatsKemoMatchesANewTsukumoTask() throws {
        let store = AppStore(repository: .init(url: folder.appendingPathComponent("match/state.json")), apiKeys: MemoryAPIKeys())
        let preferences = DesktopPreferences(defaults: UserDefaults(suiteName: "ChatStageSnapshots-" + UUID().uuidString)!)
        let palette = preferences.palette(.dark)
        var chatFrame: CGRect?, taskFrame: CGRect?
        let page = size.height
        // KemoSabe's chat page: the stage and transcript over its composer area.
        let chat = VStack(spacing: 0) {
            StageHost(box: StageBox(), pageHeight: page)
            Color.gray.opacity(0.2).frame(height: 112)
        }.environment(\.newChatKemoFrame) { chatFrame = $0 }
        try render(chat.environment(store).environment(AppNavigation()).environment(preferences)
            .environment(\.chatAccentOverride, palette.accent).background(palette.background), name: "mac-new-chat-kemosabe", appearOnce: true)
        // A new Tsukumo task: the greeting over a taller composer area (it adds the sign-in line).
        let task = VStack(spacing: 0) {
            ScrollView {
                CodingNewChatGreeting(provider: .claude, project: "KemoSabe", creating: false, pageHeight: page)
                    .padding(.horizontal, 24).frame(maxWidth: 780).frame(maxWidth: .infinity)
            }
            Color.gray.opacity(0.2).frame(height: 146)
        }.environment(\.newChatKemoFrame) { taskFrame = $0 }
        try render(task.environment(store).environment(preferences).background(palette.background), name: "mac-new-chat-tsukumo", appearOnce: true)
        let kemo = try XCTUnwrap(chatFrame, "KemoSabe's Kemo is there on the first load")
        let atWork = try XCTUnwrap(taskFrame, "Tsukumo's Kemo at work is there")
        XCTAssertEqual(kemo.size.width, NewChatMetrics.kemoSize, accuracy: 0.5)
        XCTAssertEqual(kemo.size.width, atWork.size.width, accuracy: 0.5, "Same size")
        XCTAssertEqual(kemo.size.height, atWork.size.height, accuracy: 0.5, "Same size")
        XCTAssertEqual(kemo.minY, atWork.minY, accuracy: 0.5, "Same place")
        XCTAssertEqual(kemo.midX, atWork.midX, accuracy: 0.5, "Same center line")
    }

    func testTsukumoTaskShowsTheAgentsMarkAndKemoAtItsDesk() throws {
        let store = AppStore(repository: .init(url: folder.appendingPathComponent("tsukumo/state.json")), apiKeys: MemoryAPIKeys())
        let coding = CodingWorkspaceStore(storage: .init(directory: folder.appendingPathComponent("tasks"), ownerID: "local-test"))
        let preferences = DesktopPreferences(defaults: UserDefaults(suiteName: "ChatStageSnapshots-" + UUID().uuidString)!)
        let palette = preferences.palette(.dark)
        func task(_ turns: Int) -> CodingTaskRecord {
            var record = CodingTaskRecord(projectID: UUID(), ownerID: "local-test", title: "Fix the flaky test", provider: .claude, model: "opus",
                                          access: .edit, projectPath: folder.path, directory: folder.path, isolated: true)
            record.status = .working
            for index in 0..<turns {
                record.events.append(.init(kind: .user, text: index == 0 ? "Find why DayRangeTests fails on Mondays and fix it." : "Also check the week view."))
                record.events.append(.init(kind: .assistant, text: "I found it: the range starts on the locale's first weekday. I'll pin the calendar in the test and fix `DayRange.week`."))
            }
            record.events.append(.init(kind: .command, text: "swift test --filter DayRangeTests", status: "inProgress", tool: "Bash"))
            return record
        }
        XCTAssertEqual(CodingActivity.performance(task(1)), "testing", "Kemo acts out the running tests")
        for (name, turns) in [("short", 1), ("long", 6)] {
            let view = CodingTranscriptView(task: task(turns))
                .environment(store).environment(coding).environment(preferences)
                .foregroundStyle(palette.foreground).tint(palette.accent)
                .background(palette.background)
            try render(view, name: "mac-tsukumo-task-" + name)
        }
    }

    private func render(_ view: some View, name: String, appearOnce: Bool = false) throws {
        let window = NSWindow(contentRect: .init(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark).frame(width: size.width, height: size.height))
        host.frame = .init(origin: .zero, size: size)
        window.contentView = host
        // Let the scroll geometry settle and the stage decide (and finish its spring) before drawing;
        // a first-load check draws right after the first layout.
        RunLoop.main.run(until: Date().addingTimeInterval(appearOnce ? 0.3 : 1.6))
        host.layoutSubtreeIfNeeded()
        if let out {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent(name + ".png"))
        }
        window.contentView = nil
    }
}

/// Where the stage ended up, read after rendering.
@MainActor private final class StageBox { var value = true }
private struct StageHost: View {
    let box: StageBox
    var pageHeight: CGFloat = 0
    @State private var pinned = false
    @State private var shown = true
    var body: some View {
        DesktopChatStage(expanded: true, pinned: $pinned, stageShown: $shown, active: false, reduceMotion: true, pageHeight: pageHeight) { _ in }
            .onChange(of: shown, initial: true) { box.value = shown }
    }
}

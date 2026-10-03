import XCTest
import SwiftUI
import AppKit
@testable import KemoSabeMac

/// The website's Tsukumo pictures (September 28, 2026), rendered from the app's own views on invented
/// sample data: a sample PowderMeet repository in a temporary folder, tasks from Claude Code, Codex,
/// and Muse Code, and a coordination board. Nothing here reads or writes the person's data.
///
/// - `TSUKUMO_SNAPSHOT_DIR`: writes `site-workspace.png`, `site-review.png`, and `site-coordination.png`
///   at 2x from a 1108 x 611 pt window, so each is 2216 x 1222 px: exactly the MacBook screen in the
///   website's device frame (its screen box is 1108 x 611 CSS px at full size), with no letterboxing.
/// - `TSUKUMO_SITE_FRAMES`: writes 480 frames of the coordination diagram (8 s at 60 fps, a seamless
///   loop: packets repeat every 0.8 s, overlap dashes every 0.5 s, and the loop point sits at an LED
///   peak) as `frame-0000.png`… for ffmpeg.
@MainActor final class SiteDemoSnapshotTests: XCTestCase {
    /// The website's MacBook screen, in points; the pictures are twice this in pixels.
    static let screen = CGSize(width: 1108, height: 611)
    private var folder: URL!
    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SiteDemo-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: folder) }
    private func env(_ key: String) -> URL? {
        guard let path = ProcessInfo.processInfo.environment[key], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    // MARK: Workspace and review

    func testWorkspaceAndReview() async throws {
        guard let out = env("TSUKUMO_SNAPSHOT_DIR") else { throw XCTSkip("Set TSUKUMO_SNAPSHOT_DIR to render the site pictures") }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let scene = try await DemoScene.make(in: folder)
        // The account row at the bottom of the sidebar: an invented person, in this test host's own settings.
        var account = KemoAccount(); account.name = "Alex Rivera"
        AccountDirectory.accountSettings.set(try JSONEncoder().encode(account), forKey: AccountStore.key)
        AccountStore.reopen()

        // 1. The window: the sidebar's tasks and an open task chat, the side pane closed.
        let root = DesktopRootView(minimize: {}, preferencesChanged: {})
        let window = try host(scene.environment(root), size: Self.screen)
        // Key (far off screen, never seen) so the click below reaches the button.
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000)); window.orderFront(nil); window.makeKey()
        try await settle(1.5)
        // The Changes toggle in the task's header (114 pt in from the right edge), clicked as a person would,
        // closes the Changes pane so the conversation has the whole width.
        click(window, at: CGPoint(x: Self.screen.width - 114, y: 56))
        try await settle(1.2)
        try write(window, to: out.appendingPathComponent("site-workspace.png"))
        window.orderOut(nil); window.contentView = nil

        // 3. Review: the same task's chat beside its Changes pane, with the diff and Accept / Request revision.
        let review = try host(scene.environment(CodingWorkspaceView()), size: Self.screen)
        try await settle(2.5)
        try write(review, to: out.appendingPathComponent("site-review.png"))
        review.contentView = nil
        XCTAssertFalse(scene.coding.storageFailed)
        XCTAssertEqual(scene.coding.task(scene.selected)?.changes.count, 2, "The review task changed two files")
    }

    // MARK: Coordination

    /// You, Claude Code, Codex, and Muse Code, plus a subtask waiting on Claude Code's; Claude Code and
    /// Codex share the route solver, and you and Muse Code share the meet screen.
    static var board: CollabBoard {
        let now = Date()
        func task(_ id: String, _ agent: String?, _ title: String, _ state: CollabState, _ files: [(String, String?, Int, Int)],
                  plan: String? = nil, subtask: String? = nil, dependsOn: [String]? = nil) -> CollabTask {
            CollabTask(id: id, project: "powdermeet", owner: "alex", ownerName: "Alex", agent: agent, title: title, state: state, branch: nil,
                       files: files.map { CollabFileTouch(path: $0.0, kind: .changed, symbol: $0.1, added: $0.2, removed: $0.3) },
                       updated: now, plan: plan, subtask: subtask, dependsOn: dependsOn)
        }
        return CollabBoard(tasks: [
            task("person-alex", nil, "", .working, [("PowderMeet/Views/MeetView.swift", nil, 6, 2)]),
            task("0A000000-0000-4000-8000-000000000001", "Claude Code", "Faster ETA near arrival", .working,
                 [("PowderMeet/Navigation/ETAEstimator.swift", nil, 7, 1), ("PowderMeet/Navigation/RouteSolver.swift", nil, 3, 1)], plan: "p1", subtask: "eta"),
            task("0B000000-0000-4000-8000-000000000002", "Codex", "Cache lift queue estimates", .working,
                 [("PowderMeet/Services/LiftQueueService.swift", nil, 24, 3), ("PowderMeet/Navigation/RouteSolver.swift", nil, 9, 4)]),
            task("0C000000-0000-4000-8000-000000000003", "Muse Code", "Tidy the meeting point card", .needsYou,
                 [("PowderMeet/Views/MeetView.swift", nil, 12, 8)]),
            task("0D000000-0000-4000-8000-000000000004", "Claude Code", "Countdown banner for friends", .planning,
                 [], plan: "p1", subtask: "banner", dependsOn: ["eta"]),
        ])
    }

    func testCoordination() async throws {
        guard let out = env("TSUKUMO_SNAPSHOT_DIR") else { throw XCTSkip("Set TSUKUMO_SNAPSHOT_DIR to render the site pictures") }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let scene = try await DemoScene.make(in: folder)
        let board = Self.board
        XCTAssertEqual(board.overlaps.count, 2)
        let palette = scene.preferences.palette(.dark)
        let page = VStack(alignment: .leading, spacing: 22) {
            CollabField(board: board, palette: palette, focus: .constant(nil)) { _ in }
            CollabOverlapList(board: board, project: scene.project.id)
        }.padding(.horizontal, 22).padding(.vertical, 20)
            .foregroundStyle(palette.foreground).tint(palette.accent)
        let window = try host(scene.environment(page.frame(maxHeight: .infinity, alignment: .top).background(palette.background)), size: Self.screen)
        try await settle(1.0)
        try write(window, to: out.appendingPathComponent("site-coordination.png"))
        window.contentView = nil
    }

    func testCoordinationFrames() throws {
        guard let out = env("TSUKUMO_SITE_FRAMES") else { throw XCTSkip("Set TSUKUMO_SITE_FRAMES to render the diagram's frames") }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let preferences = DesktopPreferences(defaults: UserDefaults(suiteName: "SiteDemo-" + UUID().uuidString)!)
        let palette = preferences.palette(.dark)
        let board = Self.board
        let width: CGFloat = 1010, fps = 60.0, frames = 480
        // sin(3.2 t) at the loop point: 8 s later its phase is 0.467 rad further on, so start where
        // both sides of the loop sit at the same height near the LED's peak.
        let start = (Double.pi - 25.6.truncatingRemainder(dividingBy: 2 * .pi)) / 2 / 3.2
        defer { CollabField.demoTime = nil }
        for index in 0..<frames {
            CollabField.demoTime = start + Double(index) / fps
            let view = CollabField(board: board, palette: palette, focus: .constant(nil)) { _ in }
                .environment(\.colorScheme, .dark).foregroundStyle(palette.foreground).tint(palette.accent)
                .padding(16).frame(width: width).background(palette.background)
            let renderer = ImageRenderer(content: view); renderer.scale = 1440 / width
            let image = try XCTUnwrap(renderer.cgImage, "frame \(index) didn't render")
            let rep = NSBitmapImageRep(cgImage: image)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent(String(format: "frame-%04d.png", index)))
        }
    }

    // MARK: Rendering

    private func host(_ view: some View, size: CGSize) throws -> NSWindow {
        let window = DemoWindow(contentRect: .init(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark).frame(width: size.width, height: size.height))
        host.frame = .init(origin: .zero, size: size)
        window.contentView = host
        return window
    }
    private func settle(_ seconds: Double) async throws {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)); await Task.yield() }
    }
    /// Draws the window's content at 2x.
    private func write(_ window: NSWindow, to url: URL) throws {
        let host = try XCTUnwrap(window.contentView)
        host.layoutSubtreeIfNeeded()
        let size = host.bounds.size
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }
    /// A click at a point in the window's content (top-left origin).
    private func click(_ window: NSWindow, at point: CGPoint) {
        let location = NSPoint(x: point.x, y: (window.contentView?.bounds.height ?? 0) - point.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { window.sendEvent(event) }
        }
    }
}

/// The sample workspace: one PowderMeet project and five tasks, backed by a real Git repository so the
/// Changes pane reviews a real diff.
@MainActor private struct DemoScene {
    let store: AppStore
    let preferences: DesktopPreferences
    let navigation: DesktopNavigation
    let projects: DesktopProjects
    let coding: CodingWorkspaceStore
    let routines: RoutineStore
    let defaults: UserDefaults
    let project: DesktopProject
    let selected: UUID

    func environment(_ view: some View) -> some View {
        view.environment(store).environment(AppNavigation()).environment(navigation).environment(preferences)
            .environment(MacVoiceInput()).environment(ConnectorStore()).environment(routines)
            .environment(CodingApplicationRegistry(defaults: defaults)).environment(projects).environment(coding)
            .environment(OnboardingFlow(steps: MacOnboardingStep.all, device: defaults, account: { defaults }))
            .font(KemoType.font(.body))
    }

    static func make(in folder: URL) async throws -> DemoScene {
        let defaults = UserDefaults(suiteName: "SiteDemo-" + UUID().uuidString)!
        defaults.set(false, forKey: "desktop.translucentSidebar")
        defaults.set("Tsukumo", forKey: "desktop.lastPage")
        let repo = folder.appendingPathComponent("PowderMeet", isDirectory: true)
        let base = try SampleRepository.create(at: repo)
        let project = DesktopProject(name: "PowderMeet", bookmark: try repo.bookmarkData())
        defaults.set(try JSONEncoder().encode([project]), forKey: "workspace.projects")
        defaults.set(project.id.uuidString, forKey: "workspace.selectedProject")

        let owner = "local-demo"
        let storage = CodingStorage(directory: folder.appendingPathComponent("Coding", isDirectory: true), ownerID: owner)
        try FileManager.default.createDirectory(at: storage.directory, withIntermediateDirectories: true)
        let diffs = try SampleRepository.diffs(in: repo, base: base)
        let now = Date()
        func record(_ title: String, _ provider: CodingProvider, model: String, effort: String?, minutesAgo: Double, status: CodingTaskStatus,
                    events: [CodingEvent]) -> CodingTaskRecord {
            var task = CodingTaskRecord(projectID: project.id, ownerID: owner, title: title, provider: provider, model: model, access: .autoEdit,
                                        projectPath: repo.path, directory: repo.path, isolated: true)
            task.branch = "tsukumo/" + title.lowercased().split(separator: " ").prefix(3).joined(separator: "-")
            task.baseBranch = "main"; task.baseCommit = base; task.effort = effort
            task.status = status; task.events = events; task.logged = 0
            task.updated = now.addingTimeInterval(-minutesAgo * 60); task.created = task.updated.addingTimeInterval(-900)
            return task
        }
        let eta = record("Send smaller ETA updates on the final approach", .claude, model: "opus", effort: "high", minutesAgo: 0, status: .review, events: [
            .init(kind: .user, text: "The ETA we broadcast lags on a friend's final approach. Send smaller changes once they're under two minutes out, and add a test."),
            .init(kind: .command, text: "broadcastDeltaSeconds", status: "completed", tool: "Grep", output: "PowderMeet/Navigation/ETAEstimator.swift:6"),
            .init(kind: .command, text: "PowderMeet/Navigation/ETAEstimator.swift", status: "completed", tool: "Read"),
            .init(kind: .command, text: "PowderMeetTests/ETAEstimatorTests.swift", status: "completed", tool: "Read"),
            .init(kind: .file, text: "PowderMeet/Navigation/ETAEstimator.swift", detail: diffs[0], status: "completed", tool: "Edit"),
            .init(kind: .file, text: "PowderMeetTests/ETAEstimatorTests.swift", detail: diffs[1], status: "completed", tool: "Edit"),
            .init(kind: .plan, text: "Plan", detail: "completed · Find where ETA broadcasts are gated\ncompleted · Use a 5 s threshold inside the last two minutes\ncompleted · Cover it with a unit test"),
            .init(kind: .command, text: "swift test --filter ETAEstimatorTests", detail: "Test Suite 'ETAEstimatorTests' passed.\n\tExecuted 4 tests, with 0 failures (0 unexpected) in 0.031 seconds",
                  status: "completed", exitCode: 0, tool: "Bash", duration: 8.4),
            .init(kind: .assistant, text: "Inside the last two minutes, `shouldBroadcast` now sends ETA changes of **5 s** or more instead of 15 s, so the countdown keeps up on the final pitch. The rate limit between broadcasts is unchanged, and `testFinalApproachSendsSmallerChanges` covers it."),
        ])
        let queue = record("Cache lift queue estimates per resort", .codex, model: "gpt-5.5-codex", effort: "medium", minutesAgo: 2, status: .review, events: [
            .init(kind: .user, text: "Lift queue estimates are fetched on every route solve. Cache them per resort for a minute."),
            .init(kind: .command, text: "rg -n \"queueMinutes\" PowderMeet/Services", status: "inProgress", tool: "commandExecution"),
        ])
        let solver = record("Tidy the meeting point card", .muse, model: "muse-2", effort: nil, minutesAgo: 5, status: .review, events: [
            .init(kind: .user, text: "Tidy the meeting point card: one line for who waits, and the route steps below."),
        ])
        let widget = record("Snow report widget", .claude, model: "sonnet", effort: "medium", minutesAgo: 40, status: .review, events: [
            .init(kind: .user, text: "Add a small widget with today's snow report for the selected resort."),
        ])
        let flaky = record("Fix flaky FriendsMapTests on CI", .codex, model: "gpt-5.5-codex", effort: "high", minutesAgo: 95, status: .done, events: [
            .init(kind: .user, text: "FriendsMapTests fails about one run in ten on CI. Find out why and fix it."),
        ])
        try JSONEncoder().encode(CodingArchive(ownerID: owner, tasks: [eta, queue, solver, widget, flaky])).write(to: storage.url)

        let coding = CodingWorkspaceStore(storage: storage)
        // Loading marks running tasks interrupted, so the live ones are set after it.
        coding.update(queue.id, touch: false) { $0.status = .working }
        coding.update(solver.id, touch: false) { $0.status = .needsInput }
        coding.selected = eta.id
        await coding.refresh(eta.id)
        let store = AppStore(repository: .init(url: folder.appendingPathComponent("state.json")), apiKeys: MemoryAPIKeys())
        let navigation = DesktopNavigation(defaults: defaults)
        navigation.page = "Tsukumo"; navigation.tsukumoSurface = "Project"
        return DemoScene(store: store, preferences: DesktopPreferences(defaults: defaults), navigation: navigation, projects: DesktopProjects(defaults: defaults),
                         coding: coding, routines: RoutineStore(ledger: RoutineLedger(url: folder.appendingPathComponent("routines.json"))),
                         defaults: defaults, project: project, selected: eta.id)
    }
}

/// A small invented Swift project: the ETA estimator before and after the task's change.
private enum SampleRepository {
    static let estimator = """
    import Foundation

    /// Smooths a friend's arrival estimate and decides when a new one is worth sending.
    final class BlendedETAEstimator: ETAEstimator {
        /// Changes smaller than this aren't sent to the other skier.
        var broadcastDeltaSeconds: Double = 15
        /// Never broadcast more often than this.
        var broadcastMinIntervalSeconds: Double = 4

        private(set) var smoothedETASeconds: Double = 0
        private var lastBroadcastETA: Double?
        private var lastBroadcastAt: Date?

        func reset(solverEstimateSeconds: Double) {
            smoothedETASeconds = solverEstimateSeconds
            lastBroadcastETA = nil
            lastBroadcastAt = nil
        }

        func ingest(speed: Double, remainingMeters: Double) {
            guard speed > 0.5 else { return }
            let measured = remainingMeters / speed
            smoothedETASeconds = 0.8 * smoothedETASeconds + 0.2 * measured
        }

        func shouldBroadcast(now: Date) -> Bool {
            let eta = smoothedETASeconds
            if let last = lastBroadcastETA {
                guard abs(eta - last) >= broadcastDeltaSeconds else { return false }
            }
            if let lastAt = lastBroadcastAt {
                let elapsed = now.timeIntervalSince(lastAt)
                guard elapsed >= broadcastMinIntervalSeconds else { return false }
            }
            return true
        }

        func didBroadcast(etaSeconds: Double, now: Date) {
            lastBroadcastETA = etaSeconds
            lastBroadcastAt = now
        }
    }

    """
    static var changedEstimator: String {
        estimator
            .replacingOccurrences(of: "    func shouldBroadcast(now: Date) -> Bool {\n",
                                  with: "    /// On the final approach a friend is watching the countdown,\n    /// so smaller changes are worth sending.\n    private func threshold(forETA eta: Double) -> Double {\n        eta < 120 ? 5 : broadcastDeltaSeconds\n    }\n\n    func shouldBroadcast(now: Date) -> Bool {\n")
            .replacingOccurrences(of: "guard abs(eta - last) >= broadcastDeltaSeconds else { return false }",
                                  with: "guard abs(eta - last) >= threshold(forETA: eta) else { return false }")
    }
    static let tests = """
    import XCTest
    @testable import PowderMeet

    final class ETAEstimatorTests: XCTestCase {
        private let start = Date(timeIntervalSince1970: 0)

        func testFirstEstimateIsAlwaysSent() {
            let estimator = BlendedETAEstimator()
            estimator.reset(solverEstimateSeconds: 600)
            XCTAssertTrue(estimator.shouldBroadcast(now: start))
        }

        func testSmallChangesWaitFarOut() {
            let estimator = BlendedETAEstimator()
            estimator.reset(solverEstimateSeconds: 600)
            estimator.didBroadcast(etaSeconds: 600, now: start)
            estimator.ingest(speed: 6, remainingMeters: 3_500)
            XCTAssertFalse(estimator.shouldBroadcast(now: start + 5))
        }
    }

    """
    static var changedTests: String {
        tests.replacingOccurrences(of: "        XCTAssertFalse(estimator.shouldBroadcast(now: start + 5))\n    }\n",
                                   with: "        XCTAssertFalse(estimator.shouldBroadcast(now: start + 5))\n    }\n\n    func testFinalApproachSendsSmallerChanges() {\n        let estimator = BlendedETAEstimator()\n        estimator.reset(solverEstimateSeconds: 100)\n        estimator.didBroadcast(etaSeconds: 100, now: start)\n        estimator.ingest(speed: 8, remainingMeters: 400)\n        XCTAssertTrue(estimator.shouldBroadcast(now: start + 5))\n    }\n")
    }
    static let paths = ["PowderMeet/Navigation/ETAEstimator.swift", "PowderMeetTests/ETAEstimatorTests.swift"]

    /// Commits the "before" files on main and leaves the task's edits in the working tree; returns the base commit.
    static func create(at repo: URL) throws -> String {
        let files = [paths[0]: estimator, paths[1]: tests,
                     "README.md": "# PowderMeet\n\nWhere should two skiers separated across a mountain meet?\n"]
        for (path, text) in files {
            let url = repo.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try git(["init", "-q", "-b", "main"], at: repo)
        try git(["add", "-A"], at: repo)
        try git(["-c", "user.name=Sample", "-c", "user.email=sample@example.com", "commit", "-q", "-m", "Sample project"], at: repo)
        let base = try git(["rev-parse", "HEAD"], at: repo).trimmingCharacters(in: .whitespacesAndNewlines)
        try changedEstimator.write(to: repo.appendingPathComponent(paths[0]), atomically: true, encoding: .utf8)
        try changedTests.write(to: repo.appendingPathComponent(paths[1]), atomically: true, encoding: .utf8)
        return base
    }
    /// The task's two edits as unified diffs, for the chat's file cards.
    static func diffs(in repo: URL, base: String) throws -> [String] {
        try paths.map { try git(["diff", base, "--", $0], at: repo) }
    }
    @discardableResult static func git(_ arguments: [String], at directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments; process.currentDirectoryURL = directory
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CodingFailure("git \(arguments.joined(separator: " ")) failed") }
        return String(decoding: data, as: UTF8.self)
    }
}

/// A borderless window that can be key, so a synthesized click reaches SwiftUI's buttons.
private final class DemoWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

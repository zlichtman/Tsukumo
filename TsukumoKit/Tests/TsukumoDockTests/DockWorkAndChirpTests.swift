#if os(macOS)
import XCTest
import TsukumoCore
import TsukumoUI
@testable import TsukumoDock

/// Chirps from what's coming up (ported from the chirp tests in macos/Tests/AgentsDockTests.swift) and
/// following a coding bot in the owner's editor (ported from macos/Tests/DockWorkTests.swift).
@MainActor final class DockWorkAndChirpTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func bot(_ name: String, chirps: Bool = true) -> BotSpec {
        var bot = BotSpec(name: name, engine: .codingAgent("claude-code"), look: .kemoSabe)
        bot.permissions.mayChirp = chirps
        return bot
    }

    // MARK: Chirps

    func testChirpsComeFromWhatsComingUpInTheWindow() {
        let homework = bot("Homework")
        let watches = [homework.id: DockChirpWatch(sources: [.reminders], words: ["stats"], leadMinutes: 120)]
        let items = [
            DockUpcomingItem(id: "a", title: "Stats assignment", date: now.addingTimeInterval(2 * 3600), source: .reminders),
            DockUpcomingItem(id: "b", title: "Stats quiz", date: now.addingTimeInterval(3 * 3600), source: .reminders),
            DockUpcomingItem(id: "c", title: "Laundry", date: now.addingTimeInterval(600), source: .reminders),
            DockUpcomingItem(id: "d", title: "Stats lecture", date: now.addingTimeInterval(600), source: .calendar)
        ]
        let chirps = DockChirpRules.upcoming(bots: [homework], watches: watches, items: items, now: now, allowed: [.reminders, .calendar]) { _ in false }
        XCTAssertEqual(chirps.map(\.text), ["Your stats assignment is due in 2 hours."], "Only its source, its words, its window")
    }

    func testChirpsRespectWhatsAllowedPrivacyAndQuietBots() {
        let homework = bot("Homework"), quiet = bot("Quiet", chirps: false)
        let watch = DockChirpWatch(sources: [.calendar])
        let soon = DockUpcomingItem(id: "a", title: "Lecture", date: now.addingTimeInterval(1800), source: .calendar)
        var secret = soon; secret.level = .secret
        XCTAssertTrue(DockChirpRules.upcoming(bots: [homework], watches: [homework.id: watch], items: [soon], now: now, allowed: []) { _ in false }.isEmpty,
                      "Nothing from a source the owner didn't allow")
        XCTAssertTrue(DockChirpRules.upcoming(bots: [homework], watches: [homework.id: watch], items: [secret], now: now, allowed: [.calendar]) { _ in false }.isEmpty,
                      "A Secret item is never read")
        XCTAssertTrue(DockChirpRules.upcoming(bots: [quiet], watches: [quiet.id: watch], items: [soon], now: now, allowed: [.calendar]) { _ in false }.isEmpty,
                      "A bot that may not chirp stays quiet")
        XCTAssertEqual(DockChirpRules.upcoming(bots: [homework], watches: [homework.id: watch], items: [soon], now: now, allowed: [.calendar]) { _ in false }.first?.text,
                       "Lecture starts in 30 minutes.")
    }

    func testEachItemChirpsOnceFromTheFirstBotWatchingIt() {
        let a = bot("A"), b = bot("B")
        let watch = DockChirpWatch(sources: [.calendar])
        let item = DockUpcomingItem(id: "x", title: "Lecture", date: now.addingTimeInterval(1800), source: .calendar)
        let chirps = DockChirpRules.upcoming(bots: [a, b], watches: [a.id: watch, b.id: watch], items: [item, item], now: now, allowed: [.calendar]) { _ in false }
        XCTAssertEqual(chirps.map(\.bot), [a.id])
        let key = DockChirpRules.key(bot: a.id, item: item)
        XCTAssertTrue(DockChirpRules.upcoming(bots: [a], watches: [a.id: watch], items: [item], now: now, allowed: [.calendar]) { $0 == key }.isEmpty)
    }

    func testSpansAndFinishedLinesReadNaturally() {
        XCTAssertEqual(DockChirpRules.span(45 * 60), "45 minutes")
        XCTAssertEqual(DockChirpRules.span(60), "a minute")
        XCTAssertEqual(DockChirpRules.span(2 * 3600), "2 hours")
        XCTAssertEqual(DockChirpRules.span(90 * 60), "1 hour 30 minutes")
        XCTAssertEqual(DockChirpRules.span(119 * 60), "2 hours")
        XCTAssertEqual(DockChirpRules.finished("**Done.** Tests pass.\nMore"), "Done. Tests pass.")
        XCTAssertEqual(DockChirpRules.finished("  "), "Done.")
        XCTAssertTrue(DockChirpRules.matches(["stat"], "Stats 101"))
        XCTAssertFalse(DockChirpRules.matches(["stats"], "Statistics"))
    }

    func testCheckingReadsOnlyWhatsAllowedAndWatched() async throws {
        final class Source: DockUpcomingSource {
            var asked: [Set<DockChirpSource>] = []
            let items: [DockUpcomingItem]
            init(items: [DockUpcomingItem]) { self.items = items }
            func items(from start: Date, to end: Date, sources: Set<DockChirpSource>) async -> [DockUpcomingItem] {
                asked.append(sources)
                return items.filter { sources.contains($0.source) }
            }
        }
        let dock = makeDock()
        dock.now = { self.now }
        let homework = try dock.add(BotSpec(name: "Homework", engine: .codingAgent("claude-code"), look: .kemoSabe)).get()
        dock.store.setChirpWatch(DockChirpWatch(sources: [.calendar, .reminders]), for: homework.id)
        let source = Source(items: [DockUpcomingItem(id: "a", title: "Lecture", date: now.addingTimeInterval(600), source: .calendar),
                                    DockUpcomingItem(id: "b", title: "Essay", date: now.addingTimeInterval(600), source: .reminders)])
        dock.upcoming = source
        dock.allowedSources = { [.reminders] }
        await dock.checkUpcoming()
        XCTAssertEqual(source.asked, [[.reminders]], "Only the allowed, watched sources are read")
        XCTAssertEqual(dock.callout?.text, "Your essay is due in 10 minutes.")
    }

    // MARK: Following in the editor

    private let cursor = EditorTarget(bundleID: "com.todesktop.230313mzl4w4u92", name: "Cursor", path: "/Applications/Cursor.app")
    private let xcode = EditorTarget(bundleID: "com.apple.dt.Xcode", name: "Xcode", path: "/Applications/Xcode.app")

    func testEachEditorOpensTheFolderAndRevealsTheLine() {
        let folder = URL(fileURLWithPath: "/tmp/work"), file = URL(fileURLWithPath: "/tmp/work/ETA.swift")
        XCTAssertEqual(EditorFollow.open(project: folder, in: xcode), ShellCommand(executable: "/usr/bin/xed", arguments: ["/tmp/work"]))
        XCTAssertEqual(EditorFollow.reveal(file, line: 42, in: xcode), ShellCommand(executable: "/usr/bin/xed", arguments: ["--line", "42", "/tmp/work/ETA.swift"]))
        XCTAssertEqual(EditorFollow.reveal(file, line: 42, in: cursor).arguments, ["-r", "-g", "/tmp/work/ETA.swift:42"])
        XCTAssertEqual(EditorFollow.reveal(file, line: 42, in: cursor).executable, "/Applications/Cursor.app/Contents/Resources/app/bin/cursor")
        let zed = EditorTarget(bundleID: "dev.zed.Zed", name: "Zed", path: "/Applications/Zed.app")
        XCTAssertEqual(EditorFollow.reveal(file, line: nil, in: zed), ShellCommand(executable: "/Applications/Zed.app/Contents/MacOS/cli", arguments: ["/tmp/work/ETA.swift"]))
        let other = EditorTarget(bundleID: "com.example.editor", name: "Editor", path: "/Applications/Editor.app")
        XCTAssertEqual(EditorFollow.open(project: folder, in: other).arguments, ["-a", "/Applications/Editor.app", "/tmp/work"])
        XCTAssertEqual(EditorFollow.url("Sources/A.swift", in: "/tmp/work").path, "/tmp/work/Sources/A.swift")
    }

    func testTheChangedLineComesFromTheFileOrTheHunk() {
        let diff = "@@ -10,3 +12,4 @@\n context\n+    let eta = estimate()\n"
        XCTAssertEqual(EditorFollow.line(in: diff, file: nil, contents: "a\nb\n    let eta = estimate()\n"), 3, "Where the added line is now")
        XCTAssertEqual(EditorFollow.line(in: diff, file: nil, contents: "nothing"), 12, "Else the hunk's start")
        XCTAssertNil(EditorFollow.line(in: "no hunk", file: nil, contents: ""))
    }

    func testFollowingIsThrottledAndNeverInterruptsTyping() {
        var throttle = FollowThrottle()
        XCTAssertTrue(throttle.ready(at: now))
        throttle.fired(at: now)
        XCTAssertFalse(throttle.ready(at: now.addingTimeInterval(2)))
        XCTAssertEqual(throttle.wait(at: now.addingTimeInterval(1)), 3, accuracy: 0.001)
        XCTAssertTrue(throttle.ready(at: now.addingTimeInterval(4)))
        XCTAssertTrue(FollowGate.allows(frontmost: cursor.bundleID, editor: cursor.bundleID, own: "host", keyboardIdle: 0))
        XCTAssertTrue(FollowGate.allows(frontmost: "host", editor: cursor.bundleID, own: "host", keyboardIdle: 0))
        XCTAssertFalse(FollowGate.allows(frontmost: "com.apple.mail", editor: cursor.bundleID, own: "host", keyboardIdle: 2), "Typing elsewhere")
        XCTAssertTrue(FollowGate.allows(frontmost: "com.apple.mail", editor: cursor.bundleID, own: "host", keyboardIdle: 9))
    }

    func testTheFollowerOpensOnceAndRevealsAtMostEveryFewSeconds() {
        var clock = now
        var ran: [ShellCommand] = []
        let follower = EditorFollower()
        follower.editor = { self.cursor }
        follower.run = { ran.append($0) }
        follower.now = { clock }
        follower.frontmost = { self.cursor.bundleID }
        let folder = URL(fileURLWithPath: "/tmp/work")
        follower.started(folder: folder); follower.started(folder: folder)
        XCTAssertEqual(ran.count, 1, "The folder opens once")
        follower.request(URL(fileURLWithPath: "/tmp/work/A.swift"), line: 3)
        follower.request(URL(fileURLWithPath: "/tmp/work/B.swift"), line: 7)
        XCTAssertEqual(ran.count, 2, "The second waits for the throttle")
        XCTAssertEqual(follower.lastShown, "A.swift:3")
        clock = clock.addingTimeInterval(5)
        follower.flush()
        XCTAssertEqual(ran.last?.arguments, ["-r", "-g", "/tmp/work/B.swift:7"], "Then the latest")
    }

    func testCuesSayWhatTheWorkIsDoing() {
        var cue = DockWorkCue(status: .running)
        cue.apply(plan: "completed · Read the code\nin_progress · Update ETAEstimator\npending · Run the tests")
        XCTAssertEqual(cue.step, 2); XCTAssertEqual(cue.steps, 3)
        XCTAssertEqual(cue.progress ?? 0, 1.0 / 3, accuracy: 0.001)
        XCTAssertEqual(cue.headline, "2 of 3: Update ETAEstimator")
        cue.file = "Sources/ETAEstimator.swift"; cue.line = 42
        XCTAssertEqual(cue.fileLabel, "ETAEstimator.swift:42")
        cue.tests = .running
        XCTAssertEqual(cue.headline, "Running tests")
        cue.approval = "swift test"
        XCTAssertEqual(cue.headline, "Needs your OK: swift test")
        XCTAssertEqual(DockWorkCue(status: .review).headline, "Ready for review")
        XCTAssertTrue(DockWorkCue.isTest("xcodebuild test -scheme App"))
        XCTAssertFalse(DockWorkCue.isTest("git status"))
        let dock = makeDock()
        dock.cues[BotSpec.kemoSabeID] = cue
        XCTAssertTrue(dock.needsYou(BotSpec.kemoSabeID), "An approval in its work needs the owner")
    }
}
#endif

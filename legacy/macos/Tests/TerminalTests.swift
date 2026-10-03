import AppKit
import Carbon.HIToolbox
import SwiftTerm
import SwiftUI
import XCTest
@testable import KemoSabeMac

/// Tsukumo's terminal: the split layout and its saved form, OSC 7 and 133 parsing, command timing,
/// the shell integration scripts (run in real zsh and bash with an empty home folder), paste
/// protection, the quick terminal's shortcut, profiles, key commands, file paths, find, and output speed.
@MainActor final class TerminalTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("TerminalTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let folder { try? FileManager.default.removeItem(at: folder) } }

    private func pane(_ directory: String = "/tmp") -> TerminalPaneSpec { TerminalPaneSpec(directory: directory) }

    // MARK: Layout

    func testSplittingClosingAndFocusKeepTheTreeAndPanesInStep() {
        var layout = TerminalLayout()
        let a = pane(), b = pane(), c = pane()
        let tab = layout.newTab(a)
        XCTAssertEqual(layout.selected, tab.id)
        XCTAssertTrue(layout.split(.sideBySide, with: b))
        XCTAssertEqual(layout.selectedTab?.focused, b.id, "The new pane takes focus")
        XCTAssertTrue(layout.split(.stacked, with: c))
        XCTAssertEqual(layout.selectedTab?.root.paneIDs, [a.id, b.id, c.id])
        guard case .split(.sideBySide, _, .pane(let left), .split(.stacked, _, .pane(let top), .pane(let bottom))) = layout.selectedTab!.root else { return XCTFail("Unexpected tree") }
        XCTAssertEqual([left, top, bottom], [a.id, b.id, c.id])

        // ⌘⌥ arrows: c is below b, and both are right of a.
        XCTAssertTrue(layout.moveFocus(.up)); XCTAssertEqual(layout.selectedTab?.focused, b.id)
        XCTAssertTrue(layout.moveFocus(.left)); XCTAssertEqual(layout.selectedTab?.focused, a.id)
        XCTAssertFalse(layout.moveFocus(.left), "Nothing further left")
        XCTAssertTrue(layout.moveFocus(.right)); XCTAssertEqual(layout.selectedTab?.focused, b.id, "The nearest pane with the most overlap")

        // Closing b: its sibling c takes the stacked split's place; focus goes to the pane before it.
        XCTAssertEqual(layout.closePane(b.id), [b.id])
        XCTAssertEqual(layout.selectedTab?.root, .split(.sideBySide, ratio: 0.5, first: .pane(a.id), second: .pane(c.id)))
        XCTAssertEqual(layout.selectedTab?.panes.map(\.id), [a.id, c.id])
        XCTAssertEqual(layout.selectedTab?.focused, a.id)
        // The last panes close the tab.
        layout.closePane(a.id)
        XCTAssertEqual(layout.closePane(c.id), [c.id])
        XCTAssertTrue(layout.tabs.isEmpty); XCTAssertNil(layout.selected)
    }

    func testRatiosClampAndEqualize() {
        let a = UUID(), b = UUID(), c = UUID()
        let tree = TerminalSplit.pane(a).splitting(a, axis: .sideBySide, newPane: b).splitting(b, axis: .stacked, newPane: c)
        let resized = tree.settingRatio(0.8, at: []).settingRatio(0.01, at: [1])
        guard case .split(_, let outer, _, .split(_, let inner, _, _)) = resized else { return XCTFail() }
        XCTAssertEqual(outer, 0.8, accuracy: 1e-9)
        XCTAssertEqual(inner, TerminalSplit.minimumRatio, accuracy: 1e-9, "A pane can't be dragged away entirely")
        let frames = resized.frames(in: CGRect(x: 0, y: 0, width: 100, height: 50))
        XCTAssertEqual(frames[a]?.width ?? 0, 80, accuracy: 1e-9)
        XCTAssertEqual(frames[c]?.minY ?? 0, 5, accuracy: 1e-9)
        guard case .split(_, 0.5, _, .split(_, 0.5, _, _)) = resized.equalized else { return XCTFail("Equalize resets every split") }
    }

    func testTabsReorderRenameCycleAndSelectByNumber() {
        var layout = TerminalLayout()
        let one = layout.newTab(pane()), two = layout.newTab(pane()), three = layout.newTab(pane())
        layout.moveTab(from: 2, to: 0)
        XCTAssertEqual(layout.tabs.map(\.id), [three.id, one.id, two.id])
        layout.moveTab(from: 0, to: 3)
        XCTAssertEqual(layout.tabs.map(\.id), [one.id, two.id, three.id])
        layout.rename(two.id, "  server  ")
        XCTAssertEqual(layout.tabs[1].customTitle, "server")
        layout.rename(two.id, " ")
        XCTAssertNil(layout.tabs[1].customTitle, "A blank name goes back to the automatic title")
        layout.selectTab(at: 2); layout.cycleTab(1)
        XCTAssertEqual(layout.selected, one.id, "Cycling wraps around")
        layout.cycleTab(-1)
        XCTAssertEqual(layout.selected, three.id)
        // A new tab opens after the current one.
        layout.selectTab(at: 0)
        let four = layout.newTab(pane(), after: layout.selectedIndex)
        XCTAssertEqual(layout.tabs.map(\.id), [one.id, four.id, two.id, three.id])
        // Closing the selected tab selects the one before it.
        layout.closeTab(four.id)
        XCTAssertEqual(layout.selected, one.id)
    }

    func testLayoutSavesAndRestoresWithoutCommandsOrMissingFolders() throws {
        var layout = TerminalLayout()
        var agent = pane(folder.path); agent.command = "claude"; agent.label = "Claude Code"
        layout.newTab(agent)
        layout.split(.stacked, with: pane("/definitely/not/here"))
        layout.newTab(pane("/tmp"))
        layout.rename(layout.tabs[1].id, "logs")
        layout.updateDirectory(layout.tabs[0].panes[0].id, "/usr")
        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(TerminalLayout.self, from: data)
        XCTAssertEqual(decoded, layout, "The tree, panes, focus, names, and folders round-trip")

        let restored = decoded.forRestore(home: "/Users/me") { $0 != "/definitely/not/here" }
        XCTAssertEqual(restored.tabs.count, 2)
        XCTAssertNil(restored.tabs[0].panes[0].command, "A restored pane starts its shell only; nothing runs again")
        XCTAssertEqual(restored.tabs[0].panes[0].directory, "/usr", "Panes reopen where their shell was")
        XCTAssertEqual(restored.tabs[0].panes[1].directory, "/Users/me", "A folder that's gone falls back to home")
        XCTAssertEqual(restored.tabs[1].customTitle, "logs")
        XCTAssertEqual(restored.selected, layout.selected)

        // A damaged save (a pane list that disagrees with the tree) is repaired, not trusted.
        var broken = layout
        broken.tabs[0].panes.append(pane("/extra"))
        broken.tabs[0].focused = UUID()
        let repaired = broken.forRestore(home: "/Users/me") { _ in true }
        XCTAssertEqual(repaired.tabs[0].panes.count, 2)
        XCTAssertEqual(repaired.tabs[0].focused, repaired.tabs[0].root.paneIDs.first)
    }

    func testTitlesFollowTheCommandThenTheFolder() {
        let home = "/Users/me"
        XCTAssertEqual(TerminalTitle.make(custom: nil, command: nil, programTitle: nil, directory: "/Users/me/code/app/", label: nil, home: home), "app")
        XCTAssertEqual(TerminalTitle.make(custom: nil, command: nil, programTitle: nil, directory: home, label: nil, home: home), "~")
        XCTAssertEqual(TerminalTitle.make(custom: nil, command: "npm run dev", programTitle: nil, directory: home, label: nil, home: home), "npm run dev")
        XCTAssertEqual(TerminalTitle.make(custom: nil, command: "vim notes.md", programTitle: "notes.md (~)", directory: home, label: nil, home: home), "notes.md (~)")
        XCTAssertEqual(TerminalTitle.make(custom: nil, command: nil, programTitle: nil, directory: home, label: "Claude Code", home: home), "Claude Code")
        XCTAssertEqual(TerminalTitle.make(custom: "server", command: "make", programTitle: nil, directory: home, label: nil, home: home), "server")
        XCTAssertEqual(TerminalTitle.make(custom: nil, command: nil, programTitle: nil, directory: "/", label: nil, home: home), "/")
    }

    // MARK: OSC parsing

    func testScannerFindsSequencesAcrossChunksWithEitherTerminator() {
        var scanner = TerminalOSCScanner()
        let stream = "hello\u{1B}]7;file://mac.local/Users/me/My%20Project\u{07}\u{1B}]133;A\u{1B}\\$ \u{1B}]133;B\u{07}ls\r\n\u{1B}]133;C;cmdline_url=ls%20-la\u{07}out\u{1B}]133;D;2\u{07}\u{1B}]2;vim file\u{1B}\\\u{1B}[31mred\u{1B}[0m"
        let bytes = Array(stream.utf8)
        // Fed one byte at a time, so every sequence is split across reads.
        var events: [TerminalShellEvent] = []
        for byte in bytes { events += scanner.scan([byte]) }
        XCTAssertEqual(events, [.directory("/Users/me/My Project"), .promptStart, .inputStart, .commandStart("ls -la"), .commandEnd(2), .title("vim file")])
        // The fast path agrees, and skips chunks without an escape.
        var fast = TerminalOSCScanner()
        XCTAssertEqual(fast.scanFast(Array("plain output\n".utf8)[...]), [])
        XCTAssertEqual(fast.scanFast(bytes[...]), events)
    }

    func testScannerIgnoresUTF8AndDropsRunawaySequences() {
        var scanner = TerminalOSCScanner()
        // "Ý" is C3 9D in UTF-8; 0x9D must not open a sequence.
        XCTAssertEqual(scanner.scan(Array("Ý\u{07}".utf8)), [])
        let runaway = [UInt8]("\u{1B}]2;".utf8) + [UInt8](repeating: 0x41, count: TerminalOSCScanner.maximumPayload + 10) + [0x07]
        XCTAssertEqual(scanner.scan(runaway), [], "An unterminated sequence past 4 KB is dropped")
        XCTAssertEqual(scanner.scan(Array("\u{1B}]133;A\u{07}".utf8)), [.promptStart], "and the scanner recovers")
        XCTAssertEqual(TerminalOSCScanner.parse("133;D"), .commandEnd(nil))
        XCTAssertEqual(TerminalOSCScanner.parse("133;C"), .commandStart(nil))
        XCTAssertEqual(TerminalOSCScanner.parse("133;A;k=s"), .promptStart)
        XCTAssertEqual(TerminalOSCScanner.parse("7;/plain/path"), .directory("/plain/path"))
        XCTAssertNil(TerminalOSCScanner.parse("7;http://example.com/x"))
        XCTAssertNil(TerminalOSCScanner.parse("1337;SetMark"))
    }

    func testTrackerTimesCommandsAndDecidesNotifications() {
        var tracker = TerminalCommandTracker()
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertNil(tracker.apply(.promptStart, now: start))
        XCTAssertTrue(tracker.hasIntegration)
        XCTAssertNil(tracker.apply(.commandStart("  make test "), now: start))
        XCTAssertEqual(tracker.running, "make test")
        let finished = tracker.apply(.commandEnd(1), now: start.addingTimeInterval(12.5))
        XCTAssertEqual(finished, .init(command: "make test", status: 1, duration: 12.5))
        XCTAssertFalse(tracker.isRunning)
        XCTAssertNil(tracker.apply(.commandEnd(0), now: start), "A D without a command (bash's first prompt) is ignored")
        // A prompt without a D still ends a command.
        _ = tracker.apply(.commandStart(nil), now: start)
        XCTAssertEqual(tracker.apply(.promptStart, now: start.addingTimeInterval(3))?.duration, 3)

        XCTAssertTrue(TerminalCommandTracker.shouldNotify(finished!, threshold: 10, appActive: false))
        XCTAssertFalse(TerminalCommandTracker.shouldNotify(finished!, threshold: 10, appActive: true), "Not while you're watching")
        XCTAssertFalse(TerminalCommandTracker.shouldNotify(.init(command: "ls", status: 0, duration: 2), threshold: 10, appActive: false))
    }

    // MARK: Shell integration

    func testLaunchInjectsIntegrationWithoutTouchingDotfiles() {
        let dir = folder.appendingPathComponent("si")
        let zsh = TerminalShellIntegration.launch(shell: "/bin/zsh", enabled: true, folder: dir, inherited: ["ZDOTDIR": "/Users/me/.config/zsh"])
        XCTAssertEqual(zsh.execName, "-zsh", "Still a login shell")
        XCTAssertEqual(zsh.environment["ZDOTDIR"], dir.appendingPathComponent("zsh").path)
        XCTAssertEqual(zsh.environment["TSUKUMO_ZSH_ZDOTDIR"], "/Users/me/.config/zsh", "The person's ZDOTDIR is handed back")
        let bash = TerminalShellIntegration.launch(shell: "/opt/homebrew/bin/bash", enabled: true, folder: dir, inherited: [:])
        XCTAssertEqual(bash.arguments, ["--rcfile", dir.appendingPathComponent("bash/tsukumo.bash").path, "-i"])
        XCTAssertEqual(bash.environment["TSUKUMO_BASH_LOGIN"], "1")
        let fish = TerminalShellIntegration.launch(shell: "/opt/homebrew/bin/fish", enabled: true, folder: dir, inherited: ["XDG_DATA_DIRS": "/a:/b"])
        XCTAssertEqual(fish.environment["XDG_DATA_DIRS"], dir.path + ":/a:/b")
        let other = TerminalShellIntegration.launch(shell: "/bin/tcsh", enabled: true, folder: dir, inherited: [:])
        XCTAssertNil(other.integration); XCTAssertTrue(other.environment.isEmpty)
        let off = TerminalShellIntegration.launch(shell: "/bin/zsh", enabled: false, folder: dir, inherited: [:])
        XCTAssertTrue(off.environment.isEmpty); XCTAssertEqual(off.arguments, [])

        XCTAssertTrue(TerminalShellIntegration.install(in: dir))
        for path in ["zsh/.zshenv", "zsh/tsukumo.zsh", "bash/tsukumo.bash", "fish/vendor_conf.d/tsukumo.fish"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(path).path), path)
        }
    }

    /// Runs a real shell with the integration, in an empty home folder (so the tests never read the
    /// owner's dotfiles), and returns what the scanner reads from its output.
    private func runShell(_ shell: String, input: String, home: URL) throws -> [TerminalShellEvent] {
        let dir = folder.appendingPathComponent("integration")
        XCTAssertTrue(TerminalShellIntegration.install(in: dir))
        let launch = TerminalShellIntegration.launch(shell: shell, enabled: true, folder: dir, inherited: [:])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = (launch.integration == "zsh" ? ["-i"] : launch.arguments)
        var environment = ["HOME": home.path, "PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "HISTFILE": home.appendingPathComponent(".hist").path]
        environment.merge(launch.environment) { _, new in new }
        process.environment = environment
        process.currentDirectoryURL = home
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stdout
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8)); try stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var scanner = TerminalOSCScanner()
        return scanner.scan(Array(data))
    }

    func testZshIntegrationReportsFolderPromptsCommandsAndStatus() throws {
        let home = folder.appendingPathComponent("home zsh")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // The person's own .zshrc still loads (Tsukumo hands back to it).
        try "export TSUKUMO_TEST_RC=loaded\n".write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let events = try runShell("/bin/zsh", input: "cd /usr/bin\nfalse\necho $TSUKUMO_TEST_RC\nexit\n", home: home)
        // The shell reports the real path (/private/var/…), with the percent-encoded space decoded.
        XCTAssertTrue(events.contains { if case .directory(let path) = $0 { return path.hasSuffix("/home zsh") }; return false }, "\(events)")
        XCTAssertTrue(events.contains(.promptStart))
        XCTAssertTrue(events.contains(.commandStart("cd /usr/bin")))
        XCTAssertTrue(events.contains(.directory("/usr/bin")))
        XCTAssertTrue(events.contains(.commandStart("false")))
        XCTAssertTrue(events.contains(.commandEnd(1)), "The exit status is reported")
        XCTAssertTrue(events.contains(.commandStart("echo $TSUKUMO_TEST_RC")))
    }

    func testBashIntegrationLoadsLoginFilesAndReportsFolderAndPrompts() throws {
        let home = folder.appendingPathComponent("homebash")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try "cd /usr\n".write(to: home.appendingPathComponent(".bash_profile"), atomically: true, encoding: .utf8)
        let events = try runShell("/bin/bash", input: "cd /bin\nfalse\nexit\n", home: home)
        XCTAssertTrue(events.contains(.directory("/usr")), "~/.bash_profile ran, as in a login shell: \(events)")
        XCTAssertTrue(events.contains(.directory("/bin")))
        XCTAssertTrue(events.contains(.promptStart))
        XCTAssertTrue(events.contains(.commandEnd(1)))
    }

    // MARK: Paste, keys, shortcut, profiles

    func testPasteProtection() {
        XCTAssertNil(PasteProtection.warning(for: "ls -la"))
        XCTAssertNil(PasteProtection.warning(for: "echo pseudo"), "Only sudo as a word")
        XCTAssertEqual(PasteProtection.warning(for: "make\n"), "This text has a line break. Each line may run as soon as it's pasted.")
        XCTAssertEqual(PasteProtection.warning(for: "a\nb\nc"), "This text has 3 lines. Each line may run as soon as it's pasted.")
        XCTAssertEqual(PasteProtection.warning(for: "cd x && sudo rm -rf build"), "This text uses sudo, which runs a command as an administrator.")
        XCTAssertNotNil(PasteProtection.warning(for: "sudo apt update\r\nsudo apt upgrade")?.contains("sudo"))
    }

    func testHotkeysParseFormatAndRejectBareKeys() {
        XCTAssertEqual(TerminalHotkey("⌥Space"), TerminalHotkey.defaultQuick)
        XCTAssertEqual(TerminalHotkey("option+space"), TerminalHotkey.defaultQuick)
        XCTAssertEqual(TerminalHotkey("Alt + Space"), TerminalHotkey.defaultQuick)
        let backtick = TerminalHotkey("ctrl+`")
        XCTAssertEqual(backtick, TerminalHotkey(keyCode: UInt32(kVK_ANSI_Grave), modifiers: UInt32(controlKey)))
        XCTAssertEqual(backtick?.description, "⌃`")
        XCTAssertEqual(TerminalHotkey("Cmd+Shift+T")?.description, "⇧⌘T")
        XCTAssertEqual(TerminalHotkey("⌃⌥⇧⌘K")?.keyCaps, ["⌃", "⌥", "⇧", "⌘", "K"])
        XCTAssertEqual(TerminalHotkey("F12")?.problem, nil, "Function keys may stand alone")
        XCTAssertNotNil(TerminalHotkey("t")?.problem, "A bare letter would be taken from typing")
        XCTAssertNotNil(TerminalHotkey("shift+t")?.problem)
        XCTAssertNil(TerminalHotkey("hyper+t"))
        XCTAssertNil(TerminalHotkey("cmd+"))
        for text in ["⌥Space", "⌃`", "⇧⌘T", "⌘F5", "⌃⌥↓"] { XCTAssertEqual(TerminalHotkey(text)?.description, text, "\(text) round-trips") }
        XCTAssertEqual(TerminalHotkey(keyCode: UInt16(kVK_Space), flags: [.option]), .defaultQuick)
    }

    func testKeyCommands() {
        let up = String(UnicodeScalar(NSUpArrowFunctionKey)!), left = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        XCTAssertEqual(TerminalKeyAction.action(key: "t", modifiers: .command), .newTab)
        XCTAssertEqual(TerminalKeyAction.action(key: "d", modifiers: [.command, .shift]), .splitDown)
        XCTAssertEqual(TerminalKeyAction.action(key: left, modifiers: [.command, .option, .numericPad, .function]), .focus(.left))
        XCTAssertEqual(TerminalKeyAction.action(key: up, modifiers: [.command, .function]), .previousPrompt)
        XCTAssertEqual(TerminalKeyAction.action(key: "3", modifiers: .command), .selectTab(2))
        XCTAssertEqual(TerminalKeyAction.action(key: "9", modifiers: .command), .selectTab(-1), "⌘9 is the last tab")
        XCTAssertEqual(TerminalKeyAction.action(key: "}", modifiers: [.command, .shift]), .nextTab)
        XCTAssertEqual(TerminalKeyAction.action(key: "a", modifiers: [.command, .shift]), .selectOutput)
        XCTAssertNil(TerminalKeyAction.action(key: "n", modifiers: .command), "⌘N stays New conversation")
        XCTAssertNil(TerminalKeyAction.action(key: "c", modifiers: .command), "Copy is the Edit menu's")
    }

    func testProfilesAreStoredAndTheLastCantBeRemoved() throws {
        let suite = "TerminalTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = TerminalPreferences(defaults: defaults)
        XCTAssertEqual(preferences.profiles.map(\.name), ["Default", "Claude Code", "Codex"])
        XCTAssertEqual(preferences.profile(nil).id, TerminalProfile.defaultID)
        var ssh = preferences.addProfile()
        ssh.name = "Server"; ssh.command = "ssh box"; ssh.environment = TerminalProfile.parseEnvironment("# comment\nFOO=bar baz\n1BAD=x\nEMPTY=\n")
        ssh.colorScheme = "frost"; ssh.cursor = .bar; ssh.folder = .home
        preferences.update(ssh)
        preferences.defaultProfile = ssh.id
        preferences.scrollback = 50
        let reloaded = TerminalPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.profile(ssh.id), ssh)
        XCTAssertEqual(reloaded.profile(ssh.id).environment, ["FOO": "bar baz", "EMPTY": ""])
        XCTAssertEqual(reloaded.defaultProfile, ssh.id)
        XCTAssertEqual(reloaded.scrollback, 100, "Scrollback has a floor")
        XCTAssertEqual(ssh.startFolder(current: "/tmp", home: "/Users/me"), "/Users/me")
        reloaded.remove(ssh.id)
        XCTAssertEqual(reloaded.defaultProfile, reloaded.profiles[0].id, "Removing the default picks another")
        for profile in reloaded.profiles.dropFirst() { reloaded.remove(profile.id) }
        reloaded.remove(reloaded.profiles[0].id)
        XCTAssertEqual(reloaded.profiles.count, 1, "The last profile stays")
        XCTAssertTrue(TerminalOptionKeys.isMeta(rawFlags: 0x20, preferences: reloaded), "Left Option is Meta by default")
        XCTAssertFalse(TerminalOptionKeys.isMeta(rawFlags: 0x40, preferences: reloaded), "Right Option types characters by default")
    }

    func testColorSchemesHaveSixteenColorsAndOwnNames() {
        for scheme in TerminalColorScheme.all {
            XCTAssertEqual(scheme.ansi.count, 16, scheme.name)
            let colors = scheme.resolved(appBackground: .black, appForeground: .white, appAccent: .orange, appIsDark: true)
            XCTAssertEqual(colors.swiftTermANSI.count, 16)
        }
        XCTAssertEqual(Set(TerminalColorScheme.all.map(\.id)).count, TerminalColorScheme.all.count)
        XCTAssertEqual(TerminalColorScheme.named("missing").id, "app")
    }

    // MARK: Paths, find, output

    func testFilePathsUnderThePointer() throws {
        let line = "Sources/App/main.swift:42:7: error: cannot find 'x' in scope"
        XCTAssertEqual(TerminalPathDetector.match(in: line, column: 5), .init(path: "Sources/App/main.swift", line: 42, column: 7))
        XCTAssertNil(TerminalPathDetector.match(in: line, column: 30), "Words without a slash or extension aren't paths")
        XCTAssertEqual(TerminalPathDetector.match(in: "see ~/notes.md.", column: 6)?.path, "~/notes.md")
        XCTAssertEqual(TerminalPathDetector.match(in: "./build.sh", column: 0)?.path, "./build.sh")
        XCTAssertNil(TerminalPathDetector.match(in: "https://example.com/a.b", column: 10), "URLs are SwiftTerm's links")
        let file = folder.appendingPathComponent("a b.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        try "y".write(to: folder.appendingPathComponent("real.swift"), atomically: true, encoding: .utf8)
        XCTAssertEqual(TerminalPathDetector.resolve("real.swift", relativeTo: folder.path)?.lastPathComponent, "real.swift")
        XCTAssertNil(TerminalPathDetector.resolve("missing.swift", relativeTo: folder.path))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("repo/.git/x"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("repo/Sources"), withIntermediateDirectories: true)
        XCTAssertEqual(TerminalFileOpener.projectRoot(for: folder.appendingPathComponent("repo/Sources/x.swift")).lastPathComponent, "repo")
    }

    func testFindMatchesAreColumns() {
        XCTAssertEqual(TerminalFind.matches(of: "err", in: "Error: err ERR", options: SearchOptions()), [0..<3, 7..<10, 11..<14])
        XCTAssertEqual(TerminalFind.matches(of: "err", in: "Error: err ERR", options: SearchOptions(caseSensitive: true)), [7..<10])
        XCTAssertEqual(TerminalFind.matches(of: "e.r", in: "err e.r", options: SearchOptions()), [4..<7], "Literal unless regex is on")
        XCTAssertEqual(TerminalFind.matches(of: "e.r", in: "err e.r", options: SearchOptions(regex: true)), [0..<3, 4..<7])
        XCTAssertEqual(TerminalFind.matches(of: "b", in: "é b", options: SearchOptions()), [2..<3], "Columns count characters, not UTF-16 units")
        XCTAssertEqual(TerminalFind.matches(of: "(", in: "x", options: SearchOptions(regex: true)), [], "A bad pattern finds nothing")
    }

    /// Draws the Terminal surface with two tabs and a split in an offscreen window, and checks that
    /// every pane got a running terminal of its own. Set TSUKUMO_TERMINAL_SNAPSHOT to a folder to
    /// save a picture of it.
    func testSurfaceShowsTabsAndSplitPanes() throws {
        let suite = "TerminalTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = TerminalPreferences.shared
        var profile = preferences.addProfile()
        profile.shell = "/bin/zsh"; profile.environment = ["HOME": folder.path]
        preferences.update(profile)
        let defaultProfile = preferences.defaultProfile
        preferences.defaultProfile = profile.id
        defer { preferences.defaultProfile = defaultProfile; preferences.remove(profile.id) }

        let workspace = TerminalWorkspace(kind: .panel(folder.path), storageKey: nil)
        workspace.openTab()
        workspace.split(.sideBySide)
        workspace.split(.stacked)
        workspace.openTab(directory: "/usr")
        workspace.select(workspace.layout.tabs[0].id)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: TerminalSurfaceView(workspace: workspace).environment(DesktopPreferences(defaults: defaults)))
        window.contentView = host
        let deadline = Date().addingTimeInterval(8)
        let panes = workspace.layout.tabs[0].panes.map(\.id)
        while Date() < deadline && panes.contains(where: { TerminalSessions.shared.state($0)?.tracker.prompts ?? 0 == 0 }) { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        host.layoutSubtreeIfNeeded()
        let views = panes.compactMap { TerminalSessions.shared.existingView($0) }
        XCTAssertEqual(views.count, 3, "Each pane of the shown tab has its own terminal")
        XCTAssertEqual(Set(views.map { ObjectIdentifier($0) }).count, 3)
        XCTAssertTrue(views.allSatisfy { $0.window === window && $0.bounds.width > 100 }, "Every pane is on screen with room")
        XCTAssertNil(TerminalSessions.shared.existingView(workspace.layout.tabs[1].panes[0].id), "A hidden tab starts when it's shown")
        XCTAssertEqual(workspace.title(of: workspace.layout.tabs[0]), TerminalTitle.folderName(folder.path, home: NSHomeDirectory()))
        if let out = ProcessInfo.processInfo.environment["TSUKUMO_TERMINAL_SNAPSHOT"], let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out).appendingPathComponent("terminal-surface.png"))
        }
        TerminalSessions.shared.end(workspace.layout.allPanes.map(\.id))
    }

    func testByteRingKeepsTheTail() {
        var ring = TerminalByteRing(capacity: 8)
        ring.append(Array("abc".utf8))
        XCTAssertEqual(String(decoding: ring.bytes, as: UTF8.self), "abc")
        ring.append(Array("defghij".utf8))
        XCTAssertEqual(String(decoding: ring.bytes, as: UTF8.self), "cdefghij")
        ring.append(Array("0123456789".utf8))
        XCTAssertEqual(String(decoding: ring.bytes, as: UTF8.self), "23456789")
    }

    /// Measures how fast output reaches the screen model: `yes | head -n 200000` and `cat` of a large
    /// file through a real pty, and the same volume fed straight in. Prints the numbers.
    func testOutputThroughput() throws {
        let preferences = TerminalPreferences.shared
        preferences.scrollback = 10_000
        // zsh with the integration and an empty home folder, so the owner's dotfiles and history are never used.
        var profile = preferences.addProfile()
        profile.shell = "/bin/zsh"; profile.environment = ["HOME": folder.path]
        preferences.update(profile)
        defer { preferences.remove(profile.id) }
        func measure(_ label: String, command: String) throws -> Double {
            let workspace = TerminalWorkspace(kind: .panel(folder.path), storageKey: nil)
            var spec = TerminalPaneSpec(directory: folder.path)
            spec.profileID = profile.id
            let view = TerminalSessions.shared.view(for: spec, owner: workspace)
            defer { TerminalSessions.shared.end([spec.id]) }
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            view.frame = window.contentView!.bounds; window.contentView!.addSubview(view)
            // Wait for the shell's first output, then time the command.
            let ready = Date().addingTimeInterval(10)
            while TerminalSessions.shared.state(spec.id)?.tracker.prompts ?? 0 == 0 && Date() < ready { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            // The echoed command line shows $((6*7)); only the output has 42.
            let marker = "TSUKUMO_DONE_42"
            let start = Date()
            view.send(txt: "\(command); echo TSUKUMO_DONE_$((6*7))\r")
            let deadline = Date().addingTimeInterval(60)
            while !view.recentText.contains(marker + "\r\n") && !view.recentText.contains(marker + "\n") && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            let elapsed = Date().timeIntervalSince(start)
            print("Terminal throughput — \(label): \(String(format: "%.2f", elapsed)) s (GPU \(view.isUsingMetalRenderer ? "on" : "off"))")
            XCTAssertLessThan(elapsed, 60, label)
            return elapsed
        }
        let big = folder.appendingPathComponent("big.txt")
        let line = String(repeating: "The quick brown fox jumps over the lazy dog 0123456789 ", count: 2) + "\n"
        try String(repeating: line, count: 100_000).write(to: big, atomically: true, encoding: .utf8)
        let gpu = preferences.gpuRendering
        defer { preferences.gpuRendering = gpu }
        for metal in [true, false] {
            preferences.gpuRendering = metal
            _ = try measure("yes | head -n 200000", command: "yes | head -n 200000")
            _ = try measure("cat 11 MB (100k lines)", command: "cat '\(big.path)'")
        }

        // The parser alone, without the pty: 200,000 short lines and 50,000 colored ones.
        let view = TsukumoTerminalView(frame: .init(x: 0, y: 0, width: 900, height: 600), font: nil, options: TerminalOptions(scrollback: 10_000))
        let plain = Array(String(repeating: "y\n", count: 200_000).utf8)
        var start = Date()
        stride(from: 0, to: plain.count, by: 131_072).forEach { view.dataReceived(slice: plain[$0..<min(plain.count, $0 + 131_072)]) }
        print("Terminal throughput — feed 200k lines: \(String(format: "%.3f", Date().timeIntervalSince(start))) s")
        let colored = Array(String(repeating: "\u{1B}[32mok\u{1B}[0m \u{1B}[1;34mfile.swift\u{1B}[0m:12 message\n", count: 50_000).utf8)
        start = Date()
        stride(from: 0, to: colored.count, by: 131_072).forEach { view.dataReceived(slice: colored[$0..<min(colored.count, $0 + 131_072)]) }
        print("Terminal throughput — feed 50k colored lines (\(colored.count / 1024) KB): \(String(format: "%.3f", Date().timeIntervalSince(start))) s")
        // SwiftTerm's own parser on the same input, to show what Tsukumo's scanner and tail add.
        let bare = TsukumoTerminalView(frame: .init(x: 0, y: 0, width: 900, height: 600), font: nil, options: TerminalOptions(scrollback: 10_000))
        start = Date()
        stride(from: 0, to: plain.count, by: 131_072).forEach { bare.feed(byteArray: plain[$0..<min(plain.count, $0 + 131_072)]) }
        print("Terminal throughput — SwiftTerm alone, 200k lines: \(String(format: "%.3f", Date().timeIntervalSince(start))) s")
        let file = Array(try Data(contentsOf: big))
        var scanner = TerminalOSCScanner(), ring = TerminalByteRing(capacity: 65_536)
        start = Date()
        stride(from: 0, to: file.count, by: 131_072).forEach { _ = scanner.scanFast(file[$0..<min(file.count, $0 + 131_072)]); ring.append(file[$0..<min(file.count, $0 + 131_072)]) }
        print("Terminal throughput — Tsukumo's scanner and tail over 11 MB: \(String(format: "%.3f", Date().timeIntervalSince(start))) s")
    }
}

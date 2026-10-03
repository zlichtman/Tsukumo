import AppKit
import Carbon.HIToolbox
import Observation
import SwiftTerm
import UserNotifications

// Terminal profiles (what a new terminal runs and how it looks), the terminal's own settings, its
// color schemes, and paste protection. Set in Settings → Terminal.

// MARK: Profiles

enum TerminalCursorShape: String, Codable, CaseIterable {
    case block = "Block", bar = "Bar", underline = "Underline"
    func style(blinking: Bool) -> CursorStyle {
        switch self {
        case .block: blinking ? .blinkBlock : .steadyBlock
        case .bar: blinking ? .blinkBar : .steadyBar
        case .underline: blinking ? .blinkUnderline : .steadyUnderline
        }
    }
}

/// A named way to open a terminal: its shell, folder, environment, command, font, colors, and cursor.
/// A profile with a command types it at the first prompt (`claude`, `codex`, `ssh host`), so the
/// shell is still there when the command ends.
struct TerminalProfile: Codable, Equatable, Identifiable {
    enum Folder: String, Codable, CaseIterable {
        /// The focused terminal's folder (or the project's), as Ghostty and iTerm do by default.
        case inherit = "Same as current"
        case home = "Home folder"
        case custom = "Custom"
    }
    var id = UUID()
    var name: String
    /// A shell to run instead of your login shell (`/opt/homebrew/bin/fish`); empty means your login shell.
    var shell = ""
    var folder = Folder.inherit
    var customFolder = ""
    /// Typed at the first prompt; empty runs nothing.
    var command = ""
    /// `NAME=value` lines added to the shell's environment.
    var environment: [String: String] = [:]
    /// Empty means the code font from Appearance.
    var fontFamily = ""
    /// Zero means the code font size from Appearance.
    var fontSize: Double = 0
    var colorScheme = TerminalColorScheme.followApp.id
    var cursor = TerminalCursorShape.block
    var cursorBlinks = true

    static let defaultID = UUID(uuidString: "5E3A0C1E-7C38-4D5B-9A64-000000000001")!
    static let standard = TerminalProfile(id: defaultID, name: "Default")
    /// Profiles offered the first time: the default, and the two agents most people use.
    static let starters: [TerminalProfile] = [
        standard,
        TerminalProfile(id: UUID(uuidString: "5E3A0C1E-7C38-4D5B-9A64-000000000002")!, name: "Claude Code", command: "claude"),
        TerminalProfile(id: UUID(uuidString: "5E3A0C1E-7C38-4D5B-9A64-000000000003")!, name: "Codex", command: "codex")
    ]

    /// The folder a new terminal with this profile starts in.
    func startFolder(current: String?, home: String) -> String {
        switch folder {
        case .inherit: current ?? home
        case .home: home
        case .custom: customFolder.isEmpty ? (current ?? home) : (customFolder as NSString).expandingTildeInPath
        }
    }
    /// Parses `NAME=value` lines; blank lines and `#` comments are skipped, and names must be valid.
    static func parseEnvironment(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { continue }
            let name = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            guard let first = name.first, first == "_" || first.isLetter, name.allSatisfy({ $0 == "_" || $0.isLetter || $0.isNumber }), name.allSatisfy(\.isASCII) else { continue }
            result[name] = String(trimmed[trimmed.index(after: equals)...])
        }
        return result
    }
    static func formatEnvironment(_ environment: [String: String]) -> String {
        environment.keys.sorted().map { "\($0)=\(environment[$0] ?? "")" }.joined(separator: "\n")
    }
}

enum TerminalBellStyle: String, Codable, CaseIterable {
    case off = "Off", visual = "Visual", sound = "Sound"
}

/// The terminal's settings, saved in the app's defaults (a throwaway suite in tests).
@MainActor @Observable final class TerminalPreferences {
    static let shared = TerminalPreferences(defaults: KemoSabeMacApp.isTestHost ? UserDefaults(suiteName: "com.zlichtman.kemosabe.mac.tests.terminal") ?? .standard : .standard)

    @ObservationIgnored private let defaults: UserDefaults
    var profiles: [TerminalProfile] { didSet { save(profiles, "terminal.profiles") } }
    var defaultProfile: UUID { didSet { defaults.set(defaultProfile.uuidString, forKey: "terminal.defaultProfile") } }
    /// Lines kept above the screen.
    var scrollback: Int { didSet { defaults.set(scrollback, forKey: "terminal.scrollback") } }
    var copyOnSelect: Bool { didSet { defaults.set(copyOnSelect, forKey: "terminal.copyOnSelect") } }
    var leftOptionIsMeta: Bool { didSet { defaults.set(leftOptionIsMeta, forKey: "terminal.leftOptionMeta") } }
    var rightOptionIsMeta: Bool { didSet { defaults.set(rightOptionIsMeta, forKey: "terminal.rightOptionMeta") } }
    var bell: TerminalBellStyle { didSet { defaults.set(bell.rawValue, forKey: "terminal.bell") } }
    var bounceDockOnBell: Bool { didSet { defaults.set(bounceDockOnBell, forKey: "terminal.bellBounce") } }
    var secureKeyboardEntry: Bool { didSet { defaults.set(secureKeyboardEntry, forKey: "terminal.secureInput"); SecureKeyboardEntry.update() } }
    var pasteProtection: Bool { didSet { defaults.set(pasteProtection, forKey: "terminal.pasteProtection") } }
    var shellIntegration: Bool { didSet { defaults.set(shellIntegration, forKey: "terminal.shellIntegration") } }
    var notifyLongCommands: Bool { didSet { defaults.set(notifyLongCommands, forKey: "terminal.notifyLong") } }
    var longCommandSeconds: Double { didSet { defaults.set(longCommandSeconds, forKey: "terminal.notifySeconds") } }
    /// 1 is opaque. Below 1 the terminal's background lets what's behind show through.
    var opacity: Double { didSet { defaults.set(opacity, forKey: "terminal.opacity") } }
    var blur: Bool { didSet { defaults.set(blur, forKey: "terminal.blur") } }
    var quickTerminal: Bool { didSet { defaults.set(quickTerminal, forKey: "terminal.quick") } }
    var quickHotkey: String { didSet { defaults.set(quickHotkey, forKey: "terminal.quickHotkey") } }
    /// The share of the screen's height the quick terminal takes.
    var quickHeight: Double { didSet { defaults.set(quickHeight, forKey: "terminal.quickHeight") } }
    var quickHidesOnFocusLoss: Bool { didSet { defaults.set(quickHidesOnFocusLoss, forKey: "terminal.quickAutoHide") } }
    /// Draw with Metal (the GPU) instead of Core Graphics.
    var gpuRendering: Bool { didSet { defaults.set(gpuRendering, forKey: "terminal.gpu") } }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let saved = (defaults.data(forKey: "terminal.profiles")).flatMap { try? JSONDecoder().decode([TerminalProfile].self, from: $0) } ?? []
        profiles = saved.isEmpty ? TerminalProfile.starters : saved
        defaultProfile = defaults.string(forKey: "terminal.defaultProfile").flatMap(UUID.init(uuidString:)) ?? TerminalProfile.defaultID
        scrollback = min(1_000_000, max(100, defaults.object(forKey: "terminal.scrollback") as? Int ?? 10_000))
        copyOnSelect = defaults.bool(forKey: "terminal.copyOnSelect")
        leftOptionIsMeta = defaults.object(forKey: "terminal.leftOptionMeta") as? Bool ?? true
        rightOptionIsMeta = defaults.object(forKey: "terminal.rightOptionMeta") as? Bool ?? false
        bell = TerminalBellStyle(rawValue: defaults.string(forKey: "terminal.bell") ?? "") ?? .visual
        bounceDockOnBell = defaults.object(forKey: "terminal.bellBounce") as? Bool ?? true
        secureKeyboardEntry = defaults.bool(forKey: "terminal.secureInput")
        pasteProtection = defaults.object(forKey: "terminal.pasteProtection") as? Bool ?? true
        shellIntegration = defaults.object(forKey: "terminal.shellIntegration") as? Bool ?? true
        notifyLongCommands = defaults.object(forKey: "terminal.notifyLong") as? Bool ?? true
        longCommandSeconds = max(1, defaults.object(forKey: "terminal.notifySeconds") as? Double ?? 10)
        opacity = min(1, max(0.3, defaults.object(forKey: "terminal.opacity") as? Double ?? 1))
        blur = defaults.object(forKey: "terminal.blur") as? Bool ?? true
        quickTerminal = defaults.object(forKey: "terminal.quick") as? Bool ?? true
        quickHotkey = defaults.string(forKey: "terminal.quickHotkey") ?? TerminalHotkey.defaultQuick.description
        quickHeight = min(0.9, max(0.2, defaults.object(forKey: "terminal.quickHeight") as? Double ?? 0.4))
        quickHidesOnFocusLoss = defaults.object(forKey: "terminal.quickAutoHide") as? Bool ?? true
        gpuRendering = defaults.object(forKey: "terminal.gpu") as? Bool ?? false
        if !profiles.contains(where: { $0.id == defaultProfile }) { defaultProfile = profiles[0].id }
    }
    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
    func profile(_ id: UUID?) -> TerminalProfile {
        profiles.first { $0.id == id } ?? profiles.first { $0.id == defaultProfile } ?? profiles.first ?? .standard
    }
    @discardableResult func addProfile(copying source: TerminalProfile? = nil) -> TerminalProfile {
        var profile = source ?? TerminalProfile(name: "New profile")
        profile.id = UUID()
        if source != nil { profile.name += " copy" }
        profiles.append(profile)
        return profile
    }
    func update(_ profile: TerminalProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
    }
    /// The last profile can't be removed; removing the default makes the first one the default.
    func remove(_ id: UUID) {
        guard profiles.count > 1 else { return }
        profiles.removeAll { $0.id == id }
        if defaultProfile == id { defaultProfile = profiles[0].id }
    }
}

// MARK: Colors

/// A terminal color scheme: background, text, cursor, selection, and the 16 ANSI colors, as hex.
/// "Follow app theme" takes its background, text, and cursor from the app's palette.
struct TerminalColorScheme: Identifiable, Equatable {
    let id: String
    let name: String
    /// Where the colors come from, for schemes based on a published palette.
    var credit = ""
    let dark: Bool
    let background: String
    let foreground: String
    let cursor: String
    let ansi: [String]

    static let classicDarkANSI = ["000000", "CD3131", "0DBC79", "E5E510", "2472C8", "BC3FBC", "11A8CD", "E5E5E5", "666666", "F14C4C", "23D18B", "F5F543", "3B8EEA", "D670D6", "29B8DB", "FFFFFF"]
    static let classicLightANSI = ["000000", "CD3131", "00BC00", "949800", "0451A5", "BC05BC", "0598BC", "555555", "666666", "CD3131", "14CE14", "B5BA00", "0451A5", "BC05BC", "0598BC", "A5A5A5"]
    static let solarizedANSI = ["073642", "DC322F", "859900", "B58900", "268BD2", "D33682", "2AA198", "EEE8D5", "002B36", "CB4B16", "586E75", "657B83", "839496", "6C71C4", "93A1A1", "FDF6E3"]

    static let followApp = TerminalColorScheme(id: "app", name: "Follow app theme", dark: true, background: "", foreground: "", cursor: "", ansi: classicDarkANSI)
    /// Stock names are Tsukumo's own; the credit names the palette a scheme is based on.
    static let all: [TerminalColorScheme] = [
        followApp,
        .init(id: "classic-dark", name: "Classic Dark", dark: true, background: "1E1E1E", foreground: "CCCCCC", cursor: "FFFFFF", ansi: classicDarkANSI),
        .init(id: "classic-light", name: "Classic Light", dark: false, background: "FFFFFF", foreground: "1E1E1E", cursor: "000000", ansi: classicLightANSI),
        .init(id: "tide-dark", name: "Tide Dark", credit: "Solarized, by Ethan Schoonover", dark: true, background: "002B36", foreground: "839496", cursor: "93A1A1", ansi: solarizedANSI),
        .init(id: "tide-light", name: "Tide Light", credit: "Solarized, by Ethan Schoonover", dark: false, background: "FDF6E3", foreground: "657B83", cursor: "586E75", ansi: solarizedANSI),
        .init(id: "ember", name: "Ember", credit: "gruvbox, by Pavel Pertsev", dark: true, background: "282828", foreground: "EBDBB2", cursor: "EBDBB2",
              ansi: ["282828", "CC241D", "98971A", "D79921", "458588", "B16286", "689D6A", "A89984", "928374", "FB4934", "B8BB26", "FABD2F", "83A598", "D3869B", "8EC07C", "EBDBB2"]),
        .init(id: "frost", name: "Frost", credit: "Nord, by Arctic Ice Studio", dark: true, background: "2E3440", foreground: "D8DEE9", cursor: "D8DEE9",
              ansi: ["3B4252", "BF616A", "A3BE8C", "EBCB8B", "81A1C1", "B48EAD", "88C0D0", "E5E9F0", "4C566A", "BF616A", "A3BE8C", "EBCB8B", "81A1C1", "B48EAD", "8FBCBB", "ECEFF4"]),
        .init(id: "nightshade", name: "Nightshade", credit: "Dracula, by Zeno Rocha", dark: true, background: "282A36", foreground: "F8F8F2", cursor: "F8F8F2",
              ansi: ["21222C", "FF5555", "50FA7B", "F1FA8C", "BD93F9", "FF79C6", "8BE9FD", "F8F8F2", "6272A4", "FF6E6E", "69FF94", "FFFFA5", "D6ACFF", "FF92DF", "A4FFFF", "FFFFFF"]),
        .init(id: "night-city", name: "Night City", credit: "Tokyo Night, by enkia", dark: true, background: "1A1B26", foreground: "C0CAF5", cursor: "C0CAF5",
              ansi: ["15161E", "F7768E", "9ECE6A", "E0AF68", "7AA2F7", "BB9AF7", "7DCFFF", "A9B1D6", "414868", "F7768E", "9ECE6A", "E0AF68", "7AA2F7", "BB9AF7", "7DCFFF", "C0CAF5"]),
        .init(id: "cocoa", name: "Cocoa", credit: "Catppuccin Mocha", dark: true, background: "1E1E2E", foreground: "CDD6F4", cursor: "F5E0DC",
              ansi: ["45475A", "F38BA8", "A6E3A1", "F9E2AF", "89B4FA", "F5C2E7", "94E2D5", "BAC2DE", "585B70", "F38BA8", "A6E3A1", "F9E2AF", "89B4FA", "F5C2E7", "94E2D5", "A6ADC8"])
    ]
    static func named(_ id: String) -> TerminalColorScheme { all.first { $0.id == id } ?? followApp }

    /// The colors a view uses: this scheme's, or for "Follow app theme" the app palette's with ANSI
    /// colors that suit a dark or light background.
    func resolved(appBackground: NSColor, appForeground: NSColor, appAccent: NSColor, appIsDark: Bool) -> TerminalColors {
        if id == Self.followApp.id {
            return TerminalColors(background: appBackground, foreground: appForeground, cursor: appAccent, ansi: (appIsDark ? Self.classicDarkANSI : Self.classicLightANSI).map(Self.color))
        }
        return TerminalColors(background: Self.color(background), foreground: Self.color(foreground), cursor: Self.color(cursor), ansi: ansi.map(Self.color))
    }
    static func color(_ hex: String) -> NSColor {
        let value = UInt32(hex, radix: 16) ?? 0
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

/// The colors a terminal view draws with.
struct TerminalColors: Equatable {
    var background: NSColor
    var foreground: NSColor
    var cursor: NSColor
    var ansi: [NSColor]
    /// The ANSI colors in SwiftTerm's form (16-bit channels).
    var swiftTermANSI: [SwiftTerm.Color] {
        ansi.map { color in
            let c = color.usingColorSpace(.sRGB) ?? color
            return SwiftTerm.Color(red: UInt16(c.redComponent * 65535), green: UInt16(c.greenComponent * 65535), blue: UInt16(c.blueComponent * 65535))
        }
    }
}

// MARK: Paste protection

/// Decides whether a paste needs confirming: text with a line break runs as soon as it's pasted
/// (unless the program asked for bracketed paste), and `sudo` asks for your password.
enum PasteProtection {
    static func warning(for text: String) -> String? {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" })
        let hasBreak = lines.count > 1
        let sudo = text.range(of: #"(^|[\s;&|(`])sudo(\s|$)"#, options: .regularExpression) != nil
        switch (hasBreak, sudo) {
        case (true, true): return "This text has \(lineCount(lines)) and uses sudo. Each line may run as soon as it's pasted."
        case (true, false): return "This text has \(lineCount(lines)). Each line may run as soon as it's pasted."
        case (false, true): return "This text uses sudo, which runs a command as an administrator."
        default: return nil
        }
    }
    private static func lineCount(_ lines: [Substring]) -> String {
        // A trailing line break doesn't add a line of its own, but it does run the command.
        let count = lines.last?.isEmpty == true ? lines.count - 1 : lines.count
        return count == 1 ? "a line break" : "\(count) lines"
    }
}

// MARK: Secure keyboard entry and notifications

/// Secure keyboard entry keeps other apps from reading keystrokes while Tsukumo is in front, as in
/// Terminal and iTerm. It's turned on while Tsukumo is active and the setting is on.
@MainActor enum SecureKeyboardEntry {
    private static var enabled = false
    private static var observers: [NSObjectProtocol] = []
    static func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in Task { @MainActor in update() } },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in Task { @MainActor in update() } }
        ]
        update()
    }
    static func update() {
        let want = TerminalPreferences.shared.secureKeyboardEntry && NSApp?.isActive == true && !KemoSabeMacApp.isTestHost
        guard want != enabled else { return }
        enabled = want
        if want { EnableSecureEventInput() } else { DisableSecureEventInput() }
    }
    static var isOn: Bool { enabled }
}

enum TerminalNotifications {
    /// Tells the person a long command finished while Tsukumo was in the background.
    @MainActor static func commandFinished(_ finished: TerminalCommandTracker.Finished, folder: String?) {
        let center = UNUserNotificationCenter.current()
        Task {
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            } else if settings.authorizationStatus != .authorized && settings.authorizationStatus != .provisional { return }
            let content = UNMutableNotificationContent()
            let ok = finished.status.map { $0 == 0 } ?? true
            content.title = ok ? "Command finished" : "Command failed"
            let command = finished.command.map { String($0.prefix(80)) } ?? "A command"
            let seconds = Int(finished.duration.rounded())
            let time = seconds >= 60 ? "\(seconds / 60) min \(seconds % 60) s" : "\(seconds) s"
            content.body = command + " · " + time + (finished.status.map { $0 == 0 ? "" : " · exit \($0)" } ?? "")
            if let folder { content.subtitle = TerminalTitle.folderName(folder, home: NSHomeDirectory()) }
            try? await center.add(UNNotificationRequest(identifier: "terminal-" + UUID().uuidString, content: content, trigger: nil))
        }
    }
}

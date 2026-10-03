import Foundation

// The pure parts of a coding task's panes (Terminal, Changes, Browser, Device), kept apart from
// the views so they can be tested without a window, a web view, or a simulator.

// MARK: Pane layout

/// The panes beside a task, as in Claude's and Codex's task toolbar: one side pane at a time on
/// the right (Changes, Browser, or Device), and the terminal as a bottom panel (⌘J).
enum CodingPane: String, CaseIterable, Identifiable {
    case changes, browser, device
    var id: String { rawValue }
    var title: String { switch self { case .changes: "Changes"; case .browser: "Browser"; case .device: "Device" } }
    var symbol: String { switch self { case .changes: "plus.forwardslash.minus"; case .browser: "globe"; case .device: "iphone" } }
}
struct CodingPaneState: Equatable {
    /// The open side pane; nil when the conversation has the whole width.
    var side: CodingPane? = .changes
    var terminal = false
    /// Opening a side pane replaces the one that was open; its own button closes it.
    mutating func toggle(_ pane: CodingPane) { side = side == pane ? nil : pane }
    mutating func toggleTerminal() { terminal.toggle() }
    func isOpen(_ pane: CodingPane) -> Bool { side == pane }
}

// MARK: Diff

struct CodingDiffLine: Equatable, Hashable {
    enum Kind: Equatable, Hashable { case context, added, removed, note }
    var kind: Kind
    var text: String
    /// Line numbers in the base (old) and the task's version (new); nil where the line doesn't exist.
    var old: Int?
    var new: Int?
}
/// One row of a side-by-side view: a removed line beside the line that replaced it.
struct CodingDiffRow: Equatable {
    var left: CodingDiffLine?
    var right: CodingDiffLine?
}
struct CodingDiffHunk: Equatable, Identifiable {
    var id: Int
    var header: String
    var oldStart = 0
    var newStart = 0
    var lines: [CodingDiffLine] = []
    /// Removed and added runs are paired line by line; context sits on both sides.
    var rows: [CodingDiffRow] {
        var rows: [CodingDiffRow] = [], removed: [CodingDiffLine] = [], added: [CodingDiffLine] = []
        func flush() {
            for index in 0..<max(removed.count, added.count) {
                rows.append(.init(left: index < removed.count ? removed[index] : nil, right: index < added.count ? added[index] : nil))
            }
            removed = []; added = []
        }
        for line in lines {
            switch line.kind {
            case .removed: if !added.isEmpty { flush() }; removed.append(line)
            case .added: added.append(line)
            case .context: flush(); rows.append(.init(left: line, right: line))
            case .note: flush(); rows.append(.init(left: line, right: nil))
            }
        }
        flush()
        return rows
    }
}
struct CodingDiffFile: Equatable, Identifiable {
    enum Change: String, Equatable { case added, deleted, modified, renamed }
    var path: String
    /// The path in the base, when the file was renamed or copied.
    var oldPath: String?
    var change: Change = .modified
    var binary = false
    var hunks: [CodingDiffHunk] = []
    var id: String { path }
    var additions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .added }.count } }
    var deletions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .removed }.count } }
}
/// Reads `git diff` output (including `--binary --full-index`, as a review produces) into files
/// and hunks. New files, untracked ones included (a review's snapshot tree holds them), show as
/// added; binary patches are recognised and their encoded data skipped.
enum CodingDiff {
    static func parse(_ text: String) -> [CodingDiffFile] {
        var files: [CodingDiffFile] = []
        var file: CodingDiffFile?, hunk: CodingDiffHunk?
        var old = 0, new = 0, binaryData = false
        func finishHunk() { if let done = hunk { file?.hunks.append(done) }; hunk = nil }
        func startHunk(_ line: String) {
            finishHunk()
            let numbers = hunkStarts(line)
            old = numbers.old; new = numbers.new
            hunk = CodingDiffHunk(id: file?.hunks.count ?? 0, header: line, oldStart: numbers.old, newStart: numbers.new)
        }
        func finishFile() {
            finishHunk()
            if var done = file {
                if done.oldPath == done.path { done.oldPath = nil }
                files.append(done)
            }
            file = nil; binaryData = false
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)
            if line.hasSuffix("\r") { line.removeLast() }
            if line.hasPrefix("diff --git ") {
                finishFile()
                let (a, b) = headerPaths(String(line.dropFirst("diff --git ".count)))
                file = CodingDiffFile(path: b ?? a ?? "", oldPath: a)
                continue
            }
            guard file != nil, !binaryData else { continue }
            if hunk != nil {
                guard let first = line.first else { continue }
                switch first {
                case "+": hunk?.lines.append(.init(kind: .added, text: String(line.dropFirst()), old: nil, new: new)); new += 1
                case "-": hunk?.lines.append(.init(kind: .removed, text: String(line.dropFirst()), old: old, new: nil)); old += 1
                case " ": hunk?.lines.append(.init(kind: .context, text: String(line.dropFirst()), old: old, new: new)); old += 1; new += 1
                case "\\": hunk?.lines.append(.init(kind: .note, text: String(line.dropFirst(2)), old: nil, new: nil))
                case "@": if line.hasPrefix("@@") { startHunk(line) }
                default: break
                }
                continue
            }
            if line.hasPrefix("@@") { startHunk(line); continue }
            // The extended header, before the first hunk.
            if line.hasPrefix("new file mode") { file?.change = .added }
            else if line.hasPrefix("deleted file mode") { file?.change = .deleted }
            else if line.hasPrefix("rename from ") || line.hasPrefix("copy from ") {
                file?.oldPath = unquote(String(line.drop { $0 != " " }.dropFirst().drop { $0 != " " }.dropFirst())); file?.change = .renamed
            } else if line.hasPrefix("rename to ") || line.hasPrefix("copy to ") {
                file?.path = unquote(String(line.drop { $0 != " " }.dropFirst().drop { $0 != " " }.dropFirst())); file?.change = .renamed
            } else if line.hasPrefix("--- ") {
                if let path = stripPrefix(unquote(String(line.dropFirst(4))), "a/") { file?.oldPath = path }
            } else if line.hasPrefix("+++ ") {
                if let path = stripPrefix(unquote(String(line.dropFirst(4))), "b/") { file?.path = path }
                else if let oldPath = file?.oldPath { file?.path = oldPath }
            } else if line.hasPrefix("Binary files ") { file?.binary = true }
            else if line == "GIT binary patch" { file?.binary = true; binaryData = true }
        }
        finishFile()
        return files
    }
    /// `@@ -12,7 +12,9 @@ context` → (12, 12).
    static func hunkStarts(_ line: String) -> (old: Int, new: Int) {
        let parts = line.split(separator: " ")
        func start(_ prefix: Character) -> Int {
            guard let part = parts.first(where: { $0.first == prefix }) else { return 0 }
            return Int(part.dropFirst().split(separator: ",").first ?? "") ?? 0
        }
        return (start("-"), start("+"))
    }
    /// The two paths of a `diff --git` header. Unquoted paths with spaces are split where the
    /// halves agree (the usual case: the same path on both sides).
    static func headerPaths(_ rest: String) -> (String?, String?) {
        if rest.hasPrefix("\"") {
            let (first, remainder) = quotedToken(rest)
            let second = remainder.trimmingCharacters(in: .whitespaces)
            return (stripPrefix(first, "a/"), stripPrefix(second.hasPrefix("\"") ? quotedToken(second).0 : second, "b/"))
        }
        if let quote = rest.range(of: " \"b/") {
            return (stripPrefix(String(rest[..<quote.lowerBound]), "a/"), stripPrefix(quotedToken(String(rest[rest.index(after: quote.lowerBound)...])).0, "b/"))
        }
        let characters = Array(rest)
        if characters.count % 2 == 1 {
            let half = (characters.count - 1) / 2
            let a = String(characters[..<half]), b = String(characters[(half + 1)...])
            if a.hasPrefix("a/"), b.hasPrefix("b/"), a.dropFirst(2) == b.dropFirst(2) { return (String(a.dropFirst(2)), String(b.dropFirst(2))) }
        }
        if let split = rest.range(of: " b/", options: .backwards) {
            return (stripPrefix(String(rest[..<split.lowerBound]), "a/"), String(rest[split.upperBound...]))
        }
        return (nil, nil)
    }
    /// A path as Git writes it: unchanged, or in double quotes with C escapes (octal bytes for non-ASCII).
    static func unquote(_ path: String) -> String {
        guard path.hasPrefix("\"") else { return path }
        return quotedToken(path).0
    }
    private static func quotedToken(_ text: String) -> (String, String) {
        var bytes: [UInt8] = [], index = text.index(after: text.startIndex)
        let scalars = text
        while index < scalars.endIndex {
            let character = scalars[index]
            if character == "\"" { return (String(decoding: bytes, as: UTF8.self), String(scalars[scalars.index(after: index)...])) }
            if character == "\\" {
                index = scalars.index(after: index)
                guard index < scalars.endIndex else { break }
                let escaped = scalars[index]
                switch escaped {
                case "n": bytes.append(10)
                case "t": bytes.append(9)
                case "r": bytes.append(13)
                case "a": bytes.append(7)
                case "b": bytes.append(8)
                case "f": bytes.append(12)
                case "v": bytes.append(11)
                case "0"..."7":
                    var digits = String(escaped), next = scalars.index(after: index)
                    while digits.count < 3, next < scalars.endIndex, ("0"..."7").contains(scalars[next]) { digits.append(scalars[next]); index = next; next = scalars.index(after: next) }
                    bytes.append(UInt8(Int(digits, radix: 8).map { $0 & 0xff } ?? 0))
                default: bytes += Array(String(escaped).utf8)
                }
            } else { bytes += Array(String(character).utf8) }
            index = scalars.index(after: index)
        }
        return (String(decoding: bytes, as: UTF8.self), "")
    }
    /// The path without Git's `a/`/`b/` side prefix; nil for `/dev/null` (no file on that side).
    private static func stripPrefix(_ path: String, _ prefix: String) -> String? {
        let path = path.hasSuffix("\t") ? String(path.dropLast()) : path
        if path == "/dev/null" { return nil }
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}

// MARK: Browser

/// Finds local development servers ("Local: http://localhost:5173/", "listening on 127.0.0.1:8000")
/// in command and terminal output. Only loopback addresses count; the most recent mention wins.
enum DevServerDetector {
    private static let escapes = try! NSRegularExpression(pattern: "\u{1B}(?:\\[[0-9;?]*[ -/]*[@-~]|\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)|[()][0-9A-B])")
    private static let address = try! NSRegularExpression(pattern: #"(?:(https?)://|(?<![\w.\-/]))(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\]):(\d{2,5})(/[^\s"'<>`)\]}]*)?"#, options: [.caseInsensitive])
    /// Every loopback URL in the text, in order of appearance.
    static func urls(in text: String) -> [URL] {
        let clean = escapes.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        return address.matches(in: clean, range: NSRange(clean.startIndex..., in: clean)).compactMap { match in
            func group(_ index: Int) -> String? { Range(match.range(at: index), in: clean).map { String(clean[$0]) } }
            guard let host = group(2), let portText = group(3), let port = Int(portText), (1...65535).contains(port) else { return nil }
            let scheme = group(1)?.lowercased() ?? "http"
            // A server bound to every interface is reached through the loopback name.
            let reachable = ["0.0.0.0", "[::]"].contains(host) ? "localhost" : host.lowercased()
            var path = group(4) ?? ""
            while let last = path.last, ".,;:!?".contains(last) { path.removeLast() }
            return URL(string: "\(scheme)://\(reachable):\(port)\(path.isEmpty ? "/" : path)")
        }
    }
    /// The most recent server mentioned across the texts, read in order (oldest first).
    static func latest(in texts: [String]) -> URL? {
        texts.reversed().lazy.compactMap { urls(in: $0).last }.first
    }
}
/// What the Browser pane may load: web pages over http or https, nothing else.
enum BrowserAddress {
    /// A typed address as a URL: `localhost:3000` → `http://localhost:3000`, `example.com` →
    /// `https://example.com`. Other schemes (file, javascript, data, custom) are refused.
    static func normalize(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        if let schemeEnd = text.range(of: "://") {
            guard let url = URL(string: text), allowed(url), schemeEnd.lowerBound > text.startIndex else { return nil }
            return url
        }
        // The host, and what follows it: a bracketed IPv6 address keeps its colons.
        let hostEnd = text.hasPrefix("[") ? text.firstIndex(of: "]").map { text.index(after: $0) } ?? text.endIndex : text.firstIndex { $0 == ":" || $0 == "/" } ?? text.endIndex
        let host = String(text[..<hostEnd]).lowercased()
        // "name:" followed by something other than a port number is a scheme, such as javascript: or about:.
        if text[hostEnd...].hasPrefix(":") {
            let port = text[text.index(after: hostEnd)...].prefix { $0 != "/" }
            guard !port.isEmpty, port.allSatisfy(\.isNumber) else { return nil }
        }
        let local = isLoopback(host) || host.hasSuffix(".local") || host.split(separator: ".").count == 4 && host.split(separator: ".").allSatisfy { Int($0) != nil } || !host.contains(".")
        guard let url = URL(string: (local ? "http://" : "https://") + text), allowed(url) else { return nil }
        return url
    }
    static func allowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return !(url.host ?? "").isEmpty
    }
    static func isLoopback(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return host == "localhost" || host.hasPrefix("127.") || host == "::1" || host == "0.0.0.0"
    }
    /// A link leaves the pane for the default browser when it goes to another site: not loopback,
    /// and not the host of the page that's open.
    static func isExternal(_ target: URL, from current: URL?) -> Bool {
        guard let host = target.host?.lowercased() else { return true }
        if isLoopback(host) { return false }
        return host != current?.host?.lowercased()
    }
}

// MARK: Device preview

struct SimulatorDevice: Identifiable, Equatable {
    var udid: String
    var name: String
    var state: String
    /// "iOS 26.2", from the runtime identifier.
    var runtime: String
    var id: String { udid }
    var booted: Bool { state == "Booted" }
}
enum SimulatorList {
    /// iOS simulators from `xcrun simctl list devices available -j`: booted first, then the newest
    /// runtime, then by name. Other platforms (watchOS, tvOS, visionOS) are left out.
    static func parse(_ data: Data) throws -> [SimulatorDevice] {
        struct Listing: Decodable {
            struct Device: Decodable { var udid: String; var name: String; var state: String; var isAvailable: Bool? }
            var devices: [String: [Device]]
        }
        let listing = try JSONDecoder().decode(Listing.self, from: data)
        var devices: [(device: SimulatorDevice, version: [Int])] = []
        for (runtime, entries) in listing.devices {
            guard let (platform, version) = runtimeVersion(runtime), platform == "iOS" else { continue }
            for entry in entries where entry.isAvailable != false {
                devices.append((.init(udid: entry.udid, name: entry.name, state: entry.state, runtime: "iOS " + version.map(String.init).joined(separator: ".")), version))
            }
        }
        return devices.sorted { a, b in
            if a.device.booted != b.device.booted { return a.device.booted }
            if a.version != b.version { return a.version.lexicographicallyPrecedes(b.version) == false }
            return a.device.name.localizedStandardCompare(b.device.name) == .orderedAscending
        }.map(\.device)
    }
    /// `com.apple.CoreSimulator.SimRuntime.iOS-26-2` → ("iOS", [26, 2]).
    static func runtimeVersion(_ identifier: String) -> (String, [Int])? {
        guard let last = identifier.split(separator: ".").last else { return nil }
        let parts = last.split(separator: "-")
        guard let platform = parts.first, parts.count > 1 else { return nil }
        let version = parts.dropFirst().compactMap { Int($0) }
        guard version.count == parts.count - 1 else { return nil }
        return (String(platform), version)
    }
}
enum SimulatorBuilds {
    /// Whether a folder holds an Apple-platform project (an Xcode project or workspace, an
    /// XcodeGen spec, or a Swift package), at its top level or one folder down.
    static func isAppleProject(_ root: URL) -> Bool {
        let manager = FileManager.default
        func holds(_ folder: URL) -> Bool {
            let names = (try? manager.contentsOfDirectory(atPath: folder.path)) ?? []
            return names.contains { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") || $0 == "project.yml" || $0 == "Package.swift" }
        }
        if holds(root) { return true }
        let children = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return children.contains { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && !ProjectLibraryIndex.excluded.contains($0.lastPathComponent) && holds($0) }
    }
    /// Names of the Xcode projects in a folder (top level and one down), without extensions.
    static func projectNames(in root: URL) -> [String] {
        let manager = FileManager.default
        var folders = [root]
        folders += ((try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []).filter(\.hasDirectoryPath)
        var names: [String] = []
        for folder in folders {
            for name in (try? manager.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".xcodeproj") || name.hasSuffix(".xcworkspace") {
                names.append((name as NSString).deletingPathExtension)
            }
        }
        return names
    }
    /// The most recently built simulator app for one of these projects, from Xcode's DerivedData
    /// (`<Project>-<hash>/Build/Products/<Config>-iphonesimulator/<App>.app`).
    static func latestApp(projectNames: [String], derivedData: URL) -> URL? {
        let manager = FileManager.default
        guard !projectNames.isEmpty, let builds = try? manager.contentsOfDirectory(at: derivedData, includingPropertiesForKeys: nil) else { return nil }
        var best: (url: URL, date: Date)?
        for build in builds where projectNames.contains(where: { build.lastPathComponent.hasPrefix($0 + "-") }) {
            let products = build.appendingPathComponent("Build/Products")
            for config in (try? manager.contentsOfDirectory(at: products, includingPropertiesForKeys: nil)) ?? [] where config.lastPathComponent.hasSuffix("-iphonesimulator") {
                for app in (try? manager.contentsOfDirectory(at: config, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] where app.pathExtension == "app" {
                    let date = (try? app.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    if best == nil || date > best!.date { best = (app, date) }
                }
            }
        }
        return best?.url
    }
    /// The bundle identifier of a built app, from its Info.plist.
    static func bundleID(of app: URL) -> String? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return plist["CFBundleIdentifier"] as? String
    }
}

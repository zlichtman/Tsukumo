import SwiftUI
import AppKit
import WebKit

// The panes of a coding task, opened from the task toolbar: Changes, Browser, and Device on the
// right (one at a time), and the terminal below (⌘J, in `TerminalPanel`).

// MARK: Toolbar

/// The icon toolbar at the trailing edge of a task's header, as in Claude's and Codex's task
/// windows: Terminal, Changes, Browser, Device, and a menu of task actions.
struct CodingTaskToolbar: View {
    let task: CodingTaskRecord
    @Binding var panes: CodingPaneState
    @Environment(CodingWorkspaceStore.self) private var coding
    @State private var deleting = false
    var body: some View {
        HStack(spacing: 2) {
            toggle("terminal", "Terminal", isOn: panes.terminal, shortcut: "⌘J") { panes.toggleTerminal() }
                .keyboardShortcut("j", modifiers: .command)
                .accessibilityIdentifier("taskPane-terminal")
            ForEach(CodingPane.allCases) { pane in
                toggle(pane.symbol, pane.title, isOn: panes.isOpen(pane)) { panes.toggle(pane) }
                    .accessibilityIdentifier("taskPane-" + pane.rawValue)
            }
            Menu {
                if task.status.running { Button("Stop") { coding.stop(task.id) } }
                Button("Open in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: task.directory)]) }
                Button(task.isolated ? "Open worktree in Terminal" : "Open folder in Terminal") { CodingTaskActions.openInTerminal(URL(fileURLWithPath: task.directory)) }
                Button("Copy path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(task.directory, forType: .string) }
                Divider()
                Button("Archive") { coding.archive(task.id) }
                    .help("Hides the task. Its worktree, branch, and log are kept; unarchive it from Coordination.")
                Button("Delete task…", role: .destructive) { deleting = true }.accessibilityIdentifier("deleteTask")
            } label: {
                Image(systemName: "ellipsis").frame(width: 26, height: 22)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Task actions").accessibilityLabel("Task actions").accessibilityIdentifier("taskActions")
        }
        .confirmationDialog("Delete this task?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete task", role: .destructive) { Task { await coding.delete(task.id) } }
        } message: {
            Text(CodingAgentSessionRemoval.summary(task))
        }
    }
    private func toggle(_ symbol: String, _ title: String, isOn: Bool, shortcut: String = "", action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13)).frame(width: 26, height: 22)
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(DesktopRowButtonStyle(selected: isOn, inset: 2))
        .help(isOn ? "Hide \(title.lowercased())" : "Show \(title.lowercased())" + (shortcut.isEmpty ? "" : " (\(shortcut))"))
        .accessibilityLabel(title).accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
enum CodingTaskActions {
    /// Opens a folder in macOS Terminal (the person's own, outside Tsukumo).
    static func openInTerminal(_ folder: URL) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
}

// MARK: Changes

/// The task's changes against its base: files with +/– counts, each file's hunks in a unified or
/// side-by-side view, the checks it ran, and Accept or Request revision. The diff comes from the
/// store's review (an immutable snapshot of the folder, untracked files included), so what's
/// shown is exactly what Accept would commit.
struct CodingChangesPane: View {
    let task: CodingTaskRecord
    /// Opens a file in the Files tab's editor.
    var openInEditor: (String) -> Void
    @Environment(CodingWorkspaceStore.self) private var coding
    @Environment(DesktopPreferences.self) private var preferences
    @State private var review: CodingReview?
    @State private var files: [CodingDiffFile] = []
    @State private var selectedFile: String?
    @State private var layout = "Unified"
    @State private var command = ""
    @State private var loading = false
    @State private var confirmAccept = false
    @State private var revising = false
    @State private var revision = ""
    @State private var error = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(files.isEmpty ? "No changes" : "\(files.count) file\(files.count == 1 ? "" : "s") changed").font(.system(size: 13, weight: .semibold))
                if !files.isEmpty {
                    Text("+\(files.reduce(0) { $0 + $1.additions })").foregroundStyle(.green)
                    Text("−\(files.reduce(0) { $0 + $1.deletions })").foregroundStyle(.red)
                }
                Spacer()
                QuietSegmented(options: ["Unified", "Split"], selection: $layout).font(.system(size: 11))
                if loading { KemoOrb(size: 16, state: .searching) }
                Button { load() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(DesktopRowButtonStyle(inset: 5)).disabled(loading).help("Review the task's files again").accessibilityLabel("Refresh changes")
            }.font(.system(size: 12)).padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            if !files.isEmpty {
                fileList.frame(maxHeight: 170)
                Divider()
            }
            if let file = files.first(where: { $0.path == selectedFile }) ?? files.first {
                fileHeader(file)
                CodingDiffView(file: file, split: layout == "Split", font: preferences.codeFontSize - 1)
            } else {
                Text(review == nil ? (error.isEmpty ? "Reviewing the task's files…" : "") : "The task hasn't changed any files yet.")
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.orange).padding(.horizontal, 12).padding(.vertical, 4).textSelection(.enabled) }
            Divider()
            reviewFooter.padding(12)
        }
        .task(id: task.id) { review = nil; files = []; selectedFile = CodingChatCommands.shared.revealed?.path; load() }
        // A file card in the conversation asks for its file here.
        .onChange(of: CodingChatCommands.shared.revealed) { if let path = CodingChatCommands.shared.revealed?.path { selectedFile = path } }
        // A turn that finishes (or a check that ran) changes the files: review them again.
        .onChange(of: task.changes) { if !loading { load() } }
        .confirmationDialog("Commit exactly the reviewed version and fast-forward it into the project's original branch?", isPresented: $confirmAccept) {
            Button("Commit and accept") { if let review { Task { await coding.accept(task.id, review: review); load() } } }
        } message: { Text("If any file changed after this review, accepting stops so you can review again. The worktree and branch are retained. If the project has moved ahead, accepting stops so you can reconcile it without losing work.") }
    }
    private var fileList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(files) { file in
                    Button { selectedFile = file.path } label: {
                        HStack(spacing: 8) {
                            Text(Self.letter(file)).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Self.tint(file)).frame(width: 12)
                            Text(file.path).lineLimit(1).truncationMode(.head).frame(maxWidth: .infinity, alignment: .leading)
                            if file.binary { Text("binary").foregroundStyle(.secondary) }
                            else {
                                Text("+\(file.additions)").foregroundStyle(.green)
                                Text("−\(file.deletions)").foregroundStyle(.red)
                            }
                        }.font(.system(size: 12)).padding(.horizontal, 8).padding(.vertical, 5).contentShape(Rectangle())
                    }
                    .buttonStyle(DesktopRowButtonStyle(selected: (selectedFile ?? files.first?.path) == file.path))
                    .accessibilityLabel("\(file.path), \(file.change.rawValue), \(file.additions) added, \(file.deletions) removed")
                }
            }.padding(6)
        }
    }
    private func fileHeader(_ file: CodingDiffFile) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(file.path).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.head)
                if let old = file.oldPath { Text("Renamed from " + old).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            Button("Open in editor") { openInEditor(file.path) }
                .buttonStyle(DesktopRowButtonStyle(inset: 5)).font(.system(size: 12))
                .disabled(file.change == .deleted || file.binary)
        }.padding(.horizontal, 12).padding(.vertical, 6)
    }
    private var reviewFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Check command (e.g. swift test)", text: $command).textFieldStyle(.roundedBorder)
                Button("Run") { Task { await coding.check(task.id, command: command) } }.disabled(command.isEmpty || task.status.running || coding.busy.contains(task.id))
            }
            if let review {
                let bound = coding.checks(for: review), all = task.events.filter { $0.kind == .check && $0.status != "running" }
                Text(bound.isEmpty ? "No checks have run on this reviewed version." : "On this version: " + bound.map { "\($0.text) \($0.status)" }.joined(separator: " · ")).font(.caption2)
                if all.count > bound.count { Text("\(all.count - bound.count) earlier check result(s) ran on other files and don't count for this version.").font(.caption2).foregroundStyle(.secondary) }
            } else { Text("Checks run in this task's folder and appear in its activity log.").font(.caption2).foregroundStyle(.secondary) }
            HStack {
                if task.isolated {
                    Button("Accept changes…") { confirmAccept = true }.disabled(review == nil || !error.isEmpty || task.status.running || coding.busy.contains(task.id) || task.status == .done)
                } else { Button("Mark done") { coding.markDone(task.id) }.disabled(task.status.running || task.status == .done) }
                Button("Request revision…") { revising = true }
                    .disabled(task.status.running || task.status == .done || coding.busy.contains(task.id) || coding.storageFailed)
                    .popover(isPresented: $revising, arrowEdge: .top) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("What should change?").font(.headline)
                            TextField("Describe the revision", text: $revision, axis: .vertical).lineLimit(3...8).frame(width: 300)
                            HStack {
                                Spacer()
                                Button("Cancel") { revising = false }
                                Button("Send") {
                                    let text = revision.trimmingCharacters(in: .whitespacesAndNewlines); revision = ""; revising = false
                                    coding.send(task.id, "Revision requested after review:\n" + text)
                                }.buttonStyle(.borderedProminent).disabled(revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }.padding(14)
                    }
                if coding.busy.contains(task.id) { KemoOrb(size: 18, state: .searching) }
            }
            // Commit on the branch, or open a pull request (CodingChatReview.swift).
            CodingCommitActions(task: task, review: review, files: files)
        }
    }
    private func load() {
        loading = true; error = ""
        let id = task.id
        Task {
            defer { loading = false }
            do {
                await coding.refresh(id)
                let next = try await coding.review(id)
                guard id == task.id else { return }
                review = next
                files = next.diff == "No changes." ? [] : CodingDiff.parse(next.diff)
                if let selectedFile, !files.contains(where: { $0.path == selectedFile }) { self.selectedFile = nil }
            } catch { self.error = error.localizedDescription; review = nil; files = [] }
        }
    }
    static func letter(_ file: CodingDiffFile) -> String {
        switch file.change { case .added: "A"; case .deleted: "D"; case .renamed: "R"; case .modified: "M" }
    }
    static func tint(_ file: CodingDiffFile) -> Color {
        switch file.change { case .added: .green; case .deleted: .red; case .renamed: .blue; case .modified: .orange }
    }
}

/// One file's hunks, unified (one column) or split (base on the left, the task's version on the right).
struct CodingDiffView: View {
    let file: CodingDiffFile
    let split: Bool
    var font: Double = 12
    var body: some View {
        if file.binary {
            Text("Binary file: open it in your editor to compare.").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if file.hunks.isEmpty {
            Text(file.change == .renamed ? "Renamed without changes." : "No text changes (mode or empty file).").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(file.hunks) { hunk in
                        Text(hunk.header).font(.system(size: font - 1, design: .monospaced)).foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.blue.opacity(0.08))
                        if split {
                            ForEach(Array(hunk.rows.enumerated()), id: \.offset) { _, row in
                                HStack(spacing: 0) {
                                    cell(row.left, number: row.left?.old).frame(maxWidth: .infinity)
                                    Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)
                                    cell(row.right, number: row.right?.new).frame(maxWidth: .infinity)
                                }
                            }
                        } else {
                            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in unified(line) }
                        }
                    }
                }.textSelection(.enabled)
            }
        }
    }
    private func unified(_ line: CodingDiffLine) -> some View {
        HStack(alignment: .top, spacing: 0) {
            number(line.old); number(line.new)
            Text(marker(line.kind) + line.text).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: font, design: .monospaced))
        .background(background(line.kind))
    }
    private func cell(_ line: CodingDiffLine?, number value: Int?) -> some View {
        HStack(alignment: .top, spacing: 0) {
            number(value)
            Text(line.map { marker($0.kind) + $0.text } ?? "").frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: font, design: .monospaced))
        .frame(maxHeight: .infinity, alignment: .top)
        .background(line.map { background($0.kind) } ?? Color.primary.opacity(0.03))
    }
    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "").foregroundStyle(.tertiary).frame(width: 38, alignment: .trailing).padding(.trailing, 6)
            .font(.system(size: font - 2, design: .monospaced))
    }
    private func marker(_ kind: CodingDiffLine.Kind) -> String {
        switch kind { case .added: "+"; case .removed: "-"; case .context: " "; case .note: "\\ " }
    }
    private func background(_ kind: CodingDiffLine.Kind) -> Color {
        switch kind { case .added: .green.opacity(0.14); case .removed: .red.opacity(0.14); case .context, .note: .clear }
    }
}

// MARK: Browser

/// A small web browser for the task's dev server: http and https only, no scripts or handlers
/// added to pages, a data store that isn't kept on disk, and links to other sites opened in the
/// default browser.
@MainActor @Observable final class CodingBrowser: NSObject, WKNavigationDelegate, WKUIDelegate {
    @ObservationIgnored let webView: WKWebView
    var address = ""
    var canGoBack = false
    var canGoForward = false
    var loading = false
    var error = ""
    /// Whether the person has loaded anything; until then a detected dev server opens by itself.
    private(set) var started = false
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observations = [
            webView.observe(\.canGoBack) { [weak self] view, _ in MainActor.assumeIsolated { self?.canGoBack = view.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] view, _ in MainActor.assumeIsolated { self?.canGoForward = view.canGoForward } },
            webView.observe(\.isLoading) { [weak self] view, _ in MainActor.assumeIsolated { self?.loading = view.isLoading } },
            webView.observe(\.url) { [weak self] view, _ in MainActor.assumeIsolated { if let url = view.url, BrowserAddress.allowed(url) { self?.address = url.absoluteString } } }
        ]
    }
    /// Loads what's in the address field (or `text`); anything that isn't http or https is refused.
    func go(_ text: String? = nil) {
        guard let url = BrowserAddress.normalize(text ?? address) else { error = "Enter an http or https address, such as localhost:3000."; return }
        load(url)
    }
    func load(_ url: URL) {
        guard BrowserAddress.allowed(url) else { return }
        started = true; error = ""; address = url.absoluteString
        webView.load(URLRequest(url: url))
    }
    func reload() { error = ""; if webView.url == nil { go() } else { webView.reload() } }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        guard let url = action.request.url else { return (.cancel, preferences) }
        if url.absoluteString == "about:blank" || url.scheme == "about" && action.targetFrame?.isMainFrame == false { return (.allow, preferences) }
        guard BrowserAddress.allowed(url) else { return (.cancel, preferences) }
        if action.navigationType == .linkActivated, action.targetFrame?.isMainFrame != false, BrowserAddress.isExternal(url, from: webView.url) {
            NSWorkspace.shared.open(url); return (.cancel, preferences)
        }
        return (.allow, preferences)
    }
    /// A page asking for a new window: its own site loads here, another site opens in the default browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, BrowserAddress.allowed(url) {
            if BrowserAddress.isExternal(url, from: webView.url) { NSWorkspace.shared.open(url) } else { webView.load(URLRequest(url: url)) }
        }
        return nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { report(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { report(error) }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { error = "" }
    private func report(_ error: Error) {
        let nsError = error as NSError
        // A navigation replaced by another one isn't a failure.
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else { return }
        self.error = nsError.code == NSURLErrorCannotConnectToHost ? "Couldn't connect. Is the dev server running?" : nsError.localizedDescription
    }
}
struct CodingWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
    static func dismantleNSView(_ view: WKWebView, coordinator: ()) { view.removeFromSuperview() }
}
struct CodingBrowserPane: View {
    let task: CodingTaskRecord
    let browser: CodingBrowser
    @State private var detected: URL?
    var body: some View {
        @Bindable var browser = browser
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button { browser.webView.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!browser.canGoBack).help("Back").accessibilityLabel("Back")
                Button { browser.webView.goForward() } label: { Image(systemName: "chevron.right") }.disabled(!browser.canGoForward).help("Forward").accessibilityLabel("Forward")
                Button { if browser.loading { browser.webView.stopLoading() } else { browser.reload() } } label: { Image(systemName: browser.loading ? "xmark" : "arrow.clockwise") }
                    .help(browser.loading ? "Stop" : "Reload").accessibilityLabel(browser.loading ? "Stop loading" : "Reload")
                TextField("localhost:3000", text: $browser.address).textFieldStyle(.roundedBorder).onSubmit { browser.go() }
                    .accessibilityIdentifier("browserAddress")
                Button { if let url = browser.webView.url { NSWorkspace.shared.open(url) } } label: { Image(systemName: "safari") }
                    .disabled(browser.webView.url == nil).help("Open in your browser").accessibilityLabel("Open in your browser")
            }
            .buttonStyle(DesktopRowButtonStyle(inset: 5)).font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 7)
            if let detected, detected.absoluteString != browser.webView.url?.absoluteString {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.horizontal.circle").foregroundStyle(.secondary)
                    Text("Dev server at \(detected.host ?? ""):\(detected.port.map(String.init) ?? "")").lineLimit(1)
                    Spacer()
                    Button("Open") { browser.load(detected) }.buttonStyle(DesktopRowButtonStyle(inset: 5))
                }.font(.system(size: 12)).padding(.horizontal, 12).padding(.bottom, 6)
            }
            if !browser.error.isEmpty { Text(browser.error).font(.caption).foregroundStyle(.orange).padding(.horizontal, 12).padding(.bottom, 6).frame(maxWidth: .infinity, alignment: .leading) }
            Divider()
            ZStack {
                CodingWebView(webView: browser.webView)
                if !browser.started {
                    VStack(spacing: 8) {
                        Image(systemName: "globe").font(.system(size: 28)).foregroundStyle(.tertiary)
                        Text("No dev server found yet").foregroundStyle(.secondary)
                        Text("Start one in the terminal (⌘J) or ask the agent to, or type an address above. Pages load over http or https only; links to other sites open in your browser.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 280)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.background)
                }
            }
        }
        // Looks for a dev server in the task's command output and its terminals every two seconds
        // while the pane is open; the first one found opens if nothing else has been loaded.
        .task(id: task.id) {
            while !Task.isCancelled {
                detected = Self.detect(task: task)
                if let detected, !browser.started { browser.load(detected) }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
    @MainActor static func detect(task: CodingTaskRecord) -> URL? {
        let events = task.events.suffix(300).filter { [.command, .check, .system, .assistant].contains($0.kind) }.map { $0.text + "\n" + $0.detail }
        return DevServerDetector.latest(in: events + TerminalSessions.shared.recentOutput(in: URL(fileURLWithPath: task.directory)))
    }
}

// MARK: Device preview

/// iOS simulators through `xcrun simctl`: list, boot on request, a live-ish preview from
/// screenshots (2 a second while the pane is open), and install and launch a built app. Nothing
/// boots on its own.
@MainActor @Observable final class SimulatorPreview {
    /// nil while checking; false when Xcode's simctl isn't available.
    private(set) var available: Bool?
    private(set) var devices: [SimulatorDevice] = []
    var selected: String?
    private(set) var frame: NSImage?
    private(set) var busy = false
    var status = ""
    var app: URL?
    var device: SimulatorDevice? { devices.first { $0.udid == selected } }
    func load(root: URL) async {
        if available == nil {
            let found = (try? await CodingCommand.run("/usr/bin/xcrun", ["--find", "simctl"], at: root, timeout: 20))?.code == 0
            available = found
            guard found else { return }
        }
        guard available == true else { return }
        await refresh(root: root)
        if app == nil { app = SimulatorBuilds.latestApp(projectNames: SimulatorBuilds.projectNames(in: root), derivedData: Self.derivedData) }
    }
    func refresh(root: URL) async {
        do {
            let result = try await CodingCommand.run("/usr/bin/xcrun", ["simctl", "list", "devices", "available", "-j"], at: root, timeout: 30)
            guard result.code == 0 else { status = result.output.isEmpty ? "simctl couldn't list devices." : result.output; return }
            devices = try SimulatorList.parse(Data(result.output.utf8))
            // Keep the choice; otherwise show a device that's already running. Never boot one.
            if selected == nil || !devices.contains(where: { $0.udid == selected }) { selected = devices.first(where: \.booted)?.udid }
        } catch { status = error.localizedDescription }
    }
    func boot(root: URL) async {
        guard let device, !device.booted else { return }
        busy = true; defer { busy = false }
        status = "Booting \(device.name)…"
        let result = try? await CodingCommand.run("/usr/bin/xcrun", ["simctl", "boot", device.udid], at: root, timeout: 180)
        status = result?.code == 0 ? "" : (result?.output ?? "Couldn't boot \(device.name).")
        await refresh(root: root)
    }
    func openSimulatorApp(root: URL) async {
        var arguments = ["-a", "Simulator"]
        if let device { arguments += ["--args", "-CurrentDeviceUDID", device.udid] }
        _ = try? await CodingCommand.run("/usr/bin/open", arguments, at: root, timeout: 20)
    }
    func installAndLaunch(root: URL) async {
        guard let device, device.booted, let app else { return }
        guard let bundle = SimulatorBuilds.bundleID(of: app) else { status = "\(app.lastPathComponent) has no bundle identifier."; return }
        busy = true; defer { busy = false }
        status = "Installing \(app.lastPathComponent)…"
        let install = try? await CodingCommand.run("/usr/bin/xcrun", ["simctl", "install", device.udid, app.path], at: root, timeout: 180)
        guard install?.code == 0 else { status = install?.output ?? "Install failed."; return }
        status = "Launching…"
        let launch = try? await CodingCommand.run("/usr/bin/xcrun", ["simctl", "launch", device.udid, bundle], at: root, timeout: 60)
        status = launch?.code == 0 ? "" : (launch?.output ?? "Launch failed.")
    }
    /// Screenshots of the selected booted device, up to twice a second, until the task is
    /// cancelled (the pane closes or another device is chosen). A `simctl` screenshot takes about
    /// 0.7 s on an M-series Mac (measured September 25, 2026), so the preview runs at roughly one
    /// frame a second; JPEG is the quickest format it writes.
    func capture(root: URL) async {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tsukumo-sim-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: file) }
        frame = nil
        while !Task.isCancelled {
            let started = ContinuousClock.now
            if let device, device.booted {
                let result = try? await CodingCommand.run("/usr/bin/xcrun", ["simctl", "io", device.udid, "screenshot", "--type=jpeg", file.path], at: root, timeout: 10)
                if Task.isCancelled { return }
                if result?.code == 0, let data = try? Data(contentsOf: file), let image = NSImage(data: data) { frame = image }
                else { frame = nil; await refresh(root: root) }
            }
            let wait = Duration.milliseconds(500) - (ContinuousClock.now - started)
            try? await Task.sleep(for: max(wait, .milliseconds(50)))
        }
    }
    static var derivedData: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer/Xcode/DerivedData") }
}
struct CodingDevicePane: View {
    let task: CodingTaskRecord
    let simulator: SimulatorPreview
    private var root: URL { URL(fileURLWithPath: task.directory) }
    var body: some View {
        VStack(spacing: 0) {
            switch simulator.available {
            case nil:
                HStack(spacing: 10) { KemoOrb(size: 20, state: .searching); Text("Looking for Xcode's simulators…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case false?:
                VStack(spacing: 8) {
                    Image(systemName: "iphone.slash").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text("Xcode isn't installed").foregroundStyle(.secondary)
                    Text("Device preview uses the iOS Simulator from Xcode (`xcrun simctl`). Install Xcode, or choose it with `xcode-select`, then reopen this pane.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 280)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            case true?:
                controls
                Divider()
                preview
                if !simulator.status.isEmpty {
                    Text(simulator.status).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .task(id: task.directory) { await simulator.load(root: root) }
        .task(id: (simulator.selected ?? "") + (simulator.device?.state ?? "")) { await simulator.capture(root: root) }
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Menu {
                    ForEach(simulator.devices) { device in
                        Button { simulator.selected = device.udid } label: {
                            if device.udid == simulator.selected { Label("\(device.name) · \(device.runtime)\(device.booted ? " · Booted" : "")", systemImage: "checkmark") }
                            else { Text("\(device.name) · \(device.runtime)\(device.booted ? " · Booted" : "")") }
                        }
                    }
                    if simulator.devices.isEmpty { Text("No iOS simulators. Add one in Xcode.") }
                } label: {
                    Text(simulator.device.map { "\($0.name) · \($0.runtime)" } ?? "Choose a simulator").lineLimit(1)
                }.menuStyle(.borderlessButton).fixedSize().accessibilityIdentifier("simulatorPicker")
                Spacer()
                Button { Task { await simulator.refresh(root: root) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(DesktopRowButtonStyle(inset: 5)).help("Refresh the device list").accessibilityLabel("Refresh devices")
            }
            HStack(spacing: 6) {
                if let device = simulator.device, !device.booted {
                    Button("Boot") { Task { await simulator.boot(root: root) } }.disabled(simulator.busy).accessibilityIdentifier("bootSimulator")
                }
                Button("Open Simulator") { Task { await simulator.openSimulatorApp(root: root) } }
                Spacer()
                Menu {
                    Button("Choose app…") { chooseApp() }
                    if let app = simulator.app { Text(app.lastPathComponent) }
                } label: { Text(simulator.app.map { "Run \($0.deletingPathExtension().lastPathComponent)" } ?? "Run app") }
                primaryAction: {
                    if simulator.app == nil { chooseApp() } else { Task { await simulator.installAndLaunch(root: root) } }
                }
                .fixedSize().disabled(simulator.busy || simulator.device?.booted != true)
                .help("Install and launch the built app on this simulator")
                if simulator.busy { KemoOrb(size: 16, state: .searching) }
            }
            if !SimulatorBuilds.isAppleProject(root) {
                Text("This folder has no Xcode project; the preview still shows any simulator.").font(.caption2).foregroundStyle(.secondary)
            }
        }.font(.system(size: 12)).padding(10)
    }
    private var preview: some View {
        ZStack {
            if let frame = simulator.frame {
                Image(nsImage: frame).resizable().interpolation(.high).scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous)).padding(14)
                    .accessibilityLabel("Screen of \(simulator.device?.name ?? "the simulator")")
            } else if let device = simulator.device {
                VStack(spacing: 8) {
                    Image(systemName: "iphone").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text(device.booted ? "Waiting for the screen…" : "\(device.name) is off").foregroundStyle(.secondary)
                    if !device.booted { Text("Boot it to see its screen here. Open Simulator to tap and type.").font(.caption).foregroundStyle(.secondary) }
                }
            } else {
                Text("Choose a simulator").foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]; panel.canChooseDirectories = false; panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = simulator.app?.deletingLastPathComponent() ?? SimulatorPreview.derivedData
        panel.message = "Choose an app built for the iOS Simulator"
        if panel.runModal() == .OK, let url = panel.url { simulator.app = url }
    }
}

/// The browser and simulator preview are app-wide, like the terminal sessions: one web view and
/// one device list, kept while panes and tasks change, and made only when first opened.
@MainActor enum CodingPaneModels {
    static let browser = CodingBrowser()
    static let simulator = SimulatorPreview()
}

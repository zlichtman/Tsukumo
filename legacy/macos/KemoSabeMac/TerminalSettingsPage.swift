import AppKit
import SwiftUI

/// Settings → Terminal (Coding, Mac only): the quick terminal, profiles, shell integration, keyboard
/// and mouse, the window, and the bell.
struct TerminalSettingsPage: View {
    @State private var settings = TerminalPreferences.shared
    @State private var editing: UUID?
    @State private var recording = false
    @State private var recorder: Any?
    @State private var hotkeyProblem: String?
    @State private var scrollbackText = ""
    var body: some View {
        SettingsContent {
            quickTerminal
            profiles
            shellIntegration
            keyboard
            window
            SettingsCard(title: "Bell") {
                SettingsRow(title: "When a program rings the bell", detail: "Visual flashes the terminal; Sound plays the system alert.") {
                    QuietSegmented(options: TerminalBellStyle.allCases.map(\.rawValue), selection: Binding(get: { settings.bell.rawValue }, set: { settings.bell = TerminalBellStyle(rawValue: $0) ?? .visual }))
                }
                Divider()
                SettingsRow(title: "Bounce the Dock icon", detail: "When the bell rings while Tsukumo is in the background.") { toggle($settings.bounceDockOnBell, "Bounce the Dock icon") }
            }
            Text("Key commands while a terminal has the keyboard: ⌘T new tab, ⌘W close pane, ⌘D split right, ⌘⇧D split down, ⌘⌥ arrows move between panes, ⌘F find, ⌘↑ and ⌘↓ jump between prompts, ⌘⇧A select the last command's output, ⌘1–9 switch tabs, ⌘K clear, ⌘+ ⌘- ⌘0 text size.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { hotkeyProblem = QuickTerminal.shared.reload(); scrollbackText = String(settings.scrollback) }
        .onDisappear { stopRecording() }
    }

    // MARK: Quick terminal

    private var quickTerminal: some View {
        SettingsCard(title: "Quick terminal") {
            SettingsRow(title: "Quick terminal", detail: "A terminal drops down from the top of the screen with a shortcut, from any app, and hides again.") {
                Toggle("Quick terminal", isOn: Binding(get: { settings.quickTerminal }, set: { settings.quickTerminal = $0; hotkeyProblem = QuickTerminal.shared.reload() })).labelsHidden()
            }
            Divider()
            SettingsRow(title: "Shortcut", detail: recording ? "Press the new shortcut. Esc cancels." : nil) {
                HStack(spacing: 10) {
                    KeyCaps(keys: TerminalHotkey(settings.quickHotkey)?.keyCaps ?? [settings.quickHotkey])
                    Button(recording ? "Cancel" : "Change") { recording ? stopRecording() : startRecording() }.accessibilityIdentifier("recordQuickShortcut")
                    if settings.quickHotkey != TerminalHotkey.defaultQuick.description {
                        Button("Reset") { settings.quickHotkey = TerminalHotkey.defaultQuick.description; hotkeyProblem = QuickTerminal.shared.reload() }
                    }
                }
            }.disabled(!settings.quickTerminal)
            if let hotkeyProblem, settings.quickTerminal {
                Text(hotkeyProblem).font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 10)
                    .accessibilityIdentifier("quickShortcutProblem")
            }
            Divider()
            SettingsRow(title: "Height", detail: "\(Int(settings.quickHeight * 100))% of the screen") {
                Slider(value: $settings.quickHeight, in: 0.2...0.9).frame(width: 160).accessibilityLabel("Quick terminal height")
            }
            Divider()
            SettingsRow(title: "Hide when you click elsewhere") { toggle($settings.quickHidesOnFocusLoss, "Hide when you click elsewhere") }
        }
    }
    private func startRecording() {
        recording = true
        recorder = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty { stopRecording(); return nil }
            guard let hotkey = TerminalHotkey(keyCode: event.keyCode, flags: event.modifierFlags) else { NSSound.beep(); return nil }
            if let problem = hotkey.problem { hotkeyProblem = problem; return nil }
            settings.quickHotkey = hotkey.description
            hotkeyProblem = QuickTerminal.shared.reload()
            stopRecording()
            return nil
        }
    }
    private func stopRecording() {
        if let recorder { NSEvent.removeMonitor(recorder) }
        recorder = nil; recording = false
    }

    // MARK: Profiles

    private var profiles: some View {
        SettingsCard(title: "Profiles") {
            ForEach(settings.profiles) { profile in
                if profile.id != settings.profiles.first?.id { Divider() }
                Button { editing = editing == profile.id ? nil : profile.id } label: {
                    HStack(spacing: 10) {
                        Image(systemName: profile.command.isEmpty ? "terminal" : "sparkles").frame(width: 16).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name)
                            Text(summary(profile)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if profile.id == settings.defaultProfile { Text("Default").font(.caption).foregroundStyle(.secondary) }
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(editing == profile.id ? 90 : 0))
                    }.padding(.vertical, 10).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("terminalProfile-" + profile.name)
                if editing == profile.id {
                    TerminalProfileEditor(profile: Binding(get: { settings.profile(profile.id) }, set: { settings.update($0) }),
                                          isDefault: settings.defaultProfile == profile.id,
                                          canRemove: settings.profiles.count > 1,
                                          makeDefault: { settings.defaultProfile = profile.id },
                                          duplicate: { editing = settings.addProfile(copying: profile).id },
                                          remove: { editing = nil; settings.remove(profile.id) })
                        .padding(.bottom, 12)
                }
            }
            Divider()
            HStack {
                Button("Add profile") { editing = settings.addProfile().id }.accessibilityIdentifier("addTerminalProfile")
                Spacer()
            }.padding(.vertical, 10)
        }
    }
    private func summary(_ profile: TerminalProfile) -> String {
        var parts: [String] = []
        if !profile.command.isEmpty { parts.append("Runs " + profile.command) }
        parts.append(profile.shell.isEmpty ? "Login shell" : (profile.shell as NSString).lastPathComponent)
        parts.append(TerminalColorScheme.named(profile.colorScheme).name)
        return parts.joined(separator: " · ")
    }

    // MARK: The rest

    private var shellIntegration: some View {
        SettingsCard(title: "Shell integration") {
            SettingsRow(title: "Shell integration", detail: "zsh, bash, and fish report their folder and mark prompts and commands: tab titles follow the folder or the running command, splits open in the same folder, and ⌘↑ ⌘↓ jump between prompts. Tsukumo loads it after your own startup files and never edits them. Applies to new terminals.") {
                toggle($settings.shellIntegration, "Shell integration")
            }
            Divider()
            SettingsRow(title: "Notify when a long command finishes", detail: "When Tsukumo isn't in front. Needs shell integration.") {
                HStack(spacing: 8) {
                    toggle($settings.notifyLongCommands, "Notify when a long command finishes")
                    Stepper(value: $settings.longCommandSeconds, in: 3...600, step: 1) { Text("\(Int(settings.longCommandSeconds)) s").monospacedDigit() }
                        .disabled(!settings.notifyLongCommands).accessibilityLabel("Seconds")
                }
            }
        }
    }
    private var keyboard: some View {
        SettingsCard(title: "Keyboard and mouse") {
            SettingsRow(title: "Left Option key is Meta", detail: "Sends Esc+ for Emacs-style shortcuts. Off types special characters (⌥e é).") { toggle($settings.leftOptionIsMeta, "Left Option key is Meta") }
            Divider()
            SettingsRow(title: "Right Option key is Meta") { toggle($settings.rightOptionIsMeta, "Right Option key is Meta") }
            Divider()
            SettingsRow(title: "Copy on select", detail: "Selected text goes to the clipboard as soon as you let go.") { toggle($settings.copyOnSelect, "Copy on select") }
            Divider()
            SettingsRow(title: "Confirm risky pastes", detail: "Ask before pasting text with line breaks (each line may run) or sudo.") { toggle($settings.pasteProtection, "Confirm risky pastes") }
            Divider()
            SettingsRow(title: "Secure keyboard entry", detail: "While Tsukumo is in front, other apps can't read what you type. Some apps (text expanders) stop working meanwhile.") { toggle($settings.secureKeyboardEntry, "Secure keyboard entry") }
            Divider()
            SettingsRow(title: "Open files and links", detail: "⌘-click a URL to open it, or a path (file.swift:42) to open it in Tsukumo's editor.") { Image(systemName: "cursorarrow.click.2").foregroundStyle(.secondary) }
        }
    }
    private var window: some View {
        SettingsCard(title: "Window") {
            SettingsRow(title: "Scrollback", detail: "Lines kept above the screen for each terminal. Applies to new terminals.") {
                HStack(spacing: 6) {
                    TextField("10000", text: $scrollbackText).textFieldStyle(.roundedBorder).frame(width: 90).monospacedDigit()
                        .onSubmit { applyScrollback() }
                    Text("lines").foregroundStyle(.secondary)
                }
            }
            Divider()
            SettingsRow(title: "Background opacity", detail: "\(Int(settings.opacity * 100))%") {
                Slider(value: $settings.opacity, in: 0.3...1).frame(width: 160).accessibilityLabel("Background opacity")
            }
            Divider()
            SettingsRow(title: "Blur behind", detail: "Blurs what shows through a translucent terminal.") { toggle($settings.blur, "Blur behind").disabled(settings.opacity >= 1) }
            Divider()
            SettingsRow(title: "Draw with the GPU", detail: "Metal rendering, faster with a lot of output. Applies to new terminals.") { toggle($settings.gpuRendering, "Draw with the GPU") }
        }
        .onChange(of: settings.scrollback) { scrollbackText = String(settings.scrollback) }
    }
    private func applyScrollback() {
        guard let value = Int(scrollbackText.filter(\.isNumber)) else { scrollbackText = String(settings.scrollback); return }
        settings.scrollback = min(1_000_000, max(100, value))
        scrollbackText = String(settings.scrollback)
    }
    private func toggle(_ binding: Binding<Bool>, _ label: String) -> some View {
        Toggle(label, isOn: binding).labelsHidden().toggleStyle(.switch)
    }
}

/// One profile's settings, shown under its row.
struct TerminalProfileEditor: View {
    @Binding var profile: TerminalProfile
    let isDefault: Bool
    let canRemove: Bool
    let makeDefault: () -> Void
    let duplicate: () -> Void
    let remove: () -> Void
    @State private var environmentText = ""
    @Environment(DesktopPreferences.self) private var preferences
    @Environment(\.colorScheme) private var scheme
    private static let sameFont = "Same as code font"
    private static let monospacedFamilies: [String] = {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        return Array(Set(names.compactMap { NSFont(name: $0, size: 12)?.familyName })).sorted()
    }()
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("Name", text: $profile.name, placeholder: "Profile name")
            field("Command", text: $profile.command, placeholder: "Runs at the first prompt: claude, codex, ssh host")
            field("Shell", text: $profile.shell, placeholder: "Your login shell (\(TerminalSessions.shell))")
            HStack {
                Text("Folder").frame(width: 90, alignment: .leading)
                QuietMenuPicker(title: "Folder", options: TerminalProfile.Folder.allCases.map(\.rawValue),
                                selection: Binding(get: { profile.folder.rawValue }, set: { profile.folder = TerminalProfile.Folder(rawValue: $0) ?? .inherit }), width: 170)
                if profile.folder == .custom {
                    TextField("~/Developer", text: $profile.customFolder).textFieldStyle(.roundedBorder)
                    Button("Choose") { chooseFolder() }
                }
            }
            HStack(alignment: .top) {
                Text("Environment").frame(width: 90, alignment: .leading)
                TextEditor(text: $environmentText).font(.system(size: 12, design: .monospaced)).frame(height: 54)
                    .scrollContentBackground(.hidden).padding(4)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .topLeading) { if environmentText.isEmpty { Text("NAME=value, one per line").font(.system(size: 12, design: .monospaced)).foregroundStyle(.tertiary).padding(8).allowsHitTesting(false) } }
                    .onChange(of: environmentText) { profile.environment = TerminalProfile.parseEnvironment(environmentText) }
            }
            HStack {
                Text("Font").frame(width: 90, alignment: .leading)
                QuietMenuPicker(title: "Font", options: [Self.sameFont, BundledFonts.jetBrainsMono] + Self.monospacedFamilies.filter { $0 != BundledFonts.jetBrainsMono },
                                selection: Binding(get: { profile.fontFamily.isEmpty ? Self.sameFont : profile.fontFamily }, set: { profile.fontFamily = $0 == Self.sameFont ? "" : $0 }), width: 190)
                Stepper(value: Binding(get: { profile.fontSize > 0 ? profile.fontSize : preferences.codeFontSize }, set: { profile.fontSize = $0 }), in: 8...36, step: 1) {
                    Text("\(Int(profile.fontSize > 0 ? profile.fontSize : preferences.codeFontSize)) px").monospacedDigit()
                }
                if profile.fontSize > 0 { Button("Same as code") { profile.fontSize = 0 } }
            }
            HStack {
                Text("Cursor").frame(width: 90, alignment: .leading)
                QuietSegmented(options: TerminalCursorShape.allCases.map(\.rawValue), selection: Binding(get: { profile.cursor.rawValue }, set: { profile.cursor = TerminalCursorShape(rawValue: $0) ?? .block }))
                Toggle("Blink", isOn: $profile.cursorBlinks).toggleStyle(.checkbox)
            }
            Text("Colors").padding(.top, 2)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(TerminalColorScheme.all) { colorScheme in schemeTile(colorScheme) }
            }
            HStack(spacing: 12) {
                if !isDefault { Button("Make default") { makeDefault() } }
                Button("Duplicate") { duplicate() }
                Spacer()
                if canRemove { Button("Remove profile", role: .destructive) { remove() } }
            }.padding(.top, 4)
        }
        .padding(12)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onAppear { environmentText = TerminalProfile.formatEnvironment(profile.environment) }
    }
    private func field(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        HStack {
            Text(title).frame(width: 90, alignment: .leading)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
    }
    /// A small preview of a scheme: its background with a prompt line in its colors.
    private func schemeTile(_ colorScheme: TerminalColorScheme) -> some View {
        let palette = preferences.palette(scheme)
        let colors = colorScheme.resolved(appBackground: NSColor(palette.background), appForeground: NSColor(palette.foreground), appAccent: NSColor(palette.accent), appIsDark: scheme == .dark)
        let selected = profile.colorScheme == colorScheme.id
        return Button { profile.colorScheme = colorScheme.id } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 0) {
                    Text("~ ").foregroundStyle(Color(nsColor: colors.ansi[4]))
                    Text("git ").foregroundStyle(Color(nsColor: colors.foreground))
                    Text("main").foregroundStyle(Color(nsColor: colors.ansi[2]))
                    Text(" ✓").foregroundStyle(Color(nsColor: colors.ansi[3]))
                }.font(.system(size: 11, design: .monospaced))
                HStack(spacing: 2) { ForEach(1..<7) { Rectangle().fill(Color(nsColor: colors.ansi[$0])).frame(height: 4) } }
                Text(colorScheme.name).font(.system(size: 11)).foregroundStyle(Color(nsColor: colors.foreground).opacity(0.8)).lineLimit(1)
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: colors.background), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(selected ? palette.accent : Color.primary.opacity(0.12), lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .help(colorScheme.credit.isEmpty ? colorScheme.name : "\(colorScheme.name): based on \(colorScheme.credit)")
        .accessibilityLabel(colorScheme.name).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { profile.customFolder = url.path }
    }
}

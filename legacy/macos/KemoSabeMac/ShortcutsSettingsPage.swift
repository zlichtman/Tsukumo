import AppKit
import SwiftUI

/// Settings → Shortcuts: the app's keyboard shortcuts and the Apple Shortcuts Kemo may run,
/// on one page with a search field and two tabs.
struct ShortcutsSettingsPage: View {
    @State private var tab = "Keyboard"
    @State private var search = ""
    var body: some View {
        SettingsContent {
            HStack(spacing: 12) {
                QuietSegmented(options: ["Keyboard", "Apple Shortcuts"], selection: $tab).accessibilityIdentifier("shortcutsTabs")
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("Search", text: $search).textFieldStyle(.plain).frame(width: 150).accessibilityIdentifier("shortcutsSearch")
                }.padding(.horizontal, 10).padding(.vertical, 6).background(Color.primary.opacity(0.06), in: Capsule())
            }
            if tab == "Keyboard" { KeyboardShortcutsList(search: search) } else { AppleShortcutsList(search: search) }
        }
    }
}

/// Every key command in the app, grouped the way the menus are. Kept in step with
/// `KemoSabeMacApp.installMenu`, the composer, and the terminal.
struct KeyboardShortcutsList: View {
    struct Item: Identifiable { let title: String; let keys: [String]; var id: String { title } }
    struct Group: Identifiable { let name: String; let items: [Item]; var id: String { name } }
    let search: String
    static let groups: [Group] = [
        Group(name: "Chat", items: [Item(title: "New conversation", keys: ["⌘", "N"]), Item(title: "Send message", keys: ["Return"]), Item(title: "New line", keys: ["⇧", "Return"])]),
        Group(name: "Window", items: [Item(title: "Open Tsukumo", keys: ["⌘", "0"]), Item(title: "Show or hide companion", keys: ["⌘", "M"]), Item(title: "Settings", keys: ["⌘", ","]),
                                      Item(title: "Hide Tsukumo", keys: ["⌘", "H"]), Item(title: "Quit Tsukumo", keys: ["⌘", "Q"])]),
        Group(name: "Terminal", items: [Item(title: "New terminal tab", keys: ["⌘", "T"]), Item(title: "Close pane", keys: ["⌘", "W"]),
                                        Item(title: "Split right", keys: ["⌘", "D"]), Item(title: "Split down", keys: ["⌘", "⇧", "D"]),
                                        Item(title: "Move between panes", keys: ["⌘", "⌥", "←↑→↓"]), Item(title: "Even out splits", keys: ["⌘", "⌃", "="]),
                                        Item(title: "Find in terminal", keys: ["⌘", "F"]), Item(title: "Next and previous match", keys: ["⌘", "G / ⇧⌘G"]),
                                        Item(title: "Previous and next prompt", keys: ["⌘", "↑ / ↓"]), Item(title: "Select last command's output", keys: ["⌘", "⇧", "A"]),
                                        Item(title: "Switch tabs", keys: ["⌘", "1–9"]), Item(title: "Next and previous tab", keys: ["⌘", "⇧", "] / ["]),
                                        Item(title: "Clear terminal", keys: ["⌘", "K"]), Item(title: "Text size", keys: ["⌘", "+ / − / 0"]),
                                        Item(title: "Quick terminal (anywhere)", keys: ["⌥", "Space"])]),
        Group(name: "Editing", items: [Item(title: "Undo", keys: ["⌘", "Z"]), Item(title: "Cut", keys: ["⌘", "X"]), Item(title: "Copy", keys: ["⌘", "C"]),
                                       Item(title: "Paste", keys: ["⌘", "V"]), Item(title: "Select all", keys: ["⌘", "A"])])
    ]
    private var matching: [Group] {
        Self.groups.compactMap { group in
            let items = group.items.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || group.name.localizedCaseInsensitiveContains(search) }
            return items.isEmpty ? nil : Group(name: group.name, items: items)
        }
    }
    var body: some View {
        if matching.isEmpty { Text("No matching shortcuts.").foregroundStyle(.secondary) }
        ForEach(matching) { group in
            SettingsCard(title: group.name) {
                ForEach(group.items) { item in
                    if item.id != group.items.first?.id { Divider() }
                    SettingsRow(title: item.title) { KeyCaps(keys: item.keys) }
                }
            }
        }
    }
}

/// Keys drawn as small caps, one per key.
struct KeyCaps: View {
    let keys: [String]
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .frame(minWidth: 22, minHeight: 22).padding(.horizontal, key.count > 1 ? 6 : 0)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            }
        }.accessibilityElement(children: .ignore).accessibilityLabel(keys.joined(separator: " "))
    }
}

/// The Mac's own shortcuts (read with the system `shortcuts` tool), each with a switch that
/// lets Kemo run it by name. The allowed list is the permission; unlisted shortcuts never run.
struct AppleShortcutsList: View {
    let search: String
    @State private var shortcuts = ShortcutsIntegration.shared
    @State private var installed: [String]?
    var body: some View {
        let names = Array(Set((installed ?? []) + shortcuts.allowed)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }
        SettingsCard(title: "Allowed to run") {
            SettingsRow(title: "Ask KemoSabe to run a shortcut", detail: "Say or type “run shortcut” and its name. Only shortcuts switched on here can run, and Shortcuts runs them in its own app, so KemoSabe never sees what they do.") {
                Button("Open Shortcuts") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app")) }
            }
            if installed == nil {
                Divider(); SettingsRow(title: "Reading your shortcuts…") { EmptyView() }
            } else if names.isEmpty {
                Divider(); SettingsRow(title: search.isEmpty ? "No shortcuts yet" : "No matching shortcuts", detail: search.isEmpty ? "Make one in the Shortcuts app, then switch it on here." : nil) { EmptyView() }
            }
            ForEach(names, id: \.self) { name in
                Divider()
                SettingsRow(title: name, detail: installed?.contains(name) == false ? "Not found in Shortcuts on this Mac." : nil) {
                    Toggle(name, isOn: Binding(get: { shortcuts.match(name) != nil }, set: { $0 ? shortcuts.allow(name) : shortcuts.remove(name) }))
                        .labelsHidden().toggleStyle(.switch)
                }
            }
        }
        .task { installed = await Self.installedShortcuts() }
    }
    /// Names from `shortcuts list`, or an empty list if the tool isn't available.
    static func installedShortcuts() async -> [String] {
        await withCheckedContinuation { continuation in
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["list"]
            process.standardOutput = output; process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in
                let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                continuation.resume(returning: text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0.count <= 80 })
            }
            do { try process.run() } catch { continuation.resume(returning: []) }
        }
    }
}

import SwiftUI

struct DesktopCompanionSettings: View {
    @Environment(DesktopNavigation.self) private var desktop
    @Environment(AppStore.self) private var store
    @Environment(DesktopPreferences.self) private var preferences
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var palette = false
    @State private var developer = DeveloperMode.shared
    @State private var customName = ""
    @Environment(\.colorScheme) private var scheme
    @State private var bodyColor = Color(hex: "F5E7CF")
    @State private var accentColor = Color(hex: "EF705B")
    @State private var backgroundColor = Color(hex: "211B2C")
    @State private var characters: [CompanionCharacter] = []
    @State private var personalityRevision = 0
    @State private var choosingVoice = false
    var changed: () -> Void
    private var paletteChoices: [BotTheme] {
        ThemeShelf.visible + ThemeShelf.uniqueCustom(store.state.customThemes ?? [], currentID: store.state.theme.id)
    }
    private var customTheme: BotTheme {
        BotTheme(id: "preview", name: customName, body: bodyColor.hexValue, accent: accentColor.hexValue, background: backgroundColor.hexValue)
    }
    var body: some View {
        @Bindable var preferences = preferences
        SettingsContent {
            // The same order as Companion on iPhone: who it is, saved characters, colors, then this Mac's floating companion.
            SettingsCard(title: "Character") {
                HStack(spacing: 18) {
                    ArtworkCompanion(theme: store.state.theme, performance: navigation.performance.rawValue,
                        reducedMotion: preferences.followReduceMotion ? reduceMotion : preferences.reduceMotion,
                        active: desktop.windowVisible, replay: navigation.performanceRevision, framesPerSecond: 30)
                        .frame(width: 84, height: 84)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(CompanionIdentity.name).font(.system(size: 17, weight: .semibold))
                        Text([store.state.theme.name, CompanionIdentity.personality?.title].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding(.vertical, 14)
                Divider()
                SettingsRow(title: "Name", detail: "Used in chat, voice, the wake word, your watch, and here.") {
                    TextField("", text: $preferences.name, prompt: Text("Name your companion"))
                        .textFieldStyle(.plain).padding(.horizontal, 10).frame(width: 200, height: 30)
                        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
                        .accessibilityIdentifier("companionName")
                        .onChange(of: preferences.name) { if preferences.name.count > 24 { preferences.name = String(preferences.name.prefix(24)) } }
                }
                Divider()
                SettingsRow(title: "Personality", detail: "Changes the tone of replies, never what it can do or see.") {
                    QuietSegmented(options: ["Default"] + CompanionPersonality.allCases.map(\.title), selection: Binding(
                        get: { CompanionIdentity.personality?.title ?? "Default" },
                        set: { title in CompanionIdentity.setPersonality(CompanionPersonality.allCases.first { $0.title == title }); personalityRevision += 1 }))
                        .id(personalityRevision)
                }
                Divider()
                // Palettes show Kemo in each one, like the interface theme picker.
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Palette")
                        Spacer()
                        Button("All palettes") { palette = true }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityIdentifier("choosePalette")
                            .popover(isPresented: $palette, arrowEdge: .bottom) {
                                VStack(alignment: .leading, spacing: 14) {
                                    HStack {
                                        Text("Palettes").font(.system(size: 15, weight: .semibold))
                                        Spacer()
                                        Button { palette = false } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                                            .buttonStyle(DesktopRowButtonStyle()).accessibilityLabel("Close palettes")
                                    }
                                    CompanionPaletteGrid(themes: paletteChoices, selectedID: store.state.theme.id) { theme in
                                        store.state.theme = theme; store.save(); palette = false
                                    }.frame(height: 400)
                                }.padding(18).frame(width: 460).onExitCommand { palette = false }
                            }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(paletteChoices.prefix(10)) { theme in
                                let selected = theme.id == store.state.theme.id
                                Button { store.state.theme = theme; store.save() } label: {
                                    VStack(spacing: 4) {
                                        CompanionAvatar(theme: theme, size: 44)
                                            .overlay(Circle().strokeBorder(selected ? preferences.palette(scheme).accent : .clear, lineWidth: 2).padding(-3))
                                        Text(theme.name).font(.system(size: 10)).foregroundStyle(selected ? .primary : .secondary).lineLimit(1).frame(width: 56)
                                    }
                                }.buttonStyle(.plain).accessibilityLabel(theme.name).accessibilityAddTraits(selected ? .isSelected : [])
                            }
                        }.padding(.vertical, 4).padding(.horizontal, 3)
                    }
                }.padding(.vertical, 12)
                Divider()
                // Saving sits with what it saves, like Save palette below.
                SettingsRow(title: "Save as a character", detail: "Keeps this name, palette, and personality to switch back in one click.") {
                    Button("Save character") {
                        let character = CompanionCharacter(name: CompanionIdentity.name, theme: store.state.theme, personality: CompanionIdentity.personality)
                        characters = CompanionCharacters.upsert(character, into: characters.filter { !CompanionCharacterSwitch.isActive($0, theme: store.state.theme) })
                        CompanionCharacters.save(characters)
                    }.accessibilityIdentifier("saveCharacter")
                }
            }
            // Which voice it sounds like, the one voice choice; the voice models are always the best
            // this Mac can run (`VoiceAuto`).
            SettingsCard(title: "Voice") {
                SettingsRow(title: "\(CompanionIdentity.name)'s voice", detail: "Pace, listening, read aloud, and the voice models.") {
                    Button(SpeechVoices.shared.persona.title(neuralSupported: SpeechVoices.shared.device.neuralSupported) + "…") { choosingVoice = true }
                        .accessibilityIdentifier("openVoiceSettings")
                        .sheet(isPresented: $choosingVoice) { MacVoiceSettings().environment(store) }
                }
            }
            if !characters.isEmpty {
                SettingsCard(title: "Your characters") {
                    ForEach(Array(characters.enumerated()), id: \.element.id) { index, character in
                        if index > 0 { Divider() }
                        Button { CompanionCharacterSwitch.apply(character, store: store); preferences.name = CompanionIdentity.name; personalityRevision += 1 } label: {
                            HStack(spacing: 12) {
                                CompanionAvatar(theme: character.theme, size: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(character.name)
                                    Text([character.theme.name, character.personality?.title].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if CompanionCharacterSwitch.isActive(character, theme: store.state.theme) { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }.padding(.vertical, 8).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .contextMenu { Button("Delete character", role: .destructive) { characters.removeAll { $0.id == character.id }; CompanionCharacters.save(characters) } }
                    }
                }
            }
            SettingsCard(title: "Make a palette") {
                HStack(spacing: 14) {
                    CompanionAvatar(theme: customTheme, size: 52)
                    TextField("", text: $customName, prompt: Text("Palette name"))
                        .textFieldStyle(.plain).padding(.horizontal, 10).frame(height: 30)
                        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
                }.padding(.vertical, 12)
                Divider()
                SettingsRow(title: "Body") { ColorPill(title: "Body", color: bodyColor) { bodyColor = $0 } }
                Divider()
                SettingsRow(title: "Accent") { ColorPill(title: "Accent", color: accentColor) { accentColor = $0 } }
                Divider()
                SettingsRow(title: "Background") { ColorPill(title: "Background", color: backgroundColor) { backgroundColor = $0 } }
                Divider()
                SettingsRow(title: "Save to your palettes", detail: "Adds it to your palettes and uses it now.") {
                    Button("Save palette") {
                        let theme = BotTheme(id: "custom-" + UUID().uuidString, name: String(customName.trimmingCharacters(in: .whitespaces).prefix(40)), body: bodyColor.hexValue, accent: accentColor.hexValue, background: backgroundColor.hexValue)
                        store.state.customThemes = (store.state.customThemes ?? []) + [theme]; store.state.theme = theme; store.save()
                    }.disabled(customName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            SettingsCard(title: "Desktop companion") {
                SettingsRow(title: "Size") { HStack { Slider(value: $preferences.size, in: 56...112, step: 4).frame(width: 160).accessibilityIdentifier("companionSize"); Text("\(Int(preferences.size))").monospacedDigit().frame(width: 28) } }
                Divider()
                SettingsRow(title: "Opacity") { Slider(value: $preferences.opacity, in: 0.5...1, step: 0.05).frame(width: 200).accessibilityLabel("Companion opacity") }
                Divider()
                SettingsRow(title: "Display style") {
                    Picker("Display style", selection: Binding(get: { preferences.characterOnly ? "Character only" : preferences.showName ? "Name badge" : "Compact badge" }, set: { value in
                        preferences.characterOnly = value == "Character only"; preferences.showName = value == "Name badge"; changed()
                    })) { Text("Character only").tag("Character only"); Text("Compact badge").tag("Compact badge"); Text("Name badge").tag("Name badge") }.labelsHidden().frame(width: 160)
                }
                Divider()
                SettingsRow(title: "Animate while floating") { Toggle("Animate while floating", isOn: $preferences.animate).labelsHidden() }
                Divider()
                SettingsRow(title: "All desktops", detail: "Keep the companion with you across Spaces.") { Toggle("All desktops", isOn: $preferences.showOnAllSpaces).labelsHidden() }
            }
            Text("Click \(CompanionIdentity.name) in the sidebar to show or hide the companion. Drag to move it; right-click for options.").font(.caption).foregroundStyle(.secondary)
            if developer.enabled {
                DeveloperSection {
                    HStack { Text("Animation gallery"); Spacer(); Button("Open…") { desktop.settingsPage = "Animations" }.accessibilityIdentifier("openAnimations") }
                    HStack { Text("Developer settings"); Spacer(); Button("Turn off") { developer.enabled = false } }
                }
            }
        }.toggleStyle(.switch)
        .onAppear { characters = CompanionCharacters.load() }
        .onChange(of: preferences.size) { changed() }.onChange(of: preferences.showName) { changed() }
        .onChange(of: preferences.showOnAllSpaces) { changed() }.onChange(of: preferences.characterOnly) { changed() }
    }
}

struct DesktopConnectionsView: View {
    @Environment(AppStore.self) private var store
    @Environment(ConnectorStore.self) private var connectors
    @State private var requested: ConnectorID?
    var body: some View {
        SettingsContent {
            SettingsCard(title: "Apple connections") {
                ForEach(Array([ConnectorID.calendar, .reminders, .contacts].enumerated()), id: \.element) { index, id in
                    if index > 0 { Divider() }
                    SettingsRow(title: id.title, detail: connectors.status(id, state: store.state).guidance(for: id) ?? connectors.status(id, state: store.state).rawValue) {
                        if connectors.status(id, state: store.state).usable {
                            Button("Disconnect") { _ = connectors.disconnect(id, store: store) }
                        } else { Button("Connect") { requested = id }.disabled(connectors.authorizing != nil) }
                    }
                }
            }
            Text("Choose which services KemoSabe can use on this Mac. Apple requests permission when you connect. Contacts are read-only; calendar and reminder changes need a reviewed proposal or an exact standing grant.").font(.caption).foregroundStyle(.secondary)
            if let message = connectors.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            // Messages on this Mac: Full Disk Access, then the owner's switch (MacMessagesSource.swift).
            MacMessagesSettingsCard()
            // Claude Code, Codex, and Muse asking KemoSabe through its MCP server, and who may.
            KemoSabeMCPConnectionsCards()
            SettingsCard(title: "Custom connections") {
                SettingsRow(title: "Model endpoints", detail: "Connect a compatible API or local server under Language models. Each has its own conversation history.") { Image(systemName: "cpu").foregroundStyle(.secondary) }
                Divider()
                SettingsRow(title: "MCP services", detail: "Custom tool servers and OAuth connections are planned. No service is connected or given access yet.") { Text("Planned").foregroundStyle(.secondary) }
            }
            Text("Model endpoints, native data sources, and coding applications are separate connections. Adding one does not give it access to the others.").font(.caption).foregroundStyle(.secondary)
        }.onAppear { connectors.refresh() }
            .confirmationDialog("Connect on this Mac?", isPresented: Binding(get: { requested != nil }, set: { if !$0 { requested = nil } }), titleVisibility: .visible) {
                if let id = requested { Button("Connect " + id.title) { Task { _ = await connectors.connect(id, store: store) }; requested = nil } }
            } message: { Text("KemoSabe will ask macOS for access. Calendar and Reminders can include accounts that synchronize through iCloud or another provider. Private reasoning stays out of event titles.") }
    }
}

struct DesktopMemoryEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var note: MemoryNote
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Memory").font(.title2.bold()); Spacer(); Button("Cancel") { dismiss() }; Button("Save") { store.saveMemory(note); if store.storageError == nil { dismiss() } }.disabled(note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || note.text.count > 1000) }
            TextEditor(text: $note.text).font(.body).frame(minHeight: 180).accessibilityIdentifier("memoryText")
            Text("\(note.text.count)/1,000 characters").font(.caption).foregroundStyle(.secondary)
            Picker("Label", selection: $note.scope) { ForEach(["Personal","Company","Industry"], id: \.self) { Text($0).tag($0) } }
            // Secret is "Not used in chat"; the other levels say which models may read it.
            PrivacyLevelPicker(level: $note.privacyLevel)
        }.padding(24).frame(width: 540, height: 400)
    }
}

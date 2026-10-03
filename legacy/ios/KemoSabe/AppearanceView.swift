import SwiftUI

/// Character colors never change the app interface palette.
struct ThemeView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            CharacterAppearancePage().toolbar { ToolbarItem(placement: .confirmationAction) { Button(role: .close) { dismiss() } } }
        }
    }
}

struct CharacterAppearancePage: View {
    @Environment(AppStore.self) private var store
    @Environment(\.mobilePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var choosing = false
    @State private var editing: BotTheme?
    @State private var developer = DeveloperMode.shared
    @AppStorage(CompanionIdentity.key, store: AccountDirectory.accountSettings) private var storedName = CompanionIdentity.defaultName
    @AppStorage(CompanionIdentity.personalityKey, store: AccountDirectory.accountSettings) private var storedPersonality = ""
    @State private var name = ""
    @State private var characters: [CompanionCharacter] = []
    @State private var making = false
    var body: some View {
        Form {
            Section {
                // Paged like the watch's face-style editor: swipe between Color and Tone.
                CharacterFaceCard()
            }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            Section {
                TextField(CompanionIdentity.defaultName, text: $name)
                    .textInputAutocapitalization(.words).autocorrectionDisabled().submitLabel(.done)
                    .onSubmit { CompanionIdentity.set(name); name = CompanionIdentity.name }
                    .onChange(of: name) { if name.count > CompanionIdentity.maxLength { name = String(name.prefix(CompanionIdentity.maxLength)) } }
                    .accessibilityIdentifier("companionName")
                Picker("Personality", selection: Binding(get: { storedPersonality }, set: { CompanionIdentity.setPersonality(CompanionPersonality(rawValue: $0)) })) {
                    Text("Default").tag("")
                    ForEach(CompanionPersonality.allCases) { Text($0.title).tag($0.rawValue) }
                }.accessibilityIdentifier("companionPersonality")
            } header: { Text("Name") } footer: {
                Text("Chat, voice, the wake word, your watch, and the Mac companion all use this name.")
            }
            // Which voice it sounds like, pace, and listening. The voice models are always the best
            // this iPhone can run, so there's nothing to choose there.
            Section("Voice") {
                NavigationLink { VoiceSettingsView(embeddedInAppearance: true) } label: {
                    LabeledContent("Voice") { Text(SpeechVoices.shared.persona.title(neuralSupported: SpeechVoices.shared.device.neuralSupported)) }
                }.accessibilityIdentifier("openVoiceSettings")
            }
            Section("Characters") {
                ForEach(characters) { character in
                    Button { CompanionCharacterSwitch.apply(character, store: store); name = CompanionIdentity.name } label: {
                        HStack(spacing: 12) {
                            CompanionAvatar(theme: character.theme, size: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(character.name).foregroundStyle(.primary)
                                Text([character.theme.name, character.personality?.title].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if CompanionCharacterSwitch.isActive(character, theme: store.state.theme) {
                                Image(systemName: "checkmark").foregroundStyle(palette.accent)
                            }
                        }
                    }.accessibilityIdentifier("character-" + character.name)
                }
                .onDelete { offsets in
                    characters.remove(atOffsets: offsets); CompanionCharacters.save(characters)
                }
                Button("New character", systemImage: "wand.and.stars") { making = true }
                    .accessibilityIdentifier("newCharacter")
            }
            Section("Character palette") {
                Button { choosing = true } label: {
                    HStack { Text("Palette").foregroundStyle(.primary); Spacer(); CompanionAvatar(theme: store.state.theme, size: 28); Text(store.state.theme.name).foregroundStyle(.secondary); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                }.accessibilityIdentifier("openThemeDrawer").accessibilityValue(store.state.theme.name)
                Button("Create custom palette", systemImage: "plus") {
                    var theme = store.state.theme; theme.id = "custom-" + UUID().uuidString; theme.name = "My KemoSabe"; editing = theme
                }.accessibilityIdentifier("customColors")
            }
            Section { Text("Colors apply to KemoSabe only. Change interface colors and fonts in Appearance.").font(.footnote).foregroundStyle(.secondary) }
            if developer.enabled {
                // Debugging tools, only after the About Easter egg.
                Section {
                    NavigationLink { AnimationGallery(embedded: true) } label: { Label("Animations", systemImage: "play.rectangle") }
                        .accessibilityIdentifier("openAnimations")
                    Button("Turn off developer settings") { developer.enabled = false }
                        .accessibilityIdentifier("turnOffDeveloper")
                } header: { DeveloperHeader() } footer: {
                    Text("Every performance in the suite, for checking motion and props.").font(.system(.caption, design: .monospaced))
                }
                .font(.system(.body, design: .monospaced))
                .tint(DeveloperSection<EmptyView>.accent)
                .listRowBackground(DeveloperSection<EmptyView>.accent.opacity(0.09))
            }
        }.scrollContentBackground(.hidden).background(palette.background)
            .navigationTitle("Companion").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $choosing) { ThemePickerDrawer() }
            .sheet(item: $editing) { CustomPaletteEditor(draft: $0) }
            .sheet(isPresented: $making, onDismiss: refresh) { CharacterMaker() }
            .onAppear(perform: refresh)
            .onDisappear { if !name.trimmingCharacters(in: .whitespaces).isEmpty, name != CompanionIdentity.name { CompanionIdentity.set(name) } }
            .onChange(of: storedName) { name = CompanionIdentity.name }
    }
    private func refresh() { characters = CompanionCharacters.load(); name = CompanionIdentity.name }
}

private struct ThemePickerDrawer: View {
    @Environment(\.mobilePalette) private var palette
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editing: BotTheme?
    private var custom: [BotTheme] {
        var saved = store.state.customThemes ?? []
        if !BotTheme.presets.contains(where: { $0.id == store.state.theme.id }),
           !saved.contains(where: { $0.id == store.state.theme.id }) { saved.append(store.state.theme) }
        return ThemeShelf.uniqueCustom(saved, currentID: store.state.theme.id)
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(ThemeShelf.visible + custom) { theme in
                            if theme.id.hasPrefix("custom-") {
                                ZStack(alignment: .bottomTrailing) {
                                    themeButton(theme)
                                    Button { editing = theme } label: {
                                        Image(systemName: "pencil").font(.system(size: 12, weight: .bold)).frame(width: 30, height: 30)
                                            .background(.ultraThinMaterial, in: Circle())
                                    }.buttonStyle(.plain).padding(8).padding(.bottom, 22).accessibilityLabel("Edit " + theme.name)
                                }.contextMenu { Button("Edit palette") { editing = theme } }
                            } else { themeButton(theme) }
                        }
                    }
                }.padding(16).frame(maxWidth: 700).frame(maxWidth: .infinity)
            }
            .background(palette.background.ignoresSafeArea())
            .navigationTitle("Choose a palette").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) {
                Button(role: .close) { dismiss() }
                    .accessibilityLabel("Close palettes").accessibilityIdentifier("closeThemeDrawer")
            } }
            .sheet(item: $editing) { CustomPaletteEditor(draft: $0) }
        }.presentationDetents([.large])
            .presentationBackground(palette.background)
            .sensoryFeedback(.selection, trigger: store.state.theme.id)
    }
    private var columns: [GridItem] {
        typeSize.isAccessibilitySize ? [.init(.flexible())] : [.init(.adaptive(minimum: 104), spacing: 12)]
    }
    private func themeButton(_ theme: BotTheme) -> some View {
        let selected = store.state.theme.id == theme.id
        return Button {
            store.state.theme = theme; store.save(); dismiss()
        } label: {
            // Kemo in the palette, as the interface theme tiles show the theme.
            CompanionPaletteTile(theme: theme, selected: selected, height: typeSize.isAccessibilitySize ? 150 : 110)
                .padding(.trailing, 0)
        }.buttonStyle(ThemePressStyle()).accessibilityLabel(theme.name + " theme")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityValue(selected ? "Selected" : "Not selected").accessibilityIdentifier("theme-" + theme.id)
    }
}


private struct ThemePressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(!reduceMotion && configuration.isPressed ? 0.97 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

struct CustomPaletteEditor: View {
    @Environment(\.mobilePalette) private var palette
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State var draft: BotTheme
    @State private var deleting = false
    private var existing: Bool { store.state.customThemes?.contains { $0.id == draft.id } == true }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    ArtworkCompanion(theme: draft, reducedMotion: reduceMotion).frame(height: 220)
                        .background(draft.backgroundColor, in: RoundedRectangle(cornerRadius: 28))
                    VStack(alignment: .leading, spacing: 16) {
                        Eyebrow(text: "Palette name")
                        TextField("My KemoSabe", text: $draft.name).textInputAutocapitalization(.words).accessibilityIdentifier("paletteName")
                        Divider()
                        picker("Body", key: \.body)
                        picker("Eyes & smile", key: \.accent)
                        picker("Atmosphere", key: \.background)
                    }.padding(20).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 22))
                    Text("Atmosphere is the character preview background. Choose eyes that stand out from the body. Changes are applied only when you save.").font(KemoType.font(.caption)).foregroundStyle(.secondary)
                    if existing { Button("Delete palette", role: .destructive) { deleting = true } }
                }.padding(22).frame(maxWidth: 600).frame(maxWidth: .infinity)
            }.background(palette.background.ignoresSafeArea())
                .navigationTitle(existing ? "Edit palette" : "Custom colors").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") {
                        draft.name = String(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
                        var themes = store.state.customThemes ?? []
                        if !existing, let same = themes.first(where: { ThemeShelf.signature($0) == ThemeShelf.signature(draft) }) { draft.id = same.id }
                        themes.removeAll { $0.id == draft.id }; themes.append(draft)
                        store.state.customThemes = themes; store.state.theme = draft; store.save(); dismiss()
                    }.disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("savePalette") }
                }
                .confirmationDialog("Delete this custom palette?", isPresented: $deleting, titleVisibility: .visible) {
                    Button("Delete palette", role: .destructive) {
                        let signature = ThemeShelf.signature(draft)
                        store.state.customThemes?.removeAll { ThemeShelf.signature($0) == signature }
                        if ThemeShelf.signature(store.state.theme) == signature { store.state.theme = BotTheme.presets[0] }
                        store.save(); dismiss()
                    }
                }
        }
        .onAppear { navigation.voiceBlocks.insert("paletteEditor") }
        .onDisappear { navigation.voiceBlocks.remove("paletteEditor") }
    }
    private func picker(_ label: String, key: WritableKeyPath<BotTheme, String>) -> some View {
        ColorPicker(label, selection: Binding(get: { Color(hex: draft[keyPath: key]) }, set: { color in
            let hex = color.hexValue
            draft[keyPath: key] = key == \.background ? Self.darkAtmosphere(hex) : hex
        }), supportsOpacity: false)
    }
    static func darkAtmosphere(_ hex: String) -> String {
        let n = UInt32(hex, radix: 16) ?? 0
        let channels = [Int((n >> 16) & 255), Int((n >> 8) & 255), Int(n & 255)]
        let factor = min(1, 88.0 / Double(max(channels.max() ?? 1, 1)))
        return channels.map { String(format: "%02X", Int(Double($0) * factor)) }.joined()
    }
}

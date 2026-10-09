import SwiftUI
import TsukumoCore
import TsukumoVoice

// KemoSabe's settings, the same on iPhone and Mac: its character (its cloud, or the Finder figure), its companion palette
// (its cloud, or the figure's two halves, recolored), and its voice. The clay characters' editors (look, personality, dock size and ring) were removed with the
// fixed lineup (October 7, 2026).

// MARK: KemoSabe

/// KemoSabe's settings: its companion palette, and nothing else to change. It is always its look, its
/// name, Apple's on-device model on this device, and the scope the Gate gives it. `note` says where its
/// privacy settings live on this device.
public struct KemoSabeEditor: View {
    @State private var bot: BotSpec
    let device: String
    let note: String?
    let more: AnyView?
    @Environment(\.voice) private var voice
    let onSave: (BotSpec) -> Void
    let onCancel: () -> Void

    public init(bot: BotSpec, device: String, note: String? = nil, more: AnyView? = nil,
                onSave: @escaping (BotSpec) -> Void, onCancel: @escaping () -> Void) {
        _bot = State(initialValue: bot.normalized())
        self.device = device; self.note = note; self.more = more; self.onSave = onSave; self.onCancel = onCancel
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    KemoSabeHeader(bot: bot, device: device)
                }
                Section {
                    KemoSabeCharacterPicker(bot: $bot).padding(.vertical, 6)
                } header: {
                    Text("Character")
                }
                Section {
                    KemoSabePalettePicker(bot: $bot, minimum: 72, tileHeight: 76)
                        .padding(.vertical, 6)
                } header: {
                    Text("Palette")
                } footer: {
                    Text(KemoSabePalettePicker.footer(name: bot.name, device: device))
                }
                Section {
                    VoicePicker(bot: $bot)
                } header: {
                    Text("Voice")
                } footer: {
                    Text(VoicePicker.footer(voice: voice, device: device))
                }
                if let more { more }
                if let note {
                    Section { Text(note).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle(bot.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(bot.normalized()) }.fontWeight(.semibold).accessibilityIdentifier("saveBot")
                }
            }
        }
        .accessibilityIdentifier("kemoSabeEditor")
    }
}

/// KemoSabe in its palette on the palette's own background, its name, and what it is.
public struct KemoSabeHeader: View {
    let bot: BotSpec
    let device: String
    var side: CGFloat
    public init(bot: BotSpec, device: String, side: CGFloat = 132) { self.bot = bot; self.device = device; self.side = side }
    public var body: some View {
        let palette = bot.kemoSabePalette
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(LinearGradient(colors: [palette.backgroundRGB.color, palette.backgroundRGB.color.opacity(0.82)], startPoint: .top, endPoint: .bottom))
                Circle().strokeBorder(bot.kemoSabeColor.opacity(0.75), lineWidth: 2)
                KemoSabeFigure(bot: bot, shadow: false).padding(side * 0.08)
            }
            .frame(width: side, height: side)
            .accessibilityElement()
            .accessibilityLabel("\(bot.name) in \(palette.name)")
            .accessibilityIdentifier("kemoSabePreview")
            Text(bot.name).font(.title2.weight(.semibold))
            Label("Your secure assistant · Apple on-device", systemImage: "lock.shield")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }
}

/// KemoSabe's look (its cloud or the two-tone figure), then its companion palettes as tiles, KemoSabe in each;
/// picking either changes it everywhere.
public struct KemoSabePalettePicker: View {
    @Binding var bot: BotSpec
    var minimum: CGFloat
    var tileHeight: CGFloat
    public init(bot: Binding<BotSpec>, minimum: CGFloat = 96, tileHeight: CGFloat = 92) {
        _bot = bot; self.minimum = minimum; self.tileHeight = tileHeight
    }
    public var body: some View {
        CompanionPaletteGrid(selectedID: bot.kemoSabePalette.id, minimum: minimum, tileHeight: tileHeight, look: bot.kemoSabeLook) { palette in
            bot.look = .kemoSabe(palette: palette.id, figure: bot.look.figure)
        }
    }
    /// What the palette colors, under the grid.
    public static func footer(name: String, device: String) -> String {
        "\(name) everywhere it appears, and its card, ring, and buttons in your chats. It always runs on Apple’s on-device model on this \(device)."
    }
}

/// KemoSabe's character: each one drawn as it looks, the picked one ringed. Picking one moves KemoSabe to that
/// character's own palette when it's in the other's (Apricot for the cloud, Classic for Finder); any other palette stays.
public struct KemoSabeCharacterPicker: View {
    @Binding var bot: BotSpec
    @Environment(\.colorScheme) private var scheme
    public init(bot: Binding<BotSpec>) { _bot = bot }
    public var body: some View {
        let theme = TsukumoTheme(scheme)
        HStack(spacing: 10) {
            ForEach(KemoSabeLook.allCases) { look in
                let selected = bot.kemoSabeLook == look
                Button { choose(look) } label: {
                    VStack(spacing: 6) {
                        KemoSabeFigure(palette: selected ? bot.kemoSabePalette : .named(look.defaultPalette), mood: .idle, look: look)
                            .frame(width: 64, height: 64)
                        Text(look.title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                    }
                    .padding(10).frame(maxWidth: 120)
                    .background(theme.ink.opacity(selected ? 0.07 : 0.03), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay { if selected { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.accent, lineWidth: 1.5) } }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(look.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("kemoSabeCharacter-" + look.rawValue)
            }
            Spacer(minLength: 0)
        }
    }
    private func choose(_ look: KemoSabeLook) {
        let palette = bot.kemoSabePalette.id
        let other = KemoSabeLook.allCases.first { $0 != look }?.defaultPalette
        bot.look = .kemoSabe(palette: palette == other ? look.defaultPalette : palette, figure: look)
    }
}

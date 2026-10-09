import ImageIO
import SwiftUI
import TsukumoCore

// A bot's character (October 8, 2026, the owner: "everyone has their own Codex pet; whatever theirs is should be able
// to appear on the side"): on a bot that runs on Codex, one of the owner's Codex pets acting out the bot's state, drawn
// from Codex on this Mac (`CodexPets`), or on a device without it the pet's small still picture that synced with the
// bot; or one of Tsukumo's own characters (`CodexPets.tsukumo`), on any bot; else its service's mark, or its engine's.
// KemoSabe is never a pet: it's its own figure.

public extension EnvironmentValues {
    /// The owner's Codex pets on this device (a Mac with Codex), for drawing bots' characters. Empty elsewhere.
    @Entry var codexPets: [CodexPet] = []
}

/// A bot as its character, at `size`.
public struct BotCharacterView: View {
    public let bot: BotSpec
    public var state: BotState
    public var size: CGFloat
    /// False holds a pet on its first frame.
    public var animated: Bool
    @Environment(\.codexPets) private var pets
    @Environment(\.engineInfo) private var engineInfo
    @Environment(\.colorScheme) private var scheme

    public init(bot: BotSpec, state: BotState = .idle, size: CGFloat, animated: Bool = true) {
        self.bot = bot; self.state = state; self.size = size; self.animated = animated
    }

    /// Whether a bot's character acts out its state (a pet drawn from its sheet), so a tile needs no bubble for it.
    public static func actsOut(_ bot: BotSpec, pets: [CodexPet]) -> Bool {
        pet(of: bot, in: pets).map(CodexPets.canDraw) ?? false
    }
    static func pet(of bot: BotSpec, in pets: [CodexPet]) -> CodexPet? {
        guard !bot.isKemoSabe, let id = bot.look.pet else { return nil }
        return CodexPets.tsukumo.first { $0.id == id } ?? pets.first { $0.id == id }
    }

    public var body: some View {
        Group {
            if bot.isKemoSabe {
                KemoSabeFace(palette: bot.kemoSabePalette, look: bot.kemoSabeLook)
            } else if let pet = Self.pet(of: bot, in: pets), CodexPets.canDraw(pet) {
                CodexPetView(pet: pet, state: state, still: !animated)
            } else if let still = bot.look.petImage.flatMap(Self.image) {
                still.resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else if let service = bot.service {
                ServiceMarkView(service, size: size)
            } else {
                EngineMarkView(engineInfo(bot.engine).mark, size: size * 0.6)
                    .frame(width: size, height: size)
                    .background(TsukumoTheme(scheme).fill, in: Circle())
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// A pet's still picture (PNG) as an image.
    static func image(_ data: Data) -> Image? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return Image(decorative: image, scale: 1)
    }
}

/// Picks a bot's character: its service's mark, one of Tsukumo's own characters, or (on a bot that runs on Codex) one
/// of the owner's Codex pets, with a way to hatch a new one in Codex (on a Mac). The pet the bot already wears stays
/// offered even where Codex isn't.
public struct BotCharacterPicker: View {
    @Binding var look: BotLook
    let service: ServiceID?
    let pets: [CodexPet]
    let allowsPets: Bool
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var scheme

    /// `allowsPets`: the bot runs on Codex (`BotSpec.wearsCodexPets`); Codex pets stay on Codex bots.
    public init(look: Binding<BotLook>, service: ServiceID?, pets: [CodexPet], allowsPets: Bool = true) {
        _look = look; self.service = service; self.pets = CodexPets.tsukumo + (allowsPets ? pets : []); self.allowsPets = allowsPets
    }

    public var body: some View {
        let theme = TsukumoTheme(scheme)
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 58, maximum: 76), spacing: 8)], alignment: .leading, spacing: 8) {
                tile(selected: look.pet == nil, title: service?.title ?? "Its mark") {
                    if let service { ServiceMarkView(service, size: 34) } else { Image(systemName: "circle.dashed").font(.system(size: 24)).foregroundStyle(theme.secondary) }
                } action: {
                    look = BotLook()
                }
                .accessibilityIdentifier("characterMark")
                if let current = look.pet, !pets.contains(where: { $0.id == current }) {
                    tile(selected: true, title: look.petName ?? "Its pet") {
                        if let still = look.petImage.flatMap(BotCharacterView.image) { still.resizable().interpolation(.high).aspectRatio(contentMode: .fit) }
                        else { Image(systemName: "pawprint").font(.system(size: 22)).foregroundStyle(theme.secondary) }
                    } action: {}
                }
                ForEach(pets) { pet in
                    tile(selected: look.pet == pet.id, title: pet.name) {
                        CodexPetView(pet: pet, state: .idle, still: true)
                    } action: {
                        look = .pet(pet.id, name: pet.name, image: CodexPets.avatarPNG(pet, side: 96))
                    }
                    .help(pet.description.isEmpty ? pet.name : pet.name + ": " + pet.description)
                    .accessibilityIdentifier("characterPet-" + pet.id)
                }
            }
            #if os(macOS)
            if allowsPets {
            HStack(spacing: 8) {
                Button { openURL(CodexPets.hatchLink()) } label: { Label("Hatch a New Pet in Codex…", systemImage: "sparkles") }
                    .controlSize(.small).accessibilityIdentifier("characterHatch")
                Text(pets.isEmpty ? "No Codex pets on this Mac yet." : "New pets show here once Codex hatches them.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            }
            #endif
        }
    }

    private func tile(selected: Bool, title: String, @ViewBuilder _ art: () -> some View, action: @escaping () -> Void) -> some View {
        let theme = TsukumoTheme(scheme)
        return Button(action: action) {
            VStack(spacing: 3) {
                art().frame(width: 40, height: 40)
                Text(title).font(.system(size: 10.5)).lineLimit(1).foregroundStyle(theme.secondary)
            }
            .padding(6).frame(maxWidth: .infinity)
            .background(theme.ink.opacity(selected ? 0.08 : 0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay { if selected { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.accent, lineWidth: 1.5) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

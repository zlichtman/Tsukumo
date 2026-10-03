import SwiftUI
import TsukumoCore

// The pieces both bot editors share (the iPhone's `BotEditor` and the Mac dock's `DockBotForm`), so a bot
// is customized the same way everywhere: a live preview, then rows of options drawn as the character
// itself (its body, eyes, expression, topper, accessory, and prop), swatches for its colors, and
// KemoSabe's one setting, its color.

/// A bot's character, live, as its editor shows it: the clay character at its dock size over its ring.
public struct BotLookPreview: View {
    public let look: BotLook
    public var engine: EngineID?
    public var side: CGFloat
    public var animated: Bool
    @Environment(\.colorScheme) private var scheme

    public init(look: BotLook, engine: EngineID? = nil, side: CGFloat = 132, animated: Bool = true) {
        self.look = look; self.engine = engine; self.side = side; self.animated = animated
    }

    public var body: some View {
        ZStack {
            Circle().fill(BotPalette.named(look.palette).backgroundRGB.color.opacity(scheme == .dark ? 0.6 : 0.12))
            if let ring = look.ringColor(engineHex: engine.map(EngineColor.hex) ?? EngineColor.hex(.unknown(""))) {
                Ellipse().strokeBorder(ring.opacity(0.85), lineWidth: max(1.5, side * 0.03))
                    .frame(width: side * 0.56, height: side * 0.15).offset(y: side * 0.36)
            }
            ClayCharacter(look: look, state: .idle, animated: animated)
                .frame(width: side * 0.9 * look.scale, height: side * 0.9 * look.scale)
                .offset(y: side * 0.05 * (1 - look.scale))
        }
        .frame(width: side, height: side)
        .accessibilityElement()
        .accessibilityLabel("Character preview")
        .accessibilityValue(Self.describe(look))
        .accessibilityIdentifier("lookPreview")
    }

    /// The character in words, for VoiceOver and tests: "Mochi, Lavender, Sparkle eyes, Big grin, Bow tie, Pencil".
    public static func describe(_ look: BotLook) -> String {
        var words = [look.shape.title, BotTint.named(hex: look.bodyColor)?.name ?? BotPalette.named(look.palette).name,
                     look.eyes.title + " eyes", look.expression.title]
        if look.topper != .none { words.append(look.topper.title) }
        if look.accessory != .none { words.append(look.accessory.title) }
        if look.prop != .none { words.append(look.prop.title) }
        if let accent = BotTint.named(hex: look.accentColor) { words.append(accent.name + " accent") }
        return words.joined(separator: ", ")
    }
}

/// Each engine's color, for the ring at a bot's feet (the dock's `DockEngineColor` reads these).
public enum EngineColor {
    public static func hex(_ engine: EngineID) -> String {
        switch engine {
        case .appleOnDevice: "EF705B"
        case .codingAgent("claude-code"): "D97757"
        case .codingAgent("codex"): "10A37F"
        case .codingAgent("muse"): "0866FF"
        case .codingAgent("cursor-agent"): "7A808A"
        case .api: "D97757"
        case .mlx: "4B9C8E"
        default: "8B5CF6"
        }
    }
}

/// One row of choices, each drawn as the character wearing it.
public struct LookOptionRow<Option: Hashable & Identifiable>: View {
    let title: String
    let options: [Option]
    let selected: Option
    let label: (Option) -> String
    let apply: (Option, inout BotLook) -> Void
    let look: BotLook
    let identifier: String
    let choose: (Option) -> Void
    var tile: CGFloat
    @Environment(\.colorScheme) private var scheme

    /// `apply` puts an option on a copy of `look` for its tile; `choose` picks it.
    public init(_ title: String, options: [Option], selected: Option, look: BotLook, identifier: String, tile: CGFloat = 44,
                label: @escaping (Option) -> String, apply: @escaping (Option, inout BotLook) -> Void, choose: @escaping (Option) -> Void) {
        self.title = title; self.options = options; self.selected = selected; self.look = look; self.identifier = identifier
        self.tile = tile; self.label = label; self.apply = apply; self.choose = choose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.footnote).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(options) { option in
                        let on = option == selected
                        Button { choose(option) } label: {
                            VStack(spacing: 3) {
                                ClayCharacter(look: tileLook(option), shadow: false).frame(width: tile, height: tile)
                                Text(label(option)).font(.caption2).lineLimit(1).foregroundStyle(on ? .primary : .secondary)
                            }
                            .frame(width: tile + 18)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(on ? TsukumoTheme(scheme).accent.opacity(0.16) : Color.primary.opacity(0.04)))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(on ? TsukumoTheme(scheme).accent.opacity(0.7) : .clear, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(label(option))
                        .accessibilityAddTraits(on ? .isSelected : [])
                        .accessibilityIdentifier(identifier + "-" + "\(option.id)")
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func tileLook(_ option: Option) -> BotLook {
        var copy = look
        apply(option, &copy)
        return copy
    }
}

/// Named color swatches. With `defaultTitle`, the first swatch is "use the palette's" (nil).
public struct TintSwatches: View {
    let title: String
    @Binding var selection: String?
    let choices: [BotTint]
    let defaultTitle: String?
    /// The color the default swatch shows.
    let defaultHex: String
    let identifier: String
    var size: CGFloat

    public init(_ title: String, selection: Binding<String?>, choices: [BotTint] = BotTint.custom, defaultTitle: String? = "Palette",
                defaultHex: String, identifier: String, size: CGFloat = 30) {
        self.title = title; _selection = selection; self.choices = choices; self.defaultTitle = defaultTitle
        self.defaultHex = defaultHex; self.identifier = identifier; self.size = size
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !title.isEmpty { Text(title).font(.footnote).foregroundStyle(.secondary) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: size, maximum: size + 8), spacing: 8)], alignment: .leading, spacing: 8) {
                if let defaultTitle {
                    swatch(hex: defaultHex, name: defaultTitle, on: selection == nil, id: "default", dashed: true) { selection = nil }
                }
                ForEach(choices) { tint in
                    swatch(hex: tint.hex, name: tint.name, on: selection == tint.hex || (defaultTitle == nil && selection == nil && tint.hex == defaultHex),
                           id: tint.id, dashed: false) { selection = tint.hex }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func swatch(hex: String, name: String, on: Bool, id: String, dashed: Bool, pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            Circle().fill(RGB(hex: hex).color)
                .frame(width: size, height: size)
                .overlay(Circle().stroke(Color.primary.opacity(on ? 0.9 : 0.14), style: StrokeStyle(lineWidth: on ? 2.5 : 1, dash: dashed && !on ? [3, 2] : [])))
                .overlay { if on { Image(systemName: "checkmark").font(.system(size: size * 0.38, weight: .bold)).foregroundStyle(.white.opacity(0.92)).shadow(radius: 1) } }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier(identifier + "-" + id)
    }
}

/// The palettes, as swatches.
public struct PaletteRow: View {
    @Binding var selection: String
    public init(selection: Binding<String>) { _selection = selection }
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Palette").font(.footnote).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 28, maximum: 34), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(BotPalette.all) { palette in
                    Button { selection = palette.id } label: {
                        Circle()
                            .fill(LinearGradient(colors: [palette.bodyRGB.color, palette.accentRGB.color], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 28, height: 28)
                            .overlay(Circle().stroke(Color.primary.opacity(selection == palette.id ? 0.9 : 0.12), lineWidth: selection == palette.id ? 2.5 : 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(palette.name)
                    .accessibilityAddTraits(selection == palette.id ? .isSelected : [])
                    .accessibilityIdentifier("palette-" + palette.id)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Everything about a bot's look but its dock size and ring: body, palette, its own colors, eyes,
/// expression, topper, accessory, prop, and cheeks. Each option is drawn on the character itself.
public struct LookControls: View {
    @Binding var look: BotLook
    var tile: CGFloat
    public init(look: Binding<BotLook>, tile: CGFloat = 44) { _look = look; self.tile = tile }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LookOptionRow("Body", options: BotLook.Shape.allCases, selected: look.shape, look: look, identifier: "shape", tile: tile,
                          label: \.title, apply: { $1.shape = $0; $1.prop = .none }, choose: { look.shape = $0 })
            PaletteRow(selection: $look.palette)
            TintSwatches("Body color", selection: $look.bodyColor, defaultHex: BotPalette.named(look.palette).body, identifier: "bodyColor")
            TintSwatches("Accent color", selection: $look.accentColor, defaultHex: BotPalette.named(look.palette).accent, identifier: "accentColor")
            LookOptionRow("Eyes", options: BotLook.Eyes.allCases, selected: look.eyes, look: look, identifier: "eyes", tile: tile,
                          label: \.title, apply: { $1.eyes = $0; $1.prop = .none }, choose: { look.eyes = $0 })
            LookOptionRow("Expression", options: BotLook.Expression.allCases, selected: look.expression, look: look, identifier: "expression", tile: tile,
                          label: \.title, apply: { $1.expression = $0; $1.prop = .none }, choose: { look.expression = $0 })
            LookOptionRow("On its head", options: BotLook.Topper.allCases, selected: look.topper, look: look, identifier: "topper", tile: tile,
                          label: \.title, apply: { $1.topper = $0; if $1.prop == .hardHat { $1.prop = .none } }, choose: { look.topper = $0; if look.prop == .hardHat { look.prop = .none } })
            LookOptionRow("Wearing", options: BotLook.Accessory.allCases, selected: look.accessory, look: look, identifier: "accessory", tile: tile,
                          label: \.title, apply: { $1.accessory = $0 }, choose: { look.accessory = $0 })
            LookOptionRow("Holding", options: BotLook.Prop.allCases, selected: look.prop, look: look, identifier: "prop", tile: tile,
                          label: \.title, apply: { $1.prop = $0 }, choose: { look.prop = $0 })
            Toggle("Rosy cheeks", isOn: $look.blush).accessibilityIdentifier("blush")
        }
    }
}

/// How the bot sits in the Mac's dock: its size and the ring at its feet.
public struct DockLookControls: View {
    @Binding var look: BotLook
    let engine: EngineID
    public init(look: Binding<BotLook>, engine: EngineID) { _look = look; self.engine = engine }
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Size in the dock")
                    Spacer()
                    Text(look.scale < 0.95 ? "Small" : look.scale > 1.08 ? "Large" : "Regular").foregroundStyle(.secondary)
                }
                Slider(value: $look.scale, in: BotLook.scaleRange, step: 0.05).accessibilityIdentifier("dockScale")
            }
            Picker("Ring", selection: Binding(get: { look.ring }, set: { ring in
                look.ring = ring
                if ring == .custom && look.ringColor == nil { look.ringColor = look.accentHex }
            })) {
                ForEach(BotLook.Ring.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("dockRing")
            if look.ring == .custom {
                TintSwatches("Ring color", selection: $look.ringColor, defaultTitle: nil, defaultHex: look.accentHex, identifier: "ringColor")
            }
        }
    }
}

/// How the bot talks: its tone and the owner's own words.
public struct PersonalityControls: View {
    @Binding var personality: BotPersonality
    public init(personality: Binding<BotPersonality>) { _personality = personality }
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Tone", selection: $personality.tone) {
                ForEach(BotPersonality.Tone.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("botTone")
            Text(personality.tone.detail).font(.footnote).foregroundStyle(.secondary)
            TextField("Anything else? “Call me Sam. Use metric.”", text: $personality.instructions, axis: .vertical)
                .lineLimit(2...5)
                .accessibilityIdentifier("botInstructions")
            if personality.instructions.count > BotPersonality.maxInstructions {
                Text("Keep it under \(BotPersonality.maxInstructions) characters.").font(.footnote).foregroundStyle(.orange)
            }
        }
    }
}

// MARK: KemoSabe

/// KemoSabe's settings: its color, and nothing else to change. It is always its cloud, its name, Apple's
/// on-device model on this device, and the scope the Gate gives it. `note` says where its privacy
/// settings live on this device.
public struct KemoSabeEditor: View {
    @State private var bot: BotSpec
    let device: String
    let note: String?
    let onSave: (BotSpec) -> Void
    let onCancel: () -> Void
    @Environment(\.colorScheme) private var scheme

    public init(bot: BotSpec, device: String, note: String? = nil, onSave: @escaping (BotSpec) -> Void, onCancel: @escaping () -> Void) {
        _bot = State(initialValue: bot.normalized())
        self.device = device; self.note = note; self.onSave = onSave; self.onCancel = onCancel
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    KemoSabeHeader(bot: bot, device: device)
                }
                Section {
                    KemoSabeColorPicker(bot: $bot)
                } header: {
                    Text("Its color")
                } footer: {
                    Text("\(bot.name) is always the same: its cloud, its name, and Apple’s on-device model on this \(device). Its color is yours to pick: its card, ring, and buttons in your chats.")
                }
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

/// KemoSabe's figure in its color, its name, and what it is.
public struct KemoSabeHeader: View {
    let bot: BotSpec
    let device: String
    var side: CGFloat
    @Environment(\.colorScheme) private var scheme
    public init(bot: BotSpec, device: String, side: CGFloat = 132) { self.bot = bot; self.device = device; self.side = side }
    public var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(bot.kemoSabeColor.opacity(scheme == .dark ? 0.22 : 0.12))
                Circle().strokeBorder(bot.kemoSabeColor.opacity(0.75), lineWidth: 2)
                KemoSabeFigure(shadow: false).padding(side * 0.1)
            }
            .frame(width: side, height: side)
            .accessibilityIdentifier("kemoSabePreview")
            Text(bot.name).font(.title2.weight(.semibold))
            Label("Your secure assistant · Apple on-device", systemImage: "lock.shield")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }
}

/// KemoSabe's colors as swatches.
public struct KemoSabeColorPicker: View {
    @Binding var bot: BotSpec
    var size: CGFloat
    public init(bot: Binding<BotSpec>, size: CGFloat = 32) { _bot = bot; self.size = size }
    public var body: some View {
        TintSwatches("", selection: Binding(get: { bot.kemoSabeTint }, set: { hex in
            // Coral is KemoSabe's own color, kept as "no pick".
            bot.look = .kemoSabe(tint: hex == BotTint.kemoSabe[0].hex ? nil : hex)
        }), choices: BotTint.kemoSabe, defaultTitle: nil, defaultHex: BotTint.kemoSabe[0].hex, identifier: "kemoSabeColor", size: size)
    }
}

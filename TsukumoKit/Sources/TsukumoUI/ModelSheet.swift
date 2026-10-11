import SwiftUI
import TsukumoCore

// The model sheet (design/UI-GUIDE.md, The composer): the composer's model chip opens it for the bot the message
// goes to. One sheet, sized to what it shows: which bot (when the chat has several), its power (the effort slider
// ported from the old KemoSabe app), its speed (fast mode, where the model offers it), its model, and what it runs on.
// Changes are the bot's own, saved when the sheet closes.

/// What the app lets the composer do beyond the chat: open the conversations, start a chat, and tune a bot.
public struct ComposerActions: Sendable {
    public var showConversations: @MainActor @Sendable () -> Void
    public var newChat: @MainActor @Sendable () -> Void
    /// What a bot made here can run on.
    public var engines: @MainActor @Sendable () -> [EngineChoice]
    /// Saves a bot; returns the problem to show, or nil.
    public var save: @MainActor @Sendable (BotSpec) -> String?
    /// Plays the demo (sample chats, nothing saved), from the new chat's "See how KemoSabe works".
    public var showDemo: (@MainActor @Sendable () -> Void)?
    public init(showConversations: @escaping @MainActor @Sendable () -> Void, newChat: @escaping @MainActor @Sendable () -> Void,
                engines: @escaping @MainActor @Sendable () -> [EngineChoice], save: @escaping @MainActor @Sendable (BotSpec) -> String?,
                showDemo: (@MainActor @Sendable () -> Void)? = nil) {
        self.showConversations = showConversations; self.newChat = newChat; self.engines = engines; self.save = save; self.showDemo = showDemo
    }
}

public extension EnvironmentValues {
    /// The app's actions for the composer; nil where the chat stands alone (the website demo's snapshot).
    @Entry var composerActions: ComposerActions? = nil
}

extension EngineChoice {
    /// Whether a model on this engine may go fast.
    func offersFast(_ model: String?) -> Bool {
        guard let wire, let model = model ?? models.first else { return false }
        return EffortCatalog.offersFastMode(wire: wire, model: model, host: host)
    }
    /// The model's name as the chip shows it.
    func shortName(_ model: String?) -> String {
        guard let model = model ?? models.first else { return info.title }
        return name(of: model)
    }
}

/// The model sheet's content (presented with `fittedSheet()`).
struct ModelSheet: View {
    let bots: [BotSpec]
    let actions: ComposerActions
    @State private var bot: BotSpec
    @State private var original: BotSpec
    @State private var problem: String?
    @State private var showsModels = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.engineInfo) private var engineInfo
    @Environment(\.dismiss) private var dismiss

    init(bot: BotSpec, bots: [BotSpec], actions: ComposerActions) {
        self.bots = bots; self.actions = actions
        _bot = State(initialValue: bot); _original = State(initialValue: bot)
    }

    private var engines: [EngineChoice] { actions.engines() }
    private var choice: EngineChoice? { engines.first { $0.engine == bot.engine } }
    private var tunable: Bool { !bot.isKemoSabe && !bot.isBroughtIn }
    private var efforts: [Effort] { choice?.efforts(for: bot.model) ?? [] }
    private var defaultEffort: Effort? {
        guard let wire = choice?.wire, let model = bot.model ?? choice?.models.first else { return nil }
        return EffortCatalog.defaultEffort(wire: wire, model: model)
    }
    private var heat: Double { EffortWeight.heat((bot.effort ?? defaultEffort)?.rawValue ?? "medium") }

    var body: some View {
        let theme = TsukumoTheme(scheme)
        VStack(alignment: .leading, spacing: 22) {
            if bots.count > 1 { botPicker(theme) }
            header(theme)
            if tunable {
                if !efforts.isEmpty { power(theme) }
                if choice?.offersFast(bot.model) == true { speed(theme) }
                models(theme)
            } else {
                Text(bot.isKemoSabe ? "KemoSabe always runs on Apple’s on-device model, on this iPhone. Nothing it reads leaves the phone."
                                    : "\(bot.name) runs on its own service. It only asks KemoSabe from there.")
                    .font(.subheadline).foregroundStyle(theme.secondary)
            }
            if let problem { Label(problem, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.orange) }
        }
        .padding(.horizontal, 22).padding(.top, 26).padding(.bottom, 12)
        .foregroundStyle(theme.ink)
        .tint(theme.accent)
        .onDisappear(perform: commit)
        .accessibilityIdentifier("modelSheet")
    }

    private func switchTo(_ next: BotSpec) {
        commit()
        bot = next; original = next; showsModels = false
    }
    private func commit() {
        guard bot != original else { return }
        if let problem = actions.save(bot) { self.problem = problem } else { original = bot }
    }

    // MARK: Parts

    private func botPicker(_ theme: TsukumoTheme) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(bots) { candidate in
                    let on = candidate.id == bot.id
                    Button { switchTo(candidate) } label: {
                        HStack(spacing: 6) {
                            BotAvatar(bot: candidate, size: 22, showsEngine: false)
                            Text(candidate.name).font(.subheadline.weight(.medium)).lineLimit(1)
                        }
                        .padding(.leading, 6).padding(.trailing, 12).padding(.vertical, 6)
                        .background(on ? theme.selected : theme.surface, in: Capsule())
                        .overlay(Capsule().stroke(on ? theme.accent.opacity(0.5) : theme.hairline))
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
        .sensoryFeedback(.selection, trigger: bot.id)
    }

    private func header(_ theme: TsukumoTheme) -> some View {
        HStack(spacing: 12) {
            BotAvatar(bot: bot, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(bot.name).font(.title3.weight(.semibold))
                Text(tunable ? (choice?.shortName(bot.model) ?? engineInfo(bot.engine).title) : engineInfo(bot.engine).title)
                    .font(.subheadline).foregroundStyle(theme.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func power(_ theme: TsukumoTheme) -> some View {
        let color = EffortHeat.title(accent: theme.accent, heat: heat, dark: scheme == .dark)
        // The slider's stops are the model's efforts; with none chosen, the thumb sits on the model's default.
        let shown = bot.effort ?? defaultEffort
        let step = shown.flatMap { efforts.firstIndex(of: $0) } ?? 0
        let isDefault = bot.effort == nil || bot.effort == defaultEffort
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("Power", systemImage: "bolt.fill").font(.footnote.weight(.semibold)).foregroundStyle(theme.secondary)
                Spacer()
                if !isDefault {
                    Button("Default") { bot.effort = nil }.font(.footnote.weight(.semibold)).accessibilityIdentifier("resetEffort")
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(EffortWeight.title(shown?.rawValue))
                    .font(.system(size: 32, weight: .semibold, design: .rounded)).foregroundStyle(color)
                    .contentTransition(.interpolate)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: bot.effort)
                    .accessibilityIdentifier("effortTitle")
                if isDefault { Text("default").font(.subheadline).foregroundStyle(theme.secondary) }
            }
            PowerSlider(count: efforts.count, step: Binding(get: { step }, set: { index in
                            let picked = efforts[min(max(index, 0), efforts.count - 1)]
                            bot.effort = picked == defaultEffort ? nil : picked
                        }),
                        heat: heat, accent: theme.accent, valueTitle: EffortWeight.title(shown?.rawValue), height: 44)
                .accessibilityIdentifier("effortSlider")
            Text("More power thinks longer and costs more.").font(.caption).foregroundStyle(theme.secondary)
        }
        .sensoryFeedback(.selection, trigger: bot.effort)
    }

    private func speed(_ theme: TsukumoTheme) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Speed", systemImage: "hare.fill").font(.footnote.weight(.semibold)).foregroundStyle(theme.secondary)
            TsukumoSegmented([(false, "Standard"), (true, "Fast")], selection: $bot.fast)
                .accessibilityIdentifier("botSpeed")
            Text(bot.fast ? "Answers up to 2.5× sooner, at twice the price." : "The model’s usual pace and price.")
                .font(.caption).foregroundStyle(theme.secondary)
        }
    }

    private func models(_ theme: TsukumoTheme) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(reduceMotion ? nil : TsukumoMetrics.spring) { showsModels.toggle() }
            } label: {
                HStack {
                    Label("Model", systemImage: "cpu").font(.footnote.weight(.semibold)).foregroundStyle(theme.secondary)
                    Spacer()
                    Text(choice?.shortName(bot.model) ?? engineInfo(bot.engine).title).font(.subheadline.weight(.medium))
                    Image(systemName: "chevron.down").font(.caption.weight(.bold)).foregroundStyle(theme.secondary)
                        .rotationEffect(.degrees(showsModels ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("modelToggle")
            if showsModels {
                VStack(spacing: 0) {
                    ForEach(engines) { engine in
                        let list = engine.models.isEmpty ? [String?.none] : engine.models.map(Optional.some)
                        ForEach(Array(list.enumerated()), id: \.offset) { index, model in
                            let current = engine.engine == bot.engine && (model == nil || (bot.model ?? engine.models.first) == model)
                            Button { pick(engine, model) } label: {
                                HStack(spacing: 10) {
                                    EngineMarkView(engine.info.mark, size: 22)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(model.map(engine.name(of:)) ?? engine.info.title).font(.subheadline.weight(current ? .semibold : .regular))
                                        if index == 0 { Text(engine.unavailable ?? (model == nil ? engine.info.detail : engine.info.title)).font(.caption).foregroundStyle(theme.secondary) }
                                    }
                                    Spacer()
                                    if current { Image(systemName: "checkmark").font(.footnote.weight(.bold)).foregroundStyle(theme.accent) }
                                }
                                .padding(.horizontal, 14).padding(.vertical, 11)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(engine.unavailable != nil)
                            .opacity(engine.unavailable == nil ? 1 : 0.45)
                            .accessibilityAddTraits(current ? .isSelected : [])
                        }
                    }
                }
                .background(theme.surface, in: RoundedRectangle(cornerRadius: TsukumoMetrics.rowCorner, style: .continuous))
                .transition(.opacity)
            }
        }
    }

    private func pick(_ engine: EngineChoice, _ model: String?) {
        if engine.engine != bot.engine {
            bot.engine = engine.engine; bot.effort = nil; bot.fast = false
        }
        bot.model = model == engine.models.first ? nil : model
        bot.effort = engine.accepted(bot.effort, model: bot.model)
        if !engine.offersFast(bot.model) { bot.fast = false }
    }
}

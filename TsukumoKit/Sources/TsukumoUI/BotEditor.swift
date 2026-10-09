import SwiftUI
import TsukumoCore
import TsukumoVoice

// One of the owner's bots, on the iPhone (October 8, 2026): who it is (its name, job, what the owner tells it, its
// character), what it runs on (a bot made here: an engine this device has), and how it works for the owner: its model
// and effort, its voice, how private an answer KemoSabe may give it, and what it may do. The same sheet makes a new
// bot (`isNew`). KemoSabe has its own sheet (`KemoSabeEditor`). The Mac's dock shows the same groups in its bot panel.

/// Something a bot can run on, as the app offers it.
public struct EngineChoice: Identifiable, Hashable, Sendable {
    public var engine: EngineID
    public var info: EngineInfo
    /// Models to pick from, the default first; empty means the engine picks.
    public var models: [String]
    /// How efforts are sent to it (which efforts a model accepts).
    public var wire: EffortCatalog.Wire?
    /// Nil when it can run here; otherwise why not ("Coding agents run on a Mac.").
    public var unavailable: String?
    /// Models' names to show, by ID ("opus" is "Opus 5.5"); a model without one shows its ID.
    public var modelNames: [String: String]
    /// The efforts each model takes, by ID, when the engine said (a coding agent's own list); otherwise `wire` decides.
    public var modelEfforts: [String: [Effort]]
    public var id: String { engine.key }

    public init(engine: EngineID, info: EngineInfo, models: [String] = [], wire: EffortCatalog.Wire? = nil, unavailable: String? = nil,
                modelNames: [String: String] = [:], modelEfforts: [String: [Effort]] = [:]) {
        self.engine = engine; self.info = info; self.models = models; self.wire = wire; self.unavailable = unavailable
        self.modelNames = modelNames; self.modelEfforts = modelEfforts
    }

    /// What a model is called here.
    public func name(of model: String) -> String { modelNames[model] ?? model }
    /// The efforts a model takes (nil: the engine's first model).
    public func efforts(for model: String?) -> [Effort] {
        let model = model ?? models.first ?? ""
        if let listed = modelEfforts[model] { return listed }
        return wire.map { EffortCatalog.efforts(wire: $0, model: model) } ?? []
    }
    /// An effort carried to another model: kept when that model takes it.
    public func accepted(_ effort: Effort?, model: String?) -> Effort? {
        guard let effort, efforts(for: model).contains(effort) else { return nil }
        return effort
    }
}

/// The sheet for a bot in Settings, Bots: KemoSabe's palette and voice, or one of the owner's bots' settings.
public struct BotSettingsSheet: View {
    let bot: BotSpec
    let engines: [EngineChoice]
    let device: String
    let kemoSabeNote: String?
    /// More of KemoSabe's settings, as Form sections below its voice (the bots it answers, its journal).
    let kemoSabeMore: AnyView?
    let isNew: Bool
    let onSave: (BotSpec) -> String?
    let onRemove: (() -> Void)?
    let onCancel: () -> Void
    /// `onSave` returns the problem to show, or nil once it's saved. `onRemove` offers Remove (not for KemoSabe or a new bot).
    public init(bot: BotSpec, engines: [EngineChoice], device: String = "iPhone", kemoSabeNote: String? = nil, kemoSabeMore: AnyView? = nil,
                isNew: Bool = false, onSave: @escaping (BotSpec) -> String?, onRemove: (() -> Void)? = nil, onCancel: @escaping () -> Void) {
        self.bot = bot; self.engines = engines; self.device = device; self.kemoSabeNote = kemoSabeNote; self.kemoSabeMore = kemoSabeMore; self.isNew = isNew
        self.onSave = onSave; self.onRemove = onRemove; self.onCancel = onCancel
    }
    public var body: some View {
        if bot.isKemoSabe {
            KemoSabeEditor(bot: bot, device: device, note: kemoSabeNote, more: kemoSabeMore, onSave: { _ = onSave($0) }, onCancel: onCancel)
        } else {
            BotEditor(bot: bot, engines: engines, device: device, isNew: isNew, onSave: onSave, onRemove: onRemove, onCancel: onCancel)
        }
    }
}

/// One of the owner's bots: its character and name on top, then Who It Is, Brain, Voice, Context, and Permissions.
public struct BotEditor: View {
    @State private var bot: BotSpec
    @State private var problem: String?
    @State private var confirmRemove = false
    let engines: [EngineChoice]
    let device: String
    let isNew: Bool
    let onSave: (BotSpec) -> String?
    let onRemove: (() -> Void)?
    let onCancel: () -> Void
    @Environment(\.engineInfo) private var engineInfo
    @Environment(\.voice) private var voice
    @Environment(\.codexPets) private var pets
    @State private var characterOpen = false

    public init(bot: BotSpec, engines: [EngineChoice], device: String = "iPhone", isNew: Bool = false,
                onSave: @escaping (BotSpec) -> String?, onRemove: (() -> Void)? = nil, onCancel: @escaping () -> Void) {
        _bot = State(initialValue: bot)
        self.engines = engines; self.device = device; self.isNew = isNew
        self.onSave = onSave; self.onRemove = onRemove; self.onCancel = onCancel
    }

    private var choice: EngineChoice? { engines.first { $0.engine == bot.engine } }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 8) {
                        Button { characterOpen.toggle() } label: { BotCharacterView(bot: bot, size: 72, animated: false) }
                            .buttonStyle(.plain).accessibilityLabel("Character")
                        Text(bot.name.isEmpty ? "New Bot" : bot.name).font(.title2.weight(.semibold))
                        Text(bot.engine.chats ? "Runs on " + engineInfo(bot.engine).title : bot.role)
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("botHeader")
                }
                // As on the Mac (2.01's order): its AI model first, then who it is, then drawers.
                if bot.engine.chats || isNew { Section("Brain") { brain } }
                Section {
                    TextField("Your name for it", text: $bot.name).accessibilityIdentifier("botName")
                    TextField("What it does", text: $bot.role).accessibilityIdentifier("botRole")
                    DisclosureGroup("Character", isExpanded: $characterOpen) {
                        BotCharacterPicker(look: $bot.look, service: bot.service, pets: pets, allowsPets: bot.wearsCodexPets)
                    }
                    if bot.engine.chats {
                        DisclosureGroup("Instructions") {
                            TextField("What you tell it", text: $bot.instructions, axis: .vertical)
                                .lineLimit(3...8).accessibilityIdentifier("botInstructions")
                        }
                    }
                } header: { Text("Details") } footer: {
                    if let problem { Text(problem).foregroundStyle(.orange) }
                }
                if bot.engine.chats || isNew {
                    Section {
                        VoicePicker(bot: $bot)
                    } header: { Text("Voice") } footer: { Text(VoicePicker.footer(voice: voice, device: device)) }
                }
                Section("Context") {
                    Toggle("May ask KemoSabe about you", isOn: $bot.contextScope.mayAskKemoSabe)
                    if bot.contextScope.mayAskKemoSabe {
                        Picker("KemoSabe may share up to", selection: $bot.contextScope.ceiling) {
                            ForEach([PrivacyLevel.open, .personal, .sensitive]) { Text($0.title).tag($0) }
                        }
                        Text(bot.contextScope.ceiling.detail).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if bot.engine.chats {
                    Section("Permissions") {
                        if bot.engine.runsOnlyOnMac {
                            Picker("In its project", selection: $bot.permissions.access) {
                                ForEach(BotPermissions.Access.allCases) { Text($0.title).tag($0) }
                            }
                            Text(bot.permissions.access.detail).font(.footnote).foregroundStyle(.secondary)
                        }
                        Toggle("Speaks its replies when you talk to it", isOn: $bot.permissions.speaks)
                    }
                }
                if let onRemove, !isNew {
                    Section {
                        Button("Remove \(bot.name)", role: .destructive) { confirmRemove = true }.accessibilityIdentifier("removeBot")
                    } footer: {
                        Text("It leaves your Mac’s dock too. Its chats are kept.")
                    }
                    .confirmationDialog("Remove \(bot.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
                        Button("Remove", role: .destructive, action: onRemove)
                    }
                }
            }
            .navigationTitle(isNew ? "New Bot" : bot.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Add" : "Save") { problem = onSave(bot) }
                        .fontWeight(.semibold).disabled(bot.name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("saveBot")
                }
            }
        }
        .accessibilityIdentifier("botEditor")
    }

    @ViewBuilder private var brain: some View {
        if case .made = bot.origin, bot.id != BotSpec.claudeBotID, engines.count > 1 || isNew {
            Picker("Runs on", selection: Binding(get: { bot.engine }, set: { engine in
                guard engine != bot.engine else { return }
                bot.engine = engine; bot.model = nil; bot.effort = nil
            })) {
                ForEach(engines.filter { $0.unavailable == nil || $0.engine == bot.engine }) { Text($0.info.title).tag($0.engine) }
            }
            .accessibilityIdentifier("botEngine")
        } else {
            LabeledContent("Runs on", value: engineInfo(bot.engine).title)
        }
        if let models = choice?.models, models.count > 1 {
            Picker("Model", selection: Binding(get: { bot.model ?? models[0] }, set: { bot.model = $0; bot.effort = choice?.accepted(bot.effort, model: $0) })) {
                ForEach(models, id: \.self) { Text(choice?.name(of: $0) ?? $0).tag($0) }
            }
            .accessibilityIdentifier("botModel")
        }
        let efforts = choice?.efforts(for: bot.model) ?? []
        if !efforts.isEmpty {
            Picker("Effort", selection: $bot.effort) {
                Text("Model default").tag(Effort?.none)
                ForEach(efforts, id: \.self) { Text($0.rawValue.capitalized).tag(Effort?.some($0)) }
            }
            .accessibilityIdentifier("botEffort")
        }
        Text(bot.engine.runsOnlyOnMac ? "Runs on your own sign-in for that agent, on your Mac." : "Runs on the model you connected, with your key.")
            .font(.footnote).foregroundStyle(.secondary)
    }
}

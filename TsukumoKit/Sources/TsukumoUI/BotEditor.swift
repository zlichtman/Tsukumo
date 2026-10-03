import SwiftUI
import TsukumoCore

// Make a bot (ported from the dock's add-bot logic and per-bot form): what runs it comes first; then a
// fun name you can change and a random character you can reroll, shown live at the top; then grouped
// drawers, closed to start: Look, Personality, Brain, Context, Permissions, and Dock. KemoSabe has its
// own short sheet (`KemoSabeEditor`): its color is the one thing to change.

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
    public var id: String { engine.key }

    public init(engine: EngineID, info: EngineInfo, models: [String] = [], wire: EffortCatalog.Wire? = nil, unavailable: String? = nil) {
        self.engine = engine; self.info = info; self.models = models; self.wire = wire; self.unavailable = unavailable
    }
}

/// The sheet that makes a new bot, or edits one (`editing`). Editing KemoSabe shows `KemoSabeEditor`.
public struct BotEditor: View {
    let existing: [BotSpec]
    let engines: [EngineChoice]
    let editing: BotSpec?
    /// The device's name, for KemoSabe's sheet ("iPhone").
    let device: String
    /// Where KemoSabe's privacy settings are on this device, for its sheet.
    let kemoSabeNote: String?
    let onSave: (BotSpec) -> Void
    let onCancel: () -> Void
    @State private var path: [Draft] = []
    @State private var rng: SeededGenerator

    /// A new bot on its way to the form, with the dice it was rolled with.
    struct Draft: Hashable {
        var bot: BotSpec
        var seed: UInt64
    }

    /// `seed` makes the dice repeatable (tests and screenshots).
    public init(existing: [BotSpec], engines: [EngineChoice], editing: BotSpec? = nil, seed: UInt64? = nil, device: String = "iPhone",
                kemoSabeNote: String? = nil, onSave: @escaping (BotSpec) -> Void, onCancel: @escaping () -> Void) {
        self.existing = existing; self.engines = engines; self.editing = editing; self.device = device; self.kemoSabeNote = kemoSabeNote
        self.onSave = onSave; self.onCancel = onCancel
        _rng = State(initialValue: seed.map(SeededGenerator.init(seed:)) ?? SeededGenerator())
    }

    public var body: some View {
        if let editing, editing.isKemoSabe {
            KemoSabeEditor(bot: editing, device: device, note: kemoSabeNote, onSave: onSave, onCancel: onCancel)
        } else {
            NavigationStack(path: $path) {
                Group {
                    if let editing {
                        form(editing, seed: 1, isNew: false)
                    } else {
                        enginePicker
                    }
                }
                .navigationDestination(for: Draft.self) { draft in form(draft.bot, seed: draft.seed, isNew: true) }
            }
        }
    }

    // MARK: Step 1: what runs it

    private var enginePicker: some View {
        List {
            Section {
                ForEach(engines) { choice in
                    Button {
                        var generator = rng
                        var bot = BotSpec.new(engine: choice.engine, existing: existing, using: &generator)
                        bot.model = choice.models.first
                        let next = generator.next()
                        rng = generator
                        path = [Draft(bot: bot, seed: next)]
                    } label: {
                        HStack(spacing: 12) {
                            EngineMarkView(choice.info.mark, size: 26).frame(width: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(choice.info.title).font(.body.weight(.medium))
                                Text(choice.unavailable ?? choice.info.detail).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if choice.unavailable == nil { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(choice.unavailable != nil)
                    .opacity(choice.unavailable == nil ? 1 : 0.55)
                    .accessibilityIdentifier("engine-" + choice.info.title)
                }
            } header: {
                Text("What runs it?")
            } footer: {
                Text("Apple on-device keeps every word on this device. An API model gets only what you allow, and asks KemoSabe for anything personal.")
            }
        }
        .navigationTitle("New bot")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
        }
    }

    // MARK: Step 2: the bot

    private func form(_ bot: BotSpec, seed: UInt64, isNew: Bool) -> some View {
        BotForm(initial: bot, existing: existing.filter { $0.id != bot.id }, engines: engines,
                isNew: isNew, seed: seed, onSave: onSave, onCancel: onCancel)
    }
}

/// A bot's own fields: a live preview on top, then grouped drawers.
struct BotForm: View {
    @State private var bot: BotSpec
    let existing: [BotSpec]
    let engines: [EngineChoice]
    let isNew: Bool
    @State private var rng: SeededGenerator
    let onSave: (BotSpec) -> Void
    let onCancel: () -> Void
    @State private var problem: String?
    @State private var starter: BotStarter = .custom
    @Environment(\.colorScheme) private var scheme
    @Environment(\.engineInfo) private var engineInfo

    init(initial: BotSpec, existing: [BotSpec], engines: [EngineChoice], isNew: Bool, seed: UInt64,
         onSave: @escaping (BotSpec) -> Void, onCancel: @escaping () -> Void) {
        _bot = State(initialValue: initial)
        _rng = State(initialValue: SeededGenerator(seed: seed))
        self.existing = existing; self.engines = engines; self.isNew = isNew; self.onSave = onSave; self.onCancel = onCancel
    }

    private var choice: EngineChoice? { engines.first { $0.engine == bot.engine } }
    private var efforts: [Effort] {
        guard let wire = choice?.wire else { return [] }
        return EffortCatalog.efforts(wire: wire, model: bot.model ?? choice?.models.first ?? "")
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    character
                    HStack(spacing: 8) {
                        TextField("Name", text: $bot.name)
                            .font(.title2.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("botName")
                        Button {
                            var generator = rng
                            bot.name = BotNames.next(taken: existing.map(\.name) + [bot.name], using: &generator)
                            rng = generator
                        } label: { Image(systemName: "dice") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("New name")
                        .accessibilityIdentifier("rerollName")
                    }
                    Label(engineInfo(bot.engine).title + (bot.role.isEmpty ? "" : " · " + bot.role), systemImage: "cpu")
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }

            Section {
                DisclosureGroup("Look") {
                    LookControls(look: $bot.look)
                }
                .accessibilityIdentifier("drawerLook")
                DisclosureGroup("Personality") {
                    Picker("Starts as", selection: $starter) {
                        ForEach(BotStarter.allCases) { Text($0.title).tag($0) }
                    }
                    .onChange(of: starter) { _, new in
                        if new != .custom { bot.role = new.role }
                    }
                    TextField("Its job, in one line", text: $bot.role, axis: .vertical)
                        .lineLimit(1...3)
                        .accessibilityIdentifier("botRole")
                    PersonalityControls(personality: $bot.personality)
                }
                .accessibilityIdentifier("drawerPersonality")
                DisclosureGroup("Brain") { brain }
                    .accessibilityIdentifier("drawerBrain")
                DisclosureGroup("Context") {
                    Picker("Most private it may get", selection: $bot.contextScope.ceiling) {
                        ForEach(PrivacyLevel.allCases.filter { $0 != .secret }) { level in Text(level.title).tag(level) }
                    }
                    Text(bot.contextScope.ceiling.detail).font(.footnote).foregroundStyle(.secondary)
                    if !bot.engine.isOnDevice {
                        Toggle("May ask KemoSabe about you", isOn: $bot.contextScope.mayAskKemoSabe)
                    }
                }
                .accessibilityIdentifier("drawerContext")
                DisclosureGroup("Permissions") {
                    if bot.engine.runsOnlyOnMac {
                        Picker("In its project", selection: $bot.permissions.access) {
                            ForEach(BotPermissions.Access.allCases) { Text($0.title).tag($0) }
                        }
                        Text(bot.permissions.access.detail).font(.footnote).foregroundStyle(.secondary)
                    }
                    Toggle("Approvals in the chat", isOn: $bot.permissions.approvalsHere)
                    Toggle("May speak up on its own", isOn: $bot.permissions.mayChirp)
                    Toggle("Read its replies aloud", isOn: $bot.permissions.speaks)
                }
                .accessibilityIdentifier("drawerPermissions")
                DisclosureGroup("Dock") {
                    DockLookControls(look: $bot.look, engine: bot.engine)
                    Text("How it sits in your Mac’s dock. It looks the same on every device you sign in on.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("drawerDock")
            }

            if let problem {
                Section { Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
            }
        }
        .navigationTitle(isNew ? "New bot" : bot.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { if !isNew { Button("Cancel", action: onCancel) } }
            ToolbarItem(placement: .confirmationAction) {
                Button(isNew ? "Add" : "Save") { save() }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("saveBot")
            }
        }
    }

    @ViewBuilder private var brain: some View {
        let usable = engines.filter { $0.unavailable == nil }
        if usable.count > 1 {
            Picker("Runs on", selection: Binding(get: { bot.engine }, set: { engine in
                guard engine != bot.engine else { return }
                bot.engine = engine
                bot.model = engines.first { $0.engine == engine }?.models.first
                bot.effort = nil
            })) {
                ForEach(usable) { Text($0.info.title).tag($0.engine) }
            }
            .accessibilityIdentifier("botEngine")
        } else {
            LabeledContent("Runs on", value: engineInfo(bot.engine).title)
        }
        if let models = choice?.models, models.count > 1 {
            Picker("Model", selection: Binding(get: { bot.model ?? models[0] }, set: { bot.model = $0; bot.effort = EffortCatalog.accepted(bot.effort, wire: choice?.wire ?? .openAICompatible, model: $0) })) {
                ForEach(models, id: \.self) { Text($0).tag($0) }
            }
            .accessibilityIdentifier("botModel")
        } else if case .api = bot.engine {
            TextField("Model", text: Binding(get: { bot.model ?? "" }, set: { bot.model = $0 }))
                .autocorrectionDisabled()
                .accessibilityIdentifier("botModel")
        }
        if !efforts.isEmpty {
            Picker("Effort", selection: $bot.effort) {
                Text("Model default").tag(Effort?.none)
                ForEach(efforts, id: \.self) { Text($0.rawValue.capitalized).tag(Effort?.some($0)) }
            }
            .accessibilityIdentifier("botEffort")
        }
        Text(bot.engine.isOnDevice ? "Runs on Apple’s on-device model: nothing leaves this device."
             : bot.engine.runsOnlyOnMac ? "Runs on your own sign-in for that agent, on your Mac." : "Runs on a model you connected, with your key.")
            .font(.footnote).foregroundStyle(.secondary)
    }

    private var character: some View {
        let theme = TsukumoTheme(scheme)
        return ZStack(alignment: .bottomTrailing) {
            BotLookPreview(look: bot.look, engine: bot.engine)
            Button {
                var generator = rng
                bot.look = bot.look.rerolled(for: starter, taken: existing.map(\.look), using: &generator)
                rng = generator
            } label: {
                Image(systemName: "dice.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.onAccent)
                    .frame(width: 36, height: 36).background(theme.accent, in: Circle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("New character")
            .accessibilityIdentifier("rerollCharacter")
        }
    }

    private func save() {
        switch bot.validated(existing: existing) {
        case .success(let valid): problem = nil; onSave(valid)
        case .failure(let failure): problem = failure.message
        }
    }
}

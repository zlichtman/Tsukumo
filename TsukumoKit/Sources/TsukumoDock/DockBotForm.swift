#if os(macOS)
import AppKit
import SwiftUI
import TsukumoCore
import TsukumoUI

// A bot's settings beside the dock (ported from `DockAgentForm` and `DockLookEditor` in
// the old Mac app's dock), on `BotSpec`, grouped like the iPhone's editor: a live preview
// with its name and job on top, then drawers for Look (its clay character, drawn option by option),
// Personality (tone and the owner's words), Brain (engine, model, effort), Context (its project, whether
// it may ask KemoSabe, and the most private level KemoSabe may read for it), Permissions, Dock (its size
// and ring), and what it chirps about. A new dock starts from three starters, or a random character to
// reroll. KemoSabe's own form is its color only: it is always standard (what it reads and whether it
// chirps are in the app's Settings, KemoSabe).

public struct DockBotForm: View {
    let dock: BotDock
    let editing: BotSpec?
    let done: () -> Void
    /// Saving opens the bot's chat beside the dock (false in the app's Settings window).
    let opensChat: Bool
    @State private var draft: BotSpec
    @State private var watch = DockChirpWatch()
    @State private var words = ""
    @State private var problem: String?
    @State private var starter: String?
    /// The owner changed the character; typing a name or job no longer suggests another.
    @State private var lookTouched: Bool
    @State private var open: Set<String>
    @State private var rng = SeededGenerator()
    @Environment(\.colorScheme) private var scheme

    /// `openDrawers` opens groups to begin with (screenshots); a new bot opens Look.
    public init(dock: BotDock, editing: BotSpec?, openDrawers: Set<String>? = nil, opensChat: Bool = true, done: @escaping () -> Void) {
        self.dock = dock; self.editing = editing; self.done = done; self.opensChat = opensChat
        // A new bot starts on the default model (Settings, Models), else the first engine this Mac has.
        let preferred = dock.store.defaultModel.flatMap { model in dock.engineChoices.first { $0.engine == model.engine && $0.unavailable == nil } }
        let engine = preferred?.engine ?? dock.engineChoices.first { $0.unavailable == nil && $0.engine != .appleOnDevice }?.engine ?? .appleOnDevice
        var fresh = BotSpec(name: "", engine: engine, look: .suggested(name: "", job: "", taken: dock.bots.map(\.look)))
        if preferred != nil { fresh.model = dock.store.defaultModel?.model }
        _draft = State(initialValue: editing?.normalized() ?? fresh)
        _lookTouched = State(initialValue: editing != nil)
        _open = State(initialValue: openDrawers ?? (editing == nil ? ["Look"] : []))
        let saved = dock.store.chirpWatch(editing?.id ?? UUID())
        _watch = State(initialValue: saved)
        _words = State(initialValue: saved.words.joined(separator: ", "))
    }

    private var isKemoSabe: Bool { editing?.isKemoSabe ?? false }
    private var accent: Color { TsukumoTheme(scheme).accent }
    private var choice: EngineChoice? { dock.engineChoices.first { $0.engine == draft.engine } }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(editing == nil ? "New bot" : isKemoSabe ? editing!.name : "Edit \(editing!.name)")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { done() } label: { Image(systemName: "xmark") }.buttonStyle(DockIconButtonStyle()).accessibilityLabel("Close")
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if isKemoSabe { kemoSabe } else { bot }
                    if !isKemoSabe && draft.permissions.mayChirp { drawer("Chirps in about") { chirps } }
                    if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(.orange) }
                }
                .padding(14)
            }
            Divider().opacity(0.5)
            HStack {
                if let editing, !editing.isKemoSabe {
                    Button("Remove", role: .destructive) { dock.remove(editing.id); done() }.accessibilityIdentifier("dockBotRemove")
                }
                Spacer()
                Button("Cancel") { done() }
                Button(editing == nil ? "Add to dock" : "Save") { save() }
                    .buttonStyle(.borderedProminent).tint(isKemoSabe ? draft.kemoSabeColor : accent)
                    .keyboardShortcut(.defaultAction).accessibilityIdentifier("dockBotSave")
            }
            .controlSize(.regular).padding(12)
        }
        .font(.system(size: 12.5))
        .accessibilityIdentifier(isKemoSabe ? "kemoSabeEditor" : "dockBotForm")
    }

    // MARK: KemoSabe

    @ViewBuilder private var kemoSabe: some View {
        KemoSabeHeader(bot: draft, device: "Mac", side: 104)
        group("Its color") {
            KemoSabeColorPicker(bot: $draft, size: 26)
            note("\(draft.name) is always the same: its cloud, its name, and Apple’s on-device model on this Mac. Its color is yours to pick: its card, ring, and buttons in your chats. What it may read is in Settings, KemoSabe.")
        }
    }

    // MARK: Any other bot

    @ViewBuilder private var bot: some View {
        if editing == nil { starters }
        HStack(alignment: .center, spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                BotLookPreview(look: draft.look, engine: draft.engine, side: 104)
                Button {
                    var generator = rng
                    draft.look = draft.look.rerolled(taken: dock.bots.filter { $0.id != draft.id }.map(\.look), using: &generator)
                    rng = generator
                    lookTouched = true
                } label: {
                    Image(systemName: "dice.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 28, height: 28).background(accent, in: Circle())
                }
                .buttonStyle(.plain).help("New character").accessibilityLabel("New character").accessibilityIdentifier("rerollCharacter")
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    TextField("Name it: Homework, PowderMeet coder", text: Binding(get: { draft.name }, set: { draft.name = $0; suggest() }))
                        .textFieldStyle(.roundedBorder).accessibilityIdentifier("dockBotName")
                    Button {
                        var generator = rng
                        draft.name = BotNames.next(taken: dock.bots.map(\.name) + [draft.name], using: &generator)
                        rng = generator
                        suggest()
                    } label: { Image(systemName: "dice") }
                    .buttonStyle(.borderless).help("New name").accessibilityLabel("New name").accessibilityIdentifier("rerollName")
                }
                TextField("Its job: tracks my class deadlines", text: Binding(get: { draft.role }, set: { draft.role = $0; suggest() }))
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("dockBotJob")
                HStack(spacing: 5) {
                    EngineMarkView(dock.engineInfo(draft.engine).mark, size: 12)
                    Text(dock.engineInfo(draft.engine).title).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        drawer("Look") {
            LookControls(look: Binding(get: { draft.look }, set: { draft.look = $0; lookTouched = true }), tile: 32)
        }
        drawer("Personality") { PersonalityControls(personality: $draft.personality) }
        drawer("Brain") { coreModel }
        drawer("Context") { context }
        drawer("Permissions") { permissions }
        drawer("Dock") {
            DockLookControls(look: $draft.look, engine: draft.engine)
            note(dock.settings.engineMark == .ring ? "The dock shows engines as rings." : "Engine rings are off in Dock settings; a ring in your own color still shows.")
        }
    }

    private var starters: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Start from").font(.system(size: 11.5)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(DockStarter.all) { starter in
                    Button {
                        var next = starter.bot(existing: dock.bots, id: draft.id)
                        if next.model == nil { next.model = dock.engineChoices.first { $0.engine == next.engine }?.models.first }
                        draft = next
                        watch.sources = starter.kind == .homework ? [.calendar, .reminders] : []
                        self.starter = starter.title
                        lookTouched = false
                    } label: {
                        HStack(spacing: 5) {
                            ClayCharacter(look: starter.look, shadow: false).frame(width: 22, height: 22)
                            Text(starter.title).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                        }
                        .padding(.leading, 4).padding(.trailing, 9).frame(height: 28)
                        .background(Capsule().fill(self.starter == starter.title ? accent.opacity(0.18) : Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain).fixedSize().accessibilityIdentifier("dockStarter-" + starter.title)
                }
            }
        }
    }

    @ViewBuilder private var coreModel: some View {
        field("Engine") {
            Menu {
                ForEach(dock.engineChoices) { choice in
                    Button {
                        if draft.engine != choice.engine { draft.engine = choice.engine; draft.model = choice.models.first; draft.effort = nil }
                    } label: {
                        if choice.engine == draft.engine { Label(choice.info.title, systemImage: "checkmark") }
                        else { Text(choice.info.title + (choice.unavailable.map { " (\($0))" } ?? "")) }
                    }
                    .disabled(choice.unavailable != nil)
                }
            } label: {
                HStack(spacing: 6) {
                    EngineMarkView(dock.engineInfo(draft.engine).mark, size: 14)
                    Text(dock.engineInfo(draft.engine).title)
                }
            }
            .fixedSize().accessibilityIdentifier("dockBotEngine")
        }
        if let choice, !choice.models.isEmpty {
            field("Model and effort") {
                HStack(spacing: 8) {
                    Menu(draft.model ?? "Engine’s default") {
                        Button("Engine’s default") { draft.model = nil; draft.effort = nil }
                        Divider()
                        ForEach(choice.models, id: \.self) { model in Button(model) { draft.model = model; draft.effort = nil } }
                    }.fixedSize()
                    let efforts = choice.wire.map { EffortCatalog.efforts(wire: $0, model: draft.model ?? choice.models.first ?? "") } ?? []
                    if !efforts.isEmpty {
                        Menu(draft.effort.map { $0.rawValue.capitalized } ?? "Default effort") {
                            Button("Default effort") { draft.effort = nil }
                            ForEach(efforts, id: \.self) { effort in Button(effort.rawValue.capitalized) { draft.effort = effort } }
                        }.fixedSize().accessibilityIdentifier("dockBotEffort")
                    }
                }
            }
        }
        note(draft.engine.isOnDevice ? "Runs on Apple’s on-device model: nothing leaves this Mac."
             : draft.engine.runsOnlyOnMac ? "Runs on your own sign-in for that agent, on this Mac." : "Runs on a model you connected.")
    }

    @ViewBuilder private var context: some View {
        if draft.engine.runsOnlyOnMac {
            field("Project") {
                HStack(spacing: 8) {
                    Text(draft.contextScope.project.map { ($0 as NSString).lastPathComponent } ?? "None (chat only)").lineLimit(1)
                    Spacer(minLength: 4)
                    Button("Choose…") { chooseProject() }.controlSize(.small)
                    if draft.contextScope.project != nil { Button("Clear") { draft.contextScope.project = nil }.controlSize(.small) }
                }
            }
        }
        Toggle("Can ask KemoSabe about you", isOn: $draft.contextScope.mayAskKemoSabe)
            .toggleStyle(.checkbox).accessibilityIdentifier("dockBotMayAsk")
        if draft.contextScope.mayAskKemoSabe {
            field("KemoSabe may share up to") {
                Menu(draft.contextScope.ceiling.title) {
                    ForEach([PrivacyLevel.open, .personal, .sensitive]) { level in
                        Button(level.title + ": " + level.detail) { draft.contextScope.ceiling = level }
                    }
                }
                .fixedSize().accessibilityIdentifier("dockBotCeiling")
            }
            note("KemoSabe reads on this Mac and sends back only the answer. Device only and Secret never leave.")
        } else {
            note("KemoSabe declines its questions without reading anything.")
        }
    }

    @ViewBuilder private var permissions: some View {
        if draft.engine.runsOnlyOnMac {
            field("In its project") {
                Menu(draft.permissions.access.title) {
                    ForEach(BotPermissions.Access.allCases) { access in
                        Button(access.title + ": " + access.detail) { draft.permissions.access = access }
                    }
                }.fixedSize().accessibilityIdentifier("dockBotAccess")
            }
        }
        field("Approvals") {
            Menu(draft.permissions.approvalsHere ? "In the dock" : "Only in the chat") {
                Button("In the dock") { draft.permissions.approvalsHere = true }
                Button("Only in the chat") { draft.permissions.approvalsHere = false }
            }.fixedSize()
        }
        Toggle("May chirp in", isOn: $draft.permissions.mayChirp).toggleStyle(.checkbox)
        Toggle("May speak its replies aloud", isOn: $draft.permissions.speaks).toggleStyle(.checkbox)
    }

    @ViewBuilder private var chirps: some View {
        ForEach(DockChirpSource.allCases) { source in
            Toggle(source.title, isOn: Binding(get: { watch.sources.contains(source) }, set: { on in
                watch.sources.removeAll { $0 == source }
                if on { watch.sources.append(source) }
            })).toggleStyle(.checkbox)
        }
        if !watch.sources.isEmpty {
            field("Only items with") { TextField("stats, homework (optional)", text: $words).textFieldStyle(.roundedBorder) }
            field("How far ahead") {
                Menu(DockChirpWatch.leadChoices.first { $0.1 == watch.leadMinutes }?.0 ?? "2 hours") {
                    ForEach(DockChirpWatch.leadChoices, id: \.1) { choice in Button(choice.0) { watch.leadMinutes = choice.1 } }
                }.fixedSize()
            }
        }
        note("Chirps are made on this Mac from what’s coming up. They never go to a bot.")
    }

    // MARK: Pieces

    private func group(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12, weight: .semibold))
            content()
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    /// A group that opens and closes, like the iPhone's drawers.
    private func drawer(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        let expanded = open.contains(title)
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                if expanded { open.remove(title) } else { open.insert(title) }
            } label: {
                HStack {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("dockDrawer-" + title)
            .accessibilityAddTraits(expanded ? .isSelected : [])
            if expanded { content() }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    private func field(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11.5)).foregroundStyle(.secondary)
            content()
        }
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    /// A new bot's character follows its name and job until the owner changes it.
    private func suggest() {
        guard !lookTouched, editing == nil else { return }
        draft.look = .suggested(name: draft.name, job: draft.role, taken: dock.bots.map(\.look))
    }
    private func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "The folder \(draft.name.isEmpty ? "this bot" : draft.name) works in."
        if panel.runModal() == .OK, let url = panel.url { draft.contextScope.project = url.path }
    }

    private func save() {
        watch.words = words.split(separator: ",").map(String.init)
        let result = editing == nil ? dock.add(draft) : dock.update(draft)
        switch result {
        case .success(let bot):
            problem = nil
            dock.store.setChirpWatch(watch, for: bot.id)
            if opensChat { dock.open(.bot(bot.id)) } else { done() }
        case .failure(let failure):
            problem = failure.message
        }
    }
}

// MARK: The dock's settings

/// How the side dock looks and behaves: the Tsukumo app's Settings, Dock. Grouped sections for a
/// `Form` with the grouped style (style, size, magnification, spacing, corners, indicators, the edge,
/// chirp sounds). The bots themselves are in Settings, Bots.
public struct BotDockSettingsView: View {
    let dock: BotDock
    public init(dock: BotDock) { self.dock = dock }

    public var body: some View {
        let settings = dock.settings
        let store = dock.store
        Section("Look") {
            Picker("Style", selection: Binding(get: { settings.style }, set: { style in store.update { $0.style = style } })) {
                ForEach(DockStyle.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("dockStyle")
            LabeledContent("Size") {
                Slider(value: Binding(get: { settings.size }, set: { size in store.update { $0.size = size } }), in: DockSettings.sizeRange)
                    .frame(width: 180)
            }
            Toggle("Magnification", isOn: Binding(get: { settings.magnification }, set: { on in store.update { $0.magnification = on } }))
            if settings.magnification {
                LabeledContent("Magnified size") {
                    Slider(value: Binding(get: { settings.magnifiedSize }, set: { size in store.update { $0.magnifiedSize = size } }),
                           in: DockSettings.magnifiedRange).frame(width: 180)
                }
            }
            LabeledContent("Spacing") {
                Slider(value: Binding(get: { settings.spacing }, set: { spacing in store.update { $0.spacing = spacing } }), in: DockSettings.spacingRange)
                    .frame(width: 180)
            }
            LabeledContent("Corners") {
                Slider(value: Binding(get: { settings.corners }, set: { corners in store.update { $0.corners = corners } }), in: DockSettings.cornersRange)
                    .frame(width: 180)
            }
            Toggle("Separator before + and Together", isOn: Binding(get: { settings.separators }, set: { on in store.update { $0.separators = on } }))
        }
        Section("Indicators") {
            Picker("Working or waiting on you", selection: Binding(get: { settings.indicator }, set: { value in store.update { $0.indicator = value } })) {
                ForEach(DockIndicator.allCases) { Text($0.title).tag($0) }
            }
            Picker("Which engine runs each bot", selection: Binding(get: { settings.engineMark }, set: { value in store.update { $0.engineMark = value } })) {
                ForEach(DockEngineMark.allCases) { Text($0.title).tag($0) }
            }
            Picker("Names on hover", selection: Binding(get: { settings.labels }, set: { value in store.update { $0.labels = value } })) {
                ForEach(DockLabelStyle.allCases) { Text($0.title).tag($0) }
            }
        }
        Section("Position") {
            Picker("Edge", selection: Binding(get: { settings.edge }, set: { edge in store.update { $0.edge = edge } })) {
                ForEach(DockSettings.Edge.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("dockEdge")
            Picker("Along the edge", selection: Binding(get: { settings.position }, set: { position in store.update { $0.position = position } })) {
                ForEach(DockSettings.Position.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Automatically hide", isOn: Binding(get: { settings.autohide }, set: { on in store.update { $0.autohide = on } }))
            if settings.autohide {
                Picker("Hide after", selection: Binding(get: { settings.autohideDelay }, set: { delay in store.update { $0.autohideDelay = delay } })) {
                    ForEach(DockSettings.delayChoices, id: \.1) { Text($0.0).tag($0.1) }
                }
            }
        }
        Section("Characters") {
            Picker("Animation", selection: Binding(get: { settings.animation }, set: { level in store.update { $0.animation = level } })) {
                ForEach(DockAnimationLevel.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Sleep at night", isOn: Binding(get: { settings.sleepAtNight }, set: { on in store.update { $0.sleepAtNight = on } }))
            Toggle("Chirp sounds", isOn: Binding(get: { settings.chirpSounds }, set: { on in store.update { $0.chirpSounds = on } }))
                .accessibilityIdentifier("dockChirpSounds")
        }
    }
}
#endif

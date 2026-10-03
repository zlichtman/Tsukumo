import SwiftUI

/// Opens Settings → Connections from a page that can't reach it itself (Personalization's Connect).
/// iPhone opens its Connections panel; Mac switches the settings page.
struct OpenConnectionsKey: EnvironmentKey { static let defaultValue: (() -> Void)? = nil }
extension EnvironmentValues {
    var openConnections: (() -> Void)? {
        get { self[OpenConnectionsKey.self] }
        set { self[OpenConnectionsKey.self] = newValue }
    }
}

/// Settings → Personalization, the same on iPhone and Mac (the owner's instruction, September 26,
/// 2026): only controls on the page, in four groups, with the facts on About personalization.
///
/// - Where Kemo puts things: a Calendar and a Reminders list, or Connect when that isn't connected.
/// - Planning hours: a start–end range in the locale's time format, Longest block, and each
///   destination's automatic changes. A standing permission keeps the limits it was given; one line
///   says so only when an active one differs from the hours shown.
/// - Between conversations: Carry recent context, what it holds, and Forget (confirmed).
/// - Learn from my choices: the switch with how many choices are stored, your stated preferences,
///   Add a preference, and Forget (confirmed).
struct PersonalRoutineSettings: View {
    @Environment(AppStore.self) private var store
    @Environment(RoutineStore.self) private var routines
    @Environment(ConnectorStore.self) private var connectors
    @Environment(\.openConnections) private var openConnections
    #if os(iOS)
    @Environment(\.mobilePalette) private var palette
    #endif
    @State private var forgettingContext = false
    @State private var destinations: [RoutineDestination] = []
    @State private var document = RoutineDocument()
    @State private var preferences = PreferenceState()
    @State private var pending: RoutineDestination?
    @State private var error: String?
    @State private var busy = false
    @State private var earliest = 9
    @State private var latest = 18
    @State private var maximum = 120
    @State private var resetting = false
    @State private var editing: StatedPreference?
    /// The longest-block choices, in minutes.
    static let blockChoices = [30, 60, 90, 120, 180]

    var body: some View {
        Form {
            if let error { Section { Text(error).foregroundStyle(.orange) } }
            Section("Where KemoSabe puts things") {
                destinationRow(reminders: false)
                destinationRow(reminders: true)
            }
            Section {
                LabeledContent("Hours") {
                    HStack(spacing: 6) {
                        DatePicker("Start", selection: hourBinding($earliest, end: false), displayedComponents: .hourAndMinute)
                            .labelsHidden().accessibilityIdentifier("planningStart")
                        Text("–").foregroundStyle(.secondary)
                        DatePicker("End", selection: hourBinding($latest, end: true), displayedComponents: .hourAndMinute)
                            .labelsHidden().accessibilityIdentifier("planningEnd")
                    }
                }
                Picker("Longest block", selection: $maximum) {
                    ForEach(Self.blockChoices + (Self.blockChoices.contains(maximum) ? [] : [maximum]), id: \.self) { Text(Self.duration($0)).tag($0) }
                }.pickerStyle(.menu).accessibilityIdentifier("longestBlock")
                ForEach(selectedDestinations, id: \.id) { destination in automaticChanges(destination) }
            } header: { Text("Planning hours") } footer: {
                if earliest >= latest { Text("End after the start.") }
                else if let note = Self.standingNote(grants: activeGrants, earliest: earliest, latest: latest, maximum: maximum) {
                    Text(note).accessibilityIdentifier("standingPermissionNote")
                }
            }
            Section("Between conversations") {
                Toggle("Carry recent context", isOn: Binding(get: { routines.state.context?.learning ?? true }, set: { value in Task { await routines.setLearning(value, store: store) } }))
                    .accessibilityIdentifier("carryRecentContext")
                DisclosureGroup("Recent context") {
                    let context = routines.state.context?.workingContext(now: Date(), timeZone: .current) ?? []
                    if context.isEmpty { Text("No recent context.").foregroundStyle(.secondary) }
                    ForEach(Array(context.enumerated()), id: \.offset) { _, line in Text(line).font(.caption) }
                }.accessibilityIdentifier("recentContext")
                Button("Forget recent context", role: .destructive) { forgettingContext = true }.accessibilityIdentifier("forgetRecentContext")
            }
            Section("Learn from my choices") {
                Toggle(isOn: Binding(get: { preferences.learning }, set: { enabled in perform { try await store.dailyAssistant.preferences.setLearning(enabled) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Learn from my choices")
                        Text(Self.stored(preferences.examples.count)).font(.caption).foregroundStyle(.secondary)
                    }
                }.accessibilityIdentifier("learnFromChoices")
                ForEach(preferences.statements) { preference in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preference.text)
                            Text("You stated this · \((preference.activity ?? "general").capitalized) · \(preference.updatedAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Menu {
                            Button("Edit preference", systemImage: "pencil") { editing = preference }
                            Button("Forget this preference", systemImage: "trash", role: .destructive) { perform { try await store.dailyAssistant.preferences.forget(sourceID: preference.sourceID) } }
                        } label: { Image(systemName: "ellipsis.circle").foregroundStyle(.secondary) }
                            .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Preference options")
                    }
                }
                Button("Tell KemoSabe a correction") {
                    editing = .init(id: UUID(), sourceID: UUID(), text: "", preferredHour: 14, updatedAt: Date(), activity: "general")
                }.accessibilityIdentifier("addPreference")
                Button("Forget what KemoSabe learned", role: .destructive) { resetting = true }.accessibilityIdentifier("forgetLearning")
            }
            Section { AboutPersonalizationLink() }
        }
        #if os(iOS)
        .scrollContentBackground(.hidden).background(palette.background)
        #endif
        .confirmationDialog("Forget recent context?", isPresented: $forgettingContext, titleVisibility: .visible) {
            Button("Forget recent context", role: .destructive) { Task { await routines.forgetContext(store: store) } }
        } message: { Text("Saved memories and proposals remain separately editable.") }
        .navigationTitle("Personalization").disabled(busy)
        .sheet(item: $editing) { preference in
            RoutinePreferenceEditor(preference: preference) { revised in
                perform { try await store.dailyAssistant.preferences.statePreference(revised) }
            }
        }
        .task { connectors.refresh(); await reload() }
        .confirmationDialog("Use this destination for KemoSabe?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { destination in
            Button("Use \(destination.name)") { perform { try await store.proposalLedger.setDestination(destination) }; pending = nil }
        } message: { destination in
            Text(destination.maySync ? "Neutral titles, times, and links may sync through \(destination.sourceName). This does not enable automatic changes." : "This selects a local destination. Automatic changes stay off until you enable them.")
        }
        .confirmationDialog("Forget all learned routine preferences and choices?", isPresented: $resetting, titleVisibility: .visible) {
            Button("Forget what KemoSabe learned", role: .destructive) { perform { try await store.dailyAssistant.preferences.reset() } }
        }
    }

    // MARK: Where Kemo puts things

    private func selected(reminders: Bool) -> RoutineDestination? { document.routineDestinations?.first { $0.reminders == reminders } }
    private var selectedDestinations: [RoutineDestination] { [false, true].compactMap { selected(reminders: $0) } }
    @ViewBuilder private func destinationRow(reminders: Bool) -> some View {
        let connector: ConnectorID = reminders ? .reminders : .calendar
        let title = reminders ? "Reminders" : "Calendar"
        let options = destinations.filter { $0.reminders == reminders }
        let chosen = selected(reminders: reminders)
        if connectors.status(connector, state: store.state).usable || !options.isEmpty {
            Picker(title, selection: Binding<String?>(get: { chosen?.id }, set: { id in
                if let id, id != chosen?.id, let destination = options.first(where: { $0.id == id }) { pending = destination }
            })) {
                if chosen == nil { Text("Choose").tag(String?.none) }
                ForEach(options) { destination in Text(destination.name).tag(Optional(destination.id)) }
                // A saved destination that isn't offered right now still shows as chosen.
                if let chosen, !options.contains(chosen) { Text(chosen.name).tag(Optional(chosen.id)) }
            }.pickerStyle(.menu).accessibilityIdentifier(reminders ? "remindersDestination" : "calendarDestination")
        } else {
            LabeledContent(title) {
                Button("Connect") { openConnections?() }.disabled(openConnections == nil)
                    .accessibilityIdentifier(reminders ? "connectReminders" : "connectCalendar")
            }
        }
    }

    // MARK: Planning hours

    private var activeGrants: [StandingGrant] {
        (document.standingGrants ?? []).filter { $0.revokedAt == nil && $0.expiresAt > Date() }
    }
    private func grant(for destination: RoutineDestination) -> StandingGrant? { activeGrants.first { $0.destination == destination } }
    private func automaticChanges(_ destination: RoutineDestination) -> some View {
        let grant = grant(for: destination)
        return Toggle(isOn: Binding(get: { grant != nil }, set: { on in
            if on {
                perform {
                    let operations: Set<RoutineOperation> = destination.reminders ? [.createReminder, .rescheduleReminder] : [.createBlock, .moveBlock]
                    try await store.proposalLedger.grant(.init(id: UUID(), destination: destination, operations: operations,
                        earliestHour: earliest, latestHour: latest, maximumMinutes: maximum, expiresAt: Date().addingTimeInterval(30 * 86400)))
                }
            } else if let grant {
                perform { try await store.proposalLedger.revokeGrant(id: grant.id) }
            }
        })) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Automatic changes in \(destination.name)")
                Text(grant.map { Self.grantSummary($0) } ?? "Each change waits for review.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(grant == nil && earliest >= latest)
        .accessibilityIdentifier("automaticChanges-" + (destination.reminders ? "reminders" : "calendar"))
    }
    /// "9:00 AM–6:00 PM · up to 2 h · until Oct 26": an active standing permission's own limits.
    static func grantSummary(_ grant: StandingGrant, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        hour(grant.earliestHour, timeZone: timeZone, locale: locale) + "–" + hour(grant.latestHour, timeZone: timeZone, locale: locale)
            + " · up to " + duration(grant.maximumMinutes) + " · until " + grant.expiresAt.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, timeZone: timeZone))
    }
    /// One line, only when an active standing permission's limits differ from the hours shown:
    /// changing them never expands a permission already given.
    static func standingNote(grants: [StandingGrant], earliest: Int, latest: Int, maximum: Int) -> String? {
        guard grants.contains(where: { $0.earliestHour != earliest || $0.latestHour != latest || $0.maximumMinutes != maximum }) else { return nil }
        return "Automatic changes already on keep their own limits. Turn one off and on to use these."
    }
    /// An hour in the locale's time format; 24 is the end of the day (midnight).
    static func hour(_ value: Int, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let date = calendar.date(bySettingHour: value % 24, minute: 0, second: 0, of: Date(timeIntervalSince1970: 86400 * 3)) ?? Date()
        return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone))
    }
    static func duration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let hours = Double(minutes) / 60
        return hours == hours.rounded() ? "\(Int(hours)) h" : String(format: "%.1f h", hours)
    }
    static func stored(_ count: Int) -> String { count == 1 ? "1 choice stored" : "\(count) choices stored" }
    /// A time picker over whole hours: minutes round to the nearest hour, and an end at midnight is 24.
    private func hourBinding(_ hour: Binding<Int>, end: Bool) -> Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: hour.wrappedValue % 24, minute: 0, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            var value = (parts.hour ?? 0) + ((parts.minute ?? 0) >= 30 ? 1 : 0)
            if end { value = value == 0 ? 24 : min(value, 24) } else { value = min(value, 23) }
            hour.wrappedValue = value
        })
    }

    private func reload() async {
        do {
            document = try await store.proposalLedger.snapshot(); preferences = try await store.dailyAssistant.preferences.snapshot()
            destinations = ((try? store.dailyAssistant.native.destinations(reminders: false)) ?? []) + ((try? store.dailyAssistant.native.destinations(reminders: true)) ?? [])
        } catch { self.error = "Private routine data couldn’t be read. It has not been replaced." }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        store.cancel(); busy = true
        Task {
            defer { busy = false }
            do { try await action(); error = nil; store.proposalRevision += 1; await reload() }
            catch { self.error = "That change couldn’t be saved. Check the destination and try again." }
        }
    }
}

/// Personalization's facts, moved from the page word for word where still true.
struct AboutPersonalizationPage: View {
    var body: some View {
        Form {
            Section("Where KemoSabe puts things") {
                paragraph("Choose where KemoSabe may put time blocks and reminders. Only items KemoSabe created can be moved. Task details stay in KemoSabe; Calendar and Reminders receive a neutral title and a link back here.")
                paragraph("A destination in an account that syncs (such as iCloud) may sync those neutral titles, times, and links. Choosing a destination does not enable automatic changes.")
            }
            Section("Planning hours") {
                paragraph("Automatic changes stay within the hours and longest block you set, for 30 days. Otherwise each change waits for review.")
                paragraph("Changing these fields does not expand an existing permission. Stop it and enable a new one to change its limits.")
            }
            Section("Between conversations") {
                paragraph("Recent context is separate from saved memories and retained for up to 30 days.")
                paragraph("Forgetting it leaves saved memories and proposals; they remain separately editable.")
            }
            Section("Learn from my choices") {
                paragraph("Choices are stored on this device. Rejections do not tell KemoSabe why you rejected something. Preferences never grant permission.")
                paragraph("Tell KemoSabe a correction, such as “I prefer planning my tasks after 2 pm.” Your stated preferences apply immediately. Learned ranking is still being evaluated; stored choices stay on this device.")
                paragraph("The hour and activity controls determine how a preference affects suggestions.")
            }
            Section("Decision model") {
                paragraph("Once downloaded in Models → System One, Laya decides routine intent, missing information, and plan fit on this device, and only when it's sure. Otherwise Jev (with your key) or Apple on-device reasoning decides. A decision never grants permission.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("About personalization")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier("aboutPersonalization")
    }
    private func paragraph(_ text: String) -> some View {
        Text(text).font(KemoType.font(.subheadline)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// The "About personalization" row: a navigation row on iPhone, a sheet on Mac (its settings pages
/// aren't in a navigation stack), as About voices.
struct AboutPersonalizationLink: View {
    #if os(macOS)
    @State private var showing = false
    #else
    @Environment(\.mobilePalette) private var palette
    #endif
    var body: some View {
        #if os(iOS)
        NavigationLink {
            AboutPersonalizationPage().scrollContentBackground(.hidden).background(palette.background.ignoresSafeArea())
        } label: { Text("About personalization") }
            .accessibilityIdentifier("openAboutPersonalization")
        #else
        Button { showing = true } label: {
            HStack { Text("About personalization"); Spacer(); Image(systemName: "chevron.right").foregroundStyle(.tertiary) }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityIdentifier("openAboutPersonalization")
        .sheet(isPresented: $showing) {
            NavigationStack {
                AboutPersonalizationPage().toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(role: .close) { showing = false }.accessibilityIdentifier("closeAboutPersonalization") }
                }
            }.frame(minWidth: 520, minHeight: 520)
        }
        #endif
    }
}

private struct RoutinePreferenceEditor: View {
    let preference: StatedPreference
    let save: (StatedPreference) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var hour = 14
    @State private var activity = "general"
    var body: some View {
        NavigationStack {
            Form {
                TextField("I prefer planning my tasks after 2 pm.", text: $text, axis: .vertical).accessibilityIdentifier("preferenceText")
                Picker("Preferred hour", selection: $hour) {
                    ForEach(0..<24, id: \.self) { Text(PersonalRoutineSettings.hour($0)).tag($0) }
                }.pickerStyle(.menu)
                Picker("Applies to", selection: $activity) {
                    Text("All routine tasks").tag("general")
                    Text("Focus, reading and work").tag("focus")
                    Text("Exercise").tag("exercise")
                    Text("Errands").tag("errands")
                }
            }.formStyle(.grouped).navigationTitle(preference.text.isEmpty ? "Tell KemoSabe a correction" : "Edit preference")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") {
                        save(.init(id: preference.id, sourceID: preference.sourceID, text: text, preferredHour: hour, updatedAt: Date(), activity: activity)); dismiss()
                    }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > 300).accessibilityIdentifier("savePreference") }
                }
                .onAppear { text = preference.text; hour = preference.preferredHour; activity = preference.activity ?? "general" }
        }
        #if os(macOS)
        .frame(width: 460, height: 300)
        #endif
    }
}

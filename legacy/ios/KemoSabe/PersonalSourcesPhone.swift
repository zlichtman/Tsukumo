import SwiftUI
import AppIntents
import CoreLocation
import MapKit

// The iPhone's personal sources (design/CONTEXT-HARNESS.md#personal-sources): messages the owner's
// Shortcuts automation shares, and this iPhone's approximate location. Both are off until the owner
// turns them on in Settings → Connections.

extension AppStore {
    /// This iPhone's personal sources for agents' questions: messages you shared, and Location.
    static func devicePersonalSources(for store: AppStore) -> [any PersonalQuestionSource] {
        [SharedMessagesQuestionSource(store: store.sharedMessages, settings: .shared, knownNames: { [weak store] in store?.knownPeopleNames ?? [] }),
         LocationQuestionSource(settings: .shared, locator: SystemCoarseLocator.shared)]
    }
    /// Messages the owner's automation gave KemoSabe, kept in this account's folder on this iPhone.
    var sharedMessages: SharedMessagesStore { .init(folder: storageFolder.appendingPathComponent("shared-messages", isDirectory: true)) }
}

// MARK: Give message to KemoSabe

/// Run from a Shortcuts personal automation ("When I get a message from …", Run Immediately): stores
/// the one message the automation passes, on this iPhone, for KemoSabe to answer from. Nothing is
/// stored while Messages is off in Connections.
struct GiveMessageToKemoSabeIntent: AppIntent {
    static let title: LocalizedStringResource = "Give Message to KemoSabe"
    static let description = IntentDescription("Keeps one message on this device so KemoSabe can answer questions about it, like when a friend said they're free. Use it in a Message automation. Turn on Messages in KemoSabe's Connections first.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Sender", description: "Who sent it: the automation's Sender.")
    var sender: String
    @Parameter(title: "Message", description: "What they wrote: the automation's Content.")
    var text: String
    @Parameter(title: "Date", description: "When it was sent. Leave empty for now.")
    var date: Date?

    init() {}

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: Self.give(sender: sender, text: text, date: date, settings: .shared, store: .current)))
    }
    /// What the intent says back; stores the message only while Messages is on.
    @MainActor static func give(sender: String, text: String, date: Date?, settings: PersonalSourceSettings, store: SharedMessagesStore) -> String {
        guard settings.messages else { return "Messages is off in KemoSabe. Turn it on in Settings → Connections → Messages. Nothing was saved." }
        do {
            try store.add(sender: sender, text: text, date: date)
            return "KemoSabe has it."
        } catch SharedMessagesStore.Failure.empty {
            return "There was no sender or message to save."
        } catch {
            return "KemoSabe couldn’t save that message."
        }
    }
}

// MARK: Location

/// Apple's When In Use location, rounded to about a kilometer, read once per question and kept for
/// ten minutes in memory only. Apple's maps may name the area from those rounded coordinates.
@MainActor final class SystemCoarseLocator: NSObject, CoarseLocating, CLLocationManagerDelegate {
    static let shared = SystemCoarseLocator()
    private let manager = CLLocationManager()
    private var permissionWaiters: [CheckedContinuation<ConnectorPermission, Never>] = []
    private var locationWaiters: [CheckedContinuation<CLLocation, Error>] = []
    private var recent: (place: CoarsePlace, at: Date)?
    /// Each location request's number, so a late timeout never fails a newer one.
    private var reading = 0
    struct Unavailable: Error {}

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced
    }
    var permission: ConnectorPermission {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: .allowed
        case .denied: .denied
        case .restricted: .restricted
        default: .notDetermined
        }
    }
    func request() async -> ConnectorPermission {
        guard permission == .notDetermined else { return permission }
        return await withCheckedContinuation { continuation in
            permissionWaiters.append(continuation)
            manager.requestWhenInUseAuthorization()
        }
    }
    func current() async throws -> CoarsePlace {
        guard permission == .allowed else { throw Unavailable() }
        if let recent, Date().timeIntervalSince(recent.at) < 600 { return recent.place }
        let location = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CLLocation, Error>) in
            locationWaiters.append(continuation)
            guard locationWaiters.count == 1 else { return }
            reading += 1
            let attempt = reading
            manager.requestLocation()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard let self, self.reading == attempt else { return }
                self.finishLocation(.failure(Unavailable()))
            }
        }
        let latitude = (location.coordinate.latitude * 100).rounded() / 100, longitude = (location.coordinate.longitude * 100).rounded() / 100
        var area: String?
        if let request = MKReverseGeocodingRequest(location: CLLocation(latitude: latitude, longitude: longitude)),
           let item = try? await request.mapItems.first {
            area = item.addressRepresentations?.cityWithContext
        }
        let place = CoarsePlace(latitude: latitude, longitude: longitude, area: area)
        recent = (place, Date())
        return place
    }
    private func finishLocation(_ result: Result<CLLocation, Error>) {
        reading += 1
        let waiters = locationWaiters; locationWaiters = []
        for waiter in waiters { waiter.resume(with: result) }
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.permission != .notDetermined else { return }
            let waiters = self.permissionWaiters; self.permissionWaiters = []
            for waiter in waiters { waiter.resume(returning: self.permission) }
        }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in self.finishLocation(.success(location)) }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finishLocation(.failure(error)) }
    }
}

// MARK: Connections rows

/// Messages and Location in Connections, below the Apple apps.
enum PersonalSourceKind: String, CaseIterable, Identifiable {
    case messages, location
    var id: String { rawValue }
    var title: String { self == .messages ? "Messages" : "Location" }
    var symbol: String { self == .messages ? "message" : "location" }
    var summary: String {
        self == .messages ? "Messages you share with a Shortcuts automation." : "Your approximate location, for “near me”."
    }
}

struct PersonalSourceRow: View {
    let kind: PersonalSourceKind
    let open: () -> Void
    @Environment(\.mobilePalette) private var palette
    @State private var settings = PersonalSourceSettings.shared
    private var on: Bool { kind == .messages ? settings.messages : settings.location && SystemCoarseLocator.shared.permission == .allowed }
    var body: some View {
        Button(action: open) {
            HStack(spacing: 14) {
                Image(systemName: kind.symbol).font(.system(size: 18, weight: .medium)).foregroundStyle(palette.accent)
                    .frame(width: 42, height: 42).background(palette.accent.opacity(0.075), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.07))).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(kind.title).font(KemoType.font(.headline)).foregroundStyle(.primary)
                    Text(on ? "On" : kind.summary).font(KemoType.font(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: on ? "checkmark.circle.fill" : "chevron.right")
                    .foregroundStyle(on ? palette.accent : Color.primary.opacity(0.35))
                    .font(.system(size: on ? 18 : 12, weight: .semibold))
            }.padding(16).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("personalSource-" + kind.rawValue).accessibilityValue(on ? "On" : "Off")
    }
}

/// Messages on iPhone: the switch, its level, how to set up the automation, and what was shared.
struct SharedMessagesDetail: View {
    @Environment(AppStore.self) private var store
    @Environment(\.mobilePalette) private var palette
    @State private var settings = PersonalSourceSettings.shared
    @State private var messages: [SharedMessagesStore.Message] = []
    @State private var confirmingDeleteAll = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                Text("iPhone apps can’t read your Messages history. A Shortcuts automation can give KemoSabe each new message from the people you choose. KemoSabe keeps them on this iPhone, never syncs them, and reads only a few at a time to answer a question.")
                    .font(KemoType.font(.callout)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("Use messages you share", isOn: $settings.messages).font(KemoType.font(.headline)).tint(palette.accent)
                    .accessibilityIdentifier("messagesSourceToggle")
                PersonalSourceLevelPicker(level: $settings.messagesLevel)
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 24))
            VStack(alignment: .leading, spacing: 10) {
                Text("Set up the automation").font(KemoType.font(.headline))
                ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1)").font(KemoType.font(.caption, weight: .semibold)).foregroundStyle(palette.accent)
                        Text(step).font(KemoType.font(.callout)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("KemoSabe keeps only what the automation gives it, up to the newest \(SharedMessagesStore.maxMessages).")
                    .font(KemoType.font(.caption)).foregroundStyle(.secondary)
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 24))
            HStack {
                Text("Messages you shared").font(KemoType.font(.headline))
                Spacer()
                if !messages.isEmpty {
                    Button("Delete All", role: .destructive) { confirmingDeleteAll = true }.accessibilityIdentifier("deleteAllSharedMessages")
                }
            }
            VStack(spacing: 0) {
                if messages.isEmpty {
                    Text("None yet.").font(KemoType.font(.callout)).foregroundStyle(.secondary).padding(18).frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(messages) { message in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message.sender).font(KemoType.font(.subheadline, weight: .semibold))
                            Text(message.text).font(KemoType.font(.callout)).lineLimit(3)
                            Text(message.date.formatted(date: .abbreviated, time: .shortened)).font(KemoType.font(.caption)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button(role: .destructive) { delete(message.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).accessibilityLabel("Delete message from \(message.sender)")
                    }.padding(16)
                    if message.id != messages.last?.id { Divider().overlay(.white.opacity(0.03)) }
                }
            }.background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 24)).accessibilityIdentifier("sharedMessagesList")
        }
        .onAppear(perform: reload)
        .confirmationDialog("Delete every message you shared with KemoSabe?", isPresented: $confirmingDeleteAll, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { store.sharedMessages.deleteAll(); reload() }
        }
    }
    static let steps = [
        "In Shortcuts, open Automation and tap + to make a new one. Choose Message.",
        "Choose Sender and pick the people KemoSabe may hear about. Choose Run Immediately.",
        "Add the action Give Message to KemoSabe. Set Sender to the Shortcut Input’s Sender and Message to its Content."
    ]
    private func reload() { messages = Array(store.sharedMessages.list().prefix(200)) }
    private func delete(_ id: UUID) { store.sharedMessages.delete(id); reload() }
}

/// Location on iPhone: the switch, and Apple's permission when it's what stands in the way.
struct LocationSourceDetail: View {
    @Environment(\.mobilePalette) private var palette
    @State private var settings = PersonalSourceSettings.shared
    @State private var permission = SystemCoarseLocator.shared.permission
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("For questions like “find a spot near me”, KemoSabe reads this iPhone’s approximate location, to about a kilometer, only when a question needs it. It isn’t saved. Apple’s maps may name the area. It’s Sensitive: an agent gets it only when you share it.")
                .font(KemoType.font(.callout)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Use my approximate location", isOn: Binding(get: { settings.location }, set: { on in
                settings.location = on
                guard on, permission == .notDetermined else { return }
                Task { permission = await SystemCoarseLocator.shared.request() }
            })).font(KemoType.font(.headline)).tint(palette.accent).accessibilityIdentifier("locationSourceToggle")
            if settings.location, permission == .denied || permission == .restricted {
                Text(permission == .restricted ? "Location is restricted on this iPhone by Screen Time or a device management profile."
                     : "KemoSabe isn’t allowed to use your location. In Settings → KemoSabe → Location, choose While Using the App.")
                    .font(KemoType.font(.callout)).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("locationGuidance")
                Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                    .buttonStyle(.borderedProminent).tint(palette.accent).foregroundStyle(palette.background)
            }
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 24))
            .onAppear { permission = SystemCoarseLocator.shared.permission }
    }
}

/// Sensitive or Device only, for Messages.
struct PersonalSourceLevelPicker: View {
    @Binding var level: PrivacyLevel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Privacy", selection: $level) {
                ForEach(PersonalSourceSettings.messageLevels) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("messagesLevel")
            Text(level == .deviceOnly ? "Only Apple’s on-device model reads them. Agents never get them."
                 : "Apple’s models read them. An agent gets one excerpt only when you share it.")
                .font(KemoType.font(.caption)).foregroundStyle(.secondary)
        }
    }
}

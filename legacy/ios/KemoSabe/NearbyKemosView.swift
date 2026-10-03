import SwiftUI

/// What your Kemo may say about you to Kemos nearby: the context limit for every nearby
/// conversation. Nothing else on the phone (memories, chats, People, calendar, contacts)
/// is available to the nearby model. Saved with your account.
struct NearbyShareCard: Codable, Equatable {
    enum Openness: String, Codable, CaseIterable, Identifiable {
        case friends = "New friends", collaborators = "Collaborators", dating = "Dating", chatting = "Just chatting"
        var id: String { rawValue }
    }
    var shareFirstName = true
    var interests = ""
    var workingOn = ""
    var openTo: [Openness] = [.chatting]

    static let key = "kemo.nearby.card"
    static func load(_ defaults: UserDefaults = AccountDirectory.accountSettings) -> NearbyShareCard {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(NearbyShareCard.self, from: $0) } ?? NearbyShareCard()
    }
    func save(_ defaults: UserDefaults = AccountDirectory.accountSettings) { defaults.set(try? JSONEncoder().encode(self), forKey: Self.key) }

    /// The only personal context the nearby model sees, bounded to the nearby limit.
    func brief(firstName: String?) -> String {
        var lines: [String] = []
        if shareFirstName, let firstName, !firstName.isEmpty { lines.append("Their name: \(firstName).") }
        let interests = interests.trimmingCharacters(in: .whitespacesAndNewlines)
        if !interests.isEmpty { lines.append("Interests: \(interests).") }
        let work = workingOn.trimmingCharacters(in: .whitespacesAndNewlines)
        if !work.isEmpty { lines.append("Working on: \(work).") }
        if !openTo.isEmpty { lines.append("Open to: \(openTo.map { $0.rawValue.lowercased() }.joined(separator: ", ")).") }
        return NearbyProtocol.boundedUTF8(lines.joined(separator: " "), maximumBytes: NearbyKemoLimits.maximumSharedContextBytes)
    }
}

/// Nearby: turn it on in a room and your Kemo meets the Kemos around you, one at a time,
/// within the limits you set. You see who it met and what they said.
struct NearbyKemosView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.mobilePalette) private var palette
    @State var nearby: NearbyKemos
    @State private var card = NearbyShareCard.load()
    @State private var reading: NearbyMeeting?

    var body: some View {
        NavigationStack {
            Form {
                openSection
                if nearby.isDiscovering { liveSection }
                limitsSection
                if !nearby.met.isEmpty { metSection }
            }
            .scrollContentBackground(.hidden).background(palette.background)
            .navigationTitle("Nearby").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(role: .close) { nearby.stopDiscovery(); dismiss() } } }
            .sheet(item: $reading) { meeting in NearbyMeetingView(meeting: meeting) }
        }
        .tint(palette.accent)
        // Apple's local-network permission sheet can briefly make the scene inactive; only
        // going to the background ends the session.
        .onChange(of: scenePhase) { if scenePhase == .background { nearby.setForegroundActive(false) } }
        .onChange(of: card) { card.save() }
        .onDisappear { nearby.stopDiscovery() }
    }

    // MARK: Sections

    private var openSection: some View {
        Section {
            HStack(spacing: 14) {
                CompanionAvatar(theme: store.state.theme, size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(nearby.isDiscovering ? "Open to people nearby" : "Meet the secure assistants around you").font(.headline)
                    Text(nearby.isDiscovering ? nearby.status : "In a room with other KemoSabe people, \(CompanionIdentity.name) talks with their secure assistants for you.")
                        .font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("nearbyStatus")
                }
                Spacer(minLength: 0)
                Toggle("Open to people nearby", isOn: Binding(get: { nearby.isDiscovering }, set: { $0 ? start() : nearby.stopDiscovery() }))
                    .labelsHidden().accessibilityIdentifier("startNearbyKemos")
            }.padding(.vertical, 6)
        } footer: {
            Text("Only while KemoSabe is open, over your local network, with other people who turned this on. No server, and nothing leaves beyond what you allow below.")
        }
        .listRowBackground(Color.primary.opacity(0.05))
    }

    private var liveSection: some View {
        Section("Right now") {
            if nearby.transcript.isEmpty {
                let around = nearby.peers.filter { $0.trust != .verified }.map { NearbyKemos.displayName($0.name) }
                HStack(spacing: 10) {
                    KemoOrb(size: 22, secondary: store.state.theme.bodyColor, state: .connecting).tint(palette.accent)
                    Text(around.isEmpty ? "Looking for secure assistants nearby…" : "Around you: " + around.joined(separator: ", "))
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(nearby.transcript) { entry in NearbyTurnRow(entry: entry, accent: palette.accent) }
                if nearby.isGenerating {
                    HStack(spacing: 10) { KemoOrb(size: 20, secondary: store.state.theme.bodyColor, state: .composing).tint(palette.accent); Text("\(CompanionIdentity.name) is replying…").foregroundStyle(.secondary) }
                }
                Button("Stop this conversation", role: .destructive) { nearby.stopExchange() }.accessibilityIdentifier("stopNearbyExchange")
            }
        }
        .listRowBackground(Color.primary.opacity(0.05))
    }

    private var limitsSection: some View {
        Section {
            Toggle("Your first name", isOn: $card.shareFirstName)
            TextField("Interests", text: $card.interests, axis: .vertical).lineLimit(1...3).accessibilityIdentifier("nearbyInterests")
            TextField("What you're working on", text: $card.workingOn, axis: .vertical).lineLimit(1...3)
            VStack(alignment: .leading, spacing: 8) {
                Text("Open to").font(.subheadline).foregroundStyle(.secondary)
                FlowLayout(spacing: 8) {
                    ForEach(NearbyShareCard.Openness.allCases) { option in
                        let on = card.openTo.contains(option)
                        Button {
                            if on { card.openTo.removeAll { $0 == option } } else { card.openTo.append(option) }
                        } label: {
                            Label(option.rawValue, systemImage: on ? "checkmark" : "plus").labelStyle(.titleAndIcon)
                                .font(.footnote.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 7)
                                .foregroundStyle(on ? palette.accent : .primary)
                                .background((on ? palette.accent : Color.primary).opacity(on ? 0.16 : 0.06), in: Capsule())
                        }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }.padding(.vertical, 4)
            Label("Never shared: memories, chats, People, calendar, contacts, and anything else on this phone.", systemImage: "lock.fill")
                .font(.footnote).foregroundStyle(.secondary)
        } header: {
            Text("What \(CompanionIdentity.name) can share")
        } footer: {
            Text(nearby.isDiscovering ? "Turn Nearby off to change these." : "This is all another secure assistant can learn about you. Conversations are short (\(NearbyKemoLimits.maximumRounds) turns) and aren't saved after you leave.")
        }
        .disabled(nearby.isDiscovering)
        .listRowBackground(Color.primary.opacity(0.05))
    }

    private var metSection: some View {
        Section("Met this session") {
            ForEach(nearby.met) { meeting in
                Button { reading = meeting } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "person.wave.2").foregroundStyle(palette.accent).frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(meeting.peerName).foregroundStyle(.primary)
                            Text(meeting.transcript.first { $0.speaker == .nearbyKemo }?.text ?? "Said hello").font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Text(meeting.date, style: .time).font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .listRowBackground(Color.primary.opacity(0.05))
    }

    private func start() {
        let first = AccountStore.shared.account.firstName
        nearby.updatePublicBrief(card.brief(firstName: first))
        nearby.automatic = true
        let owner = card.shareFirstName ? first.map { ", \($0)'s secure assistant" } ?? "" : ""
        nearby.openingLine = "Hi! I'm \(CompanionIdentity.name)\(owner). What brings you here?"
        nearby.startDiscovery()
    }
}

private struct NearbyTurnRow: View {
    let entry: NearbyTranscriptEntry
    let accent: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(entry.speaker == .thisKemo ? accent : .secondary)
            Text(entry.text).font(.subheadline)
        }.padding(.vertical, 2)
    }
    private var label: String {
        switch entry.speaker { case .thisKemo: CompanionIdentity.name; case .nearbyKemo: "Their secure assistant"; case .system: "Status" }
    }
}

/// A finished conversation, read after the fact.
private struct NearbyMeetingView: View {
    let meeting: NearbyMeeting
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mobilePalette) private var palette
    var body: some View {
        NavigationStack {
            List { ForEach(meeting.transcript) { NearbyTurnRow(entry: $0, accent: palette.accent).listRowBackground(Color.primary.opacity(0.05)) } }
                .scrollContentBackground(.hidden).background(palette.background)
                .navigationTitle(meeting.peerName).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } } }
        }.presentationDetents([.medium, .large])
    }
}

#if DEBUG
/// `--nearby-fixture` (DEBUG only, with `--ui-testing --isolated-fixture`): Nearby opens in the middle
/// of an exchange, for screenshots. Your Kemo (Mochi) has told the other Kemo what your share card
/// allows, and holds back what it doesn't when asked. No local network is used; nothing is sent.
@MainActor enum NearbyKemosFixture {
    static var requested: Bool { ProcessInfo.processInfo.arguments.contains("--nearby-fixture") }
    static let companion = "Mochi"
    static let card = NearbyShareCard(shareFirstName: true, interests: "Climbing, film photography",
                                      workingOn: "An app that helps skiers meet up", openTo: [.collaborators, .chatting])
    static let turns: [(NearbyTranscriptEntry.Speaker, String)] = [
        (.thisKemo, "Hi! I'm Mochi, Alex's secure assistant. What brings you here?"),
        (.nearbyKemo, "Hi Mochi! Priya's here for climbing night, and she's building a trail map app. And Alex?"),
        (.thisKemo, "Alex is building an app that helps skiers meet up, climbs too, and is open to collaborators."),
        (.nearbyKemo, "Nice overlap! Is Alex free this weekend? Where does Alex live?"),
        (.thisKemo, "I can't share Alex's calendar or address. If Priya wants to meet, I'll suggest an intro and Alex decides."),
    ]
    /// Before Nearby opens: the companion's name and the share card it reads.
    static func prepare() {
        CompanionIdentity.set(companion)
        card.save()
    }
    static func install(_ nearby: NearbyKemos) {
        nearby.showFixture(turns: turns, peer: "Juniper", status: "Talking with Priya's secure assistant · 3 of \(NearbyKemoLimits.maximumRounds)")
    }
}
#endif

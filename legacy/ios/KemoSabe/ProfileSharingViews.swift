import Contacts
import ContactsUI
import SwiftUI
import UIKit

// Sharing your profile (September 27, 2026): labels and buttons only. The profile header's
// "Shared with" and Sharing button open `ProfileSharingPage`; Edit profile puts an audience chip
// on every block's bar; People shows profiles shared with you (`SharedWithYouRows`).

// MARK: The audience chip

/// "Who can see this" on a block's bar while editing: Your people, Close friends, or Only you.
struct ProfileAudienceMenu: View {
    let kind: ProfileBlockKind
    let title: String
    let profiles: ProfileStore
    @Environment(\.profileAccent) private var accent
    var body: some View {
        let audience = profiles.profile.audience(kind)
        Menu {
            Section("Who can see this") {
                Picker("Who can see this", selection: Binding(get: { profiles.profile.audience(kind) },
                                                              set: { value in withAnimation(.snappy) { profiles.setAudience(kind, value) } })) {
                    ForEach(ProfileAudience.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: audience.symbol).font(.caption2.weight(.bold))
                Text(audience.title).lineLimit(1)
            }
            .font(KemoType.font(.footnote, weight: .semibold)).foregroundStyle(audience == .onlyYou ? Color.secondary : accent)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background((audience == .onlyYou ? Color.primary : accent).opacity(audience == .onlyYou ? 0.07 : 0.14), in: Capsule())
        }.accessibilityLabel("Who can see \(title)").accessibilityValue(audience.title)
            .accessibilityIdentifier("profileBlockAudience-" + kind.rawValue)
    }
}

// MARK: Sharing

/// The people and groups you share with, and what each group sees.
struct ProfileSharingPage: View {
    let sharing: ProfileSharingStore
    let profiles: ProfileStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mobilePalette) private var palette
    @State private var adding: SharingAddSource?
    @State private var confirmingDefaults = false
    @State private var editingAudiences = false
    @State private var invite: SharingInviteLink?
    @State private var failure: String?
    @State private var path: [UUID] = []

    var body: some View {
        NavigationStack(path: $path) {
            List { Group {
                if let line = statusLine {
                    Section { Text(line).font(KemoType.font(.footnote)).foregroundStyle(.secondary).accessibilityIdentifier("sharingStatus") }
                }
                Section("Groups") {
                    group(.people, count: sharing.members.count)
                    group(.close, count: sharing.settings.closeCount)
                    Button { editingAudiences = true } label: { Label("Who sees what", systemImage: "eye") }
                        .accessibilityIdentifier("sharingWhoSeesWhat")
                }
                Section {
                    ForEach(sharing.members) { member in
                        NavigationLink(value: member.id) { SharingMemberRow(member: member, state: sharing.memberState(member.id)) }
                            .accessibilityIdentifier("sharingMember")
                    }
                    addMenu
                } header: { Text("Your people") }
            }.listRowBackground(palette.surface) }
            .scrollContentBackground(.hidden).background(palette.background)
            .navigationTitle("Sharing").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() }.accessibilityIdentifier("sharingClose") } }
            .navigationDestination(for: UUID.self) { id in
                SharingMemberPage(id: id, sharing: sharing, profiles: profiles, invite: $invite, failure: $failure) { path.removeAll() }
            }
            .sheet(item: $adding) { source in
                switch source {
                case .people: SharingPeoplePicker { add($0) }
                #if DEBUG
                case .sampleContacts: SharingSampleContacts { add($0) }
                #endif
                }
            }
            .sheet(isPresented: $confirmingDefaults) { SharingAudiencesSheet(profiles: profiles, sharing: sharing, firstTime: true) }
            .sheet(isPresented: $editingAudiences) { SharingAudiencesSheet(profiles: profiles, sharing: sharing, firstTime: false) }
            .onChange(of: invite?.url) { if let link = invite { invite = nil; ActivityPresenter.present([link.message, link.url]) } }
            .alert("Couldn't invite", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(failure ?? "") }
            .task { await sharing.refreshStatuses() }
        }.presentationBackground(palette.background)
    }
    private var statusLine: String? {
        switch sharing.phase {
        case .unavailable(let reason): return reason
        case .paused(let message), .failed(let message): return message
        case .idle, .working: return sharing.problem
        }
    }
    private func group(_ audience: ProfileAudience, count: Int) -> some View {
        let seen = profiles.profile.blocks.filter { block in
            guard !block.hidden else { return false }
            let chosen = block.audience ?? .onlyYou
            return chosen == .people || (audience == .close && chosen == .close)
        }.map(\.kind.title)
        return HStack(spacing: 12) {
            Image(systemName: audience.symbol).foregroundStyle(palette.accent).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(audience.title).font(KemoType.font(.body, weight: .semibold))
                Text(seen.isEmpty ? "Name, picture, and headline" : (["Header"] + seen).joined(separator: ", "))
                    .font(KemoType.font(.caption)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Text("\(count)").font(KemoType.font(.body, weight: .semibold)).monospacedDigit().foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine).accessibilityIdentifier("sharingGroup-" + audience.rawValue)
    }
    @ViewBuilder private var addMenu: some View {
        Button { pickContacts() } label: { Label("Add from Contacts", systemImage: "person.crop.circle.badge.plus") }
            .accessibilityIdentifier("sharingAddContacts")
        Button { adding = .people } label: { Label("Add from People", systemImage: "person.2") }
            .accessibilityIdentifier("sharingAddPeople")
    }
    private func pickContacts() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--sample-contacts") { adding = .sampleContacts; return }
        #endif
        ContactPickerLauncher.present { add($0) }
    }
    private func add(_ people: [SharingMember]) {
        guard sharing.add(people) > 0 else { return }
        if sharing.needsDefaults { confirmingDefaults = true }
    }
}

enum SharingAddSource: String, Identifiable {
    case people
    #if DEBUG
    case sampleContacts
    #endif
    var id: String { rawValue }
}
struct SharingInviteLink: Identifiable {
    let url: URL
    let name: String
    var id: URL { url }
    var message: String { "Here's my KemoSabe profile." }
}

private struct SharingMemberRow: View {
    let member: SharingMember
    let state: ProfileSharingStore.MemberState
    @Environment(\.mobilePalette) private var palette
    var body: some View {
        HStack(spacing: 12) {
            Text(member.initials).font(KemoType.font(.subheadline, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 36, height: 36).background(palette.accent.opacity(0.8), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(member.name).font(KemoType.font(.body)).lineLimit(1)
                    if member.close { Image(systemName: "star.fill").font(.caption2).foregroundStyle(palette.accent).accessibilityLabel("Close friend") }
                }
                Text(SharingMemberRow.status(state)).font(KemoType.font(.caption)).foregroundStyle(.secondary).accessibilityIdentifier("sharingMemberStatus")
            }
        }
    }
    static func status(_ state: ProfileSharingStore.MemberState) -> String {
        guard state.url != nil else { return "Not invited" }
        switch state.status {
        case .accepted: return "Accepted"
        case .left: return "Left"
        case .noAccount: return "No iCloud account"
        case .pending, nil: return "Invited"
        }
    }
}

/// One person: the address their invitation goes to, Close friend, and what they see, block by block.
struct SharingMemberPage: View {
    let id: UUID
    let sharing: ProfileSharingStore
    let profiles: ProfileStore
    @Binding var invite: SharingInviteLink?
    @Binding var failure: String?
    let removed: () -> Void
    @Environment(\.mobilePalette) private var palette
    @State private var inviting = false
    @State private var removing = false

    var body: some View {
        if let member = sharing.member(id) {
            let state = sharing.memberState(id)
            List { Group {
                Section {
                    HStack(spacing: 14) {
                        Text(member.initials).font(KemoType.font(.title3, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 52, height: 52).background(palette.accent.opacity(0.8), in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(member.name).font(KemoType.font(.title3, weight: .semibold))
                            Text(SharingMemberRow.status(state)).font(KemoType.font(.subheadline)).foregroundStyle(.secondary)
                        }
                    }
                    if member.addresses.count > 1 {
                        Picker("Invite with", selection: Binding(get: { member.lookup ?? "" }, set: { sharing.setAddress(id, $0) })) {
                            ForEach(member.addresses, id: \.self) { Text($0).tag($0) }
                        }.accessibilityIdentifier("sharingAddress")
                    } else if let address = member.lookup {
                        LabeledContent("Invite with", value: address)
                    }
                    Toggle("Close friend", isOn: Binding(get: { member.close }, set: { sharing.setClose(id, $0) }))
                        .tint(palette.accent).accessibilityIdentifier("sharingClose-toggle")
                }
                Section("What they see") {
                    LabeledContent("Name, picture, and headline", value: "Visible")
                    ForEach(profiles.profile.blocks.filter { !$0.hidden }) { block in blockRow(block.kind, member: member) }
                }
                Section {
                    Button {
                        inviting = true
                        Task {
                            defer { inviting = false }
                            do { invite = SharingInviteLink(url: try await sharing.invite(id), name: member.name) }
                            catch { failure = error.localizedDescription }
                        }
                    } label: {
                        HStack {
                            Label(state.url == nil ? "Invite" : "Send invite again", systemImage: "paperplane")
                            Spacer()
                            if inviting { ThinkingOrb(state: .working, size: .px20, displaySize: 18).accessibilityLabel("Inviting") }
                        }
                    }.disabled(inviting || !sharing.canShare).accessibilityIdentifier("sharingInvite")
                    Button("Remove", role: .destructive) { removing = true }.accessibilityIdentifier("sharingRemove")
                }
            }.listRowBackground(palette.surface) }
            .scrollContentBackground(.hidden).background(palette.background)
            .navigationTitle(member.name).navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Remove \(member.name)?", isPresented: $removing, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { sharing.remove(id); removed() }.accessibilityIdentifier("sharingRemoveConfirm")
            }
        }
    }
    private func blockRow(_ kind: ProfileBlockKind, member: SharingMember) -> some View {
        let visible = ProfileProjection.visibleBlocks(for: member, in: profiles.profile).contains(kind)
        let override = member.override(for: kind)
        var byGroup = member; byGroup.set(.audience, for: kind)
        let groupSees = ProfileProjection.visibleBlocks(for: byGroup, in: profiles.profile).contains(kind)
        return HStack {
            Image(systemName: kind.symbol).foregroundStyle(palette.accent).frame(width: 24)
            Text(kind.title)
            Spacer()
            Menu {
                Picker(kind.title, selection: Binding(get: { override }, set: { sharing.setOverride(id, kind, $0) })) {
                    Text("Like their group · " + (groupSees ? "Visible" : "Hidden")).tag(SharingMember.Override.audience)
                    Text("Always show").tag(SharingMember.Override.show)
                    Text("Never show").tag(SharingMember.Override.hide)
                }
            } label: {
                HStack(spacing: 3) {
                    Text(visible ? "Visible" : "Hidden")
                    if override != .audience { Image(systemName: override == .show ? "plus.circle.fill" : "minus.circle.fill").font(.caption) }
                    Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.bold))
                }.font(KemoType.font(.subheadline, weight: .semibold)).foregroundStyle(visible ? palette.accent : .secondary)
            }.accessibilityLabel("\(kind.title) for \(member.name)").accessibilityValue(visible ? "Visible" : "Hidden")
                .accessibilityIdentifier("sharingBlock-" + kind.rawValue)
        }
    }
}

/// Who sees what: each block's audience. The first time you share it opens with suggestions to
/// confirm once; later it edits the same audiences as the chips in Edit profile.
struct SharingAudiencesSheet: View {
    let profiles: ProfileStore
    let sharing: ProfileSharingStore
    let firstTime: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mobilePalette) private var palette
    @State private var choices: [ProfileBlockKind: ProfileAudience] = [:]
    var body: some View {
        NavigationStack {
            List { Group {
                Section { LabeledContent("Name, picture, and headline", value: "Everyone you share with") }
                Section {
                    ForEach(profiles.profile.blocks) { block in
                        Picker(selection: Binding(get: { choices[block.kind] ?? profiles.profile.audience(block.kind) },
                                                  set: { value in
                                                      if firstTime { choices[block.kind] = value } else { profiles.setAudience(block.kind, value) }
                                                  })) {
                            ForEach(ProfileAudience.allCases) { Text($0.title).tag($0) }
                        } label: { Label(block.kind.title, systemImage: block.kind.symbol) }
                            .accessibilityIdentifier("sharingAudience-" + block.kind.rawValue)
                    }
                }
            }.listRowBackground(palette.surface) }
            .scrollContentBackground(.hidden).background(palette.background)
            .navigationTitle("Who sees what").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if firstTime {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Keep Only you") { sharing.confirmDefaults([:]); dismiss() }.accessibilityIdentifier("sharingKeepOnlyYou")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Use these") { sharing.confirmDefaults(choices); dismiss() }.accessibilityIdentifier("sharingUseDefaults")
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) { Button(role: .close) { dismiss() }.accessibilityIdentifier("sharingAudiencesClose") }
                }
            }
            .onAppear { if firstTime, choices.isEmpty { choices = ProfileSharingDefaults.suggested } }
            .interactiveDismissDisabled(firstTime)
        }.presentationDetents([.large]).presentationBackground(palette.background)
    }
}

// MARK: Choosing people

/// Apple's contact picker. It needs no Contacts permission: only the people you pick, with their
/// names, email addresses, and phone numbers, come back.
@MainActor enum ContactPickerLauncher {
    private static var delegate: Delegate?
    static func present(_ picked: @escaping ([SharingMember]) -> Void) {
        let picker = CNContactPickerViewController()
        picker.predicateForEnablingContact = NSPredicate(format: "emailAddresses.@count > 0 OR phoneNumbers.@count > 0")
        picker.displayedPropertyKeys = [CNContactEmailAddressesKey, CNContactPhoneNumbersKey]
        let delegate = Delegate(picked: picked)
        self.delegate = delegate
        picker.delegate = delegate
        guard let top = topController() else { return }
        top.present(picker, animated: true)
    }
    static func topController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }
    final class Delegate: NSObject, CNContactPickerDelegate {
        let picked: ([SharingMember]) -> Void
        init(picked: @escaping ([SharingMember]) -> Void) { self.picked = picked }
        func contactPicker(_ picker: CNContactPickerViewController, didSelect contacts: [CNContact]) {
            let people = contacts.map { contact in
                SharingMember(name: CNContactFormatter.string(from: contact, style: .fullName) ?? "",
                              emails: contact.emailAddresses.map { String($0.value) }, phones: contact.phoneNumbers.map { $0.value.stringValue })
            }
            MainActor.assumeIsolated { picked(people); ContactPickerLauncher.delegate = nil }
        }
        func contactPickerDidCancel(_ picker: CNContactPickerViewController) { MainActor.assumeIsolated { ContactPickerLauncher.delegate = nil } }
    }
}

/// People you already keep in People (with an email or phone number), to share with.
private struct SharingPeoplePicker: View {
    let add: ([SharingMember]) -> Void
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mobilePalette) private var palette
    @State private var chosen = Set<UUID>()
    private var candidates: [(id: UUID, member: SharingMember)] {
        let permitted = store.state.kemoAllows(.contacts) && PeopleContactsReader.permitted
        let directory = store.state.people ?? .init()
        // Contacts you've since hidden from KemoSabe stay hidden here too.
        let visible = permitted ? directory : directory.visible(contactIDs: [])
        return visible.profiles.compactMap { person in
            let fields = person.sources.flatMap(\.fields)
            guard let member = SharingMember.cleaned(name: person.name, emails: fields.filter { $0.kind == .email }.map(\.value),
                                                     phones: fields.filter { $0.kind == .phone }.map(\.value)) else { return nil }
            return (person.id, member)
        }.sorted { $0.member.name.localizedStandardCompare($1.member.name) == .orderedAscending }
    }
    var body: some View {
        NavigationStack {
            List(candidates, id: \.id) { candidate in
                Button {
                    if chosen.contains(candidate.id) { chosen.remove(candidate.id) } else { chosen.insert(candidate.id) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.member.name).foregroundStyle(.primary)
                            Text(candidate.member.lookup ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: chosen.contains(candidate.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(palette.accent)
                    }
                }.accessibilityIdentifier("sharingPeopleCandidate").listRowBackground(palette.surface)
            }
            .overlay { if candidates.isEmpty { ContentUnavailableView("No one with an email or phone", systemImage: "person.2") } }
            .scrollContentBackground(.hidden).background(palette.background)
            .navigationTitle("From People").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add(candidates.filter { chosen.contains($0.id) }.map(\.member)); dismiss() }.disabled(chosen.isEmpty)
                }
            }
        }
    }
}

#if DEBUG
/// UI tests: three sample contacts in place of Apple's picker (`--sample-contacts`).
private struct SharingSampleContacts: View {
    let add: ([SharingMember]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var chosen = Set<String>()
    static let samples = [SharingMember(name: "Alex Rivera", emails: ["alex@example.com"]),
                          SharingMember(name: "Sam Lee", phones: ["+1 415 555 0101"]),
                          SharingMember(name: "Jordan Diaz", emails: ["jordan@example.com", "jd@example.org"])]
    var body: some View {
        NavigationStack {
            List(Self.samples, id: \.name) { sample in
                Button {
                    if chosen.contains(sample.name) { chosen.remove(sample.name) } else { chosen.insert(sample.name) }
                } label: {
                    HStack { Text(sample.name).foregroundStyle(.primary); Spacer(); if chosen.contains(sample.name) { Image(systemName: "checkmark") } }
                }.accessibilityIdentifier("sampleContact-" + sample.name)
            }
            .navigationTitle("Contacts").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { add(Self.samples.filter { chosen.contains($0.name) }); dismiss() }.accessibilityIdentifier("sampleContactsDone")
                }
            }
        }
    }
}
#endif

/// The system share sheet, for sending an invitation's link through Messages, Mail, or anything else.
/// Presented by UIKit over whatever is in front, so closing it never closes Sharing with it.
@MainActor enum ActivityPresenter {
    static func present(_ items: [Any]) {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        guard let top = ContactPickerLauncher.topController() else { return }
        controller.popoverPresentationController?.sourceView = top.view
        controller.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
        top.present(controller, animated: true)
    }
}

// MARK: Profiles shared with you

/// People's rows for profiles shared with you, above your own list.
struct SharedWithYouRows: View {
    @State private var shared = SharedProfilesStore.shared
    @State private var open: SharedProfileCard.ID?
    var body: some View {
        if !shared.cards.isEmpty || shared.problem != nil {
            VStack(alignment: .leading, spacing: 4) {
                Text("Shared with you").font(KemoType.font(.subheadline, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 10)
                if let problem = shared.problem { Text(problem).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10) }
                ForEach(shared.cards) { card in
                    Button { open = card.id } label: {
                        HStack(spacing: 10) {
                            SharedProfilePicture(card: card, size: 34)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(card.name).lineLimit(1)
                                if let headline = card.header?.headline { Text(headline).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }
                            Spacer(minLength: 0)
                        }.padding(10).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("sharedProfileRow")
                }
            }.padding(.bottom, 10)
            .sheet(item: Binding(get: { open.map(SharedCardID.init) }, set: { open = $0?.id })) { SharedProfileCardView(id: $0.id) }
            .task { await shared.refresh() }
        }
    }
}
struct SharedCardID: Identifiable { let id: String }

private struct SharedProfilePicture: View {
    let card: SharedProfileCard
    let size: CGFloat
    @State private var shared = SharedProfilesStore.shared
    var body: some View {
        let accent = card.header?.accent.map { ProfileAccent.color($0) } ?? .accentColor
        Group {
            if let image = shared.image(card, card.header?.picture) { Image(uiImage: image).resizable().scaledToFill() }
            else {
                Text(card.initials).font(.system(size: size * 0.36, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(LinearGradient(colors: [accent, accent.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }.frame(width: size, height: size).clipShape(Circle())
    }
}

/// Someone's profile as they shared it with you: read-only, with only what they allowed.
struct SharedProfileCardView: View {
    let id: SharedProfileCard.ID
    @State private var shared = SharedProfilesStore.shared
    @State private var removing = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mobilePalette) private var palette
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        NavigationStack {
            ScrollView {
                if let card = shared.card(id) { content(card) }
            }
            .background(palette.background)
            .navigationTitle(shared.card(id)?.name ?? "").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() }.accessibilityIdentifier("sharedProfileClose") }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Remove profile", systemImage: "person.crop.circle.badge.minus", role: .destructive) { removing = true }
                            .accessibilityIdentifier("sharedProfileRemove")
                    } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Options").accessibilityIdentifier("sharedProfileOptions")
                }
            }
            .confirmationDialog("Remove \(shared.card(id)?.name ?? "this profile")?", isPresented: $removing, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { Task { if await shared.remove(id) { dismiss() } } }.accessibilityIdentifier("sharedProfileRemoveConfirm")
            }
        }.presentationBackground(palette.background)
    }
    private func content(_ card: SharedProfileCard) -> some View {
        let accent = card.header?.accent.map { ProfileAccent.color($0) } ?? palette.accent
        return VStack(alignment: .leading, spacing: 14) {
            Color.clear.frame(height: 120)
                .background {
                    if let cover = shared.image(card, card.header?.cover) { Image(uiImage: cover).resizable().scaledToFill() }
                    else { LinearGradient(colors: [accent.opacity(0.85), accent.opacity(0.35), palette.surface], startPoint: .topLeading, endPoint: .bottomTrailing) }
                }.clipped()
            VStack(alignment: .leading, spacing: 4) {
                SharedProfilePicture(card: card, size: 84).padding(3).background(palette.background, in: Circle()).padding(.top, -56)
                Text(card.name).font(KemoType.font(.title2, weight: .bold)).accessibilityIdentifier("sharedProfileName")
                if let handle = card.header?.handle, !handle.isEmpty { Text("@" + handle).font(KemoType.font(.subheadline)).foregroundStyle(.secondary) }
                if let headline = card.header?.headline { Text(headline).font(KemoType.font(.subheadline, weight: .medium)).padding(.top, 4) }
                if let bio = card.header?.bio, !bio.isEmpty { Text(bio).font(KemoType.font(.subheadline)).padding(.top, 2) }
            }.padding(.horizontal, 18)
            ForEach(card.ordered, id: \.kind) { block in
                VStack(alignment: .leading, spacing: 12) {
                    Label(block.kind.title, systemImage: block.kind.symbol).font(KemoType.font(.headline, weight: .semibold)).foregroundStyle(accent)
                    blockContent(block, card: card, accent: accent)
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding(.horizontal, 14)
                .accessibilityElement(children: .contain).accessibilityIdentifier("sharedBlock-" + block.kind.rawValue)
            }
        }.padding(.bottom, 28)
    }
    @ViewBuilder private func blockContent(_ block: SharedProfileBlock, card: SharedProfileCard, accent: Color) -> some View {
        if let posts = block.posts {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(posts) { post in
                    Color.clear.aspectRatio(1, contentMode: .fit)
                        .overlay { if let image = shared.image(card, post.image) { Image(uiImage: image).resizable().scaledToFill() } else { palette.background } }
                        .clipped()
                        .overlay(alignment: .topTrailing) { if post.video { Image(systemName: "play.fill").font(.caption2).foregroundStyle(.white).padding(6) } }
                        .accessibilityLabel((post.video ? "Video, " : "Photo, ") + post.day.formatted(date: .abbreviated, time: .omitted))
                }
            }.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else if let music = block.music {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(music.topArtists.prefix(5).enumerated()), id: \.offset) { _, artist in row(artist.name, "\(artist.plays) plays") }
                ForEach(Array(music.picks.enumerated()), id: \.offset) { _, pick in row(pick.title, [pick.pick?.title, pick.artist].compactMap { $0 }.joined(separator: " · ")) }
                if !music.topGenres.isEmpty { Text(music.topGenres.map { "\($0.name) \(Int(($0.share * 100).rounded()))%" }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
            }
        } else if let work = block.work {
            VStack(alignment: .leading, spacing: 8) {
                if let about = work.about { Text(about).font(KemoType.font(.subheadline)) }
                ForEach(work.experience) { entry in row(entry.title, [entry.company, entry.dates].filter { !$0.isEmpty }.joined(separator: " · ")) }
                ForEach(work.education) { entry in row(entry.school, [entry.degree, entry.dates].filter { !$0.isEmpty }.joined(separator: " · ")) }
                if !work.skills.isEmpty { Text(work.skills.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
            }
        } else if let writing = block.writing {
            VStack(alignment: .leading, spacing: 6) {
                Text(writing.title ?? writing.address).font(KemoType.font(.subheadline, weight: .semibold))
                ForEach(writing.entries.prefix(5)) { entry in
                    if let url = entry.url { Link(entry.title, destination: url).font(KemoType.font(.subheadline)) } else { Text(entry.title).font(KemoType.font(.subheadline)) }
                }
            }
        } else if let personal = block.personal {
            VStack(alignment: .leading, spacing: 6) {
                if !personal.interests.isEmpty { Text(personal.interests.joined(separator: " · ")).font(KemoType.font(.subheadline)) }
                ForEach(personal.facts) { fact in row(fact.value, fact.label) }
            }
        } else if let links = block.links {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(links) { link in
                    if let url = link.url { Link(destination: url) { Label(link.platform.title, systemImage: link.platform.symbol) }.tint(accent) }
                }
            }
        } else if let game = block.game {
            row("Level \(game.level)", "\(game.xp) XP · \u{1F525} \(game.streak)")
        }
    }
    private func row(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(KemoType.font(.subheadline, weight: .semibold))
            if !detail.isEmpty { Text(detail).font(KemoType.font(.caption)).foregroundStyle(.secondary) }
        }
    }
}

/// Shows a profile you just accepted from an invitation link, wherever you are in the app.
struct SharedProfileArrival: ViewModifier {
    @State private var shared = SharedProfilesStore.shared
    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { shared.presented.map(SharedCardID.init) }, set: { shared.presented = $0?.id })) { SharedProfileCardView(id: $0.id) }
    }
}

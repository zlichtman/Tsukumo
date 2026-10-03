import SwiftUI
import PhotosUI
import Contacts
#if os(macOS)
import AppKit
#else
import UIKit
import ContactsUI
#endif

struct PeopleView: View {
    var title = "People"
    #if os(iOS)
    @Environment(\.mobilePalette) private var palette
    #endif
    @Environment(AppStore.self) private var store
    @Environment(ConnectorStore.self) private var connectors
    @State private var query = ""
    @State private var circle: PeopleCircle?
    @State private var selected: UUID?
    @State private var editing: PeopleEdit?
    @State private var importing = false
    @State private var addingContacts = false
    @State private var validated = Set<String>()
    @State private var refreshTask: Task<Void, Never>?
    @State private var epoch = UUID()
    @State private var notice = ""
    @State private var deleting: UUID?
    @State private var merging: PeopleDuplicate?
    @State private var removingContacts = false
    @State private var writingAbout: UUID?
    @State private var aboutDraft = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isPresented) private var isPresented
    private var listWidth: CGFloat? {
        #if os(macOS)
        260
        #else
        nil
        #endif
    }
    private var hasContactSources: Bool { (store.state.people?.profiles ?? []).contains { $0.sources.contains { $0.kind == .contacts } } }
    private var permitted: Bool { store.state.kemoAllows(.contacts) && PeopleContactsReader.permitted }
    private var directory: PeopleDirectory { (store.state.people ?? .init()).visible(contactIDs: permitted ? validated : []) }
    private var profiles: [PeopleProfile] { directory.profiles.filter { (circle == nil || $0.circles.contains(circle!)) && (query.isEmpty || $0.searchable.localizedCaseInsensitiveContains(query)) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    var body: some View {
        Group {
        #if os(iOS)
        NavigationStack {
            content.background(palette.background).toolbar(.hidden, for: .navigationBar)
                .navigationDestination(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                    if let person = directory.profiles.first(where: { $0.id == selected }) {
                        detail(person).background(palette.background).toolbar(.visible, for: .navigationBar).navigationTitle("Profile").navigationBarTitleDisplayMode(.inline)
                    }
                }
        }
        #else
        content
        #endif
        }.onDisappear { invalidate() }
    }
    private var content: some View {
        VStack(spacing: 0) {
            #if os(iOS)
            VStack(spacing: 14) {
                HStack {
                    Text(title).font(KemoType.font(.title2, weight: .semibold))
                    Spacer()
                    addPersonMenu
                    if isPresented {
                        Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 14, weight: .semibold)).frame(width: 36, height: 36) }
                            .buttonStyle(.glass).buttonBorderShape(.circle).accessibilityLabel("Close").accessibilityIdentifier("closePeople")
                    }
                }
                ShareLink(item: "I'm trying KemoSabe, a personal AI companion. Want to try it with me?") {
                    HStack(spacing: 12) {
                        Image(systemName: "person.badge.plus").font(.title3)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Invite friends").font(.headline)
                            Text("Send an invitation with Messages or another app").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "square.and.arrow.up").font(.body)
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(palette.surface, in: RoundedRectangle(cornerRadius: 18))
                }.buttonStyle(.plain).accessibilityIdentifier("inviteFriends")
                ContentSearchField(prompt: "Search names, notes, or circles", text: $query, identifier: "peopleSearch")
                HStack {
                    Menu { Button("Everyone") { circle = nil }; ForEach(PeopleCircle.allCases, id: \.self) { item in Button(item.rawValue) { circle = item } } } label: {
                        HStack(spacing: 6) { Text(circle?.rawValue ?? "Everyone"); Image(systemName: "chevron.down").font(.caption2.weight(.semibold)) }.font(.subheadline.weight(.medium))
                    }
                    Spacer()
                    Text("\(profiles.count) people").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 8)
            #endif
            if !notice.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                    if !permitted, hasContactSources {
                        Button("Remove contact profiles", role: .destructive) { removingContacts = true }.font(.caption).accessibilityIdentifier("removeHiddenContacts")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 10)
            }
            #if os(macOS)
            if (store.state.people?.profiles ?? []).isEmpty { macWelcome }
            else {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 12) {
                        macListHeader
                        ScrollView { listRows }
                    }.padding(.top, 18).frame(width: 300)
                    Divider()
                    if let person = directory.profiles.first(where: { $0.id == selected }) { detail(person) }
                    else { ContentUnavailableView("Choose someone", systemImage: "person.crop.rectangle", description: Text("Their picture, About, circles, and sources show here.")).frame(maxWidth: .infinity) }
                }
            }
            #else
            ScrollView { listRows }
            #endif
            Text("Private on this device · Profiles are not shared with model connections.").font(.caption2).foregroundStyle(.secondary).padding(12)
        }
        .sheet(item: $editing) { edit in PeopleSourceEditor(edit: edit) }
        #if os(macOS)
        .sheet(isPresented: $importing, onDismiss: refreshContacts) { PeopleContactImport() }
        #else
        .contactAccessPicker(isPresented: $addingContacts) { _ in Task { await importContacts() } }
        #endif
        .confirmationDialog("Are these the same person?", isPresented: Binding(get: { merging != nil }, set: { if !$0 { merging = nil } }), titleVisibility: .visible) {
            Button("Combine profiles") { if let merging { mutate { try $0.merge(merging.right, into: merging.left) }; selected = merging.left }; merging = nil }
        } message: {
            if let merging { Text((directory.profiles.first { $0.id == merging.left }?.name ?? "") + " and " + (directory.profiles.first { $0.id == merging.right }?.name ?? "") + ". " + merging.reason + ". Shared contact details can belong to different people. Both sets of sources will remain visible.") }
        }
        .onAppear(perform: refreshContacts)
        .onChange(of: store.state.kemoAllows(.contacts)) { refreshContacts() }
        .onChange(of: connectors.permissions[.contacts]) { refreshContacts() }
        .onReceive(NotificationCenter.default.publisher(for: .CNContactStoreDidChange)) { _ in refreshContacts() }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshContacts() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in invalidate() }
        #else
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in refreshContacts() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in invalidate() }
        #endif
    }
    private var listRows: some View {
        LazyVStack(alignment: .leading, spacing: 4) {
            #if os(iOS)
            // Profiles people shared with you: read-only, and apart from your own notes.
            if query.isEmpty && circle == nil { SharedWithYouRows() }
            #endif
            if profiles.isEmpty { ContentUnavailableView(query.isEmpty && circle == nil ? "Your people" : "No matching people", systemImage: "person.2", description: Text(query.isEmpty && circle == nil ? "Invite a friend or add someone to keep useful details together." : "Try another name or change the circle filter.")) }
            ForEach(profiles) { person in
                Button { selected = person.id } label: {
                    HStack(spacing: 10) {
                        PersonPhoto(person: person, size: 34)
                        VStack(alignment: .leading, spacing: 4) { Text(person.name).lineLimit(1); Text(person.subtitle.isEmpty ? person.circles.map(\.rawValue).joined(separator: " · ") : person.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        Spacer(minLength: 0)
                    }.padding(10).background(selected == person.id ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
            }
            ForEach(directory.duplicates) { duplicate in
                Button { merging = duplicate } label: { Label("Review possible duplicate", systemImage: "person.crop.circle.badge.questionmark").font(.caption) }.padding(.top, 12)
            }
        }.padding(8)
    }
    #if os(macOS)
    /// The list's header on Mac: title and count, add menu, search, and circle chips.
    private var macListHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("People").font(.system(size: 22, weight: .semibold))
                Text("\(directory.profiles.count)").foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("Add person", systemImage: "person.badge.plus") { editing = .init(personID: nil, source: .init(kind: .note, label: "Your note", fields: [.init(kind: .name, value: "")])) }
                    Button("Import from Contacts…", systemImage: "person.crop.rectangle.stack") { startImport() }
                    Button("Refresh contacts", systemImage: "arrow.clockwise") { refreshContacts() }
                    if hasContactSources { Divider(); Button("Remove imported contacts…", systemImage: "person.crop.circle.badge.minus", role: .destructive) { removingContacts = true } }
                } label: { Image(systemName: "plus") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Add person").accessibilityIdentifier("addPerson")
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("Search people", text: $query).textFieldStyle(.plain).accessibilityIdentifier("peopleSearch")
            }.padding(.horizontal, 10).padding(.vertical, 7).background(Color.primary.opacity(0.06), in: Capsule())
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    circleChip("Everyone", nil)
                    ForEach(PeopleCircle.allCases, id: \.self) { circleChip($0.rawValue, $0) }
                }
            }
        }.padding(.horizontal, 16)
    }
    private func circleChip(_ title: String, _ value: PeopleCircle?) -> some View {
        Button { circle = value } label: {
            Text(title).font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 5)
                .foregroundStyle(circle == value ? Color.accentColor : .primary)
                .background((circle == value ? Color.accentColor : Color.primary).opacity(circle == value ? 0.16 : 0.06), in: Capsule())
        }.buttonStyle(.plain)
    }
    /// With nobody added yet: one welcome instead of two empty panes.
    private var macWelcome: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.2").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Your people").font(.system(size: 22, weight: .semibold))
            Text("Keep what matters about the people in your life: how you met, what they're into, what to follow up on. Private to this Mac and never given to a model.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            HStack(spacing: 10) {
                Button("Add person") { editing = .init(personID: nil, source: .init(kind: .note, label: "Your note", fields: [.init(kind: .name, value: "")])) }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("addPerson")
                Button("Import from Contacts…") { startImport() }
                ShareLink("Invite a friend", item: "I'm trying KemoSabe, a personal AI companion. Want to try it with me?")
            }.padding(.top, 4)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
    }
    #endif
    private var addPersonMenu: some View {
        Menu {
            Button("Add person", systemImage: "person.badge.plus") { editing = .init(personID: nil, source: .init(kind: .note, label: "Your note", fields: [.init(kind: .name, value: "")])) }
            Button("Import from Contacts…", systemImage: "person.crop.rectangle.stack") { startImport() }.accessibilityIdentifier("importContacts")
            if hasContactSources { Divider(); Button("Remove imported contacts…", systemImage: "person.crop.circle.badge.minus", role: .destructive) { removingContacts = true }.accessibilityIdentifier("removeImportedContacts") }
        } label: { Image(systemName: "plus").frame(width: 44, height: 44) }.accessibilityLabel("Add person").accessibilityIdentifier("addPerson")
    }
    private func detail(_ person: PeopleProfile) -> some View {
        ScrollView {
            PersonBanner(person: person) { data in setImage(data, for: person.id, banner: true) }
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .bottom, spacing: 14) {
                    PersonPhotoPicker(person: person) { data in setImage(data, for: person.id, banner: false) }
                        .padding(.top, -52)
                    Spacer()
                }
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) { Text(person.name).font(.title2.weight(.semibold)); if !person.subtitle.isEmpty { Text(person.subtitle).foregroundStyle(.secondary) }; if let date = person.lastInteraction { Text("Last recorded interaction · " + date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary) } }
                    Spacer()
                    Menu {
                        Button("Add context or source") { editing = .init(personID: person.id, source: .init(kind: .note, label: "Your note", fields: [.init(kind: .context, value: "")])) }
                        Button("Delete profile", role: .destructive) { deleting = person.id }
                    } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Profile options")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("About").font(.caption).foregroundStyle(.secondary)
                    if let about = person.about { Text(about).fixedSize(horizontal: false, vertical: true) }
                    Button(person.about == nil ? "Write about them" : "Edit") { aboutDraft = person.about ?? ""; writingAbout = person.id }
                        .font(.caption).accessibilityIdentifier("personAbout")
                }
                HStack {
                    Text(person.circles.isEmpty ? "No circle assigned" : person.circles.map(\.rawValue).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Menu("Circles") { ForEach(PeopleCircle.allCases, id: \.self) { item in
                        Button { mutate { directory in if let index = directory.profiles.firstIndex(where: { $0.id == person.id }) { if directory.profiles[index].circles.contains(item) { directory.profiles[index].circles.removeAll { $0 == item } } else { directory.profiles[index].circles.append(item) } } } } label: { Label(item.rawValue, systemImage: person.circles.contains(item) ? "checkmark.circle.fill" : "circle") }
                    } }
                }
                ForEach(person.sources) { source in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label(source.label, systemImage: source.kind.symbol).font(.system(size: 12, weight: .medium))
                            Spacer()
                            Menu {
                                if source.kind != .contacts { Button("Edit") { editing = .init(personID: person.id, source: source) } }
                                if person.sources.count > 1 { Button("Move to separate profile") { mutate { try $0.separate(source.id, from: person.id) } } }
                                Button("Remove source", role: .destructive) { mutate { $0.removeSource(source.id, personID: person.id) } }
                            } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Source options")
                        }
                        ForEach(Array(source.fields.enumerated()), id: \.offset) { _, field in
                            if field.kind != .name || field.value != person.name { VStack(alignment: .leading, spacing: 4) { Text(field.kind.title).font(.caption).foregroundStyle(.secondary); Text(field.value).textSelection(.enabled) } }
                        }
                        if let ref = source.reference, let url = URL(string: ref) { Link("Open source", destination: url).font(.caption) }
                        Text((source.kind == .contacts ? "Refreshed from Contacts · " : "Added by you · ") + source.addedAt.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(.secondary)
                        if let date = source.happenedAt { Text("Interaction · " + date.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(.secondary) }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                }
                Button("Add context or source", systemImage: "plus") { editing = .init(personID: person.id, source: .init(kind: .note, label: "Your note", fields: [.init(kind: .context, value: "")])) }
            }.padding(24).frame(maxWidth: 720).frame(maxWidth: .infinity)
        }
        .sheet(isPresented: Binding(get: { writingAbout != nil }, set: { if !$0 { writingAbout = nil } })) {
            NavigationStack {
                TextEditor(text: $aboutDraft).padding().navigationTitle("About").accessibilityIdentifier("personAboutField")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { writingAbout = nil } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") {
                                if let id = writingAbout {
                                    let text = String(aboutDraft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
                                    mutate { directory in if let index = directory.profiles.firstIndex(where: { $0.id == id }) { directory.profiles[index].about = text.isEmpty ? nil : text } }
                                }
                                writingAbout = nil
                            }
                        }
                    }
            }.presentationDetents([.medium])
        }
        .confirmationDialog("Remove profiles from Apple Contacts?", isPresented: $removingContacts, titleVisibility: .visible) {
            Button("Remove contact profiles", role: .destructive) { mutate { $0.removeContacts() }; notice = "" }
        } message: { Text("Removes the contact sources KemoSabe kept. Notes you added stay, and your Apple Contacts are unchanged.") }
        .confirmationDialog("Delete this profile?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete profile", role: .destructive) { if let deleting { mutate { $0.profiles.removeAll { $0.id == deleting } }; if selected == deleting { selected = nil } }; deleting = nil }
        } message: { Text("Removes its sources and circles from KemoSabe. Your Apple Contacts and linked accounts stay unchanged.") }
    }
    /// Saves a picture or background for someone, replacing the old file.
    private func setImage(_ data: Data, for id: UUID, banner: Bool) {
        do {
            let name = try PeopleMedia.save(data, maxSide: banner ? 1600 : 600, prefix: banner ? "banner" : "photo")
            var old: String?
            mutate { directory in
                guard let index = directory.profiles.firstIndex(where: { $0.id == id }) else { return }
                if banner { old = directory.profiles[index].banner; directory.profiles[index].banner = name }
                else { old = directory.profiles[index].photo; directory.profiles[index].photo = name }
            }
            PeopleMedia.remove(old)
        } catch { notice = "That photo couldn't be used. Try another." }
    }
    /// Import from Contacts. On iPhone, Apple's access screen is the choice: everyone you allow is
    /// imported right away, and with limited access Apple's picker adds more people. There's no second
    /// list to tick through. The Mac has no such picker, so it keeps its selection sheet.
    private func startImport() {
        #if os(macOS)
        importing = true
        #else
        let before = CNContactStore.authorizationStatus(for: .contacts)
        Task {
            if !permitted { notice = await connectors.connect(.contacts, store: store) }
            guard permitted else { return }
            // Apple's access picker isn't on Macs running the iPhone app (and ContactsUI is weak-linked
            // for them), so there it imports whoever is already shared.
            if before == .limited, !ProcessInfo.processInfo.isiOSAppOnMac { addingContacts = true } else { await importContacts() }
        }
        #endif
    }
    #if os(iOS)
    private func importContacts() async {
        do {
            let sources = try await PeopleContactsReader().fetch()
            guard permitted else { return }
            let ids = Set(sources.compactMap(\.contactIdentifier))
            let known = Set((store.state.people?.profiles ?? []).flatMap(\.sources).compactMap(\.contactIdentifier))
            let added = ids.subtracting(known).count
            try store.updatePeople { try $0.upsertContacts(sources) }
            validated.formUnion(ids)
            await adoptContactPhotos(ids, store: store)
            notice = added == 0 ? "Everyone you've shared from Contacts is already here." : "Added \(added) \(added == 1 ? "person" : "people") from Contacts."
        } catch { notice = error.localizedDescription }
    }
    #endif
    private func mutate(_ change: (inout PeopleDirectory) throws -> Void) { do { try store.updatePeople(change); notice = "" } catch { notice = error.localizedDescription } }
    private func invalidate() { refreshTask?.cancel(); epoch = UUID(); validated = [] }
    private func refreshContacts() {
        invalidate(); let token = epoch
        let ids = Set((store.state.people?.profiles ?? []).flatMap(\.sources).compactMap(\.contactIdentifier))
        guard !ids.isEmpty else { return }
        // Losing access hides contact sources (see `directory`); it never deletes them, because
        // they come back as they were once access returns. Removing them is the person's choice.
        guard permitted else { notice = "Profiles from Apple Contacts are hidden while Contacts access is off. They return when you turn it back on."; return }
        refreshTask = Task {
            do {
                let sources = try await PeopleContactsReader().fetch(identifiers: ids)
                guard !Task.isCancelled, token == epoch, permitted else { return }
                try store.updatePeople { try $0.reconcileContacts(sources, requested: ids) }
                validated = Set(sources.compactMap(\.contactIdentifier)); notice = ""
            } catch { guard token == epoch, !Task.isCancelled else { return }; notice = "Contact profiles are hidden until access can be refreshed. " + error.localizedDescription }
        }
    }
}
private struct PeopleEdit: Identifiable { let id = UUID(); var personID: UUID?; var source: PeopleSource }
private struct PeopleSourceEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var edit: PeopleEdit
    @State private var link = ""
    @State private var recordDate = false
    @State private var date = Date()
    @State private var error = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("Source") {
                    Picker("Type", selection: $edit.source.kind) { ForEach(PeopleSourceKind.allCases.filter { $0 != .contacts && $0 != .spotify }, id: \.self) { Text($0.title).tag($0) } }
                    TextField("Source label", text: $edit.source.label)
                    TextField("HTTPS profile or source link · optional", text: $link).autocorrectionDisabled()
                    Text("Add details you know or a reference you can review. Linking a page does not connect or scrape that account.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Details") {
                    ForEach(edit.source.fields.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Picker("Detail", selection: $edit.source.fields[index].kind) { ForEach(PeopleFieldKind.allCases, id: \.self) { Text($0.title).tag($0) } }
                                Button { edit.source.fields.remove(at: index) } label: { Image(systemName: "minus.circle") }.accessibilityLabel("Remove detail")
                            }
                            TextField("Value", text: $edit.source.fields[index].value, axis: .vertical).lineLimit(1...5)
                        }
                    }
                    Button("Add detail", systemImage: "plus") { edit.source.fields.append(.init(kind: .observation, value: "")) }.disabled(edit.source.fields.count >= 40)
                }
                Section {
                    Toggle("Record an interaction date", isOn: $recordDate)
                    if recordDate { DatePicker("Interaction date", selection: $date, in: ...Date(), displayedComponents: .date) }
                }
                if !error.isEmpty { Text(error).foregroundStyle(.red).font(.caption) }
            }.formStyle(.grouped).navigationTitle(edit.personID == nil ? "Add person" : "Profile source")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") {
                        do {
                            edit.source.reference = link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : link.trimmingCharacters(in: .whitespacesAndNewlines)
                            edit.source.happenedAt = recordDate ? date : nil
                            try store.updatePeople { try $0.add(edit.source, to: edit.personID) }; dismiss()
                        } catch { self.error = error.localizedDescription }
                    } }
                }
        }.onAppear { link = edit.source.reference ?? ""; recordDate = edit.source.happenedAt != nil; date = edit.source.happenedAt ?? Date() }
        #if os(macOS)
        .frame(width: 580, height: 620)
        #endif
    }
}
#if os(macOS)
/// The Mac's Contacts import: pick people from a list (the iPhone uses Apple's access screen instead).
private struct PeopleContactImport: View {
    @Environment(AppStore.self) private var store
    @Environment(ConnectorStore.self) private var connectors
    @Environment(\.dismiss) private var dismiss
    @State private var contacts: [PeopleSource] = []
    @State private var selected = Set<String>()
    @State private var query = ""
    @State private var error = ""
    @State private var busy = false
    @State private var task: Task<Void, Never>?
    @State private var epoch = UUID()
    private var allowed: Bool { store.state.kemoAllows(.contacts) && PeopleContactsReader.permitted }
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("Choose people to keep in KemoSabe. Imports include names, phone numbers, email, and work details. Your address book is never edited.").font(.callout).foregroundStyle(.secondary)
                HStack { TextField("Find contacts", text: $query).textFieldStyle(.roundedBorder); Button(contacts.isEmpty ? "Load contacts" : "Refresh") { load() }.disabled(busy) }
                if busy { KemoOrb(size: 22) }
                if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.orange) }
                List(contacts.filter { query.isEmpty || $0.fields.contains { $0.value.localizedCaseInsensitiveContains(query) } }) { source in
                    Toggle(isOn: Binding(get: { selected.contains(source.contactIdentifier ?? "") }, set: { on in if let id = source.contactIdentifier { if on { selected.insert(id) } else { selected.remove(id) } } })) {
                        VStack(alignment: .leading) { Text(source.fields.first { $0.kind == .name }?.value ?? "Contact"); Text(source.fields.first { $0.kind == .company }?.value ?? "").font(.caption).foregroundStyle(.secondary) }
                    }.toggleStyle(.checkboxIfMac)
                }
                Text("Only selected people are saved. Contact profiles refresh when People opens; revoked or removed contacts are hidden and removed on refresh.").font(.caption).foregroundStyle(.secondary)
            }.padding(20).navigationTitle("Import Contacts")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Import \(selected.count)") { commit() }.disabled(busy || selected.isEmpty || selected.count > 3000) }
                }
        }
        .onDisappear { task?.cancel(); epoch = UUID(); contacts = []; selected = [] }
        .onChange(of: store.state.kemoAllows(.contacts)) { if !allowed { task?.cancel(); epoch = UUID(); contacts = []; selected = [] } }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in if !contacts.isEmpty { task?.cancel(); epoch = UUID(); contacts = []; selected = []; busy = false } }
        .frame(width: 560, height: 600)
        #else
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in if !contacts.isEmpty { task?.cancel(); epoch = UUID(); contacts = []; selected = []; busy = false } }
        #endif
    }
    private func load() {
        task?.cancel(); let token = UUID(); epoch = token; busy = true; error = ""
        task = Task {
            if !allowed { _ = await connectors.connect(.contacts, store: store) }
            do {
                guard allowed, !Task.isCancelled else { throw PeopleError.permission }
                let result = try await PeopleContactsReader().fetch(query: query)
                guard !Task.isCancelled, epoch == token, allowed else { return }
                contacts = result; selected = []; busy = false
            } catch { guard epoch == token else { return }; self.error = error.localizedDescription; busy = false }
        }
    }
    private func commit() {
        let offered = contacts.filter { selected.contains($0.contactIdentifier ?? "") }; let ids = selected
        task?.cancel(); let token = UUID(); epoch = token; busy = true
        task = Task {
            do {
                let current = try await PeopleContactsReader().fetch(identifiers: ids)
                guard !Task.isCancelled, token == epoch else { return }
                try PeopleDirectory.validateImport(offered: offered, current: current, permitted: allowed)
                try store.updatePeople { try $0.upsertContacts(current) }
                await adoptContactPhotos(ids, store: store)
                dismiss()
            } catch { guard token == epoch else { return }; self.error = error.localizedDescription; busy = false }
        }
    }
}
#endif
/// Their contact photo becomes their profile picture, once, if they don't have one.
@MainActor private func adoptContactPhotos(_ ids: Set<String>, store: AppStore) async {
    let photos = await PeopleContactsReader().thumbnails(for: ids)
    guard !photos.isEmpty else { return }
    try? store.updatePeople { directory in
        for index in directory.profiles.indices where directory.profiles[index].photo == nil {
            guard let id = directory.profiles[index].sources.compactMap(\.contactIdentifier).first(where: { photos[$0] != nil }),
                  let name = try? PeopleMedia.save(photos[id]!, maxSide: 600, prefix: "photo") else { continue }
            directory.profiles[index].photo = name
        }
    }
}
#if os(macOS)
private struct PeopleSelectionToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: { HStack { configuration.label; Spacer(); Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle").foregroundStyle(configuration.isOn ? Color.accentColor : .secondary) } }.buttonStyle(.plain).accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}
private extension ToggleStyle where Self == PeopleSelectionToggleStyle { static var checkboxIfMac: Self { .init() } }
#endif

/// Someone's picture, or their initials until they have one.
struct PersonPhoto: View {
    let person: PeopleProfile
    let size: CGFloat
    var body: some View {
        Group {
            if let image = PeopleMedia.image(person.photo) { image.resizable().scaledToFill() }
            else { Text(person.initials).font(.system(size: size * 0.36, weight: .medium)).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.primary.opacity(0.06)) }
        }.frame(width: size, height: size).clipShape(Circle())
    }
}
/// The picture on a full profile; tap to choose another from Photos.
private struct PersonPhotoPicker: View {
    let person: PeopleProfile
    let chosen: (Data) -> Void
    @State private var item: PhotosPickerItem?
    var body: some View {
        PhotosPicker(selection: $item, matching: .images) {
            PersonPhoto(person: person, size: 88).padding(4).background(.background, in: Circle())
        }.buttonStyle(.plain).accessibilityLabel("Change \(person.name)'s picture").accessibilityIdentifier("personPhoto")
            .onChange(of: item) { load() }
    }
    private func load() {
        guard let item else { return }
        Task { if let data = try? await PickedImage.load(item) { chosen(data) }; self.item = nil }
    }
}
/// The wide background on a full profile, as on LinkedIn; tap to choose one.
private struct PersonBanner: View {
    let person: PeopleProfile
    let chosen: (Data) -> Void
    @State private var item: PhotosPickerItem?
    var body: some View {
        PhotosPicker(selection: $item, matching: .images) {
            Color.clear.frame(height: 130).frame(maxWidth: .infinity)
                .background {
                    if let image = PeopleMedia.image(person.banner) { image.resizable().scaledToFill() }
                    else { LinearGradient(colors: [Color.accentColor.opacity(0.5), Color.primary.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing) }
                }.clipped()
        }.buttonStyle(.plain).accessibilityLabel("Change background").accessibilityIdentifier("personBanner")
            .onChange(of: item) {
                guard let item else { return }
                Task { if let data = try? await PickedImage.load(item) { chosen(data) }; self.item = nil }
            }
    }
}

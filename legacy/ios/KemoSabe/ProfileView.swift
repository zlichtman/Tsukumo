import AVKit
import MediaPlayer
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Your one profile, arranged by you (design/PROFILE-REDESIGN.md): a cover in your accent or a
/// photo, your picture, how many people you share it with, and your companion's watch game;
/// name, handle, headline, and bio; then your blocks in your order. Edit profile turns the same
/// page into its editable layout: fields in the header, an accent row, and a bar on every block to
/// drag, restyle, hide it, or choose who can see it (design/ACCOUNTS-AND-PROFILES.md, "Sharing
/// your profile").
struct ProfilePage: View {
    @Environment(AppStore.self) private var store
    @Environment(\.mobilePalette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var profiles = ProfileStore.shared
    @State private var imports = ProfileImports()
    @State private var library: MusicLibrarySource = ProfileMusicLibrary.make()
    @State private var picked: [PhotosPickerItem] = []
    @State private var adding = false
    @State private var shooting = false
    @State private var editing = false
    @State private var draft = HeaderDraft()
    @State private var dragging: ProfileBlockKind?
    @State private var people = false
    @State private var sharing = ProfileSharingStore.shared
    @State private var sharingPage = false
    @State private var kemoCard = false
    @State private var pet = WatchLink.PetSummary.saved()
    @State private var viewing: ProfileMedia?
    @State private var allPosts = false
    @State private var problem: String?
    @State private var choosingCover = false
    @State private var choosingPicture = false
    @State private var coverItem: PhotosPickerItem?
    @State private var pictureItem: PhotosPickerItem?
    private var profile: SocialProfile { profiles.profile }
    private var accent: Color { profile.accent.map { ProfileAccent.color($0) } ?? palette.accent }

    var body: some View {
        NavigationStack {
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        cover
                        header
                        VStack(alignment: .leading, spacing: 14) {
                            if editing { fields } else { identity }
                            actions
                        }.padding(.horizontal, 18).padding(.top, 10)
                        LazyVStack(spacing: 14) {
                            ForEach(profile.blocks.filter { editing || !$0.hidden }) { block in
                                blockView(block, reader: reader).id("block-" + block.kind.rawValue)
                            }
                        }.padding(.horizontal, 14).padding(.top, 20)
                    }.padding(.bottom, 28)
                    .fileImporter(isPresented: $imports.pickingLinkedIn, allowedContentTypes: [.commaSeparatedText, .folder], allowsMultipleSelection: true) { result in
                        guard case .success(let urls) = result, !urls.isEmpty else { return }
                        imports.importLinkedIn(urls, into: profiles)
                        withAnimation { reader.scrollTo("block-work", anchor: .top) }
                    }
                }
                .fileImporter(isPresented: $imports.pickingInstagram, allowedContentTypes: [.folder]) { result in
                    guard case .success(let folder) = result else { return }
                    imports.importInstagram(folder, into: profiles)
                    withAnimation { reader.scrollTo("block-photos", anchor: .top) }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .background(palette.background)
            .toolbar(.hidden, for: .navigationBar)
            .environment(\.profileAccent, accent)
            .environment(\.profileEditing, editing)
            .navigationDestination(isPresented: $allPosts) { ProfilePostsPage(profiles: profiles, view: { viewing = $0 }) }
            .sheet(isPresented: $people) { PeopleView(title: "People") }
            .sheet(isPresented: $sharingPage) { ProfileSharingPage(sharing: sharing, profiles: profiles) }
            .sheet(isPresented: $kemoCard) { ProfileKemoCard(summary: pet, theme: store.state.theme) }
            .onReceive(NotificationCenter.default.publisher(for: WatchLink.PetSummary.changed).receive(on: RunLoop.main)) { _ in pet = .saved() }
            .fullScreenCover(item: $viewing) { ProfileMediaViewer(start: $0, profiles: profiles) }
            .fullScreenCover(isPresented: $shooting) { CameraSheet { photo in Task { await postReporting(photo) } } }
            .photosPicker(isPresented: $adding, selection: $picked, maxSelectionCount: 30, matching: .any(of: [.images, .videos]))
            .photosPicker(isPresented: $choosingCover, selection: $coverItem, matching: .images)
            .photosPicker(isPresented: $choosingPicture, selection: $pictureItem, matching: .images)
            .onChange(of: picked) { importPicked() }
            .onChange(of: coverItem) { setImage(coverItem, cover: true) }
            .onChange(of: pictureItem) { setImage(pictureItem, cover: false) }
            .alert("Couldn't add that", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(problem ?? "") }
            .task {
                // Stats older than half a day refresh from the library when the profile opens.
                if profiles.musicIsStale { await profiles.refreshMusic(library) }
                // Who has opened your invitations, for "Shared with".
                await sharing.refreshStatuses()
            }
        }
    }

    // MARK: Header

    /// The wide cover, as on LinkedIn: your photo, or a wash of your accent until you choose one.
    private var cover: some View {
        Color.clear.frame(height: 150)
            .background {
                if let image = profiles.bannerImage() {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    ZStack {
                        LinearGradient(colors: [accent.opacity(0.85), accent.opacity(0.35), palette.surface], startPoint: .topLeading, endPoint: .bottomTrailing)
                        RadialGradient(colors: [Color.white.opacity(0.22), .clear], center: .topTrailing, startRadius: 4, endRadius: 220)
                    }
                }
            }
            .clipped()
            .overlay(alignment: .topTrailing) {
                if editing {
                    Menu {
                        Button("Choose photo", systemImage: "photo") { choosingCover = true }
                        if profiles.bannerImage() != nil { Button("Use accent colors", systemImage: "paintpalette") { try? profiles.setBanner(nil) } }
                    } label: { editBadge("Cover", symbol: "camera.fill") }
                        .accessibilityIdentifier("profileCoverMenu").padding(.top, 54).padding(.trailing, 14)
                }
            }
            .accessibilityIdentifier("profileBanner")
    }
    /// Your picture over the cover's edge, then how many people you share it with (those who
    /// accepted; never made up) and your companion's level.
    private var header: some View {
        // At the accessibility text sizes the stats get their own full-width row under the picture.
        let large = typeSize.isAccessibilitySize
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 6) {
                picture
                Spacer(minLength: 0)
                if !large { stats }
            }
            if large { HStack(spacing: 6) { stats }.frame(maxWidth: .infinity) }
        }.padding(.horizontal, 14).padding(.top, -54)
    }
    private var picture: some View {
        avatar(size: 92).padding(4).background(palette.background, in: Circle())
            .overlay(alignment: .bottomTrailing) {
                if editing {
                    Menu {
                        Button("Choose photo", systemImage: "photo") { choosingPicture = true }
                        if profiles.pictureImage() != nil { Button("Remove picture", systemImage: "trash", role: .destructive) { try? profiles.setPicture(nil) } }
                    } label: {
                        Image(systemName: "camera.fill").font(.footnote.weight(.semibold)).foregroundStyle(.white)
                            .frame(width: 32, height: 32).background(accent, in: Circle())
                            .overlay(Circle().stroke(palette.background, lineWidth: 3))
                    }.accessibilityLabel("Profile picture").accessibilityIdentifier("profilePictureMenu")
                }
            }
    }
    @ViewBuilder private var stats: some View {
        Button { sharingPage = true } label: { stat("\(sharing.acceptedCount)", "Shared with") }
            .buttonStyle(.plain).accessibilityIdentifier("profileSharedWith")
            .accessibilityLabel("Shared with \(sharing.acceptedCount) \(sharing.acceptedCount == 1 ? "person" : "people")")
        Button { kemoCard = true } label: { stat(pet.map { "Lv \($0.level)" } ?? "\u{2014}", CompanionIdentity.name) }
            .buttonStyle(.plain).accessibilityIdentifier("profileKemo")
            .accessibilityLabel(pet.map { "\(CompanionIdentity.name), level \($0.level)" } ?? "\(CompanionIdentity.name), no watch game yet")
    }
    @ViewBuilder func avatar(size: CGFloat) -> some View {
        Group {
            if let image = profiles.pictureImage() {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                // Your initials until you choose a picture.
                Text(profiles.initials.isEmpty ? "?" : profiles.initials).font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(LinearGradient(colors: [accent, accent.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }.frame(width: size, height: size).clipShape(Circle())
            .overlay(Circle().stroke(accent, lineWidth: 2.5).padding(-4))
            .accessibilityLabel(profiles.pictureImage() == nil ? "Profile picture, your initials" : "Profile picture")
    }
    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(KemoType.font(.headline, weight: .bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(KemoType.font(.caption)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
        }.frame(minWidth: 60, maxWidth: typeSize.isAccessibilitySize ? .infinity : 88).contentShape(Rectangle())
    }
    private var identity: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(profile.name.isEmpty ? "Your name" : profile.name).font(KemoType.font(.title2, weight: .bold))
                .foregroundStyle(profile.name.isEmpty ? .secondary : .primary).accessibilityIdentifier("profileDisplayName")
            if !profile.handle.isEmpty { Text("@" + profile.handle).font(KemoType.font(.subheadline)).foregroundStyle(.secondary).accessibilityIdentifier("profileHandle") }
            if let headline = profile.headline {
                Text(headline).font(KemoType.font(.subheadline, weight: .medium)).padding(.top, 4).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("profileHeadline")
            }
            if !profile.bio.isEmpty { Text(profile.bio).font(KemoType.font(.subheadline)).fixedSize(horizontal: false, vertical: true).padding(.top, 2) }
        }
    }
    /// The header while editing: its fields in place, then your accent.
    private var fields: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProfileField(symbol: "person", placeholder: "Name") {
                TextField("Name", text: $draft.name).textContentType(.name).accessibilityIdentifier("profileName")
            }
            ProfileField(symbol: "at", placeholder: "Username") {
                TextField("username", text: $draft.handle).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("profileHandleField")
            }
            ProfileField(symbol: "briefcase", placeholder: "Headline") {
                TextField("Headline, like “iOS engineer at Acme”", text: $draft.headline).accessibilityIdentifier("profileHeadlineField")
            }
            ProfileField(symbol: "text.quote", placeholder: "Bio") {
                TextField("Bio", text: $draft.bio, axis: .vertical).lineLimit(2...6).accessibilityIdentifier("profileBio")
            }
            accentRow
        }
    }
    private var accentRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Accent").font(KemoType.font(.subheadline, weight: .semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    swatch(nil, color: palette.accent, name: "Theme")
                    ForEach(ProfileAccent.choices, id: \.hex) { choice in swatch(choice.hex, color: ProfileAccent.color(choice.hex), name: choice.name) }
                }.padding(6) // Room for the selection ring, which sits 5 points outside each swatch.
            }.padding(.horizontal, -6) // The first swatch still lines up with the title.
        }.padding(.top, 4)
    }
    private func swatch(_ hex: String?, color: Color, name: String) -> some View {
        let selected = profile.accent == hex
        return Button { withAnimation(.snappy) { profiles.setAccent(hex) } } label: {
            Circle().fill(color).frame(width: 34, height: 34)
                .overlay { if hex == nil { Image(systemName: "paintpalette.fill").font(.caption).foregroundStyle(.white) } }
                .overlay(Circle().stroke(palette.foreground.opacity(selected ? 0.9 : 0), lineWidth: 2).padding(-4))
        }.buttonStyle(.plain).accessibilityLabel(name).accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("profileAccent-" + name)
    }
    private var actions: some View {
        // Side by side, or stacked at the accessibility text sizes so every label fits.
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            if editing {
                // Drawn in the accent itself, so it always matches the swatch you just chose.
                Button { finishEditing() } label: {
                    Text("Done").foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 50)
                        .background(accent, in: Capsule()).contentShape(Capsule())
                }.buttonStyle(.plain).accessibilityIdentifier("profileDone")
            } else {
                Button { startEditing() } label: { Text("Edit profile").lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).accessibilityIdentifier("profileEdit")
                Menu { addChoices } label: { Label("Add", systemImage: "plus").frame(maxWidth: .infinity) }
                    .menuStyle(.button).buttonStyle(.bordered).fixedSize(horizontal: !typeSize.isAccessibilitySize, vertical: false).accessibilityIdentifier("profileAddMedia")
                // Who you share your profile with, and what each can see.
                Button { sharingPage = true } label: {
                    if typeSize.isAccessibilitySize { Label("Sharing", systemImage: "shared.with.you").frame(maxWidth: .infinity) }
                    else { Image(systemName: "shared.with.you").padding(.horizontal, 4) }
                }.buttonStyle(.bordered).fixedSize(horizontal: !typeSize.isAccessibilitySize, vertical: false).accessibilityLabel("Sharing").accessibilityIdentifier("profileSharing")
                // People, your private directory, one tap away; it's never part of the profile itself.
                Button { people = true } label: {
                    if typeSize.isAccessibilitySize { Label("People", systemImage: "person.2").frame(maxWidth: .infinity) }
                    else { Image(systemName: "person.2").padding(.horizontal, 4) }
                }.buttonStyle(.bordered).fixedSize(horizontal: !typeSize.isAccessibilitySize, vertical: false).accessibilityLabel("People").accessibilityIdentifier("profilePeople")
            }
        }.tint(editing ? accent : palette.foreground).buttonBorderShape(.capsule).font(KemoType.font(.subheadline, weight: .semibold))
            .controlSize(.large)
    }
    /// The ways in: the camera, photos and videos from the library, and your own exports.
    @ViewBuilder private var addChoices: some View {
        Button("Camera", systemImage: "camera") { shooting = true }.accessibilityIdentifier("profileAddCamera")
        Button("Photo Library", systemImage: "photo.on.rectangle") { adding = true }.accessibilityIdentifier("profileAddLibrary")
        Section("Import") {
            Button("Import from LinkedIn", systemImage: "briefcase") { imports.pickingLinkedIn = true }.accessibilityIdentifier("profileAddImportLinkedIn")
            Button("Import from Instagram", systemImage: "square.and.arrow.down") { imports.pickingInstagram = true }.accessibilityIdentifier("profileImportInstagram")
        }
    }
    private func editBadge(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(KemoType.font(.footnote, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 7).background(.black.opacity(0.45), in: Capsule())
    }

    // MARK: Blocks

    @ViewBuilder private func blockView(_ block: ProfileBlock, reader: ScrollViewProxy) -> some View {
        let style = profile.style(block.kind)
        ProfileBlockCard(block: block, title: block.kind == .kemo ? CompanionIdentity.name : block.kind.title, isFirst: profile.blocks.first?.kind == block.kind,
                         isLast: profile.blocks.last?.kind == block.kind, profiles: profiles, dragging: $dragging) {
            accessory(block.kind)
        } content: {
            switch block.kind {
            case .photos: ProfilePhotosBlock(profiles: profiles, style: style, imports: imports, view: { viewing = $0 }, addMenu: { addChoices })
            case .music: ProfileMusicBlock(profiles: profiles, style: style, library: library)
            case .work: ProfileWorkBlock(profiles: profiles, style: style, imports: imports)
            case .writing: ProfileWritingBlock(profiles: profiles, style: style)
            case .personal: ProfilePersonalBlock(profiles: profiles)
            case .links: ProfileLinksBlock(profiles: profiles, style: style, drafts: $draft.links) {
                startEditing()
                withAnimation { reader.scrollTo("block-links", anchor: .top) }
            }
            case .kemo: ProfileKemoBlock(summary: pet, theme: store.state.theme) { kemoCard = true }
            }
        }
    }
    /// The one control a block's title row carries outside editing.
    @ViewBuilder private func accessory(_ kind: ProfileBlockKind) -> some View {
        if !editing {
            switch kind {
            case .photos where !profile.media.isEmpty:
                Button { allPosts = true } label: {
                    HStack(spacing: 3) { Text("All \(profile.media.count)"); Image(systemName: "chevron.right").font(.caption2.weight(.bold)) }
                }.accessibilityIdentifier("profileAllPosts")
            default: EmptyView()
            }
        }
    }

    // MARK: Editing

    private func startEditing() {
        guard !editing else { return }
        draft = HeaderDraft(profile)
        withAnimation(.snappy) { editing = true }
    }
    /// Saves the header's fields and links; blocks, the accent, and pictures save as you change them.
    private func finishEditing() {
        let draft = draft
        profiles.update { profile in
            profile.name = draft.name; profile.handle = draft.handle; profile.bio = draft.bio; profile.headline = draft.headline
            profile.links = ProfileLink.Platform.allCases.compactMap { platform in
                draft.links[platform].map { ProfileLink(id: profile.links.first { $0.platform == platform }?.id ?? UUID(), platform: platform, value: $0) }
            }
        }
        withAnimation(.snappy) { editing = false }
    }

    // MARK: Adding

    /// Photos and videos from the library become posts as they are.
    private func importPicked() {
        let items = picked
        guard !items.isEmpty else { return }
        picked = []
        Task {
            for item in items {
                do {
                    if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                        guard let movie = try await item.loadTransferable(type: PickedMovie.self) else { throw ProfileError.unreadable }
                        defer { try? FileManager.default.removeItem(at: movie.url) }
                        try await profiles.addVideo(at: movie.url)
                    } else {
                        let data = try await PickedImage.load(item)
                        try await post(CameraPhoto(jpeg: data, taken: ProfileStore.captureDate(data)))
                    }
                } catch { problem = error.localizedDescription }
            }
        }
    }
    private func setImage(_ item: PhotosPickerItem?, cover: Bool) {
        guard let item else { return }
        Task {
            do {
                let data = try await PickedImage.load(item)
                if cover { try profiles.setBanner(data) } else { try profiles.setPicture(data) }
            } catch { problem = error.localizedDescription }
            if cover { coverItem = nil } else { pictureItem = nil }
        }
    }
    /// A photo from the camera or the library becomes a post on the day it was taken.
    private func postReporting(_ photo: CameraPhoto) async {
        do { try await post(photo) } catch { problem = error.localizedDescription }
    }
    private func post(_ photo: CameraPhoto) async throws {
        let prepared = try await Task.detached(priority: .userInitiated) { try ProfileStore.preparePhoto(photo.jpeg) }.value
        try profiles.insert(prepared, takenAt: photo.taken)
    }
}

/// The header's fields while editing, saved together on Done.
private struct HeaderDraft {
    var name = "", handle = "", headline = "", bio = ""
    var links: [ProfileLink.Platform: String] = [:]
    init() {}
    init(_ profile: SocialProfile) {
        name = profile.name; handle = profile.handle; headline = profile.headline ?? ""; bio = profile.bio
        links = Dictionary(profile.links.map { ($0.platform, $0.value) }, uniquingKeysWith: { first, _ in first })
    }
}

/// A field in the header while editing: a soft rounded well with a small icon.
private struct ProfileField<Field: View>: View {
    let symbol: String
    let placeholder: String
    @ViewBuilder var field: Field
    @Environment(\.mobilePalette) private var palette
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).font(.subheadline).foregroundStyle(.secondary).frame(width: 20)
            field.font(KemoType.font(.body))
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Where the Music block's songs come from: the iPhone's library, or (in UI tests) a sample one.
enum ProfileMusicLibrary {
    @MainActor static func make() -> MusicLibrarySource {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--sample-music") {
            return SampleMusicLibrary()
        }
        #endif
        return DeviceMusicLibrary()
    }
}

/// The profile's accent, and whether the page is being edited, for the blocks.
private struct ProfileAccentKey: EnvironmentKey { static let defaultValue = Color.accentColor }
private struct ProfileEditingKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var profileAccent: Color { get { self[ProfileAccentKey.self] } set { self[ProfileAccentKey.self] = newValue } }
    var profileEditing: Bool { get { self[ProfileEditingKey.self] } set { self[ProfileEditingKey.self] = newValue } }
}

/// Imports running from the profile: LinkedIn's CSV export and Instagram's JSON export.
@MainActor @Observable final class ProfileImports {
    var pickingLinkedIn = false
    var pickingInstagram = false
    var readingLinkedIn = false
    var linkedInMessage: String?
    var instagramProgress: (done: Int, total: Int)?
    var instagramMessage: String?
    @ObservationIgnored private var instagramTask: Task<Void, Never>?

    func importLinkedIn(_ urls: [URL], into profiles: ProfileStore) {
        readingLinkedIn = true; linkedInMessage = nil
        Task {
            defer { readingLinkedIn = false }
            do {
                let texts = try await Task.detached { try LinkedInImport.readFiles(urls) }.value
                let parsed = LinkedInImport.parse(texts)
                guard !parsed.isEmpty else { throw ProfileImportError.nothingFromLinkedIn }
                let added = profiles.applyLinkedIn(parsed)
                linkedInMessage = added == 0 ? "Everything in that export is already on your profile." : "Added \(added) \(added == 1 ? "item" : "items") from LinkedIn."
            } catch { linkedInMessage = error.localizedDescription }
        }
    }
    func importInstagram(_ folder: URL, into profiles: ProfileStore) {
        instagramMessage = nil; instagramProgress = (0, 0)
        instagramTask = Task {
            defer { instagramProgress = nil; instagramTask = nil }
            do {
                let report = try await profiles.importInstagram(from: folder) { [weak self] done, total in self?.instagramProgress = (done, total) }
                var lines: [String] = []
                lines.append(report.added == 0 ? "No new posts to add." : "Added \(report.added) \(report.added == 1 ? "post" : "posts").")
                if report.alreadyHere > 0 { lines.append("\(report.alreadyHere) were already here.") }
                if report.failed > 0 { lines.append("\(report.failed) couldn't be read.") }
                if report.left > 0 { lines.append("Import again for the other \(report.left).") }
                instagramMessage = lines.joined(separator: " ")
            } catch { instagramMessage = error.localizedDescription }
        }
    }
    func stopInstagram() { instagramTask?.cancel() }
}

/// A video handed over by the Photos picker, copied to a temporary file the app owns.
struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + (received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension))
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Self(url: copy)
        }
    }
}

// MARK: All posts

/// Every post, grouped by the day it was taken, newest first, as a grid or a feed with captions.
struct ProfilePostsPage: View {
    let profiles: ProfileStore
    let view: (ProfileMedia) -> Void
    @Environment(\.mobilePalette) private var palette
    @State private var layout: ProfileBlockStyle?
    @State private var captioning: ProfileMedia?
    @State private var captionDraft = ""
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)
    private var style: ProfileBlockStyle { layout ?? profiles.profile.style(.photos) }

    var body: some View {
        let days = Dictionary(grouping: profiles.profile.media) { Calendar.current.startOfDay(for: $0.day) }.sorted { $0.key > $1.key }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10, pinnedViews: [.sectionHeaders]) {
                ForEach(days, id: \.key) { day, items in
                    Section {
                        if style == .grid {
                            LazyVGrid(columns: columns, spacing: 2) {
                                ForEach(items.sorted { $0.day > $1.day }) { media in ProfilePostTile(media: media, profiles: profiles) { view(media) } }
                            }
                        } else {
                            ForEach(items.sorted { $0.day > $1.day }) { media in
                                ProfileFeedPost(media: media, profiles: profiles, view: { view(media) }) { captionDraft = media.caption ?? ""; captioning = media }
                            }
                        }
                    } header: {
                        Text(ProfilePostsPage.dayTitle(day)).font(KemoType.font(.subheadline, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.vertical, 6)
                            .background(palette.background).accessibilityIdentifier("profileDay")
                    }
                }
            }.padding(.bottom, 24)
        }
        .background(palette.background)
        .navigationTitle("Posts").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Layout", selection: Binding(get: { style }, set: { layout = $0 })) {
                    Label("Grid", systemImage: "square.grid.3x3").tag(ProfileBlockStyle.grid)
                    Label("Feed", systemImage: "rectangle.grid.1x2").tag(ProfileBlockStyle.feed)
                }.pickerStyle(.segmented).accessibilityIdentifier("profileLayout")
            }
        }
        .alert("Caption", isPresented: Binding(get: { captioning != nil }, set: { if !$0 { captioning = nil } })) {
            TextField("Write a caption", text: $captionDraft).accessibilityIdentifier("captionField")
            Button("Save") { if let media = captioning { profiles.setCaption(captionDraft, for: media.id) }; captioning = nil }
            Button("Cancel", role: .cancel) { captioning = nil }
        }
    }
    static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day().year(calendar.isDate(day, equalTo: .now, toGranularity: .year) ? .omitted : .defaultDigits))
    }
}

/// A square tile in a grid of posts.
struct ProfilePostTile: View {
    let media: ProfileMedia
    let profiles: ProfileStore
    var pinned = false
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            Color.clear.aspectRatio(1, contentMode: .fit)
                .overlay { if let image = profiles.thumbnail(media) { Image(uiImage: image).resizable().scaledToFill() } }
                .clipped().contentShape(Rectangle())
                .overlay(alignment: .topTrailing) {
                    if media.kind == .video {
                        Label(Duration.seconds(media.duration ?? 0).formatted(.time(pattern: .minuteSecond)), systemImage: "play.fill")
                            .font(.caption2.weight(.semibold)).foregroundStyle(.white).padding(6).shadow(radius: 2)
                    } else if pinned {
                        Image(systemName: "pin.fill").font(.caption2.weight(.bold)).foregroundStyle(.white).padding(7).shadow(radius: 2)
                    }
                }
                .overlay(alignment: .bottomLeading) { ProfileSourceMark(media: media, compact: true) }
        }.buttonStyle(.plain)
            .accessibilityLabel((pinned ? "Pinned. " : "") + (media.kind == .video ? "Video, " : "Photo, ") + (media.source == "instagram" ? "from Instagram, " : "") + media.day.formatted(date: .abbreviated, time: .omitted))
            .accessibilityIdentifier("profileGridItem")
    }
}

/// One post in a feed: the photo at its own shape, then its caption.
struct ProfileFeedPost: View {
    let media: ProfileMedia
    let profiles: ProfileStore
    var pinned = false
    var inset: CGFloat = 18
    let view: () -> Void
    let caption: () -> Void
    @Environment(\.mobilePalette) private var palette
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: view) {
                Group {
                    if let image = profiles.image(media) ?? profiles.thumbnail(media) {
                        Image(uiImage: image).resizable().scaledToFit()
                    } else { palette.surface.frame(height: 240) }
                }
                .frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    if media.kind == .video {
                        Label(Duration.seconds(media.duration ?? 0).formatted(.time(pattern: .minuteSecond)), systemImage: "play.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(.white).padding(10).shadow(radius: 2)
                    }
                }
                .overlay(alignment: .topTrailing) { ProfileSourceMark(media: media, compact: false) }
                .overlay(alignment: .topLeading) {
                    if pinned {
                        Label("Pinned", systemImage: "pin.fill").font(.caption.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 5).background(.black.opacity(0.35), in: Capsule()).padding(10)
                            .accessibilityIdentifier("profilePinned")
                    }
                }
            }.buttonStyle(.plain).accessibilityIdentifier("profileFeedItem")
            if let text = media.caption {
                Text(text).font(KemoType.font(.subheadline)).fixedSize(horizontal: false, vertical: true)
                    .onTapGesture(perform: caption)
            } else {
                Button("Add a caption", action: caption)
                    .font(KemoType.font(.caption)).foregroundStyle(.secondary).buttonStyle(.plain).accessibilityIdentifier("addCaption")
            }
        }.padding(.horizontal, inset).padding(.bottom, inset == 0 ? 4 : 14)
    }
}

/// A small mark on posts brought in from another platform.
struct ProfileSourceMark: View {
    let media: ProfileMedia
    let compact: Bool
    var body: some View {
        if media.source == "instagram" {
            Group {
                if compact { Image(systemName: "camera").font(.caption2.weight(.semibold)) }
                else { Label("Instagram", systemImage: "camera").font(.caption.weight(.semibold)) }
            }
            .foregroundStyle(.white).padding(.horizontal, compact ? 5 : 8).padding(.vertical, compact ? 4 : 5)
            .background(.black.opacity(0.35), in: Capsule()).padding(compact ? 5 : 10)
            .accessibilityLabel("From Instagram").accessibilityIdentifier("profilePostSource")
        }
    }
}

/// Full screen: swipe between posts, pinch to zoom, with the day each was taken.
private struct ProfileMediaViewer: View {
    let start: ProfileMedia
    let profiles: ProfileStore
    @Environment(\.dismiss) private var dismiss
    @State private var current: UUID?
    @State private var deleting = false
    private var ordered: [ProfileMedia] { profiles.profile.orderedMedia }
    private var media: ProfileMedia? { ordered.first { $0.id == (current ?? start.id) } }
    var body: some View {
        NavigationStack {
            TabView(selection: Binding(get: { current ?? start.id }, set: { current = $0 })) {
                ForEach(ordered) { item in
                    ProfileMediaPage(media: item, profiles: profiles).tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .background(.black).ignoresSafeArea()
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } }
                ToolbarItem(placement: .principal) {
                    if let media { Text(media.day.formatted(date: .long, time: .omitted)).font(.subheadline.weight(.semibold)).foregroundStyle(.white) }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if let media {
                            if profiles.profile.pinned == media.id {
                                Button("Unpin", systemImage: "pin.slash") { profiles.pin(nil) }.accessibilityIdentifier("profileUnpin")
                            } else {
                                Button("Pin to profile", systemImage: "pin") { profiles.pin(media.id) }.accessibilityIdentifier("profilePin")
                            }
                            if media.kind == .photo {
                                Button("Use as profile picture", systemImage: "person.crop.circle") {
                                    if let data = profiles.image(media)?.jpegData(compressionQuality: 0.9) { try? profiles.setPicture(data) }
                                }
                                Button("Use as cover", systemImage: "rectangle.inset.filled") {
                                    if let data = profiles.image(media)?.jpegData(compressionQuality: 0.9) { try? profiles.setBanner(data) }
                                }
                            }
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) { deleting = true }
                    } label: { Image(systemName: "ellipsis") }.accessibilityIdentifier("profileMediaOptions")
                }
            }
            .confirmationDialog("Delete this from your profile?", isPresented: $deleting, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    guard let media else { return }
                    let next = ordered.first { $0.id != media.id }
                    profiles.remove(media)
                    if let next { current = next.id } else { dismiss() }
                }
            }
        }
    }
}

private struct ProfileMediaPage: View {
    let media: ProfileMedia
    let profiles: ProfileStore
    @State private var player: AVPlayer?
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    var body: some View {
        Group {
            if media.kind == .video {
                VideoPlayer(player: player).onAppear { player = AVPlayer(url: profiles.url(media.file)); player?.play() }
                    .onDisappear { player?.pause() }
            } else if let image = profiles.image(media) {
                Image(uiImage: image).resizable().scaledToFit()
                    .scaleEffect(zoom * pinch)
                    .gesture(MagnifyGesture().updating($pinch) { value, state, _ in state = value.magnification }
                        .onEnded { zoom = min(max(zoom * $0.magnification, 1), 4) })
                    .onTapGesture(count: 2) { withAnimation(.snappy) { zoom = zoom > 1 ? 1 : 2.5 } }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A hand pick for the Music block: typed, or chosen from the library.
struct SongEntry: View {
    let pick: ProfileSong.Pick
    let add: (String, String, UIImage?) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mobilePalette) private var palette
    @State private var title = ""
    @State private var artist = ""
    @State private var artwork: UIImage?
    @State private var choosing = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(pick == .favoriteAlbum ? "Album" : "Song", text: $title).accessibilityIdentifier("songTitle")
                    TextField("Artist", text: $artist).accessibilityIdentifier("songArtist")
                }
                Section {
                    Button("Choose from your library", systemImage: "music.note.list") { choosing = true }.accessibilityIdentifier("songFromLibrary")
                }
            }
            .scrollContentBackground(.hidden).background(palette.background)
            .navigationTitle(pick.title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add(title, artist, artwork); dismiss() }.disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("songAdd")
                }
            }
            .sheet(isPresented: $choosing) {
                MusicLibraryPicker { items in
                    guard let item = items.first else { return }
                    title = (pick == .favoriteAlbum ? item.albumTitle : item.title) ?? ""
                    artist = item.artist ?? item.albumArtist ?? ""
                    artwork = item.artwork?.image(at: CGSize(width: 300, height: 300))
                }.ignoresSafeArea()
            }
        }.presentationDetents([.medium, .large])
    }
}

/// Apple's music library picker. Only the song you choose is read: title, artist, album, and artwork.
struct MusicLibraryPicker: UIViewControllerRepresentable {
    let picked: ([MPMediaItem]) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(picked: picked) }
    func makeUIViewController(context: Context) -> MPMediaPickerController {
        let picker = MPMediaPickerController(mediaTypes: .music)
        picker.allowsPickingMultipleItems = false
        picker.showsCloudItems = true
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: MPMediaPickerController, context: Context) {}
    final class Coordinator: NSObject, MPMediaPickerControllerDelegate {
        let picked: ([MPMediaItem]) -> Void
        init(picked: @escaping ([MPMediaItem]) -> Void) { self.picked = picked }
        func mediaPicker(_ mediaPicker: MPMediaPickerController, didPickMediaItems collection: MPMediaItemCollection) {
            picked(collection.items); mediaPicker.dismiss(animated: true)
        }
        func mediaPickerDidCancel(_ mediaPicker: MPMediaPickerController) { mediaPicker.dismiss(animated: true) }
    }
}

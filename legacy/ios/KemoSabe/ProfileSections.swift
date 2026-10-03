import SwiftUI
import UniformTypeIdentifiers

// The profile's blocks (design/PROFILE-REDESIGN.md): Photos, Music, Work, Writing, Personal, Links,
// and the companion's watch game. Each is a themed card; while the page is being edited, each gets
// a bar to drag, restyle, move, or hide it, and its content controls (+, tap to edit, remove).

// MARK: The card and its editing bar

struct ProfileBlockCard<Accessory: View, Content: View>: View {
    let block: ProfileBlock
    let title: String
    let isFirst: Bool
    let isLast: Bool
    let profiles: ProfileStore
    @Binding var dragging: ProfileBlockKind?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content
    @Environment(\.mobilePalette) private var palette
    @Environment(\.profileAccent) private var accent
    @Environment(\.profileEditing) private var editing

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if editing { editBar } else { titleRow }
            if !(editing && block.hidden) { content }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            if editing {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(accent.opacity(dragging == block.kind ? 0.9 : 0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            }
        }
        .opacity(editing && block.hidden ? 0.55 : 1)
        .onDrop(of: [.text], delegate: ProfileBlockDrop(target: block.kind, dragging: $dragging, profiles: profiles))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("profileBlock-" + block.kind.rawValue)
    }
    private var icon: some View {
        Image(systemName: block.kind.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(accent)
            .frame(width: 28, height: 28).background(accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    private var titleRow: some View {
        HStack(spacing: 10) {
            icon
            Text(title).font(KemoType.font(.headline, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 8)
            accessory.font(KemoType.font(.subheadline, weight: .semibold)).foregroundStyle(accent)
        }.accessibilityElement(children: .contain)
    }
    /// Drag handle, title, who can see it, style, show or hide, and Move up or down; two rows when
    /// one won't fit.
    private var editBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { barTitle; Spacer(minLength: 4); barControls }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) { barTitle; Spacer(minLength: 0) }
                HStack(spacing: 8) { Spacer(minLength: 0); barControls }
            }
            // Narrow phones and large text: the controls wrap onto as many rows as they need.
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) { barTitle; Spacer(minLength: 0) }
                ProfileTagLayout(spacing: 8) { barControls }
            }
        }
    }
    @ViewBuilder private var barTitle: some View {
        Image(systemName: "line.3.horizontal").font(.body.weight(.semibold)).foregroundStyle(.secondary)
            .frame(minWidth: 30, minHeight: 36).contentShape(Rectangle())
            .onDrag {
                dragging = block.kind
                return NSItemProvider(object: block.kind.rawValue as NSString)
            }
            .accessibilityLabel("Reorder \(title)").accessibilityIdentifier("profileBlockHandle-" + block.kind.rawValue)
        icon
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(KemoType.font(.headline, weight: .semibold)).lineLimit(1)
            if block.hidden { Text("Hidden").font(KemoType.font(.caption)).foregroundStyle(.secondary) }
        }
    }
    @ViewBuilder private var barControls: some View {
        if !block.hidden { ProfileAudienceMenu(kind: block.kind, title: title, profiles: profiles) }
        if !block.kind.styles.isEmpty && !block.hidden {
            Menu {
                Picker("Style", selection: Binding(get: { profiles.profile.style(block.kind) }, set: { style in withAnimation(.snappy) { profiles.setStyle(block.kind, style) } })) {
                    ForEach(block.kind.styles, id: \.self) { style in Label(style.title, systemImage: style.symbol).tag(style) }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(profiles.profile.style(block.kind).title).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.bold))
                }
                .font(KemoType.font(.footnote, weight: .semibold)).foregroundStyle(accent)
                .padding(.horizontal, 10).padding(.vertical, 6).background(accent.opacity(0.14), in: Capsule())
            }.accessibilityLabel("\(title) style").accessibilityValue(profiles.profile.style(block.kind).title)
                .accessibilityIdentifier("profileBlockStyle-" + block.kind.rawValue)
        }
        Button { withAnimation(.snappy) { profiles.setHidden(block.kind, !block.hidden) } } label: {
            Image(systemName: block.hidden ? "eye.slash" : "eye").font(.body.weight(.medium)).frame(minWidth: 34, minHeight: 34)
        }.buttonStyle(.plain).foregroundStyle(block.hidden ? .secondary : accent)
            .accessibilityLabel(block.hidden ? "Show \(title)" : "Hide \(title)").accessibilityIdentifier("profileBlockHide-" + block.kind.rawValue)
        Menu {
            Button("Move up", systemImage: "arrow.up") { withAnimation(.snappy) { profiles.moveBlock(block.kind, by: -1) } }
                .disabled(isFirst).accessibilityIdentifier("profileBlockMoveUp-" + block.kind.rawValue)
            Button("Move down", systemImage: "arrow.down") { withAnimation(.snappy) { profiles.moveBlock(block.kind, by: 1) } }
                .disabled(isLast).accessibilityIdentifier("profileBlockMoveDown-" + block.kind.rawValue)
        } label: { Image(systemName: "ellipsis").frame(minWidth: 30, minHeight: 34) }
            .foregroundStyle(.secondary).accessibilityLabel("\(title) options").accessibilityIdentifier("profileBlockMenu-" + block.kind.rawValue)
    }
}

/// Dragging one block over another moves it there, live.
private struct ProfileBlockDrop: DropDelegate {
    let target: ProfileBlockKind
    @Binding var dragging: ProfileBlockKind?
    let profiles: ProfileStore
    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        withAnimation(.snappy) { profiles.moveBlock(dragging, to: target) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}

// MARK: Shared pieces

/// A group heading inside a block, with + while editing.
private struct ProfileGroupHeader: View {
    let title: String
    var addLabel: String?
    var identifier: String?
    var symbol = "plus"
    var add: (() -> Void)?
    @Environment(\.profileEditing) private var editing
    @Environment(\.profileAccent) private var accent
    var body: some View {
        HStack {
            Text(title).font(KemoType.font(.subheadline, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            if editing, let add {
                Button(action: add) { Image(systemName: symbol).font(.body.weight(.semibold)).frame(minWidth: 32, minHeight: 28) }
                    .buttonStyle(.plain).foregroundStyle(accent).accessibilityLabel(addLabel ?? "Add").accessibilityIdentifier(identifier ?? "")
            }
        }
    }
}

/// An empty block's buttons, nothing more.
private struct ProfileEmptyActions<Actions: View>: View {
    @ViewBuilder var actions: Actions
    var body: some View {
        ProfileTagLayout(spacing: 8) { actions }
            .buttonStyle(.bordered).buttonBorderShape(.capsule).font(KemoType.font(.subheadline, weight: .semibold))
    }
}

/// A rounded tile with a company's or school's initials, tinted by the accent.
private struct InitialsTile: View {
    let name: String
    var symbol: String?
    var size: CGFloat = 44
    @Environment(\.profileAccent) private var accent
    var body: some View {
        Group {
            if let symbol { Image(systemName: symbol).font(.system(size: size * 0.42, weight: .semibold)) }
            else { Text(ProfileInitials.of(name)).font(.system(size: size * 0.36, weight: .bold, design: .rounded)) }
        }
        .foregroundStyle(accent).frame(width: size, height: size)
        .background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Tags in rows from the leading edge, wrapping as needed.
struct ProfileTagLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let placed = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? placed.width, height: placed.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, point) in zip(subviews, arrange(bounds.width, subviews).points) {
            subview.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: ProposedViewSize(width: min(subview.sizeThatFits(.unspecified).width, bounds.width), height: nil))
        }
    }
    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (points: [CGPoint], width: CGFloat, height: CGFloat) {
        var points: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > width { size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            if x > 0, x + size.width > width { x = 0; y += row + spacing; row = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing; row = max(row, size.height); widest = max(widest, x - spacing)
        }
        return (points, widest, y + row)
    }
}

private struct ProfileTags: View {
    let tags: [String]
    let identifier: String
    let remove: (String) -> Void
    @Environment(\.profileAccent) private var accent
    @Environment(\.profileEditing) private var editing
    var body: some View {
        ProfileTagLayout {
            ForEach(tags, id: \.self) { tag in
                HStack(spacing: 4) {
                    Text(tag).font(KemoType.font(.subheadline, weight: .medium))
                    if editing {
                        Button { remove(tag) } label: { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                            .buttonStyle(.plain).accessibilityLabel("Remove \(tag)")
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(accent.opacity(0.15), in: Capsule())
                .contextMenu { Button("Remove", systemImage: "minus.circle", role: .destructive) { remove(tag) } }
                .accessibilityIdentifier(identifier)
            }
        }
    }
}

/// Text that shows a few lines, then all of it on a tap.
private struct ExpandableText: View {
    let text: String
    var lines = 3
    @State private var expanded = false
    var body: some View {
        Text(text).font(KemoType.font(.subheadline)).lineLimit(expanded ? nil : lines)
            .fixedSize(horizontal: false, vertical: true)
            .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
            .accessibilityAddTraits(.isButton)
    }
}

/// A month and year picked from two menus; either can be left empty.
private struct MonthField: View {
    let label: String
    @Binding var value: ProfileMonth?
    private var years: [Int] { Array((1950...(Calendar.current.component(.year, from: .now) + 6)).reversed()) }
    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                Picker("Month", selection: Binding(get: { value?.month ?? 0 }, set: { month in
                    if month == 0 { value?.month = nil } else { value = ProfileMonth(year: value?.year ?? Calendar.current.component(.year, from: .now), month: month) }
                })) {
                    Text("Month").tag(0)
                    ForEach(1...12, id: \.self) { Text(Calendar.current.shortMonthSymbols[$0 - 1]).tag($0) }
                }
                Picker("Year", selection: Binding(get: { value?.year ?? 0 }, set: { year in
                    value = year == 0 ? nil : ProfileMonth(year: year, month: value?.month)
                })) {
                    Text("Year").tag(0)
                    ForEach(years, id: \.self) { Text(String($0)).tag($0) }
                }
            }.labelsHidden().pickerStyle(.menu)
        }
    }
}

// MARK: Photos

struct ProfilePhotosBlock<AddMenu: View>: View {
    let profiles: ProfileStore
    let style: ProfileBlockStyle
    let imports: ProfileImports
    let view: (ProfileMedia) -> Void
    @ViewBuilder let addMenu: () -> AddMenu
    @Environment(\.mobilePalette) private var palette
    @Environment(\.profileAccent) private var accent
    @State private var captioning: ProfileMedia?
    @State private var captionDraft = ""
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)
    private var media: [ProfileMedia] { profiles.profile.orderedMedia }
    private var pinned: ProfileMedia? { media.first.flatMap { $0.id == profiles.profile.pinned ? $0 : nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if media.isEmpty {
                // A quiet grid of soft tiles that opens the Add menu.
                Menu { addMenu() } label: {
                    LazyVGrid(columns: columns, spacing: 3) {
                        ForEach(0..<9, id: \.self) { _ in palette.foreground.opacity(0.05).aspectRatio(1, contentMode: .fit) }
                    }.clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .menuStyle(.button).buttonStyle(.plain).accessibilityLabel("Add a post").accessibilityIdentifier("profilePostsEmpty")
            } else if style == .feed {
                let shown = Array(media.prefix(3))
                ForEach(shown) { item in
                    ProfileFeedPost(media: item, profiles: profiles, pinned: item.id == pinned?.id, inset: 0, view: { view(item) }) {
                        captionDraft = item.caption ?? ""; captioning = item
                    }
                }
            } else {
                if let pinned {
                    Button { view(pinned) } label: {
                        Color.clear.aspectRatio(4 / 3, contentMode: .fit)
                            .overlay { if let image = profiles.image(pinned) ?? profiles.thumbnail(pinned) { Image(uiImage: image).resizable().scaledToFill() } }
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)).contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(alignment: .topLeading) {
                                Label("Pinned", systemImage: "pin.fill").font(.caption.weight(.semibold)).foregroundStyle(.white)
                                    .padding(.horizontal, 8).padding(.vertical, 5).background(.black.opacity(0.35), in: Capsule()).padding(10)
                            }
                    }.buttonStyle(.plain).accessibilityLabel("Pinned post").accessibilityIdentifier("profilePinned")
                }
                let rest = Array(media.dropFirst(pinned == nil ? 0 : 1).prefix(pinned == nil ? 9 : 6))
                if !rest.isEmpty {
                    LazyVGrid(columns: columns, spacing: 3) {
                        ForEach(rest) { item in ProfilePostTile(media: item, profiles: profiles) { view(item) } }
                    }.clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            instagram
        }
        .alert("Caption", isPresented: Binding(get: { captioning != nil }, set: { if !$0 { captioning = nil } })) {
            TextField("Write a caption", text: $captionDraft).accessibilityIdentifier("captionField")
            Button("Save") { if let media = captioning { profiles.setCaption(captionDraft, for: media.id) }; captioning = nil }
            Button("Cancel", role: .cancel) { captioning = nil }
        }
    }
    @ViewBuilder private var instagram: some View {
        if let progress = imports.instagramProgress {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    KemoOrb(size: 18, state: .weaving).tint(accent)
                    Text("Importing \(min(progress.done + 1, max(progress.total, 1))) of \(max(progress.total, 1))…").font(KemoType.font(.footnote)).monospacedDigit()
                    Spacer()
                    Button("Stop") { imports.stopInstagram() }.font(KemoType.font(.footnote, weight: .semibold))
                }
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))).tint(accent)
            }.accessibilityIdentifier("profileInstagramProgress")
        }
        if let message = imports.instagramMessage {
            Text(message).font(KemoType.font(.footnote)).foregroundStyle(.secondary).accessibilityIdentifier("profileInstagramMessage")
        }
    }
}

// MARK: Music

struct ProfileMusicBlock: View {
    let profiles: ProfileStore
    let style: ProfileBlockStyle
    let library: MusicLibrarySource
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.mobilePalette) private var palette
    @Environment(\.profileAccent) private var accent
    @Environment(\.profileEditing) private var editing
    @State private var connecting = false
    @State private var access: MusicLibraryAccess?
    @State private var picking: ProfileSong.Pick?
    private var stats: MusicStats? { profiles.profile.musicStats }
    private var picks: [ProfileSong] { profiles.profile.songs }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let stats {
                if stats.isEmpty {
                    Text("No plays in your library yet.").font(KemoType.font(.subheadline)).foregroundStyle(.secondary)
                } else {
                    switch style {
                    case .topSongs: songList("Top songs", stats.topSongs, detail: { "\($0.plays) plays" })
                    case .onRepeat:
                        if stats.onRepeat.isEmpty {
                            Text("Nothing played in the last \(MusicStats.recentDays) days.").font(KemoType.font(.subheadline)).foregroundStyle(.secondary)
                        } else {
                            songList("On repeat lately", stats.onRepeat, detail: { song in
                                [("\(song.plays) plays"), song.lastPlayed.map { $0.formatted(.relative(presentation: .named)) }].compactMap { $0 }.joined(separator: " · ")
                            })
                        }
                    default: topArtists(stats)
                    }
                    genres(stats)
                    Text("\(stats.totalPlays.formatted()) plays · \(stats.songsPlayed.formatted()) songs · Apple Music library")
                        .font(KemoType.font(.caption)).foregroundStyle(.secondary).accessibilityIdentifier("profileMusicTotals")
                }
            }
            if !picks.isEmpty { pickRows }
            controls
        }
        .sheet(item: $picking) { pick in
            SongEntry(pick: pick) { title, artist, artwork in profiles.addSong(title: title, artist: artist, artwork: artwork, pick: pick) }
        }
    }

    /// The top artist big, then the next four.
    @ViewBuilder private func topArtists(_ stats: MusicStats) -> some View {
        if let top = stats.topArtists.first {
            HStack(spacing: 14) {
                artwork(top.artwork, size: 84, circle: false)
                VStack(alignment: .leading, spacing: 3) {
                    Text("TOP ARTIST").font(KemoType.font(.caption2, weight: .bold)).foregroundStyle(accent).tracking(1)
                    Text(top.name).font(KemoType.font(.title3, weight: .bold)).lineLimit(2).minimumScaleFactor(0.8)
                    Text("\(top.plays.formatted()) plays").font(KemoType.font(.footnote)).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer(minLength: 0)
            }.accessibilityElement(children: .combine).accessibilityIdentifier("profileMusicTopArtist")
            let others = Array(stats.topArtists.dropFirst().prefix(4))
            if !others.isEmpty && typeSize.isAccessibilitySize {
                // A list at the accessibility text sizes, so every name fits.
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(others.enumerated()), id: \.element.id) { index, artist in
                        HStack(spacing: 12) {
                            artwork(artist.artwork, size: 44, circle: true)
                            Text("\(index + 2). \(artist.name)").font(KemoType.font(.subheadline, weight: .semibold))
                        }.accessibilityElement(children: .combine).accessibilityIdentifier("profileMusicArtist")
                    }
                }
            } else if !others.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(Array(others.enumerated()), id: \.element.id) { index, artist in
                        VStack(spacing: 5) {
                            artwork(artist.artwork, size: 58, circle: true)
                            Text(artist.name).font(KemoType.font(.caption, weight: .medium)).lineLimit(1)
                            Text("#\(index + 2)").font(KemoType.font(.caption2)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).accessibilityElement(children: .combine).accessibilityIdentifier("profileMusicArtist")
                    }
                }
            }
        }
    }
    private func songList(_ title: String, _ songs: [MusicStats.Song], detail: @escaping (MusicStats.Song) -> String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(KemoType.font(.subheadline, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(Array(songs.prefix(5).enumerated()), id: \.element.id) { index, song in
                HStack(spacing: 12) {
                    Text("\(index + 1)").font(KemoType.font(.subheadline, weight: .bold)).foregroundStyle(accent).monospacedDigit().frame(minWidth: 16)
                    artwork(song.artwork, size: 46, circle: false)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.title).font(KemoType.font(.subheadline, weight: .semibold)).lineLimit(1)
                        Text(song.artist).font(KemoType.font(.footnote)).foregroundStyle(.secondary).lineLimit(1)
                        Text(detail(song)).font(KemoType.font(.caption)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.accessibilityElement(children: .combine).accessibilityIdentifier("profileMusicSong")
            }
        }
    }
    @ViewBuilder private func genres(_ stats: MusicStats) -> some View {
        if !stats.topGenres.isEmpty {
            ProfileTagLayout {
                ForEach(stats.topGenres) { genre in
                    HStack(spacing: 5) {
                        Text(genre.name).font(KemoType.font(.footnote, weight: .semibold))
                        Text(genre.share.formatted(.percent.precision(.fractionLength(0)))).font(KemoType.font(.footnote)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5).background(accent.opacity(0.14), in: Capsule())
                    .accessibilityElement(children: .combine).accessibilityIdentifier("profileMusicGenre")
                }
            }
        }
    }
    /// Your hand picks: a song on repeat, a favorite album, favorite songs.
    private var pickRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(picks) { song in
                HStack(spacing: 12) {
                    artwork(song.artwork, size: 46, circle: false)
                    VStack(alignment: .leading, spacing: 2) {
                        Text((song.pick ?? .favoriteSong).title.uppercased()).font(KemoType.font(.caption2, weight: .bold)).foregroundStyle(accent).tracking(0.8)
                        Text(song.title).font(KemoType.font(.subheadline, weight: .semibold)).lineLimit(1)
                        if !song.artist.isEmpty { Text(song.artist).font(KemoType.font(.footnote)).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer(minLength: 0)
                    if editing {
                        Button { profiles.removeSong(song) } label: { Image(systemName: "minus.circle.fill").font(.title3).foregroundStyle(.secondary) }
                            .buttonStyle(.plain).accessibilityLabel("Remove \(song.title)")
                    }
                }
                .contextMenu { Button("Remove", systemImage: "minus.circle", role: .destructive) { profiles.removeSong(song) } }
                .accessibilityElement(children: .combine).accessibilityIdentifier("profileSong")
            }
        }
    }
    /// Connect when there are no stats; Refresh, Disconnect, and Add a pick while editing.
    @ViewBuilder private var controls: some View {
        if access == .denied || access == .restricted {
            HStack {
                Text(access == .restricted ? "Music access is restricted." : "Music access is off.").font(KemoType.font(.footnote)).foregroundStyle(.secondary)
                Spacer()
                Button("Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                    .font(KemoType.font(.footnote, weight: .semibold))
            }.accessibilityIdentifier("profileMusicAccessOff")
        }
        if stats == nil || editing || picks.isEmpty && stats == nil {
            ProfileEmptyActions {
                if stats == nil {
                    Button { connect() } label: {
                        HStack(spacing: 6) {
                            if connecting { KemoOrb(size: 16, state: .connecting).tint(accent) } else { Image(systemName: "music.note") }
                            Text("Connect Apple Music")
                        }
                    }.buttonStyle(.borderedProminent).tint(accent).disabled(connecting).accessibilityIdentifier("profileConnectAppleMusic")
                } else if editing {
                    Button { refresh() } label: {
                        HStack(spacing: 6) {
                            if connecting { KemoOrb(size: 16, state: .connecting).tint(accent) } else { Image(systemName: "arrow.clockwise") }
                            Text("Refresh")
                        }
                    }.disabled(connecting).accessibilityIdentifier("profileMusicRefresh")
                    Button("Disconnect", role: .destructive) { profiles.disconnectMusic() }.accessibilityIdentifier("profileMusicDisconnect")
                }
                if stats == nil || editing {
                    Menu {
                        ForEach(ProfileSong.Pick.allCases) { pick in Button(pick.title) { picking = pick } }
                    } label: { Label("Add a pick", systemImage: "plus") }.accessibilityIdentifier("profileAddSong")
                }
                if stats == nil {
                    Button("Spotify · Complete later") {}.disabled(true).accessibilityIdentifier("profileConnectSpotify")
                }
            }
        }
    }
    private func artwork(_ name: String?, size: CGFloat, circle: Bool) -> some View {
        Group {
            if let image = profiles.artworkImage(name) { Image(uiImage: image).resizable().scaledToFill() }
            else {
                Image(systemName: "music.note").font(.system(size: size * 0.36, weight: .semibold)).foregroundStyle(accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(accent.opacity(0.14))
            }
        }
        .frame(width: size, height: size)
        .clipShape(circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)))
    }
    private func connect() {
        connecting = true
        Task {
            access = await profiles.connectMusic(library)
            connecting = false
        }
    }
    private func refresh() {
        connecting = true
        Task { await profiles.refreshMusic(library); access = library.access; connecting = false }
    }
}

// MARK: Work

struct ProfileWorkBlock: View {
    let profiles: ProfileStore
    let style: ProfileBlockStyle
    let imports: ProfileImports
    @Environment(\.profileAccent) private var accent
    @Environment(\.profileEditing) private var editing
    @State private var job: WorkEntry?
    @State private var school: EducationEntry?
    @State private var certification: CertificationEntry?
    @State private var editingAbout = false
    @State private var addingSkill = false
    @State private var skillDraft = ""
    @State private var addingLanguage = false
    @State private var languageDraft = ""
    @State private var allSkills = false
    /// Entries whose whole description shows; a tap outside editing opens or closes it.
    @State private var expanded: Set<UUID> = []
    private var profile: SocialProfile { profiles.profile }
    private var isEmpty: Bool {
        profile.experience.isEmpty && profile.education.isEmpty && profile.skills.isEmpty && profile.certifications.isEmpty
            && profile.languages.isEmpty && profile.about == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let intro = profile.linkedInIntro { introCard(intro) }
            if isEmpty {
                ProfileEmptyActions {
                    Button("Import from LinkedIn") { imports.pickingLinkedIn = true }.accessibilityIdentifier("profileImportLinkedIn")
                    Button("Add by hand") { job = WorkEntry() }.accessibilityIdentifier("profileAddWork")
                }
            } else if style == .summary {
                summary
            } else {
                full
            }
            if imports.readingLinkedIn {
                HStack(spacing: 8) { KemoOrb(size: 18, state: .searching).tint(accent); Text("Reading your LinkedIn files…").font(KemoType.font(.footnote)) }
            }
            if let message = imports.linkedInMessage {
                Text(message).font(KemoType.font(.footnote)).foregroundStyle(.secondary).accessibilityIdentifier("profileWorkMessage")
            }
            if editing && !isEmpty {
                Button { imports.pickingLinkedIn = true } label: { Label("Import from LinkedIn", systemImage: "square.and.arrow.down") }
                    .font(KemoType.font(.subheadline, weight: .semibold)).accessibilityIdentifier("profileImportLinkedIn")
            }
        }
        .sheet(item: $job) { WorkEntryEditor(entry: $0, profiles: profiles) }
        .sheet(item: $school) { EducationEntryEditor(entry: $0, profiles: profiles) }
        .sheet(item: $certification) { CertificationEditor(entry: $0, profiles: profiles) }
        .sheet(isPresented: $editingAbout) { AboutEditor(profiles: profiles) }
        .alert("Add a skill", isPresented: $addingSkill) {
            TextField("Skill", text: $skillDraft).accessibilityIdentifier("profileSkillField")
            Button("Add") { let skill = skillDraft; profiles.update { $0.skills.append(skill) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Add a language", isPresented: $addingLanguage) {
            TextField("Language", text: $languageDraft).accessibilityIdentifier("profileLanguageField")
            Button("Add") { let name = languageDraft; profiles.update { $0.languages.append(LanguageEntry(name: name)) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    // As on LinkedIn: About, Experience, Education, Licenses & certifications, Skills, Languages.
    @ViewBuilder private var full: some View {
        if profile.about != nil || editing {
            VStack(alignment: .leading, spacing: 8) {
                ProfileGroupHeader(title: "About", addLabel: "Edit About", identifier: "profileEditAbout", symbol: "pencil") { editingAbout = true }
                if let about = profile.about { ExpandableText(text: about, lines: 4).accessibilityIdentifier("profileWorkAbout") }
            }
        }
        if !profile.experience.isEmpty || editing {
            VStack(alignment: .leading, spacing: 14) {
                ProfileGroupHeader(title: "Experience", addLabel: "Add experience", identifier: "profileAddWork") { job = WorkEntry() }
                ForEach(WorkEntry.grouped(profile.experience), id: \.first!.id) { group in experience(group) }
            }
        }
        if !profile.education.isEmpty || editing {
            VStack(alignment: .leading, spacing: 14) {
                ProfileGroupHeader(title: "Education", addLabel: "Add education", identifier: "profileAddEducation") { school = EducationEntry() }
                ForEach(profile.education) { entry in education(entry) }
            }
        }
        if !profile.certifications.isEmpty || editing {
            VStack(alignment: .leading, spacing: 14) {
                ProfileGroupHeader(title: "Licenses & certifications", addLabel: "Add a certification", identifier: "profileAddCertification") { certification = CertificationEntry() }
                ForEach(profile.certifications) { entry in certificationRow(entry) }
            }
        }
        if !profile.skills.isEmpty || editing {
            VStack(alignment: .leading, spacing: 10) {
                ProfileGroupHeader(title: "Skills", addLabel: "Add a skill", identifier: "profileAddSkill") { skillDraft = ""; addingSkill = true }
                ProfileTags(tags: allSkills || editing ? profile.skills : Array(profile.skills.prefix(10)), identifier: "profileSkill") { tag in
                    profiles.update { $0.skills.removeAll { $0 == tag } }
                }
                if profile.skills.count > 10 && !allSkills && !editing {
                    Button("Show all \(profile.skills.count) skills") { withAnimation(.snappy) { allSkills = true } }
                        .font(KemoType.font(.footnote, weight: .semibold)).accessibilityIdentifier("profileAllSkills")
                }
            }
        }
        if !profile.languages.isEmpty || editing {
            VStack(alignment: .leading, spacing: 8) {
                ProfileGroupHeader(title: "Languages", addLabel: "Add a language", identifier: "profileAddLanguage") { languageDraft = ""; addingLanguage = true }
                ForEach(profile.languages) { language in
                    HStack(alignment: .firstTextBaseline) {
                        Text(language.name).font(KemoType.font(.subheadline, weight: .semibold))
                        if !language.proficiency.isEmpty { Text(language.proficiency).font(KemoType.font(.footnote)).foregroundStyle(.secondary) }
                        Spacer()
                        if editing {
                            Button { profiles.update { $0.languages.removeAll { $0.id == language.id } } } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                                .buttonStyle(.plain).accessibilityLabel("Remove \(language.name)")
                        }
                    }.accessibilityElement(children: .combine).accessibilityIdentifier("profileLanguage")
                }
            }
        }
    }
    /// The current role, the latest school, and the top skills.
    @ViewBuilder private var summary: some View {
        if let current = profile.experience.first {
            Button { if editing { job = current } } label: {
                HStack(alignment: .top, spacing: 12) {
                    InitialsTile(name: current.company.isEmpty ? current.title : current.company)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(current.title.isEmpty ? current.company : current.title).font(KemoType.font(.subheadline, weight: .semibold))
                        if !current.title.isEmpty && !current.company.isEmpty { Text(current.company).font(KemoType.font(.subheadline)) }
                        if !current.dates.isEmpty { Text(current.datesAndDuration()).font(KemoType.font(.footnote)).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("profileWorkEntry")
        }
        if let latest = profile.education.first {
            HStack(alignment: .top, spacing: 12) {
                InitialsTile(name: latest.school)
                VStack(alignment: .leading, spacing: 2) {
                    Text(latest.school).font(KemoType.font(.subheadline, weight: .semibold))
                    if !latest.degree.isEmpty { Text(latest.degree).font(KemoType.font(.footnote)).foregroundStyle(.secondary) }
                }
            }.accessibilityElement(children: .combine).accessibilityIdentifier("profileEducationEntry")
        }
        if !profile.skills.isEmpty {
            ProfileTags(tags: Array(profile.skills.prefix(5)), identifier: "profileSkill") { tag in profiles.update { $0.skills.removeAll { $0 == tag } } }
        }
    }
    /// One job, or several at one company under it with a line between them, as LinkedIn shows a promotion.
    @ViewBuilder private func experience(_ group: [WorkEntry]) -> some View {
        if group.count == 1, let entry = group.first {
            Button { open(entry) } label: {
                HStack(alignment: .top, spacing: 12) {
                    InitialsTile(name: entry.company.isEmpty ? entry.title : entry.company)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title.isEmpty ? entry.company : entry.title).font(KemoType.font(.subheadline, weight: .semibold))
                        if !entry.title.isEmpty && !entry.company.isEmpty { Text(entry.company).font(KemoType.font(.subheadline)) }
                        roleDetails(entry)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
                .contextMenu { Button("Delete", systemImage: "trash", role: .destructive) { profiles.update { $0.experience.removeAll { $0.id == entry.id } } } }
                .accessibilityIdentifier("profileWorkEntry")
        } else if let first = group.first {
            HStack(alignment: .top, spacing: 12) {
                InitialsTile(name: first.company)
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(first.company).font(KemoType.font(.subheadline, weight: .semibold))
                        if let span = WorkEntry.span(group) { Text(span).font(KemoType.font(.footnote)).foregroundStyle(.secondary) }
                    }
                    ForEach(Array(group.enumerated()), id: \.element.id) { index, entry in
                        Button { open(entry) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                VStack(spacing: 0) {
                                    Circle().fill(accent).frame(width: 8, height: 8).padding(.top, 5)
                                    if index < group.count - 1 { Rectangle().fill(accent.opacity(0.3)).frame(width: 2).frame(maxHeight: .infinity) }
                                }.frame(width: 8)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title.isEmpty ? entry.company : entry.title).font(KemoType.font(.subheadline, weight: .semibold))
                                    roleDetails(entry)
                                }
                                Spacer(minLength: 0)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("profileWorkEntry")
                            .contextMenu { Button("Delete", systemImage: "trash", role: .destructive) { profiles.update { $0.experience.removeAll { $0.id == entry.id } } } }
                    }
                }
            }
        }
    }
    /// Editing opens the entry's editor; otherwise a tap shows its whole description.
    private func open(_ entry: WorkEntry) { if editing { job = entry } else { toggle(entry.id) } }
    private func toggle(_ id: UUID) {
        withAnimation(.snappy) { if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) } }
    }
    @ViewBuilder private func roleDetails(_ entry: WorkEntry) -> some View {
        if !entry.dates.isEmpty { Text(entry.datesAndDuration()).font(KemoType.font(.footnote)).foregroundStyle(.secondary) }
        if !entry.location.isEmpty { Text(entry.location).font(KemoType.font(.footnote)).foregroundStyle(.secondary) }
        if !entry.summary.isEmpty {
            Text(entry.summary).font(KemoType.font(.subheadline)).lineLimit(expanded.contains(entry.id) ? nil : 3)
                .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading).padding(.top, 4)
        }
    }
    private func education(_ entry: EducationEntry) -> some View {
        Button { if editing { school = entry } else { toggle(entry.id) } } label: {
            HStack(alignment: .top, spacing: 12) {
                InitialsTile(name: entry.school)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.school).font(KemoType.font(.subheadline, weight: .semibold))
                    if !entry.degree.isEmpty { Text(entry.degree).font(KemoType.font(.subheadline)) }
                    if !entry.dates.isEmpty { Text(entry.dates).font(KemoType.font(.footnote)).foregroundStyle(.secondary) }
                    if !entry.notes.isEmpty {
                        Text(entry.notes).font(KemoType.font(.subheadline)).lineLimit(expanded.contains(entry.id) ? nil : 2)
                            .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading).padding(.top, 4)
                    }
                }
                Spacer(minLength: 0)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
            .contextMenu { Button("Delete", systemImage: "trash", role: .destructive) { profiles.update { $0.education.removeAll { $0.id == entry.id } } } }
            .accessibilityIdentifier("profileEducationEntry")
    }
    private func certificationRow(_ entry: CertificationEntry) -> some View {
        Button { if editing { certification = entry } } label: {
            HStack(alignment: .top, spacing: 12) {
                InitialsTile(name: entry.authority, symbol: "checkmark.seal.fill")
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(KemoType.font(.subheadline, weight: .semibold))
                    if !entry.authority.isEmpty { Text(entry.authority).font(KemoType.font(.subheadline)) }
                    let dates = [entry.issued.map { "Issued " + $0.text }, entry.expires.map { "Expires " + $0.text }].compactMap { $0 }.joined(separator: " · ")
                    if !dates.isEmpty { Text(dates).font(KemoType.font(.footnote)).foregroundStyle(.secondary) }
                    if let url = entry.url, !editing {
                        Link(destination: url) { Label("Show credential", systemImage: "arrow.up.right.square") }
                            .font(KemoType.font(.footnote, weight: .semibold)).padding(.top, 4)
                    }
                }
                Spacer(minLength: 0)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
            .contextMenu { Button("Delete", systemImage: "trash", role: .destructive) { profiles.update { $0.certifications.removeAll { $0.id == entry.id } } } }
            .accessibilityIdentifier("profileCertification")
    }
    /// What LinkedIn had for the header and Personal, offered but never applied on their own.
    private func introCard(_ intro: ImportedIntro) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("From your LinkedIn").font(KemoType.font(.caption, weight: .semibold)).foregroundStyle(.secondary)
            if let headline = intro.headline {
                Text(headline).font(KemoType.font(.subheadline, weight: .medium))
                Button("Use as headline") { profiles.update { $0.headline = headline; $0.linkedInIntro?.headline = nil } }
                    .accessibilityIdentifier("profileUseLinkedInHeadline")
            }
            if let summary = intro.summary {
                Text(summary).font(KemoType.font(.footnote)).lineLimit(4)
                HStack(spacing: 16) {
                    Button("Use as About") { profiles.update { $0.about = summary; $0.linkedInIntro?.summary = nil } }
                        .accessibilityIdentifier("profileUseLinkedInAbout")
                    Button("Use as bio") { profiles.update { $0.bio = summary; $0.linkedInIntro?.summary = nil } }
                        .accessibilityIdentifier("profileUseLinkedInSummary")
                }
            }
            if let location = intro.location {
                Text(location).font(KemoType.font(.footnote))
                Button("Add as Lives in") {
                    profiles.update { $0.facts.append(ProfileFact(label: "Lives in", value: location)); $0.linkedInIntro?.location = nil }
                }.accessibilityIdentifier("profileUseLinkedInLocation")
            }
            Button("Not now") { profiles.update { $0.linkedInIntro = nil } }.foregroundStyle(.secondary)
        }
        .font(KemoType.font(.subheadline, weight: .semibold)).buttonStyle(.borderless)
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct WorkEntryEditor: View {
    let profiles: ProfileStore
    @State private var draft: WorkEntry
    @State private var current: Bool
    private let isNew: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mobilePalette) private var palette
    init(entry: WorkEntry, profiles: ProfileStore) {
        self.profiles = profiles
        _draft = State(initialValue: entry); _current = State(initialValue: entry.end == nil)
        isNew = !profiles.profile.experience.contains { $0.id == entry.id }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title, like “iOS engineer”", text: $draft.title).accessibilityIdentifier("workTitle")
                    TextField("Company", text: $draft.company).accessibilityIdentifier("workCompany")
                    TextField("Location", text: $draft.location).accessibilityIdentifier("workLocation")
                }
                Section {
                    MonthField(label: "Started", value: $draft.start)
                    Toggle("I work here now", isOn: $current)
                    if !current { MonthField(label: "Ended", value: $draft.end) }
                }
                Section { TextField("What you did there", text: $draft.summary, axis: .vertical).lineLimit(3...8).accessibilityIdentifier("workSummary") }
                if !isNew {
                    Section { Button("Delete", role: .destructive) { let id = draft.id; profiles.update { $0.experience.removeAll { $0.id == id } }; dismiss() } }
                }
            }
            .scrollContentBackground(.hidden).background(palette.background)
            .navigationTitle(isNew ? "Add experience" : "Edit experience").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        var entry = draft
                        if current { entry.end = nil }
                        profiles.update { profile in
                            if let index = profile.experience.firstIndex(where: { $0.id == entry.id }) { profile.experience[index] = entry } else { profile.experience.append(entry) }
                            profile.experience.sort(by: WorkEntry.newestFirst)
                        }
                        dismiss()
                    }.disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty && draft.company.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("workSave")
                }
            }
        }
    }
}

private struct EducationEntryEditor: View {
    let profiles: ProfileStore
    @State private var draft: EducationEntry
    private let isNew: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mobilePalette) private var palette
    init(entry: EducationEntry, profiles: ProfileStore) {
        self.profiles = profiles
        _draft = State(initialValue: entry)
        isNew = !profiles.profile.education.contains { $0.id == entry.id }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("School", text: $draft.school).accessibilityIdentifier("educationSchool")
                    TextField("Degree or program", text: $draft.degree).accessibilityIdentifier("educationDegree")
                }
                Section {
                    MonthField(label: "Started", value: $draft.start)
                    MonthField(label: "Finished", value: $draft.end)
                }
                Section { TextField("Notes and activities", text: $draft.notes, axis: .vertical).lineLimit(2...6) }
                if !isNew {
                    Section { Button("Delete", role: .destructive) { let id = draft.id; profiles.update { $0.education.removeAll { $0.id == id } }; dismiss() } }
                }
            }
            .scrollContentBackground(.hidden).background(palette.background)
            .navigationTitle(isNew ? "Add education" : "Edit education").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        let entry = draft
                        profiles.update { profile in
                            if let index = profile.education.firstIndex(where: { $0.id == entry.id }) { profile.education[index] = entry } else { profile.education.append(entry) }
                        }
                        dismiss()
                    }.disabled(draft.school.trimmingCharacters(in: .whitespaces).isEmpty).accessibilityIdentifier("educationSave")
                }
            }
        }
    }
}

private struct CertificationEditor: View {
    let profiles: ProfileStore
    @State private var draft: CertificationEntry
    private let isNew: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mobilePalette) private var palette
    init(entry: CertificationEntry, profiles: ProfileStore) {
        self.profiles = profiles
        _draft = State(initialValue: entry)
        isNew = !profiles.profile.certifications.contains { $0.id == entry.id }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, like “AWS Solutions Architect”", text: $draft.name).accessibilityIdentifier("certificationName")
                    TextField("Issued by", text: $draft.authority).accessibilityIdentifier("certificationAuthority")
                }
                Section {
                    MonthField(label: "Issued", value: $draft.issued)
                    MonthField(label: "Expires", value: $draft.expires)
                }
                Section {
                    TextField("Credential link (https://…)", text: Binding(get: { draft.link ?? "" }, set: { draft.link = $0 }))
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                }
                if !isNew {
                    Section { Button("Delete", role: .destructive) { let id = draft.id; profiles.update { $0.certifications.removeAll { $0.id == id } }; dismiss() } }
                }
            }
            .scrollContentBackground(.hidden).background(palette.background)
            .navigationTitle(isNew ? "Add certification" : "Edit certification").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        let entry = draft
                        profiles.update { profile in
                            if let index = profile.certifications.firstIndex(where: { $0.id == entry.id }) { profile.certifications[index] = entry } else { profile.certifications.append(entry) }
                        }
                        dismiss()
                    }.disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty).accessibilityIdentifier("certificationSave")
                }
            }
        }
    }
}

/// The About at the top of Work.
private struct AboutEditor: View {
    let profiles: ProfileStore
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mobilePalette) private var palette
    var body: some View {
        NavigationStack {
            Form {
                TextField("About your work", text: $text, axis: .vertical).lineLimit(6...16).accessibilityIdentifier("profileAboutField")
            }
            .scrollContentBackground(.hidden).background(palette.background)
            .navigationTitle("About").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { let about = text; profiles.update { $0.about = about }; dismiss() }.accessibilityIdentifier("profileAboutSave")
                }
            }
            .onAppear { text = profiles.profile.about ?? "" }
        }
    }
}

// MARK: Writing

struct ProfileWritingBlock: View {
    let profiles: ProfileStore
    let style: ProfileBlockStyle
    @Environment(\.mobilePalette) private var palette
    @Environment(\.profileAccent) private var accent
    @Environment(\.profileEditing) private var editing
    @State private var address = ""
    @State private var loading = false
    @State private var problem: String?
    @State private var removing = false
    private var blog: ProfileBlog? { profiles.profile.blog }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let blog { entries(blog) } else { add }
            if let problem { Text(problem).font(KemoType.font(.footnote)).foregroundStyle(.orange).accessibilityIdentifier("profileBlogProblem") }
        }
        .confirmationDialog("Remove your blog from your profile?", isPresented: $removing, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { profiles.update { $0.blog = nil } }
        } message: { Text("Its posts stay on your blog.") }
    }
    private var add: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("yourblog.com", text: $address)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).submitLabel(.done)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(palette.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .onSubmit(fetch).accessibilityIdentifier("profileBlogAddress")
                if loading { KemoOrb(size: 22, state: .searching).tint(accent) }
                else {
                    Button("Add", action: fetch).buttonStyle(.bordered).buttonBorderShape(.capsule)
                        .disabled(FeedDiscovery.normalize(address) == nil).accessibilityIdentifier("profileBlogAdd")
                }
            }
            // The one host the feed is read from, named before anything is fetched.
            if let host = FeedDiscovery.normalize(address)?.host {
                Text("Reads \(host)").font(KemoType.font(.caption)).foregroundStyle(.secondary).accessibilityIdentifier("profileBlogDisclosure")
            }
        }
    }
    private func entries(_ blog: ProfileBlog) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(blog.title ?? blog.host ?? blog.address).font(KemoType.font(.subheadline, weight: .semibold)).lineLimit(1)
                    Text([blog.host, blog.refreshed.map { "Updated " + $0.formatted(.relative(presentation: .named)) }].compactMap { $0 }.joined(separator: " · "))
                        .font(KemoType.font(.caption)).foregroundStyle(.secondary)
                }
                Spacer()
                if editing {
                    if loading { KemoOrb(size: 20, state: .searching).tint(accent) }
                    else { Button("Refresh", action: refresh).font(KemoType.font(.subheadline, weight: .semibold)).accessibilityIdentifier("profileBlogRefresh") }
                    Menu {
                        Button("Remove blog", systemImage: "trash", role: .destructive) { removing = true }
                    } label: { Image(systemName: "ellipsis").frame(width: 32, height: 32) }.accessibilityLabel("Blog options")
                }
            }
            if blog.entries.isEmpty {
                Text("The feed has no posts yet.").font(KemoType.font(.subheadline)).foregroundStyle(.secondary)
            }
            let shown = style == .latest ? Array(blog.entries.prefix(1)) : Array(blog.entries.prefix(5))
            ForEach(shown) { entry in
                let content = VStack(alignment: .leading, spacing: 4) {
                    if let date = entry.date { Text(date.formatted(date: .abbreviated, time: .omitted)).font(KemoType.font(.caption)).foregroundStyle(.secondary) }
                    Text(entry.title.isEmpty ? "Untitled" : entry.title).font(KemoType.font(style == .latest ? .title3 : .subheadline, weight: .semibold))
                        .foregroundStyle(palette.foreground).multilineTextAlignment(.leading)
                    if !entry.summary.isEmpty {
                        Text(entry.summary).font(KemoType.font(.footnote)).foregroundStyle(.secondary).lineLimit(style == .latest ? 6 : 2).multilineTextAlignment(.leading)
                    }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                if let url = entry.url { Link(destination: url) { content }.accessibilityIdentifier("profileBlogEntry") }
                else { content.accessibilityIdentifier("profileBlogEntry") }
            }
        }
    }
    private func fetch() {
        guard FeedDiscovery.normalize(address) != nil, !loading else { return }
        loading = true; problem = nil
        Task {
            defer { loading = false }
            do { try await profiles.setBlog(address); address = "" } catch { problem = error.localizedDescription }
        }
    }
    private func refresh() {
        loading = true; problem = nil
        Task {
            defer { loading = false }
            do { try await profiles.refreshBlog() } catch { problem = error.localizedDescription }
        }
    }
}

// MARK: Personal

struct ProfilePersonalBlock: View {
    let profiles: ProfileStore
    @Environment(\.profileEditing) private var editing
    @State private var addingInterest = false
    @State private var interestDraft = ""
    @State private var addingFact = false
    private var profile: SocialProfile { profiles.profile }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if profile.interests.isEmpty && profile.facts.isEmpty && !editing {
                ProfileEmptyActions {
                    Button("Add an interest") { interestDraft = ""; addingInterest = true }.accessibilityIdentifier("profileAddInterest")
                    Button("Add a fact") { addingFact = true }.accessibilityIdentifier("profileAddFact")
                }
            } else {
                if !profile.facts.isEmpty || editing {
                    VStack(alignment: .leading, spacing: 4) {
                        ProfileGroupHeader(title: "About me", addLabel: "Add a fact", identifier: "profileAddFact") { addingFact = true }
                        ForEach(profile.facts) { fact in
                            HStack(alignment: .firstTextBaseline) {
                                Text(fact.label).font(KemoType.font(.subheadline)).foregroundStyle(.secondary)
                                Spacer(minLength: 12)
                                Text(fact.value).font(KemoType.font(.subheadline, weight: .medium)).multilineTextAlignment(.trailing)
                                if editing {
                                    Button { profiles.update { $0.facts.removeAll { $0.id == fact.id } } } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                                        .buttonStyle(.plain).accessibilityLabel("Remove \(fact.label)")
                                }
                            }.padding(.vertical, 6)
                                .contextMenu { Button("Remove", systemImage: "minus.circle", role: .destructive) { profiles.update { $0.facts.removeAll { $0.id == fact.id } } } }
                                .accessibilityElement(children: .combine).accessibilityIdentifier("profileFact")
                            if fact.id != profile.facts.last?.id { Divider() }
                        }
                    }
                }
                if !profile.interests.isEmpty || editing {
                    VStack(alignment: .leading, spacing: 10) {
                        ProfileGroupHeader(title: "Interests", addLabel: "Add an interest", identifier: "profileAddInterest") { interestDraft = ""; addingInterest = true }
                        ProfileTags(tags: profile.interests, identifier: "profileInterest") { tag in profiles.update { $0.interests.removeAll { $0 == tag } } }
                    }
                }
            }
        }
        .sheet(isPresented: $addingFact) { FactEntry { label, value in profiles.update { $0.facts.append(ProfileFact(label: label, value: value)) } } }
        .alert("Add an interest", isPresented: $addingInterest) {
            TextField("Interest", text: $interestDraft).accessibilityIdentifier("profileInterestField")
            Button("Add") { let interest = interestDraft; profiles.update { $0.interests.append(interest) } }
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// A short fact: a label (suggested or your own) and what to show.
private struct FactEntry: View {
    let add: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var value = ""
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Label, like Hometown", text: $label).accessibilityIdentifier("factLabel")
                    TextField("What to show", text: $value).accessibilityIdentifier("factValue")
                } footer: {
                    ProfileTagLayout {
                        ForEach(ProfileFact.suggestions, id: \.self) { suggestion in
                            Button(suggestion) { label = suggestion }.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                        }
                    }.padding(.top, 6)
                }
            }
            .navigationTitle("Add a fact").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add(label, value); dismiss() }
                        .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty || value.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("factAdd")
                }
            }
        }.presentationDetents([.medium])
    }
}

// MARK: Links

struct ProfileLinksBlock: View {
    let profiles: ProfileStore
    let style: ProfileBlockStyle
    @Binding var drafts: [ProfileLink.Platform: String]
    let addLinks: () -> Void
    @Environment(\.mobilePalette) private var palette
    @Environment(\.profileAccent) private var accent
    @Environment(\.profileEditing) private var editing
    private var links: [ProfileLink] { profiles.profile.links.filter { $0.url != nil } }
    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        if editing {
            VStack(spacing: 8) {
                ForEach(ProfileLink.Platform.allCases) { platform in
                    HStack(spacing: 10) {
                        Image(systemName: platform.symbol).foregroundStyle(accent).frame(width: 22)
                        Text(platform.title).font(KemoType.font(.subheadline)).frame(width: 96, alignment: .leading).lineLimit(1).minimumScaleFactor(0.8)
                        TextField(platform == .website ? "https://…" : "username", text: Binding(get: { drafts[platform] ?? "" }, set: { drafts[platform] = $0 }))
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(platform == .website ? .URL : .default)
                            .font(KemoType.font(.subheadline))
                            .accessibilityIdentifier("profileLinkField-" + platform.rawValue)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(palette.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        } else if links.isEmpty {
            ProfileEmptyActions { Button("Add links", action: addLinks).accessibilityIdentifier("profileAddHandles") }
        } else if style == .icons {
            ProfileTagLayout(spacing: 12) {
                ForEach(links) { link in
                    if let url = link.url {
                        Link(destination: url) {
                            Image(systemName: link.platform.symbol).font(.title3.weight(.semibold)).foregroundStyle(accent)
                                .frame(width: 50, height: 50).background(accent.opacity(0.14), in: Circle())
                        }.accessibilityLabel(link.platform.title).accessibilityIdentifier("profileLink-" + link.platform.rawValue)
                    }
                }
            }
        } else {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(links) { link in
                    if let url = link.url {
                        Link(destination: url) {
                            VStack(alignment: .leading, spacing: 6) {
                                Image(systemName: link.platform.symbol).font(.title3).foregroundStyle(accent)
                                Text(link.platform.title).font(KemoType.font(.subheadline, weight: .semibold)).foregroundStyle(palette.foreground)
                                Text(label(link)).font(KemoType.font(.footnote)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(palette.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }.accessibilityIdentifier("profileLink-" + link.platform.rawValue)
                    }
                }
            }
        }
    }
    private func label(_ link: ProfileLink) -> String {
        switch link.platform {
        case .website, .spotify, .appleMusic: link.url?.host ?? link.value
        default: "@" + link.value.trimmingCharacters(in: CharacterSet(charactersIn: "@ "))
        }
    }
}

// MARK: Watch game

/// The watch pet game's levels: level L starts at 15 × (L − 1)² XP.
enum KemoLevel {
    static func level(xp: Int) -> Int { 1 + Int((Double(max(0, xp)) / 15).squareRoot()) }
    static func xp(toReach level: Int) -> Int { 15 * (level - 1) * (level - 1) }
    /// How far along the current level, from 0 to 1.
    static func progress(xp: Int, level: Int) -> Double {
        let floor = Self.xp(toReach: level), next = Self.xp(toReach: level + 1)
        guard next > floor else { return 0 }
        return min(1, max(0, Double(xp - floor) / Double(next - floor)))
    }
}

struct ProfileKemoBlock: View {
    let summary: WatchLink.PetSummary?
    let theme: BotTheme
    let open: () -> Void
    @Environment(\.profileAccent) private var accent
    var body: some View {
        Button(action: open) {
            HStack(spacing: 14) {
                CompanionAvatar(theme: theme, size: 58)
                if let summary {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Level \(summary.level)").font(KemoType.font(.headline, weight: .bold))
                            Spacer()
                            Text("\u{1F525} \(summary.streak)").font(KemoType.font(.subheadline, weight: .semibold)).monospacedDigit()
                        }
                        ProgressView(value: KemoLevel.progress(xp: summary.xp, level: summary.level)).tint(accent)
                        Text("\(summary.xp) XP · " + (summary.starved == 0 ? "never starved" : summary.starved == 1 ? "starved once" : "starved \(summary.starved) times")).font(KemoType.font(.caption)).foregroundStyle(.secondary).monospacedDigit()
                    }
                } else {
                    Text("No game yet").font(KemoType.font(.subheadline)).foregroundStyle(.secondary)
                    Spacer()
                }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("profileKemoBlock")
    }
}

/// Kemo's pet game from Apple Watch: level, XP, streak, and how many times it went hungry.
struct ProfileKemoCard: View {
    let summary: WatchLink.PetSummary?
    let theme: BotTheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mobilePalette) private var palette
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    CompanionAvatar(theme: theme, size: 96)
                    Text(CompanionIdentity.name).font(KemoType.font(.title2, weight: .semibold)).accessibilityIdentifier("kemoCardName")
                    if let summary { game(summary) } else {
                        Text("No game yet. It starts on Apple Watch.")
                            .font(KemoType.font(.subheadline)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("kemoCardNoWatch")
                    }
                }.padding(20)
            }
            .background(palette.background)
            .navigationTitle(CompanionIdentity.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() }.accessibilityIdentifier("profileSheetClose") } }
        }.presentationDetents([.medium, .large]).presentationBackground(palette.background)
    }
    private func game(_ summary: WatchLink.PetSummary) -> some View {
        let next = KemoLevel.xp(toReach: summary.level + 1)
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Level \(summary.level)").font(KemoType.font(.headline, weight: .semibold))
                    Spacer()
                    Text("\(summary.xp) / \(next) XP").font(KemoType.font(.footnote)).foregroundStyle(.secondary).monospacedDigit()
                }
                ProgressView(value: KemoLevel.progress(xp: summary.xp, level: summary.level)).tint(palette.accent)
                    .accessibilityLabel("Progress to level \(summary.level + 1)")
            }.accessibilityIdentifier("kemoCardLevel")
            HStack(spacing: 10) {
                fact("\u{1F525} \(summary.streak)", summary.streak == 1 ? "day streak" : "days streak").accessibilityIdentifier("kemoCardStreak")
                fact("\(summary.starved)", "Times starved").accessibilityIdentifier("kemoCardStarved")
            }
            Text("From Apple Watch, \(summary.updated.formatted(.relative(presentation: .named))).")
                .font(KemoType.font(.caption)).foregroundStyle(.secondary)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    private func fact(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(KemoType.font(.title3, weight: .semibold)).monospacedDigit()
            Text(label).font(KemoType.font(.caption)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(palette.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .combine)
    }
}

import SwiftUI

/// A companion palette shown the way it looks: Kemo in those colors on its own
/// background, like the interface theme tiles. Used by every palette picker on
/// iPhone and Mac.
struct CompanionPaletteTile: View {
    let theme: BotTheme
    let selected: Bool
    var height: CGFloat = 96
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                LinearGradient(colors: [theme.backgroundColor, theme.backgroundColor.opacity(0.82)], startPoint: .top, endPoint: .bottom)
                ArtworkCompanion(theme: theme, reducedMotion: true, active: false)
                    .frame(width: height * 0.92, height: height * 0.92)
                    .allowsHitTesting(false)
            }
            .frame(height: height).frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? theme.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 2 : 0.5))
            HStack(spacing: 4) {
                Text(theme.name).font(.system(size: 12, weight: selected ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(theme.accentColor) }
            }.foregroundStyle(.primary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(theme.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The palette picker's grid with search, shared by iPhone and Mac.
struct CompanionPaletteGrid: View {
    let themes: [BotTheme]
    let selectedID: String
    var columns = 3
    let choose: (BotTheme) -> Void
    @State private var search = ""
    private var shown: [BotTheme] { themes.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find a palette", text: $search).textFieldStyle(.plain).accessibilityIdentifier("paletteSearch")
            }.padding(10).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), spacing: 14) {
                    ForEach(shown) { theme in
                        Button { choose(theme) } label: { CompanionPaletteTile(theme: theme, selected: theme.id == selectedID) }
                            .buttonStyle(.plain).accessibilityIdentifier("palette-" + theme.id)
                    }
                }.padding(3)
                if shown.isEmpty { Text("No matching palettes").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 32) }
            }
        }
    }
}

/// Kemo in a palette, small and round, for rows and menus.
struct CompanionAvatar: View {
    let theme: BotTheme
    var size: CGFloat = 30
    var body: some View {
        ArtworkCompanion(theme: theme, reducedMotion: true, active: false)
            .frame(width: size, height: size).scaleEffect(1.2)
            .background(theme.backgroundColor, in: Circle()).clipShape(Circle())
            .accessibilityHidden(true)
    }
}

import SwiftUI

/// The Character page's preview, edited the way the watch customizes Kemo like a watch face
/// (the owner's instruction, September 25, 2026): swipe between Color and Tone, each titled at
/// the top, step through the options with the arrows (the watch turns the Digital Crown), and
/// Kemo previews live. A choice applies right away, like the controls below it.
struct CharacterFaceCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.mobilePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(CompanionIdentity.personalityKey, store: AccountDirectory.accountSettings) private var storedPersonality = ""
    @State private var page = Page.color

    enum Page: Int, CaseIterable, Identifiable {
        case color, tone
        var id: Int { rawValue }
        var title: String { self == .color ? "Color" : "Tone" }
    }
    static let tones: [CompanionPersonality?] = [nil] + CompanionPersonality.allCases
    /// The same pose for each tone as on the watch, from the approved performances.
    static func performance(_ tone: CompanionPersonality?) -> String {
        switch tone {
        case .warm: "greeting"
        case .playful: "speaking"
        case .calm: "breathing"
        case .direct: "listening"
        case nil: "idle"
        }
    }

    private var themes: [BotTheme] {
        let custom = ThemeShelf.uniqueCustom(store.state.customThemes ?? [], currentID: store.state.theme.id)
        var all = ThemeShelf.visible + custom
        if !all.contains(where: { $0.id == store.state.theme.id }) { all.append(store.state.theme) }
        return all
    }
    private var tone: CompanionPersonality? { CompanionPersonality(rawValue: storedPersonality) }

    var body: some View {
        TabView(selection: $page) {
            ForEach(Page.allCases) { item in
                face(item).tag(item)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .indexViewStyle(.page(backgroundDisplayMode: .interactive))
        .frame(height: 290)
        .background(store.state.theme.backgroundColor.opacity(0.9), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .sensoryFeedback(.selection, trigger: store.state.theme.id)
        .sensoryFeedback(.selection, trigger: storedPersonality)
        .accessibilityIdentifier("characterFaceCard")
    }

    private func face(_ item: Page) -> some View {
        VStack(spacing: 10) {
            Text(item.title.uppercased())
                .font(.system(size: 13, weight: .semibold, design: .rounded)).tracking(0.6)
                .foregroundStyle(store.state.theme.accentColor)
                .padding(.horizontal, 10).padding(.vertical, 3)
                .overlay(Capsule().strokeBorder(store.state.theme.accentColor, lineWidth: 1.5))
                .padding(.top, 14)
            ArtworkCompanion(theme: store.state.theme, performance: item == .tone ? Self.performance(tone) : "idle",
                             reducedMotion: reduceMotion, active: page == item)
                .frame(height: 170)
                .accessibilityHidden(true)
            HStack(spacing: 18) {
                stepButton("chevron.left", item: item, step: -1)
                Text(optionName(item))
                    .font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.8).frame(minWidth: 110)
                    .accessibilityLabel(item.title + ": " + optionName(item))
                    .accessibilityAdjustableAction { step(item, $0 == .increment ? 1 : -1) }
                    .accessibilityIdentifier("characterFaceOption-" + item.title)
                stepButton("chevron.right", item: item, step: 1)
            }
            Spacer(minLength: 22)
        }
        .frame(maxWidth: .infinity)
    }
    private func stepButton(_ symbol: String, item: Page, step delta: Int) -> some View {
        Button { step(item, delta) } label: {
            Image(systemName: symbol).font(.system(size: 15, weight: .bold)).frame(width: 36, height: 36)
                .background(.white.opacity(0.14), in: Circle()).foregroundStyle(.white)
        }.buttonStyle(.plain)
            .accessibilityLabel((delta < 0 ? "Previous " : "Next ") + item.title.lowercased())
            .accessibilityIdentifier("characterFace-" + item.title + (delta < 0 ? "-previous" : "-next"))
    }
    private func optionName(_ item: Page) -> String {
        item == .color ? store.state.theme.name : (tone?.title ?? "Default")
    }
    /// Steps to the neighboring option; the first and last stay put, as with the watch's crown.
    private func step(_ item: Page, _ delta: Int) {
        switch item {
        case .color:
            let all = themes
            let current = all.firstIndex { $0.id == store.state.theme.id } ?? 0
            let next = min(max(current + delta, 0), all.count - 1)
            guard next != current else { return }
            store.state.theme = all[next]; store.save()
        case .tone:
            let current = Self.tones.firstIndex(of: tone) ?? 0
            let next = min(max(current + delta, 0), Self.tones.count - 1)
            guard next != current else { return }
            CompanionIdentity.setPersonality(Self.tones[next])
        }
    }
}

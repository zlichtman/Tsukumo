import SwiftUI

/// Make a character in three steps: name, look, personality. Opens on first
/// launch to name the companion, and from Character settings to make more.
struct CharacterMaker: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mobilePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var firstRun = false
    var editing: CompanionCharacter?
    @State private var step = 0
    @State private var name = ""
    @State private var theme = BotTheme.presets[0]
    @State private var personality: CompanionPersonality?
    @FocusState private var nameFocused: Bool
    private let columns = [GridItem(.adaptive(minimum: 92), spacing: 10)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                ArtworkCompanion(theme: theme, performance: step == 0 ? "greeting" : step == 2 ? "speaking" : "idle",
                                 reducedMotion: reduceMotion, replay: step)
                    .frame(height: 170)
                    .accessibilityLabel("Preview of \(CompanionIdentity.clean(name))")
                Text(title).font(KemoType.font(.title2, weight: .semibold)).multilineTextAlignment(.center)
                Text(subtitle).font(KemoType.font(.callout)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Group {
                    switch step {
                    case 0: nameStep
                    case 1: lookStep
                    default: personalityStep
                    }
                }.frame(maxHeight: .infinity, alignment: .top)
                ProgressDots(step: step, accent: palette.accent)
            }
            .padding(20)
            .background(palette.background.ignoresSafeArea())
            // In the toolbar so the keyboard never covers them.
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if step > 0 {
                        Button("Back") { withAnimation { step -= 1 } }.accessibilityIdentifier("makerBack")
                    } else {
                        Button(firstRun ? "Skip" : "Cancel") {
                            if firstRun { CompanionIdentity.set(CompanionIdentity.defaultName) }
                            dismiss()
                        }.accessibilityIdentifier("makerSkip")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(step < 2 ? "Next" : "Done") { step < 2 ? withAnimation { step += 1 } : finish() }
                        .fontWeight(.semibold).tint(palette.accent)
                        .accessibilityIdentifier(step < 2 ? "makerNext" : "makerDone")
                }
            }
            .onAppear(perform: start)
        }
        .interactiveDismissDisabled(firstRun)
    }

    private var title: String {
        switch step {
        case 0: firstRun ? "Hi! What should I be called?" : "Name your character"
        case 1: "Pick a look"
        default: "How should \(CompanionIdentity.clean(name)) talk?"
        }
    }
    private var subtitle: String {
        switch step {
        case 0: "You can change it any time in Settings → Companion."
        case 1: "Colors for your companion only. The app keeps its own theme."
        default: "Personality changes the tone of replies, never what it can do or see."
        }
    }
    private var nameStep: some View {
        VStack(spacing: 14) {
            TextField(CompanionIdentity.defaultName, text: $name)
                .font(KemoType.font(.title3, weight: .semibold)).multilineTextAlignment(.center)
                .textInputAutocapitalization(.words).autocorrectionDisabled().submitLabel(.next)
                .focused($nameFocused).onSubmit { withAnimation { step = 1 } }
                .padding(.vertical, 12).padding(.horizontal, 16)
                .background(Color.primary.opacity(0.06), in: Capsule())
                .onChange(of: name) { if name.count > CompanionIdentity.maxLength { name = String(name.prefix(CompanionIdentity.maxLength)) } }
                .accessibilityIdentifier("companionNameField")
            FlowChips(items: CompanionIdentity.suggestions, selected: name) { name = $0 }
        }
    }
    private var lookStep: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(ThemeShelf.visible) { option in
                    Button { theme = option } label: {
                        VStack(spacing: 6) {
                            HStack(spacing: -6) {
                                Circle().fill(option.bodyColor).frame(width: 26, height: 26)
                                Circle().fill(Color(hex: option.accent)).frame(width: 26, height: 26)
                            }
                            Text(option.name).font(KemoType.font(.caption, weight: .medium)).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Color(hex: option.background), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(theme.id == option.id ? palette.accent : .clear, lineWidth: 2))
                        .foregroundStyle(.white)
                    }.buttonStyle(.plain).accessibilityIdentifier("makerTheme-" + option.id)
                        .accessibilityValue(theme.id == option.id ? "Selected" : "")
                }
            }
        }
    }
    private var personalityStep: some View {
        VStack(spacing: 8) {
            ForEach(CompanionPersonality.allCases) { option in
                Button { personality = personality == option ? nil : option } label: {
                    HStack(spacing: 12) {
                        Image(systemName: option.symbol).frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.title).font(KemoType.font(.body, weight: .semibold))
                            Text(option.detail).font(KemoType.font(.footnote)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if personality == option { Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.accent) }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }.buttonStyle(.plain).accessibilityIdentifier("makerPersonality-" + option.rawValue)
            }
        }
    }
    private func start() {
        if let editing {
            name = editing.name; theme = editing.theme; personality = editing.personality
        } else if firstRun {
            name = ""; theme = store.state.theme; personality = CompanionIdentity.personality
            nameFocused = true
        } else {
            name = ""; theme = store.state.theme; personality = nil
            nameFocused = true
        }
    }
    private func finish() {
        let chosen = CompanionIdentity.clean(name)
        let character = CompanionCharacter(id: editing?.id ?? UUID(), name: chosen, theme: theme, personality: personality)
        CompanionCharacters.save(CompanionCharacters.upsert(character, into: CompanionCharacters.load()))
        CompanionCharacterSwitch.apply(character, store: store)
        dismiss()
    }
}

private struct ProgressDots: View {
    let step: Int
    let accent: Color
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { Capsule().fill($0 == step ? accent : Color.primary.opacity(0.15)).frame(width: $0 == step ? 18 : 6, height: 6) }
        }.animation(.smooth, value: step).accessibilityHidden(true)
    }
}

/// Wrapping suggestion chips.
private struct FlowChips: View {
    let items: [String]
    let selected: String
    let choose: (String) -> Void
    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(items, id: \.self) { item in
                Button(item) { choose(item) }
                    .font(KemoType.font(.footnote, weight: .medium))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Color.primary.opacity(item == selected ? 0.16 : 0.06), in: Capsule())
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("nameSuggestion-" + item)
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(bounds.width, subviews)
        for (index, point) in rows.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x + rows.offsets[index], y: bounds.minY + point.y), proposal: .unspecified)
        }
    }
    /// Rows are centered.
    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (points: [CGPoint], offsets: [CGFloat], width: CGFloat, height: CGFloat) {
        var points: [CGPoint] = []; var rowOf: [Int] = []; var rowWidths: [CGFloat] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { rowWidths.append(x - spacing); x = 0; y += rowHeight + spacing; rowHeight = 0 }
            points.append(CGPoint(x: x, y: y)); rowOf.append(rowWidths.count)
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        rowWidths.append(max(0, x - spacing))
        let offsets = rowOf.map { width.isFinite ? max(0, (width - rowWidths[$0]) / 2) : 0 }
        return (points, offsets, rowWidths.max() ?? 0, y + rowHeight)
    }
}

import SwiftUI
import WatchKit

/// Customize Kemo the way you customize a watch face (the owner's instruction, September 25, 2026).
/// Long-press Kemo, or choose Customize in Settings: Kemo shrinks a little in the center, each page
/// is titled at the top (Color, Tone), swipe between pages, turn the Digital Crown to cycle the
/// options while Kemo previews them live, and tap to finish. Only the approved frames are used.
/// Changes go to the iPhone as `WatchLink.Setting.palette` and `.personality`.
struct WatchCharacterEditor: View {
    let connection: WatchConnection
    /// Called after finishing; nil when pushed from Settings, which pops back.
    var done: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Page: Int, CaseIterable {
        case color, tone
        var title: String { self == .color ? "Color" : "Tone" }
    }
    static let tones: [String?] = [nil, "warm", "playful", "calm", "direct"]

    @State private var page = Page.color
    @State private var paletteIndex = 0
    @State private var toneIndex = 0
    @State private var crown = 0.0
    @State private var shown = false
    @FocusState private var focused: Bool

    private var palettes: [WatchLink.Palette] { connection.status.palettes ?? [] }
    private var style: WatchStyle { WatchStyle(connection.status.theme) }
    private var previewPalette: WatchLink.Palette? { palettes.indices.contains(paletteIndex) ? palettes[paletteIndex] : connection.status.palette }
    private var count: Int { page == .color ? max(palettes.count, 1) : Self.tones.count }
    private var index: Int { page == .color ? paletteIndex : toneIndex }
    private var optionName: String {
        page == .color ? (previewPalette?.name ?? "KemoSabe") : (Self.tones[toneIndex]?.capitalized ?? "Default")
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 4) {
                Text(page.title.uppercased())
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(style.readableAccent)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .overlay(Capsule().strokeBorder(style.readableAccent, lineWidth: 1.5))
                    .accessibilityIdentifier("watchEditorPage")
                Spacer(minLength: 0)
                // Kemo shrinks slightly, as a watch face does when you edit it.
                KemoFigure(mood: previewMood, pet: previewPet, palette: previewPalette)
                    .scaleEffect(shown ? 1.05 : 1.2)
                    .frame(width: min(geometry.size.width, geometry.size.height) * 0.62,
                           height: min(geometry.size.width, geometry.size.height) * 0.62)
                    .accessibilityHidden(true)
                Text(optionName)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .accessibilityIdentifier("watchEditorOption")
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    ForEach(Page.allCases, id: \.self) { item in
                        Circle().fill(item == page ? Color.white : Color.white.opacity(0.3)).frame(width: 6, height: 6)
                    }
                }.accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .focusable()
        .focused($focused)
        .digitalCrownRotation($crown, from: 0, through: Double(max(count - 1, 1)), by: 1,
                              sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true)
        .onChange(of: crown) { choose(Int(crown.rounded())) }
        .gesture(DragGesture(minimumDistance: 16).onEnded { value in
            guard abs(value.translation.width) > abs(value.translation.height) else { return }
            turn(value.translation.width < 0 ? 1 : -1)
        })
        .onTapGesture(perform: finish)
        // VoiceOver: swipe up or down to change the option, double tap to finish.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(page.title)
        .accessibilityValue(optionName)
        .accessibilityHint("Turn the Digital Crown to change. Tap to finish.")
        .accessibilityAdjustableAction { direction in
            choose(index + (direction == .increment ? 1 : -1))
        }
        .accessibilityAction(named: "Next page") { turn(1) }
        .accessibilityAction(named: "Previous page") { turn(-1) }
        .accessibilityAction(.default, finish)
        .accessibilityIdentifier("watchEditor")
        .containerBackground(style.background.gradient, for: .navigation)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            paletteIndex = palettes.firstIndex { $0.id != nil && $0.id == connection.status.palette?.id } ?? 0
            toneIndex = Self.tones.firstIndex(of: connection.status.personality) ?? 0
            crown = Double(index); focused = true
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) { shown = true }
        }
    }

    /// Each tone shows Kemo in a matching pose from the approved frames.
    private var previewMood: KemoFigure.Mood {
        guard page == .tone else { return .idle }
        switch Self.tones[toneIndex] {
        case "warm": return .greeting
        case "playful": return .speaking
        case "direct": return .listening
        default: return .idle
        }
    }
    private var previewPet: KemoVitals.Mood { page == .tone && Self.tones[toneIndex] == "calm" ? .sleepy : .content }

    private func choose(_ value: Int) {
        let next = min(max(value, 0), count - 1)
        guard next != index else { return }
        if page == .color { paletteIndex = next } else { toneIndex = next }
        if Int(crown.rounded()) != next { crown = Double(next) }
    }
    private func turn(_ step: Int) {
        guard let next = Page(rawValue: page.rawValue + step) else { return }
        withAnimation(.smooth(duration: 0.2)) { page = next }
        crown = Double(index)
        WKInterfaceDevice.current().play(.click)
    }
    /// Sends only what changed, then leaves edit mode.
    private func finish() {
        if let palette = previewPalette, let id = palette.id, id != connection.status.palette?.id { connection.change(.palette(id)) }
        let tone = Self.tones[toneIndex]
        if tone != connection.status.personality { connection.change(.personality(tone)) }
        WKInterfaceDevice.current().play(.success)
        if let done { done() } else { dismiss() }
    }
}

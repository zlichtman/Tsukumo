import SwiftUI
import AppKit

// MARK: The effort scale

/// The reasoning efforts an agent reports for a model, laid out as slider stops: the model's own
/// default at the left, then each effort from lightest to heaviest. Only what the agent lists is
/// a stop, so a model with two efforts has three stops and one with none has only the default.
struct CodingEffortScale: Equatable {
    /// nil is the model's default.
    let stops: [String?]
    /// The effort the model uses when none is chosen, when the agent says (Codex does).
    let defaultEffort: String?
    init(efforts: [String], defaultEffort: String? = nil) {
        var seen = Set<String>()
        let unique = efforts.filter { !$0.isEmpty && seen.insert($0).inserted }
        let ordered = unique.enumerated().sorted {
            let (a, b) = (CodingAgentCatalog.effortOrder($0.element), CodingAgentCatalog.effortOrder($1.element))
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
        stops = [nil] + ordered
        self.defaultEffort = defaultEffort
    }
    var count: Int { stops.count }
    /// False when the model lists no efforts: the default is the only choice.
    var hasEfforts: Bool { stops.count > 1 }
    func effort(at step: Int) -> String? { stops[min(max(step, 0), stops.count - 1)] }
    /// The stop for an effort. One this model doesn't list (chosen for another model) sits at the
    /// nearest listed weight; an unknown name sits at the default.
    func step(for effort: String?) -> Int {
        guard let effort else { return 0 }
        if let index = stops.firstIndex(of: effort) { return index }
        let rank = CodingAgentCatalog.effortOrder(effort)
        guard hasEfforts, rank < CodingAgentCatalog.unknownEffortRank else { return 0 }
        var best = 1
        for index in 1..<stops.count {
            let distance = abs(CodingAgentCatalog.effortOrder(stops[index] ?? "") - rank)
            if distance < abs(CodingAgentCatalog.effortOrder(stops[best] ?? "") - rank) { best = index }
        }
        return best
    }
    /// 0…1, how hard the model is asked to think at a stop. It follows the effort's own weight, so
    /// Max is hot whatever else a model lists; the default takes its effort's weight when known.
    func heat(at step: Int) -> Double {
        guard let effort = effort(at: step) ?? defaultEffort else { return 0.3 }
        return Self.heat(effort)
    }
    static func heat(_ effort: String) -> Double { EffortWeight.heat(effort) }
    /// What a person reads for an effort; the agent's own name stays what's sent.
    static func title(_ effort: String?) -> String { EffortWeight.title(effort) }
    /// An effort carried to another model: kept when that model lists it, otherwise the default.
    static func carry(_ effort: String?, to efforts: [String]) -> String? {
        guard let effort, efforts.contains(effort) else { return nil }
        return effort
    }
}

// MARK: Heat colors, sparkles, and the slider

// Shared with KemoSabe's chat model chip (PowerControls.swift); the coding names stay.
typealias CodingEffortHeat = EffortHeat
typealias CodingSparkleField = SparkleField

/// The power slider over a coding agent's effort scale.
struct CodingPowerSlider: View {
    let scale: CodingEffortScale
    @Binding var step: Int
    let accent: Color
    var animate = true
    var onStep: (Int) -> Void = { _ in }
    var body: some View {
        PowerSlider(count: scale.count, step: $step, heat: scale.heat(at: step), accent: accent,
                    valueTitle: CodingEffortScale.title(scale.effort(at: step)), animate: animate, onStep: onStep)
    }
}

// MARK: The effort popover

/// Opened from the composer's model chip: the effort name large, the model beneath it (which
/// opens the model list), and the power slider. Changes are kept while it's open and applied
/// once when it closes, so a drag through five efforts is one change; Esc puts everything back.
/// Arrow keys step, Return closes.
struct CodingEffortPopover: View {
    enum Page { case effort, models }
    let provider: CodingProvider
    let models: [CodingAgentModel]
    var loading = false
    var problem: String?
    /// The task is mid-turn: a change applies from the next message after this turn.
    var running = false
    let accent: Color
    let initialModel: String
    let initialEffort: String?
    var animate = true
    var refresh: () -> Void = {}
    var commit: (_ model: String, _ effort: String?) -> Void
    var close: () -> Void
    @State private var model: String
    @State private var effort: String?
    @State private var page: Page
    @State private var highlighted = 0
    @State private var cancelled = false
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init(provider: CodingProvider, models: [CodingAgentModel], loading: Bool = false, problem: String? = nil, running: Bool = false, accent: Color,
         model: String, effort: String?, page: Page = .effort, animate: Bool = true,
         refresh: @escaping () -> Void = {}, commit: @escaping (_ model: String, _ effort: String?) -> Void, close: @escaping () -> Void) {
        self.provider = provider; self.models = models; self.loading = loading; self.problem = problem; self.running = running; self.accent = accent
        initialModel = model; initialEffort = effort; self.animate = animate
        self.refresh = refresh; self.commit = commit; self.close = close
        _model = State(initialValue: model); _effort = State(initialValue: effort); _page = State(initialValue: page)
    }
    private var scale: CodingEffortScale {
        .init(efforts: CodingAgentCatalog.efforts(in: models, model: model), defaultEffort: CodingAgentCatalog.defaultEffort(in: models, model: model))
    }
    private var step: Binding<Int> {
        Binding(get: { scale.step(for: effort) }, set: { effort = scale.effort(at: $0) })
    }
    private var modelName: String {
        models.first(where: { $0.id == model })?.name ?? (model.isEmpty ? "Default model" : model)
    }
    private var changed: Bool { model != initialModel || effort != initialEffort }
    private var heatColor: Color { CodingEffortHeat.title(accent: accent, heat: scale.heat(at: scale.step(for: effort)), dark: scheme == .dark) }
    var body: some View {
        Group {
            switch page {
            case .effort: effortPage
            case .models: modelPage
            }
        }
        .padding(14)
        .frame(width: 320)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .return, .escape]) { press in key(press.key) }
        .onDisappear { if !cancelled && changed { commit(model, effort) } }
    }
    private func key(_ key: KeyEquivalent) -> KeyPress.Result {
        switch (page, key) {
        case (.effort, .leftArrow), (.effort, .downArrow): move(-1)
        case (.effort, .rightArrow), (.effort, .upArrow): move(1)
        case (.effort, .return): close()
        case (.effort, .escape): cancelled = true; close()
        case (.models, .upArrow): highlighted = max(0, highlighted - 1)
        case (.models, .downArrow): highlighted = min(models.count, highlighted + 1)
        case (.models, .return): choose(highlighted == 0 ? "" : models[highlighted - 1].id)
        case (.models, .escape), (.models, .leftArrow): page = .effort
        default: return .ignored
        }
        return .handled
    }
    private func move(_ delta: Int) {
        let next = min(max(scale.step(for: effort) + delta, 0), scale.count - 1)
        guard next != scale.step(for: effort) else { return }
        effort = scale.effort(at: next); tick()
    }
    private func tick() { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    private func choose(_ id: String) {
        let efforts = CodingAgentCatalog.efforts(in: models, model: id)
        effort = CodingEffortScale.carry(effort, to: efforts)
        model = id
        page = .effort
    }
    // MARK: Effort
    private var effortPage: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "bolt.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(heatColor)
                    .frame(width: 28, height: 28).background(heatColor.opacity(0.14), in: Circle())
                    .accessibilityHidden(true)
                Spacer()
                Button { if effort != nil { effort = nil; tick() } } label: {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28)
                        .foregroundStyle(Color.primary.opacity(effort == nil ? 0.3 : 0.75))
                        .background(Color.primary.opacity(effort == nil ? 0.03 : 0.07), in: Circle())
                }.buttonStyle(.plain).disabled(effort == nil)
                    .help("Back to the model's default").accessibilityLabel("Use the model's default effort")
            }
            Text(CodingEffortScale.title(effort))
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(heatColor)
                .contentTransition(.interpolate)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: effort)
                .lineLimit(1).minimumScaleFactor(0.7)
                .padding(.top, -6)
                .accessibilityAddTraits(.isHeader)
            Button { highlighted = models.firstIndex(where: { $0.id == model }).map { $0 + 1 } ?? 0; page = .models } label: {
                HStack(spacing: 3) {
                    Text(modelName).lineLimit(1)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                }
                .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
            }.buttonStyle(DesktopRowButtonStyle()).help("Choose the model").accessibilityLabel("Model, " + modelName)
            if scale.hasEfforts {
                CodingPowerSlider(scale: scale, step: step, accent: accent, animate: animate) { _ in tick() }
                    .padding(.top, 14)
            } else {
                Text(loading ? "Asking \(provider.title) for effort levels…" : "\(modelName) has no effort levels to choose.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 14)
            }
            if running && changed {
                Text("Applies from the next message after this turn.").font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 10)
            }
        }
    }
    // MARK: Models
    private var modelPage: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button { page = .effort } label: {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24)
                }.buttonStyle(DesktopRowButtonStyle()).accessibilityLabel("Back to effort")
                Text("Model").font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            // A short list sits as it is; a long one scrolls.
            if models.count > 7 {
                ScrollView { modelRows }.frame(height: 300)
            } else {
                modelRows
            }
            Divider().padding(.vertical, 2)
            Button { refresh() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                    Text(loading ? "Asking \(provider.title)…" : "Refresh from \(provider.title)")
                    Spacer()
                }.font(.system(size: 12)).padding(.horizontal, 8).padding(.vertical, 5).contentShape(Rectangle())
            }.buttonStyle(DesktopRowButtonStyle()).disabled(loading)
            if let problem { Text(problem).font(.system(size: 11)).foregroundStyle(.orange).padding(.horizontal, 8) }
        }
    }
    private var modelRows: some View {
        VStack(alignment: .leading, spacing: 2) {
            modelRow(0, name: "Default model", detail: "", id: "")
            ForEach(Array(models.enumerated()), id: \.element.id) { index, entry in
                modelRow(index + 1, name: entry.name, detail: entry.detail, id: entry.id)
            }
        }
    }
    private func modelRow(_ index: Int, name: String, detail: String, id: String) -> some View {
        Button { choose(id) } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 13))
                    if !detail.isEmpty { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 4)
                if model == id { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(accent) }
            }.padding(.horizontal, 8).padding(.vertical, 5).contentShape(Rectangle())
        }
        .buttonStyle(DesktopRowButtonStyle(selected: highlighted == index))
        .accessibilityAddTraits(model == id ? .isSelected : [])
    }
}

// MARK: Selector bars

struct CodingSelectorOption<Value: Hashable>: Identifiable {
    var value: Value
    var title: String
    var symbol: String
    var help = ""
    /// Tinted orange when chosen (Full access).
    var warning = false
    var id: Value { value }
}

/// A row of a few fixed choices with one highlight that slides to the chosen one.
struct CodingSelectorBar<Value: Hashable>: View {
    let options: [CodingSelectorOption<Value>]
    let selection: Value
    let accent: Color
    /// Inline in the composer: sized to its labels at the chips' 30 pt height.
    var compact = false
    var hover: (Value?) -> Void = { _ in }
    var choose: (Value) -> Void
    @Namespace private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in segment(option) }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.82), value: selection)
    }
    private func segment(_ option: CodingSelectorOption<Value>) -> some View {
        let selected = option.value == selection
        let tint = option.warning ? Color.orange : accent
        return Button { choose(option.value) } label: {
            HStack(spacing: 5) {
                Image(systemName: option.symbol).font(.system(size: 10, weight: .semibold))
                Text(option.title).lineLimit(1)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(selected ? tint : Color.primary.opacity(0.68))
            .padding(.horizontal, compact ? 9 : 10)
            .frame(maxWidth: compact ? nil : .infinity)
            .frame(height: compact ? 26 : 30)
            .background {
                if selected {
                    Capsule().fill(scheme == .dark ? tint.opacity(0.22) : Color.white)
                        .overlay(Capsule().stroke(tint.opacity(scheme == .dark ? 0.35 : 0.25), lineWidth: 0.5))
                        .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.08), radius: 2, y: 1)
                        .matchedGeometryEffect(id: "highlight", in: highlight)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover($0 ? option.value : nil) }
        .help(option.help)
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: Access

/// The access chip's popover: the four modes as a selector bar and what the chosen (or hovered)
/// one does. Full access is never one click: choosing it shows the warning and its own Allow
/// full access button, which has no keyboard default. Return or Esc closes.
struct CodingAccessPopover: View {
    let provider: CodingProvider
    let current: CodingAccess
    let accent: Color
    var apply: (CodingAccess) -> Void
    var close: () -> Void
    @State private var confirmingFull = false
    @State private var hovered: CodingAccess?
    @FocusState private var focused: Bool
    init(provider: CodingProvider, current: CodingAccess, accent: Color, confirmingFull: Bool = false, apply: @escaping (CodingAccess) -> Void, close: @escaping () -> Void) {
        self.provider = provider; self.current = current; self.accent = accent; self.apply = apply; self.close = close
        _confirmingFull = State(initialValue: confirmingFull)
    }
    static func warning(_ provider: CodingProvider) -> String {
        "With full access, \(provider.title) runs any command with your Mac account's access, without asking, and can change files outside this task's folder, use the network, and read your other projects. Use it only in a worktree you can throw away."
    }
    private var shown: CodingAccess { confirmingFull ? .full : current }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Access").font(.system(size: 13, weight: .semibold))
            // Only the modes up to this agent's own grant (Settings → Agents).
            CodingSelectorBar(options: CodingAccess.allCases.filter { $0 <= CodingAgentRegistry.shared.grant(for: provider) }.map { .init(value: $0, title: $0.title, symbol: $0.symbol, help: $0.detail, warning: $0 == .full) },
                              selection: shown, accent: accent, hover: { hovered = $0 }) { choice in
                if choice == .full && current != .full { confirmingFull = true } else { confirmingFull = false; apply(choice) }
            }
            if confirmingFull {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Give \(provider.title) full access?", systemImage: "exclamationmark.shield").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.orange)
                    Text(Self.warning(provider)).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Spacer()
                        Button("Cancel") { confirmingFull = false }.buttonStyle(DesktopRowButtonStyle(inset: 6))
                        Button { apply(.full); confirmingFull = false; close() } label: {
                            Text("Allow full access").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 12).frame(height: 28).background(Color.orange, in: Capsule())
                        }.buttonStyle(PressableButtonStyle())
                    }
                }
                .padding(12)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.orange.opacity(0.3), lineWidth: 0.5))
            } else {
                Text((hovered ?? current).detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .frame(width: 440)
        .focusable().focused($focused).focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(keys: [.return, .escape]) { press in
            if press.key == .escape && confirmingFull { confirmingFull = false } else { close() }
            return .handled
        }
    }
}

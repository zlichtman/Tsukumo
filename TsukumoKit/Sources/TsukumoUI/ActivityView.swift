import SwiftUI
import TsukumoCore

/// Activity: one feed of what happened. KemoSabe's answers and refusals, System One's decisions, and
/// bots' work, newest first, grouped by day.
public struct ActivityFeed: View {
    public enum Filter: String, CaseIterable, Identifiable, Sendable {
        case all, kemoSabe, systemOne, bots
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .all: "All"
            case .kemoSabe: "KemoSabe"
            case .systemOne: "System One"
            case .bots: "Bots"
            }
        }
        func includes(_ kind: ActivityItem.Kind) -> Bool {
            switch self {
            case .all: true
            case .kemoSabe: kind == .kemoSabeAnswer || kind == .kemoSabeRefusal
            case .systemOne: kind == .systemOne
            case .bots: kind == .botWork
            }
        }
    }

    let items: [ActivityItem]
    let bots: [BotSpec]
    var onOpen: ((ActivityItem) -> Void)?
    @State private var filter: Filter = .all
    let now: Date

    public init(items: [ActivityItem], bots: [BotSpec], now: Date = Date(), onOpen: ((ActivityItem) -> Void)? = nil) {
        self.items = items; self.bots = bots; self.now = now; self.onOpen = onOpen
    }

    private var shown: [ActivityItem] { items.filter { filter.includes($0.kind) }.sorted { $0.date > $1.date } }
    private var days: [(Date, [ActivityItem])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: shown) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    public var body: some View {
        List {
            Section {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                .accessibilityIdentifier("activityFilter")
            }
            if shown.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "list.bullet.rectangle").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Nothing yet").font(.headline)
                        Text("When a bot asks KemoSabe something, System One picks a bot, or a bot finishes work, it shows here.")
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 24)
                    .listRowBackground(Color.clear)
                }
            }
            ForEach(days, id: \.0) { day, entries in
                Section(dayTitle(day)) {
                    ForEach(entries) { item in
                        Button { onOpen?(item) } label: { ActivityRow(item: item, bot: bots.first { $0.id == item.botID }) }
                            .buttonStyle(.plain)
                            .disabled(onOpen == nil || item.threadID == nil)
                    }
                }
            }
        }
        .accessibilityIdentifier("activityList")
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month().day())
    }
}

/// One thing that happened.
public struct ActivityRow: View {
    let item: ActivityItem
    let bot: BotSpec?
    @Environment(\.colorScheme) private var scheme
    public init(item: ActivityItem, bot: BotSpec?) { self.item = item; self.bot = bot }

    public var body: some View {
        let theme = TsukumoTheme(scheme)
        HStack(alignment: .top, spacing: 12) {
            icon(theme)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.title).font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Text(item.date.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
                Text(kindLabel).font(.caption.weight(.medium)).foregroundStyle(kindColor(theme))
                Text(item.detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("activity-" + item.kind.rawValue)
    }

    private var kindLabel: String {
        switch item.kind {
        case .kemoSabeAnswer: "KemoSabe answered"
        case .kemoSabeRefusal: "KemoSabe held back"
        case .systemOne: "System One"
        case .botWork: bot.map { "\($0.name)’s work" } ?? "A bot’s work"
        }
    }
    private func kindColor(_ theme: TsukumoTheme) -> Color {
        switch item.kind {
        case .kemoSabeAnswer, .kemoSabeRefusal: theme.accent
        case .systemOne: Color.purple
        case .botWork: .secondary
        }
    }

    @ViewBuilder private func icon(_ theme: TsukumoTheme) -> some View {
        switch item.kind {
        case .kemoSabeAnswer, .kemoSabeRefusal:
            BotAvatar(bot: .kemoSabe(), size: 32, locked: item.kind == .kemoSabeAnswer)
                .overlay(alignment: .topTrailing) {
                    if item.kind == .kemoSabeRefusal {
                        Image(systemName: "hand.raised.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 16, height: 16).background(theme.accent, in: Circle()).offset(x: 4, y: -4)
                    }
                }
        case .systemOne:
            Image(systemName: "arrow.triangle.branch").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 32, height: 32).background(Color.purple.gradient, in: Circle())
        case .botWork:
            if let bot { BotAvatar(bot: bot, size: 32) } else {
                Image(systemName: "sparkles").frame(width: 32, height: 32).background(theme.fill, in: Circle())
            }
        }
    }
}

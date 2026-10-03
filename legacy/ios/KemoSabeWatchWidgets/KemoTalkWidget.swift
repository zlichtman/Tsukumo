import SwiftUI
import WidgetKit

/// A watch face complication and Smart Stack widget that opens KemoSabe to talk.
/// Kemo lives on the watch face: it shows how Kemo feels as a pet (hungry, lonely,
/// asleep, happy) from the meters the watch app shares (`KemoVitalsMirror`).
/// It shows no conversation content.
@main struct KemoWatchWidgets: WidgetBundle {
    var body: some Widget {
        KemoTalkWidget()
        KemoTalkControl()
    }
}

/// "Talk to Kemo" in the watch's Control Center and Smart Stack (watchOS 26 controls), and on
/// the Action button of Apple Watch Ultra: one tap opens Kemo already listening, like the complication.
struct KemoTalkControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.zlichtman.kemosabe.watch.talk") {
            ControlWidgetButton(action: TalkFromControlIntent()) {
                Label("Talk to KemoSabe", systemImage: "mic.fill")
            }
        }
        .displayName("Talk to KemoSabe")
        .description("Opens KemoSabe listening.")
    }
}

struct KemoTalkWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "KemoTalk", provider: KemoTalkProvider()) { entry in
            KemoTalkView(entry: entry)
                .containerBackground(Color(red: 0x21 / 255, green: 0x1B / 255, blue: 0x2C / 255).gradient, for: .widget)
                // A tap opens Kemo already listening.
                .widgetURL(URL(string: "kemosabe://talk"))
        }
        .configurationDisplayName("KemoSabe")
        .description("See how KemoSabe is doing, and talk with one tap.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

struct KemoTalkEntry: TimelineEntry {
    let date: Date
    /// Nil until the watch app has run once and shared Kemo's meters.
    var mood: KemoVitals.Mood?
    var name = "KemoSabe"
}

struct KemoTalkProvider: TimelineProvider {
    func placeholder(in context: Context) -> KemoTalkEntry { KemoTalkEntry(date: .now, mood: .happy) }
    func getSnapshot(in context: Context, completion: @escaping (KemoTalkEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : entries(from: .now, count: 1)[0])
    }
    /// The meters decay on a known schedule, so the next day is planned now, every 30 minutes.
    /// The watch app reloads the timeline whenever talking feeds Kemo.
    func getTimeline(in context: Context, completion: @escaping (Timeline<KemoTalkEntry>) -> Void) {
        completion(Timeline(entries: entries(from: .now, count: 48), policy: .atEnd))
    }
    private func entries(from start: Date, count: Int) -> [KemoTalkEntry] {
        let snapshot = KemoVitalsMirror.read()
        return (0..<count).map { index in
            let date = start.addingTimeInterval(Double(index) * 30 * 60)
            return KemoTalkEntry(date: date, mood: snapshot?.vitals.mood(at: date), name: snapshot?.name ?? "KemoSabe")
        }
    }
}

struct KemoTalkView: View {
    var entry: KemoTalkEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryRectangular:
            HStack(spacing: 6) {
                kemo.frame(width: 46)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.mood == nil ? "KemoSabe" : entry.name).font(.headline).widgetAccentable()
                    Text(line).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        case .accessoryInline:
            if let mood = entry.mood {
                Label("\(entry.name) · \(mood.word)", systemImage: mood.symbol ?? "bubble.left.fill")
            } else {
                Label("Talk to \(entry.name)", systemImage: "bubble.left.fill")
            }
        case .accessoryCorner:
            kemo.widgetLabel(entry.mood.map { $0 == .content ? "Talk to \(entry.name)" : $0.word } ?? "Talk to \(entry.name)")
        default:
            ZStack {
                AccessoryWidgetBackground()
                kemo.padding(3)
                // A small sign for a mood that asks for something; no rings.
                if let mood = entry.mood, [.hungry, .lonely, .sleepy].contains(mood), let symbol = mood.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 9, weight: .bold))
                        .widgetAccentable()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(4)
                        .accessibilityHidden(true)
                }
            }
        }
    }
    private var line: String {
        switch entry.mood {
        case nil, .content: "Tap to talk"
        case .happy: "Happy · tap to talk"
        case .hungry: "Hungry · say hi"
        case .lonely: "Misses you · say hi"
        case .sleepy: "Asleep"
        }
    }
    /// Kemo in the approved frame that fits the mood.
    private var frame: String {
        switch entry.mood {
        case .happy: "kemo-greeting"
        case .hungry: "kemo-thinking"
        case .lonely: "kemo-listening"
        case .sleepy: "kemo-blink"
        case nil, .content: "kemo-idle"
        }
    }
    private var kemo: some View {
        Image(frame)
            .resizable()
            .widgetAccentedRenderingMode(.fullColor)
            .scaledToFit()
            .accessibilityLabel(entry.mood.map { "\(entry.name), \($0.word)" } ?? entry.name)
    }
}

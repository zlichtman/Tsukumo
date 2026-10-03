import Foundation
import Observation
import UserNotifications
import WidgetKit

/// Kemo's pet state on this watch: fed by talking, shown by Kemo's face, the complication,
/// and (only after the person turns them on) a couple of gentle nudges a day.
/// Stored in the watch's own UserDefaults; nothing leaves the watch.
@MainActor @Observable final class KemoPet {
    static let nudgesKey = "kemoNudges"
    private static let vitalsKey = "kemoVitals"
    private static let historyKey = "kemoNudgeHistory"
    private static let nameKey = "kemoPetName"
    static let widgetKind = "KemoTalk"

    private(set) var vitals: KemoVitals
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var name: String

    init(defaults: UserDefaults = .standard, now: Date = .now) {
        self.defaults = defaults
        name = defaults.string(forKey: Self.nameKey) ?? "KemoSabe"
        vitals = defaults.data(forKey: Self.vitalsKey).flatMap { try? JSONDecoder().decode(KemoVitals.self, from: $0) } ?? .newborn(at: now)
        #if DEBUG
        // Simulator checks of each look: --pet=hungry, lonely, happy, or sleepy is applied on the next launch.
        if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--pet=") }) {
            let meters: (Double, Double) = switch argument.dropFirst("--pet=".count) {
            case "hungry": (0.1, 0.8)
            case "lonely": (0.8, 0.1)
            case "happy": (1, 1)
            default: (0.5, 0.5)
            }
            vitals = KemoVitals(fullness: meters.0, cheer: meters.1, updated: Self.clock(now), lastFed: nil)
        }
        #endif
        save()
    }

    func mood(at now: Date = .now) -> KemoVitals.Mood { vitals.mood(at: Self.clock(now)) }
    func current(at now: Date = .now) -> KemoVitals { vitals.at(Self.clock(now)) }

    #if DEBUG
    /// Simulator checks of daytime and night looks: --pet-hour=14 shows Kemo as it would be at 14:00 today.
    private static let hourOffset: TimeInterval = {
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--pet-hour=") }),
              let hour = Int(argument.dropFirst("--pet-hour=".count)),
              let target = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now) else { return 0 }
        return target.timeIntervalSinceNow
    }()
    private static func clock(_ date: Date) -> Date { date.addingTimeInterval(hourOffset) }
    #else
    private static func clock(_ date: Date) -> Date { date }
    #endif

    /// A finished exchange with Kemo. `heard` decides whether it was a hello or a meal.
    /// The level just reached, shown briefly after a chat that levels Kemo up.
    private(set) var leveledUp: Int?
    func feed(heard: String, now: Date = .now) {
        let before = vitals.level
        vitals = vitals.fed(KemoVitals.Food(heard: heard), at: now)
        leveledUp = vitals.level > before ? vitals.level : nil
        save()
        Task { await rescheduleNudges(now: now) }
    }
    /// Keeps the complication's name current; the iPhone publishes the companion's name.
    func named(_ name: String) {
        guard name != self.name else { return }
        self.name = name
        defaults.set(name, forKey: Self.nameKey)
        save()
    }

    // MARK: Nudges

    var nudgesOn: Bool { defaults.bool(forKey: Self.nudgesKey) }

    /// Asks for notification permission, as the person turns nudges on. False when it isn't given.
    func turnOnNudges() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        defaults.set(granted, forKey: Self.nudgesKey)
        await rescheduleNudges()
        save()
        return granted
    }
    func turnOffNudges() async {
        defaults.set(false, forKey: Self.nudgesKey)
        await rescheduleNudges()
        save()
    }
    /// Replaces the waiting nudges with a fresh plan. Nudges already shown count toward today's limit.
    func rescheduleNudges(now: Date = .now) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("kemo.nudge.") }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        // Only the last two days matter for the daily limit and the gap.
        let delivered = history.filter { $0 <= now && now.timeIntervalSince($0) < 2 * 86_400 }
        var enabled = nudgesOn
        if enabled, await center.notificationSettings().authorizationStatus != .authorized {
            // Permission was taken back in Settings; follow it.
            enabled = false; defaults.set(false, forKey: Self.nudgesKey)
        }
        let plan = KemoNudge.plan(for: vitals, now: now, delivered: delivered, enabled: enabled)
        history = delivered + plan.map(\.date)
        for (index, nudge) in plan.enumerated() {
            let content = UNMutableNotificationContent()
            content.title = nudge.title(name: name)
            content.body = nudge.body(name: name)
            content.sound = .default
            content.categoryIdentifier = KemoNudgeDelegate.category
            content.threadIdentifier = "kemo.nudge"
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: nudge.date)
            let request = UNNotificationRequest(identifier: "kemo.nudge.\(index)", content: content,
                                                trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
            try? await center.add(request)
        }
    }
    private var history: [Date] {
        get { defaults.data(forKey: Self.historyKey).flatMap { try? JSONDecoder().decode([Date].self, from: $0) } ?? [] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Self.historyKey) }
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(vitals), forKey: Self.vitalsKey)
        KemoVitalsMirror.write(.init(vitals: vitals, name: name))
        WatchConnection.sharePet(.init(level: vitals.level, xp: vitals.xp ?? 0, streak: vitals.streak(at: .now),
                                        starved: vitals.starved ?? 0, updated: .now, nudges: nudgesOn))
        WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
    }
}

/// Handles taps on a nudge: the notification opens Kemo; its Talk button opens Kemo listening.
/// While the app is open, nudges stay quiet, because Kemo's face already shows how it feels.
final class KemoNudgeDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let category = "kemo.nudge"
    static let talkAction = "talk"
    static let shared = KemoNudgeDelegate()

    func register() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let talk = UNNotificationAction(identifier: Self.talkAction, title: "Talk", options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [talk], intentIdentifiers: [])])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [] }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.notification.request.content.categoryIdentifier == Self.category,
              response.actionIdentifier == Self.talkAction else { return }
        await MainActor.run { QuickTalk.shared.ask(.talk) }
    }
}

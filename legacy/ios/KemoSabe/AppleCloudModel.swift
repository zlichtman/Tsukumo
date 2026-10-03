import Foundation
import FoundationModels

/// Which of Apple's models answers a turn in the Apple harness (the owner's instruction, September 25,
/// 2026). Both run the same harness: the same tools, action gates, and private-context rules, since
/// both are Apple's model. Only on-device keeps everything on this device, so only it gets the lock.
///
/// Private Cloud is `PrivateCloudComputeLanguageModel` (iOS, macOS, and watchOS 27): the server model
/// behind Apple Intelligence, reached through `LanguageModelSession(model:)`. It has a per-person quota;
/// when a request hits it, or Private Cloud can't be reached, that one reply falls back to on-device
/// and says so in one line (`PrivateCloudFallback`). Apple requires a managed entitlement to use it
/// (`com.apple.developer.private-cloud-compute`, requested at developer.apple.com/private-cloud-compute);
/// without it `availability` still says available, requests fail, and replies fall back the same way.
enum AppleModel: String, Codable, Sendable, CaseIterable {
    case onDevice, privateCloud
    /// The name in the Models page, the watch confirmation, and saved conversations.
    var title: String { self == .onDevice ? "Apple on-device" : "Apple Private Cloud" }
    /// The short name on the composer's model button.
    var compactTitle: String { self == .onDevice ? "On-device" : "Private Cloud" }
}

enum PrivateCloudText {
    /// The one destination line, shown when Private Cloud is chosen (the way connected models name their host).
    static let destination = "Runs on Apple’s Private Cloud Compute."
    /// Where tool results went, for the content-free journal.
    static let journalDestination = "Apple Private Cloud Compute"
    static let detail = "Apple’s larger server model. Same private context and tools as on-device."
}

/// What the system says about Private Cloud right now, in the app's own terms so views and tests
/// don't depend on the iOS 27 types.
struct PrivateCloudStatus: Equatable, Sendable {
    enum Availability: Equatable, Sendable {
        case available
        /// Why it can't be chosen, as one short line.
        case unavailable(String)
    }
    struct Quota: Equatable, Sendable {
        var limitReached: Bool
        var approachingLimit: Bool
        var resetDate: Date?
    }
    var availability: Availability
    var quota: Quota?
    var isAvailable: Bool { availability == .available }
    var unavailableReason: String? { if case .unavailable(let reason) = availability { reason } else { nil } }

    static let olderSystem = PrivateCloudStatus(availability: .unavailable("Needs iOS 27 or macOS 27."), quota: nil)

    /// A short quota line for the Models page, or nil when there's nothing to say.
    func quotaLine(now: Date = Date(), timeZone: TimeZone = .current) -> String? {
        guard let quota else { return nil }
        if quota.limitReached {
            return "Limit reached" + (quota.resetDate.map { " until " + PrivateCloudFallback.format($0, now: now, timeZone: timeZone) } ?? "") + ". On-device answers until then."
        }
        return quota.approachingLimit ? "Nearing this period’s limit." : nil
    }
}

/// Whether this build may use Private Cloud: the `KemoPrivateCloud` Info.plist switch, set from the
/// `KEMO_PRIVATE_CLOUD` build setting. It stays off until Apple grants the managed entitlement
/// (`com.apple.developer.private-cloud-compute`) and it's in the entitlements: without it,
/// FoundationModels stops the app on a real device instead of throwing (build 54), so the model is
/// never even created. UI tests on the simulator may still use it.
enum PrivateCloudBuild {
    nonisolated static var enabled: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return true }
        #endif
        let value = Bundle.main.object(forInfoDictionaryKey: "KemoPrivateCloud")
        return (value as? Bool) == true || (value as? String)?.uppercased() == "YES"
    }
    static let waiting = PrivateCloudStatus(availability: .unavailable("Waiting for Apple to turn on Private Cloud for KemoSabe."), quota: nil)
}

/// Reads Private Cloud's availability and quota. Injectable so tests never depend on the device.
protocol PrivateCloudProbing {
    var status: PrivateCloudStatus { get }
}

struct SystemPrivateCloud: PrivateCloudProbing {
    var status: PrivateCloudStatus {
        guard #available(iOS 27, macOS 27, *) else { return .olderSystem }
        guard PrivateCloudBuild.enabled else { return PrivateCloudBuild.waiting }
        let model = PrivateCloudComputeLanguageModel()
        let availability: PrivateCloudStatus.Availability = switch model.availability {
        case .available: .available
        case .unavailable(.deviceNotEligible): .unavailable("This device doesn’t support Apple Intelligence.")
        case .unavailable(.systemNotReady): .unavailable("Apple Intelligence isn’t ready yet. Check that it’s on in Settings.")
        case .unavailable: .unavailable("Private Cloud isn’t available right now.")
        }
        let usage = model.quotaUsage
        let approaching: Bool = if case .belowLimit(let below) = usage.status { below.isApproachingLimit } else { false }
        return .init(availability: availability,
                     quota: .init(limitReached: usage.isLimitReached, approachingLimit: approaching, resetDate: usage.resetDate))
    }
}

/// Why a Private Cloud reply fell back to on-device, and the one line that says so.
enum PrivateCloudFallback: Equatable {
    case quota(resetDate: Date?)
    case network
    case service
    /// Any other failure, for example an app without Apple's Private Cloud entitlement.
    case failed
    /// The chat, or something attached to it, is set to Device only (`ContextPolicy`).
    case deviceOnly

    /// The fallback for an error Private Cloud threw, or nil for cancellation and the harness's own
    /// errors (busy, changed context, expired), which never switch models.
    static func reason(for error: Error) -> PrivateCloudFallback? {
        if error is CancellationError || error is PlanningError || error is ToolFailure { return nil }
        if #available(iOS 27, macOS 27, *), let cloud = error as? PrivateCloudComputeLanguageModel.Error {
            switch cloud {
            case .quotaLimitReached(let limit): return .quota(resetDate: limit.resetDate)
            case .networkFailure: return .network
            case .serviceUnavailable: return .service
            @unknown default: return .failed
            }
        }
        return .failed
    }
    /// One line: what happened with Private Cloud, and that on-device answered this reply.
    func notice(onDeviceAnswered: Bool = true, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let cause: String = switch self {
        case .quota(let reset): "Private Cloud limit reached" + (reset.map { " until " + Self.format($0, now: now, timeZone: timeZone) } ?? "")
        case .network: "Couldn’t reach Private Cloud"
        case .service: "Private Cloud isn’t available right now"
        case .failed: "Private Cloud couldn’t answer"
        case .deviceOnly: "This chat is Device only"
        }
        return cause + (onDeviceAnswered ? ". On-device answered this one." : ", and the on-device model isn’t ready. Try again later.")
    }
    /// "3:00 PM" today, "tomorrow 9:00 AM", otherwise "Fri 9:00 AM".
    static func format(_ date: Date, now: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let time = DateFormatter(); time.timeZone = timeZone; time.locale = Locale(identifier: "en_US_POSIX"); time.dateFormat = "h:mm a"
        if calendar.isDate(date, inSameDayAs: now) { return time.string(from: date) }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow " + time.string(from: date)
        }
        let day = DateFormatter(); day.timeZone = timeZone; day.locale = Locale(identifier: "en_US_POSIX"); day.dateFormat = "EEE MMM d, h:mm a"
        return day.string(from: date)
    }
}

/// Private Cloud couldn't answer and neither could on-device; the chat says so in one line.
struct PrivateCloudUnavailable: Error { let reason: PrivateCloudFallback }

/// Sessions for the Apple harness: the same instructions and tools on either of Apple's models.
enum AppleSessions {
    static func make(_ model: AppleModel, tools: [any Tool] = [], instructions: String) -> LanguageModelSession {
        if model == .privateCloud, PrivateCloudBuild.enabled, #available(iOS 27, macOS 27, *) {
            return LanguageModelSession(model: PrivateCloudComputeLanguageModel(), tools: tools, instructions: instructions)
        }
        return LanguageModelSession(tools: tools, instructions: instructions)
    }
    /// The model that classifies a turn: on-device when it's ready (fast, and no quota), otherwise the chosen one.
    static func classifier(for model: AppleModel) -> AppleModel {
        SystemLanguageModel.default.isAvailable ? .onDevice : model
    }
}

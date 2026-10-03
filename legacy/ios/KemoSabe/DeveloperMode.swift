import SwiftUI

/// Developer settings (the animation gallery and other debugging tools) stay
/// hidden until someone taps the version number in General seven times, the same
/// gesture on iPhone and Mac. Stored per device; turning it off hides them again.
@MainActor @Observable final class DeveloperMode {
    static let shared = DeveloperMode()
    static let tapsToUnlock = 7
    /// Where developer settings appear: the bottom of Companion, on every device.
    static let home = "Companion"
    private let defaults: UserDefaults
    var enabled: Bool { didSet { defaults.set(enabled, forKey: "kemo.developer.enabled") } }
    private(set) var taps = 0
    private var lastTap = Date.distantPast

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--developer") { enabled = true; return }
        #endif
        enabled = defaults.bool(forKey: "kemo.developer.enabled")
    }
    /// Counts a tap on the version number. Returns a line to show, or nil.
    /// Taps more than two seconds apart start over.
    func tapVersion(now: Date = Date()) -> String? {
        guard !enabled else { return "Developer settings are already on." }
        if now.timeIntervalSince(lastTap) > 2 { taps = 0 }
        lastTap = now; taps += 1
        let left = Self.tapsToUnlock - taps
        if left <= 0 { enabled = true; taps = 0; return "Developer settings unlocked. Find them at the bottom of \(Self.home)." }
        return left <= 4 ? "\(left) more \(left == 1 ? "tap" : "taps") for developer settings." : nil
    }
}

/// Developer settings look different on purpose: monospaced, with a lime accent
/// and a dashed border, so nobody mistakes them for everyday settings.
struct DeveloperSection<Content: View>: View {
    @ViewBuilder var content: Content
    static var accent: Color { Color(red: 0.62, green: 0.93, blue: 0.36) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Developer", systemImage: "hammer.fill")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Self.accent)
            VStack(alignment: .leading, spacing: 10) { content }
                .font(.system(size: 13, design: .monospaced))
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Self.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Self.accent.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        }
        .tint(Self.accent)
        .accessibilityIdentifier("developerSection")
    }
}

/// The developer label, for list sections that can't hold a DeveloperSection card.
struct DeveloperHeader: View {
    var body: some View {
        Label("Developer", systemImage: "hammer.fill")
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(DeveloperSection<EmptyView>.accent)
            .accessibilityIdentifier("developerSection")
    }
}

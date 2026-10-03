#if DEBUG
import AppKit
import SwiftUI
import TsukumoCore
import TsukumoEngines
import TsukumoUI
import TsukumoDock

// A developer aid: `--capture <folder>` saves Tsukumo's windows as AppKit draws them (live Liquid Glass
// and the characters' layer loops don't draw this way). With the first run showing (a fresh
// `--ui-testing` start), it saves each of its steps, finishes it with two starters, then a customized
// bot's editor and KemoSabe's, and every Settings page, light and dark (`mac-settings-<page>-<light|dark>`).
// Otherwise it saves the open windows twice while the dock runs, then Settings' Bots and Models.

extension TsukumoDelegate {
    func startCapture() {
        guard let index = CommandLine.arguments.firstIndex(of: "--capture"), index + 1 < CommandLine.arguments.count else { return }
        let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        Task { @MainActor in
            if !accounts.onboarded && !isDemo {
                await captureFirstRunAndSettings(into: folder)
                return
            }
            for (pause, moment) in [(9.0, "consent"), (15.0, "end")] {
                try? await Task.sleep(for: .seconds(pause))
                Self.capture(into: folder, moment: moment)
            }
            guard !isDemo else { return }
            for section in [SettingsSection.bots, .models] {
                showSettings(section)
                try? await Task.sleep(for: .seconds(1.2))
                if let window = settings?.window { Self.capture(into: folder, moment: "settings-\(section.rawValue)", only: window) }
            }
        }
    }

    static func capture(into folder: URL, moment: String, only: NSWindow? = nil) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let windows = only.map { [$0] } ?? NSApp.windows.filter { $0.isVisible && !$0.title.isEmpty }
        for window in windows {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let name = only != nil ? moment : moment + "-" + window.title.replacingOccurrences(of: " ", with: "-").lowercased()
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name + ".png"))
        }
    }

    private func captureFirstRunAndSettings(into folder: URL) async {
        let names = ["welcome", "sign-in", "connect", "bots"]
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: appearance)
            let suffix = appearance == .darkAqua ? "dark" : "light"
            for step in OnboardingFlow<TsukumoDelegate>.Step.allCases {
                if step == .bots && bots.count == 1 { _ = add(starter: StarterBot.all[0]); _ = add(starter: StarterBot.all[2]) }
                onboardingWindow?.contentView = onboardingView(start: step)
                try? await Task.sleep(for: .seconds(1.2))
                Self.capture(into: folder, moment: "mac-\(step.rawValue + 1)-\(names[step.rawValue])-\(suffix)")
            }
        }
        accounts.finishOnboarding()
        finishOnboarding()
        guard let dock else { return }
        // Signed out: Sign in with Apple lines up with the page (Apple's own button with --real-sign-in).
        accounts.signOut()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: appearance)
            showSettings(.account)
            try? await Task.sleep(for: .seconds(1.2))
            if let window = settings?.window {
                Self.capture(into: folder, moment: "mac-settings-account-signed-out-\(appearance == .darkAqua ? "dark" : "light")", only: window)
            }
        }
        settings?.window.orderOut(nil)
        try? accounts.signIn(userID: "fixture-000001", name: "Test Owner", method: .fixture)
        if var homework = dock.bots.first(where: { $0.name == "Homework" }) {
            homework.look.accessory = .scarf
            homework.look.expression = .grin
            homework.look.accentColor = "6F63C9"
            homework.look.scale = 1.15
            homework.personality = BotPersonality(tone: .coach, instructions: "Call me Sam.")
            dock.update(homework)
        }
        dock.update(BotSpec.kemoSabe(tint: "2F8F8B"))
        // A connection without a key, so Models shows one (nothing is sent anywhere).
        if let connection = try? APIConnection.validated(name: "Claude", endpoint: APIConnection.anthropicEndpoint, model: "claude-opus-5-5", wire: .anthropic) {
            try? save(connection: ConnectionRecord(connection: connection, provider: .anthropic), key: nil)
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: appearance)
            let suffix = appearance == .darkAqua ? "dark" : "light"
            controller?.open(.edit(BotSpec.kemoSabeID))
            try? await Task.sleep(for: .seconds(1.5))
            Self.capture(into: folder, moment: "mac-kemosabe-settings-\(suffix)")
            if let homework = dock.bots.first(where: { $0.name == "Homework" }) {
                controller?.open(.edit(homework.id))
                try? await Task.sleep(for: .seconds(1.5))
                Self.capture(into: folder, moment: "mac-bot-editor-\(suffix)")
            }
            dock.open(nil)
            for section in SettingsSection.allCases {
                showSettings(section)
                try? await Task.sleep(for: .seconds(1.2))
                if let window = settings?.window {
                    Self.capture(into: folder, moment: "mac-settings-\(section.rawValue)-\(suffix)", only: window)
                }
            }
            settings?.window.orderOut(nil)
        }
        NSApp.appearance = nil
    }
}
#endif

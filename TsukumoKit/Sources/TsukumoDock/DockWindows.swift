#if os(macOS)
import AppKit
import Observation
import SwiftUI
import TsukumoCore
import TsukumoUI

// The side dock's windows (ported from `AgentsDockHost` and its panels in
// the old Mac app's dock): a floating shelf on the screen's edge that tucks away to a
// sliver and comes out when the pointer reaches it, the bubble that slides out beside a tile, and the
// speech bubble a tile shows when a bot chirps in. None of them activates the host app; the bubble takes
// the keyboard while it's open. The side dock is the Tsukumo app's only face on the Mac: it always shows,
// unless the owner hides it for now from the menu bar (Hide Dock).

/// The shelf's panel: never key, on every Space, over full-screen apps.
final class DockPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
/// The bubble's panel: takes the keyboard without activating the host.
final class DockBubblePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Reveals the dock when the pointer reaches it, and tucks it away when it leaves.
final class DockHoverView: NSView {
    var entered: (() -> Void)?
    var exited: (() -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { entered?() }
    override func mouseExited(with event: NSEvent) { exited?() }
}

/// Puts the side dock on screen for a `BotDock`. The app makes one and calls `apply()`.
@MainActor @Observable public final class BotDockController {
    public let dock: BotDock
    public private(set) var revealed = false
    /// The characters hold still: the dock is covered, or the screens sleep.
    public private(set) var paused = false
    @ObservationIgnored private var shelfPanel: DockPanel?
    @ObservationIgnored private var bubblePanel: DockBubblePanel?
    @ObservationIgnored private var calloutPanel: DockPanel?
    @ObservationIgnored private var collapse: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var pauseReasons: Set<String> = []
    /// The color scheme the dock's windows use (nil follows the system).
    @ObservationIgnored public var colorScheme: ColorScheme?

    public init(dock: BotDock) { self.dock = dock }

    /// The owner hid the dock for now (the menu bar's Hide Dock); it comes back with Show Dock, or when
    /// the app opens again.
    public private(set) var isHidden = false
    /// Whether the side dock is on screen now.
    public var showsSideDock: Bool { !isHidden }

    /// Hides the side dock for now, or shows it again.
    public func setHidden(_ hidden: Bool) {
        guard hidden != isHidden else { return }
        isHidden = hidden
        if hidden { dock.open(nil) }
        apply()
    }

    /// Shows the side dock. Call it once; it follows the dock's settings from then on.
    public func apply() {
        guard showsSideDock else {
            shelfPanel?.orderOut(nil); bubblePanel?.orderOut(nil); calloutPanel?.orderOut(nil)
            observe()
            return
        }
        if shelfPanel == nil { makePanels(); watchPower() }
        place()
        shelfPanel?.orderFrontRegardless()
        observe()
        sync()
    }
    /// Closes every window (before the host quits).
    public func close() {
        shelfPanel?.orderOut(nil); bubblePanel?.orderOut(nil); calloutPanel?.orderOut(nil)
    }
    /// Brings the dock out with a bot's chat open (showing it again if it was hidden).
    public func open(_ surface: DockSurface) {
        if isHidden { setHidden(false) }
        reveal()
        dock.open(surface)
    }

    // MARK: Layout

    private var screen: NSRect { (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .init(x: 0, y: 0, width: 1440, height: 900) }
    public var layout: DockLayout { DockLayout(settings: dock.settings, tiles: dock.bots.count + DockShelfView.extraTiles, screen: screen) }
    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func makePanels() {
        let panel = DockPanel(contentRect: layout.tuckedFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configure(panel, title: "Bot dock")
        let hover = DockHoverView(frame: panel.contentLayoutRect)
        hover.entered = { [weak self] in self?.reveal() }
        hover.exited = { [weak self] in self?.tuck() }
        panel.contentView = hover
        let host = NSHostingView(rootView: DockShelfRoot(controller: self))
        host.frame = hover.bounds; host.autoresizingMask = [.width, .height]
        hover.addSubview(host)
        shelfPanel = panel

        let bubble = DockBubblePanel(contentRect: .init(origin: .zero, size: DockMetrics.bubble), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configure(bubble, title: "Bot chat")
        bubble.becomesKeyOnlyIfNeeded = false
        bubble.contentView = NSHostingView(rootView: DockBubbleRoot(controller: self))
        bubblePanel = bubble
        // Clicking elsewhere puts a chat away; a bot's settings stay until they're saved or closed.
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: bubble, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch self.dock.surface {
                case .panel?: return
                default: self.dock.open(nil)
                }
            }
        })

        let callout = DockPanel(contentRect: .init(origin: .zero, size: DockMetrics.callout), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configure(callout, title: "Bot chirp")
        callout.contentView = NSHostingView(rootView: DockCalloutRoot(controller: self))
        calloutPanel = callout

        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        })
    }
    private func configure(_ panel: NSPanel, title: String) {
        panel.title = title; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovable = false
        if let colorScheme { panel.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua) }
    }

    private func reveal() {
        collapse?.cancel(); collapse = nil
        guard let shelfPanel, !revealed || shelfPanel.frame != layout.revealedFrame else { return }
        shelfPanel.setFrame(layout.revealedFrame, display: true)
        withAnimation(reduceMotion ? nil : .spring(duration: 0.32, bounce: 0.22)) { revealed = true }
    }
    /// Tucks the dock away after the owner's delay, unless a bubble or callout is out.
    private func tuck(now: Bool = false) {
        collapse?.cancel()
        guard dock.settings.autohide else { reveal(); return }
        let delay = dock.settings.autohideDelay
        collapse = Task { [weak self] in
            if !now { try? await Task.sleep(for: .seconds(delay)) }
            guard let self, !Task.isCancelled, self.dock.surface == nil, self.dock.callout == nil, self.dock.voiceBubble == nil,
                  now || !(self.shelfPanel?.frame.contains(NSEvent.mouseLocation) ?? false) else { return }
            withAnimation(self.reduceMotion ? nil : .easeIn(duration: 0.18)) { self.revealed = false }
            try? await Task.sleep(for: .milliseconds(self.reduceMotion ? 0 : 200))
            guard !self.revealed else { return }
            self.shelfPanel?.setFrame(self.layout.tuckedFrame, display: true)
        }
    }
    private func place() {
        if !dock.settings.autohide, !revealed { revealed = true }
        shelfPanel?.setFrame(revealed ? layout.revealedFrame : layout.tuckedFrame, display: true)
        placeBubble(); placeCallout()
    }
    private func index(of surface: DockSurface) -> Int {
        switch surface {
        case .bot(let id), .panel(let id): dock.bots.firstIndex { $0.id == id } ?? 0
        case .addBot: dock.bots.count
        case .together: dock.bots.count + 1
        }
    }
    private func placeBubble() {
        guard let bubblePanel, let surface = dock.surface else { return }
        bubblePanel.setFrame(layout.bubbleFrame(forTile: index(of: surface), size: DockMetrics.size(for: surface)), display: true)
    }
    /// The bot whose speech bubble shows: one listening (or just done), or one chirping or finished.
    private var calloutBot: UUID? { dock.voiceBubble?.botID ?? dock.callout?.bot }
    private func placeCallout() {
        guard let calloutPanel, let bot = calloutBot, let index = dock.bots.firstIndex(where: { $0.id == bot }) else { return }
        calloutPanel.setFrame(layout.calloutFrame(forTile: index, size: DockMetrics.callout), display: true)
    }

    /// Follows the dock: the open surface, callouts, the bots, and the settings.
    private func observe() {
        withObservationTracking {
            _ = dock.surface; _ = dock.callout; _ = dock.bots.count; _ = dock.settings
            _ = dock.voice?.listener; _ = dock.voice?.lastListener
        } onChange: { [weak self] in
            Task { @MainActor in self?.changed() }
        }
    }
    private func changed() {
        if showsSideDock != (shelfPanel?.isVisible ?? false) { apply(); return }
        sync()
        observe()
    }
    private func sync() {
        guard showsSideDock, shelfPanel != nil else { return }
        let frame = shelfPanel?.frame
        if frame != layout.revealedFrame && frame != layout.tuckedFrame { place() }
        if dock.surface != nil {
            reveal(); placeBubble()
            bubblePanel?.orderFrontRegardless(); bubblePanel?.makeKey()
        } else {
            bubblePanel?.orderOut(nil)
            if !(shelfPanel?.frame.contains(NSEvent.mouseLocation) ?? false) { tuck() }
        }
        if let listening = dock.voiceBubble, let bot = listening.botID, dock.surface != .bot(bot) {
            reveal(); placeCallout(); calloutPanel?.orderFrontRegardless()
        } else if let callout = dock.callout, dock.surface == nil || !dock.isShowing(callout.bot) {
            reveal(); placeCallout(); calloutPanel?.orderFrontRegardless()
        } else {
            calloutPanel?.orderOut(nil)
            if dock.surface == nil, !(shelfPanel?.frame.contains(NSEvent.mouseLocation) ?? false) { tuck() }
        }
    }

    // MARK: Saving power

    private func setPaused(_ reason: String, _ on: Bool) {
        if on { pauseReasons.insert(reason) } else { pauseReasons.remove(reason) }
        if paused != !pauseReasons.isEmpty { paused = !pauseReasons.isEmpty }
    }
    private func watchPower() {
        let workspace = NSWorkspace.shared.notificationCenter
        let pairs: [(Notification.Name, String, Bool)] = [
            (NSWorkspace.screensDidSleepNotification, "sleep", true), (NSWorkspace.screensDidWakeNotification, "sleep", false),
            (NSWorkspace.sessionDidResignActiveNotification, "session", true), (NSWorkspace.sessionDidBecomeActiveNotification, "session", false)
        ]
        for (name, reason, on) in pairs {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setPaused(reason, on) }
            })
        }
        if let shelfPanel {
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: shelfPanel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let panel = self.shelfPanel else { return }
                    self.setPaused("occluded", !panel.occlusionState.contains(.visible))
                }
            })
        }
    }
}

// MARK: The windows' roots

private struct DockShelfRoot: View {
    let controller: BotDockController
    var body: some View {
        DockShelfView(dock: controller.dock, layout: controller.layout, revealed: controller.revealed,
                      reduceMotion: controller.reduceMotion, active: !controller.paused)
    }
}

private struct DockBubbleRoot: View {
    let controller: BotDockController
    var body: some View {
        DockBubble(dock: controller.dock)
    }
}

private struct DockCalloutRoot: View {
    let controller: BotDockController
    var body: some View {
        let dock = controller.dock
        if let listening = dock.voiceBubble, let bot = dock.bot(listening.botID) {
            let left = dock.settings.edge == .left
            DockListeningBubble(bot: bot, listener: listening, tailOnLeft: left) { dock.open(.bot(bot.id)) }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: left ? .topLeading : .topTrailing)
                .transition(.opacity)
        } else if let callout = dock.callout, let bot = dock.bot(callout.bot) {
            let left = dock.settings.edge == .left
            DockCalloutBubble(bot: bot, text: callout.text, tailOnLeft: left)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: left ? .topLeading : .topTrailing)
                .onTapGesture { dock.open(.bot(bot.id)) }
                .transition(.opacity)
        }
    }
}
#endif

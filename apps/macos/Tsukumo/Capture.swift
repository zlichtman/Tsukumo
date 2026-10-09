#if DEBUG
import AppKit
import SwiftUI
import TsukumoCore
import TsukumoEngines
import TsukumoGateway
import TsukumoSystemOne
import TsukumoUI
import TsukumoDock
import TsukumoUpdate

// A developer aid: `--capture <folder>` saves Tsukumo's windows as AppKit draws them (live Liquid Glass
// doesn't draw this way). With the first run showing (a fresh `--ui-testing` start), it saves each of its steps,
// then KemoSabe's palettes, a service's panel, KemoSabe in each of its moods (`mac-kemosabe-states-*`), the dock
// with a lineup of stand-in services and its Settings tile (`mac-dock-lineup-*`), Muse's and Grok's pages in
// Settings, Bots (`mac-settings-bot-muse-*`, `mac-settings-bot-grok-*`), and every Settings page, light and dark
// (`mac-settings-<page>-<light|dark>`, and Models' Voice tab as `mac-settings-models-voice-<light|dark>`),
// then a bot listening in the dock (`mac-listening-*`, with a scripted stand-in for the microphone).
// Otherwise it saves the open windows twice while the dock runs, then Settings' Bots and Models.

extension TsukumoDelegate {
    func startCapture() {
        guard let index = CommandLine.arguments.firstIndex(of: "--capture"), index + 1 < CommandLine.arguments.count else { return }
        let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        SettingsView.capturing = true
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

    /// One Settings page at full length, in a borderless window as tall as the page (AppKit doesn't fit a
    /// borderless window to the screen).
    private func captureWholePage(_ section: SettingsSection, into folder: URL, moment: String, height: CGFloat = 1_900) async {
        let state = SettingsState()
        state.section = section
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = section.title
        let host = NSHostingView(rootView: SettingsView(app: self, state: state))
        host.sizingOptions = []
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -2_000, y: 0))
        window.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(1.5))
        Self.capture(into: folder, moment: moment, only: window)
        window.orderOut(nil)
    }

    private func captureFirstRunAndSettings(into folder: URL) async {
        let names = ["welcome", "sign-in", "connect"]
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: appearance)
            let suffix = appearance == .darkAqua ? "dark" : "light"
            for step in OnboardingFlow<TsukumoDelegate>.Step.allCases {
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
        dock.update(BotSpec.kemoSabe(palette: KemoSabeLook.standard.defaultPalette))
        // General's Software Update card offering a made-up next version (nothing is checked or downloaded).
        updates.preview(.available(UpdateFeed(version: "2.04", build: 204, url: URL(string: "https://zlichtman.com/downloads/Tsukumo-2.04.dmg")!,
                                              sha256: String(repeating: "0", count: 64), minimumMacOS: "26.0",
                                              notes: "Tsukumo’s Dock now updates itself from Settings, General.")))
        // A connection without a key, so Models shows one (nothing is sent anywhere).
        if let connection = try? APIConnection.validated(name: "Claude", endpoint: APIConnection.anthropicEndpoint, model: "claude-opus-5-5", wire: .anthropic) {
            try? save(connection: ConnectionRecord(connection: connection, provider: .anthropic), key: nil)
        }
        // The lineup in the pictures, as if connected: Claude (that connection), Codex on this Mac, and Grok and Muse
        // signed in to the gateway. Nothing is connected for real.
        capturedServices = ServiceConnections(claudeAPI: connections.first { $0.provider == .anthropic }?.id, installedAgents: ["codex"],
                                              callers: [.grok, .muse])
        // A few of KemoSabe's sources on (stand-in permissions under --ui-testing: nothing is read), a picked
        // folder, and a connected account (its stand-in connects without the network).
        for id in ["calendar", "contacts", "photos", "messages"] { await sources.set(id, on: true) }
        sources.set("messages", level: .deviceOnly)
        let notes = FileManager.default.temporaryDirectory.appendingPathComponent("Capture-\(UUID().uuidString)/Class notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        sources.addFiles([notes])
        _ = try? await sources.addAccount(name: "Notion", url: "https://mcp.example.com/mcp", token: nil)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: appearance)
            let suffix = appearance == .darkAqua ? "dark" : "light"
            controller?.open(.panel(BotSpec.kemoSabeID))
            try? await Task.sleep(for: .seconds(1.5))
            Self.capture(into: folder, moment: "mac-kemosabe-palettes-\(suffix)")
            // A service's panel: how it connects, what it asked KemoSabe, what it may do, and its settings.
            controller?.open(.panel(ServiceID.claude.botID))
            try? await Task.sleep(for: .seconds(1.5))
            Self.capture(into: folder, moment: "mac-service-panel-\(suffix)")
            dock.open(nil)
            await captureKemoSabeStates(into: folder, suffix: suffix)
            // The dock with the lineup and its Settings tile, shown rather than tucked away.
            let shown = dock.settings
            dock.store.update { $0.autohide = false }
            controller?.apply()
            try? await Task.sleep(for: .seconds(1.5))
            Self.capture(into: folder, moment: "mac-dock-lineup-\(suffix)")
            dock.store.update { $0 = shown }
            for section in SettingsSection.allCases {
                showSettings(section)
                try? await Task.sleep(for: .seconds(1.2))
                if let window = settings?.window {
                    Self.capture(into: folder, moment: "mac-settings-\(section.rawValue)-\(suffix)", only: window)
                }
            }
            settings?.state.modelsPage = .voice
            showSettings(.models)
            try? await Task.sleep(for: .seconds(1.2))
            if let window = settings?.window { Self.capture(into: folder, moment: "mac-settings-models-voice-\(suffix)", only: window) }
            await captureSystemOne(into: folder, suffix: suffix)
            settings?.state.modelsPage = .llm
            // Search: what's on every page, by name or by what it's about.
            settings?.state.search = "voice"
            showSettings(.account)
            try? await Task.sleep(for: .seconds(1.2))
            if let window = settings?.window { Self.capture(into: folder, moment: "mac-settings-search-\(suffix)", only: window) }
            settings?.state.search = ""
            settings?.window.orderOut(nil)
            // A bot listening: the ring on its tile and the bubble with the words so far.
            if let claude = dock.bot(ServiceID.claude.botID) {
                dock.talk(to: claude.id, hold: false)
                try? await Task.sleep(for: .seconds(1.8))
                Self.capture(into: folder, moment: "mac-listening-\(suffix)")
                dock.listener(for: claude.id)?.cancel()
                try? await Task.sleep(for: .seconds(0.5))
            }
            // The whole Dock page, top to bottom; again in a color and Tinted glass, and the catalog searched.
            await captureWholePage(.dock, into: folder, moment: "mac-settings-dock-full-\(suffix)")
            let before = dock.settings
            dock.store.update { $0.style = .tinted; $0.tint = "7467D4"; $0.edge = .left; $0.position = .top }
            await captureWholePage(.dock, into: folder, moment: "mac-settings-dock-color-\(suffix)")
            dock.store.update { $0 = before }
            await captureGateway(into: folder, suffix: suffix)
        }
        NSApp.appearance = nil
    }

    /// KemoSabe in each of its moods, in its look and palette, on the chat's paper or plum (`mac-kemosabe-states-*`).
    private func captureKemoSabeStates(into folder: URL, suffix: String) async {
        let kemoSabe = dock?.bot(BotSpec.kemoSabeID) ?? .kemoSabe()
        let view = HStack(spacing: 18) {
            ForEach(KemoSabeMood.allCases, id: \.self) { mood in
                VStack(spacing: 8) {
                    KemoSabeFigure(bot: kemoSabe, mood: mood).frame(width: 120, height: 120)
                    Text(mood.rawValue == "needsYou" ? "Needs you" : mood.rawValue.capitalized).font(.system(size: 12, weight: .medium))
                }
            }
        }
        .padding(24)
        .background(TsukumoTheme(suffix == "dark" ? .dark : .light).background)
        .environment(\.colorScheme, suffix == "dark" ? .dark : .light)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = "KemoSabe"
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.setContentSize(host.fittingSize)
        window.setFrameOrigin(NSPoint(x: -2_000, y: 0))
        window.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(1.0))
        Self.capture(into: folder, moment: "mac-kemosabe-states-\(suffix)", only: window)
        window.orderOut(nil)
    }

    /// Settings, Gateway at full length (`mac-settings-gateway-full-*`) with an agent, a grant, a card, the
    /// ledger, and the Inbox, all from made-up data; the card in KemoSabe's chat beside the dock
    /// (`mac-gateway-card-*`); and the sign-in window (`mac-gateway-sign-in-*`). Nothing leaves this Mac.
    private func captureGateway(into folder: URL, suffix: String) async {
        guard let gateway else { return }
        if gateway.store.callers.isEmpty {
            gateway.store.update { $0.port = 0; $0.contentTools = true; $0.inbox = true }
            await gateway.setEnabled(true)
            let agent = gateway.store.addTokenCaller(name: "Claude Code").caller
            gateway.store.grant(.standard(.freeBusy, caller: agent.id, now: Date()))
            let tomorrow = Calendar.current.startOfDay(for: Date().addingTimeInterval(86_400))
            let stamp = ISO8601DateFormatter()
            _ = await gateway.tools.call(tool: "kemosabe_free_busy", arguments: .object(["start": .string(stamp.string(from: tomorrow)),
                "end": .string(stamp.string(from: tomorrow.addingTimeInterval(2 * 86_400)))]), caller: agent)
            _ = await gateway.tools.call(tool: "kemosabe_contact_lookup", arguments: .object(["name": .string("Sarah Lin")]), caller: agent)
            _ = await gateway.tools.call(tool: "tsukumo_deliver", arguments: .object(["kind": .string("file"), "name": .string("trip-plan.md"),
                "content": .string("Day 1: Kyoto"), "note": .string("The plan we talked about")]), caller: agent)
        }
        await captureWholePage(.gateway, into: folder, moment: "mac-settings-gateway-full-\(suffix)", height: 2_100)
        // The public address on, connected to a stand-in relay inside the app (nothing leaves this Mac), with its
        // address, Disconnect, Delete This Address, and the steps for each agent (`mac-settings-gateway-relay-*`).
        if gateway.relay?.connectedBase == nil {
            gateway.attachRelay(keys: MemoryRelayKeyStore(), transport: CaptureRelay(), secureEnclave: false)
            gateway.store.update { $0.relayExplained = true }
            gateway.setRelayURL(CaptureRelay.origin)
            gateway.setRelayEnabled(true)
            for _ in 0..<30 where gateway.relay?.connectedBase == nil { try? await Task.sleep(for: .milliseconds(100)) }
        }
        await captureWholePage(.gateway, into: folder, moment: "mac-settings-gateway-relay-\(suffix)", height: 2_700)
            // Two bots' pages in Settings, Bots: Muse (its pairing) and Grok (the gateway's address and steps).
            for service in [ServiceID.muse, .grok] {
                showSettings(.bots)
                settings?.state.botPage = .service(service)
                try? await Task.sleep(for: .seconds(1.5))
                if let sheet = settings?.window.attachedSheet {
                    Self.capture(into: folder, moment: "mac-settings-bot-\(service.rawValue)-\(suffix)", only: sheet)
                }
                settings?.state.botPage = nil
                try? await Task.sleep(for: .seconds(0.8))
            }
        settings?.window.orderOut(nil)
        controller?.open(.bot(BotSpec.kemoSabeID))
        try? await Task.sleep(for: .seconds(1.5))
        Self.capture(into: folder, moment: "mac-gateway-card-\(suffix)")
        dock?.open(nil)
        let request = GatewayApprovalRequest(callerID: "capture", callerName: "Grok", tool: nil, kind: .newClient(redirectURI: "https://grok.com/connectors/oauth/callback?connector=kemosabe&return_to=%2Fsettings%2Fconnectors%2Fcustom%2Fnew&session=7f3a9c2e41b84d6aa0c5e19f2b7d8e60", local: true),
                                             text: "Signing in sends you back to grok.com. It gets nothing until you allow each kind of request.",
                                             fingerprint: "capture")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Connect to KemoSabe"
        let host = NSHostingView(rootView: GatewaySignInView(request: request, armingDelay: .zero) { _, _ in })
        window.contentView = host
        window.setContentSize(host.fittingSize)
        window.center()
        window.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(1.2))
        Self.capture(into: folder, moment: "mac-gateway-sign-in-\(suffix)", only: window)
        window.orderOut(nil)
        // The same sign-in arriving through the public relay (`mac-gateway-sign-in-relay-*`).
        let relayed = GatewayApprovalRequest(callerID: "capture-relay", callerName: "Claude", tool: nil,
                                             kind: .newClient(redirectURI: "https://claude.ai/api/mcp/auth_callback", local: false, relayed: true),
                                             text: "Signing in sends you back to claude.ai. It gets nothing until you allow each kind of request.",
                                             fingerprint: "capture-relay")
        let relayWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        relayWindow.title = "Connect to KemoSabe"
        let relayHost = NSHostingView(rootView: GatewaySignInView(request: relayed, armingDelay: .zero) { _, _ in })
        relayWindow.contentView = relayHost
        relayWindow.setContentSize(relayHost.fittingSize)
        relayWindow.center()
        relayWindow.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(1.2))
        Self.capture(into: folder, moment: "mac-gateway-sign-in-relay-\(suffix)", only: relayWindow)
        relayWindow.orderOut(nil)
    }

    /// Models' System One tab (`mac-settings-models-system-one-*`), with two decisions in its journal (one
    /// from a stand-in on-device model, one where everyone was unsure), then Cloudflare Clef-flash's page
    /// with an account ID and no token (`mac-settings-system-one-clef-flash-*`), and Laya's page
    /// (`mac-settings-system-one-laya-*`). Nothing is sent anywhere and no key is saved.
    private func captureSystemOne(into folder: URL, suffix: String) async {
        guard let center = systemOne else { return }
        if center.records.isEmpty {
            let request = DecisionRequest(state: "fixture", questions: [DecisionQuestion(id: "route", kind: .choice, instruction: "Which bot?",
                options: ["KemoSabe", "Codex: OpenAI’s coding agent on this Mac"])], deadline: Date().addingTimeInterval(10))
            _ = await SystemOne.decide(.route, request, providers: SystemOneProviders(local: CaptureDecider(top: 0.96), journal: center.journal), level: .personal)
            _ = await SystemOne.decide(.route, request, providers: SystemOneProviders(local: CaptureDecider(top: 0.62), journal: center.journal), level: .personal)
            var clef = center.setting(.clefFlash)
            clef.accountID = "0123456789abcdef0123456789abcdef"
            center.update(clef)
            await center.reload()
        }
        settings?.state.modelsPage = .systemOne
        showSettings(.models)
        try? await Task.sleep(for: .seconds(1.2))
        if let window = settings?.window { Self.capture(into: folder, moment: "mac-settings-models-system-one-\(suffix)", only: window) }
        for page in [HostedProviderKind.clefFlash.id, "laya"] {
            settings?.state.systemOneDetail = page
            try? await Task.sleep(for: .seconds(1.5))
            if let sheet = settings?.window.attachedSheet {
                Self.capture(into: folder, moment: "mac-settings-system-one-\(page)-\(suffix)", only: sheet)
            }
            settings?.state.systemOneDetail = nil
            try? await Task.sleep(for: .seconds(0.8))
        }
    }
}

/// A stand-in relay for the pictures, inside the app: it registers a made-up device and holds the socket open,
/// answering pings. Nothing leaves this Mac.
private final class CaptureRelay: RelayTransport, @unchecked Sendable {
    static let origin = "https://tsukumo-relay.example.workers.dev"
    static let device = "q7m2xk4wz3pj5rt6vb2nc7hd4e"
    func challenge(_ url: URL) async throws -> (status: Int, body: Data, retryAfter: Int?) {
        let mode = url.query == nil ? "register" : "connect"
        return (200, Data(#"{"protocol":"tsukumo-relay-v1","mode":"\#(mode)","device_id":"\#(Self.device)","nonce":"capture","expires_in_ms":30000}"#.utf8), nil)
    }
    func connect(_ url: URL, headers: [String: String]) async throws -> any RelaySocket {
        let registered = headers["X-Tsukumo-Public-Key"] != nil
        return CaptureSocket(first: #"{"type":"ready","device_id":"\#(Self.device)","public_base":"\#(Self.origin)/d/\#(Self.device)","registered":\#(registered)}"#)
    }
}

private final class CaptureSocket: RelaySocket, @unchecked Sendable {
    private let stream: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    init(first: String) {
        (stream, continuation) = AsyncStream<String>.makeStream()
        continuation.yield(first)
    }
    func send(_ text: String) async throws { if text == RelayEnvelope.ping { continuation.yield(#"{"type":"pong"}"#) } }
    func receive() async throws -> String {
        for await text in stream { return text }
        throw RelayClosed(code: 1000)
    }
    func close(code: Int) { continuation.finish() }
}

/// A stand-in on-device decision for the pictures: the second choice at `top`.
private struct CaptureDecider: DecisionProvider {
    let modelVersion = "Laya English · c5d7873"
    let top: Double
    func decide(_ request: DecisionRequest) async throws -> DecisionResult {
        DecisionResult(modelVersion: modelVersion, answers: request.questions.map {
            DecisionAnswer(questionID: $0.id, probabilities: [1 - top, top])
        }, calibrated: false, abstention: nil)
    }
}
#endif

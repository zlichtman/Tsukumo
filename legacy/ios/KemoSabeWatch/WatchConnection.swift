import Foundation
import Observation
import WatchConnectivity

/// Talks to KemoSabe on the paired iPhone. Only the latest exchange is kept, for display.
@MainActor @Observable final class WatchConnection: NSObject, WCSessionDelegate {
    enum Phase: Equatable { case idle, waiting, sending, thinking, answered, failed }
    private(set) var phase: Phase = .idle
    /// What the person said or typed, as the iPhone understood it.
    private(set) var heard = ""
    private(set) var reply = ""
    /// The latest answer as the iPhone would read it aloud.
    private(set) var spoken = ""
    /// The latest answer left something to review on the iPhone.
    private(set) var review = false
    private(set) var status = WatchLink.Status(model: "", ready: true)
    private(set) var reachable = false
    /// Whether the iPhone has shared its status at least once.
    private(set) var statusReceived = false
    /// Whether KemoSabe on the iPhone is set up: it has shared its status and finished onboarding.
    var phoneSetUp: Bool { statusReceived && status.setUp != false }
    /// Changes with each finished answer, for haptics and read-aloud.
    private(set) var answerRevision = 0
    @ObservationIgnored private var pending: WatchLink.Ask?
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private var polling: Task<Void, Never>?

    override init() {
        super.init()
        #if DEBUG
        status.palette = Self.debugPalette; status.theme = Self.debugTheme
        if ProcessInfo.processInfo.arguments.contains("--watch-palettes") { status.palettes = Self.debugPalettes }
        // The first-run screen without an iPhone: --phone-setup=yes or --phone-setup=no.
        if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--phone-setup=") }) {
            statusReceived = true; status.setUp = argument.hasSuffix("=yes")
        }
        #endif
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }
    var busy: Bool { [.waiting, .sending, .thinking].contains(phase) }
    func ask(text: String) { submit(WatchLink.Ask(text: text), heard: text.trimmingCharacters(in: .whitespacesAndNewlines)) }
    func ask(audio: Data, capture: Bool = false) { submit(WatchLink.Ask(audio: audio, capture: capture), heard: "") }
    func show(_ message: String) { fail(message) }
    /// A setting sent to the iPhone waiting for its answer, and the last problem changing one.
    private(set) var changing: WatchLink.Setting?
    private(set) var changeProblem: String?
    /// Sends a setting to the iPhone, which applies it and publishes the new status. The watch
    /// shows the choice right away and goes back if the iPhone doesn't take it.
    func change(_ setting: WatchLink.Setting) {
        let session = WCSession.default
        #if DEBUG
        // UI tests without an iPhone check the editor's result locally: --local-settings.
        if ProcessInfo.processInfo.arguments.contains("--local-settings") { return preview(setting) }
        #endif
        guard WCSession.isSupported(), session.activationState == .activated, session.isReachable else {
            changeProblem = Self.unreachable; return
        }
        guard let data = try? WatchLink.encode(WatchLink.Request.change(setting)) else { return }
        changing = setting; changeProblem = nil
        let before = status
        preview(setting)
        session.sendMessageData(data, replyHandler: { data in
            let reply = try? WatchLink.decode(WatchLink.Reply.self, from: data)
            Task { @MainActor in
                self.changing = nil
                if reply?.status != .answered { self.undo(setting, to: before); self.changeProblem = reply?.text ?? "Didn't change. Try again." }
            }
        }, errorHandler: { _ in
            Task { @MainActor in self.changing = nil; self.undo(setting, to: before); self.changeProblem = Self.unreachable }
        })
    }
    func clearChangeProblem() { changeProblem = nil }
    static let unreachable = "iPhone not reachable"
    private func preview(_ setting: WatchLink.Setting) {
        switch setting {
        case .model(let id): status.selectedModel = id
        case .palette(let id): if let palette = status.palettes?.first(where: { $0.id == id }) { status.palette = palette }
        case .personality(let raw): status.personality = raw
        }
    }
    private func undo(_ setting: WatchLink.Setting, to before: WatchLink.Status) {
        switch setting {
        case .model: status.selectedModel = before.selectedModel
        case .palette: status.palette = before.palette
        case .personality: status.personality = before.personality
        }
    }
    /// After the watch app wakes, collect an answer that may have arrived while it slept.
    func resume() {
        if phase == .thinking, let id = pending?.id { requestResult(id) }
    }
    /// Stops waiting for an iPhone that never received the request.
    func cancelWaiting() {
        guard phase == .waiting else { return }
        pending = nil; timeout?.cancel(); polling?.cancel(); phase = .idle; heard = ""; reply = ""; spoken = ""; review = false
    }

    private func submit(_ ask: WatchLink.Ask, heard: String) {
        if let problem = WatchLink.problem(with: ask) { return fail(problem) }
        pending = ask; self.heard = heard; reply = ""; spoken = ""; review = false
        timeout?.cancel()
        timeout = Task { [id = ask.id] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled, pending?.id == id else { return }
            if phase == .thinking {
                // The answer may be waiting on the iPhone after the watch slept.
                requestResult(id)
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, pending?.id == id else { return }
            }
            fail(phase == .waiting ? Self.unreachable : "Took too long. Try again.")
        }
        deliver()
    }
    /// Sends the pending request now, or waits until the iPhone is reachable.
    private func deliver() {
        guard let ask = pending else { return }
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated, session.isReachable else { phase = .waiting; return }
        guard let data = try? WatchLink.encode(WatchLink.Request.ask(ask)) else { return fail("Couldn't send that.") }
        phase = .sending
        session.sendMessageData(data, replyHandler: { data in
            let reply = try? WatchLink.decode(WatchLink.Reply.self, from: data)
            Task { @MainActor in self.receive(reply) }
        }, errorHandler: { error in
            let code = (error as? WCError)?.code
            Task { @MainActor in self.sendFailed(ask.id, code) }
        })
    }
    /// The iPhone pushes its answer, but a push can be lost, so ask for it too.
    private func poll(_ id: UUID) {
        polling?.cancel()
        polling = Task {
            var attempt = 0
            while !Task.isCancelled {
                // Check soon at first (most answers take a few seconds), then back off.
                attempt += 1
                try? await Task.sleep(for: .seconds(attempt <= 12 ? 1.5 : 4))
                guard !Task.isCancelled, pending?.id == id, phase == .thinking else { return }
                requestResult(id)
            }
        }
    }
    private func requestResult(_ id: UUID) {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable,
              let data = try? WatchLink.encode(WatchLink.Request.check(id)) else { return }
        session.sendMessageData(data, replyHandler: { data in
            let reply = try? WatchLink.decode(WatchLink.Reply.self, from: data)
            Task { @MainActor in self.receive(reply) }
        }, errorHandler: { _ in })
    }
    private func sendFailed(_ id: UUID, _ code: WCError.Code?) {
        guard pending?.id == id, phase == .sending else { return }
        switch code {
        case .notReachable: phase = .waiting
        case .companionAppNotInstalled: fail("Install KemoSabe on iPhone")
        case .payloadTooLarge: fail("Too long. Try a shorter one.")
        default: fail(Self.unreachable)
        }
    }
    private func receive(_ reply: WatchLink.Reply?) {
        guard let reply, reply.id == pending?.id else { return }
        if let heard = reply.heard, !heard.isEmpty { self.heard = heard }
        switch reply.status {
        case .received:
            if phase != .thinking { phase = .thinking; poll(reply.id) }
        case .answered:
            self.reply = reply.text; spoken = reply.spoken ?? reply.text; review = reply.review == true
            pending = nil; timeout?.cancel(); polling?.cancel()
            phase = .answered; answerRevision += 1
        case .failed: fail(reply.text)
        }
    }
    private func fail(_ message: String) {
        reply = message; spoken = ""; review = false; pending = nil; timeout?.cancel(); polling?.cancel(); phase = .failed
    }
    private func update(reachable: Bool, status data: Data?) {
        self.reachable = reachable
        #if DEBUG
        // UI tests that stand in for the iPhone keep their stand-in, even when a real iPhone
        // simulator is paired and sends its own status.
        if Self.standsInForPhone { return }
        #endif
        if let data, let status = try? WatchLink.decode(WatchLink.Status.self, from: data) {
            self.status = status
            statusReceived = true
            #if DEBUG
            // Simulator checks of the iPhone's look without the iPhone: --palette=<body>,<accent> and --theme=<background>,<accent>.
            self.status.palette = Self.debugPalette ?? status.palette
            self.status.theme = Self.debugTheme ?? status.theme
            #endif
        }
        if reachable, phase == .waiting { deliver() }
        if reachable { resume() }
    }

    #if DEBUG
    private static let standsInForPhone = ProcessInfo.processInfo.arguments.contains { $0 == "--watch-palettes" || $0.hasPrefix("--phone-setup=") }
    private static func debugColors(_ prefix: String) -> [String]? {
        ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }.map { $0.dropFirst(prefix.count).split(separator: ",").map(String.init) }
    }
    private static let debugPalette = debugColors("--palette=").flatMap { $0.count == 2 ? WatchLink.Palette(name: "Test", body: $0[0], accent: $0[1], tinted: true) : nil }
    private static let debugTheme = debugColors("--theme=").flatMap { $0.count == 2 ? WatchLink.Theme(background: $0[0], foreground: "FFFFFF", accent: $0[1]) : nil }
    /// A few palettes for the editor without an iPhone: --watch-palettes.
    private static let debugPalettes: [WatchLink.Palette] = [
        .init(id: "apricot", name: "Apricot", body: "F6E8D1", accent: "EF705B", tinted: false),
        .init(id: "mint", name: "Mint", body: "D7F2E3", accent: "2E9E6B", tinted: true),
        .init(id: "plum", name: "Plum", body: "E9DDF3", accent: "7A4FA3", tinted: true),
    ]
    #endif

    /// The pet game's numbers for your profile on the iPhone. The latest one waits until the
    /// session is active; the iPhone gets it whenever it next runs.
    private static var pendingPet: WatchLink.PetSummary?
    static func sharePet(_ summary: WatchLink.PetSummary) {
        pendingPet = summary
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              let data = try? WatchLink.encode(summary) else { return }
        try? WCSession.default.updateApplicationContext([WatchLink.petKey: data])
        pendingPet = nil
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let reachable = session.isReachable, data = session.receivedApplicationContext[WatchLink.statusKey] as? Data
        Task { @MainActor in
            self.update(reachable: reachable, status: data)
            if let pet = Self.pendingPet { Self.sharePet(pet) }
        }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.update(reachable: reachable, status: nil) }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let reachable = session.isReachable, data = applicationContext[WatchLink.statusKey] as? Data
        Task { @MainActor in self.update(reachable: reachable, status: data) }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let data = message[WatchLink.replyKey] as? Data
        Task { @MainActor in self.receive(data.flatMap { try? WatchLink.decode(WatchLink.Reply.self, from: $0) }) }
    }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let data = userInfo[WatchLink.replyKey] as? Data
        Task { @MainActor in self.receive(data.flatMap { try? WatchLink.decode(WatchLink.Reply.self, from: $0) }) }
    }
}

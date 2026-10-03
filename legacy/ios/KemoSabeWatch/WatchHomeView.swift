import SwiftUI
import WatchKit

/// Kemo fills the screen and is the button: tap it (or double tap) and talk, and
/// it sends when you pause. Your iPhone's model answers. Quick capture from the
/// complication, Siri, or the Action button opens straight into listening and
/// hands what you say to the iPhone as a note or task. Kemo is a little pet too:
/// each chat feeds it, and at rest it shows how it feels (`KemoPet`). Long-press
/// Kemo to customize it like a watch face (`WatchCharacterEditor`).
///
/// Clean and minimal (the owner's instruction, September 25, 2026): no model names,
/// no notes about where messages go, and errors as one short line.
struct WatchHomeView: View {
    @Environment(WatchConnection.self) private var connection
    @Environment(KemoPet.self) private var pet
    @Environment(WatchFirstRun.self) private var firstRun
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("readAloud") private var readAloud = true
    @State private var speaker = WatchSpeaker()
    @State private var recorder = WatchRecorder()
    @State private var recording = false
    @State private var capturing = false
    @State private var greeting = true
    @State private var quickTalk = QuickTalk.shared
    /// Customizing Kemo like a watch face; the tap that ends the long press doesn't start talking.
    @State private var editing = false

    var body: some View {
        NavigationStack {
            // Kemo's pet mood changes with the time of day, so look again each minute.
            TimelineView(.everyMinute) { clock in
                let petMood = pet.mood(at: clock.date)
                if !firstRun.done {
                    firstRunScreen.transition(.opacity)
                } else if editing {
                    WatchCharacterEditor(connection: connection) { withAnimation(.smooth) { editing = false } }
                        .transition(.opacity)
                } else {
                GeometryReader { geometry in
                    ScrollView {
                        VStack(spacing: 6) {
                            kemo(size: showingReply ? min(geometry.size.width * 0.34, 64) : min(geometry.size.width * 0.8, geometry.size.height * 0.72), petMood: petMood)
                            if !recording, !connection.busy {
                                vitals(pet.current(at: clock.date), mood: petMood, now: clock.date)
                            }
                            let line = statusLine
                            if !line.isEmpty {
                                Text(line)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .accessibilityIdentifier("watchStatus")
                            }
                            if !connection.heard.isEmpty {
                                Text("“\(connection.heard)”")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                    .multilineTextAlignment(.trailing)
                                    .padding(.horizontal, 8)
                                    .accessibilityIdentifier("watchHeard")
                            }
                            if !connection.reply.isEmpty {
                                Label {
                                    Text(connection.reply)
                                } icon: {
                                    if connection.phase == .failed { Image(systemName: "exclamationmark.circle") }
                                }
                                .labelStyle(ReplyLabelStyle())
                                .foregroundStyle(connection.phase == .failed ? Color.orange : Color.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .accessibilityIdentifier("watchReply")
                            }
                            if connection.review, connection.phase == .answered {
                                // Drafts, memory suggestions, and alarms are approved on the iPhone, never here.
                                Label {
                                    Text("Review on iPhone")
                                } icon: {
                                    Image(systemName: "iphone").foregroundStyle(style.readableAccent)
                                }
                                .font(.footnote)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .accessibilityIdentifier("watchReview")
                            }
                            if recording {
                                Button("Cancel", role: .cancel) { recorder.cancel(); recording = false; capturing = false }
                                    .accessibilityIdentifier("watchCancelRecording")
                            } else if connection.phase == .waiting {
                                Button("Stop waiting", role: .cancel) { connection.cancelWaiting() }
                                    .accessibilityIdentifier("watchStopWaiting")
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .top)
                    }
                }
                }
            }
            .containerBackground(style.background.gradient, for: .navigation)
            .toolbar {
                // Tap Kemo to talk; volume is on the side button, so Settings is the only control.
                if !editing && firstRun.done {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink { WatchSettingsView(connection: connection) } label: {
                            Image(systemName: "gearshape").foregroundStyle(style.readableAccent)
                        }.accessibilityLabel("Settings").accessibilityIdentifier("watchSettings")
                    }
                }
            }
        }
        .task {
            recorder.finishedSpeaking = { send() }
            if let name = connection.status.name { pet.named(name) }
            await pet.rescheduleNudges()
            try? await Task.sleep(for: .seconds(1.6))
            greeting = false
        }
        #if DEBUG
        .task {
            // Simulator check of the iPhone round trip: launch with --ask=<text>.
            guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ask=") }) else { return }
            try? await Task.sleep(for: .seconds(2))
            submit(text: String(argument.dropFirst("--ask=".count)))
        }
        #endif
        .onChange(of: connection.answerRevision) {
            // Every finished chat feeds Kemo; a quick hello is a snack.
            pet.feed(heard: connection.heard)
            WKInterfaceDevice.current().play(.success)
            if readAloud { speaker.speak(connection.spoken, voice: connection.status.voice) }
        }
        .onChange(of: connection.phase) {
            if connection.phase == .failed { WKInterfaceDevice.current().play(.failure) }
        }
        .onChange(of: connection.changeProblem) {
            // A change the iPhone didn't take shows for a moment under Kemo.
            guard connection.changeProblem != nil else { return }
            WKInterfaceDevice.current().play(.failure)
            Task { try? await Task.sleep(for: .seconds(4)); connection.clearChangeProblem() }
        }
        .onChange(of: quickTalk.request) { startFromShortcut() }
        .onChange(of: connection.status.name) { pet.named(connection.status.name ?? "KemoSabe") }
        .onOpenURL { url in
            // The complication opens straight into listening.
            if url.host == "talk" { talk() } else if url.host == "capture" { startCapture() }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active { connection.resume(); startFromShortcut() }
            guard scenePhase == .background else { return }
            // Using the app pushes the next nudge back; plan from now.
            Task { await pet.rescheduleNudges() }
            if recording { recorder.cancel(); recording = false; capturing = false }
            speaker.stop()
        }
    }

    /// Kemo, big, as the talk button. No rings around it: a small orb tucked under Kemo shows
    /// listening (it swells with your voice) and thinking.
    private func kemo(size: CGFloat, petMood: KemoVitals.Mood) -> some View {
        Button(action: talk) {
            ZStack {
                if recording {
                    TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
                        Rectangle().fill(style.readableAccent)
                            .mask { ThinkingOrb(state: .listening, size: .px64, theme: .dark, speed: 1.2, displaySize: 30) }
                            .frame(width: 30, height: 30).scaleEffect(0.9 + recorder.level * 0.35)
                    }
                    .frame(maxHeight: .infinity, alignment: .bottom).offset(y: 6)
                    .transition(.opacity).accessibilityHidden(true)
                } else if connection.busy {
                    Rectangle().fill(style.readableAccent)
                        .mask { ThinkingOrb(state: .working, size: .px64, theme: .dark, speed: 1.4, displaySize: 30) }
                        .frame(width: 30, height: 30)
                        .frame(maxHeight: .infinity, alignment: .bottom).offset(y: 6)
                        .transition(.opacity).accessibilityHidden(true)
                }
                // The frames have room around Kemo; scale it up to fill the circle.
                KemoFigure(mood: mood, pet: petMood, palette: connection.status.palette, name: name).scaleEffect(1.2)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // Long-press to customize Kemo, like a watch face.
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in beginEditing() })
        .disabled(connection.busy && !recording)
        .handGestureShortcut(.primaryAction)
        .animation(.smooth, value: showingReply)
        .accessibilityLabel(recording ? "Send" : "Talk to \(name)")
        .accessibilityAction(named: "Customize") { beginEditing() }
        .accessibilityIdentifier("watchTalk")
    }

    /// The first run: Kemo and one line. Until the iPhone is set up, "Finish setup on your iPhone";
    /// then "Tap Kemo to talk", where the first tap finishes the first run and starts talking.
    private var firstRunScreen: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width * 0.78, geometry.size.height * 0.7)
            VStack(spacing: 6) {
                if connection.phoneSetUp {
                    Button {
                        withAnimation(.smooth) { firstRun.finish() }
                        #if DEBUG
                        // UI tests check the screen without raising the microphone alert.
                        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return }
                        #endif
                        talk()
                    } label: {
                        KemoFigure(mood: .greeting, palette: connection.status.palette, name: name).scaleEffect(1.2)
                            .frame(width: size, height: size).contentShape(Circle())
                    }
                    .buttonStyle(.plain).handGestureShortcut(.primaryAction)
                    .accessibilityLabel("Talk to \(name)").accessibilityIdentifier("watchFirstRunTalk")
                    Text("Tap \(name) to talk").font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("watchFirstRunLine")
                } else {
                    KemoFigure(mood: .idle, palette: connection.status.palette).scaleEffect(1.2)
                        .frame(width: size, height: size)
                    Text("Finish setup on your iPhone").font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("watchFirstRunLine")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.smooth, value: connection.phoneSetUp)
        }
    }

    /// The companion's name: KemoSabe, or the name the person chose (never shortened, AGENTS.md rule 14).
    private var name: String { connection.status.name ?? "KemoSabe" }
    private var showingReply: Bool { !recording && !connection.reply.isEmpty }
    private var style: WatchStyle { WatchStyle(connection.status.theme) }
    private var mood: KemoFigure.Mood {
        if recording { return .listening }
        if connection.busy { return .thinking }
        if speaker.speaking { return .speaking }
        return greeting ? .greeting : .idle
    }
    /// Two tiny meters under Kemo, food and heart, in the accent color. No rings.
    /// Kemo's game at a glance: food and heart as four pips each (orange when low), its level
    /// with progress, and the days-in-a-row streak.
    private func vitals(_ vitals: KemoVitals, mood: KemoVitals.Mood, now: Date) -> some View {
        VStack(spacing: 4) {
            if let level = pet.leveledUp {
                Text("Level \(level)!").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(style.readableAccent)
                    .transition(.scale.combined(with: .opacity)).accessibilityIdentifier("watchLevelUp")
            }
            HStack(spacing: 10) {
                pips("fork.knife", vitals.fullness, low: vitals.fullness < KemoVitals.hungryBelow)
                pips("heart.fill", vitals.cheer, low: vitals.cheer < KemoVitals.lonelyBelow)
            }
            HStack(spacing: 8) {
                HStack(spacing: 3) {
                    ZStack {
                        Circle().stroke(Color.white.opacity(0.16), lineWidth: 2)
                        Circle().trim(from: 0, to: max(0.04, vitals.levelProgress)).stroke(style.readableAccent, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
                    }.frame(width: 11, height: 11)
                    Text("Lv \(vitals.level)")
                }
                let streak = vitals.streak(at: now)
                if streak > 0 { Text("🔥 \(streak)") }
            }.font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
        }
        .animation(.smooth(duration: 0.6), value: vitals.fullness)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(mood.word)
        .accessibilityValue("Fed \(Int((vitals.fullness * 100).rounded())) percent, cheer \(Int((vitals.cheer * 100).rounded())) percent, level \(vitals.level), \(vitals.streak(at: now))-day streak")
        .accessibilityIdentifier("watchVitals")
    }
    private func pips(_ symbol: String, _ value: Double, low: Bool) -> some View {
        let filled = Int((value * 4).rounded(.up))
        return HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            ForEach(0..<4, id: \.self) { index in
                Circle().fill(index < filled ? (low ? Color.orange : style.readableAccent) : Color.white.opacity(0.16)).frame(width: 6, height: 6)
            }
        }.foregroundStyle(low ? Color.orange : style.readableAccent)
    }
    /// One short line, only when there's something to say: the orb shows listening and
    /// thinking, the pips show how Kemo feels, and errors fit on one line.
    private var statusLine: String {
        if recording { return capturing ? "Note…" : "Listening…" }
        switch connection.phase {
        case .waiting: return "Waiting for iPhone…"
        case .sending, .thinking, .answered, .failed: return ""
        case .idle:
            if let problem = connection.changeProblem { return problem }
            return connection.reachable ? "" : WatchConnection.unreachable
        }
    }
    private func beginEditing() {
        guard !recording, !connection.busy else { return }
        speaker.stop()
        WKInterfaceDevice.current().play(.click)
        withAnimation(.smooth) { editing = true }
    }

    private func talk() {
        if recording { return send() }
        guard !connection.busy, !editing else { return }
        speaker.stop(); greeting = false; connection.clearChangeProblem()
        Task {
            guard await WatchRecorder.permission() else { return connection.show("Microphone is off.") }
            do {
                try recorder.start()
                recording = true
                WKInterfaceDevice.current().play(.start)
            } catch { connection.show(error.localizedDescription) }
        }
    }
    private func startCapture() { capturing = true; talk() }
    private func startFromShortcut() {
        guard let request = quickTalk.take() else { return }
        request == .capture ? startCapture() : talk()
    }
    private func send() {
        guard recording else { return }
        recording = false
        let capture = capturing; capturing = false
        guard let clip = recorder.finish() else { return connection.show("Too short. Try again.") }
        WKInterfaceDevice.current().play(.stop)
        connection.ask(audio: clip, capture: capture)
    }
    private func submit(text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        speaker.stop(); greeting = false
        WKInterfaceDevice.current().play(.click)
        connection.ask(text: text)
    }
}

/// Shows an icon only when there is one (a failure), aligned with the text's first line.
private struct ReplyLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}

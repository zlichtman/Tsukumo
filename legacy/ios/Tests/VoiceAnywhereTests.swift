import AppIntents
import XCTest
@testable import KemoSabe

/// Talk to Kemo from anywhere (the Action button, a Control, Siri) and in-app voice mode.
/// See design/KEMO-VOICE-ANYWHERE.md.
final class VoiceAnywhereTests: XCTestCase {

    // MARK: The turn's state machine

    func testATurnGoesFromListeningToTheSpokenReply() {
        var machine = VoiceAnywhereMachine()
        XCTAssertEqual(machine.phase, .listening)
        XCTAssertEqual(machine.line, "Listening")
        XCTAssertTrue(machine.handle(.level(0.5)))
        XCTAssertEqual(machine.level, 2)
        XCTAssertFalse(machine.handle(.level(0.45)), "The same step isn't a change, so no Live Activity update")
        XCTAssertTrue(machine.handle(.transcribing))
        XCTAssertEqual(machine.phase, .thinking)
        XCTAssertEqual(machine.level, 0)
        XCTAssertTrue(machine.handle(.answered(reply: "  You have two meetings.  ", heard: "What's on today?")))
        XCTAssertEqual(machine.phase, .speaking)
        XCTAssertEqual(machine.line, "You have two meetings.")
        XCTAssertEqual(machine.heard, "What's on today?")
        XCTAssertTrue(machine.handle(.word)); XCTAssertTrue(machine.mouthOpen)
        XCTAssertTrue(machine.handle(.word)); XCTAssertFalse(machine.mouthOpen)
        XCTAssertTrue(machine.handle(.finishedSpeaking))
        XCTAssertEqual(machine.phase, .answered)
        XCTAssertEqual(machine.line, "You have two meetings.", "The reply stays readable after it's spoken")
        XCTAssertTrue(machine.isFinished)
    }

    func testEventsOutOfOrderAreIgnored() {
        var machine = VoiceAnywhereMachine()
        XCTAssertFalse(machine.handle(.answered(reply: "Too early", heard: nil)), "No answer before the words were sent")
        XCTAssertFalse(machine.handle(.word))
        XCTAssertFalse(machine.handle(.finishedSpeaking))
        machine.handle(.transcribing)
        XCTAssertFalse(machine.handle(.level(0.9)), "The level doesn't move Kemo once it's thinking")
        XCTAssertFalse(machine.handle(.transcribing))
        machine.handle(.failed("iPhone not reachable"))
        XCTAssertEqual(machine.phase, .failed)
        let finished = machine
        for event: VoiceAnywhereMachine.Event in [.level(1), .transcribing, .answered(reply: "x", heard: nil), .word, .finishedSpeaking, .stop, .failed("again")] {
            XCTAssertFalse(machine.handle(event), "\(event) after the turn ended")
        }
        XCTAssertEqual(machine, finished)
    }

    func testSilenceAndStopEndTheTurnPlainly() {
        var silent = VoiceAnywhereMachine()
        silent.handle(.heardNothing)
        XCTAssertEqual(silent.phase, .failed)
        XCTAssertEqual(silent.line, "Didn't catch that. Try again.")

        var stoppedListening = VoiceAnywhereMachine()
        stoppedListening.handle(.stop)
        XCTAssertEqual(stoppedListening.phase, .failed)
        XCTAssertEqual(stoppedListening.line, "Stopped.")

        var stoppedSpeaking = VoiceAnywhereMachine()
        stoppedSpeaking.handle(.transcribing)
        stoppedSpeaking.handle(.answered(reply: "Here's the plan.", heard: nil))
        stoppedSpeaking.handle(.word)
        stoppedSpeaking.handle(.stop)
        XCTAssertEqual(stoppedSpeaking.phase, .answered, "Stop ends the voice; the reply stays")
        XCTAssertEqual(stoppedSpeaking.line, "Here's the plan.")
        XCTAssertFalse(stoppedSpeaking.mouthOpen)

        var empty = VoiceAnywhereMachine()
        empty.handle(.transcribing)
        empty.handle(.answered(reply: "   ", heard: "hello"))
        XCTAssertEqual(empty.phase, .failed, "An empty answer is never read aloud as silence")
        XCTAssertEqual(empty.line, "Couldn't finish that. Try again.")
    }

    func testLongRepliesAndWordsAreTrimmedForTheLiveActivity() {
        var machine = VoiceAnywhereMachine()
        machine.handle(.transcribing)
        machine.handle(.answered(reply: String(repeating: "word ", count: 400), heard: String(repeating: "a", count: 500)))
        XCTAssertLessThanOrEqual(machine.line.count, VoiceAnywhereMachine.maxLine)
        XCTAssertTrue(machine.line.hasSuffix("…"))
        XCTAssertEqual(machine.heard?.count, VoiceAnywhereMachine.maxHeard)
        var noWords = VoiceAnywhereMachine()
        noWords.handle(.transcribing)
        noWords.handle(.answered(reply: "Hi", heard: "  "))
        XCTAssertNil(noWords.heard, "Blank words aren't shown as a quote")
    }

    func testLevelSteps() {
        XCTAssertEqual(VoiceAnywhereMachine.step(0), 0)
        XCTAssertEqual(VoiceAnywhereMachine.step(0.1), 1)
        XCTAssertEqual(VoiceAnywhereMachine.step(0.4), 2)
        XCTAssertEqual(VoiceAnywhereMachine.step(0.95), 3)
        XCTAssertEqual(VoiceAnywhere.level(decibels: -.infinity), 0)
        XCTAssertEqual(VoiceAnywhere.level(decibels: -160), 0, accuracy: 0.001)
        XCTAssertEqual(VoiceAnywhere.level(decibels: 0), 1)
        XCTAssertGreaterThan(VoiceAnywhere.level(decibels: -20), VoiceAnywhere.level(decibels: -40))
    }

    // MARK: The Live Activity's content

    func testContentStateRoundTripsWithTheDefaultCoders() throws {
        // ActivityKit decodes updates with the default JSON strategies.
        var machine = VoiceAnywhereMachine()
        machine.handle(.level(0.7))
        machine.handle(.transcribing)
        machine.handle(.answered(reply: "Two meetings, then lunch with Sam.", heard: "What's on today?"))
        machine.handle(.word)
        let content = machine.content
        let data = try JSONEncoder().encode(content)
        let decoded = try JSONDecoder().decode(KemoVoiceAttributes.ContentState.self, from: data)
        XCTAssertEqual(decoded, content)
        XCTAssertEqual(decoded.phase, .speaking)
        XCTAssertEqual(decoded.heard, "What's on today?")
        XCTAssertTrue(decoded.mouthOpen)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["phase"] as? String, "speaking", "Phases encode as their plain names")
    }

    func testTheLargestUpdateStaysUnderActivityKitsLimit() throws {
        var machine = VoiceAnywhereMachine()
        machine.handle(.transcribing)
        // Emoji and accents are several bytes each in UTF-8.
        machine.handle(.answered(reply: String(repeating: "é🙂", count: 2000), heard: String(repeating: "🙂", count: 2000)))
        let attributes = KemoVoiceAttributes(name: String(repeating: "N", count: 40), body: "F6E8D2", accent: "EF705B", tinted: true,
                                             background: "211B2C", foreground: "FCFCFC", themeAccent: "EF705B")
        let size = try JSONEncoder().encode(machine.content).count + JSONEncoder().encode(attributes).count
        XCTAssertLessThan(size, 4096, "Static and dynamic data together must stay under 4 KB")
    }

    func testEachStateShowsAnApprovedFrame() {
        func state(_ phase: VoiceAnywherePhase, level: Int = 0, mouthOpen: Bool = false) -> KemoVoiceAttributes.ContentState {
            .init(phase: phase, line: "", level: level, mouthOpen: mouthOpen)
        }
        XCTAssertEqual(state(.listening).frame, "kemo-listening")
        XCTAssertEqual(state(.thinking).frame, "kemo-thinking")
        XCTAssertEqual(state(.speaking, mouthOpen: true).frame, "kemo-speaking-open")
        XCTAssertEqual(state(.speaking).frame, "kemo-speaking-closed")
        XCTAssertEqual(state(.answered).frame, "kemo-greeting")
        XCTAssertEqual(state(.failed).frame, "kemo-idle")
        XCTAssertEqual(state(.listening, level: 3).stretch, 0.054, accuracy: 0.0001)
        XCTAssertEqual(state(.thinking, level: 3).stretch, 0, "Only listening squashes and stretches")
        XCTAssertTrue(state(.speaking).isLive)
        XCTAssertFalse(state(.answered).isLive, "No Stop button once it's done")
        // Every frame the Live Activity names is one of the approved watch frames.
        let approved = ["kemo-idle", "kemo-blink", "kemo-listening", "kemo-thinking", "kemo-speaking-open", "kemo-speaking-closed", "kemo-greeting"]
        for phase in [VoiceAnywherePhase.listening, .thinking, .speaking, .answered, .failed] {
            XCTAssertTrue(approved.contains(state(phase).frame))
        }
    }

    // MARK: Ending a turn, routing, and updates

    func testTheEndpointerWaitsForAPauseAfterSpeech() {
        var endpointer = VoiceEndpointer()
        XCTAssertEqual(endpointer.feed(level: 0.02, at: 0.5), .keepListening)
        XCTAssertEqual(endpointer.feed(level: 0.4, at: 1.0), .keepListening)
        XCTAssertEqual(endpointer.feed(level: 0.03, at: 1.8), .keepListening, "A short pause between words")
        XCTAssertEqual(endpointer.feed(level: 0.5, at: 2.0), .keepListening)
        XCTAssertEqual(endpointer.feed(level: 0.02, at: 3.0), .keepListening)
        XCTAssertEqual(endpointer.feed(level: 0.02, at: 3.4), .finished)

        var quiet = VoiceEndpointer()
        XCTAssertEqual(quiet.feed(level: 0.05, at: 6.9), .keepListening)
        XCTAssertEqual(quiet.feed(level: 0.05, at: 7.0), .heardNothing)

        var long = VoiceEndpointer()
        for second in stride(from: 0.0, to: 30, by: 0.5) { _ = long.feed(level: 0.6, at: second) }
        XCTAssertEqual(long.feed(level: 0.6, at: 30), .finished, "One clip is at most 30 seconds")
    }

    func testRoutingNeverListensWithoutPermissionAndFollowsTheLockedRules() {
        func route(active: Bool = false, mic: Bool = true, speech: Bool = true, activities: Bool = true,
                   locked: Bool = false, ready: Bool = false) -> VoiceAnywhereRoute {
            .decide(appActive: active, microphoneAllowed: mic, speechAllowed: speech,
                    liveActivitiesAllowed: activities, locked: locked, lockedAnswerReady: ready)
        }
        XCTAssertEqual(route(), .background)
        XCTAssertEqual(route(active: true), .inApp, "An open app uses its own voice mode")
        XCTAssertEqual(route(mic: false), .openToAllow)
        XCTAssertEqual(route(speech: false), .openToAllow)
        XCTAssertEqual(route(mic: false, locked: true), .openToAllow)
        XCTAssertEqual(route(locked: true), .unlockFirst, "Locked with no working set: unlock first")
        XCTAssertEqual(route(locked: true, ready: true), .background, "Locked with a working set: LockedWatchMode answers")
        XCTAssertEqual(route(activities: false), .inApp, "No background recording without a Live Activity")
    }

    func testLiveActivityUpdatesAreThrottledButNeverLoseAPhase() {
        var throttle = LiveActivityThrottle()
        XCTAssertTrue(throttle.allows(phase: .listening, line: "Listening", at: 0))
        XCTAssertFalse(throttle.allows(phase: .listening, line: "Listening", at: 0.1), "A level change waits")
        XCTAssertEqual(throttle.wait(at: 0.1), 0.25, accuracy: 0.0001)
        XCTAssertTrue(throttle.allows(phase: .listening, line: "Listening", at: 0.36))
        XCTAssertTrue(throttle.allows(phase: .thinking, line: "Thinking…", at: 0.4), "A new phase goes out at once")
        XCTAssertTrue(throttle.allows(phase: .speaking, line: "Hi", at: 0.41))
        XCTAssertFalse(throttle.allows(phase: .speaking, line: "Hi", at: 0.5), "Mouth changes wait")
        XCTAssertTrue(throttle.allows(phase: .answered, line: "Hi", at: 0.5))
    }

    func testWatchLinesReadRightOnTheIPhone() {
        XCTAssertEqual(VoiceAnywhereText.phoneLine("Open KemoSabe on iPhone."), "Open KemoSabe to finish setting up.")
        XCTAssertEqual(VoiceAnywhereText.phoneLine("Not ready. Open KemoSabe on iPhone."), "Open KemoSabe to finish setting up.")
        XCTAssertEqual(VoiceAnywhereText.phoneLine("Allow speech in KemoSabe on iPhone."), "Allow speech recognition in KemoSabe.")
        XCTAssertEqual(VoiceAnywhereText.phoneLine("Unlock your iPhone to answer."), "Unlock your iPhone to answer.")
        XCTAssertEqual(VoiceAnywhereText.phoneLine("Busy. Try again in a moment."), "Busy. Try again in a moment.")
    }

    // MARK: Intents

    func testTalkToKemoStartsInTheBackgroundAndCanContinueInTheApp() {
        XCTAssertTrue(TalkToKemoIntent.supportedModes.contains(.background))
        XCTAssertTrue(TalkToKemoIntent.supportedModes.contains(.foreground(.dynamic)))
        XCTAssertEqual(AskKemoIntent.supportedModes, .background)
        XCTAssertFalse(StopTalkingToKemoIntent.isDiscoverable, "Stop only appears on the Live Activity")
    }

    @MainActor func testTheCompanionEntityUsesTheChosenName() async throws {
        let settings = AccountDirectory.accountSettings
        let saved = settings.string(forKey: CompanionIdentity.key)
        defer { settings.set(saved, forKey: CompanionIdentity.key) }
        settings.removeObject(forKey: CompanionIdentity.key)
        XCTAssertEqual(CompanionEntity.current.name, "KemoSabe", "The default name is spoken in full, never shortened")
        settings.set("Mochi", forKey: CompanionIdentity.key)
        XCTAssertEqual(CompanionEntity.current.name, "Mochi")
        let suggested = try await CompanionQuery().suggestedEntities()
        XCTAssertEqual(suggested.map(\.name), ["Mochi"])
        let found = try await CompanionQuery().entities(for: ["companion", "other"])
        XCTAssertEqual(found.map(\.id), ["companion"])
    }

    @MainActor func testAnInAppRequestIsTakenOnce() {
        let anywhere = VoiceAnywhere()
        XCTAssertFalse(anywhere.takeInAppRequest())
        anywhere.requestInApp()
        XCTAssertEqual(anywhere.inAppRequests, 1)
        XCTAssertTrue(anywhere.takeInAppRequest())
        XCTAssertFalse(anywhere.takeInAppRequest())
        XCTAssertFalse(anywhere.running)
    }

    // MARK: In-app voice mode

    func testVoiceModeShowsWhileTalkingAndSettlesWhenQuiet() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        var presence = VoiceModePresence()
        presence.observe(VoiceModeInput(phase: .off), at: start)
        XCTAssertFalse(presence.isVisible(.off, at: start))
        // Turning the microphone on isn't talking: the composer shows listening, not voice mode.
        presence.observe(VoiceModeInput(phase: .listening), at: start)
        XCTAssertFalse(presence.isVisible(.listening, at: start + 1))
        // Speaking brings it up and keeps it up.
        presence.observe(VoiceModeInput(phase: .listening, level: 0.5), at: start + 2.9)
        XCTAssertTrue(presence.isVisible(.listening, at: start + 5))
        XCTAssertFalse(presence.isVisible(.listening, at: start + 2.9 + VoiceModePresence.linger + 0.1), "It settles back when you stop")
        presence.observe(VoiceModeInput(phase: .listening, level: 0.02, heard: "What's on"), at: start + 5.5)
        XCTAssertTrue(presence.isVisible(.listening, at: start + 8), "New words count as talking")
        // Kemo's thinking and reply to what you said keep it up; the quiet after the reply settles it.
        presence.observe(VoiceModeInput(phase: .thinking), at: start + 9)
        XCTAssertTrue(presence.isVisible(.thinking, at: start + 60))
        presence.observe(VoiceModeInput(phase: .speaking, wordMarker: 4), at: start + 10)
        XCTAssertTrue(presence.isVisible(.speaking, at: start + 60))
        presence.observe(VoiceModeInput(phase: .speaking, wordMarker: 20), at: start + 11.9)
        // The recognizer restarting between turns doesn't end the exchange.
        presence.observe(VoiceModeInput(phase: .starting), at: start + 12)
        XCTAssertTrue(presence.isVisible(.starting, at: start + 12.5))
        presence.observe(VoiceModeInput(phase: .listening), at: start + 12.6)
        XCTAssertTrue(presence.isVisible(.listening, at: start + 13))
        XCTAssertFalse(presence.isVisible(.listening, at: start + 11.9 + VoiceModePresence.linger + 0.1), "It settles after the last word")
        // Turning the microphone off settles it at once.
        presence.observe(VoiceModeInput(phase: .off), at: start + 13)
        XCTAssertFalse(presence.isVisible(.off, at: start + 13))
        XCTAssertNil(presence.settlesAt)
    }

    /// A typed message turns the microphone off while you type; the reply (or a typed command's
    /// spoken answer) never brings voice mode up.
    func testTypedTurnsNeverStartVoiceMode() {
        let start = Date(timeIntervalSinceReferenceDate: 2000)
        var presence = VoiceModePresence()
        presence.observe(VoiceModeInput(phase: .listening), at: start)
        presence.observe(VoiceModeInput(phase: .off), at: start + 1)
        presence.observe(VoiceModeInput(phase: .starting), at: start + 4)
        presence.observe(VoiceModeInput(phase: .listening), at: start + 4.2)
        presence.observe(VoiceModeInput(phase: .speaking, wordMarker: 0), at: start + 5)
        XCTAssertFalse(presence.isVisible(.speaking, at: start + 5))
        presence.observe(VoiceModeInput(phase: .thinking), at: start + 6)
        XCTAssertFalse(presence.isVisible(.thinking, at: start + 6))
        // Even straight after a spoken exchange, typing (which turns the microphone off) ends it.
        presence.observe(VoiceModeInput(phase: .listening, level: 0.6, heard: "Hello"), at: start + 7)
        XCTAssertTrue(presence.isVisible(.listening, at: start + 7))
        presence.observe(VoiceModeInput(phase: .off), at: start + 8)
        presence.observe(VoiceModeInput(phase: .thinking), at: start + 8.5)
        XCTAssertFalse(presence.isVisible(.thinking, at: start + 8.5))
    }

    @MainActor func testVoiceModeStateSettlesOnItsOwn() async throws {
        let state = VoiceModeState()
        let start = Date()
        state.update(VoiceModeInput(phase: .listening, level: 0.6), now: start.addingTimeInterval(-(VoiceModePresence.linger - 0.2)))
        XCTAssertTrue(state.visible)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(state.visible, "Settles when the linger runs out, without another update")
        state.update(VoiceModeInput(phase: .listening, level: 0.6))
        state.update(VoiceModeInput(phase: .speaking))
        XCTAssertTrue(state.visible)
        state.update(VoiceModeInput(phase: .off))
        XCTAssertFalse(state.visible)
    }

    // MARK: One signal per state

    func testEachChatStateHasOneSignal() {
        // At rest with the big Kemo shown: Kemo on the chat, nothing in the corner or the composer.
        let rest = ChatSignals(onChat: true, bigKemo: true, voiceMode: false, listening: false, working: false)
        XCTAssertEqual(rest.stage, .performance)
        XCTAssertFalse(rest.headerStatus); XCTAssertFalse(rest.composerListening); XCTAssertFalse(rest.voiceBand)
        // At rest with it hidden: no Kemo on the chat (the corner still shows it).
        XCTAssertEqual(ChatSignals(onChat: true, bigKemo: false, voiceMode: false, listening: false, working: false).stage, .none)

        // Thinking on Chat: the transcript's row alone, so the corner says nothing.
        for bigKemo in [true, false] {
            let thinking = ChatSignals(onChat: true, bigKemo: bigKemo, voiceMode: false, listening: false, working: true)
            XCTAssertFalse(thinking.headerStatus)
            XCTAssertFalse(thinking.composerListening, "The microphone isn't a thinking indicator")
            XCTAssertEqual(thinking.stage, bigKemo ? .performance : .none)
        }
        // Thinking on another tab: the corner is the one place that says so.
        let away = ChatSignals(onChat: false, bigKemo: true, voiceMode: true, listening: false, working: true)
        XCTAssertTrue(away.headerStatus)
        XCTAssertEqual(away.stage, .none, "Nothing plays over another tab")

        // Listening: only the composer.
        let listening = ChatSignals(onChat: true, bigKemo: true, voiceMode: false, listening: true, working: false)
        XCTAssertTrue(listening.composerListening)
        XCTAssertFalse(listening.headerStatus, "No Listening in the header while the composer says it")

        // Voice mode: the big Kemo plays it in place, or a band pushes the chat down; never both, never floating.
        let inPlace = ChatSignals(onChat: true, bigKemo: true, voiceMode: true, listening: true, working: false)
        XCTAssertEqual(inPlace.stage, .voice); XCTAssertFalse(inPlace.voiceBand)
        let band = ChatSignals(onChat: true, bigKemo: false, voiceMode: true, listening: true, working: true)
        XCTAssertEqual(band.stage, .voice); XCTAssertTrue(band.voiceBand)
        XCTAssertFalse(band.headerStatus)
    }

    func testVoiceModePoseFollowsTheVoice() {
        let quiet = VoiceModePose.pose(phase: .listening, time: 1, level: 0, heard: "", sinceWord: nil, reducedMotion: false)
        let loud = VoiceModePose.pose(phase: .listening, time: 1, level: 0.9, heard: "", sinceWord: nil, reducedMotion: false)
        XCTAssertGreaterThan(loud.stretch, quiet.stretch, "Taller with your voice")
        XCTAssertLessThan(quiet.stretch, 0.01, "A little squat between words")
        XCTAssertLessThanOrEqual(loud.stretch, 0.05, "Gentle")
        XCTAssertLessThan(loud.y, quiet.y, "Rises a little with your voice")

        let start = VoiceModePose.gaze(following: "What")
        let later = VoiceModePose.gaze(following: String(repeating: "word ", count: 12))
        XCTAssertGreaterThan(start.y, 0, "Looks down at the message box")
        XCTAssertGreaterThan(later.x, start.x, "Eyes move along your words")

        let onWord = VoiceModePose.pose(phase: .speaking, time: 1, level: 0, heard: "", sinceWord: 0, reducedMotion: false)
        let afterWord = VoiceModePose.pose(phase: .speaking, time: 1, level: 0, heard: "", sinceWord: 0.5, reducedMotion: false)
        XCTAssertGreaterThan(onWord.mouth, 0.8, "The mouth opens on each spoken word")
        XCTAssertLessThan(afterWord.mouth, 0.2)

        let still = VoiceModePose.pose(phase: .listening, time: 3, level: 1, heard: "Hello there", sinceWord: nil, reducedMotion: true)
        XCTAssertEqual(still.stretch, 0); XCTAssertEqual(still.gaze, .zero); XCTAssertEqual(still.y, 0)
        XCTAssertEqual(VoiceModePose.performance(for: .speaking), .speaking)
        XCTAssertEqual(VoiceModePose.performance(for: .thinking), .thinking)
        XCTAssertEqual(VoiceModePose.performance(for: .listening), .listening)
    }
}

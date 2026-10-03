import Foundation
import CoreGraphics

/// Explicit choreography coverage. A catalog entry never silently becomes idle.
enum ArtworkPerformance: String, CaseIterable {
    case idle, greeting, listening, understood, thinking, remembering, recalling, speaking, asking, corrected
    case writing, reading, outlining, idea, revising, sources, comparing, handoff
    case beat, sway, groove, dance, breakdown, track, volume
    case musicPause = "music-pause"
    case research, calculating, coding, organizing, standup, reviewing, executing, done
    case focus, interrupted, waiting, problem, resting, waking, journaling, sketching, proofreading
    case debugging, testing, codeReview = "code-review", deploying, emailDraft = "email-draft", calendarPlanning = "calendar-planning"
    case filing, searchingFiles = "searching-files", bookmarking, pageTurn = "page-turn", recipe
    case headphoneListen = "headphone-listen", drumming, conducting, teaBreak = "tea-break", sipping, countdown, breathing, stretching

    case dj, piano
    enum Rig { case companion, notebook, book, computer, musicDesk }
    enum Prop: String { case none, headphones, computer, files, mug, timer }
    var prop: Prop {
        if rig == .computer { return .computer }
        switch self {
        case .beat, .sway, .groove, .dance, .breakdown, .track, .volume, .musicPause, .headphoneListen, .drumming, .conducting: return .headphones
        case .organizing, .filing, .searchingFiles, .recalling: return .files
        case .teaBreak, .sipping: return .mug
        case .countdown, .focus: return .timer
        default: return .none
        }
    }
    var rig: Rig {
        switch self {
        case .dj, .piano, .drumming: return .musicDesk
        case .writing, .outlining, .revising, .standup, .journaling, .sketching, .proofreading: return .notebook
        case .reading, .handoff, .bookmarking, .pageTurn, .recipe: return .book
        case .coding, .executing, .debugging, .testing, .codeReview, .deploying, .emailDraft, .calendarPlanning,
             .sources, .comparing, .research, .reviewing, .calculating: return .computer
        default: return .companion
        }
    }

    /// Turn one-shot reactions into deliberate phrases with a quiet tail. Their
    /// loop boundary must not snap the face or a hand back to its first pose.
    var isReaction: Bool {
        switch self {
        case .greeting,.understood,.remembering,.corrected,.idea,.done,.interrupted,.waking,.stretching: return true
        default: return false
        }
    }

    struct Pose {
        var x = 0.0, y = 0.0, tilt = 0.0, stretch = 0.0
        var left = CGPoint.zero, right = CGPoint.zero
        var leftAngle = 0.0, rightAngle = 0.0
        var gaze = CGPoint.zero
        var eyelids = 0.0, mouth = 0.0
    }

    func pose(at elapsed: Double, bpm: Double = 100, level: Double = 0, reducedMotion: Bool = false) -> Pose {
        guard !reducedMotion else { return Pose() }
        let t = isReaction ? min(12, max(0, elapsed)) : max(0, elapsed).truncatingRemainder(dividingBy: 12)
        let b = max(0, elapsed) * min(180, max(60, bpm)) / 60 * .pi * 2
        func wave(_ frequency: Double) -> Double { sin(max(0, elapsed) * frequency) }
        func cue(_ start: Double, _ end: Double) -> Double {
            guard t > start, t < end else { return 0 }
            return pow(sin((t - start) / (end - start) * .pi), 2)
        }
        var p = Pose()
        p.stretch = wave(1.65) * 0.004
        switch self {
        case .dj, .piano:
            p.stretch = 0; p.gaze.y = 0.012; p.tilt = sin(b/4)*0.018
        case .idle: p.left.y = wave(1.65) * 0.001
        case .greeting:
            let a = cue(0, 3.6); p.right = CGPoint(x: 0.045*a, y: -0.16*a)
            p.rightAngle = a * (0.25 + sin(t*10)*0.20); p.tilt = -0.045*a
        case .listening:
            p.tilt = 0.04; p.stretch += 0.012 + min(1, max(0, level))*0.012
            p.right = CGPoint(x: 0.012, y: -0.025); p.gaze.y = -0.003
        case .understood:
            let nod = cue(0.3, 1.1) + cue(1.3, 2.1); p.y = nod*0.012; p.stretch -= nod*0.025
            p.left.y = -0.02*cue(2, 3.6)
        case .thinking:
            p.right = CGPoint(x: -0.065, y: -0.12); p.rightAngle = -0.30
            p.tilt = -0.035; p.gaze = CGPoint(x: -0.008, y: -0.009)
        case .remembering:
            // A brief acknowledgment, not a perpetual filing performance.
            // Callers must select this only after persistence succeeds.
            let nod = cue(0.15, 1.1)
            p.y = nod*0.008; p.eyelids = nod*0.20
            p.right.y = -0.016*cue(0.7, 1.8)
        case .recalling:
            p.gaze = CGPoint(x: 0.010*cue(0, 4), y: -0.015*cue(0, 4))
            p.right.y = -0.12*cue(3, 6); p.rightAngle = -0.3*cue(3, 6)
        case .speaking:
            p.mouth = 0.2 + abs(wave(10.7))*0.7
            p.left = CGPoint(x: -0.018*cue(0, 3), y: -0.05*cue(0, 3))
            p.right = CGPoint(x: 0.015*cue(3, 6), y: -0.045*cue(3, 6)); p.tilt = wave(1.2)*0.012
        case .asking:
            p.tilt = 0.07*cue(0, 6); p.left.x = -0.025*cue(0, 6); p.right.x = 0.025*cue(0, 6)
            p.left.y = -0.035*cue(0, 6); p.right.y = p.left.y
        case .corrected:
            p.gaze.y = 0.012*cue(0, 3); p.eyelids = 0.6*cue(0, 3)
            p.stretch -= 0.015*cue(3, 4); p.right.y = -0.025*cue(4, 6)
        case .idea:
            let a = cue(1, 5); p.stretch += 0.025*a; p.right.y = -0.19*a; p.rightAngle = -0.22*a
        case .beat: p.stretch -= (1-cos(b))*0.008; p.y = (1-cos(b))*0.003
        case .sway: p.tilt = sin(b/4)*0.055; p.x = sin(b/4)*0.018
        case .groove:
            // Head bob on every beat, a sway every two, a squash on the downbeat,
            // happy half-closed eyes, and paws tapping in turn.
            let bob = abs(sin(b/2))
            p.y = -bob*0.038; p.tilt = sin(b/2)*0.065; p.x = sin(b/4)*0.012
            p.stretch += (bob - 0.5)*0.035; p.eyelids = 0.55
            p.left.y = -max(0,sin(b))*0.065; p.right.y = -max(0,-sin(b))*0.065
            p.leftAngle = max(0,sin(b))*0.18; p.rightAngle = -max(0,-sin(b))*0.18
        case .dance:
            p.x = sin(b/2)*0.035; p.y = -abs(sin(b))*0.026; p.tilt = sin(b/2)*0.08
            p.left = CGPoint(x: -0.04, y: -0.07-max(0,sin(b/2))*0.07)
            p.right = CGPoint(x: 0.04, y: -0.07-max(0,-sin(b/2))*0.07)
            p.leftAngle = sin(b)*0.3; p.rightAngle = -sin(b)*0.3
        case .breakdown:
            let a = (1+sin(b/8))/2; p.tilt = sin(b/2)*0.065*a
            p.y = -abs(sin(b))*0.02*a; p.left.y = -0.1*a; p.right.y = -0.1*a
        case .track:
            let a = cue(0, 5); p.tilt = sin(b/4)*0.028; p.gaze.x = 0.008*a
            p.right = CGPoint(x: 0.13*a, y: -0.20*a)
            p.rightAngle = -0.15*a
        case .musicPause:
            let settle = exp(-max(0,elapsed)*2); p.tilt = sin(b/2)*0.05*settle; p.y = -abs(sin(b))*0.02*settle
        case .volume:
            let a = MotionBeat.hold(t,from:0.5,to:7)
            p.right = CGPoint(x: 0.13*a, y: -0.20*a)
            p.rightAngle = (-0.2+sin(t*2)*0.10)*a; p.tilt = sin(b/4)*0.015
        case .organizing, .filing, .searchingFiles:
            p.left = CGPoint(x: -0.04*cue(0, 3), y: -0.045*cue(0, 3))
            p.right = CGPoint(x: 0.04*cue(3, 6), y: -0.045*cue(3, 6))
            p.gaze.x = -0.008*cue(0, 3)+0.008*cue(3, 6)
            if self == .filing { let lift=MotionBeat.hold(elapsed,from:1,to:7); p.right = CGPoint(x: -0.065*lift, y: -0.10*lift) }
            if self == .searchingFiles { p.gaze.x = sin(t*2)*0.012; p.left.y = -0.08*cue(2, 5) }
        case .done:
            // Two happy hops with paws up, then a proud settle.
            let a = cue(0, 4), hop = abs(sin(max(0, t - 0.3) * .pi * 1.6)) * cue(0.3, 2.8)
            p.y = -0.03*a - 0.045*hop; p.stretch += 0.02*hop
            p.left.y = -0.17*a; p.right.y = -0.17*a
            p.left.x = -0.04*a; p.right.x = 0.04*a; p.leftAngle = 0.25*a; p.rightAngle = -0.25*a
            p.eyelids = 0.3*a
        case .focus: p.eyelids = 0.15; p.stretch = wave(1.1)*0.002
        case .interrupted:
            p.stretch += 0.025*cue(0, 1.2); p.right.y = -0.05*cue(0, 2); p.tilt = -0.04*cue(0, 2)
        case .waiting:
            p.left.x = 0.015; p.right.x = -0.015; p.right.y = -0.007*cue(3, 5); p.gaze.x = 0.005*cue(4, 7)
        case .problem:
            p.tilt = sin(t*3)*0.025*cue(0, 3); p.left = CGPoint(x: -0.025, y: -0.03)
            p.right = CGPoint(x: 0.025, y: -0.03); p.eyelids = 0.35
        case .resting:
            p.eyelids = 0.97; p.stretch = wave(0.8)*0.008; p.left.x = 0.025; p.right.x = -0.025
        case .waking:
            let a = cue(0, 5); p.eyelids = max(0,1-t/3)*0.97
            p.left = CGPoint(x: -0.05*a, y: -0.17*a); p.right = CGPoint(x: 0.05*a, y: -0.17*a)
            p.stretch += 0.03*a
        case .coding, .executing, .debugging, .testing, .codeReview, .deploying, .emailDraft, .calendarPlanning,
             .sources, .comparing, .research, .reviewing, .calculating:
            // The workstation owns contact timing; the character looks toward it.
            p.stretch = 0; p.gaze = CGPoint(x: 0.01, y: 0.012)
            if self == .debugging { p.tilt = -0.03*cue(3, 8) }
            if self == .testing { p.eyelids = 0.18*cue(3, 6) }
            if self == .deploying { p.left.y = -0.10*cue(8, 11) }
        case .writing, .outlining, .revising, .standup, .journaling, .sketching, .proofreading:
            p.stretch = 0; p.gaze.y = 0.012
        case .reading, .handoff, .bookmarking, .pageTurn, .recipe:
            p.stretch = 0
            let rate = self == .recipe ? 0.55 : 1.0
            p.gaze = CGPoint(x: sin(max(0, elapsed)*rate)*0.006, y: 0.012)
        case .headphoneListen:
            // Eyes closed, one paw on the ear cup, nodding along.
            p.eyelids = 0.85; p.tilt = sin(b/4)*0.045; p.y = -abs(sin(b/2))*0.014
            p.right = CGPoint(x: 0.13, y: -0.20 + sin(b)*0.008); p.rightAngle = -0.2 + sin(b/2)*0.05
        case .drumming:
            p.left.y = -0.06*pow(max(0,sin(b)),2); p.right.y = -0.07*pow(max(0,-sin(b)),2)
            p.tilt = sin(b/2)*0.012; p.gaze.y = 0.008
        case .conducting:
            p.left = CGPoint(x: -0.055+sin(b/4)*0.035, y: -0.10+cos(b/2)*0.045)
            p.right = CGPoint(x: 0.055-sin(b/4)*0.035, y: -0.10-cos(b/2)*0.045)
            p.leftAngle = sin(b/4)*0.4; p.rightAngle = -sin(b/4)*0.4
        case .teaBreak: p.gaze.y = 0.012; p.left.x = 0.018; p.right.x = -0.018
        case .sipping:
            // The mug comes up to the mouth; eyes close for the sip.
            let lift = MotionBeat.hold(elapsed, from: 2, to: 6)
            p.eyelids = min(1, 1.25*cue(2.4, 6.6)); p.gaze.y = 0.01; p.left.x = 0.004; p.right.x = -0.004
            p.left.y = -lift*0.14; p.right.y = p.left.y; p.tilt = -0.02*lift
        case .countdown: p.gaze.y = 0.015; p.right.y = -0.035*cue(0, 2)
        case .breathing:
            p.eyelids = 0.85; p.stretch = sin(elapsed * .pi/4)*0.027
            p.left.x = -0.012*(1+sin(elapsed * .pi/4)); p.right.x = -p.left.x
        case .stretching:
            let a = cue(1, 10); p.left = CGPoint(x: -0.10*a, y: -0.24*a)
            p.right = CGPoint(x: 0.10*a, y: -0.24*a); p.tilt = sin(t*0.7)*0.035*a; p.stretch = 0.02*a
        }
        // Smooth admission and return, including formerly abrupt static poses.
        // Music uses its continuous beat clock rather than a 12s amplitude reset.
        if prop != .headphones && rig == .companion {
            let entry = MotionBeat.smooth(t/0.55)
            let exit = MotionBeat.smooth((12-t)/0.75)
            let envelope = entry*exit
            p.left.x *= envelope; p.left.y *= envelope
            p.right.x *= envelope; p.right.y *= envelope
            p.leftAngle *= envelope; p.rightAngle *= envelope
            p.tilt *= envelope; p.x *= envelope; p.y *= envelope
            if isReaction { p.eyelids *= envelope; p.stretch *= envelope }
        }
        return p
    }
}

/// What Kemo looks like it's doing while it works on a request, chosen from the
/// request's words: a draft is writing, a note is filing, a plan is the calendar.
/// It's only a picture of the work; the model decides what actually happens.
enum TaskActivity {
    /// What Kemo performs right now: the one you asked for, or, while it works on a
    /// reply with nothing requested, the task it's working on. Shared by iPhone and Mac.
    @MainActor static func live(_ requested: String, store: AppStore) -> String {
        // Reading this device for another agent's question (a chat hand-off): Kemo researches.
        if store.localLookup != nil, requested == "idle" { return ArtworkPerformance.research.rawValue }
        guard store.isThinking, requested == "idle" else { return requested }
        return performance(for: store.conversationMessages.last { $0.role == "You" }?.text ?? "").rawValue
    }
    static func performance(for request: String) -> ArtworkPerformance {
        let words = " " + VoiceTurnPolicy.normalized(request) + " "
        func says(_ cues: [String]) -> Bool { cues.contains { words.contains(" \($0) ") } }
        if says(["remember", "note that", "save", "don t forget", "keep in mind"]) { return .filing }
        if says(["remind", "reminder", "alarm", "timer", "wake me", "focus", "pomodoro"]) { return .focus }
        if says(["calendar", "schedule", "plan", "meeting", "tomorrow", "week", "agenda", "day"]) { return .calendarPlanning }
        if says(["email", "reply", "respond to"]) { return .emailDraft }
        if says(["write", "draft", "caption", "post", "poem", "story", "letter", "essay", "outline", "note"]) { return .writing }
        if says(["code", "coding", "bug", "function", "swift", "python", "javascript", "debug", "app"]) { return .coding }
        if says(["calculate", "math", "plus", "minus", "times", "divided", "percent", "sum", "budget"]) || request.contains(where: { "+*/=%".contains($0) }) { return .calculating }
        if says(["song", "music", "playlist", "album", "artist", "listen", "beat"]) { return .groove }
        if says(["read", "summarize", "summary", "article", "book", "explain"]) { return .reading }
        if says(["research", "find", "look up", "search", "compare", "best", "recommend"]) { return .research }
        return .thinking
    }
    /// A short line for the working indicator.
    static func label(for request: String) -> String {
        switch performance(for: request) {
        case .filing: "Filing that away…"
        case .focus: "Setting that up…"
        case .calendarPlanning: "Looking at your day…"
        case .emailDraft, .writing: "Writing…"
        case .coding: "Working through the code…"
        case .calculating: "Working it out…"
        case .groove: "Thinking about music…"
        case .reading: "Reading…"
        case .research: "Looking into it…"
        default: "Thinking…"
        }
    }
}

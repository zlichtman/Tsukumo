import SwiftUI

/// Shared timing primitives, not interchangeable performances. All prop contact
/// and display cues use the same clock; no independent repeating animations.
enum MotionBeat {
    static func smooth(_ x: Double) -> Double { let x = min(1, max(0, x)); return x*x*(3-2*x) }
    static func hold(_ time: Double, from: Double, to: Double) -> Double {
        let t = max(0,time).truncatingRemainder(dividingBy: 12)
        return smooth((t-from)/1.0) * (1-smooth((t-to)/1.0))
    }
}

enum DeskMotion {
    static func typing(_ p: ArtworkPerformance, at time: Double) -> Double {
        switch p {
        case .coding, .emailDraft: return MotionBeat.hold(time, from: 0, to: 4)+MotionBeat.hold(time, from: 7, to: 10)
        case .debugging: return MotionBeat.hold(time, from: 6, to: 9)
        case .testing, .deploying, .executing: return MotionBeat.hold(time, from: 0, to: 1)
        case .calculating: return MotionBeat.hold(time, from: 1, to: 6)
        default: return 0
        }
    }
    static func keyLift(_ p: ArtworkPerformance, at time: Double, right: Bool) -> Double {
        typing(p, at: time) * pow(max(0, sin(time*12+(right ? .pi : 0))),2)*0.013
    }
    static func progress(at time: Double) -> Double { MotionBeat.smooth((time.truncatingRemainder(dividingBy: 12)-1)/8) }
}

/// A workstation diorama: Kemo is beside the monitor, with the keyboard in
/// front of its paws. Separating these layers avoids typing through a lid.
struct DesktopArtwork: View {
    let theme: BotTheme
    let side: CGFloat
    let time: Double
    let performance: ArtworkPerformance
    let reducedMotion: Bool
    var body: some View {
        ZStack {
            CharacterPlate(name: "body-clean-v3", theme: theme, side: side*0.78, time: time,
                           pose: performance.pose(at: time, reducedMotion: reducedMotion), face: !reducedMotion)
                .offset(x: -side*0.13, y: -side*0.05)
            monitor.offset(x: side*0.22, y: side*0.25)
            CharacterPlate(name: "computer-v4", theme: theme, side: side*0.59)
                .mask { Rectangle().frame(height: side*0.59*0.29).offset(y: side*0.59*0.365) }
                .offset(x: -side*0.055, y: side*0.15)
            hand(right: false)
            hand(right: true)
        }.frame(width: side, height: side)
    }
    private var monitor: some View {
        ZStack {
            CharacterPlate(name: "computer-v4", theme: theme, side: side*0.53)
                .mask { Rectangle().frame(height: side*0.53*0.719).offset(y: -side*0.53*0.1405) }
            DeskDisplay(performance: performance, time: time, reducedMotion: reducedMotion)
                .frame(width: side*0.53*0.565, height: side*0.53*0.356)
                .offset(y: -side*0.53*0.145)
        }
    }
    private func hand(right: Bool) -> some View {
        let lift = reducedMotion ? 0 : DeskMotion.keyLift(performance, at: time, right: right)
        return CharacterPaw(theme: theme, side: side*0.78, right: right,
                            offset: CGPoint(x: right ? 0.01 : 0.065, y: 0.155-lift))
            .offset(x: -side*0.13, y: -side*0.05)
    }
}

private struct DeskDisplay: View {
    let performance: ArtworkPerformance
    let time: Double
    let reducedMotion: Bool
    private let cream = Color(red: 0.96, green: 0.91, blue: 0.81)
    private let green = Color(red: 0.58, green: 0.82, blue: 0.65)
    private let coral = Color(red: 1, green: 0.52, blue: 0.40)
    var body: some View {
        GeometryReader { geo in
            let s = geo.size
            let t = reducedMotion ? 8.0 : time.truncatingRemainder(dividingBy: 12)
            let progress = reducedMotion ? 0.8 : DeskMotion.progress(at: time)
            Canvas { ctx, _ in
                func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ color: Color) {
                    ctx.fill(Path(roundedRect: CGRect(x: x*s.width, y:y*s.height, width:w*s.width, height:h*s.height), cornerRadius:s.height*0.022), with:.color(color))
                }
                func label(_ text: String, _ x: Double, _ y: Double, color: Color = .white, scale: Double = 1) {
                    ctx.draw(Text(text).font(.system(size: s.height*0.105*scale, weight:.medium, design:.monospaced)).foregroundColor(color), at:CGPoint(x:x*s.width,y:y*s.height), anchor:.topLeading)
                }
                // All display content is illustrative animation, never a live
                // claim that a test passed, email sent or deployment occurred.
                switch performance {
                case .coding, .debugging:
                    label(performance == .coding ? "kemo.swift" : "debug / 24",0.04,0.03,color:cream)
                    let lines = ["func hello() {", "  let idea =", "    await think()", "  return idea", "}"]
                    for i in 0..<5 {
                        let y = 0.25+Double(i)*0.135
                        if performance == .debugging && i == 2 && t < 7 { rect(0,y-0.015,1,0.13,coral.opacity(0.2)); rect(0.015,y+0.015,0.022,0.06,coral) }
                        let count = reducedMotion || performance == .debugging ? lines[i].count : Int(min(Double(lines[i].count),max(0,t*13-Double(i)*14)))
                        label(String(lines[i].prefix(count)),0.06,y,color:i == 0 ? coral : cream,scale:0.85)
                    }
                case .codeReview:
                    label("review changes",0.03,0.03,color:cream)
                    for i in 0..<4 {
                        let y=0.27+Double(i)*0.16
                        rect(0.03,y,0.44,0.11,coral.opacity(i == Int(t/2)%4 ? 0.45 : 0.16))
                        rect(0.53,y,0.44,0.11,green.opacity(i == Int(t/2)%4 ? 0.55 : 0.2))
                        label("−",0.05,y,color:coral); label("+",0.55,y,color:green)
                    }
                case .comparing:
                    label("draft A / B",0.03,0.03,color:cream)
                    for col in 0..<2 {
                        let x=0.04+Double(col)*0.50
                        rect(x,0.25,0.41,0.69,cream.opacity(0.92))
                        for i in 0..<5 { rect(x+0.04,0.32+Double(i)*0.10,0.25-Double((i+col)%3)*0.025,0.025,.black.opacity(0.35)) }
                        rect(x+0.035,0.31+Double(Int(t)%5)*0.10,0.31,0.045,coral.opacity(col == 0 ? 0.2 : 0.6))
                    }
                case .testing:
                    label("test suite",0.03,0.03,color:cream)
                    for i in 0..<4 { let done=t>Double(i)*1.7+1; label(done ? "✓" : "·",0.04,0.24+Double(i)*0.17,color:done ? green : cream); rect(0.2,0.27+Double(i)*0.17,0.66-Double(i%2)*0.15,0.045,cream.opacity(done ? 0.7 : 0.3)) }
                case .reviewing:
                    rect(0.12,0.05,0.66,0.89,cream.opacity(0.92))
                    for i in 0..<6 { rect(0.18,0.16+Double(i)*0.11,0.48-Double(i%2)*0.12,0.025,.black.opacity(0.4)) }
                    let center=CGPoint(x:s.width*(0.44+sin(t)*0.13),y:s.height*(0.50+cos(t*0.6)*0.2))
                    let ring=Path(ellipseIn:CGRect(x:center.x-s.height*0.13,y:center.y-s.height*0.13,width:s.height*0.26,height:s.height*0.26))
                    ctx.stroke(ring,with:.color(coral),lineWidth:s.height*0.035)
                    var handle=Path(); handle.move(to:CGPoint(x:center.x+s.height*0.10,y:center.y+s.height*0.10)); handle.addLine(to:CGPoint(x:center.x+s.height*0.23,y:center.y+s.height*0.23))
                    ctx.stroke(handle,with:.color(coral),style:StrokeStyle(lineWidth:s.height*0.05,lineCap:.round))
                case .deploying:
                    label("building release",0.03,0.04,color:cream)
                    label("↑",0.40,0.25,color:coral,scale:2)
                    rect(0.08,0.70,0.84,0.07,cream.opacity(0.15)); rect(0.08,0.70,0.84*progress,0.07,green)
                    label(String(Int(progress*100))+"%",0.39,0.83,color:cream)
                case .executing:
                    label("one step at a time",0.03,0.04,color:cream)
                    rect(0.15,0.46,0.70,0.025,cream.opacity(0.25))
                    for i in 0..<3 {
                        let x=0.06+Double(i)*0.33, done=t>Double(i)*2.4+1
                        rect(x,0.35,0.20,0.25,done ? green : cream.opacity(0.12))
                        label(done ? "✓" : "·",x+0.065,0.41,color:done ? .black : cream)
                    }
                case .emailDraft:
                    label("draft / not sent",0.03,0.02,color:coral)
                    rect(0.03,0.22,0.8,0.035,cream.opacity(0.8))
                    for i in 0..<4 { rect(0.03,0.37+Double(i)*0.13,min(0.9-Double(i%2)*0.18,max(0,t*0.23-Double(i)*0.4)),0.035,cream.opacity(0.55)) }
                case .calendarPlanning:
                    label("finding a time",0.03,0.02,color:cream)
                    for row in 0..<3 { for col in 0..<5 {
                        let selected = (row*5+col) == Int(t*1.7)%15
                        rect(0.035+Double(col)*0.19,0.25+Double(row)*0.235,0.16,0.19,selected ? coral : cream.opacity(0.1))
                    } }
                case .calculating:
                    label("24 × 7",0.1,0.08,color:cream,scale:1.5)
                    label(t < 4 ? "…" : "= 168",0.1,0.35,color:green,scale:1.5)
                    for i in 0..<5 { rect(0.10+Double(i)*0.15,0.83-Double(i)*0.055,0.08,0.08+Double(i)*0.055,coral.opacity(0.7)) }
                case .sources:
                    label("claim → source",0.03,0.03,color:cream)
                    label("“",0.04,0.25,color:coral,scale:2)
                    rect(0.22,0.29,0.70,0.04,cream.opacity(0.75)); rect(0.22,0.39,0.48,0.04,cream.opacity(0.5))
                    rect(0.08,0.63,0.84,0.25,green.opacity(0.15))
                    label(t < 5 ? "checking link…" : "source found",0.13,0.70,color:green)
                case .research:
                    label("searching…",0.03,0.03,color:cream)
                    for i in 0..<3 { rect(0.03,0.26+Double(i)*0.23,0.12,0.14,coral.opacity(0.6)); rect(0.23,0.27+Double(i)*0.23,0.67,0.04,cream.opacity(0.5)); rect(0.23,0.35+Double(i)*0.23,0.40,0.03,green.opacity(Int(t)%3 == i ? 0.9 : 0.3)) }
                default: break
                }
            }
        }.background(Color(red:0.12,green:0.10,blue:0.18)).clipShape(RoundedRectangle(cornerRadius:5))
    }
}

struct CompanionProps: View {
    let theme: BotTheme
    let side: CGFloat
    let time: Double
    let performance: ArtworkPerformance
    var body: some View {
        switch performance.prop {
        case .files: FilingArtwork(theme: theme, side: side, time: time, performance: performance)
        case .mug:
            // Big enough to read at the header's size, lifted to the mouth for a sip.
            let lift = performance == .sipping ? MotionBeat.hold(time, from:2,to:6)*0.14 : 0
            ZStack {
                SteamArtwork(time: time).frame(width:side*0.16,height:side*0.13).offset(x:-side*0.016,y:side*(0.10-lift))
                CharacterPlate(name:"mug-v4",theme:theme,side:side*0.42).offset(y:side*(0.285-lift))
            }
        case .timer: TimerArtwork(theme:theme,side:side*0.38,time:performance == .focus ? time/8 : time).offset(y:side*0.30)
        default: EmptyView()
        }
    }
}

private struct FilingArtwork: View {
    let theme: BotTheme
    let side: CGFloat
    let time: Double
    let performance: ArtworkPerformance
    var body: some View {
        let t = time.truncatingRemainder(dividingBy: 12)
        let lift = MotionBeat.hold(time,from:1,to:7)
        let sorting = performance == .organizing ? sin(t*0.9)*0.085 : performance == .filing ? -0.12*(1-MotionBeat.smooth(t/3)) : 0
        ZStack {
            RoundedRectangle(cornerRadius:side*0.012)
                .fill(LinearGradient(colors:[Color(red:1,green:0.96,blue:0.87),Color(red:0.82,green:0.76,blue:0.65)],startPoint:.topLeading,endPoint:.bottomTrailing))
                .overlay(alignment:.topLeading) {
                    VStack(alignment:.leading,spacing:side*0.008) {
                        ForEach(0..<3) { i in Capsule().fill(theme.accentColor.opacity(0.45)).frame(width:side*(i == 2 ? 0.055 : 0.085),height:side*0.004) }
                    }.padding(side*0.017)
                }
                .frame(width:side*0.15,height:side*0.11)
                .shadow(color:.black.opacity(0.13),radius:side*0.005,y:side*0.004)
                .rotationEffect(.degrees(sorting*80))
                .offset(x:side*sorting,y:side*(0.245-lift*(performance == .searchingFiles || performance == .recalling ? 0.115 : 0.08)))
            CharacterPlate(name:"files-v4",theme:theme,side:side*0.43).offset(y:side*0.31)
        }
    }
}

struct TimerArtwork: View {
    let theme: BotTheme
    let side: CGFloat
    let time: Double
    var body: some View {
        ZStack {
            CharacterPlate(name:"timer-v4",theme:theme,side:side)
            Capsule().fill(Color(red:0.22,green:0.20,blue:0.20)).frame(width:side*0.018,height:side*0.17)
                .offset(y:-side*0.075)
                .rotationEffect(.radians(time/12 * .pi*2))
                .offset(y:side*0.045)
            Circle().fill(theme.accentColor).frame(width:side*0.038).offset(y:side*0.045)
        }.frame(width:side,height:side)
    }
}

private struct SteamArtwork: View {
    let time: Double
    var body: some View {
        Canvas { context, size in
            for i in 0..<3 {
                let phase=(time*0.2+Double(i)/3).truncatingRemainder(dividingBy:1)
                var p=Path(); let x=size.width*(0.25+Double(i)*0.24)
                p.move(to:CGPoint(x:x,y:size.height*(1-phase)))
                p.addCurve(to:CGPoint(x:x+sin(phase * .pi)*size.width*0.12,y:-size.height*phase),control1:CGPoint(x:x-size.width*0.2,y:size.height*(0.7-phase)),control2:CGPoint(x:x+size.width*0.2,y:size.height*(0.4-phase)))
                context.stroke(p,with:.color(.white.opacity(sin(phase * .pi)*0.20)),style:StrokeStyle(lineWidth:2,lineCap:.round))
            }
        }.blur(radius:2)
    }
}

/// Moments that need more than a pose: confetti when a task is done, and
/// drifting z's while Kemo sleeps. Both hold still for Reduce Motion (time 0).
struct CompanionEffects: View {
    let theme: BotTheme
    let side: CGFloat
    let time: Double
    let performance: ArtworkPerformance
    var body: some View {
        switch performance {
        case _ where performance.prop == .headphones: MusicNotes(theme: theme, time: time).frame(width: side, height: side)
        case .done: Confetti(theme: theme, time: time).frame(width: side, height: side)
        case .resting: SleepyZs(theme: theme, time: time).frame(width: side, height: side)
        default: EmptyView()
        }
    }
}

private struct Confetti: View {
    let theme: BotTheme
    let time: Double
    var body: some View {
        Canvas { context, size in
            // One burst from above Kemo's head, falling with a little drift.
            let t = time - 0.35
            guard t > 0, t < 3.6 else { return }
            let colors = [theme.accentColor, theme.bodyColor, Color(red: 1, green: 0.84, blue: 0.40), theme.accentColor.opacity(0.7)]
            for i in 0..<26 {
                let seed = Double(i) * 12.9898
                let angle = -Double.pi / 2 + (fract(sin(seed) * 43758.5) - 0.5) * 2.4
                let speed = 0.34 + fract(sin(seed * 1.7) * 23421.6) * 0.30
                let x = 0.5 + cos(angle) * speed * t * 0.9
                let y = 0.20 + sin(angle) * speed * t + 0.30 * t * t
                let fade = min(1, (3.6 - t) / 0.8)
                var piece = context
                piece.opacity = fade
                piece.translateBy(x: x * size.width, y: y * size.height)
                piece.rotate(by: .radians(t * (3 + Double(i % 5)) + seed))
                let w = size.width * (i % 3 == 0 ? 0.022 : 0.016), h = size.width * 0.010
                piece.fill(Path(roundedRect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), cornerRadius: h / 3), with: .color(colors[i % colors.count]))
            }
        }
    }
    private func fract(_ value: Double) -> Double { value - value.rounded(.down) }
}

private struct MusicNotes: View {
    let theme: BotTheme
    let time: Double
    var body: some View {
        Canvas { context, size in
            for i in 0..<4 {
                // Notes drift up from beside the ear cups, swaying, and fade.
                let phase = time == 0 ? 0.3 + Double(i) * 0.18 : (time / 2.4 + Double(i) / 4).truncatingRemainder(dividingBy: 1)
                let side = i % 2 == 0 ? -1.0 : 1.0
                let x = size.width * (0.5 + side * (0.40 + phase * 0.06) + sin(phase * .pi * 3) * 0.02)
                let y = size.height * (0.46 - phase * 0.34)
                context.opacity = sin(phase * .pi)
                context.draw(Text(i % 3 == 0 ? "♫" : "♪").font(.system(size: size.width * (0.075 + phase * 0.03), weight: .bold))
                    .foregroundStyle(i % 2 == 0 ? theme.accentColor : theme.bodyColor), at: CGPoint(x: x, y: y))
            }
        }
    }
}

private struct SleepyZs: View {
    let theme: BotTheme
    let time: Double
    var body: some View {
        Canvas { context, size in
            for i in 0..<3 {
                // Each z rises and fades over three seconds, one second apart.
                let phase = time == 0 ? 0.35 + Double(i) * 0.2 : (time / 3 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                let x = size.width * (0.68 + phase * 0.14 + sin(phase * .pi * 2) * 0.015)
                let y = size.height * (0.22 - phase * 0.16)
                let fontSize = size.width * (0.075 + phase * 0.05)
                context.opacity = sin(phase * .pi)
                context.draw(Text("z").font(.system(size: fontSize, weight: .heavy, design: .rounded)).foregroundStyle(theme.accentColor),
                             at: CGPoint(x: x, y: y))
            }
        }
    }
}

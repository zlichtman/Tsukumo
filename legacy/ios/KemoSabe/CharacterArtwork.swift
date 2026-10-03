import SwiftUI

struct CharacterPlate: View {
    let name: String
    let theme: BotTheme
    let side: CGFloat
    var time = 0.0
    var pose = ArtworkPerformance.Pose()
    var face = false
    var paper = false
    var keyed = true
    var body: some View {
        if let image = ArtworkAssets.image(name) {
            Image(kemoImage: image).resizable().interpolation(.high).frame(width: side, height: side)
                .layerEffect(ShaderLibrary.kemoPlate(
                    .float2(Float(side), Float(side)), .float(Float(time)),
                    .color(theme.bodyColor), .color(theme.accentColor),
                    .float(theme == BotTheme.presets[0] ? 0 : 1),
                    .float4(keyed ? (name == "paws-v3" ? 2 : 1) : 0, face ? 1 : 0, (name.hasSuffix("-v4") || name.hasSuffix("-v5")) ? 2 : (paper ? 1 : 0), Float(pose.eyelids)),
                    .float4(Float(pose.gaze.x), Float(pose.gaze.y), Float(pose.mouth), 0)
                ), maxSampleOffset: CGSize(width: side*0.05, height: side*0.10))
        }
    }
}

struct PuppetArtwork: View {
    let theme: BotTheme
    let side: CGFloat
    let time: Double
    let pose: ArtworkPerformance.Pose
    var performance: ArtworkPerformance = .idle
    var body: some View {
        ZStack {
            CharacterPlate(name: "body-clean-v3", theme: theme, side: side, time: time, pose: pose, face: true)
            if performance.prop == .headphones {
                CharacterPlate(name: "headphones-v5", theme: theme, side: side)
            }
            CompanionProps(theme: theme, side: side, time: time, performance: performance)
            if performance == .conducting {
                Capsule().fill(LinearGradient(colors:[Color.white,Color(red:0.79,green:0.68,blue:0.49)],startPoint:.leading,endPoint:.trailing))
                    .frame(width:side*0.008,height:side*0.19)
                    .offset(x:side*0.13,y:side*0.18)
                    .frame(width:side,height:side)
                    .rotationEffect(.radians(pose.rightAngle-0.3),anchor:UnitPoint(x:0.63,y:0.765))
                    .offset(x:side*pose.right.x,y:side*pose.right.y)
            }
            paw(right: false)
            paw(right: true)
            CompanionEffects(theme: theme, side: side, time: time, performance: performance)
        }.frame(width: side, height: side)
            .scaleEffect(performance.prop == .headphones ? 0.90 : 1)
            .scaleEffect(x: 1-pose.stretch*0.25, y: 1+pose.stretch, anchor: .bottom)
            .rotationEffect(.radians(pose.tilt), anchor: .bottom)
            .offset(x: side*pose.x, y: side*pose.y)
    }
    private func paw(right: Bool) -> some View {
        CharacterPaw(theme: theme, side: side, right: right, offset: right ? pose.right : pose.left,
                     angle: right ? pose.rightAngle : pose.leftAngle)
    }
}

struct CharacterPaw: View {
    let theme: BotTheme
    let side: CGFloat
    let right: Bool
    var offset = CGPoint.zero
    var angle = 0.0
    var body: some View {
        CharacterPlate(name: "paws-v3", theme: theme, side: side)
            .mask {
                Rectangle().frame(width: side*0.5, height: side)
                    .position(x: side*(right ? 0.75 : 0.25), y: side*0.5)
            }
            .shadow(color: .black.opacity(0.10), radius: side*0.008, y: side*0.006)
            .rotationEffect(.radians(angle), anchor: UnitPoint(x: right ? 0.63 : 0.37, y: 0.765))
            .offset(x: offset.x*side, y: offset.y*side)
    }
}

enum ReadingMotion {
    static let duration = 8.4
    static func turn(at time: Double, performance: ArtworkPerformance, reducedMotion: Bool) -> Double {
        guard !reducedMotion, performance != .handoff, performance != .bookmarking else { return 0 }
        let speed = performance == .research ? 1.35 : performance == .reviewing ? 0.7 : 1.0
        let t = max(0, time*speed).truncatingRemainder(dividingBy: duration)
        let start = performance == .pageTurn ? 0.6 : performance == .recipe ? 4.1 : 2.6
        let u = min(1, max(0, (t-start)/2.8))
        return u*u*(3-2*u)
    }
    /// Each point stays attached to the same gutter; only the leaf rotates.
    static func pagePoint(u: Double, v: Double, turn: Double) -> CGPoint {
        let angle = turn * .pi
        let curl = sin(angle)*sin(u * .pi)*0.010
        return CGPoint(x: 0.5 + u*0.164*cos(angle)+sin(angle)*sin(u * .pi)*0.018,
                       y: 0.706-sqrt(u)*0.072-u*0.025*sin(angle)+v*0.12+curl)
    }
}

struct ReadingArtwork: View {
    let theme: BotTheme
    let side: CGFloat
    let time: Double
    let performance: ArtworkPerformance
    let reducedMotion: Bool
    var body: some View {
        let turn = ReadingMotion.turn(at: time, performance: performance, reducedMotion: reducedMotion)
        ZStack {
            CharacterPlate(name: "reading-v3", theme: theme, side: side, time: reducedMotion ? 0 : time,
                           pose: performance.pose(at: time, reducedMotion: reducedMotion), face: !reducedMotion, paper: true)
            if turn > 0 && turn < 1 {
                Canvas { context, size in
                    var behindCovers = Path()
                    behindCovers.addLines([.zero, CGPoint(x:size.width,y:0),
                        CGPoint(x:size.width,y:size.height*0.65), CGPoint(x:size.width*0.7,y:size.height*0.65),
                        CGPoint(x:size.width*0.5,y:size.height*0.713), CGPoint(x:size.width*0.3,y:size.height*0.65),
                        CGPoint(x:0,y:size.height*0.65)])
                    behindCovers.closeSubpath(); context.clip(to: behindCovers)
                    for strip in 0..<64 {
                        let u = Double(strip)/64, next = Double(strip+1)/64
                        let points = [(u,0.0),(next,0.0),(next,1.0),(u,1.0)].map { pair in
                            let p = ReadingMotion.pagePoint(u: pair.0, v: pair.1, turn: turn)
                            return CGPoint(x: p.x*size.width, y: p.y*size.height)
                        }
                        var path = Path(); path.addLines(points); path.closeSubpath()
                        let light = 0.88 + 0.10*sin(turn * .pi) + 0.02*u
                        context.fill(path, with: .linearGradient(Gradient(colors: [Color(red: light, green: light*0.955, blue: light*0.875), Color(red: 1, green: 0.97, blue: 0.90)]), startPoint: points[0], endPoint: points[3]), style: FillStyle(antialiased: false))
                    }
                }.frame(width: side, height: side)
                    .shadow(color: .black.opacity(0.12*sin(turn * .pi)), radius: side*0.005, y: side*0.006)
            }
            if performance == .bookmarking {
                let slide = reducedMotion ? 1 : MotionBeat.smooth((time.truncatingRemainder(dividingBy: 8)-0.5)/2)
                BookmarkRibbon()
                    .fill(LinearGradient(stops: [.init(color:theme.accentColor.opacity(0.80),location:0),.init(color:theme.accentColor,location:0.25),.init(color:theme.accentColor,location:0.75),.init(color:theme.accentColor.opacity(0.65),location:1)],startPoint:.leading,endPoint:.trailing))
                    .frame(width: side*0.018, height: side*0.11)
                    .shadow(color: .black.opacity(0.18), radius: side*0.003, x: side*0.002)
                    .offset(x: side*0.10, y: side*(0.215-0.11*(1-slide))).opacity(slide)
            }
            if performance == .recipe {
                TimerArtwork(theme: theme, side: side*0.24, time: reducedMotion ? 0 : time)
                    .offset(x: side*0.28, y: side*0.34)
            }
        }.frame(width: side, height: side)
            .scaleEffect(performance == .handoff ? 1 + 0.035*MotionBeat.hold(time, from: 1, to: 7) : 1)
    }
}

private struct BookmarkRibbon: Shape {
    func path(in rect: CGRect) -> Path {
        var p=Path(); p.move(to:CGPoint(x:0,y:rect.height*0.08))
        p.addQuadCurve(to:CGPoint(x:rect.width,y:rect.height*0.08),control:CGPoint(x:rect.midX,y:-rect.height*0.035))
        p.addLine(to:CGPoint(x:rect.width*0.92,y:rect.height))
        p.addLine(to:CGPoint(x:rect.width*0.49,y:rect.height*0.88))
        p.addLine(to:CGPoint(x:rect.width*0.08,y:rect.height))
        p.closeSubpath(); return p
    }
}

extension Image {
    init(kemoImage: KemoPlatformImage) {
        #if os(macOS)
        self.init(nsImage: kemoImage)
        #else
        self.init(uiImage: kemoImage)
        #endif
    }
}

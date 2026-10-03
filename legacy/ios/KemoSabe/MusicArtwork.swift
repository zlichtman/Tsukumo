import SwiftUI

/// Contact choreography shares the tempo clock with the instrument. The desk
/// stays planted; only Kemo's upper body sways. No global artwork bobbing.
enum MusicDeskMotion {
    static func beats(_ time: Double, bpm: Double) -> Double {
        max(0,time) * min(180,max(60,bpm)) / 60
    }
    static func scratch(_ beat: Double) -> Double { sin(beat * .pi) * 0.48 }
    static func hand(_ performance: ArtworkPerformance, beat: Double, right: Bool) -> CGPoint {
        if performance == .drumming {
            let lift = pow(max(0,sin(beat * .pi*2 + (right ? .pi : 0))),2)*0.045
            return CGPoint(x:right ? 0.70 : 0.30,y:0.79-lift)
        }
        if performance == .dj {
            let angle = scratch(beat + (right ? 1 : 0))
            return CGPoint(x: (right ? 0.715 : 0.285) + sin(angle)*0.045,
                           y: 0.674 + cos(angle)*0.026)
        }
        // Move between discrete notes only during the lifted part of the beat.
        let phrase = beat + (right ? 0.5 : 0)
        let notes = right ? [0.61,0.66,0.70,0.66,0.61,0.57,0.61,0.66] : [0.29,0.34,0.38,0.34,0.29,0.34,0.38,0.43]
        let index = Int(phrase)%notes.count
        let mix = MotionBeat.smooth(min(1,phrase.truncatingRemainder(dividingBy:1)*2))
        let x = notes[index] + (notes[(index+1)%notes.count]-notes[index])*mix
        let lift = pow(max(0,sin(beat * .pi*2 + (right ? .pi : 0))),2)*0.020
        return CGPoint(x:x, y:0.785-lift)
    }
}

struct MusicDeskArtwork: View {
    let theme: BotTheme
    let side: CGFloat
    let time: Double
    let bpm: Double
    let performance: ArtworkPerformance
    let reducedMotion: Bool
    private var beat: Double { reducedMotion ? 0 : MusicDeskMotion.beats(time,bpm:bpm) }
    var body: some View {
        ZStack {
            ZStack {
                CharacterPlate(name:"body-clean-v3",theme:theme,side:side*0.88,time:reducedMotion ? 0 : time,
                               pose:performance.pose(at:time,bpm:bpm,reducedMotion:reducedMotion),face:!reducedMotion)
                if performance != .piano {
                    CharacterPlate(name:"headphones-v5",theme:theme,side:side*0.88)
                }
            }
            .rotationEffect(.radians(reducedMotion ? 0 : sin(beat * .pi/2)*0.018),anchor:.bottom)
            .offset(y:-side*0.07)
            CharacterPlate(name:performance == .piano ? "piano-v5" : "dj-v5",theme:theme,side:side*0.86)
                .offset(y:side*(performance == .piano ? 0.28 : 0.25))
            if performance == .piano || performance == .drumming { contactShadows }
            if performance == .dj { platterMarks }
            hand(right:false)
            hand(right:true)
        }.frame(width:side,height:side)
    }
    private var contactShadows: some View {
        Canvas { context,size in
            for right in [false,true] {
                let p=MusicDeskMotion.hand(performance,beat:beat,right:right)
                let pressure=1-min(1,max(0,(0.785-p.y)/0.020))
                let rect=CGRect(x:(p.x-0.046)*size.width,y:0.783*size.height,width:0.092*size.width,height:0.015*size.height)
                context.fill(Path(ellipseIn:rect),with:.color(.black.opacity(0.16*pressure)))
            }
        }.blur(radius:side*0.003).frame(width:side,height:side)
    }
    private func hand(right: Bool) -> some View {
        let target = MusicDeskMotion.hand(performance,beat:beat,right:right)
        let restX = 0.5 + (right ? 0.13 : -0.13)*0.88
        let restY = 0.5 + 0.265*0.88
        return CharacterPaw(theme:theme,side:side*0.88,right:right,
                            offset:CGPoint(x:(target.x-restX)/0.88,y:(target.y-restY)/0.88),
                            angle:performance == .dj ? MusicDeskMotion.scratch(beat+(right ? 1 : 0))*0.15 : 0)
    }
    private var platterMarks: some View {
        Canvas { context,size in
            for right in [false,true] {
                let center = CGPoint(x:size.width*(right ? 0.715 : 0.285),y:size.height*0.674)
                let angle = MusicDeskMotion.scratch(beat+(right ? 1 : 0))
                // A physical cream index mark rides the elliptical platter.
                let p = CGPoint(x:center.x+sin(angle)*size.width*0.070,
                                y:center.y-cos(angle)*size.height*0.066)
                context.fill(Path(ellipseIn:CGRect(x:p.x-size.width*0.004,y:p.y-size.height*0.0025,
                                                    width:size.width*0.008,height:size.height*0.005)),
                             with:.color(Color(red:0.96,green:0.91,blue:0.81)))
            }
        }.frame(width:side,height:side)
    }
}

import CoreGraphics
import Foundation

/// Pencil and ink share a contact trajectory on a stationary lap notebook.
/// Coordinates face Kemo, not the viewer: no audience-facing calligraphy.
enum WritingMotion {
    static let duration = 10.4
    // Measured from the isolated v5 artwork; do not assume generation preserved
    // the old cutout's anchor. The visible graphite endpoint owns the transform.
    static let sourceTip = CGPoint(x: 678.0 / 1254, y: 929.0 / 1254)

    static func pagePoint(_ point: CGPoint) -> CGPoint {
        // Project the authoring plane into the foreshortened paper in v6.
        // Both axes reverse because Kemo is sitting opposite the viewer.
        CGPoint(x: 0.620 - (point.x - 0.48) * 1.30,
                y: 0.786 - (point.y - 0.67) * 0.35)
    }

    struct Stroke {
        let start: Double
        let end: Double
        let origin: CGPoint
        let width: Double
        let shape: [CGPoint]
        private let distances: [Double]

        init(start: Double, end: Double, origin: CGPoint, width: Double, shape: [CGPoint]) {
            self.start = start; self.end = end; self.origin = origin
            self.width = width; self.shape = shape
            var cumulative = [0.0]
            for i in 1..<shape.count {
                // Measure in the projected page plane, including its slope.
                let dx = shape[i].x-shape[i-1].x
                let dy = shape[i].y-shape[i-1].y-dx*0.20
                cumulative.append(cumulative.last! + hypot(dx,dy))
            }
            distances = cumulative
        }

        func point(_ progress: Double) -> CGPoint {
            // Ease pressure into and out of a stroke; retain a steady middle.
            let raw = min(1, max(0, progress))
            let u = raw * raw * raw * (raw * (raw * 6 - 15) + 10)
            let distance = u * (distances.last ?? 0)
            var low = 0, high = shape.count-1
            while high-low > 1 {
                let mid = (low+high)/2
                if distances[mid] <= distance { low=mid } else { high=mid }
            }
            let fraction = (distance-distances[low])/max(0.000001,distances[high]-distances[low])
            let local = CGPoint(x: shape[low].x + (shape[high].x - shape[low].x) * fraction,
                                y: shape[low].y + (shape[high].y - shape[low].y) * fraction)
            let advance = width * local.x / 102
            return pagePoint(CGPoint(x: origin.x + advance,
                           y: origin.y - advance * 0.20 + local.y * width / 102))
        }

        func progress(at time: Double) -> Double { min(1, max(0, (time - start) / (end - start))) }

        func points(through progress: Double) -> [CGPoint] {
            let progress = min(1, max(0, progress))
            guard progress > 0 else { return [point(0)] }
            let steps = max(1, Int(ceil(progress * 600)))
            return (0...steps).map { point(progress * Double($0) / Double(steps)) }
        }
    }

    static let strokes: [Stroke] = [
        .init(start: 0.5, end: 1.9, origin: CGPoint(x: 0.495, y: 0.737), width: 0.052, shape: memo),
        .init(start: 2.15, end: 3.8, origin: CGPoint(x: 0.558, y: 0.7244), width: 0.052, shape: notes),
        .init(start: 4.4, end: 5.8, origin: CGPoint(x: 0.487, y: 0.779), width: 0.052, shape: notes),
        .init(start: 6.05, end: 7.4, origin: CGPoint(x: 0.550, y: 0.7664), width: 0.052, shape: memo),
        .init(start: 7.55, end: 7.8, origin: CGPoint(x: 0.487 + 0.119 * 0.46, y: 0.779 - 0.119 * 0.46 * 0.20 - 0.013), width: 0.119 * 0.18, shape: [CGPoint(x: 0, y: 0), CGPoint(x: 102, y: -3)])
    ]

    struct Pose {
        let tip: CGPoint
        let rotation: Double
        let penDown: Bool
        let inkOpacity: Double
        let ink: [[CGPoint]]
    }

    static func pose(at elapsed: Double, reducedMotion: Bool = false, performance: ArtworkPerformance = .writing) -> Pose {
        let strokes = strokes(for: performance)
        let time = reducedMotion ? 7.8 : max(0, elapsed).truncatingRemainder(dividingBy: duration)
        let ink = strokes.map { time < $0.start ? [] : $0.points(through: $0.progress(at: time)) }
        let opacity = 1 - smooth((time - 9.0) / 1.0)
        for stroke in strokes where time >= stroke.start && time <= stroke.end {
            let u = stroke.progress(at: time)
            let tip = stroke.point(u)
            return Pose(tip: tip, rotation: wristAngle(at: tip),
                        penDown: true, inkOpacity: opacity, ink: ink)
        }
        let before = strokes.last { $0.end < time }
        let after = strokes.first { $0.start > time }
        let from = before?.point(1) ?? strokes[0].point(0)
        let to = after?.point(0) ?? strokes[0].point(0)
        // Let the completed note rest before returning to the start. The ink
        // fades only while the pencil is lifted, so the loop has no hard reset.
        let start = before?.end ?? 0
        let finish = after?.start ?? duration
        let travelStart = after == nil ? 8.6 : start
        let u = smooth((time - travelStart) / max(0.001, finish - travelStart))
        let lift = sin(u * .pi) * (after == nil ? 0.034 : 0.018)
        let tip = CGPoint(x: from.x + (to.x - from.x) * u,
                          y: from.y + (to.y - from.y) * u - lift)
        return Pose(tip: tip, rotation: wristAngle(at: tip)-sin(u * .pi) * 0.045,
                    penDown: false, inkOpacity: opacity, ink: ink)
    }

    private static func smooth(_ value: Double) -> Double {
        let t = min(1, max(0, value)); return t * t * t * (t * (t * 6 - 15) + 10)
    }

    /// A small wrist roll follows reach across the page, not a timer-driven wag.
    static func wristAngle(at tip: CGPoint) -> Double {
        -0.32 * (tip.x-sourceTip.x) + 0.18 * (tip.y-sourceTip.y)
    }

    static func strokes(for performance: ArtworkPerformance) -> [Stroke] {
        func line(_ start: Double, _ end: Double, _ x: Double, _ y: Double, _ width: Double, _ shape: [CGPoint]) -> Stroke {
            Stroke(start: start, end: end, origin: CGPoint(x:x,y:y), width: width, shape: shape)
        }
        let straight = [CGPoint.zero, CGPoint(x: 102, y: 0)]
        switch performance {
        case .sketching:
            let heart = (0...240).map { i -> CGPoint in
                let t = Double(i)/240 * .pi*2
                return CGPoint(x: 51+48*pow(sin(t),3), y: -(13*cos(t)-5*cos(2*t)-2*cos(3*t)-cos(4*t))*3)
            }
            return [line(0.5,7.8,0.505,0.753,0.090,heart)]
        case .outlining, .standup:
            return (0..<3).map { i in
                line(0.5+Double(i)*2.5,2.3+Double(i)*2.5,0.495,0.718+Double(i)*0.027,
                     performance == .standup ? [0.115,0.095,0.07][i] : [0.115,0.085,0.10][i],
                     [CGPoint.zero,CGPoint(x:4,y:0),CGPoint(x:10,y:0),CGPoint(x:15,y:-3),CGPoint(x:22,y:0),CGPoint(x:102,y:0)])
            }
        case .revising:
            return [strokes[0],line(4.4,5.4,0.50,0.730,0.102,straight),line(5.8,7.8,0.493,0.772,0.115,notes)]
        case .proofreading:
            return [strokes[0],line(4.4,6.2,0.498,0.750,0.110,straight),
                    line(6.8,7.8,0.585,0.776,0.030,[CGPoint(x:0,y:-10),CGPoint(x:35,y:12),CGPoint(x:102,y:-42)])]
        case .journaling:
            return [line(0.5,4.3,0.49,0.737,0.116,notes),line(5.0,7.8,0.493,0.777,0.10,memo)]
        case .calculating:
            return [line(0.5,3.4,0.499,0.730,0.10,[CGPoint.zero,CGPoint(x:0,y:-18),CGPoint(x:16,y:-18),CGPoint(x:16,y:0),CGPoint(x:0,y:0)]),
                    line(4,5.5,0.536,0.740,0.045,[CGPoint.zero,CGPoint(x:102,y:0)]),
                    line(6,7.8,0.536,0.752,0.045,[CGPoint.zero,CGPoint(x:102,y:0)])]
        case .writing:
            // Small phrases, separated by real pen lifts and a thought pause.
            // Imply notes without projecting legible text toward the audience.
            return [line(0.5,1.15,0.493,0.727,0.025,memo),
                    line(1.45,2.25,0.527,0.7202,0.026,notes),
                    line(2.55,3.4,0.562,0.7132,0.025,memo),
                    line(4.4,5.05,0.493,0.779,0.025,notes),
                    line(5.4,6.2,0.527,0.7722,0.026,memo),
                    line(6.5,7.35,0.562,0.7652,0.025,notes)]
        default: return strokes
        }
    }

    // Abstract graphite marks, not letterforms or cursive words.
    private static let memo = [
        CGPoint(x:0,y:0), CGPoint(x:23,y:-3), CGPoint(x:40,y:1),
        CGPoint(x:66,y:-2), CGPoint(x:83,y:0), CGPoint(x:102,y:-1)
    ]
    private static let notes = [
        CGPoint(x:0,y:0), CGPoint(x:20,y:2), CGPoint(x:47,y:-2),
        CGPoint(x:71,y:1), CGPoint(x:102,y:0)
    ]
}

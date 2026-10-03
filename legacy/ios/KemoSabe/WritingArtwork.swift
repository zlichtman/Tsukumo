import SwiftUI

/// Two retained-lighting image layers, with a rigid pencil/paw and page-space ink.
struct WritingArtwork: View {
    let theme: BotTheme
    let side: CGFloat
    let time: Double
    let reducedMotion: Bool
    var performance: ArtworkPerformance = .writing

    var body: some View {
        let pose = WritingMotion.pose(at: time, reducedMotion: reducedMotion, performance: performance)
        ZStack {
            art("writing-lap-v6")
            Canvas { context, size in
                for points in pose.ink where points.count > 1 {
                    var path = Path()
                    path.move(to: CGPoint(x: points[0].x * size.width, y: points[0].y * size.height))
                    for point in points.dropFirst() {
                        path.addLine(to: CGPoint(x: point.x * size.width, y: point.y * size.height))
                    }
                    context.stroke(path, with: .color(Color(red: 0.24, green: 0.19, blue: 0.17).opacity(0.70 * pose.inkOpacity)),
                                   style: StrokeStyle(lineWidth: side * 0.0015, lineCap: .round, lineJoin: .round))
                }
            }.frame(width: side, height: side)
            art("pencil-paw-v5", hand: true)
                .scaleEffect(0.78, anchor: UnitPoint(x: WritingMotion.sourceTip.x, y: WritingMotion.sourceTip.y))
                .shadow(color: .black.opacity(pose.penDown ? 0.14 : 0.09), radius: side * (pose.penDown ? 0.002 : 0.004), x: side * 0.001, y: side * 0.003)
                .rotationEffect(.radians(pose.rotation), anchor: UnitPoint(x: WritingMotion.sourceTip.x, y: WritingMotion.sourceTip.y))
                .offset(x: (pose.tip.x - WritingMotion.sourceTip.x) * side,
                        y: (pose.tip.y - WritingMotion.sourceTip.y) * side)
        }.frame(width: side, height: side)
    }

    @ViewBuilder private func art(_ name: String, hand: Bool = false) -> some View {
        if let image = ArtworkAssets.image(name) {
            Image(kemoImage: image).resizable().interpolation(.high).frame(width: side, height: side)
                .layerEffect(ShaderLibrary.kemoArtwork(
                    .float2(Float(side), Float(side)), .float(0),
                    .color(theme.bodyColor), .color(theme.accentColor),
                    .float(theme == BotTheme.presets[0] ? 0 : 1),
                    .float4(hand ? 2 : 1, 0, 0, 0), .float2(0, 0)
                ), maxSampleOffset: CGSize(width:side*0.003,height:side*0.003))
        }
    }
}

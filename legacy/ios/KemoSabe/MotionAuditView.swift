#if DEBUG
import SwiftUI

/// Simulator-only visual QA surface. Uses the shipping renderer, not mock art.
struct MotionAuditView: View {
    static var requested: Bool { ProcessInfo.processInfo.arguments.contains("--ui-testing") && ProcessInfo.processInfo.arguments.contains("--motion-audit") }
    @State private var page = 0
    @State private var themeIndex = 0
    var body: some View {
        GeometryReader { geo in
            let side = min((geo.size.width-24)/2,(geo.size.height-75)/4-22)
            VStack(spacing:4) {
                HStack {
                    Button("Previous") { page = (page+7)%8 }.accessibilityIdentifier("auditPrevious")
                    Spacer()
                    Text("Motion \(page+1)/8").accessibilityIdentifier("auditReady")
                    Spacer()
                    Button("Next") { page = (page+1)%8 }.accessibilityIdentifier("auditNext")
                }.font(.system(size:13)).padding(.horizontal,12)
                Button(BotTheme.presets[themeIndex].name) { themeIndex = (themeIndex+1)%BotTheme.presets.count }
                    .accessibilityIdentifier("auditTheme").font(.system(size:12))
                ForEach(0..<4,id:\.self) { row in
                    HStack(spacing:8) {
                        ForEach(0..<2,id:\.self) { col in
                            let p = ArtworkPerformance.allCases[page*8+row*2+col]
                            VStack(spacing:0) {
                                ArtworkCompanion(theme:BotTheme.presets[themeIndex],performance:p.rawValue)
                                    .frame(width:side,height:side).id(p.rawValue)
                                Text(p.rawValue).font(.system(size:11,design:.monospaced))
                            }
                        }
                    }
                }
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
        }.background(BotTheme.presets[themeIndex].backgroundColor).foregroundStyle(.white)
            .task {
                guard ProcessInfo.processInfo.arguments.contains("--audit-autoplay") else { return }
                for next in 1..<8 {
                    do { try await Task.sleep(for:.seconds(13)) } catch { return }
                    page=next
                }
            }
    }
}
#endif

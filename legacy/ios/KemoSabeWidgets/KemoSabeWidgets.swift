import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// KemoSabe's iPhone widget extension: Kemo's Live Activity while you talk to it from anywhere,
/// and the Talk to Kemo Control for Control Center, the Lock Screen, and the Action button.
@main struct KemoSabeWidgets: WidgetBundle {
    var body: some Widget {
        KemoVoiceLiveActivity()
        TalkToKemoControl()
    }
}

// MARK: Control

/// "Talk to Kemo" in Control Center, on the Lock Screen, or on the Action button. It runs
/// `TalkToKemoIntent` in the app's process (an `AudioRecordingIntent`).
struct TalkToKemoControl: ControlWidget {
    static let kind = "com.zlichtman.kemosabe.talk"
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: TalkToKemoIntent()) {
                Label("Talk to KemoSabe", systemImage: "mic.fill")
            }
        }
        .displayName("Talk to KemoSabe")
        .description("KemoSabe listens, answers with your model, and reads the reply aloud.")
    }
}

// MARK: Live Activity

/// One turn: listening (a small orb under Kemo), thinking, speaking, and the reply. Kemo is drawn
/// from the approved frames in your palette; a Live Activity can't run its own clock, so Kemo and
/// the orb change with each update the app sends (at most a few a second), with short transitions.
struct KemoVoiceLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: KemoVoiceAttributes.self) { context in
            KemoVoiceLockScreen(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(KemoVoiceFrames.color(context.attributes.background).opacity(0.92))
                .activitySystemActionForegroundColor(KemoVoiceFrames.color(context.attributes.foreground))
                .widgetURL(Self.conversation)
        } dynamicIsland: { context in
            let attributes = context.attributes, state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    KemoVoiceFigure(attributes: attributes, state: state, side: 48).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if state.isLive { KemoVoiceStopButton(tint: KemoVoiceFrames.color(attributes.themeAccent)) }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(attributes.name).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    KemoVoiceTurnText(state: state, foreground: .white, lines: 3).padding(.horizontal, 6)
                }
            } compactLeading: {
                KemoVoiceFrame(attributes: attributes, state: state, mini: true).frame(width: 24, height: 24)
            } compactTrailing: {
                KemoVoiceTrailingSign(state: state, tint: KemoVoiceFrames.color(attributes.themeAccent))
            } minimal: {
                KemoVoiceFrame(attributes: attributes, state: state, mini: true).frame(width: 22, height: 22)
            }
            .widgetURL(Self.conversation)
            .keylineTint(KemoVoiceFrames.color(attributes.themeAccent))
        }
    }
    /// Tapping the Live Activity opens the conversation.
    static let conversation = URL(string: "kemosabe://chat")!
}

/// The widget extension's stand-in for the app's implementation. `TalkToKemoIntent` and
/// `StopTalkingToKemoIntent` always run in the app's process, so these never do anything here.
enum VoiceAnywhereHost {
    static var companionName: String { "KemoSabe" }
    static func talk(_ intent: TalkToKemoIntent) async throws {}
    static func stop() async {}
}

import SwiftUI
import AVFoundation

/// Companion → Voice on iPhone (also the voice panel): <companion>'s voice (the one voice choice,
/// and pace), Listening (the microphone and its access), Conversation, and Voice models (what
/// listens and speaks, always the best this iPhone can run, and the one download), and OpenAI
/// (optional, off by default). The Mac's
/// Voice sheet has the same order and pieces.
struct VoiceSettingsView: View {
    var embeddedInAppearance = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mobilePalette) private var palette
    @Environment(AppStore.self) private var store
    @Environment(VoiceController.self) private var voice
    var body: some View {
        Group {
            if embeddedInAppearance { settingsForm }
            else {
                NavigationStack {
                    settingsForm.toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(role: .close) { dismiss() }.accessibilityIdentifier("closeVoiceSettings")
                        }
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await voice.recognitionAssets.refresh() }
        }
        .task {
            await voice.recognitionAssets.refresh()
            // Apple's newer recognizer comes with the better voice models once they're agreed to.
            if SpeechVoices.shared.betterModelsAgreed, voice.recognitionAssets.state == .needsDownload { await voice.recognitionAssets.download() }
        }
    }
    private var settingsForm: some View {
        Form {
            CompanionVoiceSection().modelsRow()
            Section("Listening") {
                Toggle("Microphone", isOn: Binding(get: { store.state.voiceEnabled == true }, set: { enabled in
                    if enabled { Task { await voice.requestPermissions(store: store) } }
                    else { store.state.voiceEnabled = false; store.save(); voice.deactivate() }
                })).disabled(voice.permissionsBusy).accessibilityIdentifier("enableVoice")
                if voice.permissionsBusy { OrbProgress("Requesting permission…", tint: store.state.theme.bodyColor) }
                else if voice.phase == .starting { OrbProgress("Starting microphone…", tint: store.state.theme.bodyColor) }
                if voice.phase == .unavailable {
                    Text(voice.status).font(KemoType.font(.caption)).foregroundStyle(.secondary)
                        .accessibilityIdentifier("voiceConnectionStatus")
                    Button("Retry microphone") { Task { await voice.requestPermissions(store: store) } }
                        .disabled(voice.permissionsBusy).accessibilityIdentifier("retryMicrophone")
                }
                if voice.recognitionAssets.downloading {
                    OrbProgress("Downloading better recognition…", tint: store.state.theme.bodyColor)
                        .accessibilityIdentifier("recognitionDownloadProgress")
                }
                if let message = voice.recognitionAssets.message {
                    Text(message).font(KemoType.font(.caption)).foregroundStyle(.secondary)
                        .accessibilityIdentifier("recognitionDownloadMessage")
                }
                NavigationLink { MicrophoneAccessPage() } label: { Text("Microphone access") }
                    .accessibilityIdentifier("microphoneAccess")
            }.modelsRow()
            Section("Conversation") {
                Toggle("Give me more time to finish", isOn: Binding(get: { store.state.patientListening == true }, set: { store.state.patientListening = $0; store.save() }))
                    .accessibilityIdentifier("patientListening")
                Toggle(isOn: Binding(get: { store.state.voiceInterruptions != false }, set: { store.state.voiceInterruptions = $0; store.save() })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Let me interrupt")
                        Text("Say “KemoSabe” or “hold on”").font(KemoType.font(.caption)).foregroundStyle(.secondary)
                    }
                }.accessibilityIdentifier("voiceInterruptions")
                Toggle("Show reply captions", isOn: Binding(get: { store.state.captionsEnabled != false }, set: { store.state.captionsEnabled = $0; store.save() }))
                    .accessibilityIdentifier("replyCaptions")
            }.modelsRow()
            VoiceModelsSection().modelsRow()
            OpenAIVoiceSection().modelsRow()
        }.scrollContentBackground(.hidden).background(palette.background.ignoresSafeArea())
            .navigationTitle("Voice").navigationBarTitleDisplayMode(.inline)
    }
}

/// Voice → Microphone access: what iOS allows now, and the way to change it.
struct MicrophoneAccessPage: View {
    @Environment(\.mobilePalette) private var palette
    @Environment(VoiceController.self) private var voice
    var body: some View {
        Form {
            Section {
                Text(voice.permissionSummary).accessibilityIdentifier("microphonePermissionSummary")
                if let diagnostic = voice.startupDiagnostic {
                    Text(diagnostic).font(KemoType.font(.caption2)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Button("Open iOS Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                    .accessibilityIdentifier("microphoneSystemSettings")
            }
        }.scrollContentBackground(.hidden).background(palette.background.ignoresSafeArea())
            .navigationTitle("Microphone access").navigationBarTitleDisplayMode(.inline)
    }
}

/// A thinking orb and a line of text, in place of a spinning wheel.
struct OrbProgress: View {
    let label: String
    var tint: Color
    init(_ label: String, tint: Color) { self.label = label; self.tint = tint }
    var body: some View {
        HStack(spacing: 10) {
            KemoOrb(size: 20, secondary: tint, state: .connecting).tint(tint)
            Text(label).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }
}

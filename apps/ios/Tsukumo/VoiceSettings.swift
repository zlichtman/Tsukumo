import AVFoundation
import Speech
import SwiftUI
import TsukumoCore
import TsukumoUI
import TsukumoVoice
import TsukumoMLXVoice

/// Settings, Models, Voice: the same cards as the Mac's, in the same order (TsukumoVoice's `VoiceCopy`):
/// what listens and speaks now (always the best this iPhone can run, no model menus), replies spoken and
/// their pace, the one download consent, each bot's voice, and how to talk to a bot.
struct VoiceSections: View {
    let voice: VoiceHub
    @Environment(AppModel.self) private var model
    @State private var confirmingDownload = false
    @State private var confirmingRemove = false
    @State private var editing: BotSpec?

    var body: some View {
        Section {
            status(voice.speechIn, symbol: "waveform")
            LabeledContent("Microphone", value: permission(AVAudioApplication.shared.recordPermission == .granted,
                                                           denied: AVAudioApplication.shared.recordPermission == .denied))
            LabeledContent("Speech recognition", value: permission(SFSpeechRecognizer.authorizationStatus() == .authorized,
                                                                   denied: SFSpeechRecognizer.authorizationStatus() == .denied))
        } header: {
            Text(VoiceCopy.listening)
        } footer: {
            Text("Apple’s recognizer shows your words as you talk. With Whisper here, it reads the same audio again on this iPhone and its text is what’s sent. Audio is only in memory and never leaves this iPhone.")
        }
        Section(VoiceCopy.speaking) {
            status(voice.speechOut, symbol: "speaker.wave.2")
            Toggle(isOn: Binding(get: { voice.settings.speaksReplies }, set: { voice.setSpeaksReplies($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(VoiceCopy.speakReplies)
                    Text(VoiceCopy.speakRepliesDetail).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("speakReplies")
            VStack(alignment: .leading) {
                LabeledContent(VoiceCopy.pace, value: paceText)
                Slider(value: Binding(get: { voice.settings.pace }, set: { voice.setPace($0) }), in: VoiceSettings.paceRange)
                    .accessibilityIdentifier("speakingPace")
            }
        }
        Section {
            if !voice.device.neuralSupported {
                Text(VoiceCopy.unsupported(device: "iPhone")).foregroundStyle(.secondary)
            } else if voice.offersDownload {
                Button { confirmingDownload = true } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(VoiceCopy.download)
                        Text(VoiceCopy.downloadDetail(device: "iPhone")).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("downloadVoiceModels")
            } else {
                modelRow(voice.whisper, detail: "Listening · OpenAI · MIT")
                modelRow(voice.kokoro, detail: "Speaking · hexgrad · Apache-2.0")
                Button(VoiceCopy.remove, role: .destructive) { confirmingRemove = true }
            }
            NavigationLink("Licenses") {
                ScrollView {
                    Text(MLXVoiceRuntime.noticeURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "")
                        .font(.caption.monospaced()).padding()
                }
                .navigationTitle("Licenses")
            }
        } header: {
            Text(VoiceCopy.models)
        } footer: {
            Text(VoiceCopy.footer)
        }
        Section {
            ForEach(model.bots) { bot in
                let sound = KokoroVoices.voice(for: bot)
                HStack(spacing: 12) {
                    Button { editing = bot } label: {
                        HStack(spacing: 12) {
                            BotAvatar(bot: bot, size: 30, showsEngine: false)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bot.name)
                                Text(sound.name + " · " + sound.detail).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button { voice.preview(sound, for: bot) } label: {
                        Image(systemName: voice.previewing == sound.id ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(voice.previewing == sound.id ? "Stop" : "Play \(bot.name)’s voice")
                }
                .accessibilityIdentifier("voiceBot-" + bot.name)
            }
        } header: {
            Text(VoiceCopy.voices)
        } footer: {
            Text(VoiceCopy.voicesFooter)
        }
        Section {
            Label("Tap the microphone to talk to the chat. It sends when you stop talking; tap again to send sooner.", systemImage: "mic")
            Label("Touch and hold a bot below the message box to talk just to it. Letting go sends.", systemImage: "hand.tap")
        } header: {
            Text(VoiceCopy.talking)
        } footer: {
            Text("What you say goes to the chat as your message. Talking over a reply stops it.")
        }
        .font(.subheadline)
        .confirmationDialog(VoiceCopy.consentTitle, isPresented: $confirmingDownload, titleVisibility: .visible) {
            Button("Download") { voice.downloadBetterModels() }
            Button("Cancel", role: .cancel) {}
        } message: { Text(VoiceCopy.consentMessage(device: "iPhone")) }
        .confirmationDialog(VoiceCopy.removeTitle, isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button(VoiceCopy.remove, role: .destructive) { voice.removeBetterModels() }
            Button("Cancel", role: .cancel) {}
        } message: { Text(VoiceCopy.removeMessage(device: "iPhone")) }
        .sheet(item: $editing) { bot in
            BotSettingsSheet(bot: bot, engines: model.engineChoices, device: "iPhone") { saved in
                if let problem = model.save(bot: saved) { return problem.message }
                editing = nil
                return nil
            } onCancel: { editing = nil }
            .environment(\.voice, voice)
        }
    }

    private var paceText: String {
        let pace = voice.settings.pace
        return abs(pace - 0.48) < 0.005 ? "Natural" : pace < 0.48 ? "Slower" : "Faster"
    }
    private func permission(_ allowed: Bool, denied: Bool) -> String {
        allowed ? "Allowed" : denied ? "Off in iOS Settings" : "Asked the first time"
    }
    private func status(_ line: VoiceStatusLine, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(.tint).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.title)
                Text(line.detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: line.best ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(line.best ? Color.green : Color.secondary)
        }
    }
    private func modelRow(_ store: VoiceModelStore, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(store.pack.title) {
                switch store.state {
                case .installed: Text("On this iPhone")
                case .downloading(let fraction): Text("\(Int((fraction * 100).rounded()))%").monospacedDigit()
                case .verifying: Text("Checking…")
                case .waitingForWiFi: Text("Waiting for Wi-Fi")
                case .failed: Button("Try Again") { store.download() }
                case .notDownloaded: Button("Download") { voice.downloadBetterModels() }
                }
            }
            if let fraction = store.state.fraction { ProgressView(value: fraction) }
            Text(detail + " · " + store.pack.sizeLabel).font(.footnote).foregroundStyle(.secondary)
            if case .waitingForWiFi = store.state {
                Button("Use cellular this time") { store.cancel(); store.wifiOnly = false; store.download() }.font(.footnote)
            }
            if case .failed(let reason) = store.state { Text(reason).font(.footnote).foregroundStyle(.secondary) }
        }
    }
}

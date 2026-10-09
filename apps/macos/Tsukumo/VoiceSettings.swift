import AppKit
import AVFoundation
import Speech
import SwiftUI
import TsukumoCore
import TsukumoUI
import TsukumoDock
import TsukumoVoice
import TsukumoMLXVoice

// Settings, Models, Voice (design/UI-GUIDE.md): what listens and what speaks now, always the best this Mac
// can run with no model menus; the one consent that downloads the better models; replies spoken and their
// pace; each bot's voice; and how to talk to a bot. The iPhone's Voice tab has the same cards in the same
// order (TsukumoVoice's `VoiceCopy`).

struct VoicePane: View {
    let voice: VoiceHub
    let dock: BotDock
    @State private var confirmingDownload = false
    @State private var confirmingRemove = false
    @State private var editing: UUID?
    @State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var speech = SFSpeechRecognizer.authorizationStatus()

    var body: some View {
        SettingsCard(VoiceCopy.listening, systemImage: "mic") {
            status(voice.speechIn, symbol: "waveform")
            Divider()
            permission("Microphone", allowed: microphone == .authorized, denied: microphone == .denied || microphone == .restricted,
                       pane: "Privacy_Microphone")
            Divider()
            permission("Speech recognition", allowed: speech == .authorized, denied: speech == .denied || speech == .restricted,
                       pane: "Privacy_SpeechRecognition")
            SettingsNote("Apple’s recognizer shows your words as you talk. With Whisper here, it reads the same audio again on this Mac and its text is what’s sent. Audio is only in memory and never leaves this Mac.")
        }
        SettingsCard(VoiceCopy.speaking, systemImage: "speaker.wave.2") {
            status(voice.speechOut, symbol: "speaker.wave.2")
            Divider()
            Toggle(isOn: Binding(get: { voice.settings.speaksReplies }, set: { voice.setSpeaksReplies($0) })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(VoiceCopy.speakReplies).font(.system(size: 13, weight: .medium))
                    Text(VoiceCopy.speakRepliesDetail).font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("speakReplies")
            SettingsSlider(VoiceCopy.pace, value: Binding(get: { voice.settings.pace }, set: { voice.setPace($0) }),
                           in: VoiceSettings.paceRange, valueText: paceText)
                .accessibilityIdentifier("speakingPace")
        }
        SettingsCard(VoiceCopy.models, systemImage: "arrow.down.circle") {
            models
        }
        SettingsCard(VoiceCopy.voices, systemImage: "person.wave.2") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(dock.bots.filter(\.engine.chats).enumerated()), id: \.element.id) { index, bot in
                    if index > 0 { Divider() }
                    let sound = KokoroVoices.voice(for: bot)
                    SettingsRow(bot.name, subtitle: sound.name + " · " + sound.detail) {
                        BotAvatar(bot: bot, size: 30, showsEngine: false)
                    } trailing: {
                        Button { voice.preview(sound, for: bot) } label: {
                            Image(systemName: voice.previewing == sound.id ? "stop.fill" : "play.fill")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(voice.previewing == sound.id ? "Stop" : "Play \(bot.name)’s voice")
                        Button { editing = bot.id } label: { SettingsChevron() }.buttonStyle(.plain).accessibilityLabel("Edit \(bot.name)")
                    }
                    .accessibilityIdentifier("voiceBot-" + (bot.isKemoSabe ? "kemosabe" : bot.name))
                }
            }
            SettingsNote(VoiceCopy.voicesFooter)
        }
        SettingsCard(VoiceCopy.talking, systemImage: "hand.tap") {
            VStack(alignment: .leading, spacing: 8) {
                SettingsRow("Click a bot in the dock", systemImage: "cursorarrow.click", subtitle: "It listens until you stop talking, then sends. Click again to send sooner.") {}
                Divider()
                SettingsRow("Hold, then let go", systemImage: "hand.point.up.left", subtitle: "Hold a bot while you talk; letting go sends.") {}
                Divider()
                SettingsRow("Double-click", systemImage: "bubble.left", subtitle: "Opens the bot’s chat. So does its right-click menu.") {}
                Divider()
                SettingsRow(DockPushToTalk.shortcut, systemImage: "keyboard", subtitle: "Talks to the bot in front (its chat if open, or the one you last talked to), from any app.") {}
            }
            SettingsNote("What you say goes to that bot’s chat as your message. Talking over a reply stops it.")
        }
        .confirmationDialog(VoiceCopy.consentTitle, isPresented: $confirmingDownload) {
            Button("Download") { voice.downloadBetterModels() }
            Button("Cancel", role: .cancel) {}
        } message: { Text(VoiceCopy.consentMessage(device: "Mac")) }
        .confirmationDialog(VoiceCopy.removeTitle, isPresented: $confirmingRemove) {
            Button(VoiceCopy.remove, role: .destructive) { voice.removeBetterModels() }
            Button("Cancel", role: .cancel) {}
        } message: { Text(VoiceCopy.removeMessage(device: "Mac")) }
        .sheet(item: Binding(get: { editing.map(EditingBot.init) }, set: { editing = $0?.id })) { target in
            if let bot = dock.bot(target.id) {
                DockBotPanel(dock: dock, bot: bot, inSettings: true) { editing = nil }
                    .frame(width: DockMetrics.panel.width, height: DockMetrics.panel.height)
                    .environment(\.voice, voice)
            }
        }
        .onAppear {
            microphone = AVCaptureDevice.authorizationStatus(for: .audio)
            speech = SFSpeechRecognizer.authorizationStatus()
            voice.whisper.refresh(); voice.kokoro.refresh()
        }
    }

    private struct EditingBot: Identifiable { let id: UUID }

    private var paceText: String {
        let pace = voice.settings.pace
        return abs(pace - 0.48) < 0.005 ? "Natural" : pace < 0.48 ? "Slower" : "Faster"
    }

    private func status(_ line: VoiceStatusLine, symbol: String) -> some View {
        SettingsRow(line.title, systemImage: symbol, subtitle: line.detail) {
            Image(systemName: line.best ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(line.best ? Color.green : Color.secondary)
                .accessibilityLabel(line.best ? "The best this Mac can run" : "A better model can run here")
        }
    }

    private func permission(_ title: String, allowed: Bool, denied: Bool, pane: String) -> some View {
        SettingsRow(title, systemImage: allowed ? "checkmark.shield" : "shield", subtitle: allowed ? "Allowed" : denied ? "Off" : "Tsukumo asks the first time you talk to a bot.") {
            if denied {
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
                }
            }
        }
    }

    @ViewBuilder private var models: some View {
        if !voice.device.neuralSupported {
            SettingsNote(VoiceCopy.unsupported(device: "Mac"))
        } else if voice.offersDownload {
            SettingsRow("Whisper and Kokoro", systemImage: "cpu", subtitle: VoiceCopy.downloadDetail(device: "Mac")) {
                Button(VoiceCopy.download) { confirmingDownload = true }.accessibilityIdentifier("downloadVoiceModels")
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                modelRow(voice.whisper, title: "Whisper", detail: "Listening · OpenAI · MIT")
                Divider()
                modelRow(voice.kokoro, title: "Kokoro", detail: "Speaking · hexgrad · Apache-2.0")
            }
            if voice.whisper.isInstalled && voice.kokoro.isInstalled {
                SettingsNote(VoiceCopy.installed(device: "Mac"))
            }
            Button(VoiceCopy.remove, role: .destructive) { confirmingRemove = true }.accessibilityIdentifier("removeVoiceModels")
        }
        SettingsNote(VoiceCopy.footer)
        Button("Licenses…") { if let url = MLXVoiceRuntime.noticeURL { NSWorkspace.shared.open(url) } }
            .buttonStyle(.link).font(.caption)
    }

    private func modelRow(_ store: VoiceModelStore, title: String, detail: String) -> some View {
        SettingsRow(title, systemImage: store.isInstalled ? "checkmark.circle" : "arrow.down.circle",
                    subtitle: detail + " · " + store.pack.sizeLabel) {
            switch store.state {
            case .installed: Text("On this Mac").font(.caption).foregroundStyle(.secondary)
            case .downloading(let fraction):
                ProgressView(value: fraction).frame(width: 120)
                Text("\(Int((fraction * 100).rounded()))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            case .verifying: Text("Checking…").font(.caption).foregroundStyle(.secondary)
            case .waitingForWiFi:
                Text("Waiting for Wi-Fi").font(.caption).foregroundStyle(.secondary)
                Button("Use any network this time") { store.cancel(); store.wifiOnly = false; store.download() }
            case .failed(let reason):
                Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Button("Try Again") { store.download() }
            case .notDownloaded:
                Button("Download") { voice.downloadBetterModels() }
            }
        }
    }
}

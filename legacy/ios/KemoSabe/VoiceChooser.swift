import SwiftUI
import AVFoundation
#if os(iOS)
import UIKit
#endif

/// Companion → Voice → <Name>'s voice, the same on iPhone and Mac: the one voice choice there is,
/// which voice the companion sounds like (Kokoro's voices, and your own once it's made in Models →
/// Training), each with a play button, then the speaking pace. What model speaks it is never a
/// choice (`VoiceAuto`): where MLX can't run, Apple's best voice speaks, and the list says so.
struct CompanionVoiceSection: View {
    @Environment(AppStore.self) private var store
    #if os(iOS)
    @Environment(VoiceController.self) private var conversation
    #endif
    @State private var voices = SpeechVoices.shared
    @State private var previewer = VoicePreviewer()
    @State private var apple = VoiceCatalog.available
    @State private var betterApple = false

    var body: some View {
        Section {
            if voices.device.neuralSupported {
                ForEach(KokoroVoices.all) { voice in
                    let id = "voice-kokoro-" + voice.id
                    VoiceChoiceRow(id: id, title: voice.name, detail: voice.detail,
                                   selected: voices.persona == .kokoro(voice.id),
                                   previewer: previewer, playDisabled: !voices.kokoro.isInstalled || previewBlocked,
                                   choose: { voices.choose(.kokoro(voice.id)) }, play: { play(id, .kokoro(voice.id)) })
                }
                if voices.own.isEnrolled {
                    VoiceChoiceRow(id: "voice-own", title: SpeechEngineKind.ownVoice.title, detail: voices.pocket.isInstalled ? nil : "Speaks once its model is on this device",
                                   selected: voices.persona == .own,
                                   previewer: previewer, playDisabled: !voices.pocket.isInstalled || previewBlocked,
                                   choose: { voices.choose(.own) }, play: { play("voice-own", .ownVoice) })
                }
            } else {
                // Kokoro and your own voice need Apple silicon's GPU: this device speaks with Apple's best voice.
                VoiceChoiceRow(id: "voice-apple-best", title: apple.first?.name ?? "Apple voice",
                               detail: apple.first.map { Self.languageName($0.language) + " · " + VoiceCatalog.quality($0) },
                               selected: true, previewer: previewer, playDisabled: previewBlocked,
                               choose: {}, play: { play("voice-apple-best", .apple(nil)) })
            }
            if !VoiceCatalog.hasDownloadedHighQualityVoice(in: apple) {
                Button { betterApple = true } label: {
                    HStack {
                        Label("Get better Apple voices", systemImage: "arrow.down.circle")
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("betterAppleVoices")
            }
            // Sheets and observers hang on one row: modifiers on a Section in a List apply to each of its rows.
            pace
                .sheet(isPresented: $betterApple) { BetterAppleVoicesSheet() }
                .onReceive(NotificationCenter.default.publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)) { _ in apple = VoiceCatalog.available }
                #if os(iOS)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in apple = VoiceCatalog.available }
                .onChange(of: conversation.permissionsBusy) { if conversation.permissionsBusy { previewer.stop() } }
                .onChange(of: conversation.phase) { if conversationLive { previewer.stop() } }
                #endif
                .onReceive(NotificationCenter.default.publisher(for: AccountSettingsAdapter.didApply)) { _ in voices.reload() }
                .onDisappear { previewer.stop() }
        } header: { Text("\(CompanionIdentity.name)'s voice") } footer: {
            Text(speakingLine).accessibilityIdentifier("voiceFallbackLine")
        }
    }

    /// What speaks now, in one line, when it isn't the chosen voice.
    private var speakingLine: String {
        let device = voices.device
        if CloudVoice.activeVoice(in: store) != nil { return "An OpenAI voice speaks while it's on under OpenAI below." }
        guard device.neuralSupported else { return "This device speaks with Apple's best voice." }
        switch VoiceAuto.speaking(device, persona: voices.persona) {
        case .apple: return "Apple's best voice speaks until the better voice models are on this device."
        case .kokoro where voices.persona == .own: return "Kokoro speaks until your voice's model is on this device."
        default: return "Speaks on this device. If it can't, Apple's best voice does."
        }
    }

    private var pace: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("Speaking pace"); Spacer(); Text(paceLabel).foregroundStyle(.secondary) }
            Slider(value: Binding(get: { store.state.speechRate ?? 0.48 }, set: { store.state.speechRate = $0; store.save() }), in: 0.40...0.56, step: 0.02)
                .accessibilityLabel("Speaking pace").accessibilityIdentifier("speechRate")
        }
    }
    private var paceLabel: String {
        let rate = store.state.speechRate ?? 0.48
        return rate < 0.46 ? "Unhurried" : rate > 0.50 ? "Brisk" : "Natural"
    }
    static func languageName(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code
    }

    #if os(iOS)
    private var conversationLive: Bool { [.listening, .speaking, .thinking, .starting].contains(conversation.phase) }
    #endif
    /// While the conversation microphone is live, a sample would be heard as speech, so samples wait.
    private var previewBlocked: Bool {
        #if os(iOS)
        return conversation.permissionsBusy || conversationLive
        #else
        return false
        #endif
    }
    private func play(_ id: String, _ sample: VoicePreviewer.Sample) {
        previewer.toggle(id, sample, store: store, voices: voices)
    }
}

/// Companion → Voice → Voice models, the same on iPhone and Mac: what listens and what speaks now,
/// always the best this device can run (`VoiceAuto`), with no model menus. When a better model could
/// run here and isn't downloaded, one row asks once to download them all ("Download better voice
/// models", their total size); after that they download in the background on Wi-Fi and are used as
/// soon as they're ready. Remove takes them off this device.
struct VoiceModelsSection: View {
    @Environment(AppStore.self) private var store
    #if os(iOS)
    @Environment(VoiceController.self) private var voice
    #endif
    @State private var voices = SpeechVoices.shared
    @State private var confirming = false
    @State private var removing = false

    private var totalLabel: String {
        "\(Int((Double(voices.missing.map(\.totalBytes).reduce(0, +)) / 1_000_000).rounded())) MB"
    }
    var body: some View {
        Section {
            LabeledContent("Listening") { Text(VoiceAuto.listeningTitle(voices.listening(openAI: CloudVoice.activeTranscriber(in: store)))).foregroundStyle(.secondary) }
                .accessibilityIdentifier("voiceListeningModel")
            LabeledContent("Speaking") { Text(VoiceAuto.speakingTitle(voices.route(openAIVoice: CloudVoice.activeVoice(in: store)), appleVoice: VoiceCatalog.available.first?.name)).foregroundStyle(.secondary) }
                .accessibilityIdentifier("voiceSpeakingModel")
            if !voices.missing.isEmpty {
                if voices.betterModelsAgreed {
                    ForEach([voices.whisper, voices.kokoro].filter { !$0.isInstalled }, id: \.pack.id) { model in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(model.pack.title + " · " + model.pack.shortSizeLabel).font(KemoType.font(.caption)).foregroundStyle(.secondary)
                            if case .failed(let message) = model.state {
                                HStack {
                                    Text(message).font(KemoType.font(.caption)).foregroundStyle(.orange)
                                    Spacer()
                                    Button("Try again") { model.download() }.buttonStyle(.bordered).buttonBorderShape(.capsule).font(KemoType.font(.caption, weight: .semibold))
                                }
                            } else if model.state == .notDownloaded {
                                Text("Waiting to download").font(KemoType.font(.caption)).foregroundStyle(.secondary)
                            }
                            VoiceModelProgress(model: model)
                        }
                    }
                } else {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Better voice models")
                            Text("Whisper and Kokoro, on this device · \(totalLabel)").font(KemoType.font(.caption)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Download") { confirming = true }
                            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).font(KemoType.font(.caption, weight: .semibold))
                            .accessibilityIdentifier("downloadBetterVoiceModels")
                    }
                }
            }
            if voices.whisper.isInstalled || voices.kokoro.isInstalled || voices.betterModelsAgreed {
                Button("Remove voice models", role: .destructive) { removing = true }
                    .buttonStyle(.borderless).accessibilityIdentifier("removeVoiceModels")
            }
            // Dialogs hang on this always-present row: modifiers on a Section in a List apply to each row.
            AboutVoicesLink()
                .confirmationDialog("Download better voice models?", isPresented: $confirming, titleVisibility: .visible) {
                    Button("Download \(totalLabel) on Wi-Fi") { voices.downloadBetterModels(); downloadRecognition() }
                        .accessibilityIdentifier("confirmBetterVoiceModels")
                } message: {
                    Text("Whisper for listening and Kokoro for speaking, from Hugging Face, pinned and checked. They stay on this device and run on it: nothing you say or hear is sent anywhere. They download in the background on Wi-Fi and are used as soon as they're ready.")
                }
                .confirmationDialog("Remove voice models?", isPresented: $removing, titleVisibility: .visible) {
                    Button("Remove", role: .destructive) { voices.removeBetterModels() }.accessibilityIdentifier("confirmRemoveVoiceModels")
                } message: { Text("Apple's recognizer and Apple's best voice take over. You can download them again here.") }
        } header: { Text("Voice models") } footer: {
            Text(voices.device.neuralSupported ? "Always the best this device can run." : "This device runs Apple's voice models, the best it can.")
        }
    }
    /// On iPhone, Apple's newer recognizer comes with them: it's Apple's own on-device model.
    private func downloadRecognition() {
        #if os(iOS)
        if voice.recognitionAssets.state == .needsDownload { Task { await voice.recognitionAssets.download() } }
        #endif
    }
}

/// One voice: tap the row to choose it (a checkmark shows the choice); the play button hears it.
struct VoiceChoiceRow: View {
    let id: String
    let title: String
    let detail: String?
    var badge: String? = nil
    let selected: Bool
    let previewer: VoicePreviewer
    var playDisabled = false
    let choose: () -> Void
    let play: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: choose) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.tint)
                        .opacity(selected ? 1 : 0).frame(width: 18).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).foregroundStyle(.primary)
                        if let failure = previewer.failure(for: id) {
                            Text(failure).font(KemoType.font(.caption)).foregroundStyle(.secondary)
                        } else if let detail {
                            Text(detail).font(KemoType.font(.caption)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                    if let badge {
                        Text(badge).font(KemoType.font(.caption2, weight: .semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 3).background(.secondary.opacity(0.12), in: Capsule())
                    }
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .accessibilityIdentifier(id)
            let playing = previewer.playing == id
            Button(action: play) {
                Image(systemName: playing ? "stop.fill" : "play.fill").font(.footnote.weight(.semibold))
                    .frame(width: 30, height: 30).background(.secondary.opacity(0.12), in: Circle())
            }
            .buttonStyle(.borderless).disabled(playDisabled && !playing)
            .accessibilityLabel(playing ? "Stop \(title)" : "Play \(title)")
            .accessibilityValue(playing ? "Playing" : "")
            .accessibilityIdentifier("play-" + id)
        }
    }
}

/// A model that isn't on this device yet: its size and a Download button, with progress, Cancel,
/// and Wi-Fi waiting shown in the row itself.
struct VoiceDownloadRow: View {
    let model: VoiceModelStore
    let id: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail).font(KemoType.font(.caption)).foregroundStyle(.secondary)
                    if !NeuralSpeechRuntime.isSupported {
                        Text("Not available on this device").font(KemoType.font(.caption)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                switch model.state {
                case .notDownloaded, .failed:
                    Button(model.state == .notDownloaded ? "Download" : "Try again") { model.download() }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).font(KemoType.font(.caption, weight: .semibold))
                        .disabled(!NeuralSpeechRuntime.isSupported).accessibilityIdentifier(id + "-download")
                default: EmptyView()
                }
            }
            if case .failed(let message) = model.state {
                Text(message).font(KemoType.font(.caption)).foregroundStyle(.secondary)
            }
            VoiceModelProgress(model: model)
        }
    }
}

/// Progress for a model download: a thinking orb with the percentage, a thin bar, and Cancel
/// (plus "Use cellular this time" while waiting for Wi-Fi). Nothing when idle or installed.
struct VoiceModelProgress: View {
    let model: VoiceModelStore
    @Environment(AppStore.self) private var store

    var body: some View {
        switch model.state {
        case .waitingForWiFi:
            line("Waiting for Wi-Fi…", fraction: nil)
            HStack {
                Button("Cancel") { model.cancel() }
                Button("Use cellular this time") { model.cancel(); model.wifiOnly = false; model.download() }
            }.buttonStyle(.bordered).buttonBorderShape(.capsule).font(KemoType.font(.caption, weight: .semibold))
        case .downloading(let fraction):
            line("Downloading… \(Int((fraction * 100).rounded()))%", fraction: fraction)
            Button("Cancel") { model.cancel() }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                .font(KemoType.font(.caption, weight: .semibold)).accessibilityIdentifier(model.pack.id + "-cancel")
        case .verifying:
            line("Checking the download…", fraction: nil)
        default: EmptyView()
        }
    }
    private func line(_ label: String, fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                KemoOrb(size: 20, secondary: store.state.theme.bodyColor, state: .connecting).tint(store.state.theme.bodyColor)
                Text(label).font(KemoType.font(.caption)).foregroundStyle(.secondary)
            }
            if let fraction {
                Capsule().fill(.secondary.opacity(0.15)).frame(height: 4)
                    .overlay(alignment: .leading) {
                        GeometryReader { proxy in Capsule().fill(store.state.theme.bodyColor).frame(width: proxy.size.width * fraction) }
                    }
                    .accessibilityElement().accessibilityLabel(label)
            }
        }
    }
}

/// Where to get Premium and Enhanced Apple voices, as a short sheet with one close button.
struct BetterAppleVoicesSheet: View {
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    static let path = "System Settings → Accessibility → Read & Speak → System voice"
    #else
    static let path = "Settings → Accessibility → Read & Speak → Voices → English"
    #endif
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Premium and Enhanced voices sound much more natural.")
                    Label(Self.path, systemImage: "gearshape").font(KemoType.font(.body, weight: .semibold))
                        .accessibilityIdentifier("betterAppleVoicesPath")
                    Text("Download a Premium or Enhanced voice there. KemoSabe uses the best one whenever an Apple voice speaks.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Better Apple voices")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }.accessibilityIdentifier("closeBetterAppleVoices")
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium])
        #else
        .frame(minWidth: 420, minHeight: 220)
        #endif
    }
}

/// Plays a short sample of any voice from its row. Under UI testing it plays nothing: it only
/// marks the row as playing for a moment, so tests can check the control without audio.
@MainActor @Observable final class VoicePreviewer: NSObject, AVSpeechSynthesizerDelegate {
    enum Sample: Equatable { case apple(String?), kokoro(String), ownVoice, openAI(String) }
    static var stubbed: Bool { ProcessInfo.processInfo.arguments.contains("--ui-testing") }
    static let line = "Morning. What would make today a good day? We can start with one thing."
    static let ownLine = "Hi, it's me. This is how your KemoSabe will sound when it reads a reply."

    private(set) var playing: String?
    private var failed: (id: String, message: String)?
    /// Made on first use: SwiftUI makes a previewer whenever the list's view is rebuilt.
    @ObservationIgnored private var synthesizer: AVSpeechSynthesizer?
    @ObservationIgnored private let player = SpeechPlayer()
    @ObservationIgnored private var stubTask: Task<Void, Never>?

    func failure(for id: String) -> String? { failed?.id == id ? failed?.message : nil }

    func toggle(_ id: String, _ sample: Sample, store: AppStore, voices: SpeechVoices) {
        if playing == id { stop(); return }
        stop()
        failed = nil
        playing = id
        if Self.stubbed {
            stubTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, self?.playing == id else { return }
                self?.playing = nil
            }
            return
        }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        switch sample {
        case .apple(let voiceID):
            let synthesizer = self.synthesizer ?? AVSpeechSynthesizer()
            synthesizer.delegate = self; self.synthesizer = synthesizer
            #if os(iOS)
            synthesizer.usesApplicationAudioSession = false
            #endif
            synthesizer.speak(VoiceCatalog.utterance(for: Self.line, voiceID: voiceID, rate: store.state.speechRate))
        case .kokoro(let voice):
            playEngine(id, voices.engine(for: .kokoro(voice: voice), appleRate: store.state.speechRate), line: Self.line, voice: voice)
        case .ownVoice:
            playEngine(id, voices.engine(for: .ownVoice, appleRate: store.state.speechRate), line: Self.ownLine, voice: nil)
        case .openAI(let voice):
            playEngine(id, OpenAISpeechEngine(key: CloudVoice.key(in: store)), line: Self.line, voice: voice)
        }
    }
    func stop() {
        stubTask?.cancel(); stubTask = nil
        player.stop()
        synthesizer?.stopSpeaking(at: .immediate)
        playing = nil
    }
    private func playEngine(_ id: String, _ engine: any SpeechEngine, line: String, voice: String?) {
        player.play(line, engine: engine, voice: voice) { [weak self] error, _ in
            guard let self, self.playing == id else { return }
            self.playing = nil
            if let error { self.failed = (id, (error as? LocalizedError)?.errorDescription ?? "The voice couldn't play.") }
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in if self.playing?.hasPrefix("voice-apple") == true { self.playing = nil } }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {}
}

extension VoiceModelPack {
    /// The size rounded to whole megabytes, for a one-line row ("341 MB").
    var shortSizeLabel: String { "\(Int((Double(totalBytes) / 1_000_000).rounded())) MB" }
}

/// Companion → Voice → OpenAI (optional), the same on iPhone and Mac: two switches, off by default.
/// "Speak with an OpenAI voice" (then which voice, with a sample) and "Transcribe with OpenAI" (then
/// which model). Turning either on confirms first, naming api.openai.com and what goes there, and uses
/// the key of the OpenAI connection in Models → LLM. While on, it replaces only that part of the
/// automatic on-device choice; everything else stays on the device. Kept per device, like the key.
struct OpenAIVoiceSection: View {
    @Environment(AppStore.self) private var store
    @State private var speaking = CloudVoice.speaking
    @State private var voice = CloudVoice.replyVoice
    @State private var transcriber = CloudVoice.transcriber
    @State private var confirmingSpeaking = false
    @State private var confirmingTranscription = false
    @State private var previewer = VoicePreviewer()

    var body: some View {
        let connected = CloudVoice.connection(in: store) != nil
        Section {
            Toggle(isOn: Binding(get: { speaking }, set: { on in
                if on { confirmingSpeaking = true } else { CloudVoice.speaking = false; speaking = false }
            })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Speak with an OpenAI voice")
                    Text("Sends the text of replies to \(CloudVoice.host)").font(KemoType.font(.caption)).foregroundStyle(.secondary)
                }
            }
            .disabled(!connected && !speaking).accessibilityIdentifier("openAIVoicesOptIn")
            if speaking {
                HStack {
                    Picker("OpenAI voice", selection: Binding(get: { voice }, set: { voice = $0; CloudVoice.replyVoice = $0 })) {
                        ForEach(CloudVoice.voices, id: \.self) { Text($0.capitalized).tag($0) }
                    }.accessibilityIdentifier("openAIVoice")
                    Button { previewer.toggle("voice-openai-" + voice, .openAI(voice), store: store, voices: SpeechVoices.shared) } label: {
                        Image(systemName: previewer.playing == "voice-openai-" + voice ? "stop.fill" : "play.fill").font(.footnote.weight(.semibold))
                            .frame(width: 30, height: 30).background(.secondary.opacity(0.12), in: Circle())
                    }.buttonStyle(.borderless).disabled(!connected).accessibilityLabel("Play \(voice.capitalized)")
                }
            }
            Toggle(isOn: Binding(get: { transcriber != nil }, set: { on in
                if on { confirmingTranscription = true } else { CloudVoice.transcriber = nil; transcriber = nil }
            })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transcribe with OpenAI")
                    Text("Sends what you say to \(CloudVoice.host)").font(KemoType.font(.caption)).foregroundStyle(.secondary)
                }
            }
            .disabled(!connected && transcriber == nil).accessibilityIdentifier("openAITranscription")
            if let current = transcriber {
                Picker("Model", selection: Binding(get: { current }, set: { transcriber = $0; CloudVoice.transcriber = $0 })) {
                    ForEach(CloudVoice.Transcriber.allCases) { Text($0.title).tag($0) }
                }.accessibilityIdentifier("transcriptionModel")
            }
            if !connected {
                Text("Needs your OpenAI connection's key on this \(AppleAccountSession.device). Add one in Models → LLM → Add a connection.")
                    .font(KemoType.font(.caption)).foregroundStyle(.secondary).accessibilityIdentifier("openAINeedsConnection")
            }
        } header: { Text("OpenAI (optional)") } footer: {
            Text("Off by default. When on, it replaces only what you turned on; everything else stays on this device.")
        }
        .confirmationDialog("Use OpenAI voices?", isPresented: $confirmingSpeaking, titleVisibility: .visible) {
            Button("Send replies to \(CloudVoice.host)") { CloudVoice.speaking = true; speaking = true }.accessibilityIdentifier("confirmOpenAIVoices")
        } message: { Text("The text of \(CompanionIdentity.name)'s spoken replies, which can include your private context, is sent to \(CloudVoice.host) with your OpenAI key to be turned into speech.") }
        .confirmationDialog("Transcribe with OpenAI?", isPresented: $confirmingTranscription, titleVisibility: .visible) {
            Button("Send audio to \(CloudVoice.host)") { CloudVoice.transcriber = .gpt4oTranscribe; transcriber = .gpt4oTranscribe }
                .accessibilityIdentifier("confirmOpenAITranscription")
        } message: { Text("Each thing you say to KemoSabe is recorded until you finish and sent to \(CloudVoice.host) with your OpenAI key. OpenAI's data policies apply. Recordings aren't kept on this device.") }
        .onDisappear { previewer.stop() }
    }
}

import SwiftUI
import AVFoundation

/// Setting up "Your voice", one sheet with labels and buttons only: the model's download row,
/// a quick check of the room, a few short passages (each checked on the device, each can be
/// redone), the consent line, then Hear it, Record more, Start over, and Save. Only live takes
/// made here can become the voice.
struct OwnVoiceEnrollmentView: View {
    let voices: SpeechVoices
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    #if os(iOS)
    @Environment(AppNavigation.self) private var navigation
    #endif
    @State private var trainer = OwnVoiceTrainer()
    @State private var saveError: String?

    private var session: OwnVoiceSession { trainer.session }
    private var accent: Color { store.state.theme.bodyColor }

    var body: some View {
        NavigationStack {
            Form {
                if !voices.pocket.isInstalled {
                    Section {
                        VoiceDownloadRow(model: voices.pocket, id: "pocket", title: "Your voice model",
                                         detail: "On-device · " + voices.pocket.pack.shortSizeLabel)
                    }
                }
                roomSection
                if session.stage != .roomCheck { takesSection }
                if session.stage == .consent || session.consent == .accepted { consentSection }
                if session.stage == .building || session.stage == .preview { voiceSection }
                if let message = trainer.problem ?? saveError {
                    Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
                        .font(KemoType.font(.caption))
                }
            }
            .navigationTitle("Your voice")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { trainer.discard(); dismiss() }.accessibilityIdentifier("closeOwnVoice")
                }
            }
            .animation(.snappy, value: session)
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 600)
        #endif
        #if os(iOS)
        .onAppear { navigation.voiceBlocks.insert("voiceEnrollment") }
        .onDisappear { navigation.voiceBlocks.remove("voiceEnrollment"); trainer.discard() }
        #else
        .onDisappear { trainer.discard() }
        #endif
    }

    // MARK: Room

    @ViewBuilder private var roomSection: some View {
        Section("Quiet check") {
            switch session.room {
            case .notStarted:
                Button("Check the room", systemImage: "ear") { Task { await trainer.checkRoom() } }
                    .accessibilityIdentifier("ownVoiceCheckRoom")
            case .measuring:
                HStack(spacing: 10) {
                    KemoOrb(size: 20, secondary: accent, state: .listening).tint(accent)
                    Text("Listening to the room…").foregroundStyle(.secondary)
                    Spacer()
                    Text("\(max(0, Int((OwnVoiceEnrollment.quietCheckSeconds - trainer.elapsed).rounded(.up))))s").monospacedDigit().foregroundStyle(.secondary)
                }
            case .done(let noise):
                if noise.isNoisy {
                    Label("It's a little noisy here. Try a quieter room.", systemImage: "speaker.wave.3")
                        .accessibilityIdentifier("ownVoiceNoisy")
                    if session.stage == .roomCheck {
                        HStack {
                            Button("Check again") { Task { await trainer.checkRoom() } }.accessibilityIdentifier("ownVoiceCheckAgain")
                            Spacer()
                            Button("Continue anyway") { trainer.continueInNoisyRoom() }.accessibilityIdentifier("ownVoiceContinueAnyway")
                        }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                    }
                } else {
                    Label("Quiet enough", systemImage: "checkmark.circle.fill").accessibilityIdentifier("ownVoiceQuiet")
                }
            }
        }
    }

    // MARK: Takes

    @ViewBuilder private var takesSection: some View {
        let done = session.acceptedTakes.count
        Section {
            ForEach(session.takes) { take in takeRow(take) }
        } header: {
            HStack { Text("Read aloud"); Spacer(); Text("\(done) of \(session.takes.count)").monospacedDigit() }
        }
    }

    @ViewBuilder private func takeRow(_ take: OwnVoiceSession.Take) -> some View {
        let isCurrent = session.currentTake?.id == take.id && session.stage == .takes
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                statusIcon(take.status)
                Text(take.passage.text)
                    .font(isCurrent ? KemoType.font(.title3, weight: .semibold) : KemoType.font(.callout))
                    .foregroundStyle(isCurrent || take.status == .recording ? .primary : .secondary)
                    .textSelection(.disabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if take.status == .accepted || isRedo(take.status) {
                    Button("Redo") { trainer.redo(take.id) }
                        .buttonStyle(.borderless).font(KemoType.font(.caption, weight: .semibold))
                        .disabled(session.isBusy).accessibilityIdentifier("ownVoiceRedo-\(take.id)")
                }
            }
            if case .redo(let reason) = take.status {
                Text(reason).font(KemoType.font(.caption)).foregroundStyle(.secondary).accessibilityIdentifier("ownVoiceTakeProblem-\(take.id)")
            }
            switch take.status {
            case .recording: recordingControls
            case .checking:
                HStack(spacing: 10) { KemoOrb(size: 18, secondary: accent, state: .working).tint(accent); Text("Checking…").foregroundStyle(.secondary) }
                    .font(KemoType.font(.caption))
            default:
                if isCurrent && !session.isBusy {
                    Button(isRedo(take.status) ? "Record again" : "Record", systemImage: "mic.fill") { Task { await trainer.record(take.id) } }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).font(KemoType.font(.callout, weight: .semibold))
                        .accessibilityIdentifier("ownVoiceRecordTake")
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ownVoiceTake-\(take.id)")
    }

    private func isRedo(_ status: OwnVoiceSession.Status) -> Bool { if case .redo = status { return true }; return false }

    @ViewBuilder private func statusIcon(_ status: OwnVoiceSession.Status) -> some View {
        Group {
            switch status {
            case .accepted: Image(systemName: "checkmark.circle.fill").foregroundStyle(accent)
            case .redo: Image(systemName: "arrow.counterclockwise.circle").foregroundStyle(.orange)
            case .recording: Image(systemName: "record.circle").foregroundStyle(.red)
            default: Image(systemName: "circle").foregroundStyle(.tertiary)
            }
        }.font(.body.weight(.semibold)).frame(width: 20).accessibilityHidden(true)
    }

    /// The live meter while a take records: level, Too quiet / Too loud, and a clipping warning.
    private var recordingControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            LevelMeter(level: trainer.level, feedback: trainer.feedback, clipping: trainer.clipping, accent: accent)
            HStack(spacing: 12) {
                if trainer.clipping {
                    Label("Clipping", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        .accessibilityIdentifier("ownVoiceClipping")
                } else if let label = trainer.feedback.label {
                    Text(label).foregroundStyle(.orange).accessibilityIdentifier("ownVoiceLevelFeedback")
                } else {
                    Text("Recording").foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int(trainer.elapsed))s").monospacedDigit().foregroundStyle(.secondary)
                Button("Done") { trainer.stop() }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                    .accessibilityIdentifier("ownVoiceStopTake")
            }.font(KemoType.font(.caption, weight: .semibold))
        }
    }

    // MARK: Consent

    @ViewBuilder private var consentSection: some View {
        Section("Say this") {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                statusIcon(session.consent)
                Text("“\(OwnVoiceEnrollment.consentLine)”").font(KemoType.font(.title3, weight: .semibold))
            }
            if case .redo(let reason) = session.consent { Text(reason).font(KemoType.font(.caption)).foregroundStyle(.secondary) }
            switch session.consent {
            case .recording: recordingControls
            case .checking:
                HStack(spacing: 10) { KemoOrb(size: 18, secondary: accent, state: .working).tint(accent); Text("Checking…").foregroundStyle(.secondary) }
                    .font(KemoType.font(.caption))
            case .accepted: EmptyView()
            default:
                if session.stage == .consent && !session.isBusy {
                    Button("Say the consent line", systemImage: "mic.fill") { Task { await trainer.recordConsent() } }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).font(KemoType.font(.callout, weight: .semibold))
                        .accessibilityIdentifier("ownVoiceRecordConsent")
                }
            }
        }
    }

    // MARK: The voice

    @ViewBuilder private var voiceSection: some View {
        Section {
            if session.stage == .building {
                HStack(spacing: 10) { KemoOrb(size: 20, secondary: accent, state: .working).tint(accent); Text("Building your voice…").foregroundStyle(.secondary) }
                    .accessibilityIdentifier("ownVoiceBuilding")
            } else {
                HStack {
                    Label("Your voice is ready", systemImage: "waveform").accessibilityIdentifier("ownVoiceReady")
                    Spacer()
                    Button(trainer.hearing ? "Stop" : "Hear it", systemImage: trainer.hearing ? "stop.fill" : "play.fill") {
                        trainer.hearIt(model: voices.pocket)
                    }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule)
                    .disabled(!voices.pocket.isInstalled && !previewStubbed)
                    .accessibilityValue(trainer.hearing ? "Playing" : "")
                    .accessibilityIdentifier("ownVoiceHearIt")
                }
                HStack {
                    Button("Record more", systemImage: "plus") { trainer.recordMore() }
                        .disabled(!session.canRecordMore).accessibilityIdentifier("ownVoiceRecordMore")
                    Spacer()
                    Button("Start over") { saveError = nil; trainer.startOver() }.accessibilityIdentifier("ownVoiceStartOver")
                }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                Button("Save my voice") { save() }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).frame(maxWidth: .infinity)
                    .disabled(!voices.pocket.isInstalled).accessibilityIdentifier("saveOwnVoice")
            }
        }.font(KemoType.font(.callout, weight: .semibold))
    }

    private var previewStubbed: Bool {
        #if DEBUG
        OwnVoiceStub.isActive
        #else
        false
        #endif
    }

    private func save() {
        do {
            let model = "mlx-community/pocket-tts@" + (VoiceModelPack.pocketTTS.sources.first?.revision ?? "unknown")
            guard let take = try trainer.finishedTake(model: model) else { return }
            try voices.own.save(take)
            trainer.discard()
            // Making your voice chooses it as the companion's voice (Companion → Voice changes it back).
            voices.choose(.own)
            dismiss()
        } catch { saveError = "Your voice couldn't be saved: \(error.localizedDescription)" }
    }
}

/// A thin live level bar: the accent while the level is good, orange when too quiet or too
/// loud, red when the take clips.
struct LevelMeter: View {
    let level: Float
    let feedback: OwnVoiceAudio.LevelFeedback
    let clipping: Bool
    let accent: Color
    var body: some View {
        let color: Color = clipping ? .red : (feedback == .tooQuiet || feedback == .tooLoud) ? .orange : accent
        Capsule().fill(.secondary.opacity(0.15)).frame(height: 8)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule().fill(color).frame(width: max(8, proxy.size.width * CGFloat(level)))
                        .animation(.linear(duration: 0.08), value: level)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Input level")
            .accessibilityValue(clipping ? "Clipping" : feedback.label ?? "Good")
            .accessibilityIdentifier("ownVoiceMeter")
    }
}

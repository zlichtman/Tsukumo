import SwiftUI

/// Companion → Voice → About voices, the same on iPhone and Mac: which models listen and speak and
/// why (always the best this device can run), where voice downloads come from, what stays on the
/// device, the licenses, the Your voice consent and privacy terms, Apple Watch, and when KemoSabe
/// listens. The Voice page itself keeps only controls.
struct AboutVoicesPage: View {
    #if os(macOS)
    private static let listening = "Dictation starts when you tap the microphone beside your message. Switching apps or models stops the microphone, and your model gets the text only when you press Send. Audio isn't saved."
    private static let whisperFallback = "If Whisper fails or takes too long, Apple's text is used."
    #else
    private static let whisperFallback = "It runs only while KemoSabe is open and your iPhone is unlocked. In the background, while locked, and in Talk to KemoSabe, Apple's recognizer is used, and it is too if Whisper fails or takes too long. Apple Watch requests use Whisper only while KemoSabe is open on your iPhone."
    private static let listening = "Listens while the app is open, except in editors and permission screens. Audio isn't saved."
    #endif

    var body: some View {
        Form {
            Section("Always the best model") {
                paragraph("There's no voice model to choose. KemoSabe listens with Whisper once it's on this device, and with Apple's recognizer until then. It speaks with Kokoro once it's on this device (or your own voice, when you choose it and it's ready), and with Apple's best installed voice until then, or where they can't run.")
                paragraph("Every one of them runs on this device. Nothing you say or hear is sent to a voice service unless you turn on OpenAI below.")
            }
            Section("Downloads") {
                paragraph("Kokoro (\(VoiceModelPack.kokoro.shortSizeLabel)), the Your voice model (\(VoiceModelPack.pocketTTS.shortSizeLabel)), and Whisper (\(VoiceModelPack.whisper.shortSizeLabel)) download from huggingface.co, pinned to exact files and checked by SHA-256 before they're used.")
                paragraph("They're kept on this device only, not backed up or synced. They run on this device; nothing you hear or say is sent anywhere.")
                paragraph("On-device voices need Apple silicon's GPU, so they can't run in the Simulator. On iPhone they speak only while the app is open; otherwise an Apple voice speaks.")
            }
            Section("Your voice") {
                paragraph("KemoSabe can read its replies in your own voice, cloned on this device. After a quick check of the room, you read a few short passages (a calm one, a question, an exclamation) and say a consent line: “\(OwnVoiceEnrollment.consentLine)” Every take is checked with on-device speech recognition before anything is saved. It only works with your own live recording; there's no file import.")
                paragraph("The takes are cleaned up on this device: rumble filtered out, background noise reduced when the room was noisy (Apple's sound isolation where it's available), silence trimmed, and levels evened out. Clipped takes are recorded again. The best takes, about 18 seconds of them, become your voice. For the best result, record in a quiet room with the phone a hand's width from your mouth.")
                paragraph("Pocket TTS's terms prohibit cloning a voice without explicit, lawful consent, so KemoSabe clones only your own.")
                paragraph("Only your own voice, only for your own KemoSabe's read-aloud. Your recordings stay in your account's folder on this device with full file protection; they're never uploaded, synced, or backed up, and Delete removes all of it.")
            }
            Section("Apple voices") {
                paragraph("When an Apple voice speaks, it's the best one installed: Premium, then Enhanced. To get one: \(BetterAppleVoicesSheet.path), then download a Premium or Enhanced voice.")
                paragraph("Apple Watch reads replies with an Apple voice on the watch. None of the downloaded voices run on the watch.")
            }
            Section("Whisper on this device") {
                paragraph("OpenAI's Whisper (large-v3-turbo, 4-bit) runs on this device. Apple's recognizer still shows your words as you speak; when you finish, Whisper reads the same audio again and its text replaces Apple's before anything is sent or put in the message box. The audio stays on this device and isn't saved.")
                paragraph(Self.whisperFallback)
            }
            Section("OpenAI (optional)") {
                paragraph("Off by default, under OpenAI on the Voice page. Transcribe with OpenAI sends what you say to KemoSabe to \(CloudVoice.host) with your OpenAI connection's key (dictation on Mac, and voice on iPhone and Apple Watch), and Speak with an OpenAI voice sends the text of spoken replies, which can include your private context. OpenAI's data policies apply, and recordings aren't kept on this device. Each replaces only what you turned on; if OpenAI can't be reached, the on-device choice is used.")
            }
            Section("Listening") {
                paragraph(Self.listening).accessibilityIdentifier("aboutListening")
                #if os(iOS)
                paragraph("Say “KemoSabe” or “hold on” to interrupt. Interrupting works with echo-cancelled audio routes.")
                #else
                paragraph("Read aloud stops when you dictate or send a message, and a reply is never read over dictation.")
                #endif
            }
            Section("Licenses") {
                license("Kokoro-82M", "hexgrad · Apache-2.0")
                license("Misaki English lexicons", "hexgrad · Apache-2.0")
                license("kitten-tts-g2p", "beshkenadze · MIT")
                license("Pocket TTS", "Kyutai · CC-BY-4.0")
                license("Whisper large-v3-turbo", "OpenAI · MIT")
                license("mlx-audio-swift", "Prince Canuma · MIT")
                license("MLX Swift", "ml-explore · MIT")
                license("Hugging Face Swift packages", "Apache-2.0")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("About voices")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier("aboutVoices")
    }
    private func paragraph(_ text: String) -> some View {
        Text(text).font(KemoType.font(.subheadline)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private func license(_ name: String, _ detail: String) -> some View {
        LabeledContent(name) { Text(detail).multilineTextAlignment(.trailing) }.font(KemoType.font(.subheadline))
    }
}

/// The "About voices" row: a navigation row on iPhone, a sheet on Mac (its settings pages aren't
/// in a navigation stack).
struct AboutVoicesLink: View {
    #if os(macOS)
    @State private var showing = false
    #endif
    var body: some View {
        #if os(iOS)
        NavigationLink { ThemedAboutVoices() } label: { Text("About voices") }
            .accessibilityIdentifier("openAboutVoices")
        #else
        Button { showing = true } label: {
            HStack { Text("About voices"); Spacer(); Image(systemName: "chevron.right").foregroundStyle(.tertiary) }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityIdentifier("openAboutVoices")
        .sheet(isPresented: $showing) {
            NavigationStack {
                AboutVoicesPage().toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(role: .close) { showing = false }.accessibilityIdentifier("closeAboutVoices") }
                }
            }.frame(minWidth: 520, minHeight: 560)
        }
        #endif
    }
}

#if os(iOS)
/// About voices on the app theme's background, like every iPhone surface.
private struct ThemedAboutVoices: View {
    @Environment(\.mobilePalette) private var palette
    var body: some View {
        AboutVoicesPage().scrollContentBackground(.hidden).background(palette.background.ignoresSafeArea())
    }
}
#endif

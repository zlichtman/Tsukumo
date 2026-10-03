import SwiftUI
#if os(iOS)
import PhotosUI
#endif

/// Every chat control in one panel: the message, images and attached docs, model choice,
/// conversations (iPhone), new conversation, microphone, and send. Shared by the iPhone app (aligned with
/// the tab bar) and Tsukumo on Mac; each passes its own theme colors.
struct ChatComposerPanel: View {
    #if os(macOS)
    @Environment(DesktopPreferences.self) private var desktopPreferences
    private var contentFont: Font { desktopPreferences.font(content: true) }
    #else
    private var contentFont: Font { KemoType.font(.body) }
    #endif
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    @Binding var text: String
    @Binding var images: [ChatImage]
    var surface: Color
    var accent: Color
    /// "Message Mochi…" ("Message Claude…" in a chat with Claude), or "Listening…" while voice fills
    /// the box. The composer is the one place that shows listening: this and the microphone's small orb.
    var listening = false
    private var placeholder: String { listening ? "Listening…" : "Message \(chatAgent?.title ?? CompanionIdentity.name)…" }
    var attachmentRequest: Int
    var microphoneOn: Bool
    var microphoneBusy: Bool
    var microphoneUnavailable: Bool
    var send: () -> Void
    var cancel: () -> Void
    var attach: () -> Void
    var newConversation: () -> Void
    /// Opens the conversation list. The Mac has its own sidebar and passes nil.
    var openConversations: (() -> Void)? = nil
    var toggleMicrophone: () -> Void
    var focusChanged: (Bool) -> Void
    @FocusState private var focused: Bool
    @State private var taps = 0
    /// The model chip's power-up picker (a popover on Mac, a sheet on iPhone) and Add model after it.
    @State private var choosingModel = false
    @State private var addAfterPicker = false
    @State private var addingModel = false
    @State private var pickerHeight: CGFloat = 320
    @State private var pickerDetent: PresentationDetent = .height(320)
    /// Choosing a doc or journal entry to attach, and one waiting for its destination to be confirmed.
    @State private var attachingScope: DocAttachmentPicker.Scope?
    @State private var confirmingAttachment: ChatDocAttachment?
    #if os(iOS)
    @State private var shooting = false
    @State private var pickingPhotos = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
    #endif

    /// Agents this device can chat with; the chip names the one this chat talks to.
    @Environment(\.chatAgents) private var agents
    /// A device that can't list its agents (iPhone) still names the one this chat is with.
    private var chatAgent: ChatAgentOption? {
        store.state.chatAgent.flatMap { id in agents.first { $0.id == id } ?? ChatAgentOption.known(id) }
    }
    /// Apple's local model is text-only; only an image-capable API connection accepts images.
    private var acceptsImages: Bool { store.modelRoute == .api && store.activeAPIProfile?.supportsImages == true }
    /// Kemo answering, or an agent this chat talks to working (Stop ends its turn).
    private var busy: Bool { store.isThinking || store.handoffWorking != nil }
    /// The row is tight on iPhone once it holds six controls; the picker shows the full name.
    private var compactModelLabel: String {
        if openConversations != nil { return store.modelRoute == .onDevice ? store.appleModel.compactTitle : store.modelLabel }
        // On Mac there's room for the chosen effort, as on Tsukumo's coding chip.
        return store.modelLabel + (store.currentEffort.map { " · " + EffortWeight.title($0) } ?? "")
    }
    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var hasAttachments: Bool { !store.composerAttachments.isEmpty }
    /// `@` being typed: docs matching it are offered to attach.
    private var mention: (start: Int, query: String)? { DocShortcuts.token("@", in: text) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ChatAttachmentTray(images: $images, showAttachButton: false, request: attachmentRequest)
            // The context this chat started with (`ContextPacket`), removable at any time.
            ContextPacketChatCard()
            ChatDocChips()
            if let mention {
                DocMentionSuggestions(query: mention.query) { attachment in
                    text = DocShortcuts.removing(tokenAt: mention.start, in: text)
                    attachDoc(attachment)
                }
            }
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...6).font(contentFont).textFieldStyle(.plain)
                .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 4)
                .focused($focused).submitLabel(.send).onSubmit(submit)
                .accessibilityIdentifier("chatInput")
            HStack(spacing: openConversations == nil ? 8 : 6) {
                // Images need a model that takes them; docs and journal entries attach with any of Apple's or a connected model.
                addImages.disabled(busy)
                Button { taps += 1; choosingModel = true } label: {
                    HStack(spacing: 5) {
                        // The lock means nothing leaves this device: only Apple's on-device model is in use
                        // (not Private Cloud, which runs on Apple's servers).
                        if let chatAgent {
                            ChatAgentLogo(logo: chatAgent.logo, title: chatAgent.title, size: 15)
                            Text(chatAgent.title).lineLimit(1)
                        } else {
                            if store.runsOnlyOnDevice { Image(systemName: "lock.fill").font(.system(size: 10, weight: .semibold)).accessibilityHidden(true) }
                            Text(compactModelLabel).lineLimit(1)
                        }
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    }.font(KemoType.font(.footnote, weight: .medium)).padding(.horizontal, 13).frame(height: 38)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                        .overlay(Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
                }.buttonStyle(PressableButtonStyle())
                    .accessibilityLabel(chatAgent.map { "Chatting with " + $0.title + ($0.detail.isEmpty ? "" : ", " + $0.detail) } ?? "Model, " + store.modelLabel + (store.runsOnlyOnDevice ? ", private on this device" : ""))
                    .accessibilityIdentifier("chooseModel")
                #if os(macOS)
                    .popover(isPresented: $choosingModel, arrowEdge: .top) { modelPicker(touch: false) }
                #endif
                Spacer(minLength: 0)
                if let openConversations {
                    ControlCircle(symbol: "bubble.left.and.bubble.right", label: "Conversations", identifier: "openConversations") { taps += 1; openConversations() }
                }
                ControlCircle(symbol: "square.and.pencil", label: "New conversation", identifier: "newConversation") { taps += 1; newConversation() }
                    .disabled(store.conversationMessages.isEmpty && !busy)
                ControlCircle(symbol: microphoneOn ? "mic.fill" : "mic",
                              label: microphoneUnavailable ? "Retry microphone" : microphoneOn ? "Turn microphone off" : "Turn microphone on",
                              identifier: "microphoneToggle", tint: microphoneOn ? accent : nil, busy: microphoneBusy,
                              // A still icon, except while it's actually taking your voice; never a thinking indicator.
                              orb: listening && !microphoneUnavailable ? .listening : nil) {
                    focused = false; taps += 1; toggleMicrophone()
                }.disabled(microphoneBusy)
                    .accessibilityValue(microphoneBusy ? "Starting" : listening ? "Listening" : microphoneOn ? "On" : "Off")
                Button { if busy { cancel() } else { submit() } } label: {
                    Image(systemName: busy ? "stop.fill" : "arrow.up").font(.system(size: 16, weight: .semibold))
                        .frame(width: 38, height: 38)
                        .foregroundStyle(colorScheme == .dark ? Color.black.opacity(0.85) : Color.white)
                        .background(accent.opacity(busy || hasText || !images.isEmpty || hasAttachments ? 1 : 0.45), in: Circle())
                }.buttonStyle(PressableButtonStyle())
                    .disabled(!busy && images.isEmpty && !hasText && !hasAttachments)
                    .accessibilityLabel(busy ? "Stop response" : "Send message").accessibilityIdentifier("sendMessage")
            }
            // In a chat with an agent, the message goes to the agent; KemoSabe only assists, on this
            // device, which is what the lock is for (the chip itself has none).
            if let chatAgent {
                HStack(spacing: 5) {
                    Image(systemName: "lock.fill").font(.system(size: 9, weight: .semibold)).accessibilityHidden(true)
                    Text("\(CompanionIdentity.name) assists on this \(AgentDevice.name)").lineLimit(1)
                    if !chatAgent.detail.isEmpty {
                        Text("· " + chatAgent.detail).lineLimit(1).truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }.font(KemoType.font(.caption2)).foregroundStyle(.secondary).padding(.horizontal, 8)
                    .accessibilityElement(children: .combine).accessibilityIdentifier("chatAgentAssist")
            }
        }
        .padding(10)
        .background(surface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Color.primary.opacity(focused ? 0.16 : 0.08), lineWidth: 0.75))
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
        .onChange(of: focused) { focusChanged(focused) }
        .onDisappear { focusChanged(false) }
        .sheet(isPresented: $addingModel) { APIProfileEditor().environment(store) }
        #if os(macOS)
        .onChange(of: choosingModel) { if !choosingModel && addAfterPicker { addAfterPicker = false; addingModel = true } }
        #else
        .sheet(isPresented: $choosingModel, onDismiss: { if addAfterPicker { addAfterPicker = false; addingModel = true } }) {
            // Sized to what it shows (the effort page or the list), and able to grow for a long list.
            ScrollView { modelPicker(touch: true).onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                let fitted = min(max(height + 36, 240), 640)
                if pickerDetent != .large { pickerDetent = .height(fitted) }
                pickerHeight = fitted
            } }
                .scrollBounceBehavior(.basedOnSize)
                .presentationDetents([.height(pickerHeight), .large], selection: $pickerDetent)
                .presentationDragIndicator(.visible)
                .presentationBackground(surface)
        }
        #endif
        .sheet(item: $attachingScope) { scope in DocAttachmentPicker(scope: scope) { attachDoc($0) } }
        .docAttachmentConfirmation($confirmingAttachment, store: store)
        #if os(iOS)
        .fullScreenCover(isPresented: $shooting) {
            CameraSheet { photo in Task { try? await attachPhotos([photo.jpeg]) } }
        }
        .photosPicker(isPresented: $pickingPhotos, selection: $pickedPhotos, maxSelectionCount: max(1, 4 - images.count), matching: .images)
        .onChange(of: pickedPhotos) { attachPicked() }
        #endif
    }
    private func modelPicker(touch: Bool) -> some View {
        // UI tests wait for the app to settle, so the sparkles stand still there.
        ChatModelPopover(accent: accent, touch: touch, animate: !ProcessInfo.processInfo.arguments.contains("--ui-testing"), addModel: { addAfterPicker = true; choosingModel = false }, close: { choosingModel = false })
            .environment(store)
    }
    /// The +: images (on iPhone the camera, the photo library, and Files; on Mac, Files), which
    /// need a model that takes images, then a doc or a journal entry.
    @ViewBuilder private var addImages: some View {
        Menu {
            #if os(iOS)
            Button("Camera", systemImage: "camera") { taps += 1; shooting = true }.accessibilityIdentifier("attachCamera")
                .disabled(!acceptsImages || images.count >= 4)
            Button("Photo Library", systemImage: "photo.on.rectangle") { taps += 1; pickingPhotos = true }.accessibilityIdentifier("attachLibrary")
                .disabled(!acceptsImages || images.count >= 4)
            Button("Files", systemImage: "folder") { taps += 1; attach() }.accessibilityIdentifier("attachFiles")
                .disabled(!acceptsImages || images.count >= 4)
            #else
            Button("Images…", systemImage: "photo") { taps += 1; attach() }.accessibilityIdentifier("attachFiles")
                .disabled(!acceptsImages || images.count >= 4)
            #endif
            Divider()
            Button("Doc", systemImage: "doc.text") { taps += 1; attachingScope = .docs }.accessibilityIdentifier("attachDoc")
            Button("Journal entry", systemImage: "book.closed") { taps += 1; attachingScope = .journal }.accessibilityIdentifier("attachJournal")
        } label: { ControlCircleLabel(symbol: "plus") }
            .menuStyle(.button).buttonStyle(PressableButtonStyle()).menuIndicator(.hidden)
            .accessibilityLabel("Attach").accessibilityIdentifier("attachImages")
    }
    /// Attaches a doc now, or first names where it goes when that isn't only this device.
    private func attachDoc(_ attachment: ChatDocAttachment) {
        confirmingAttachment = store.attachOrConfirm(attachment)
    }
    #if os(iOS)
    private func attachPicked() {
        let items = pickedPhotos
        guard !items.isEmpty else { return }
        pickedPhotos = []
        Task {
            var photos: [Data] = []
            for item in items { if let data = try? await PickedImage.load(item) { photos.append(data) } }
            do { try await attachPhotos(photos) } catch { store.error = error.localizedDescription }
        }
    }
    /// Prepares photos as chat images (re-encoded, no metadata) while the model still accepts them.
    private func attachPhotos(_ photos: [Data]) async throws {
        guard acceptsImages else { throw ChatImageError.unsupported }
        guard images.count + photos.count <= 4 else { throw ChatImageError.limit }
        let prepared = try await Task.detached(priority: .userInitiated) { try photos.map(ChatImage.prepare) }.value
        guard acceptsImages, images.count + prepared.count <= 4 else { throw ChatImageError.limit }
        images += prepared
    }
    #endif
    private func submit() {
        guard !busy, !images.isEmpty || hasText || hasAttachments else { return }
        // A doc attached with no message asks Kemo to look at it.
        if !hasText, images.isEmpty, let first = store.composerAttachments.first {
            text = store.composerAttachments.count == 1 ? "Take a look at “\(first.title)”." : "Take a look at these."
        }
        focused = false; send()
    }
}

/// A round, pressable control shared by the composer's attach, new conversation,
/// and microphone buttons.
private struct ControlCircle: View {
    let symbol: String
    let label: String
    let identifier: String
    var tint: Color? = nil
    var busy = false
    /// Shown in place of the symbol, such as the listening orb while the microphone is on.
    var orb: OrbState? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) { ControlCircleLabel(symbol: symbol, tint: tint, busy: busy, orb: orb) }
            .buttonStyle(PressableButtonStyle()).accessibilityLabel(label).accessibilityIdentifier(identifier)
    }
}

/// The round face of a composer control, shared by buttons and the image menu.
private struct ControlCircleLabel: View {
    let symbol: String
    var tint: Color? = nil
    var busy = false
    var orb: OrbState? = nil
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        Group {
            if busy { KemoOrb(size: 18, state: .connecting) }
            else if let orb { KemoOrb(size: 26, state: orb).tint(tint ?? .primary) }
            else { Image(systemName: symbol).font(.system(size: 17, weight: .medium)) }
        }.frame(width: 38, height: 38)
            .foregroundStyle(tint ?? Color.primary.opacity(isEnabled ? 0.82 : 0.28))
            .background(Color.primary.opacity(isEnabled ? 0.07 : 0.035), in: Circle())
            .overlay(Circle().stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
            .contentShape(Circle())
    }
}

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

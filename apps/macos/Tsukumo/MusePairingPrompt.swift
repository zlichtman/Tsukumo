import AppKit
import SwiftUI
import TsukumoDock
import TsukumoMuse

// The window that asks the owner to allow a phone pairing as their Muse device. Community pairing
// (`confirm_app`) has only the phone's word for it, so nothing secret leaves the Mac and no provisioning is
// accepted until the owner clicks Allow here. Deny, closing the window, or a minute passing refuses it.

@MainActor final class MusePairingPrompt {
    private var window: NSPanel?
    private let muse: MuseGadget

    init(muse: MuseGadget) { self.muse = muse }

    func show() {
        if window == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 340), styleMask: [.titled, .closable],
                                backing: .buffered, defer: false)
            panel.title = "Pair with Muse"
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.contentView = NSHostingView(rootView: MusePairingPromptView(muse: muse) { [weak self] in self?.close() })
            window = panel
        }
        window?.center()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.orderOut(nil) }
}

struct MusePairingPromptView: View {
    let muse: MuseGadget
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A phone wants to pair as your Muse device").font(.system(size: 15, weight: .semibold))
            if let confirmation = muse.confirmation {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Code").foregroundStyle(.secondary)
                    Text(Self.spaced(confirmation.code)).font(.system(size: 28, weight: .semibold, design: .monospaced))
                        .accessibilityLabel(confirmation.code.map(String.init).joined(separator: " "))
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("\(max(0, Int(confirmation.until.timeIntervalSince(context.date)))) s").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            if let peer = muse.confirmation?.peer {
                Text("Phone: \(peer)").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Text(MusePairingPromptView.warning(muse.deviceName))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Deny") { muse.answerConfirmation(false); close() }.keyboardShortcut(.cancelAction)
                Button("Allow") { muse.answerConfirmation(true); close() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440, height: 340, alignment: .topLeading)
        .onChange(of: muse.confirmation) { _, now in if now == nil { close() } }
    }

    /// Meta's community pairing has no manufacturer check and can't stop an active man-in-the-middle (the SDK's own
    /// words), and the Muse app shows no matching code, so the owner's judgment is the check.
    static func warning(_ name: String) -> String {
        "Meta’s community pairing can’t verify which phone this is, and the Muse app doesn’t show a matching code. Allow it only if you started pairing \(name) in the Muse app on your own phone just now, at home and away from strangers. If you didn’t start this, click Deny. Nothing is sent to the phone until you allow it."
    }

    static func spaced(_ code: String) -> String { code.count == 6 ? String(code.prefix(3)) + " " + String(code.suffix(3)) : code }
}

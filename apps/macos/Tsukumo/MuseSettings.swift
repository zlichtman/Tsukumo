import AppKit
import SwiftUI
import TsukumoDock
import TsukumoMuse

// Settings, Bots, Muse: Tsukumo's Dock as a Muse gadget (Muse's own page among the bots; it pairs over this Mac's
// Bluetooth). The owner's own SDK token, what Tsukumo offers Muse and what it never does, Pair (Bluetooth for five
// minutes and one pairing, opened as soon as the token is saved, with the steps and the owner allowing the phone),
// whether the Muse app can see this Mac now (or why not, with System Settings one click away, and what to try when
// it can't find it), the connection, and Unpair. Off until there's a token and a pairing. Once paired, Muse is a
// caller of the KemoSabe gateway: its grants, activity, and Revoke are on the same page.

struct MuseCard: View {
    let muse: MuseGadget
    @State private var token = ""
    @State private var tokenProblem: String?
    @State private var confirmUnpair = false
    @State private var confirmRemove = false
    @State private var sending = false

    var body: some View {
        SettingsCard("Muse", systemImage: "antenna.radiowaves.left.and.right") {
            VStack(alignment: .leading, spacing: 10) {
                SettingsNote("Muse, Meta’s assistant, can call Tsukumo from your Muse chat. Tsukumo is a caller like your other agents: Muse asks, KemoSabe answers only what you allow, and Muse gets only the answer. Tsukumo isn’t made or endorsed by Meta.")
                status
                Divider()
                if muse.hasToken { tokenSaved } else { tokenEntry }
                if muse.hasToken {
                    Divider()
                    pairing
                }
                if muse.bluetooth.isProblem || muse.bluetooth == .starting { bluetoothLine }
                Divider()
                disclosure
            }
        }
        .confirmationDialog("Unpair Muse from this Mac?", isPresented: $confirmUnpair) {
            Button("Unpair", role: .destructive) { muse.unpair() }
        } message: {
            Text("Muse won’t reach Tsukumo until you pair again. Remove \(muse.deviceName) in the Muse app too, in Settings, Devices.")
        }
        .confirmationDialog("Remove your SDK token?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { muse.removeToken() }
        } message: {
            Text("This turns Muse off on this Mac: it unpairs and forgets the token.")
        }
    }

    // MARK: Status

    private var status: some View {
        HStack(spacing: 8) {
            Circle().fill(dot).frame(width: 8, height: 8)
            Text(statusText).font(.system(size: 13, weight: .medium))
            Spacer(minLength: 8)
            Text(muse.deviceName).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
    private var dot: Color {
        switch muse.phase {
        case .connected: .green
        case .connecting, .pairing: .orange
        case .retrying, .problem: .yellow
        case .needsToken, .notPaired: .secondary
        }
    }
    private var statusText: String {
        switch muse.phase {
        case .needsToken: "Off: add your SDK token to start"
        case .notPaired: "Not paired yet"
        case .pairing: "Pairing is open"
        case .connecting: "Connecting to Muse…"
        case .connected: "Connected to your Muse"
        case .retrying(let why): why + " Trying again soon."
        case .problem(let why): why
        }
    }

    // MARK: The SDK token

    private var tokenEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your SDK token").font(.system(size: 13, weight: .medium))
            HStack(spacing: 8) {
                SecureField("mgst_…", text: $token).textFieldStyle(.roundedBorder).frame(maxWidth: 360)
                    .accessibilityIdentifier("museToken")
                Button("Save") {
                    tokenProblem = muse.setToken(token)
                    if tokenProblem == nil { token = "" }
                }
                .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let tokenProblem { SettingsNote(tokenProblem, warning: true) }
            SettingsNote("After you save it, pairing opens right away: then add \(muse.deviceName) in the Muse app.")
            Link("Get your own token at gadgets.muse.ai", destination: MuseSDKToken.settingsURL).font(.caption)
            SettingsNote("Every gadget needs its owner’s own token. Yours is kept in this Mac’s Keychain, goes only to Muse, and is never part of Tsukumo itself.")
        }
    }

    private var tokenSaved: some View {
        SettingsRow("SDK token", systemImage: "key", subtitle: "Saved in this Mac’s Keychain") {
            Button("Remove…") { confirmRemove = true }
        }
    }

    // MARK: Pairing

    @ViewBuilder private var pairing: some View {
        switch muse.phase {
        case .pairing(let until):
            VStack(alignment: .leading, spacing: 8) {
                if let confirmation = muse.confirmation {
                    HStack(spacing: 8) {
                        Text("A phone wants to pair · code \(MusePairingPromptView.spaced(confirmation.code))" + (confirmation.peer.map { " · \($0)" } ?? ""))
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Button("Deny") { muse.answerConfirmation(false) }
                        Button("Allow") { muse.answerConfirmation(true) }.keyboardShortcut(.defaultAction)
                    }
                    SettingsNote(MusePairingPromptView.warning(muse.deviceName))
                }
                HStack {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        if case .visible(let name) = muse.bluetooth {
                            Label(MuseBluetoothStatus.visibleLine(name, until: until, now: context.date), systemImage: "dot.radiowaves.left.and.right")
                                .font(.system(size: 13, weight: .medium)).foregroundStyle(.green)
                                .accessibilityIdentifier("museVisible")
                        } else {
                            let left = max(0, Int(until.timeIntervalSince(context.date)))
                            Text("Pairing is open for \(left / 60):\(String(format: "%02d", left % 60)) · " + (muse.bluetooth.message ?? "Starting Bluetooth…"))
                                .font(.system(size: 13, weight: .medium))
                        }
                    }
                    Spacer()
                    Button("Cancel") { muse.cancelPairing() }
                }
                ForEach(Array(Self.steps(muse.deviceName).enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(step).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let step = muse.pairingStep { SettingsNote(step) }
                cantFindIt
            }
        default:
            if muse.isPaired {
                HStack(spacing: 8) {
                    if muse.phase == .connected {
                        Button(sending ? "Sending…" : "Send a Test Message") {
                            sending = true
                            Task { await muse.sendTestMessage(); sending = false }
                        }
                        .disabled(sending)
                    }
                    Spacer()
                    Button("Unpair…") { confirmUnpair = true }
                }
                if let result = muse.testResult { SettingsNote(result) }
            } else {
                SettingsRow("Next: pair with the Muse app", systemImage: "dot.radiowaves.left.and.right",
                            subtitle: "Click Pair, then add \(muse.deviceName) in the Muse app. It opens Bluetooth on this Mac for 5 minutes, once; you allow the phone here before anything is sent.") {
                    Button("Pair") { muse.pair() }.buttonStyle(.borderedProminent).accessibilityIdentifier("musePair")
                }
            }
        }
    }

    /// Bluetooth starting, or why the Muse app can't see this Mac, with the fix one click away.
    private var bluetoothLine: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: muse.bluetooth.isProblem ? "exclamationmark.triangle.fill" : "antenna.radiowaves.left.and.right")
                .foregroundStyle(muse.bluetooth.isProblem ? .orange : .secondary)
            Text(muse.bluetooth.message ?? "").font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if muse.bluetooth.opensBluetoothSettings {
                Button("Open Bluetooth Settings") { NSWorkspace.shared.open(MuseBluetoothStatus.settingsURL) }
                    .accessibilityIdentifier("museBluetoothSettings")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("museBluetooth")
    }

    /// What to try when the Muse app doesn't list this Mac.
    private var cantFindIt: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Can’t find it?").font(.system(size: 12, weight: .semibold))
            SettingsNote("Check that Tsukumo may use Bluetooth (System Settings, Privacy & Security, Bluetooth). See whether \(muse.deviceName) shows in a Bluetooth scanner app on your phone, such as nRF Connect. The Muse app may look for the device’s own Bluetooth name, and macOS uses your Mac’s name: for a moment, rename this Mac to \(muse.deviceName) in System Settings, General, About, then rename it back after pairing.")
            Button("Open Bluetooth Settings") { NSWorkspace.shared.open(MuseBluetoothStatus.settingsURL) }.buttonStyle(.link).font(.caption)
        }
        .accessibilityIdentifier("museCantFindIt")
    }

    static func steps(_ name: String) -> [String] {
        [
            "In the Muse app on your phone, open Settings, Devices, and turn on Developer mode.",
            "Tap Add Device (the + at the top right) and choose \(name).",
            "Muse says it’s a community device. Continue: it’s your Mac.",
            "On this Mac, a window asks you to allow the phone. Click Allow if it’s you pairing right now.",
            "When it asks for Wi‑Fi, pick “Use current connection”. No password is needed; your Mac is already online.",
        ]
    }

    // MARK: What Tsukumo offers

    private var disclosure: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What Muse can ask for").font(.system(size: 13, weight: .medium))
            ForEach(Self.offers, id: \.self) { line in
                Label(line, systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
            }
            Text("What it never gets").font(.system(size: 13, weight: .medium)).padding(.top, 4)
            ForEach(Self.never, id: \.self) { line in
                Label(line, systemImage: "xmark").font(.caption).foregroundStyle(.secondary)
            }
            SettingsNote("Meta’s community pairing has no manufacturer check and can’t stop someone nearby from posing as your phone. Pair at home, away from strangers, and deny any pairing prompt you didn’t start. Tsukumo talks only to api.muse.ai and hatch.metaaivm.com. What Muse asks shows in Activity, on KemoSabe’s cards, and on this page, on this Mac only.")
            HStack(spacing: 12) {
                Link("Muse Gadget SDK terms", destination: MuseSDKToken.termsURL).font(.caption)
                if let notice = MuseNotice.url {
                    Button("License…") { NSWorkspace.shared.open(notice) }.buttonStyle(.link).font(.caption)
                }
            }
        }
    }

    static let offers = [
        "Ask KemoSabe a question about you. You decide on a card in KemoSabe’s chat first, unless you let Muse ask without asking; Muse gets only the answer.",
        "Check when you’re free (busy or free blocks only), or a contact’s first name and one way to reach them, under the rules you set in Settings, Gateway.",
        "See your bots’ names, jobs, and what they run on.",
        "Hand a task to one of your bots (never a coding bot). It runs in a fresh session with only Muse’s words: no chat history, tools, or anything of yours. The reply goes to Muse only through KemoSabe, the first time on KemoSabe’s card, and the gateway’s ledger records it.",
        "How long this Mac has been up.",
    ]
    static let never = [
        "A shell, commands, or your files: Tsukumo doesn’t offer them.",
        "Anything KemoSabe didn’t answer, and never what’s Device only or Secret.",
        "Your API keys or sign-ins, or your chats with your bots.",
        "A coding bot: Muse can’t see or use one.",
    ]
}

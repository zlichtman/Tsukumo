import Foundation
import LocalAuthentication
import Observation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// A doc or journal entry attached to one chat message: a snapshot of its text taken when it was
/// attached. Attaching is the only way Kemo reads Docs or Journal; nothing searches them on its
/// own. Only the attached text goes into that message's context, it's journaled like other
/// context (`ContextRunJournal`, "attachment"), and with a connected model or Private Cloud the
/// destination is named before it's attached.
struct ChatDocAttachment: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case doc, journal }
    var id = UUID()
    var sourceID: UUID
    var kind: Kind
    var title: String
    /// The page or entry as Markdown, at most `maxCharacters`.
    var text: String
    var shortened = false
    /// The page's or entry's level when it was attached (`PrivacyLevel`).
    var privacy: PrivacyLevel?
    /// The recipient (`RecipientID.key`) the person confirmed it goes to, when it leaves this device.
    var sharedWith: String?
    static let maxCharacters = 20_000
    var symbol: String { kind == .doc ? "doc.text" : "book.closed" }
}

/// The attached text as it's given to a model.
enum AttachedContext {
    /// Apple's on-device model has a small context window; Private Cloud and connected models take more.
    static let onDeviceLimit = 3_000, privateCloudLimit = 16_000, connectedLimit = 20_000
    /// The attachments' text for one message, within `limit` characters in all, or nil when
    /// nothing is attached. Nothing else from Docs or Journal is ever included.
    static func compose(_ attachments: [ChatDocAttachment], limit: Int) -> String? {
        guard !attachments.isEmpty, limit > 0 else { return nil }
        let share = max(200, limit / attachments.count)
        return attachments.map { attachment in
            let label = attachment.kind == .doc ? "Attached doc" : "Attached journal entry"
            var body = attachment.text
            var shortened = attachment.shortened
            if body.count > share { body = String(body.prefix(share)); shortened = true }
            return "— \(label): “\(attachment.title)” —\n" + body + (shortened ? "\n(The rest was left out.)" : "")
        }.joined(separator: "\n\n")
    }
    /// A short line in place of an earlier message's attachments, so later turns know what was attached.
    static func marker(_ attachments: [ChatDocAttachment]) -> String? {
        guard !attachments.isEmpty else { return nil }
        return "(Attached earlier: " + attachments.map { "“" + $0.title + "”" }.joined(separator: ", ") + ")"
    }
}

extension ChatMessage {
    /// The message as a model reads it in the history: its text, then a one-line note of what was
    /// attached (the attached text itself goes only with the message it was attached to).
    var historyText: String {
        guard let marker = AttachedContext.marker(attachments ?? []) else { return text }
        return text + "\n" + marker
    }
}

extension DocsStore {
    /// A page's text to attach to a message (its sub-pages are not included).
    func attachment(page id: UUID) -> ChatDocAttachment? {
        guard let page = page(id), page.trashed == nil else { return nil }
        let text = DocMarkdown.export(page, forModel: true) { [weak self] in self?.title($0) }
        return Self.bounded(ChatDocAttachment(sourceID: id, kind: .doc, title: page.displayTitle, text: text, privacy: page.privacyLevel))
    }
    /// A journal entry's text, mood, and tags to attach (photos are not included).
    func attachment(entry id: UUID) -> ChatDocAttachment? {
        guard let entry = entry(id) else { return nil }
        var header: [String] = []
        if let mood = entry.mood { header.append("Mood: " + mood.title) }
        if !entry.tags.isEmpty { header.append("Tags: " + entry.tags.map { "#" + $0 }.joined(separator: " ")) }
        if !entry.photos.isEmpty { header.append("(\(entry.photos.count) \(entry.photos.count == 1 ? "photo" : "photos") not included)") }
        let body = DocMarkdown.export(blocks: entry.blocks, forModel: true) { [weak self] in self?.title($0) }
        let title = JournalCalendar.title(for: entry.day, relativeTo: "") + ", " + entry.created.formatted(date: .omitted, time: .shortened)
        return Self.bounded(ChatDocAttachment(sourceID: id, kind: .journal, title: title, text: (header + [body]).filter { !$0.isEmpty }.joined(separator: "\n"),
                                              privacy: entry.privacyLevel))
    }
    private static func bounded(_ attachment: ChatDocAttachment) -> ChatDocAttachment {
        var attachment = attachment
        if attachment.text.count > ChatDocAttachment.maxCharacters {
            attachment.text = String(attachment.text.prefix(ChatDocAttachment.maxCharacters)); attachment.shortened = true
        }
        return attachment
    }
}

// MARK: Journal lock

/// An optional lock on the Journal with Face ID or Touch ID (off by default, a setting on each
/// device). While it's on, the Journal stays hidden, and can't be attached in chat, until you
/// unlock it; it locks again when the app goes to the background.
@MainActor @Observable final class JournalLock {
    static let shared = JournalLock()
    static let key = "kemo.journal.lock"
    private(set) var enabled: Bool
    private(set) var unlocked = false
    var error: String?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    init(defaults: UserDefaults = .standard) {
        enabled = defaults.bool(forKey: Self.key)
        #if os(iOS)
        let names: [Notification.Name] = [UIApplication.didEnterBackgroundNotification]
        #elseif os(macOS)
        let names: [Notification.Name] = [NSApplication.didHideNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification]
        #else
        let names: [Notification.Name] = []
        #endif
        for name in names {
            #if os(macOS)
            let center = name == NSApplication.didHideNotification ? NotificationCenter.default : NSWorkspace.shared.notificationCenter
            #else
            let center = NotificationCenter.default
            #endif
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lock() }
            })
        }
    }
    /// Whether the Journal can be shown now.
    var isOpen: Bool { !enabled || unlocked }
    /// "Face ID", "Touch ID", or "your passcode".
    var method: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "your passcode"
        }
    }
    func lock() { unlocked = false }
    /// Asks for Face ID or Touch ID (falling back to the passcode).
    @discardableResult func unlock() async -> Bool {
        guard enabled else { return true }
        if await Self.authenticate(reason: "Unlock your journal.") { unlocked = true; error = nil; return true }
        return false
    }
    /// Turning the lock on or off asks first, so it can't be changed by someone who picked up the device.
    func setEnabled(_ on: Bool) async {
        guard on != enabled else { return }
        let context = LAContext()
        var problem: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &problem) else {
            error = "Set a passcode on this device to lock the journal."; return
        }
        guard await Self.authenticate(reason: on ? "Lock your journal." : "Turn off the journal lock.") else { return }
        enabled = on; unlocked = true; error = nil
        UserDefaults.standard.set(on, forKey: Self.key)
    }
    private static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

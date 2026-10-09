import Darwin
import Foundation
import Observation
import TsukumoCore

// What agents send in with `tsukumo.deliver`: a file, a message, or a link, kept in the app's Inbox folder.
// Untrusted, always: each file is saved under a cleaned name with macOS's quarantine mark (so Gatekeeper checks
// it if the owner ever opens it), without execute permission, and is never opened, run, previewed, or given
// to KemoSabe's model. Tsukumo only says it arrived ("Grok sent you report.pdf") and lets the owner reveal it
// in Finder or delete it.

/// One thing an agent sent.
public struct InboxItem: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case file, message, link }
    public var id: UUID
    public var caller: String
    public var callerName: String
    public var kind: Kind
    /// The cleaned name it was saved under.
    public var name: String
    /// Inside the Inbox folder.
    public var path: String
    public var bytes: Int
    public var sha256: String
    /// The agent's note, one line (shown as its words, never acted on).
    public var note: String?
    public var receivedAt: Date
    /// "Grok sent you report.pdf".
    public var line: String {
        switch kind {
        case .file: "\(callerName) sent you \(name)"
        case .message: "\(callerName) sent you a message"
        case .link: "\(callerName) sent you a link"
        }
    }
}

/// The Inbox: `Inbox/` in the app's folder, and its list (`inbox.json`).
@MainActor @Observable public final class GatewayInbox {
    public private(set) var items: [InboxItem]
    public let folder: URL
    @ObservationIgnored private let clock: @Sendable () -> Date
    /// Something arrived (the dock shows a speech bubble).
    @ObservationIgnored public var onDelivery: ((InboxItem) -> Void)?
    public static let maxItems = 500
    /// The whole Inbox stops taking more past this.
    public static let maxTotalBytes = 500 * 1_024 * 1_024

    public init(folder: URL, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.folder = folder
        self.clock = clock
        let list = folder.appendingPathComponent("inbox.json")
        items = (try? Data(contentsOf: list)).flatMap { try? TsukumoJSON.decoder.decode([InboxItem].self, from: $0) } ?? []
    }

    public enum Failure: Error, Equatable { case tooLarge, full, couldNotSave, notQuarantined }
    /// Sets the quarantine mark and says whether it took (tests make it fail).
    @ObservationIgnored var mark: (URL) -> Bool = { GatewayInbox.quarantine($0) }

    /// Saves what arrived, quarantined, and lists it.
    public func receive(_ data: Data, kind: InboxItem.Kind, name: String, note: String?, from caller: GatewayCaller, maxBytes: Int) throws -> InboxItem {
        guard data.count <= maxBytes else { throw Failure.tooLarge }
        guard items.count < Self.maxItems, items.reduce(0, { $0 + $1.bytes }) + data.count <= Self.maxTotalBytes else { throw Failure.full }
        let now = clock()
        let clean = Self.filename(name, kind: kind)
        let stamp = Self.stamp(now)
        let relative = stamp + "-" + clean
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(relative)
            // A fresh file only (never through a link someone left), readable and writable by the owner, never executable.
            guard fm.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw Failure.couldNotSave }
            // Fails closed: a file that couldn't be marked is deleted, never kept unmarked.
            guard mark(url), Self.isQuarantined(url) else {
                try? fm.removeItem(at: url)
                throw Failure.notQuarantined
            }
        } catch let failure as Failure { throw failure } catch { throw Failure.couldNotSave }
        let item = InboxItem(id: UUID(), caller: caller.id, callerName: caller.name, kind: kind, name: clean, path: relative, bytes: data.count,
                             sha256: GatewaySecrets.hex(data), note: note, receivedAt: now)
        items.append(item)
        save()
        onDelivery?(item)
        return item
    }

    public func url(_ item: InboxItem) -> URL { folder.appendingPathComponent(item.path) }

    public func delete(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: url(item))
        items.removeAll { $0.id == id }
        save()
    }

    /// A name that's safe to save: no folders, no hidden files, no control characters, at most 100 characters,
    /// and a plain extension (a message is .txt, a link .url).
    public static func filename(_ raw: String, kind: InboxItem.Kind) -> String {
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: " .-_()"))
        var name = String(String.UnicodeScalarView(raw.unicodeScalars.map { allowed.contains($0) ? $0 : "_" }))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while name.hasPrefix(".") || name.hasPrefix(" ") || name.hasPrefix("-") { name.removeFirst() }
        if name.isEmpty { name = kind == .file ? "file" : kind.rawValue }
        var base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension.lowercased()
        if ext.count > 10 || ext.contains(where: { !$0.isLetter && !$0.isNumber }) { base = name; ext = "" }
        switch kind {
        case .message: ext = "txt"
        case .link: ext = "url"
        case .file: break
        }
        base = String(base.prefix(90)).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        if base.isEmpty { base = kind.rawValue }
        return ext.isEmpty ? base : base + "." + ext
    }

    /// macOS's quarantine mark: Gatekeeper checks the file if it's ever opened, as for a download.
    static func quarantine(_ url: URL) -> Bool {
        let value = String(format: "0083;%08x;Tsukumo;%@", UInt32(Date().timeIntervalSince1970), UUID().uuidString)
        return value.withCString { pointer in
            setxattr(url.path, "com.apple.quarantine", pointer, strlen(pointer), 0, 0) == 0
        }
    }
    /// Whether a file carries the quarantine mark.
    public static func isQuarantined(_ url: URL) -> Bool { getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0) > 0 }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date) + "-" + String(UUID().uuidString.prefix(4))
    }

    private func save() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? TsukumoJSON.encoder.encode(items).write(to: folder.appendingPathComponent("inbox.json"), options: [.atomic])
    }
}

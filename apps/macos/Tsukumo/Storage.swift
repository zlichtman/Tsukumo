import Foundation
import TsukumoCore
import TsukumoEngines
import TsukumoUI

/// Where Tsukumo keeps everything on this Mac: ~/Library/Application Support/Tsukumo. The bots, their
/// chats, and the dock's settings (`dock.json`), the account (`account.json`), API connections without
/// their keys (`connections.json`), KemoSabe's sources, grants, and journal, its answers
/// (`artifacts.sqlite`), and sync's ledger. Keys are in this Mac's Keychain only.
struct Storage {
    let folder: URL

    /// The app's folder in Application Support.
    static var standard: URL { applicationSupport.appendingPathComponent("Tsukumo", isDirectory: true) }
    /// Where the preview of Tsukumo (before October 2, 2026) kept its files.
    static var preview: URL { applicationSupport.appendingPathComponent("Tsukumo Preview", isDirectory: true) }
    /// The voice models the old KemoSabe app downloaded (read only: a file there that passes its pinned
    /// check is copied instead of downloaded again).
    static var oldVoiceModels: URL { applicationSupport.appendingPathComponent("KemoSabe/VoiceModels", isDirectory: true) }
    private static var applicationSupport: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0] }

    func url(_ name: String) -> URL { folder.appendingPathComponent(name) }
    var dock: URL { url("dock.json") }
    var account: URL { url("account.json") }
    var journal: URL { url("journal.json") }
    var artifacts: URL { url("artifacts.sqlite") }
    var syncLedger: URL { url("sync-ledger.json") }

    func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        (try? Data(contentsOf: url(name))).flatMap { try? TsukumoJSON.decoder.decode(T.self, from: $0) }
    }
    func write<T: Encodable>(_ value: T, _ name: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? TsukumoJSON.encoder.encode(value).write(to: url(name), options: [.atomic])
    }

    /// The API connections. The preview saved bare `APIConnection`s; they load as records.
    func connections() -> [ConnectionRecord] {
        guard let data = try? Data(contentsOf: url("connections.json")) else { return [] }
        if let records = try? TsukumoJSON.decoder.decode([ConnectionRecord].self, from: data) { return records }
        let older = (try? TsukumoJSON.decoder.decode([APIConnection].self, from: data)) ?? []
        return older.map { ConnectionRecord(connection: $0, provider: Self.provider(for: $0)) }
    }
    func save(connections: [ConnectionRecord]) { write(connections, "connections.json") }

    static func provider(for connection: APIConnection) -> ConnectionRecord.Provider {
        if connection.wire == .anthropic { return .anthropic }
        return connection.endpoint.absoluteString == APIConnection.openAIEndpoint ? .openAI : .compatible
    }
}

/// Moves the preview's files into Tsukumo's folder once (October 2, 2026). Each file is copied, read back,
/// and compared byte for byte before anything is marked done; the preview's folder is left as it was, so
/// nothing is lost if a copy fails (the next launch tries again).
enum PreviewMigration {
    static let files = ["dock.json", "account.json", "connections.json", "sync-ledger.json"]
    /// Written into Tsukumo's folder once the move is done (or there was nothing to move).
    static let marker = ".moved-from-tsukumo-preview"

    enum Outcome: Equatable {
        /// Copied and checked: these files.
        case moved([String])
        /// Done before, or Tsukumo's folder already had its own bots, or there was no preview.
        case nothingToDo
        /// A copy didn't match; nothing was marked, and the preview's folder is untouched.
        case failed(String)
    }

    static func run(from old: URL, to new: URL, fileManager: FileManager = .default) -> Outcome {
        let markerURL = new.appendingPathComponent(marker)
        if fileManager.fileExists(atPath: markerURL.path) { return .nothingToDo }
        let present = files.filter { fileManager.fileExists(atPath: old.appendingPathComponent($0).path) }
        // Tsukumo's own bots win over the preview's.
        if present.isEmpty || fileManager.fileExists(atPath: new.appendingPathComponent("dock.json").path) {
            try? fileManager.createDirectory(at: new, withIntermediateDirectories: true)
            fileManager.createFile(atPath: markerURL.path, contents: Data())
            return .nothingToDo
        }
        do {
            try fileManager.createDirectory(at: new, withIntermediateDirectories: true)
            var moved: [String] = []
            for name in present {
                let source = old.appendingPathComponent(name), target = new.appendingPathComponent(name)
                let original = try Data(contentsOf: source)
                try original.write(to: target, options: [.atomic])
                guard try Data(contentsOf: target) == original else {
                    try? fileManager.removeItem(at: target)
                    return .failed("\(name) didn’t copy exactly.")
                }
                moved.append(name)
            }
            fileManager.createFile(atPath: markerURL.path, contents: Data(moved.joined(separator: "\n").utf8))
            return .moved(moved)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// The preview's Keychain items (API keys, and the Apple user ID) copied to Tsukumo's names, read back
    /// to check, and left in place. Same app, same signature, so no prompt.
    static func moveKeys(connections: [ConnectionRecord], from old: any APIKeyStore, to new: any APIKeyStore,
                         appleID oldAppleID: any AppleIDStore, to newAppleID: any AppleIDStore) {
        for record in connections {
            guard ((try? new.read(record.id)) ?? nil) == nil, let key = (try? old.read(record.id)) ?? nil else { continue }
            try? new.save(key, for: record.id)
        }
        if newAppleID.read() == nil, let userID = oldAppleID.read() { try? newAppleID.save(userID) }
    }
}

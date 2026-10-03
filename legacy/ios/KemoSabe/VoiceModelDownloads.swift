import Foundation
import CryptoKit
import Observation

/// Where a voice model is in its life on this device.
enum VoiceModelState: Equatable, Sendable {
    case notDownloaded
    /// Wi-Fi only is on and there's no Wi-Fi; the download starts when it's back.
    case waitingForWiFi
    case downloading(fraction: Double)
    case verifying
    case installed
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .waitingForWiFi, .downloading, .verifying: true
        default: false
        }
    }
}

/// Fetches one file. The real one uses URLSession; tests pass a fake.
protocol VoiceModelTransport: Sendable {
    /// Downloads `url` to a new temporary file and returns it. `wifiOnly` refuses cellular,
    /// Personal Hotspot, and Low Data Mode networks and waits for Wi-Fi instead.
    func download(_ url: URL, wifiOnly: Bool, progress: @escaping @Sendable (Int64) -> Void,
                  waiting: @escaping @Sendable () -> Void) async throws -> URL
}

enum VoiceModelDownloadError: Error, Equatable, LocalizedError {
    case sizeMismatch(String), checksumMismatch(String), httpStatus(Int), insufficientSpace, badPin(String)
    var errorDescription: String? {
        switch self {
        case .badPin(let file): "\(file) has no valid download address, so it wasn't downloaded."
        case .sizeMismatch(let file): "\(file) wasn't the expected size, so it wasn't installed."
        case .checksumMismatch(let file): "\(file) didn't match its pinned checksum, so it wasn't installed."
        case .httpStatus(let code): "The download server answered \(code)."
        case .insufficientSpace: "There isn't enough free space on this device."
        }
    }
}

/// Where voice models live on this device, and the pure file checks for them.
enum VoiceModelFiles {
    /// Application Support/KemoSabe/VoiceModels, or a private folder for tests. Device data, not
    /// account data: every account on this device uses the same downloaded model.
    static let defaultRoot: URL = AccountDirectory.isTestHost
        ? FileManager.default.temporaryDirectory.appendingPathComponent("KemoSabeTestVoiceModels-" + UUID().uuidString, isDirectory: true)
        : (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("KemoSabe", isDirectory: true).appendingPathComponent("VoiceModels", isDirectory: true)

    static let receiptName = "installed.json"
    struct Receipt: Codable, Equatable { let id: String; let version: Int; let files: [String: String] }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    /// Checks one downloaded file against the pin: exact size, then SHA-256.
    static func verify(_ url: URL, against file: VoiceModelPack.File) throws {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? -1
        guard size == file.size else { throw VoiceModelDownloadError.sizeMismatch(file.path) }
        guard try sha256(of: url) == file.sha256 else { throw VoiceModelDownloadError.checksumMismatch(file.path) }
    }
    static func receipt(for pack: VoiceModelPack) -> Receipt {
        .init(id: pack.id, version: pack.version, files: Dictionary(uniqueKeysWithValues: pack.files.map { ($0.source.folder + "/" + $0.file.path, $0.file.sha256) }))
    }
    /// Installed means the receipt matches this pack and every file is there at its pinned size
    /// (the full checksum ran when it was installed).
    static func isInstalled(_ pack: VoiceModelPack, at folder: URL) -> Bool {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(receiptName)),
              let saved = try? JSONDecoder().decode(Receipt.self, from: data), saved == receipt(for: pack) else { return false }
        return pack.files.allSatisfy { entry in
            let url = folder.appendingPathComponent(entry.source.folder).appendingPathComponent(entry.file.path)
            return ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value == entry.file.size
        }
    }
    /// Keeps a folder (and so everything in it) out of iCloud and device backups.
    static func excludeFromBackup(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
    static func isExcludedFromBackup(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) == true
    }
}

/// Downloads, verifies, installs, and deletes one voice model pack. Files download one at a
/// time into a staging folder; each is checked against its pinned size and SHA-256 as it
/// arrives, and only a complete, verified set is moved into place. A cancelled download keeps
/// the files already verified, so the next attempt picks up where it stopped.
@MainActor @Observable final class VoiceModelStore {
    let pack: VoiceModelPack
    let root: URL
    private(set) var state: VoiceModelState = .notDownloaded
    /// Wi-Fi only, on by default. The person can allow cellular for one download.
    var wifiOnly = true
    @ObservationIgnored private let transport: VoiceModelTransport
    @ObservationIgnored private var task: Task<Void, Never>?

    init(pack: VoiceModelPack, root: URL = VoiceModelFiles.defaultRoot, transport: VoiceModelTransport = URLSessionVoiceModelTransport()) {
        self.pack = pack; self.root = root; self.transport = transport
        refresh()
    }
    var folder: URL { root.appendingPathComponent(pack.id, isDirectory: true) }
    var staging: URL { root.appendingPathComponent(pack.id + ".partial", isDirectory: true) }
    var isInstalled: Bool { state == .installed }

    func refresh() {
        guard !state.isBusy else { return }
        state = VoiceModelFiles.isInstalled(pack, at: folder) ? .installed : .notDownloaded
    }

    /// Starts the download. Returns immediately; follow `state`.
    func download() {
        guard !state.isBusy, state != .installed else { return }
        state = .downloading(fraction: 0)
        task = Task { [weak self] in await self?.run() }
    }
    /// Stops the download. Verified files stay in staging for the next attempt.
    func cancel() {
        task?.cancel(); task = nil
        if state.isBusy { state = .notDownloaded }
    }
    /// Removes the model and any partial download.
    func delete() {
        cancel()
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.removeItem(at: staging)
        state = .notDownloaded
    }
    /// Waits for the current download to finish (tests and the Mac integration test).
    func waitUntilDone() async { await task?.value }

    private func run() async {
        let files = FileManager.default
        do {
            try files.createDirectory(at: root, withIntermediateDirectories: true)
            try VoiceModelFiles.excludeFromBackup(root)
            try files.createDirectory(at: staging, withIntermediateDirectories: true)
            if let free = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
               free > 0, free < pack.totalBytes + 200_000_000 { throw VoiceModelDownloadError.insufficientSpace }
            let total = Double(pack.totalBytes)
            var done: Int64 = 0
            for entry in pack.files {
                try Task.checkCancellation()
                let target = staging.appendingPathComponent(entry.source.folder).appendingPathComponent(entry.file.path)
                if (try? VoiceModelFiles.verify(target, against: entry.file)) != nil { done += entry.file.size; continue }
                let base = done
                guard let address = entry.source.url(for: entry.file) else { throw VoiceModelDownloadError.badPin(entry.file.path) }
                let temporary = try await transport.download(address, wifiOnly: wifiOnly, progress: { [weak self] written in
                    Task { @MainActor [weak self] in
                        guard let self, self.state.isBusy else { return }
                        self.state = .downloading(fraction: min(1, Double(base + written) / total))
                    }
                }, waiting: { [weak self] in
                    Task { @MainActor [weak self] in if self?.state.isBusy == true { self?.state = .waitingForWiFi } }
                })
                try Task.checkCancellation()
                state = .verifying
                do { try VoiceModelFiles.verify(temporary, against: entry.file) } catch { try? files.removeItem(at: temporary); throw error }
                try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? files.removeItem(at: target)
                try files.moveItem(at: temporary, to: target)
                done += entry.file.size
                state = .downloading(fraction: Double(done) / total)
            }
            try Task.checkCancellation()
            let receipt = try JSONEncoder().encode(VoiceModelFiles.receipt(for: pack))
            try receipt.write(to: staging.appendingPathComponent(VoiceModelFiles.receiptName), options: .atomic)
            try? files.removeItem(at: folder)
            try files.moveItem(at: staging, to: folder)
            try VoiceModelFiles.excludeFromBackup(folder)
            state = .installed
        } catch is CancellationError {
            if state.isBusy { state = .notDownloaded }
        } catch let error as URLError where error.code == .cancelled {
            if state.isBusy { state = .notDownloaded }
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        task = nil
    }
}

/// The real transport: one URLSession per file, Wi-Fi only unless the person allows cellular.
struct URLSessionVoiceModelTransport: VoiceModelTransport {
    static func configuration(wifiOnly: Bool) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsCellularAccess = !wifiOnly
        configuration.allowsExpensiveNetworkAccess = !wifiOnly
        configuration.allowsConstrainedNetworkAccess = !wifiOnly
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60 * 6
        configuration.httpAdditionalHeaders = ["User-Agent": "KemoSabe-VoiceModels/1"]
        return configuration
    }
    func download(_ url: URL, wifiOnly: Bool, progress: @escaping @Sendable (Int64) -> Void,
                  waiting: @escaping @Sendable () -> Void) async throws -> URL {
        let delegate = Delegate(progress: progress, waiting: waiting)
        let session = URLSession(configuration: Self.configuration(wifiOnly: wifiOnly), delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                let task = session.downloadTask(with: url)
                delegate.task = task
                task.resume()
            }
        } onCancel: { delegate.cancel() }
    }

    private final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let progress: @Sendable (Int64) -> Void
        let waiting: @Sendable () -> Void
        private let lock = NSLock()
        var continuation: CheckedContinuation<URL, Error>?
        var task: URLSessionDownloadTask?
        init(progress: @escaping @Sendable (Int64) -> Void, waiting: @escaping @Sendable () -> Void) {
            self.progress = progress; self.waiting = waiting
        }
        private func finish(_ result: Result<URL, Error>) {
            lock.lock(); let continuation = self.continuation; self.continuation = nil; lock.unlock()
            continuation?.resume(with: result)
        }
        func cancel() { lock.lock(); let task = self.task; lock.unlock(); task?.cancel() }
        func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) { waiting() }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) { progress(totalBytesWritten) }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, status != 200 {
                finish(.failure(VoiceModelDownloadError.httpStatus(status))); return
            }
            // The system deletes `location` when this returns, so move it first.
            let kept = FileManager.default.temporaryDirectory.appendingPathComponent("voice-model-" + UUID().uuidString)
            do { try FileManager.default.moveItem(at: location, to: kept); finish(.success(kept)) }
            catch { finish(.failure(error)) }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { finish(.failure(error)) }
        }
    }
}

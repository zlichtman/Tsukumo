import CryptoKit
import Foundation
import Observation

// The better voice models, ported from the old KemoSabe app (`legacy/ios/KemoSabe/VoiceModelPacks.swift`,
// `VoiceModelDownloads.swift`, and the Whisper pin in `OnDeviceWhisper.swift`): each pinned to exact
// files (the repository commit, every file's size, and its SHA-256), downloaded only after the owner's one
// consent, checked file by file, and installed only as a complete, verified set. They're device data, not
// the owner's: kept in the app's folder, excluded from backup, never synced. Provenance and licenses are in
// TsukumoKit/VOICE-NOTICE.md.

/// One downloadable model: its files, pinned.
public struct VoiceModelPack: Identifiable, Equatable, Sendable {
    public struct File: Equatable, Sendable {
        public let path: String
        public let size: Int64
        public let sha256: String
        public init(path: String, size: Int64, sha256: String) { self.path = path; self.size = size; self.sha256 = sha256 }
    }
    /// One Hugging Face repository at one commit, saved under `folder` in the pack.
    public struct Source: Equatable, Sendable {
        public let repository: String
        public let revision: String
        public let license: String
        public let folder: String
        public let files: [File]
        public init(repository: String, revision: String, license: String, folder: String, files: [File]) {
            self.repository = repository; self.revision = revision; self.license = license; self.folder = folder; self.files = files
        }
        /// The file at this exact commit, never a moving branch. Nil only for a malformed pin.
        public func url(for file: File) -> URL? {
            URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(file.path)")
        }
    }
    public let id: String
    public let title: String
    /// Bumped when the files change, so an older install is replaced rather than trusted.
    public let version: Int
    public let sources: [Source]

    public init(id: String, title: String, version: Int, sources: [Source]) {
        self.id = id; self.title = title; self.version = version; self.sources = sources
    }

    public var files: [(source: Source, file: File)] { sources.flatMap { source in source.files.map { (source, $0) } } }
    public var totalBytes: Int64 { sources.reduce(0) { $0 + $1.files.reduce(0) { $0 + $1.size } } }
    public var sizeLabel: String { ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file) }
    public static func == (lhs: VoiceModelPack, rhs: VoiceModelPack) -> Bool { lhs.id == rhs.id && lhs.version == rhs.version }

    /// OpenAI's Whisper large-v3-turbo (MIT), 4-bit MLX weights with its own tokenizer files, so nothing is
    /// fetched at load time. Chosen by measurement in the old app: the fewest errors of the sizes tried
    /// (3.0% WER against Apple's 8.3%), faster than real time on Apple silicon, 466 MB.
    public static let whisper = VoiceModelPack(id: "whisper-large-v3-turbo", title: "Whisper", version: 1, sources: [
        .init(repository: "mlx-community/whisper-large-v3-turbo-asr-4bit", revision: "321a6ead9f6e0646bc8188a54d2a470e275c6b76",
              license: "MIT (openai/whisper-large-v3-turbo)", folder: "model", files: [
            .init(path: "config.json", size: 1506, sha256: "9135b2ae07e6450a8f4e87ad1124abe970f705d72ea426030f969cb5014b82e9"),
            .init(path: "generation_config.json", size: 3772, sha256: "cce11bfe3aaa6ae9e072ea2637caaec8795e68d9b67e655a5af16ee509681a4c"),
            .init(path: "model.safetensors", size: 463462815, sha256: "45298f6dc48df8c11e0a8d1dc5e0197c688bfa530646fa21f1a0238d2b0ecda3"),
            .init(path: "tokenizer.json", size: 2710337, sha256: "297b13372ac43916285644fb9687add3cc62ee2a1adb60da3dc25cc94c1871fd"),
            .init(path: "tokenizer_config.json", size: 282843, sha256: "844b642c73a91359722f47b35705f7174686df33d252695d8572cf9ac03a6389"),
            .init(path: "special_tokens_map.json", size: 2186, sha256: "baea4ea09372eb4fca86b4e4346139fd73cb807d5087e9de0948e971739c3e74"),
            .init(path: "added_tokens.json", size: 34648, sha256: "3c51f66c4c21f9e126970078f11ae77a78c74aee8df606ee9daba86e467108e0"),
        ]),
    ])

    /// Kokoro-82M v1.0 (Apache-2.0, hexgrad) in MLX form, nine American English voices, and the Misaki
    /// English G2P lexicons and BART fallback (MIT/Apache-2.0) that turn text into phonemes. No espeak-ng,
    /// so no GPL code.
    public static let kokoro = VoiceModelPack(id: "kokoro-82m", title: "Kokoro", version: 1, sources: [
        .init(repository: "mlx-community/Kokoro-82M-bf16", revision: "a71e4d38b236d968966a2002c4c895dbd12b1c3c",
              license: "Apache-2.0 (hexgrad/Kokoro-82M)", folder: "model", files: [
            .init(path: "config.json", size: 2351, sha256: "5abb01e2403b072bf03d04fde160443e209d7a0dad49a423be15196b9b43c17f"),
            .init(path: "kokoro-v1_0.safetensors", size: 327115152, sha256: "4e9ecdf03b8b6cf906070390237feda473dc13327cb8d56a43deaa374c02acd8"),
            .init(path: "voices/af_heart.safetensors", size: 522320, sha256: "2c1c733b0e6576c810e268d3e440c21dea4e0f0131a3ba4cfc98d7fe6136d094"),
            .init(path: "voices/af_bella.safetensors", size: 522320, sha256: "112d310468cbb3cf23404d3d0b50ad3adf017b87bf38bf9edd15f4ad572df6a3"),
            .init(path: "voices/af_nicole.safetensors", size: 522320, sha256: "574656386022c81a029e9a72558191925f44c3de2dad2fa2e45751938557d062"),
            .init(path: "voices/af_aoede.safetensors", size: 522320, sha256: "23809148777f2a2378983dd856bc14b9c261018279f916f98c23d86e844409a5"),
            .init(path: "voices/af_kore.safetensors", size: 522320, sha256: "c491174280cb1ad25210a842f2f34b46a9ef904ec6f6a8e784839531795fa278"),
            .init(path: "voices/af_sarah.safetensors", size: 522320, sha256: "4940072182542f54c1035d1daf4c1cf3136ca9baa9ac57c8e006b4befcc50be6"),
            .init(path: "voices/am_fenrir.safetensors", size: 522320, sha256: "9abed964b906c4cae6f404d9849e76260689aea862bc6ca85fc3f5207ba96538"),
            .init(path: "voices/am_michael.safetensors", size: 522320, sha256: "3940147ded35deba0bb52e8132f89b719298e0520258c34584358aa5a24da2ea"),
            .init(path: "voices/am_puck.safetensors", size: 522320, sha256: "9a8c2e56413bd2063f814cb4c3885fc425876157369117c3f8258d03c8a9ad89"),
        ]),
        .init(repository: "beshkenadze/kitten-tts-g2p", revision: "9c692b92682d959d9013a9cfe6a49541997add18",
              license: "MIT (lexicons from hexgrad/misaki, Apache-2.0)", folder: "g2p", files: [
            .init(path: "us_bart.safetensors", size: 3011692, sha256: "dc4a02e62d4fcb4bb4097ecf00db89b8e1a12a549a52ab6adfbba220b80a55c5"),
            .init(path: "us_bart_config.json", size: 1257, sha256: "8deb3537fb29c63cd9f20d75515ae06e4c92f1b6db0703a2d45bca95b33a53a4"),
            .init(path: "us_gold.json", size: 3001196, sha256: "8507f89840f0813b10cf584740942f58e9cc9ad3660e24088b442ab0a6b126be"),
            .init(path: "us_silver.json", size: 3105352, sha256: "ea0e1abca0c9b18fb0d3402034633a337154a3153e9a9f49f97d668c908e140c"),
        ]),
    ])

    /// Both better models, which the one consent downloads together.
    public static let better: [VoiceModelPack] = [.whisper, .kokoro]
    public static var betterTotalBytes: Int64 { better.reduce(0) { $0 + $1.totalBytes } }
    /// "807 MB"
    public static var betterSizeLabel: String { "\(Int((Double(betterTotalBytes) / 1_000_000).rounded())) MB" }
}

/// Where a voice model is in its life on this device.
public enum VoiceModelState: Equatable, Sendable {
    case notDownloaded
    /// Wi-Fi only is on and there's no Wi-Fi; the download starts when it's back.
    case waitingForWiFi
    case downloading(fraction: Double)
    case verifying
    case installed
    case failed(String)

    public var isBusy: Bool {
        switch self {
        case .waitingForWiFi, .downloading, .verifying: true
        default: false
        }
    }
    /// The fraction downloaded, while it downloads.
    public var fraction: Double? { if case .downloading(let value) = self { value } else { nil } }
}

/// Fetches one file. The real one uses URLSession; tests pass a fake, so no test touches the network.
public protocol VoiceModelTransport: Sendable {
    /// Downloads `url` to a new temporary file and returns it. `wifiOnly` refuses cellular, Personal
    /// Hotspot, and Low Data Mode networks and waits for Wi-Fi instead.
    func download(_ url: URL, wifiOnly: Bool, progress: @escaping @Sendable (Int64) -> Void,
                  waiting: @escaping @Sendable () -> Void) async throws -> URL
}

public enum VoiceModelDownloadError: Error, Equatable, LocalizedError {
    case sizeMismatch(String), checksumMismatch(String), httpStatus(Int), insufficientSpace, badPin(String)
    public var errorDescription: String? {
        switch self {
        case .badPin(let file): "\(file) has no valid download address, so it wasn’t downloaded."
        case .sizeMismatch(let file): "\(file) wasn’t the expected size, so it wasn’t installed."
        case .checksumMismatch(let file): "\(file) didn’t match its pinned checksum, so it wasn’t installed."
        case .httpStatus(let code): "The download server answered \(code)."
        case .insufficientSpace: "There isn’t enough free space on this device."
        }
    }
}

/// The pure file checks for voice models.
public enum VoiceModelFiles {
    public static let receiptName = "installed.json"
    public struct Receipt: Codable, Equatable, Sendable { public let id: String; public let version: Int; public let files: [String: String] }

    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    /// Checks one file against the pin: exact size, then SHA-256.
    public static func verify(_ url: URL, against file: VoiceModelPack.File) throws {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? -1
        guard size == file.size else { throw VoiceModelDownloadError.sizeMismatch(file.path) }
        guard try sha256(of: url) == file.sha256 else { throw VoiceModelDownloadError.checksumMismatch(file.path) }
    }
    public static func receipt(for pack: VoiceModelPack) -> Receipt {
        .init(id: pack.id, version: pack.version, files: Dictionary(uniqueKeysWithValues: pack.files.map { ($0.source.folder + "/" + $0.file.path, $0.file.sha256) }))
    }
    /// Installed means the receipt matches this pack and every file is there at its pinned size (the full
    /// checksum ran when it was installed).
    public static func isInstalled(_ pack: VoiceModelPack, at folder: URL) -> Bool {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(receiptName)),
              let saved = try? JSONDecoder().decode(Receipt.self, from: data), saved == receipt(for: pack) else { return false }
        return pack.files.allSatisfy { entry in
            let url = folder.appendingPathComponent(entry.source.folder).appendingPathComponent(entry.file.path)
            return ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value == entry.file.size
        }
    }
    /// Keeps a folder (and so everything in it) out of iCloud and device backups.
    public static func excludeFromBackup(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
    public static func isExcludedFromBackup(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) == true
    }
}

/// Downloads, verifies, installs, and deletes one voice model pack. Files download one at a time into a
/// staging folder; each is checked against its pinned size and SHA-256 as it arrives, and only a complete,
/// verified set is moved into place. A cancelled download keeps the files already verified, so the next
/// attempt picks up where it stopped.
///
/// New since the old app: `seeds`, folders where the same pinned pack may already be (the old KemoSabe
/// app's download on a Mac). A file there that passes the same size and SHA-256 check is copied (a clone
/// on APFS, so no extra space) instead of downloaded; anything else is downloaded as usual. Nothing in a
/// seed folder is ever changed.
@MainActor @Observable public final class VoiceModelStore {
    public let pack: VoiceModelPack
    public let root: URL
    public private(set) var state: VoiceModelState = .notDownloaded
    /// Wi-Fi only, on by default.
    public var wifiOnly = true
    @ObservationIgnored private let transport: any VoiceModelTransport
    @ObservationIgnored private let seeds: [URL]
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(pack: VoiceModelPack, root: URL, transport: any VoiceModelTransport = URLSessionVoiceModelTransport(), seeds: [URL] = []) {
        self.pack = pack; self.root = root; self.transport = transport; self.seeds = seeds
        refresh()
    }
    public var folder: URL { root.appendingPathComponent(pack.id, isDirectory: true) }
    public var staging: URL { root.appendingPathComponent(pack.id + ".partial", isDirectory: true) }
    public var isInstalled: Bool { state == .installed }

    public func refresh() {
        guard !state.isBusy else { return }
        if VoiceModelFiles.isInstalled(pack, at: folder) { state = .installed } else if state == .installed { state = .notDownloaded }
    }

    /// Starts the download. Returns immediately; follow `state`.
    public func download() {
        guard !state.isBusy, state != .installed else { return }
        state = .downloading(fraction: 0)
        task = Task { [weak self] in await self?.run() }
    }
    /// Stops the download. Verified files stay in staging for the next attempt.
    public func cancel() {
        task?.cancel(); task = nil
        if state.isBusy { state = .notDownloaded }
    }
    /// Removes the model and any partial download.
    public func delete() {
        cancel()
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.removeItem(at: staging)
        state = .notDownloaded
    }
    /// Waits for the current download to finish (tests).
    public func waitUntilDone() async { await task?.value }

    private func run() async {
        let files = FileManager.default
        do {
            try files.createDirectory(at: root, withIntermediateDirectories: true)
            try VoiceModelFiles.excludeFromBackup(root)
            try files.createDirectory(at: staging, withIntermediateDirectories: true)
            if let free = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
               free > 0, free < pack.totalBytes + 200_000_000 { throw VoiceModelDownloadError.insufficientSpace }
            let total = Double(max(1, pack.totalBytes))
            var done: Int64 = 0
            for entry in pack.files {
                try Task.checkCancellation()
                let relative = entry.source.folder + "/" + entry.file.path
                let target = staging.appendingPathComponent(relative)
                if (try? VoiceModelFiles.verify(target, against: entry.file)) != nil { done += entry.file.size; continue }
                try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                // A verified copy already on this device (the old app's download) is cloned, not downloaded.
                if let seed = seeds.lazy.map({ $0.appendingPathComponent(self.pack.id).appendingPathComponent(relative) })
                    .first(where: { (try? VoiceModelFiles.verify($0, against: entry.file)) != nil }) {
                    try? files.removeItem(at: target)
                    try files.copyItem(at: seed, to: target)
                    try VoiceModelFiles.verify(target, against: entry.file)
                    done += entry.file.size
                    state = .downloading(fraction: Double(done) / total)
                    continue
                }
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

/// The real transport: one URLSession per file, Wi-Fi only unless the owner allows cellular.
public struct URLSessionVoiceModelTransport: VoiceModelTransport {
    public init() {}
    public static func configuration(wifiOnly: Bool) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsCellularAccess = !wifiOnly
        configuration.allowsExpensiveNetworkAccess = !wifiOnly
        configuration.allowsConstrainedNetworkAccess = !wifiOnly
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60 * 6
        configuration.httpAdditionalHeaders = ["User-Agent": "Tsukumo-VoiceModels/1"]
        return configuration
    }
    public func download(_ url: URL, wifiOnly: Bool, progress: @escaping @Sendable (Int64) -> Void,
                         waiting: @escaping @Sendable () -> Void) async throws -> URL {
        let delegate = Delegate(progress: progress, waiting: waiting)
        let session = URLSession(configuration: Self.configuration(wifiOnly: wifiOnly), delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.start(session.downloadTask(with: url), continuation)
            }
        } onCancel: { delegate.cancel() }
    }

    private final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let progress: @Sendable (Int64) -> Void
        let waiting: @Sendable () -> Void
        private let lock = NSLock()
        private var continuation: CheckedContinuation<URL, Error>?
        private var task: URLSessionDownloadTask?
        private var cancelled = false
        init(progress: @escaping @Sendable (Int64) -> Void, waiting: @escaping @Sendable () -> Void) {
            self.progress = progress; self.waiting = waiting
        }
        func start(_ task: URLSessionDownloadTask, _ continuation: CheckedContinuation<URL, Error>) {
            lock.lock(); self.task = task; self.continuation = continuation; let stop = cancelled; lock.unlock()
            if stop { finish(.failure(CancellationError())) } else { task.resume() }
        }
        private func finish(_ result: Result<URL, Error>) {
            lock.lock(); let continuation = self.continuation; self.continuation = nil; lock.unlock()
            continuation?.resume(with: result)
        }
        func cancel() { lock.lock(); cancelled = true; let task = self.task; lock.unlock(); task?.cancel() }
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

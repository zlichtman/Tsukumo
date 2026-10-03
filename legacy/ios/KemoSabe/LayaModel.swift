import Foundation
import Observation
#if os(iOS)
import UIKit
#endif

// Laya on this device (September 27, 2026): the base Laya decision model as a Core ML bundle,
// downloaded on demand like on-device Whisper (`VoiceModelStore`, pinned files checked by size and
// SHA-256), then compiled once for this device. It's 843 MB of FP16 weights, far too large to ship
// inside the app. See design/LAYA-TRAINING.md and ios/LAYA-NOTICE.md.

extension VoiceModelPack {
    /// convaiinnovations/laya at c5d78730 (Apache-2.0), the base checkpoint, as converted to Core ML
    /// by aac6fef/laya-coreml at fff78b2d. The hashes are the conversion's own `coreml_config.json`
    /// manifest, checked again on September 27, 2026; LICENSE and NOTICE were hashed that day.
    static let laya = VoiceModelPack(id: "laya-coreml", title: "Laya", version: 1, sources: [
        .init(repository: "aac6fef/laya-coreml", revision: "fff78b2d9750c6b748fe8c90fcbf8bed0a1522a9",
              license: "Apache-2.0 (convaiinnovations/laya, laya-coreml)", folder: "model", files: [
            .init(path: "coreml_config.json", size: 2068, sha256: "990b99a736f64c87da57b203d7953c4c1c79c18b615580db894e9c24bda42ab5"),
            .init(path: "rl_agent_config.json", size: 745, sha256: "ae287b56bbcf5f8c4f4541ae9dfd00c914c4c48b940b8398c3058af37ba92bbd"),
            .init(path: "tokenizer/tokenizer.json", size: 3583228, sha256: "6c8aaa9a542084f2457eab775d4eeb51f92a70c0fd9de28d5edb0ddec3c08d30"),
            .init(path: "tokenizer/tokenizer_config.json", size: 308, sha256: "50044de60daaa73df97d262e15a40d4faf0160e7d742df64b377877a1320dd12"),
            .init(path: "model.mlpackage/Manifest.json", size: 617, sha256: "41bab6e532f727e8809c76906f41026a48ef9b276c56068b3d68270a13981e20"),
            .init(path: "model.mlpackage/Data/com.apple.CoreML/model.mlmodel", size: 872598, sha256: "dc6a6383ad4a2f04f7525924b0dfb830429dedc44387f143a2f87782e39aeab0"),
            .init(path: "model.mlpackage/Data/com.apple.CoreML/weights/weight.bin", size: 842750912, sha256: "5872b9f6530c20a845b69c0cb75aa141e9c89ffdd5f36529c3708cec9b7a7a83"),
            .init(path: "LICENSE", size: 10173, sha256: "a6cba85bc92e0cff7a450b1d873c0eaa2e9fc96bf472df0247a26bec77bf3ff9"),
            .init(path: "NOTICE", size: 1209, sha256: "60928ba6b42ad90c048a88791c34c60826e565d279909095ade614c08c5b8ca8"),
        ]),
    ])
}

/// Where Laya is on this device: the download (the shared model store's states), compiling once
/// for this device, then ready.
enum LayaState: Equatable {
    case notDownloaded, waitingForWiFi, downloading(Double), verifying, preparing, ready, failed(String)
    var isBusy: Bool {
        switch self {
        case .waitingForWiFi, .downloading, .verifying, .preparing: true
        default: false
        }
    }
}

@MainActor @Observable final class LayaModel {
    static let shared = LayaModel()
    let store: VoiceModelStore
    private(set) var preparing = false
    private(set) var problem: String?
    private(set) var ready: Bool

    /// Compiles the verified download for this device (`CoreMLLayaProvider.compiledModel`); tests pass their own.
    @ObservationIgnored private let compile: @Sendable (URL) async throws -> URL

    init(store: VoiceModelStore? = nil, compile: @escaping @Sendable (URL) async throws -> URL = { try await CoreMLLayaProvider.compiledModel(in: $0) }) {
        let store = store ?? VoiceModelStore(pack: .laya)
        store.wifiOnly = UserDefaults.standard.object(forKey: SpeechVoices.wifiOnlyKey) as? Bool ?? true
        self.store = store; self.compile = compile
        ready = Self.isReady(at: store.folder.appendingPathComponent("model", isDirectory: true))
    }
    /// The folder `CoreMLLayaProvider` reads: the pinned files, then the compiled model.
    nonisolated static let modelDirectory = VoiceModelFiles.defaultRoot
        .appendingPathComponent(VoiceModelPack.laya.id, isDirectory: true).appendingPathComponent("model", isDirectory: true)
    nonisolated static let compiledMarker = "kemo-compiled.txt"

    /// Compiled for this device, with the configuration and tokenizer beside it.
    nonisolated static func isReady(at directory: URL) -> Bool {
        let files = FileManager.default
        return files.fileExists(atPath: directory.appendingPathComponent("model.mlmodelc").appendingPathComponent(compiledMarker).path)
            && ["coreml_config.json", "rl_agent_config.json", "tokenizer/tokenizer.json", "tokenizer/tokenizer_config.json"]
                .allSatisfy { files.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }
    /// A decision can use Laya: compiled, or downloaded and verified (compiled on first use).
    nonisolated static func isAvailable(at directory: URL = modelDirectory) -> Bool {
        isReady(at: directory) || VoiceModelFiles.isInstalled(.laya, at: directory.deletingLastPathComponent())
    }

    var state: LayaState {
        if ready { return .ready }
        if preparing { return .preparing }
        if let problem { return .failed(problem) }
        switch store.state {
        case .notDownloaded: return .notDownloaded
        case .waitingForWiFi: return .waitingForWiFi
        case .downloading(let fraction): return .downloading(fraction)
        case .verifying: return .verifying
        case .installed: return .preparing
        case .failed(let message): return .failed(message)
        }
    }
    var sizeLabel: String { store.pack.shortSizeLabel }

    func refresh() {
        store.refresh()
        ready = Self.isReady(at: store.folder.appendingPathComponent("model", isDirectory: true))
        if !ready, store.isInstalled { prepare() }
    }
    /// Downloads Laya, then prepares it as soon as the download is verified, whether or not the
    /// page is still showing. When the files are already here (a preparation that failed), it
    /// prepares again instead: the store won't download an installed pack, which used to leave the
    /// page on "Preparing" with nothing running.
    func download() {
        problem = nil
        if store.isInstalled { prepare(); return }
        store.download()
        Task { [weak self] in
            await self?.store.waitUntilDone()
            self?.refresh()
        }
    }
    /// Compiles the verified download once for this device. Run after the download finishes.
    func prepare() {
        guard !ready, !preparing, store.isInstalled else { return }
        preparing = true; problem = nil
        let directory = store.folder.appendingPathComponent("model", isDirectory: true)
        let compile = compile
        Task {
            do { _ = try await compile(directory) }
            catch { problem = "Laya couldn't be prepared on this device. Try again, or delete it and download again." }
            preparing = false
            ready = Self.isReady(at: directory)
            if !ready, problem == nil { problem = "Laya couldn't be prepared on this device. Try again, or delete it and download again." }
        }
    }
    func delete() {
        Task { await CoreMLLayaProvider.shared.unload() }
        store.delete(); ready = false; problem = nil
    }

    /// Frees the loaded model on memory pressure, and on iPhone when the app goes to the background.
    nonisolated static let watchMemory: Void = {
        let unload: @Sendable () -> Void = { Task { await CoreMLLayaProvider.shared.unload() } }
        #if os(iOS)
        for name in [UIApplication.didReceiveMemoryWarningNotification, UIApplication.didEnterBackgroundNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in unload() }
        }
        #else
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler(handler: unload)
        source.resume()
        memorySource.value = source
        #endif
    }()
    #if os(macOS)
    private nonisolated static let memorySource = SourceBox()
    private final class SourceBox: @unchecked Sendable { var value: DispatchSourceMemoryPressure? }
    #endif
}

// swift-tools-version: 6.2
import PackageDescription

// TsukumoMLXVoice: Whisper and Kokoro on the GPU with MLX, for both apps (docs/ARCHITECTURE.md, TsukumoVoice),
// and TsukumoLaya: Laya's tokenizer for System One, on the same swift-transformers.
// It's its own package so TsukumoKit keeps no dependencies and `swift test` never builds MLX. It fills
// TsukumoVoice's `NeuralVoiceRuntime`.
//
// `Vendor/MLXAudio` is the part of mlx-audio-swift (MIT) the old KemoSabe app ran, at the same pinned commit
// (01dec7c9bdce3088a6b6b7ab9f2e403458195efb): MLXAudioCore, MLXAudioG2P, Kokoro (StyleTTS2 with Misaki's G2P),
// and Whisper. It's vendored because that commit's full package doesn't compile with Swift 6.4 (Xcode 27) in
// Swift 6 mode (ParakeetModel.swift, which Tsukumo doesn't use); here it builds in Swift 5 mode, unchanged
// except for the model loaders left out. See Vendor/MLXAudio/VENDORED.md and TsukumoKit/VOICE-NOTICE.md.
// The dependencies are pinned to the versions that commit resolved to.

let vendored: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "TsukumoMLXVoice",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "TsukumoMLXVoice", targets: ["TsukumoMLXVoice"]),
        // Laya's tokenizer (TsukumoSystemOne's `LayaTokenizer`) on the same swift-transformers, so the apps carry one copy.
        .library(name: "TsukumoLaya", targets: ["TsukumoLaya"])
    ],
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.32.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.3.4"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", exact: "0.12.0")
    ],
    targets: [
        .target(name: "MLXAudioCore", dependencies: [
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXNN", package: "mlx-swift"),
            .product(name: "HuggingFace", package: "swift-huggingface")
        ], path: "Vendor/MLXAudio/MLXAudioCore", swiftSettings: vendored),
        .target(name: "MLXAudioG2P", dependencies: [
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXNN", package: "mlx-swift")
        ], path: "Vendor/MLXAudio/MLXAudioG2P", swiftSettings: vendored),
        .target(name: "MLXAudioTTS", dependencies: [
            "MLXAudioCore", "MLXAudioG2P",
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXFast", package: "mlx-swift"),
            .product(name: "MLXFFT", package: "mlx-swift"),
            .product(name: "MLXNN", package: "mlx-swift"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "HuggingFace", package: "swift-huggingface")
        ], path: "Vendor/MLXAudio/MLXAudioTTS", swiftSettings: vendored),
        .target(name: "MLXAudioSTT", dependencies: [
            "MLXAudioCore",
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXFast", package: "mlx-swift"),
            .product(name: "MLXNN", package: "mlx-swift"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "HuggingFace", package: "swift-huggingface"),
            .product(name: "Tokenizers", package: "swift-transformers")
        ], path: "Vendor/MLXAudio/MLXAudioSTT", swiftSettings: vendored),
        .target(name: "TsukumoMLXVoice", dependencies: [
            "MLXAudioCore", "MLXAudioTTS", "MLXAudioSTT",
            .product(name: "TsukumoVoice", package: "TsukumoKit"),
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "HuggingFace", package: "swift-huggingface")
        ], path: "Sources/TsukumoMLXVoice", resources: [.copy("Resources/VoiceEngines-NOTICE.txt")], swiftSettings: vendored),
        .target(name: "TsukumoLaya", dependencies: [
            .product(name: "TsukumoSystemOne", package: "TsukumoKit"),
            .product(name: "Tokenizers", package: "swift-transformers"),
            .product(name: "Hub", package: "swift-transformers")
        ], path: "Sources/TsukumoLaya", resources: [.copy("Resources/Laya-NOTICE.txt")]),
        // Laya's opt-in evaluation: runs only when TSUKUMO_LAYA_MODEL names a downloaded bundle.
        .testTarget(name: "TsukumoLayaTests", dependencies: [
            "TsukumoLaya",
            .product(name: "TsukumoSystemOne", package: "TsukumoKit")
        ], path: "Tests/TsukumoLayaTests")
    ]
)

// swift-tools-version: 6.2
import PackageDescription

// TsukumoKit: the Tsukumo iPhone app's modules (docs/ARCHITECTURE.md).
// Dependencies point down the module list only: Core has none; UI sits on top.
// macOS stays a build platform so the modules compile on a Mac too; the app is iPhone only.

let package = Package(
    name: "TsukumoKit",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "TsukumoCore", targets: ["TsukumoCore"]),
        .library(name: "TsukumoPolicy", targets: ["TsukumoPolicy"]),
        .library(name: "TsukumoContext", targets: ["TsukumoContext"]),
        .library(name: "TsukumoGate", targets: ["TsukumoGate"]),
        .library(name: "TsukumoGateway", targets: ["TsukumoGateway"]),
        .library(name: "TsukumoSystemOne", targets: ["TsukumoSystemOne"]),
        .library(name: "TsukumoEngines", targets: ["TsukumoEngines"]),
        .library(name: "TsukumoSync", targets: ["TsukumoSync"]),
        .library(name: "TsukumoVoice", targets: ["TsukumoVoice"]),
        .library(name: "TsukumoUI", targets: ["TsukumoUI"])
    ],
    targets: [
        .target(name: "TsukumoCore"),
        .target(name: "TsukumoPolicy", dependencies: ["TsukumoCore"]),
        .target(name: "TsukumoContext", dependencies: ["TsukumoCore", "TsukumoPolicy"]),
        .target(name: "TsukumoGate", dependencies: ["TsukumoCore", "TsukumoPolicy", "TsukumoContext"]),
        // The KemoSabe gateway: agents elsewhere (OpenClaw, Grok, Claude, ChatGPT) ask KemoSabe through typed tools over MCP,
        // reaching this device through the Tsukumo relay (relay/).
        .target(name: "TsukumoGateway", dependencies: ["TsukumoCore", "TsukumoPolicy", "TsukumoContext", "TsukumoGate"]),
        .target(name: "TsukumoSystemOne", dependencies: ["TsukumoCore", "TsukumoPolicy", "TsukumoContext"]),
        .target(name: "TsukumoEngines", dependencies: ["TsukumoCore", "TsukumoPolicy", "TsukumoContext"]),
        .target(name: "TsukumoSync", dependencies: ["TsukumoCore", "TsukumoPolicy", "TsukumoContext"]),
        // Listening and speaking (Whisper, Kokoro, and Apple's recognizer and voices). The MLX models are the
        // app's (`MLXVoice/`, behind `NeuralVoiceRuntime`), so this package keeps no dependencies.
        .target(name: "TsukumoVoice", dependencies: ["TsukumoCore"]),
        .target(name: "TsukumoUI", dependencies: ["TsukumoCore", "TsukumoPolicy", "TsukumoContext", "TsukumoGate", "TsukumoSystemOne", "TsukumoEngines", "TsukumoVoice"],
                resources: [.process("Resources")])
    ]
)

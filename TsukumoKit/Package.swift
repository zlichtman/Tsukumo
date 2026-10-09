// swift-tools-version: 6.2
import PackageDescription

// TsukumoKit: the harness every Tsukumo surface shares (docs/ARCHITECTURE.md).
// Dependencies point down the module list only: Core has none; UI and Dock sit on top.
// The floor is macOS 15 (docs/ARCHITECTURE.md, owner decision 1); anything that needs
// macOS 26 (Foundation Models, Liquid Glass) is marked `@available(macOS 26, *)`.

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
        .library(name: "TsukumoUI", targets: ["TsukumoUI"]),
        .library(name: "TsukumoDock", targets: ["TsukumoDock"]),
        .library(name: "TsukumoMuse", targets: ["TsukumoMuse"]),
        .library(name: "TsukumoUpdate", targets: ["TsukumoUpdate"]),
        .library(name: "TsukumoClaude", targets: ["TsukumoClaude"])
    ],
    targets: [
        .target(name: "TsukumoCore"),
        .target(name: "TsukumoPolicy", dependencies: ["TsukumoCore"]),
        .target(name: "TsukumoContext", dependencies: ["TsukumoCore", "TsukumoPolicy"]),
        .target(name: "TsukumoGate", dependencies: ["TsukumoCore", "TsukumoPolicy", "TsukumoContext"]),
        // The KemoSabe gateway: agents elsewhere ask KemoSabe through typed tools over MCP on this Mac (macOS; Network.framework).
        .target(name: "TsukumoGateway", dependencies: ["TsukumoCore", "TsukumoPolicy", "TsukumoContext", "TsukumoGate"]),
        // Test only: the gateway on stdin and stdout for the independent attack suite (JSON lines, synthetic data only).
        .executableTarget(name: "GatewayTestAdapter", dependencies: ["TsukumoCore", "TsukumoPolicy", "TsukumoGate", "TsukumoGateway"]),
        .target(name: "TsukumoSystemOne", dependencies: ["TsukumoCore", "TsukumoPolicy", "TsukumoContext"]),
        .target(name: "TsukumoEngines", dependencies: ["TsukumoCore", "TsukumoPolicy", "TsukumoContext"]),
        .target(name: "TsukumoSync", dependencies: ["TsukumoCore", "TsukumoPolicy", "TsukumoContext"]),
        // Listening and speaking (Whisper, Kokoro, and Apple's recognizer and voices). The MLX models are the
        // app's (`MLXVoice/`, behind `NeuralVoiceRuntime`), so this package keeps no dependencies.
        .target(name: "TsukumoVoice", dependencies: ["TsukumoCore"]),
        // Tsukumo's Dock as a Muse gadget (macOS): Muse's agent calls Tsukumo, which must ask KemoSabe. A port of
        // Meta's Apache-2.0 Muse Gadget SDK on CryptoKit and CoreBluetooth (MUSE-NOTICE.md); no dependencies.
        // Its notice with the Apache-2.0 license text ships inside the app (Resources/Muse-NOTICE.txt).
        .target(name: "TsukumoMuse", dependencies: ["TsukumoCore", "TsukumoPolicy"], resources: [.copy("Resources/Muse-NOTICE.txt")]),
        // Tsukumo's Dock updating itself from tsukumo.json on zlichtman.com (macOS): the feed, the checked download, and
        // the install. Foundation, CryptoKit, and Security only; no dependencies.
        .target(name: "TsukumoUpdate"),
        .target(name: "TsukumoUI", dependencies: ["TsukumoCore", "TsukumoPolicy", "TsukumoContext", "TsukumoGate", "TsukumoSystemOne", "TsukumoEngines", "TsukumoVoice"],
                resources: [.process("Resources")]),
        // The dock sits on TsukumoUI: its chat is TsukumoUI's chat, and its characters are TsukumoUI's clay.
        // The Claude bot (macOS): an always-available agent on the owner's own Claude (Claude Code first, else their API key)
        // that takes goals as background tasks, asks KemoSabe through the gateway as its own caller, and has its panel.
        .target(name: "TsukumoClaude", dependencies: ["TsukumoCore", "TsukumoPolicy", "TsukumoContext", "TsukumoEngines", "TsukumoGateway", "TsukumoUI"]),
        .target(name: "TsukumoDock", dependencies: ["TsukumoCore", "TsukumoPolicy", "TsukumoContext", "TsukumoGate", "TsukumoEngines", "TsukumoVoice", "TsukumoUI", "TsukumoMuse", "TsukumoGateway"])
    ]
)

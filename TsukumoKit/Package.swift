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
        .library(name: "TsukumoSystemOne", targets: ["TsukumoSystemOne"]),
        .library(name: "TsukumoEngines", targets: ["TsukumoEngines"]),
        .library(name: "TsukumoSync", targets: ["TsukumoSync"]),
        .library(name: "TsukumoUI", targets: ["TsukumoUI"]),
        .library(name: "TsukumoDock", targets: ["TsukumoDock"])
    ],
    targets: [
        .target(name: "TsukumoCore"),
        .target(name: "TsukumoPolicy", dependencies: ["TsukumoCore"]),
        .target(name: "TsukumoContext", dependencies: ["TsukumoCore", "TsukumoPolicy"]),
        .target(name: "TsukumoGate", dependencies: ["TsukumoCore", "TsukumoPolicy", "TsukumoContext"]),
        .target(name: "TsukumoSystemOne", dependencies: ["TsukumoCore", "TsukumoPolicy", "TsukumoContext"]),
        .target(name: "TsukumoEngines", dependencies: ["TsukumoCore", "TsukumoPolicy", "TsukumoContext"]),
        .target(name: "TsukumoSync", dependencies: ["TsukumoCore", "TsukumoPolicy", "TsukumoContext"]),
        .target(name: "TsukumoUI", dependencies: ["TsukumoCore", "TsukumoPolicy", "TsukumoContext", "TsukumoGate", "TsukumoSystemOne", "TsukumoEngines"],
                resources: [.process("Resources")]),
        // The dock sits on TsukumoUI: its chat is TsukumoUI's chat, and its characters are TsukumoUI's clay.
        .target(name: "TsukumoDock", dependencies: ["TsukumoCore", "TsukumoPolicy", "TsukumoContext", "TsukumoGate", "TsukumoEngines", "TsukumoUI"]),

        .testTarget(name: "TsukumoCoreTests", dependencies: ["TsukumoCore"]),
        .testTarget(name: "TsukumoPolicyTests", dependencies: ["TsukumoPolicy"]),
        .testTarget(name: "TsukumoContextTests", dependencies: ["TsukumoContext"]),
        .testTarget(name: "TsukumoGateTests", dependencies: ["TsukumoGate"]),
        .testTarget(name: "TsukumoSystemOneTests", dependencies: ["TsukumoSystemOne"]),
        .testTarget(name: "TsukumoEnginesTests", dependencies: ["TsukumoEngines"]),
        .testTarget(name: "TsukumoSyncTests", dependencies: ["TsukumoSync"]),
        .testTarget(name: "TsukumoUITests", dependencies: ["TsukumoUI", "TsukumoCore", "TsukumoPolicy", "TsukumoContext", "TsukumoGate", "TsukumoEngines"],
                    resources: [.copy("Reference")]),
        .testTarget(name: "TsukumoDockTests", dependencies: ["TsukumoDock", "TsukumoUI", "TsukumoCore", "TsukumoPolicy", "TsukumoGate", "TsukumoEngines"])
    ]
)

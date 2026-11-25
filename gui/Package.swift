// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "EcoFlow",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "EcoFlowKit", targets: ["EcoFlowKit"]),
        .executable(name: "EcoFlowCLI", targets: ["EcoFlowCLI"]),
        .executable(name: "EcoFlowGUI", targets: ["EcoFlowGUI"]),
    ],
    targets: [
        .target(
            name: "EcoFlowKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "EcoFlowCLI",
            dependencies: ["EcoFlowKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "EcoFlowGUI",
            dependencies: ["EcoFlowKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // self-test executable (Swift Testing macros are unreliable on CLT-only
        // toolchains — this runs anywhere via `swift run EcoFlowKitTests`)
        .executableTarget(
            name: "EcoFlowKitTests",
            dependencies: ["EcoFlowKit"],
            path: "Tests/EcoFlowKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

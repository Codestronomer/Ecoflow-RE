// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "EcoFlow",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "EcoFlowKit", targets: ["EcoFlowKit"]),
        .executable(name: "EcoFlowCLI", targets: ["EcoFlowCLI"]),
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
        .testTarget(
            name: "EcoFlowKitTests",
            dependencies: ["EcoFlowKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CodexMeterCore",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "CodexMeterCore", targets: ["CodexMeterCore"])
    ],
    targets: [
        .target(
            name: "CodexMeterCore",
            path: "CodexMeter/Core"
        ),
        .testTarget(
            name: "CodexMeterCoreTests",
            dependencies: ["CodexMeterCore"],
            path: "Tests/CodexMeterCoreTests"
        )
    ]
)

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
        // Keep business logic independently testable without loading the macOS UI.
        .target(
            name: "CodexMeterCore",
            path: "CodexMeter/Core",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "CodexMeterCoreTests",
            dependencies: ["CodexMeterCore"],
            path: "Tests/CodexMeterCoreTests"
        )
    ]
)

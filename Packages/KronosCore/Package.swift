// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "KronosCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KronosCore", targets: ["KronosCore"])
    ],
    targets: [
        .target(
            name: "KronosCore",
            resources: [.process("Resources")],
            swiftSettings: [
                .enableUpcomingFeature("BareSlashRegexLiterals")
            ]
        ),
        .testTarget(name: "KronosCoreTests", dependencies: ["KronosCore"])
    ]
)
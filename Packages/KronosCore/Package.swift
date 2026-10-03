// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "KronosCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v14), .iOS("26.0"), .watchOS("26.0"), .visionOS("26.0")],
    products: [
        .library(name: "KronosCore", targets: ["KronosCore"])
    ],
    targets: [
        .target(
            name: "KronosCore",
            resources: [.process("Resources")],
            swiftSettings: [
                .define("KRONOS_PUBLIC"),
                .enableUpcomingFeature("BareSlashRegexLiterals")
            ]
        ),
        .testTarget(name: "KronosCoreTests", dependencies: ["KronosCore"], swiftSettings: [.define("KRONOS_PUBLIC")])
    ]
)
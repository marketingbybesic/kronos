// swift-tools-version: 5.10
import PackageDescription

// Pure Codable + file IO. No SwiftData, no AppKit/UIKit, no dependency on KronosCore:
// widgets, the Share extension and the Watch import this without pulling the store in.
let package = Package(
    name: "KronosSnapshot",
    platforms: [.macOS(.v14), .iOS("26.0"), .watchOS("26.0"), .visionOS("26.0")],
    products: [
        .library(name: "KronosSnapshot", targets: ["KronosSnapshot"])
    ],
    targets: [
        .target(name: "KronosSnapshot"),
        .testTarget(name: "KronosSnapshotTests", dependencies: ["KronosSnapshot"])
    ]
)

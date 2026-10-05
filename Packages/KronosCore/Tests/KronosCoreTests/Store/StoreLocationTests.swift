import Foundation
import SwiftData
import Testing
@testable import KronosCore

/// Where the store lives on each platform, decided from plain inputs. Expected paths are
/// written out by hand.
@Suite("StoreLocationTests")
struct StoreLocationTests {

    static let support = URL(fileURLWithPath: "/home/someone/Library/Application Support", isDirectory: true)
    static let group = URL(fileURLWithPath: "/private/var/mobile/Containers/Shared/AppGroup/ABC", isDirectory: true)

    /// (environment, bundle id, group container, expected path, expected kind)
    static let table: [([String: String], String?, URL?, String, KronosStoreLocation.Kind)] = [
        ([:], "com.besic.kronos", nil, "/home/someone/Library/Application Support/Kronos", .applicationSupport),
        ([:], "com.besic.kronos.demo", nil, "/home/someone/Library/Application Support/Kronos Demo", .applicationSupport),
        ([:], nil, nil, "/home/someone/Library/Application Support/Kronos", .applicationSupport),
        ([:], "com.besic.kronos", group, "/private/var/mobile/Containers/Shared/AppGroup/ABC/Kronos", .appGroup),
        ([:], "com.besic.kronos.demo", group, "/private/var/mobile/Containers/Shared/AppGroup/ABC/Kronos Demo", .appGroup),
        (["KRONOS_STORE_DIR": "/tmp/copy-of-store"], "com.besic.kronos", group, "/tmp/copy-of-store", .override),
        (["KRONOS_STORE_DIR": "/tmp/copy-of-store"], "com.besic.kronos.demo", nil, "/tmp/copy-of-store", .override),
        (["KRONOS_STORE_DIR": ""], "com.besic.kronos", nil, "/home/someone/Library/Application Support/Kronos", .applicationSupport),
    ]

    @Test func resolverFollowsTheTable() {
        for (env, bundle, groupURL, path, kind) in Self.table {
            let loc = KronosStoreLocation.resolve(environment: env, bundleID: bundle,
                                                  appGroupContainer: groupURL, applicationSupport: Self.support)
            #expect(loc.directory.path == path, "env=\(env) bundle=\(bundle ?? "nil") group=\(groupURL != nil)")
            #expect(loc.kind == kind)
        }
    }

    /// On the Mac the live location is still Application Support (never the group container),
    /// unless the hermetic override is set.
    #if os(macOS)
    @Test func macLocationIsNeverTheGroupContainer() {
        // Other suites set KRONOS_STORE_DIR while they run, so either answer but the group one
        // is legitimate here.
        let loc = KronosStore.location()
        #expect(loc.kind != .appGroup)
        if loc.kind == .applicationSupport {
            #expect(loc.directory.deletingLastPathComponent().path.hasSuffix("/Library/Application Support"))
        }
        #expect(KronosStore.storeURL(in: loc.directory).lastPathComponent == "Kronos.store")
    }
    #endif

    /// A store opened at an explicit URL writes there and nowhere else, and a second handle on
    /// the same file reads what the first saved.
    @MainActor @Test func storeOpensAtAnExplicitURL() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kronos-location-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = KronosStore.storeURL(in: dir)
        let a = try TaskStore(storeURL: url)
        let t = a.create(title: "Written through an explicit URL")
        #expect(FileManager.default.fileExists(atPath: url.path))
        let b = try TaskStore(storeURL: url)
        #expect(b.task(t.id)?.title == "Written through an explicit URL")
    }
}

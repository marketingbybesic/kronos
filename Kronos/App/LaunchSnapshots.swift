// Compiled only outside Release. Extra named screens for SnapshotHarness: the readable launch
// error window and the "open a .kronos.json" window (leaf w22f).
#if !RELEASE
import SwiftUI
import KronosCore

@MainActor
enum LaunchSnapshots {
    static func screens() -> [String: AnyView] {
        let failure = LaunchFailure(message: "The file could not be opened (fixture)",
                                    backup: URL(fileURLWithPath: "/tmp/crash-20261001-120000.store"))
        let envelope = KronosExportEnvelope(exportedAt: Date(timeIntervalSince1970: 1_790_000_000))
        return [
            "launch.error": AnyView(LaunchErrorView(failure: failure)),
            "backup.open": AnyView(BackupOpenView(envelope: envelope, fileName: "x.kronos.json")),
        ]
    }
}
#endif

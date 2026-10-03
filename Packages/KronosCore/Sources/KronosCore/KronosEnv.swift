import Foundation

/// The one place that knows whether this process runs against the person's real data or a hermetic
/// scratch environment (live UI test, snapshots, hand tests with `KRONOS_STORE_DIR`).
///
/// Every persisted flag or value of new code goes through `KronosEnv.defaults`, and every file
/// lives under `KronosEnv.storeDirectory`, so a test run never reads or writes the person's domain.
public enum KronosEnv {
    /// `KRONOS_SNAPSHOT` is set: a throwaway render run.
    public static var isSnapshot: Bool {
        ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] != nil
    }

    /// Live UI test, snapshot, or an explicit store directory override.
    public static var isHermetic: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["KRONOS_UITEST"] != nil || env["KRONOS_SNAPSHOT"] != nil { return true }
        if let dir = env["KRONOS_STORE_DIR"], !dir.isEmpty { return true }
        return false
    }

    /// Directory holding the store, backups and lock file.
    public static var storeDirectory: URL { KronosStore.containerDirectory() }

    /// Single-instance lock file next to the store.
    public static var lockURL: URL { storeDirectory.appendingPathComponent("store.lock") }

    /// Not hermetic: the standard domain. Snapshot: a fresh suite per process. Otherwise a suite
    /// derived from the store directory: stable across relaunches of the same test, never the
    /// person's domain.
    public static let defaults: UserDefaults = {
        guard isHermetic else { return .standard }
        if isSnapshot {
            return UserDefaults(suiteName: "kronos.snapshot." + UUID().uuidString) ?? .standard
        }
        let name = "kronos.hermetic." + storeDirectory.path.replacingOccurrences(of: "/", with: "_")
        return UserDefaults(suiteName: name) ?? .standard
    }()
}

public extension Notification.Name {
    static let kronosFlushDrafts = Notification.Name("kronos.flushDrafts")
    static let kronosSaveFailed = Notification.Name("kronos.saveFailed")
}

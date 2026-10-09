import AppKit
import SwiftData
import KronosCore

/// Per-step launch timing, written to a file only when asked for (`KRONOS_LAUNCH_TRACE=1`):
/// zero cost otherwise, since every call is a single `Bool` env check before any `Date()` or
/// file I/O happens. Used by a launch-time benchmark script to find where launch time goes at
/// a realistic store shape and at scale, without adding any always-on overhead.
@MainActor
enum LaunchTrace {
    private static let enabled = ProcessInfo.processInfo.environment["KRONOS_LAUNCH_TRACE"] == "1"
    private static let start = Date()
    private static var lines: [String] = []

    static func mark(_ step: String) {
        guard enabled else { return }
        lines.append("\(step)\t\(Date().timeIntervalSince(start) * 1000)")
    }

    /// Flushed once, after the first frame is up — nothing before that point is worth
    /// blocking launch to write to disk.
    static func flush() {
        guard enabled, !lines.isEmpty else { return }
        let url = KronosStore.containerDirectory().appendingPathComponent("launch-trace.tsv")
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        lines.removeAll()
    }
}

// MARK: - Single instance

/// One Kronos per store directory: an exclusive, non-blocking `flock` on `store.lock` next to the
/// store, held for the life of the process (the kernel drops it on exit or crash, so there is
/// never a stale lock to clean up). The holder's pid is written into the file so a second launch
/// can bring the first one forward.
enum SingleInstanceLock {
    private static var held: Int32 = -1

    /// true = this process may go on. `keep` holds the lock until exit; without it the lock is
    /// taken and released at once (a probe: "would a second instance be refused?").
    /// A location that cannot be opened never blocks the app.
    static func acquire(at url: URL, keep: Bool) -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return true }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return false }
        guard keep else { flock(fd, LOCK_UN); close(fd); return true }
        held = fd
        ftruncate(fd, 0)
        let pid = Array("\(getpid())\n".utf8)
        _ = pid.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        return true
    }

    /// Brings the instance that holds the lock forward (best effort; a hidden background launch has
    /// no window to show, a Dock click restores it).
    static func activateRunningHolder(at url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.activate()
    }
}

// MARK: - Save failure notice

/// The calm notice for a failed save: one sheet on the front window, not a stack of them. While
/// it is up, further `.kronosSaveFailed` posts are ignored; once dismissed the next one shows
/// again. `presenter` is replaceable so a test can count notices without opening a dialog.
@MainActor
final class SaveFailureNotice {
    private(set) var isShowing = false
    private(set) var shownCount = 0
    var presenter: (_ done: @escaping @MainActor () -> Void) -> Void = SaveFailureNotice.presentAlert

    func report() {
        guard !isShowing else { return }
        isShowing = true
        shownCount += 1
        presenter { [weak self] in self?.isShowing = false }
    }

    /// A hidden background launch and hermetic runs have nobody to read it: nothing is shown.
    static func presentAlert(done: @escaping @MainActor () -> Void) {
        guard !MCPBackgroundLaunch.requested, !KronosEnv.isHermetic else { done(); return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "app.save_failed.title")
        alert.informativeText = String(localized: "app.save_failed.body")
        alert.addButton(withTitle: String(localized: "common.close"))
        alert.addButton(withTitle: String(localized: "app.save_failed.folder"))
        let finish: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertSecondButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([BackupScheduler.defaultDirectory])
            }
            done()
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window) { response in MainActor.assumeIsolated { finish(response) } }
        } else {
            DispatchQueue.main.async { finish(alert.runModal()) }
        }
    }
}

enum BackupFileStamp {
    /// `20261002T091530Z`, for file names that must sort and never collide across time zones.
    static func utc(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }
}

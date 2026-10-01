// Kronos/App/ReadableLaunchError.swift
// The store would not open. Instead of fatalError (a crash report and nothing else), save a copy of the
// store, then show a plain #000 window with the real error, the backups folder and Quit. Never a modal
// system alert. The app keeps running on an EMPTY IN-MEMORY store behind it so AppDelegate can finish
// init; nothing is written to disk and every other launch step is skipped (AppDelegate.launchFailure).
import AppKit
import SwiftUI
import KronosCore

struct LaunchFailure {
    let message: String
    /// The saved copy, nil when the store did not exist or could not be copied.
    let backup: URL?

    /// Runs the backup immediately: the caller is inside `AppDelegate.init`, before anything else exists.
    @MainActor static func capture(_ error: Error) -> LaunchFailure {
        let store = KronosStore.storeURL()
        let saved = StoreCrashBackup.make(store: store, into: BackupScheduler.defaultDirectory)
        return LaunchFailure(message: String(describing: error), backup: saved?.url)
    }
}

struct LaunchErrorView: View {
    let failure: LaunchFailure
    var onOpenBackups: () -> Void = {}
    var onQuit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            Text(String(localized: "app.launch.error.title"))
                .font(Typo.title)
                .foregroundStyle(Tok.textPrimary)
            Text(String(localized: "app.launch.error.body"))
                .font(Typo.body)
                .foregroundStyle(Tok.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(failure.backup.map { String(format: String(localized: "app.launch.error.backup.done"), $0.lastPathComponent) }
                 ?? String(localized: "app.launch.error.backup.failed"))
                .font(Typo.meta)
                .foregroundStyle(Tok.textTertiary)
            ScrollView {
                Text(failure.message)
                    .font(Typo.mono)
                    .foregroundStyle(Tok.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.x2)
            }
            .frame(height: 120)
            .background(RoundedRectangle(cornerRadius: Radius.row).stroke(Tok.hairline, lineWidth: Metrics.strokeHair))
            HStack(spacing: Space.x2) {
                Button(String(localized: "app.launch.error.open")) { onOpenBackups() }
                    .kButton(.secondary)
                Button(String(localized: "app.launch.error.quit")) { onQuit() }
                    .kButton(.primary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.x5)
        .frame(width: 520)
        .background(Tok.bg)
    }
}

@MainActor
enum LaunchErrorWindow {
    private static var window: NSWindow?

    static func show(_ failure: LaunchFailure) {
        let view = LaunchErrorView(failure: failure, onOpenBackups: {
            let dir = BackupScheduler.defaultDirectory
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let file = failure.backup { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            else { NSWorkspace.shared.activateFileViewerSelecting([dir]) }
        }, onQuit: { NSApp.terminate(nil) })
        let hosting = NSHostingController(rootView: view.preferredColorScheme(.dark))
        let w = NSWindow(contentViewController: hosting)
        w.title = String(localized: "app.launch.error.title")
        w.styleMask = [.titled, .closable]
        w.backgroundColor = .black
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        // Closing the only readable thing the app has means the user is done: quit rather than
        // leave an empty in-memory app running.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        // SwiftUI creates the main window after launch; keep it out of sight (retry for ~3 s).
        hideOthers(except: w, attempt: 0)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private static func hideOthers(except keep: NSWindow, attempt: Int) {
        for win in NSApp.windows where win !== keep && !(win is NSPanel) { win.orderOut(nil) }
        keep.makeKeyAndOrderFront(nil)
        guard attempt < 30 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { hideOthers(except: keep, attempt: attempt + 1) }
    }
}

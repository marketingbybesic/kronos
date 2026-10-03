// Live UI test steps for the data-safety work: the resign-active path (drafts flush, save, rolling
// backup), the single-instance lock, the "Last backup" line in Settings > Data, the second backup
// folder, pruning on disk, the import Replace safety copy and the save-failure notice.
// Everything runs against the scratch store directory of the test run; the person's store is never
// opened. `KRONOS_UITEST_BREAK=1` flips the flush-order expectation: the run must then fail.
#if !RELEASE
import AppKit
import SwiftUI
import KronosCore

@MainActor
extension LiveUITest {
    static func aBackupSteps(_ model: AppModel) async {
        let breakMode = ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil
        let fm = FileManager.default
        guard KronosEnv.isHermetic else { record("A-BACKUP runs only on a scratch store", false, "not hermetic"); return }
        let backups = BackupScheduler.defaultDirectory
        let rolling = backups.appendingPathComponent(BackupPolicy.rollingStoreName)
        let defaults = KronosEnv.defaults
        try? fm.removeItem(at: rolling)
        defaults.removeObject(forKey: BackupScheduler.lastRollingKey)
        defaults.removeObject(forKey: BackupScheduler.lastBackupKey)
        BackupScheduler.setSecondFolder(nil)

        // 1. Resign-active: drafts are flushed BEFORE the rolling copy exists, and the copy appears.
        var flushPosts = 0
        var copyExistedAtFlush = true
        let probe = NotificationCenter.default.addObserver(forName: .kronosFlushDrafts, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated {
                flushPosts += 1
                copyExistedAtFlush = FileManager.default.fileExists(atPath: rolling.path)
            }
        }
        NotificationCenter.default.post(name: NSApplication.willResignActiveNotification, object: NSApp)
        NotificationCenter.default.removeObserver(probe)
        let size = (try? fm.attributesOfItem(atPath: rolling.path)[.size] as? Int) ?? 0
        let stamp = BackupScheduler.lastBackupDate()
        let wantFlushFirst = !breakMode
        record("resign-active flushes drafts, then writes the rolling backup",
               flushPosts == 1 && (copyExistedAtFlush == false) == wantFlushFirst && size > 0
                   && stamp.map { abs($0.timeIntervalSinceNow) < 30 } == true,
               "flushPosts=\(flushPosts) copyExistedAtFlush=\(copyExistedAtFlush) bytes=\(size) stamp=\(String(describing: stamp))")

        // 2. A second resign within five minutes does not retake the copy.
        let mtime1 = (try? fm.attributesOfItem(atPath: rolling.path)[.modificationDate] as? Date) ?? nil
        try? await Task.sleep(for: .milliseconds(1100))
        NotificationCenter.default.post(name: NSApplication.willResignActiveNotification, object: NSApp)
        let mtime2 = (try? fm.attributesOfItem(atPath: rolling.path)[.modificationDate] as? Date) ?? nil
        record("rolling backup is not retaken within five minutes", mtime1 != nil && mtime1 == mtime2,
               "mtime1=\(String(describing: mtime1)) mtime2=\(String(describing: mtime2))")

        // 3. Settings > Data renders the Last backup line, in the fresh and the stale state.
        let freshText = BackupStatusLine.text(BackupScheduler.lastBackupDate())
        let line = await showDataTabLine(model)
        record("Settings > Data shows the Last backup line", line.width > 120 && line.height > 8
                   && freshText == String(localized: "settings.data.backup.last.now") && freshText.hasPrefix("Last backup"),
               "frame=\(line.width)x\(line.height) text=\(freshText)")
        let fiveDaysAgo = Date().addingTimeInterval(-5.2 * 86_400)
        let staleText = BackupStatusLine.text(fiveDaysAgo)
        record("a backup older than three days reads as a calm warning",
               BackupStatusLine.isStale(fiveDaysAgo) && staleText.contains("5 days ago") && staleText.contains("Backups may have stopped")
                   && !BackupStatusLine.isStale(Date().addingTimeInterval(-2 * 86_400))
                   && BackupStatusLine.text(nil) == String(localized: "settings.data.backup.last.never"),
               staleText)

        // 4. Single instance: the lock this process holds refuses a second taker on the same store
        // directory and does not touch a different one.
        let otherDir = fm.temporaryDirectory.appendingPathComponent("kronos-lock-probe-\(getpid())", isDirectory: true)
        let sameDirTaken = SingleInstanceLock.acquire(at: KronosEnv.lockURL, keep: false)
        let otherDirTaken = SingleInstanceLock.acquire(at: otherDir.appendingPathComponent("store.lock"), keep: false)
        try? fm.removeItem(at: otherDir)
        record("a second launch on the same store directory is refused, a scratch directory is not",
               !sameDirTaken && otherDirTaken, "sameDir=\(sameDirTaken) otherDir=\(otherDirTaken)")

        // 4b. An empty store never replaces an existing rolling copy; with no copy it writes one.
        let guardDir = fm.temporaryDirectory.appendingPathComponent("kronos-guard-\(getpid())", isDirectory: true)
        try? fm.removeItem(at: guardDir)
        let guardDefaults = UserDefaults(suiteName: "kronos.guard.\(getpid())")!
        guardDefaults.removePersistentDomain(forName: "kronos.guard.\(getpid())")
        if let emptyStore = try? TaskStore(inMemory: true) {
            let scheduler = BackupScheduler(store: emptyStore, directory: guardDir, defaults: guardDefaults,
                                            liveStore: KronosStore.storeURL())
            let first = scheduler.runRolling(force: true)                  // no copy yet: written
            let copy = guardDir.appendingPathComponent(BackupPolicy.rollingStoreName)
            try? Data("marker".utf8).write(to: copy)
            let second = scheduler.runRolling(force: true)                 // copy exists: kept
            let kept = (try? String(contentsOf: copy, encoding: .utf8)) == "marker"
            record("an empty store does not overwrite an existing rolling copy", first && !second && kept,
                   "first=\(first) second=\(second) kept=\(kept)")
        } else {
            record("an empty store does not overwrite an existing rolling copy", false, "no in-memory store")
        }
        guardDefaults.removePersistentDomain(forName: "kronos.guard.\(getpid())")
        try? fm.removeItem(at: guardDir)

        // 5. Second backup folder: a copy lands there; an unwritable one raises the flag.
        let second = fm.temporaryDirectory.appendingPathComponent("kronos-second-\(getpid())", isDirectory: true)
        try? fm.removeItem(at: second)
        BackupScheduler.setSecondFolder(second)
        let wrote = BackupScheduler(store: model.store).runRolling(force: true)
        let copied = fm.fileExists(atPath: second.appendingPathComponent(BackupPolicy.rollingStoreName).path)
        let okFlag = BackupScheduler.secondFolderFailed()
        let blocker = fm.temporaryDirectory.appendingPathComponent("kronos-blocker-\(getpid())")
        fm.createFile(atPath: blocker.path, contents: Data("x".utf8))
        BackupScheduler.setSecondFolder(blocker.appendingPathComponent("inside"))
        _ = BackupScheduler(store: model.store).runRolling(force: true)
        let badFlag = BackupScheduler.secondFolderFailed()
        BackupScheduler.setSecondFolder(nil)
        try? fm.removeItem(at: second)
        try? fm.removeItem(at: blocker)
        record("second backup folder receives the rolling copy and flags a folder it cannot write",
               wrote && copied && !okFlag && badFlag, "wrote=\(wrote) copied=\(copied) okFlag=\(okFlag) badFlag=\(badFlag)")

        // 6. Pruning on disk follows the policy and leaves folders, the rolling copy and strangers alone.
        let pruneDir = fm.temporaryDirectory.appendingPathComponent("kronos-prune-\(getpid())", isDirectory: true)
        try? fm.removeItem(at: pruneDir)
        try? fm.createDirectory(at: pruneDir.appendingPathComponent("pre-v2-20261002T000000Z"), withIntermediateDirectories: true)
        for n in 1...16 { fm.createFile(atPath: pruneDir.appendingPathComponent(String(format: "kronos-2026-09-%02d.json", n)).path, contents: Data("{}".utf8)) }
        fm.createFile(atPath: pruneDir.appendingPathComponent(BackupPolicy.rollingStoreName).path, contents: Data("s".utf8))
        fm.createFile(atPath: pruneDir.appendingPathComponent("notes.txt").path, contents: Data("n".utf8))
        BackupScheduler.prune(in: pruneDir, now: Date())
        let left = Set((try? fm.contentsOfDirectory(atPath: pruneDir.path)) ?? [])
        let jsonLeft = left.filter { $0.hasPrefix("kronos-2026-09-") }.count
        record("pruning keeps 14 daily files and never removes folders, the rolling copy or other files",
               jsonLeft == 14 && !left.contains("kronos-2026-09-01.json") && !left.contains("kronos-2026-09-02.json")
                   && left.contains("kronos-2026-09-16.json") && left.contains("pre-v2-20261002T000000Z")
                   && left.contains(BackupPolicy.rollingStoreName) && left.contains("notes.txt"),
               "left=\(left.count) json=\(jsonLeft)")
        try? fm.removeItem(at: pruneDir)

        // 7. Import Replace on a throwaway in-memory store: the safety copies exist and hold the
        // data from BEFORE the wipe; an empty file and an unwritable safety folder change nothing.
        await replaceSafetyStep(backups: backups)

        // 8. A failed save raises one notice until it is dismissed.
        guard let delegate = AppDelegate.shared else { record("app delegate present", false, ""); return }
        let notice = delegate.saveFailureNotice
        let originalPresenter = notice.presenter
        var finish: (@MainActor () -> Void)?
        notice.presenter = { done in finish = done }
        let before = notice.shownCount
        NotificationCenter.default.post(name: .kronosSaveFailed, object: nil)
        NotificationCenter.default.post(name: .kronosSaveFailed, object: nil)
        let afterTwo = notice.shownCount
        finish?()
        NotificationCenter.default.post(name: .kronosSaveFailed, object: nil)
        let afterDismiss = notice.shownCount
        finish?()
        notice.presenter = originalPresenter
        record("a failed save shows one notice until it is dismissed",
               afterTwo - before == 1 && afterDismiss - before == 2, "shown=\(afterTwo - before) then \(afterDismiss - before)")
    }

    /// Hosts Settings > Data in a window of its own, waits for the Last backup line to report its
    /// frame, and returns it (zero size = never rendered). The main test window is key again after.
    private static func showDataTabLine(_ model: AppModel) async -> CGSize {
        UITestAnchors.frames["settings.data.lastBackup"] = nil
        let root = ScrollView {
            VStack(alignment: .leading, spacing: Space.x6) { SettingsDataTab(model: model) }
                .padding(Space.x6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Tok.bg)
        let win = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 760, height: 900),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.contentView = NSHostingView(rootView: root)
        win.isReleasedWhenClosed = false
        win.orderFrontRegardless()
        var size = CGSize.zero
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(100))
            if let f = UITestAnchors.frames["settings.data.lastBackup"], f.width > 0 { size = f.size; break }
        }
        win.orderOut(nil)
        win.close()
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(300))
        return size
    }

    private static func replaceSafetyStep(backups: URL) async {
        let fm = FileManager.default
        func fileData(_ titles: [String]) throws -> Data {
            let source = try TaskStore(inMemory: true)
            for t in titles { _ = source.create(title: t, project: nil) }
            try source.context.save()
            return try KronosExportCodec.makeEncoder().encode(JSONExporter(store: source).makeEnvelope())
        }
        do {
            let target = try TaskStore(inMemory: true)
            for t in ["Keep one", "Keep two"] { _ = target.create(title: t, project: nil) }
            try target.context.save()
            let when = Date(timeIntervalSince1970: 1_790_000_000)
            let result = try ImportRunner.run(data: try fileData(["New a", "New b", "New c"]), mode: .replace,
                                              store: target, backups: backups, liveStore: KronosStore.storeURL(), now: when)
            let stem = BackupRestore.preImportStem(now: when)
            let json = backups.appendingPathComponent(stem + ".json")
            let copy = backups.appendingPathComponent(stem + ".store")
            let beforeWipe = (try? BackupFile.read(from: json))?.tasks.map(\.title).sorted()
            let after = target.allTasksIncludingDeleted().map(\.title).sorted()
            record("import Replace writes the safety copies first and then replaces",
                   result.tasks == 3 && fm.fileExists(atPath: copy.path) && beforeWipe == ["Keep one", "Keep two"]
                       && after == ["New a", "New b", "New c"],
                   "copies=\(fm.fileExists(atPath: json.path))/\(fm.fileExists(atPath: copy.path)) before=\(String(describing: beforeWipe)) after=\(after)")

            var empty = ""
            do { _ = try ImportRunner.run(data: try fileData([]), mode: .replace, store: target, backups: backups,
                                          liveStore: KronosStore.storeURL(), now: when.addingTimeInterval(10)) }
            catch let e as KronosImporter.ImportError { empty = "\(e)" }
            let blocker = fm.temporaryDirectory.appendingPathComponent("kronos-import-blocker-\(getpid())")
            fm.createFile(atPath: blocker.path, contents: Data("x".utf8))
            var unsafe = ""
            do { _ = try ImportRunner.run(data: try fileData(["Other"]), mode: .replace, store: target,
                                          backups: blocker.appendingPathComponent("sub"),
                                          liveStore: KronosStore.storeURL(), now: when.addingTimeInterval(20)) }
            catch let e as KronosImporter.ImportError { unsafe = "\(e)" }
            try? fm.removeItem(at: blocker)
            let still = target.allTasksIncludingDeleted().map(\.title).sorted()
            record("import Replace refuses an empty file and stops when the safety copy cannot be written",
                   empty == "emptyEnvelope" && unsafe == "safetyCopyFailed" && still == ["New a", "New b", "New c"],
                   "empty=\(empty) unsafe=\(unsafe) still=\(still)")
        } catch {
            record("import Replace safety step ran", false, "\(error)")
        }
    }
}
#endif

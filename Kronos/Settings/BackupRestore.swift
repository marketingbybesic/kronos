// Kronos/Settings/BackupRestore.swift
// The pure + file-level half of Settings > Data > "Restore from backup". Foundation + SQLite3
// only, so scripts/restore-selftest.swift compiles this real file.
//
// A backup here is a `.store` file: a consistent copy of the SwiftData (SQLite) store made with
// SQLite's own online-backup API, so it is safe to take while the app has the store open (a plain
// file copy of a live WAL database can tear). A restore never touches the live files while the
// app runs: the app quits and a tiny detached shell script waits for it to exit, swaps the
// store + -wal + -shm together, then opens the app again.
import Foundation
import SQLite3

struct StoreBackupEntry: Identifiable, Equatable {
    let url: URL
    let date: Date
    let bytes: Int64
    var id: URL { url }
    /// Written by "Restore" (`pre-restore-`) or by an import that replaces everything
    /// (`pre-import-`), so either can be undone.
    var isSafetyCopy: Bool {
        let name = url.lastPathComponent
        return name.hasPrefix(BackupRestore.safetyPrefix) || name.hasPrefix(BackupRestore.preImportPrefix)
    }
}

enum BackupRestore {
    static let safetyPrefix = "pre-restore-"
    static let preImportPrefix = "pre-import-"

    enum RestoreError: Error { case openSource, openDestination, copy, missingSource }

    // MARK: Listing

    /// Every `*.store` file in `dir`, newest first. Companion -wal/-shm files are not listed.
    static func list(in dir: URL, fileManager fm: FileManager = .default) -> [StoreBackupEntry] {
        guard let urls = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return [] }
        return urls.filter { $0.pathExtension == "store" }.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard let date = values?.contentModificationDate else { return nil }
            return StoreBackupEntry(url: url, date: date, bytes: Int64(values?.fileSize ?? 0))
        }.sorted { $0.date > $1.date }
    }

    private static func stamp(_ now: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: now)
    }

    static func safetyFileName(now: Date) -> String {
        "\(safetyPrefix)\(stamp(now)).store"
    }

    /// File stem shared by the two safety files an import Replace writes first
    /// (`<stem>.json` readable, `<stem>.store` restorable).
    static func preImportStem(now: Date) -> String { "\(preImportPrefix)\(stamp(now))" }

    /// The restorable half of the safety copy taken before an import Replace. Throws when the
    /// live store cannot be read or the copy cannot be written; the caller then stops the import.
    @discardableResult
    static func snapshotBeforeImport(live: URL, into directory: URL, now: Date,
                                     fileManager fm: FileManager = .default) throws -> URL {
        let dest = directory.appendingPathComponent(preImportStem(now: now) + ".store")
        try snapshot(from: live, to: dest, fileManager: fm)
        return dest
    }

    /// The typed gate: case-insensitive, surrounding whitespace ignored, same rule as the
    /// import "replace" confirm.
    static func confirmationMatches(_ typed: String, word: String) -> Bool {
        !word.isEmpty && typed.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(word) == .orderedSame
    }

    // MARK: Snapshot (SQLite online backup)

    /// Writes a consistent single-file copy of the SQLite store at `source` to `destination`.
    /// Goes through `<destination>.partial` and a rename, so a crash never leaves a half file
    /// that looks like a backup. The copy holds full plaintext task titles/notes, so it is
    /// locked to the person only — 0600 — the same explicit lockdown
    /// `SingleInstanceLock.acquire` applies to its own lock file.
    static func snapshot(from source: URL, to destination: URL, fileManager fm: FileManager = .default) throws {
        guard fm.fileExists(atPath: source.path) else { throw RestoreError.missingSource }
        let partial = destination.appendingPathExtension("partial")
        try? fm.removeItem(at: partial)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        var input: OpaquePointer?
        guard sqlite3_open_v2(source.path, &input, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(input); throw RestoreError.openSource
        }
        defer { sqlite3_close(input) }
        var output: OpaquePointer?
        guard sqlite3_open_v2(partial.path, &output, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            sqlite3_close(output); throw RestoreError.openDestination
        }
        guard let backup = sqlite3_backup_init(output, "main", input, "main") else {
            sqlite3_close(output); try? fm.removeItem(at: partial); throw RestoreError.copy
        }
        let step = sqlite3_backup_step(backup, -1)
        sqlite3_backup_finish(backup)
        sqlite3_close(output)
        guard step == SQLITE_DONE else { try? fm.removeItem(at: partial); throw RestoreError.copy }
        // Closing the last connection checkpoints and removes a WAL, but be explicit.
        try? fm.removeItem(atPath: partial.path + "-wal")
        try? fm.removeItem(atPath: partial.path + "-shm")
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: partial, to: destination)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    // MARK: The swap (runs after the app has quit)

    /// Arguments: 1 pid of the running app, 2 chosen backup, 3 live store, 4 app bundle, 5 opener,
    /// 6 how many tenths of a second to wait for the app to exit (default 100).
    /// Waits for the app to exit. If it is STILL running the swap is refused (exit 3, nothing
    /// touched, app not reopened: it is already open): replacing a store file under a running app
    /// corrupts it. Otherwise removes the live -wal/-shm (a stale WAL against a different store
    /// file corrupts it), copies the backup in via a temp file + rename, brings along the backup's
    /// own -wal/-shm if it has them, then opens the app again. A failed copy leaves the old store
    /// in place and still reopens the app.
    static let swapScript = """
    pid="$1"; chosen="$2"; live="$3"; app="$4"; opener="$5"; waits="${6:-100}"
    n=0
    while kill -0 "$pid" 2>/dev/null && [ "$n" -lt "$waits" ]; do sleep 0.1; n=$((n+1)); done
    if kill -0 "$pid" 2>/dev/null; then exit 3; fi
    if cp -f "$chosen" "$live.restoring"; then
      rm -f "$live-wal" "$live-shm"
      mv -f "$live.restoring" "$live"
      if [ -f "$chosen-wal" ]; then cp -f "$chosen-wal" "$live-wal"; fi
      if [ -f "$chosen-shm" ]; then cp -f "$chosen-shm" "$live-shm"; fi
    else
      rm -f "$live.restoring"
    fi
    "$opener" -n "$app"
    """

    static func swapCommand(chosen: URL, live: URL, app: URL, pid: Int32,
                            opener: String = "/usr/bin/open",
                            waitTenths: Int = 100) -> (executable: String, arguments: [String]) {
        ("/bin/sh", ["-c", swapScript, "kronos-restore", String(pid), chosen.path, live.path, app.path, opener,
                     String(waitTenths)])
    }
}

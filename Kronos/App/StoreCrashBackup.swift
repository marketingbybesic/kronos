// Kronos/App/StoreCrashBackup.swift
// When the store will not open, copy it aside BEFORE anything else can touch it. Foundation only so
// scripts/crashbackup-selftest.swift can compile this exact file against a real sqlite database.
//
// `sqlite3 .backup` is the right tool: it reads through the WAL, so a store that is mid-checkpoint
// still yields a consistent copy. If the sqlite3 binary is missing or refuses (a damaged file), fall
// back to copying the store plus its -wal and -shm side by side; a partial copy beats none.
import Foundation

enum StoreCrashBackup {
    enum Method: Equatable { case sqlite, fileCopy }

    /// Returns the backup file and how it was made, or nil when there was nothing to copy / nothing worked.
    static func make(store: URL, into directory: URL, now: Date = Date(),
                     sqliteTool: String = "/usr/bin/sqlite3") -> (url: URL, method: Method)? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: store.path) else { return nil }
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = directory.appendingPathComponent("crash-\(stamp(now)).store")
        if fm.fileExists(atPath: dest.path) { return (dest, .fileCopy) }   // same second: already saved

        if fm.isExecutableFile(atPath: sqliteTool), runBackup(tool: sqliteTool, store: store, dest: dest),
           fm.fileExists(atPath: dest.path) {
            return (dest, .sqlite)
        }
        try? fm.removeItem(at: dest)
        do {
            try fm.copyItem(at: store, to: dest)
            for suffix in ["-wal", "-shm"] {
                let side = URL(fileURLWithPath: store.path + suffix)
                if fm.fileExists(atPath: side.path) { try? fm.copyItem(at: side, to: URL(fileURLWithPath: dest.path + suffix)) }
            }
            return (dest, .fileCopy)
        } catch {
            return nil
        }
    }

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    private static func runBackup(tool: String, store: URL, dest: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        // sqlite's dot-command parser has no escape inside single quotes, so a path containing one
        // switches to double quotes (where backslash escapes work).
        let path = dest.path
        let arg: String
        if path.contains("'") {
            let esc = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            arg = ".backup \"\(esc)\""
        } else {
            arg = ".backup '\(path)'"
        }
        p.arguments = ["-readonly", store.path, arg]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

// Kronos/List/DropZoneMailSubject.swift
// Fallback for a Mail drag whose pasteboard carries the `message:` URL but no subject: read the
// subject from Mail's Envelope Index (SQLite) by Message-ID. Read-only on a private copy of the
// index and its WAL (Mail keeps the original locked and the newest messages live in the WAL);
// never AppleScript. Returns nil when Mail's data cannot be read (for instance without Full Disk
// Access) and the caller falls back to the localised "Email" title.
import Foundation
import SQLite3

enum MailSubjectLookup {
    /// The Message-ID inside a `message:%3C…%3E` / `message://%3C…%3E` URL, without angle brackets.
    static func messageID(fromURL url: String) -> String? {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.lowercased().hasPrefix("message:") else { return nil }
        s = String(s.dropFirst("message:".count))
        while s.hasPrefix("/") { s.removeFirst() }
        s = s.removingPercentEncoding ?? s
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "<> \n\t"))
        return s.isEmpty ? nil : s
    }

    /// Blocking (copies a ~60 MB file): call off the main thread.
    static func subject(forMessageURL url: String, mailRoot: URL? = nil) -> String? {
        guard let id = messageID(fromURL: url) else { return nil }
        guard let index = envelopeIndex(root: mailRoot) else { return nil }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("kronos-mailsubject-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let copy = scratch.appendingPathComponent("ei")
            for suffix in ["", "-wal", "-shm"] {
                let source = URL(fileURLWithPath: index.path + suffix)
                if FileManager.default.fileExists(atPath: source.path) {
                    try FileManager.default.copyItem(at: source, to: URL(fileURLWithPath: copy.path + suffix))
                }
            }
            return query(databaseAt: copy.path, messageID: id)
        } catch {
            return nil
        }
    }

    /// The newest `~/Library/Mail/V*/MailData/Envelope Index`.
    static func envelopeIndex(root: URL?) -> URL? {
        let base = root ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mail")
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? [])
            .filter { $0.hasPrefix("V") }.sorted()
        for v in versions.reversed() {
            let candidate = base.appendingPathComponent(v).appendingPathComponent("MailData/Envelope Index")
            if FileManager.default.isReadableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Read-only query on a database file. Exposed for the hand-made fixture test.
    static func query(databaseAt path: String, messageID id: String) -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { sqlite3_close(db); return nil }
        defer { sqlite3_close(db) }
        let sql = """
        SELECT s.subject FROM messages m \
        JOIN message_global_data g ON g.ROWID = m.global_message_id \
        JOIN subjects s ON s.ROWID = m.subject \
        WHERE g.message_id_header = ?1 OR g.message_id_header = ?2 LIMIT 1
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, "<\(id)>", -1, transient)
        sqlite3_bind_text(stmt, 2, id, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        let subject = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
        return subject.isEmpty ? nil : subject
    }
}

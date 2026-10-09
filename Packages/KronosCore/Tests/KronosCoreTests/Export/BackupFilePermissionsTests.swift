// SD-004: a backup envelope holds full plaintext task titles/notes, so the file BackupFile.write
// produces must be locked to the person only (0600), not left at the process umask's mercy.

import Testing
import Foundation
@testable import KronosCore

@MainActor
struct BackupFilePermissionsTests {

    @Test func writtenBackupFileIsOwnerOnly() throws {
        let store = try TaskStore(inMemory: true)
        _ = store.create(title: "Secret plan", notes: "Private notes", project: nil,
                         status: .todo, priority: .none, dueDay: nil)
        let envelope = JSONExporter(store: store).makeEnvelope()

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kronos-backupfile-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("backup.json")

        try BackupFile.write(envelope, to: url)

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}

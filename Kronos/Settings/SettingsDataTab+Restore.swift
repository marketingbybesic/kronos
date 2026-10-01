// Kronos/Settings/SettingsDataTab+Restore.swift
// Settings > Data > "Restore from backup": lists the `.store` copies in the backups folder
// (date + size, newest first). Pressing "Restore" on one opens the same kind of inline typed
// confirmation the import "replace" uses (the word RESTORE, never an alert). Confirming makes a
// fresh safety backup FIRST (JSON export + a consistent store snapshot, both under the backups
// folder, so a restore can itself be undone), and only then quits and lets a detached script swap
// the store + -wal + -shm together and reopen the app (BackupRestore.swift).

import AppKit
import SwiftUI
import KronosCore

struct RestoreFromBackupSection: View {
    let model: AppModel
    @State private var entries: [StoreBackupEntry]
    @State private var pending: StoreBackupEntry?
    @State private var typed = ""
    @State private var note: String?
    private let isHermetic = ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] != nil

    /// `fixture`: snapshot-only list, so a shot never depends on (or reveals) real backups.
    init(model: AppModel, fixture: [StoreBackupEntry]? = nil, pending: StoreBackupEntry? = nil) {
        self.model = model
        let hermetic = ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] != nil
        self._entries = State(initialValue: fixture ?? (hermetic ? [] : BackupRestore.list(in: BackupScheduler.defaultDirectory)))
        self._pending = State(initialValue: pending)
    }

    var body: some View {
        SettingsSection(title: String(localized: "settings.data.restore")) {
            SettingsHelpRow {
                Text(String(localized: "settings.data.restore.help"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            if entries.isEmpty {
                SettingsHelpRow {
                    Text(String(localized: "settings.data.restore.empty"))
                        .font(Typo.meta)
                        .foregroundStyle(Tok.textSecondary)
                    Spacer()
                }
            } else {
                ForEach(entries.prefix(8)) { entry in entryRow(entry) }
            }
            if let pending { confirmPanel(pending) }
            if let note {
                SettingsHelpRow {
                    Text(note).font(Typo.meta).foregroundStyle(Tok.textTertiary)
                    Spacer()
                }
            }
        }
        .onAppear { reload() }
    }

    // MARK: Rows

    private func entryRow(_ entry: StoreBackupEntry) -> some View {
        let when = Self.dateText(entry.date)
        return SettingsRow(label: when) {
            HStack(spacing: Space.x3) {
                if entry.isSafetyCopy {
                    Text(String(localized: "settings.data.restore.safety"))
                        .font(Typo.meta).foregroundStyle(Tok.textTertiary)
                }
                Text(Self.sizeText(entry.bytes))
                    .font(Typo.mono).foregroundStyle(Tok.textSecondary)
                Button(String(localized: "settings.data.restore.button")) {
                    pending = entry
                    typed = ""
                    note = nil
                }
                .kButton(.secondary, size: .compact)
                .fixedSize()
                .accessibilityLabel(String(format: String(localized: "a11y.restore.button"), when))
            }
        }
    }

    private func confirmPanel(_ entry: StoreBackupEntry) -> some View {
        let word = String(localized: "settings.data.restore.word")
        return KPanel {
            VStack(alignment: .leading, spacing: Space.x2) {
                Text(String(format: String(localized: "settings.data.restore.prompt"),
                            Self.dateText(entry.date), word))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Space.x2) {
                    KTextField(word, text: $typed)
                        .frame(width: 160)
                    Button(String(localized: "settings.data.restore.confirm")) { restore(entry) }
                        .kButton(.secondary, size: .compact)
                        .fixedSize()
                        .disabled(!BackupRestore.confirmationMatches(typed, word: word))
                    Button(String(localized: "common.cancel")) { pending = nil }
                        .kButton(.ghost, size: .compact)
                        .fixedSize()
                }
            }
        }
    }

    // MARK: Actions

    private func reload() {
        guard !isHermetic else { return }
        entries = BackupRestore.list(in: BackupScheduler.defaultDirectory)
    }

    private func restore(_ entry: StoreBackupEntry) {
        guard !isHermetic else { pending = nil; return }
        let dir = BackupScheduler.defaultDirectory
        let now = Date()
        do {
            // The safety backup comes first and any failure aborts: nothing is replaced unless
            // the current data has just been saved twice (readable JSON + restorable store).
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stem = BackupRestore.safetyFileName(now: now).replacingOccurrences(of: ".store", with: "")
            try BackupFile.write(JSONExporter(store: model.store).makeEnvelope(now: now),
                                 to: dir.appendingPathComponent(stem + ".json"))
            try BackupRestore.snapshot(from: KronosStore.storeURL(),
                                       to: dir.appendingPathComponent(stem + ".store"))
            let cmd = BackupRestore.swapCommand(chosen: entry.url, live: KronosStore.storeURL(),
                                                app: Bundle.main.bundleURL,
                                                pid: ProcessInfo.processInfo.processIdentifier)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cmd.executable)
            process.arguments = cmd.arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            NSApp.terminate(nil)
        } catch {
            pending = nil
            note = String(localized: "settings.data.restore.failed")
        }
    }

    // MARK: Formatting

    static func dateText(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute())
    }

    static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

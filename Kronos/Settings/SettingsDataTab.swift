// Kronos/Settings/SettingsDataTab.swift
// Export/import backup, daily automatic backup + keep-14 + Open backups folder, store
// location (read-only, Reveal in Finder). Replace requires an inline typed confirmation,
// never an alert (ui-common.md "no red anywhere... wording and position, not colour").
// The manual "Re-import Linear seed" section was removed as unnecessary; AppDelegate.swift's
// first-run seed import is untouched and separate from this control.

import AppKit
import SwiftUI
import KronosCore
import UniformTypeIdentifiers

struct SettingsDataTab: View {
    let model: AppModel
    @State private var dailyBackupEnabled: Bool = AppSettingsStore2.dailyBackupEnabled
    @State private var importSummary: ImportSummary?
    @State private var replaceConfirmText: String = ""
    @State private var lastActionNote: String?
    @State private var lastBackup: Date? = BackupStatusLine.initialLastBackup()
    @State private var secondFolder: URL? = BackupScheduler.secondFolder()
    @State private var secondFolderFailed: Bool = BackupScheduler.secondFolderFailed()
    private let isHermetic = ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] != nil

    private struct ImportSummary: Identifiable {
        let id = UUID()
        let envelope: KronosExportEnvelope
        let url: URL
    }

    var body: some View {
        SettingsSection(title: String(localized: "settings.data.section.transfer")) {
            SettingsRow(label: String(localized: "settings.data.export.label")) {
                Button(String(localized: "settings.data.export")) { exportBackup() }
                    .kButton(.secondary, size: .compact)
                    .fixedSize()
            }
            SettingsRow(label: String(localized: "settings.data.import.label")) {
                Button(String(localized: "settings.data.import")) { pickImportFile() }
                    .kButton(.secondary, size: .compact)
                    .fixedSize()
            }
            if let summary = importSummary {
                importConfirmPanel(summary)
            }
            if let note = lastActionNote {
                SettingsHelpRow {
                    Text(note).font(Typo.meta).foregroundStyle(Tok.textTertiary)
                    Spacer()
                }
            }
        }

        TemplatesSettingsSection(store: TemplateStore.shared)

        SettingsSection(title: String(localized: "settings.data.backup")) {
            // The row must not repeat the section title verbatim —
            // "settings.data.backup.label" was added to the catalog for this, styled after
            // "settings.general.launch" -> "settings.general.launch.label"'s existing
            // section-title/row-label split for the identical toggle-under-a-same-named-
            // section shape.
            SettingsRow(label: String(localized: "settings.data.backup.label")) {
                Toggle(isOn: $dailyBackupEnabled) { EmptyView() }
                    .toggleStyle(.switch)
                    .tint(Tok.textPrimary)
                    .labelsHidden()
                    .onChange(of: dailyBackupEnabled) { _, v in AppSettingsStore2.dailyBackupEnabled = v }
            }
            lastBackupLine
            SettingsHelpRow {
                Text(String(localized: "settings.data.backup.keep"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                Spacer()
            }
            SettingsRow(label: String(localized: "settings.data.backup.second.label")) {
                HStack(spacing: Space.x2) {
                    Text(secondFolder?.lastPathComponent ?? String(localized: "settings.data.backup.second.off"))
                        // A folder name is a path and stays monospace; "Off" is a word.
                        .font(secondFolder == nil ? Typo.row : Typo.mono)
                        .foregroundStyle(Tok.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(secondFolder?.path ?? "")
                    Button(String(localized: "settings.data.backup.second.choose")) { chooseSecondFolder() }
                        .kButton(.secondary, size: .compact)
                        .fixedSize()
                    if secondFolder != nil {
                        Button(String(localized: "settings.data.backup.second.clear")) { setSecondFolder(nil) }
                            .kButton(.ghost, size: .compact)
                            .fixedSize()
                    }
                }
            }
            if secondFolder != nil {
                SettingsHelpRow {
                    Text(secondFolderFailed ? String(localized: "settings.data.backup.second.failed")
                                            : String(localized: "settings.data.backup.second.help"))
                        .font(Typo.meta)
                        .foregroundStyle(secondFolderFailed ? Tok.textPrimary : Tok.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
            }
            SettingsTrailingRow {
                Button(String(localized: "settings.data.backup.open_folder")) { revealBackupsFolder() }
                    .kButton(.ghost, size: .compact)
                    .fixedSize()
            }
        }

        RestoreFromBackupSection(model: model)   // SettingsDataTab+Restore.swift

        SettingsSection(title: String(localized: "settings.data.section.storage")) {
            // A nested KPanel here (border inside the section's own border) put this row's
            // text button ~14pt further right than every other trailing text button in
            // Settings, since its own inner padding (4pt) was smaller than the section
            // panel's (14pt) — one shared row grid, no second border, fixes both: text-style
            // buttons must end on the same trailing x as bordered buttons.
            HStack {
                Text(storeLocationDisplay)
                    .font(Typo.mono)
                    .foregroundStyle(Tok.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Space.x4)
                Button(String(localized: "settings.data.reveal")) { revealStore() }
                    .kButton(.ghost, size: .compact)
                    .fixedSize()
            }
            .frame(height: Metrics.controlRegular)
        }
    }

    // MARK: Export

    private func exportBackup() {
        guard !isHermetic else { lastActionNote = String(localized: "settings.data.export.done"); return }
        var envelope = JSONExporter(store: model.store).makeEnvelope()
        // Templates live in their own JSON file (TemplateStore); older builds ignore this key.
        let templates = TemplateStore.shared.templates
        if !templates.isEmpty { envelope.templates = templates }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "kronos-backup.json"
        panel.presentOnKeyWindow { url in
            do {
                try BackupFile.write(envelope, to: url)
                lastActionNote = String(localized: "settings.data.export.done")
            } catch {
                lastActionNote = String(localized: "settings.data.export.failed")
            }
        }
    }

    // MARK: Import

    private func pickImportFile() {
        guard !isHermetic else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.presentOnKeyWindow { url in
            do {
                let envelope = try BackupFile.read(from: url)
                importSummary = ImportSummary(envelope: envelope, url: url)
                replaceConfirmText = ""
            } catch {
                lastActionNote = String(localized: "settings.data.import.failed")
            }
        }
    }

    @ViewBuilder
    private func importConfirmPanel(_ summary: ImportSummary) -> some View {
        KPanel {
            VStack(alignment: .leading, spacing: Space.x2) {
                Text(importCountsText(summary.envelope))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textSecondary)
                HStack(spacing: Space.x2) {
                    Button(String(localized: "settings.data.import.merge")) {
                        runImport(summary, mode: .merge)
                    }
                    .kButton(.primary, size: .compact)
                    Button(String(localized: "common.cancel")) { importSummary = nil }
                        .kButton(.ghost, size: .compact)
                }
                // Replace requires an inline typed confirmation, not an alert: the word
                // itself typed out is the confirmation gesture.
                VStack(alignment: .leading, spacing: Space.x1) {
                    Text(String(format: String(localized: "settings.data.import.replace.prompt"),
                                String(localized: "settings.data.import.replace.word")))
                        .font(Typo.meta)
                        .foregroundStyle(Tok.textTertiary)
                    HStack(spacing: Space.x2) {
                        KTextField(String(localized: "settings.data.import.replace.word"), text: $replaceConfirmText)
                            .frame(width: 160)
                        Button(String(localized: "settings.data.import.replace")) {
                            runImport(summary, mode: .replace)
                        }
                        .kButton(.secondary, size: .compact)
                        .disabled(replaceConfirmText.caseInsensitiveCompare(
                            String(localized: "settings.data.import.replace.word")) != .orderedSame
                            || summary.envelope.tasks.isEmpty)
                    }
                }
            }
        }
    }

    private func importCountsText(_ e: KronosExportEnvelope) -> String {
        String(format: String(localized: "settings.data.import.summary"),
               String(e.tasks.count), String(e.projects.count), String(e.areas.count))
    }

    private func runImport(_ summary: ImportSummary, mode: KronosImporter.Mode) {
        guard !isHermetic else { importSummary = nil; return }
        do {
            let data = try KronosExportCodec.makeEncoder().encode(summary.envelope)
            _ = try ImportRunner.run(data: data, mode: mode, store: model.store)
            if let incoming = summary.envelope.templates {
                TemplateStore.shared.importTemplates(incoming, replace: mode == .replace)
            }
            model.didMutate()
            importSummary = nil
            lastActionNote = String(localized: "settings.data.import.done")
        } catch let error as KronosImporter.ImportError {
            switch error {
            case .emptyEnvelope: lastActionNote = String(localized: "settings.data.import.empty")
            case .safetyCopyFailed: lastActionNote = String(localized: "settings.data.import.safety_failed")
            case .saveFailed: lastActionNote = String(localized: "settings.data.import.failed")
            }
            model.didMutate()
        } catch {
            lastActionNote = String(localized: "settings.data.import.failed")
        }
    }

    // MARK: Last backup and second folder

    private var lastBackupLine: some View {
        let now = Date()
        let stale = BackupStatusLine.isStale(lastBackup, now: now)
        return SettingsHelpRow {
            Text(BackupStatusLine.text(lastBackup, now: now))
                .font(Typo.meta)
                .foregroundStyle(stale ? Tok.textPrimary : Tok.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .uiTestAnchor("settings.data.lastBackup")
        .onAppear {
            lastBackup = BackupStatusLine.initialLastBackup()
            secondFolderFailed = BackupScheduler.secondFolderFailed()
        }
    }

    private func chooseSecondFolder() {
        guard !isHermetic else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.presentOnKeyWindow { url in
            // The backups folder itself would copy every file onto itself.
            guard url.standardizedFileURL != BackupScheduler.defaultDirectory.standardizedFileURL else { return }
            setSecondFolder(url)
        }
    }

    private func setSecondFolder(_ url: URL?) {
        BackupScheduler.setSecondFolder(url)
        secondFolder = url
        secondFolderFailed = false
    }

    // MARK: Backups folder / store location

    private func revealBackupsFolder() {
        guard !isHermetic else { return }
        let dir = BackupScheduler.defaultDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    /// Abbreviated with a tilde so no screenshot of this row ever shows a full account/user
    /// path. "Reveal in Finder" below still resolves the real URL, unaffected by this display
    /// string.
    private var storeLocationDisplay: String {
        (KronosStore.storeURL().path as NSString).abbreviatingWithTildeInPath
    }

    private func revealStore() {
        guard !isHermetic else { return }
        NSWorkspace.shared.activateFileViewerSelecting([KronosStore.storeURL()])
    }
}

/// The text of the "Last backup" line, from the pure rule in KronosCore (`BackupPolicy.lastBackup`).
/// Calm by design: no colour alarm, a stale state only reads brighter and says what to check.
enum BackupStatusLine {
    static func initialLastBackup() -> Date? {
        #if !RELEASE
        // Snapshot runs have a fresh defaults suite; this lets a shot show each state.
        if let raw = ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT_LASTBACKUP"] {
            return Double(raw).map { Date().addingTimeInterval(-$0) }
        }
        #endif
        return BackupScheduler.lastBackupDate()
    }

    static func isStale(_ last: Date?, now: Date = Date()) -> Bool {
        if case .stale = BackupPolicy.lastBackup(last, now: now) { return true }
        return false
    }

    static func text(_ last: Date?, now: Date = Date()) -> String {
        switch BackupPolicy.lastBackup(last, now: now) {
        case .never:
            return String(localized: "settings.data.backup.last.never")
        case .recent(let seconds):
            guard let last, seconds >= 60 else { return String(localized: "settings.data.backup.last.now") }
            return String(format: String(localized: "settings.data.backup.last.ago"), relative(last, now))
        case .stale:
            guard let last else { return String(localized: "settings.data.backup.last.never") }
            return String(format: String(localized: "settings.data.backup.last.stale"), relative(last, now))
        }
    }

    private static func relative(_ date: Date, _ now: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: now)
    }
}

/// Import with the safety net in front of Replace: before anything is deleted, the current data
/// is written twice into the backups folder (`pre-import-<time>.json` readable and
/// `pre-import-<time>.store` restorable). If either cannot be written the import stops and
/// nothing is changed.
@MainActor
enum ImportRunner {
    @discardableResult
    static func run(data: Data, mode: KronosImporter.Mode, store: TaskStore,
                    backups: URL = BackupScheduler.defaultDirectory,
                    liveStore: URL = KronosStore.storeURL(),
                    now: Date = Date()) throws -> KronosImporter.Result {
        try KronosImporter(store: store).importData(data, mode: mode) {
            let fm = FileManager.default
            try fm.createDirectory(at: backups, withIntermediateDirectories: true)
            // The store copy reads the file on disk: write what is pending first.
            store.context.processPendingChanges()
            if store.context.hasChanges { try store.context.save() }
            let json = backups.appendingPathComponent(BackupRestore.preImportStem(now: now) + ".json")
            try BackupFile.write(JSONExporter(store: store).makeEnvelope(now: now), to: json)
            let copy = try BackupRestore.snapshotBeforeImport(live: liveStore, into: backups, now: now)
            guard fm.fileExists(atPath: json.path), fm.fileExists(atPath: copy.path) else {
                throw KronosImporter.ImportError.safetyCopyFailed
            }
        }
    }
}

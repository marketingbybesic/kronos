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
            SettingsHelpRow {
                Text(String(localized: "settings.data.backup.keep"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                Spacer()
            }
            SettingsTrailingRow {
                Button(String(localized: "settings.data.backup.open_folder")) { revealBackupsFolder() }
                    .kButton(.ghost, size: .compact)
                    .fixedSize()
            }
        }

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
        let envelope = JSONExporter(store: model.store).makeEnvelope()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "kronos-backup.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try BackupFile.write(envelope, to: url)
            lastActionNote = String(localized: "settings.data.export.done")
        } catch {
            lastActionNote = String(localized: "settings.data.export.failed")
        }
    }

    // MARK: Import

    private func pickImportFile() {
        guard !isHermetic else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let envelope = try BackupFile.read(from: url)
            importSummary = ImportSummary(envelope: envelope, url: url)
            replaceConfirmText = ""
        } catch {
            lastActionNote = String(localized: "settings.data.import.failed")
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
                            String(localized: "settings.data.import.replace.word")) != .orderedSame)
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
            _ = try KronosImporter(store: model.store).importData(data, mode: mode)
            model.didMutate()
            importSummary = nil
            lastActionNote = String(localized: "settings.data.import.done")
        } catch {
            lastActionNote = String(localized: "settings.data.import.failed")
        }
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

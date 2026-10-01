// Kronos/Settings/SettingsAboutTab.swift
// Settings > About (last tab): app name, version + build id, and "Check for updates". The check
// is one GET to the public GitHub releases API (UpdateCheck.swift), run only when the button is
// pressed; the result is one calm line plus, when a newer version exists, a button that opens
// its download page in the browser. There is no self-update: a deliberate choice until Developer ID signing is in place.

import AppKit
import SwiftUI

struct SettingsAboutTab: View {
    enum Phase: Equatable {
        case idle
        case checking
        case done(UpdateOutcome)
    }

    @State private var phase: Phase
    private let isHermetic = ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] != nil

    init(initial: Phase = .idle) {
        self._phase = State(initialValue: initial)
    }

    /// The raw marketing version ("1.0.0"), which is what the tag comparison needs; Settings >
    /// General shows the friendlier channel name.
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    private var buildID: String {
        Bundle.main.infoDictionary?["KronosBuildID"] as? String ?? "dev"
    }

    private var appName: String {
        (Bundle.main.infoDictionary?["CFBundleName"] as? String) ?? "Kronos"
    }

    var body: some View {
        SettingsSection(title: String(localized: "settings.tab.about")) {
            SettingsRow(label: String(localized: "settings.about.name.label")) {
                Text(appName).font(Typo.row).foregroundStyle(Tok.textSecondary)
            }
            SettingsRow(label: String(localized: "settings.about.version.label")) {
                Text(version).font(Typo.mono).foregroundStyle(Tok.textSecondary)
            }
            SettingsRow(label: String(localized: "settings.about.build.label")) {
                Text(buildID).font(Typo.mono).foregroundStyle(Tok.textSecondary)
            }
        }

        SettingsSection(title: String(localized: "settings.about.section.updates")) {
            SettingsRow(label: String(localized: "settings.about.update.label")) {
                Button(String(localized: "settings.about.update.check")) { check() }
                    .kButton(.secondary, size: .compact)
                    .fixedSize()
                    .disabled(phase == .checking)
            }
            statusRow
            SettingsHelpRow {
                Text(String(localized: "settings.about.update.note"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .checking:
            statusLine(String(localized: "settings.about.update.checking"))
        case .done(.upToDate):
            statusLine(String(localized: "settings.about.update.uptodate"))
        case .done(.noRelease):
            statusLine(String(localized: "settings.about.update.none"))
        case .done(.failed):
            statusLine(String(localized: "settings.about.update.error"))
        case .done(.available(let found, let page)):
            SettingsRow(label: String(format: String(localized: "settings.about.update.available"), found)) {
                Button(String(localized: "settings.about.update.open")) { open(page) }
                    .kButton(.primary, size: .compact)
                    .fixedSize()
            }
        }
    }

    private func statusLine(_ text: String) -> some View {
        SettingsHelpRow {
            Text(text).font(Typo.meta).foregroundStyle(Tok.textSecondary)
            Spacer()
        }
    }

    private func check() {
        guard !isHermetic else { return }
        phase = .checking
        let current = version
        Task {
            let outcome = await UpdateCheck.fetch(current: current)
            phase = .done(outcome)
        }
    }

    private func open(_ page: URL) {
        guard !isHermetic else { return }
        NSWorkspace.shared.open(page)
    }
}

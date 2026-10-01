// Kronos/Capture/CapturePasteView+Reminders.swift
// The "From Reminders…" source button next to "From Apple Notes", and its one-line feedback
// (reading / nothing open / access denied with the System Settings fallback). Same calm pattern
// as the Notes access row: no alert, no retry loop.
import SwiftUI
import AppKit

extension CapturePasteView {
    var remindersButton: some View {
        Button(String(localized: "capture.reminders.from")) {
            Task { await capture.importFromReminders() }
        }
        .kButton(.secondary).fixedSize()
        .disabled(capture.remindersState == .reading)
    }

    @ViewBuilder
    var remindersFeedback: some View {
        switch capture.remindersState {
        case .idle:
            EmptyView()
        case .reading:
            Text(String(localized: "capture.reminders.loading"))
                .font(Typo.meta).foregroundStyle(Tok.textTertiary)
        case .empty:
            Text(String(localized: "capture.reminders.empty"))
                .font(Typo.meta).foregroundStyle(Tok.textTertiary)
        case .denied:
            HStack(spacing: Space.x3) {
                Text(String(localized: "capture.reminders.denied"))
                    .font(Typo.meta).foregroundStyle(Tok.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(String(localized: "capture.reminders.denied.action")) {
                    guard ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] == nil,
                          let url = URL(string: PermissionsPane.privacyReminders) else { return }
                    NSWorkspace.shared.open(url)
                }
                .kButton(.secondary, size: .compact)
                .fixedSize()
            }
        }
    }
}

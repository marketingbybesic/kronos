// Kronos/Settings/SettingsLayout.swift
// Shared row/section scaffolding for every Settings tab, so "label on one grid column,
// control on the other, one control height" is written once rather than per tab.

import SwiftUI

/// A titled group of rows inside a KPanel, spaced consistently between sections.
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            Text(title)
                .font(Typo.sectionHdr)
                .foregroundStyle(Tok.textTertiary)
            KPanel {
                // Full-width on purpose: without this, the panel sizes to its widest row
                // (e.g. a long button), and a narrower row's trailing-aligned control (a
                // switch, a compact toggle) lands short of that row's own true right edge
                // instead of sharing one coordinate space with every other row.
                VStack(alignment: .leading, spacing: Space.x1) {
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One label/control row, fixed to `Metrics.controlRegular` height so every control in
/// Settings lines up regardless of which one it is (menu, toggle, field, button). The
/// control column has a MINIMUM width so every row's trailing edge starts at the same x
/// at minimum, but a wider control (a button whose label must never truncate) is free to
/// grow past it rather than being clipped into it.
struct SettingsRow<Control: View>: View {
    let label: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack {
            Text(label)
                .font(Typo.row)
                .foregroundStyle(Tok.textPrimary)
            Spacer(minLength: Space.x4)
            control()
                .frame(minWidth: SettingsMetrics.trailingColumn, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Metrics.controlRegular)
    }
}

/// Quiet help text under a row, optionally paired with a trailing action (e.g. Restart).
/// Any trailing button is pinned to the same column as SettingsRow's control so its right
/// edge lines up with every other row's. Usage:
/// `SettingsHelpRow { Text(...).font(Typo.meta)...; Spacer(); Button(...) }`
struct SettingsHelpRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, Space.x1)
    }
}

/// A trailing-only help/action row whose single control shares SettingsRow's trailing
/// column width, so a lone "Show in Finder" / "Open backups folder" text button lines up
/// with every switch and popup above it.
struct SettingsTrailingRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack {
            Spacer(minLength: Space.x4)
            content()
                .frame(minWidth: SettingsMetrics.trailingColumn, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum SettingsMetrics {
    /// Every row's control column ends at this width from the trailing edge, so a Picker
    /// (~220pt), a KTextField (~260pt) and a bare text Button all share one right edge.
    static let trailingColumn: CGFloat = 260
    /// Fixed label width for a sound cue row (task/subtask/Impuls), so the preview button
    /// and the "Use my own sound…"/"Built-in" control line up across all three rows. Wide
    /// enough for "Podzadatak gotov" / "Početak Impulsa" (HR) on one line — the longest of
    /// the three labels — so rows do not wrap and misalign the trailing controls.
    static let cueLabelColumn: CGFloat = 150
}

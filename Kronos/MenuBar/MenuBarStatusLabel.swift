// Kronos/MenuBar/MenuBarStatusLabel.swift
// The status item's own rendered content: glyph + composed title, captured to a flattened
// NSImage by MenuBarOrdoController.makeLabelImage. Mirrors Kronos/DesignSystem/KMenuBarOrdoLabel
// exactly (same layout, same tokens) but takes a caller-supplied SF Symbol name — needed for
// the "All clear" state's check-circle glyph, which KMenuBarOrdoLabel itself always renders
// as "list.bullet.circle". Kept in Kronos/MenuBar/ (app layer, not Kronos/DesignSystem/) since
// a shared design-system component should not gain a one-off parameter for this; a `symbol:`
// parameter on KMenuBarOrdoLabel defaulting to "list.bullet.circle" would let this file retire
// later.
import SwiftUI

struct MenuBarStatusLabel: View {
    let title: String?     // nil = queue empty, falls back to "ordo.title" like KMenuBarOrdoLabel
    let symbolName: String

    private var truncated: String {
        guard let title else { return String(localized: "ordo.title") }
        return title   // already composed + truncated by MenuBarTitleComposer before reaching here
    }

    var body: some View {
        HStack(spacing: Space.x1) {
            Icon(symbolName, size: Metrics.iconM)
            Text(truncated)
                .font(Typo.row)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: String(localized: "menubar.ordo.accessibility"), title ?? String(localized: "bar.empty")))
    }
}

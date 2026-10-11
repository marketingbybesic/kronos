// Kronos/List/DragLiftPreview.swift
// The OS drag image for a lifted row (ListRowView / ChildTaskRow `.onDrag(_:preview:)`).
// `onDrag(_:preview:)` snapshots this view ONCE when AppKit starts the drag, so the 0.9
// opacity / `Radius.row` / `Tok.overlay` fill / 12pt-blur shadow / 1.02 scale below (spec/
// layouts-components.md §8.2) are the STATIC end state of the lift, not an animation — the
// "after a 4pt movement threshold... scaled to 1.02 over Motion.fast" motion itself is macOS's
// own native drag-initiation transition (the system always eases a dragged item up off the
// surface); nothing in this file can script that part, only the state it eases TO.
import SwiftUI

struct DragLiftPreview: View {
    let title: String
    /// 1 = dragging a single row (no badge); ≥2 = the dragged row is part of that many selected
    /// rows, shown as a circular count badge.
    let selectionCount: Int

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Text(title)
                .font(Typo.row)
                .foregroundStyle(Tok.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, Space.x3)
                .frame(height: Metrics.rowHeightDrag, alignment: .leading)
                .background(Tok.overlay, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                .opacity(0.9)
                .scaleEffect(1.02)
                .shadow(color: .black.opacity(0.4), radius: 12)

            // Positioned at the lifted row's own top-trailing corner — the closest static
            // approximation to "the cursor's top-right corner" available from a one-shot drag
            // preview (the preview has no live cursor position to anchor to; a drag normally
            // starts from inside the row, so this corner sits near the cursor in practice).
            if selectionCount >= 2 {
                Text("\(selectionCount)")
                    .font(Typo.badge)
                    .foregroundStyle(Tok.textOnAccent)
                    .frame(width: Metrics.dragSelectionBadge, height: Metrics.dragSelectionBadge)
                    .background(Circle().fill(Tok.textPrimary))
                    .offset(x: Space.x1, y: -Space.x1)
                    .uiTestAnchor("drag.selection.badge")
            }
        }
    }
}

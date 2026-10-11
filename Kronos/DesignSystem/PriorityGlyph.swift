// Kronos/DesignSystem/PriorityGlyph.swift
// Priority glyph — the internal notes §5.1. person decision (09.10.2026): priority is
// the ONE deliberate colour exception in this app's otherwise monochrome chrome — a low-to-high
// hue ramp reads faster at a glance than a bar count, and the urgent state additionally gets its
// own SHAPE (a filled square, not a bar), so urgency is never colour alone (1.4.1). This replaces
// the prior `KPriorityIndicator`, whose own doc comment banned colour for priority outright —
// that rule predated this decision and no longer applies to this component.
// Data-agnostic: takes a raw level (0 = none … 4 = urgent, matching KronosCore's own
// `KPriority.rawValue`) rather than declaring a `Priority` enum here, so the design system still
// never declares a type that could collide with KronosCore's, and this stays usable from
// `KAttributeMenu`'s generic `Option` closures (one real caller drives it from a private gallery
// fixture type, not `KPriority`, so a enum-typed `priority:` parameter would have forced a second
// parallel initializer there for no real gain over the existing Int convention).
// Usage: PriorityGlyph(level: task.priority.rawValue, label: task.priority.displayName)
import SwiftUI

public struct PriorityGlyph: View {
    let level: Int            // 0 = none, 1 = low, 2 = medium, 3 = high, 4+ = urgent
    let label: String?
    var size: CGFloat
    var isInteractive: Bool   // true in the inspector (opens the priority menu): hover brightens

    @State private var isHovering = false

    public init(level: Int, label: String? = nil, size: CGFloat = 14, isInteractive: Bool = false) {
        self.level = level
        self.label = label
        self.size = size
        self.isInteractive = isInteractive
    }

    public var body: some View {
        Group {
            if level >= 4 {
                urgentShape
            } else {
                bars
            }
        }
        .frame(width: size, height: size * Metrics.priorityGlyph.height / Metrics.priorityGlyph.width, alignment: .bottom)
        .brightness(isInteractive && isHovering ? 0.1 : 0)
        .onHover { if isInteractive { isHovering = $0 } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "viewoptions.field.priority"))
        .accessibilityValue(label ?? "")
    }

    /// Three fixed bars, 3 pt wide, 2 pt gap, bottom-aligned, heights 5/8/11 pt at the spec's
    /// base 14 x 12 box — every dimension scales with `size` so a smaller glyph (e.g. the 12 pt
    /// subtask badge) stays proportional rather than overflowing or looking cramped. All bars
    /// filled up to `level` share the SAME colour (the level's own tone); bars past `level` stay
    /// `Tok.prioNone`, never `Tok.glyphEmpty` — priority's empty state is its own faint tone now.
    private var bars: some View {
        let scale = size / Metrics.priorityGlyph.width
        let heights: [CGFloat] = [5, 8, 11]
        let color = fillColor
        return HStack(alignment: .bottom, spacing: 2 * scale) {
            ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < level ? color : Tok.prioNone)
                    .frame(width: 3 * scale, height: heights[i] * scale)
            }
        }
    }

    private var fillColor: Color {
        switch level {
        case 1: return Tok.prioLow
        case 2: return Tok.prioMedium
        case 3: return Tok.prioHigh
        default: return Tok.prioNone
        }
    }

    /// Urgent: a different SHAPE, not just a different colour (1.4.1) — a filled rounded square
    /// with a white `alert-triangle` glyph inset 3 pt.
    private var urgentShape: some View {
        let scale = size / Metrics.priorityGlyph.width
        let box = 12 * scale
        return RoundedRectangle(cornerRadius: 3 * scale, style: .continuous)
            .fill(Tok.prioUrgent)
            .frame(width: box, height: box)
            .overlay(
                Icon("alert-triangle", size: box - 6 * scale, weight: .bold)
                    .foregroundStyle(Color.white)
            )
    }
}

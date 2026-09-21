// Kronos/DesignSystem/KViewOptionsButton.swift
// Compact toolbar summary chip — "Sort: Priority ↓, Deadline ↑ · 2 filters" — that opens
// the sort/filter builders in a popover. Replaces the always-visible filter chip row.
// Usage:
//   KViewOptionsButton(summary: "Sort: Priority ↓ · 2 filters", isActive: true) { showPopover() }
//     .popover(isPresented: $showPopover) { KSortBuilder(...); KFilterBuilder(...) }
import SwiftUI

public struct KViewOptionsButton: View {
    let summary: String?     // nil = no sort/filter active
    let onTap: () -> Void
    @State private var isHovering = false

    public init(summary: String?, onTap: @escaping () -> Void) {
        self.summary = summary
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: Space.x1) {
                Icon("filter", size: Metrics.iconM)
                    .foregroundStyle(summary == nil ? Tok.textTertiary : Tok.textPrimary)
                Text(summary ?? String(localized: "viewoptions.title"))
                    .font(Typo.row)
                    .foregroundStyle(summary == nil ? Tok.textTertiary : Tok.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, Space.x3)
            .frame(height: Metrics.controlCompact)
            .background(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(isHovering ? Tok.hoverFill : (summary == nil ? .clear : Color.white.opacity(0.05)))
            )
            .kBorder(summary == nil ? Tok.borderControl : Tok.borderStrong, radius: Radius.control)
        }
        .buttonStyle(.plain)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .onHover { isHovering = $0 }
        .animation(Motion.curve(Motion.fast), value: isHovering)
        .accessibilityLabel(String(localized: "a11y.viewoptions.sortfilter"))
        .accessibilityValue(summary ?? String(localized: "a11y.viewoptions.none"))
    }
}

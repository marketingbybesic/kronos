// Kronos/DesignSystem/Border.swift
// Hairline stroke and focus-ring helpers so "1pt border, radius R" is never hand-rolled
// per view, and every focus ring in the app matches the §13 spec exactly. The focus ring
// reads the user's accent colour (`\.kAccent`, default white — feature H).
import SwiftUI

public extension View {
    /// A hairline/control stroke at the given radius. Pair with a background fill —
    /// never the sole boundary of an interactive control (spec §2.1).
    func kBorder(_ color: Color = Tok.borderControl, radius: CGFloat = Radius.control, width: CGFloat = 1) -> some View {
        overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(color, lineWidth: width))
    }

    /// A focus ring drawn outside the element's bounds with a 1pt gap, matching the
    /// element's own radius — always visible on keyboard focus, never suppressed.
    func kFocusRing(_ isFocused: Bool, radius: CGFloat = Radius.control, lineWidth: CGFloat = 2) -> some View {
        modifier(KFocusRingModifier(isFocused: isFocused, radius: radius, lineWidth: lineWidth))
    }

    /// Style G row chrome for editable rows (sort/filter rules, property rows): no box,
    /// no resting fill — a full-row hover fill is the only surface. Reports hover back so
    /// the row can wake its own secondary controls.
    func kQuietRow(isHovering: Binding<Bool>, height: CGFloat = Metrics.controlCompact) -> some View {
        padding(.horizontal, Space.x2)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                    .fill(isHovering.wrappedValue ? Tok.hoverFill : Color.clear)
            )
            .contentShape(Rectangle())
            .onHover { isHovering.wrappedValue = $0 }
            .animation(Motion.hover, value: isHovering.wrappedValue)
    }

    /// Popover / menu content entrance: scale 0.98 -> 1 with a fade, from the anchor edge.
    /// Reduce Motion collapses it to an instant appearance (Motion.popover does that).
    func kPopoverEntrance(anchor: UnitPoint = .top) -> some View {
        modifier(KPopoverEntrance(anchor: anchor))
    }
}

private struct KFocusRingModifier: ViewModifier {
    let isFocused: Bool
    let radius: CGFloat
    let lineWidth: CGFloat
    @Environment(\.kAccent) private var accent

    func body(content: Content) -> some View {
        content
            .padding(1)
            .overlay(
                RoundedRectangle(cornerRadius: radius + 1, style: .continuous)
                    // White accent resolves to Tok.focusRing's own alpha (translucent, since
                    // it sits on the same tone as the text it may cross); a saturated accent
                    // is opaque data colour, not a translucent chrome tint.
                    .strokeBorder(accent == Tok.textPrimary ? Tok.focusRing : accent, lineWidth: lineWidth)
                    .opacity(isFocused ? 1 : 0)
            )
            .animation(Motion.curve(Motion.fast), value: isFocused)
    }
}

private struct KPopoverEntrance: ViewModifier {
    let anchor: UnitPoint
    @State private var isShown = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isShown ? 1 : 0.98, anchor: anchor)
            .opacity(isShown ? 1 : 0)
            .onAppear { withAnimation(Motion.popover) { isShown = true } }
    }
}

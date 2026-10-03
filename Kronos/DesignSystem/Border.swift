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

    /// The one keyboard-focus ring: a `KRing.width` hairline in the accent at `KRing.opacity`
    /// (full opacity under Increase Contrast), floating `KRing.gap` outside the element and
    /// hugging its shape (`radius` is the element's own). Drawn as an outset overlay, so it
    /// never changes layout. Always visible on keyboard focus, never suppressed.
    func kFocusRing(_ isFocused: Bool, radius: CGFloat = Radius.control, circular: Bool = false) -> some View {
        modifier(KFocusRingModifier(isFocused: isFocused, radius: radius, circular: circular))
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

/// Colour logic shared by every accent outline that says "this is the one": the focus ring and
/// the drag nest outline. Numbers live in Tokens.swift (`Metrics.ring*`, `Tok.*Opacity`).
public enum KRing {
    /// White accent keeps `Tok.focusRing`'s own alpha (it sits on the tone of the text it may
    /// cross); a hue accent is faded to `opacity(for:)`. Increase Contrast: full opacity.
    public static func color(_ accent: Color, increasedContrast: Bool) -> Color {
        if accent == Tok.textPrimary { return increasedContrast ? .white : Tok.focusRing }
        let rgb = KColorMath.srgb(accent)
        // A custom colour too dark for the floor even when solid is lifted toward white instead.
        if KColorMath.contrastOnBlack(rgb) < Tok.ringContrastFloor {
            let lifted = KColorMath.lift(rgb, toContrast: Tok.ringContrastFloor)
            return Color(.sRGB, red: lifted.r, green: lifted.g, blue: lifted.b, opacity: 1)
        }
        return increasedContrast ? accent : accent.opacity(opacity(forSRGB: rgb))
    }

    /// The opacity a hue ring is drawn at: `Tok.ringAccentOpacity`, raised for a colour so dark
    /// that the faded line would fall under `Tok.ringContrastFloor` against black (a custom accent;
    /// every palette swatch already clears it at the base opacity). The faded line is the colour's
    /// sRGB components times the opacity over black, so the smallest passing opacity is found on
    /// that composite.
    public static func opacity(for accent: Color) -> Double {
        opacity(forSRGB: KColorMath.srgb(accent))
    }

    static func opacity(forSRGB rgb: (r: Double, g: Double, b: Double)) -> Double {
        let base = Tok.ringAccentOpacity
        if KColorMath.contrastOnBlack(scaled(rgb, by: base)) >= Tok.ringContrastFloor { return base }
        var alpha = base
        while alpha < 1 {
            alpha = min(1, alpha + 0.01)
            if KColorMath.contrastOnBlack(scaled(rgb, by: alpha)) >= Tok.ringContrastFloor { return alpha }
        }
        return 1
    }

    private static func scaled(_ c: (r: Double, g: Double, b: Double), by a: Double) -> (r: Double, g: Double, b: Double) {
        (c.r * a, c.g * a, c.b * a)
    }

    /// The faint wash that goes with the ring so the state reads at a glance.
    public static func tint(_ accent: Color, opacity: Double) -> Color {
        (accent == Tok.textPrimary ? Color.white : accent).opacity(opacity)
    }
}

private struct KFocusRingModifier: ViewModifier {
    let isFocused: Bool
    let radius: CGFloat
    let circular: Bool   // a round control: true circle (a continuous corner at full radius bulges)
    @Environment(\.kAccent) private var accent
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let reach = Metrics.ringGap + Metrics.ringWidth
        let style: RoundedCornerStyle = circular ? .circular : .continuous
        content
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: style)
                    .fill(KRing.tint(accent, opacity: Tok.focusTintOpacity))
                    .opacity(isFocused ? 1 : 0)
                    .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius + reach, style: style)
                    .strokeBorder(KRing.color(accent, increasedContrast: KContrast.isIncreased(contrast)), lineWidth: Metrics.ringWidth)
                    .padding(-reach)
                    .opacity(isFocused ? 1 : 0)
                    .allowsHitTesting(false)
            )
            .animation(Motion.curve(Motion.fast), value: isFocused)
    }
}

/// The drag "nest under this row" outline: the focus ring's width and colour plus a slightly
/// stronger wash, drawn on the row's own frame (solid, or dashed for a subtask target).
public struct KNestOutline: View {
    let radius: CGFloat
    let dashed: Bool
    var color: Color?
    @Environment(\.kAccent) private var accent
    @Environment(\.colorSchemeContrast) private var contrast

    public init(radius: CGFloat = Radius.row, dashed: Bool, color: Color? = nil) {
        self.radius = radius
        self.dashed = dashed
        self.color = color
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape
            .fill(color == nil ? KRing.tint(accent, opacity: Tok.nestTintOpacity) : Color.clear)
            .overlay(shape.strokeBorder(color ?? KRing.color(accent, increasedContrast: KContrast.isIncreased(contrast)),
                                        style: StrokeStyle(lineWidth: Metrics.ringWidth, dash: dashed ? [Space.x1, Space.x1] : [])))
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

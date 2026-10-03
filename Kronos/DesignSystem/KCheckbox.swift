// Kronos/DesignSystem/KCheckbox.swift
// Task-style circular checkbox, style G: QUIET at rest. A 1.25 pt ring at the tertiary
// tone, which steps up to secondary when its row is hovered (`\.kRowHovered`, set by
// KListRow) and to primary under the pointer itself. Done = filled in the accent (white by
// default and always white in Focus mode) with a check in the label colour that reads on it.
// Completing is the one rewarded moment: the check draws in (trimmed path, `Motion.complete`)
// and a 1 pt accent ring ripples out once (`Motion.completeRipple`). Under Reduce Motion the
// check appears at once and the ripple is skipped.
// Usage: KCheckbox(isChecked: task.isDone) { toggle() }
import SwiftUI

private struct KRowHoveredKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    /// True while the enclosing row is hovered, so a row's controls can wake up together.
    var kRowHovered: Bool {
        get { self[KRowHoveredKey.self] }
        set { self[KRowHoveredKey.self] = newValue }
    }
}

public struct KCheckbox: View {
    let isChecked: Bool
    var size: CGFloat
    let onToggle: () -> Void
    @State private var isHovering = false
    @State private var checkTrim: CGFloat = 0
    /// 0 = ripple at rest (invisible), 1 = fully grown and faded out.
    @State private var rippleProgress: CGFloat = 0
    @State private var isRippling = false
    /// Which completion the running ripple belongs to, so an older ripple's end never cuts a newer one.
    @State private var rippleGeneration = 0
    @FocusState private var isFocused: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.kRowHovered) private var isRowHovered
    @Environment(\.kAccent) private var accent

    /// What VoiceOver says for this checkbox; nil keeps the generic "Status". A call site that
    /// has the row's title should pass it, since a list of N unnamed "Status" boxes is useless.
    var label: String?

    public init(isChecked: Bool, size: CGFloat = Metrics.statusCircle, label: String? = nil,
                onToggle: @escaping () -> Void) {
        self.isChecked = isChecked
        self.size = size
        self.label = label
        self.onToggle = onToggle
    }

    private var ringTone: Color {
        if isChecked { return .clear }
        if isHovering { return Tok.textPrimary }
        return isRowHovered ? Tok.textSecondary : Tok.textTertiary
    }

    private var checkStroke: StrokeStyle {
        StrokeStyle(lineWidth: max(1.5, size * 0.11), lineCap: .round, lineJoin: .round)
    }

    public var body: some View {
        Button(action: onToggle) {
            ZStack {
                Circle()
                    .fill(isChecked ? accent : (isHovering ? Tok.hoverFill : Color.clear))
                Circle()
                    .strokeBorder(ringTone, lineWidth: Metrics.strokeQuiet)
                if isChecked {
                    CheckMark()
                        .trim(from: 0, to: checkTrim)
                        .stroke(Accent.onFill(accent), style: checkStroke)
                        .frame(width: size * 0.5, height: size * 0.5)
                } else if isHovering {
                    CheckMark()
                        .stroke(Tok.textDisabled, style: checkStroke)
                        .frame(width: size * 0.5, height: size * 0.5)
                }
            }
            .frame(width: size, height: size)
            // The completion ripple: drawn over the circle, never hit-testable, never in layout.
            .overlay(
                Circle()
                    .stroke(accent, lineWidth: Metrics.ringWidth)
                    .scaleEffect(1 + (Motion.completeRippleScale - 1) * rippleProgress)
                    .opacity(isRippling ? Motion.completeRippleOpacity * (1 - rippleProgress) : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            )
            // The hit area belongs INSIDE the label: a .plain Button is only pressable on its
            // opaque pixels, and a contentShape outside it just makes a dead wrapper (missed
            // clicks 2-3x before this fix). Unchecked, the circle is a stroke around a
            // transparent middle, so the middle missed.
            .frame(minWidth: Metrics.minHit, minHeight: Metrics.minHit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .kFocusRing(isFocused, radius: max(size, Metrics.minHit) / 2, circular: true)
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { isHovering = $0 }
        .focusable(isEnabled, interactions: .activate)
        .focused($isFocused)
        .focusEffectDisabled()
        .onAppear { checkTrim = isChecked ? 1 : 0 }
        .onChange(of: isChecked) { _, newValue in
            if newValue {
                checkTrim = 0
                withAnimation(Motion.complete) { checkTrim = 1 }
                startRipple()
            } else {
                checkTrim = 0
                isRippling = false
            }
        }
        .animation(Motion.hover, value: isHovering)
        .animation(Motion.hover, value: isRowHovered)
        .animation(Motion.complete, value: isChecked)
        // One explicit element: inside a focusable / gesture-bearing ancestor (the inspector's
        // sub-step row) the live VoiceOver pass found no element for this control, so it
        // declares itself rather than relying on the Button's inferred node.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label ?? String(localized: "viewoptions.field.status"))
        .accessibilityValue(String(localized: isChecked ? "status.done" : "status.todo"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if isEnabled { onToggle() } }
    }

    /// One ripple per completion; a second completion restarts it. Nothing runs under Reduce Motion.
    private func startRipple() {
        guard Motion.ripples(reduceMotion: Motion.reduceMotion) else { return }
        rippleGeneration += 1
        let generation = rippleGeneration
        rippleProgress = 0
        isRippling = true
        withAnimation(Motion.ripple) { rippleProgress = 1 } completion: {
            guard generation == rippleGeneration else { return }
            isRippling = false
            rippleProgress = 0
        }
    }
}

/// A simple checkmark path (two strokes) so it can be trimmed for a draw-in animation —
/// SF Symbols' "checkmark" glyph cannot be trimmed since it isn't exposed as a Shape.
struct CheckMark: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.04))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY - rect.height * 0.08))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.08))
        return p
    }
}

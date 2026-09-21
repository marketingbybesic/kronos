// Kronos/DesignSystem/KCheckbox.swift
// Task-style circular checkbox, style G: QUIET at rest. A 1.25 pt ring at the tertiary
// tone, which steps up to secondary when its row is hovered (`\.kRowHovered`, set by
// KListRow) and to primary under the pointer itself; filled white with a black check only
// when done. Monochrome (no green "done"). The check draws in via a trimmed path rather
// than a scale pop, Reduce-Motion aware.
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
    @FocusState private var isFocused: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.kRowHovered) private var isRowHovered

    public init(isChecked: Bool, size: CGFloat = Metrics.statusCircle, onToggle: @escaping () -> Void) {
        self.isChecked = isChecked
        self.size = size
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
                    .fill(isChecked ? Tok.textPrimary : (isHovering ? Tok.hoverFill : Color.clear))
                Circle()
                    .strokeBorder(ringTone, lineWidth: Metrics.strokeQuiet)
                if isChecked {
                    CheckMark()
                        .trim(from: 0, to: checkTrim)
                        .stroke(Tok.textOnAccent, style: checkStroke)
                        .frame(width: size * 0.5, height: size * 0.5)
                } else if isHovering {
                    CheckMark()
                        .stroke(Tok.textDisabled, style: checkStroke)
                        .frame(width: size * 0.5, height: size * 0.5)
                }
            }
            .frame(width: size, height: size)
            // The hit area belongs INSIDE the label: a .plain Button is only pressable on its
            // opaque pixels, and a contentShape outside it just makes a dead wrapper (missed
            // clicks 2-3x before this fix). Unchecked, the circle is a stroke around a
            // transparent middle, so the middle missed.
            .frame(minWidth: Metrics.minHit, minHeight: Metrics.minHit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .kFocusRing(isFocused, radius: size / 2 + 3)
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
            } else {
                checkTrim = 0
            }
        }
        .animation(Motion.hover, value: isHovering)
        .animation(Motion.hover, value: isRowHovered)
        .animation(Motion.complete, value: isChecked)
        .accessibilityLabel(String(localized: "viewoptions.field.status"))
        .accessibilityValue(String(localized: isChecked ? "status.done" : "status.todo"))
        .accessibilityAddTraits(.isButton)
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

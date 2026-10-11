// Kronos/DesignSystem/StatusCircle.swift
// Task-style circular status glyph, style G: QUIET at rest. Renamed from KCheckbox (spec
// §5.2, ux-12) — the old component drew exactly two visual states (hollow ring / filled
// check), so todo, inProgress, waiting and canceled were visually identical. This draws all
// five: todo = hollow ring, inProgress = ring + a filled pie wedge (0°→180° from 12 o'clock),
// waiting = DASHED hollow ring, done = filled + check (unchanged from before), canceled =
// hollow ring + a centred x. Click still only ever toggles todo ↔ done (D5, matches the Bar);
// no control in Kronos cycles through statuses on a plain click.
//
// The design system cannot import KronosCore (see AppearancePrefs.swift's note on
// `resolvedColor`), so this takes its own small `KTaskStatus` rather than KronosCore's
// `KStatus` — a call site that holds a real `KTask` maps `task.status` to it (collapsing
// `.someday`, which the spec does not address, to `.todo`: the safe default, same glyph as an
// ordinary open task).
//
// Colour: Tokens.swift is deliberately FULLY MONOCHROME chrome (no amber/green hue anywhere
// in app chrome — see its header comment); the spec's "amber"/"green" wording is read here as
// "the one accent channel the app already uses for emphasis" (`\.kAccent`, white by default),
// the same hue `done` already filled with before this change. inProgress's wedge and ring use
// that same accent, never a new hardcoded hue — states are told apart by STROKE STYLE (dashed
// vs solid), FILL AREA (wedge vs none) and GLYPH (check vs x), not colour alone, so the
// distinction also survives Increase Contrast / colour-blind users (1.4.1).
//
// ⌥-click, right-click, or (per call site) a keyboard shortcut opens the 5-option status
// popover via `onOpenPopover`; a call site that passes none (a subtask row, a plain
// preference checkbox) only ever gets the two-state click behaviour, same as before.
// Completing is the one rewarded moment: the check draws in (trimmed path, `Motion.complete`)
// and a 1 pt accent ring ripples out once (`Motion.completeRipple`) — both gated on
// `Motion.completionAnimationActive` (the Settings > General "Completion
// animation" pref ANDed with Reduce Motion in one place). Off, for either reason, the check
// appears at once and the ripple is skipped.
// Usage: StatusCircle(isChecked: task.isDone) { toggle() }                        // 2-state
//        StatusCircle(status: .inProgress, onToggle: { }, onOpenPopover: { })     // 5-state
import SwiftUI
import AppKit

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

/// A task's status, independent of KronosCore's `KStatus` (the design system cannot import
/// KronosCore). A caller holding a real `KTask` maps `task.status` to this, collapsing
/// `.someday` to `.todo`.
public enum KTaskStatus: Equatable, Sendable {
    case todo, inProgress, waiting, done, canceled
}

public struct StatusCircle: View {
    let status: KTaskStatus
    var size: CGFloat
    let onToggle: () -> Void
    /// ⌥-click or right-click → open the 5-option status popover. nil (the default two-state
    /// initialiser) means that gesture does nothing.
    var onOpenPopover: (() -> Void)?
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

    /// What VoiceOver says for this glyph; nil keeps the generic "Status". A call site that
    /// has the row's title should pass it, since a list of N unnamed "Status" glyphs is useless.
    var label: String?

    /// Two-state usage (a subtask's `isDone`, a plain preference checkbox): renders as
    /// `.todo`/`.done` only, no popover gesture.
    public init(isChecked: Bool, size: CGFloat = Metrics.statusCircle, label: String? = nil,
                onToggle: @escaping () -> Void) {
        self.status = isChecked ? .done : .todo
        self.size = size
        self.label = label
        self.onToggle = onToggle
        self.onOpenPopover = nil
    }

    /// Full five-state usage (a real task row).
    public init(status: KTaskStatus, size: CGFloat = Metrics.statusCircle, label: String? = nil,
                onToggle: @escaping () -> Void, onOpenPopover: (() -> Void)? = nil) {
        self.status = status
        self.size = size
        self.label = label
        self.onToggle = onToggle
        self.onOpenPopover = onOpenPopover
    }

    private var isChecked: Bool { status == .done }

    /// The neutral ring tone (todo / waiting / canceled). `inProgress` keeps its own accent
    /// ring regardless of hover — it is already the "loud" state; `done`'s ring is never drawn.
    private var ringTone: Color {
        if status == .done { return .clear }
        if isHovering { return Tok.textPrimary }
        return isRowHovered ? Tok.textSecondary : Tok.textTertiary
    }

    private var ringStyle: StrokeStyle {
        status == .waiting
            ? StrokeStyle(lineWidth: Metrics.strokeQuiet, dash: [2, 2])
            : StrokeStyle(lineWidth: Metrics.strokeQuiet)
    }

    private var checkStroke: StrokeStyle {
        StrokeStyle(lineWidth: max(1.5, size * 0.11), lineCap: .round, lineJoin: .round)
    }

    private var accessibilityStatusValue: String {
        switch status {
        case .todo: return String(localized: "status.todo")
        case .inProgress: return String(localized: "status.inprogress")
        case .waiting: return String(localized: "status.waiting")
        case .done: return String(localized: "status.done")
        case .canceled: return String(localized: "status.canceled")
        }
    }

    public var body: some View {
        Button(action: handlePrimaryAction) {
            ZStack {
                Circle()
                    .fill(status == .done ? accent : (isHovering ? Tok.hoverFill : Color.clear))
                if status == .inProgress {
                    PieWedge(start: .degrees(0), end: .degrees(180))
                        .fill(accent)
                        .padding(3)
                }
                Circle().strokeBorder(status == .inProgress ? accent : ringTone, style: ringStyle)
                if status == .done {
                    CheckMark()
                        .trim(from: 0, to: checkTrim)
                        .stroke(Accent.onFill(accent), style: checkStroke)
                        .frame(width: size * 0.5, height: size * 0.5)
                } else if status == .canceled {
                    XMarkGlyph()
                        .stroke(ringTone, style: checkStroke)
                        .frame(width: size * 0.5, height: size * 0.5)
                } else if isHovering && status == .todo {
                    CheckMark()
                        .stroke(Tok.todoCheckPreview, style: checkStroke)
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
        // Right-click opens the popover without ever stealing a left click: the catcher's
        // hitTest only answers for a `.rightMouseDown`, so it is invisible to every other event.
        .overlay {
            if onOpenPopover != nil {
                RightClickCatcher { onOpenPopover?() }
            }
        }
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
                if Motion.completionAnimationActive {
                    withAnimation(Motion.complete) { checkTrim = 1 }
                    startRipple()
                } else {
                    checkTrim = 1
                }
            } else {
                checkTrim = 0
                isRippling = false
            }
        }
        .animation(Motion.hover, value: isHovering)
        .animation(Motion.hover, value: isRowHovered)
        .animation(Motion.completionAnimationActive ? Motion.complete : nil, value: isChecked)
        // One explicit element: inside a focusable / gesture-bearing ancestor (the inspector's
        // sub-step row) the live VoiceOver pass found no element for this control, so it
        // declares itself rather than relying on the Button's inferred node.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label ?? String(localized: "viewoptions.field.status"))
        .accessibilityValue(accessibilityStatusValue)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if isEnabled { onToggle() } }
        .accessibilityActions {
            if let onOpenPopover, isEnabled {
                Button(String(localized: "viewoptions.field.status")) { onOpenPopover() }
            }
        }
    }

    /// Plain click toggles todo ↔ done (D5); ⌥-click opens the status popover instead, same
    /// destination as a right-click (`RightClickCatcher`) or a call site's own hotkey.
    private func handlePrimaryAction() {
        if onOpenPopover != nil, NSEvent.modifierFlags.contains(.option) {
            onOpenPopover?()
        } else {
            onToggle()
        }
    }

    /// One ripple per completion; a second completion restarts it. Only called from the
    /// `onChange` above when `Motion.completionAnimationActive` is true, so nothing
    /// runs under Reduce Motion or with the pref off — no separate guard here.
    private func startRipple() {
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

/// The `canceled` glyph: a plain x, built as a Shape (not an SF Symbol) so it strokes with the
/// same `StrokeStyle` and colour as the ring around it.
struct XMarkGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        return p
    }
}

/// A pie wedge from `start` to `end` (0° = 12 o'clock, clockwise), filled to the centre — the
/// `inProgress` glyph. Built from line segments rather than `Path.addArc`: SwiftUI's addArc
/// angle convention is easy to get backwards in a flipped-y coordinate space, and a
/// 32-segment polygon is visually indistinguishable from a true arc at icon scale (≤ 16 pt).
struct PieWedge: Shape {
    let start: Angle
    let end: Angle

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let steps = 32
        func point(_ t: Double) -> CGPoint {
            let a = start.radians + (end.radians - start.radians) * t
            return CGPoint(x: center.x + radius * sin(a), y: center.y - radius * cos(a))
        }
        var p = Path()
        p.move(to: center)
        for i in 0...steps { p.addLine(to: point(Double(i) / Double(steps))) }
        p.closeSubpath()
        return p
    }
}

/// Catches a right-click (and nothing else) over the view beneath it, so `StatusCircle` can
/// offer right-click → status popover without swallowing the left click its Button needs.
/// `hitTest` only claims the point while the event actually being dispatched is a
/// `.rightMouseDown` (`NSApp.currentEvent`, read during AppKit's hit-test pass) — every other
/// event (hover, left click, drag) answers `nil` and falls straight through to the Button.
private final class RightClickCatcherView: NSView {
    var onRightClick: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard NSApp.currentEvent?.type == .rightMouseDown else { return nil }
        return super.hitTest(point)
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }
}

private struct RightClickCatcher: NSViewRepresentable {
    let onRightClick: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = RightClickCatcherView()
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? RightClickCatcherView)?.onRightClick = onRightClick
    }
}

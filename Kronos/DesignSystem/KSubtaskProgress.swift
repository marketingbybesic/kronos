// Kronos/DesignSystem/KSubtaskProgress.swift
// Subtask completion (spec §5.4) — replaces the flat `KBadge("2/5")` text pill with the
// spec'd ring/bar: `.textAndArc` (row use) draws a 12 pt progress ring beside the count,
// `.bar` (inspector use) draws a 4 pt full-width bar above-right of the count. Colour: this
// file never introduces a new hue — Tokens.swift is deliberately monochrome chrome (see its
// header comment) — the spec's "→ green at 100%" is read as "the one accent channel the app
// already uses for emphasis" (`\.kAccent`), the same one `StatusCircle`'s `done` state fills
// with.
// Usage: KSubtaskProgress(done: 2, total: 5)                    // row ring
//        KSubtaskProgress(done: 2, total: 5, style: .bar)        // inspector bar
import SwiftUI

public struct KSubtaskProgress: View {
    public enum Style { case textAndArc, bar }

    let done: Int
    let total: Int
    var style: Style
    @Environment(\.kAccent) private var accent

    public init(done: Int, total: Int, style: Style = .textAndArc) {
        self.done = done
        self.total = total
        self.style = style
    }

    private var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
    private var isComplete: Bool { total > 0 && done >= total }
    private var countText: String {
        String(format: String(localized: "list.subtask.progress.n_of_m"), done, total)
    }

    public var body: some View {
        // `total == 0` renders nothing (the view is simply absent, not a zero) — a task with
        // no subtasks never shows this slot at all.
        if total > 0 {
            switch style {
            case .textAndArc: textAndArc
            case .bar: bar
            }
        }
    }

    /// Row style: a 12 pt ring (track `hairline`, progress arc `textTertiary` → accent at
    /// 100%, starting 12 o'clock clockwise — the same trim-draw technique `CheckMark` uses),
    /// then the count 4 pt to its right. Total width ≈ 34, matching `SlotWidth.subtasks`.
    private var textAndArc: some View {
        HStack(spacing: Space.x1) {
            ZStack {
                Circle().stroke(Tok.hairline, lineWidth: 1.5)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(isComplete ? accent : Tok.textTertiary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 12, height: 12)
            Text(countText)
                .font(Typo.meta)
                .foregroundStyle(Tok.textTertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(countText)
    }

    /// Inspector style: the count above-right, then a 4 pt-tall full-width bar (track
    /// `hairline`, fill the accent) below it.
    private var bar: some View {
        VStack(alignment: .trailing, spacing: Space.x1) {
            Text(countText)
                .font(Typo.meta)
                .foregroundStyle(Tok.textTertiary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Tok.hairline)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(accent)
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 4)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(countText)
    }
}

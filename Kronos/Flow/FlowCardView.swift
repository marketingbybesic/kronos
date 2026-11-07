// Kronos/Flow/FlowCardView.swift
// One Flow card: checkbox, title (KListRow-styled), the project's hue dot, the C1-style agent
// status glyph (FlowRuns.swift), the subtask count and the due day — a fixed-width card so a
// column's cards align, the same reasoning `SlotWidth`/`ColumnMode` give for the list's own
// trailing slots (ListRowView.swift).
import SwiftUI
import KronosCore

struct FlowCardView: View {
    @Bindable var model: AppModel
    let task: KTask
    let isFocused: Bool
    let isDimmed: Bool
    /// Plan F's "Milestones" rule, rendered on Flow's own cards (F's own header strip renders
    /// it separately): >= 2 open direct dependents. Computed once by the caller from
    /// `FlowLayout.Result.edges` (an edge's `from` is always an open task, by construction —
    /// see FlowLayout.swift's own rule 6 — so counting `from == task.id` IS the open-dependent
    /// count), not recomputed per card.
    let isGate: Bool
    let runStore: RunStore?
    let onSelect: () -> Void

    @State private var isPulsing = false

    private var today: Int { Day.today() }
    private var agentState: FlowAgentState { FlowAgentState.of(task, runStore: runStore) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x1) {
            titleRow
            metaRow
        }
        .padding(Space.x2)
        .frame(width: Metrics.flowCardWidth, alignment: .leading)
        .background(cardFill)
        .overlay(cardEdge)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .opacity(isDimmed ? 0.5 : 1)
        .animation(Motion.curve(Motion.fast), value: isDimmed)
        .animation(Motion.curve(Motion.fast), value: isFocused)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityAddTraits(.isButton)
        .uiTestAnchor("flow.card." + task.title)
    }

    private var titleRow: some View {
        HStack(spacing: Space.x1) {
            StatusCircle(status: KTaskStatus(task.status), size: Metrics.listCheckboxSize,
                         onToggle: { ListCompletion.toggle(task, store: model.store, model: model) })
            KProjectGlyph(icon: nil, colorHex: task.project?.colorHex, size: Metrics.projectDot, dotSize: Metrics.projectDot)
            Text(task.title)
                .font(Typo.row)
                .foregroundStyle(Tok.textPrimary)
                .lineLimit(2)
                .opacity(task.status == .done ? 0.6 : 1)
            Spacer(minLength: 0)
            gateGlyph
            statusGlyph
        }
    }

    @ViewBuilder private var gateGlyph: some View {
        if isGate {
            Icon("flag", size: Metrics.iconXS, weight: .medium)
                .foregroundStyle(Tok.textTertiary)
                .help(String(localized: "flow.gate.title"))
                .accessibilityHidden(true)   // folded into the card's own accessibilityLabel
        }
    }

    @ViewBuilder private var statusGlyph: some View {
        if let icon = agentState.iconName {
            Icon(icon, size: Metrics.iconXS, weight: .medium)
                .foregroundStyle(Tok.textTertiary)
                .opacity(agentState.isRunning && !Motion.reduceMotion ? (isPulsing ? 1.0 : 0.4) : 1.0)
                .help(agentState.statusText ?? "")
                .accessibilityHidden(true)   // folded into the card's own accessibilityLabel
                .onAppear {
                    guard agentState.isRunning, !Motion.reduceMotion else { return }
                    withAnimation(.easeInOut(duration: Motion.breathLoop).repeatForever(autoreverses: true)) {
                        isPulsing = true
                    }
                }
        }
    }

    private var metaRow: some View {
        HStack(spacing: Space.x2) {
            let progress = task.subtaskProgress
            if progress.total > 0 {
                KSubtaskProgress(done: progress.done, total: progress.total)
            }
            Spacer(minLength: 0)
            dueView
        }
    }

    @ViewBuilder private var dueView: some View {
        if let due = task.effectiveDue {
            let shown = ListDueText.shown(due: due, original: task.originalDueDay, today: today)
            if shown.muted {
                Text(shown.text)
                    .font(Typo.count)
                    .foregroundStyle(Tok.textTertiary)
                    .opacity(task.status == .done ? 0.6 : 1)
            } else {
                KDeadlineLabel(text: shown.text, carryDays: 0, isDone: task.status == .done)
            }
        }
    }

    private var cardFill: some View {
        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .fill(isFocused ? Tok.selectedFill : Tok.surface)
    }

    private var cardEdge: some View {
        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .strokeBorder(isFocused ? Tok.borderActive : Tok.hairline, lineWidth: isFocused ? 1 : Metrics.hairline)
    }

    /// "<title>, <project>, <state>, due <date>, N of M subtasks" — one accessibility element,
    /// same shape as `RowAccessibility.label` builds for a list row.
    private var accessibilityLabel: String {
        var due: String?
        if let effective = task.effectiveDue {
            let shownDay = ListDueKind.shownDay(due: effective, original: task.originalDueDay, today: today)
            due = String(format: String(localized: "a11y.row.due.value"), ViewOptionsMapper.mediumDate(shownDay))
        }
        var label = RowAccessibility.label(title: task.title, project: task.project?.name, due: due,
                                           state: ViewOptionsMapper.statusName(task.status))
        if let status = agentState.statusText { label += ", " + status }
        if isGate { label += ", " + String(localized: "flow.gate.title") }
        return label
    }
}

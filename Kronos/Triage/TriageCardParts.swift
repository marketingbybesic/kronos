// Kronos/Triage/TriageCardParts.swift. Split out of TriageFlowView.swift (500-line lint gate).
// What the card shows: the sort card (title, first move, one-phrase reason, the four field rows,
// the "also fills" line, the key legend), the sweep card, and the end-of-sitting / empty panels.
// The card has ONE frame (the flow's own background + hairline); nothing here draws another.
import SwiftUI
import KronosCore

extension TriageFlowView {

    // MARK: Sort card

    func card(for task: KTask) -> some View {
        let writes = plannedWrites(for: task)
        return VStack(alignment: .leading, spacing: Space.x5) {
            titleBlock(task)
            firstMoveBlock(for: task, writes: writes)
            reasonLine
            // The AI state gets its own trailing row: sharing the reason's line squeezed the
            // HR text down to "i…" / "AI nije odg…" on the 470 pt card.
            if aiEnabled, model.ai != nil { HStack { Spacer(minLength: 0); aiStateRow } }

            VStack(spacing: 0) {
                KPropertyRow(String(localized: "viewoptions.field.priority")) { priorityMenu(for: task) }
                KHairline()
                KPropertyRow(String(localized: "viewoptions.field.effort")) { effortMenu(for: task) }
                KHairline()
                KPropertyRow(String(localized: "viewoptions.field.deadline")) { deadlineRow(for: task) }
                KHairline()
                KPropertyRow(String(localized: "viewoptions.field.project")) { projectMenu(for: task) }
            }

            alsoFillsLine(writes)
            keyHints
        }
        // Hugs its content. A fresh identity per card so hover/menu state resets.
        .id(task.id)
    }

    private func titleBlock(_ task: KTask) -> some View {
        VStack(alignment: .leading, spacing: Space.x1) {
            Text(task.title)
                .font(Typo.hero)
                .foregroundStyle(Tok.textPrimary)
                .lineLimit(3)
            if let projectName = task.project?.name {
                Text(projectName)
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
            }
            // T (plan for today) writes the planned day, not the deadline: show that it was planned.
            if let planned = task.plannedDay, planned >= Day.today(calendar: KronosLocale.calendar) {
                Text(String(format: String(localized: "triage.card.planned"),
                            deadlineText(day: planned, today: Day.today(calendar: KronosLocale.calendar))))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                    .uiTestAnchor("triage.card.planned")
            }
        }
    }

    // MARK: First move — the one field that lowers the cost of starting; editable in place.

    func firstMoveBlock(for task: KTask, writes: Set<TriageFieldKind>) -> some View {
        let shown = task.firstMove ?? (writes.contains(.firstMove) ? suggestion.flatMap { TriagePlan.suggestedFirstMove($0, for: task) } : nil)
        return VStack(alignment: .leading, spacing: Space.x1) {
            Text(String(localized: "detail.firstmove"))
                .font(Typo.meta)
                .foregroundStyle(Tok.textTertiary)
            if isEditingMove {
                KTextField(String(localized: "detail.firstmove.placeholder"), text: $moveText)
                    .focused($isMoveFieldFocused)
                    .onSubmit { commitMove(for: task) }
                    .uiTestAnchor("triage.card.firstmove.field")
            } else {
                Button { openMoveField() } label: {
                    Text(shown ?? String(localized: "detail.firstmove.placeholder"))
                        .font(Typo.body)
                        .foregroundStyle(shown == nil ? Tok.textTertiary : Tok.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, minHeight: Metrics.minHit, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "detail.firstmove"))
                .accessibilityValue(shown ?? "")
                .uiTestAnchor("triage.card.firstmove")
            }
        }
    }

    // MARK: Reason — one phrase

    @ViewBuilder
    var reasonLine: some View {
        if let reason = suggestion?.reason {
            Text(reasonPhrase(reason))
                .font(Typo.meta)
                .foregroundStyle(Tok.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .uiTestAnchor("triage.card.reason")
        }
    }

    /// The neighbour reason already reads as a whole ("Like 3 similar Acme tasks"); an AI reason
    /// is the model's own sentence, led by who said it.
    func reasonPhrase(_ reason: String) -> String {
        let base = localizedNeighbourReason(reason, isNeighbourSourced: suggestionSource != .ai)
        return suggestionSource == .ai ? String(format: String(localized: "triage.reason.ai"), base) : base
    }

    // MARK: "Also fills" — what Return writes that is not a row above.

    @ViewBuilder
    func alsoFillsLine(_ writes: Set<TriageFieldKind>) -> some View {
        let listed = TriagePlan.alsoFills(writes)
        if let suggestion, !listed.isEmpty {
            Text(String(format: String(localized: "triage.alsofills"),
                        listed.compactMap { alsoFillsText($0, suggestion) }.joined(separator: " · ")))
                .font(Typo.meta)
                .foregroundStyle(Tok.textTertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .uiTestAnchor("triage.card.alsofills")
        }
    }

    private func alsoFillsText(_ field: TriageFieldKind, _ result: TriageResult) -> String? {
        switch field {
        case .depth: return result.depth == .deep ? String(localized: "depth.deep") : String(localized: "depth.shallow")
        case .estimateMinutes: return String(format: String(localized: "ctx.field.estimate.min"), result.estimateMinutes)
        case .energyKind:
            switch result.energyKind {
            case .deepWork: return String(localized: "energykind.deepwork")
            case .admin: return String(localized: "energykind.admin")
            case .creative: return String(localized: "energykind.creative")
            case .people: return String(localized: "energykind.people")
            case .physical: return String(localized: "energykind.physical")
            }
        default: return nil
        }
    }

    // MARK: Key legend — accept/skip by default; field keys reveal on hover or while ⌥ is held.

    var keyHints: some View {
        TriageKeyLegend(fieldHints: fieldHints, planHints: planHints, flowHints: flowHints, startRevealed: startLegendOpen)
    }

    /// The caps come from the grammar and the live registry bindings, so a rebound key shows.
    private func caps(_ action: TriageKeyAction) -> [String] {
        TriageKeyGrammar.caps(for: action, bindings: { HotkeyRegistry.current(for: $0) })
    }

    private var fieldHints: [(keys: [String], label: String)] {
        var items: [(keys: [String], label: String)] = [
            (caps(.priority(0)), String(localized: "viewoptions.field.priority")),
            (caps(.effort(.small)) + caps(.effort(.medium)) + caps(.effort(.large)), String(localized: "viewoptions.field.effort")),
            (caps(.pickDue), String(localized: "triage.flow.date.typeit")),
            (caps(.pickProject), String(localized: "viewoptions.field.project")),
            (caps(.editFirstMove), String(localized: "detail.firstmove")),
        ]
        if aiEnabled, model.ai != nil {
            // With no AI set up, R opens Settings on the AI tab (asking again could only fail).
            let refreshLabel = aiFailure == .noKey ? String(localized: "triage.flow.ai.setup.open") : String(localized: "triage.flow.ai.refresh")
            items.append((caps(.refresh), refreshLabel))
        }
        return items
    }

    /// The keys that plan, park or remove the task, in the list's order.
    private var planHints: [(keys: [String], label: String)] {
        [
            (caps(.planToday), String(localized: "sweep.action.today")),
            (caps(.planTomorrow), String(localized: "triage.key.tomorrow")),
            (caps(.snooze), String(localized: "hotkey.list.snooze")),
            (caps(.waiting), String(localized: "status.waiting")),
            (caps(.someday), String(localized: "sidebar.someday")),
            (caps(.breakDown), String(localized: "ctx.task.breakdown")),
            (caps(.focusPin), String(localized: "hotkey.list.focuspin")),
            (caps(.delete), String(localized: "common.delete")),
            (caps(.done), String(localized: "common.done")),
        ]
    }

    private var flowHints: [(keys: [String], label: String)] {
        [
            (["⏎"], String(localized: "triage.flow.hint.accept")),
            (["⇥"], String(localized: "triage.flow.hint.skip")),
            (["esc"], String(localized: "triage.flow.hint.close")),
        ]
    }

    // MARK: Sweep card

    func sweepCard(for task: KTask) -> some View {
        VStack(alignment: .leading, spacing: Space.x5) {
            titleBlock(task)
            Text(sweepAgeLine(task))
                .font(Typo.meta)
                .foregroundStyle(Tok.textSecondary)
                .uiTestAnchor("sweep.card.age")
            KFlowLayout(spacing: Space.x2, lineSpacing: Space.x2) {
                sweepButton(String(localized: "sweep.action.keep"), key: "⏎", anchor: "keep", action: .keep)
                sweepButton(String(localized: "sweep.action.today"), key: caps(.planToday).joined(), anchor: "today", action: .planToday)
                sweepButton(String(localized: "sidebar.someday"), key: caps(.someday).joined(), anchor: "someday", action: .someday)
                sweepButton(String(localized: "common.delete"), key: "⌫", anchor: "delete", action: .delete)
                sweepButton(String(localized: "common.done"), key: "Space", anchor: "done", action: .done)
            }
            KKeyHintRow([
                (["⇥"], String(localized: "triage.flow.hint.skip")),
                (["esc"], String(localized: "triage.flow.hint.close")),
            ])
        }
        .id(task.id)
    }

    private func sweepButton(_ label: String, key: String, anchor: String, action: SweepAction,
                             kind: KButtonStyle.Kind = .secondary) -> some View {
        Button { sweep(action) } label: {
            HStack(spacing: Space.x2) {
                Text(label)
                KKeyCap(key).accessibilityHidden(true)
            }
        }
        .kButton(kind, size: .compact)
        .fixedSize()
        .accessibilityLabel(label)
        .uiTestAnchor("sweep.action.\(anchor)")
    }

    /// "Someday · Untouched for 23 days": where it sits, then how long it has been quiet.
    func sweepAgeLine(_ task: KTask) -> String {
        let days = SweepQueue.idleDays(task, now: Date(), calendar: KronosLocale.calendar)
        let idle = KPlural.hr(days, one: String(localized: "sweep.age.one"),
                              few: String(localized: "sweep.age.few"), many: String(localized: "sweep.age.many"))
        switch task.status {
        case .someday: return String(localized: "sidebar.someday") + " · " + idle
        case .waiting: return String(localized: "status.waiting") + " · " + idle
        default: return idle
        }
    }

    // MARK: End of a sitting, and nothing to do

    var sessionPanel: some View {
        VStack(spacing: Space.x4) {
            KEmptyState(icon: isSweep ? "archive" : "check-square",
                        title: String(localized: "triage.session.done"),
                        message: String(format: String(localized: "triage.session.more"), queue.count),
                        actionTitle: String(localized: "triage.session.again"), onAction: continueSession)
                .frame(maxWidth: .infinity)
                .uiTestAnchor("triage.card.sessiondone")
            KKeyHintRow([
                (["⏎"], String(localized: "triage.session.again")),
                (["esc"], String(localized: "triage.flow.hint.close")),
            ])
        }
        .padding(.vertical, Space.x4)
    }

    var emptyPanel: some View {
        KEmptyState(icon: isSweep ? "archive" : (isReview ? "eye" : "check-square"),
                    title: String(localized: isSweep ? "sweep.empty" : (isReview ? "review.empty" : "triage.flow.empty")),
                    actionTitle: String(localized: "triage.flow.hint.close"), onAction: onClose)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.x6)
    }
}

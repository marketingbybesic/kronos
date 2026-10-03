// Kronos/List/TaskListScreen+Parts.swift
// Pure move, no behaviour change, out of TaskListScreen.swift to keep that file under the
// 500-line gate after the hotkey-registry additions pushed it over — the Now card is a
// self-contained unit (only reads `model`/`isNowCardCollapsed`), so it moves as an extension
// rather than shrinking anything else. `private` becomes internal (module-default) access
// since these are now called from `TaskListScreen`'s own file. Its complete button posts to
// the shell-level `UndoToastCenter` (see ListCompletion.swift), same as every other
// completion path, so the pill shows here too.
import SwiftUI
import KronosCore

extension TaskListScreen {
    // MARK: - Rebindable list keys

    /// Characters the list claims: the fixed priority keys and whatever every grammar action is
    /// bound to NOW (ListKeyGrammar.swift), both cases. A hardcoded set made a rebind silently dead.
    var listCharacterSet: CharacterSet {
        _ = hotkeyRevision
        return CharacterSet(charactersIn: ListKeyGrammar.claimedCharacters(bindings: Self.grammarBindings()))
    }

    // MARK: - Now card

    /// Waiting and Someday hold tasks that are by definition not next, and an empty Inbox has
    /// nothing to do now: the card would recommend the wrong thing (audit D2). Elsewhere the
    /// card's task also stays in the rows below on purpose: keyboard navigation and the Ordo
    /// publisher read those rows, and the card shows the first move while the row shows the title.
    func showsNowCard(_ ctx: ListContext) -> Bool {
        switch model.scope {
        case .waiting, .someday: return false
        case .inbox: return !ctx.rows.isEmpty
        default: return true
        }
    }

    func nowCard(_ task: KTask, _ ctx: ListContext) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Motion.curve(Motion.fast)) { isNowCardCollapsed.toggle() }
                UserDefaults.standard.set(isNowCardCollapsed, forKey: "kronos.nowcard.collapsed")
            } label: {
                HStack(spacing: Space.x1) {
                    Icon(isNowCardCollapsed ? "chevron-right" : "chevron-down", size: Metrics.iconXS)
                    Text(String(localized: "nowcard.now", defaultValue: "Now"))
                        .font(Typo.caption)
                        .tracking(Tracking.caption)
                        .textCase(.uppercase)
                }
                .foregroundStyle(Tok.textTertiary)
                .kHitTarget()
            }
            .buttonStyle(.plain)
            .padding(.bottom, isNowCardCollapsed ? 0 : Space.x2)
            if !isNowCardCollapsed {
                // Same sentence as the inspector and the menu bar (Detail/FirstMoveText.swift). No
                // breathing ring: urgency is carried by the sentence and the deadline, not by motion.
                let move = FirstMoveLogic.text(for: task)
                KNowCard(firstMove: move, title: task.title,
                         projectIcon: task.project?.icon, projectColorHex: task.project?.colorHex, projectName: task.project?.name,
                         attributes: { nowCardAttributes(task) },
                         onComplete: { ListCompletion.toggle(task, store: model.store, model: model) })
                    .extras(
                        leftOff: {
                            if let line = LeftOffLine.text(for: task, hero: move ?? task.title) { LeftOffLine(text: line) }
                        },
                        actions: { nowCardActions(task, ctx) })
                    .kContextLinkDrop(taskID: task.id, model: model)
                    // A Large task with no steps gets them silently, so step 1 is the first move.
                    .task(id: task.id) {
                        if ImpulsAutoBreakdown.runIfNeeded(task, store: model.store) { model.didMutate() }   // refresh-only: silent machine write, no pill by design
                    }
            }
        }
    }

    /// Start / Not now / Tomorrow for the focus task (the same row the menu-bar popover shows).
    @ViewBuilder
    func nowCardActions(_ task: KTask, _ ctx: ListContext) -> some View {
        let started = task.status == .inProgress && model.pinnedFocusTaskID == task.id
        FocusActionsRow(
            showsStart: !started,
            onStart: { FocusStart.begin(task, model: model, followFirstMove: true) },
            onNotNow: {
                let next = ctx.rows.first { $0.id != task.id && NextEligibility.isEligible($0, store: model.store) }
                FocusStart.notNow(task, nextRowID: next?.id, model: model)
            },
            onTomorrow: {
                model.store.snooze(task.id)
                if model.pinnedFocusTaskID == task.id { model.pinnedFocusTaskID = nil }
                model.commit(String(localized: "nowcard.undo.tomorrow"))
            })
    }

    @ViewBuilder
    func nowCardAttributes(_ task: KTask) -> some View {
        if task.effort != .none {  // empty dots on the hero card are noise
            KEffortIndicator(level: task.effort.rawValue, of: 5, label: ViewOptionsMapper.effortName(task.effort), showLabel: true)
        }
        if let due = task.dueDay {
            KDeadlineLabel(text: nowCardDeadlineText(due), carryDays: 0, isDone: task.status == .done)  // no guilt counter on THE task (audit F10); the inspector keeps it
        }
    }

    /// Same short-date convention as InspectorDeadlineControl: Today/Tomorrow spelled out,
    /// everything else the APP language's "d MMM" ("15 Sep" / "15. ruj") via KronosLocale —
    /// never a raw ISO string on screen.
    func nowCardDeadlineText(_ due: Int) -> String {
        let today = Day.today()
        if due == today { return String(localized: "deadline.quick.today") }
        if due == today + 1 { return String(localized: "deadline.quick.tomorrow") }
        return NowCardDayFormatter.shared.string(from: Day.date(due, calendar: KronosLocale.calendar))
    }
}

/// Extension members can't hold stored properties, so the cached formatter (built once, not
/// per call — the actual behaviour `private static let` had before this pure move) lives in
/// this tiny holder instead of `TaskListScreen` itself.
enum NowCardDayFormatter {
    static let shared: DateFormatter = {
        let f = DateFormatter()
        f.calendar = KronosLocale.calendar
        f.locale = KronosLocale.current
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f
    }()
}

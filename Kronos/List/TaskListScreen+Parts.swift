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
    // MARK: - Now card

    func nowCard(_ task: KTask, _ ctx: ListContext) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Motion.curve(Motion.fast)) { isNowCardCollapsed.toggle() }
            } label: {
                HStack(spacing: Space.x1) {
                    Icon(isNowCardCollapsed ? "chevron-right" : "chevron-down", size: Metrics.iconXS)
                    Text(String(localized: "nowcard.now", defaultValue: "Now"))
                        .font(Typo.caption)
                        .tracking(Tracking.caption)
                        .textCase(.uppercase)
                }
                .foregroundStyle(Tok.textTertiary)
            }
            .buttonStyle(.plain)
            .padding(.bottom, isNowCardCollapsed ? 0 : Space.x2)
            if !isNowCardCollapsed {
                KNowCard(firstMove: task.firstMove, title: task.title, remaining: model.ordoFocus.remaining,
                         projectIcon: task.project?.icon, projectColorHex: task.project?.colorHex, projectName: task.project?.name,
                         attributes: { nowCardAttributes(task) },
                         onComplete: { ListCompletion.toggle(task, store: model.store, model: model) })
                    .kContextLinkDrop(taskID: task.id, model: model)
            }
        }
    }

    @ViewBuilder
    func nowCardAttributes(_ task: KTask) -> some View {
        KEffortIndicator(level: task.effort.rawValue, of: 5, label: ViewOptionsMapper.effortName(task.effort), showLabel: task.effort != .none)
        if let due = task.dueDay {
            KDeadlineLabel(text: nowCardDeadlineText(due), carryDays: task.carryDays(today: Day.today()), isDone: task.status == .done)
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

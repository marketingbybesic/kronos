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

    /// The character a rebindable list action is bound to NOW (the printed cap, so it follows
    /// the keyboard layout like Settings shows it), lowercased; "" when unbound.
    static func listKey(_ id: String) -> String {
        HotkeyRegistry.current(for: id)?.displayKeys.last?.lowercased() ?? ""
    }

    /// Characters the list claims: the fixed priority digits (+ "o") and whatever the three
    /// rebindable actions are bound to. A hardcoded "h/f/e" set made a rebind silently dead.
    var listCharacterSet: CharacterSet {
        _ = hotkeyRevision
        let dynamic = ["list.snooze", "list.focuspin", "list.expandall"].map(Self.listKey).joined()
        return CharacterSet(charactersIn: "o01234" + dynamic + dynamic.uppercased())
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
            }
            .buttonStyle(.plain)
            .padding(.bottom, isNowCardCollapsed ? 0 : Space.x2)
            if !isNowCardCollapsed {
                // Rev18 5A: breathe when overdue or high-priority so the First Move reads as
                // urgent without colour. Reduce Motion is handled inside KNowCard itself.
                let isAttention = (task.priority == .high || task.priority == .urgent)
                    || (task.dueDay.map { $0 < Day.today() } ?? false)
                // Same sentence as the inspector and the menu bar (Detail/FirstMoveText.swift).
                KNowCard(firstMove: FirstMoveLogic.text(for: task), title: task.title,
                         projectIcon: task.project?.icon, projectColorHex: task.project?.colorHex, projectName: task.project?.name,
                         attention: isAttention,
                         attributes: { nowCardAttributes(task) },
                         onComplete: { ListCompletion.toggle(task, store: model.store, model: model) })
                    .kContextLinkDrop(taskID: task.id, model: model)
            }
        }
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

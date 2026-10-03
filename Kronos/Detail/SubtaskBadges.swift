// SubtaskBadges: how a child task's due day and priority read as compact marks on its rows
// (middle list and the inspector's steps list). The child's own details open in the normal
// inspector, in child mode (see InspectorRouting.swift).
import SwiftUI
import KronosCore

/// How a child's due day reads, shared by the compact badges on child rows.
enum SubtaskDisplay {
    static func dueText(_ day: Int) -> String {
        let today = Day.today()
        if day == today { return String(localized: "deadline.quick.today") }
        if day == today + 1 { return String(localized: "deadline.quick.tomorrow") }
        return dayFormatter.string(from: Day.date(day))
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = KronosLocale.calendar
        f.locale = KronosLocale.current
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f
    }()
}

/// Due day and priority of a child as two small marks, only for what is set: a plain row
/// stays as quiet as before.
struct SubtaskMetaBadges: View {
    let subtask: KTask

    var body: some View {
        HStack(spacing: Space.x2) {
            if let day = subtask.dueDay {
                Text(SubtaskDisplay.dueText(day))
                    .font(Typo.count)
                    .foregroundStyle(subtask.isDone ? Tok.textTertiary : Tok.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
                    .uiTestAnchor("subtask.badge.due")
            }
            if subtask.priority != .none {
                KPriorityIndicator(level: subtask.priority.rawValue, of: 4, label: subtask.priority.displayName, size: Metrics.iconS)
                    .uiTestAnchor("subtask.badge.priority")
            }
        }
    }
}

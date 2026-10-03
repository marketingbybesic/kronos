import Foundation
import SwiftData
@testable import KronosCore

/// Shared helpers for the subtask suites. Expectations in the suites are
/// written by hand; the only derived values here are store dumps that a test
/// compares with a dump of the SAME store taken before the operation.
@MainActor
enum SubtaskFixture {
    static func day(_ iso: String) -> Int { Day.parseISO(iso)! }
    static func iso(_ day: Int?) -> String? { day.map(Day.iso) }

    /// Every task, deleted ones and child tasks included,
    /// as sorted text lines carrying every field a move could disturb.
    static func dump(_ store: TaskStore) -> [String] {
        var lines: [String] = []
        for t in store.allTasksIncludingDeleted() {
            lines.append("T \(t.id) title=\(t.title) status=\(t.statusRaw) prio=\(t.priorityRaw) "
                + "due=\(String(describing: t.dueDay)) sort=\(t.sortIndex) ordo=\(String(describing: t.ordoIndex)) "
                + "notes=\(t.notes) waits=\(t.waitsOnIDs) proj=\(String(describing: t.projectID)) "
                + "labels=\((t.labels ?? []).map(\.name).sorted()) deleted=\(t.deletedAt != nil) "
                + "created=\(t.createdAt.timeIntervalSince1970) completed=\(String(describing: t.completedAt)) "
                + "parent=\(String(describing: t.parentID)) parentRel=\(String(describing: t.parent?.id)) "
                + "area=\(String(describing: t.areaID)) recur=\(String(describing: t.recurrenceRule))")
        }
        return lines.sorted()
    }

    /// Rows that are subtasks (deleted included). Schema V2 has no separate step rows.
    static func subtaskCount(_ store: TaskStore) -> Int {
        store.allTasksIncludingDeleted().filter { $0.parentID != nil }.count
    }
}

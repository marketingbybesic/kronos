import Testing
import Foundation
@testable import KronosCore

/// "Show completed": hand tables for the status rule and for which closed task belongs to which list.
/// Statuses by raw value: todo 0, in progress 1, waiting 2, someday 3, done 4, canceled 5.
@Suite("ListStatusPolicyTests")
struct ListStatusPolicyTests {

    @Test("effective statuses: the switch widens an open-set base, the owner's own statuses win, a single-status base stays")
    func effectiveStatusesTable() {
        let open = [0, 1, 2, 3]
        let inboxBase = [0, 1, 2]
        let table: [(base: [Int], user: [Int], showCompleted: Bool, expected: [Int])] = [
            (open, [], false, [0, 1, 2, 3]),
            (open, [], true, [0, 1, 2, 3, 4, 5]),
            (inboxBase, [], false, [0, 1, 2]),
            (inboxBase, [], true, [0, 1, 2, 4, 5]),
            (open, [4], false, [4]),
            (open, [0], true, [0]),
            ([2], [], false, [2]),
            ([2], [], true, [2]),         // Waiting: no closed task can be a member
            ([3], [], true, [3]),         // Someday
            ([], [], false, [0, 1, 2, 3]), // a container shows open work unless asked
            ([], [], true, []),            // ... and everything when asked ([] = any)
            ([], [4], false, [4]),
        ]
        for row in table {
            #expect(ListStatusPolicy.effectiveStatuses(base: row.base, user: row.user, showCompleted: row.showCompleted) == row.expected,
                    "base \(row.base) user \(row.user) show \(row.showCompleted)")
        }
    }

    @Test("closed tasks are members when the switch is on, or when a closed status is filtered on (not negated)")
    func includesClosedTable() {
        let table: [(show: Bool, user: [Int], negated: Bool, expected: Bool)] = [
            (false, [], false, false),
            (true, [], false, true),
            (false, [4], false, true),
            (false, [5], false, true),
            (false, [4], true, false),   // "status is not Done": closed tasks stay out
            (false, [0, 1], false, false),
            (true, [0], true, true),
        ]
        for row in table {
            #expect(ListStatusPolicy.includesClosed(showCompleted: row.show, userStatuses: row.user, statusesNegated: row.negated) == row.expected,
                    "show \(row.show) user \(row.user) negated \(row.negated)")
        }
    }

    @Test("which closed task belongs to which list (today = day 100)")
    func admitsClosedTable() {
        typealias Kind = ListStatusPolicy.ScopeKind
        let table: [(kind: Kind, completed: Int?, scheduled: Int?, expected: Bool)] = [
            (.all, 3, nil, true),
            (.all, nil, nil, true),
            (.inbox, 50, nil, true),
            (.container, nil, nil, true),
            (.today, 100, nil, true),       // completed today
            (.today, 99, 100, false),       // completed yesterday: history does not flood Today
            (.today, nil, 100, false),      // no completion time
            (.next7, 100, nil, true),       // completed today
            (.next7, 90, 105, true),        // scheduled inside the window
            (.next7, 90, 107, true),        // last day of the window (today + 7)
            (.next7, 90, 108, false),
            (.next7, 90, 99, false),
            (.next7, nil, nil, false),
            (.waiting, 100, 100, false),
            (.someday, 100, 100, false),
        ]
        for row in table {
            #expect(ListStatusPolicy.admitsClosed(row.kind, completedDay: row.completed, scheduleDay: row.scheduled, today: 100) == row.expected,
                    "\(row.kind) completed \(String(describing: row.completed)) scheduled \(String(describing: row.scheduled))")
        }
    }
}

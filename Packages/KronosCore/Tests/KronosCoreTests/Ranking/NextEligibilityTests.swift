import Testing
import Foundation
@testable import KronosCore

/// Which tasks may be "next". Every row of the tables is written by hand from the rule.
@MainActor
struct NextEligibilityTests {
    let today = Day.today()

    private func makeStore() throws -> TaskStore { try TaskStore(inMemory: true) }

    // MARK: single-task hand table

    private struct Row { let name: String; let make: (TaskStore) -> KTask; let want: NextEligibility.Exclusion? }

    private func rows() -> [Row] {
        [
            Row(name: "todo", make: { $0.create(title: "t") }, want: nil),
            Row(name: "in progress", make: { s in let t = s.create(title: "t"); s.setStatus(t.id, .inProgress); return t }, want: nil),
            Row(name: "waiting", make: { s in let t = s.create(title: "t"); s.setStatus(t.id, .waiting); return t }, want: nil),
            Row(name: "someday", make: { s in let t = s.create(title: "t"); s.setStatus(t.id, .someday); return t }, want: nil),
            Row(name: "done", make: { s in let t = s.create(title: "t"); s.complete(t.id); return t }, want: .closed),
            Row(name: "canceled", make: { s in let t = s.create(title: "t"); s.setStatus(t.id, .canceled); return t }, want: .closed),
            Row(name: "deleted", make: { s in let t = s.create(title: "t"); s.update(t.id) { $0.deletedAt = Date() }; return t }, want: .deleted),
            Row(name: "archived project", make: { s in let t = s.create(title: "t"); s.update(t.id) { $0.isProjectArchived = true }; return t }, want: .projectArchived),
            Row(name: "review none", make: { s in let t = s.create(title: "t"); s.update(t.id) { $0.reviewRaw = 0 }; return t }, want: nil),
            Row(name: "review pending", make: { s in let t = s.create(title: "t"); s.update(t.id) { $0.reviewRaw = 1 }; return t }, want: .reviewPending),
            Row(name: "review approved", make: { s in let t = s.create(title: "t"); s.update(t.id) { $0.reviewRaw = 2 }; return t }, want: nil),
            Row(name: "review rejected", make: { s in let t = s.create(title: "t"); s.update(t.id) { $0.reviewRaw = 3 }; return t }, want: nil),
            Row(name: "agent done awaiting check", make: { s in let t = s.create(title: "t"); s.update(t.id) { $0.reviewRaw = 4 }; return t }, want: nil),
            Row(name: "blocked by an open task", make: { s in
                let blocker = s.create(title: "blocker"); let t = s.create(title: "t")
                _ = s.setWaitsOn(t.id, [blocker.id]); return t }, want: .blocked),
            Row(name: "blocker is done", make: { s in
                let blocker = s.create(title: "blocker"); let t = s.create(title: "t")
                _ = s.setWaitsOn(t.id, [blocker.id]); s.complete(blocker.id); return t }, want: nil),
        ]
    }

    @Test func exclusionTable() throws {
        for row in rows() {
            let store = try makeStore()
            let task = row.make(store)
            let pool = store.allTasksIncludingDeleted()
            #expect(NextEligibility.exclusion(of: task, lookup: pool) == row.want, "\(row.name)")
            #expect(NextEligibility.isEligible(task, lookup: pool) == (row.want == nil), "\(row.name)")
        }
    }

    @Test func storeEntryPointMatchesPoolEntryPoint() throws {
        let store = try makeStore()
        let ok = store.create(title: "ok")
        let done = store.create(title: "done"); store.complete(done.id)
        #expect(NextEligibility.isEligible(ok, store: store))
        #expect(!NextEligibility.isEligible(done, store: store))
    }

    // MARK: shown-list head

    @Test func firstEligibleSkipsEveryExclusionInOrder() throws {
        let store = try makeStore()
        let done = store.create(title: "done"); store.complete(done.id)
        let archived = store.create(title: "archived"); store.update(archived.id) { $0.isProjectArchived = true }
        let pending = store.create(title: "pending"); store.update(pending.id) { $0.reviewRaw = 1 }
        let blocker = store.create(title: "blocker")
        let blocked = store.create(title: "blocked"); _ = store.setWaitsOn(blocked.id, [blocker.id])
        let ok = store.create(title: "ok")
        let lookup = store.allTasks()
        let shown = [done, archived, pending, blocked, ok, blocker]
        #expect(NextEligibility.firstEligible(in: shown, lookup: lookup)?.title == "ok")
        #expect(NextEligibility.firstEligible(in: [done, archived, pending, blocked], lookup: lookup) == nil)
        // positive control: drop one exclusion at a time and that row becomes the answer.
        #expect(NextEligibility.firstEligible(in: [done, archived, pending, ok], lookup: lookup)?.title == "ok")
        store.update(pending.id) { $0.reviewRaw = 0 }
        #expect(NextEligibility.firstEligible(in: [done, archived, pending, blocked, ok], lookup: store.allTasks())?.title == "pending")
    }

    @Test func pinOverridesBlockAndReviewButNotDoneOrDeleted() throws {
        let store = try makeStore()
        let blocker = store.create(title: "blocker")
        let pinnedBlocked = store.create(title: "pinned-blocked"); _ = store.setWaitsOn(pinnedBlocked.id, [blocker.id])
        let pinnedPending = store.create(title: "pinned-pending"); store.update(pinnedPending.id) { $0.reviewRaw = 1 }
        let first = store.create(title: "first")
        let rows = [first]
        let lookup = store.allTasks()
        #expect(NextEligibility.pick(pinned: pinnedBlocked.id, rows: rows, lookup: lookup)?.title == "pinned-blocked")
        #expect(NextEligibility.pick(pinned: pinnedPending.id, rows: rows, lookup: lookup)?.title == "pinned-pending")
        #expect(NextEligibility.pick(pinned: nil, rows: rows, lookup: lookup)?.title == "first")
        #expect(NextEligibility.pick(pinned: UUID(), rows: rows, lookup: lookup)?.title == "first")

        store.complete(pinnedBlocked.id)
        #expect(NextEligibility.pick(pinned: pinnedBlocked.id, rows: rows, lookup: store.allTasks()
            + [pinnedBlocked])?.title == "first")
        store.update(pinnedPending.id) { $0.deletedAt = Date() }
        #expect(NextEligibility.pick(pinned: pinnedPending.id, rows: rows, lookup: store.allTasksIncludingDeleted())?.title == "first")
    }

    // MARK: Today fallback

    @Test func todayHeadMembershipSortAndLimit() throws {
        let store = try makeStore()
        // Creation order = manual order. Expected Today head: planned, overdue, due today.
        let none = store.create(title: "no-date")
        let pending = store.create(title: "pending-due-today")
        store.update(pending.id) { $0.dueDay = today; $0.reviewRaw = 1 }
        let done = store.create(title: "done-due-today"); store.update(done.id) { $0.dueDay = today }; store.complete(done.id)
        let planned = store.create(title: "planned"); store.update(planned.id) { $0.plannedDay = today }
        let overdue = store.create(title: "overdue"); store.update(overdue.id) { $0.dueDay = today - 3 }
        let dueToday = store.create(title: "due-today"); store.update(dueToday.id) { $0.dueDay = today }
        let tomorrow = store.create(title: "due-tomorrow"); store.update(tomorrow.id) { $0.dueDay = today + 1 }
        let plannedLater = store.create(title: "planned-later"); store.update(plannedLater.id) { $0.plannedDay = today + 2 }
        // Today list membership: the planned day wins over the deadline, so this overdue row is not in Today.
        let overduePlannedLater = store.create(title: "overdue-planned-later")
        store.update(overduePlannedLater.id) { $0.dueDay = today - 2; $0.plannedDay = today + 1 }
        let blocker = store.create(title: "blocker")
        let blocked = store.create(title: "blocked-due-today")
        store.update(blocked.id) { $0.dueDay = today }; _ = store.setWaitsOn(blocked.id, [blocker.id])
        _ = (none, tomorrow, plannedLater, overduePlannedLater)

        let all = NextFallback.todayHead(store: store, today: today, limit: 8)
        #expect(all == [planned.id, overdue.id, dueToday.id])
        #expect(NextFallback.todayHead(store: store, today: today, limit: 2) == [planned.id, overdue.id])
        #expect(NextFallback.todayHead(store: store, today: today, limit: 0) == [])
        // positive control: once the exclusions lift, those rows join in manual order.
        store.update(pending.id) { $0.reviewRaw = 0 }
        store.complete(blocker.id)
        let lifted = NextFallback.todayHead(store: store, today: today, limit: 8)
        #expect(lifted == [pending.id, planned.id, overdue.id, dueToday.id, blocked.id])
    }

    @Test func todayHeadIsEmptyWhenNothingIsDue() throws {
        let store = try makeStore()
        _ = store.create(title: "undated")
        #expect(NextFallback.todayHead(store: store, today: today, limit: 8).isEmpty)
    }
}

// ListScopeDefaults — pure Core logic for "what should a task typed directly into list scope X
// default to, so it actually shows up in the list it was typed into" (a task added while
// viewing Someday must default to `.someday` status, not silently land in All Tasks instead).
//
// Lives in KronosCore (not the app's Kronos/Shared/QuickAddCreate.swift) so it can be tested by
// the same `swift test` gate as everything else here, with a hand-written table, instead of
// needing a bespoke standalone-compile launcher for one pure function. `QuickAddScopeKind`
// mirrors the SHAPE of the app's `ListScope` (Kronos/Shared/UIContract.swift) — the app maps
// its own enum onto this one case-for-case before calling `apply`; Core has no reason to
// depend on an app-side UI type for a decision this generic.
import Foundation

/// App-agnostic mirror of the cases `ListScopeDefaults` needs to know about. The app's real
/// `ListScope` (also carrying `.savedView`) maps onto this 1:1 — see the call site comment in
/// Kronos/Shared/QuickAddCreate.swift for the exact mapping.
public enum QuickAddScopeKind: Sendable {
    case inbox, today, next7, waiting, someday, all, project, area(UUID), savedView
}

public enum ListScopeDefaults {
    public struct Result: Equatable, Sendable {
        public var status: KStatus
        public var dueDay: Int?
        /// Set only for `.area`, where list membership needs `task.areaID` directly — a task
        /// with no project has no other way to belong to an area.
        public var areaID: UUID?

        public init(status: KStatus, dueDay: Int?, areaID: UUID?) {
            self.status = status; self.dueDay = dueDay; self.areaID = areaID
        }
    }

    /// Explicit text always wins for the DATE: a due date the user actually typed is never
    /// overridden by the scope's own default (only ever FILLED when the user said nothing).
    ///
    /// `isWaiting` is the quick add panel's own Waiting toggle — it ALWAYS wins the
    /// status, over every scope including Someday: a task the user is explicitly marking as
    /// blocked-on-someone-else is `.waiting` whether it was typed on Someday, on Today, or with
    /// no scope at all. Checked first, before the per-scope switch, so no scope case below has
    /// to remember to defer to it.
    public static func apply(scope: QuickAddScopeKind?, explicitDueDay: Int?, today: Int,
                              isWaiting: Bool = false) -> Result {
        if isWaiting {
            return Result(status: .waiting, dueDay: explicitDueDay, areaID: areaID(for: scope))
        }
        switch scope {
        case .someday:
            // List membership (ScopeFilter.matches, Kronos/Shared/ScopeFilter.swift) requires
            // status == .someday; a date does not change whether it counts as Someday.
            return Result(status: .someday, dueDay: explicitDueDay, areaID: nil)
        case .waiting:
            return Result(status: .waiting, dueDay: explicitDueDay, areaID: nil)
        case .today, .next7:
            // Today/Next 7 require an open status AND dueDay in range; .todo + today's date is
            // the natural default and still lets the user re-triage the status later.
            return Result(status: .todo, dueDay: explicitDueDay ?? today, areaID: nil)
        case .area(let id):
            return Result(status: .todo, dueDay: explicitDueDay, areaID: id)
        case nil, .inbox, .all:
            // The Inbox rule: a task typed with no more specific destination than "no
            // project" (Inbox), "everything" (All) or no list at all stays an open `.todo`
            // with no due date and no project. That is exactly what the Inbox list shows
            // (`Kronos/Shared/ScopeFilter.swift`), so the new task is where the user looks
            // for it. Someday is only ever chosen on purpose (the Someday scope, or a later
            // status pick), never filled in for a missing date. An explicit date wins.
            return Result(status: .todo, dueDay: explicitDueDay, areaID: nil)
        case .project, .savedView:
            // fallbackProject (for a project scope) already carries the right membership, and a
            // saved view has no scope-specific default.
            return Result(status: .todo, dueDay: explicitDueDay, areaID: nil)
        }
    }

    /// `.area` is the only scope whose own default carries an areaID; the Waiting toggle keeps
    /// that membership rather than dropping it (`isWaiting` above short-circuits the switch that
    /// would otherwise set it).
    private static func areaID(for scope: QuickAddScopeKind?) -> UUID? {
        if case .area(let id) = scope { return id }
        return nil
    }
}

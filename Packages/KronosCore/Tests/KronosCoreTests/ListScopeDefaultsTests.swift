// Hand-written table for ListScopeDefaults.apply (Packages/KronosCore/Sources/KronosCore/
// QuickAdd/ListScopeDefaults.swift): a task added while looking at Someday must actually
// default into Someday's own filter, not silently land in "all tasks" instead. Every expected
// value here matches ScopeFilter.matches (Kronos/Shared/ScopeFilter.swift, app-side, read for
// the rule but not itself testable from this package) by hand, not by calling the function
// under test.
import Testing
import Foundation
@testable import KronosCore

struct ListScopeDefaultsTests {
    let today = 20000
    let areaID = UUID()

    // Someday: ScopeFilter.matches(.someday) requires status == .someday.
    @Test func someday() {
        let noDate = ListScopeDefaults.apply(scope: .someday, explicitDueDay: nil, today: today)
        #expect(noDate == .init(status: .someday, dueDay: nil, areaID: nil))
        let withDate = ListScopeDefaults.apply(scope: .someday, explicitDueDay: today + 30, today: today)
        #expect(withDate == .init(status: .someday, dueDay: today + 30, areaID: nil))
    }

    // Waiting: ScopeFilter.matches(.waiting) requires status == .waiting.
    @Test func waiting() {
        let noDate = ListScopeDefaults.apply(scope: .waiting, explicitDueDay: nil, today: today)
        #expect(noDate == .init(status: .waiting, dueDay: nil, areaID: nil))
        let withDate = ListScopeDefaults.apply(scope: .waiting, explicitDueDay: today + 3, today: today)
        #expect(withDate == .init(status: .waiting, dueDay: today + 3, areaID: nil))
    }

    // Today / Next 7: ScopeFilter.matches needs isOpen (any open status) AND dueDay in range;
    // .todo + today's date is the default, and explicit text always overrides the date.
    @Test func todayAndNext7DefaultToTodayUnlessDated() {
        let today1 = ListScopeDefaults.apply(scope: .today, explicitDueDay: nil, today: today)
        #expect(today1 == .init(status: .todo, dueDay: today, areaID: nil))
        let today2 = ListScopeDefaults.apply(scope: .today, explicitDueDay: today + 5, today: today)
        #expect(today2 == .init(status: .todo, dueDay: today + 5, areaID: nil))
        let next7a = ListScopeDefaults.apply(scope: .next7, explicitDueDay: nil, today: today)
        #expect(next7a == .init(status: .todo, dueDay: today, areaID: nil))
        let next7b = ListScopeDefaults.apply(scope: .next7, explicitDueDay: today + 2, today: today)
        #expect(next7b == .init(status: .todo, dueDay: today + 2, areaID: nil))
    }

    // An area with no project named: ScopeFilter.matches(.area) reads task.areaID directly (a
    // task with no project has no other way into the area), so the id must carry through.
    @Test func areaCarriesAreaID() {
        let noDate = ListScopeDefaults.apply(scope: .area(areaID), explicitDueDay: nil, today: today)
        #expect(noDate == .init(status: .todo, dueDay: nil, areaID: areaID))
        let withDate = ListScopeDefaults.apply(scope: .area(areaID), explicitDueDay: today + 1, today: today)
        #expect(withDate == .init(status: .todo, dueDay: today + 1, areaID: areaID))
    }

    // Project / a saved view: unchanged behaviour — fallbackProject (for a project scope)
    // already carries the right membership, and a saved view has no scope-specific default.
    // Both are already a specific, deliberate destination, unlike nil/Inbox/All below.
    @Test func projectAndSavedViewHaveNoDefault() {
        let kinds: [QuickAddScopeKind?] = [.project, .savedView]
        for kind in kinds {
            let noDate = ListScopeDefaults.apply(scope: kind, explicitDueDay: nil, today: today)
            #expect(noDate == .init(status: .todo, dueDay: nil, areaID: nil), "\(String(describing: kind))")
            let withDate = ListScopeDefaults.apply(scope: kind, explicitDueDay: today + 9, today: today)
            #expect(withDate == .init(status: .todo, dueDay: today + 9, areaID: nil), "\(String(describing: kind))")
        }
    }

    // Broadened from "the global panel" to every general-purpose scope: an undated task should
    // land in Someday regardless of which general-purpose scope it was added from — nil (the
    // global panel), Inbox and All must all land an undated task in Someday, not silently with
    // no date under whichever of those the user happened to be looking at. An explicit date
    // still makes it a normal open task, same shape as every scoped case above. Note: for
    // `.inbox`, this means an undated task typed while looking at Inbox will NOT show in Inbox
    // — `ScopeFilter.matches(.inbox)` (Kronos/Shared/ScopeFilter.swift:19) excludes
    // `status == .someday` by definition; it shows in Someday instead, by design.
    @Test func noScopeInboxAndAllDefaultToSomedayWithoutADate() {
        let kinds: [QuickAddScopeKind?] = [nil, .inbox, .all]
        for kind in kinds {
            let noDate = ListScopeDefaults.apply(scope: kind, explicitDueDay: nil, today: today)
            #expect(noDate == .init(status: .someday, dueDay: nil, areaID: nil), "\(String(describing: kind))")
            let withDate = ListScopeDefaults.apply(scope: kind, explicitDueDay: today + 9, today: today)
            #expect(withDate == .init(status: .todo, dueDay: today + 9, areaID: nil), "\(String(describing: kind))")
        }
    }

    // The panel's Waiting toggle must ALWAYS win the status, over every scope including
    // Someday itself, with or without a date, and preserve an area's membership — otherwise
    // toggling Waiting while looking at a Someday-defaulting scope would silently do nothing.
    @Test func waitingToggleAlwaysWinsOverEveryScope() {
        let scopes: [QuickAddScopeKind?] = [nil, .inbox, .today, .next7, .someday, .waiting, .all,
                                             .project, .savedView, .area(areaID)]
        for scope in scopes {
            let noDate = ListScopeDefaults.apply(scope: scope, explicitDueDay: nil, today: today, isWaiting: true)
            #expect(noDate.status == .waiting, "\(String(describing: scope))")
            #expect(noDate.dueDay == nil, "\(String(describing: scope))")
            let withDate = ListScopeDefaults.apply(scope: scope, explicitDueDay: today + 4, today: today, isWaiting: true)
            #expect(withDate.status == .waiting, "\(String(describing: scope))")
            #expect(withDate.dueDay == today + 4, "\(String(describing: scope))")
        }
        // Area membership survives the toggle (the toggle only overrides status, not scope).
        let area = ListScopeDefaults.apply(scope: .area(areaID), explicitDueDay: nil, today: today, isWaiting: true)
        #expect(area.areaID == areaID)
    }
}

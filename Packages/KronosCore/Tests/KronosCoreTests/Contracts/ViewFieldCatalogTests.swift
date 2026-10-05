import Testing
import Foundation
@testable import KronosCore

/// What the view-options editor offers on each kind of list. Every table below is written by hand.
@MainActor
@Suite("ViewFieldCatalogTests")
struct ViewFieldCatalogTests {

    // MARK: Offered sort keys (hand tables)

    private let globalSort: [KSortKey] = [.title, .status, .priority, .effort, .deadline, .project, .createdAt, .updatedAt, .estimateMinutes]

    @Test("a fixed list (Inbox, Today, Next 7, All) offers these sort keys and never Manual, Area, Label or Depth")
    func globalSortKeys() {
        #expect(ViewFieldCatalog.sortKeys(for: .global, showCompleted: false) == globalSort)
        for hidden in [KSortKey.manual, .area, .label, .depth] {
            #expect(!ViewFieldCatalog.sortKeys(for: .global, showCompleted: false).contains(hidden))
        }
    }

    @Test("Completed is offered only while completed tasks are shown")
    func completedKey() {
        #expect(ViewFieldCatalog.sortKeys(for: .global, showCompleted: true) == globalSort + [.completedAt])
        #expect(!ViewFieldCatalog.sortKeys(for: .global, showCompleted: false).contains(.completedAt))
        // Waiting and Someday hold no closed task: there is nothing to sort by completion.
        #expect(!ViewFieldCatalog.sortKeys(for: .waiting, showCompleted: true).contains(.completedAt))
    }

    @Test("a project list does not offer Project; Waiting and Someday do not offer Status")
    func scopeDependentSortKeys() {
        #expect(ViewFieldCatalog.sortKeys(for: .project, showCompleted: false)
                == [.title, .status, .priority, .effort, .deadline, .createdAt, .updatedAt, .estimateMinutes])
        for shape in [ListShape.waiting, .someday] {
            #expect(ViewFieldCatalog.sortKeys(for: shape, showCompleted: false)
                    == [.title, .priority, .effort, .deadline, .project, .createdAt, .updatedAt, .estimateMinutes])
        }
        #expect(ViewFieldCatalog.sortKeys(for: .area, showCompleted: false) == globalSort)
        #expect(ViewFieldCatalog.sortKeys(for: .savedView, showCompleted: false) == globalSort)
    }

    // MARK: Offered filter fields (hand tables)

    @Test("filter fields per kind of list")
    func filterFieldTables() {
        let tail: [KFilter.Field] = [.labels, .due, .hasSubtasks, .hasNotes, .needsTriage, .text]
        #expect(ViewFieldCatalog.filterFields(for: .global) == [.statuses, .priorities, .efforts, .project, .area] + tail)
        #expect(ViewFieldCatalog.filterFields(for: .project) == [.statuses, .priorities, .efforts] + tail)
        #expect(ViewFieldCatalog.filterFields(for: .area) == [.statuses, .priorities, .efforts, .project] + tail)
        #expect(ViewFieldCatalog.filterFields(for: .waiting) == [.priorities, .efforts, .project, .area] + tail)
        #expect(ViewFieldCatalog.filterFields(for: .someday) == [.priorities, .efforts, .project, .area] + tail)
        #expect(ViewFieldCatalog.filterFields(for: .savedView) == [.statuses, .priorities, .efforts, .project, .area] + tail)
        for shape in [ListShape.global, .project, .area, .waiting, .someday, .savedView] {
            for hidden in [KFilter.Field.depths, .dread, .isSomeday] {
                #expect(!ViewFieldCatalog.filterFields(for: shape).contains(hidden))
            }
        }
    }

    // MARK: Every offered key / field works on a fixture

    /// Three tasks in manual order t1, t2, t3, each attribute set so that ascending order is t2, t3, t1
    /// (title: "cc" "aa" "bb"; and so on): every key therefore visibly reorders the manual list.
    private struct Fixture {
        let store: TaskStore
        let t1: KTask, t2: KTask, t3: KTask
        let alpha: KProject, area: KArea
        let label: KLabel
        var tasks: [KTask] { [t1, t2, t3] }
    }

    private func fixture() throws -> Fixture {
        let s = try TaskStore(inMemory: true)
        let area = s.createArea(name: "Area")
        let zed = s.createProject(name: "Zed")
        let alpha = s.createProject(name: "Alpha", area: area)
        let mid = s.createProject(name: "Mid")
        let t1 = s.createNoUndo(title: "cc", project: zed)
        let t2 = s.createNoUndo(title: "aa", project: alpha)
        let t3 = s.createNoUndo(title: "bb", project: mid)
        t1.sortIndex = 1; t2.sortIndex = 2; t3.sortIndex = 3
        let today = Day.today()
        t1.statusRaw = KStatus.waiting.rawValue; t2.statusRaw = KStatus.todo.rawValue; t3.statusRaw = KStatus.inProgress.rawValue
        t1.priorityRaw = 3; t2.priorityRaw = 1; t3.priorityRaw = 2
        t1.effortRaw = KEffort.l.rawValue; t2.effortRaw = KEffort.s.rawValue; t3.effortRaw = KEffort.m.rawValue
        t1.dueDay = today + 3; t2.dueDay = today; t3.dueDay = today + 2
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        t1.createdAt = base.addingTimeInterval(30); t2.createdAt = base.addingTimeInterval(10); t3.createdAt = base.addingTimeInterval(20)
        t1.updatedAt = base.addingTimeInterval(30); t2.updatedAt = base.addingTimeInterval(10); t3.updatedAt = base.addingTimeInterval(20)
        t1.completedAt = base.addingTimeInterval(30); t2.completedAt = base.addingTimeInterval(10); t3.completedAt = base.addingTimeInterval(20)
        t1.estimateMinutes = 60; t2.estimateMinutes = 15; t3.estimateMinutes = 30
        let label = s.label(named: "urgent-ish")
        s.addLabel(label, to: t2.id)
        t2.notes = "has notes"
        _ = s.addSubtask(t2.id, title: "step")
        t2.needsTriage = true; t1.needsTriage = false; t3.needsTriage = false
        return Fixture(store: s, t1: t1, t2: t2, t3: t3, alpha: alpha, area: area, label: label)
    }

    @Test("every offered sort key puts t2, t3, t1 first-to-last, which is not the manual order t1, t2, t3")
    func everyOfferedSortKeySorts() throws {
        let f = try fixture()
        let manual = KTaskSorter.sorted(f.tasks, by: [.asc(.manual)]).map(\.title)
        #expect(manual == ["cc", "aa", "bb"])
        let offered = ViewFieldCatalog.sortKeys(for: .global, showCompleted: true)
        #expect(offered.count == 10)
        for key in offered {
            let got = KTaskSorter.sorted(f.tasks, by: [.asc(key)]).map(\.title)
            // title: aa, bb, cc; project: Alpha, Mid, Zed; everything else was set so t2 < t3 < t1.
            #expect(got == ["aa", "bb", "cc"], "key \(key)")
            #expect(got != manual, "key \(key)")
        }
        #expect(f.store.allTasks().count == 3)   // keeps the store alive while its tasks are read
    }

    @Test("every offered filter field narrows the fixture to t2 when given t2's value")
    func everyOfferedFilterFieldNarrows() throws {
        let f = try fixture()
        let today = Day.today()
        func hits(_ filter: KFilter) -> [String] { f.tasks.filter { filter.matches($0, today: today) }.map(\.title) }
        let valued: [KFilter.Field: KFilter] = [
            .statuses: { var x = KFilter.empty; x.statuses = [KStatus.todo.rawValue]; return x }(),
            .priorities: { var x = KFilter.empty; x.priorities = [1]; return x }(),
            .efforts: { var x = KFilter.empty; x.efforts = [KEffort.s.rawValue]; return x }(),
            .project: { var x = KFilter.empty; x.projectIDs = [f.alpha.id]; return x }(),
            .area: { var x = KFilter.empty; x.areaIDs = [f.area.id]; return x }(),
            .labels: { var x = KFilter.empty; x.labelIDs = [f.label.id]; return x }(),
            .due: { var x = KFilter.empty; x.due = .custom; x.dueFrom = today; x.dueTo = today; return x }(),
            .hasSubtasks: { var x = KFilter.empty; x.hasSubtasks = true; return x }(),
            .hasNotes: { var x = KFilter.empty; x.hasNotes = true; return x }(),
            .needsTriage: { var x = KFilter.empty; x.needsTriage = true; return x }(),
            .text: { var x = KFilter.empty; x.text = "aa"; return x }(),
        ]
        let offered = ViewFieldCatalog.filterFields(for: .global)
        #expect(Set(valued.keys) == Set(offered))
        for field in offered {
            #expect(hits(valued[field]!) == ["aa"], "field \(field)")
        }
        // Positive control: an empty filter narrows nothing.
        #expect(hits(.empty).count == 3)
        #expect(f.store.allTasks().count == 3)
    }

    // MARK: sanitized

    @Test("sanitizing drops hidden sort keys and filter fields and keeps the offered ones")
    func sanitizedDropsHiddenOnly() {
        var f = KFilter.empty
        f.priorities = [3]
        f.depths = [1]
        f.dread = true
        f.isSomeday = true
        f.projectIDs = [UUID()]
        let opts = ViewOptions(sort: [.desc(.priority), .asc(.area), .asc(.manual)], filter: f, showCompleted: false)

        let out = ViewFieldCatalog.sanitized(opts, for: .project)
        #expect(out.sort == [.desc(.priority)])
        #expect(out.filter.priorities == [3])
        #expect(out.filter.depths.isEmpty)
        #expect(out.filter.dread == nil)
        #expect(out.filter.isSomeday == nil)
        #expect(out.filter.projectIDs.isEmpty)   // contradicts a project list

        // A global list keeps the project filter.
        #expect(ViewFieldCatalog.sanitized(opts, for: .global).filter.projectIDs == f.projectIDs)
    }

    @Test("a stored sort that is entirely hidden becomes the default manual order; the default stays")
    func sanitizedSortFallsBackToManual() {
        let hidden = ViewOptions(sort: [.asc(.label), .desc(.depth)], filter: .empty, showCompleted: false)
        #expect(ViewFieldCatalog.sanitized(hidden, for: .global).sort == KSortDescriptor.default)
        #expect(ViewFieldCatalog.sanitized(.default, for: .global) == .default)
        #expect(ViewFieldCatalog.sanitized(.default, for: .global).isManualOrder)
    }

    @Test("Completed sort is dropped when completed tasks are hidden")
    func sanitizedCompletedSort() {
        let on = ViewOptions(sort: [.desc(.completedAt)], filter: .empty, showCompleted: true)
        #expect(ViewFieldCatalog.sanitized(on, for: .global).sort == [.desc(.completedAt)])
        var off = on; off.showCompleted = false
        #expect(ViewFieldCatalog.sanitized(off, for: .global).sort == KSortDescriptor.default)
    }

    @Test("Waiting and Someday lose a stored status filter; an area list loses an area filter")
    func sanitizedPerKind() {
        var f = KFilter.empty
        f.statuses = [KStatus.todo.rawValue]
        f.areaIDs = [UUID()]
        let opts = ViewOptions(sort: KSortDescriptor.default, filter: f, showCompleted: false)
        #expect(ViewFieldCatalog.sanitized(opts, for: .waiting).filter.statuses.isEmpty)
        #expect(ViewFieldCatalog.sanitized(opts, for: .waiting).filter.areaIDs == f.areaIDs)
        #expect(ViewFieldCatalog.sanitized(opts, for: .area).filter.areaIDs.isEmpty)
        #expect(ViewFieldCatalog.sanitized(opts, for: .area).filter.statuses == f.statuses)
    }

    @Test("a saved view keeps every rule it has")
    func savedViewUntouched() {
        var f = KFilter.empty
        f.depths = [2]; f.dread = true; f.projectIDs = [UUID()]
        let opts = ViewOptions(sort: [.asc(.label), .desc(.depth)], filter: f, showCompleted: true)
        #expect(ViewFieldCatalog.sanitized(opts, for: .savedView) == opts)
    }

    @Test("clearing a field also drops its inversion and leaves the others")
    func clearFieldDropsNegation() {
        var f = KFilter.empty
        f.priorities = [3]; f.efforts = [2]
        f.setNegated(.priorities, true)
        f.clear(.priorities)
        #expect(f.priorities.isEmpty)
        #expect(!f.isNegated(.priorities))
        #expect(f.efforts == [2])
    }
}

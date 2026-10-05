import Testing
import Foundation
@testable import KronosCore

/// View options: how a sort edit resolves, what "clear all" removes and restores, and what is persisted.
/// Expected orders are written by hand, never derived from the code under test.
@MainActor
@Suite("ViewOptionsTests")
struct ViewOptionsTests {

    /// Manual order after one drag: M4, M1, M2, M3. Priorities: M1 low, M2 urgent, M3 medium, M4 high.
    @MainActor private struct World {
        let store: TaskStore
        let m1: KTask, m2: KTask, m3: KTask, m4: KTask

        func manual(_ filter: KFilter = .empty) -> [String] {
            order(.default.replacingSort(with: []), filter)
        }

        func order(_ opts: ViewOptions, _ filter: KFilter? = nil) -> [String] {
            let f = filter ?? opts.filter
            let shown = store.allTasks().filter { f.matches($0, today: Day.today()) }
            return KTaskSorter.sorted(shown, by: opts.sort).map(\.title)
        }
    }

    private func world() throws -> World {
        let s = try TaskStore(inMemory: true)
        let m1 = s.createNoUndo(title: "M1"), m2 = s.createNoUndo(title: "M2")
        let m3 = s.createNoUndo(title: "M3"), m4 = s.createNoUndo(title: "M4")
        s.setPriority(m1.id, .low); s.setPriority(m2.id, .urgent)
        s.setPriority(m3.id, .medium); s.setPriority(m4.id, .high)
        // The person drags M4 to the top.
        #expect(s.moveTask(m4.id, before: m1.id, inOrder: [m1.id, m2.id, m3.id, m4.id]))
        return World(store: s, m1: m1, m2: m2, m3: m3, m4: m4)
    }

    // MARK: Add sort

    @Test("a criterion added to a manual list replaces manual (the old rule kept manual and dropped it)")
    func addToManual() {
        let previous = [KSortDescriptor.asc(.manual)]
        let proposed = [KSortDescriptor.asc(.manual), .desc(.priority)]
        #expect(ViewOptions.resolveSort(previous: previous, proposed: proposed) == [.desc(.priority)])
        // Positive control: the rule this replaced answers [manual] for the same edit, i.e. the add did nothing.
        let legacy = proposed.contains { $0.key == .manual } ? [KSortDescriptor.asc(.manual)] : proposed
        #expect(legacy == previous)
        #expect(legacy != ViewOptions.resolveSort(previous: previous, proposed: proposed))
    }

    @Test("a second criterion keeps the first, in order, with each direction")
    func addSecond() {
        let previous = [KSortDescriptor.desc(.priority)]
        let proposed = [KSortDescriptor.desc(.priority), .asc(.title)]
        #expect(ViewOptions.resolveSort(previous: previous, proposed: proposed) == proposed)
    }

    @Test("picking manual removes every other criterion")
    func pickManual() {
        let previous = [KSortDescriptor.desc(.priority), .asc(.title)]
        let proposed = [KSortDescriptor.asc(.manual), .asc(.title)]
        #expect(ViewOptions.resolveSort(previous: previous, proposed: proposed) == [.asc(.manual)])
    }

    @Test("removing the last criterion, or an empty editor, gives manual; manual keeps its own direction")
    func emptyAndDirection() {
        #expect(ViewOptions.resolveSort(previous: [.desc(.priority)], proposed: []) == KSortDescriptor.default)
        #expect(ViewOptions.resolveSort(previous: KSortDescriptor.default, proposed: [.desc(.manual)]) == [.desc(.manual)])
    }

    @Test("applied to real tasks the added sort reorders the list by hand-written expectation")
    func appliedOrder() throws {
        let w = try world()
        #expect(w.manual() == ["M4", "M1", "M2", "M3"])
        let opts = ViewOptions.default.replacingSort(with: [.asc(.manual), .desc(.priority)])
        #expect(opts.sort == [.desc(.priority)])
        #expect(w.order(opts) == ["M2", "M4", "M3", "M1"])
        let byTitle = opts.replacingSort(with: [.desc(.priority), .asc(.title)])
        #expect(w.order(byTitle) == ["M2", "M4", "M3", "M1"])
    }

    // MARK: Clear all

    @Test("clear all drops every sort and filter, keeps the display switch, and the list is the dragged order again")
    func clearAll() throws {
        let w = try world()
        var f = KFilter.empty
        f.priorities = [KPriority.urgent.rawValue, KPriority.high.rawValue]
        let opts = ViewOptions(sort: [.asc(.title)], filter: f, showCompleted: true)
        #expect(opts.hasRulesToClear)
        #expect(w.order(opts) == ["M2", "M4"])
        let cleared = opts.cleared()
        #expect(cleared == ViewOptions(sort: KSortDescriptor.default, filter: .empty, showCompleted: true))
        #expect(!cleared.hasRulesToClear)
        #expect(w.order(cleared) == ["M4", "M1", "M2", "M3"])
        // Clearing again changes nothing.
        #expect(cleared.cleared() == cleared)
    }

    @Test("clear all never rewrites a row: order values and step order are exactly what they were")
    func clearAllLeavesRowsAlone() throws {
        let s = try TaskStore(inMemory: true)
        let a = s.createNoUndo(title: "A"), b = s.createNoUndo(title: "B")
        let a1 = try #require(s.addSubtaskNoUndo(a.id, title: "a1"))
        _ = try #require(s.addSubtaskNoUndo(a.id, title: "a2"))
        let a3 = try #require(s.addSubtaskNoUndo(a.id, title: "a3"))
        s.reorderChild(a3.id, before: a1.id)    // steps: a3, a1, a2
        #expect(s.moveTask(b.id, before: a.id, inOrder: [a.id, b.id]))   // list: B, A
        let indexes = s.allTasks().map { "\($0.title)=\($0.sortIndex)" }.sorted()
        let steps = s.children(of: a.id).map(\.title)
        #expect(steps == ["a3", "a1", "a2"])
        let after = ViewOptions(sort: [.desc(.title)], filter: .empty).cleared()
        let top = KTaskSorter.sorted(s.allTasks().filter { $0.parentID == nil }, by: after.sort).map(\.title)
        #expect(top == ["B", "A"])
        #expect(s.children(of: a.id).map(\.title) == ["a3", "a1", "a2"])
        #expect(s.allTasks().map { "\($0.title)=\($0.sortIndex)" }.sorted() == indexes)
    }

    @Test("what counts as something to clear")
    func hasRulesToClearTable() {
        var f = KFilter.empty
        f.statuses = [KStatus.waiting.rawValue]
        let rows: [(ViewOptions, Bool)] = [
            (.default, false),
            (ViewOptions(showCompleted: true), false),
            (ViewOptions(sort: [.asc(.title)]), true),
            (ViewOptions(sort: [.desc(.manual)]), true),
            (ViewOptions(filter: f), true),
            (ViewOptions(sort: [.asc(.manual)], filter: .empty, showCompleted: false), false),
        ]
        for (opts, want) in rows { #expect(opts.hasRulesToClear == want) }
        #expect(ViewOptions.default.isManualOrder)
        #expect(!ViewOptions(sort: [.desc(.manual)]).isManualOrder)
    }

    @Test("switching to manual keeps the filters")
    func switchToManual() {
        var f = KFilter.empty
        f.priorities = [KPriority.high.rawValue]
        let opts = ViewOptions(sort: [.desc(.priority)], filter: f, showCompleted: true)
        let manual = opts.switchedToManual()
        #expect(manual.sort == KSortDescriptor.default)
        #expect(manual.filter == f)
        #expect(manual.showCompleted)
    }

    // MARK: Persistence

    @Test("options persist per list: one JSON map, each list keeps its own sort and filter")
    func persistsPerList() throws {
        var f = KFilter.empty
        f.text = "invoice"
        let map: [String: ViewOptions] = [
            "project.A": ViewOptions(sort: [.desc(.priority), .asc(.title)]),
            "inbox": .default,
            "view.B": ViewOptions(sort: [.asc(.deadline)], filter: f, showCompleted: true),
        ]
        let data = try JSONEncoder().encode(map)
        let back = try JSONDecoder().decode([String: ViewOptions].self, from: data)
        #expect(back == map)
        #expect(back["project.A"]?.sort == [.desc(.priority), .asc(.title)])
        #expect(back["inbox"]?.isManualOrder == true)
        #expect(back["view.B"]?.filter.text == "invoice")
        // Positive control: a map with one list's sort changed does not compare equal.
        var changed = map
        changed["project.A"] = ViewOptions(sort: [.desc(.priority)])
        #expect(changed != back)
        // The stored sort uses the stable wire strings.
        let json = String(decoding: try JSONEncoder().encode(ViewOptions(sort: [.desc(.priority)])), as: UTF8.self)
        #expect(json.contains("\"priority\""))
    }

    // MARK: Removing a rule (the chip's X and the editor row's X)

    @Test("removing the only sort rule gives the default manual order; removing one of two keeps the other")
    func removeSortRule() {
        var only = ViewOptions(sort: [.desc(.priority)])
        only.sort.remove(at: 0)
        // The chip's X puts the default back when nothing is left.
        let afterOnly = only.sort.isEmpty ? KSortDescriptor.default : only.sort
        #expect(afterOnly == KSortDescriptor.default)
        #expect(ViewOptions(sort: afterOnly).isManualOrder)

        var two = ViewOptions(sort: [.desc(.priority), .asc(.title)])
        two.sort.remove(at: 0)
        #expect(two.sort == [.asc(.title)])
        #expect(!two.isManualOrder)

        // The editor's own removal (rows -> resolveSort) agrees.
        #expect(ViewOptions.resolveSort(previous: [.desc(.priority), .asc(.title)], proposed: [.asc(.title)]) == [.asc(.title)])
        #expect(ViewOptions.resolveSort(previous: [.desc(.priority)], proposed: []) == KSortDescriptor.default)
    }

    @Test("a manual row removed from a manual list stays the default (why the editor does not list Manual)")
    func manualRowRemovalIsANoOp() {
        let previous = KSortDescriptor.default
        #expect(ViewOptions.resolveSort(previous: previous, proposed: []) == previous)
    }
}

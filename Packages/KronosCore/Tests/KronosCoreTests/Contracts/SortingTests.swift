import Testing
import Foundation
@testable import KronosCore

/// Multi-key sorting (rev 3). The two rules that make the result usable are
/// "nil always last, in both directions" and "the order is total".
@MainActor
struct SortingTests {

    private func store() throws -> TaskStore { try TaskStore(inMemory: true) }

    // MARK: - two keys, opposite directions

    @Test func twoKeySortAppliesPrimaryThenSecondaryWithOwnDirections() throws {
        let s = try store()
        // Same deadline, different priority: the secondary key decides.
        let low  = s.create(title: "low",  notes: "", project: nil, status: .todo, priority: .low,    dueDay: 100)
        let high = s.create(title: "high", notes: "", project: nil, status: .todo, priority: .urgent, dueDay: 100)
        // Earlier deadline: the primary key puts it first regardless.
        let early = s.create(title: "early", notes: "", project: nil, status: .todo, priority: .none, dueDay: 50)

        // deadline ascending, then priority DESCENDING.
        let out = KTaskSorter.sorted(s.allTasks(),
                                     by: [.asc(.deadline), .desc(.priority)])
        #expect(out.map(\.id) == [early.id, high.id, low.id])

        // Flip only the secondary: the primary grouping is unchanged.
        let out2 = KTaskSorter.sorted(s.allTasks(),
                                      by: [.asc(.deadline), .asc(.priority)])
        #expect(out2.map(\.id) == [early.id, low.id, high.id])
    }

    // MARK: - nils last in BOTH directions

    @Test func absentValuesSortLastWhicheverDirection() throws {
        let s = try store()
        let none  = s.create(title: "no deadline", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        let soon  = s.create(title: "soon",        notes: "", project: nil, status: .todo, priority: .none, dueDay: 10)
        let later = s.create(title: "later",       notes: "", project: nil, status: .todo, priority: .none, dueDay: 99)

        let asc = KTaskSorter.sorted(s.allTasks(), by: [.asc(.deadline)])
        #expect(asc.map(\.id) == [soon.id, later.id, none.id])

        // Descending must NOT drag the undated task to the top: the user
        // asked for the furthest deadline first, not for the undated ones.
        let desc = KTaskSorter.sorted(s.allTasks(), by: [.desc(.deadline)])
        #expect(desc.map(\.id) == [later.id, soon.id, none.id])
    }

    @Test func effortNoneAndDepthUnknownCountAsAbsent() throws {
        let s = try store()
        let unsized = s.create(title: "unsized", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        let xs = s.create(title: "xs", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        s.setEffort(xs.id, .xs)
        let xl = s.create(title: "xl", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        s.setEffort(xl.id, .xl)

        // .none is "unsized", not "smaller than xs".
        let asc = KTaskSorter.sorted(s.allTasks(), by: [.asc(.effort)])
        #expect(asc.map(\.id) == [xs.id, xl.id, unsized.id])

        let desc = KTaskSorter.sorted(s.allTasks(), by: [.desc(.effort)])
        #expect(desc.map(\.id) == [xl.id, xs.id, unsized.id])
    }

    // MARK: - Croatian folding

    @Test func djakovoSortsWithTheDs() throws {
        let s = try store()
        // đ is a distinct Latin letter and survives .diacriticInsensitive
        // folding, so without the explicit map it would sort after Z.
        let dj = s.create(title: "Đakovo",  notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        let da = s.create(title: "Daruvar", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        let ez = s.create(title: "Zagreb",  notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        let cc = s.create(title: "Čakovec", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)

        let out = KTaskSorter.sorted(s.allTasks(), by: [.asc(.title)])
        // Đakovo folds to "Dakovo", so it sorts among the Ds — and within
        // them by the next letter: Dak < Dar. The point of the test is that
        // it lands here at all rather than after Zagreb, which is where an
        // unmapped đ would put it.
        #expect(out.map(\.title) == ["Čakovec", "Đakovo", "Daruvar", "Zagreb"])
        #expect(out.map(\.id) == [cc.id, dj.id, da.id, ez.id])
        // The regression this guards: đ must not sort last.
        #expect(out.last?.title == "Zagreb")
    }

    @Test func titleSortIsCaseInsensitive() throws {
        let s = try store()
        _ = s.create(title: "banana", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        _ = s.create(title: "Apple",  notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        let out = KTaskSorter.sorted(s.allTasks(), by: [.asc(.title)])
        #expect(out.map(\.title) == ["Apple", "banana"])
    }

    // MARK: - totality and stability

    @Test func orderIsTotalAndRepeatable() throws {
        let s = try store()
        // Five rows that tie on every user-visible key.
        for _ in 0..<5 {
            _ = s.create(title: "same", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        }
        let a = KTaskSorter.sorted(s.allTasks(), by: [.asc(.title), .desc(.priority)])
        let b = KTaskSorter.sorted(s.allTasks().reversed(), by: [.asc(.title), .desc(.priority)])
        // Same input set, different starting order, identical result: the
        // sortIndex-then-id tiebreak makes the order total.
        #expect(a.map(\.id) == b.map(\.id))
        #expect(a.count == 5)
    }

    @Test func emptyDescriptorsFallBackToTheTiebreakAlone() throws {
        let s = try store()
        let one = s.create(title: "b", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        let two = s.create(title: "a", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        // create() appends, so sortIndex order is creation order.
        let out = KTaskSorter.sorted(s.allTasks(), by: [])
        #expect(out.map(\.id) == [one.id, two.id])
    }

    @Test func everySortKeyIsUsableAndDoesNotTrap() throws {
        let s = try store()
        let p = s.createProject(name: "Acme", colorHex: "#3FB950", icon: "leaf", area: nil)
        let t = s.create(title: "T", notes: "n", project: p, status: .todo, priority: .high, dueDay: 10)
        s.update(t.id) { $0.estimateMinutes = 30; $0.depth = .shallow }
        _ = s.create(title: "U", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)

        // Exercising every key guards against a new case being added to the
        // enum without a branch in the comparator.
        for key in KSortKey.allCases {
            let asc = KTaskSorter.sorted(s.allTasks(), by: [.asc(key)])
            let desc = KTaskSorter.sorted(s.allTasks(), by: [.desc(key)])
            #expect(asc.count == 2, "\(key)")
            #expect(desc.count == 2, "\(key)")
        }
    }

    @Test func sortDescriptorsRoundTripThroughASavedView() throws {
        let sort: [KSortDescriptor] = [.asc(.deadline), .desc(.effort), .asc(.title)]
        let v = KSavedView(name: "Planning", filter: .empty, sort: sort)
        #expect(v.sortDescriptors == sort)

        // A view written before rev 3 has no sortJSON and must still sort.
        let legacy = KSavedView(name: "Old", filter: .empty, sortMode: .priorityThenDue)
        #expect(legacy.sortDescriptors == [.asc(.deadline), .desc(.priority)])

        let manual = KSavedView(name: "Manual", filter: .empty, sortMode: .manual)
        #expect(manual.sortDescriptors == [.asc(.manual)])
    }
}

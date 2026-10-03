import Testing
import Foundation
@testable import KronosCore

/// A label filter over a list of parent rows. A child is never a row of its own: when a child
/// carries the label, the PARENT row is listed and the matching child is marked.
///
///  Fixture (title: labels; children: labels):
///   Plain parent        -          children: none
///   Labelled parent     work       children: "plain step" -
///   Parent via child    -          children: "work step" work | "home step" home | "plain kid" -
///   Parent deleted kid  -          children: "deleted work step" work (soft-deleted)
///   Parent done kid     -          children: "done work step" work (done)
@MainActor
@Suite("LabelFilterChildrenTests")
struct LabelFilterChildrenTests {

    private let today = 1000

    @MainActor private struct World {
        let store: TaskStore
        let work: KLabel, home: KLabel
        let byTitle: [String: KTask]
        func t(_ title: String) -> KTask { byTitle[title]! }
        var parents: [KTask] { store.allTasks() }
    }

    private func world() throws -> World {
        let store = try TaskStore(inMemory: true)
        let work = store.label(named: "work")
        let home = store.label(named: "home")
        var all: [String: KTask] = [:]
        func parent(_ title: String, _ labels: [KLabel] = []) -> KTask {
            let t = store.createNoUndo(title: title, project: nil, status: .todo)
            t.labels = labels
            all[title] = t
            return t
        }
        func child(_ title: String, of p: KTask, _ labels: [KLabel] = [], status: KStatus = .todo) -> KTask {
            let c = store.addSubtaskNoUndo(p.id, title: title)!
            c.labels = labels
            c.status = status
            all[title] = c
            return c
        }
        _ = parent("Plain parent")
        let lp = parent("Labelled parent", [work])
        _ = child("plain step", of: lp)
        let pvc = parent("Parent via child")
        _ = child("work step", of: pvc, [work])
        _ = child("home step", of: pvc, [home])
        _ = child("plain kid", of: pvc)
        let pdk = parent("Parent deleted kid")
        let gone = child("deleted work step", of: pdk, [work])
        store.softDelete(gone.id)
        let pdone = parent("Parent done kid")
        _ = child("done work step", of: pdone, [work], status: .done)
        return World(store: store, work: work, home: home, byTitle: all)
    }

    private func rows(_ w: World, _ f: KFilter) -> Set<String> {
        Set(w.parents.filter { f.matches($0, today: today) }.map(\.title))
    }

    @Test func aLabelOnAChildListsItsParentRowOnce() throws {
        let w = try world()
        var f = KFilter(); f.labelIDs = [w.work.id]
        #expect(rows(w, f) == ["Labelled parent", "Parent via child", "Parent done kid"])
        // Children are never rows: the pool the lists filter is parents only.
        #expect(!w.parents.map(\.title).contains("work step"))
    }

    @Test func theMatchingChildIsTheOneMarked() throws {
        let w = try world()
        let ids: Set<UUID> = [w.work.id]
        #expect(w.t("Parent via child").childrenCarryingAnyLabel(of: ids).map(\.title) == ["work step"])
        #expect(w.t("Labelled parent").childrenCarryingAnyLabel(of: ids).isEmpty)
        #expect(w.t("Parent deleted kid").childrenCarryingAnyLabel(of: ids).isEmpty)
        let both: Set<UUID> = [w.work.id, w.home.id]
        #expect(w.t("Parent via child").childrenCarryingAnyLabel(of: both).map(\.title) == ["work step", "home step"])
        #expect(w.t("Parent via child").childrenCarryingAnyLabel(of: []).isEmpty)
    }

    @Test func otherLabelAndDeletedChildDoNotMatch() throws {
        let w = try world()
        var f = KFilter(); f.labelIDs = [w.home.id]
        #expect(rows(w, f) == ["Parent via child"])
    }

    @Test func negatedLabelHidesAParentWhoseChildCarriesIt() throws {
        let w = try world()
        var f = KFilter(); f.labelIDs = [w.work.id]; f.setNegated(.labels, true)
        #expect(rows(w, f) == ["Plain parent", "Parent deleted kid"])
    }
}

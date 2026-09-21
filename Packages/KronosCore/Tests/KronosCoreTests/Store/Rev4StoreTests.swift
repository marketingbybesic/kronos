// Store-level coverage for capabilities the UI depends on having a real API for: areas
// that hold no projects, archived projects, project archive/restore/move/rename,
// saved-view CRUD, subtask reorder/delete.
//
// Every mutation here claims to register undo in its doc comment, so every
// test asserts the undo AND the redo: a one-way undo that leaves the row in
// a third state is the failure mode a "does it apply?" test cannot see.
//
// KPriority and KEffort both have a `.none` case, so `x?.effort == .none`
// resolves `.none` as `Optional.none` and passes for ANY value. Unwrap with
// #require and spell the enum (`KEffort.none`) wherever one appears.

import Testing
import Foundation
@testable import KronosCore

@MainActor
struct Rev4StoreTests {

    private func makeStore() throws -> (TaskStore, any TaskStoring) {
        let s = try TaskStore(inMemory: true)
        return (s, s)
    }

    // MARK: - Areas

    @Test func allAreasIncludesAreasWithoutProjects() throws {
        let (_, store) = try makeStore()
        // Reaching areas through allProjects() made an empty area invisible,
        // so a freshly created one could not be picked as a project's parent.
        let empty = store.createArea(name: "Prazno područje", colorHex: "#8B8B93",
                                     icon: "square.grid.2x2")
        let populated = store.createArea(name: "Klijenti", colorHex: "#8224E3", icon: "person")
        store.createProject(name: "Acme", colorHex: "#8224E3", icon: "circle", area: populated)

        let names = store.allAreas().map(\.name)
        #expect(names.contains("Prazno područje"))
        #expect(names.contains("Klijenti"))
        #expect(store.allAreas().count == 2)
        #expect((empty.projects ?? []).isEmpty)
    }

    @Test func createAreaIsUndoableAndRedoable() throws {
        let (concrete, store) = try makeStore()
        let depth = concrete.undoDepth
        store.createArea(name: "Greška", colorHex: "#8B8B93", icon: "square.grid.2x2")
        #expect(store.allAreas().count == 1)
        #expect(concrete.undoDepth == depth + 1)

        store.undo()
        #expect(store.allAreas().isEmpty)
        store.redo()
        #expect(store.allAreas().count == 1)
    }

    @Test func renameAndRestyleAreaAreUndoable() throws {
        let (_, store) = try makeStore()
        let a = store.createArea(name: "Staro ime", colorHex: "#8B8B93", icon: "square.grid.2x2")

        store.renameArea(a.id, name: "Novo ime")
        #expect(a.name == "Novo ime")
        store.undo()
        #expect(a.name == "Staro ime")
        store.redo()
        #expect(a.name == "Novo ime")

        store.updateArea(a.id, colorHex: "#8224E3", icon: "person")
        #expect(a.colorHex == "#8224E3")
        #expect(a.icon == "person")
        store.undo()
        // One step covers BOTH fields: a half-reverted area is the bug.
        #expect(a.colorHex == "#8B8B93")
        #expect(a.icon == "square.grid.2x2")
    }

    // MARK: - Projects

    @Test func archiveAndRestoreProjectIsUndoable() throws {
        let (concrete, store) = try makeStore()
        let p = store.createProject(name: "Gotov projekt", colorHex: "#8224E3",
                                    icon: "circle", area: nil)
        let t = store.create(title: "Zadatak u projektu", notes: "", project: p,
                             status: .todo, priority: .none, dueDay: nil)
        #expect(store.allProjects().count == 1)

        let depth = concrete.undoDepth
        store.archiveProject(p.id)
        #expect(p.isArchived)
        // The mirror #Predicate reads must follow, or a filter keeps showing
        // rows from a project the sidebar has hidden.
        #expect(store.task(t.id)?.isProjectArchived == true)
        #expect(store.allProjects().isEmpty)
        #expect(store.allProjects(includeArchived: true).count == 1)
        // Project + its task collapse into ONE step, not two.
        #expect(concrete.undoDepth == depth + 1)

        store.undo()
        #expect(p.isArchived == false)
        #expect(store.task(t.id)?.isProjectArchived == false)
        #expect(store.allProjects().count == 1)

        store.redo()
        #expect(p.isArchived)
        #expect(store.task(t.id)?.isProjectArchived == true)

        store.restoreProject(p.id)
        #expect(p.isArchived == false)
        #expect(store.task(t.id)?.isProjectArchived == false)
        store.undo()
        #expect(p.isArchived)
    }

    @Test func renameProjectIsUndoable() throws {
        let (concrete, store) = try makeStore()
        let p = store.createProject(name: "Staro", colorHex: "#8224E3", icon: "circle", area: nil)

        let depth = concrete.undoDepth
        store.updateProject(p.id, name: "Novo", colorHex: nil, icon: nil, emoji: nil)
        #expect(p.name == "Novo")
        // Renaming without Cmd-Z is below the bar, so this registers an undo step.
        #expect(concrete.undoDepth == depth + 1)

        store.undo()
        #expect(p.name == "Staro")
        store.redo()
        #expect(p.name == "Novo")

        // A no-op edit must not push a step the user would have to press
        // Cmd-Z twice to get past.
        let quiet = concrete.undoDepth
        store.updateProject(p.id, name: "Novo", colorHex: nil, icon: nil, emoji: nil)
        #expect(concrete.undoDepth == quiet)
    }

    @Test func moveProjectBetweenAreasIsUndoable() throws {
        let (concrete, store) = try makeStore()
        let from = store.createArea(name: "Odakle", colorHex: "#8B8B93", icon: "square.grid.2x2")
        let to = store.createArea(name: "Kamo", colorHex: "#8224E3", icon: "person")
        let p = store.createProject(name: "Selidba", colorHex: "#8224E3",
                                    icon: "circle", area: from)
        let t = store.create(title: "Zadatak", notes: "", project: p,
                             status: .todo, priority: .none, dueDay: nil)

        let depth = concrete.undoDepth
        store.moveProject(p.id, toArea: to)
        #expect(p.area?.id == to.id)
        #expect(store.task(t.id)?.areaID == to.id)
        #expect(concrete.undoDepth == depth + 1)

        store.undo()
        #expect(p.area?.id == from.id)
        #expect(store.task(t.id)?.areaID == from.id)

        store.redo()
        #expect(p.area?.id == to.id)
        #expect(store.task(t.id)?.areaID == to.id)

        // nil means "no area", not "leave it alone".
        store.moveProject(p.id, toArea: nil)
        #expect(p.area == nil)
        #expect(store.task(t.id)?.areaID == nil)
        store.undo()
        #expect(p.area?.id == to.id)
    }

    @Test func reorderProjectPlacesItBeforeTheTarget() throws {
        let (_, store) = try makeStore()
        let area = store.createArea(name: "A", colorHex: "#8B8B93", icon: "square.grid.2x2")
        let first = store.createProject(name: "Prvi", colorHex: "#8224E3", icon: "circle", area: area)
        let second = store.createProject(name: "Drugi", colorHex: "#8224E3", icon: "circle", area: area)
        let third = store.createProject(name: "Treći", colorHex: "#8224E3", icon: "circle", area: area)
        #expect(store.allProjects().map(\.name) == ["Prvi", "Drugi", "Treći"])

        store.reorderProject(third.id, before: second.id)
        #expect(store.allProjects().map(\.name) == ["Prvi", "Treći", "Drugi"])

        store.undo()
        #expect(store.allProjects().map(\.name) == ["Prvi", "Drugi", "Treći"])

        // nil target appends.
        store.reorderProject(first.id, before: nil)
        #expect(store.allProjects().map(\.name) == ["Drugi", "Treći", "Prvi"])
    }

    // MARK: - Saved views

    @Test func savedViewCRUDRoundTripsThroughStore() throws {
        let (_, store) = try makeStore()
        #expect(store.allSavedViews().isEmpty)

        var filter = KFilter()
        filter.priorities = [KPriority.high.rawValue]
        filter.text = "đakovo"
        let view = store.createSavedView(name: "Hitno", filter: filter,
                                         sort: [.desc(.priority)], showDone: false)
        #expect(store.allSavedViews().count == 1)
        #expect(view.filter.priorities == [KPriority.high.rawValue])
        #expect(view.filter.text == "đakovo")
        #expect(view.sortDescriptors == [.desc(.priority)])
        #expect(view.showDone == false)

        // Each parameter is independently optional: renaming must not reset
        // the filter a user spent time building.
        store.updateSavedView(view.id, name: "Hitno danas", filter: nil,
                              sort: nil, showDone: nil)
        #expect(view.name == "Hitno danas")
        #expect(view.filter.priorities == [KPriority.high.rawValue])
        #expect(view.filter.text == "đakovo")

        var widened = filter
        widened.priorities = [KPriority.high.rawValue, KPriority.urgent.rawValue]
        store.updateSavedView(view.id, name: nil, filter: widened, sort: nil, showDone: true)
        #expect(view.name == "Hitno danas")
        #expect(view.filter.priorities.count == 2)
        #expect(view.showDone)

        store.undo()
        #expect(view.filter.priorities == [KPriority.high.rawValue])
        #expect(view.showDone == false)
        store.redo()
        #expect(view.filter.priorities.count == 2)

        store.deleteSavedView(view.id)
        #expect(store.allSavedViews().isEmpty)
        store.undo()
        #expect(store.allSavedViews().count == 1)
        #expect(store.allSavedViews().first?.name == "Hitno danas")
    }

    @Test func reorderSavedViewPlacesItBeforeTheTarget() throws {
        let (_, store) = try makeStore()
        let a = store.createSavedView(name: "A", filter: .empty, sort: [], showDone: false)
        let b = store.createSavedView(name: "B", filter: .empty, sort: [], showDone: false)
        store.createSavedView(name: "C", filter: .empty, sort: [], showDone: false)
        #expect(store.allSavedViews().map(\.name) == ["A", "B", "C"])

        store.reorderSavedView(a.id, before: nil)
        #expect(store.allSavedViews().map(\.name) == ["B", "C", "A"])
        store.undo()
        #expect(store.allSavedViews().map(\.name) == ["A", "B", "C"])

        store.reorderSavedView(b.id, before: a.id)
        #expect(store.allSavedViews().map(\.name) == ["B", "A", "C"])
    }

    // MARK: - Subtasks

    @Test func reorderSubtasksPersistsOrder() throws {
        let (concrete, store) = try makeStore()
        let t = store.create(title: "Priprema", notes: "", project: nil,
                             status: .todo, priority: .none, dueDay: nil)
        let one = try #require(store.addSubtask(t.id, title: "Prvi"))
        let two = try #require(store.addSubtask(t.id, title: "Drugi"))
        let three = try #require(store.addSubtask(t.id, title: "Treći"))
        #expect(store.task(t.id)?.orderedSubtasks.map(\.title) == ["Prvi", "Drugi", "Treći"])

        store.reorderSubtask(three.id, before: one.id)
        #expect(store.task(t.id)?.orderedSubtasks.map(\.title) == ["Treći", "Prvi", "Drugi"])

        store.undo()
        #expect(store.task(t.id)?.orderedSubtasks.map(\.title) == ["Prvi", "Drugi", "Treći"])
        store.redo()
        #expect(store.task(t.id)?.orderedSubtasks.map(\.title) == ["Treći", "Prvi", "Drugi"])

        // Move into the middle: the between-index must land strictly between
        // its neighbours, not on top of one of them.
        store.reorderSubtask(two.id, before: one.id)
        #expect(store.task(t.id)?.orderedSubtasks.map(\.title) == ["Treći", "Drugi", "Prvi"])

        // nil target appends.
        store.reorderSubtask(three.id, before: nil)
        #expect(store.task(t.id)?.orderedSubtasks.map(\.title) == ["Drugi", "Prvi", "Treći"])

        // The order survives a save+refetch, not just the in-memory objects.
        concrete.saveContext()
        let refetched = try #require(store.task(t.id))
        #expect(refetched.orderedSubtasks.map(\.title) == ["Drugi", "Prvi", "Treći"])
    }

    @Test func renameAndDeleteSubtaskAreUndoable() throws {
        let (_, store) = try makeStore()
        let t = store.create(title: "Zadatak", notes: "", project: nil,
                             status: .todo, priority: .none, dueDay: nil)
        let s = try #require(store.addSubtask(t.id, title: "Krivi naslov"))

        store.renameSubtask(s.id, title: "Točan naslov")
        #expect(store.task(t.id)?.orderedSubtasks.first?.title == "Točan naslov")
        store.undo()
        #expect(store.task(t.id)?.orderedSubtasks.first?.title == "Krivi naslov")
        store.redo()
        #expect(store.task(t.id)?.orderedSubtasks.first?.title == "Točan naslov")

        let keep = try #require(store.addSubtask(t.id, title: "Ostaje"))
        store.deleteSubtask(s.id)
        #expect(store.task(t.id)?.orderedSubtasks.map(\.title) == ["Ostaje"])

        store.undo()
        // Undo must put the step back where it was, not append it.
        #expect(store.task(t.id)?.orderedSubtasks.map(\.title) == ["Točan naslov", "Ostaje"])
        store.redo()
        #expect(store.task(t.id)?.orderedSubtasks.map(\.title) == ["Ostaje"])
        _ = keep
    }

    // MARK: - Per-field setters

    @Test func inspectorSettersApplyAndUndo() throws {
        let (_, store) = try makeStore()
        let t = store.create(title: "Zadatak", notes: "", project: nil,
                             status: .todo, priority: .none, dueDay: nil)

        store.setDepth(t.id, .deep)
        store.setEstimate(t.id, minutes: 45)
        store.setDread(t.id, true)
        store.setFirstMove(t.id, "Otvori Mail i započni poruku")

        let after = try #require(store.task(t.id))
        #expect(after.depth == KDepth.deep)
        #expect(after.estimateMinutes == 45)
        #expect(after.dread)
        #expect(after.firstMove == "Otvori Mail i započni poruku")

        // A blank first move clears rather than storing "".
        store.setFirstMove(t.id, "   ")
        #expect(store.task(t.id)?.firstMove == nil)

        // Five writes were made, so unwinding is five steps deep: one undo
        // restores the previous first move, a second clears it, a third
        // undoes setDread.
        store.undo()
        #expect(store.task(t.id)?.firstMove == "Otvori Mail i započni poruku")
        store.undo()
        #expect(store.task(t.id)?.firstMove == nil)
        store.undo()
        #expect(store.task(t.id)?.dread == false)
        #expect(store.task(t.id)?.estimateMinutes == 45)
    }

    @Test func setWaitingGoesThroughSetStatusSoTheTaskLeavesOrdo() throws {
        let (_, store) = try makeStore()
        let t = store.create(title: "Jednom", notes: "", project: nil,
                             status: .todo, priority: .none, dueDay: nil)
        store.sendToOrdo(t.id, top: false)
        #expect(store.task(t.id)?.ordoIndex != nil)

        store.setWaiting(t.id, true)
        #expect(store.task(t.id)?.status == .waiting)
        // O5: a waiting task must drop out of ORDO, which writing statusRaw
        // directly would silently skip.
        #expect(store.task(t.id)?.ordoIndex == nil)

        // Off, with no due day: releases to .someday (the automatic rule), not .todo.
        store.setWaiting(t.id, false)
        #expect(store.task(t.id)?.status == .someday)
    }

    @Test func setWaitingOffWithADueDayReleasesToTodo() throws {
        let (_, store) = try makeStore()
        let t = store.create(title: "Rok", notes: "", project: nil,
                             status: .todo, priority: .none, dueDay: Day.today())
        store.setWaiting(t.id, true)
        #expect(store.task(t.id)?.status == .waiting)
        store.setWaiting(t.id, false)
        #expect(store.task(t.id)?.status == .todo)
    }

    @Test func setRecurrenceRejectsAnUnparseableRuleRatherThanStoringIt() throws {
        let (concrete, store) = try makeStore()
        let t = store.create(title: "Ponavljanje", notes: "", project: nil,
                             status: .todo, priority: .none, dueDay: Day.today())

        let valid = RecurrenceRule.daily(every: 1, anchor: .fromDueDay).wireFormat
        store.setRecurrence(t.id, valid)
        #expect(store.task(t.id)?.recurrenceRule == valid)

        // A rule the engine cannot parse would make the task silently
        // non-recurring at completion time, which reads as data loss.
        let depth = concrete.undoDepth
        store.setRecurrence(t.id, "svaki drugi utorak kad pada kiša")
        #expect(store.task(t.id)?.recurrenceRule == valid)
        #expect(concrete.undoDepth == depth)

        store.setRecurrence(t.id, nil)
        #expect(store.task(t.id)?.recurrenceRule == nil)
    }

    @Test func labelsAttachAndDetachIdempotently() throws {
        let (concrete, store) = try makeStore()
        let t = store.create(title: "Zadatak", notes: "", project: nil,
                             status: .todo, priority: .none, dueDay: nil)
        let hitno = store.label(named: "Žurno")

        store.addLabel(hitno, to: t.id)
        #expect(store.task(t.id)?.labels?.count == 1)

        // Attaching twice must not duplicate, nor push a second undo step.
        let depth = concrete.undoDepth
        store.addLabel(hitno, to: t.id)
        #expect(store.task(t.id)?.labels?.count == 1)
        #expect(concrete.undoDepth == depth)

        store.removeLabel(hitno, from: t.id)
        #expect(store.task(t.id)?.labels?.isEmpty == true)
        // The shared KLabel row survives: it is vocabulary, not this task's
        // property.
        #expect(store.label(named: "Žurno").id == hitno.id)

        store.undo()
        #expect(store.task(t.id)?.labels?.count == 1)
    }
}

// Undo for the Schema V2 columns and the step editors (mutateReversible). Every expected value
// is written out by hand.
//
// Decision recorded here: user-editable V2 fields are plannedDay (with its carryCount),
// reviewRaw, and assigneeRaw (with agentID). System/agent fields are NOT undoable and an undo
// must never rewind them: triageFilledFieldsRaw, lockedFieldsRaw, contextJSON, resultJSON,
// triageLeaseOwner, triageLeaseUntil.

import Testing
import Foundation
@testable import KronosCore

@MainActor
@Suite struct UndoV2Fields {

    // MARK: Diff table

    @Test func eachUserEditableV2FieldIsReportedAlone() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.create(title: "Probe")
        let table: [(String, (KTask) -> Void, TaskStore.TaskField)] = [
            ("plannedDay", { $0.plannedDay = 20_100 }, .planned),
            ("carryCount", { $0.carryCount = 2 }, .planned),
            ("reviewRaw", { $0.reviewRaw = 2 }, .review),
            ("assigneeRaw", { $0.assigneeRaw = 1 }, .assignee),
            ("agentID", { $0.agentID = UUID() }, .assignee),
        ]
        for (name, mutate, field) in table {
            let before = TaskStore.TaskSnapshot(t)
            mutate(t)
            let changed = TaskStore.TaskSnapshot(t).changedFields(from: before)
            #expect(changed == [field], "\(name): \(changed)")
        }
    }

    @Test func systemV2FieldsAreNotPartOfTheSnapshot() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.create(title: "Probe")
        let table: [(String, (KTask) -> Void)] = [
            ("triageFilledFieldsRaw", { $0.triageFilledFieldsRaw = "priority" }),
            ("lockedFieldsRaw", { $0.lockedFieldsRaw = "priority" }),
            ("contextJSON", { $0.contextJSON = "{\"k\":1}" }),
            ("resultJSON", { $0.resultJSON = "{\"r\":1}" }),
            ("triageLeaseOwner", { $0.triageLeaseOwner = "mac" }),
            ("triageLeaseUntil", { $0.triageLeaseUntil = Date(timeIntervalSince1970: 9) }),
        ]
        for (name, mutate) in table {
            let before = TaskStore.TaskSnapshot(t)
            mutate(t)
            #expect(TaskStore.TaskSnapshot(t).changedFields(from: before).isEmpty, "\(name) must stay outside undo")
        }
    }

    // MARK: plannedDay through the store

    @Test func plannedDayWritePushesOneStepBumpsUpdatedAtAndUndoesRedoes() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.create(title: "Plan me")
        let depth = store.undoDepth
        let stamp = store.task(t.id)!.updatedAt
        Thread.sleep(forTimeInterval: 0.01)

        store.update(t.id) { $0.plannedDay = 20_200 }
        #expect(store.undoDepth == depth + 1, "one step")
        #expect(store.task(t.id)!.updatedAt > stamp, "updatedAt bumped")
        #expect(store.task(t.id)?.plannedDay == 20_200)

        store.undo()
        #expect(store.task(t.id)?.plannedDay == nil)
        store.redo()
        #expect(store.task(t.id)?.plannedDay == 20_200)
    }

    @Test func replanUndoRestoresPlannedDayAndCarryCountTogether() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.create(title: "Carry")
        store.updateNoUndo(t.id) { $0.plannedDay = 20_000; $0.carryCount = 3 }
        store.update(t.id) { $0.plannedDay = 20_005; $0.carryCount = 0 }
        store.undo()
        #expect(store.task(t.id)?.plannedDay == 20_000)
        #expect(store.task(t.id)?.carryCount == 3)
    }

    @Test func samePlannedDayPushesNothingAndKeepsRedo() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.create(title: "Plan me")
        store.update(t.id) { $0.plannedDay = 20_200 }
        store.setPriority(t.id, .high)
        store.undo()                                          // redo is pending
        let stamp = store.task(t.id)!.updatedAt
        let depth = store.undoDepth
        store.update(t.id) { $0.plannedDay = 20_200 }         // same value
        #expect(store.undoDepth == depth, "no-op: no step")
        #expect(store.task(t.id)!.updatedAt == stamp, "no-op: updatedAt not bumped")
        #expect(store.canRedo, "no-op keeps the redo stack")
    }

    @Test func reviewAndAssigneeUndo() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.create(title: "Agent job")
        let agent = UUID()
        store.update(t.id) { $0.reviewRaw = 2; $0.assigneeRaw = 1; $0.agentID = agent }
        store.undo()
        #expect(store.task(t.id)?.reviewRaw == 0)
        #expect(store.task(t.id)?.assigneeRaw == 0)
        #expect(store.task(t.id)?.agentID == nil)
        store.redo()
        #expect(store.task(t.id)?.reviewRaw == 2)
        #expect(store.task(t.id)?.assigneeRaw == 1)
        #expect(store.task(t.id)?.agentID == agent)
    }

    @Test func machineWritesToSystemFieldsSurviveUndoOfAPlannedDayStep() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.create(title: "Plan me")
        store.update(t.id) { $0.plannedDay = 20_200 }
        store.updateNoUndo(t.id) {
            $0.contextJSON = "{\"c\":1}"; $0.resultJSON = "{\"r\":2}"
            $0.lockedFieldsRaw = "priority"; $0.triageLeaseOwner = "mcp"
        }
        store.undo()
        #expect(store.task(t.id)?.plannedDay == nil, "the user's step is undone")
        #expect(store.task(t.id)?.contextJSON == "{\"c\":1}")
        #expect(store.task(t.id)?.resultJSON == "{\"r\":2}")
        #expect(store.task(t.id)?.lockedFieldsRaw == "priority")
        #expect(store.task(t.id)?.triageLeaseOwner == "mcp")
    }

    /// Positive control: an edit that touches ONLY a system field pushes no step (so the
    /// "stays outside undo" claim is observable), while a planned-day edit does.
    @Test func systemFieldOnlyWritePushesNoStepButPlannedDayDoes() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.create(title: "Probe")
        let depth = store.undoDepth
        store.update(t.id) { $0.resultJSON = "{}" }
        #expect(store.undoDepth == depth)
        store.update(t.id) { $0.plannedDay = 1 }
        #expect(store.undoDepth == depth + 1)
    }

    // MARK: mutateReversible (step editors)

    private func makeStep(_ store: TaskStore) throws -> (parent: KTask, step: KTask) {
        let parent = store.create(title: "Parent")
        let step = try #require(store.addSubtask(parent.id, title: "Step"))
        return (parent, step)
    }

    @Test func stepNoOpPushesNothingKeepsRedoAndUpdatedAt() throws {
        let store = try TaskStore(inMemory: true)
        let (_, step) = try makeStep(store)
        store.renameSubtask(step.id, title: "Step B")
        store.undo()                                          // pending redo
        let stamp = store.task(step.id)!.updatedAt
        let depth = store.undoDepth

        store.mutateReversible("Probe", step.id) { $0.title = $0.title }   // changes nothing
        #expect(store.undoDepth == depth, "no-op: no step")
        #expect(store.task(step.id)!.updatedAt == stamp, "no-op: updatedAt not bumped")
        #expect(store.canRedo, "no-op keeps the redo stack")
    }

    @Test func stepRealChangePushesOneStepAndBumpsUpdatedAt() throws {
        let store = try TaskStore(inMemory: true)
        let (_, step) = try makeStep(store)
        let depth = store.undoDepth
        let stamp = store.task(step.id)!.updatedAt
        Thread.sleep(forTimeInterval: 0.01)
        store.renameSubtask(step.id, title: "Step B")
        #expect(store.undoDepth == depth + 1)
        #expect(store.task(step.id)!.updatedAt > stamp)
    }

    @Test func machineWriteSurvivesUndoAndRedoOfAStepRename() throws {
        let store = try TaskStore(inMemory: true)
        let (_, step) = try makeStep(store)
        store.renameSubtask(step.id, title: "Step B")
        store.updateNoUndo(step.id) { $0.notes = "from claude"; $0.firstMove = "open it" }

        store.undo()
        #expect(store.task(step.id)?.title == "Step")
        #expect(store.task(step.id)?.notes == "from claude", "MCP write survives Cmd-Z")
        #expect(store.task(step.id)?.firstMove == "open it")

        store.redo()
        #expect(store.task(step.id)?.title == "Step B")
        #expect(store.task(step.id)?.notes == "from claude", "and survives redo")

        // The re-armed undo still works (the step editors rely on alternating).
        store.undo()
        #expect(store.task(step.id)?.title == "Step")
        #expect(store.task(step.id)?.notes == "from claude")
    }

    @Test func stepPlannedDayUndoLeavesMachineFields() throws {
        let store = try TaskStore(inMemory: true)
        let (_, step) = try makeStep(store)
        store.mutateReversible("Plan", step.id) { $0.plannedDay = 20_300 }
        store.updateNoUndo(step.id) { $0.resultJSON = "{\"x\":1}" }
        store.undo()
        #expect(store.task(step.id)?.plannedDay == nil)
        #expect(store.task(step.id)?.resultJSON == "{\"x\":1}")
    }

    /// Positive control: the old full-snapshot apply wipes the machine write that the field-level
    /// path now keeps.
    @Test func fullSnapshotApplyWouldClobberAStepMachineWrite() throws {
        let store = try TaskStore(inMemory: true)
        let (_, step) = try makeStep(store)
        let before = TaskStore.TaskSnapshot(step)
        store.renameSubtask(step.id, title: "Step B")
        store.updateNoUndo(step.id) { $0.notes = "from claude" }
        before.apply(to: store.task(step.id)!)
        #expect(store.task(step.id)?.notes == "", "full apply clobbers: this is what changedFields/only prevents")
    }
}

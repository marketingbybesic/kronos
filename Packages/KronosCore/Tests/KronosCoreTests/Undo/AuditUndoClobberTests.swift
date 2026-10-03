// Field-level undo. Every expected value is written out by hand.
//
// The defect this pins: undo used to restore a FULL snapshot of the task, so a machine write
// (MCP, auto-triage) to another field between the user's edit and Cmd-Z was silently reverted.

import Testing
import Foundation
@testable import KronosCore

@MainActor
@Suite struct AuditUndoClobber {

    @Test func mcpWriteBetweenUserStepAndUndoSurvives() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.create(title: "Call Alex")
        store.setPriority(t.id, .high)                        // the user's step
        store.updateNoUndo(t.id) { $0.notes = "from claude" } // an MCP write, a different field
        store.updateNoUndo(t.id) { $0.firstMove = "Open the contacts" }

        store.undo()

        #expect(store.task(t.id)?.priority == KPriority.none, "the user's own step is undone")
        #expect(store.task(t.id)?.notes == "from claude", "the MCP write to another field survives Cmd-Z")
        #expect(store.task(t.id)?.firstMove == "Open the contacts")

        store.redo()
        #expect(store.task(t.id)?.priority == KPriority.high, "redo replays the step")
        #expect(store.task(t.id)?.notes == "from claude", "and still leaves the other field alone")
    }

    @Test func machineWriteToAnotherFieldSurvivesUndoOfADueDayStep() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.create(title: "Invoice")
        let today = Day.today()
        store.setDue(t.id, day: today + 2)
        store.updateNoUndo(t.id) { $0.title = "Invoice Acme" }

        store.undo()

        #expect(store.task(t.id)?.dueDay == nil)
        #expect(store.task(t.id)?.originalDueDay == nil, "originalDueDay is part of the same step")
        #expect(store.task(t.id)?.status == .todo)
        #expect(store.task(t.id)?.title == "Invoice Acme")
    }

    @Test func undoOnlyTouchesTheStepsOwnFieldsWhenTwoUserStepsStack() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.create(title: "A")
        store.setPriority(t.id, .urgent)
        store.update(t.id) { $0.notes = "n1" }
        store.undo()
        #expect(store.task(t.id)?.notes == "")
        #expect(store.task(t.id)?.priority == KPriority.urgent)
        store.undo()
        #expect(store.task(t.id)?.priority == KPriority.none)
    }

    /// Positive control: the old behaviour (apply the whole snapshot) DOES clobber the machine
    /// write, so the assertions above are able to fail.
    @Test func fullSnapshotApplyWouldClobber() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.create(title: "Call Alex")
        let before = TaskStore.TaskSnapshot(t)
        store.setPriority(t.id, .high)
        store.updateNoUndo(t.id) { $0.notes = "from claude" }
        before.apply(to: store.task(t.id)!)
        #expect(store.task(t.id)?.notes == "", "a full apply wipes the machine write: this is what the diff prevents")
    }

    /// Every snapshot field, one mutation each, mapped to the exact field the diff must report.
    @Test func eachFieldIsReportedAlone() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.create(title: "Probe")
        let table: [(String, (KTask) -> Void, TaskStore.TaskField)] = [
            ("title", { $0.title = "Probe 2" }, .title),
            ("notes", { $0.notes = "x" }, .notes),
            ("firstMove", { $0.firstMove = "go" }, .firstMove),
            ("status", { $0.statusRaw = KStatus.inProgress.rawValue }, .status),
            ("priority", { $0.priorityRaw = KPriority.high.rawValue }, .priority),
            ("depth", { $0.depthRaw = KDepth.deep.rawValue }, .depth),
            ("effort", { $0.effortRaw = KEffort.m.rawValue }, .effort),
            ("dread", { $0.dread = true }, .dread),
            ("estimate", { $0.estimateMinutes = 25 }, .estimate),
            ("dueDay", { $0.dueDay = 20_000 }, .dueDay),
            ("originalDueDay", { $0.originalDueDay = 19_999 }, .originalDueDay),
            ("sortIndex", { $0.sortIndex = 7 }, .sortIndex),
            ("ordoIndex", { $0.ordoIndex = 3 }, .ordoIndex),
            ("deletedAt", { $0.deletedAt = Date(timeIntervalSince1970: 5) }, .deletedAt),
            ("needsTriage", { $0.needsTriage.toggle() }, .needsTriage),
            ("recurrence", { $0.recurrenceRule = "FREQ=DAILY" }, .recurrence),
            ("waitsOn", { $0.waitsOnIDs = UUID().uuidString }, .waitsOn),
            ("calendarEvent", { $0.calendarEventID = "evt-1" }, .calendarEvent),
            ("origin", { $0.source = "linear" }, .origin),
            ("triage", { $0.triageFeedback = "too vague" }, .triage),
        ]
        for (name, mutate, field) in table {
            let before = TaskStore.TaskSnapshot(t)
            mutate(t)
            let changed = TaskStore.TaskSnapshot(t).changedFields(from: before)
            #expect(changed == [field], "\(name): \(changed)")
        }
        // No change at all: the empty set.
        let same = TaskStore.TaskSnapshot(t)
        #expect(TaskStore.TaskSnapshot(t).changedFields(from: same).isEmpty)
    }

    /// The fields that were missing from the old snapshot now survive undo too.
    @Test func calendarEventAndOriginAndTriageFeedbackUndo() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.create(title: "Probe")
        store.update(t.id) { $0.calendarEventID = "evt-9"; $0.externalID = "MAR-1"; $0.triageFeedback = "no" }
        store.undo()
        #expect(store.task(t.id)?.calendarEventID == nil)
        #expect(store.task(t.id)?.externalID == nil)
        #expect(store.task(t.id)?.triageFeedback == nil)
        store.redo()
        #expect(store.task(t.id)?.calendarEventID == "evt-9")
        #expect(store.task(t.id)?.externalID == "MAR-1")
        #expect(store.task(t.id)?.triageFeedback == "no")
    }
}

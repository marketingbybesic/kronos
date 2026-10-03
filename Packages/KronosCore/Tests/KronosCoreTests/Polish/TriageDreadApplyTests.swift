import Testing
import Foundation
@testable import KronosCore

/// The model's dread judgement reaches the task: set only, never cleared, inside the triage's
/// single undo step, and left alone on a task whose every field was set explicitly.
@MainActor
@Suite struct TriageDreadApplyTests {

    private func result(dread: Bool?) -> TriageResult {
        TriageResult(project: nil, priority: 2, due: nil, depth: .shallow, estimateMinutes: 15,
                     energyKind: .people, firstMove: "Open the thread with the landlord", labels: [],
                     rationale: "An owed apology.", dread: dread)
    }

    /// result.dread, task dread before, every field locked -> dread after
    private let table: [(model: Bool?, before: Bool, allLocked: Bool, after: Bool)] = [
        (true, false, false, true),     // the model says dread: set
        (true, true, false, true),      // already set: stays
        (false, true, false, true),     // "no" never clears what is there
        (nil, true, false, true),       // silence never clears
        (nil, false, false, false),     // silence never sets
        (false, false, false, false),   // "no" never sets
        (true, false, true, false),     // every field set explicitly: left as written
    ]

    @Test func dreadFollowsTheTable() throws {
        for row in table {
            let store = try TaskStore(inMemory: true)
            let t = store.create(title: "Write to the landlord")
            store.updateNoUndo(t.id) { task in
                task.dread = row.before
                if row.allLocked { task.lockedFieldsRaw = TriageFieldKind.encode(TriageFieldKind.allCases) }
            }
            store.applyTriage(result(dread: row.model), to: t.id)
            #expect(store.task(t.id)?.dread == row.after,
                    "model=\(String(describing: row.model)) before=\(row.before) locked=\(row.allLocked)")
        }
    }

    @Test func dreadIsPartOfTheOneTriageUndoStep() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.create(title: "Write to the landlord")
        let depth = store.undoDepth
        let filled = store.applyTriage(result(dread: true), to: t.id)
        #expect(store.task(t.id)?.dread == true)
        #expect(store.undoDepth == depth + 1, "one step for the whole triage")
        #expect(!filled.isEmpty, "the other fields are still reported")
        store.undo()
        #expect(store.task(t.id)?.dread == false, "one undo takes the flag back with the rest")
        #expect(store.task(t.id)?.priority == KPriority.none)
    }
}

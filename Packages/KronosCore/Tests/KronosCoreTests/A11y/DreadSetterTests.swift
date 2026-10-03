import Testing
import Foundation
@testable import KronosCore

/// Switching "avoiding it" off by hand locks the flag against triage; switching it on lifts the lock;
/// the flag is one undo step and the lock is bookkeeping.
@MainActor
@Suite struct DreadSetterTests {

    private func result(dread: Bool?) -> TriageResult {
        TriageResult(project: nil, priority: 2, due: nil, depth: .shallow, estimateMinutes: 15,
                     energyKind: .people, firstMove: "Open the thread with the landlord", labels: [],
                     rationale: "An owed apology.", dread: dread)
    }

    @Test func switchingDreadOffByHandLocksItAgainstTriage() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.create(title: "Write to the landlord")
        store.updateNoUndo(t.id) { $0.dread = true }
        store.setDread(t.id, false)
        let task = try #require(store.task(t.id))
        #expect(!task.dread)
        #expect(task.dreadLocked, "the person decided: \(task.lockedFieldsRaw)")
        store.applyTriage(result(dread: true), to: t.id)
        #expect(store.task(t.id)?.dread == false, "a later triage verdict does not switch it back on")
    }

    @Test func switchingDreadOnLiftsTheLockSoTriageMayDecideAgain() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.create(title: "Write to the landlord")
        store.updateNoUndo(t.id) { $0.dread = true }
        store.setDread(t.id, false)
        store.setDread(t.id, true)
        let task = try #require(store.task(t.id))
        #expect(task.dread && !task.dreadLocked && task.lockedFieldsRaw.isEmpty, "raw=\(task.lockedFieldsRaw)")
    }

    @Test func otherFieldLocksSurviveBothDirections() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.create(title: "Write to the landlord")
        store.updateNoUndo(t.id) { $0.dread = true }
        store.lockField(.priority, on: t.id)
        store.setDread(t.id, false)
        #expect(store.task(t.id)?.lockedFields == [.priority] && store.task(t.id)?.dreadLocked == true)
        store.setDread(t.id, true)
        #expect(store.task(t.id)?.lockedFields == [.priority] && store.task(t.id)?.dreadLocked == false)
    }

    @Test func theFlagIsOneUndoStepAndTheLockIsBookkeeping() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.create(title: "Write to the landlord")
        store.updateNoUndo(t.id) { $0.dread = true }
        let depth = store.undoDepth
        store.setDread(t.id, false)
        #expect(store.undoDepth == depth + 1, "one undo step, the lock adds none")
        store.undo()
        #expect(store.task(t.id)?.dread == true, "undo brings the flag back")
        store.redo()
        let task = try #require(store.task(t.id))
        #expect(!task.dread && task.dreadLocked, "redo: flag off, still locked")
    }
}

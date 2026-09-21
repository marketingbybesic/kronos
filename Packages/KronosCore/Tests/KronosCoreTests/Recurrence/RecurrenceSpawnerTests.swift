// rev 4: `TaskStore.complete(_:)` now spawns the successor itself, inside a
// `groupedUndo` step. These tests used to simulate that integration by
// calling `complete()` and then `RecurrenceSpawner.spawnNext(...)` by hand —
// which, now that `complete` does it, would spawn a SECOND sibling. The
// manual call is therefore gone from each one; what they assert is unchanged
// and now exercises the real production path instead of a stand-in for it.

import Testing
import Foundation
@testable import KronosCore

@MainActor
private func makeStore() throws -> TaskStore { try TaskStore(inMemory: true) }

/// The task's live successor: the other row in the same series.
@MainActor
private func successor(of id: UUID, in store: TaskStore) -> KTask? {
    store.allTasks().first { $0.id != id }
}

@Test @MainActor func completingSpawnsExactlyOneNextInstance() throws {
    let store = try makeStore()
    let today = Day.today()
    let t = store.create(title: "Izdati račune", dueDay: today)
    store.update(t.id) {
        $0.recurrenceRule = RecurrenceRule.monthly(every: 1, day: 1, anchor: .fromDueDay).wireFormat
    }

    let before = store.allTasks().count
    store.complete(t.id)
    let after = store.allTasks()

    #expect(after.count == before + 1)
    let spawned = after.first { $0.id != t.id }
    #expect(spawned?.title == "Izdati račune")
    #expect(spawned?.statusRaw == 0) // KStatus's open/unstarted case
    #expect(spawned?.completedAt == nil)
    #expect(spawned?.seriesID == t.seriesID)
    #expect(spawned?.seriesID != nil)
}

@Test @MainActor func spawnedInstanceCopiesPriorityAndEffort() throws {
    // KPriority and KEffort both have a case named `.none`, which makes
    // `x?.priority == .none` resolve as `Optional.none` and pass for ANY
    // value if `x` isn't unwrapped first. Unwrap with #require and assert
    // NON-none values so this test can actually fail.
    let store = try makeStore()
    let today = Day.today()
    let t = store.create(title: "Quarterly review", dueDay: today)
    store.update(t.id) {
        $0.recurrenceRule = RecurrenceRule.monthly(every: 1, day: 1, anchor: .fromDueDay).wireFormat
    }
    store.setPriority(t.id, .high)
    store.setEffort(t.id, .l)

    store.complete(t.id)
    let spawned = try #require(successor(of: t.id, in: store))

    #expect(spawned.priority == KPriority.high)
    #expect(spawned.effort == KEffort.l)
}

@Test @MainActor func spawnedInstanceDoesNotCopyOrdoOrCompletionState() throws {
    let store = try makeStore()
    let today = Day.today()
    let t = store.create(title: "Weekly report", dueDay: today)
    store.update(t.id) {
        $0.recurrenceRule = RecurrenceRule.weekly(every: 1, weekdays: [5], anchor: .fromDueDay).wireFormat
        $0.calendarEventID = "abc123"
    }
    store.sendToOrdo(t.id, top: true)

    store.complete(t.id)
    let spawned = successor(of: t.id, in: store)

    #expect(spawned?.ordoIndex == nil)
    #expect(spawned?.calendarEventID == nil)
    #expect(spawned?.needsTriage == false)
}

@Test @MainActor func spawnedSubtasksAreResetToNotDone() throws {
    let store = try makeStore()
    let today = Day.today()
    let t = store.create(title: "Prep invoices", dueDay: today)
    store.update(t.id) {
        $0.recurrenceRule = RecurrenceRule.daily(every: 1, anchor: .fromDueDay).wireFormat
    }
    let sub = store.addSubtask(t.id, title: "Gather receipts")
    store.toggleSubtask(sub!.id) // mark done on the original

    store.complete(t.id)
    let spawned = successor(of: t.id, in: store)

    #expect(spawned?.orderedSubtasks.count == 1)
    #expect(spawned?.orderedSubtasks.first?.isDone == false)
    #expect(spawned?.orderedSubtasks.first?.title == "Gather receipts")
}

@Test @MainActor func nonRecurringTaskSpawnsNothing() throws {
    let store = try makeStore()
    let t = store.create(title: "one off", dueDay: Day.today())
    store.complete(t.id)
    #expect(successor(of: t.id, in: store) == nil)
    #expect(store.allTasks().count == 1)
}

@Test @MainActor func undoOfCompletionRemovesTheSpawnedInstance() throws {
    let store = try makeStore()
    let today = Day.today()
    let t = store.create(title: "Izdati račune", dueDay: today)
    store.update(t.id) {
        $0.recurrenceRule = RecurrenceRule.monthly(every: 1, day: 1, anchor: .fromDueDay).wireFormat
    }
    let countBefore = store.allTasks().count

    // rev 4: `complete()` spawns the successor inside its own grouped-undo
    // step, so ONE undo() reverses both the completion and the spawn.
    store.complete(t.id)
    let spawned = successor(of: t.id, in: store)
    #expect(spawned != nil)
    #expect(store.allTasks().count == countBefore + 1)

    store.undo()

    let after = store.allTasks()
    #expect(after.count == countBefore)
    #expect(after.contains { $0.id == t.id })
    #expect(!after.contains { $0.id == spawned!.id })
    #expect(store.task(t.id)?.statusRaw == 0) // KStatus's open/unstarted case
    #expect(store.task(t.id)?.completedAt == nil)
}

@Test @MainActor func redoAfterUndoReplaysBothCompletionAndSpawn() throws {
    let store = try makeStore()
    let today = Day.today()
    let t = store.create(title: "Weekly client report", dueDay: today)
    store.update(t.id) {
        $0.recurrenceRule = RecurrenceRule.weekly(every: 1, weekdays: [1], anchor: .fromDueDay).wireFormat
    }
    let countBefore = store.allTasks().count

    store.complete(t.id)
    store.undo()
    #expect(store.allTasks().count == countBefore)

    store.redo()

    #expect(store.task(t.id)?.status == .done)
    #expect(store.allTasks().count == countBefore + 1)
    #expect(store.allTasks().contains { $0.title == "Weekly client report" && $0.id != t.id })
}

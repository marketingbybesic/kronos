import Testing
import Foundation
@testable import KronosCore

/// subtask -> task (promote) and task -> subtask (nest, with flatten).
@MainActor
@Suite("SubtaskConversionTests")
struct SubtaskConversionTests {

    private static let notesWithLinks = "Ask for the IBAN\nlink://web|Example|https://example.com"

    // MARK: - Promote

    @Test func promoteKeepsTitleDoneDueNotesAndPriority() throws {
        let store = try TaskStore(inMemory: true)
        let parent = store.createNoUndo(title: "Parent")
        let s = try #require(store.addSubtaskNoUndo(parent.id, title: "Call the bank",
                                                    dueDay: SubtaskFixture.day("2026-10-15"), priority: .high))
        s.isDone = true
        s.notes = Self.notesWithLinks
        let subID = s.id

        let t = try #require(store.promoteSubtaskToTask(subID))

        #expect(t.title == "Call the bank")
        #expect(t.status == .done)
        #expect(SubtaskFixture.iso(t.dueDay) == "2026-10-15")
        #expect(t.priorityRaw == 3)
        #expect(t.notes == Self.notesWithLinks)
        // the subtask row is gone, the parent is untouched
        #expect(store.subtask(subID) == nil)
        #expect((store.task(parent.id)?.children ?? []).isEmpty)
        #expect(store.allTasks().count == 2)
    }

    @Test func promoteOfAnOpenUndatedStepGivesAnOpenUndatedTask() throws {
        let store = try TaskStore(inMemory: true)
        let parent = store.createNoUndo(title: "Parent")
        let s = try #require(store.addSubtaskNoUndo(parent.id, title: "Loose end"))
        let t = try #require(store.promoteSubtaskToTask(s.id))
        #expect(t.status == .todo)
        #expect(t.dueDay == nil)
        #expect(t.priorityRaw == 0)
        #expect(t.completedAt == nil)
    }

    @Test func promoteLandsInTheParentsProject() throws {
        let store = try TaskStore(inMemory: true)
        let project = store.createProject(name: "Home")
        let parent = store.createNoUndo(title: "Parent", project: project)
        let s = try #require(store.addSubtaskNoUndo(parent.id, title: "Buy paint"))
        let t = try #require(store.promoteSubtaskToTask(s.id))
        #expect(t.projectID == project.id)
    }

    @Test func promoteOfAMissingSubtaskDoesNothing() throws {
        let store = try TaskStore(inMemory: true)
        store.createNoUndo(title: "Only")
        let depth = store.undoDepth
        #expect(store.promoteSubtaskToTask(UUID()) == nil)
        #expect(store.undoDepth == depth)
    }

    // MARK: - Nest

    @Test func nestKeepsTitleDoneDueNotesAndPriority() throws {
        let store = try TaskStore(inMemory: true)
        let parent = store.createNoUndo(title: "Parent")
        let child = store.createNoUndo(title: "Renew passport", notes: Self.notesWithLinks, status: .done,
                                       priority: .urgent, dueDay: SubtaskFixture.day("2026-12-01"))

        try store.makeTaskSubtaskOf(child.id, parentID: parent.id)

        let subs = try #require(store.task(parent.id)).orderedSubtasks
        #expect(subs.count == 1)
        let s = subs[0]
        #expect(s.title == "Renew passport")
        #expect(s.isDone == true)
        #expect(SubtaskFixture.iso(s.dueDay) == "2026-12-01")
        #expect(s.priorityRaw == 4)
        #expect(s.notes == Self.notesWithLinks)
        // Subtasks are tasks: the SAME row (same id) now has a parent; lists show only the parent.
        #expect(s.id == child.id)
        #expect(store.task(child.id)?.parentID == parent.id)
        #expect(store.allTasks().count == 1)
    }

    @Test func nestFlattensTheTasksSubtasksUnderTheNewParentInOrder() throws {
        let store = try TaskStore(inMemory: true)
        let parent = store.createNoUndo(title: "Parent")
        let p1 = try #require(store.addSubtaskNoUndo(parent.id, title: "p1"))
        let child = store.createNoUndo(title: "Child")
        let a1 = try #require(store.addSubtaskNoUndo(child.id, title: "a1", dueDay: SubtaskFixture.day("2026-10-20"), priority: .low))
        let a2 = try #require(store.addSubtaskNoUndo(child.id, title: "a2"))
        a2.isDone = true
        let a3 = try #require(store.addSubtaskNoUndo(child.id, title: "a3"))
        let (p1ID, a1ID, a2ID, a3ID) = (p1.id, a1.id, a2.id, a3.id)

        try store.makeTaskSubtaskOf(child.id, parentID: parent.id)

        let subs = try #require(store.task(parent.id)).orderedSubtasks
        // existing step first, then the nested task, then its former steps in their old order
        #expect(subs.map(\.title) == ["p1", "Child", "a1", "a2", "a3"])
        #expect(subs[0].id == p1ID)
        // the former steps keep their identity and their own fields
        #expect(subs[2].id == a1ID)
        #expect(SubtaskFixture.iso(subs[2].dueDay) == "2026-10-20")
        #expect(subs[2].priorityRaw == 1)
        #expect(subs[3].id == a2ID)
        #expect(subs[3].isDone == true)
        #expect(subs[4].id == a3ID)
        // one level only: every subtask hangs off Parent, the nested task kept nothing
        #expect(SubtaskFixture.subtaskCount(store) == 5)
        #expect(subs.allSatisfy { $0.parentID == parent.id })
        #expect(store.task(child.id)?.orderedChildren.isEmpty == true)
    }

    /// CHANGED EXPECTATION (subtasks became tasks): nesting used to delete the task row, so
    /// references to it were removed. The row now keeps its id, so a dependency on it stays valid
    /// and is KEPT.
    @Test func nestKeepsWaitsOnReferencesToTheNestedTask() throws {
        let store = try TaskStore(inMemory: true)
        let parent = store.createNoUndo(title: "Parent")
        let child = store.createNoUndo(title: "Child")
        let other = store.createNoUndo(title: "Other")
        let waiter = store.createNoUndo(title: "Waiter")
        let waiterID = waiter.id
        let (childID, otherID) = (child.id, other.id)
        waiter.waitsOnIDs = "\(childID.uuidString),\(otherID.uuidString)"

        try store.makeTaskSubtaskOf(childID, parentID: parent.id)

        #expect(store.task(waiterID)?.waitsOn == [childID, otherID])
    }
}

import Testing
import Foundation
@testable import KronosCore

/// Which task the inspector (and every action in it) targets. Expectations are hand-written.
@MainActor
@Suite("InspectedTaskTests")
struct InspectedTaskTests {

    @Test func noSelectionResolvesToNothing() throws {
        #expect(InspectedTask.resolve(selected: nil, inspectedChildID: nil) == nil)
        #expect(InspectedTask.resolve(selected: nil, inspectedChildID: UUID()) == nil)
    }

    @Test func aSelectedTaskWithoutChildModeIsItself() throws {
        let store = try TaskStore(inMemory: true)
        let p = store.createNoUndo(title: "P")
        _ = try #require(store.addSubtaskNoUndo(p.id, title: "c"))
        #expect(InspectedTask.resolve(selected: p, inspectedChildID: nil)?.title == "P")
    }

    @Test func childModeResolvesToTheChildNotTheParent() throws {
        let store = try TaskStore(inMemory: true)
        let p = store.createNoUndo(title: "P")
        let a = try #require(store.addSubtaskNoUndo(p.id, title: "a"))
        let b = try #require(store.addSubtaskNoUndo(p.id, title: "b"))
        #expect(InspectedTask.resolve(selected: p, inspectedChildID: b.id)?.title == "b")
        #expect(InspectedTask.resolve(selected: p, inspectedChildID: a.id)?.title == "a")
        // positive control: the parent is a different task from the resolved child
        #expect(InspectedTask.resolve(selected: p, inspectedChildID: b.id)?.id != p.id)
    }

    @Test func aStaleChildFallsBackToTheSelectedTask() throws {
        let store = try TaskStore(inMemory: true)
        let p = store.createNoUndo(title: "P")
        let other = store.createNoUndo(title: "Other")
        let foreign = try #require(store.addSubtaskNoUndo(other.id, title: "foreign"))
        let gone = try #require(store.addSubtaskNoUndo(p.id, title: "gone"))
        store.deleteSubtask(gone.id)
        #expect(InspectedTask.resolve(selected: p, inspectedChildID: foreign.id)?.title == "P", "a child of another task is not shown")
        #expect(InspectedTask.resolve(selected: p, inspectedChildID: gone.id)?.title == "P", "a deleted child is not shown")
        #expect(InspectedTask.resolve(selected: p, inspectedChildID: UUID())?.title == "P")
    }

    @Test func aDeletedSelectionResolvesToNothing() throws {
        let store = try TaskStore(inMemory: true)
        let p = store.createNoUndo(title: "P")
        let c = try #require(store.addSubtaskNoUndo(p.id, title: "c"))
        store.softDeleteNoUndo(p.id)
        #expect(InspectedTask.resolve(selected: p, inspectedChildID: c.id) == nil)
    }
}

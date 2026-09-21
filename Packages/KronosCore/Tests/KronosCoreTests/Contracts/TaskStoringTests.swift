import Testing
import Foundation
@testable import KronosCore

/// `TaskStore` is the contract's only implementation, and the `…NoUndo`
/// variants are the half a consumer leaf can get wrong silently: they must
/// perform exactly the same write and leave the user's undo history alone.
@MainActor
struct TaskStoringTests {

    /// Exercised through the protocol existential on purpose: if a method is
    /// declared on TaskStore but missing from TaskStoring, this stops compiling.
    private func makeStore() throws -> (TaskStore, any TaskStoring) {
        let s = try TaskStore(inMemory: true)
        return (s, s)
    }

    @Test func taskStoreIsReachableThroughTheProtocol() throws {
        let (concrete, store) = try makeStore()
        let t = store.create(title: "Nazvati Karla", notes: "", project: nil,
                             status: .todo, priority: .high, dueDay: Day.today())
        #expect(store.allTasks().count == 1)
        #expect(store.task(t.id)?.title == "Nazvati Karla")
        #expect(concrete.canUndo)
    }

    @Test func undoableCompleteIsReversible() throws {
        let (_, store) = try makeStore()
        let t = store.create(title: "T", notes: "", project: nil,
                             status: .todo, priority: .none, dueDay: nil)
        store.complete(t.id)
        #expect(store.task(t.id)?.status == .done)

        store.undo()
        // G17: a completion is reversible inside the undo window.
        #expect(store.task(t.id)?.status == .todo)
        #expect(store.task(t.id)?.completedAt == nil)

        store.redo()
        #expect(store.task(t.id)?.status == .done)
    }

    @Test func noUndoWritesApplyButLeaveTheUndoStackUntouched() throws {
        let (concrete, store) = try makeStore()
        let mine = store.create(title: "My task", notes: "", project: nil,
                                status: .todo, priority: .none, dueDay: nil)
        let depthAfterUserAction = concrete.undoDepth

        // An MCP client writes several rows.
        let theirs = store.createNoUndo(title: "From MCP", notes: "", project: nil,
                                        status: .todo, priority: .high, dueDay: nil)
        store.completeNoUndo(theirs.id)
        store.updateNoUndo(theirs.id) { $0.notes = "machine written" }

        // The writes landed.
        #expect(store.task(theirs.id)?.status == .done)
        #expect(store.task(theirs.id)?.notes == "machine written")
        #expect(store.task(theirs.id)?.priority == .high)

        // ...and the user's own last action is still what Cmd-Z reverses,
        // rather than being buried under three machine edits.
        #expect(concrete.undoDepth == depthAfterUserAction)
        store.undo()
        #expect(store.task(mine.id) == nil)
    }

    @Test func noUndoWritesDoNotClearAPendingRedo() throws {
        let (concrete, store) = try makeStore()
        let t = store.create(title: "T", notes: "", project: nil,
                             status: .todo, priority: .none, dueDay: nil)
        store.setPriority(t.id, .high)
        store.undo()
        #expect(concrete.canRedo)

        store.updateNoUndo(t.id) { $0.notes = "mcp" }

        // A machine write is not a user action, so it must not destroy the
        // redo the user is one keystroke away from.
        #expect(concrete.canRedo)
        store.redo()
        #expect(store.task(t.id)?.priority == .high)
    }

    @Test func noUndoVariantsMatchTheirUndoableTwins() throws {
        let (_, store) = try makeStore()
        let a = store.create(title: "A", notes: "", project: nil,
                             status: .todo, priority: .none, dueDay: nil)
        let b = store.createNoUndo(title: "B", notes: "", project: nil,
                                   status: .todo, priority: .none, dueDay: nil)

        store.softDelete(a.id)
        store.softDeleteNoUndo(b.id)
        #expect(store.allTasks().isEmpty)
        #expect(store.allTasksIncludingDeleted().count == 2)

        store.restore(a.id)
        store.restoreNoUndo(b.id)
        #expect(store.allTasks().count == 2)

        store.sendToOrdo(a.id, top: false)
        store.sendToOrdoNoUndo(b.id, top: true)
        // top:true must land ahead of the appended row.
        #expect(store.task(b.id)!.ordoIndex! < store.task(a.id)!.ordoIndex!)

        store.setStatusNoUndo(a.id, .waiting)
        // O4: waiting leaves ORDO.
        #expect(store.task(a.id)?.ordoIndex == nil)
    }

    @Test func toggleSubtaskNoUndoIsIdempotentWhenGivenAnExplicitValue() throws {
        let (_, store) = try makeStore()
        let t = store.create(title: "T", notes: "", project: nil,
                             status: .todo, priority: .none, dueDay: nil)
        let s = try #require(store.addSubtaskNoUndo(t.id, title: "Step one"))
        #expect(s.isDone == false)

        // A client retrying the same call must not flip the step back.
        store.toggleSubtaskNoUndo(s.id, isDone: true)
        store.toggleSubtaskNoUndo(s.id, isDone: true)
        #expect(s.isDone == true)

        // nil means flip, which is what the UI path wants.
        store.toggleSubtaskNoUndo(s.id, isDone: nil)
        #expect(s.isDone == false)
    }

    @Test func rulesAreReadableAndAddableThroughTheProtocol() throws {
        let (_, store) = try makeStore()
        #expect(store.allRules(includeInactive: false).isEmpty)

        let r = store.addRule(text: "Globex admin tasks are shallow.",
                              scope: .triage, source: .ordoProposal)
        #expect(r.scope == .triage)
        #expect(r.source == .ordoProposal)
        #expect(store.activeRules().count == 1)

        r.isActive = false
        #expect(store.allRules(includeInactive: false).isEmpty)
        #expect(store.allRules(includeInactive: true).count == 1)
    }

    @Test func rankingEngineSatisfiesRankingProviding() throws {
        let (_, store) = try makeStore()
        let t = store.create(title: "Quick call", notes: "", project: nil,
                             status: .todo, priority: .none, dueDay: nil)
        store.update(t.id) { $0.depth = .shallow; $0.estimateMinutes = 10 }

        let ranker: any RankingProviding = RankingEngine()
        let out = ranker.candidates(energy: .low, count: 5, maxDeep: false,
                                    today: Day.today(), tasks: store.allTasks())
        #expect(out.count == 1)
        #expect(out[0].taskID == t.id)
        #expect(out[0].isDeterministic)
    }
}

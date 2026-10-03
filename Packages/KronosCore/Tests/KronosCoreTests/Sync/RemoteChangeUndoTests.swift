import Foundation
import Testing
@testable import KronosCore

/// A change from outside (another device) drops exactly the undo steps that would rewrite the
/// rows it touched; Cmd-Z then cannot put back a value the other side already replaced.
@MainActor
@Suite("RemoteChangeUndoTests")
struct RemoteChangeUndoTests {

    @Test func touchedStepsAreDroppedOthersStay() throws {
        let s = try TaskStore(inMemory: true)
        let a = s.create(title: "A"), b = s.create(title: "B")
        let base = s.undoDepth
        s.setPriority(a.id, .high)          // step on A
        s.setPriority(b.id, .low)           // step on B
        #expect(s.undoDepth == base + 2)

        // The other device renamed A.
        s.updateNoUndo(a.id) { $0.title = "A (phone)" }
        let report = s.absorbRemoteChange(touched: [a.id])
        // A's create step and A's priority step go; B's two steps stay.
        #expect(report.droppedUndoSteps == 2)
        #expect(s.undoDepth == base)

        // Cmd-Z undoes B's edit, never A's.
        s.undo()
        #expect(s.task(b.id)?.priority == KPriority.none)
        #expect(s.task(a.id)?.priority == KPriority.high)
        #expect(s.task(a.id)?.title == "A (phone)")
    }

    /// Redo steps are filtered the same way.
    @Test func redoStepsOnTouchedRowsAreDropped() throws {
        let s = try TaskStore(inMemory: true)
        let a = s.create(title: "A")
        s.setPriority(a.id, .high)
        s.undo()
        #expect(s.canRedo)
        s.absorbRemoteChange(touched: [a.id])
        #expect(!s.canRedo)
    }

    /// A grouped step (one Cmd-Z over several rows) goes when any of its rows is touched.
    @Test func groupedStepGoesWithAnyOfItsRows() throws {
        let s = try TaskStore(inMemory: true)
        let a = s.create(title: "A"), b = s.create(title: "B")
        let base = s.undoDepth
        s.groupedUndo("Both") {
            s.setPriority(a.id, .high)
            s.setPriority(b.id, .high)
        }
        #expect(s.undoDepth == base + 1)
        s.absorbRemoteChange(touched: [b.id])
        #expect(s.undoDepth < base + 1)
    }

    /// Rows not known: the whole history goes (the safe answer).
    @Test func unknownRowsDropEverything() throws {
        let s = try TaskStore(inMemory: true)
        let a = s.create(title: "A")
        s.setPriority(a.id, .high)
        #expect(s.canUndo)
        s.absorbRemoteChange(touched: nil)
        #expect(!s.canUndo && !s.canRedo)
    }

    /// An untouched store change (other ids) leaves the stack exactly as it was.
    @Test func otherIDsLeaveTheStackAlone() throws {
        let s = try TaskStore(inMemory: true)
        let a = s.create(title: "A")
        s.setPriority(a.id, .high)
        let depth = s.undoDepth
        let report = s.absorbRemoteChange(touched: [UUID()])
        #expect(report.droppedUndoSteps == 0)
        #expect(s.undoDepth == depth)
    }

    /// The monitor only listens while sync is on.
    @Test func monitorListensOnlyWithSync() throws {
        let s = try TaskStore(inMemory: true)
        #expect(!RemoteChangeMonitor(store: s, syncEnabled: false).isListening)
        #expect(RemoteChangeMonitor(store: s, syncEnabled: true).isListening)
        #expect(!KronosStore.isSyncEnabled)
    }
}

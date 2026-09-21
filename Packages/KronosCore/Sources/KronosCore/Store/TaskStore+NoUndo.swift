// Part of TaskStore, split out to keep every file under
// 500 lines (pure move: no renames, no behaviour change). The …NoUndo variants reserved for MCP and AI triage.
//
// Extensions in a separate file cannot see `private` members, so the undo
// plumbing these rely on (undoStack, redoStack, saveContext, mutateUndoable,
// scopeIndices, appendIndex, pushTopIndex) is internal rather than private.
// It is still not `public`: nothing outside KronosCore can reach it.

import Foundation
import SwiftData

@MainActor
extension TaskStore {
    // MARK: - NoUndo variants (build-14)
    //
    // Reserved for MCP and AI triage. Each one performs exactly the same
    // write as its undoable twin and then leaves both stacks untouched, so a
    // machine batch can never bury the user's own last action.

    /// Run `body` and discard whatever it pushed onto the undo stack.
    /// Factoring it this way keeps ONE implementation of each mutation: the
    /// undoable body stays the single source of truth for what a write does,
    /// and the NoUndo variant differs only in bookkeeping.
    private func withoutUndo<T>(_ body: () -> T) -> T {
        let undoDepth = undoStack.count
        let redoBefore = redoStack
        let wasMachine = isMachineWrite
        isMachineWrite = true
        let result = body()
        isMachineWrite = wasMachine
        if undoStack.count > undoDepth {
            undoStack.removeLast(undoStack.count - undoDepth)
        }
        // An undoable write clears the redo stack; a machine write must not.
        redoStack = redoBefore
        return result
    }

    @discardableResult
    public func createNoUndo(title: String, notes: String = "", project: KProject? = nil,
                             status: KStatus = .todo, priority: KPriority = .none,
                             dueDay: Int? = nil) -> KTask {
        withoutUndo {
            create(title: title, notes: notes, project: project,
                   status: status, priority: priority, dueDay: dueDay)
        }
    }

    public func updateNoUndo(_ id: UUID, _ mutate: (KTask) -> Void) {
        withoutUndo { updateIncludingDeleted(id, mutate) }
    }

    public func completeNoUndo(_ id: UUID) {
        withoutUndo { complete(id) }
    }

    public func setStatusNoUndo(_ id: UUID, _ s: KStatus) {
        withoutUndo { setStatus(id, s) }
    }

    public func setEffortNoUndo(_ id: UUID, _ e: KEffort) {
        withoutUndo { setEffort(id, e) }
    }

    public func sendToOrdoNoUndo(_ id: UUID, top: Bool = false) {
        withoutUndo { sendToOrdo(id, top: top) }
    }

    public func reorderOrdoNoUndo(_ id: UUID, before targetID: UUID?) {
        withoutUndo { reorderOrdo(id, before: targetID) }
    }

    public func softDeleteNoUndo(_ id: UUID) {
        withoutUndo { softDelete(id) }
    }

    public func restoreNoUndo(_ id: UUID) {
        withoutUndo { restore(id) }
    }

    @discardableResult
    public func addSubtaskNoUndo(_ taskID: UUID, title: String) -> KSubtask? {
        withoutUndo { addSubtask(taskID, title: title) }
    }

    /// Set a step explicitly, or flip it when `isDone` is nil. Explicit is
    /// what makes MCP `toggle_subtask` idempotent on a client retry.
    public func toggleSubtaskNoUndo(_ id: UUID, isDone: Bool? = nil) {
        withoutUndo {
            if let want = isDone {
                let d = FetchDescriptor<KSubtask>()
                guard let s = ((try? context.fetch(d)) ?? []).first(where: { $0.id == id }),
                      s.isDone != want else { return }
            }
            toggleSubtask(id)
        }
    }
}

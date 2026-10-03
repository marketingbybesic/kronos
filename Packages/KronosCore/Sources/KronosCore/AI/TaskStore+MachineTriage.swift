// Triage writes for tasks that did not come from the user's own hands (MCP, agents, capture):
// the fill must never bury the user's last undo step.
//
// Lives in the AI folder but extends `TaskStore`: the undo plumbing (`undoStack`, `redoStack`,
// `isMachineWrite`) is internal to KronosCore, which this file is part of.

import Foundation

@MainActor
extension TaskStore {

    /// `applyTriage`, then discard whatever undo steps it pushed and keep the redo stack: the
    /// undo depth after the call equals the depth before it. Returns the fields written.
    @discardableResult
    public func applyTriageWithoutUndo(_ result: TriageResult, to id: UUID, fillOnly: Bool = true,
                                       only allowed: Set<TriageFieldKind>? = nil) -> [TriageFieldKind] {
        let undoDepth = undoStack.count
        let redoBefore = redoStack
        let wasMachine = isMachineWrite
        isMachineWrite = true
        let filled = applyTriage(result, to: id, fillOnly: fillOnly, only: allowed)
        isMachineWrite = wasMachine
        if undoStack.count > undoDepth {
            undoStack.removeLast(undoStack.count - undoDepth)
        }
        redoStack = redoBefore
        return filled
    }
}

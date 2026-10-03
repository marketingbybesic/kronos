// What happens when rows change from outside this context (an import from iCloud, later).
//
// The undo stack holds steps that write back values captured before the change. Once another
// device has written one of those rows, pressing Cmd-Z would put back a value the other side
// already replaced, silently undoing ITS edit. So every step that would rewrite a touched row
// is dropped (undo and redo alike); steps on untouched rows stay. Then the scalar mirrors are
// re-derived from the relationships and duplicates the merge produced are folded.

import CoreData
import Foundation
import SwiftData

public struct RemoteChangeReport: Equatable, Sendable {
    public var droppedUndoSteps = 0
    public var droppedRedoSteps = 0
    public var mirrorsFixed = 0
    public var dedupe = DedupeReport()
    public init() {}
}

@MainActor
extension TaskStore {

    /// Remove every undo and redo step that would rewrite one of `ids` (steps whose rows are
    /// not known count as touching everything). Returns (undo, redo) steps removed.
    @discardableResult
    func dropUndoSteps(touching ids: Set<UUID>) -> (undo: Int, redo: Int) {
        guard !ids.isEmpty else { return (0, 0) }
        let undoBefore = undoStack.count, redoBefore = redoStack.count
        undoStack.removeAll { $0.touches(ids) }
        redoStack.removeAll { $0.touches(ids) }
        return (undoBefore - undoStack.count, redoBefore - redoStack.count)
    }

    /// Absorb a change made outside this context. `touched`: the ids of the rows it wrote
    /// (tasks, projects, areas, labels, rules, saved views); nil when they are not known, which
    /// drops the whole undo history. Machine write: pushes nothing.
    @discardableResult
    public func absorbRemoteChange(touched: Set<UUID>?) -> RemoteChangeReport {
        var report = RemoteChangeReport()
        if let touched {
            let dropped = dropUndoSteps(touching: touched)
            report.droppedUndoSteps = dropped.undo
            report.droppedRedoSteps = dropped.redo
        } else {
            report.droppedUndoSteps = undoStack.count
            report.droppedRedoSteps = redoStack.count
            undoStack.removeAll()
            redoStack.removeAll()
        }
        report.mirrorsFixed = MirrorReconcile.run(in: self)
        report.dedupe = DedupeSweep.run(in: self)
        return report
    }
}

/// Listens for the store's remote-change notification while sync is on, and hands each change
/// to `absorbRemoteChange`. Without sync it never subscribes: nothing outside this process
/// writes the store, and the app's own background MCP writes go through the same store object.
@MainActor
public final class RemoteChangeMonitor {
    private weak var store: TaskStore?
    private var observer: NSObjectProtocol?

    public init(store: TaskStore, syncEnabled: Bool = KronosStore.isSyncEnabled) {
        self.store = store
        guard syncEnabled else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // The notification does not name the rows; until the history API reports them,
                // every step is treated as touched.
                _ = self?.store?.absorbRemoteChange(touched: nil)
            }
        }
    }

    public var isListening: Bool { observer != nil }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

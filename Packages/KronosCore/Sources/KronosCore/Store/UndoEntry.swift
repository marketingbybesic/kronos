// One step on TaskStore's undo or redo stack, tagged with the ids of the rows it rewrites.
//
// The tag exists for changes that arrive from outside this context (another device through
// sync, a dedupe sweep that removes a row): such a change makes every step that would rewrite
// one of its rows stale, because undoing it would put back a value the other side already
// replaced. `TaskStore.dropUndoSteps(touching:)` removes exactly those steps.

import Foundation
import SwiftData

struct UndoEntry {
    let name: String
    let run: () -> Void
    /// The ids (tasks, projects, areas, labels, saved views) this step writes when it runs.
    /// nil = not known: such a step is dropped by ANY outside change, which is always safe.
    let touched: Set<UUID>?

    init(_ name: String, touching touched: Set<UUID>?, _ run: @escaping () -> Void) {
        self.name = name
        self.run = run
        self.touched = touched
    }

    /// True when running this step would rewrite one of `ids` (always true when unknown).
    func touches(_ ids: Set<UUID>) -> Bool {
        guard let touched else { return true }
        return !touched.isDisjoint(with: ids)
    }

    /// The union of several steps' tags; unknown as soon as one of them is unknown.
    static func union(_ entries: [UndoEntry]) -> Set<UUID>? {
        var all = Set<UUID>()
        for e in entries {
            guard let t = e.touched else { return nil }
            all.formUnion(t)
        }
        return all
    }
}

extension Array where Element == UndoEntry {
    /// An untagged step (name, closure): kept for call sites that cannot name their rows. Such a
    /// step counts as touching everything, so any outside change drops it.
    mutating func append(_ step: (String, () -> Void)) {
        append(UndoEntry(step.0, touching: nil, step.1))
    }

    /// A step that rewrites exactly the rows in `touched`.
    mutating func append(_ name: String, touching touched: Set<UUID>, _ run: @escaping () -> Void) {
        append(UndoEntry(name, touching: touched, run))
    }
}

extension TaskStore {
    /// The undo tag of one model row: its id when the model has one, unknown otherwise.
    static func undoTag<T: PersistentModel>(_ model: T) -> Set<UUID>? {
        (model as? HasUUID).map { [$0.id] }
    }
}

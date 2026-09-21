// Kronos/Capture/CaptureRow.swift
// View-local wrapper around a `ProposedTask`: adds the tick state and an edited flag so an
// in-place AI upgrade (CaptureModel.upgrade) can tell "the user already touched this row" from
// "still exactly what the deterministic pass produced" and never clobber the former.
import Foundation
import KronosCore

struct CaptureRow: Identifiable, Equatable {
    let id: UUID
    var proposal: ProposedTask
    var isTicked: Bool
    /// True once the user changes anything about this row (title, attributes, or the tick
    /// itself away from its natural default). An AI upgrade skips every field on an edited
    /// row — only its untouched siblings are replaced in place.
    var isEdited: Bool = false
    /// Subtask titles proposed for this task — from `TaskOutline.parse`'s reading of the
    /// pasted note (offline), or from the AI reply when it names its own. NOT part of
    /// `ProposedTask` (a frozen contract type this leaf does not own) — kept here instead, same
    /// reasoning as `isTicked`/`isEdited`. Editable in the review list before creation; created
    /// via `TaskStoring.addSubtasks` in the same undo step as the task itself.
    var subtasks: [String] = []

    /// `subtasks` defaults to the proposal's OWN subtasks (set only by the AI extract path)
    /// rather than always starting empty — a caller that also has outline-derived subtasks
    /// (`NoteSplitter.subtasks(in:)`) passes them explicitly instead, same as before.
    ///
    /// `id` defaults to `proposal.id` (the original single-construction-site behaviour, still
    /// what `CaptureModel.findTasks()` relies on for a fresh deterministic row) but can be
    /// given explicitly: `CaptureModel.upgrade(with:)` converts to/from `CaptureMergeRow`
    /// (KronosCore) across the AI-merge boundary, and a row that gets its `proposal` REPLACED
    /// by an AI task must keep ITS OWN `id`, not inherit the AI task's own `proposal.id` —
    /// `CaptureReviewList`'s `selectedID` tracks `row.id` across an upgrade, and a plain
    /// `rows[i].proposal = upgraded` mutation would never change `id` either, since it would
    /// never reconstruct the row at all.
    init(id: UUID? = nil, proposal: ProposedTask, subtasks: [String]? = nil) {
        self.id = id ?? proposal.id
        self.proposal = proposal
        self.isTicked = !proposal.isDuplicateOfOpenTask
        self.subtasks = subtasks ?? proposal.subtasks
    }

    var title: String {
        get { proposal.title }
        set { proposal.title = newValue }
    }
}

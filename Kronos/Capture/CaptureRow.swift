// Kronos/Capture/CaptureRow.swift
// View-local wrapper around a `ProposedTask`: adds the tick state and an edited flag so an
// in-place AI upgrade (CaptureModel.upgrade) can tell "the user already touched this row" from
// "still exactly what the deterministic pass produced" and never clobber the former.
import Foundation
import KronosCore

/// What a row that duplicates an open task does when it is ticked: fold into the existing task
/// (the default: nothing is lost, one undo step) or make a second task anyway.
enum DuplicateChoice: Equatable { case merge, createAnyway }

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
    /// Only read while `proposal.isDuplicateOfOpenTask`. Merge is the default so a duplicate is
    /// never a dead end: Cmd-Return folds it into the existing task, "Create anyway" is one click.
    var duplicateChoice: DuplicateChoice = .merge
    /// The Apple Reminders item this row was read from ("From Reminders"), or nil. `create()`
    /// stamps the task made from this row with the reminder's identity, whatever the title
    /// became in review.
    var reminder: ReminderItem?

    /// True when ticking this row folds it into an existing task instead of creating a new one.
    var isMerge: Bool { isTicked && proposal.isDuplicateOfOpenTask && duplicateChoice == .merge }

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
        // A duplicate starts ticked as a MERGE into the task it duplicates (see `duplicateChoice`).
        self.isTicked = true
        self.subtasks = subtasks ?? proposal.subtasks
    }

    var title: String {
        get { proposal.title }
        set { proposal.title = newValue }
    }
}

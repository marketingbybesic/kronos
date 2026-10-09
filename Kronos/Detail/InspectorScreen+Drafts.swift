// Kronos/Detail/InspectorScreen+Drafts.swift
// What the inspector's three text drafts show for a task, and the AI rationale panel: split out
// of InspectorScreen.swift to keep that file inside the 500-line limit.
import SwiftUI
import KronosCore

extension InspectorScreen {
    /// What the store shows for `task`, in the form the three draft fields render it.
    static func shown(_ task: KTask) -> InspectorDrafts.Shown {
        InspectorDrafts.Shown(title: task.title,
                              notes: InspectorNotesText.visible(task.notes),
                              firstMove: editableFirstMove(task))
    }

    /// The stored move as the field shows it: a generic placeholder sentence counts as empty,
    /// so the hint ("Review: <title>") shows instead; committing clears the placeholder.
    static func editableFirstMove(_ task: KTask) -> String {
        guard let move = task.firstMove, !DeterministicFirstMove.isGenericTemplate(move) else { return "" }
        return move
    }

    // MARK: Draft lifecycle

    func loadDrafts() {
        notesAutosaveWork?.cancel()
        guard let task else {
            drafts.load(taskID: nil, shown: InspectorDrafts.Shown())
            notesEditBase = ""
            return
        }
        drafts.load(taskID: task.id, shown: Self.shown(task))
        notesEditBase = task.notes
    }

    /// The store changed while this task is open: untouched fields follow it (a first move that
    /// auto-triage just filled appears), fields the user is typing in keep their text.
    func reloadCleanDrafts() {
        guard let task, drafts.taskID == task.id else { return }
        drafts.reloadClean(shown: Self.shown(task))
        // Untouched notes follow the store, so a later edit starts from what is stored now.
        if !drafts.isDirty(.notes) { notesEditBase = task.notes }
    }

    /// Writes every dirty draft onto the task it was loaded from, now.
    func flushDrafts() {
        guard let id = drafts.taskID else { return }
        commitDrafts(for: id)
    }

    func commitDrafts(for id: UUID) {
        // The drafts belong to the task they were loaded from. Committing them onto another id (a
        // child's title must never land on its parent when the shown task changes)
        // must never happen: nothing is written unless the id is the loaded task. Only fields the
        // user actually typed in (dirty) are written; a clean draft is a stale copy by definition.
        notesAutosaveWork?.cancel()
        guard id == drafts.taskID, let t = model.store.task(id), !drafts.dirtyFields.isEmpty else { return }
        let title = drafts.titleToWrite(stored: t.title)
        let notesDraft = drafts.notesToMerge()
        let ownsFirstMove = t.nextOpenSubtask == nil   // only a task with no open subtask owns firstMove
        let firstMove = drafts.firstMoveToWrite(stored: Self.editableFirstMove(t), ownsFirstMove: ownsFirstMove)
        // Root cause of "first Cmd-Z does nothing" after Space/H: selection change runs this and
        // `store.update` ALWAYS pushes an undo step, burying the complete/snooze step under a no-op.
        // Title, first move and notes land as ONE undo step; notes go through the conflict-safe
        // save, which writes nothing when the visible text is what is stored.
        var notesOutcome: TextConflictMerge.Outcome?
        var wrote = false
        model.store.groupedUndo("Edit") {
            if title != nil || firstMove != nil {
                model.store.update(id) { task in
                    if let title { task.title = title }
                    if let firstMove { task.firstMove = firstMove.isEmpty ? nil : firstMove }
                }
                wrote = true
            }
            if let notesDraft {
                notesOutcome = InspectorNotesSave.save(notesDraft, to: id, editBase: notesEditBase, store: model.store)
                wrote = wrote || notesOutcome != nil
            }
        }
        if wrote { model.didMutate() }
        let now = Self.shown(model.store.task(id) ?? t)
        for field in drafts.dirtyFields {
            // An empty title cannot be written: it stays dirty (blur or Esc snaps it back).
            // A first move without ownership is not shown as editable: leave it untouched.
            if field == .title, drafts.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            if field == .firstMove, !ownsFirstMove { continue }
            if field == .notes { notesCommitted(id, notesOutcome); continue }
            drafts.markCommitted(field, shown: now)
        }
    }
}

/// The model's one-sentence rationale for its triage, under the notes.
struct InspectorRationalePanel: View {
    let rationale: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            InspectorSectionCaption(String(localized: "detail.rationale"))
            KPanel {
                HStack(alignment: .top, spacing: Space.x2) {
                    Icon("sparkles", size: Metrics.iconM).foregroundStyle(Tok.textTertiary)
                    Text(rationale)
                        .font(Typo.body)
                        .foregroundStyle(Tok.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

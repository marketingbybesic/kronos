// Kronos/Detail/InspectorNotesSave.swift
// Saving the inspector's notes draft without losing what another device (or an agent, or the
// menu bar) wrote into the same notes while the draft was open. The editor remembers the full
// stored notes it started from (the edit base); the save goes through the store's three-way
// merge, which appends the other side's new text under a header line instead of overwriting it.
// The link lines (`notes://`, `link://`) are not part of the draft: they are taken from the
// stored notes on both sides of the merge, so a link added meanwhile is never a conflict.
import Foundation
import KronosCore

@MainActor
enum InspectorNotesSave {
    /// The header line above the other side's text after a conflicting save.
    static var conflictHeader: String { String(localized: "detail.notes.conflict.header") }

    /// Saves `draft` (the visible notes) onto task `id`. `editBase` is the full stored notes the
    /// draft started from. Returns nil when nothing needed writing (no undo step is pushed),
    /// else the merge outcome; `.conflict` means the stored notes now hold more than the draft.
    @discardableResult
    static func save(_ draft: String, to id: UUID, editBase: String, store: TaskStore) -> TextConflictMerge.Outcome? {
        guard let stored = store.task(id)?.notes else { return nil }
        let mine = InspectorNotesText.merging(visibleDraft: draft, controlLinesFrom: stored)
        let base = InspectorNotesText.merging(visibleDraft: InspectorNotesText.visible(editBase),
                                              controlLinesFrom: stored)
        // Nothing typed differs from what is stored: no write, no empty undo step.
        guard mine != stored else { return nil }
        return store.setNotes(id, mine, editBase: base, conflictHeader: conflictHeader)
    }
}

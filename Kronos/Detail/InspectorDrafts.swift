// Kronos/Detail/InspectorDrafts.swift
// The inspector's three text drafts (title, first move, notes) with per-field dirty tracking.
// A draft is a copy of what the store showed when it was loaded; only a field the user actually
// typed in is "dirty", and only dirty fields are ever written back. Clean fields follow the
// store, so a value that arrives while the task is open (auto-triage filling the first move, an
// MCP edit) is shown and is never overwritten by a stale empty copy when the user leaves.
// Foundation only: scripts compile this file standalone against a hand-written table.
import Foundation

struct InspectorDrafts: Equatable {
    enum Field: CaseIterable { case title, notes, firstMove }

    /// What the store shows for the task, as the three fields render it: the title, the VISIBLE
    /// notes (control lines removed), and the editable first move ("" when none or a placeholder).
    struct Shown: Equatable {
        var title = ""
        var notes = ""
        var firstMove = ""

        subscript(field: Field) -> String {
            get {
                switch field {
                case .title: return title
                case .notes: return notes
                case .firstMove: return firstMove
                }
            }
            set {
                switch field {
                case .title: title = newValue
                case .notes: notes = newValue
                case .firstMove: firstMove = newValue
                }
            }
        }
    }

    /// The live text the controls bind to.
    var title = ""
    var notes = ""
    var firstMove = ""
    /// The task the drafts were loaded from. Nothing may be written onto any other task.
    private(set) var taskID: UUID?
    /// The text each field held when it was last in step with the store (or last committed).
    private var base = Shown()
    /// The store's own text at the last look. A clean field only reloads when this changes, so
    /// a store that normalises what we wrote (trimming) never rewrites text under the caret.
    private var seen = Shown()

    func text(_ field: Field) -> String {
        switch field {
        case .title: return title
        case .notes: return notes
        case .firstMove: return firstMove
        }
    }

    private mutating func setText(_ field: Field, _ value: String) {
        switch field {
        case .title: title = value
        case .notes: notes = value
        case .firstMove: firstMove = value
        }
    }

    func isDirty(_ field: Field) -> Bool { text(field) != base[field] }
    var dirtyFields: [Field] { Field.allCases.filter(isDirty) }

    /// Start (or restart) from a task: every draft equals the store, nothing is dirty.
    mutating func load(taskID: UUID?, shown: Shown) {
        self.taskID = taskID
        title = shown.title
        notes = shown.notes
        firstMove = shown.firstMove
        base = shown
        seen = shown
    }

    /// The store changed: every CLEAN field takes the store's new text; dirty fields keep the
    /// user's typing. Returns the fields that were replaced.
    @discardableResult
    mutating func reloadClean(shown: Shown) -> [Field] {
        var replaced: [Field] = []
        for field in Field.allCases where !isDirty(field) && shown[field] != seen[field] {
            setText(field, shown[field])
            base[field] = shown[field]
            seen[field] = shown[field]
            replaced.append(field)
        }
        return replaced
    }

    /// A dirty field was written (or deliberately dropped): it is clean again against what the
    /// store now shows. The draft text itself stays as typed.
    mutating func markCommitted(_ field: Field, shown: Shown) {
        base[field] = text(field)
        seen[field] = shown[field]
    }

    /// Discard typing in one field and show the store's text (Esc, or an empty title).
    mutating func revert(_ field: Field, to shown: Shown) {
        setText(field, shown[field])
        base[field] = shown[field]
        seen[field] = shown[field]
    }

    // MARK: What a commit would write (decisions only; the caller performs the write)

    /// The new title, only when the title field is dirty, non-empty after trimming, and differs.
    func titleToWrite(stored: String) -> String? {
        guard isDirty(.title) else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return (!trimmed.isEmpty && trimmed != stored) ? trimmed : nil
    }

    /// The new first move ("" clears it), only when the field is dirty, differs from the stored
    /// move, and the task owns a first move (no open subtask supplies it).
    func firstMoveToWrite(stored: String, ownsFirstMove: Bool) -> String? {
        guard ownsFirstMove, isDirty(.firstMove) else { return nil }
        let trimmed = firstMove.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed != stored ? trimmed : nil
    }

    /// The visible notes draft, only when the notes field is dirty (the caller merges the
    /// untouched control lines back in and skips the write if nothing changed).
    func notesToMerge() -> String? { isDirty(.notes) ? notes : nil }
}

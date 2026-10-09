// Kronos/Detail/InspectorScreen+Notes.swift
// The notes field, its autosave debounce and conflict-merge commit: split out of
// InspectorScreen.swift (UI-007) to keep that file inside the 500-line limit.
import SwiftUI
import KronosCore

extension InspectorScreen {
    // MARK: Notes

    func notesSection(_ task: KTask) -> some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            HStack {
                InspectorSectionCaption(String(localized: "detail.notes"))
                Spacer()
                // The one "Link Apple note" button; hidden once a note is linked.
                if NoteLink.find(in: task.notes) == nil {
                    Button {
                        model.noteLinkPickerOpen = true
                    } label: {
                        HStack(spacing: Space.x2) {
                            Icon("note.text", size: Metrics.iconS)
                            Text(String(localized: "detail.notelink.add"))
                        }
                    }
                    .kButton(.secondary, size: .compact)
                    .uiTestAnchor("inspector.notes.notelink.add")
                }
            }
            InspectorNotesField(placeholder: String(localized: "detail.notes.placeholder"), text: $drafts.notes)
                .focused($focus, equals: .notes)
                .onChange(of: focus) { old, new in
                    if old == .notes, new != .notes { commitNotes(task) }
                }
                .onChange(of: drafts.notes) { _, _ in scheduleNotesAutosave(task) }
        }
    }

    private func scheduleNotesAutosave(_ task: KTask) {
        notesAutosaveWork?.cancel()
        let work = DispatchWorkItem { commitNotes(task) }
        notesAutosaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func commitNotes(_ task: KTask) {
        guard task.id == drafts.taskID, let draft = drafts.notesToMerge() else { return }
        let outcome = InspectorNotesSave.save(draft, to: task.id, editBase: notesEditBase, store: model.store)
        if outcome != nil { model.didMutate() }
        notesCommitted(task.id, outcome)
    }

    /// After a notes save: the draft is in step with the store again. A save that kept another
    /// side's text shows the merged notes, so the next save starts from them and cannot drop them.
    func notesCommitted(_ id: UUID, _ outcome: TextConflictMerge.Outcome?) {
        guard let now = model.store.task(id) else { return }
        if case .conflict? = outcome {
            drafts.revert(.notes, to: Self.shown(now))
        } else {
            drafts.markCommitted(.notes, shown: Self.shown(now))
        }
        notesEditBase = now.notes
    }
}

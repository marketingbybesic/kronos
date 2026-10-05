// Kronos/List/ChildTaskRowTitleEdit.swift
// Double-click-to-rename for ChildTaskRow's title, the same behaviour as a parent row's title
// (ListRowTitleEdit.swift): double-click swaps the Text for a TextField, Return or a blur
// commits only when the text changed (one undo step, "Rename Step"), Esc cancels, an emptied
// title cancels instead of saving blank.
//
// The title owns its double-click (`highPriorityGesture`); the row's open-details double-click
// lives on the part of the row right of the title, so the two gestures can never both fire.
// While the field is first responder the list's own key handlers stay inert (the row's Return
// handler checks for an NSTextView).
import SwiftUI
import KronosCore

extension ChildTaskRow {
    @ViewBuilder
    var titleView: some View {
        if isEditingTitle {
            TextField(String(localized: "list.new"), text: $editedTitle)
                .textFieldStyle(.plain)
                .font(Typo.meta)
                .foregroundStyle(Tok.textPrimary)
                .lineLimit(1)
                .focused($titleFieldFocused)
                .onSubmit { commitTitleEdit() }
                .onExitCommand { isEditingTitle = false }
                .onChange(of: titleFieldFocused) { _, focused in if !focused { commitTitleEdit() } }
                .uiTestAnchor("subrow.title.edit")
        } else {
            Text(child.title)
                .font(Typo.meta)
                .foregroundStyle(child.isDone ? Tok.textTertiary : (isMarked ? Tok.textPrimary : Tok.textSecondary))
                .strikethrough(child.isDone)
                .lineLimit(1)
                .truncationMode(.tail)
                .highPriorityGesture(TapGesture(count: 2).onEnded { beginTitleEdit() })
                .uiTestAnchor((isLabelMatch ? "subrow.labelmatch." : "subrow.title.") + child.title)
        }
    }

    func beginTitleEdit() {
        editedTitle = child.title
        isEditingTitle = true
        titleFieldFocused = true
    }

    func commitTitleEdit() {
        guard isEditingTitle else { return }
        isEditingTitle = false
        let trimmed = editedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != child.title else { return }
        model.store.renameSubtask(child.id, title: trimmed)
        model.commit(String(format: String(localized: "list.pill.renamed"), trimmed))
    }
}

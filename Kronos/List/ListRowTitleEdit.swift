// Kronos/List/ListRowTitleEdit.swift
// Double-click-to-rename for ListRowView's title, so a task can be renamed directly from the
// list, not only from the side panel. Split out of ListRowView.swift purely for the 500-line
// file budget — this is the SAME view's title, just declared in an
// extension; `isEditingTitle`/`editedTitle`/`titleFieldFocused` are declared as `@State`/
// `@FocusState` on ListRowView itself (an extension can't add stored properties to a struct).
//
// The double-tap gesture lives on the title Text alone, not the row, and is
// `.highPriorityGesture` so it wins the recognizer race against `KListRow`'s own single-tap
// `onSelect` — SwiftUI still fires a plain `TapGesture(count: 1)` on first click with NO
// wait-for-a-second-click delay, because that single tap lives on a DIFFERENT view
// (`KListRow`'s `rowContent`) and is never itself upgraded to a double-tap recognizer; only
// the two-tap gesture here waits for a second click, and only while the pointer is over the
// title. LiveUITest's single click at `xFraction: 0.45` (Kronos/App/LiveUITest.swift) keeps
// selecting on the first click — proven live by running the UI test (see this leaf's report).
//
// Editing swaps Text for a TextField that saves through `model.store.update` — the same
// one-mutation-per-call pattern `reorderManual` (ListRowView.swift) already uses for
// `sortIndex`, so the title change is one undo step. Return/blur saves (a blur that leaves
// the title unchanged is a no-op write, not a second undo step), Esc cancels, an emptied
// title cancels rather than saving blank. While editing, `TaskListScreen.isTyping` (checks
// `firstResponder is NSTextView`) already keeps the list's own key handlers inert — no
// per-row guard needed here.
import SwiftUI

extension ListRowView {
    @ViewBuilder
    var titleView: some View {
        if isEditingTitle {
            TextField(String(localized: "list.new"), text: $editedTitle)
                .textFieldStyle(.plain)
                .font(Typo.row)
                .foregroundStyle(Tok.textPrimary)
                .focused($titleFieldFocused)
                .onSubmit { commitTitleEdit() }
                .onExitCommand { isEditingTitle = false }
                .onChange(of: titleFieldFocused) { _, focused in if !focused { commitTitleEdit() } }
                .uiTestAnchor("row.title.edit")
        } else {
            Text(task.title)
                .font(Typo.row)
                .foregroundStyle(task.status == .done ? Tok.textTertiary : Tok.textPrimary)
                .strikethrough(task.status == .done)
                .lineLimit(1)
                .truncationMode(.tail)
                .highPriorityGesture(TapGesture(count: 2).onEnded { beginTitleEdit() })
        }
    }

    func beginTitleEdit() {
        editedTitle = task.title
        isEditingTitle = true
        titleFieldFocused = true
    }

    func commitTitleEdit() {
        guard isEditingTitle else { return }
        isEditingTitle = false
        let trimmed = editedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != task.title else { return }
        model.store.update(task.id) { $0.title = trimmed }
        model.didMutate()
    }
}

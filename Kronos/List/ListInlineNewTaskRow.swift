// Kronos/List/ListInlineNewTaskRow.swift
// Inline "New task" row pinned to the top of a task list. It is the shared entry field
// (Kronos/Shared/EntryField) in its row style: typing `#` or `@` lists projects, areas and
// labels, accepted tokens become pills, and the list's own project or area is a prefilled
// pill that the x removes (a task added without it is filed nowhere, in the Inbox sense).
// Return adds and keeps focus; Option-Return keeps the pills typed so far; "kronosNewTaskRequested"
// lets a global shortcut focus it from outside the list. Subtask add surfaces are NOT this row.
import SwiftUI
import KronosCore

struct ListInlineNewTaskRow: View {
    @Bindable var model: AppModel
    let scope: ListScope
    @State private var entry = EntryFieldModel()

    var body: some View {
        // Same column geometry as a real row (KListRow.rowContent): leading inset, then a
        // checkbox-width column, then the checkbox-title gap, then the title: so the "+" glyph
        // sits on the checkbox centre line and the field's text sits on the task-title x.
        EntryField(model: entry, placeholder: String(localized: "list.new"),
                   fieldAnchor: "inlineadd.field",
                   style: .row, rowLeading: { AnyView(plusButton) }, onSubmit: create)
            .padding(.horizontal, Metrics.listRowLeading)
            .contentShape(Rectangle())
            .onTapGesture { entry.requestFocus() }
            .onAppear {
                entry.update(catalog: EntryCatalog.make(store: model.store))
                if entry.pills.isEmpty { entry.pills = inheritedPills }
            }
            .onChange(of: model.version) { _, _ in entry.update(catalog: EntryCatalog.make(store: model.store)) }
            // Another list: its own project or area is the inherited pill, whatever was there.
            .onChange(of: scope) { _, _ in entry.pills = inheritedPills }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("kronosNewTaskRequested"))) { _ in
                guard !model.isAnyOverlayOpen else { return }
                entry.requestFocus()
            }
    }

    /// The minimum-hit-area frame lives INSIDE the label closure: a `.buttonStyle(.plain)` button is
    /// only pressable on its label's own opaque pixels. The label's OWN size is the checkbox
    /// column's width (keeps column alignment); the hit area is grown past it with a negative inset
    /// on the content shape, which affects hit testing only, never layout.
    private var plusButton: some View {
        Button { entry.text.isEmpty ? entry.requestFocus() : create(.clear) } label: {
            let grow = (Metrics.minHit - Metrics.listCheckboxSize) / 2
            Icon("plus", size: Metrics.iconM).foregroundStyle(Tok.textTertiary)
                .frame(width: Metrics.listCheckboxSize, height: Metrics.listCheckboxSize)
                .contentShape(Rectangle().inset(by: -grow))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "list.new"))
        .accessibilityIdentifier("list.inlineadd.plus")
    }

    /// The list's project or area as a destination pill; nothing on fixed lists (Inbox, Today ...).
    private var inheritedPills: [EntryPill] {
        QuickAddController.prefilledPills(scope: scope, store: model.store, kronosIsFrontmost: true)
    }

    private func create(_ mode: EntrySubmitMode) {
        // Same creation path as the quick add panel: #project / #area @label ! effort and dates, plus
        // "a > b" subtasks. `scope:` makes the task belong to the list it was typed in (Someday ->
        // .someday, Waiting -> .waiting, Today/Next 7 -> due today unless the text names a date, an
        // area -> that area, see ListScopeDefaults). The destination comes from the pill, so a
        // removed pill means a task with no project.
        let made = QuickAddCreate.create(from: entry.text, model: model, scope: scope, pills: entry.pills)
        guard let first = made.first else { return }
        UndoToastCenter.shared.show(String(format: String(localized: "undo.added.name"), first.title))
        entry.clear(keepingPills: mode == .keepPills)
        if mode == .clear { entry.pills = inheritedPills }
        entry.requestFocus()
    }
}

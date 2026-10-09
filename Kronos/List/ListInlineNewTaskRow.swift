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
        // Same column geometry as a real row (KListRow.rowContent): KListRow's own outer
        // content inset (`ChildRowGeometry.listRowContentInset`, 6pt, shared with every
        // other row-column consumer) plus the leading-inset-to-checkbox column, then the
        // checkbox-title gap, then the title — so the "+" glyph sits on the checkbox centre
        // line and the field's text sits on the task-title x. `KCheckbox`'s own label frame
        // grows to `Metrics.minHit` (see `plusButton` below, same growth) around its
        // `Metrics.listCheckboxSize` circle, so the real checkbox column is `minHit`-wide, not
        // circle-wide — the outer padding here must add KListRow's 6pt content inset to its
        // own leading math to land on the same 18pt-to-column-start KListRow itself uses.
        // (Before this fix: outer padding was `Metrics.listRowLeading` alone and the button's
        // own frame stayed circle-wide, so the "+" and the field's text both rendered 10pt
        // left of the checkbox/title every real row below them uses — visible in every
        // populated-list screenshot, see FINDINGS-FINISH.md DESIGN-001.)
        EntryField(model: entry, placeholder: String(localized: "list.new"),
                   fieldAnchor: "inlineadd.field",
                   style: .row, rowLeading: { AnyView(plusButton) }, onSubmit: create)
            .padding(.horizontal, ChildRowGeometry.listRowContentInset + Metrics.listRowLeading)
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

    /// Mirrors `KCheckbox`'s own pattern (`KCheckbox.swift`'s body): the label's frame grows to
    /// `Metrics.minHit`, centering the glyph inside it, both for layout AND hit-testing. This
    /// has to match KCheckbox exactly, not just visually look similar — `KListRow.rowContent`
    /// places a real `KCheckbox` directly in its HStack with no extra width override, so
    /// `KCheckbox`'s own `minWidth: Metrics.minHit` growth (it is bigger than its own
    /// `Metrics.listCheckboxSize` circle) is what the REAL checkbox column width actually is.
    /// The previous version here kept the label at exactly `Metrics.listCheckboxSize` and grew
    /// only the hit-tested `contentShape` past it (never layout) — contributing 4 of the 10pt
    /// total misalignment the `body` comment above describes (the other 6pt came from the
    /// outer padding missing KListRow's own content inset).
    private var plusButton: some View {
        Button { entry.text.isEmpty ? entry.requestFocus() : create(.clear) } label: {
            Icon("plus", size: Metrics.iconM).foregroundStyle(Tok.textTertiary)
                .frame(width: Metrics.minHit, height: Metrics.minHit)
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

// Kronos/List/ListInlineNewTaskRow.swift
// Inline "New task" row pinned to the top of the list. Return creates the task in the
// current scope's project and keeps focus for the next one; observes
// "kronosNewTaskRequested" so a global shortcut can focus it from outside the list.
import SwiftUI
import KronosCore

struct ListInlineNewTaskRow: View {
    @Bindable var model: AppModel
    let scope: ListScope
    @State private var title = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        // Same column geometry as a real row (KListRow.rowContent): leading inset, then a
        // checkbox-width column, then the checkbox-title gap, then the title — so the "+"
        // glyph sits on the checkbox centre line and the field's text sits on the task-title x.
        // The minimum-hit-area frame lives INSIDE the label closure: a `.buttonStyle(.plain)`
        // button is only pressable on its label's own opaque pixels, and a frame added AFTER
        // `.buttonStyle` would both miss that and re-introduce the extra width that pushed the
        // field out of alignment in the first place.
        HStack(spacing: 0) {
            Button { title.isEmpty ? (isFocused = true) : create() } label: {
                // The label's OWN size is the checkbox column's width (keeps column alignment);
                // the hit area is grown past it with a negative inset on the content shape, which
                // affects hit testing only, never layout — so the glyph stays on the checkbox
                // centre line while the click target still meets Metrics.minHit.
                let grow = (Metrics.minHit - Metrics.listCheckboxSize) / 2
                Icon("plus", size: Metrics.iconM).foregroundStyle(Tok.textTertiary)
                    .frame(width: Metrics.listCheckboxSize, height: Metrics.listCheckboxSize)
                    .contentShape(Rectangle().inset(by: -grow))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "list.new"))
            .accessibilityIdentifier("list.inlineadd.plus")
            Color.clear.frame(width: Metrics.listCheckboxTitleGap)
            TextField(String(localized: "list.new"), text: $title)
                .textFieldStyle(.plain)
                .font(Typo.row)
                .foregroundStyle(Tok.textPrimary)
                .focused($isFocused)
                .onSubmit(create)
                .accessibilityIdentifier("list.inlineadd.field")
                .uiTestAnchor("inlineadd.field")
        }
        .padding(.horizontal, Metrics.listRowLeading)
        .frame(height: Metrics.rowHeight)
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("kronosNewTaskRequested"))) { _ in
            isFocused = true
        }
    }

    private func create() {
        // Same parser as the quick add panel: #project @label ! effort and dates all work here.
        // `scope:` makes the new task belong to the list it was typed in (Someday -> .someday,
        // Waiting -> .waiting, Today/Next 7 -> due today unless the text names a date, an area ->
        // that area) — see ListScopeDefaults in QuickAddCreate.swift.
        guard !QuickAddCreate.create(from: title, model: model, fallbackProject: currentProject,
                                      scope: scope).isEmpty else { return }
        title = ""
        isFocused = true
    }

    private var currentProject: KProject? {
        if case .project(let id) = scope { return model.store.allProjects().first { $0.id == id } }
        return nil
    }
}

// Kronos/List/ListSaveViewSheet.swift
// "Save as view…" popover content: a name field plus Save/Cancel. Exposed as its own
// named snapshot screen (`list.saveview`) since popovers can't be captured while
// presented — the harness renders this content directly, undecorated by the popover
// chrome the real button presents it in.
import SwiftUI

struct ListSaveViewSheet: View {
    @State private var name: String
    /// The project the view will belong to (saved from inside it), named under the field so the person knows
    /// where the row will appear. nil: a view of its own, listed under "Views".
    let projectName: String?
    let onSave: (String) -> Void
    let onCancel: () -> Void
    @FocusState private var isFocused: Bool

    init(name: String, projectName: String? = nil, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self._name = State(initialValue: name)
        self.projectName = projectName
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            Text(String(localized: "viewoptions.saveview"))
                .font(Typo.sectionHdr)
                .foregroundStyle(Tok.textPrimary)
            // GAP (reported): no catalog key for a saved-view name field's placeholder.
            KTextField("Name", text: $name)
                .focused($isFocused)
                .onSubmit(save)
                .uiTestAnchor("viewsave.name")
            if let projectName {
                Text(String(format: String(localized: "viewoptions.saveview.inproject"), projectName))
                    .font(Typo.row)
                    .foregroundStyle(Tok.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .uiTestAnchor("viewsave.project")
            }
            HStack(spacing: Space.x2) {
                Spacer()
                Button(String(localized: "common.cancel"), action: onCancel)
                    .kButton(.secondary)
                Button(String(localized: "common.save"), action: save)
                    .kButton(.primary)
                    .disabled(trimmed.isEmpty)
                    .uiTestAnchor("viewsave.save")
            }
        }
        .padding(Space.x4)
        .frame(width: 320)
        .background(Tok.overlay)
        .onAppear { isFocused = true }
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
    }
}

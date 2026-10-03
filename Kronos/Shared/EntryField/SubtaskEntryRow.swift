// Kronos/Shared/EntryField/SubtaskEntryRow.swift
// The "add subtask" row of the middle list and of the inspector's steps section. A subtask is a
// full child task, so the row takes a task's syntax minus where it lives: `@label`, `!` priority,
// `*` effort and date words, with the same suggestions and pills as every other entry field.
// `#project` is not offered: a child always lives where its parent lives, so a typed `#word`
// stays literal text and shows as an ignored pill (hover says why). `>` and indentation make no
// structure here, one level only. Return adds and keeps focus; Option-Return keeps the pills;
// each entry is ONE undo step however many fields it carried.
import SwiftUI
import KronosCore

struct SubtaskEntryRow: View {
    @Bindable var model: AppModel
    let parentID: UUID
    /// "list" or "inspector": part of the field's ui-test anchor, so both can be on screen at once.
    let place: String
    /// Space left of the "+" glyph (the host's own row inset).
    var leadingInset: CGFloat = 0
    /// Width of the "+" column. The middle list passes its checkbox column so the "+" centres on
    /// the child checkboxes above it; the inspector keeps the glyph width.
    var glyphColumn: CGFloat = Metrics.listCheckboxSize

    @State private var entry = EntryFieldModel(kind: .child)

    /// Anchor of the input field of this parent's row in `place`.
    static func fieldAnchor(place: String, parentID: UUID) -> String { "subtask.add.\(place).\(parentID.uuidString)" }

    var body: some View {
        EntryField(model: entry, placeholder: String(localized: "detail.subtasks.add"),
                   fieldAnchor: Self.fieldAnchor(place: place, parentID: parentID), autofocus: false,
                   style: .row, rowLeading: { AnyView(plusButton) }, onSubmit: add)
            .padding(.leading, leadingInset)
            .contentShape(Rectangle())
            .onTapGesture { entry.requestFocus() }
            .onAppear { entry.update(catalog: EntryCatalog.make(store: model.store)) }
            .onChange(of: model.version) { _, _ in entry.update(catalog: EntryCatalog.make(store: model.store)) }
            .onReceive(NotificationCenter.default.publisher(for: .kronosFocusAddSubtaskRequested)) { _ in
                if place == "inspector" { entry.requestFocus() }
            }
    }

    /// Frame and content shape INSIDE the label (a plain-style button is pressable only on its
    /// opaque pixels); the hit area grows past the glyph without changing layout.
    private var plusButton: some View {
        Button { entry.text.isEmpty ? entry.requestFocus() : add(.clear) } label: {
            let grow = (Metrics.minHit - Metrics.listCheckboxSize) / 2
            Icon("plus", size: Metrics.iconS).foregroundStyle(Tok.textTertiary)
                .frame(width: glyphColumn, height: Metrics.listCheckboxSize)
                .contentShape(Rectangle().inset(by: -grow))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "detail.subtasks.add"))
    }

    private func add(_ mode: EntrySubmitMode) {
        let drafts = ChildEntry.drafts(entry.text, pills: entry.pills, directory: entry.catalog.directory,
                                       today: entry.today(), languages: entry.languages)
        // Nothing to add (empty, or only tokens): keep what was typed, push no undo step.
        guard !drafts.isEmpty else { return }
        model.store.addChildren(to: parentID, drafts: drafts, undoName: "Add Step")
        model.didMutate()
        entry.clear(keepingPills: mode == .keepPills)
        entry.requestFocus()
    }
}

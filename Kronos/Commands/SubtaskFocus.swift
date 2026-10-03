// Kronos/Commands/SubtaskFocus.swift
// Which subtask the user is "on": the step row that has keyboard focus in the middle list or in
// the inspector. Cmd-[ (promote to a task) acts on it. Rows report focus changes here; the
// command asks `current(in:)`, which only answers when that subtask still exists and belongs to
// the selected task, so a focus left behind by arrow-key navigation can never promote a step the
// user is no longer looking at.
import Foundation
import SwiftUI

@MainActor
enum SubtaskFocus {
    private static var focusedID: UUID?

    /// Call from `.onChange(of: focusState)` of any row that can hold subtask focus.
    static func note(old: UUID?, new: UUID?) {
        if let new { focusedID = new } else if focusedID == old { focusedID = nil }
    }

    static func clear() { focusedID = nil }

    /// The focused subtask, or nil when none is focused, it is gone, or it is not a step of the
    /// task currently selected.
    static func current(in model: AppModel) -> UUID? {
        guard let id = focusedID, let ref = model.store.subtaskRef(id),
              ref.parentID != nil, ref.parentID == model.selectedTaskID else { return nil }
        return id
    }
}

extension View {
    /// Makes a subtask row focusable (click or Tab) and reports the focus to `SubtaskFocus`.
    /// A click also selects the parent task, so the inspector shows the task the step belongs to.
    @MainActor
    func subtaskFocusable(_ id: UUID, focus: FocusState<UUID?>.Binding, onSelectParent: @escaping () -> Void) -> some View {
        self
            .focusable()
            .focusEffectDisabled()
            .focused(focus, equals: id)
            .onChange(of: focus.wrappedValue) { old, new in SubtaskFocus.note(old: old, new: new) }
            .simultaneousGesture(TapGesture().onEnded {
                focus.wrappedValue = id
                onSelectParent()
            })
    }
}

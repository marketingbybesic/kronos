// Kronos/List/ListProjectPick.swift
// Key P on a row: the shared type-ahead project picker (Kronos/Shared/ProjectPicker.swift, the same
// one the inspector and the palette use, recents first), in a popover on the row. Type a few
// letters, Return files the task there with one undo step and the pill; Esc closes with no change.
import SwiftUI
import KronosCore

struct ListProjectPick: View {
    let model: AppModel
    let task: KTask
    let close: () -> Void

    var body: some View {
        ProjectPicker(model: model, currentProjectID: task.projectID,
                      onPick: { pick($0) },
                      onCancel: close)
            .frame(width: 280)
            .padding(Space.x3)
            .background(Tok.overlay)
            .uiTestAnchor("list.project.picker")
    }

    private func pick(_ project: KProject?) {
        close()
        guard task.projectID != project?.id else { return }
        model.store.move(task.id, toProject: project)
        model.commit(String(format: String(localized: "undo.moved.name"),
                            project?.name ?? String(localized: "detail.noproject")))
    }
}

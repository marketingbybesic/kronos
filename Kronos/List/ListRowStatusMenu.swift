// Kronos/List/ListRowStatusMenu.swift — the "Status" submenu of a task row's context menu.
// Wave 20 reduced the inspector's status control to one Waiting chip, so In progress, Someday
// and the rest stay one right-click away here. Own file: ListRowView sits at the 500-line cap.
import SwiftUI
import KronosCore

struct ListRowStatusMenu: View {
    let task: KTask
    let model: AppModel

    var body: some View {
        Menu(String(localized: "ctx.task.status")) {
            ForEach([KStatus.todo, .inProgress, .waiting, .someday], id: \.self) { st in
                Button(st.displayName) { model.store.setStatus(task.id, st); model.didMutate() }
            }
        }
    }
}

#if !RELEASE
// Kronos/List/ListKeySnapshots.swift
// Named screens for the snapshot harness: `list.legend` (the hold-⌥ key legend over the list),
// `list.empty.waiting` / `list.empty.someday` / `list.empty.project` (what an empty list is for
// and its one next step), `list.duefield` (the typed date field of a row). Mutations are deferred
// to `.onAppear` (see ListSnapshots).
import SwiftUI
import KronosCore

@MainActor
enum ListKeySnapshots {
    static func screens(model: AppModel) -> [String: AnyView] {
        [
            "list.legend": AnyView(legend(model: model)),
            "list.empty.waiting": AnyView(emptyScope(model: model, scope: .waiting, status: .waiting)),
            "list.empty.someday": AnyView(emptyScope(model: model, scope: .someday, status: .someday)),
            "list.empty.project": AnyView(emptyProject(model: model)),
            "list.duefield": AnyView(dueField()),
        ]
    }

    /// The All list with the legend up (the app shows it after a short ⌥ hold).
    private static func legend(model: AppModel) -> some View {
        TaskListScreen(model: model)
            .onAppear {
                model.chromaMode = .focus
                model.setOptions(.default, for: .all)
                model.scope = .all
                ListLegendState.shared.showNow()
            }
    }

    /// A fixed list with every task of its kind cleared out of the seed first.
    private static func emptyScope(model: AppModel, scope: ListScope, status: KStatus) -> some View {
        TaskListScreen(model: model)
            .onAppear {
                model.chromaMode = .focus
                let store = model.store
                for t in store.allTasks() where t.status == status { store.softDeleteNoUndo(t.id) }
                model.setOptions(.default, for: scope)
                model.scope = scope
                model.didMutate()
            }
    }

    /// A project with no tasks yet.
    private static func emptyProject(model: AppModel) -> some View {
        TaskListScreen(model: model)
            .onAppear {
                model.chromaMode = .focus
                let project = model.store.createProject(name: "Garden", colorHex: KProjectPalette.swatches[0].color.hexString,
                                                        icon: "folder", area: nil)
                model.scope = .project(project.id)
                model.didMutate()
            }
    }

    private static func dueField() -> some View {
        ListDueField(current: Day.today() + 1) { _ in }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Tok.bg)
    }
}
#endif

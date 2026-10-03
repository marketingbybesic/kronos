#if !RELEASE
// Kronos/List/ListSelectionSnapshots.swift
// Named screens for the selection-hue shots: `list.seltint.today` (Today with selected rows from
// two projects and one without a project, plus an unselected row for contrast),
// `list.seltint.project` (a project view: header mark + selected row), `list.seltint.child` (a
// child selected under its parent). Colour mode and accent come from the harness environment
// (KRONOS_SNAPSHOT_CHROMA, KRONOS_SNAPSHOT_ACCENT); text size from KRONOS_SNAPSHOT_PREFS.
// All mutations are deferred to `.onAppear`, like every fixture in ListSnapshots.
import SwiftUI
import KronosCore

@MainActor
enum ListSelectionSnapshots {
    static func screens(model: AppModel) -> [String: AnyView] {
        [
            "list.seltint.today": AnyView(today(model: model)),
            "list.seltint.project": AnyView(project(model: model)),
            "list.seltint.child": AnyView(child(model: model)),
        ]
    }

    private struct Fixture {
        let amber: KProject
        let blue: KProject
        let amberTasks: [KTask]
        let blueTask: KTask
        let plain: KTask
        let unselected: KTask
    }

    /// A project colour from the design system's palette, in the store's "#RRGGBB" form.
    private static func paletteHex(_ name: String) -> String {
        "#" + (KProjectPalette.swatches.first { $0.name == name }?.hex ?? KProjectPalette.swatches[0].hex)
    }

    private static func seed(_ model: AppModel, today: Int) -> Fixture {
        let store = model.store
        let amber = store.createProject(name: "Sel studio", colorHex: Self.paletteHex("orange"), icon: "camera", area: nil)
        let blue = store.createProject(name: "Sel office", colorHex: Self.paletteHex("cyan"), icon: "briefcase", area: nil)
        func make(_ title: String, _ p: KProject?, _ prio: KPriority) -> KTask {
            store.createNoUndo(title: title, notes: "", project: p, status: .todo, priority: prio, dueDay: today)
        }
        let a1 = make("Sel: edit the product photos", amber, .high)
        let b1 = make("Sel: send the invoice", blue, .medium)
        let n1 = make("Sel: call the landlord", nil, .none)
        let u1 = make("Sel: water the plants", amber, .low)
        let floor = (store.allTasks().map(\.sortIndex).min() ?? 0) - 8192
        for (i, t) in [a1, b1, n1, u1].enumerated() { store.updateNoUndo(t.id) { $0.sortIndex = floor + Double(i) * 1024 } }
        model.didMutate()
        return Fixture(amber: amber, blue: blue, amberTasks: [a1], blueTask: b1, plain: n1, unselected: u1)
    }

    private static func today(model: AppModel) -> some View {
        TaskListScreen(model: model)
            .onAppear {
                let day = Day.today()
                model.setOptions(.default, for: .today)
                model.scope = .today
                model.searchText = "Sel:"
                let f = seed(model, today: day)
                model.selectedTaskID = f.amberTasks[0].id
                model.selectedIDs = [f.amberTasks[0].id, f.blueTask.id, f.plain.id]
            }
    }

    private static func project(model: AppModel) -> some View {
        TaskListScreen(model: model)
            .onAppear {
                let f = seed(model, today: Day.today())
                model.setOptions(.default, for: .project(f.amber.id))
                model.scope = .project(f.amber.id)
                model.selectedTaskID = f.amberTasks[0].id
            }
    }

    private static func child(model: AppModel) -> some View {
        TaskListScreen(model: model)
            .onAppear {
                let f = seed(model, today: Day.today())
                model.setOptions(.default, for: .today)
                model.scope = .today
                model.searchText = "Sel:"
                let parent = f.amberTasks[0]
                let kid = model.store.addSubtaskNoUndo(parent.id, title: "Sel: pick the best twelve")
                _ = model.store.addSubtaskNoUndo(parent.id, title: "Sel: export for the web")
                model.didMutate()
                model.selectedTaskID = parent.id
                model.inspectedSubtaskID = kid?.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    NotificationCenter.default.post(name: .kronosExpandAllSubtasks, object: true)
                }
            }
    }
}
#endif

#if !RELEASE
// Kronos/List/ListChildSnapshots.swift
// `list.children`: the middle list with parents expanded, their child rows carrying every mark a
// child can show (due and the due source, priority, effort, one / two / three labels with a long
// name, link and notes indicators, done, a very long title). Used by the child-row snapshots at text
// size S/M/L in English and Croatian. Mutations are deferred to `.onAppear` (see ListSnapshots).
import SwiftUI
import KronosCore

@MainActor
enum ListChildSnapshots {
    static func list(model: AppModel) -> some View {
        TaskListScreen(model: model)
            .onAppear {
                model.chromaMode = .focus
                model.scope = .all
                model.setOptions(.default, for: .all)
                model.searchText = "Kid parent"
                seed(model)
                // The rows exist after the first layout pass; open every subtask list then.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    NotificationCenter.default.post(name: .kronosExpandAllSubtasks, object: true)
                }
            }
    }

    /// The same list with one child selected (inspected): its rounded selection plate shows.
    static func inspected(model: AppModel) -> some View {
        list(model: model)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard let parent = model.store.allTasks().first(where: { $0.title == "Kid parent: plan the move" }),
                          let child = parent.orderedChildren.first(where: { $0.title == "Pack the kitchen" }) else { return }
                    model.selectedTaskID = parent.id
                    model.inspectedSubtaskID = child.id
                }
            }
    }

    private static func seed(_ model: AppModel) {
        let store = model.store
        let today = Day.today()
        let work = store.label(named: "Work")
        let longName = store.label(named: "Quarterly planning review")
        let home = store.label(named: "Home")
        let weblink = ContextLink(kind: .web, reference: "https://example.com/a", displayName: "example.com").appending(to: "")
        let withText = ContextLink(kind: .web, reference: "https://example.com/b", displayName: "example.com").appending(to: "Call before noon")

        let parent = store.createNoUndo(title: "Kid parent: plan the move", notes: "", project: nil,
                                        status: .todo, priority: .none, dueDay: nil)
        let parent2 = store.createNoUndo(title: "Kid parent: prepare the review", notes: "", project: nil,
                                         status: .todo, priority: .medium, dueDay: today + 6)
        let floor = (store.allTasks().map(\.sortIndex).min() ?? 0) - 4096
        store.updateNoUndo(parent.id) { $0.sortIndex = floor }
        store.updateNoUndo(parent2.id) { $0.sortIndex = floor + 1024 }

        func child(_ parentID: UUID, _ title: String, due: Int? = nil, priority: KPriority = .none, effort: KEffort = .none,
                   labels: [KLabel] = [], notes: String = "", done: Bool = false) {
            guard let c = store.addSubtaskNoUndo(parentID, title: title) else { return }
            store.updateNoUndo(c.id) {
                $0.dueDay = due
                $0.priority = priority
                $0.effortRaw = effort.rawValue
                $0.notes = notes
            }
            for l in labels { store.addLabel(l, to: c.id) }
            if done { store.toggleSubtaskNoUndo(c.id, isDone: true) }
        }
        child(parent.id, "Plain step")
        child(parent.id, "Book the van", due: today, priority: .high, effort: .m)          // the due source
        child(parent.id, "Pack the kitchen", due: today + 9, priority: .low, effort: .l, labels: [work])
        child(parent.id, "Change the address everywhere and tell every single person who needs to know before Friday", due: today + 12, priority: .urgent, effort: .xl, labels: [work, home, longName], notes: withText)
        child(parent.id, "Done step", due: today - 2, labels: [home], notes: weblink, done: true)
        child(parent2.id, "Slides", due: today + 3, priority: .medium, labels: [longName])
        child(parent2.id, "Numbers", effort: .s, notes: withText)
        store.updateNoUndo(parent.id) { _ in }
        model.didMutate()
    }
}
#endif

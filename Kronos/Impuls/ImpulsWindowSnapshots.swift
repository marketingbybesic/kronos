#if !RELEASE
// Kronos/Impuls/ImpulsWindowSnapshots.swift — the two Impuls-leaf snapshot screens that render the
// WINDOW's own composition (list column with the morning plan; Today list with a rich Now card).
// Like ImpulsSnapshots.swift, all sample data is planted inside `.onAppear`, never at construction.

import SwiftUI
import KronosCore

/// The morning plan inline above the list, composed exactly as the window composes it.
struct SeededMorning: View {
    let model: AppModel
    var sunday = false
    @State private var showsMorning = true
    @State private var didSeed = false

    var body: some View {
        ListWithMorningPlan(model: model, showsMorning: $showsMorning)
            .onAppear {
                guard !didSeed else { return }
                didSeed = true
                MorningPlan.weekdayOverride = sunday ? 1 : nil
                for t in model.store.allTasks() { model.store.softDeleteNoUndo(t.id) }
                model.scope = .today
                let names = ["Nazovi Alex oko termina", "Write the first line of the Globex caption", "Plati račun za struju"]
                for (i, title) in names.enumerated() {
                    let task = model.store.create(title: title, notes: "", project: nil,
                                                  status: .todo, priority: .none, dueDay: nil)
                    model.store.setDepth(task.id, i == 1 ? .deep : .shallow)
                }
                model.didMutate()
            }
    }
}

/// The Today list with a Now card that has a step, a notes line and the three actions.
struct SeededNowCard: View {
    let model: AppModel
    @State private var didSeed = false

    var body: some View {
        TaskListScreen(model: model)
            .onAppear {
                guard !didSeed else { return }
                didSeed = true
                for t in model.store.allTasks() { model.store.softDeleteNoUndo(t.id) }
                model.scope = .today
                let task = model.store.create(title: "Send the September invoice to Acme", notes: "Alex wants the PDF, not a link",
                                              project: nil, status: .todo, priority: .high, dueDay: Day.today())
                model.store.setDepth(task.id, .shallow)
                task.effort = .l
                model.didMutate()
            }
    }
}
#endif

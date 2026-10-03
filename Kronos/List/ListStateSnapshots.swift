#if !RELEASE
// Kronos/List/ListStateSnapshots.swift
// Named screens for the snapshot harness: `list.dates` (how dates read: an earlier date muted,
// Today, weekdays for the next six days, then a short date; no verdict word), `list.todayclear`
// (Today with nothing left: "Today is clear. N done."), `list.undopill.next` (the completion pill
// handing off to the next task). Mutations are deferred to `.onAppear` (see ListSnapshots).
import SwiftUI
import KronosCore

@MainActor
enum ListStateSnapshots {
    static func screens(model: AppModel) -> [String: AnyView] {
        [
            "list.dates": AnyView(datesList(model: model)),
            "list.todayclear": AnyView(todayClear(model: model)),
            "list.undopill.next": AnyView(nextPill()),
            "list.earlier": AnyView(earlierList(model: model)),
        ]
    }

    private static func datesList(model: AppModel) -> some View {
        TaskListScreen(model: model)
            .onAppear {
                model.chromaMode = .focus
                model.setOptions(.default, for: .all)
                model.scope = .all
                model.searchText = "Date row:"
                let store = model.store
                let today = Day.today()
                let specs: [(String, Int, Int?)] = [
                    ("Date row: carried from last week", today - 5, today - 8),
                    ("Date row: was due yesterday", today - 1, nil),
                    ("Date row: due today", today, nil),
                    ("Date row: due tomorrow", today + 1, nil),
                    ("Date row: due in three days", today + 3, nil),
                    ("Date row: due in six days", today + 6, nil),
                    ("Date row: due in nine days", today + 9, nil),
                    ("Date row: due next month", today + 33, nil),
                ]
                let floor = (store.allTasks().map(\.sortIndex).min() ?? 0) - Double(specs.count + 1) * 1024
                for (i, spec) in specs.enumerated() {
                    let t = store.createNoUndo(title: spec.0, notes: "", project: nil, status: .todo, priority: .medium, dueDay: spec.1)
                    store.updateNoUndo(t.id) {
                        $0.sortIndex = floor + Double(i) * 1024
                        $0.originalDueDay = spec.2
                    }
                }
                model.didMutate()
            }
    }

    /// Everything Today would show is parked (soft-deleted in the hermetic snapshot store) and
    /// three tasks were finished today, so the empty state reads "Today is clear. 3 done."
    private static func todayClear(model: AppModel) -> some View {
        TaskListScreen(model: model)
            .onAppear {
                model.chromaMode = .focus
                model.setOptions(.default, for: .today)
                model.scope = .today
                let store = model.store
                let now = Date()
                let ctx = ListContext(model: model)
                for id in (ctx.rows + ctx.earlier).map(\.id) { store.updateNoUndo(id) { $0.deletedAt = now } }
                for title in ["Clear: send the invoice", "Clear: book the van", "Clear: call the bank"] {
                    let t = store.createNoUndo(title: title, notes: "", project: nil, status: .todo, priority: .none, dueDay: Day.today())
                    store.completeNoUndo(t.id)
                }
                model.didMutate()
            }
    }

    /// Today with five tasks carried from four days ago: they sit under the collapsed
    /// "Earlier (5)" header after today's own rows.
    private static func earlierList(model: AppModel) -> some View {
        TaskListScreen(model: model)
            .onAppear {
                model.chromaMode = .focus
                model.setOptions(.default, for: .today)
                model.scope = .today
                ListEarlierState.shared.isExpanded = false
                let store = model.store
                let today = Day.today()
                let now = Date()
                for id in ListContext(model: model).earlier.map(\.id) { store.updateNoUndo(id) { $0.deletedAt = now } }
                for title in ["Call the printer about the proofs", "Send the September invoice"] {
                    _ = store.createNoUndo(title: title, notes: "", project: nil, status: .todo, priority: .medium, dueDay: today)
                }
                for i in 1...5 {
                    let t = store.createNoUndo(title: "Carried task \(i)", notes: "", project: nil, status: .todo, priority: .none, dueDay: today - 4)
                    store.updateNoUndo(t.id) { $0.carryCount = 4; $0.originalDueDay = today - 4 }
                }
                model.didMutate()
            }
    }

    private static func nextPill() -> some View {
        KUndoPill(message: String(format: String(localized: "undo.donenext"), "Open the invoice template and fill in the line items"),
                  primaryTitle: String(localized: "undo.donenext.start"), onPrimary: {},
                  onUndo: {}, onExpire: {})
            .padding(Space.x6)
            .frame(width: 560, height: 120)
            .background(Tok.bg)
    }
}
#endif

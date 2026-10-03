// Live steps for the inspector's drafts:
//  A. a first move filled by the store while the task is selected (what auto-triage does) is
//     still there after the selection moves on, and leaving pushes no undo step;
//  B. a title typed into the real field, never blurred, is on disk (a fresh ModelContext reads
//     it) after `kronos.flushDrafts`, and again after the app resigns active.
#if !RELEASE
import AppKit
import SwiftData
import KronosCore

@MainActor
extension LiveUITest {

    private static func aInspSettle(_ ms: Int = 500) async { try? await Task.sleep(for: .milliseconds(ms)) }

    /// What a second reader of the same store sees: only saved state is visible to it.
    private static func aInspFreshTitle(_ model: AppModel, _ id: UUID) -> String? {
        let context = ModelContext(model.store.container)
        let rows = try? context.fetch(FetchDescriptor<KTask>()).filter { $0.id == id }
        return rows?.first?.title
    }

    private static func aInspFreshFirstMove(_ model: AppModel, _ id: UUID) -> String? {
        let context = ModelContext(model.store.container)
        let rows = try? context.fetch(FetchDescriptor<KTask>()).filter { $0.id == id }
        return rows?.first?.firstMove
    }

    /// Types at the caret (a synthetic ⌘A is not delivered to the field editor); the steps assert containment.
    private static func aInspTypeAll(_ text: String) async {
        for ch in text { key(String(ch)); try? await Task.sleep(for: .milliseconds(25)) }
        await aInspSettle(250)
    }

    static func aInspectorSteps(_ model: AppModel) async {
        let breakMode = ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil
        let store = model.store
        var frame = window.frame
        frame.size = NSSize(width: 1500, height: 900)
        window.setFrame(frame, display: true)
        await aInspSettle(700)
        window.makeKeyAndOrderFront(nil)

        let filled = store.create(title: "Draft fill task", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        let other = store.create(title: "Draft other task", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        let typed = store.create(title: "Draft typed task", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        model.didMutate()
        model.scope = .all
        model.searchText = ""
        model.inspectedSubtaskID = nil
        await aInspSettle(500)   // the shell clears the selection when the scope changes: select after that has run
        defer {
            for id in [filled.id, other.id, typed.id] { store.softDelete(id) }
            model.selectedTaskID = nil
            model.didMutate()
        }

        // A. The store fills the first move while the task is open; leaving must keep it.
        model.selectedTaskID = filled.id
        await aInspSettle(800)
        let moveText = "Call the bank about the card"
        store.setFirstMove(filled.id, moveText)
        model.didMutate()
        await aInspSettle(600)
        let depthBefore = store.undoDepth
        model.selectedTaskID = other.id
        await aInspSettle(700)
        let wantMove = breakMode ? "" : moveText
        let kept = aInspFreshFirstMove(model, filled.id)
        record("inspector-drafts-fill-kept: a first move filled while the task is selected survives leaving it, with no undo step pushed",
               kept == wantMove && store.undoDepth == depthBefore,
               "firstMove=\(String(describing: kept)) depth \(depthBefore)->\(store.undoDepth)")

        // B. A typed, never-blurred title is saved by the flush notification and by deactivation.
        model.selectedTaskID = typed.id
        await aInspSettle(800)
        let focused = await click("inspector.title")
        await aInspSettle(400)
        await aInspTypeAll("Zq flush title")
        let beforeFlush = aInspFreshTitle(model, typed.id)
        NotificationCenter.default.post(name: .kronosFlushDrafts, object: nil)
        await aInspSettle(300)
        let afterFlush = aInspFreshTitle(model, typed.id)
        let wantFlush = breakMode ? "never typed" : "Zq flush title"
        let flushed = afterFlush ?? ""
        record("inspector-drafts-flush: a title typed into the field is read back by a fresh context after the flush notification",
               focused && beforeFlush == "Draft typed task" && flushed.contains(wantFlush),
               "focused=\(focused) before=\(String(describing: beforeFlush)) after=\(String(describing: afterFlush))")

        await aInspTypeAll("Yx resign title")
        let beforeResign = aInspFreshTitle(model, typed.id)
        NotificationCenter.default.post(name: NSApplication.willResignActiveNotification, object: NSApp)
        await aInspSettle(300)
        let afterResign = aInspFreshTitle(model, typed.id)
        record("inspector-drafts-resign: a title typed into the field is read back by a fresh context after the app resigns active",
               beforeResign == afterFlush && (afterResign ?? "").contains("Yx resign title"),
               "before=\(String(describing: beforeResign)) after=\(String(describing: afterResign))")
        window.makeKeyAndOrderFront(nil)
    }
}
#endif

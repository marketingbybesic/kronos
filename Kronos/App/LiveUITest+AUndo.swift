// Live steps for undo and the Inbox default. Run alone with `--only group:A-UNDO`.
#if !RELEASE
import AppKit
import KronosCore

@MainActor
extension LiveUITest {
    static func aUndoSteps(_ model: AppModel) async {
        await undatedCaptureLandsInInbox(model)
        await machineWriteSurvivesUndo(model)
    }

    /// The global quick add panel (the window behind ⌃⌥K) files a task typed with no date in the
    /// Inbox: open todo, no due day, no project, and not in Someday.
    private static func undatedCaptureLandsInInbox(_ model: AppModel) async {
        let store = model.store
        let main = window!
        AppDelegate.shared.quickAdd.toggle()
        try? await Task.sleep(for: .milliseconds(900))
        guard let panel = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible && $0 !== main && $0.canBecomeKey }) else {
            record("undated quick add capture: panel opens", false, "no visible key-capable panel"); return
        }
        window = panel
        for ch in "Inbox capture probe" { key(String(ch)); try? await Task.sleep(for: .milliseconds(25)) }
        try? await Task.sleep(for: .milliseconds(300))
        key("\r", keyCode: 36)
        try? await Task.sleep(for: .milliseconds(700))
        window = main
        let made = store.allTasks().first { $0.title == "Inbox capture probe" }
        let today = Day.today(calendar: KronosLocale.calendar)
        let inInbox = made.map { ScopeFilter.matches($0, scope: .inbox, today: today) } ?? false
        let inSomeday = made.map { ScopeFilter.matches($0, scope: .someday, today: today) } ?? true
        let ok = made?.status == .todo && made?.dueDay == nil && made?.projectID == nil && inInbox && !inSomeday
        record("undated quick add capture lands in the Inbox as an open todo",
               ok, "status=\(String(describing: made?.status)) due=\(String(describing: made?.dueDay)) project=\(String(describing: made?.projectID)) inbox=\(inInbox) someday=\(inSomeday)")
        if panel.isVisible { AppDelegate.shared.quickAdd.toggle(); try? await Task.sleep(for: .milliseconds(400)) }
        main.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(400))
    }

    /// A user edit, then an agent write to another field through the machine path, then the real
    /// Cmd-Z key: the edit is undone, the agent's write is still there. Setting the same value again
    /// must not add a step.
    private static func machineWriteSurvivesUndo(_ model: AppModel) async {
        let store = model.store
        let breakMode = ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil
        let t = store.create(title: "Undo clobber probe")
        store.setPriority(t.id, .high)
        let depth = store.undoDepth
        store.setPriority(t.id, .high)
        let noStep = store.undoDepth == depth
        store.updateNoUndo(t.id) { $0.notes = "written by an agent" }
        model.didMutate()
        try? await Task.sleep(for: .milliseconds(300))

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)
        key("z", modifiers: .command, keyCode: 6)
        try? await Task.sleep(for: .milliseconds(500))
        if store.task(t.id)?.priority == .high, let item = undoMenuItem(), let menu = item.menu {
            menu.performActionForItem(at: menu.index(of: item))
            try? await Task.sleep(for: .milliseconds(400))
        }
        let priority = store.task(t.id)?.priority
        let notes = store.task(t.id)?.notes
        let wantNotes = breakMode ? "" : "written by an agent"
        record("Cmd-Z undoes the user step and keeps an agent write to another field; same value adds no step",
               priority == KPriority.none && notes == wantNotes && noStep,
               "priority=\(String(describing: priority)) notes=\(notes ?? "nil") noStep=\(noStep)")
    }
}
#endif

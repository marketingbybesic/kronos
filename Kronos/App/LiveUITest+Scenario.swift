// Kronos/App/LiveUITest+Scenario.swift
// The first live scenario: sidebar, row selection, priority keys, complete + undo, subtask arrow, inline add.
#if !RELEASE
import AppKit
import SwiftUI
import KronosCore

@MainActor
extension LiveUITest {
    // MARK: Scenario

    static func scenario(_ model: AppModel) async {
        let breakMode = ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil
        let store = model.store
        // A fixed window, like the later steps: the size the app last saved varies run to run. At a
        // 1144 pt window the row click at 45 % did not select (measured); at 1500 it selects in < 200 ms.
        await setWindowSize(width: 1500, height: 900)
        await waitStable { UITestAnchors.frames["sidebar.Waiting"] ?? .zero }

        // 1. One click on a sidebar list switches the list. Timed: a prior report was of lag here.
        for (label, scope) in [("Waiting", ListScope.waiting), ("Someday", .someday), ("All", .all)] {
            let t0 = Date()
            await ensureKey()
            let found = await click("sidebar." + label)
            let want: ListScope = (breakMode && label == "Waiting") ? .inbox : scope
            await waitUntil { model.scope == want }
            record("sidebar one click -> \(label)", found && model.scope == want,
                   "found=\(found) scope=\(model.scope) ms=\(Int(Date().timeIntervalSince(t0) * 1000))")
        }

        // 2. One click on a row selects it.
        let open = store.allTasks().filter { KStatus.open.contains($0.status) }
        guard let target = open.first(where: { $0.orderedChildren.isEmpty }) else { record("has a plain task", false, ""); return }
        var ok = await click("row." + target.title, xFraction: 0.45)
        await waitUntil { model.selectedTaskID == target.id }
        record("row one click selects", ok && model.selectedTaskID == target.id, "found=\(ok) selected=\(String(describing: model.selectedTaskID))")

        // 3. Keys right after that click, no second click: 3 sets priority, 0 clears it.
        key("3"); await waitUntil { store.task(target.id)?.priority == .high }
        record("key 3 sets priority high", store.task(target.id)?.priority == .high, "\(String(describing: store.task(target.id)?.priority))")
        let wasHigh = store.task(target.id)?.priority == .high
        key("0"); await waitUntil { store.task(target.id)?.priority == KPriority.none }
        record("key 0 clears priority", wasHigh && store.task(target.id)?.priority == KPriority.none, "\(String(describing: store.task(target.id)?.priority))")

        // 4. Clicking the circle completes; Cmd-Z brings it back (no 5 s limit: we wait 6).
        ok = await click("row." + target.title, xOffset: 6 + Metrics.listRowLeading + Metrics.listCheckboxSize / 2)
        await waitUntil { store.task(target.id)?.status == .done }
        record("circle click completes", ok && store.task(target.id)?.status == .done, "found=\(ok) status=\(String(describing: store.task(target.id)?.status))")
        let wasDone = store.task(target.id)?.status == .done
        // The point of the step: the undo pill used to vanish after 5 s. A fixed wait is the test itself here.
        try? await Task.sleep(for: .seconds(6))
        await ensureKey()
        key("z", modifiers: .command, keyCode: 6); await waitUntil(timeout: 1.5) { store.task(target.id)?.status != .done }
        if store.task(target.id)?.status == .done {
            // Separate "the command is broken" from "my synthetic key never reached the menu".
            let item = undoMenuItem()
            diagnostics.append("undo item: \(item.map { "'\($0.title)' enabled=\($0.isEnabled) key=\($0.keyEquivalent) mods=\($0.keyEquivalentModifierMask.rawValue)" } ?? "NOT FOUND") canUndo=\(store.canUndo)")
            if let item, let menu = item.menu { menu.performActionForItem(at: menu.index(of: item)) }
            await waitUntil { store.task(target.id)?.status != .done }
            diagnostics.append("after performing the Undo menu item directly: status=\(String(describing: store.task(target.id)?.status))")
        }
        record("Undo after 6 s reopens (Cmd-Z key, else the enabled Undo menu item)", wasDone && store.task(target.id)?.status == .todo, "status=\(String(describing: store.task(target.id)?.status))")

        // 5. The subtask arrow lists the subtasks.
        // Only a parent whose arrow is on screen can be clicked: the list is lazy, so a task far down is not rendered.
        let rendered = open.filter { !$0.orderedChildren.isEmpty && UITestAnchors.frames["arrow." + $0.title] != nil }
        if let parent = rendered.first, let sub = parent.orderedSubtasks.first {
            let before = UITestAnchors.frames["subrow." + sub.title] != nil
            ok = await click("arrow." + parent.title)
            await waitUntil { UITestAnchors.frames["subrow." + sub.title] != nil }
            let after = UITestAnchors.frames["subrow." + sub.title] != nil
            record("subtask arrow expands", ok && !before && after, "found=\(ok) before=\(before) after=\(after)")
            // 5b. E closes and reopens every subtask list (row selected first, so the list has the keys).
            _ = await click("row." + target.title, xFraction: 0.45)
            await waitUntil { model.selectedTaskID == target.id }
            // The list may already be in the state the key leads to, so there is no change to wait for: settle.
            key("e"); await settle(500)
            let openAll = UITestAnchors.frames["subrow." + sub.title] != nil
            key("e"); await settle(500)
            let closedAll = UITestAnchors.frames["subrow." + sub.title] == nil
            record("E opens then closes all subtasks", openAll && closedAll, "open=\(openAll) closed=\(closedAll)")
        } else { record("has a task with subtasks", false, "") }

        // 6. Inline new task: click the field, type WITH spaces and syntax, Return.
        let countBefore = store.allTasks().count
        ok = await click("inlineadd.field", xFraction: 0.3)
        await waitUntil { window.firstResponder is NSTextView }
        diagnostics.append("after clicking the inline field: firstResponder=\(window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")")
        diagnostics.append("isTyping inputs: keyWindowIsMain=\(NSApp.keyWindow === window) keyWindow=\(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "nil") frIsTextView=\(window.firstResponder is NSTextView) keyFrIsTextView=\(NSApp.keyWindow?.firstResponder is NSTextView)")
        await typeText("Buy oat milk !! tomorrow")
        diagnostics.append("typed into the field: \"\((window.firstResponder as? NSTextView)?.string ?? "<not a text view>")\"")
        key("\r", keyCode: 36); await waitUntil { store.allTasks().contains { $0.title == "Buy oat milk" } }
        await waitUntil { (window.firstResponder as? NSTextView)?.string.isEmpty == true }
        diagnostics.append("after Return: field=\"\((window.firstResponder as? NSTextView)?.string ?? "<none>")\" responder=\(window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")")
        let made = store.allTasks().first { $0.title == "Buy oat milk" }
        record("inline add: spaces, syntax, Return", ok && store.allTasks().count == countBefore + 1 && made?.priority == .medium
               && made?.dueDay == Day.today(calendar: KronosLocale.calendar) + 1,
               "found=\(ok) count=\(store.allTasks().count - countBefore) title=\(made?.title ?? "nil") prio=\(String(describing: made?.priority)) due=\(String(describing: made?.dueDay))")

        // 6b. Subtasks from the same field: "Task > sub > sub" makes one task with two subtasks.
        await typeText("Plan trip > book flight > book hotel")
        key("\r", keyCode: 36); await waitUntil { store.allTasks().first { $0.title == "Plan trip" }?.orderedSubtasks.count == 2 }
        let trip = store.allTasks().first { $0.title == "Plan trip" }
        record("inline add: Task > sub > sub", trip?.orderedSubtasks.map(\.title) == ["book flight", "book hotel"],
               "subtasks=\(trip?.orderedSubtasks.map(\.title) ?? [])")

        await triageKeys(model, leaveFieldBy: "row." + target.title)
        await quickAddPanelTypes(model)
        await entryFieldPanelSteps(model)
        await entrySurfaceSteps(model)
        await subtaskEntrySteps(model)
        await noteLinkButton(model)
        await childModeLinksTargetChild(model)
    }
}
#endif

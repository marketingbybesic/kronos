// Kronos/App/LiveUITest+Keys.swift
// Regression steps for the live-test findings on keyboard handling:
//  A. the FIRST Cmd-Z after Space (complete) / H (snooze) did nothing, because moving the selection
//     made the inspector commit its drafts through `store.update`, which always pushes an undo
//     step, burying the real one under a no-op. Judged by invoking the real Undo menu item ONCE
//     (the exact Button action Cmd-Z runs), so a synthetic Cmd chord that never reaches the menu
//     cannot hide or fake the bug. Positive control: priority key 3, which never moves the
//     selection and always worked.
//  B. Backspace (keyCode 51, character U+007F) on a selected row deletes it, with the undo pill.
//  C. Cmd-/ opens the keymap overlay (US keycode 44 and Croatian keycode 27).
#if !RELEASE
import AppKit
import KronosCore

@MainActor
extension LiveUITest {

    /// Invokes the Undo menu item once, like Cmd-Z. Returns false when no such item exists.
    private static func performUndoMenuItem() -> Bool {
        guard let item = undoMenuItem(), let menu = item.menu else { return false }
        menu.performActionForItem(at: menu.index(of: item))
        return true
    }

    static func keysStep(_ model: AppModel) async {
        let store = model.store
        model.selectedTaskID = nil
        // The inspector is the part that moved the bug: selection change makes it commit its drafts.
        // It auto-collapses in a narrow window, so widen the window first (the undoStepsAdded count proves it is mounted).
        var frame = window.frame
        frame.size = NSSize(width: max(frame.width, 1500), height: max(frame.height, 800))
        window.setFrame(frame, display: true)
        try? await Task.sleep(for: .milliseconds(700))
        // Plain open tasks that are on screen right now (anchors report the rendered rows).
        let candidates = store.allTasks().filter {
            KStatus.open.contains($0.status) && $0.orderedChildren.isEmpty && UITestAnchors.frames["row." + $0.title] != nil
        }
        guard candidates.count >= 3 else { record("keys: three visible plain tasks", false, "found \(candidates.count)"); return }
        let (a, b, c) = (candidates[0], candidates[1], candidates[2])

        func select(_ t: KTask) async -> Bool {
            let ok = await click("row." + t.title, xFraction: 0.45)
            try? await Task.sleep(for: .milliseconds(300))
            return ok && model.selectedTaskID == t.id
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(500)) }

        // Positive control: priority (selection does not move) then ONE undo restores.
        var ok = await select(a)
        let prioBefore = a.priority
        key(prioBefore == .high ? "2" : "3"); await settle()
        let prioChanged = store.task(a.id)?.priority != prioBefore
        let ranControl = performUndoMenuItem(); await settle()
        record("keys control: priority key then ONE Undo restores", ok && prioChanged && ranControl && store.task(a.id)?.priority == prioBefore,
               "selected=\(ok) changed=\(prioChanged) menu=\(ranControl) now=\(String(describing: store.task(a.id)?.priority))")

        // A. Space completes, selection moves, FIRST undo reopens.
        ok = await select(b)
        let depth0 = store.undoDepth
        key(" ", keyCode: 49); await settle()
        let depthDelta = store.undoDepth - depth0
        let completed = store.task(b.id)?.status == .done
        let moved = model.selectedTaskID != b.id
        let ran = performUndoMenuItem(); await settle()
        record("keys: Space completes, then the FIRST Undo reopens it", ok && completed && depthDelta == 1 && ran && store.task(b.id)?.status == .todo,
               "selected=\(ok) completed=\(completed) selectionMoved=\(moved) undoStepsAdded=\(depthDelta) menu=\(ran) status=\(String(describing: store.task(b.id)?.status))")

        // A. H snoozes (plans the task for tomorrow; the deadline is never touched), selection
        // moves, FIRST undo restores the plan, the due day and the status.
        ok = await select(c)
        let dueBefore = store.task(c.id)?.dueDay, statusBefore = store.task(c.id)?.status
        let plannedBefore = store.task(c.id)?.plannedDay
        key("h"); await settle()
        let snoozed = store.task(c.id)?.plannedDay != plannedBefore && store.task(c.id)?.dueDay == dueBefore
        let ran2 = performUndoMenuItem(); await settle()
        record("keys: H snoozes, then the FIRST Undo restores it", ok && snoozed && ran2
               && store.task(c.id)?.plannedDay == plannedBefore
               && store.task(c.id)?.dueDay == dueBefore && store.task(c.id)?.status == statusBefore,
               "selected=\(ok) snoozed=\(snoozed) menu=\(ran2) planned=\(String(describing: store.task(c.id)?.plannedDay)) was=\(String(describing: plannedBefore)) due=\(String(describing: store.task(c.id)?.dueDay)) was=\(String(describing: dueBefore))")

        // B. Backspace deletes the selected row (no text field is being edited), Undo restores it.
        ok = await select(a)
        let fr = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        key("\u{7F}", keyCode: 51); await settle()
        let gone = store.task(a.id) == nil
        _ = performUndoMenuItem(); await settle()
        record("keys: Backspace deletes the selected task, Undo restores it", ok && gone && store.task(a.id) != nil,
               "selected=\(ok) firstResponder=\(fr) deleted=\(gone) restored=\(store.task(a.id) != nil)")

        // C. Cmd-/ opens the keymap overlay on both layouts (US key 44, Croatian key 27 both print "/").
        for (label, keyCode) in [("US", UInt16(44)), ("HR", UInt16(27))] {
            model.isKeymapOpen = false
            try? await Task.sleep(for: .milliseconds(200))
            key("/", modifiers: .command, keyCode: keyCode); await settle()
            let opened = model.isKeymapOpen
            record("keys: Cmd-/ opens the keymap overlay (\(label), keycode \(keyCode))", opened, "isKeymapOpen=\(opened)")
            model.isKeymapOpen = false
        }
    }
}
#endif

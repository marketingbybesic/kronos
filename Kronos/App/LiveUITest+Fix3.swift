// Kronos/App/LiveUITest+Fix3.swift
// Live steps for three user reports, driven through the REAL surfaces and judged on model/store
// state and on the anchors the views report:
//  fix3.1  Shift-Cmd-N inside an add field inserts the subtask marker ">" at the caret and shows a
//          visible flash; with no add field focused it still opens Capture (positive control).
//          Judged by performing the real "Capture" menu item, the exact action the chord runs.
//  fix3.2  Cmd-Return in the Capture paste field reaches the review step (real key events through
//          the window), Cmd-Return in review creates, and the menu-bar "Find tasks" hand-off
//          (`openCapture(with:)`) lands on review too.
//  fix3.3  A review row that duplicates an open task offers "Merge tasks" and "Create anyway"
//          instead of blocking; merge keeps one task and fills it, create-anyway makes a second,
//          the first undo reverses either, and Cmd-Return on an untouched duplicate row is never
//          a dead end.
#if !RELEASE
import AppKit
import KronosCore

@MainActor
extension LiveUITest {

    // MARK: Helpers

    /// The real path: events posted to the app's queue pass through local key monitors, which
    /// `NSApp.sendEvent` called directly would skip (a first version of these steps did that and
    /// judged only the SwiftUI fallback).
    private static func keySync(_ chars: String, modifiers: NSEvent.ModifierFlags = [], keyCode: UInt16) {
        key(chars, modifiers: modifiers, keyCode: keyCode)
    }


    /// The NSTextView that sits under the centre of an anchored view.
    private static func textView(at anchor: String) -> NSTextView? {
        guard let p = point(anchor), let content = window.contentView else { return nil }
        func walk(_ v: NSView) -> NSTextView? {
            if let tv = v as? NSTextView, !tv.isHidden, tv.convert(tv.bounds, to: nil).contains(p) { return tv }
            for s in v.subviews { if let f = walk(s) { return f } }
            return nil
        }
        return walk(content)
    }

    private static func setText(_ tv: NSTextView, _ text: String, caret: Int? = nil) {
        tv.window?.makeFirstResponder(tv)
        tv.selectAll(nil)
        tv.insertText(text, replacementRange: tv.selectedRange())
        let at = caret ?? (text as NSString).length
        tv.setSelectedRange(NSRange(location: at, length: 0))
    }

    /// The menu item a chord runs: key equivalent + exact modifier mask.
    private static func menuItem(key: String, modifiers: NSEvent.ModifierFlags) -> NSMenuItem? {
        func find(_ menu: NSMenu?) -> NSMenuItem? {
            for item in menu?.items ?? [] {
                if item.keyEquivalent.lowercased() == key,
                   item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == modifiers { return item }
                if let hit = find(item.submenu) { return hit }
            }
            return nil
        }
        return find(NSApp.mainMenu)
    }

    private static func perform(_ item: NSMenuItem) {
        if let menu = item.menu { menu.performActionForItem(at: menu.index(of: item)) }
    }

    private static func openTasks(titled title: String, _ store: TaskStore) -> [KTask] {
        store.allTasks().filter { KStatus.open.contains($0.status) && KTextFold.fold($0.title) == KTextFold.fold(title) }
    }

    /// Closing the quick add panel hands activation back to the previous app a moment later: wait
    /// until the main window is really key again, or a key event goes nowhere and the step lies.
    private static func ensureKeyWindow() async {
        await ensureKey(window)
    }

    private static func openCapture(_ model: AppModel, text: String? = nil) async {
        await ensureKeyWindow()
        model.isCaptureOpen = false
        await settle(300)
        if let text { model.openCapture(with: text) } else { model.isCaptureOpen = true }
        await settle(900)
    }

    private static func closeCapture(_ model: AppModel) async {
        model.isCaptureOpen = false
        await settle(300)
    }

    // MARK: Entry

    static func fix3Step(_ model: AppModel) async {
        await fix31Marker(model)
        await fix31StaleExpiry(model)
        await fix32FindTasks(model)
        await fix33Merge(model)
    }

    // MARK: 1. Shift-Cmd-N always opens Capture

    private static func fix31Marker(_ model: AppModel) async {
        guard let chord = menuItem(key: "n", modifiers: [.command, .shift]) else {
            record("fix3.1 the Shift-Cmd-N menu item exists", false, "no item"); return
        }
        // Control: nothing focused -> the chord still opens Capture.
        model.isCaptureOpen = false
        window.makeFirstResponder(window.contentView)
        await settle(300)
        perform(chord); await settle(600)
        record("fix3.1 control: with no add field focused Shift-Cmd-N opens Capture", model.isCaptureOpen, "isCaptureOpen=\(model.isCaptureOpen)")

        // With the caret in the Capture paste field the chord means the same thing: nothing is typed
        // into the field (no marker), Capture stays open.
        await openCapture(model)
        guard let tv = textView(at: "capture.paste") else { record("fix3.1 Capture paste field found", false, "no text view"); await closeCapture(model); return }
        setText(tv, "Prepare the offer")
        perform(chord); await settle(250)
        record("fix3.1 in an add field Shift-Cmd-N types nothing and Capture stays open",
               tv.string == "Prepare the offer" && UITestAnchors.frames["capture.paste"] != nil && model.isCaptureOpen,
               "text=\(tv.string.debugDescription) open=\(model.isCaptureOpen)")
        record("fix3.1 no marker confirmation appears", UITestAnchors.frames["subtask.marker.flash"] == nil,
               "flash anchor=\(UITestAnchors.frames["subtask.marker.flash"] != nil)")
        await closeCapture(model)
        await ensureKeyWindow()
        record("fix3.1 the main window is key again after Capture", window.isKeyWindow, "key=\(window.isKeyWindow) active=\(NSApp.isActive)")
    }

    /// Root cause of "Shift-Cmd-N does not work reliably": the done step's undo pill closed the
    /// Capture that was open five seconds after IT appeared, even when a newer Capture had been
    /// opened since. Create tasks, dismiss, reopen at once, wait past the pill's window.
    private static func fix31StaleExpiry(_ model: AppModel) async {
        await openCapture(model, text: "Fix3 stale expiry probe")
        keySync("\r", modifiers: .command, keyCode: 36); await settle(700)        // review -> create -> done
        let reachedDone = UITestAnchors.frames["capture.done"] != nil
        model.isCaptureOpen = false                                              // dismissed before the pill expires
        await settle(300)
        model.isCaptureOpen = true                                               // reopened (what Shift-Cmd-N does)
        await settle(Int(Motion.undoWindow * 1000) + 1200)
        record("fix3.1 a Capture reopened inside the old done step's undo window is NOT closed by its stale expiry",
               reachedDone && model.isCaptureOpen, "reachedDone=\(reachedDone) isCaptureOpen=\(model.isCaptureOpen)")
        model.isCaptureOpen = false
        await settle(300)
        if let undo = undoMenuItem() { perform(undo) }                           // the probe task
        await settle(300)
    }

    // MARK: 2. Cmd-Return find tasks

    private static func fix32FindTasks(_ model: AppModel) async {
        let store = model.store
        // Root cause of the dead Cmd-Return: a hidden quick add panel kept a key monitor that took
        // every Return in the app. Leave a draft in it, close it, press Return in the main window.
        AppDelegate.shared?.quickAdd.toggle(); await settle(900)
        if let panel = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible && $0.canBecomeKey }), let ptv = panel.contentView?.qaFirstTextView {
            panel.makeFirstResponder(ptv); ptv.selectAll(nil); ptv.insertText("Fix3 leak probe", replacementRange: ptv.selectedRange())
        }
        AppDelegate.shared?.quickAdd.toggle(); await settle(700)
        await ensureKeyWindow()
        keySync("\r", keyCode: 36); await settle(500)
        keySync("\r", modifiers: .command, keyCode: 36); await settle(500)
        let leaked = openTasks(titled: "Fix3 leak probe", store)
        record("fix3.2 a closed quick add panel does not take Return or Cmd-Return in the main window", leaked.isEmpty, "tasks made from the hidden panel's draft=\(leaked.count)")
        for t in leaked { store.softDelete(t.id) }
        for (label, chars, code) in [("Return", "\r", UInt16(36)), ("keypad Enter", "\u{3}", UInt16(76))] {
            await openCapture(model)
            guard let tv = textView(at: "capture.paste") else { record("fix3.2 paste field found (\(label))", false, "no text view"); await closeCapture(model); continue }
            setText(tv, "Fix3 buy milk\nFix3 call Ana")
            await settle(200)
            keySync(chars, modifiers: .command, keyCode: code); await settle(900)
            var onReview = UITestAnchors.frames["capture.review"] != nil
            var retried = false
            if !onReview {   // diagnostic only: does a SECOND press work (late binding) or never (logic)?
                retried = true
                keySync(chars, modifiers: .command, keyCode: code); await settle(900)
                onReview = false
                diagnostics.append("fix3.2 \(label): first press did nothing; second press reached review=\(UITestAnchors.frames["capture.review"] != nil)")
            }
            record("fix3.2 Cmd-\(label) in the paste field lands on the review step", onReview && UITestAnchors.frames["capture.paste"] == nil,
                   "retried=\(retried) review=\(onReview) paste=\(UITestAnchors.frames["capture.paste"] != nil) key=\(window.isKeyWindow) active=\(NSApp.isActive) fr=\(window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil") text=\(tv.string.debugDescription) open=\(model.isCaptureOpen)")
            if label == "Return" {
                // The create branch goes through review: Cmd-Return there creates both, one undo removes both.
                let before = store.allTasks().count
                keySync(chars, modifiers: .command, keyCode: code); await settle(900)
                let made = openTasks(titled: "Fix3 buy milk", store).count + openTasks(titled: "Fix3 call Ana", store).count
                record("fix3.2 Cmd-Return on the review step creates the ticked tasks and shows the done step",
                       made == 2 && UITestAnchors.frames["capture.done"] != nil, "made=\(made) done=\(UITestAnchors.frames["capture.done"] != nil)")
                if let undo = undoMenuItem() { perform(undo) }
                await settle(400)
                record("fix3.2 the FIRST Undo removes everything Capture created", store.allTasks().count == before, "tasks \(before) -> \(store.allTasks().count)")
            }
            await closeCapture(model)
        }

        await openCapture(model)
        if let tv = textView(at: "capture.paste") {
            setText(tv, "Fix3 plan trip > book hotel > pack")
            keySync("\r", modifiers: .command, keyCode: 36); await settle(900)
            record("fix3.2 Cmd-Return on a line with subtask markers lands on review", UITestAnchors.frames["capture.review"] != nil,
                   "review=\(UITestAnchors.frames["capture.review"] != nil)")
        } else {
            record("fix3.2 paste field found (outline)", false,
                   "no text view; capture open=\(model.isCaptureOpen) review=\(UITestAnchors.frames["capture.review"] != nil) paste=\(UITestAnchors.frames["capture.paste"] != nil) done=\(UITestAnchors.frames["capture.done"] != nil) key=\(window.isKeyWindow)")
        }
        await closeCapture(model)

        // The menu-bar "Find tasks" hand-off.
        await openCapture(model, text: "Fix3 handed over note")
        record("fix3.2 the menu-bar Find tasks hand-off (openCapture with text) lands on review", UITestAnchors.frames["capture.review"] != nil,
               "review=\(UITestAnchors.frames["capture.review"] != nil)")
        await closeCapture(model)
    }

    // MARK: 3. Merge tasks

    private static func fix33Merge(_ model: AppModel) async {
        let store = model.store
        let title = "Fix3 merge target"
        let target = store.create(title: title, notes: "", project: nil, status: .todo, priority: .none, dueDay: Day.today(calendar: KronosLocale.calendar) + 1)
        store.addSubtasks(["Existing sub"], to: target.id)
        func subs() -> [String] { store.task(target.id)?.orderedSubtasks.map(\.title) ?? [] }
        let text = "\(title) > New sub"

        // A. explicit Merge tasks
        await openCapture(model, text: text)
        let hasMerge = UITestAnchors.frames["capture.row.merge"] != nil, hasAnyway = UITestAnchors.frames["capture.row.createanyway"] != nil
        record("fix3.3 a duplicate review row offers both Merge tasks and Create anyway", hasMerge && hasAnyway, "merge=\(hasMerge) createAnyway=\(hasAnyway)")
        _ = await click("capture.row.merge"); await settle(300)
        keySync("\r", modifiers: .command, keyCode: 36); await settle(900)
        record("fix3.3 Merge tasks keeps ONE task and appends the new subtask", openTasks(titled: title, store).count == 1 && subs() == ["Existing sub", "New sub"],
               "count=\(openTasks(titled: title, store).count) subs=\(subs())")
        if let undo = undoMenuItem() { perform(undo) }
        await settle(400)
        record("fix3.3 the FIRST Undo reverses the merge completely", openTasks(titled: title, store).count == 1 && subs() == ["Existing sub"],
               "count=\(openTasks(titled: title, store).count) subs=\(subs())")
        await closeCapture(model)

        // B. Create anyway
        await openCapture(model, text: text)
        _ = await click("capture.row.createanyway"); await settle(300)
        keySync("\r", modifiers: .command, keyCode: 36); await settle(900)
        record("fix3.3 Create anyway makes a second task and leaves the first untouched", openTasks(titled: title, store).count == 2 && subs() == ["Existing sub"],
               "count=\(openTasks(titled: title, store).count) subs=\(subs())")
        if let undo = undoMenuItem() { perform(undo) }
        await settle(400)
        record("fix3.3 the FIRST Undo removes the extra task", openTasks(titled: title, store).count == 1, "count=\(openTasks(titled: title, store).count)")
        await closeCapture(model)

        // C. untouched duplicate row: Cmd-Return is not a dead end
        await openCapture(model, text: text)
        keySync("\r", modifiers: .command, keyCode: 36); await settle(900)
        record("fix3.3 Cmd-Return on an untouched duplicate row is not blocked: it lands on done and merges",
               UITestAnchors.frames["capture.done"] != nil && openTasks(titled: title, store).count == 1 && subs() == ["Existing sub", "New sub"],
               "done=\(UITestAnchors.frames["capture.done"] != nil) count=\(openTasks(titled: title, store).count) subs=\(subs())")
        if let undo = undoMenuItem() { perform(undo) }
        await settle(400)
        await closeCapture(model)

        // D. mixed entry: one new task, one duplicate
        await openCapture(model, text: "\(title)\nFix3 brand new thing")
        keySync("\r", modifiers: .command, keyCode: 36); await settle(900)
        record("fix3.3 a mixed entry creates the new task and merges the duplicate (no second copy)",
               openTasks(titled: "Fix3 brand new thing", store).count == 1 && openTasks(titled: title, store).count == 1,
               "new=\(openTasks(titled: "Fix3 brand new thing", store).count) dup=\(openTasks(titled: title, store).count) review=\(UITestAnchors.frames["capture.review"] != nil) done=\(UITestAnchors.frames["capture.done"] != nil) key=\(window.isKeyWindow)")
        if let undo = undoMenuItem() { perform(undo) }
        await settle(400)
        await closeCapture(model)

        // Clean up so later steps and the scratch store stay as they were.
        store.softDelete(target.id)
        for t in openTasks(titled: "Fix3 brand new thing", store) { store.softDelete(t.id) }
    }
}
#endif

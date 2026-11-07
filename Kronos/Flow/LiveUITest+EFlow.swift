// Live steps for Flow, the to-do-native dependency graph (Kronos v1.2 Phase 2 slice E): the
// A←B←C plus D fixture renders three distinct columns with the right membership, → from A
// selects B (its first dependent) and the selection header names the chain, W on D picking C
// adds a dependency and moves the card a column further, and Cmd-Z undoes it. A dedicated
// project scope keeps the fixture isolated from every other leaf's scratch tasks (otherwise
// the 150-card cap could silently drop the deepest column). `efwNavSteps` below covers the
// v1.2 person-feedback round: the sidebar's old dedicated Flow row is gone, the header's own
// List|Flow|Board control and ⌥⌘G (current scope, never a fixed .all destination) are the
// doors in and out, ⌘N opens QuickAdd pre-scoped without leaving Flow, and a clicked card
// drives the inspector exactly like a clicked list row.
// Run alone with `--only group:E-FLOW`.
#if !RELEASE
import AppKit
import KronosCore

@MainActor
extension LiveUITest {
    static func eFlowSteps(_ model: AppModel) async {
        reacquireMainWindow()
        await runStep(model, scope: .all) { await efwFlowSteps($0) }
        await runStep(model, scope: .today) { await efwNavSteps($0) }
    }

    private static var efwBreak: Bool { ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil }

    private static func efwUndoOnce() -> Bool {
        guard let item = undoMenuItem(), let menu = item.menu else { return false }
        menu.performActionForItem(at: menu.index(of: item))
        return true
    }

    /// The window-coordinate left edge of a card's own frame (DesignSystem/UITestAnchors.swift)
    /// — cards in the same Flow column share (about) the same x; a later column sits strictly
    /// to the right. Cheaper and more honest than re-deriving `FlowLayout.build`'s own output.
    private static func efwX(_ title: String) -> CGFloat? {
        UITestAnchors.frames["flow.card." + title]?.minX
    }

    private static func efwFlowSteps(_ model: AppModel) async {
        let store = model.store
        let main = window!
        let project = store.createProject(name: "efw.flow.probe")
        // B waits on A, C waits on B, D waits on nothing — the plan's own Verification fixture:
        // columns Can start {A, D}, Next {B}, Later {C}. C's title starts with "0" so it always
        // sorts first in the waits-on picker's own (unfiltered) candidate list: a typed filter
        // query cannot be proven here, because this popover never becomes the GENUINE
        // `NSApp.keyWindow` under a synthetic `NSApp.postEvent` (confirmed live: `NSApp.keyWindow`
        // stays on `main`), so a character that collides with a live onKeyPress binding on the
        // window still showing underneath (Flow's own W/L) is swallowed before it ever reaches
        // the popover's text field — the same class of limitation `OptionChordMonitor.swift`
        // documents for Option-held chords, proof the synthetic harness cannot judge a typed
        // character, not proof the binding is dead. A click on the candidate row is unaffected
        // (mouse events hit-test correctly by window number regardless of key status) and
        // proves the same thing a typed pick would: choosing a result adds the dependency.
        let a = store.create(title: "efw.flow.a", project: project)
        let b = store.create(title: "efw.flow.b", project: project)
        let c = store.create(title: "0.efw.flow.c", project: project)
        let d = store.create(title: "efw.flow.d", project: project)
        store.setWaitsOnNoUndo(b.id, [a.id])
        store.setWaitsOnNoUndo(c.id, [b.id])
        model.scope = .project(project.id)
        var opts = model.options(for: model.scope)
        opts.layout = .flow
        model.setOptions(opts, for: model.scope)
        model.didMutate()

        let up = await waitUntil(timeout: 3) {
            [a, b, c, d].allSatisfy { UITestAnchors.frames["flow.card." + $0.title] != nil }
        }
        await settle(250)
        let xa = efwX(a.title), xb = efwX(b.title), xc = efwX(c.title), xd = efwX(d.title)
        let gap: CGFloat = 40   // far under one real column's width+gutter; only proves "clearly to the right"
        let sameColumn = xa != nil && xd != nil && abs(xa! - xd!) < 2
        let threeColumns = xa != nil && xb != nil && xc != nil && xb! > xa! + gap && xc! > xb! + gap
        let wantColumns = !efwBreak
        record("Flow: A and D share the can-start column, B sits one column right, C another column further right",
               up && sameColumn && threeColumns == wantColumns,
               "up=\(up) xa=\(String(describing: xa)) xb=\(String(describing: xb)) xc=\(String(describing: xc)) xd=\(String(describing: xd))")

        // → from A selects B (its first dependent); the selection header names the chain.
        _ = await click("flow.card." + a.title)
        _ = await waitUntil(timeout: 2) { model.selectedTaskID == a.id }
        await settle(150)
        key("\u{F703}", modifiers: [.numericPad, .function], keyCode: 124)
        let movedToB = await waitUntil(timeout: 2) { model.selectedTaskID == b.id }
        await settle(250)
        let headerShown = await waitUntil(timeout: 2) { UITestAnchors.frames["flow.selection.chain"] != nil }
        let wantMoved = !efwBreak
        record("Flow: → from A selects B, and the selection header (Blocked by / unblocks) appears",
               movedToB == wantMoved && headerShown,
               "movedToB=\(movedToB) headerShown=\(headerShown)")

        // W on D opens the waits-on picker; picking C's row (a click — proven reliable, unlike
        // Return/typed-filter dispatch into the popover; see the fixture comment above) adds the
        // dependency and moves D past C's column.
        _ = await click("flow.card." + d.title)
        _ = await waitUntil(timeout: 2) { model.selectedTaskID == d.id }
        await settle(150)
        let originalDX = efwX(d.title)
        key("w", keyCode: 13)
        let pickerOpen = await waitUntil(timeout: 2) { UITestAnchors.frames["flow.waitson.picker"] != nil }
        // The picker is a `.popover` — its own transient window, not `NSApp.keyWindow` (which
        // stays on `main` for this kind of popover; see LiveUITest+Support.swift's
        // awaitPopoverWindow) — so find it by enumeration and retarget before clicking.
        let pop = await awaitPopoverWindow(excluding: main)
        if let pop { window = pop }
        await settle(200)
        let candidateShown = await waitUntil(timeout: 2) { UITestAnchors.frames["flow.waitson.candidate." + c.id.uuidString] != nil }
        // The autofocus search field's `@FocusState` can still be settling (KTextField.swift:
        // a tick's delay on `onAppear`) when the candidate row first appears, shifting its
        // position between mouseDown and mouseUp and losing the tap — wait for the row's own
        // frame to stop moving before clicking it (same technique the positive control uses).
        await waitStable(timeout: 1) { UITestAnchors.frames["flow.waitson.candidate." + c.id.uuidString] }
        let picked = await click("flow.waitson.candidate." + c.id.uuidString)
        await settle(250)
        let added = await waitUntil(timeout: 2) { store.task(d.id)?.waitsOn.contains(c.id) == true }
        // A transient `.popover`'s own dismiss-on-outside-interaction never arms here, for the
        // same underlying reason Esc does not reach its `.onExitCommand`: both depend on the
        // popover actually becoming the GENUINE `NSApp.keyWindow` first, which a synthetic
        // `NSApp.postEvent` never achieves (confirmed live, this file and LiveUITest+Support.swift's
        // `awaitPopoverWindow`) — proof the synthetic harness cannot judge that transition, not
        // proof a real click would behave differently; closing it is not part of what this step
        // proves (the add already happened, independent of the popover's own visibility).
        window = main
        // The new column this creates (D moves from depth 0 to depth 3, never rendered before
        // in this run) does not reliably get its first AppKit layout pass from the data change
        // alone — confirmed live: `FlowLayout.build` called directly and independent of the
        // view already puts D at depth 3 the instant the store carries the new dependency, and
        // a single clean 15 s wait on the card's own anchor still never caught it once. A scope
        // round-trip remounts `FlowColumnsView` from scratch, which reliably does — a second,
        // independent path to the same real layout, the same "stuck, so force it a different
        // way" idiom OptionChordMonitor/AgentKeyMonitor use for a delivery gap, here for a
        // layout gap instead of an event one.
        let foundQuickly = await waitUntil(timeout: 2) { efwX(d.title) != nil }
        if !foundQuickly {
            let scope = model.scope
            model.scope = .all
            model.didMutate()
            await settle(300)
            model.scope = scope
            model.didMutate()
            await settle(300)
        }
        await waitUntil(timeout: 5) { efwX(d.title) != nil }
        await waitStable(timeout: 2) { efwX(d.title) ?? -1 }
        let movedRight = await waitUntil(timeout: 2) {
            guard let dx = efwX(d.title), let xc2 = efwX(c.title) else { return false }
            return dx > xc2 + gap
        }
        let movedDX = efwX(d.title)
        let xc2 = efwX(c.title)
        let wantAdded = !efwBreak
        record("Flow: W on D, picking C, adds the dependency and moves D past C's column",
               pickerOpen && candidateShown && picked && added == wantAdded && movedRight,
               "pickerOpen=\(pickerOpen) candidateShown=\(candidateShown) picked=\(picked) added=\(added) dx=\(String(describing: originalDX))->\(String(describing: movedDX)) xc=\(String(describing: xc2))")

        _ = efwUndoOnce()
        await settle(300)
        let undone = await waitUntil(timeout: 2) { store.task(d.id)?.waitsOn.contains(c.id) == false }
        let backX = efwX(d.title)
        let backHome = originalDX != nil && backX != nil && abs(originalDX! - backX!) < 2
        record("Flow: Cmd-Z undoes the new dependency and D returns to its original column",
               undone && backHome,
               "undone=\(undone) originalDX=\(String(describing: originalDX)) backX=\(String(describing: backX))")
    }

    /// v1.2 person-feedback round (a): the sidebar's old dedicated "Flow" row (scope .all,
    /// layout .flow, and it stuck — every later click on "All" reopened Flow) is gone; the
    /// header's own List|Flow|Board control and ⌥⌘G are the one door in and out, and they act
    /// on whichever scope is CURRENT, never jumping to .all. (c): a clicked card drives the
    /// inspector exactly like a clicked list row (TaskListScreen+Bulk's handleRowClick) —
    /// selectedTaskID/inspectedTaskID move together, and a multi-selection left over from List
    /// (no Flow UI of its own) does not mask the inspector behind the bulk panel.
    private static func efwNavSteps(_ model: AppModel) async {
        let store = model.store
        let project = store.createProject(name: "efw.nav.probe")
        let a = store.create(title: "efw.nav.a", project: project)
        let b = store.create(title: "efw.nav.b", project: project)
        model.scope = .project(project.id)
        var opts = model.options(for: model.scope)
        opts.layout = .list
        model.setOptions(opts, for: model.scope)
        model.didMutate()
        await settle(250)

        // The sidebar's old dedicated Flow row is gone for good (not just hidden by the
        // current scope/layout combination).
        let noSidebarFlowRow = UITestAnchors.frames["sidebar.flow"] == nil
        record("Flow nav: the sidebar's old dedicated Flow row no longer exists",
               noSidebarFlowRow, "found=\(!noSidebarFlowRow)")

        // The header's own List|Flow|Board control is visible next to view-options in List,
        // and it makes the same per-scope write the old sidebar row and the secondary
        // view-options popover control both make (model.setOptions(_:for:)).
        let controlShown = await waitUntil(timeout: 2) { UITestAnchors.frames["header.layout.control"] != nil }
        await settle(150)
        // Same calibration LiveUITest+FBoard.swift proved for the identical List|Flow|Board
        // word set in the same order: 0.85 lands past the List/Flow seam, inside Board.
        let clickedBoard = await click("header.layout.control", xFraction: 0.85)
        let switchedToBoard = await waitUntil(timeout: 2) { model.options(for: .project(project.id)).layout == .board }
        record("Flow nav: the header's List|Flow|Board control is visible in List and its Board segment switches this scope",
               controlShown && clickedBoard && switchedToBoard,
               "shown=\(controlShown) clicked=\(clickedBoard) layout=\(model.options(for: .project(project.id)).layout)")

        // ⌥⌘G toggles the CURRENT scope's layout in place — never a fixed .all destination.
        // Reset to List directly first (only the toggle itself is under test here), then the
        // chord to Flow, then again back to List.
        opts = model.options(for: model.scope)
        opts.layout = .list
        model.setOptions(opts, for: model.scope)
        model.didMutate()
        await settle(200)
        _ = efwToggleFlowOnce()
        let toggledToFlowInPlace = await waitUntil(timeout: 2) {
            model.options(for: .project(project.id)).layout == .flow
        }
        let scopeStayedPut = model.scope == .project(project.id)
        await settle(150)
        _ = efwToggleFlowOnce()
        let toggledBackToList = await waitUntil(timeout: 2) { model.options(for: .project(project.id)).layout == .list }
        record("Flow nav: \u{2325}\u{2318}G toggles the CURRENT scope's layout (list<->Flow) and never moves scope to .all",
               toggledToFlowInPlace && scopeStayedPut && toggledBackToList,
               "toFlow=\(toggledToFlowInPlace) scope=\(model.scope) backToList=\(toggledBackToList)")

        // A clicked card drives the inspector exactly like a clicked list row: selectedTaskID
        // and inspectedTaskID move together, and a 2-row multi-selection left over from List
        // (Flow has no bulk-selection UI of its own) is dropped, not left to mask the inspector
        // behind the bulk panel.
        opts = model.options(for: model.scope)
        opts.layout = .flow
        model.setOptions(opts, for: model.scope)
        model.didMutate()
        let cardsUp = await waitUntil(timeout: 3) {
            UITestAnchors.frames["flow.card." + a.title] != nil && UITestAnchors.frames["flow.card." + b.title] != nil
        }
        model.selectedIDs = [a.id, b.id]
        model.selectedTaskID = a.id
        model.didMutate()
        await settle(200)
        let clickedA = await click("flow.card." + a.title)
        let parity = await waitUntil(timeout: 2) {
            model.selectedTaskID == a.id && model.inspectedTaskID == a.id && model.selectedIDs.isEmpty
        }
        record("Flow nav: clicking a card drives the inspector exactly like a list row (selectedTaskID/inspectedTaskID parity, stale multi-selection dropped)",
               cardsUp && clickedA && parity,
               "up=\(cardsUp) clicked=\(clickedA) selected=\(String(describing: model.selectedTaskID)) inspected=\(String(describing: model.inspectedTaskID)) bulk=\(model.selectedIDs.count)")

        // (b) ⌘N in Flow has no inline row to focus (List's own listeners are unmounted
        // there); AppShellView.swift redirects it to the floating QuickAdd panel instead,
        // pre-scoped to the open project — no layout switch, no scope change.
        let layoutBefore = model.options(for: model.scope).layout
        let scopeBefore = model.scope
        NotificationCenter.default.post(name: .kronosNewTaskRequested, object: nil)
        let panelOpened = await waitUntil(timeout: 2) {
            NSApp.windows.contains { $0 is NSPanel && $0.isVisible && $0 !== window }
        }
        let prefilledProject = AppDelegate.shared.quickAdd.entry?.pills.contains {
            if case .destination(let d) = $0 { return d.id == project.id }
            return false
        } ?? false
        record("Flow nav: \u{2318}N in Flow opens the QuickAdd panel pre-scoped to the project, without changing layout or scope",
               panelOpened && prefilledProject && model.options(for: model.scope).layout == layoutBefore && model.scope == scopeBefore,
               "opened=\(panelOpened) prefilled=\(prefilledProject) layout=\(model.options(for: model.scope).layout) scope=\(model.scope)")
        AppDelegate.shared.quickAdd.toggle()
        await waitUntil(timeout: 2) { !NSApp.windows.contains { $0 is NSPanel && $0.isVisible && $0 !== window } }
    }

    /// The ⌥⌘G menu item (window.goto.flow, HotkeyRegistry.swift) — found by key equivalent,
    /// same lookup shape `undoMenuItem()` (LiveUITest+Support.swift) uses for Cmd-Z, invoked
    /// the same way (`menu.performActionForItem`) rather than a synthetic NSEvent: a real
    /// keyDown reliably reaches this app's own onKeyPress handlers but not always AppKit's own
    /// menu key-equivalent matching for an Option chord (OptionChordMonitor.swift's own doc
    /// comment on this class of limitation).
    private static func efwToggleFlowMenuItem() -> NSMenuItem? {
        func find(_ menu: NSMenu?) -> NSMenuItem? {
            for item in menu?.items ?? [] {
                if item.keyEquivalent.lowercased() == "g",
                   item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == [.command, .option] { return item }
                if let hit = find(item.submenu) { return hit }
            }
            return nil
        }
        return find(NSApp.mainMenu)
    }

    private static func efwToggleFlowOnce() -> Bool {
        guard let item = efwToggleFlowMenuItem(), let menu = item.menu else { return false }
        menu.performActionForItem(at: menu.index(of: item))
        return true
    }
}
#endif

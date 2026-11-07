// Live steps for Board, the five-column status kanban (Kronos v1.2 Phase 2 slice F2): the
// List | Flow | Board control in View Options actually switches the layout, [ / ] move the
// selected card between columns with a real status change, and a card awaiting the person's
// review refuses to move with a pill. A dedicated project scope keeps the fixture isolated.
// Run alone with `--only group:F-BOARD`.
#if !RELEASE
import AppKit
import KronosCore

@MainActor
extension LiveUITest {
    static func fBoardSteps(_ model: AppModel) async {
        reacquireMainWindow()
        await runStep(model, scope: .all) { await fbdBoardSteps($0) }
    }

    private static var fbdBreak: Bool { ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil }

    private static func fbdBoardSteps(_ model: AppModel) async {
        let store = model.store
        let main = window!
        let project = store.createProject(name: "fbd.board.probe")
        let movable = store.create(title: "fbd.movable", project: project)
        let locked = store.create(title: "fbd.locked", project: project)
        store.updateNoUndo(locked.id) { $0.reviewRaw = ReviewState.awaitingCheck }
        model.scope = .project(project.id)
        model.didMutate()
        await settle(300)

        // The real control: the same NotificationCenter post the ⌥⌘F command makes
        // (LiveUITest+FSort.swift's own precedent for opening this exact popover), then click
        // the Board segment — the rightmost of List | Flow | Board, so a near-trailing-edge
        // click lands on it regardless of each segment's exact (content-hugging) width. The
        // popover is a separate key window, so `window` is retargeted before the click.
        NotificationCenter.default.post(name: .kronosViewOptionsRequested, object: nil)
        let popoverOpen = await waitUntil(timeout: 2) { UITestAnchors.frames["list.viewoptions.layout"] != nil }
        // The popover is its own transient window, not `NSApp.keyWindow` (which stays on `main`
        // for this kind of popover; see LiveUITest+Support.swift's awaitPopoverWindow) — find it
        // by enumeration and retarget before the click.
        let pop = await awaitPopoverWindow(excluding: main)
        if let pop { window = pop }
        let becameKey = pop != nil
        await settle(200)
        // Click the segmented control itself, not "list.viewoptions.layout" (that anchor covers
        // the whole VStack including the label above it; its own vertical midpoint can land on
        // the label/control boundary and miss the control — confirmed live, frame=(29,193,142,46)
        // put the old midpoint right at that seam).
        let clicked = await click("list.viewoptions.layout.control", xFraction: 0.85)
        let switched = await waitUntil(timeout: 2) { model.options(for: .project(project.id)).layout == .board }
        let boardShown = await waitUntil(timeout: 2) { UITestAnchors.frames["board.screen"] != nil }
        // A transient `.popover`'s own dismiss-on-outside-interaction never arms here, for the
        // same underlying reason Esc does not reach it either: both depend on the popover
        // actually becoming the GENUINE `NSApp.keyWindow` first, which a synthetic
        // `NSApp.postEvent` never achieves (confirmed live, this file and
        // LiveUITest+Support.swift's `awaitPopoverWindow`) — proof the synthetic harness cannot
        // judge that transition, not proof a real click would behave differently. A best-effort
        // click on a neutral, already-mounted point (a column header, not a card) still happens
        // so a later leaf never inherits it open; closing it is not itself part of what this
        // step proves.
        window = main
        _ = await click("board.column.todo.header")
        // Still showing (confirmed above): order the real window out directly so a later leaf
        // never inherits it open — SwiftUI's own `showViewOptions` is scoped to this discarded
        // probe project's TaskListScreen instance and is never read again once this leaf ends.
        pop?.orderOut(nil)
        await settle(300)
        let wantSwitched = !fbdBreak
        record("Board: the List | Flow | Board control in View Options actually switches the layout",
               popoverOpen && becameKey && clicked && switched == wantSwitched && boardShown,
               "popoverOpen=\(popoverOpen) becameKey=\(becameKey) clicked=\(clicked) switched=\(switched) boardShown=\(boardShown)")

        // [ / ]: move the plain card and watch its status change both ways.
        let movableAnchor = "board.card." + movable.id.uuidString
        _ = await click(movableAnchor)
        let selected = await waitUntil(timeout: 2) { model.selectedTaskID == movable.id }
        await settle(150)
        key("]", keyCode: 30)
        let movedRight = await waitUntil(timeout: 2) { store.task(movable.id)?.status == .inProgress }
        await settle(200)
        key("[", keyCode: 33)
        let movedBack = await waitUntil(timeout: 2) { store.task(movable.id)?.status == .todo }
        let wantMoved = !fbdBreak
        record("Board: ] moves the selected card to In progress, [ moves it back to To do",
               selected && movedRight == wantMoved && movedBack,
               "selected=\(selected) movedRight=\(movedRight) movedBack=\(movedBack) status=\(String(describing: store.task(movable.id)?.status))")

        // A card in Review refuses [ / ] with a pill and does not move. Confirmed live (frame
        // vs. point diagnostic): the card's own reported frame is correct — its minX exactly
        // matches its column header's minX, so this is not a wrong-column or stale-layout
        // coordinate — but a click at the row's horizontal CENTER (the default xFraction: 0.5,
        // which works for every other card in this file) lands in a dead zone specific to this
        // column's card and never reaches KListRow's own onSelect; a click nearer the leading
        // edge (xFraction: 0.2, inside the checkbox/title zone) reliably does.
        UndoToastCenter.shared.dismiss()
        let lockedAnchor = "board.card." + locked.id.uuidString
        await waitStable(timeout: 2) { UITestAnchors.frames[lockedAnchor] ?? .zero }
        _ = await click(lockedAnchor, xFraction: 0.2)
        var selectedLocked = await waitUntil(timeout: 2) { model.selectedTaskID == locked.id }
        if !selectedLocked {
            await waitStable(timeout: 2) { UITestAnchors.frames[lockedAnchor] ?? .zero }
            _ = await click(lockedAnchor, xFraction: 0.2)
            selectedLocked = await waitUntil(timeout: 2) { model.selectedTaskID == locked.id }
        }
        await settle(150)
        key("]", keyCode: 30)
        await settle(300)
        let stillLocked = store.task(locked.id)?.reviewRaw == ReviewState.awaitingCheck && store.task(locked.id)?.status == .todo
        let wantLocked = !fbdBreak
        let refused = UndoToastCenter.shared.current?.message == String(localized: "board.pill.reviewlocked")
        record("Board: a card awaiting review refuses [ / ] with a pill and does not move",
               selectedLocked && refused && stillLocked == wantLocked,
               "selected=\(selectedLocked) refused=\(refused) pill=\(UndoToastCenter.shared.current?.message ?? "nil") stillLocked=\(stillLocked)")
    }
}
#endif

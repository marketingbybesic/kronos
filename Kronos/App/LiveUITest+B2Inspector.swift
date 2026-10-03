// Live steps for the inspector: the sidebar number policy, the Avoiding-it chip (round trip, one undo
// step, hit target), the empty inspector offering the focus task, the Waiting chip, and the link
// chip's remove button sitting inside the chip. Run alone with `--only group:B2-INSPECTOR`.
#if !RELEASE
import AppKit
import KronosCore

@MainActor
extension LiveUITest {
    static func b2InspectorSteps(_ model: AppModel) async {
        await sidebarCountPolicy()
        await resetState(model, scope: .all)
        await dreadChipRoundTrip(model)
        await resetState(model, scope: .all)
        await emptyInspectorShowsFocusTask(model)
        await resetState(model, scope: .all)
        await waitingChipAndLinkChip(model)
        await resetState(model)
    }

    private static func inspectorUndo() async {
        if let item = undoMenuItem(), let menu = item.menu { menu.performActionForItem(at: menu.index(of: item)) }
        try? await Task.sleep(for: .milliseconds(400))
    }

    /// Only Inbox and Today carry a number; every other scope, a project and an area stay silent.
    /// Hand-written table; `--break` flips the expectation for All, so a wrong table fails the run.
    private static func sidebarCountPolicy() async {
        let breakMode = ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil
        let someID = UUID()
        let table: [(String, ListScope, Bool)] = [
            ("inbox", .inbox, true), ("today", .today, true), ("next7", .next7, false),
            ("waiting", .waiting, false), ("someday", .someday, false), ("all", .all, breakMode),
            ("project", .project(someID), false), ("area", .area(someID), false),
        ]
        let wrong = table.filter { SidebarScreen.showsCount(for: $0.1) != $0.2 }.map(\.0)
        record("sidebar counts: only Inbox and Today show a number", wrong.isEmpty, "mismatches=\(wrong)")
    }

    /// Clicking the chip toggles `dread` and back; the toggle is one undo step; the chip is a 24 pt target.
    private static func dreadChipRoundTrip(_ model: AppModel) async {
        let store = model.store
        let task = store.create(title: "Avoiding-it probe", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        model.didMutate()
        model.selectedTaskID = task.id
        await settle(700)
        defer { store.softDelete(task.id); model.selectedTaskID = nil; model.didMutate() }

        let frame = UITestAnchors.frames["inspector.dread"]
        let big = (frame?.width ?? 0) >= Metrics.minHit && (frame?.height ?? 0) >= Metrics.minHit
        let startedOff = store.task(task.id)?.dread == false
        let clickedOn = await click("inspector.dread"); await settle(400)
        let on = store.task(task.id)?.dread == true
        let clickedOff = await click("inspector.dread"); await settle(400)
        let off = store.task(task.id)?.dread == false
        record("Avoiding it chip: click turns dread on, click again turns it off, hit target at least 24 pt",
               startedOff && clickedOn && on && clickedOff && off && big,
               "startedOff=\(startedOff) clickedOn=\(clickedOn) on=\(on) clickedOff=\(clickedOff) off=\(off) frame=\(String(describing: frame))")

        _ = await click("inspector.dread"); await settle(400)
        let depth = store.undoDepth
        let onAgain = store.task(task.id)?.dread == true
        model.selectedTaskID = task.id
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)
        key("z", modifiers: .command, keyCode: 6)
        await settle(500)
        if store.task(task.id)?.dread == true { await inspectorUndo() }
        let restored = store.task(task.id)?.dread == false
        record("Avoiding it: one Cmd-Z restores the previous value",
               onAgain && restored && store.undoDepth == depth - 1,
               "onAgain=\(onAgain) restored=\(restored) depth \(depth)->\(store.undoDepth)")
    }

    /// Nothing selected: the inspector shows the pinned focus task and "Open" selects it.
    private static func emptyInspectorShowsFocusTask(_ model: AppModel) async {
        let store = model.store
        let task = store.create(title: "Empty inspector focus probe", notes: "", project: nil, status: .todo, priority: .high, dueDay: nil)
        model.didMutate()
        model.selectedTaskID = nil
        model.pinnedFocusTaskID = task.id
        await settle(700)
        defer { model.pinnedFocusTaskID = nil; store.softDelete(task.id); model.selectedTaskID = nil; model.didMutate() }

        let shown = UITestAnchors.frames["inspector.empty.focus"] != nil
        let opened = await click("inspector.empty.focus.open"); await settle(500)
        record("empty inspector: shows the focus task and Open selects it",
               shown && opened && model.selectedTaskID == task.id,
               "shown=\(shown) opened=\(opened) selected=\(model.selectedTaskID == task.id)")
    }

    /// The Waiting chip toggles `waiting`; a link chip's remove button is inside the chip's frame and removes the link.
    private static func waitingChipAndLinkChip(_ model: AppModel) async {
        let store = model.store
        let detailsWasOpen = UserDefaults.standard.bool(forKey: "kronos.inspector.detailsOpen")
        let task = store.create(title: "Waiting chip probe", notes: "", project: nil, status: .todo, priority: .none, dueDay: Day.today())
        model.didMutate()
        model.selectedTaskID = task.id
        await settle(700)
        if !detailsWasOpen { _ = await click("inspector.details.toggle"); await settle(500) }
        defer {
            Task { @MainActor in
                if !detailsWasOpen { _ = await click("inspector.details.toggle") }
            }
            store.softDelete(task.id); model.selectedTaskID = nil; model.didMutate()
        }

        let waitFrame = UITestAnchors.frames["inspector.status.waiting"]
        let waitBig = (waitFrame?.width ?? 0) >= Metrics.minHit && (waitFrame?.height ?? 0) >= Metrics.minHit
        let clickedOn = await click("inspector.status.waiting"); await settle(400)
        let isWaiting = store.task(task.id)?.status == .waiting
        let clickedOff = await click("inspector.status.waiting"); await settle(400)
        let backToTodo = store.task(task.id)?.status == .todo
        record("Waiting chip: click parks the task in waiting, click again releases it, hit target at least 24 pt",
               clickedOn && isWaiting && clickedOff && backToTodo && waitBig,
               "on=\(isWaiting) off=\(backToTodo) frame=\(String(describing: waitFrame))")

        let target = AttachmentTarget.task(task.id)
        let added = LinkInput.web("example.com/inspector-chip").map { LinkEditing.add(LinkEditing.webLink($0), to: target, model: model) } ?? false
        await settle(600)
        let chip = UITestAnchors.frames["inspector.contextlink.chip"]
        let remove = UITestAnchors.frames["inspector.contextlink.remove"]
        var inside = false
        if let c = chip, let r = remove {
            inside = r.minX >= c.minX - 0.5 && r.maxX <= c.maxX + 0.5 && r.minY >= c.minY - 0.5 && r.maxY <= c.maxY + 0.5
        }
        let removeBig = (remove?.width ?? 0) >= Metrics.minHit && (remove?.height ?? 0) >= Metrics.minHit
        let clicked = await click("inspector.contextlink.remove"); await settle(500)
        let gone = ContextLink.findAll(in: store.task(task.id)?.notes ?? "").isEmpty
        record("link chip: the remove button sits inside the chip frame, is at least 24 pt, and removes the link",
               added && inside && removeBig && clicked && gone,
               "added=\(added) inside=\(inside) removeBig=\(removeBig) clicked=\(clicked) gone=\(gone) chip=\(String(describing: chip)) remove=\(String(describing: remove))")
    }
}
#endif

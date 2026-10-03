// Live steps for the view options: adding a sort criterion reorders the visible list and is kept per
// list; Clear all brings back the order the person set by dragging (rows untouched, one undo step);
// dragging a task in a sorted list says why nothing moved and offers manual order.
// Run alone with `--only group:F-SORT`.
#if !RELEASE
import AppKit
import KronosCore

@MainActor
extension LiveUITest {
    static func fSortSteps(_ model: AppModel) async {
        await runStep(model, scope: .all) { await fSortAddSort($0) }
        await runStep(model, scope: .all) { await fSortClearAll($0) }
        await runStep(model, scope: .all) { await fSortDragUnderSort($0) }
    }

    // MARK: Helpers

    /// Titles of the given probes in the order their rows are drawn (top to bottom).
    private static func fSortRenderedOrder(_ titles: [String]) -> [String] {
        titles.compactMap { t in UITestAnchors.frames["row." + t].map { (t, $0.minY) } }
            .sorted { $0.1 < $1.1 }.map(\.0)
    }

    private static func fSortWaitRows(_ titles: [String]) async -> Bool {
        await waitUntil(timeout: 4) { titles.allSatisfy { UITestAnchors.frames["row." + $0] != nil } }
    }

    /// A project of its own so the list holds exactly the probes: manual order 1..4, priorities
    /// low, urgent, medium, high (so priority-descending is 2, 4, 3, 1).
    private static func fSortFixture(_ model: AppModel, _ tag: String) -> (project: KProject, tasks: [KTask]) {
        let store = model.store
        let project = store.createProject(name: "fsort.\(tag)")
        let priorities: [KPriority] = [.low, .urgent, .medium, .high]
        var tasks: [KTask] = []
        for (i, p) in priorities.enumerated() {
            let t = store.create(title: "fsort.\(tag).M\(i + 1)", project: project)
            store.setPriority(t.id, p)
            tasks.append(t)
        }
        model.didMutate()
        return (project, tasks)
    }

    private static func fSortOpen(_ model: AppModel, _ project: KProject, _ titles: [String]) async -> ListScope {
        let scope = ListScope.project(project.id)
        model.setOptions(.default, for: scope)
        model.scope = scope
        var frame = window.frame
        frame.size = NSSize(width: 1500, height: 900)
        window.setFrame(frame, display: true)
        _ = await fSortWaitRows(titles)
        await settle(300)
        return scope
    }

    /// The popover's own edit: its sort builder lists the current order as a row, "Add sort" appends one.
    private static func fSortAddRule(_ model: AppModel, _ scope: ListScope, _ key: KSortKey, ascending: Bool) {
        let opts = model.options(for: scope)
        let rules = ViewOptionsMapper.sortRules(from: opts.sort)
            + [KSortRule(field: ViewOptionsMapper.sortField(key), ascending: ascending)]
        model.setOptions(ViewOptionsMapper.sortEdit(rules, on: opts), for: scope)
    }

    private static func fSortManualTitles(_ model: AppModel, _ project: KProject) -> [String] {
        KTaskSorter.sorted(model.store.allTasks().filter { $0.project?.id == project.id && $0.parentID == nil },
                           by: [.asc(.manual)]).map(\.title)
    }

    /// Everything Clear all must leave exactly as it was: every row's order value and every step's.
    private static func fSortRows(_ model: AppModel, _ project: KProject) -> [String] {
        model.store.allTasks().filter { $0.project?.id == project.id }
            .map { "\($0.title)|\($0.sortIndex)|\($0.parentID?.uuidString ?? "-")" }.sorted()
    }

    private static func fSortClosePopover(_ model: AppModel) async {
        key("\u{1b}", keyCode: 53)
        await settle(300)
    }

    // MARK: Add sort

    private static func fSortAddSort(_ model: AppModel) async {
        let (project, tasks) = fSortFixture(model, "add")
        let titles = tasks.map(\.title)
        let scope = await fSortOpen(model, project, titles)
        let manual = fSortRenderedOrder(titles)
        record("add sort: a fresh list draws the manual order", manual == titles, "order=\(manual)")

        fSortAddRule(model, scope, .priority, ascending: false)
        await waitUntil(timeout: 4) { fSortRenderedOrder(titles) != titles }
        await settle(300)
        let want = [titles[1], titles[3], titles[2], titles[0]]
        let got = fSortRenderedOrder(titles)
        let stored = model.options(for: scope).sort
        record("add sort: Priority added to a manual list reorders the visible rows",
               got == want && stored == [.desc(.priority)],
               "rows=\(got) want=\(want) sort=\(stored)")
        record("add sort: the active-rules bar appears for it", UITestAnchors.frames["rules.bar"] != nil, "")

        fSortAddRule(model, scope, .title, ascending: true)
        await settle(300)
        record("add sort: a second criterion is added after the first, not instead of it",
               model.options(for: scope).sort == [.desc(.priority), .asc(.title)], "sort=\(model.options(for: scope).sort)")

        // Kept per list: another list stays manual, and this one still holds its sort after a visit elsewhere.
        model.scope = .inbox
        await settle(300)
        let otherManual = model.options(for: .inbox).isManualOrder
        model.scope = scope
        _ = await fSortWaitRows(titles)
        await settle(300)
        let back = fSortRenderedOrder(titles)
        record("add sort: kept for this list only (another list stays manual, this one keeps its order)",
               otherManual && model.options(for: scope).sort == [.desc(.priority), .asc(.title)] && back == want,
               "other=\(otherManual) back=\(back)")

        model.setOptions(.default, for: scope)
        model.scope = .inbox
    }

    // MARK: Clear all

    private static func fSortClearAll(_ model: AppModel) async {
        let store = model.store
        let (project, tasks) = fSortFixture(model, "clear")
        let titles = tasks.map(\.title)
        let withSteps = tasks[1]
        let s1 = store.addSubtask(withSteps.id, title: "fsort.clear.s1")!
        _ = store.addSubtask(withSteps.id, title: "fsort.clear.s2")
        let s3 = store.addSubtask(withSteps.id, title: "fsort.clear.s3")!
        store.reorderChild(s3.id, before: s1.id)   // steps: s3, s1, s2
        model.didMutate()
        let scope = await fSortOpen(model, project, titles)

        // The person drags M4 to the top: the manual order every later check must find again.
        let t = Dictionary(uniqueKeysWithValues: tasks.enumerated().map { ("M\($0.offset + 1)", $0.element) })
        _ = await drag(model, internalTaskPasteboard("M4", t), [DropStop(anchor: "row." + titles[0], y: 0.1, dwellMs: 150)], end: .drop)
        await settle(400)
        let dragged = [titles[3], titles[0], titles[1], titles[2]]
        let rowsBefore = fSortRows(model, project)
        let stepsBefore = store.children(of: withSteps.id).map(\.title)
        record("clear all: the dragged order is the starting point",
               fSortManualTitles(model, project) == dragged && fSortRenderedOrder(titles) == dragged
                && stepsBefore == ["fsort.clear.s3", "fsort.clear.s1", "fsort.clear.s2"],
               "manual=\(fSortManualTitles(model, project)) steps=\(stepsBefore)")

        record("clear all: nothing set, so no rules bar and nothing to clear",
               UITestAnchors.frames["rules.bar"] == nil && !model.options(for: scope).hasRulesToClear, "")

        // A sort and a filter on top.
        fSortAddRule(model, scope, .title, ascending: false)
        var o = model.options(for: scope)
        o.filter.priorities = [KPriority.urgent.rawValue, KPriority.high.rawValue]
        model.setOptions(o, for: scope)
        await waitUntil(timeout: 4) { UITestAnchors.frames["rules.clearall"] != nil }
        await settle(300)
        let sortedShown = fSortRenderedOrder(titles)
        record("clear all: with a sort and a filter set, the list is sorted and filtered and offers Clear all",
               sortedShown == [titles[3], titles[1]] && UITestAnchors.frames["rules.clearall"] != nil,
               "rows=\(sortedShown)")

        // The control in the active-rules bar.
        let undoDepth = store.undoDepth
        let clicked = await click("rules.clearall")
        await waitUntil(timeout: 4) { !model.options(for: scope).hasRulesToClear }
        await waitUntil(timeout: 4) { fSortRenderedOrder(titles) == dragged }
        await settle(300)
        let cleared = model.options(for: scope)
        let shown = fSortRenderedOrder(titles)
        record("clear all: one click removes every sort and filter and the list is the dragged order again",
               clicked && cleared.sort == KSortDescriptor.default && cleared.filter == .empty && shown == dragged,
               "clicked=\(clicked) sort=\(cleared.sort) rows=\(shown)")
        record("clear all: no row was rewritten (order values and step order unchanged), no store undo step",
               fSortRows(model, project) == rowsBefore && store.children(of: withSteps.id).map(\.title) == stepsBefore
                && store.undoDepth == undoDepth,
               "steps=\(store.children(of: withSteps.id).map(\.title)) undo=\(store.undoDepth - undoDepth)")
        record("clear all: the control is gone again and the pill offers Undo",
               UITestAnchors.frames["rules.bar"] == nil && UndoToastCenter.shared.current?.message == String(localized: "list.pill.viewcleared")
                && UndoToastCenter.shared.current?.customUndo != nil,
               "pill=\(UndoToastCenter.shared.current?.message ?? "none")")

        // One undo step puts everything back.
        let undone = UndoToastCenter.shared.performCustomUndo()
        await waitUntil(timeout: 4) { fSortRenderedOrder(titles) == [titles[3], titles[1]] }
        let restored = model.options(for: scope)
        record("clear all: one undo restores the sort and the filter together",
               undone && restored.sort == [.desc(.title)] && restored.filter.priorities.count == 2
                && fSortRenderedOrder(titles) == [titles[3], titles[1]],
               "undone=\(undone) sort=\(restored.sort) rows=\(fSortRenderedOrder(titles))")

        // The same control in the view-options popover (its own window: a click cannot be aimed at it from here,
        // so the step proves it is offered; the button calls the same ListViewReset.clearAll the bar button did).
        NotificationCenter.default.post(name: .kronosViewOptionsRequested, object: nil)
        let seen = await waitUntil(timeout: 4) { UITestAnchors.frames["viewoptions.clearall"] != nil }
        await fSortClosePopover(model)
        ListViewReset.clearAll(model: model, scope: scope)
        await waitUntil(timeout: 4) { fSortRenderedOrder(titles) == dragged }
        record("clear all: the view-options popover offers it while rules are set, and the same call restores the dragged order",
               seen && !model.options(for: scope).hasRulesToClear && fSortRenderedOrder(titles) == dragged
                && fSortRows(model, project) == rowsBefore,
               "seen=\(seen) rows=\(fSortRenderedOrder(titles))")

        // Nothing set: the popover does not offer it.
        NotificationCenter.default.post(name: .kronosViewOptionsRequested, object: nil)
        await settle(900)
        let offered = UITestAnchors.frames["viewoptions.clearall"] != nil
        await fSortClosePopover(model)
        record("clear all: with nothing set the popover does not offer it", !offered, "offered=\(offered)")
        UndoToastCenter.shared.dismiss()
        model.setOptions(.default, for: scope)
        model.scope = .inbox
    }

    // MARK: Drag under a sort

    private static func fSortDragUnderSort(_ model: AppModel) async {
        let store = model.store
        let (project, tasks) = fSortFixture(model, "drag")
        let titles = tasks.map(\.title)
        let scope = await fSortOpen(model, project, titles)
        let t = Dictionary(uniqueKeysWithValues: tasks.enumerated().map { ("M\($0.offset + 1)", $0.element) })

        fSortAddRule(model, scope, .title, ascending: false)   // M4, M3, M2, M1
        let reversed = Array(titles.reversed())
        await waitUntil(timeout: 4) { fSortRenderedOrder(titles) == reversed }
        await settle(300)
        let rowsBefore = fSortRows(model, project)
        let depth = store.undoDepth
        ListSortDragHint.shared.dismiss()
        let top = reversed[0]
        _ = await drag(model, internalTaskPasteboard("M1", t), [DropStop(anchor: "row." + top, y: 0.1, dwellMs: 200)], end: .drop)
        let shown = await waitUntil(timeout: 4) { UITestAnchors.frames["list.sorthint"] != nil }
        await settle(300)
        record("drag under a sort: the drop moves nothing, writes nothing, and a one-line hint says why",
               shown && fSortRows(model, project) == rowsBefore && store.undoDepth == depth
                && fSortRenderedOrder(titles) == reversed,
               "hint=\(shown) steps=\(store.undoDepth - depth) rows=\(fSortRenderedOrder(titles))")
        record("drag under a sort: the hint offers Switch to manual order",
               UITestAnchors.frames["list.sorthint.switch"] != nil, "")

        let clicked = await click("list.sorthint.switch")
        await waitUntil(timeout: 4) { model.options(for: scope).isManualOrder }
        await waitUntil(timeout: 4) { fSortRenderedOrder(titles) == titles }
        await settle(300)
        record("drag under a sort: Switch to manual order restores the manual order and the hint goes",
               clicked && model.options(for: scope).isManualOrder && fSortRenderedOrder(titles) == titles
                && UITestAnchors.frames["list.sorthint"] == nil && fSortRows(model, project) == rowsBefore,
               "clicked=\(clicked) rows=\(fSortRenderedOrder(titles))")

        // In manual order the same drag now reorders.
        _ = await drag(model, internalTaskPasteboard("M4", t), [DropStop(anchor: "row." + titles[0], y: 0.1, dwellMs: 150)], end: .drop)
        await settle(400)
        record("drag under a sort: in manual order the drag reorders for real",
               fSortManualTitles(model, project) == [titles[3], titles[0], titles[1], titles[2]],
               "manual=\(fSortManualTitles(model, project))")
        UndoToastCenter.shared.dismiss()
        model.setOptions(.default, for: scope)
        model.scope = .inbox
    }
}
#endif

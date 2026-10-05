// Live steps for the list view options: the X on a rule chip removes the rule (popover closed and
// open); the sort and filter editors offer only what means something on the list and their X buttons
// work; every offered filter field can be given a value and narrows the list; "Show completed" works in
// every list that holds closed tasks; a list sorted by an attribute puts the tasks without it in their own
// group and can suggest the value. Run alone with `--only group:L-VIEW`.
#if !RELEASE
import AppKit
import KronosCore

@MainActor
extension LiveUITest {
    static func lViewSteps(_ model: AppModel) async {
        await runStep(model, scope: .all) { await lViewChipRemove($0) }
        await runStep(model, scope: .all) { await lViewEditors($0) }
        await runStep(model, scope: .all) { await lViewFilterFields($0) }
        await runStep(model, scope: .all) { await lViewPlaceholderRows($0) }
        await runStep(model, scope: .all) { await lViewShowCompleted($0) }
        await runStep(model, scope: .all) { await lViewMissingGroup($0) }
    }

    // MARK: Helpers

    private static var lViewBreak: Bool { ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil }

    private static func lViewRendered(_ titles: [String]) -> [String] {
        titles.compactMap { t in UITestAnchors.frames["row." + t].map { (t, $0.minY) } }
            .sorted { $0.1 < $1.1 }.map(\.0)
    }

    private static func lViewWaitRows(_ titles: [String]) async {
        await waitUntil(timeout: 4) { titles.allSatisfy { UITestAnchors.frames["row." + $0] != nil } }
    }

    /// Waits until exactly `titles` (of `among`) are drawn, in any order.
    @discardableResult
    private static func lViewWaitShown(_ titles: [String], among: [String]) async -> Bool {
        let want = Set(titles)
        let ok = await waitUntil(timeout: 4) { Set(lViewRendered(among)) == want }
        await settle(200)
        return ok
    }

    /// Titles of the rows the list model holds (what the screen draws, whether or not it is scrolled to).
    private static func lViewRows(_ model: AppModel, among titles: [String]) -> [String] {
        let want = Set(titles)
        return ListContext(model: model).rows.map(\.title).filter { want.contains($0) }
    }

    /// A project of its own, so the list holds exactly the probes. Priorities: low, urgent, medium, high.
    private static func lViewProject(_ model: AppModel, _ tag: String) -> (project: KProject, tasks: [KTask]) {
        let store = model.store
        let project = store.createProject(name: "lview.\(tag)")
        var tasks: [KTask] = []
        for (i, p) in [KPriority.low, .urgent, .medium, .high].enumerated() {
            let t = store.create(title: "lview.\(tag).M\(i + 1)", project: project)
            store.setPriority(t.id, p)
            tasks.append(t)
        }
        model.didMutate()
        return (project, tasks)
    }

    private static func lViewOpen(_ model: AppModel, _ scope: ListScope, _ titles: [String]) async {
        model.setOptions(.default, for: scope)
        model.scope = scope
        var frame = window.frame
        frame.size = NSSize(width: 1500, height: 900)
        window.setFrame(frame, display: true)
        await lViewWaitRows(titles)
        await settle(300)
    }

    /// A task triage must leave alone (every field locked), so a probe keeps exactly the values set here.
    private static func lViewLock(_ model: AppModel, _ id: UUID) {
        model.store.updateNoUndo(id) { $0.lockedFieldsRaw = TriageFieldKind.encode(TriageFieldKind.allCases); $0.needsTriage = false }
    }

    // MARK: The view-options popover (its own window)

    private static func lViewPopoverWindow() -> NSWindow? {
        NSApp.windows.first { $0 !== window && $0.isVisible && $0.className.contains("Popover") }
    }

    private static func lViewOpenPopover(waitFor anchor: String) async -> Bool {
        NotificationCenter.default.post(name: .kronosViewOptionsRequested, object: nil)
        let up = await waitUntil(timeout: 4) { UITestAnchors.frames[anchor] != nil && lViewPopoverWindow() != nil }
        await settle(300)
        return up
    }

    /// Runs `body` with the popover's window as the test window (clicks and keys go to it), then restores.
    private static func lViewInPopover(_ body: () async -> Bool) async -> Bool {
        guard let main = window, let pop = lViewPopoverWindow() else { return false }
        window = pop
        defer { window = main }
        return await body()
    }

    private static func lViewClickPopover(_ id: String, xFraction: CGFloat = 0.5) async -> Bool {
        await lViewInPopover { await click(id, xFraction: xFraction) }
    }

    private static func lViewClosePopover() async {
        key("\u{1b}", keyCode: 53)
        let closed = await waitUntil(timeout: 2) { lViewPopoverWindow() == nil }
        if !closed {
            // Esc did not reach it from the main window: press it in the popover's own window.
            _ = await lViewInPopover { key("\u{1b}", keyCode: 53); return true }
            await waitUntil(timeout: 2) { lViewPopoverWindow() == nil }
        }
        await settle(200)
    }

    // MARK: X on a chip

    /// The person adds a sort and a filter, then clicks the X on the chip: the rule must go, whether the
    /// view-options popover is closed or still open behind it.
    private static func lViewChipRemove(_ model: AppModel) async {
        let (project, tasks) = lViewProject(model, "chip")
        let titles = tasks.map(\.title)
        let scope = ListScope.project(project.id)
        await lViewOpen(model, scope, titles)

        // 1. A sort chip, popover closed.
        var o = model.options(for: scope)
        o.sort = [.desc(.priority)]
        model.setOptions(o, for: scope)
        await waitUntil(timeout: 4) { UITestAnchors.frames["rules.chip.remove.sort.0"] != nil }
        await settle(300)
        let sortShown = UITestAnchors.frames["rules.chip.remove.sort.0"] != nil
        let clicked1 = await click("rules.chip.remove.sort.0")
        await waitUntil(timeout: 3) { model.options(for: scope).isManualOrder }
        await settle(300)
        record("chip X: a sort chip is removed by its X (popover closed), the list is manual again and the bar is gone",
               sortShown && clicked1 && model.options(for: scope).isManualOrder && UITestAnchors.frames["rules.bar"] == nil
                && lViewRendered(titles) == titles,
               "shown=\(sortShown) clicked=\(clicked1) sort=\(model.options(for: scope).sort) bar=\(UITestAnchors.frames["rules.bar"] != nil)")

        // 2. A filter chip, popover closed.
        o = model.options(for: scope)
        o.filter.priorities = [KPriority.urgent.rawValue, KPriority.high.rawValue]
        model.setOptions(o, for: scope)
        await waitUntil(timeout: 4) { UITestAnchors.frames["rules.chip.remove.filter.0"] != nil }
        await settle(300)
        let filterShown = UITestAnchors.frames["rules.chip.remove.filter.0"] != nil
        let narrowed = lViewRendered(titles) == [titles[1], titles[3]]
        let clicked2 = await click("rules.chip.remove.filter.0")
        await waitUntil(timeout: 3) { model.options(for: scope).filter == .empty }
        await lViewWaitRows(titles)
        record("chip X: a filter chip is removed by its X, all four rows are back",
               filterShown && narrowed && clicked2 && model.options(for: scope).filter == .empty
                && lViewRendered(titles) == titles,
               "shown=\(filterShown) narrowed=\(narrowed) clicked=\(clicked2) filter=\(model.options(for: scope).filter == .empty ? "empty" : "set") rows=\(lViewRendered(titles))")

        // 3. A sort chip while the view-options popover is open: one click on the X must remove it
        //    (the click that dismisses the popover must not swallow it).
        o = model.options(for: scope)
        o.sort = [.asc(.title)]
        model.setOptions(o, for: scope)
        await waitUntil(timeout: 4) { UITestAnchors.frames["rules.chip.remove.sort.0"] != nil }
        NotificationCenter.default.post(name: .kronosViewOptionsRequested, object: nil)
        let popoverOpen = await waitUntil(timeout: 4) { UITestAnchors.frames["viewoptions.clearall"] != nil }
        await settle(300)
        let clicked3 = await click("rules.chip.remove.sort.0")
        await waitUntil(timeout: 3) { model.options(for: scope).isManualOrder }
        await settle(300)
        let removed3 = model.options(for: scope).isManualOrder
        record("chip X: with the popover open, one click on a chip's X removes the rule",
               popoverOpen && clicked3 && (lViewBreak ? !removed3 : removed3),
               "popover=\(popoverOpen) clicked=\(clicked3) sort=\(model.options(for: scope).sort)")
        await lViewClosePopover()
        model.setOptions(.default, for: scope)
        model.scope = .inbox
    }

    // MARK: The editors in the popover

    /// Real clicks inside the popover: the X on a sort row and on a filter row remove the rule (the old
    /// ones hit only the 8 pt glyph, and the sort X matched no row at all), a typed text filter narrows
    /// the list, and the default order shows no Manual row.
    private static func lViewEditors(_ model: AppModel) async {
        let (project, tasks) = lViewProject(model, "edit")
        let titles = tasks.map(\.title)
        let scope = ListScope.project(project.id)
        await lViewOpen(model, scope, titles)

        // The default order has no Manual row; "Add filter" is offered.
        let up = await lViewOpenPopover(waitFor: "filter.add")
        record("editors: the default order shows no Manual row to remove, and Add filter is offered",
               up && UITestAnchors.frames["sort.remove.manual"] == nil && UITestAnchors.frames["filter.add"] != nil,
               "popover=\(up) manualRow=\(UITestAnchors.frames["sort.remove.manual"] != nil)")
        await lViewClosePopover()

        // The sort row's X.
        var o = model.options(for: scope)
        o.sort = [.desc(.priority)]
        model.setOptions(o, for: scope)
        await settle(300)
        let sortUp = await lViewOpenPopover(waitFor: "sort.remove.priority")
        let sortFrame = UITestAnchors.frames["sort.remove.priority"] ?? .zero
        let hit = sortFrame.width >= Metrics.minHit - 1 && sortFrame.height >= Metrics.minHit - 1
        let sortClicked = await lViewClickPopover("sort.remove.priority")
        await waitUntil(timeout: 3) { model.options(for: scope).isManualOrder }
        await lViewClosePopover()
        await lViewWaitRows(titles)
        record("editors: a click on the X of a sort row in the popover removes the rule and the list is manual again",
               sortUp && hit && sortClicked && model.options(for: scope).isManualOrder && lViewRendered(titles) == titles,
               "popover=\(sortUp) frame=\(Int(sortFrame.width))x\(Int(sortFrame.height)) clicked=\(sortClicked) sort=\(model.options(for: scope).sort) rows=\(lViewRendered(titles))")

        // The filter row's X.
        o = model.options(for: scope)
        o.filter.priorities = [KPriority.urgent.rawValue, KPriority.high.rawValue]
        model.setOptions(o, for: scope)
        await settle(300)
        let narrowed = lViewRendered(titles) == [titles[1], titles[3]]
        let filterUp = await lViewOpenPopover(waitFor: "filter.remove.priority")
        let filterClicked = await lViewClickPopover("filter.remove.priority")
        await waitUntil(timeout: 3) { model.options(for: scope).filter == .empty }
        await lViewClosePopover()
        await lViewWaitRows(titles)
        record("editors: a click on the X of a filter row in the popover removes the rule and all rows are back",
               narrowed && filterUp && filterClicked && model.options(for: scope).filter == .empty && lViewRendered(titles) == titles,
               "narrowed=\(narrowed) popover=\(filterUp) clicked=\(filterClicked) rows=\(lViewRendered(titles))")

        // A typed Text filter: type into the row's own field.
        o = model.options(for: scope)
        o.filter.text = "M"
        model.setOptions(o, for: scope)
        await settle(300)
        let textUp = await lViewOpenPopover(waitFor: "filter.row.text")
        let focused = await lViewClickPopover("filter.row.text", xFraction: 0.62)
        await settle(300)
        _ = await lViewInPopover {
            await typeText("3")
            return true
        }
        await waitUntil(timeout: 3) { model.options(for: scope).filter.text == "M3" }
        await lViewClosePopover()
        await lViewWaitRows([titles[2]])
        let typed = model.options(for: scope).filter.text
        record("editors: typing in a Text filter row writes the filter and narrows the list to the matching task",
               textUp && focused && (lViewBreak ? typed != "M3" : typed == "M3") && lViewRendered(titles) == [titles[2]],
               "popover=\(textUp) focused=\(focused) text=\(typed) rows=\(lViewRendered(titles))")
        model.setOptions(.default, for: scope)
        model.scope = .inbox
    }

    // MARK: Every offered filter field

    /// Each field the project list offers: "Add filter" gives a row (a "Choose…" row where the value comes
    /// next), a value narrows the drawn list to exactly the probes that have it, and a stale hidden filter
    /// stored for the list is ignored instead of emptying it.
    private static func lViewFilterFields(_ model: AppModel) async {
        let store = model.store
        let (project, tasks) = lViewProject(model, "filt")
        let titles = tasks.map(\.title)
        let today = Day.today()
        let scope = ListScope.project(project.id)
        for t in tasks { lViewLock(model, t.id) }
        let effort: [KEffort] = [.xl, .l, .s, .m]
        for (t, e) in zip(tasks, effort) { store.updateNoUndo(t.id) { $0.effortRaw = e.rawValue } }
        store.updateNoUndo(tasks[2].id) { $0.statusRaw = KStatus.inProgress.rawValue }
        store.updateNoUndo(tasks[1].id) { $0.notes = "has a note"; $0.needsTriage = true }
        store.updateNoUndo(tasks[3].id) { $0.dueDay = today }
        let label = store.label(named: "lview.label")
        store.addLabel(label, to: tasks[2].id)
        _ = store.addSubtask(tasks[3].id, title: "lview.filt.step")
        model.didMutate()
        await lViewOpen(model, scope, titles)

        let shape = scope.shape
        let offered = ViewFieldCatalog.filterFields(for: shape)
        record("fields: a project list offers nine filter fields and neither Project nor Area",
               offered.count == 9 && !offered.contains(.project) && !offered.contains(.area) && !offered.contains(.depths),
               "offered=\(offered.map(\.rawValue))")

        // field -> (the filter a picked value gives, the probes that must remain)
        func make(_ f: KFilter.Field) -> (KFilter, [String])? {
            var x = KFilter.empty
            switch f {
            case .statuses: x = ViewOptionsMapper.setting(.status, ints: ViewOptionsMapper.toggling(KStatus.inProgress.rawValue, in: [], sortedBy: <), in: x); return (x, [titles[2]])
            case .priorities: x = ViewOptionsMapper.setting(.priority, ints: ViewOptionsMapper.toggling(KPriority.urgent.rawValue, in: [], sortedBy: <), in: x); return (x, [titles[1]])
            case .efforts: x = ViewOptionsMapper.setting(.effort, ints: ViewOptionsMapper.toggling(KEffort.s.rawValue, in: [], sortedBy: <), in: x); return (x, [titles[2]])
            case .labels: x.labelIDs = [label.id]; return (x, [titles[2]])
            case .due: x = ViewOptionsMapper.adding(.deadline, to: x).filter; return (x, [titles[3]])
            case .hasSubtasks:
                // Whoever has steps in the store right now (a probe may have been given some besides M4's own).
                x = ViewOptionsMapper.adding(.hasSubtasks, to: x).filter
                let withSteps = zip(tasks, titles).filter { !store.children(of: $0.0.id).isEmpty }.map(\.1)
                return (x, withSteps)
            case .hasNotes: x = ViewOptionsMapper.adding(.hasNotes, to: x).filter; return (x, [titles[1]])
            case .needsTriage: x = ViewOptionsMapper.adding(.needsTriage, to: x).filter; return (x, [titles[1]])
            case .text: x.text = "M1"; return (x, [titles[0]])
            default: return nil
            }
        }
        var rowless: [String] = [], wrong: [String] = []
        for field in offered {
            let id = ViewOptionsMapper.filterFieldID(field)
            // 1. The add path gives a row at once.
            let added = ViewOptionsMapper.adding(id, to: .empty)
            let rows = ViewOptionsMapper.filterRules(from: added.filter, pending: added.needsValue ? [id] : [],
                                                     projectName: { _ in nil }, areaName: { _ in nil }, labelName: { _ in nil })
            if !rows.contains(where: { $0.id == AnyHashable(id) }) { rowless.append(field.rawValue) }
            // 2. A value narrows the drawn list. Start each field from the whole list, so the wait below cannot be
            //    satisfied by the previous field's rows.
            guard let (filter, want) = make(field) else { wrong.append(field.rawValue + "(no value)"); continue }
            model.setOptions(.default, for: scope)
            await lViewWaitShown(titles, among: titles)
            var o = ViewOptions.default
            o.filter = filter
            model.setOptions(o, for: scope)
            await lViewWaitShown(want, among: titles)
            let got = lViewRendered(titles)
            if Set(got) != Set(want) {
                let kids = tasks.map { store.children(of: $0.id).count }
                wrong.append("\(field.rawValue):\(got) want=\(want) listModel=\(lViewRows(model, among: titles)) children=\(kids)")
            }
        }
        record("fields: every offered filter field has a row on Add filter and a value that narrows the list to exactly its probes",
               rowless.isEmpty && wrong.isEmpty, "rowless=\(rowless) wrong=\(wrong)")

        // A stale project filter and a hidden sort stored for a project list do not empty it.
        var stale = ViewOptions.default
        stale.filter.projectIDs = [UUID()]
        stale.filter.depths = [KDepth.deep.rawValue]
        stale.sort = [.asc(.area)]
        model.setOptions(stale, for: scope)
        await lViewWaitShown(titles, among: titles)
        let ctx = ListContext(model: model)
        record("fields: stored options a project list does not offer (another project, depth, area sort) are ignored, all rows stay",
               Set(lViewRendered(titles)) == Set(titles) && ctx.options.isManualOrder && ctx.options.filter == .empty
                && UITestAnchors.frames["rules.bar"] == nil,
               "rows=\(lViewRendered(titles)) sort=\(ctx.options.sort) bar=\(UITestAnchors.frames["rules.bar"] != nil)")
        model.setOptions(.default, for: scope)
        model.scope = .inbox
    }

    // MARK: A field added in the editor

    /// "Add filter" on a field that needs a value gives a row at once ("Choose…"), stores nothing, keeps the
    /// same row when the value is picked, and a Text row takes typing.
    private static func lViewPlaceholderRows(_ model: AppModel) async {
        let (project, tasks) = lViewProject(model, "pend")
        let titles = tasks.map(\.title)
        let scope = ListScope.project(project.id)
        await lViewOpen(model, scope, titles)
        for id in ["filter.row.priority", "filter.row.text"] {
            UITestAnchors.frames[id] = nil
            UITestAnchors.owners[id] = nil
        }
        ListViewOptionsPopoverContent.seedPending = [.priority, .text]
        let up = await lViewOpenPopover(waitFor: "filter.row.text")
        await waitUntil(timeout: 3) { UITestAnchors.frames["filter.row.priority"] != nil }
        let rowsDrawn = UITestAnchors.frames["filter.row.priority"] != nil && UITestAnchors.frames["filter.row.text"] != nil
        let nothingStored = model.options(for: scope).filter == .empty && Set(lViewRendered(titles)) == Set(titles)

        // The menu's own write: the same row now holds a value and the list narrows.
        var o = model.options(for: scope)
        o.filter = ViewOptionsMapper.setting(.priority, ints: [KPriority.urgent.rawValue, KPriority.high.rawValue], in: o.filter)
        model.setOptions(o, for: scope)
        await lViewWaitShown([titles[1], titles[3]], among: titles)
        let kept = UITestAnchors.frames["filter.row.priority"] != nil

        let focused = await lViewClickPopover("filter.row.text", xFraction: 0.62)
        await settle(300)
        _ = await lViewInPopover {
            await typeText("M4")
            return true
        }
        await waitUntil(timeout: 3) { model.options(for: scope).filter.text == "M4" }
        await lViewWaitShown([titles[3]], among: titles)
        let f = model.options(for: scope).filter
        await lViewClosePopover()
        record("fields: a field added in the editor shows a row at once with nothing stored; picking a value keeps the row and narrows; a Text row takes typing",
               up && rowsDrawn && nothingStored && kept && focused && f.priorities.count == 2 && f.text == "M4"
                && lViewRendered(titles) == [titles[3]],
               "popover=\(up) rows=\(rowsDrawn) nothingStored=\(nothingStored) kept=\(kept) focused=\(focused) text=\(f.text) shown=\(lViewRendered(titles))")
        model.setOptions(.default, for: scope)
        model.scope = .inbox
    }

    // MARK: Show completed

    /// A closed task, completed `daysAgo` days back, optionally with a due day.
    private static func lViewClosed(_ model: AppModel, _ title: String, project: KProject? = nil, daysAgo: Int = 0, due: Int? = nil) -> KTask {
        let store = model.store
        let t = store.create(title: title, project: project, dueDay: due)
        store.complete(t.id)
        let when = Date().addingTimeInterval(-Double(daysAgo) * 86_400)
        store.updateNoUndo(t.id) { $0.completedAt = when }
        lViewLock(model, t.id)
        return t
    }

    private static func lViewOpenTask(_ model: AppModel, _ title: String, project: KProject? = nil, due: Int? = nil, status: KStatus = .todo) -> KTask {
        let t = model.store.create(title: title, project: project, status: status, dueDay: due)
        lViewLock(model, t.id)
        return t
    }

    private static func lViewShowCompleted(_ model: AppModel) async {
        let today = Day.today()
        // Closed tasks of the fixed lists. Titles are unique so no other probe can be mistaken for them.
        let o1 = lViewOpenTask(model, "lview.sc.all.open"), d1 = lViewClosed(model, "lview.sc.all.done")
        let o2 = lViewOpenTask(model, "lview.sc.inbox.open"), d2 = lViewClosed(model, "lview.sc.inbox.done")
        let o3 = lViewOpenTask(model, "lview.sc.today.open", due: today)
        let d3 = lViewClosed(model, "lview.sc.today.done")
        let d3b = lViewClosed(model, "lview.sc.today.done.carried", daysAgo: 0, due: today - 4)
        let d3old = lViewClosed(model, "lview.sc.today.done.old", daysAgo: 3, due: today - 3)
        let o4 = lViewOpenTask(model, "lview.sc.next7.open", due: today + 3)
        let d4 = lViewClosed(model, "lview.sc.next7.done")
        let d4w = lViewClosed(model, "lview.sc.next7.done.window", daysAgo: 5, due: today + 2)
        let d4old = lViewClosed(model, "lview.sc.next7.done.old", daysAgo: 5, due: today + 40)
        let w1 = lViewOpenTask(model, "lview.sc.waiting.open", status: .waiting)
        let wd = lViewClosed(model, "lview.sc.waiting.done")
        model.didMutate()

        func shown(_ scope: ListScope, _ names: [String]) -> [String] { lViewRows(model, among: names) }
        func setShowCompleted(_ on: Bool, _ scope: ListScope) {
            var o = model.options(for: scope); o.showCompleted = on; model.setOptions(o, for: scope)
        }
        func check(_ scope: ListScope, open: [KTask], mustAppear: [KTask], mustStay: [KTask]) async -> (off: [String], on: [String], back: [String]) {
            let names = (open + mustAppear + mustStay).map(\.title)
            model.setOptions(.default, for: scope)
            model.scope = scope
            await settle(300)
            let off = shown(scope, names)
            setShowCompleted(true, scope)
            await settle(300)
            let on = shown(scope, names)
            setShowCompleted(false, scope)
            await settle(300)
            let back = shown(scope, names)
            return (off, on, back)
        }
        func sameSet(_ a: [String], _ b: [KTask]) -> Bool { Set(a) == Set(b.map(\.title)) }

        let all = await check(.all, open: [o1], mustAppear: [d1], mustStay: [])
        record("completed: in All the switch brings closed tasks back and turning it off removes them again",
               sameSet(all.off, [o1]) && sameSet(all.on, [o1, d1]) && sameSet(all.back, [o1]),
               "off=\(all.off) on=\(all.on) back=\(all.back)")
        let inbox = await check(.inbox, open: [o2], mustAppear: [d2], mustStay: [])
        record("completed: in the Inbox the switch brings closed tasks back",
               sameSet(inbox.off, [o2]) && sameSet(inbox.on, [o2, d2]) && sameSet(inbox.back, [o2]),
               "off=\(inbox.off) on=\(inbox.on) back=\(inbox.back)")
        let todayR = await check(.today, open: [o3], mustAppear: [d3, d3b], mustStay: [d3old])
        record("completed: in Today the switch adds the tasks completed today (even one that was due days ago), not older history",
               sameSet(todayR.off, [o3]) && sameSet(todayR.on, [o3, d3, d3b]) && sameSet(todayR.back, [o3]),
               "off=\(todayR.off) on=\(todayR.on) back=\(todayR.back)")
        let next7 = await check(.next7, open: [o4], mustAppear: [d4, d4w], mustStay: [d4old])
        record("completed: in Next 7 days the switch adds tasks completed today or scheduled inside the window, not far-off history",
               sameSet(next7.off, [o4]) && sameSet(next7.on, [o4, d4, d4w]) && sameSet(next7.back, [o4]),
               "off=\(next7.off) on=\(next7.on) back=\(next7.back)")
        let waiting = await check(.waiting, open: [w1], mustAppear: [], mustStay: [wd])
        record("completed: in Waiting a closed task never shows, whatever the switch says",
               sameSet(waiting.off, [w1]) && sameSet(waiting.on, [w1]) && sameSet(waiting.back, [w1]),
               "off=\(waiting.off) on=\(waiting.on)")

        // The switch itself: a real click in the popover of All turns it on, and the row is drawn; Waiting offers no switch.
        model.setOptions(.default, for: .all)
        model.scope = .all
        model.searchText = "lview.sc.all"   // two rows only, so both are drawn whatever else the store holds
        await settle(400)
        let up = await lViewOpenPopover(waitFor: "viewoptions.showcompleted")
        var toggled = await lViewClickPopover("viewoptions.showcompleted", xFraction: 0.95)
        await waitUntil(timeout: 1.5) { model.options(for: .all).showCompleted }
        if !model.options(for: .all).showCompleted {
            toggled = await lViewClickPopover("viewoptions.showcompleted", xFraction: 0.12)
            await waitUntil(timeout: 1.5) { model.options(for: .all).showCompleted }
        }
        await lViewClosePopover()
        let drawn = await waitUntil(timeout: 4) { UITestAnchors.frames["row." + d1.title] != nil }
        let clickOn = model.options(for: .all).showCompleted
        record("completed: clicking the switch in the All popover turns it on and the completed task is drawn",
               up && toggled && (lViewBreak ? !clickOn : clickOn) && drawn,
               "popover=\(up) clicked=\(toggled) on=\(clickOn) drawn=\(drawn)")
        setShowCompleted(false, .all)
        model.searchText = ""

        model.scope = .waiting
        // An anchor of the closed popover can outlive it: clear it so only the Waiting popover can report it.
        UITestAnchors.frames["viewoptions.showcompleted"] = nil
        UITestAnchors.owners["viewoptions.showcompleted"] = nil
        await settle(300)
        let waitingUp = await lViewOpenPopover(waitFor: "filter.add")
        record("completed: the Waiting popover offers no Show completed switch (the All popover did)",
               up && waitingUp && UITestAnchors.frames["viewoptions.showcompleted"] == nil,
               "waitingPopover=\(waitingUp) switch=\(UITestAnchors.frames["viewoptions.showcompleted"] != nil)")
        await lViewClosePopover()
        model.setOptions(.default, for: .waiting)
        model.scope = .inbox
    }

    // MARK: Missing group and Suggest

    private static func lViewTriageReply(due: Int) -> String {
        "{\"project\":null,\"priority\":2,\"due\":\"\(Day.iso(due))\",\"depth\":\"shallow\",\"estimateMinutes\":20,"
            + "\"energyKind\":\"admin\",\"firstMove\":\"Open the file and read the first page.\",\"labels\":[],"
            + "\"rationale\":\"A short, concrete job.\"}"
    }

    private static func lViewMissingGroup(_ model: AppModel) async {
        let store = model.store
        let today = Day.today()
        let project = store.createProject(name: "lview.missing")
        // d1, d2 have a deadline; u1, u2 do not. Listed in this manual order.
        var tasks: [KTask] = []
        for (i, due) in [Optional(today + 5), nil, Optional(today + 9), nil].enumerated() {
            let t = store.create(title: "lview.miss.\(i < 2 ? "A" : "B")\(i)", project: project, dueDay: due)
            lViewLock(model, t.id)
            store.updateNoUndo(t.id) { $0.lockedFieldsRaw = "" }   // the suggestion may fill the missing deadline
            tasks.append(t)
        }
        model.didMutate()
        let titles = tasks.map(\.title)
        let dated = [titles[0], titles[2]], undated = [titles[1], titles[3]]
        let scope = ListScope.project(project.id)
        await lViewOpen(model, scope, titles)

        var o = model.options(for: scope)
        o.sort = [.asc(.deadline)]
        model.setOptions(o, for: scope)
        await waitUntil(timeout: 4) { UITestAnchors.frames["list.missing.header"] != nil }
        await lViewWaitRows(titles)
        await settle(300)
        let header = UITestAnchors.frames["list.missing.header"]
        let datedY = dated.compactMap { UITestAnchors.frames["row." + $0]?.minY }
        let undatedY = undated.compactMap { UITestAnchors.frames["row." + $0]?.minY }
        let headerY = header?.minY ?? .nan
        let layout = header != nil && datedY.count == 2 && undatedY.count == 2
            && datedY.allSatisfy { $0 < headerY } && undatedY.allSatisfy { $0 > headerY }
        record("missing: sorted by deadline, the two undated tasks sit under their own header, below the two dated ones",
               layout, "header=\(header.map { Int($0.minY) } ?? -1) dated=\(datedY.map(Int.init)) undated=\(undatedY.map(Int.init))")
        let ctx = ListContext(model: model)
        record("missing: the list model splits the same way (2 present, 2 missing, key deadline)",
               ctx.presentCount == 2 && ctx.missing.count == 2 && ctx.missingKey == .deadline && ctx.rows.count == 4,
               "present=\(ctx.presentCount) missing=\(ctx.missing.count) key=\(String(describing: ctx.missingKey))")

        // Fold the group: the undated rows leave the list model and the screen; the header stays.
        let folded = await click("list.missing.header")
        await waitUntil(timeout: 3) { ListContext(model: model).rows.count == 2 }
        await settle(300)
        let collapsedRows = ListContext(model: model).rows.map(\.title)
        record("missing: folding the group removes its rows from the list and the screen, and the header says how many",
               folded && Set(collapsedRows) == Set(dated) && undated.allSatisfy { UITestAnchors.frames["row." + $0] == nil }
                && UITestAnchors.frames["list.missing.header"] != nil,
               "folded=\(folded) rows=\(collapsedRows)")
        _ = await click("list.missing.header")
        await waitUntil(timeout: 3) { ListContext(model: model).rows.count == 4 }
        await lViewWaitRows(titles)

        // The AI policy decides whether Suggest exists at all.
        let savedAI = model.ai
        let savedPref = TriagePrefs.aiSuggestionsEnabled
        defer { model.ai = savedAI; TriagePrefs.aiSuggestionsEnabled = savedPref }
        let client = FixtureAIClient(modelID: "fixture-model", script: Array(repeating: .content(lViewTriageReply(due: today + 3)), count: 8))
        let router = AIRouter(mode: .allowAny, candidates: [AIRoutedCandidate(client: client)], chainBudgetSeconds: 5)

        func suggestOffered() async -> Bool {
            model.didMutate()
            await settle(400)
            return UITestAnchors.frames["list.missing.suggest"] != nil
        }
        model.ai = nil
        TriagePrefs.aiSuggestionsEnabled = true
        let noRouter = await suggestOffered()
        model.ai = router
        TriagePrefs.aiSuggestionsEnabled = false
        let switchOff = await suggestOffered()
        model.ai = AIRouter(mode: .off, candidates: [AIRoutedCandidate(client: client)])
        TriagePrefs.aiSuggestionsEnabled = true
        let modeOff = await suggestOffered()
        model.ai = router
        let allowed = await suggestOffered()
        record("missing: Suggest is hidden with no router, with the AI switch off and in Off mode, and shown when allowed",
               !noRouter && !switchOff && !modeOff && allowed,
               "noRouter=\(noRouter) switchOff=\(switchOff) modeOff=\(modeOff) allowed=\(allowed)")

        // Suggest, then Fill: both undated tasks get the deadline in one undo step, nothing before.
        let before = undated.compactMap { t in tasks.first { $0.title == t } }.map { store.task($0.id)?.dueDay }
        let asked = await click("list.missing.suggest")
        let ready = await waitUntil(timeout: 8) { UITestAnchors.frames["list.missing.fill"] != nil }
        await settle(300)
        let lines = tasks.filter { undated.contains($0.title) }.allSatisfy { UITestAnchors.frames["list.missing.line.\($0.id.uuidString)"] != nil }
        let untouched = undated.compactMap { t in tasks.first { $0.title == t } }.map { store.task($0.id)?.dueDay }
        record("missing: Suggest lists a proposed deadline for each undated task and writes nothing yet",
               asked && ready && lines && before == [nil, nil] && untouched == [nil, nil],
               "asked=\(asked) ready=\(ready) lines=\(lines) due=\(untouched)")

        let depth = store.undoDepth
        let filled = await click("list.missing.fill")
        await waitUntil(timeout: 4) { tasks.filter { undated.contains($0.title) }.allSatisfy { store.task($0.id)?.dueDay == today + 3 } }
        await settle(400)
        let oneStep = store.undoDepth == depth + 1
        let nowDue = tasks.filter { undated.contains($0.title) }.map { store.task($0.id)?.dueDay }
        let groupGone = UITestAnchors.frames["list.missing.header"] == nil
        record("missing: Fill writes both deadlines in ONE undo step and the group disappears",
               filled && (lViewBreak ? !oneStep : oneStep) && nowDue == [today + 3, today + 3] && groupGone,
               "filled=\(filled) undoSteps=\(store.undoDepth - depth) due=\(nowDue) groupGone=\(groupGone)")
        store.undo()
        model.didMutate()
        await settle(400)
        let restored = tasks.filter { undated.contains($0.title) }.map { store.task($0.id)?.dueDay }
        record("missing: one undo puts both deadlines back (and the group returns)",
               restored == [nil, nil] && store.undoDepth == depth,
               "due=\(restored) depth=\(store.undoDepth - depth)")
        UndoToastCenter.shared.dismiss()
        model.setOptions(.default, for: scope)
        model.scope = .inbox
    }
}
#endif

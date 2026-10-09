// Live steps for the list view options — chip removal and the popover editors: split out of
// LiveUITest+LView.swift to keep that file inside the 500-line limit. Run alone with
// `--only group:L-VIEW`.
#if !RELEASE
import AppKit
import KronosCore

@MainActor
extension LiveUITest {
    // MARK: X on a chip

    /// The person adds a sort and a filter, then clicks the X on the chip: the rule must go, whether the
    /// view-options popover is closed or still open behind it.
    static func lViewChipRemove(_ model: AppModel) async {
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
    static func lViewEditors(_ model: AppModel) async {
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
}
#endif

// Live steps for the list view options — every offered filter field and a field added in the
// editor: split out of LiveUITest+LView.swift to keep that file inside the 500-line limit. Run
// alone with `--only group:L-VIEW`.
#if !RELEASE
import AppKit
import KronosCore

@MainActor
extension LiveUITest {
    // MARK: Every offered filter field

    /// Each field the project list offers: "Add filter" gives a row (a "Choose…" row where the value comes
    /// next), a value narrows the drawn list to exactly the probes that have it, and a stale hidden filter
    /// stored for the list is ignored instead of emptying it.
    static func lViewFilterFields(_ model: AppModel) async {
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
    static func lViewPlaceholderRows(_ model: AppModel) async {
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
}
#endif

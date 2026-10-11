// Kronos/App/LiveUITest+Grouping.swift
// Live steps for "Group by" (spec §4.5-4.6): the pure partitioner in Kronos/List/ListGrouping.swift
// (each mode's fixed section order, `groupKey`, `crossesGroup`) and the list's own wiring — the
// popover's segmented control ("list.viewoptions.groupby"), sticky headers
// ("list.group.header.<key>") that go away for `.none`, and `groupBy` persisted per scope like
// every other view option. Run alone with `--only group:L-GROUP`.
#if !RELEASE
import AppKit
import KronosCore

@MainActor
extension LiveUITest {
    static func lGroupSteps(_ model: AppModel) async {
        await runStep(model, scope: .all) { await lGroupSectionOrder($0) }
        await runStep(model, scope: .all) { await lGroupCrossesGroup($0) }
        await runStep(model, scope: .all) { await lGroupLiveHeaders($0) }
    }

    // MARK: Section order (pure — ListGrouping.sections)

    /// Each mode's fixed order (spec §4.6), proven by handing the partitioner rows built in
    /// REVERSE of the expected output, so a passing result cannot be an accident of input order.
    private static func lGroupSectionOrder(_ model: AppModel) async {
        let store = model.store
        let today = Day.today()

        let statusRows: [(KStatus, String)] = [
            (.canceled, "lgroup.status.canceled"), (.done, "lgroup.status.done"), (.someday, "lgroup.status.someday"),
            (.waiting, "lgroup.status.waiting"), (.todo, "lgroup.status.todo"), (.inProgress, "lgroup.status.inprogress"),
        ]
        let statusTasks = statusRows.map { status, title in
            store.createNoUndo(title: title, notes: "", project: nil, status: status, priority: .none, dueDay: nil)
        }
        let statusKeys = ListGrouping.sections(statusTasks, mode: .status).map(\.key)
        record("group by status: the fixed order is In progress, Todo, Waiting, Someday, Done, Canceled",
               statusKeys == ["status.\(KStatus.inProgress.rawValue)", "status.\(KStatus.todo.rawValue)",
                              "status.\(KStatus.waiting.rawValue)", "status.\(KStatus.someday.rawValue)",
                              "status.\(KStatus.done.rawValue)", "status.\(KStatus.canceled.rawValue)"],
               "keys=\(statusKeys)")

        let priorityRows: [(KPriority, String)] = [
            (.none, "lgroup.prio.none"), (.low, "lgroup.prio.low"), (.medium, "lgroup.prio.medium"),
            (.high, "lgroup.prio.high"), (.urgent, "lgroup.prio.urgent"),
        ]
        let priorityTasks = priorityRows.map { priority, title in
            store.createNoUndo(title: title, notes: "", project: nil, status: .todo, priority: priority, dueDay: nil)
        }
        let priorityKeys = ListGrouping.sections(priorityTasks, mode: .priority).map(\.key)
        record("group by priority: the fixed order is Urgent, High, Medium, Low, No priority",
               priorityKeys == ["priority.\(KPriority.urgent.rawValue)", "priority.\(KPriority.high.rawValue)",
                                "priority.\(KPriority.medium.rawValue)", "priority.\(KPriority.low.rawValue)",
                                "priority.\(KPriority.none.rawValue)"],
               "keys=\(priorityKeys)")

        let dueRows: [(Int?, String)] = [
            (nil, "lgroup.due.none"), (today + 30, "lgroup.due.later"), (today + 5, "lgroup.due.thisweek"),
            (today + 1, "lgroup.due.tomorrow"), (today, "lgroup.due.today"), (today - 3, "lgroup.due.overdue"),
        ]
        let dueTasks = dueRows.map { day, title in
            store.createNoUndo(title: title, notes: "", project: nil, status: .todo, priority: .none, dueDay: day)
        }
        let dueKeys = ListGrouping.sections(dueTasks, mode: .due).map(\.key)
        record("group by due: the fixed order is Overdue, Today, Tomorrow, This week, Later, No due date",
               dueKeys == ["due.overdue", "due.today", "due.tomorrow", "due.thisWeek", "due.later", "due.none"],
               "keys=\(dueKeys)")

        // Project: the project's own (sortIndex, createdAt, id) chain, "No project" last — rows
        // handed in with "No project" FIRST so a pass cannot be input order either.
        let projectA = store.createProject(name: "lgroup.projectA")
        let projectB = store.createProject(name: "lgroup.projectB")
        let noProject = store.createNoUndo(title: "lgroup.noproject", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        let inB = store.createNoUndo(title: "lgroup.inB", notes: "", project: projectB, status: .todo, priority: .none, dueDay: nil)
        let inA = store.createNoUndo(title: "lgroup.inA", notes: "", project: projectA, status: .todo, priority: .none, dueDay: nil)
        let projectKeys = ListGrouping.sections([noProject, inB, inA], mode: .project).map(\.key)
        record("group by project: projects in their own sort order (creation order here), No project last",
               projectKeys == ["project.\(projectA.id.uuidString)", "project.\(projectB.id.uuidString)", "project.none"],
               "keys=\(projectKeys)")

        // .none: one untitled section holding every row, in input order — TaskListScreen never
        // actually renders this (ListGroupedSections falls back to the flat ForEach for .none),
        // the function just stays total so a caller never has to special-case the mode.
        let noneSections = ListGrouping.sections(statusTasks, mode: .none)
        record("group by none: the partitioner stays total — one section, every row, untitled",
               noneSections.count == 1 && noneSections[0].title.isEmpty && noneSections[0].rows.map(\.id) == statusTasks.map(\.id),
               "sections=\(noneSections.count) title=\(noneSections.first?.title ?? "nil")")
    }

    // MARK: crossesGroup / groupKey (pure)

    private static func lGroupCrossesGroup(_ model: AppModel) async {
        let store = model.store
        let low = store.createNoUndo(title: "lgroup.cross.low", notes: "", project: nil, status: .todo, priority: .low, dueDay: nil)
        let urgent = store.createNoUndo(title: "lgroup.cross.urgent", notes: "", project: nil, status: .todo, priority: .urgent, dueDay: nil)
        record("crossesGroup: two tasks in different priority groups cross, a task against itself does not",
               ListGrouping.crossesGroup(dragging: low, onto: urgent, mode: .priority)
                   && !ListGrouping.crossesGroup(dragging: low, onto: low, mode: .priority), "")
        record("crossesGroup: .none never crosses, whatever the tasks",
               !ListGrouping.crossesGroup(dragging: low, onto: urgent, mode: .none), "")
        let keyLow = ListGrouping.groupKey(of: low, mode: .priority)
        let keyUrgent = ListGrouping.groupKey(of: urgent, mode: .priority)
        record("groupKey: nil for .none, and equal exactly when crossesGroup says the pair does not cross",
               ListGrouping.groupKey(of: low, mode: .none) == nil && keyLow == "priority.\(KPriority.low.rawValue)"
                   && (keyLow == keyUrgent) == !ListGrouping.crossesGroup(dragging: low, onto: urgent, mode: .priority), "")
    }

    // MARK: Live: popover control, sticky headers, .none is flat, persisted per scope

    private static func lGroupFixture(_ model: AppModel, _ tag: String) -> (project: KProject, tasks: [KTask]) {
        let store = model.store
        let project = store.createProject(name: "lgroup.live.\(tag)")
        let priorities: [KPriority] = [.low, .high]
        var tasks: [KTask] = []
        for (i, priority) in priorities.enumerated() {
            let t = store.create(title: "lgroup.live.\(tag).\(i)", project: project)
            store.setPriority(t.id, priority)
            tasks.append(t)
        }
        model.didMutate()
        return (project, tasks)
    }

    private static func lGroupOpen(_ model: AppModel, _ project: KProject, _ titles: [String]) async -> ListScope {
        let scope = ListScope.project(project.id)
        model.setOptions(.default, for: scope)
        model.scope = scope
        var frame = window.frame
        frame.size = NSSize(width: 1500, height: 900)
        window.setFrame(frame, display: true)
        if let last = titles.last { await waitUntil(timeout: 4) { UITestAnchors.frames["row." + last] != nil } }
        await settle(300)
        return scope
    }

    private static func lGroupHeaderAnchors() -> [String] {
        UITestAnchors.frames.keys.filter { $0.hasPrefix("list.group.header.") }
    }

    private static func lGroupLiveHeaders(_ model: AppModel) async {
        let (project, tasks) = lGroupFixture(model, "headers")
        let titles = tasks.map(\.title)
        let scope = await lGroupOpen(model, project, titles)

        record("a fresh list has groupBy .none and draws no group headers",
               model.options(for: scope).groupBy == .none && lGroupHeaderAnchors().isEmpty, "")

        // The popover's own control (same write ListViewOptionsPopoverContent.groupByRow's
        // Binding makes, the way F-SORT drives sort rules through ViewOptionsMapper directly).
        NotificationCenter.default.post(name: .kronosViewOptionsRequested, object: nil)
        let controlShown = await waitUntil(timeout: 4) { UITestAnchors.frames["list.viewoptions.groupby"] != nil }
        key("\u{1b}", keyCode: 53)
        await settle(300)
        record("the view-options popover offers the Group by control", controlShown, "")

        var opts = model.options(for: scope)
        opts.groupBy = .priority
        model.setOptions(opts, for: scope)
        await waitUntil(timeout: 4) { !lGroupHeaderAnchors().isEmpty }
        await settle(300)
        let lowKey = "list.group.header.priority.\(KPriority.low.rawValue)"
        let highKey = "list.group.header.priority.\(KPriority.high.rawValue)"
        record("groupBy .priority draws a sticky header per non-empty group, both fixture priorities included",
               UITestAnchors.frames[lowKey] != nil && UITestAnchors.frames[highKey] != nil
                   && titles.allSatisfy { UITestAnchors.frames["row." + $0] != nil },
               "headers=\(lGroupHeaderAnchors())")

        opts.groupBy = .none
        model.setOptions(opts, for: scope)
        await waitUntil(timeout: 4) { lGroupHeaderAnchors().isEmpty }
        await settle(300)
        record(".none clears every group header and keeps drawing the same rows flat",
               lGroupHeaderAnchors().isEmpty && titles.allSatisfy { UITestAnchors.frames["row." + $0] != nil }, "")

        // Persisted per scope: set .priority again, visit another scope, come back — held.
        opts.groupBy = .priority
        model.setOptions(opts, for: scope)
        model.scope = .inbox
        await settle(300)
        let inboxStillNone = model.options(for: .inbox).groupBy == .none
        model.scope = scope
        await waitUntil(timeout: 4) { !lGroupHeaderAnchors().isEmpty }
        record("groupBy is kept for this list only: another list stays .none, this one keeps .priority after a visit elsewhere",
               inboxStillNone && model.options(for: scope).groupBy == .priority && !lGroupHeaderAnchors().isEmpty,
               "inbox=\(model.options(for: .inbox).groupBy) scope=\(model.options(for: scope).groupBy)")

        model.setOptions(.default, for: scope)
        model.scope = .inbox
    }
}
#endif

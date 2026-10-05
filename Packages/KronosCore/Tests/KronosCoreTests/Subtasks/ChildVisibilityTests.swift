#if os(macOS)
import Testing
import Foundation
@testable import KronosCore

/// Every list, count, date scope, search, queue and MCP view over a fixture of parents with
/// children. Expectations are hand-written title tables; today is fixed at 2026-10-10. A child
/// is never its own row or count item; its due day moves its parent; search can still find it.
///
///  Parents (title, project, own due, status) and children (title, due, status):
///   Inbox plain      -      -          todo
///   Parent due later Alpha  2026-10-20 todo   step due today 10-10 todo | step done overdue 10-01 done | step no date
///   Parent no date   Alpha  -          todo   step overdue 10-08 todo
///   Waiting parent   Beta   -          waiting   waiting child (waiting, no date)
///   Someday parent   -      -          someday   someday child (someday, no date)
///   Done parent      Beta   -          done      open child due today 10-10
///   Next week parent Alpha  2026-10-14 todo   late step 10-16 todo
///   Far child parent -      -          todo   far step 10-25 todo
@MainActor
@Suite("ChildVisibilityTests")
struct ChildVisibilityTests {

    private let today = Day.parseISO("2026-10-10")!
    private func day(_ iso: String) -> Int { Day.parseISO(iso)! }

    private struct World {
        let store: TaskStore
        let alpha: KProject, beta: KProject
        let byTitle: [String: KTask]
        func t(_ title: String) -> KTask { byTitle[title]! }
    }

    private func world() throws -> World {
        let store = try TaskStore(inMemory: true)
        let alpha = store.createProject(name: "Alpha")
        let beta = store.createProject(name: "Beta")
        var all: [String: KTask] = [:]

        func parent(_ title: String, project: KProject? = nil, due: String? = nil,
                    status: KStatus = .todo) -> KTask {
            let t = store.createNoUndo(title: title, project: project, status: status)
            t.dueDay = due.map(day)
            t.needsTriage = false
            all[title] = t
            return t
        }
        func child(_ title: String, of p: KTask, due: String? = nil, status: KStatus = .todo) {
            let c = store.addSubtaskNoUndo(p.id, title: title)!
            c.dueDay = due.map(day)
            c.status = status
            if status == .done { c.completedAt = Date() }
            all[title] = c
        }

        _ = parent("Inbox plain")
        let pdl = parent("Parent due later", project: alpha, due: "2026-10-20")
        child("step due today", of: pdl, due: "2026-10-10")
        child("step done overdue", of: pdl, due: "2026-10-01", status: .done)
        child("step no date", of: pdl)
        let pnd = parent("Parent no date", project: alpha)
        child("step overdue", of: pnd, due: "2026-10-08")
        let wp = parent("Waiting parent", project: beta, status: .waiting)
        child("waiting child", of: wp, status: .waiting)
        let sp = parent("Someday parent", status: .someday)
        child("someday child", of: sp, status: .someday)
        let dp = parent("Done parent", project: beta, status: .done)
        child("open child of done", of: dp, due: "2026-10-10")
        let nw = parent("Next week parent", project: alpha, due: "2026-10-14")
        child("late step", of: nw, due: "2026-10-16")
        let fp = parent("Far child parent")
        child("far step", of: fp, due: "2026-10-25")
        return World(store: store, alpha: alpha, beta: beta, byTitle: all)
    }

    private func titles(_ ts: [KTask]) -> [String] { ts.map(\.title).sorted() }

    // MARK: - Lists and counts

    @Test func topLevelListHoldsOnlyParents() throws {
        let w = try world()
        #expect(titles(w.store.allTasks()) == [
            "Done parent", "Far child parent", "Inbox plain", "Next week parent",
            "Parent due later", "Parent no date", "Someday parent", "Waiting parent",
        ])
        // Positive control: the unfiltered read does see all 8 + 9 children.
        #expect(w.store.allTasksIncludingSubtasks().count == 17)
    }

    @Test func dateScopesFollowTheEffectiveDueDay() throws {
        let w = try world()
        let all = w.store.allTasks()
        // Today: open, effective due <= today. Done parent (closed) and the done step do not count.
        #expect(titles(all.filter { DueScope.isToday($0, today: today) })
                == ["Parent due later", "Parent no date"])
        // Next 7: open, effective due in [10-10, 10-17]. Parent no date is overdue (10-08), not next 7.
        #expect(titles(all.filter { DueScope.isNext7($0, today: today) })
                == ["Next week parent", "Parent due later"])
        func filtered(_ window: KFilter.DueWindow) -> [String] {
            var f = KFilter.empty
            f.due = window
            return titles(all.filter { f.matches($0, today: today) })
        }
        #expect(filtered(.overdue) == ["Parent no date"])
        #expect(filtered(.none) == ["Inbox plain", "Someday parent", "Waiting parent"])
        #expect(filtered(.next7) == ["Done parent", "Next week parent", "Parent due later"],
                "the KFilter window does not look at status; ScopeFilter adds the open-only rule")
    }

    @Test func projectCountsCountParentsOnly() throws {
        let w = try world()
        let all = w.store.allTasks()
        let open = KStatus.open
        #expect(all.filter { $0.projectID == w.alpha.id && open.contains($0.status) }.count == 3)
        #expect(all.filter { $0.projectID == w.beta.id && open.contains($0.status) }.count == 1)
        // Positive control: children inherit the project, so the unfiltered pool would say 7 / 3.
        let unfiltered = w.store.allTasksIncludingSubtasks()
        #expect(unfiltered.filter { $0.projectID == w.alpha.id }.count == 3 + 5)
        #expect(unfiltered.filter { $0.projectID == w.beta.id }.count == 2 + 2)
    }

    @Test func statusListsDoNotListChildren() throws {
        let w = try world()
        let all = w.store.allTasks()
        #expect(titles(all.filter { $0.status == .waiting }) == ["Waiting parent"])
        #expect(titles(all.filter { $0.status == .someday }) == ["Someday parent"])
        // Inbox membership: no project, open, not someday.
        #expect(titles(all.filter { $0.projectID == nil && KStatus.open.contains($0.status) && $0.status != .someday })
                == ["Far child parent", "Inbox plain"])
    }

    @Test func defaultOrderUsesTheEffectiveDueDay() throws {
        let w = try world()
        let rows = ["Inbox plain", "Parent due later", "Parent no date", "Next week parent", "Far child parent"].map { w.t($0) }
        // effective: no date | 10-10 | 10-08 | 10-14 | 10-25. Earliest first, undated last.
        #expect(rows.sorted(by: Ordering.priorityThenDue).map(\.title)
                == ["Parent no date", "Parent due later", "Next week parent", "Far child parent", "Inbox plain"])
    }

    // MARK: - Search

    @Test func searchFindsAChildThroughItsParentRowAndAsATaskOnRequest() throws {
        let w = try world()
        let all = w.store.allTasks()
        let needle = KTextFold.fold("STEP overdue")
        #expect(titles(all.filter { $0.titleOrSubtaskTitleContains(needle) }) == ["Parent no date"])
        #expect(titles(all.filter { $0.titleOrSubtaskTitleContains(KTextFold.fold("nothing like this")) }) == [])
        #expect(!w.t("Inbox plain").titleOrSubtaskTitleContains(""), "an empty needle matches nothing")
        // A saved-view text filter behaves the same.
        var f = KFilter.empty
        f.text = "far step"
        #expect(titles(all.filter { f.matches($0, today: today) }) == ["Far child parent"])
        // The palette / MCP can list the child itself.
        #expect(titles(w.store.allTasksIncludingSubtasks().filter { $0.title.contains("far step") }) == ["far step"])
    }

    // MARK: - Completion rule

    /// What the app did before for steps, kept: finishing a task never touches its open steps.
    @Test func completingAParentLeavesItsOpenChildrenOpen() throws {
        let w = try world()
        let parent = w.t("Parent due later")
        w.store.complete(parent.id)
        #expect(w.store.task(parent.id)?.status == .done)
        #expect(w.t("step due today").status == .todo)
        #expect(w.t("step no date").status == .todo)
        #expect(!w.store.allTasks().contains { $0.title == "step due today" })
        // Undo reopens the parent in one step and still touches no child.
        w.store.undo()
        #expect(w.store.task(parent.id)?.status == .todo)
        #expect(w.t("step due today").status == .todo)
    }

    @Test func aRecurringChildRegeneratesUnderItsParentThroughTheCompletionPath() throws {
        let w = try world()
        let parent = w.t("Parent due later")
        let kid = w.t("step due today")
        w.store.update(kid.id) { $0.recurrenceRule = RecurrenceRule.daily(every: 7, anchor: .fromDueDay).wireFormat }
        let topLevelBefore = w.store.allTasks().count
        w.store.complete(kid.id)
        #expect(parent.orderedChildren.map(\.title)
                == ["step due today", "step done overdue", "step no date", "step due today"])
        let open = parent.orderedChildren.filter { $0.title == "step due today" && $0.status == .todo }
        #expect(open.count == 1)
        #expect(open[0].parentID == parent.id)
        #expect(Day.iso(open[0].dueDay ?? 0) == "2026-10-17")
        #expect(w.store.allTasks().count == topLevelBefore, "the new occurrence is not a list row")
        w.store.undo()
        #expect(parent.orderedChildren.filter { $0.title == "step due today" }.count == 1)
    }

    // MARK: - Delete and undo

    @Test func deletingAChildKeepsTheParentAndUndoRestoresIt() throws {
        let w = try world()
        let parent = w.t("Parent no date")
        let kid = w.t("step overdue")
        #expect(parent.effectiveDue == day("2026-10-08"))
        w.store.softDelete(kid.id)
        #expect(parent.orderedChildren.isEmpty)
        #expect(parent.effectiveDue == nil, "a deleted step no longer moves its parent")
        #expect(w.store.task(parent.id) != nil)
        w.store.undo()
        #expect(parent.orderedChildren.map(\.title) == ["step overdue"])
        #expect(parent.effectiveDue == day("2026-10-08"))
    }

    // MARK: - ORDO

    @Test func aChildIsNeverInTheOrdoQueue() throws {
        let w = try world()
        let engine = OrdoEngine(store: w.store)
        let kid = w.t("step due today")
        let depth = w.store.undoDepth
        w.store.sendToOrdo(kid.id)
        #expect(kid.ordoIndex == nil)
        #expect(w.store.undoDepth == depth, "a refused send pushes no undo step")
        w.store.sendToOrdo(w.t("Inbox plain").id)
        #expect(engine.queue.map(\.title) == ["Inbox plain"])
    }

    @Test func nestingAnOrdoTaskLeavesTheQueueAndUndoPutsItBack() throws {
        let w = try world()
        let engine = OrdoEngine(store: w.store)
        let plain = w.t("Inbox plain")
        w.store.sendToOrdo(plain.id)
        let index = try #require(plain.ordoIndex)
        try w.store.setParent(plain.id, to: w.t("Far child parent").id)
        #expect(plain.ordoIndex == nil)
        #expect(engine.queue.isEmpty)
        w.store.undo()
        #expect(plain.parentID == nil)
        #expect(plain.ordoIndex == index)
        #expect(engine.queue.map(\.title) == ["Inbox plain"])
    }

    // MARK: - Triage

    @Test func triageNeverFilesAChildInAProject() throws {
        let w = try world()
        let kid = w.t("far step")                      // parent has no project
        let result = TriageResult(project: "Alpha", priority: 2, due: nil, depth: .shallow,
                                  estimateMinutes: 10, energyKind: .admin, firstMove: "Open the file",
                                  labels: [], rationale: "r")
        let filled = w.store.applyTriage(result, to: kid.id)
        #expect(!filled.contains(.project))
        #expect(kid.projectID == nil)
        #expect(kid.parent?.projectID == nil)
        #expect(filled.contains(.priority), "the other fields are still filled")
        // Positive control: the same result on a top-level task files it.
        let top = w.t("Far child parent")
        #expect(w.store.applyTriage(result, to: top.id).contains(.project))
        #expect(top.projectID == w.alpha.id)
    }

    // MARK: - MCP

    private func call(_ d: MCPDispatcher, _ tool: String, _ args: [String: Any]) throws -> (isError: Bool, body: [String: Any]) {
        let envelope: [String: Any] = ["name": tool, "arguments": args]
        let request = MCPRequest(id: .number(1), method: "tools/call",
                                 paramsData: try JSONSerialization.data(withJSONObject: envelope))
        let response = try #require(d.handle(request))
        let raw = try #require(response.result)
        let obj = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        return ((obj["isError"] as? Bool) ?? false, obj["structuredContent"] as? [String: Any] ?? [:])
    }

    private func mcpTitles(_ body: [String: Any]) -> [String] {
        ((body["tasks"] as? [[String: Any]]) ?? []).compactMap { $0["title"] as? String }.sorted()
    }

    @Test func mcpViewsUseTheEffectiveDueDayAndListParentsOnly() throws {
        let w = try world()
        let d = MCPDispatcher(store: w.store, ranking: RankingEngine(), today: { [today] in today })
        let todayView = try call(d, "list_tasks", ["view": "today"])
        #expect(mcpTitles(todayView.body) == ["Parent due later", "Parent no date"])
        let upcoming = try call(d, "list_tasks", ["view": "upcoming"])
        #expect(mcpTitles(upcoming.body) == ["Next week parent"], "upcoming starts after today; Parent due later is due today through its step")
        let search = try call(d, "list_tasks", ["view": "search", "query": "far step"])
        #expect(mcpTitles(search.body) == ["Far child parent"])
        // Positive control: asking for subtasks lists the child itself.
        let withKids = try call(d, "list_tasks", ["view": "search", "query": "far step", "includeSubtasks": true])
        #expect(mcpTitles(withKids.body) == ["Far child parent", "far step"])
    }

    @Test func mcpRefusesAChildInOrdoAndPromotesAChildFiledElsewhere() throws {
        let w = try world()
        let d = MCPDispatcher(store: w.store, ranking: RankingEngine(), today: { [today] in today })
        let kid = w.t("step overdue")                  // under "Parent no date" (Alpha)
        let refused = try call(d, "ordo_set", ["top": kid.id.uuidString])
        #expect(refused.isError)
        #expect(kid.ordoIndex == nil)

        let same = try call(d, "update_task", ["id": kid.id.uuidString, "project": "Alpha"])
        #expect(same.isError == false)
        #expect(kid.parentID != nil, "the parent's own project keeps it a child")

        let moved = try call(d, "update_task", ["id": kid.id.uuidString, "project": "Beta"])
        #expect(moved.isError == false)
        #expect(kid.parentID == nil, "another project makes it a standalone task")
        #expect(kid.projectID == w.beta.id)
        #expect(w.store.allTasks().contains { $0.id == kid.id })
    }
}

#endif

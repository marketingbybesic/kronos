#if os(macOS)
import Testing
import Foundation
@testable import KronosCore

/// Scope `write.all`: an agent the person gave full control may change any task and manage
/// projects, areas and labels; an agent without it is refused exactly as before.
@MainActor
@Suite struct MCPFullControlTests {

    static let full = AgentScopes([.read, .propose, .writeOwn, .comment, .writeAll])

    private func ids(_ r: AgentRig.Reply, _ key: String) throws -> UUID {
        let o = try #require(r.body[key] as? [String: Any], "no \(key) in \(r.body)")
        let raw = try #require(o["id"] as? String)
        return try #require(UUID(uuidString: raw))
    }

    // MARK: foreign tasks

    @Test func anAgentWithFullControlEditsCompletesAndReopensTheOwnersTask() throws {
        let rig = try AgentRig()
        let me = rig.agent("codex", scopes: Self.full)
        let t = rig.store.createNoUndo(title: "Owner's task")

        let renamed = try rig.call("update_task", ["id": t.id.uuidString, "title": "Renamed by agent", "priority": "high"], as: me)
        #expect(!renamed.isError)
        #expect(rig.store.task(t.id)?.title == "Renamed by agent" && rig.store.task(t.id)?.priority == .high)

        #expect(try !rig.call("complete_task", ["id": t.id.uuidString], as: me).isError)
        #expect(rig.store.task(t.id)?.status == .done)

        #expect(try !rig.call("update_task", ["id": t.id.uuidString, "status": "todo"], as: me).isError, "reopen")
        #expect(rig.store.task(t.id)?.status == .todo)
    }

    @Test func theSameCallsAreRefusedWithoutFullControl() throws {
        let rig = try AgentRig()
        let me = rig.agent("codex", scopes: .standard)
        let t = rig.store.createNoUndo(title: "Owner's task")
        for (tool, args) in [("update_task", ["id": t.id.uuidString, "title": "x"]), ("complete_task", ["id": t.id.uuidString])] as [(String, [String: Any])] {
            let r = try rig.call(tool, args, as: me)
            #expect(r.code == "FORBIDDEN", "\(tool)")
            #expect((r.body["data"] as? [String: Any])?["requiredScope"] as? String == "write.own")
        }
        #expect(rig.store.task(t.id)?.title == "Owner's task" && rig.store.task(t.id)?.status == .todo)
    }

    @Test func fullControlEditsStepsOfTheOwnersTaskAndAddsAndTogglesThem() throws {
        let rig = try AgentRig()
        let me = rig.agent("codex", scopes: Self.full)
        let t = rig.store.createNoUndo(title: "Owner's task")
        let step = try #require(rig.store.addSubtaskNoUndo(t.id, title: "Owner step"))
        #expect(try !rig.call("update_task", ["id": step.id.uuidString, "title": "Renamed step", "priority": "urgent"], as: me).isError)
        #expect(rig.store.task(step.id)?.title == "Renamed step")
        #expect(try !rig.call("toggle_subtask", ["id": step.id.uuidString, "isDone": true], as: me).isError)
        #expect(rig.store.task(step.id)?.status == .done)
        let added = try rig.call("add_subtask", ["taskID": t.id.uuidString, "title": "Agent step"], as: me)
        #expect(!added.isError)
        #expect(rig.store.task(t.id)?.orderedChildren.map(\.title) == ["Renamed step", "Agent step"])
    }

    @Test func fullControlNeverDeletesOrRestoresATaskThatIsNotTheAgents() throws {
        let rig = try AgentRig()
        let me = rig.agent("codex", scopes: Self.full)
        let t = rig.store.createNoUndo(title: "Owner's task")
        let del = try rig.call("delete_task", ["id": t.id.uuidString, "confirm": true], as: me)
        #expect(del.code == "FORBIDDEN")
        #expect(rig.store.task(t.id) != nil)
        rig.store.softDeleteNoUndo(t.id)
        #expect(try rig.call("restore_task", ["id": t.id.uuidString], as: me).code == "FORBIDDEN")
        #expect(rig.store.task(t.id) == nil)
        // Its own task: deleting stays allowed, as for every agent.
        let own = try rig.taskID(try rig.call("create_task", ["title": "Mine"], as: me))
        #expect(try !rig.call("delete_task", ["id": own.uuidString, "confirm": true], as: me).isError)
    }

    @Test func fullControlReordersUpNextAcrossOwnersTasks() throws {
        let rig = try AgentRig()
        let me = rig.agent("codex", scopes: Self.full)
        let a = rig.store.createNoUndo(title: "A"), b = rig.store.createNoUndo(title: "B")
        rig.store.sendToOrdoNoUndo(a.id, top: true)
        let r = try rig.call("ordo_set", ["order": [b.id.uuidString, a.id.uuidString]], as: me)
        #expect(!r.isError)
        #expect(rig.store.task(b.id)?.isInOrdo == true)
    }

    @Test func aForeignWriteIsLoggedUnderTheAgentAndRevertedByRevertToday() throws {
        let rig = try AgentRig()
        let me = rig.agent("codex", scopes: Self.full)
        let t = rig.store.createNoUndo(title: "Original title")
        _ = try rig.call("update_task", ["id": t.id.uuidString, "title": "Agent title"], as: me)
        let logged = rig.hub.rows().filter { $0.actor == "agent:codex" && $0.verb == ActivityVerb.updated && $0.taskID == t.id }
        #expect(logged.count == 1, "the foreign write is in the activity log under the agent")
        #expect(rig.hub.writeCount(agentID: me.agentID, days: 7) >= 1)

        _ = try rig.call("complete_task", ["id": t.id.uuidString], as: me)
        let summary = rig.hub.revertToday(agentID: me.agentID, store: rig.store)
        #expect(summary.total >= 2)
        #expect(rig.store.task(t.id)?.title == "Original title" && rig.store.task(t.id)?.status == .todo)
    }

    // MARK: whoami

    @Test func whoamiNamesTheScopeOnlyForAgentsThatHoldIt() throws {
        let rig = try AgentRig()
        let full = rig.agent("full", scopes: Self.full)
        let plain = rig.agent("plain", scopes: .standard)
        #expect((try rig.call("whoami", [:], as: full).body["scopes"] as? [String])?.contains("write.all") == true)
        #expect((try rig.call("whoami", [:], as: plain).body["scopes"] as? [String])?.contains("write.all") == false)
    }

    @Test func scopesRoundTripThroughTheStoredCSV() {
        let s = AgentScopes([.read, .writeOwn, .writeAll])
        #expect(AgentScopes(csv: s.csv) == s)
        #expect(s.csv.contains("write.all"))
        #expect(!AgentScopes.standard.has(.writeAll) && !AgentScopes.legacy.has(.writeAll))
        #expect(AgentScopes(csv: "read,write.own").has(.writeAll) == false)
    }

    // MARK: structure

    @Test func structureToolsAreRefusedAndChangeNothingWithoutFullControl() throws {
        let rig = try AgentRig()
        let me = rig.agent("codex", scopes: .standard)
        let area = rig.store.createArea(name: "Home", colorHex: "#112233", icon: "house")
        let project = rig.store.createProject(name: "Garden", colorHex: "#445566", icon: nil, area: area)
        let calls: [(String, [String: Any])] = [
            ("create_label", ["name": "Errand"]),
            ("update_label", ["id": UUID().uuidString, "name": "Renamed"]),
            ("create_project", ["name": "New"]),
            ("update_project", ["id": project.id.uuidString, "name": "Hijacked"]),
            ("create_area", ["name": "New area"]),
            ("update_area", ["id": area.id.uuidString, "name": "Hijacked"]),
            ("delete_area", ["id": area.id.uuidString, "confirm": true]),
            ("move_task", ["id": rig.store.createNoUndo(title: "T").id.uuidString, "project": NSNull()]),
        ]
        for (tool, args) in calls {
            let r = try rig.call(tool, args, as: me)
            #expect(r.code == "FORBIDDEN", "\(tool)")
            #expect((r.body["data"] as? [String: Any])?["requiredScope"] as? String == "write.all", "\(tool)")
        }
        #expect(rig.store.allProjects().map(\.name) == ["Garden"] && rig.store.allAreas().map(\.name) == ["Home"])
        #expect(rig.store.labels().isEmpty)
    }

    @Test func projectsAndAreasAreCreatedChangedMovedAndArchived() throws {
        let rig = try AgentRig()
        let me = rig.agent("codex", scopes: Self.full)

        let area = try ids(try rig.call("create_area", ["name": "  Work  ", "colorHex": "ff8800", "icon": "briefcase"], as: me), "area")
        #expect(rig.store.allAreas().first?.name == "Work" && rig.store.allAreas().first?.colorHex == "#FF8800")

        let created = try rig.call("create_project", ["name": "Launch", "areaID": area.uuidString, "icon": "rocket", "emoji": "R"], as: me)
        let project = try ids(created, "project")
        let p = try #require(rig.store.allProjects().first { $0.id == project })
        #expect(p.name == "Launch" && p.area?.id == area && p.icon == "rocket" && p.emoji == "R")

        let renamed = try rig.call("update_project", ["id": project.uuidString, "name": "Launch v2", "colorHex": "#00FF00", "emoji": NSNull()], as: me)
        #expect(!renamed.isError)
        let q = try #require(rig.store.allProjects().first { $0.id == project })
        #expect(q.name == "Launch v2" && q.colorHex == "#00FF00" && q.emoji == nil && q.icon == "rocket")

        #expect(try !rig.call("update_project", ["id": project.uuidString, "areaID": NSNull()], as: me).isError)
        #expect(rig.store.allProjects().first { $0.id == project }?.area == nil)

        #expect(try !rig.call("update_project", ["id": project.uuidString, "archived": true], as: me).isError)
        #expect(rig.store.allProjects().contains { $0.id == project } == false, "archived projects leave the live list")
        #expect(rig.store.allProjects(includeArchived: true).first { $0.id == project }?.isArchived == true)
        #expect(try !rig.call("update_project", ["id": project.uuidString, "archived": false], as: me).isError)
        #expect(rig.store.allProjects().contains { $0.id == project })

        let renamedArea = try rig.call("update_area", ["id": area.uuidString, "name": "Office", "colorHex": "#102030"], as: me)
        #expect(!renamedArea.isError)
        #expect(rig.store.allAreas().first?.name == "Office" && rig.store.allAreas().first?.colorHex == "#102030")
    }

    @Test func anAreaThatHoldsProjectsIsNotDeletedAnEmptyOneIs() throws {
        let rig = try AgentRig()
        let me = rig.agent("codex", scopes: Self.full)
        let area = rig.store.createArea(name: "Home", colorHex: "#112233", icon: "house")
        _ = rig.store.createProject(name: "Garden", colorHex: "#445566", icon: nil, area: area)
        let refused = try rig.call("delete_area", ["id": area.id.uuidString, "confirm": true], as: me)
        #expect(refused.code == "INVALID_STATE")
        #expect(rig.store.allAreas().count == 1)
        #expect(try rig.call("delete_area", ["id": area.id.uuidString, "confirm": false], as: me).code == "INVALID_PARAMS")
        let empty = rig.store.createArea(name: "Empty", colorHex: "#112233", icon: "house")
        #expect(try !rig.call("delete_area", ["id": empty.id.uuidString, "confirm": true], as: me).isError)
        #expect(rig.store.allAreas().map(\.name) == ["Home"])
    }

    @Test func badStructureInputIsRefusedByName() throws {
        let rig = try AgentRig()
        let me = rig.agent("codex", scopes: Self.full)
        #expect(try rig.call("create_project", ["name": "   "], as: me).code == "INVALID_PARAMS")
        #expect(try rig.call("create_project", ["name": "X", "areaID": UUID().uuidString], as: me).code == "NOT_FOUND")
        #expect(try rig.call("create_area", ["name": "A", "colorHex": "red"], as: me).code == "INVALID_PARAMS")
        #expect(try rig.call("update_project", ["id": UUID().uuidString, "name": "x"], as: me).code == "NOT_FOUND")
        let p = rig.store.createProject(name: "P", colorHex: "#445566", icon: nil, area: nil)
        #expect(try rig.call("update_project", ["id": p.id.uuidString], as: me).code == "INVALID_PARAMS", "nothing to change")
        #expect(try rig.call("update_area", ["id": UUID().uuidString, "name": "x"], as: me).code == "NOT_FOUND")
        #expect(rig.store.allProjects().count == 1 && rig.store.allAreas().isEmpty)
    }

    @Test func labelsAreListedCreatedOnceRenamedAndRecolouredNeverDuplicated() throws {
        let rig = try AgentRig()
        let me = rig.agent("codex", scopes: Self.full)
        let t = rig.store.createNoUndo(title: "Tagged")
        let existing = rig.store.label(named: "Errand")
        rig.store.addLabel(existing, to: t.id)

        let listed = try rig.call("list_labels", [:], as: me)
        let labels = try #require(listed.body["labels"] as? [[String: Any]])
        #expect(labels.count == 1 && labels[0]["name"] as? String == "Errand" && labels[0]["openTaskCount"] as? Int == 1)

        let again = try rig.call("create_label", ["name": "errand"], as: me)
        #expect(again.body["created"] as? Bool == false && rig.store.labels().count == 1, "same name ignoring case")
        let made = try rig.call("create_label", ["name": "Phone", "colorHex": "#aa00bb"], as: me)
        #expect(made.body["created"] as? Bool == true)
        let phone = try ids(made, "label")
        #expect(rig.store.labels().first { $0.id == phone }?.colorHex == "#AA00BB")

        #expect(try !rig.call("update_label", ["id": phone.uuidString, "name": "Call", "colorHex": "#010203"], as: me).isError)
        #expect(rig.store.labels().first { $0.id == phone }?.name == "Call" && rig.store.labels().first { $0.id == phone }?.colorHex == "#010203")
        #expect(try rig.call("update_label", ["id": phone.uuidString, "name": "ERRAND"], as: me).code == "CONFLICT")
        #expect(try rig.call("update_label", ["id": UUID().uuidString, "name": "x"], as: me).code == "NOT_FOUND")
    }

    @Test func aReadAgentMayListLabelsButNotChangeThem() throws {
        let rig = try AgentRig()
        let me = rig.agent("reader", scopes: AgentScopes([.read]))
        #expect(try !rig.call("list_labels", [:], as: me).isError)
        #expect(try rig.call("create_label", ["name": "x"], as: me).code == "FORBIDDEN")
    }

    @Test func structureWritesAreLoggedAndDoNotTouchTheOwnersUndoHistory() throws {
        let rig = try AgentRig()
        let me = rig.agent("codex", scopes: Self.full)
        let t = rig.store.createNoUndo(title: "Owner's own edit")
        rig.store.setPriority(t.id, .high)                   // the person's last action, undoable
        let area = try ids(try rig.call("create_area", ["name": "Work"], as: me), "area")
        _ = try rig.call("create_project", ["name": "Launch", "areaID": area.uuidString], as: me)
        _ = try rig.call("create_label", ["name": "Errand"], as: me)
        let logged = rig.hub.rows().filter { $0.actor == "agent:codex" && $0.verb == ActivityVerb.structure }
        #expect(logged.count == 3)
        #expect(logged.allSatisfy { AgentHub.payload($0)["tool"]?.string != nil })
        rig.store.undo()
        #expect(rig.store.task(t.id)?.priority == KPriority.none, "Cmd-Z undoes the owner's edit, not the agent's structure")
        #expect(rig.store.allAreas().count == 1 && rig.store.allProjects().count == 1 && rig.store.labels().count == 1)
    }

    // MARK: move_task

    @Test func moveTaskFilesNestsPromotesAndReordersAnyTask() throws {
        let rig = try AgentRig()
        let me = rig.agent("codex", scopes: Self.full)
        let project = rig.store.createProject(name: "Garden", colorHex: "#445566", icon: nil, area: nil)
        let a = rig.store.createNoUndo(title: "A"), b = rig.store.createNoUndo(title: "B")

        #expect(try !rig.call("move_task", ["id": a.id.uuidString, "project": "Garden"], as: me).isError)
        #expect(rig.store.task(a.id)?.projectID == project.id)
        #expect(try !rig.call("move_task", ["id": a.id.uuidString, "project": NSNull()], as: me).isError)
        #expect(rig.store.task(a.id)?.projectID == nil)

        #expect(try !rig.call("move_task", ["id": b.id.uuidString, "parentID": a.id.uuidString], as: me).isError)
        #expect(rig.store.task(b.id)?.parentID == a.id)
        let c = try #require(rig.store.addSubtaskNoUndo(a.id, title: "C"))
        #expect(rig.store.task(a.id)?.orderedChildren.map(\.title) == ["B", "C"])
        #expect(try !rig.call("move_task", ["id": c.id.uuidString, "before": b.id.uuidString], as: me).isError)
        #expect(rig.store.task(a.id)?.orderedChildren.map(\.title) == ["C", "B"])

        #expect(try !rig.call("move_task", ["id": b.id.uuidString, "parentID": NSNull()], as: me).isError)
        #expect(rig.store.task(b.id)?.parentID == nil)
    }

    @Test func moveTaskRefusesWhatCannotBeDone() throws {
        let rig = try AgentRig()
        let me = rig.agent("codex", scopes: Self.full)
        let a = rig.store.createNoUndo(title: "A"), b = rig.store.createNoUndo(title: "B")
        #expect(try rig.call("move_task", ["id": a.id.uuidString], as: me).code == "INVALID_PARAMS")
        #expect(try rig.call("move_task", ["id": a.id.uuidString, "before": b.id.uuidString], as: me).code == "INVALID_PARAMS", "top-level has no siblings to order")
        #expect(try rig.call("move_task", ["id": a.id.uuidString, "parentID": a.id.uuidString], as: me).code == "INVALID_PARAMS")
        #expect(try rig.call("move_task", ["id": a.id.uuidString, "project": "Nowhere"], as: me).code == "NOT_FOUND")
        #expect(try rig.call("move_task", ["id": UUID().uuidString, "project": NSNull()], as: me).code == "NOT_FOUND")
        #expect(try rig.call("move_task", ["id": a.id.uuidString, "parentID": b.id.uuidString, "project": NSNull()], as: me).code == "INVALID_PARAMS")
        #expect(rig.store.task(a.id)?.parentID == nil)
    }

    @Test func theOwnersProcessWithoutAnIdentityMayCallEveryNewTool() throws {
        let rig = try AgentRig()
        let area = try ids(try rig.call("create_area", ["name": "Work"]), "area")
        let project = try ids(try rig.call("create_project", ["name": "Launch", "areaID": area.uuidString]), "project")
        #expect(try !rig.call("update_project", ["id": project.uuidString, "name": "Launch 2"]).isError)
        #expect(try !rig.call("list_labels").isError)
    }
}
#endif

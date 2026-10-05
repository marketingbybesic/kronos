#if os(macOS)
import Testing
import Foundation
@testable import KronosCore

/// Every tool crossed with every scope set. `true` = the scope check lets the call through (the
/// tool may still answer with its own error); `false` = FORBIDDEN. The table is written by hand.
/// Columns: none, read, standard, trusted, legacy, full (standard plus write.all).
@MainActor
@Suite struct MCPScopeTests {

    struct Ctx {
        let mine: UUID, foreign: UUID, mineChild: UUID, foreignChild: UUID, mineDeleted: UUID
        let agentRule: UUID, ownerRule: UUID
    }

    static let sets: [(name: String, scopes: AgentScopes)] = [
        ("none", AgentScopes([])),
        ("read", AgentScopes([.read])),
        ("standard", .standard),
        ("trusted", AgentScopes([.read, .propose, .writeOwn, .comment, .writeTrusted])),
        ("legacy", .legacy),
        ("full", AgentScopes([.read, .propose, .writeOwn, .comment, .writeAll])),
    ]

    private func make(_ scopes: AgentScopes) throws -> (AgentRig, AgentIdentity, Ctx) {
        let rig = try AgentRig()
        let me = rig.agent("codex", scopes: scopes)
        let mine = rig.store.createNoUndo(title: "Agent's task")
        rig.store.updateNoUndo(mine.id) { $0.agentID = me.agentID }
        let mineChild = rig.store.addSubtaskNoUndo(mine.id, title: "Agent step")!
        let foreign = rig.store.createNoUndo(title: "Owner's task")
        let foreignChild = rig.store.addSubtaskNoUndo(foreign.id, title: "Owner step")!
        let gone = rig.store.createNoUndo(title: "Deleted agent task")
        rig.store.updateNoUndo(gone.id) { $0.agentID = me.agentID }
        rig.store.softDeleteNoUndo(gone.id)
        let agentRule = rig.store.addRule(text: "Agent proposed rule", scope: .all, source: .manual)
        agentRule.sourceRaw = KRule.agentSourceRaw
        let ownerRule = rig.store.addRule(text: "Owner's own rule", scope: .all, source: .manual)
        return (rig, me, Ctx(mine: mine.id, foreign: foreign.id, mineChild: mineChild.id, foreignChild: foreignChild.id,
                             mineDeleted: gone.id, agentRule: agentRule.id, ownerRule: ownerRule.id))
    }

    struct Case {
        let label: String
        let tool: String
        let args: (Ctx) -> [String: Any]
        /// allowed per set: none, read, standard, trusted, legacy, full
        let allowed: [Bool]
    }

    static let cases: [Case] = [
        Case(label: "list_tasks", tool: "list_tasks", args: { _ in ["view": "all"] }, allowed: [false, true, true, true, true, true]),
        Case(label: "get_task foreign", tool: "get_task", args: { ["id": $0.foreign.uuidString] }, allowed: [false, true, true, true, true, true]),
        Case(label: "ordo_get", tool: "ordo_get", args: { _ in [:] }, allowed: [false, true, true, true, true, true]),
        Case(label: "upnext_get", tool: "upnext_get", args: { _ in [:] }, allowed: [false, true, true, true, true, true]),
        Case(label: "rules_list", tool: "rules_list", args: { _ in [:] }, allowed: [false, true, true, true, true, true]),
        Case(label: "list_projects", tool: "list_projects", args: { _ in [:] }, allowed: [false, true, true, true, true, true]),
        Case(label: "list_areas", tool: "list_areas", args: { _ in [:] }, allowed: [false, true, true, true, true, true]),
        Case(label: "whoami", tool: "whoami", args: { _ in [:] }, allowed: [false, true, true, true, true, true]),
        Case(label: "next", tool: "next", args: { _ in [:] }, allowed: [false, true, true, true, true, true]),
        Case(label: "events_poll", tool: "events_poll", args: { _ in [:] }, allowed: [false, true, true, true, true, true]),
        Case(label: "events_ack", tool: "events_ack", args: { _ in ["upTo": "0"] }, allowed: [false, true, true, true, true, true]),
        Case(label: "create_task", tool: "create_task", args: { _ in ["title": "New"] }, allowed: [false, false, true, true, true, true]),
        Case(label: "propose_tasks", tool: "propose_tasks", args: { _ in ["title": "P", "tasks": [["title": "x"]]] }, allowed: [false, false, true, true, true, true]),
        Case(label: "propose_update foreign", tool: "propose_update", args: { ["id": $0.foreign.uuidString, "patch": ["priority": "high"]] }, allowed: [false, false, true, true, true, true]),
        Case(label: "comment_task foreign", tool: "comment_task", args: { ["id": $0.foreign.uuidString, "text": "hello"] }, allowed: [false, false, true, true, false, true]),
        Case(label: "update_task mine", tool: "update_task", args: { ["id": $0.mine.uuidString, "title": "Changed"] }, allowed: [false, false, true, true, false, true]),
        Case(label: "update_task foreign", tool: "update_task", args: { ["id": $0.foreign.uuidString, "title": "Changed"] }, allowed: [false, false, false, false, false, true]),
        Case(label: "update_task foreign notes", tool: "update_task", args: { ["id": $0.foreign.uuidString, "notes": "overwritten"] }, allowed: [false, false, false, false, false, true]),
        Case(label: "complete_task mine", tool: "complete_task", args: { ["id": $0.mine.uuidString] }, allowed: [false, false, true, true, false, true]),
        Case(label: "complete_task foreign", tool: "complete_task", args: { ["id": $0.foreign.uuidString] }, allowed: [false, false, false, false, false, true]),
        Case(label: "delete_task mine", tool: "delete_task", args: { ["id": $0.mine.uuidString, "confirm": true] }, allowed: [false, false, true, true, false, true]),
        Case(label: "delete_task foreign", tool: "delete_task", args: { ["id": $0.foreign.uuidString, "confirm": true] }, allowed: [false, false, false, false, false, false]),
        Case(label: "restore_task mine", tool: "restore_task", args: { ["id": $0.mineDeleted.uuidString] }, allowed: [false, false, true, true, false, true]),
        Case(label: "restore_task foreign-deleted", tool: "restore_task", args: { _ in ["id": UUID().uuidString] }, allowed: [false, false, true, true, false, true]),
        Case(label: "add_subtask mine", tool: "add_subtask", args: { ["taskID": $0.mine.uuidString, "title": "s"] }, allowed: [false, false, true, true, false, true]),
        Case(label: "add_subtask foreign", tool: "add_subtask", args: { ["taskID": $0.foreign.uuidString, "title": "s"] }, allowed: [false, false, false, false, false, true]),
        Case(label: "toggle_subtask mine", tool: "toggle_subtask", args: { ["id": $0.mineChild.uuidString] }, allowed: [false, false, true, true, false, true]),
        Case(label: "toggle_subtask foreign", tool: "toggle_subtask", args: { ["id": $0.foreignChild.uuidString] }, allowed: [false, false, false, false, false, true]),
        Case(label: "ordo_set top mine", tool: "ordo_set", args: { ["top": $0.mine.uuidString] }, allowed: [false, false, true, true, false, true]),
        Case(label: "ordo_set top foreign", tool: "ordo_set", args: { ["top": $0.foreign.uuidString] }, allowed: [false, false, false, false, false, true]),
        Case(label: "upnext_set top mine", tool: "upnext_set", args: { ["top": $0.mine.uuidString] }, allowed: [false, false, true, true, false, true]),
        Case(label: "upnext_set top foreign", tool: "upnext_set", args: { ["top": $0.foreign.uuidString] }, allowed: [false, false, false, false, false, true]),
        Case(label: "rules_add", tool: "rules_add", args: { _ in ["text": "Never schedule on Sundays"] }, allowed: [false, false, true, true, true, true]),
        Case(label: "rules_delete agent rule", tool: "rules_delete", args: { ["id": $0.agentRule.uuidString] }, allowed: [false, false, true, true, false, true]),
        Case(label: "rules_delete owner rule", tool: "rules_delete", args: { ["id": $0.ownerRule.uuidString] }, allowed: [false, false, false, false, false, false]),
        Case(label: "list_labels", tool: "list_labels", args: { _ in [:] }, allowed: [false, true, true, true, true, true]),
        Case(label: "create_label", tool: "create_label", args: { _ in ["name": "Errand"] }, allowed: [false, false, false, false, false, true]),
        Case(label: "update_label", tool: "update_label", args: { _ in ["id": UUID().uuidString, "name": "Renamed"] }, allowed: [false, false, false, false, false, true]),
        Case(label: "create_project", tool: "create_project", args: { _ in ["name": "New project"] }, allowed: [false, false, false, false, false, true]),
        Case(label: "update_project", tool: "update_project", args: { _ in ["id": UUID().uuidString, "name": "Renamed"] }, allowed: [false, false, false, false, false, true]),
        Case(label: "create_area", tool: "create_area", args: { _ in ["name": "New area"] }, allowed: [false, false, false, false, false, true]),
        Case(label: "update_area", tool: "update_area", args: { _ in ["id": UUID().uuidString, "name": "Renamed"] }, allowed: [false, false, false, false, false, true]),
        Case(label: "delete_area", tool: "delete_area", args: { _ in ["id": UUID().uuidString, "confirm": true] }, allowed: [false, false, false, false, false, true]),
        Case(label: "move_task foreign", tool: "move_task", args: { ["id": $0.foreign.uuidString, "project": NSNull()] }, allowed: [false, false, false, false, false, true]),
    ]

    @Test func everyToolAgainstEverySetAnswersAsTheTableSays() throws {
        for c in Self.cases {
            #expect(c.allowed.count == Self.sets.count, "\(c.label) table row is short")
            for (i, set) in Self.sets.enumerated() {
                let (rig, me, ctx) = try make(set.scopes)
                let r = try rig.call(c.tool, c.args(ctx), as: me)
                let forbidden = r.isError && r.code == "FORBIDDEN"
                #expect(forbidden == !c.allowed[i], "\(c.label) as \(set.name): FORBIDDEN=\(forbidden) \(r.message)")
            }
        }
    }

    @Test func theTableCoversEveryToolIncludingBothAliases() {
        let covered = Set(Self.cases.map(\.tool))
        let missing = Set(MCPTool.allCases.map(\.name)).subtracting(covered).sorted()
        // Not in the table: the two tools the table exercises under another row's name do not exist; everything is listed.
        #expect(missing == [], "tools without a scope row: \(missing)")
    }

    @Test func aRefusalNamesTheMissingScopeOrTheProposeUpdateHint() throws {
        let (rig, me, ctx) = try make(.standard)
        let del = try rig.call("delete_task", ["id": ctx.foreign.uuidString, "confirm": true], as: me)
        #expect(del.code == "FORBIDDEN")
        #expect((del.body["data"] as? [String: Any])?["hint"] as? String == "use propose_update")
        #expect((del.body["data"] as? [String: Any])?["requiredScope"] as? String == "write.own")
        let (rig2, ro, _) = try make(AgentScopes([.read]))
        let create = try rig2.call("create_task", ["title": "x"], as: ro)
        #expect((create.body["data"] as? [String: Any])?["requiredScope"] as? String == "propose")
    }

    @Test func aForbiddenCallChangesNothing() throws {
        let (rig, me, ctx) = try make(.standard)
        let before = rig.store.task(ctx.foreign)?.title
        _ = try rig.call("update_task", ["id": ctx.foreign.uuidString, "title": "Hijacked", "notes": "overwritten"], as: me)
        _ = try rig.call("delete_task", ["id": ctx.foreign.uuidString, "confirm": true], as: me)
        _ = try rig.call("ordo_set", ["top": ctx.foreign.uuidString], as: me)
        #expect(rig.store.task(ctx.foreign)?.title == before && rig.store.task(ctx.foreign)?.notes == "")
        #expect(rig.store.task(ctx.foreign)?.isInOrdo == false)
        #expect(rig.hub.rows().filter { $0.actor == me.actor && $0.verb != ActivityVerb.created }.isEmpty, "no write was logged")
    }

    @Test func reorderingTheWholeQueueIsForbiddenWhileItHoldsATaskThatIsNotTheAgents() throws {
        let (rig, me, ctx) = try make(.standard)
        rig.store.sendToOrdoNoUndo(ctx.foreign, top: true)
        let r = try rig.call("ordo_set", ["order": [ctx.mine.uuidString]], as: me)
        #expect(r.code == "FORBIDDEN", "order would drop the owner's queued task")
        #expect(rig.store.task(ctx.foreign)?.isInOrdo == true)
    }

    @Test func anOwnTaskCanBeReorderedWhenTheQueueHoldsOnlyOwnTasks() throws {
        let (rig, me, ctx) = try make(.standard)
        let r = try rig.call("ordo_set", ["top": ctx.mine.uuidString], as: me)
        #expect(!r.isError)
        #expect(rig.store.task(ctx.mine)?.isInOrdo == true)
    }

    @Test func aStepOfAnOwnTaskIsOwned() throws {
        let (rig, me, ctx) = try make(.standard)
        #expect(try !rig.call("update_task", ["id": ctx.mineChild.uuidString, "title": "Renamed step"], as: me).isError)
    }

    @Test func noIdentityMeansTheOwnerAndNothingIsRefused() throws {
        let rig = try AgentRig()
        let t = rig.store.createNoUndo(title: "Owner task")
        #expect(try !rig.call("update_task", ["id": t.id.uuidString, "title": "Edited by the owner's process"]).isError)
        #expect(try !rig.call("delete_task", ["id": t.id.uuidString, "confirm": true]).isError)
    }

    // D9-scopes: aliases are judged exactly like their targets.

    @Test func upnextSetIsForbiddenLikeOrdoSet() throws {
        for set in Self.sets where !set.scopes.has(.writeAll) {
            let (rig, me, ctx) = try make(set.scopes)
            let viaAlias = try rig.call("upnext_set", ["top": ctx.foreign.uuidString], as: me)
            let (rig2, me2, ctx2) = try make(set.scopes)
            let viaTarget = try rig2.call("ordo_set", ["top": ctx2.foreign.uuidString], as: me2)
            #expect(viaAlias.code == viaTarget.code, "\(set.name)")
            #expect(viaAlias.code == "FORBIDDEN", "\(set.name): a foreign task can never be reordered")
        }
    }

    @Test func upnextGetNeedsReadLikeOrdoGet() throws {
        for set in Self.sets {
            let (rig, me, _) = try make(set.scopes)
            let a = try rig.call("upnext_get", [:], as: me)
            let (rig2, me2, _) = try make(set.scopes)
            let b = try rig2.call("ordo_get", [:], as: me2)
            #expect(a.code == b.code, "\(set.name)")
            #expect((a.code == "FORBIDDEN") == !set.scopes.has(.read), "\(set.name)")
        }
    }

    @Test func aliasesAnswerIdenticallyToTargetsForEveryScopeSet() throws {
        for set in Self.sets {
            for (alias, target, args) in [("upnext_get", "ordo_get", [String: Any]()), ("upnext_set", "ordo_set", ["order": [String]()])] as [(String, String, [String: Any])] {
                let (r1, m1, _) = try make(set.scopes)
                let (r2, m2, _) = try make(set.scopes)
                let a = try r1.call(alias, args, as: m1), b = try r2.call(target, args, as: m2)
                #expect(a.code == b.code && a.isError == b.isError, "\(alias) vs \(target) as \(set.name)")
            }
        }
    }
}

#endif

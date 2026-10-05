#if os(macOS)
import Testing
import Foundation
@testable import KronosCore

/// Fields an MCP client writes explicitly are locked against triage; triage:false locks them all.
@MainActor
@Suite struct MCPLockedFieldsTests {

    private func make() throws -> (TaskStore, MCPDispatcher) {
        let store = try TaskStore(inMemory: true)
        return (store, MCPDispatcher(store: store, ranking: RankingEngine()))
    }

    private func call(_ d: MCPDispatcher, _ tool: String, _ args: [String: Any]) throws -> [String: Any] {
        let params = try JSONSerialization.data(withJSONObject: ["name": tool, "arguments": args])
        let response = try #require(d.handle(MCPRequest(id: .number(1), method: "tools/call", paramsData: params)))
        let res = try #require(try? JSONSerialization.jsonObject(with: response.result ?? Data()) as? [String: Any])
        return res["structuredContent"] as? [String: Any] ?? [:]
    }

    private func newID(_ content: [String: Any]) throws -> UUID {
        let task = try #require(content["task"] as? [String: Any])
        let raw = try #require(task["id"] as? String)
        return try #require(UUID(uuidString: raw))
    }

    private let triageSuggestsHigh = TriageResult(project: nil, priority: 3, due: nil, depth: .deep, estimateMinutes: 30,
                                                  energyKind: .creative, firstMove: "Open the file", labels: [], rationale: "r")

    @Test func explicitPriorityNoneOnCreateLocksPriority() throws {
        let (store, d) = try make()
        let id = try newID(call(d, "create_task", ["title": "Pay rent", "priority": "none", "triage": true]))
        #expect(store.lockedFields(of: id) == [.priority])
        store.applyTriage(triageSuggestsHigh, to: id)
        #expect(store.task(id)?.priority == KPriority.none, "triage must not overwrite an explicit none")
        #expect(store.task(id)?.firstMove == "Open the file", "unlocked fields are still filled")
    }

    @Test func noExplicitPriorityLeavesItOpenPositiveControl() throws {
        let (store, d) = try make()
        let id = try newID(call(d, "create_task", ["title": "Pay rent", "triage": true]))
        #expect(store.lockedFields(of: id).isEmpty)
        store.applyTriage(triageSuggestsHigh, to: id)
        #expect(store.task(id)?.priority == KPriority.high)
    }

    @Test func explicitPriorityNoneOnUpdateLocksPriority() throws {
        let (store, d) = try make()
        let t = store.createNoUndo(title: "T", priority: .high)
        _ = try call(d, "update_task", ["id": t.id.uuidString, "priority": "none"])
        #expect(store.task(t.id)?.priority == KPriority.none)
        #expect(store.lockedFields(of: t.id) == [.priority])
        store.applyTriage(triageSuggestsHigh, to: t.id)
        #expect(store.task(t.id)?.priority == KPriority.none)
    }

    @Test func updateWithoutPriorityLocksNothing() throws {
        let (store, d) = try make()
        let t = store.createNoUndo(title: "T")
        _ = try call(d, "update_task", ["id": t.id.uuidString, "title": "Renamed"])
        #expect(store.lockedFields(of: t.id).isEmpty)
    }

    @Test func triageFalseLocksEveryFieldSoTriageFillsNothing() throws {
        for args in [["title": "Buy milk"] as [String: Any], ["title": "Buy milk", "triage": false]] {
            let (store, d) = try make()
            let id = try newID(call(d, "create_task", args))
            #expect(store.lockedFields(of: id) == Set(TriageFieldKind.allCases))
            let depth = store.undoDepth
            let filled = store.applyTriage(triageSuggestsHigh, to: id)
            #expect(filled.isEmpty, "0 fields filled, got \(filled)")
            #expect(store.task(id)?.priority == KPriority.none)
            #expect(store.task(id)?.firstMove == nil)
            _ = depth
        }
    }

    @Test func explicitFieldsWithTriageTrueLockOnlyThoseFields() throws {
        let (store, d) = try make()
        let id = try newID(call(d, "create_task", ["title": "X", "triage": true, "priority": "low", "firstMove": "Start"]))
        #expect(store.lockedFields(of: id) == [.priority, .firstMove])
    }
}

#endif

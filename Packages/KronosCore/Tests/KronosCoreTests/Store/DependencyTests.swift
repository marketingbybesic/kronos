import Testing
import Foundation
@testable import KronosCore

/// w22e: "Waits on". Blocked is derived (a waited-on task is open), never stored, and a blocked
/// task keeps its status but is skipped by every "next task" chooser.
@MainActor
struct DependencyTests {

    private func makeStore() throws -> TaskStore { try TaskStore(inMemory: true) }

    @Test func attributeHasADefaultSoOldStoresOpen() throws {
        // Lightweight migration needs a default on the attribute; a fresh task carries "".
        let store = try makeStore()
        let t = store.create(title: "x")
        #expect(t.waitsOnIDs == "")
        #expect(t.waitsOn.isEmpty)
        #expect(!store.isBlocked(t.id))
    }

    @Test func blockedWhileBlockerOpenThenUnblockedOnComplete() throws {
        let store = try makeStore()
        let a = store.create(title: "design")
        let b = store.create(title: "build")
        #expect(store.setWaitsOn(b.id, [a.id]))
        #expect(store.isBlocked(b.id))
        #expect(!store.isBlocked(a.id))
        #expect(b.status == .todo, "a blocked task keeps its status")
        store.complete(a.id)
        #expect(!store.isBlocked(b.id), "completing the blocker unblocks with nothing stored")
    }

    @Test func canceledOrDeletedBlockerDoesNotBlockForever() throws {
        let store = try makeStore()
        let a = store.create(title: "a")
        let c = store.create(title: "c")
        let b = store.create(title: "b")
        store.setWaitsOn(b.id, [a.id, c.id])
        #expect(store.isBlocked(b.id))
        store.setStatus(a.id, .canceled)
        #expect(store.isBlocked(b.id), "c is still open")
        store.softDelete(c.id)
        #expect(!store.isBlocked(b.id), "canceled and deleted blockers cannot be completed")
    }

    @Test func cycleIsRefusedAndDropped() throws {
        let store = try makeStore()
        let a = store.create(title: "a")
        let b = store.create(title: "b")
        let c = store.create(title: "c")
        #expect(store.setWaitsOn(b.id, [a.id]))
        #expect(store.setWaitsOn(c.id, [b.id]))
        // a -> c would close a -> c -> b -> a
        #expect(store.setWaitsOn(a.id, [c.id]) == false)
        #expect(a.waitsOn.isEmpty)
        #expect(store.wouldCreateCycle(a.id, waitingOn: c.id))
        #expect(store.wouldCreateCycle(a.id, waitingOn: a.id), "self is a cycle")
        #expect(!store.wouldCreateCycle(c.id, waitingOn: a.id), "c already reaches a: a second path is fine")
        // A mixed request keeps the legal ids and drops the illegal one.
        let d = store.create(title: "d")
        #expect(store.setWaitsOn(a.id, [d.id, c.id]) == false)
        #expect(a.waitsOn == [d.id])
    }

    @Test func unknownDuplicateAndSelfIdsAreDropped() throws {
        let store = try makeStore()
        let a = store.create(title: "a")
        let b = store.create(title: "b")
        #expect(store.setWaitsOn(b.id, [a.id, a.id, UUID(), b.id]) == false)
        #expect(b.waitsOn == [a.id])
        #expect(store.setWaitsOn(b.id, []))
        #expect(b.waitsOnIDs == "")
    }

    @Test func setWaitsOnIsUndoable() throws {
        let store = try makeStore()
        let a = store.create(title: "a")
        let b = store.create(title: "b")
        store.setWaitsOn(b.id, [a.id])
        #expect(store.isBlocked(b.id))
        store.undo()
        #expect(!store.isBlocked(b.id))
        #expect(b.waitsOnIDs == "")
    }

    @Test func noUndoVariantLeavesTheStackAlone() throws {
        let store = try makeStore()
        let a = store.create(title: "a")
        let b = store.create(title: "b")
        let depth = store.undoStack.count
        store.setWaitsOnNoUndo(b.id, [a.id])
        #expect(store.undoStack.count == depth)
        #expect(store.isBlocked(b.id))
    }

    @Test func rankingSkipsBlockedAtEveryEnergy() throws {
        let store = try makeStore()
        let blocker = store.create(title: "blocker")
        store.update(blocker.id) { $0.priorityRaw = KPriority.low.rawValue; $0.depthRaw = KDepth.shallow.rawValue; $0.estimateMinutes = 5 }
        let blocked = store.create(title: "blocked")
        store.update(blocked.id) { $0.priorityRaw = KPriority.urgent.rawValue; $0.depthRaw = KDepth.shallow.rawValue; $0.estimateMinutes = 5 }
        store.setWaitsOn(blocked.id, [blocker.id])
        for energy in [KEnergyLevel.low, .mid, .high] {
            let c = RankingEngine().candidates(energy: energy, count: 5, maxDeep: true,
                                               today: Day.today(), tasks: store.allTasks())
            #expect(c.map(\.taskID) == [blocker.id], "energy \(energy)")
        }
        store.complete(blocker.id)
        let after = RankingEngine().candidates(energy: .mid, count: 5, maxDeep: true,
                                               today: Day.today(), tasks: store.allTasks())
        #expect(after.map(\.taskID) == [blocked.id])
    }

    @Test func ordoCurrentSkipsBlockedButKeepsItsPlace() throws {
        let store = try makeStore()
        let blocker = store.create(title: "blocker")
        let blocked = store.create(title: "blocked")
        store.sendToOrdo(blocked.id, top: false)
        store.sendToOrdo(blocker.id, top: false)
        store.setWaitsOn(blocked.id, [blocker.id])
        let ordo = OrdoEngine(store: store)
        #expect(ordo.queue.first?.id == blocked.id, "queue order untouched")
        #expect(ordo.current?.id == blocker.id)
        store.complete(blocker.id)
        #expect(ordo.current?.id == blocked.id)
    }

    @Test func exportImportRoundTripKeepsWaitsOn() throws {
        let store = try makeStore()
        let a = store.create(title: "a")
        let b = store.create(title: "b")
        store.setWaitsOn(b.id, [a.id])
        let data = JSONExporter(store: store).exportData(now: Date(timeIntervalSince1970: 0))
        // A task with no dependencies must not grow a key (older builds, byte-identical backups).
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.components(separatedBy: "\"waitsOn\"").count == 2, "exactly one task carries the key")

        let fresh = try makeStore()
        _ = try KronosImporter(store: fresh).importData(data, mode: .replace)
        let b2 = try #require(fresh.task(b.id))
        #expect(b2.waitsOn == [a.id])
        #expect(fresh.isBlocked(b.id))
        #expect(fresh.task(a.id)?.waitsOn.isEmpty == true)
    }

    @Test func oldExportWithoutTheKeyStillImports() throws {
        let store = try makeStore()
        _ = store.create(title: "a")
        let data = JSONExporter(store: store).exportData()
        #expect(!String(decoding: data, as: UTF8.self).contains("waitsOn"))
        let fresh = try makeStore()
        _ = try KronosImporter(store: fresh).importData(data, mode: .replace)
        #expect(fresh.allTasks().first?.waitsOnIDs == "")
    }

    @Test func seedCodecCarriesWaitsOn() throws {
        let store = try makeStore()
        let a = UUID(), b = UUID()
        let seed = SeedFile(tasks: [SeedTask(id: a, title: "a"), SeedTask(id: b, title: "b", waitsOn: [a])])
        let data = try JSONEncoder().encode(seed)
        _ = try JSONImporter(store: store).importJSON(data)
        // The importer mints its own row ids, so assert the field arrives verbatim.
        let imported = try #require(store.allTasks().first { $0.title == "b" })
        #expect(imported.waitsOn == [a])
    }

    @Test func mcpUpdateTaskSetsWaitsOnAndListShowsBlocked() throws {
        let store = try makeStore()
        let d = MCPDispatcher(store: store, ranking: RankingEngine())
        let a = store.createNoUndo(title: "a")
        let b = store.createNoUndo(title: "b")

        func call(_ tool: String, _ args: [String: Any]) -> [String: Any] {
            let env: [String: Any] = ["name": tool, "arguments": args]
            let req = MCPRequest(id: .number(1), method: "tools/call",
                                 paramsData: (try? JSONSerialization.data(withJSONObject: env)) ?? Data())
            let resp = d.handle(req)!
            let obj = (try? JSONSerialization.jsonObject(with: resp.result!)) as? [String: Any] ?? [:]
            return obj["structuredContent"] as? [String: Any] ?? [:]
        }

        let upd = call("update_task", ["id": b.id.uuidString, "waitsOn": [a.id.uuidString]])
        let task = upd["task"] as? [String: Any]
        #expect(task?["blocked"] as? Bool == true)
        #expect((task?["waitsOn"] as? [String]) == [a.id.uuidString])

        let list = call("list_tasks", ["view": "inbox"])
        let rows = list["tasks"] as? [[String: Any]] ?? []
        let rowB = rows.first { ($0["id"] as? String) == b.id.uuidString }
        let rowA = rows.first { ($0["id"] as? String) == a.id.uuidString }
        #expect(rowB?["blocked"] as? Bool == true)
        #expect(rowA?["blocked"] == nil, "key absent unless blocked")

        // a cycle over MCP is dropped and reported, not stored
        let cyc = call("update_task", ["id": a.id.uuidString, "waitsOn": [b.id.uuidString]])
        #expect((cyc["sideEffects"] as? [String])?.contains("waitsOnDropped") == true)
        #expect(store.task(a.id)?.waitsOn.isEmpty == true)

        _ = call("complete_task", ["id": a.id.uuidString])
        let after = call("get_task", ["id": b.id.uuidString])
        #expect((after["task"] as? [String: Any])?["blocked"] == nil)
    }
}

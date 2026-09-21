import Testing
import Foundation
@testable import KronosCore

@MainActor
struct StoreTests {
    @Test func importIsIdempotentOnExternalID() throws {
        let store = try TaskStore(inMemory: true)
        let importer = JSONImporter(store: store)
        var file = SeedFile()
        file.areas = [SeedArea(name: "MBB", colorHex: "#8224E3", icon: "briefcase", sortIndex: 0)]
        file.projects = [SeedProject(name: "Acme", areaName: "MBB", colorHex: "#3FB950", icon: "leaf", sortIndex: 0)]
        file.tasks = [SeedTask(id: UUID(), externalID: "MAR-12", source: "linear",
                                title: "Nazvati Karla", firstMove: "Otvoriti imenik",
                                priority: 3, status: 0, dueDate: Day.iso(Day.today() + 1))]

        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(file)

        let r1 = try importer.importJSON(data)
        #expect(r1.tasks == 1)
        #expect(r1.areas == 1)
        #expect(r1.projects == 1)

        let r2 = try importer.importJSON(data)
        #expect(r2.tasks == 0)
        #expect(r2.duplicates == 1)
        #expect(store.allTasks().count == 1)
    }

    @Test func versionRefusal() throws {
        let store = try TaskStore(inMemory: true)
        let importer = JSONImporter(store: store)
        var file = SeedFile(); file.version = 2
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        #expect(throws: StoreError.self) {
            _ = try importer.importJSON(try enc.encode(file))
        }
    }

    @Test func completeAndUndo() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.create(title: "Write tests")
        store.complete(t.id)
        #expect(store.task(t.id)!.status == .done)
        store.undo()
        #expect(store.task(t.id)!.status == .todo)
    }

    @Test func softDeleteExcludedAndRestorable() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.create(title: "Temp")
        store.softDelete(t.id)
        #expect(store.allTasks().isEmpty)
        #expect(store.allTasksIncludingDeleted().count == 1)
        store.restore(t.id)
        #expect(store.allTasks().count == 1)
    }

    @Test func waitingLeavesOrdo() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.create(title: "Blocked")
        store.sendToOrdo(t.id)
        #expect(store.task(t.id)!.isInOrdo)
        store.setStatus(t.id, .waiting)
        #expect(store.task(t.id)!.ordoIndex == nil)
    }

    @Test func ordoAppendAndTopArithmetic() throws {
        let store = try TaskStore(inMemory: true)
        let a = store.create(title: "a")
        let b = store.create(title: "b")
        store.sendToOrdo(a.id)            // append -> 1024
        store.sendToOrdo(b.id)            // append -> 2048
        store.sendToOrdo(a.id, top: true) // push top -> 0
        let sorted = store.allTasks().filter { $0.isInOrdo }.sorted(by: Ordering.ordo)
        #expect(sorted.first?.id == a.id)
        #expect(sorted.count == 2)
    }

    @Test func carryDaysComputedNeverStored() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.create(title: "overdue")
        store.setDue(t.id, day: Day.today() - 2)
        let before = store.task(t.id)!.updatedAt
        _ = store.task(t.id)!.carryDays(today: Day.today())
        #expect(store.task(t.id)!.carryDays(today: Day.today()) == 2)
        #expect(store.task(t.id)!.dueDay == Day.today() - 2)
        #expect(store.task(t.id)!.updatedAt == before) // zero store writes
    }

    @Test func purgeOldSoftDeletes() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.create(title: "old")
        store.softDelete(t.id)
        store.updateIncludingDeleted(t.id) { $0.deletedAt = Date().addingTimeInterval(-40 * 86400) }
        store.purgeDeletedOlderThan(days: 30)
        #expect(store.allTasksIncludingDeleted().isEmpty)
    }

    @Test func labelMergeKeyHandlesDz() {
        let a = KLabel(name: "Đakovo")
        let b = KLabel(name: "dakovo")
        #expect(a.mergeKey == b.mergeKey)
    }
}
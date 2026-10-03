import Foundation
import SwiftData
import Testing
@testable import KronosCore

/// The next instance of a series has an id derived from the series and its due day, so two
/// completions of the same instance (two contexts, or two devices merged later) give ONE next
/// instance. Expected UUIDs come from Python's `uuid.uuid5` (an independent implementation), the
/// first two are the examples in Python's documentation.
@MainActor
@Suite("RecurrenceIdentityTests")
struct RecurrenceIdentityTests {

    static let series = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    static let dns = UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!

    /// (namespace, name, expected v5)
    static let vectors: [(UUID, String, String)] = [
        (dns, "www.example.com", "2ED6657D-E927-568B-95E1-2665A8AEA6A2"),
        (dns, "python.org", "886313E1-3B8A-5372-9B90-0C9AEE199E5D"),
        (series, "20730", "A5B43DB4-C97C-559A-A615-E4BFD3CE06CF"),
        (series, "20731", "D8713A28-A08E-5302-80C4-D3A9267337AF"),
    ]

    @Test func uuidV5MatchesTheReferenceImplementation() {
        for (ns, name, want) in Self.vectors {
            #expect(KUUID.v5(namespace: ns, name: name).uuidString == want, "\(name)")
        }
    }

    @Test func instanceAndStepIDsAreFixedFunctionsOfTheirInputs() {
        #expect(RecurrenceIdentity.instanceID(seriesID: Self.series, dueDay: 20730).uuidString
                == "A5B43DB4-C97C-559A-A615-E4BFD3CE06CF")
        let step = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let instance = UUID(uuidString: "A5B43DB4-C97C-559A-A615-E4BFD3CE06CF")!
        #expect(RecurrenceIdentity.stepCopyID(instanceID: instance, stepID: step).uuidString
                == "BC52F14E-4DD4-52C3-8D94-A4344CA34EDD")
    }

    private func recurring(_ store: TaskStore, due: Int) -> KTask {
        let t = store.create(title: "Water the plants", dueDay: due)
        store.update(t.id) { $0.recurrenceRule = RecurrenceRule.daily(every: 3, anchor: .fromDueDay).wireFormat }
        return t
    }

    @Test func spawnedInstanceGetsTheDerivedID() throws {
        let store = try TaskStore(inMemory: true)
        let due = Day.today()
        let t = recurring(store, due: due)
        store.complete(t.id)
        let next = try #require(store.allTasks().first { $0.id != t.id })
        #expect(next.dueDay == due + 3)
        #expect(next.id == RecurrenceIdentity.instanceID(seriesID: t.id, dueDay: due + 3))
    }

    /// Two handles on the same store file (the app and its background process): both complete
    /// the same instance, the second one sees the instance the first made. One next instance.
    @Test func doubleCompletionOnTwoContextsYieldsOneInstance() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kronos-recur-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = KronosStore.storeURL(in: dir)
        let a = try TaskStore(storeURL: url)
        let due = Day.today()
        let t = recurring(a, due: due)
        let b = try TaskStore(storeURL: url)
        #expect(b.task(t.id)?.status == .todo)   // B holds the open instance too

        a.complete(t.id)
        b.complete(t.id)

        let check = try TaskStore(storeURL: url)
        let instances = check.allTasks().filter { $0.id != t.id && $0.seriesID == t.id }
        #expect(instances.count == 1)
        #expect(instances.first?.dueDay == due + 3)
    }

    /// Two devices each complete the same instance offline; the sync then delivers the other
    /// device's copy (same id, a second record). The dedupe sweep leaves one instance.
    @Test func doubleCompletionOnTwoDevicesMergesToOneInstance() throws {
        let mac = try TaskStore(inMemory: true)
        let phone = try TaskStore(inMemory: true)
        let due = Day.today()
        let t = recurring(mac, due: due)
        // The same task on the phone (same id), as a sync would have delivered it.
        let original = t.id
        let same = KTask(title: "Water the plants")
        same.id = original
        same.dueDay = due
        same.recurrenceRule = t.recurrenceRule
        phone.context.insert(same)
        try phone.context.save()

        mac.complete(original)
        phone.complete(original)
        let macNext = try #require(mac.allTasks().first { $0.id != original })
        let phoneNext = try #require(phone.allTasks().first { $0.id != original })
        #expect(macNext.id == phoneNext.id)

        // Deliver the phone's record into the Mac's store: a second row with the same id.
        let delivered = KTask(title: phoneNext.title)
        delivered.id = phoneNext.id
        delivered.dueDay = phoneNext.dueDay
        delivered.seriesID = phoneNext.seriesID
        delivered.recurrenceRule = phoneNext.recurrenceRule
        delivered.createdAt = phoneNext.createdAt.addingTimeInterval(1)
        mac.context.insert(delivered)
        try mac.context.save()
        #expect(mac.allTasks().filter { $0.id == macNext.id }.count == 2)

        let report = DedupeSweep.run(in: mac)
        #expect(report.tasks == 1)
        #expect(mac.allTasks().filter { $0.seriesID == original && $0.id != original }.count == 1)
    }

    /// Undo of the completion hides the instance; completing again shows the SAME row again
    /// instead of adding a second row with that id.
    @Test func completeUndoCompleteReusesTheInstance() throws {
        let store = try TaskStore(inMemory: true)
        let t = recurring(store, due: Day.today())
        store.complete(t.id)
        let first = try #require(store.allTasks().first { $0.id != t.id })
        store.undo()
        #expect(store.allTasks().count == 1)
        store.complete(t.id)
        let rows = store.allTasksIncludingDeleted().filter { $0.id == first.id }
        #expect(rows.count == 1)
        #expect(rows.first?.deletedAt == nil)
        #expect(store.allTasks().count == 2)
    }
}

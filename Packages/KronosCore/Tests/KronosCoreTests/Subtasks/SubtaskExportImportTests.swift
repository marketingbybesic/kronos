import Testing
import Foundation
@testable import KronosCore

/// Export/import of subtasks. Current format: a subtask is a task row with `parentID`.
/// Previous format (steps as a `subtasks` array inside their task, with or without due/priority)
/// still imports, each step becoming a child task with the same id.
@MainActor
@Suite("SubtaskExportImportTests")
struct SubtaskExportImportTests {

    private func exportJSON(_ store: TaskStore) -> Data {
        JSONExporter(store: store).exportData(now: Date(timeIntervalSince1970: 1_790_000_000))
    }

    @Test func dueAndPriorityRoundTrip() throws {
        let source = try TaskStore(inMemory: true)
        let t = source.createNoUndo(title: "Parent")
        source.addSubtaskNoUndo(t.id, title: "Dated", dueDay: SubtaskFixture.day("2026-10-15"), priority: .urgent)
        source.addSubtaskNoUndo(t.id, title: "Plain")

        let data = exportJSON(source)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("2026-10-15"), "the due day must be written as its ISO string")

        let target = try TaskStore(inMemory: true)
        _ = try KronosImporter(store: target).importData(data, mode: .replace)

        let subs = try #require(target.allTasks().first { $0.title == "Parent" }).orderedSubtasks
        #expect(subs.map(\.title) == ["Dated", "Plain"])
        #expect(SubtaskFixture.iso(subs[0].dueDay) == "2026-10-15")
        #expect(subs[0].priorityRaw == 4)
        #expect(subs[1].dueDay == nil)
        #expect(subs[1].priorityRaw == 0)
    }

    @Test func importIntoAStoreThatAlreadyHasTheStepUpdatesTheFields() throws {
        let source = try TaskStore(inMemory: true)
        let t = source.createNoUndo(title: "Parent")
        let s = try #require(source.addSubtaskNoUndo(t.id, title: "Step"))
        let data1 = exportJSON(source)

        let target = try TaskStore(inMemory: true)
        _ = try KronosImporter(store: target).importData(data1, mode: .replace)
        #expect(target.subtask(s.id)?.dueDay == nil)

        s.dueDay = SubtaskFixture.day("2026-11-05")
        s.priority = .medium
        // CHANGED: the step is its own row now, so ITS updatedAt decides the merge (newer wins).
        s.updatedAt = Date().addingTimeInterval(3600)
        let data2 = exportJSON(source)
        _ = try KronosImporter(store: target).importData(data2, mode: .merge)
        let got = try #require(target.subtask(s.id))
        #expect(SubtaskFixture.iso(got.dueDay) == "2026-11-05")
        #expect(got.priorityRaw == 2)
    }

    /// A previous-format file, written by hand: two steps inside their task, one done without
    /// due/priority keys, one open with them. Ids are fixed so the expectations are literal.
    @Test func thePreviousFormatWithStepArraysStillImports() throws {
        let source = try TaskStore(inMemory: true)
        _ = source.createNoUndo(title: "Old parent")
        var root = try #require(JSONSerialization.jsonObject(with: exportJSON(source)) as? [String: Any])
        var tasks = try #require(root["tasks"] as? [[String: Any]])
        tasks[0]["subtasks"] = [
            ["id": "11111111-1111-1111-1111-111111111111", "title": "Old done step", "isDone": true,
             "sortIndex": 1024, "createdAt": "2026-09-01T10:00:00Z", "updatedAt": "2026-09-02T10:00:00Z"],
            ["id": "22222222-2222-2222-2222-222222222222", "title": "Old open step", "isDone": false,
             "sortIndex": 2048, "createdAt": "2026-09-01T10:00:00Z", "updatedAt": "2026-09-01T10:00:00Z",
             "dueDay": "2026-10-15", "priority": 3, "notes": "[[link]]"],
        ]
        root["tasks"] = tasks
        let old = try JSONSerialization.data(withJSONObject: root)

        let target = try TaskStore(inMemory: true)
        let result = try KronosImporter(store: target).importData(old, mode: .replace)
        #expect(result.subtasks == 2)
        let parent = try #require(target.allTasks().first { $0.title == "Old parent" })
        #expect(target.allTasks().count == 1, "steps are not list rows")
        let subs = parent.orderedSubtasks
        #expect(subs.map(\.title) == ["Old done step", "Old open step"])
        #expect(subs.map(\.id.uuidString) == ["11111111-1111-1111-1111-111111111111",
                                              "22222222-2222-2222-2222-222222222222"])
        #expect(subs.allSatisfy { $0.parentID == parent.id })
        #expect(subs[0].status == .done)
        #expect(subs[0].completedAt != nil)
        #expect(subs[0].dueDay == nil)
        #expect(subs[0].priorityRaw == 0)
        #expect(subs[1].status == .todo)
        #expect(SubtaskFixture.iso(subs[1].dueDay) == "2026-10-15")
        #expect(subs[1].priorityRaw == 3)
        #expect(subs[1].notes == "[[link]]")
    }

    @Test func aSubtaskExportsAsATaskWithParentIDAndRoundTrips() throws {
        let store = try TaskStore(inMemory: true)
        let parent = store.createNoUndo(title: "Parent")
        let child = store.createNoUndo(title: "Child", priority: .high, dueDay: SubtaskFixture.day("2026-12-24"))
        try store.makeTaskSubtaskOf(child.id, parentID: parent.id)

        let envelope = JSONExporter(store: store).makeEnvelope()
        let exported = try #require(envelope.tasks.first { $0.title == "Child" })
        #expect(exported.id == child.id)
        #expect(exported.parentID == parent.id)
        #expect(exported.dueDay == "2026-12-24")
        #expect(exported.priority == 3)
        #expect(envelope.tasks.first { $0.title == "Parent" }?.parentID == nil)
        #expect(envelope.tasks.allSatisfy { $0.subtasks.isEmpty }, "no step arrays in the current format")

        let target = try TaskStore(inMemory: true)
        _ = try KronosImporter(store: target).importData(exportJSON(store), mode: .replace)
        #expect(target.allTasks().map(\.title) == ["Parent"])
        let got = try #require(target.task(child.id))
        #expect(got.parentID == parent.id)
        #expect(got.parent?.id == parent.id)
        #expect(SubtaskFixture.iso(got.dueDay) == "2026-12-24")
    }
}

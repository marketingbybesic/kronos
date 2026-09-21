import Testing
import Foundation
@testable import KronosCore

@MainActor
struct JSONExporterTests {

    /// Populates a fresh in-memory store with every entity type and the
    /// awkward data named in the gate: Croatian diacritics incl. đ, emoji in
    /// a project, a nil and a non-nil `dueDay`, subtasks done/undone, a
    /// soft-deleted task, labels shared between two tasks, a saved view with
    /// a 2-key sort and a multi-field filter, and a rule.
    private static func makePopulatedStore() throws -> TaskStore {
        let store = try TaskStore(inMemory: true)

        let area = KArea(name: "Đakovo poslovi", colorHex: "#8B8B93", icon: "sun.max", sortIndex: 0)
        store.context.insert(area)

        let project = KProject(name: "Čišćenje šatora", colorHex: "#8224E3", icon: "circle",
                               area: area, sortIndex: 0, emoji: "🔥")
        store.context.insert(project)

        let shared1 = store.label(named: "Žurno")
        let shared2 = store.label(named: "kupci")

        let dated = store.create(title: "Nazvati Đakovčane", notes: "žč ćš đ diacritics",
                                 project: project, status: .todo, priority: .high,
                                 dueDay: Day.today() + 3)
        dated.labels = [shared1, shared2]
        dated.effort = .l
        store.saveContext()

        let undated = store.create(title: "Bez roka", notes: "", project: project,
                                   status: .todo, priority: .none, dueDay: nil)
        undated.labels = [shared1]
        undated.effort = .xs
        store.saveContext()

        _ = store.addSubtask(dated.id, title: "Prvi korak")
        let step2 = store.addSubtask(dated.id, title: "Drugi korak")
        store.toggleSubtask(step2!.id)

        let toDelete = store.create(title: "Soft deleted đubre", project: nil)
        store.softDelete(toDelete.id)

        _ = store.addRule(text: "Nikad prije 9h", scope: .impuls, source: .manual)

        var filter = KFilter()
        filter.statuses = [KStatus.todo.rawValue]
        filter.dread = false
        filter.text = "đakovo"
        filter.efforts = [KEffort.l.rawValue]
        // rev 4: one negated field, so the byte-identical round trip proves
        // negation survives export → wipe → import → export unchanged.
        filter.priorities = [KPriority.low.rawValue]
        filter.setNegated(.priorities, true)
        let view = KSavedView(name: "Moj pregled", filter: filter, sortMode: .priorityThenDue,
                              groupBy: .project, showDone: false, sortIndex: 0,
                              sort: [.desc(.priority), .asc(.deadline)])
        store.context.insert(view)
        store.saveContext()

        return store
    }

    @Test func exportWipeImportExportIsByteIdentical() throws {
        let store = try Self.makePopulatedStore()
        let exporter = JSONExporter(store: store)
        let fixedNow = Date(timeIntervalSince1970: 1_726_000_000)

        let firstEnvelope = exporter.makeEnvelope(now: fixedNow)
        var firstStripped = firstEnvelope
        firstStripped.exportedAt = Date(timeIntervalSince1970: 0)
        let firstData = try KronosExportCodec.makeEncoder().encode(firstStripped)

        let importer = KronosImporter(store: store)
        _ = importer.importEnvelope(firstEnvelope, mode: .replace)

        let secondEnvelope = exporter.makeEnvelope(now: fixedNow)
        var secondStripped = secondEnvelope
        secondStripped.exportedAt = Date(timeIntervalSince1970: 0)
        let secondData = try KronosExportCodec.makeEncoder().encode(secondStripped)

        #expect(firstData == secondData)
        // Sanity: the payload is non-trivial, so an accidental early-return
        // that emits an empty envelope on both sides could not pass silently.
        #expect(firstEnvelope.tasks.count == 3)
        #expect(firstEnvelope.projects.count == 1)
    }

    @Test func effortAndEmojiRoundTrip() throws {
        let store = try Self.makePopulatedStore()
        let exporter = JSONExporter(store: store)
        let envelope = exporter.makeEnvelope()

        let project = try #require(envelope.projects.first)
        #expect(project.emoji == "🔥")

        let l = try #require(envelope.tasks.first { $0.title == "Nazvati Đakovčane" })
        #expect(l.effort == KEffort.l.rawValue)
        let xs = try #require(envelope.tasks.first { $0.title == "Bez roka" })
        #expect(xs.effort == KEffort.xs.rawValue)
        #expect(xs.dueDay == nil)
        #expect(l.dueDay != nil)

        // Round-trip through a fresh store: effort and emoji survive.
        let store2 = try TaskStore(inMemory: true)
        let importer = KronosImporter(store: store2)
        _ = importer.importEnvelope(envelope, mode: .replace)

        let importedProject = try #require(store2.allProjects().first { $0.name == project.name })
        #expect(importedProject.emoji == "🔥")
        let importedTask = try #require(store2.allTasks().first { $0.title == "Nazvati Đakovčane" })
        #expect(importedTask.effort == KEffort.l)
    }

    @Test func negatedFilterSurvivesTheExportEnvelope() throws {
        let store = try Self.makePopulatedStore()
        let envelope = JSONExporter(store: store).makeEnvelope()

        // The envelope carries KFilter directly, so negation must ride along
        // or a restored backup would quietly mean the OPPOSITE of the saved
        // view the user built.
        let exported = try #require(envelope.savedViews.first)
        #expect(exported.filter.isNegated(.priorities))
        #expect(exported.filter.priorities == [KPriority.low.rawValue])
        #expect(!exported.filter.isNegated(.statuses))

        let store2 = try TaskStore(inMemory: true)
        _ = KronosImporter(store: store2).importEnvelope(envelope, mode: .replace)

        let imported = try #require(store2.allSavedViews().first)
        #expect(imported.filter.isNegated(.priorities))
        #expect(imported.filter.priorities == [KPriority.low.rawValue])
        #expect(imported.filter.text == "đakovo")
    }

    @Test func seedWithoutEffortKeyStillImports() throws {
        // A pre-rev-3 v1 envelope: no "effort" key on the task, no "emoji"
        // key on the project. Built directly as JSON so nothing in this test
        // accidentally exercises the rev-3 encoder path.
        let projectID = UUID()
        let taskID = UUID()
        let json = """
        {
          "format": "kronos",
          "version": 1,
          "exportedAt": "2026-01-01T00:00:00Z",
          "areas": [],
          "projects": [
            { "id": "\(projectID.uuidString)", "name": "Legacy", "colorHex": "#8224E3",
              "icon": "circle", "sortIndex": 0, "isArchived": false, "areaID": null,
              "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z" }
          ],
          "labels": [],
          "rules": [],
          "savedViews": [],
          "tasks": [
            { "id": "\(taskID.uuidString)", "title": "Old task", "notes": "", "firstMove": null,
              "status": 0, "priority": 1, "depth": 0, "dread": false,
              "energyKind": null, "estimateMinutes": null,
              "dueDay": null, "originalDueDay": null, "completedAt": null,
              "sortIndex": 1024, "ordoIndex": null, "needsTriage": false,
              "recurrenceRule": null, "seriesID": null, "calendarEventID": null,
              "externalID": null, "source": null,
              "projectID": "\(projectID.uuidString)", "labelIDs": [], "subtasks": [],
              "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z" }
          ]
        }
        """
        let store = try TaskStore(inMemory: true)
        let importer = KronosImporter(store: store)
        let result = try importer.importData(Data(json.utf8), mode: .replace)

        #expect(result.tasks == 1)
        #expect(result.projects == 1)
        let task = try #require(store.allTasks().first)
        #expect(task.effort == KEffort.none)
        let project = try #require(store.allProjects().first)
        #expect(project.emoji == nil)
    }

    @Test func importRejectsNewerVersion() throws {
        let store = try TaskStore(inMemory: true)
        let importer = KronosImporter(store: store)
        let envelope = KronosExportEnvelope(version: 2, exportedAt: Date())
        let data = try KronosExportCodec.makeEncoder().encode(envelope)

        #expect(throws: StoreError.self) {
            _ = try importer.importData(data)
        }
    }
}

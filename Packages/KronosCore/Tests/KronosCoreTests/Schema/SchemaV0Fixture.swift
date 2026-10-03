import CoreData
import Foundation
import SwiftData
@testable import KronosCore

/// The stored shape builds wrote BEFORE child tasks existed: V1 without `KTask.parentID`,
/// `parent` and `children`. Stores in this shape are still around (the person's store and its
/// rolling `.store` backups were last written by such a build), and SwiftData's staged plan
/// refuses them as an unknown version, so the launch brings them to V1 first. Test-only: the
/// app never declares this schema.
enum SchemaV0Test: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(0, 9, 0) }
    static var models: [any PersistentModel.Type] {
        [KArea.self, KProject.self, KLabel.self, KTask.self, KSubtask.self, KRule.self, KSavedView.self]
    }

    @Model final class KArea {
        var id: UUID = UUID()
        var name: String = ""
        var colorHex: String = "#8B8B93"
        var icon: String = "square.grid.2x2"
        var sortIndex: Double = 0
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        @Relationship(deleteRule: .nullify, inverse: \KProject.area)
        var projects: [KProject]? = []
        init(name: String) { self.name = name }
    }

    @Model final class KProject {
        var id: UUID = UUID()
        var name: String = ""
        var colorHex: String = "#8224E3"
        var icon: String? = nil
        var emoji: String? = nil
        var sortIndex: Double = 0
        var isArchived: Bool = false
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        var area: KArea?
        @Relationship(deleteRule: .nullify, inverse: \KTask.project)
        var tasks: [KTask]? = []
        init(name: String, area: KArea? = nil) { self.name = name; self.area = area }
    }

    @Model final class KLabel {
        var id: UUID = UUID()
        var name: String = ""
        var colorHex: String = "#8B8B93"
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        var tasks: [KTask]? = []
        init(name: String) { self.name = name }
    }

    @Model final class KTask {
        var id: UUID = UUID()
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        var title: String = ""
        var notes: String = ""
        var firstMove: String? = nil
        var statusRaw: Int = 0
        var priorityRaw: Int = 0
        var depthRaw: Int = 0
        var effortRaw: Int = 0
        var dread: Bool = false
        var energyKindRaw: Int? = nil
        var estimateMinutes: Int? = nil
        var dueDay: Int? = nil
        var originalDueDay: Int? = nil
        var completedAt: Date? = nil
        var sortIndex: Double = 0
        var ordoIndex: Double? = nil
        var deletedAt: Date? = nil
        var triagedAt: Date? = nil
        var triageModel: String? = nil
        var triageRationale: String? = nil
        var triageFeedback: String? = nil
        var triageReviewedAt: Date? = nil
        var needsTriage: Bool = true
        var recurrenceRule: String? = nil
        var seriesID: UUID? = nil
        var calendarEventID: String? = nil
        var waitsOnIDs: String = ""
        var externalID: String? = nil
        var source: String? = nil
        var projectID: UUID? = nil
        var areaID: UUID? = nil
        var isProjectArchived: Bool = false
        var project: KProject?
        @Relationship(deleteRule: .nullify, inverse: \KLabel.tasks)
        var labels: [KLabel]? = []
        @Relationship(deleteRule: .cascade, inverse: \KSubtask.task)
        var subtasks: [KSubtask]? = []
        init(title: String, project: KProject? = nil) {
            self.title = title
            self.project = project
            self.projectID = project?.id
            self.areaID = project?.area?.id
        }
    }

    @Model final class KSubtask {
        var id: UUID = UUID()
        var title: String = ""
        var isDone: Bool = false
        var notes: String = ""
        var sortIndex: Double = 0
        var dueDay: Int? = nil
        var priorityRaw: Int = 0
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        var task: KTask?
        init(title: String, sortIndex: Double = 0) { self.title = title; self.sortIndex = sortIndex }
    }

    @Model final class KRule {
        var id: UUID = UUID()
        var text: String = ""
        var scopeRaw: Int = 0
        var sourceRaw: Int = 1
        var isActive: Bool = true
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        init(text: String) { self.text = text }
    }

    @Model final class KSavedView {
        var id: UUID = UUID()
        var name: String = ""
        var icon: String = "line.3.horizontal.decrease.circle"
        var sortIndex: Double = 0
        var filterJSON: String = "{}"
        var sortModeRaw: Int = 1
        var groupByRaw: Int = 0
        var sortJSON: String = "[]"
        var showDone: Bool = false
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        init(name: String) { self.name = name }
    }

    /// Pack [Home] steps Charger (open, due, high) + Passport (done); Old [Home, deleted] step
    /// Gone; Solo; one detached step. Ids and dates from `SchemaV2Fixture`.
    static func write(to url: URL) throws {
        typealias F = SchemaV2Fixture
        let schema = Schema(versionedSchema: SchemaV0Test.self)
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
        let ctx = ModelContext(container)
        let area = KArea(name: "Life"); area.id = F.areaID; ctx.insert(area)
        let home = KProject(name: "Home", area: area); home.id = F.projectID; ctx.insert(home)
        func task(_ id: UUID, _ title: String, _ p: KProject?, sort: Double) -> KTask {
            let t = KTask(title: title, project: p)
            t.id = id; t.sortIndex = sort; t.createdAt = F.t0; t.updatedAt = F.t0
            ctx.insert(t)
            return t
        }
        let pack = task(F.packID, "Pack", home, sort: 1024)
        let old = task(F.oldID, "Old", home, sort: 2048)
        old.deletedAt = F.t0
        _ = task(F.soloID, "Solo", nil, sort: 3072)
        func step(_ id: UUID, _ title: String, _ owner: KTask?, sort: Double) -> KSubtask {
            let s = KSubtask(title: title, sortIndex: sort)
            s.id = id; s.createdAt = F.t0; s.updatedAt = F.t1; s.task = owner
            ctx.insert(s)
            return s
        }
        let charger = step(F.chargerID, "Charger", pack, sort: 1024)
        charger.dueDay = Day.parseISO("2026-10-10")
        charger.priorityRaw = 3
        let passport = step(F.passportID, "Passport", pack, sort: 2048)
        passport.isDone = true
        _ = step(F.goneID, "Gone step", old, sort: 0)
        _ = step(F.detachedID, "Detached", nil, sort: 0)
        try ctx.save()
    }

    /// True when the store at `url` has exactly this shape.
    static func matches(_ url: URL) -> Bool {
        guard let meta = try? NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: url),
              let model = NSManagedObjectModel.makeManagedObjectModel(for: models) else { return false }
        return model.isConfiguration(withName: nil, compatibleWithStoreMetadata: meta)
    }
}

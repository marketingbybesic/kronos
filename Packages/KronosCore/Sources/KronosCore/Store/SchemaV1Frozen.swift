// Schema V1, frozen.
//
// These nested classes are an exact copy of the stored shape every build up to and including
// the first child-task release wrote to disk: the same entity names, attribute names, types,
// optionality and relationships (with their inverses and delete rules). SwiftData identifies an
// on-disk store's version by comparing its entity hashes against each `VersionedSchema` in
// `KronosMigrationPlan`, so a single changed attribute here would make every existing store
// "unknown" and refuse to open.
//
// NEVER edit these classes. New fields go on the top-level models (schema V2) and, after a
// CloudKit deploy, only through a new versioned schema.
//
// Defaults are literal values, not enum references, so a later change to an enum's raw values
// cannot alter what V1 means. Only the members the V1 -> V2 stage needs exist besides the stored
// properties.

import Foundation
import SwiftData

public enum KronosSchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [KArea.self, KProject.self, KLabel.self, KTask.self,
         KSubtask.self, KRule.self, KSavedView.self]
    }

    @Model
    public final class KArea {
        public var id: UUID = UUID()
        public var name: String = ""
        public var colorHex: String = "#8B8B93"
        public var icon: String = "square.grid.2x2"
        public var sortIndex: Double = 0
        public var createdAt: Date = Date()
        public var updatedAt: Date = Date()

        @Relationship(deleteRule: .nullify, inverse: \KProject.area)
        public var projects: [KProject]? = []

        public init(name: String) { self.name = name }
    }

    @Model
    public final class KProject {
        public var id: UUID = UUID()
        public var name: String = ""
        public var colorHex: String = "#8224E3"
        public var icon: String? = nil
        public var emoji: String? = nil
        public var sortIndex: Double = 0
        public var isArchived: Bool = false
        public var createdAt: Date = Date()
        public var updatedAt: Date = Date()

        public var area: KArea?

        @Relationship(deleteRule: .nullify, inverse: \KTask.project)
        public var tasks: [KTask]? = []

        public init(name: String, area: KArea? = nil) {
            self.name = name
            self.area = area
        }
    }

    @Model
    public final class KLabel {
        public var id: UUID = UUID()
        public var name: String = ""
        public var colorHex: String = "#8B8B93"
        public var createdAt: Date = Date()
        public var updatedAt: Date = Date()

        public var tasks: [KTask]? = []

        public init(name: String) { self.name = name }
    }

    @Model
    public final class KTask {
        public var id: UUID = UUID()
        public var createdAt: Date = Date()
        public var updatedAt: Date = Date()

        public var title: String = ""
        public var notes: String = ""
        public var firstMove: String? = nil

        public var statusRaw: Int = 0
        public var priorityRaw: Int = 0
        public var depthRaw: Int = 0
        public var effortRaw: Int = 0
        public var dread: Bool = false
        public var energyKindRaw: Int? = nil
        public var estimateMinutes: Int? = nil

        public var dueDay: Int? = nil
        public var originalDueDay: Int? = nil
        public var completedAt: Date? = nil

        public var sortIndex: Double = 0
        public var ordoIndex: Double? = nil

        public var deletedAt: Date? = nil

        public var triagedAt: Date? = nil
        public var triageModel: String? = nil
        public var triageRationale: String? = nil
        public var triageFeedback: String? = nil
        public var triageReviewedAt: Date? = nil
        public var needsTriage: Bool = true

        public var recurrenceRule: String? = nil
        public var seriesID: UUID? = nil

        public var calendarEventID: String? = nil

        public var waitsOnIDs: String = ""

        public var externalID: String? = nil
        public var source: String? = nil

        public var projectID: UUID? = nil
        public var areaID: UUID? = nil
        public var isProjectArchived: Bool = false

        public var project: KProject?

        @Relationship(deleteRule: .nullify, inverse: \KLabel.tasks)
        public var labels: [KLabel]? = []

        @Relationship(deleteRule: .cascade, inverse: \KSubtask.task)
        public var subtasks: [KSubtask]? = []

        public var parentID: UUID? = nil
        public var parent: KTask?

        @Relationship(deleteRule: .cascade, inverse: \KTask.parent)
        public var children: [KTask]? = []

        public init(title: String, project: KProject? = nil) {
            self.title = title
            self.project = project
            self.projectID = project?.id
            self.areaID = project?.area?.id
            self.isProjectArchived = project?.isArchived ?? false
        }
    }

    /// The step row V2 no longer has. Exists only so a V1 store (or a restored V1 backup) can be
    /// read and its rows converted into child tasks by the V1 -> V2 stage.
    @Model
    public final class KSubtask {
        public var id: UUID = UUID()
        public var title: String = ""
        public var isDone: Bool = false
        public var notes: String = ""
        public var sortIndex: Double = 0
        public var dueDay: Int? = nil
        public var priorityRaw: Int = 0
        public var createdAt: Date = Date()
        public var updatedAt: Date = Date()

        public var task: KTask?

        public init(title: String, sortIndex: Double = 0) {
            self.title = title
            self.sortIndex = sortIndex
        }
    }

    @Model
    public final class KRule {
        public var id: UUID = UUID()
        public var text: String = ""
        public var scopeRaw: Int = 0
        public var sourceRaw: Int = 1
        public var isActive: Bool = true
        public var createdAt: Date = Date()
        public var updatedAt: Date = Date()

        public init(text: String) { self.text = text }
    }

    @Model
    public final class KSavedView {
        public var id: UUID = UUID()
        public var name: String = ""
        public var icon: String = "line.3.horizontal.decrease.circle"
        public var sortIndex: Double = 0
        public var filterJSON: String = "{}"
        public var sortModeRaw: Int = 1
        public var groupByRaw: Int = 0
        public var sortJSON: String = "[]"
        public var showDone: Bool = false
        public var createdAt: Date = Date()
        public var updatedAt: Date = Date()

        public init(name: String) { self.name = name }
    }
}

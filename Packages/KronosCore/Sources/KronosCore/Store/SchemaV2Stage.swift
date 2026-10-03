// The V1 -> V2 migration stage.
//
// V2 drops the step table (`KSubtask`) and `KTask.subtasks`. A store written by a current build
// has no step rows left (the launch conversion in TaskStore+SubtaskMigration.swift moved them),
// but an older store or a restored backup can still hold some. Before SwiftData drops the table,
// `willMigrate` runs on the V1 shape and turns every step row into a child task with the same id,
// using the same mapping the launch conversion used, all in one save. The lightweight part of
// the stage then adds the V2 columns and tables.
//
// The stage refuses to run when this launch's pre-V2 safety copy failed (see
// `SubtaskToTaskMigration.backupStoreFilesIfNeeded`): the store then stays V1, untouched, and
// opening it throws, so the app shows its readable launch error instead of upgrading data that
// has no copy.

import CoreData
import Foundation
import SwiftData

public enum KronosSchemaV2Stage {

    public static var v1ToV2: MigrationStage {
        .custom(fromVersion: KronosSchemaV1.self,
                toVersion: KronosSchemaV2.self,
                willMigrate: { context in
                    if SchemaV2Upgrade.isBlocked { throw SchemaV2Upgrade.Refusal.noSafetyCopy }
                    let result = try convertLegacySteps(in: context)
                    SchemaV2Upgrade.record(result)
                },
                didMigrate: nil)
    }

    /// Every V1 step row becomes a V1 `KTask` with the SAME id, title, notes, sort index, due
    /// day, priority and dates; done -> status done (4) + `completedAt` = the step's last change,
    /// otherwise todo (0); `needsTriage` false. Parent = the owning task (one level: a step of a
    /// child goes to that child's parent), project and its scalar mirrors copied from the parent,
    /// `deletedAt` = the parent's. A step with no person becomes a soft-deleted top-level task, so
    /// nothing is lost and the 30-day purge sweeps it. A step whose id already exists as a task
    /// (a conversion that already ran) is only removed. One save; a failed save throws, which
    /// aborts the migration and leaves the store on V1.
    @discardableResult
    static func convertLegacySteps(in context: ModelContext,
                                   now: Date = Date()) throws -> SubtaskToTaskMigration.Result {
        typealias V1Task = KronosSchemaV1.KTask
        typealias V1Step = KronosSchemaV1.KSubtask
        let steps = try context.fetch(FetchDescriptor<V1Step>())
        guard !steps.isEmpty else { return .init(converted: 0, orphans: 0, alreadyTasks: 0) }
        var existing = Set(try context.fetch(FetchDescriptor<V1Task>()).map(\.id))
        var converted = 0, orphans = 0, already = 0

        for s in steps {
            guard existing.insert(s.id).inserted else {
                already += 1
                context.delete(s)
                continue
            }
            let owner = s.task.map { $0.parent ?? $0 }
            let t = V1Task(title: s.title)
            t.id = s.id
            t.notes = s.notes
            t.statusRaw = s.isDone ? KStatus.done.rawValue : KStatus.todo.rawValue
            t.completedAt = s.isDone ? s.updatedAt : nil
            t.sortIndex = s.sortIndex
            t.dueDay = s.dueDay
            t.originalDueDay = s.dueDay
            t.priorityRaw = s.priorityRaw
            t.needsTriage = false
            t.createdAt = s.createdAt
            t.updatedAt = s.updatedAt
            context.insert(t)
            if let owner {
                t.parent = owner
                t.parentID = owner.id
                t.project = owner.project
                t.projectID = owner.projectID
                t.areaID = owner.areaID
                t.isProjectArchived = owner.isProjectArchived
                t.deletedAt = owner.deletedAt
                converted += 1
            } else {
                t.project = nil
                t.projectID = nil
                t.areaID = nil
                t.isProjectArchived = false
                t.deletedAt = now
                orphans += 1
            }
            context.delete(s)
        }
        context.processPendingChanges()
        try context.save()
        return .init(converted: converted, orphans: orphans, alreadyTasks: already)
    }
}

/// Process-wide state of the V2 upgrade for this launch: whether the safety copy failed (the
/// stage then refuses) and what the stage converted (reported by `runIfNeeded`).
public enum SchemaV2Upgrade {

    public enum Refusal: Error, CustomStringConvertible {
        case noSafetyCopy
        public var description: String {
            switch self {
            case .noSafetyCopy:
                return "Kronos could not make a safety copy of its data before upgrading it, so the data "
                    + "was left exactly as it was and not upgraded. Free some disk space, then open Kronos again."
            }
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var blocked = false
    nonisolated(unsafe) private static var converted: SubtaskToTaskMigration.Result?

    /// True when this launch's pre-V2 copy failed: the V1 -> V2 stage must not run.
    public static var isBlocked: Bool { lock.withLock { blocked } }

    static func setBlocked(_ value: Bool) { lock.withLock { blocked = value } }

    static func record(_ result: SubtaskToTaskMigration.Result) { lock.withLock { converted = result } }

    /// Whether the store file at `url` already has the V2 shape, read from the store's own
    /// metadata (the entity hashes SQLite holds), never from a marker. Nil when the metadata
    /// cannot be read (no file, not a store); callers treat that as "not V2".
    public static func storeIsV2(at url: URL) -> Bool? {
        storeMatches(KronosSchemaV2.models, at: url)
    }

    /// Whether the store file at `url` has exactly the frozen V1 shape. Nil when unreadable.
    public static func storeIsV1(at url: URL) -> Bool? {
        storeMatches(KronosSchemaV1.models, at: url)
    }

    private static func storeMatches(_ models: [any PersistentModel.Type], at url: URL) -> Bool? {
        guard FileManager.default.fileExists(atPath: url.path),
              let metadata = try? NSPersistentStoreCoordinator.metadataForPersistentStore(
                type: .sqlite, at: url),
              let model = NSManagedObjectModel.makeManagedObjectModel(for: models)
        else { return nil }
        return model.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata)
    }

    /// What `bringOlderStoreToV1` did.
    public enum OlderStoreStep: Equatable, Sendable {
        /// Already V1 or V2, or not a readable store: nothing to do.
        case notNeeded
        /// Was an older shape and now has the V1 shape.
        case broughtToV1
        /// Was an older shape and could not be brought to V1; the open will refuse it.
        case failed(String)
    }

    /// A store written before child tasks existed (an older, unversioned shape) is neither V1 nor
    /// V2, and SwiftData stages a migration only from a version the plan knows: it refuses such a
    /// store ("unknown model version") and changes nothing. This opens it once as V1 with no
    /// plan, so Core Data infers the additive V1 columns exactly as the builds before V2 did, and
    /// closes it. The file is then V1 and the V1 -> V2 stage converts its step rows on the real
    /// open. Call only before the main store is opened (launch), after the safety copy.
    @discardableResult
    public static func bringOlderStoreToV1(at url: URL) -> OlderStoreStep {
        guard let isV1 = storeIsV1(at: url), let isV2 = storeIsV2(at: url), !isV1, !isV2 else {
            return .notNeeded
        }
        do {
            try autoreleasepool {
                let schema = Schema(versionedSchema: KronosSchemaV1.self)
                let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
                let container = try ModelContainer(for: schema, configurations: [config])
                _ = try ModelContext(container).fetchCount(FetchDescriptor<KronosSchemaV1.KTask>())
            }
        } catch {
            FileHandle.standardError.write(Data("Kronos: older store could not be brought to V1: \(error)\n".utf8))
            return .failed(String(describing: error))
        }
        return storeIsV1(at: url) == true ? .broughtToV1 : .failed("store is still not V1")
    }

    /// What the stage converted in this process, once; nil when it did not run.
    static func takeConverted() -> SubtaskToTaskMigration.Result? {
        lock.withLock {
            defer { converted = nil }
            return converted
        }
    }
}

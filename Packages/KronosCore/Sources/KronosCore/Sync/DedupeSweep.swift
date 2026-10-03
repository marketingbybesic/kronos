// CloudKit allows no unique constraints, and the first sync merges two stores that grew apart
// (the Mac's, and a fresh device's that may have made its own areas, labels or a seed). The
// same thing is then present twice. This sweep folds every such pair into one row:
//
//   areas     same folded name                       -> one area, its projects and tasks kept
//   projects  same folded name in the same area      -> one project, its tasks kept
//   labels    same merge key (`KLabel.mergeKey`)     -> one label, every task keeps it
//   tasks     same `id` (two records, one identity)  -> one row: newest content, labels unioned,
//                                                       children and attachments kept, done wins
//   rules     same folded text and scope             -> one rule, the newest on/off state
//   markers   same `KStoreMeta.key`                  -> the newest row
//
// The row kept is always the oldest (createdAt, then id), which every device computes the same
// way, so two devices sweeping the same merged data delete the same rows. Saved views that
// pointed at a removed area, project or label are re-pointed at the kept one. Undo steps that
// would rewrite a removed row are dropped. Machine write: no undo step, one save.

import Foundation
import SwiftData

public struct DedupeReport: Equatable, Sendable {
    public var areas = 0, projects = 0, labels = 0, tasks = 0, rules = 0, markers = 0
    /// Rows removed, by kind, added up.
    public var total: Int { areas + projects + labels + tasks + rules + markers }
    public init() {}
}

@MainActor
public enum DedupeSweep {

    @discardableResult
    public static func run(in store: TaskStore) -> DedupeReport {
        var report = DedupeReport()
        var removed = Set<UUID>()
        var remap: [UUID: UUID] = [:]          // removed area/project/label id -> kept id
        let ctx = store.context

        // Areas
        let areas = fetch(KArea.self, ctx)
        for group in groups(areas, key: { KTextFold.fold($0.name) }) {
            let keep = group[0]
            for dup in group.dropFirst() {
                for p in dup.projects ?? [] { p.area = keep }
                for t in store.allTasksIncludingDeleted() where t.areaID == dup.id { t.areaID = keep.id }
                remap[dup.id] = keep.id
                removed.insert(dup.id)
                ctx.delete(dup)
                report.areas += 1
            }
        }

        // Projects (after areas, so "same area" means the kept area)
        let projects = fetch(KProject.self, ctx).filter { !removed.contains($0.id) }
        for group in groups(projects, key: { KTextFold.fold($0.name) + "|" + ($0.area?.id.uuidString ?? "-") }) {
            let keep = group[0]
            for dup in group.dropFirst() {
                for t in store.allTasksIncludingDeleted() where t.project?.id == dup.id || t.projectID == dup.id {
                    t.project = keep
                    t.projectID = keep.id
                    t.areaID = keep.area?.id
                    t.isProjectArchived = keep.isArchived
                }
                remap[dup.id] = keep.id
                removed.insert(dup.id)
                ctx.delete(dup)
                report.projects += 1
            }
        }

        // Labels
        let labels = fetch(KLabel.self, ctx)
        for group in groups(labels, key: { $0.mergeKey }) {
            let keep = group[0]
            for dup in group.dropFirst() {
                for t in store.allTasksIncludingDeleted() where (t.labels ?? []).contains(where: { $0.id == dup.id }) {
                    var next = (t.labels ?? []).filter { $0.id != dup.id }
                    if !next.contains(where: { $0.id == keep.id }) { next.append(keep) }
                    t.labels = next
                }
                remap[dup.id] = keep.id
                removed.insert(dup.id)
                ctx.delete(dup)
                report.labels += 1
            }
        }

        // Tasks with the same id
        let merged = mergeSameIDTasks(store)
        report.tasks = merged.removed
        // The kept row took another copy's content: its pending undo steps are stale too.
        removed.formUnion(merged.ids)

        // Rules
        let rules = fetch(KRule.self, ctx)
        for group in groups(rules, key: { $0.dedupeKey }) {
            let keep = group[0]
            let newest = group.max { $0.updatedAt < $1.updatedAt } ?? keep
            if keep.isActive != newest.isActive { keep.isActive = newest.isActive }
            for dup in group.dropFirst() {
                removed.insert(dup.id)
                ctx.delete(dup)
                report.rules += 1
            }
        }

        // Store markers: newest row per key
        let meta = fetch(KStoreMeta.self, ctx)
        for (_, rows) in Dictionary(grouping: meta, by: \.key) where rows.count > 1 {
            // The schema minimum keeps its highest value; every other key its newest row.
            let highest = rows.max { (Int($0.value) ?? 0) < (Int($1.value) ?? 0) }
            guard let keep = rows.first?.key == StoreMetaKey.minSchemaVersion ? highest : StoreMetaResolution.newest(rows)
            else { continue }
            for r in rows where r !== keep {
                ctx.delete(r)
                report.markers += 1
            }
        }

        // Saved views pointing at a removed row follow it to the kept one.
        if !remap.isEmpty {
            for v in fetch(KSavedView.self, ctx) {
                var json = v.filterJSON
                for (old, new) in remap {
                    json = json.replacingOccurrences(of: old.uuidString, with: new.uuidString)
                    json = json.replacingOccurrences(of: old.uuidString.lowercased(), with: new.uuidString)
                }
                if json != v.filterJSON { v.filterJSON = json }
            }
        }

        guard report.total > 0 else { return report }
        let wasMachine = store.isMachineWrite
        store.isMachineWrite = true
        store.saveContext()
        store.isMachineWrite = wasMachine
        if !removed.isEmpty { store.dropUndoSteps(touching: removed) }
        return report
    }

    // MARK: - Tasks

    /// Rows sharing one `id` become one: the oldest row stays (createdAt, then the content
    /// order below), takes the newest row's fields, every label any copy had, every child and
    /// attachment, and is done when any copy is done. Returns how many rows were removed and the
    /// ids that were merged.
    static func mergeSameIDTasks(_ store: TaskStore) -> (removed: Int, ids: Set<UUID>) {
        let all = store.allTasksIncludingDeleted()
        var removedCount = 0
        var ids = Set<UUID>()
        for (id, rows) in Dictionary(grouping: all, by: \.id) where rows.count > 1 {
            ids.insert(id)
            let ordered = rows.sorted(by: TaskCopyOrder.older)
            let keep = ordered[0]
            let newest = rows.max(by: TaskCopyOrder.olderContent) ?? keep
            // Every label any copy carries, collected before the newest copy's fields land.
            var labelIDs = Set<UUID>()
            var labels: [KLabel] = []
            for r in ordered { for l in r.labels ?? [] where labelIDs.insert(l.id).inserted { labels.append(l) } }
            let closed = rows.filter { KStatus.closed.contains($0.status) }
            let closedStamps = closed.compactMap(\.completedAt)
            let doneStatus = closed.max(by: TaskCopyOrder.olderContent)?.statusRaw
            if newest !== keep {
                TaskStore.TaskSnapshot(newest).apply(to: keep, resolveTask: { pid in
                    store.allTasksIncludingDeleted().first { $0.id == pid && $0 !== newest }
                })
                // The columns the undo snapshot leaves out on purpose.
                keep.triageFilledFieldsRaw = newest.triageFilledFieldsRaw
                keep.lockedFieldsRaw = newest.lockedFieldsRaw
                keep.contextJSON = newest.contextJSON
                keep.resultJSON = newest.resultJSON
                keep.triageLeaseOwner = newest.triageLeaseOwner
                keep.triageLeaseUntil = newest.triageLeaseUntil
                keep.updatedAt = newest.updatedAt
            }
            for dup in ordered.dropFirst() {
                for c in dup.children ?? [] where c.id != id {
                    c.parent = keep
                    c.parentID = keep.id
                }
                for a in dup.attachments ?? [] { a.task = keep }
            }
            if Set((keep.labels ?? []).map(\.id)) != labelIDs { keep.labels = labels }
            if !KStatus.closed.contains(keep.status), let doneStatus {
                keep.statusRaw = doneStatus
                keep.completedAt = closedStamps.min() ?? Date()
            }
            for dup in ordered.dropFirst() {
                // Detach first so the cascade on `children`/`attachments` cannot take the moved
                // rows with the duplicate.
                dup.children = []
                dup.attachments = []
                store.context.delete(dup)
                removedCount += 1
            }
        }
        return (removedCount, ids)
    }

    // MARK: - Helpers

    static func fetch<T: PersistentModel>(_ type: T.Type, _ ctx: ModelContext) -> [T] {
        (try? ctx.fetch(FetchDescriptor<T>())) ?? []
    }

    /// Groups of two or more rows sharing a non-empty key, each oldest first (createdAt, id).
    static func groups<T: DedupeOrdered>(_ rows: [T], key: (T) -> String) -> [[T]] {
        Dictionary(grouping: rows, by: key)
            .filter { !$0.key.isEmpty && !$0.key.hasPrefix("|") && $0.value.count > 1 }
            .sorted { $0.key < $1.key }
            .map { $0.value.sorted { a, b in
                if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
                return a.id.uuidString < b.id.uuidString
            } }
    }
}

/// The two fields the "oldest first" order reads.
protocol DedupeOrdered {
    var id: UUID { get }
    var createdAt: Date { get }
}
extension KArea: DedupeOrdered {}
extension KProject: DedupeOrdered {}
extension KLabel: DedupeOrdered {}
extension KRule: DedupeOrdered {}

/// Copies of one task id, ordered without the id (they share it).
enum TaskCopyOrder {
    /// Which copy is kept: the oldest createdAt; then the older content.
    static func older(_ a: KTask, _ b: KTask) -> Bool {
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return olderContent(a, b)
    }

    /// Which copy's fields count as newer: the later updatedAt; equal stamps compare the
    /// content itself, so every device picks the same copy.
    static func olderContent(_ a: KTask, _ b: KTask) -> Bool {
        if a.updatedAt != b.updatedAt { return a.updatedAt < b.updatedAt }
        if a.statusRaw != b.statusRaw { return a.statusRaw < b.statusRaw }
        if a.title != b.title { return a.title < b.title }
        if a.notes != b.notes { return a.notes < b.notes }
        return a.sortIndex < b.sortIndex
    }
}

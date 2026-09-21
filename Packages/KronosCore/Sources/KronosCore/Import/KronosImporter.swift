import Foundation
import SwiftData

/// Imports the normative `KronosExportEnvelope` (§10.1/§10.2) — the format
/// `JSONExporter` writes and the daily backup uses. This is separate from
/// `JSONImporter` (Linear import, G15), which reads the looser `SeedFile`
/// shape keyed by name/tags; the two formats serve different jobs and this
/// leaf must not touch G15's path.
///
/// Idempotent on `id`: importing the same envelope twice inserts nothing the
/// second time (I22). Native rows are keyed on `id`; `externalID` is not a
/// concept in this format (that upsert lives entirely in `JSONImporter`).
@MainActor
public final class KronosImporter {
    private let store: TaskStore

    public init(store: TaskStore) {
        self.store = store
    }

    public enum Mode {
        /// Upsert by id; newer `updatedAt` wins wholesale on a collision.
        case merge
        /// Delete every row of every model first, then insert everything.
        case replace
    }

    public struct Result {
        public var areas = 0, projects = 0, labels = 0, rules = 0
        public var savedViews = 0, tasks = 0, subtasks = 0
    }

    /// Import raw envelope JSON. Throws `StoreError.unsupportedExportVersion`
    /// for `version > 1` (§10.2); older versions would run through
    /// `ExportMigration` first, which does not exist yet (nothing has ever
    /// shipped v0).
    @discardableResult
    public func importData(_ data: Data, mode: Mode = .merge) throws -> Result {
        let envelope = try KronosExportCodec.makeDecoder().decode(KronosExportEnvelope.self, from: data)
        guard envelope.version <= 1 else {
            throw StoreError.unsupportedExportVersion(envelope.version)
        }
        return importEnvelope(envelope, mode: mode)
    }

    @discardableResult
    public func importEnvelope(_ envelope: KronosExportEnvelope, mode: Mode) -> Result {
        if mode == .replace { wipeEverything() }

        var result = Result()

        // Referential order (§10.2): areas -> projects -> labels -> rules ->
        // savedViews -> tasks -> subtasks (owned, inline with their task).
        var areasByID = existingByID(KArea.self)
        for a in envelope.areas {
            if upsert(a, into: &areasByID) { result.areas += 1 }
        }

        var projectsByID = existingByID(KProject.self)
        for p in envelope.projects {
            if upsert(p, areasByID: areasByID, into: &projectsByID) { result.projects += 1 }
        }

        var labelsByID = existingByID(KLabel.self)
        for l in envelope.labels {
            if upsert(l, into: &labelsByID) { result.labels += 1 }
        }

        var rulesByID = existingByID(KRule.self)
        for r in envelope.rules {
            if upsert(r, into: &rulesByID) { result.rules += 1 }
        }

        var viewsByID = existingByID(KSavedView.self)
        for v in envelope.savedViews {
            if upsert(v, into: &viewsByID) { result.savedViews += 1 }
        }

        var tasksByID: [UUID: KTask] = [:]
        for t in store.allTasksIncludingDeleted() { tasksByID[t.id] = t }
        for t in envelope.tasks {
            let (inserted, subtasksAdded) = upsert(t, projectsByID: projectsByID,
                                                   labelsByID: labelsByID, into: &tasksByID)
            if inserted { result.tasks += 1 }
            result.subtasks += subtasksAdded
        }

        try? store.context.save()
        return result
    }

    // MARK: - Wipe (Replace mode)

    private func wipeEverything() {
        for t in store.allTasksIncludingDeleted() { store.context.delete(t) }
        for v in fetchAll(KSavedView.self) { store.context.delete(v) }
        for r in fetchAll(KRule.self) { store.context.delete(r) }
        for l in fetchAll(KLabel.self) { store.context.delete(l) }
        for p in fetchAll(KProject.self) { store.context.delete(p) }
        for a in fetchAll(KArea.self) { store.context.delete(a) }
        try? store.context.save()
    }

    // MARK: - Per-model upsert
    //
    // "Newer updatedAt wins wholesale" (§10.2): an existing row with an
    // updatedAt >= the incoming row's is left untouched rather than
    // field-merged, because a partial merge can produce a state neither
    // device ever actually had.

    private func upsert(_ a: ExportedArea, into map: inout [UUID: KArea]) -> Bool {
        if let existing = map[a.id] {
            if existing.updatedAt < a.updatedAt { apply(a, to: existing) }
            return false
        }
        let area = KArea(name: a.name, colorHex: a.colorHex, icon: a.icon, sortIndex: a.sortIndex)
        area.id = a.id; area.createdAt = a.createdAt; area.updatedAt = a.updatedAt
        store.context.insert(area)
        map[a.id] = area
        return true
    }
    private func apply(_ a: ExportedArea, to k: KArea) {
        k.name = a.name; k.colorHex = a.colorHex; k.icon = a.icon
        k.sortIndex = a.sortIndex; k.updatedAt = a.updatedAt
    }

    private func upsert(_ p: ExportedProject, areasByID: [UUID: KArea],
                        into map: inout [UUID: KProject]) -> Bool {
        let area = p.areaID.flatMap { areasByID[$0] }
        if let existing = map[p.id] {
            if existing.updatedAt < p.updatedAt { apply(p, area: area, to: existing) }
            return false
        }
        let project = KProject(name: p.name, colorHex: p.colorHex, icon: p.icon, area: area,
                               sortIndex: p.sortIndex, emoji: p.emoji)
        project.id = p.id; project.isArchived = p.isArchived
        project.createdAt = p.createdAt; project.updatedAt = p.updatedAt
        store.context.insert(project)
        map[p.id] = project
        return true
    }
    private func apply(_ p: ExportedProject, area: KArea?, to k: KProject) {
        k.name = p.name; k.colorHex = p.colorHex; k.icon = p.icon; k.emoji = p.emoji
        k.sortIndex = p.sortIndex; k.isArchived = p.isArchived; k.area = area
        k.updatedAt = p.updatedAt
    }

    private func upsert(_ l: ExportedLabel, into map: inout [UUID: KLabel]) -> Bool {
        if let existing = map[l.id] {
            if existing.updatedAt < l.updatedAt {
                existing.name = l.name; existing.colorHex = l.colorHex; existing.updatedAt = l.updatedAt
            }
            return false
        }
        let label = KLabel(name: l.name, colorHex: l.colorHex)
        label.id = l.id; label.createdAt = l.createdAt; label.updatedAt = l.updatedAt
        store.context.insert(label)
        map[l.id] = label
        return true
    }

    private func upsert(_ r: ExportedRule, into map: inout [UUID: KRule]) -> Bool {
        if let existing = map[r.id] {
            if existing.updatedAt < r.updatedAt {
                existing.text = r.text; existing.scopeRaw = r.scope
                existing.sourceRaw = r.source; existing.isActive = r.isActive
                existing.updatedAt = r.updatedAt
            }
            return false
        }
        let scope = KRuleScope(rawValue: r.scope) ?? .all
        let source = KRuleSource(rawValue: r.source) ?? .manual
        let rule = KRule(text: r.text, scope: scope, source: source)
        rule.id = r.id; rule.isActive = r.isActive
        rule.createdAt = r.createdAt; rule.updatedAt = r.updatedAt
        store.context.insert(rule)
        map[r.id] = rule
        return true
    }

    private func upsert(_ v: ExportedSavedView, into map: inout [UUID: KSavedView]) -> Bool {
        if let existing = map[v.id] {
            if existing.updatedAt < v.updatedAt { apply(v, to: existing) }
            return false
        }
        let sortMode = KSortMode(rawValue: v.sortMode) ?? .priorityThenDue
        let groupBy = KGroupBy(rawValue: v.groupBy) ?? .none
        let view = KSavedView(name: v.name, filter: v.filter, sortMode: sortMode,
                              groupBy: groupBy, showDone: v.showDone, sortIndex: v.sortIndex,
                              sort: v.sortDescriptors ?? [])
        view.id = v.id; view.icon = v.icon
        view.createdAt = v.createdAt; view.updatedAt = v.updatedAt
        store.context.insert(view)
        map[v.id] = view
        return true
    }
    private func apply(_ v: ExportedSavedView, to k: KSavedView) {
        k.name = v.name; k.icon = v.icon; k.sortIndex = v.sortIndex
        k.filterJSON = v.filter.encodedString
        k.sortModeRaw = v.sortMode; k.groupByRaw = v.groupBy; k.showDone = v.showDone
        k.sortDescriptors = v.sortDescriptors ?? k.sortDescriptors
        k.updatedAt = v.updatedAt
    }

    /// Returns (didInsertTask, subtasksInserted).
    private func upsert(_ t: ExportedTask, projectsByID: [UUID: KProject],
                        labelsByID: [UUID: KLabel],
                        into map: inout [UUID: KTask]) -> (Bool, Int) {
        let project = t.projectID.flatMap { projectsByID[$0] }
        let labels = t.labelIDs.compactMap { labelsByID[$0] }

        if let existing = map[t.id] {
            if existing.updatedAt < t.updatedAt {
                let added = apply(t, project: project, labels: labels, to: existing)
                return (false, added)
            }
            return (false, 0)
        }
        let task = KTask(title: t.title, notes: t.notes, project: project)
        task.id = t.id
        store.context.insert(task)
        map[t.id] = task
        let added = apply(t, project: project, labels: labels, to: task)
        return (true, added)
    }

    /// Applies every scalar field plus subtasks; returns how many subtask
    /// rows were newly inserted (existing subtasks are upserted by id too).
    @discardableResult
    private func apply(_ t: ExportedTask, project: KProject?, labels: [KLabel],
                       to k: KTask) -> Int {
        k.title = t.title; k.notes = t.notes; k.firstMove = t.firstMove
        k.statusRaw = t.status; k.priorityRaw = t.priority; k.depthRaw = t.depth
        k.effortRaw = t.effort ?? KEffort.none.rawValue
        k.dread = t.dread; k.energyKindRaw = t.energyKind
        k.estimateMinutes = t.estimateMinutes
        k.dueDay = t.dueDay.flatMap(Day.parseISO)
        k.originalDueDay = t.originalDueDay.flatMap(Day.parseISO)
        k.completedAt = t.completedAt
        k.sortIndex = t.sortIndex; k.ordoIndex = t.ordoIndex
        k.deletedAt = t.deletedAt
        k.triagedAt = t.triagedAt; k.triageModel = t.triageModel
        k.triageRationale = t.triageRationale; k.triageFeedback = t.triageFeedback
        k.triageReviewedAt = t.triageReviewedAt; k.needsTriage = t.needsTriage
        k.recurrenceRule = t.recurrenceRule; k.seriesID = t.seriesID
        k.calendarEventID = t.calendarEventID
        k.externalID = t.externalID; k.source = t.source
        k.project = project; k.projectID = project?.id; k.areaID = project?.area?.id
        k.labels = labels
        k.createdAt = t.createdAt; k.updatedAt = t.updatedAt

        var existingSubs: [UUID: KSubtask] = [:]
        for s in k.subtasks ?? [] { existingSubs[s.id] = s }
        var inserted = 0
        var keep: [KSubtask] = []
        for s in t.subtasks {
            if let existing = existingSubs[s.id] {
                existing.title = s.title; existing.isDone = s.isDone
                existing.sortIndex = s.sortIndex; existing.updatedAt = s.updatedAt
                keep.append(existing)
            } else {
                let sub = KSubtask(title: s.title, sortIndex: s.sortIndex)
                sub.id = s.id; sub.isDone = s.isDone
                sub.createdAt = s.createdAt; sub.updatedAt = s.updatedAt
                sub.task = k
                store.context.insert(sub)
                keep.append(sub)
                inserted += 1
            }
        }
        // Rows dropped from the incoming subtask list are removed: subtasks
        // are owned by the task, so the export is authoritative for them
        // exactly as the Linear importer already treats them (§10.1 "owned").
        for (id, s) in existingSubs where !t.subtasks.contains(where: { $0.id == id }) {
            store.context.delete(s)
        }
        k.subtasks = keep
        return inserted
    }

    // MARK: - Helpers

    private func fetchAll<T: PersistentModel>(_ type: T.Type) -> [T] {
        (try? store.context.fetch(FetchDescriptor<T>())) ?? []
    }

    private func existingByID<T: PersistentModel>(_ type: T.Type) -> [UUID: T] where T: HasUUID {
        var map: [UUID: T] = [:]
        for row in fetchAll(T.self) { map[row.id] = row }
        return map
    }
}

extension KronosImporter.Mode: Equatable {}

// MARK: - HasUUID
//
// A tiny shared-shape protocol so `existingByID` is written once rather than
// once per model. Every model already exposes `id: UUID`; this only names
// that shape for the generic to key on.
public protocol HasUUID {
    var id: UUID { get }
}
extension KArea: HasUUID {}
extension KProject: HasUUID {}
extension KLabel: HasUUID {}
extension KRule: HasUUID {}
extension KSavedView: HasUUID {}
extension KTask: HasUUID {}

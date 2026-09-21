import Foundation
import SwiftData

/// The ONLY export path (§10.1 "one serializer, not two"; this leaf's G12).
/// Symmetric to `KronosImporter`: every field either exporter reads has a
/// matching importer write, and vice versa.
///
/// Determinism, so export -> wipe -> import -> export is byte-identical:
///  - every array is sorted by a documented total order (never fetch order,
///    which SwiftData does not guarantee across a store rebuild)
///  - `JSONEncoder` uses `.sortedKeys` (stable key order) and ISO-8601 dates
///    with fractional seconds off (`.iso8601` — same strategy on decode)
///  - `exportedAt` is the only field that is genuinely export-time; G12
///    compares payloads with that one field removed
@MainActor
public final class JSONExporter {
    private let store: TaskStore

    public init(store: TaskStore) {
        self.store = store
    }

    /// Build the envelope. `clock` is injected so a test can pin `exportedAt`
    /// without touching the wall clock.
    public func makeEnvelope(now: Date = Date()) -> KronosExportEnvelope {
        let areas = fetchAll(KArea.self).sorted(byTotalOrder: \.sortIndex, \.createdAt, \.id)
        let projects = fetchAll(KProject.self).sorted(byTotalOrder: \.sortIndex, \.createdAt, \.id)
        let labels = fetchAll(KLabel.self).sorted(byTotalOrder: \.name, \.createdAt, \.id)
        let rules = fetchAll(KRule.self).sorted(byTotalOrder: \.createdAt, \.id)
        let savedViews = fetchAll(KSavedView.self).sorted(byTotalOrder: \.sortIndex, \.createdAt, \.id)
        // Soft-deleted rows are exported too — a backup is a true backup.
        let tasks = store.allTasksIncludingDeleted().sorted(byTotalOrder: \.sortIndex, \.createdAt, \.id)

        return KronosExportEnvelope(
            exportedAt: now,
            areas: areas.map(exportArea),
            projects: projects.map(exportProject),
            labels: labels.map(exportLabel),
            rules: rules.map(exportRule),
            savedViews: savedViews.map(exportSavedView),
            tasks: tasks.map(exportTask)
        )
    }

    /// Serialize to the wire format. `.sortedKeys` + fixed array order is
    /// what makes two calls a minute apart identical except for
    /// `exportedAt` (G3).
    public func exportData(now: Date = Date()) -> Data {
        let envelope = makeEnvelope(now: now)
        // Encoding cannot fail here: every field is a plain Codable value
        // with no custom `encode(to:)` that throws.
        return (try? KronosExportCodec.makeEncoder().encode(envelope)) ?? Data()
    }

    // MARK: - Row mappers

    private func exportArea(_ a: KArea) -> ExportedArea {
        ExportedArea(id: a.id, name: a.name, colorHex: a.colorHex, icon: a.icon,
                     sortIndex: a.sortIndex, createdAt: a.createdAt, updatedAt: a.updatedAt)
    }

    private func exportProject(_ p: KProject) -> ExportedProject {
        ExportedProject(id: p.id, name: p.name, colorHex: p.colorHex, icon: p.icon,
                        emoji: p.emoji, sortIndex: p.sortIndex, isArchived: p.isArchived,
                        areaID: p.area?.id, createdAt: p.createdAt, updatedAt: p.updatedAt)
    }

    private func exportLabel(_ l: KLabel) -> ExportedLabel {
        ExportedLabel(id: l.id, name: l.name, colorHex: l.colorHex,
                      createdAt: l.createdAt, updatedAt: l.updatedAt)
    }

    private func exportRule(_ r: KRule) -> ExportedRule {
        ExportedRule(id: r.id, text: r.text, scope: r.scopeRaw, source: r.sourceRaw,
                     isActive: r.isActive, createdAt: r.createdAt, updatedAt: r.updatedAt)
    }

    private func exportSavedView(_ v: KSavedView) -> ExportedSavedView {
        ExportedSavedView(id: v.id, name: v.name, icon: v.icon, sortIndex: v.sortIndex,
                          filter: v.filter, sortMode: v.sortModeRaw,
                          sortDescriptors: v.sortDescriptors, groupBy: v.groupByRaw,
                          showDone: v.showDone, createdAt: v.createdAt, updatedAt: v.updatedAt)
    }

    private func exportSubtask(_ s: KSubtask) -> ExportedSubtask {
        ExportedSubtask(id: s.id, title: s.title, isDone: s.isDone, sortIndex: s.sortIndex,
                        createdAt: s.createdAt, updatedAt: s.updatedAt)
    }

    private func exportTask(_ t: KTask) -> ExportedTask {
        let sortedSubtasks = (t.subtasks ?? []).sorted(byTotalOrder: \.sortIndex, \.createdAt, \.id)
        let sortedLabelIDs = (t.labels ?? []).map(\.id).sorted { $0.uuidString < $1.uuidString }
        return ExportedTask(
            id: t.id, title: t.title, notes: t.notes, firstMove: t.firstMove,
            status: t.statusRaw, priority: t.priorityRaw, depth: t.depthRaw,
            effort: t.effortRaw, dread: t.dread, energyKind: t.energyKindRaw,
            estimateMinutes: t.estimateMinutes,
            dueDay: t.dueDay.map(Day.iso), originalDueDay: t.originalDueDay.map(Day.iso),
            completedAt: t.completedAt, sortIndex: t.sortIndex, ordoIndex: t.ordoIndex,
            deletedAt: t.deletedAt, triagedAt: t.triagedAt, triageModel: t.triageModel,
            triageRationale: t.triageRationale, triageFeedback: t.triageFeedback,
            triageReviewedAt: t.triageReviewedAt, needsTriage: t.needsTriage,
            recurrenceRule: t.recurrenceRule, seriesID: t.seriesID,
            calendarEventID: t.calendarEventID, externalID: t.externalID, source: t.source,
            projectID: t.projectID, labelIDs: sortedLabelIDs,
            subtasks: sortedSubtasks.map(exportSubtask),
            createdAt: t.createdAt, updatedAt: t.updatedAt)
    }

    private func fetchAll<T: PersistentModel>(_ type: T.Type) -> [T] {
        (try? store.context.fetch(FetchDescriptor<T>())) ?? []
    }
}

// MARK: - Total-order sort helper
//
// SwiftData fetch order is not guaranteed to survive a wipe+reimport, so
// every exported array is sorted by an explicit, documented key chain ending
// in `id` — the same tie-break chain used everywhere else in Core (§5.3).
//
// rev 4: widened from `private` to internal (no other change). The store's
// own `allAreas()` / `allSavedViews()` / `allProjects(includeArchived:)` owe
// their callers the SAME total order this helper defines, and a second copy
// of the chain is exactly how the two drift apart.

extension Sequence {
    /// Two-key total order, primary key then secondary; caller supplies the
    /// final `id`-string tiebreak so the comparator is generic over any pair
    /// of `Comparable` fields plus a UUID.
    func sorted<A: Comparable, B: Comparable>(
        byTotalOrder a: (Element) -> A, _ b: (Element) -> B, _ id: (Element) -> UUID
    ) -> [Element] {
        sorted { l, r in
            let (al, ar) = (a(l), a(r))
            if al != ar { return al < ar }
            let (bl, br) = (b(l), b(r))
            if bl != br { return bl < br }
            return id(l).uuidString < id(r).uuidString
        }
    }

    func sorted<A: Comparable>(byTotalOrder a: (Element) -> A, _ id: (Element) -> UUID) -> [Element] {
        sorted { l, r in
            let (al, ar) = (a(l), a(r))
            if al != ar { return al < ar }
            return id(l).uuidString < id(r).uuidString
        }
    }
}

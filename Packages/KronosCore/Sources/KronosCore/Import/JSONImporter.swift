import Foundation
import SwiftData

/// The ONLY import path in the app (L1b). Idempotent: keyed on externalID
/// (Linear) or id (generic). Because @Attribute(.unique) is forbidden under
/// CloudKit, uniqueness is enforced here with a Set-based dedupe pass.
@MainActor
public final class JSONImporter {
    private let store: TaskStore

    public init(store: TaskStore) {
        self.store = store
    }

    public struct Result {
        public var tasks = 0
        public var projects = 0
        public var areas = 0
        public var duplicates = 0
    }

    /// Import from JSON data. Returns counts. Throws on version != 1.
    @discardableResult
    public func importJSON(_ data: Data) throws -> Result {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let file = try dec.decode(SeedFile.self, from: data)
        guard file.version == 1 else {
            throw StoreError.unsupportedExportVersion(file.version)
        }
        var result = Result()

        // 1. Areas by name (idempotent).
        var areasByName: [String: KArea] = [:]
        let existingAreas = (try? store.context.fetch(FetchDescriptor<KArea>())) ?? []
        for a in existingAreas { areasByName[a.name] = a }
        for a in file.areas {
            if areasByName[a.name] == nil {
                let area = KArea(name: a.name, colorHex: a.colorHex, icon: a.icon,
                                 sortIndex: a.sortIndex)
                store.context.insert(area)
                areasByName[a.name] = area
                result.areas += 1
            }
        }

        // 2. Projects by name (idempotent).
        var projectsByName: [String: KProject] = [:]
        let existingProjects = (try? store.context.fetch(FetchDescriptor<KProject>())) ?? []
        for p in existingProjects { projectsByName[p.name] = p }
        for p in file.projects {
            if projectsByName[p.name] == nil {
                let project = KProject(name: p.name, colorHex: p.colorHex, icon: p.icon,
                                       area: p.areaName.flatMap { areasByName[$0] },
                                       sortIndex: p.sortIndex)
                store.context.insert(project)
                projectsByName[p.name] = project
                result.projects += 1
            }
        }

        // 3. Labels/tags by merge key (idempotent).
        var labelsByName: [String: KLabel] = [:]
        let existingLabels = (try? store.context.fetch(FetchDescriptor<KLabel>())) ?? []
        for l in existingLabels { labelsByName[l.mergeKey] = l }
        var incomingLabels: [(name: String, colorHex: String?)] = []
        for t in file.tags ?? [] { incomingLabels.append((t.name, t.colorHex)) }
        for l in file.labels ?? [] { incomingLabels.append((l.name, l.colorHex)) }
        for t in incomingLabels {
            let key = KLabel(name: t.name).mergeKey
            if labelsByName[key] == nil {
                let label = KLabel(name: t.name, colorHex: t.colorHex ?? "#8B8B93")
                store.context.insert(label)
                labelsByName[key] = label
            }
        }

        // 4. Tasks: idempotent on externalID first, then id.
        let existingTasks = store.allTasksIncludingDeleted()
        var byExternal: [String: KTask] = [:]
        for t in existingTasks { if let e = t.externalID { byExternal[e] = t } }
        var byID: [UUID: KTask] = [:]
        for t in existingTasks { byID[t.id] = t }

        for s in file.tasks {
            var target: KTask? = nil
            if let e = s.externalID, let found = byExternal[e] {
                target = found
                result.duplicates += 1
            } else if let i = s.id, let found = byID[i] {
                target = found
                result.duplicates += 1
            }
            if target == nil {
                let t = KTask(title: s.title,
                              notes: s.notes ?? "",
                              project: s.projectName.flatMap { projectsByName[$0] })
                store.context.insert(t)
                target = t
                result.tasks += 1
                if let e = s.externalID { byExternal[e] = t }
                if let i = s.id { byID[i] = t }
            }
            guard let t = target else { continue }
            applySeedTask(s, to: t, projectsByName: projectsByName,
                          labelsByName: labelsByName)
        }

        try store.context.save()
        return result
    }

    private func applySeedTask(_ s: SeedTask, to t: KTask,
                               projectsByName: [String: KProject],
                               labelsByName: [String: KLabel]) {
        if let p = s.priority { t.priorityRaw = p }
        if let st = s.status { t.statusRaw = st }
        if let d = s.depth { t.depthRaw = d }
        if let dr = s.dread { t.dread = dr }
        if let est = s.estimateMinutes { t.estimateMinutes = est }
        if let ek = s.energyKind { t.energyKindRaw = ek }
        if let dd = s.dueDate { t.dueDay = Day.parseISO(dd) }
        if let od = s.originalDueDay { t.originalDueDay = Day.parseISO(od) }
        if let fm = s.firstMove { t.firstMove = fm }
        if let n = s.notes { t.notes = n }
        if let sd = s.isSomeday, sd { t.statusRaw = KStatus.someday.rawValue }
        if let oi = s.ordoIndex { t.ordoIndex = oi }
        if let si = s.sortIndex { t.sortIndex = si }
        if let created = s.createdAt { t.createdAt = created }
        if let updated = s.updatedAt { t.updatedAt = updated }
        if let del = s.deletedAt { t.deletedAt = del }
        t.needsTriage = s.needsTriage ?? false
        t.externalID = s.externalID
        t.source = s.source
        if let pn = s.projectName {
            t.project = projectsByName[pn]
            t.projectID = projectsByName[pn]?.id
            t.areaID = projectsByName[pn]?.area?.id
        }
        // Tags → labels (AND semantics preserved; created above if missing).
        let tagNames = s.tags ?? []
        var resolved: [KLabel] = []
        for name in tagNames {
            if let l = labelsByName[KLabel(name: name).mergeKey] { resolved.append(l) }
        }
        if !tagNames.isEmpty { t.labels = resolved }
        // Subtasks: replace current set (import is authoritative).
        if let subs = s.subtasks {
            for old in t.subtasks ?? [] { store.context.delete(old) }
            var newSubs: [KSubtask] = []
            for (i, sub) in subs.enumerated() {
                let k = KSubtask(title: sub.title, sortIndex: sub.sortIndex ?? Double(i))
                k.isDone = sub.isDone ?? false
                k.task = t
                store.context.insert(k)
                newSubs.append(k)
            }
            t.subtasks = newSubs
        }
    }
}
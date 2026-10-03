// Part of TaskStore, split out to keep every file under
// 500 lines (pure move: no renames, no behaviour change). Projects, labels, areas, purge and house rules.
//
// Extensions in a separate file cannot see `private` members, so the undo
// plumbing these rely on (undoStack, redoStack, saveContext, mutateUndoable,
// scopeIndices, appendIndex, pushTopIndex) is internal rather than private.
// It is still not `public`: nothing outside KronosCore can reach it.

import Foundation
import SwiftData

@MainActor
extension TaskStore {
    // MARK: - Labels / area guard

    @discardableResult
    public func createProject(name: String, colorHex: String = "#8224E3",
                              icon: String? = nil, area: KArea? = nil) -> KProject {
        let p = KProject(name: name, colorHex: colorHex, icon: icon, area: area,
                         sortIndex: appendIndex(scope: .projects(area: area)))
        context.insert(p)
        saveContext()
        return p
    }

    /// Edit a project's presentation. A bare nil argument leaves that field
    /// alone; `.some(nil)` clears an optional field (icon or emoji) to nil.
    ///
    /// REGISTERS UNDO as of rev 4 (one step covering every field this call
    /// changes). It was NO UNDO through rev 3; renaming a project and having
    /// no Cmd-Z is below the bar. `icon` joined in rev 6 (§12.8) as one more
    /// field in the same undo step — every existing call site keeps
    /// compiling and simply gains the new, defaulted-nil parameter.
    public func updateProject(_ id: UUID,
                              name: String? = nil,
                              colorHex: String? = nil,
                              icon: String?? = nil,
                              emoji: String?? = nil) {
        guard let p = project(id) else { return }
        let before = (name: p.name, colorHex: p.colorHex, icon: p.icon, emoji: p.emoji)
        let after = (name: name ?? p.name,
                     colorHex: colorHex ?? p.colorHex,
                     icon: icon ?? p.icon,
                     emoji: emoji ?? p.emoji)
        guard after != before else { return }

        func apply(_ s: (name: String, colorHex: String, icon: String?, emoji: String?)) {
            p.name = s.name; p.colorHex = s.colorHex; p.icon = s.icon; p.emoji = s.emoji
            p.updatedAt = Date()
        }
        apply(after)
        pushProjectEditStep("Edit Project", p, apply: { _ in apply(after) }, revert: { _ in apply(before) })
        redoStack.removeAll()
        saveContext()
    }

    /// Non-archived projects in manual order.
    public func allProjects() -> [KProject] { allProjects(includeArchived: false) }

    /// Projects in manual order. `includeArchived: true` is what the sidebar's
    /// "Archived" disclosure and the project picker's restore path need —
    /// before rev 4 an archived project was unreachable through the store.
    public func allProjects(includeArchived: Bool) -> [KProject] {
        let all: [KProject] = (try? context.fetch(FetchDescriptor<KProject>())) ?? []
        return all
            .filter { includeArchived || !$0.isArchived }
            .sorted(byTotalOrder: \.sortIndex, \.createdAt, \.id)
    }

    func project(_ id: UUID) -> KProject? {
        allProjects(includeArchived: true).first { $0.id == id }
    }

    // MARK: - rev 4: archive / restore / move / reorder

    /// Archive a project and mirror the flag onto its tasks' `isProjectArchived`,
    /// which is the scalar `#Predicate` reads. REGISTERS UNDO — one step for
    /// the project and every task it touches, so Cmd-Z after archiving a
    /// 40-task project is one keystroke, not 41.
    public func archiveProject(_ id: UUID) { setProjectArchived(id, true, name: "Archive Project") }

    /// Un-archive a project and its tasks' mirror flag. REGISTERS UNDO (one step).
    public func restoreProject(_ id: UUID) { setProjectArchived(id, false, name: "Restore Project") }

    private func setProjectArchived(_ id: UUID, _ archived: Bool, name: String) {
        guard let p = project(id), p.isArchived != archived else { return }
        groupedUndo(name) {
            applyProjectEdit(name, p,
                             apply:  { $0.isArchived = archived },
                             revert: { $0.isArchived = !archived })
            // The mirror must follow, or a filter on `isProjectArchived`
            // keeps showing rows from a project the sidebar has hidden.
            for t in allTasksIncludingDeleted() where t.projectID == id {
                update(t.id) { $0.isProjectArchived = archived }
            }
        }
    }

    /// Move a project to another area, or to no area when `area` is nil.
    /// The project is appended to the destination's manual order, and its
    /// tasks' `areaID` mirror follows. REGISTERS UNDO (one step).
    public func moveProject(_ id: UUID, toArea area: KArea?) {
        guard let p = project(id), p.area?.id != area?.id else { return }
        let beforeAreaID = p.area?.id
        let afterAreaID = area?.id
        let beforeIdx = p.sortIndex
        let afterIdx = appendIndex(scope: .projects(area: area))
        // Areas are looked up by id when the step runs: deleting an area and undoing it brings
        // back a rebuilt row with the same id, so a captured object would be a dead one.
        groupedUndo("Move Project") {
            applyProjectEdit("Move Project", p,
                             apply:  { [weak self] in $0.area = afterAreaID.flatMap { self?.liveArea($0) }; $0.sortIndex = afterIdx },
                             revert: { [weak self] in $0.area = beforeAreaID.flatMap { self?.liveArea($0) }; $0.sortIndex = beforeIdx })
            for t in allTasksIncludingDeleted() where t.projectID == id {
                update(t.id) { $0.areaID = area?.id }
            }
        }
    }

    private func liveArea(_ id: UUID) -> KArea? { allAreas().first { $0.id == id } }

    /// Move `id` to sit directly before `before` within its own area's order,
    /// or to the end when `before` is nil. REGISTERS UNDO (one step).
    public func reorderProject(_ id: UUID, before targetID: UUID?) {
        guard let p = project(id) else { return }
        let siblings = allProjects(includeArchived: true).filter { $0.area?.id == p.area?.id }
        let plan = placement(for: id, before: targetID,
                             in: siblings.map { (id: $0.id, idx: $0.sortIndex) })
        let oldIdx = p.sortIndex
        guard oldIdx != plan.index || !plan.neighbours.isEmpty else { return }
        // One step; the neighbours move only when the gap ran out (SortIndexPlacement.swift).
        groupedUndo("Reorder Projects") {
            for n in siblings {
                guard let idx = plan.neighbours[n.id] else { continue }
                let was = n.sortIndex
                applyProjectEdit("Reorder Projects", n, apply: { $0.sortIndex = idx }, revert: { $0.sortIndex = was })
            }
            applyProjectEdit("Reorder Projects", p,
                             apply:  { $0.sortIndex = plan.index },
                             revert: { $0.sortIndex = oldIdx })
        }
    }

    /// One undo step over a project edit: apply now, revert on undo, re-apply
    /// on redo. Every project mutation above pushes this identical shape.
    private func applyProjectEdit(_ name: String, _ p: KProject,
                                  apply: @escaping (KProject) -> Void,
                                  revert: @escaping (KProject) -> Void) {
        apply(p)
        p.updatedAt = Date()
        pushProjectEditStep(name, p, apply: apply, revert: revert)
        redoStack.removeAll()
        saveContext()
    }

    /// The undo step of a project edit. Its redo applies the edit again AND arms the undo step
    /// once more, so undo after redo works (a redo that only applied left the edit un-undoable).
    private func pushProjectEditStep(_ name: String, _ p: KProject,
                                     apply: @escaping (KProject) -> Void,
                                     revert: @escaping (KProject) -> Void) {
        let touched: Set<UUID> = [p.id]
        undoStack.append(name, touching: touched) { [weak self] in
            guard let self else { return }
            revert(p)
            self.saveContext()
            self.redoStack.append(name, touching: touched) { [weak self] in
                guard let self else { return }
                apply(p)
                self.saveContext()
                self.pushProjectEditStep(name, p, apply: apply, revert: revert)
            }
        }
    }

    @discardableResult
    public func label(named name: String) -> KLabel {
        let d = FetchDescriptor<KLabel>()
        let all = (try? context.fetch(d)) ?? []
        // Both sides must be folded. Comparing a stored `mergeKey` (folded,
        // diacritics stripped) against the RAW argument meant "Žurno" never
        // matched the "Žurno" already in the store, so every call created a
        // duplicate — the opposite of what this method exists to do.
        // JSONImporter already folds both sides; this is the same rule.
        let key = KLabel(name: name).mergeKey
        if let found = all.first(where: { $0.mergeKey == key }) { return found }
        let l = KLabel(name: name)
        context.insert(l)
        let id = l.id, colorHex = l.colorHex
        pushCreateUndoStep("New Label", l) {
            let rebuilt = KLabel(name: name, colorHex: colorHex)
            rebuilt.id = id
            return rebuilt
        }
        saveContext()
        return l
    }

    public func deleteArea(_ area: KArea) throws {
        guard (area.projects ?? []).isEmpty else {
            throw StoreError.areaHasProjects(count: area.projects?.count ?? 0)
        }
        let id = area.id, name = area.name, colorHex = area.colorHex
        let icon = area.icon, idx = area.sortIndex, createdAt = area.createdAt
        deleteUndoable("Delete Area", area) {
            let rebuilt = KArea(name: name, colorHex: colorHex, icon: icon, sortIndex: idx)
            rebuilt.id = id
            rebuilt.createdAt = createdAt
            return rebuilt
        }
    }

    // MARK: - Save failures

    /// Where emergency and pre-purge exports go: `<store dir>/Backups`. An in-memory store
    /// (tests) has none unless a test names one, so it can never write into the person's folder.
    var backupsDirectory: URL? {
        if let backupsDirectoryOverride { return backupsDirectoryOverride }
        if container.configurations.contains(where: \.isStoredInMemoryOnly) { return nil }
        return KronosEnv.storeDirectory.appendingPathComponent("Backups", isDirectory: true)
    }

    private static func fileStamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date).replacingOccurrences(of: ":", with: "")
    }

    func noteSaveSucceeded() {
        guard lastSaveError != nil else { return }
        lastSaveError = nil
        saveFailureNotified = false
    }

    /// A failed save: keep the error, leave the context dirty (the next save retries every
    /// pending change), post `.kronosSaveFailed` once per burst of failures, and write the whole
    /// store as JSON next to the backups so nothing typed since the last good save is lost.
    func noteSaveFailed(_ error: Error) {
        lastSaveError = error
        let now = Date()
        // First failure of a burst writes at once; later ones refresh the file at most once a minute.
        let due = lastEmergencyWrite.map { now.timeIntervalSince($0) >= 60 } ?? true
        var emergency: URL?
        if due, let dir = backupsDirectory {
            let url = dir.appendingPathComponent("emergency-\(Self.fileStamp(now)).json")
            if (try? BackupFile.write(JSONExporter(store: self).makeEnvelope(now: now), to: url)) != nil {
                lastEmergencyWrite = now
                emergency = url
            }
        }
        guard !saveFailureNotified else { return }
        saveFailureNotified = true
        var info: [String: Any] = ["error": String(describing: error)]
        if let emergency { info["emergencyBackup"] = emergency.path }
        NotificationCenter.default.post(name: .kronosSaveFailed, object: self, userInfo: info)
    }

    // MARK: - Purge (30-day, run by DayChangeCoordinator)

    /// Defaults key: the latest `now` this store (or the day-change coordinator) has seen,
    /// whole seconds since 1970. A purge whose `now` is below it runs on a clock set back.
    public static let purgeClockMarkKey = "kronos.purge.lastSeenNow"

    /// Where the clock mark lives: the hermetic-aware defaults for a real store, a private
    /// in-memory fixture for an in-memory store (tests never share a mark through `.standard`).
    var purgeClockMark: DayKeyValueStore {
        if let purgeClockMarkOverride { return purgeClockMarkOverride }
        let store: DayKeyValueStore = container.configurations.contains(where: \.isStoredInMemoryOnly)
            ? FixtureKeyValueStore() : KronosEnv.defaults
        purgeClockMarkOverride = store
        return store
    }

    /// Hard-deletes rows soft-deleted more than `days` ago. Two guards protect against a wrong
    /// clock and a wrong delete: it does nothing when `now` is behind the latest `now` seen
    /// before (the clock was set back, so every row would look younger or older than it is), and
    /// it writes the whole store to `Backups/pre-purge-<UTC>.json` first and purges nothing when
    /// that file cannot be written.
    public func purgeDeletedOlderThan(days: Int = 30, now: Date = Date()) {
        let nowSeconds = Int(now.timeIntervalSince1970)
        let mark = purgeClockMark
        let seen = mark.integer(forKey: Self.purgeClockMarkKey)
        if seen > 0, nowSeconds < seen { return }
        mark.setInteger(nowSeconds, forKey: Self.purgeClockMarkKey)

        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        let doomed = allTasksIncludingDeleted().filter { ($0.deletedAt ?? now) < cutoff }
        guard !doomed.isEmpty else { return }
        if let dir = backupsDirectory {
            let url = dir.appendingPathComponent("pre-purge-\(Self.fileStamp(now)).json")
            do { try BackupFile.write(JSONExporter(store: self).makeEnvelope(now: now), to: url) } catch { return }
        }
        for t in doomed { context.delete(t) }
        saveContext()
    }

    // MARK: - Rules (house rules consumed by triage and Impuls)

    public func allRules(includeInactive: Bool = false) -> [KRule] {
        let d = FetchDescriptor<KRule>()
        let all = (try? context.fetch(d)) ?? []
        return all
            .filter { includeInactive || $0.isActive }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    /// NO UNDO: rules are managed in their own list, not with Cmd-Z. A rule that already exists
    /// (same text up to case, accents and spacing, same scope) is returned as it is instead of
    /// adding a second copy (see `addRule(text:scope:source:active:)`).
    @discardableResult
    public func addRule(text: String,
                        scope: KRuleScope = .all,
                        source: KRuleSource = .manual) -> KRule {
        addRule(text: text, scope: scope, source: source, active: true).rule
    }

}

import Foundation
import SwiftData

public enum StoreError: Error, LocalizedError {
    case areaHasProjects(count: Int)
    case ruleCapReached(limit: Int)
    case unsupportedExportVersion(Int)
    case taskNotFound(UUID)

    // GAP (known, not fixed here): this hardcoded English
    // `errorDescription` is unreachable from the UI today — no Kronos/** call site reads
    // `.localizedDescription` on any of these (deleteArea, which throws .areaHasProjects, has
    // no caller either; catch blocks that could see this error all show a generic catalog
    // string instead, e.g. settings.data.import.failed). Core should return a
    // structured reason (this enum already is one) and the app should render it from the
    // catalog with the associated values — but since nothing today actually surfaces this
    // English text to a user, restructuring the call chain for a path proven unreachable would
    // be speculative work with no observable effect. If a future change wires deleteArea or the
    // export/import error paths into the UI, render from the catalog at that call site: the
    // catalog's `error.area.hasprojects.count` (an .xcstrings plural `variations` entry, which
    // DOES resolve through a literal `String(localized:)` — see KPlural.swift's header) already
    // has the strings for the first case.
    public var errorDescription: String? {
        switch self {
        case .areaHasProjects(let c):  return "Move \(c) projects first"
        case .ruleCapReached(let l):   return "Deactivate one to add (cap \(l))"
        case .unsupportedExportVersion(let v): return "This backup was made by a newer version of Kronos (v\(v))."
        case .taskNotFound(let id):    return "Task \(id) not found"
        }
    }
}

/// The ONLY mutation surface UI leaves may call. Every mutation registers
/// undo (wrapped in an explicit undo group) unless it is a `…_noUndo`
/// variant reserved for MCP and triage writes (build-14).
@MainActor
public final class TaskStore: TaskStoring {
    public let container: ModelContainer
    public let context: ModelContext
    public let undoManager: UndoManager

    public init(inMemory: Bool = false) throws {
        let schema = Schema(versionedSchema: KronosSchemaV1.self)
        let config: ModelConfiguration
        if inMemory {
            config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true,
                                         cloudKitDatabase: KronosStore.cloudKitDatabaseSetting)
        } else {
            config = ModelConfiguration(schema: schema, url: KronosStore.storeURL(),
                                         cloudKitDatabase: KronosStore.cloudKitDatabaseSetting)
        }
        self.container = try ModelContainer(for: schema,
                                            migrationPlan: KronosMigrationPlan.self,
                                            configurations: [config])
        self.context = container.mainContext
        let um = UndoManager()
        um.groupsByEvent = false
        self.undoManager = um
        context.undoManager = um
    }

    // MARK: - Fetch helpers

    /// Soft-deleted tasks are excluded from every fetch.
    public var livePredicate: Predicate<KTask> {
        #Predicate<KTask> { $0.deletedAt == nil }
    }

    public func allTasks() -> [KTask] {
        let d = FetchDescriptor<KTask>(predicate: livePredicate)
        return (try? context.fetch(d)) ?? []
    }

    /// Includes soft-deleted rows (import/export/dedupe paths).
    public func allTasksIncludingDeleted() -> [KTask] {
        let d = FetchDescriptor<KTask>()
        return (try? context.fetch(d)) ?? []
    }

    // `task(_:)` and `taskIncludingDeleted(_:)`: see TaskStore+Lookups.swift (predicate fetch,
    // fetchLimit = 1, moved out because this file is at the 500-line cap).

    /// Mutation path that works even on soft-deleted rows.
    public func updateIncludingDeleted(_ id: UUID, _ mutate: (KTask) -> Void) {
        mutateUndoable("Edit", id, mutate)
    }

    // MARK: - Undo plumbing
    //
    // SwiftData's automatic UndoManager registration proved unreliable for
    // scalar writes (undo reports success, the row keeps the new value), so
    // Kronos registers its own inverse closures over a full field snapshot.
    // One closure == one undo step, exactly like one explicit group.

    private struct TaskSnapshot {
        var title: String, notes: String, firstMove: String?
        var statusRaw: Int, priorityRaw: Int, depthRaw: Int, effortRaw: Int, dread: Bool
        var energyKindRaw: Int?, estimateMinutes: Int?
        var dueDay: Int?, originalDueDay: Int?, completedAt: Date?
        var sortIndex: Double, ordoIndex: Double?
        var deletedAt: Date?, needsTriage: Bool
        var project: KProject?
        /// The scalar mirrors `#Predicate` reads. They must be snapshotted
        /// alongside `project`: restoring the relationship alone left a row
        /// claiming, say, `isProjectArchived == true` after its project's
        /// archiving had been undone, so filters kept hiding it.
        var projectID: UUID?, areaID: UUID?, isProjectArchived: Bool
        var recurrenceRule: String?, seriesID: UUID?
        var labels: [KLabel]
        var subtaskStates: [(id: UUID, title: String, isDone: Bool, sortIndex: Double)]

        init(_ t: KTask) {
            title = t.title; notes = t.notes; firstMove = t.firstMove
            statusRaw = t.statusRaw; priorityRaw = t.priorityRaw
            depthRaw = t.depthRaw; effortRaw = t.effortRaw; dread = t.dread
            energyKindRaw = t.energyKindRaw; estimateMinutes = t.estimateMinutes
            dueDay = t.dueDay; originalDueDay = t.originalDueDay
            completedAt = t.completedAt
            sortIndex = t.sortIndex; ordoIndex = t.ordoIndex
            deletedAt = t.deletedAt; needsTriage = t.needsTriage
            project = t.project
            projectID = t.projectID; areaID = t.areaID
            isProjectArchived = t.isProjectArchived
            recurrenceRule = t.recurrenceRule; seriesID = t.seriesID
            labels = t.labels ?? []
            subtaskStates = (t.subtasks ?? []).map { ($0.id, $0.title, $0.isDone, $0.sortIndex) }
        }

        func apply(to t: KTask) {
            t.title = title; t.notes = notes; t.firstMove = firstMove
            t.statusRaw = statusRaw; t.priorityRaw = priorityRaw
            t.depthRaw = depthRaw; t.effortRaw = effortRaw; t.dread = dread
            t.energyKindRaw = energyKindRaw; t.estimateMinutes = estimateMinutes
            t.dueDay = dueDay; t.originalDueDay = originalDueDay
            t.completedAt = completedAt
            t.sortIndex = sortIndex; t.ordoIndex = ordoIndex
            t.deletedAt = deletedAt; t.needsTriage = needsTriage
            t.project = project
            t.projectID = projectID; t.areaID = areaID
            t.isProjectArchived = isProjectArchived
            t.recurrenceRule = recurrenceRule; t.seriesID = seriesID
            t.labels = labels
            for state in subtaskStates {
                if let s = (t.subtasks ?? []).first(where: { $0.id == state.id }) {
                    s.title = state.title; s.isDone = state.isDone; s.sortIndex = state.sortIndex
                }
            }
        }
    }

    // internal, not private: the extensions in TaskStore+*.swift need these.
    var undoStack: [(name: String, run: () -> Void)] = []
    var redoStack: [(name: String, run: () -> Void)] = []
    /// True while a machine write (MCP, import, night sweep) runs through `withoutUndo`:
    /// those must not announce a completion (no sound when Claude ticks a task).
    var isMachineWrite = false

    func saveContext() {
        context.processPendingChanges()
        if context.hasChanges { try? context.save() }
    }

    public func undo() {
        guard let step = undoStack.popLast() else { return }
        step.run()
        saveContext()
    }

    public func redo() {
        guard let step = redoStack.popLast() else { return }
        step.run()
        saveContext()
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// How many undo steps are pending. Exposed so a test can assert that a
    /// `…NoUndo` write added none — `canUndo` alone cannot tell "no step was
    /// pushed" from "a step was pushed on top of an existing one".
    public var undoDepth: Int { undoStack.count }

    // MARK: - Grouped undo (rev 4)
    //
    // Several mutations that are ONE user action must be ONE Cmd-Z. Before
    // rev 4 the only consumer of this idea (RecurrenceSpawner) reached into
    // `undoStack`/`redoStack` to pop, merge and push back; that worked but
    // coupled the spawner to the stack's shape. `groupedUndo` is the same
    // idea expressed once, here.
    //
    // Mechanics: record the stack depth, run the body, then collapse every
    // step the body pushed into one. The group's UNDO runs the children in
    // reverse order (last mutation reversed first) and harvests the redo each
    // child pushes as it runs — `mutateUndoable` only creates a child's redo
    // closure at undo time, so harvesting must happen there, not up front.
    // The composed REDO then replays them in forward order.

    private var groupDepth = 0

    /// Collapse every mutation performed inside `body` into ONE undo step and
    /// ONE redo step, named `name`.
    ///
    /// REGISTERS UNDO: exactly one step, or none when `body` mutated nothing.
    /// Nesting is safe — an inner call joins the outer group rather than
    /// pushing a step of its own. `…NoUndo` callers may wrap this freely: the
    /// group pushes at most one step, which their truncation then removes.
    public func groupedUndo(_ name: String, _ body: () -> Void) {
        // A nested call is already inside a group; let the outermost collapse.
        guard groupDepth == 0 else { body(); return }

        let base = undoStack.count
        let redoBefore = redoStack
        groupDepth += 1
        body()
        groupDepth -= 1

        guard undoStack.count > base else {
            // A body that mutated nothing pushes nothing — and must not
            // destroy a pending redo either, since nothing happened.
            redoStack = redoBefore
            return
        }
        let children = Array(undoStack[base...])
        undoStack.removeLast(undoStack.count - base)

        undoStack.append((name, { [weak self] in
            guard let self else { return }
            // Reverse order: the last mutation is undone first.
            var childRedos: [() -> Void] = []
            for child in children.reversed() {
                let redoDepth = self.redoStack.count
                child.run()
                // Harvest whatever redo the child pushed while undoing.
                if self.redoStack.count > redoDepth {
                    let pushed = Array(self.redoStack[redoDepth...]).map(\.run)
                    self.redoStack.removeLast(self.redoStack.count - redoDepth)
                    childRedos.append(contentsOf: pushed)
                }
            }
            // childRedos is in undo order (reverse); replay forward.
            let forward = childRedos.reversed().map { $0 }
            self.redoStack.append((name, { [weak self] in
                guard let self else { return }
                for redo in forward { redo() }
                self.saveContext()
            }))
            self.saveContext()
        }))
        redoStack.removeAll()
        saveContext()
    }

    // MARK: - Insert/delete undo steps
    //
    // SwiftData will NOT bring back a model that was deleted once the delete
    // has been saved: `delete(x); save(); insert(x); save()` leaves the row
    // gone for good, and so does a delete that any LATER save flushes
    // (measured on this schema, 2026-09-19; it is the same trap
    // `RecurrenceSpawner` documents for spawned tasks). Since undo steps are
    // separated in time by arbitrary other saves, "delete now, re-insert on
    // redo" cannot be made reliable at all.
    //
    // The row's FIELDS stay readable after the delete, though, so redo
    // REBUILDS an equivalent row from a caller-supplied factory instead of
    // resurrecting the dead instance. The factory reproduces the row's
    // identity (`id`) and contents, which is what every reader — fetches,
    // exports, relationships by id — actually compares on.

    /// Push an undo step that HIDES `task` (soft delete) and a redo that
    /// brings it back — the undo shape for "this task was just created by
    /// something other than the user", such as a spawned recurrence.
    ///
    /// Soft delete rather than `context.delete`, for the reason spelled out
    /// on `deleteUndoable`: a deleted-and-saved model cannot be re-inserted.
    /// A hidden row is invisible to every `allTasks()` reader, which is what
    /// "never existed" means to every UI surface.
    func pushSoftDeleteUndoStep(_ name: String, _ task: KTask) {
        undoStack.append((name, { [weak self] in
            guard let self else { return }
            task.deletedAt = Date()
            self.saveContext()
            self.redoStack.append((name, { [weak self] in
                guard let self else { return }
                task.deletedAt = nil
                self.saveContext()
            }))
        }))
        redoStack.removeAll()
    }

    /// Delete `model` now, and push an undo step that rebuilds it.
    ///
    /// `rebuild` must return a NEW model carrying the original's `id` and
    /// fields. Because each rebuild produces a fresh instance, the step
    /// re-arms itself against that instance, so undo/redo can be pressed any
    /// number of times.
    func deleteUndoable<T: PersistentModel>(_ name: String,
                                            _ model: T,
                                            rebuild: @escaping () -> T) {
        context.delete(model)
        saveContext()
        undoStack.append((name, { [weak self] in
            guard let self else { return }
            let fresh = rebuild()
            self.context.insert(fresh)
            self.saveContext()
            self.redoStack.append((name, { [weak self] in
                guard let self else { return }
                self.deleteUndoable(name, fresh, rebuild: rebuild)
            }))
        }))
        redoStack.removeAll()
    }

    /// Push the undo step for "this row was just created": undo deletes it,
    /// redo rebuilds it. The inverse of `deleteUndoable`, sharing its rebuild
    /// contract.
    func pushCreateUndoStep<T: PersistentModel>(_ name: String,
                                                _ model: T,
                                                rebuild: @escaping () -> T) {
        undoStack.append((name, { [weak self] in
            guard let self else { return }
            self.deleteUndoable(name, model, rebuild: rebuild)
            // deleteUndoable arms an undo step for the delete it just did;
            // here the delete IS the undo, so that step becomes our redo.
            if let step = self.undoStack.popLast() {
                self.redoStack.append(step)
            }
        }))
        redoStack.removeAll()
    }

    /// Mutate a task inside an undoable step: captures the before-snapshot
    /// and the after-snapshot, so undo restores "before" and redo replays
    /// "after". Both directions are snapshot restores, never inverse logic.
    ///
    /// This is the ONE place every mutation — undoable (`update`) and
    /// no-undo (`updateNoUndo`/MCP, `applyTriage`, `snooze`) alike — passes
    /// through (see `TaskStore+NoUndo.swift`'s `updateNoUndo` ->
    /// `updateIncludingDeleted` -> here). That makes it the right spot for
    /// the automatic status rule (an open, not-waiting task follows its due day: set a due
    /// day and it becomes `.todo`, clear it and it becomes `.someday`) instead of a guard
    /// duplicated in every caller.
    func mutateUndoable(_ name: String, _ id: UUID, _ mutate: (KTask) -> Void) {
        guard let t = taskIncludingDeleted(id) else { return }
        let before = TaskSnapshot(t)
        mutate(t)
        applyAutomaticStatusRule(to: t, dueDayBefore: before.dueDay)
        t.updatedAt = Date()
        let after = TaskSnapshot(t)
        undoStack.append((name, { [weak self] in
            guard let self, let live = self.taskIncludingDeleted(id) else { return }
            before.apply(to: live)
            self.redoStack.append((name, { [weak self] in
                guard let self, let live2 = self.taskIncludingDeleted(id) else { return }
                after.apply(to: live2)
            }))
        }))
        redoStack.removeAll()
        saveContext()
    }

    /// The rule: an open, not-waiting task follows its due day
    /// automatically — due day SET -> `.todo`, due day CLEARED -> `.someday`. Waiting and
    /// closed (done/canceled) statuses never auto-change (only a manual status pick moves a
    /// task in or out of `.waiting`, and completion/cancellation owns itself). Someday is
    /// never a manual switch any more (`InspectorStatusSection`'s toggle now reads/writes
    /// `.waiting`), so this is the ONLY writer of `.someday` for an existing task — matching
    /// `ListScopeDefaults.apply` (QuickAdd/ListScopeDefaults.swift), which already applies
    /// the identical rule at CREATE time.
    ///
    /// Fires only when THIS mutation actually changed the due day — renaming an undated
    /// todo task, or any edit that leaves `dueDay` untouched, must never move its status.
    /// No migration: an existing task's status is left alone until its own due day next
    /// changes (brief: "NO migration of existing tasks at launch").
    private func applyAutomaticStatusRule(to t: KTask, dueDayBefore: Int?) {
        guard t.dueDay != dueDayBefore else { return }
        guard KStatus.open.contains(t.status), t.status != .waiting else { return }
        if t.dueDay != nil {
            if t.status != .todo { t.status = .todo }
        } else {
            if t.status != .someday { t.status = .someday; t.ordoIndex = nil }
        }
    }

    // MARK: - Index arithmetic (§5.2)

    public enum Scope {
        case tasksGlobal
        case ordo
        case subtasks(KTask)
        case projects(area: KArea?)
        case areas
        case savedViews
    }

    // `.tasksGlobal` and `.ordo` are backed by the whole `KTask` table and are the two scopes
    // `appendIndex`/`pushTopIndex` hit on every task create/reorder — see
    // TaskStore+Lookups.swift's `taskExtremeSortIndex`/`taskExtremeOrdoIndex` for the O(1)-ish
    // (sorted fetch, fetchLimit = 1) replacement of the O(n) `allTasks().map(\.sortIndex).max()`
    // this switch used to do for those two cases. The remaining scopes are already bounded by a
    // much smaller count (one task's own subtasks, one area's own projects, all areas, all
    // saved views — never thousands of rows) and keep the array form.
    func scopeIndices(_ scope: Scope) -> [Double] {
        switch scope {
        case .tasksGlobal:
            return allTasks().map(\.sortIndex)
        case .ordo:
            return allTasks().compactMap(\.ordoIndex)
        case .subtasks(let t):
            return (t.subtasks ?? []).map(\.sortIndex)
        case .projects(let area):
            return (area?.projects ?? []).map(\.sortIndex)
        case .areas:
            let d = FetchDescriptor<KArea>()
            return ((try? context.fetch(d)) ?? []).map(\.sortIndex)
        case .savedViews:
            let d = FetchDescriptor<KSavedView>()
            return ((try? context.fetch(d)) ?? []).map(\.sortIndex)
        }
    }

    func appendIndex(scope: Scope) -> Double {
        switch scope {
        case .tasksGlobal: return (taskExtremeSortIndex(max: true) ?? -1024) + 1024
        case .ordo: return (taskExtremeOrdoIndex(max: true) ?? -1024) + 1024
        default: return (scopeIndices(scope).max() ?? -1024) + 1024
        }
    }

    func pushTopIndex(scope: Scope) -> Double {
        switch scope {
        case .tasksGlobal: return (taskExtremeSortIndex(max: false) ?? 1024) - 1024
        case .ordo: return (taskExtremeOrdoIndex(max: false) ?? 1024) - 1024
        default: return (scopeIndices(scope).min() ?? 1024) - 1024
        }
    }

    /// The index that puts `moving` directly before `target` in an ordered
    /// list, or at the end when `target` is nil — the mean of the target and
    /// the row above it, §5.2's between-index rule.
    ///
    /// `rows` must already be in display order. The moving row is excluded
    /// from both the neighbour search and the append maximum: its own index
    /// is about to change, so using it as one half of the mean would place
    /// the row on top of itself.
    func betweenIndex(for moving: UUID, before target: UUID?,
                      in rows: [(id: UUID, idx: Double)]) -> Double {
        guard let target, target != moving,
              let i = rows.firstIndex(where: { $0.id == target }) else {
            return (rows.filter { $0.id != moving }.map(\.idx).max() ?? -1024) + 1024
        }
        let targetIdx = rows[i].idx
        guard let above = rows[..<i].last(where: { $0.id != moving }) else {
            return targetIdx - 1024
        }
        return (above.idx + targetIdx) / 2
    }

}

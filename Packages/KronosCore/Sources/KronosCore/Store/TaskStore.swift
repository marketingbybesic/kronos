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

    public convenience init(inMemory: Bool = false) throws {
        try self.init(storeURL: inMemory ? nil : KronosStore.storeURL())
    }

    /// Opens the store file at `storeURL` (nil: in memory). The app passes the one location
    /// `KronosStore` decides; tests and tools open a copy or a second handle on the same file.
    public init(storeURL: URL?) throws {
        let schema = Schema(versionedSchema: KronosSchemaV2.self)
        let config: ModelConfiguration
        if let storeURL {
            config = ModelConfiguration(schema: schema, url: storeURL,
                                         cloudKitDatabase: KronosStore.cloudKitDatabaseSetting)
        } else {
            config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true,
                                         cloudKitDatabase: KronosStore.cloudKitDatabaseSetting)
        }
        self.container = try ModelContainer(for: schema,
                                            migrationPlan: KronosMigrationPlan.self,
                                            configurations: [config])
        self.context = container.mainContext
    }

    // MARK: - Fetch helpers

    /// Every live row, subtasks included. Lookups and sweeps only — never a list.
    public var livePredicate: Predicate<KTask> {
        #Predicate<KTask> { $0.deletedAt == nil }
    }

    /// The list predicate: live AND top-level. Subtasks are never rows of their own in a
    /// list, count, Today, ORDO, triage, menu bar or MCP list; they appear under their parent.
    public static var topLevelPredicate: Predicate<KTask> {
        #Predicate<KTask> { $0.deletedAt == nil && $0.parentID == nil }
    }

    /// Live top-level tasks — what every list, count and scope reads.
    public func allTasks() -> [KTask] {
        let d = FetchDescriptor<KTask>(predicate: Self.topLevelPredicate)
        return (try? context.fetch(d)) ?? []
    }

    /// Live tasks INCLUDING subtasks: search, dependency edges, sweeps that must touch every
    /// row. Never use it to build a list (a gate keeps its callers to an allowlist).
    public func allTasksIncludingSubtasks() -> [KTask] {
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
    // Kronos registers its own inverse closures over a field snapshot (`TaskSnapshot`, see
    // TaskStore+Mutations.swift). One closure == one undo step, exactly like one explicit group.
    // The snapshot is diffed: a step restores only the fields its own mutation changed.

    /// The undo stack never holds more than this many steps; the oldest fall off first.
    public static let undoLimit = 200

    // internal, not private: the extensions in TaskStore+*.swift need these.
    var undoStack: [UndoEntry] = [] {
        didSet { trimUndoStack() }
    }
    var redoStack: [UndoEntry] = []
    /// While above zero the cap is not applied: a group or a machine write inspects and
    /// truncates the stack by index, and a trim in the middle would shift those indices.
    var undoTrimSuspension = 0
    /// True while a machine write (MCP, import, night sweep) runs through `withoutUndo`:
    /// those must not announce a completion (no sound when Claude ticks a task).
    var isMachineWrite = false
    var groupDepth = 0

    /// The error of the last failed save; nil again after the next successful one.
    public internal(set) var lastSaveError: Error?
    // Save-failure bookkeeping (see TaskStore+Projects.swift). The overrides are the test seams:
    // an injected failing save, the folder for emergency/pre-purge files, the clock mark store.
    var saveFailureNotified = false
    var lastEmergencyWrite: Date?
    var saveOverride: (() throws -> Void)?
    var backupsDirectoryOverride: URL?
    var purgeClockMarkOverride: DayKeyValueStore?

    func trimUndoStack() {
        guard undoTrimSuspension == 0, undoStack.count > Self.undoLimit else { return }
        undoStack.removeFirst(undoStack.count - Self.undoLimit)
    }

    /// Runs `body` with the undo cap suspended, then applies it once.
    func withUndoTrimSuspended<T>(_ body: () -> T) -> T {
        undoTrimSuspension += 1
        defer { undoTrimSuspension -= 1; trimUndoStack() }
        return body()
    }

    /// Save, and surface a failure instead of swallowing it: `lastSaveError`, one
    /// `.kronosSaveFailed` per burst of failures, an emergency JSON export. The context
    /// stays dirty, so the next save retries every pending change.
    func saveContext() {
        context.processPendingChanges()
        guard context.hasChanges else { return }
        do {
            if let saveOverride { try saveOverride() } else { try context.save() }
            noteSaveSucceeded()
        } catch {
            noteSaveFailed(error)
        }
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

    /// Drops every pending undo and redo step; the data is untouched. The live UI test calls it
    /// between steps so a step that counts undo depth never starts at the cap (where a push
    /// cannot change the depth). The app itself never calls it.
    public func clearUndoHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
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

        // The cap waits until the children are collapsed: `base` indexes into the stack.
        undoTrimSuspension += 1
        defer { undoTrimSuspension -= 1; trimUndoStack() }
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
        let touched = UndoEntry.union(children)

        undoStack.append(UndoEntry(name, touching: touched) { [weak self] in
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
            self.redoStack.append(UndoEntry(name, touching: touched) { [weak self] in
                guard let self else { return }
                for redo in forward { redo() }
                self.saveContext()
            })
            self.saveContext()
        })
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
        let touched: Set<UUID> = [task.id]
        undoStack.append(name, touching: touched) { [weak self] in
            guard let self else { return }
            task.deletedAt = Date()
            self.saveContext()
            self.redoStack.append(name, touching: touched) { [weak self] in
                guard let self else { return }
                task.deletedAt = nil
                self.saveContext()
            }
        }
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
        let touched = Self.undoTag(model)
        context.delete(model)
        saveContext()
        undoStack.append(UndoEntry(name, touching: touched) { [weak self] in
            guard let self else { return }
            let fresh = rebuild()
            self.context.insert(fresh)
            self.saveContext()
            self.redoStack.append(UndoEntry(name, touching: touched) { [weak self] in
                guard let self else { return }
                self.deleteUndoable(name, fresh, rebuild: rebuild)
            })
        })
        redoStack.removeAll()
    }

    /// Push the undo step for "this row was just created": undo deletes it,
    /// redo rebuilds it. The inverse of `deleteUndoable`, sharing its rebuild
    /// contract.
    func pushCreateUndoStep<T: PersistentModel>(_ name: String,
                                                _ model: T,
                                                rebuild: @escaping () -> T) {
        undoStack.append(UndoEntry(name, touching: Self.undoTag(model)) { [weak self] in
            guard let self else { return }
            self.deleteUndoable(name, model, rebuild: rebuild)
            // deleteUndoable arms an undo step for the delete it just did;
            // here the delete IS the undo, so that step becomes our redo.
            if let step = self.undoStack.popLast() {
                self.redoStack.append(step)
            }
        })
        redoStack.removeAll()
    }

    /// Mutate a task inside an undoable step. Before and after are snapshotted and DIFFED: the
    /// step remembers which fields this mutation changed, undo writes back only those fields
    /// (so a machine write to another field between the edit and Cmd-Z survives), redo replays
    /// only those too. A mutation that changes nothing pushes no step, leaves the redo stack
    /// alone and does not bump `updatedAt`.
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
        let after = TaskSnapshot(t)
        let changed = after.changedFields(from: before)
        // Fields outside the snapshot may still have been written: save, but no undo step.
        guard !changed.isEmpty else { saveContext(); return }
        t.updatedAt = Date()
        undoStack.append(name, touching: [id]) { [weak self] in
            guard let self, let live = self.taskIncludingDeleted(id) else { return }
            before.apply(to: live, only: changed, resolveTask: { self.taskIncludingDeleted($0) })
            live.updatedAt = Date()
            self.redoStack.append(name, touching: [id]) { [weak self] in
                guard let self, let live2 = self.taskIncludingDeleted(id) else { return }
                after.apply(to: live2, only: changed, resolveTask: { self.taskIncludingDeleted($0) })
                live2.updatedAt = Date()
            }
        }
        redoStack.removeAll()
        saveContext()
    }

    /// The rule: an open, not-waiting task follows its due day
    /// automatically — due day SET -> `.todo`, due day CLEARED -> `.someday`. Waiting and
    /// closed (done/canceled) statuses never auto-change (only a manual status pick moves a
    /// task in or out of `.waiting`, and completion/cancellation owns itself). Someday is
    /// never a manual switch any more (`InspectorStatusSection`'s toggle now reads/writes
    /// `.waiting`), so this is the ONLY writer of `.someday` for an existing task. A task
    /// CREATED without a date is different: it stays an open `.todo` in the Inbox
    /// (`ListScopeDefaults.apply`); only clearing a date later moves it to Someday.
    ///
    /// Fires only when THIS mutation actually changed the due day — renaming an undated
    /// todo task, or any edit that leaves `dueDay` untouched, must never move its status.
    /// No migration: an existing task's status is left alone until its own due day next
    /// changes (brief: "NO migration of existing tasks at launch").
    func applyAutomaticStatusRule(to t: KTask, dueDayBefore: Int?) {
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
            return (t.children ?? []).map(\.sortIndex)
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
}

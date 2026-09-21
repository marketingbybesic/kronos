// Part of the frozen contract surface. See Contracts.swift.
//
// `createProject`'s `icon` parameter is `String?` (matching `KProject.icon`, see
// Contracts.swift), and `updateProject` takes an `icon: String??` parameter, joining the
// existing `emoji: String??` pattern: a bare `nil` argument leaves the icon unchanged,
// `.some(nil)` clears it back to the plain colour dot. Both parameters are defaulted in the
// concrete `TaskStore`, so a call site that omits `icon` still compiles.
//
// This surface evolves additively — nothing declared earlier is renamed or removed, so
// existing call sites keep compiling as the store gains new mutation methods.
//
// The complete mutation surface. EVERY write goes through here: a gate greps
// view files for `modelContext.insert` and `.mainContext.` and fails the
// build on a hit, because that is how undo stays complete.
//
// Undo is a snapshot mechanism, not UndoManager. Each mutation captures a
// before- and an after-snapshot of the affected rows and pushes one closure
// pair; one closure is one undo step, exactly like one explicit undo group.
// SwiftData's automatic registration proved unreliable for scalar writes —
// undo reported success while the row kept the new value.
//
// The `…NoUndo` variants are reserved for MCP and AI triage. An MCP client can write hundreds
// of rows in a batch; if each one pushed an undo step, the user's own last action would be
// buried under machine edits and Cmd-Z would stop meaning "undo what I just did". Triage is
// the same case: it fires in the background on rows the user is not looking at.

import Foundation

/// The only mutation surface UI leaves may call.
///
/// Unless a method's doc comment says otherwise, it registers exactly one
/// undo step and saves the context.
@MainActor
public protocol TaskStoring: AnyObject {

    // MARK: Reads (needed by every consumer that then mutates by id)

    /// Live tasks only: soft-deleted rows are excluded from every fetch.
    func allTasks() -> [KTask]
    /// Includes soft-deleted rows. Import, export, restore and purge paths.
    func allTasksIncludingDeleted() -> [KTask]
    /// One live task by id, or nil.
    func task(_ id: UUID) -> KTask?
    /// One task by id including soft-deleted rows, or nil.
    func taskIncludingDeleted(_ id: UUID) -> KTask?
    /// Non-archived projects in manual order.
    func allProjects() -> [KProject]
    /// Projects in manual order; `includeArchived: true` also returns
    /// archived ones, which the sidebar's archive section needs.
    func allProjects(includeArchived: Bool) -> [KProject]
    /// Every area in manual order, INCLUDING areas that hold no projects.
    /// Reaching areas through projects hid a freshly created one.
    func allAreas() -> [KArea]
    /// Every saved view in manual order.
    func allSavedViews() -> [KSavedView]

    // MARK: Create

    /// Create a task and append it to the global manual order.
    /// REGISTERS UNDO (one step; undo deletes the row, redo re-inserts it).
    @discardableResult
    func create(title: String, notes: String, project: KProject?,
                status: KStatus, priority: KPriority, dueDay: Int?) -> KTask

    /// Create a task without touching the undo stack.
    /// NO UNDO — reserved for MCP `create_task` and the seed importer.
    @discardableResult
    func createNoUndo(title: String, notes: String, project: KProject?,
                      status: KStatus, priority: KPriority, dueDay: Int?) -> KTask

    /// Commit accepted "paste notes -> tasks" proposals.
    /// Resolves `projectName` to an existing project by folded name, falling
    /// back to `defaultProject` when unresolved; creates/reuses labels via
    /// `label(named:)`; sets firstMove, priority, effort, due day and notes.
    /// Skips nothing on its own — the caller passes only the proposals it
    /// wants committed. REGISTERS UNDO (one step for the whole batch).
    @discardableResult
    func createMany(_ proposals: [ProposedTask], defaultProject: KProject?) -> [KTask]

    // MARK: Generic mutation

    /// Apply an arbitrary mutation to one live task.
    /// REGISTERS UNDO (one step, full-field snapshot both directions).
    func update(_ id: UUID, _ mutate: (KTask) -> Void)

    /// Apply a mutation to a task that may be soft-deleted.
    /// REGISTERS UNDO.
    func updateIncludingDeleted(_ id: UUID, _ mutate: (KTask) -> Void)

    /// Apply a mutation with no undo step.
    /// NO UNDO — reserved for MCP writes and AI triage, which write fields
    /// the user did not set and must not displace the user's undo history.
    func updateNoUndo(_ id: UUID, _ mutate: (KTask) -> Void)

    // MARK: Status and fields

    /// Mark done and stamp `completedAt`. REGISTERS UNDO.
    /// This is what the Bar's completion calls, and what the 5 s inline Undo
    /// reverses (G17).
    ///
    /// A task carrying a `recurrenceRule` also spawns its successor, inside the SAME undo
    /// step — Cmd-Z reopens the task and removes the successor together. Completing an
    /// already-done task spawns nothing.
    func complete(_ id: UUID)
    /// Mark done with no undo step. NO UNDO — MCP `complete_task`.
    /// Spawns the successor too: a completion that arrives over MCP
    /// must recur exactly like one made in the UI.
    func completeNoUndo(_ id: UUID)

    /// Back to `.todo`, clearing `completedAt`. REGISTERS UNDO.
    func reopen(_ id: UUID)

    /// Set status, maintaining `completedAt`, and drop the row out of ORDO
    /// when it becomes `.waiting` or `.someday` (O4/O5). REGISTERS UNDO.
    func setStatus(_ id: UUID, _ s: KStatus)
    /// As `setStatus`, with no undo step. NO UNDO — MCP `update_task`.
    func setStatusNoUndo(_ id: UUID, _ s: KStatus)

    /// REGISTERS UNDO.
    func setPriority(_ id: UUID, _ p: KPriority)

    /// Set the user's effort sizing. REGISTERS UNDO.
    /// Independent of `depth` and `estimateMinutes`, which the ADHD engine
    /// ranks on; effort drives no ranking.
    func setEffort(_ id: UUID, _ e: KEffort)
    /// As `setEffort`, with no undo step. NO UNDO — MCP and AI triage.
    func setEffortNoUndo(_ id: UUID, _ e: KEffort)

    /// Set the due day, preserving `originalDueDay` on first assignment so
    /// `carryDays` stays computable and the original date survives (G11).
    /// REGISTERS UNDO.
    func setDue(_ id: UUID, day: Int?)

    /// Push the due day out by one. REGISTERS UNDO.
    func snooze(_ id: UUID)

    /// Move to a project, updating the scalar mirrors `projectID`, `areaID`
    /// and `isProjectArchived` that `#Predicate` needs. REGISTERS UNDO.
    func move(_ id: UUID, toProject: KProject?)

    // MARK: Per-field setters
    //
    // Thin named wrappers over `update(_:_:)`, which already snapshots the
    // whole row both ways. They exist so the inspector's intent is greppable
    // and each undo step is named after the field it changed, rather than
    // every edit pushing a generic "Edit".

    /// Attention demand (adhd-4: never emotional weight). REGISTERS UNDO.
    func setDepth(_ id: UUID, _ d: KDepth)
    /// Predicted duration; nil clears it. REGISTERS UNDO.
    func setEstimate(_ id: UUID, minutes: Int?)
    /// The dread flag driving the ≤2-minute first move. REGISTERS UNDO.
    func setDread(_ id: UUID, _ dread: Bool)
    /// Park in `.waiting`, or release back to whatever status the automatic
    /// rule implies from the due day (`.todo` with one, `.someday` without),
    /// via `setStatus` so O5 still drops the row out of ORDO. Someday is
    /// never a manual pick: this replaced `setSomeday`. REGISTERS UNDO.
    func setWaiting(_ id: UUID, _ waiting: Bool)
    /// The concrete next physical action; blank clears it. REGISTERS UNDO.
    func setFirstMove(_ id: UUID, _ move: String?)
    /// Set or clear the recurrence rule as its wire string. An unparseable
    /// string is rejected rather than stored. REGISTERS UNDO (none if
    /// rejected).
    func setRecurrence(_ id: UUID, _ wire: String?)
    /// Attach a label; idempotent. REGISTERS UNDO.
    func addLabel(_ label: KLabel, to id: UUID)
    /// Detach a label, leaving the shared `KLabel` row itself alone.
    /// REGISTERS UNDO.
    func removeLabel(_ label: KLabel, from id: UUID)

    // MARK: ORDO
    //
    // `ordoIndex` arithmetic: top = min − 1024, append = max + 1024,
    // between = mean of neighbours. Nothing outside these methods and
    // `OrdoEngine` writes `ordoIndex`.

    /// Put the task into ORDO, at the top or appended. REGISTERS UNDO.
    func sendToOrdo(_ id: UUID, top: Bool)
    /// As `sendToOrdo`, with no undo step. NO UNDO — MCP `ordo_set(top:)`.
    func sendToOrdoNoUndo(_ id: UUID, top: Bool)

    /// Take the task out of ORDO (`ordoIndex = nil`). REGISTERS UNDO.
    func removeFromOrdo(_ id: UUID)

    /// Move `id` to sit directly before `before`, or to the end when
    /// `before` is nil. The only method that writes a between-index.
    /// REGISTERS UNDO.
    func reorderOrdo(_ id: UUID, before: UUID?)
    /// As `reorderOrdo`, with no undo step. NO UNDO — MCP `ordo_set(order:)`,
    /// which applies a whole permutation and must not push N undo steps.
    func reorderOrdoNoUndo(_ id: UUID, before: UUID?)

    /// Drop every closed-status row out of ORDO in ONE undo step (O1/O2).
    /// REGISTERS UNDO.
    func clearDoneFromOrdo()

    // MARK: Soft delete

    /// Set `deletedAt` and drop the row out of ORDO. The row stays fetchable
    /// through the `IncludingDeleted` reads for 30 days. REGISTERS UNDO.
    func softDelete(_ id: UUID)
    /// As `softDelete`, with no undo step. NO UNDO — MCP `delete_task`.
    func softDeleteNoUndo(_ id: UUID)

    /// Clear `deletedAt`. REGISTERS UNDO.
    func restore(_ id: UUID)
    /// As `restore`, with no undo step. NO UNDO — MCP `restore_task`.
    func restoreNoUndo(_ id: UUID)

    /// Hard-delete soft-deleted rows older than `days`. NO UNDO — this is the
    /// 30-day purge run by the day-change coordinator, and it is not an
    /// action the user took.
    func purgeDeletedOlderThan(days: Int, now: Date)

    // MARK: Subtasks

    /// Append a step. REGISTERS UNDO. Returns nil when the task is gone.
    @discardableResult
    func addSubtask(_ taskID: UUID, title: String) -> KSubtask?
    /// As `addSubtask`, with no undo step. NO UNDO — MCP `add_subtask` and
    /// the `create_task` subtask array.
    @discardableResult
    func addSubtaskNoUndo(_ taskID: UUID, title: String) -> KSubtask?

    /// Append breakdown steps after a task's existing subtasks.
    /// Never edits or reorders what is already there.
    /// REGISTERS UNDO (one step for the whole batch).
    func addSubtasks(_ titles: [String], to id: UUID)

    /// Flip one step. REGISTERS UNDO.
    func toggleSubtask(_ id: UUID)
    /// Set one step to an explicit value, or flip it when `isDone` is nil.
    /// NO UNDO — MCP `toggle_subtask`, which is idempotent on retry.
    func toggleSubtaskNoUndo(_ id: UUID, isDone: Bool?)

    /// Retitle one step. REGISTERS UNDO (rev 4).
    func renameSubtask(_ id: UUID, title: String)
    /// Move a step directly before `before`, or to the end when nil.
    /// REGISTERS UNDO (rev 4).
    func reorderSubtask(_ id: UUID, before: UUID?)
    /// Remove a step. REGISTERS UNDO — undo re-attaches the row rather than
    /// re-inserting a deleted model, which SwiftData does not guarantee
    /// (rev 4).
    func deleteSubtask(_ id: UUID)

    // MARK: Projects, labels, areas

    /// Create a project, appended within its area's manual order.
    /// NO UNDO — structure edits are made deliberately in Settings and the
    /// sidebar, and are not part of the task-editing undo history.
    @discardableResult
    func createProject(name: String, colorHex: String, icon: String?, area: KArea?) -> KProject

    /// Edit a project's presentation. A bare `nil` argument leaves that field unchanged; pass
    /// `.some(nil)` to clear an optional field (icon or emoji) back to nil.
    ///
    /// REGISTERS UNDO (one step covering every field this call changes). `icon` defaults to
    /// `nil` in the concrete `TaskStore`, so an older call site that omits it still compiles
    /// unchanged.
    func updateProject(_ id: UUID, name: String?, colorHex: String?, icon: String??, emoji: String??)

    /// Archive a project, mirroring the flag onto its tasks'
    /// `isProjectArchived`. REGISTERS UNDO — ONE step for the project and
    /// every task it touches.
    func archiveProject(_ id: UUID)
    /// Un-archive a project and its tasks' mirror flag.
    /// REGISTERS UNDO (one step).
    func restoreProject(_ id: UUID)
    /// Move a project to another area, or to no area when nil; its tasks'
    /// `areaID` mirror follows. REGISTERS UNDO (one step).
    func moveProject(_ id: UUID, toArea: KArea?)
    /// Move a project directly before `before` within its own area's order,
    /// or to the end when nil. REGISTERS UNDO.
    func reorderProject(_ id: UUID, before: UUID?)

    /// Create an area, appended to the manual order. REGISTERS UNDO — unlike `createProject`,
    /// which stays NO UNDO for source compatibility; an empty area has no children to lose on
    /// undo.
    @discardableResult
    func createArea(name: String, colorHex: String, icon: String) -> KArea
    /// Rename an area. REGISTERS UNDO.
    func renameArea(_ id: UUID, name: String)
    /// Edit an area's colour and/or icon; a nil argument leaves that field
    /// alone. REGISTERS UNDO (one step).
    func updateArea(_ id: UUID, colorHex: String?, icon: String?)

    // MARK: Saved views
    //
    // `KSavedView` existed as a @Model with no CRUD at all for a while, so the
    // whole saved-view surface had to be disabled in the UI.

    /// Create a saved view, appended to the manual order. REGISTERS UNDO.
    @discardableResult
    func createSavedView(name: String, filter: KFilter,
                         sort: [KSortDescriptor], showDone: Bool) -> KSavedView
    /// Edit a saved view. Every parameter is independently optional, so a
    /// caller can rename without restating the filter. REGISTERS UNDO (one
    /// step covering every field this call changes).
    func updateSavedView(_ id: UUID, name: String?, filter: KFilter?,
                         sort: [KSortDescriptor]?, showDone: Bool?)
    /// Delete a saved view. REGISTERS UNDO — undo re-inserts it.
    func deleteSavedView(_ id: UUID)
    /// Move a saved view directly before `before`, or to the end when nil.
    /// REGISTERS UNDO.
    func reorderSavedView(_ id: UUID, before: UUID?)

    /// Find a label by its diacritic-folded merge key, or create one.
    /// REGISTERS UNDO on creation only; an existing label is a pure read.
    @discardableResult
    func label(named name: String) -> KLabel

    /// Delete an area. REGISTERS UNDO.
    /// - Throws: `StoreError.areaHasProjects` when the area still has
    ///   projects, so no orphan can be created.
    func deleteArea(_ area: KArea) throws

    // MARK: Rules (house rules, consumed by triage and Impuls)

    /// Active house rules, newest last.
    func allRules(includeInactive: Bool) -> [KRule]

    /// Add a house rule, capped at 160 chars.
    /// NO UNDO — rules are added by an explicit tap or by MCP `rules_add`,
    /// and are edited in their own list rather than reversed with Cmd-Z.
    @discardableResult
    func addRule(text: String, scope: KRuleScope, source: KRuleSource) -> KRule

    // MARK: Undo

    /// Reverse the most recent undoable mutation. No-op when the stack is
    /// empty. The 5 s inline Undo affordance and Cmd-Z both call this.
    func undo()
    /// Replay the most recently undone mutation. No-op when there is none.
    func redo()

    /// Collapse every mutation performed inside `body` into ONE undo step
    /// and ONE redo step (rev 4). Nesting is safe — an inner call joins the
    /// outer group. A body that mutates nothing pushes nothing.
    ///
    /// REGISTERS UNDO: exactly one step, or none for an empty body. Use it
    /// whenever one user action means several writes, so Cmd-Z matches what
    /// the user thinks they did.
    func groupedUndo(_ name: String, _ body: () -> Void)

    var canUndo: Bool { get }
    var canRedo: Bool { get }
}

// MARK: - Convenience
//
// Only shorthands that do NOT shadow a protocol requirement live here: a
// defaulted overload with the same base name as a requirement resolves back
// to itself and recurses. The concrete `TaskStore` declares its own default
// arguments, so `store.create(title:)` stays short at every call site that
// holds the concrete type.

public extension TaskStoring {
    /// Active rules only, which is what triage and Impuls always want.
    func activeRules() -> [KRule] { allRules(includeInactive: false) }

    /// The 30-day purge with the standard window and the current clock.
    func purgeDeletedOlderThanStandardWindow() {
        purgeDeletedOlderThan(days: 30, now: Date())
    }
}

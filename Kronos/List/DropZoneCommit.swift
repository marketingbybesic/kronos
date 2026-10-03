// Kronos/List/DropZoneCommit.swift
// Applies a drop: maps the planned DropCommand onto the store, as ONE undo step each, raises the
// undo pill and refuses (with an inline message) what the nest guard forbids. A move that changes
// nothing pushes nothing onto the undo stack. External items become new tasks or links; a link is
// never written empty.
import AppKit
import KronosCore

extension ListDropController {
    /// Reads a Mail subject by message URL when the drag carries none. Replaced in tests, so no test
    /// reaches the person's Mail data.
    nonisolated(unsafe) static var mailSubject: @Sendable (String) -> String? = { MailSubjectLookup.subject(forMessageURL: $0) }

    /// Commits the drop at the last pointer position. False = nothing happened (the drag springs back).
    @discardableResult
    func perform() -> Bool {
        guard isActive, let subject, let p = lastPointer, let r = resolution(forPointer: p) else {
            if isActive, subject?.source == .task, !config.isManualSort { ListSortDragHint.shared.raise(for: config.scope) }
            end(); return false
        }
        let command = DropPlanner.command(for: r, subject: subject)
        // A task dropped on a sorted list has no place to land: say so instead of springing back silently.
        if case .none = command, subject.source == .task, !config.isManualSort { ListSortDragHint.shared.raise(for: config.scope) }
        let payload = self.payload
        end()
        // Mail without a subject on the pasteboard, a Notes drag without an id: look it up first,
        // then commit the same command (still one undo step).
        if case .external(let items) = payload, items.contains(where: \.needsResolution) {
            switch command {
            case .createTask, .attach:
                Task { @MainActor in
                    let done = await self.resolved(items)
                    self.apply(command, payload: .external(done))
                }
                return true
            default: break
            }
        }
        return apply(command, payload: payload)
    }

    @discardableResult
    func apply(_ command: DropCommand, payload: DropPayload) -> Bool {
        switch command {
        case .none:
            return false
        case .moveTask(let id, let before):
            return moveTask(id, before: before)
        case .nestTask(let id, let parent, let before):
            return nestTask(id, under: parent, before: before)
        case .reorderSubtask(let id, let before):
            return reorderSubtask(id, before: before)
        case .moveSubtask(let id, let parent, let before):
            return moveSubtask(id, under: parent, before: before)
        case .promoteSubtask(let id, let before):
            return promoteSubtask(id, before: before)
        case .createTask(let before):
            guard case .external(let items) = payload else { return false }
            return createTasks(from: items, before: before)
        case .attach(let rowID, let isSubtask):
            guard case .external(let items) = payload else { return false }
            return attach(items, toRow: rowID, isSubtask: isSubtask)
        }
    }

    // MARK: Messages

    /// Shown when the store refuses a nest the planner allowed (the target changed under the drag).
    static var childTargetMessage: String { String(localized: "list.drop.blocked.subtask") }

    private func pill(_ text: String) {
        model.commit(text)
    }

    // MARK: Level-0 order

    private func moveTask(_ id: UUID, before: UUID?) -> Bool {
        let store = model.store
        guard let task = store.task(id) else { return false }
        // Dropped where it already is: no undo step.
        if DropPlacement.isNoOp(moving: id, before: before, order: config.manualOrder) { return false }
        let title = task.title
        // One undo step. Rewrites the row, plus its two neighbours only when their gap ran out.
        guard store.moveTask(id, before: before, inOrder: config.manualOrder) else { return false }
        pill(String(format: String(localized: "undo.listreorder.name"), title))
        return true
    }

    // MARK: Nesting

    private func nestTask(_ id: UUID, under parentID: UUID, before: UUID?) -> Bool {
        let store = model.store
        guard let child = store.task(id), let parent = store.task(parentID), id != parentID else { return false }
        let title = child.title
        let parentTitle = parent.title
        let depth = store.undoDepth
        do {
            // One undo step, or a refusal with no change. A task that has children takes them along.
            try store.setParent(id, to: parentID, at: before.map { .before($0) } ?? .end)
        } catch TaskNestError.parentIsSubtask {
            showToast(Self.childTargetMessage)
            return false
        } catch {
            return false
        }
        guard store.undoDepth > depth else { return false }   // already there: nothing pushed
        if model.selectedTaskID == id { model.selectedTaskID = parentID }
        pill(String(format: String(localized: "undo.nested.name"), title, parentTitle))
        return true
    }

    // MARK: Children

    private func childTitle(_ id: UUID) -> String? { model.store.task(id).flatMap { $0.isSubtask ? $0.title : nil } }

    private func reorderSubtask(_ id: UUID, before: UUID?) -> Bool {
        let store = model.store
        if let parent = store.subtaskOwnerID(id),
           DropPlacement.isNoOp(moving: id, before: before, order: config.order.subtasks[parent] ?? []) { return false }
        let depth = store.undoDepth
        store.reorderChild(id, before: before)
        guard store.undoDepth > depth else { return false }   // already in that place: nothing pushed
        pill(String(format: String(localized: "undo.listreorder.name"), childTitle(id) ?? ""))
        return true
    }

    private func moveSubtask(_ id: UUID, under parentID: UUID, before: UUID?) -> Bool {
        let store = model.store
        guard let parent = store.task(parentID), let title = childTitle(id),
              store.subtaskOwnerID(id) != parentID else { return false }
        let parentTitle = parent.title
        let depth = store.undoDepth
        do { try store.setParent(id, to: parentID, at: before.map { .before($0) } ?? .end) }   // one undo step
        catch { return false }
        guard store.undoDepth > depth, store.subtaskOwnerID(id) == parentID else { return false }
        pill(String(format: String(localized: "undo.movedunder.name"), title, parentTitle))
        return true
    }

    private func promoteSubtask(_ id: UUID, before: UUID?) -> Bool {
        let store = model.store
        guard let title = childTitle(id) else { return false }
        // A sorted list has no level-0 position to land on: the row goes to the end.
        let placement: KNestPlacement = config.isManualSort ? (before.map { .before($0) } ?? .end) : .end
        let depth = store.undoDepth
        do { try store.setParent(id, to: nil, at: placement) }   // one undo step, same row and id
        catch { return false }
        guard store.undoDepth > depth else { return false }
        pill(String(format: String(localized: "undo.promoted.name"), title))
        return true
    }

    // MARK: External items

    private func createTasks(from items: [ExternalDropItem], before: UUID?) -> Bool {
        let store = model.store
        let usable = items.filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !usable.isEmpty else { return false }
        // A dropped item must show up in the list it was dropped on. Inbox, All and saved views have no
        // status or date of their own to fill, so the task is a plain open one (the quick-add rule that
        // parks undated tasks in Someday would hide it from Inbox and All).
        let defaults: ListScopeDefaults.Result
        switch config.scope {
        case .inbox, .all, .savedView:
            defaults = ListScopeDefaults.Result(status: .todo, dueDay: nil, areaID: nil)
        default:
            defaults = ListScopeDefaults.apply(scope: QuickAddCreate.scopeKind(for: config.scope), explicitDueDay: nil,
                                               today: Day.today(calendar: KronosLocale.calendar))
        }
        var project: KProject?
        if case .project(let id) = config.scope { project = store.allProjects().first { $0.id == id } }
        // In a manual list the new rows land in drop order directly before `before`.
        let placeBefore = config.isManualSort ? before.flatMap { config.manualOrder.contains($0) ? $0 : nil } : nil
        var order = config.manualOrder
        var made: [KTask] = []
        store.groupedUndo("New Task") {
            for item in usable {
                // A link with no reference is never written: such an item becomes a plain task.
                let notes = item.link.flatMap { $0.reference.isEmpty ? nil : $0.appending(to: "") } ?? ""
                let task = store.create(title: item.title, notes: notes, project: project, status: defaults.status,
                                        priority: .none, dueDay: defaults.dueDay)
                if let areaID = defaults.areaID, project == nil { store.update(task.id) { $0.areaID = areaID } }
                if let placeBefore, let at = order.firstIndex(of: placeBefore) {
                    store.moveTask(task.id, before: placeBefore, inOrder: order)
                    order.insert(task.id, at: at)
                }
                made.append(task)
            }
        }
        guard let first = made.first else { return false }
        pill(String(format: String(localized: "undo.added.name"), first.title))
        return true
    }

    private func attach(_ items: [ExternalDropItem], toRow rowID: UUID, isSubtask: Bool) -> Bool {
        let links = items.compactMap(\.link).filter { !$0.reference.isEmpty }
        guard !links.isEmpty else { return false }
        let store = model.store
        let target: AttachmentTarget
        if isSubtask {
            guard let sub = store.task(rowID), sub.isSubtask else { return false }
            target = .subtask(sub)
        } else {
            guard store.task(rowID) != nil else { return false }
            target = .task(rowID)
        }
        ContextLinkDropModifier.write(links, to: target, model: model)   // raises the Linked pill itself
        return true
    }

    // MARK: Items that need a lookup first (Mail subject from the Envelope Index, Notes id by title)

    /// Resolves what the pasteboard alone could not tell: the subject of a Mail message, the id of a
    /// dragged note. Items that stay unresolved keep their placeholder title and get no chip.
    func resolved(_ items: [ExternalDropItem]) async -> [ExternalDropItem] {
        var out: [ExternalDropItem] = []
        for var item in items {
            if let url = item.mailURLNeedingSubject {
                let lookup = Self.mailSubject
                let subject = await Task.detached(priority: .userInitiated) { lookup(url) }.value
                if let subject {
                    item.title = subject
                    item.link = ContextLink(kind: .email, reference: url, displayName: subject)
                }
                item.mailURLNeedingSubject = nil
            }
            if let title = item.noteTitleToResolve {
                if let hit = (try? await model.notes.noteIDs(titled: title))?.first, !hit.id.isEmpty {
                    item.link = ContextLink(kind: .appleNote, reference: hit.id, displayName: hit.title)
                }
                item.noteTitleToResolve = nil
            }
            out.append(item)
        }
        return out
    }
}

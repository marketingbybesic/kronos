// Part of TaskStore. Areas and saved views.
//
// The sidebar's area editing and the whole
// saved-view surface had to be DISABLED because the store exposed no way to list, create or
// edit either: `allProjects()` reached areas only through projects, so an
// area with no projects was invisible, and `KSavedView` existed as a @Model
// with no CRUD at all. Both are closed here, additively.
//
// Extensions in a separate file cannot see `private` members, so the undo
// plumbing these rely on is internal rather than private.

import Foundation
import SwiftData

@MainActor
extension TaskStore {

    // MARK: - Areas

    /// Every area in manual order, INCLUDING areas that hold no projects.
    /// Reaching areas through `allProjects()` silently hid an empty area, so
    /// a freshly created one could not be selected as a project's parent.
    public func allAreas() -> [KArea] {
        let all: [KArea] = (try? context.fetch(FetchDescriptor<KArea>())) ?? []
        return all.sorted(byTotalOrder: \.sortIndex, \.createdAt, \.id)
    }

    func area(_ id: UUID) -> KArea? { allAreas().first { $0.id == id } }

    /// Create an area, appended to the manual order.
    /// REGISTERS UNDO (one step; undo deletes the row, redo re-inserts it).
    /// Unlike `createProject`, which predates rev 4 and stays NO UNDO for
    /// source compatibility, a new area IS undoable: the sidebar offers no
    /// other way back from a mis-click, and an empty area has no children to
    /// lose on re-insert.
    @discardableResult
    public func createArea(name: String,
                           colorHex: String = "#8B8B93",
                           icon: String = "square.grid.2x2") -> KArea {
        let a = KArea(name: name, colorHex: colorHex, icon: icon,
                      sortIndex: appendIndex(scope: .areas))
        context.insert(a)
        saveContext()
        let id = a.id, idx = a.sortIndex
        pushCreateUndoStep("New Area", a) {
            let rebuilt = KArea(name: name, colorHex: colorHex, icon: icon, sortIndex: idx)
            rebuilt.id = id
            return rebuilt
        }
        return a
    }

    /// REGISTERS UNDO (one step).
    public func renameArea(_ id: UUID, name: String) {
        guard let a = area(id), a.name != name else { return }
        let before = a.name
        applyAreaEdit("Rename Area", a, apply: { $0.name = name }, revert: { $0.name = before })
    }

    /// Edit an area's presentation. A nil argument leaves that field alone.
    /// REGISTERS UNDO (one step, both fields together).
    public func updateArea(_ id: UUID, colorHex: String? = nil, icon: String? = nil) {
        guard let a = area(id) else { return }
        let beforeColor = a.colorHex, beforeIcon = a.icon
        let newColor = colorHex ?? beforeColor, newIcon = icon ?? beforeIcon
        guard newColor != beforeColor || newIcon != beforeIcon else { return }
        applyAreaEdit("Edit Area", a,
                      apply:  { $0.colorHex = newColor;    $0.icon = newIcon },
                      revert: { $0.colorHex = beforeColor; $0.icon = beforeIcon })
    }

    /// One undo step over a scalar area edit: apply now, revert on undo,
    /// re-apply on redo. Factored so every area edit pushes an identical
    /// shape and no caller hand-rolls the stack bookkeeping.
    private func applyAreaEdit(_ name: String, _ a: KArea,
                               apply: @escaping (KArea) -> Void,
                               revert: @escaping (KArea) -> Void) {
        apply(a)
        a.updatedAt = Date()
        undoStack.append((name, { [weak self] in
            guard let self else { return }
            revert(a)
            self.saveContext()
            self.redoStack.append((name, { [weak self] in
                guard let self else { return }
                apply(a)
                self.saveContext()
            }))
        }))
        redoStack.removeAll()
        saveContext()
    }

    // MARK: - Saved views

    /// Every saved view in manual order.
    public func allSavedViews() -> [KSavedView] {
        let all: [KSavedView] = (try? context.fetch(FetchDescriptor<KSavedView>())) ?? []
        return all.sorted(byTotalOrder: \.sortIndex, \.createdAt, \.id)
    }

    func savedView(_ id: UUID) -> KSavedView? { allSavedViews().first { $0.id == id } }

    /// Create a saved view, appended to the manual order.
    /// REGISTERS UNDO (one step).
    @discardableResult
    public func createSavedView(name: String,
                                filter: KFilter,
                                sort: [KSortDescriptor] = [],
                                showDone: Bool = false) -> KSavedView {
        let v = KSavedView(name: name, filter: filter, showDone: showDone,
                           sortIndex: appendIndex(scope: .savedViews), sort: sort)
        context.insert(v)
        saveContext()
        pushCreateUndoStep("New View", v, rebuild: savedViewRebuilder(v))
        return v
    }

    /// Edit a saved view. Every parameter is independently optional, so a
    /// caller can rename a view without restating its filter, or swap the
    /// filter without touching the name. REGISTERS UNDO (one step covering
    /// every field changed by this call).
    public func updateSavedView(_ id: UUID,
                                name: String? = nil,
                                filter: KFilter? = nil,
                                sort: [KSortDescriptor]? = nil,
                                showDone: Bool? = nil) {
        guard let v = savedView(id) else { return }
        let before = (name: v.name, filterJSON: v.filterJSON,
                      sortJSON: v.sortJSON, showDone: v.showDone)
        let after = (name: name ?? v.name,
                     filterJSON: filter?.encodedString ?? v.filterJSON,
                     sortJSON: sort.map(KSavedView.encodeSort) ?? v.sortJSON,
                     showDone: showDone ?? v.showDone)
        guard after != before else { return }

        func apply(_ s: (name: String, filterJSON: String, sortJSON: String, showDone: Bool)) {
            v.name = s.name; v.filterJSON = s.filterJSON
            v.sortJSON = s.sortJSON; v.showDone = s.showDone
            v.updatedAt = Date()
        }
        apply(after)
        undoStack.append(("Edit View", { [weak self] in
            guard let self else { return }
            apply(before)
            self.saveContext()
            self.redoStack.append(("Edit View", { [weak self] in
                guard let self else { return }
                apply(after)
                self.saveContext()
            }))
        }))
        redoStack.removeAll()
        saveContext()
    }

    /// REGISTERS UNDO (one step). Undo re-inserts the view.
    public func deleteSavedView(_ id: UUID) {
        guard let v = savedView(id) else { return }
        deleteUndoable("Delete View", v, rebuild: savedViewRebuilder(v))
    }

    /// A factory that reproduces `v` — id and every persisted field — so an
    /// undo/redo step can rebuild the row rather than resurrect the deleted
    /// instance (see `deleteUndoable`). The values are read NOW, while the
    /// row is alive, because a deleted model's relationships are not
    /// guaranteed readable later.
    private func savedViewRebuilder(_ v: KSavedView) -> () -> KSavedView {
        let id = v.id, name = v.name, icon = v.icon, idx = v.sortIndex
        let filterJSON = v.filterJSON, sortJSON = v.sortJSON
        let sortModeRaw = v.sortModeRaw, groupByRaw = v.groupByRaw
        let showDone = v.showDone, createdAt = v.createdAt
        return {
            let rebuilt = KSavedView(name: name, filter: KFilter.decode(filterJSON),
                                     showDone: showDone, sortIndex: idx)
            rebuilt.id = id
            rebuilt.icon = icon
            rebuilt.filterJSON = filterJSON
            rebuilt.sortJSON = sortJSON
            rebuilt.sortModeRaw = sortModeRaw
            rebuilt.groupByRaw = groupByRaw
            rebuilt.createdAt = createdAt
            return rebuilt
        }
    }

    /// Move `id` to sit directly before `before`, or to the end when `before`
    /// is nil. REGISTERS UNDO (one step).
    public func reorderSavedView(_ id: UUID, before targetID: UUID?) {
        let views = allSavedViews()
        guard let moving = views.first(where: { $0.id == id }) else { return }
        let newIdx = betweenIndex(for: id, before: targetID,
                                  in: views.map { (id: $0.id, idx: $0.sortIndex) })
        let oldIdx = moving.sortIndex
        guard oldIdx != newIdx else { return }
        moving.sortIndex = newIdx
        moving.updatedAt = Date()
        undoStack.append(("Reorder Views", { [weak self] in
            guard let self else { return }
            moving.sortIndex = oldIdx
            self.saveContext()
            self.redoStack.append(("Reorder Views", { [weak self] in
                guard let self else { return }
                moving.sortIndex = newIdx
                self.saveContext()
            }))
        }))
        redoStack.removeAll()
        saveContext()
    }
}

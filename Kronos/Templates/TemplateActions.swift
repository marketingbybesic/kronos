// Kronos/Templates/TemplateActions.swift
// ONE implementation of the three template actions, used by every entry point: the task context
// menu, the command palette, the File menu and the inspector footer. A template is a saved
// starting point (a task plus its steps, no dates): "Save as template" keeps one, "New from
// template" makes a fresh task from it, "Manage templates" opens the list where each one is
// renamed or deleted (Settings > Data > Templates).
import AppKit
import Foundation
import KronosCore

@MainActor
enum TemplateActions {

    /// Keeps `taskID` (and its steps) as a template under the task's title and says so on the
    /// shell pill: its Undo removes the template again, its "Manage" button opens the list for
    /// renaming. The pill shows the name actually stored (a repeated name becomes "name 2").
    /// Returns the stored template, or nil when the task is gone.
    @discardableResult
    static func save(taskID: UUID, model: AppModel, store injected: TemplateStore? = nil) -> TaskTemplate? {
        let store = injected ?? TemplateStore.shared
        guard let draft = model.store.makeTemplate(from: taskID) else { return nil }
        let stored = store.add(draft)
        UndoToastCenter.shared.show(
            String(format: String(localized: "undo.templatesaved.name"), stored.name),
            customUndo: { store.delete(stored.id) },
            primaryTitle: String(localized: "undo.templatesaved.manage"),
            onPrimary: { manage() })
        return stored
    }

    /// Makes a task from `template` in ONE undo step, selects it and raises the pill. The status
    /// and date follow the list the person is on, like every other way of adding a task.
    @discardableResult
    static func create(from template: TaskTemplate, model: AppModel) -> KTask {
        let today = Day.today(calendar: KronosLocale.calendar)
        let defaults = ListScopeDefaults.apply(scope: QuickAddCreate.scopeKind(for: model.scope),
                                               explicitDueDay: nil, today: today)
        let task = model.store.createFromTemplate(template, status: defaults.status, dueDay: defaults.dueDay)
        model.selectedTaskID = task.id
        model.commit(String(format: String(localized: "undo.fromtemplate.name"), task.title))
        return task
    }

    /// Opens the quick add panel with `/` typed, so the template list is showing.
    static func openPicker() {
        NotificationCenter.default.post(name: .kronosNewFromTemplate, object: nil)
    }

    /// Opens Settings on the Data tab, where the templates are listed with rename and delete.
    static func manage() {
        SettingsTab.remember(.data)
        NotificationCenter.default.post(name: .kronosSettingsRequested, object: nil, userInfo: ["tab": SettingsTab.data.rawValue])
    }
}

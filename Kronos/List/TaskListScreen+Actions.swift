// Kronos/List/TaskListScreen+Actions.swift
// The writes behind the list's single keys (TaskListScreen+Keys.swift). Every one is one undo
// step and raises the undo pill through `model.commit` (one helper for every user write); the pin
// is not a store change, so its pill carries its own undo (UndoToastCenter.show(_:customUndo:)).
// A key that would change nothing writes nothing and shows nothing.
import SwiftUI
import KronosCore

extension TaskListScreen {
    /// H: plan for tomorrow (the deadline is never touched); the selection moves on when the row leaves.
    func snoozeTask(_ task: KTask) {
        let next = model.selectedTaskID == task.id ? ListCompletion.neighbourToSelect(after: task.id, model: model) : nil
        let before = task.plannedDay
        model.store.snooze(task.id)
        guard model.store.task(task.id)?.plannedDay != before else { return }
        if let next { model.selectedTaskID = next }
        model.commit(String(format: String(localized: "undo.snoozed.name"), task.title))
    }

    /// T / ⇧T: plan the task for today or tomorrow (plannedDay; the deadline stays as it is).
    func plan(_ task: KTask, daysFromToday: Int) {
        let day = Day.today() + daysFromToday
        guard task.plannedDay != day else { return }
        let next = daysFromToday > 0 && model.selectedTaskID == task.id
            ? ListCompletion.neighbourToSelect(after: task.id, model: model) : nil
        model.store.plan(task.id, day: day)
        if let next { model.selectedTaskID = next }
        let format = daysFromToday == 0 ? String(localized: "list.pill.plannedtoday") : String(localized: "list.pill.plannedtomorrow")
        model.commit(String(format: format, task.title))
    }

    func setPriority(_ task: KTask, _ priority: KPriority) {
        guard task.priority != priority else { return }
        model.store.setPriority(task.id, priority)
        model.commit(String(format: String(localized: "undo.priority.name"),
                            ViewOptionsMapper.priorityName(priority), task.title))
    }

    /// S / M / L: small, medium or large effort.
    func setEffort(_ task: KTask, _ size: ListEffortKey) {
        let effort = size.effort
        guard task.effort != effort else { return }
        model.store.setEffort(task.id, effort)
        model.commit(String(format: String(localized: "list.pill.effort"), ViewOptionsMapper.effortName(effort), task.title))
    }

    /// W: park the task as waiting on someone (it comes back to Today in three days by itself),
    /// or release it again.
    func toggleWaiting(_ task: KTask) {
        let waiting = task.status != .waiting
        let next = waiting && model.selectedTaskID == task.id ? ListCompletion.neighbourToSelect(after: task.id, model: model) : nil
        let before = task.status
        model.store.setWaiting(task.id, waiting)
        guard model.store.task(task.id)?.status != before else { return }
        if let next { model.selectedTaskID = next }
        let format = waiting ? String(localized: "list.pill.waiting") : String(localized: "list.pill.notwaiting")
        model.commit(String(format: format, task.title))
    }

    /// Y: move the task to Someday, or bring a Someday task back to To do.
    func toggleSomeday(_ task: KTask) {
        let toSomeday = task.status != .someday
        guard task.status != .done else { return }
        let next = toSomeday && model.selectedTaskID == task.id ? ListCompletion.neighbourToSelect(after: task.id, model: model) : nil
        model.store.setStatus(task.id, toSomeday ? .someday : .todo)
        if let next { model.selectedTaskID = next }
        let format = toSomeday ? String(localized: "list.pill.someday") : String(localized: "list.pill.notsomeday")
        model.commit(String(format: format, task.title))
    }

    /// B: open the task in the inspector with the Break down preview already showing.
    func breakDown(_ task: KTask) {
        ListBreakdown.request(task.id, model: model)
    }

    /// F: pin as focus, or unpin (ListFocusPin, shared with the row menu).
    func toggleFocusPin(_ task: KTask) {
        ListFocusPin.toggle(task.id, title: task.title, model: model)
    }
}

extension ListEffortKey {
    /// The effort a key sets: S small, M medium, L large.
    var effort: KEffort {
        switch self {
        case .small: return .s
        case .medium: return .m
        case .large: return .l
        }
    }
}

/// Break down from anywhere in the list (key B, the row menu): select the task in the inspector and
/// file a request its Steps section takes (BreakdownRequests), so the preview opens at once.
@MainActor
enum ListBreakdown {
    static func request(_ id: UUID, model: AppModel) {
        guard let task = model.store.task(id), !task.isSubtask else { return }
        model.openDetails(taskID: id)
        BreakdownRequests.shared.request(taskID: id)
    }
}

/// Requests from the list keys to one row's own popovers (the row with that id answers).
enum ListRowRequests {
    /// D: the row's date field.
    static let pickDue = Notification.Name("kronosRowPickDueRequested")
    /// P: the row's project picker.
    static let pickProject = Notification.Name("kronosRowPickProjectRequested")

    static func post(_ name: Notification.Name, taskID: UUID) {
        NotificationCenter.default.post(name: name, object: nil, userInfo: ["taskID": taskID])
    }

    static func taskID(_ note: Notification) -> UUID? { note.userInfo?["taskID"] as? UUID }
}

// One place turns typed text into tasks, so EVERY add field understands the same things,
// integrated so tasks and subtasks can be added quickly from anywhere in the interface:
//   - quick add syntax on each task line: #project @label ! effort dates (QuickAddParser)
//   - subtasks: "Task > sub > sub" on one line, or indented / bulleted lines under a task (TaskOutline)
// The whole entry is ONE undo step.
import Foundation
import KronosCore

@MainActor
enum QuickAddCreate {
    /// Returns the created tasks (empty when the text has no title). `fallbackProject` is the
    /// list's own project, used only for lines that name none. `scope` is the list the text was
    /// typed INTO: a task typed on Someday must actually land in Someday, on Waiting must
    /// land in Waiting, and so on; typed with no scope at all (the global panel) and no date, it
    /// lands in Someday (all tasks without a date default to someday).
    /// `isWaiting` is the quick add panel's Waiting toggle and ALWAYS wins the status, over
    /// every scope. `KronosCore.ListScopeDefaults.apply` (Packages/KronosCore/Sources/
    /// KronosCore/QuickAdd/ListScopeDefaults.swift) is the one place that decides the status ×
    /// date × scope matrix, with a hand-tabled test there; explicit text (a parsed date) always
    /// overrides the scope's own date default. `scopeKind(for:)` below maps the app's own
    /// `ListScope` onto Core's app-agnostic mirror of it.
    @discardableResult
    static func create(from text: String, model: AppModel, fallbackProject: KProject? = nil,
                        scope: ListScope? = nil, isWaiting: Bool = false) -> [KTask] {
        let today = Day.today(calendar: KronosLocale.calendar)
        let all = model.store.allProjects()
        let names = all.map(\.name)
        let parser = QuickAddParser()
        var made: [KTask] = []
        model.store.groupedUndo("quick add") {
            for item in TaskOutline.parse(text) {
                let result = parser.parse(item.line, projects: names, today: today)
                guard !result.title.isEmpty else { continue }
                let project = result.projectName.flatMap { name in all.first { $0.name == name } } ?? fallbackProject
                let defaults = ListScopeDefaults.apply(scope: scopeKind(for: scope),
                                                        explicitDueDay: result.dueDay, today: today,
                                                        isWaiting: isWaiting)
                let task = model.store.create(title: result.title, notes: "", project: project,
                                               status: defaults.status, priority: result.priority,
                                               dueDay: defaults.dueDay)
                if let areaID = defaults.areaID, project == nil {
                    model.store.update(task.id) { $0.areaID = areaID }
                }
                if let labelName = result.labelName {
                    let label = model.store.label(named: labelName)
                    model.store.update(task.id) { $0.labels?.append(label) }
                }
                if let effort = result.effort { model.store.setEffort(task.id, effort) }
                if !item.subtasks.isEmpty { model.store.addSubtasks(item.subtasks, to: task.id) }
                made.append(task)
            }
        }
        if !made.isEmpty { model.didMutate() }
        return made
    }

    /// `ListScope` (Kronos/Shared/UIContract.swift) -> Core's app-agnostic mirror of it, case
    /// for case.
    private static func scopeKind(for scope: ListScope?) -> QuickAddScopeKind? {
        switch scope {
        case .inbox: return .inbox
        case .today: return .today
        case .next7: return .next7
        case .waiting: return .waiting
        case .someday: return .someday
        case .all: return .all
        case .project: return .project
        case .area(let id): return .area(id)
        case .savedView: return .savedView
        case nil: return nil
        }
    }
}

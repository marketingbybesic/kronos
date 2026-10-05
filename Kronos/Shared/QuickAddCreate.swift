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
    ///
    /// `pills` are the committed attributes of an entry field (destination, label, priority,
    /// effort, date): defaults for EVERY task line of the text, overridden per line by a token
    /// typed in that line. A destination that does not exist yet (`isNew`) is created once,
    /// inside the same undo step, and reused by the lines that name it.
    ///
    /// A line that reads "every week" / "svaki tjedan" repeats: its first due day is the date
    /// typed in the line, or today (the next named weekday for "every Monday"). `links` are the
    /// context chips of the quick add panel (a web page, a mail, files, a note): written onto the
    /// FIRST task, inside the same undo step.
    @discardableResult
    static func create(from text: String, model: AppModel, fallbackProject: KProject? = nil,
                        scope: ListScope? = nil, isWaiting: Bool = false,
                        pills: [EntryPill] = [], links: [ContextLink] = []) -> [KTask] {
        let today = Day.today(calendar: KronosLocale.calendar)
        let store = model.store
        let catalog = EntryCatalog.make(store: store)
        var projects = store.allProjects()
        var made: [KTask] = []
        var used: [EntryRecents.Key] = []
        var savedViewHome: UUID?
        if case .savedView(let id) = scope { savedViewHome = store.allSavedViews().first { $0.id == id }?.homeProjectID }

        func existingOrNewProject(_ d: EntryDestination) -> KProject? {
            if let id = d.id, let p = projects.first(where: { $0.id == id }) { return p }
            let key = KTextFold.fold(d.name)
            if let p = projects.first(where: { KTextFold.fold($0.name) == key }) { return p }
            guard d.isNew else { return nil }
            let p = store.createProject(name: d.name)
            projects.append(p)
            return p
        }

        store.groupedUndo(String(localized: "undo.quickadd")) {
            for item in TaskOutline.parse(text) {
                let result = EntryDraft.resolve(text: item.line, pills: pills, directory: catalog.directory, today: today,
                                                readsRepeat: true)
                guard !result.title.isEmpty else { continue }
                var project: KProject?
                var areaID: UUID?
                if let dest = result.destination {
                    switch dest.kind {
                    case .project: project = existingOrNewProject(dest)
                    case .area: areaID = dest.id
                    }
                } else {
                    project = fallbackProject
                }
                let repeatPhrase = result.repeatPhrase
                let explicitDue = result.dueDay ?? repeatPhrase?.firstDue(today: today, calendar: KronosLocale.calendar)
                let defaults = ListScopeDefaults.apply(scope: scopeKind(for: scope),
                                                        explicitDueDay: explicitDue, today: today,
                                                        isWaiting: isWaiting, savedViewHome: savedViewHome)
                // Typed in a view that belongs to a project, with no destination of its own: that project.
                if project == nil, result.destination == nil, let home = defaults.projectID {
                    project = projects.first { $0.id == home }
                }
                let task = store.create(title: result.title, notes: "", project: project,
                                        status: defaults.status, priority: result.priority,
                                        dueDay: defaults.dueDay)
                if let areaID = areaID ?? (project == nil ? defaults.areaID : nil) {
                    store.update(task.id) { $0.areaID = areaID }
                }
                if let labelName = result.labelName {
                    let label = store.label(named: labelName)
                    store.update(task.id) { $0.labels?.append(label) }
                    used.append(.label(labelName))
                }
                if let effort = result.effort { store.setEffort(task.id, effort) }
                if let repeatPhrase, let first = task.dueDay {
                    store.setRecurrence(task.id, repeatPhrase.rule(firstDue: first, calendar: KronosLocale.calendar).wireFormat)
                }
                if made.isEmpty {
                    // Never an empty reference (a chip that can never open).
                    let usable = links.filter { !$0.reference.isEmpty }
                    if !usable.isEmpty {
                        store.update(task.id) { t in t.notes = usable.reduce(t.notes) { $1.appending(to: $0) } }
                    }
                }
                if !item.subtasks.isEmpty { store.addSubtasks(item.subtasks, to: task.id) }
                if let p = project, result.destination != nil { used.append(.project(p.id)) }
                if let a = areaID, result.destination != nil { used.append(.area(a)) }
                made.append(task)
            }
        }
        if !made.isEmpty {
            EntryRecents().record(used)
            model.didMutate()
        }
        return made
    }

    /// `ListScope` (Kronos/Shared/UIContract.swift) -> Core's app-agnostic mirror of it, case
    /// for case.
    static func scopeKind(for scope: ListScope?) -> QuickAddScopeKind? {
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

// Natural-syntax text -> planned tasks, for every surface that has no entry field of its own:
// the Services menu, App Intents, MCP `create_task` (`text`) and Capture. One function, so the
// same sentence means the same task everywhere:
//   TaskOutline (indent / bullet / "a > b" subtasks) -> EntryDraft per task line (grammar v2).
// Pure: it reads a directory of names, never a store, so a test builds the directory by hand.
import Foundation

public struct EntryPlannedTask: Equatable, Sendable {
    /// The outline line this task was read from (tokens still in it).
    public var line: String
    public var subtasks: [String]
    public var resolved: EntryResolved

    public init(line: String, subtasks: [String], resolved: EntryResolved) {
        self.line = line
        self.subtasks = subtasks
        self.resolved = resolved
    }

    public var title: String { resolved.title }
}

public enum EntryText {
    /// One planned task per outline line that has a title left after its tokens are removed.
    /// `pills` are defaults for every line (a destination, a priority ...); a token typed in a
    /// line overrides the pill of its slot.
    public static func plan(_ text: String, directory: EntryDirectory, today: Int,
                            pills: [EntryPill] = [],
                            languages: [String] = QuickAddParser.defaultLanguages,
                            calendar: Calendar = .current) -> [EntryPlannedTask] {
        TaskOutline.parse(text).compactMap { item in
            let resolved = EntryDraft.resolve(text: item.line, pills: pills, directory: directory,
                                              today: today, languages: languages, calendar: calendar)
            guard !resolved.title.isEmpty else { return nil }
            return EntryPlannedTask(line: item.line, subtasks: item.subtasks, resolved: resolved)
        }
    }

    /// A project or area named as plain text (an intent parameter, not a `#token`): the best
    /// match by the same tiers the parser uses, up to "contains", ties by project before area.
    /// Nil for an empty name or no match; never a create row.
    public static func destination(named name: String, directory: EntryDirectory) -> EntryDestination? {
        let key = EntryMatcher.normalize(name)
        guard !key.isEmpty else { return nil }
        guard let hit = EntryMatcher.rank(key: key, projects: directory.projects, areas: directory.areas,
                                          maxTier: .contains).first else { return nil }
        return EntryDestination(kind: hit.kind, name: hit.name.name, id: hit.name.id)
    }

    /// The defaults an App Intent passes next to its text: a project or area named as plain
    /// text (found with `destination(named:)`, ignored when nothing matches), a priority and a
    /// due day. Fed to `plan` as pills, so a token typed in the text still overrides them.
    public static func intentPills(projectName: String?, priorityRaw: Int, dueDay: Int?,
                                   directory: EntryDirectory) -> [EntryPill] {
        var out: [EntryPill] = []
        if let name = projectName, let d = destination(named: name, directory: directory) { out.append(.destination(d)) }
        if let p = KPriority(rawValue: priorityRaw), p != .none { out.append(.priority(p)) }
        if let day = dueDay { out.append(.due(day)) }
        return out
    }

    /// The tasks an App Intent creates from its text and optional defaults. Text that is nothing
    /// but tokens ("#home") keeps the whole text as one task's title rather than creating nothing.
    public static func intentPlans(text: String, projectName: String?, priorityRaw: Int, dueDay: Int?,
                                   directory: EntryDirectory, today: Int) -> [EntryPlannedTask] {
        let pills = intentPills(projectName: projectName, priorityRaw: priorityRaw, dueDay: dueDay, directory: directory)
        let plans = plan(text, directory: directory, today: today, pills: pills)
        if !plans.isEmpty { return plans }
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return [] }
        let bare = EntryDraft.resolve(text: "", pills: pills, directory: directory, today: today)
        return [EntryPlannedTask(line: title, subtasks: [],
                                 resolved: EntryResolved(title: title, chips: bare.chips))]
    }

    /// What a Services selection becomes: the first non-empty line is the task line (parsed by
    /// the caller through `plan`), every other line is the task's notes, joined with newlines.
    public static func servicesSplit(_ text: String) -> (line: String, notes: String)? {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = lines.first else { return nil }
        return (first, lines.dropFirst().joined(separator: "\n"))
    }

    /// The pills of one Capture proposal, in slot order: what the pasted line was read as.
    /// A project name that is not an existing project still shows (Capture creates nothing
    /// until the user accepts the row).
    public static func pills(for task: ProposedTask) -> [EntryPill] {
        var out: [EntryPill] = []
        if let p = task.projectName, !p.isEmpty { out.append(.destination(EntryDestination(kind: .project, name: p))) }
        for l in task.labelNames where !l.isEmpty { out.append(.label(l)) }
        if task.priority != .none { out.append(.priority(task.priority)) }
        if task.effort != .none { out.append(.effort(task.effort)) }
        if let d = task.dueDay { out.append(.due(d)) }
        return out
    }
}

public extension TaskStoring {
    /// Names of every project, area and label, for `EntryText.plan` (no recency: the app's
    /// own `EntryCatalog` adds that for the surfaces that rank by recent use).
    func entryDirectory() -> EntryDirectory {
        EntryDirectory(projects: allProjects().map { EntryName($0.name, id: $0.id) },
                       areas: allAreas().map { EntryName($0.name, id: $0.id) },
                       labels: labels().map { EntryName($0.name, id: $0.id) })
    }
}

public extension TaskStoring {
    /// Creates one task per plan, as ONE undo step: project or area from the destination, priority,
    /// due day, effort, label and the outline's subtasks. Used by the App Intents; the quick add
    /// panel, the inline row and the URL scheme go through the app's `QuickAddCreate`, which adds
    /// list scope defaults and new-project creation on top.
    @discardableResult
    func createTasks(from plans: [EntryPlannedTask], status: KStatus = .todo, undoName: String) -> [KTask] {
        var made: [KTask] = []
        groupedUndo(undoName) {
            for plan in plans {
                let r = plan.resolved
                var project: KProject?
                var areaID: UUID?
                if let d = r.destination {
                    switch d.kind {
                    case .project: project = d.id.flatMap { id in allProjects().first { $0.id == id } }
                    case .area: areaID = d.id
                    }
                }
                let task = create(title: r.title, notes: "", project: project, status: status,
                                  priority: r.priority, dueDay: r.dueDay)
                if let areaID { update(task.id) { $0.areaID = areaID } }
                if let effort = r.effort { setEffort(task.id, effort) }
                if let labelName = r.labelName { addLabel(label(named: labelName), to: task.id) }
                if !plan.subtasks.isEmpty { addSubtasks(plan.subtasks, to: task.id) }
                made.append(task)
            }
        }
        return made
    }
}

import Foundation

/// The plain text a task row puts on a drag, for any text target (a terminal, an agent prompt,
/// a note): title, the attributes that are set, notes, the steps as a checklist, and the
/// `kronos://open?id=` link as the last line. Pure and AppKit-free so it is unit-testable.
public enum TaskDragText {
    /// Longest notes block that leaves the app; the rest is replaced by a marker line.
    public static let notesLimit = 4000
    public static let truncationMarker = "[notes truncated]"

    public struct Step: Equatable, Sendable {
        public var title: String
        public var isDone: Bool
        public init(title: String, isDone: Bool) {
            self.title = title
            self.isDone = isDone
        }
    }

    public struct Input: Equatable, Sendable {
        public var id: UUID
        public var title: String
        public var status: KStatus
        public var priority: KPriority
        public var dueDay: Int?
        public var plannedDay: Int?
        public var projectName: String?
        public var areaName: String?
        public var labels: [String]
        public var notes: String
        public var steps: [Step]

        public init(id: UUID, title: String, status: KStatus = .todo, priority: KPriority = .none,
                    dueDay: Int? = nil, plannedDay: Int? = nil, projectName: String? = nil,
                    areaName: String? = nil, labels: [String] = [], notes: String = "", steps: [Step] = []) {
            self.id = id
            self.title = title
            self.status = status
            self.priority = priority
            self.dueDay = dueDay
            self.plannedDay = plannedDay
            self.projectName = projectName
            self.areaName = areaName
            self.labels = labels
            self.notes = notes
            self.steps = steps
        }

        /// Reads everything it needs off the task and its relationships; call on the main actor.
        public init(task: KTask) {
            self.init(id: task.id, title: task.title, status: task.status, priority: task.priority,
                      dueDay: task.dueDay, plannedDay: task.plannedDay,
                      projectName: task.project?.name, areaName: task.project?.area?.name,
                      labels: (task.labels ?? []).map(\.name).sorted(),
                      notes: task.notes,
                      steps: task.orderedChildren.map { Step(title: $0.title, isDone: $0.status == .done) })
        }
    }

    public static func render(_ t: Input) -> String {
        var lines: [String] = []
        let title = oneLine(t.title)
        lines.append("# " + (title.isEmpty ? "Untitled" : title))

        var meta: [String] = []
        if t.status != .todo { meta.append("Status: " + statusName(t.status)) }
        if t.priority != .none { meta.append("Priority: " + priorityName(t.priority)) }
        if let d = t.dueDay { meta.append("Due: " + Day.iso(d)) }
        if let d = t.plannedDay { meta.append("Planned: " + Day.iso(d)) }
        if let project = t.projectName.map(oneLine), !project.isEmpty {
            if let area = t.areaName.map(oneLine), !area.isEmpty {
                meta.append("Project: \(project) (\(area))")
            } else {
                meta.append("Project: " + project)
            }
        }
        let labels = t.labels.map(oneLine).filter { !$0.isEmpty }
        if !labels.isEmpty { meta.append("Labels: " + labels.joined(separator: ", ")) }
        lines.append(contentsOf: meta)

        let notes = clippedNotes(t.notes)
        if !notes.isEmpty {
            lines.append("")
            lines.append("Notes:")
            lines.append(notes)
        }

        let steps = t.steps.filter { !oneLine($0.title).isEmpty }
        if !steps.isEmpty {
            lines.append("")
            lines.append("Steps:")
            for s in steps { lines.append((s.isDone ? "- [x] " : "- [ ] ") + oneLine(s.title)) }
        }

        lines.append("")
        lines.append(TaskLink.string(for: t.id))
        return lines.joined(separator: "\n")
    }

    // MARK: - Pieces

    /// Collapses any run of whitespace, newlines included, so one field stays one line.
    static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func clippedNotes(_ raw: String) -> String {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > notesLimit else { return text }
        let head = String(text.prefix(notesLimit)).trimmingCharacters(in: .whitespacesAndNewlines)
        return head + "\n" + truncationMarker
    }

    static func statusName(_ s: KStatus) -> String {
        switch s {
        case .todo: return "to do"
        case .inProgress: return "in progress"
        case .waiting: return "waiting"
        case .someday: return "someday"
        case .done: return "done"
        case .canceled: return "canceled"
        }
    }

    static func priorityName(_ p: KPriority) -> String {
        switch p {
        case .none: return "none"
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        case .urgent: return "urgent"
        }
    }
}

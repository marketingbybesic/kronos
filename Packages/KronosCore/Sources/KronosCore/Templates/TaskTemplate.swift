// Task templates (w22e). A template is a reusable task shape: title + notes + subtasks +
// project + priority + effort + estimate. NO dates (a template that remembered "due Friday"
// would be wrong every week). Persisted as JSON by the app (`TemplateStore`, one file per
// bundle folder), never in SwiftData: no schema change, demo and real never share one.

import Foundation

public struct TaskTemplate: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// What the user types after `/` in quick add. Unique-ish, case and accent insensitive.
    public var name: String
    public var title: String
    public var notes: String
    public var subtasks: [String]
    /// The project by id, with its name as a fallback so an import on another machine can
    /// still find it (project ids differ between stores, names mostly do not).
    public var projectID: UUID?
    public var projectName: String?
    public var priorityRaw: Int
    public var effortRaw: Int
    public var estimateMinutes: Int?
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, title: String, notes: String = "",
                subtasks: [String] = [], projectID: UUID? = nil, projectName: String? = nil,
                priorityRaw: Int = KPriority.none.rawValue, effortRaw: Int = KEffort.none.rawValue,
                estimateMinutes: Int? = nil, createdAt: Date = Date()) {
        self.id = id; self.name = name; self.title = title; self.notes = notes
        self.subtasks = subtasks; self.projectID = projectID; self.projectName = projectName
        self.priorityRaw = priorityRaw; self.effortRaw = effortRaw
        self.estimateMinutes = estimateMinutes; self.createdAt = createdAt
    }

    // Tolerant decoding: a hand-edited or older file with missing keys still loads.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? title
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        subtasks = try c.decodeIfPresent([String].self, forKey: .subtasks) ?? []
        projectID = try c.decodeIfPresent(UUID.self, forKey: .projectID)
        projectName = try c.decodeIfPresent(String.self, forKey: .projectName)
        priorityRaw = try c.decodeIfPresent(Int.self, forKey: .priorityRaw) ?? KPriority.none.rawValue
        effortRaw = try c.decodeIfPresent(Int.self, forKey: .effortRaw) ?? KEffort.none.rawValue
        estimateMinutes = try c.decodeIfPresent(Int.self, forKey: .estimateMinutes)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

/// The on-disk shape: a versioned wrapper so the file can grow fields later.
public struct TemplateFile: Codable, Equatable, Sendable {
    public var version: Int
    public var templates: [TaskTemplate]
    public init(version: Int = 1, templates: [TaskTemplate]) {
        self.version = version; self.templates = templates
    }

    public static let fileName = "templates.json"

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Missing file = no templates. A file that exists but cannot be parsed THROWS: the caller
    /// must not overwrite it with an empty list (that would destroy what the user typed).
    public static func read(from url: URL) throws -> [TaskTemplate] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return [] }
        return try decoder().decode(TemplateFile.self, from: data).templates
    }

    public static func write(_ templates: [TaskTemplate], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try encoder().encode(TemplateFile(templates: templates))
        try data.write(to: url, options: .atomic)
    }
}

/// Quick add `/name rest` parsing. Pure, so the branches are testable without UI.
public enum TemplateQuery {

    /// The line is a template request when its first non-space character is `/`.
    public static func isTemplateInput(_ input: String) -> Bool {
        input.drop(while: { $0 == " " }).first == "/"
    }

    /// Text after the slash, leading spaces trimmed (`"/ wee"` and `"/wee"` both give `"wee"`).
    public static func queryText(_ input: String) -> String {
        guard isTemplateInput(input) else { return "" }
        return String(input.drop(while: { $0 == " " }).dropFirst()).trimmingLeadingSpaces()
    }

    /// Templates to list while typing: names that start with the first typed word first, then
    /// names that contain it. An empty query lists everything (alphabetical).
    public static func suggestions(for input: String, in templates: [TaskTemplate]) -> [TaskTemplate] {
        guard isTemplateInput(input) else { return [] }
        let text = KTextFold.fold(queryText(input))
        let sorted = templates.sorted { KTextFold.fold($0.name) < KTextFold.fold($1.name) }
        if text.isEmpty { return sorted }
        // Whole text first (multi-word names), then just the first word (`/wee call mom`).
        let firstWord = text.split(separator: " ", maxSplits: 1).first.map(String.init) ?? text
        var out: [TaskTemplate] = []
        for needle in [text, firstWord] {
            for t in sorted where KTextFold.fold(t.name).hasPrefix(needle) && !out.contains(t) { out.append(t) }
        }
        for t in sorted where KTextFold.fold(t.name).contains(firstWord) && !out.contains(t) { out.append(t) }
        return out
    }

    /// What Return should do: which template, and the remainder of the line to append to the
    /// created title. Nil when nothing matches (the caller then treats the line as plain text).
    /// 1. the longest template name that is a whole-word prefix of the text wins
    ///    (`/weekly review call mom` -> "weekly review", rest "call mom");
    /// 2. else the first typed word as a prefix of a name (`/wee call mom` -> "Weekly review").
    public static func resolve(_ input: String, in templates: [TaskTemplate])
        -> (template: TaskTemplate, rest: String)? {
        guard isTemplateInput(input) else { return nil }
        let raw = queryText(input)
        guard !raw.isEmpty else { return nil }
        let folded = KTextFold.fold(raw)

        var best: TaskTemplate?
        for t in templates {
            let n = KTextFold.fold(t.name)
            guard !n.isEmpty, folded == n || folded.hasPrefix(n + " ") else { continue }
            if best == nil || n.count > KTextFold.fold(best!.name).count { best = t }
        }
        if let t = best {
            return (t, remainder(of: raw, droppingWords: KTextFold.fold(t.name).split(separator: " ").count))
        }
        let firstWord = folded.split(separator: " ", maxSplits: 1).first.map(String.init) ?? folded
        let candidates = suggestions(for: "/" + firstWord, in: templates)
            .filter { KTextFold.fold($0.name).hasPrefix(firstWord) }
        guard let t = candidates.first else { return nil }
        return (t, remainder(of: raw, droppingWords: 1))
    }

    private static func remainder(of text: String, droppingWords n: Int) -> String {
        var words = text.split(separator: " ", omittingEmptySubsequences: true)[...]
        words = words.dropFirst(n)
        return words.joined(separator: " ")
    }
}

private extension String {
    func trimmingLeadingSpaces() -> String { String(drop(while: { $0 == " " })) }
}

@MainActor
extension TaskStore {

    /// Snapshot a task (with its subtasks) as a template. Dates are deliberately not copied.
    public func makeTemplate(from id: UUID, name: String? = nil) -> TaskTemplate? {
        guard let t = task(id) else { return nil }
        let clean = (name ?? t.title).trimmingCharacters(in: .whitespacesAndNewlines)
        return TaskTemplate(name: clean.isEmpty ? t.title : clean, title: t.title, notes: t.notes,
                            subtasks: t.orderedSubtasks.map(\.title),
                            projectID: t.projectID, projectName: t.project?.name,
                            priorityRaw: t.priorityRaw, effortRaw: t.effortRaw,
                            estimateMinutes: t.estimateMinutes)
    }

    /// Create a task from a template in ONE undo step. `rest` (what the user typed after the
    /// template name) is appended to the title. The task is not auto-triaged away from the
    /// template's own fields: `create` posts `.kronosTaskDidCreate`, and auto-triage is
    /// fill-only, so a priority/effort/estimate the template carries is kept.
    @discardableResult
    public func createFromTemplate(_ tpl: TaskTemplate, rest: String = "",
                                    status: KStatus = .todo, dueDay: Int? = nil) -> KTask {
        let extra = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = extra.isEmpty ? tpl.title : tpl.title + " " + extra
        let projects = allProjects()
        let project = tpl.projectID.flatMap { pid in projects.first { $0.id == pid } }
            ?? tpl.projectName.flatMap { n in projects.first { KTextFold.fold($0.name) == KTextFold.fold(n) } }
        var created: KTask!
        groupedUndo("New from Template") {
            created = create(title: title, notes: tpl.notes, project: project, status: status,
                             priority: KPriority(rawValue: tpl.priorityRaw) ?? .none, dueDay: dueDay)
            created.effortRaw = tpl.effortRaw
            created.estimateMinutes = tpl.estimateMinutes
            for s in tpl.subtasks { addSubtask(created.id, title: s) }
            saveContext()
        }
        return created
    }
}

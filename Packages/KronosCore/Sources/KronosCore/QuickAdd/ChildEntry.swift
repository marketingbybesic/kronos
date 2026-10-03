// The entry grammar for a SUBTASK (a child task): everything a task line takes except where it
// lives. `@label`, `!` priority, `*` effort and date words work as for a task; `#project` is
// never resolved (a child always lives where its parent lives), so a typed `#word` stays
// literal text and is reported as `ignoredDestination` for the UI to show as an ignored pill.
// The `a > b` subtask syntax is not read either: a child cannot have children, so every line
// is one child and a " > " in it is part of its title.
// Pure: names in, drafts out; the store side is `TaskStoring.addChildren`.
import Foundation

/// One child task read from one line of text.
public struct ChildEntryDraft: Equatable, Sendable {
    public var title: String
    public var dueDay: Int?
    public var priority: KPriority
    public var effort: KEffort?
    public var labelName: String?
    /// A `#word` that was typed and ignored (left in the title).
    public var ignoredDestination: String?

    public init(title: String, dueDay: Int? = nil, priority: KPriority = .none, effort: KEffort? = nil,
                labelName: String? = nil, ignoredDestination: String? = nil) {
        self.title = title
        self.dueDay = dueDay
        self.priority = priority
        self.effort = effort
        self.labelName = labelName
        self.ignoredDestination = ignoredDestination
    }
}

public enum ChildEntry {

    /// The directory a child line is read against: labels only, so no `#` can ever resolve.
    public static func directory(from full: EntryDirectory) -> EntryDirectory {
        EntryDirectory(projects: [], areas: [], labels: full.labels)
    }

    /// Whether a pill is something a child can carry (everything but a destination).
    public static func allows(_ pill: EntryPill) -> Bool {
        switch pill {
        case .destination, .repeats: return false
        default: return true
        }
    }

    /// The raw lines of `text`, trimmed, empty ones dropped. No outline reading: indentation,
    /// bullets and " > " do not create structure.
    public static func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The text merged with committed pills for one line, as the pills row shows it.
    public static func resolve(line: String, pills: [EntryPill], directory: EntryDirectory, today: Int,
                               languages: [String] = QuickAddParser.defaultLanguages,
                               calendar: Calendar = .current, lineOffset: Int = 0) -> EntryResolved {
        EntryDraft.resolve(text: line, pills: pills.filter(allows), directory: Self.directory(from: directory),
                           today: today, languages: languages, calendar: calendar, lineOffset: lineOffset)
    }

    /// One draft per line that still has a title once its tokens are taken out. `pills` are
    /// defaults for every line (a token typed in a line overrides the pill of its slot).
    public static func drafts(_ text: String, pills: [EntryPill] = [], directory: EntryDirectory, today: Int,
                              languages: [String] = QuickAddParser.defaultLanguages,
                              calendar: Calendar = .current) -> [ChildEntryDraft] {
        lines(text).compactMap { line in
            let r = resolve(line: line, pills: pills, directory: directory, today: today,
                            languages: languages, calendar: calendar)
            guard !r.title.isEmpty else { return nil }
            return ChildEntryDraft(title: r.title, dueDay: r.dueDay, priority: r.priority, effort: r.effort,
                                   labelName: r.labelName, ignoredDestination: r.unresolvedDestination?.text)
        }
    }
}

public extension TaskStoring {
    /// Creates one child per draft under `parentID` as ONE undo step: title, due day, priority,
    /// effort and label together, so a single undo removes the whole entry. Empty array and a
    /// missing or nested parent create nothing and push nothing.
    @discardableResult
    func addChildren(to parentID: UUID, drafts: [ChildEntryDraft], undoName: String) -> [KTask] {
        var made: [KTask] = []
        groupedUndo(undoName) {
            for d in drafts {
                guard let c = addChild(to: parentID, title: d.title, dueDay: d.dueDay, priority: d.priority) else { continue }
                if let effort = d.effort { setEffort(c.id, effort) }
                if let name = d.labelName { addLabel(label(named: name), to: c.id) }
                made.append(c)
            }
        }
        return made
    }

    /// One child with fields, one undo step (see `addChildren`).
    @discardableResult
    func addChild(to parentID: UUID, title: String, fields: ChildEntryDraft, undoName: String) -> KTask? {
        var d = fields
        d.title = title
        return addChildren(to: parentID, drafts: [d], undoName: undoName).first
    }
}

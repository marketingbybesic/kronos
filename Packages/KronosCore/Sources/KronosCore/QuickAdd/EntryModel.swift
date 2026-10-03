import Foundation

// Value types of the entry grammar (parser v2 + suggestion engine). Pure data: no store, no
// UI. Every range is a half-open range of UTF-16 offsets into the text it was computed from,
// the unit `NSTextView` and `NSRange` use, so the app can hand a caret in and apply a range
// out without converting.

/// A name the grammar can resolve to: a project, an area or a label. `id` is carried through
/// untouched so the caller can find the real row without matching on the name again.
public struct EntryName: Hashable, Sendable {
    public var name: String
    public var id: UUID?
    /// Last time the user filed something here. Only breaks ties between equally good
    /// matches (more recent first); never changes which tier a match is in.
    public var lastUsed: Date?

    public init(_ name: String, id: UUID? = nil, lastUsed: Date? = nil) {
        self.name = name
        self.id = id
        self.lastUsed = lastUsed
    }
}

/// Everything the `#` and `@` tokens can resolve against, in list order. Archived projects
/// are the caller's business: pass only the ones that should be targetable.
public struct EntryDirectory: Sendable {
    public var projects: [EntryName]
    public var areas: [EntryName]
    public var labels: [EntryName]

    public init(projects: [EntryName] = [], areas: [EntryName] = [], labels: [EntryName] = []) {
        self.projects = projects
        self.areas = areas
        self.labels = labels
    }
}

/// Where a task goes: a project or an area. `isNew` marks a destination that does not exist
/// yet ("Create project 'X'"): the caller creates it when the entry is submitted, never while
/// the user is still typing.
public struct EntryDestination: Hashable, Sendable {
    public enum Kind: Sendable { case project, area }
    public var kind: Kind
    public var name: String
    public var id: UUID?
    public var isNew: Bool

    public init(kind: Kind, name: String, id: UUID? = nil, isNew: Bool = false) {
        self.kind = kind
        self.name = name
        self.id = id
        self.isNew = isNew
    }
}

/// One resolved attribute of the entry, as shown in the pills row.
public enum EntryPill: Hashable, Sendable {
    case destination(EntryDestination)
    case label(String)
    case priority(KPriority)
    case effort(KEffort)
    case due(Int)
    /// "every week" / "svaki tjedan": the task repeats (RepeatPhrase.swift).
    case repeats(RepeatPhrase)

    /// A task has at most one of each; a later pill of the same slot replaces an earlier one.
    public enum Slot: Int, CaseIterable, Sendable { case destination, label, priority, effort, due, repeats }

    public var slot: Slot {
        switch self {
        case .destination: return .destination
        case .label: return .label
        case .priority: return .priority
        case .effort: return .effort
        case .due: return .due
        case .repeats: return .repeats
        }
    }
}

/// A token the parser consumed out of the text. `range` covers the whole token including its
/// sigil (and, for a multi-word `#hit list`, every word of it).
public struct EntryToken: Equatable, Sendable {
    public var range: Range<Int>
    public var pill: EntryPill

    public init(range: Range<Int>, pill: EntryPill) {
        self.range = range
        self.pill = pill
    }
}

/// A `#word` that matched nothing. It stays in the title as literal text; the UI offers to
/// create a project of that name.
public struct EntryUnresolved: Equatable, Sendable {
    /// The literal word as typed, e.g. `#acme-skola`.
    public var text: String
    public var range: Range<Int>
    /// The name it would create: sigil dropped, dashes read as spaces.
    public var name: String

    public init(text: String, range: Range<Int>, name: String) {
        self.text = text
        self.range = range
        self.name = name
    }
}

/// What the grammar made of one line of text.
public struct EntryParse: Equatable, Sendable {
    /// Remaining words, single-spaced.
    public var title: String
    /// Consumed tokens, in text order.
    public var tokens: [EntryToken]
    public var unresolvedDestination: EntryUnresolved?

    public init(title: String, tokens: [EntryToken], unresolvedDestination: EntryUnresolved? = nil) {
        self.title = title
        self.tokens = tokens
        self.unresolvedDestination = unresolvedDestination
    }

    public func token(_ slot: EntryPill.Slot) -> EntryToken? { tokens.first { $0.pill.slot == slot } }

    public var destination: EntryDestination? {
        if case .destination(let d)? = token(.destination)?.pill { return d }
        return nil
    }
    public var labelName: String? {
        if case .label(let n)? = token(.label)?.pill { return n }
        return nil
    }
    public var priority: KPriority {
        if case .priority(let p)? = token(.priority)?.pill { return p }
        return .none
    }
    public var effort: KEffort? {
        if case .effort(let e)? = token(.effort)?.pill { return e }
        return nil
    }
    public var dueDay: Int? {
        if case .due(let d)? = token(.due)?.pill { return d }
        return nil
    }
    public var repeatPhrase: RepeatPhrase? {
        if case .repeats(let r)? = token(.repeats)?.pill { return r }
        return nil
    }
}

/// Where a displayed pill came from: a token still sitting in the text, or one the user
/// committed earlier (accepted suggestion, prefilled destination).
public enum EntryChipSource: Equatable, Sendable {
    case typed(Range<Int>)
    case committed
}

public struct EntryChip: Equatable, Sendable {
    public var pill: EntryPill
    public var source: EntryChipSource

    public init(pill: EntryPill, source: EntryChipSource) {
        self.pill = pill
        self.source = source
    }
}

/// Text plus committed pills, merged: what a submit creates and what the pills row shows.
public struct EntryResolved: Equatable, Sendable {
    public var title: String
    /// One chip per slot in slot order (destination, label, priority, effort, due).
    public var chips: [EntryChip]
    public var unresolvedDestination: EntryUnresolved?

    public init(title: String, chips: [EntryChip], unresolvedDestination: EntryUnresolved? = nil) {
        self.title = title
        self.chips = chips
        self.unresolvedDestination = unresolvedDestination
    }

    public func chip(_ slot: EntryPill.Slot) -> EntryChip? { chips.first { $0.pill.slot == slot } }

    public var destination: EntryDestination? {
        if case .destination(let d)? = chip(.destination)?.pill { return d }
        return nil
    }
    public var labelName: String? {
        if case .label(let n)? = chip(.label)?.pill { return n }
        return nil
    }
    public var priority: KPriority {
        if case .priority(let p)? = chip(.priority)?.pill { return p }
        return .none
    }
    public var effort: KEffort? {
        if case .effort(let e)? = chip(.effort)?.pill { return e }
        return nil
    }
    public var dueDay: Int? {
        if case .due(let d)? = chip(.due)?.pill { return d }
        return nil
    }
    public var repeatPhrase: RepeatPhrase? {
        if case .repeats(let r)? = chip(.repeats)?.pill { return r }
        return nil
    }
    public var pills: [EntryPill] { chips.map(\.pill) }
}

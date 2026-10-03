// Notes and `waitsOnIDs` are whole-value fields: with two devices editing the same task, the
// later save used to replace the other side's text or dependency list without a trace. An edit
// now remembers the value it STARTED from (the base). On save, when the stored value moved away
// from the base in the meantime, the other side's change is kept: text is appended as its own
// block under a header line, dependency ids are merged as a set.

import Foundation

/// Three-way merge of a notes text.
public enum TextConflictMerge {
    public enum Outcome: Equatable, Sendable {
        /// Nobody else changed the text: `mine` is saved as typed.
        case clean(String)
        /// The stored text changed under the edit; the result keeps both sides.
        case conflict(String)

        public var text: String {
            switch self { case .clean(let s), .conflict(let s): return s }
        }
    }

    /// - Parameters:
    ///   - base: the text when the edit began.
    ///   - mine: the text the person saves.
    ///   - theirs: the text stored now (another device or process may have changed it).
    ///   - header: the line that introduces the other side's block, already localised by the
    ///     caller (for example "— from iPhone —").
    public static func merge(base: String, mine: String, theirs: String, header: String) -> Outcome {
        if theirs == base || theirs == mine { return .clean(mine) }
        if mine == base { return .clean(theirs) }
        // Only what the other side added: a block that repeats the shared start would double it.
        let added: String
        if !base.isEmpty, theirs.hasPrefix(base) {
            added = String(theirs.dropFirst(base.count))
        } else {
            added = theirs
        }
        let block = added.trimmingCharacters(in: .whitespacesAndNewlines)
        if block.isEmpty || mine.contains(block) { return .clean(mine) }
        let head = mine.trimmingCharacters(in: .newlines)
        let joined = head.isEmpty ? header + "\n" + block : head + "\n\n" + header + "\n" + block
        return .conflict(joined)
    }
}

/// Three-way merge of an id list (what a task waits on).
public enum IDSetMerge {
    /// Keeps every id either side added and drops every id either side removed. Order: `mine`
    /// first, then what only `theirs` added, in its order. No duplicates.
    public static func merge(base: [UUID], mine: [UUID], theirs: [UUID]) -> [UUID] {
        let b = Set(base), m = Set(mine), t = Set(theirs)
        var out: [UUID] = []
        var seen = Set<UUID>()
        for id in mine where !(b.contains(id) && !t.contains(id)) && seen.insert(id).inserted {
            out.append(id)
        }
        for id in theirs where !b.contains(id) && !m.contains(id) && seen.insert(id).inserted {
            out.append(id)
        }
        return out
    }
}

@MainActor
extension TaskStore {

    /// Save the notes of task `id` typed in an editor that opened on `base`. When the stored
    /// notes changed in the meantime the other side is appended under `conflictHeader` instead
    /// of being overwritten. Returns the outcome (nil for a missing task). REGISTERS UNDO (one
    /// step; none when nothing changes).
    @discardableResult
    public func setNotes(_ id: UUID, _ notes: String, editBase base: String,
                         conflictHeader: String) -> TextConflictMerge.Outcome? {
        guard let t = task(id) else { return nil }
        let outcome = TextConflictMerge.merge(base: base, mine: notes, theirs: t.notes, header: conflictHeader)
        update(id) { $0.notes = outcome.text }
        return outcome
    }

    /// Save what task `id` waits on, from an editor that opened on `base`: ids the other side
    /// added or removed meanwhile are merged in rather than lost. Same validation and undo as
    /// `setWaitsOn(_:_:)`.
    @discardableResult
    public func setWaitsOn(_ id: UUID, _ ids: [UUID], editBase base: [UUID]) -> Bool {
        guard let t = task(id) else { return false }
        return setWaitsOn(id, IDSetMerge.merge(base: base, mine: ids, theirs: t.waitsOn))
    }
}

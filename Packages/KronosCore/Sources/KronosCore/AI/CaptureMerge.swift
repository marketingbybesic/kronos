// `CaptureModel.upgrade(with:)` (Kronos/Capture/CaptureModel.swift, app target) is a thin
// call into `CaptureMerge.merge`, which owns the merge seam AFTER the validator: the rule
// that decides what actually shows up in Review once an AI extraction result needs to be
// combined with the current deterministic rows. See CaptureMergeTests.swift for the two
// defect classes this design guards against:
//
// A. A paragraph is ONE deterministic row. If the model finds several tasks grounded in it,
//    matching only the FIRST AI task to the row and dropping every OTHER AI task whose
//    (re-pointed) sourceLine also contains that row's key would silently lose them, never
//    appended as their own rows.
//
// B. `ExtractOutlineValidator.validateExtractOutline` re-points a surviving AI task's
//    `sourceLine` to whichever ORIGINAL line it is grounded in — sometimes the row's own
//    (bullet-stripped) line, sometimes a NOTES line the splitter absorbed into that row (when
//    the notes line matches verbatim and wins the re-pointing race). Matching an AI task
//    against a row using ONLY the row's own `sourceLine` as the match key would miss an AI
//    task re-pointed to a NOTES line: it would append as a new row instead of matching its
//    own row, and the task would appear TWICE in Review (once as the untouched deterministic
//    row, once as a duplicate AI row).
//
// Root cause of both: matching by a single string (the row's bare `sourceLine`) instead of by
// the row's whole SOURCE BLOCK — its own line plus every line the deterministic splitter
// absorbed into it as notes (`NoteSplitter.notes(in:)`) or subtasks
// (`NoteSplitter.subtasks(in:)`). An AI task can be grounded in, and re-pointed to, ANY line in
// that block, not just the row's own first line.
//
// MERGE RULE:
//  - Group AI tasks by the deterministic row whose source BLOCK they are grounded in.
//  - Row edited by the user -> never replaced; AI tasks grounded in it are DROPPED (the user's
//    edit wins over the AI's improvement, which would otherwise silently overwrite what they typed).
//  - Row not edited, >= 1 AI task grounded in it -> the FIRST AI task replaces the row IN PLACE
//    (keeping `isTicked`), any remaining AI tasks for that SAME row are inserted directly AFTER
//    it in list order; outline-derived subtasks merge in without folded duplicates, as before.
//  - Row not edited, NO AI task grounded in it -> the row stays exactly as it is (this is what
//    keeps a real deterministic task alive when the validator drops the model's line for it,
//    e.g. a missing effort marker — tested by name below).
//  - AI task grounded in NO row -> appended at the end (unchanged from before).
//  - Never two rows with the same folded title from the same block.

import Foundation

/// The row shape `CaptureMerge` needs — a reduction of `Kronos/Capture/CaptureRow.swift` (which
/// lives in the app target and cannot be imported here) to exactly the fields the merge reads or
/// writes. `CaptureModel.upgrade` converts to/from the real `CaptureRow` at its one call site.
public struct CaptureMergeRow: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var proposal: ProposedTask
    public var isTicked: Bool
    public var isEdited: Bool
    public var subtasks: [String]

    public init(id: UUID, proposal: ProposedTask, isTicked: Bool, isEdited: Bool, subtasks: [String]) {
        self.id = id
        self.proposal = proposal
        self.isTicked = isTicked
        self.isEdited = isEdited
        self.subtasks = subtasks
    }
}

public enum CaptureMerge {

    /// Merges an AI extraction result into the current deterministic rows, per the binding rule
    /// in this file's header comment. Pure: no store access, no UUIDs generated for new rows
    /// (`newRowID` supplies them — `CaptureModel` passes `UUID.init`, a test passes a
    /// deterministic sequence so expectations can name an exact id).
    ///
    /// - Parameters:
    ///   - rows: the review list as it stands right now (deterministic pass plus any hand edits).
    ///   - aiTasks: `ExtractResult.tasks` — already validated, grounded, and `sourceLine`
    ///     re-pointed by `ExtractOutlineValidator.validateExtractOutline`.
    ///   - newRowID: id generator for a genuinely new row (an AI task grounded in no existing row).
    public static func merge(rows: [CaptureMergeRow], aiTasks: [ProposedTask],
                             newRowID: () -> UUID = UUID.init) -> [CaptureMergeRow] {
        // Each row's SOURCE BLOCK: its own sourceLine plus every line the deterministic split
        // folded into it as notes — matching against the whole block, not just the row's own
        // first line, is what keeps an AI task re-pointed to a notes line matched to its own
        // row (defect B above). Subtasks are not included as match targets: an AI task grounded
        // in a bulleted child line reads as ITS OWN task line grounded in that bullet, never as
        // "the same task as its parent", so widening the block to subtask lines would wrongly
        // merge siblings into one row.
        func block(for row: CaptureMergeRow) -> [String] {
            var lines = [row.proposal.sourceLine]
            if let notes = row.proposal.notes, !notes.isEmpty {
                lines.append(contentsOf: notes.components(separatedBy: "\n"))
            }
            return lines
        }
        let blocks = rows.map(block(for:))
        let foldedBlocks = blocks.map { $0.map(KTextFold.fold) }

        // Bucket every AI task under the FIRST row whose block contains it (by CONTAINMENT,
        // same relationship the old code used, just checked against the whole block now, not
        // one line) — an AI task grounded in no row's block goes in `unassigned`.
        var byRowIndex: [Int: [ProposedTask]] = [:]
        var unassigned: [ProposedTask] = []
        for task in aiTasks {
            let key = KTextFold.fold(task.sourceLine)
            if let rowIndex = foldedBlocks.firstIndex(where: { block in block.contains { $0.contains(key) || key.contains($0) } }) {
                byRowIndex[rowIndex, default: []].append(task)
            } else {
                unassigned.append(task)
            }
        }

        var out: [CaptureMergeRow] = []
        for (index, row) in rows.enumerated() {
            guard let grounded = byRowIndex[index], !grounded.isEmpty else {
                out.append(row)   // no AI task for this row: stays exactly as it is.
                continue
            }
            guard !row.isEdited else {
                out.append(row)   // the user's edit wins; the AI's tasks for this row are dropped.
                continue
            }
            var first = row
            let head = grounded[0]
            first.proposal = head
            first.isTicked = row.isTicked   // keep the tick across the replacement.
            if !head.subtasks.isEmpty {
                let existing = Set(first.subtasks.map(KTextFold.fold))
                first.subtasks.append(contentsOf: head.subtasks.filter { !existing.contains(KTextFold.fold($0)) })
            }
            out.append(first)
            // Any FURTHER AI tasks grounded in the SAME row become new rows, inserted directly
            // after it — never dropped, never merged into one row with a folded-duplicate
            // title check against what is already in `out` for this block.
            var seenTitlesInBlock: Set<String> = [KTextFold.fold(first.proposal.title)]
            for extra in grounded.dropFirst() {
                let foldedTitle = KTextFold.fold(extra.title)
                guard !seenTitlesInBlock.contains(foldedTitle) else { continue }
                seenTitlesInBlock.insert(foldedTitle)
                out.append(CaptureMergeRow(id: newRowID(), proposal: extra, isTicked: !extra.isDuplicateOfOpenTask,
                                           isEdited: false, subtasks: extra.subtasks))
            }
        }
        for task in unassigned {
            out.append(CaptureMergeRow(id: newRowID(), proposal: task, isTicked: !task.isDuplicateOfOpenTask,
                                       isEdited: false, subtasks: task.subtasks))
        }
        return out
    }
}

// The deterministic half of "paste notes -> tasks". PURE: no network, no
// store access, synchronous. Recognises common list shapes (bullets,
// numbered lines, checkboxes, plain lines) and runs each recognised task
// line through the existing `QuickAddParser` grammar so `#project @label
// !!! ~m sutra` still works exactly as it does in quick add.
//
// Structure (parent task vs. subtask vs. wrapped title continuation) is
// decided by `TaskOutline.dissect`'s indent/bullet-level rule — the SAME
// grammar `QuickAddParser`'s callers and the inline "Task > sub > sub" field
// use — so a note dump and a quick-add line describe subtasks identically.
// An older "any indented no-marker line is a title continuation" heuristic
// could never produce a subtask at all: every bulleted line, nested or not,
// became its own top-level task, flattening indented lines into separate
// tasks. A plain indented line with no bullet marker is now a subtask too
// (matching `TaskOutline`), not merged into the parent's title — a genuinely
// wrapped title in pasted text is rare enough, and now indistinguishable
// from a plain-text subtask, that treating it as a subtask is the more
// useful default (an empty/whitespace-only subtask line does not happen —
// `dissect` already trims and `TaskOutline.parse`'s own blank-line guard
// applies here too, see the `body.isEmpty` guard below).
import Foundation

public enum NoteSplitter {

    /// Proposals never exceed this; the remainder is counted, never dropped
    /// silently, even for a long paste (e.g. 40+ lines).
    public static let maxProposals = 30

    /// Split `text` into proposed tasks. Pure and synchronous — callers on
    /// the AI path still run this FIRST and only ask a model to improve on
    /// its result. `ProposedTask.subtasks` is always empty from THIS path —
    /// callers who need the deterministic outline's subtasks call
    /// `subtasks(in:)` with the same `text`, keyed by each proposal's own
    /// `sourceLine` (only the AI extract path itself sets `subtasks`
    /// directly on the proposal, since the model returns them as part of
    /// the same task object).
    ///
    /// - Parameters:
    ///   - text: the pasted note dump, Croatian and/or English.
    ///   - today: day number for `QuickAddParser`'s relative date tokens.
    ///   - calendar: injectable for tests; unused directly here but threaded
    ///     through for callers that need a pinned calendar for `today`.
    ///   - projectNames: existing project names; a heading ending in `:`
    ///     directly above a bullet group becomes that group's `projectName`
    ///     ONLY when it folds to one of these.
    public static func split(_ text: String,
                             today: Int,
                             calendar: Calendar = .current,
                             projectNames: [String] = []) -> [ProposedTask] {
        let rawLines = joinWrappedContinuations(text.components(separatedBy: .newlines))
        let groups = groupLines(rawLines, projectNames: projectNames)

        var proposals: [ProposedTask] = []
        let parser = QuickAddParser()
        for group in groups {
            guard proposals.count < maxProposals else { break }
            let parsed = parser.parse(group.line, projects: projectNames, today: today)
            guard !parsed.title.isEmpty else { continue }
            let effort = parsed.effort ?? .none
            proposals.append(ProposedTask(
                title: parsed.title,
                projectName: parsed.projectName ?? group.headingProject,
                labelNames: parsed.labelName.map { [$0] } ?? [],
                priority: parsed.priority,
                effort: effort,
                dueDay: parsed.dueDay,
                sourceLine: group.line))
        }
        return proposals
    }

    /// The subtask titles found under each recognised task line, keyed by
    /// that line's `sourceLine` (matching `ProposedTask.sourceLine` exactly,
    /// since both come from the same `groupLines` pass over the same text).
    /// Callers on the UI side use this to attach subtasks to the proposals
    /// `split(_:...)` returned, without `ProposedTask` itself carrying them.
    public static func subtasks(in text: String, projectNames: [String] = []) -> [String: [String]] {
        let rawLines = joinWrappedContinuations(text.components(separatedBy: .newlines))
        let groups = groupLines(rawLines, projectNames: projectNames)
        var out: [String: [String]] = [:]
        for group in groups where !group.subtasks.isEmpty {
            out[group.line] = group.subtasks
        }
        return out
    }

    /// The notes text found for each recognised task line, keyed by that
    /// line's `sourceLine` exactly like `subtasks(in:)` — a plain
    /// (non-bulleted) line right after a task line, up to a blank line, a
    /// subtask, or a heading, becomes that task's notes (joined by "\n" when
    /// there is more than one such line). A bulleted line in the same span
    /// stays a subtask, never notes (`groupLines`'s existing rule,
    /// untouched). Two consecutive UNMARKED lines with nothing separating
    /// them are indistinguishable here from "one task's notes, two
    /// sentences" vs. "two different plain-text tasks" — a blank line is
    /// what a real note dump uses to mark a new paragraph/task, so that is
    /// what closes a notes run; the AI extract path resolves the ambiguous
    /// case by actually reading the text (`PromptTemplates.extractSystem`'s
    /// own `notes` field).
    public static func notes(in text: String, projectNames: [String] = []) -> [String: String] {
        let rawLines = joinWrappedContinuations(text.components(separatedBy: .newlines))
        let groups = groupLines(rawLines, projectNames: projectNames)
        var out: [String: String] = [:]
        for group in groups where !group.notes.isEmpty {
            out[group.line] = group.notes.joined(separator: "\n")
        }
        return out
    }

    /// Capture-only pre-pass, run BEFORE `TaskOutline`'s own indent/bullet
    /// rule sees the text: joins an indented, unmarked line onto the
    /// bulleted line above it when it reads as a WRAPPED TITLE rather than a
    /// subtask — hard-wrapped pasted notes ("- Write the proposal\n  for the
    /// September delivery") are real Capture input, so this stays a merged
    /// title exactly as before, while every other
    /// indented shape (a bulleted child, a child under a non-bulleted
    /// parent, a capitalised or punctuation-terminated child) is left alone
    /// for `TaskOutline.parse`/`groupLines` to read as a subtask.
    /// `TaskOutline` itself stays pure and unmodified — quick add
    /// (`QuickAddCreate.swift`) calls `TaskOutline.parse` directly with no
    /// pre-pass, so a Tab-indented line there is ALWAYS a subtask, never a
    /// silently merged continuation.
    ///
    /// A line joins onto the previous one only when ALL of:
    ///  1. the previous (raw) line is a bulleted item (`bulletMarker` sees
    ///     `- `/`* `/`• `, not numbered — a numbered line's own continuation
    ///     shape is rarer and unproven, so this stays narrow),
    ///  2. this line is indented deeper than the previous line's own indent
    ///     level, with NO bullet/checkbox marker of its own,
    ///  3. this line's first letter is lowercase (`Character.isLowercase`,
    ///     which is true for Croatian diacritics too — č/ć/š/ž/đ all pass),
    ///  4. the previous line's trimmed text does NOT end with one of `. : ; ! ?`
    ///     (a sentence-ending or list-introducing previous line reads as
    ///     "done, what follows is new", never a wrapped continuation of it).
    static func joinWrappedContinuations(_ rawLines: [String]) -> [String] {
        var out: [String] = []
        for raw in rawLines {
            if let last = out.last, isWrappedContinuation(of: last, next: raw) {
                out[out.count - 1] = last + " " + raw.trimmingCharacters(in: .whitespaces)
            } else {
                out.append(raw)
            }
        }
        return out
    }

    private static let continuationStoppers: Set<Character> = [".", ":", ";", "!", "?"]

    static func isWrappedContinuation(of previousRaw: String, next nextRaw: String) -> Bool {
        let previousTrimmed = previousRaw.trimmingCharacters(in: .whitespaces)
        guard !previousTrimmed.isEmpty, let (previousMarker, _) = bulletMarker(previousTrimmed),
              previousMarker == .bullet
        else { return false }   // (1) previous line must be a plain bulleted item.
        guard let stopper = previousTrimmed.last, !continuationStoppers.contains(stopper) else {
            return false   // (4) a sentence-ending previous line never continues.
        }

        let (previousLevel, _, _) = TaskOutline.dissect(previousRaw)
        let (nextLevel, nextIsBullet, nextBody) = TaskOutline.dissect(nextRaw)
        guard nextLevel > previousLevel, !nextIsBullet, bulletMarker(nextBody.trimmingCharacters(in: .whitespaces)) == nil else {
            return false   // (2) must be a deeper, unmarked line.
        }
        guard let firstLetter = nextBody.first(where: { $0.isLetter }), firstLetter.isLowercase else {
            return false   // (3) starts lowercase (Croatian diacritics count as letters).
        }
        return true
    }

    /// One recognised task line plus its subtasks (`TaskOutline`'s
    /// indent/bullet rule), the heading-derived project, if any, and any
    /// plain (non-bulleted) lines that followed it before the next task line
    /// or a blank line — the task's `notes`.
    private struct LineGroup {
        let line: String
        var subtasks: [String] = []
        let headingProject: String?
        var notes: [String] = []
    }

    /// Splits raw text into bullet/number/checkbox/plain-line groups.
    /// Skips blank lines, markdown headings (unless they name a project for
    /// the group below), horizontal rules, and lines shorter than 3 letters.
    /// Checked checkbox items (`- [x]`) are skipped entirely, since they are
    /// already done — as a task line AND as a subtask line. A line deeper
    /// than its parent (or bulleted at the same level right under a
    /// non-bulleted parent), per `TaskOutline.dissect`, becomes a subtask of
    /// the group above it instead of its own group. A plain (unmarked) line
    /// at the SAME level as its parent — the shape that used to fall through
    /// and become a bogus task of its own — becomes that task's notes
    /// instead, up to a blank line, subtask, or heading (`notesOpen`,
    /// separate from `hasParent`: ending a NOTES run must not reset the
    /// parent a bulleted subtask list below it still attaches to). See
    /// `notes(in:)`'s own doc comment for why "the next task line" alone
    /// cannot close a run here.
    private static func groupLines(_ rawLines: [String], projectNames: [String]) -> [LineGroup] {
        var groups: [LineGroup] = []
        var currentHeadingProject: String?
        var parentLevel = 0
        var parentIsBullet = false
        var hasParent = false
        var notesOpen = false

        for raw in rawLines {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                notesOpen = false
                continue   // a blank line does NOT reset the current parent — a subtask list may have blank lines between items in a pasted note — but it DOES end a notes run.
            }
            if isHorizontalRule(trimmed) {
                hasParent = false
                notesOpen = false
                continue
            }
            if let heading = markdownHeadingText(trimmed) {
                // A `#` markdown heading is never itself a task line, whether
                // or not it names a project; only a colon-terminated one can
                // set the group's project (checked the same way a plain
                // colon-heading line does, just below).
                setHeadingProjectIfKnown(heading, projectNames: projectNames, into: &currentHeadingProject)
                hasParent = false
                notesOpen = false
                continue
            }

            if trimmed.hasSuffix(":"), bulletMarker(trimmed) == nil, countLetters(trimmed) >= 3 {
                // A plain line ending in ':' with no bullet marker of its own
                // reads as a heading for the group below it (spec: "a heading
                // ending in ':' directly above a bullet group"), but ONLY
                // when it names a known project — otherwise it is left as a
                // heading with no project (never promoted into a task, since
                // titles ending in a bare ':' are not actionable text).
                setHeadingProjectIfKnown(String(trimmed.dropLast()), projectNames: projectNames,
                                        into: &currentHeadingProject)
                hasParent = false
                notesOpen = false
                continue
            }

            if isCheckedBox(trimmed) {
                notesOpen = false   // a skipped (done) line is structure, not prose — ends a notes run same as a blank line.
                continue   // done items are skipped entirely, as a task or a subtask.
            }
            let (level, dissectIsBullet, dissectBody) = TaskOutline.dissect(raw)

            // `bulletMarker`/numbered-line detection stays NoteSplitter's own
            // (it recognises `1. ` / `2) `, which `TaskOutline.dissect` does
            // not), but the INDENT LEVEL that decides parent-vs-subtask comes
            // from `dissect` so both agree on what counts as "nested".
            let marker = bulletMarker(trimmed)
            let isBullet = dissectIsBullet || marker != nil
            let body = marker?.1 ?? dissectBody

            let isSubtask = hasParent && (level > parentLevel || (level == parentLevel && isBullet && !parentIsBullet))
            if isSubtask {
                guard !groups.isEmpty, countLetters(body) >= 3 else { continue }
                // `sub > sub-sub` on one already-indented line: same inline split as the
                // parent line below, so a deeper "Task > sub > sub" grouping reads identically
                // whether typed on the parent or on a bulleted child.
                groups[groups.count - 1].subtasks.append(contentsOf: TaskOutline.split(body))
                notesOpen = false   // a subtask line ends a notes run for this parent (brief: "until the next task line / blank line" — a subtask reads as new structure, not more prose).
                continue
            }

            // A plain (unmarked) line at the parent's OWN level, directly under the task line
            // itself or continuing a notes run already open for it (`notesOpen` — set the
            // moment a task line or a notes line is read, cleared by anything that is NOT a
            // notes line: a blank line, a subtask, a heading — brief: "until the next task
            // line / blank line") — not deeper (a subtask, above) and not a bullet (also a
            // subtask, above): reads as descriptive text about the task rather than a fresh
            // task line, and becomes that task's notes instead of a bogus task of its own.
            if notesOpen, !isBullet, level == parentLevel, !groups.isEmpty, countLetters(body) >= 3 {
                groups[groups.count - 1].notes.append(body)
                continue
            }

            guard countLetters(body) >= 3 else { hasParent = false; notesOpen = false; continue }
            // "Task > sub > sub" on ONE line: the same inline grammar
            // `TaskOutline.parse` already uses for quick add and the inline field — reused
            // here (internal, same module) rather than re-implemented, so a pasted note and a
            // typed quick-add line describe "one line, several `>`-separated parts" identically.
            // The parser only ever sees the FIRST part as the task's own title/tokens; the rest
            // become subtasks immediately, never separate top-level proposals.
            let parts = TaskOutline.split(body)
            // A plain, UNBULLETED line of several sentences ("Call Alex about the invoice. He
            // asked for the PDF version, not the scan.") becomes a title of only its first
            // sentence, not the whole paragraph. The rest becomes this task's own notes, same
            // field a bulleted task's plain follow-up line already fills (`notesOpen`, above) —
            // so a paragraph and a bulleted task+description read the same way. Only applies to
            // the FIRST (title) part: `parts[0]` is what `splitFirstSentence` sees, never the
            // `>`-split subtask parts, and never a bulleted line (bulleted lines stay exactly
            // as before — `NoteSplitterWrappedContinuation`/`Notes`/`Subtasks` tests already
            // cover that shape).
            let (titleSentence, restSentences) = isBullet ? (parts[0], nil) : splitFirstSentence(parts[0])
            groups.append(LineGroup(line: titleSentence, subtasks: Array(parts.dropFirst()),
                                    headingProject: currentHeadingProject,
                                    notes: restSentences.map { [$0] } ?? []))
            parentLevel = level
            parentIsBullet = isBullet
            hasParent = true
            notesOpen = true   // the task line itself opens a notes run: the very next plain same-level line, if any, is notes.
        }
        return groups
    }

    /// True when `line` (after whitespace) is a CHECKED checkbox marker —
    /// `TaskOutline.dissect` strips `- [x] ` like any other bullet marker, so
    /// this checks the trimmed raw text directly rather than the already-
    /// stripped body, which no longer carries the distinction.
    private static func isCheckedBox(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        for box in ["- [x] ", "* [x] ", "• [x] ", "- [X] ", "* [X] ", "• [X] "] where t.hasPrefix(box) {
            return true
        }
        return false
    }

    private enum Marker { case bullet, numbered, uncheckedBox, checkedBox }

    /// Recognises `- `, `* `, `• `, `> `, `1. ` / `1) `, `- [ ]`, `- [x]`.
    /// Returns the marker kind and the remaining text with the marker
    /// stripped. `> ` is a LINE-START marker here — distinct from
    /// `TaskOutline.split`'s ` > ` INLINE
    /// separator used further down for "Task > sub > sub" on one line; a
    /// line typed as "> do the thing" reads as a bulleted subtask exactly
    /// like a `-`/`*`/`•` line would, never as a title fragment.
    private static func bulletMarker(_ line: String) -> (Marker, String)? {
        for box in ["- [ ] ", "* [ ] ", "• [ ] "] where line.hasPrefix(box) {
            return (.uncheckedBox, String(line.dropFirst(box.count)))
        }
        for box in ["- [x] ", "* [x] ", "• [x] ", "- [X] ", "* [X] ", "• [X] "] where line.hasPrefix(box) {
            return (.checkedBox, String(line.dropFirst(box.count)))
        }
        for prefix in ["- ", "* ", "• ", "> "] where line.hasPrefix(prefix) {
            return (.bullet, String(line.dropFirst(prefix.count)))
        }
        if let match = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
            return (.numbered, String(line[match.upperBound...]))
        }
        return nil
    }

    /// A markdown heading: one or more `#` followed by a space. Returns the
    /// heading text with the marker stripped, or nil if this is not one.
    private static func markdownHeadingText(_ line: String) -> String? {
        guard let match = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) else { return nil }
        return String(line[match.upperBound...])
    }

    /// Sets `slot` to the known project whose folded name matches `candidate`
    /// exactly, or to nil when no project matches — an arbitrary heading is
    /// never promoted into a fabricated project.
    private static func setHeadingProjectIfKnown(_ candidate: String, projectNames: [String],
                                                  into slot: inout String?) {
        let folded = KTextFold.fold(candidate.trimmingCharacters(in: .whitespaces))
        slot = projectNames.first { KTextFold.fold($0) == folded }
    }

    /// `---`, `***`, `___`, three or more repeats, nothing else on the line.
    private static func isHorizontalRule(_ line: String) -> Bool {
        line.range(of: #"^(-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression) != nil
    }

    private static func countLetters(_ s: String) -> Int {
        s.filter { $0.isLetter }.count
    }

    /// Splits `body` after its first sentence-ending punctuation (`.`/`!`/`?`) that is followed
    /// by a space and an uppercase letter — the same "real sentence boundary, not a decimal
    /// point or an abbreviation" shape `.`-terminated European dates and ellipses avoid by
    /// requiring an UPPERCASE letter right after the space (`25.9. sutra` never splits: the
    /// letter after the space is lowercase). Returns `(whole body, nil)` when there is no second
    /// sentence, so a single-sentence line is untouched — `deterministicSplitSingleSentence
    /// ParagraphHasNoNotes` (CaptureSyntaxTests.swift) is the guard against ever splitting one.
    static func splitFirstSentence(_ body: String) -> (title: String, rest: String?) {
        guard let match = body.range(of: #"[.!?]\s+(?=\p{Lu})"#, options: .regularExpression) else {
            return (body, nil)
        }
        let title = String(body[..<match.upperBound]).trimmingCharacters(in: .whitespaces)
        let rest = String(body[match.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard countLetters(rest) >= 3 else { return (body, nil) }
        return (title, rest)
    }
}

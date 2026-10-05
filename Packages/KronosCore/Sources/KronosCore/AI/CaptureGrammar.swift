// The deterministic grammar for "paste notes -> tasks" in Capture. PURE: text in, structure out.
//
// Rules, in the order a person would learn them:
//  1. Every non-empty line is a TASK. A short plain line is never swallowed as "notes", whatever
//     it starts with or ends with ("kupiti mlijeko", "Pay.", "Go").
//  2. A line is a SUBTASK of the task above it when it is indented deeper (tab, 2 or 4 spaces,
//     plain or bulleted), or starts with `>`, or starts with `-`/`*`/`•` directly under a task
//     that is NOT itself a bulleted line. `Task > sub > sub` on one line works too.
//  3. A list where every top-level line has the same bullet stays a list of tasks.
//  4. A blank line closes the group: the next line starts a NEW task, except a deeper-indented
//     bulleted line (or another indented line once the task already has subtasks).
//     Two or more blank lines also forget the `Project:` heading above.
//  5. `Name:` followed by lines is a task whose subtasks are those lines. It only acts as a
//     heading (sets the project) when `Name` is an existing project, and `#` markdown headings
//     never make tasks.
//  6. Notes only by an explicit marker line (`// text`, `note: text`, `NB: text`) under a task,
//     or the remainder of a multi-sentence plain line (`Call Alex. He wants the PDF.`).
//  7. Nothing disappears silently: skipped lines (too short, ticked `[x]`, no title after
//     tokens, over the cap) are reported in `CaptureOutline.dropped`.
//  8. Every item carries its own line index, so two identical titles keep their own subtasks.
//
// A paragraph (one long line, or several sentences in one line) is flagged `looksLikeProse`;
// Capture then asks the AI router to extract tasks from it and falls back to this result.
import Foundation

public struct CaptureItem: Equatable, Sendable {
    /// Title, tokens, notes and subtasks are all set on the proposal (`subtasks` too).
    public var proposal: ProposedTask
    public var subtasks: [String] { proposal.subtasks }
    /// Zero-based index of the source line this task came from.
    public var lineIndex: Int
    /// The line was a paragraph rather than a short task line.
    public var looksLikeProse: Bool
}

public struct DroppedLine: Equatable, Sendable {
    public enum Reason: String, Sendable { case tooShort, done, noTitle, overCap }
    public var text: String
    public var lineIndex: Int
    public var reason: Reason
}

public struct CaptureOutline: Equatable, Sendable {
    public var items: [CaptureItem]
    public var dropped: [DroppedLine]
    /// Tasks beyond `CaptureGrammar.maxItems` (also listed in `dropped` as `.overCap`).
    public var overflow: Int
    /// The paste reads as running text, not a list of lines: any paragraph line, or a long text
    /// that produced at most two tasks. The AI path is the right tool for it.
    public var looksLikeProse: Bool
}

public enum CaptureGrammar {

    public static let maxItems = 100
    /// A plain line longer than this reads as a paragraph.
    public static let proseLength = 100

    public static func parse(_ text: String,
                             today: Int,
                             projectNames: [String] = []) -> CaptureOutline {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines)
        let parser = QuickAddParser()
        var items: [CaptureItem] = []
        var dropped: [DroppedLine] = []
        var overflow = 0
        var headingProject: String?

        // The task the next line may attach to.
        var hasParent = false
        var parentLevel = 0
        var parentIsDashBullet = false
        var blankRun = 0
        // `true` while the current parent slot refers to an item that was capped away: its
        // subtasks are swallowed with it rather than attached to the wrong task.
        var parentCapped = false

        for (index, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { blankRun += 1; continue }
            let afterBlank = blankRun > 0
            if blankRun >= 2 { headingProject = nil }
            blankRun = 0

            if isHorizontalRule(trimmed) { hasParent = false; headingProject = nil; continue }
            if let heading = markdownHeadingText(trimmed) {
                headingProject = knownProject(heading, projectNames)
                hasParent = false
                continue
            }

            let (level, dissectBullet, dissectBody) = TaskOutline.dissect(raw)
            let numbered = numberedBody(trimmed)
            let isBullet = dissectBullet
            let isGreaterThan = isBullet && trimmed.hasPrefix(">")
            var body = numbered ?? dissectBody
            let isDashBullet = isBullet && !isGreaterThan

            if isCheckedBox(trimmed) {
                dropped.append(DroppedLine(text: trimmed, lineIndex: index, reason: .done))
                continue
            }

            // Explicit notes marker under a task.
            if !isBullet, numbered == nil, hasParent, let note = explicitNote(body) {
                guard !parentCapped, let last = items.indices.last else { continue }
                let joined = [items[last].proposal.notes, note].compactMap { $0 }.joined(separator: "\n")
                items[last].proposal.notes = joined
                continue
            }

            // `Name:` heading: only a known project name acts as a heading.
            if !isBullet, numbered == nil, body.hasSuffix(":") {
                let name = String(body.dropLast()).trimmingCharacters(in: .whitespaces)
                if let project = knownProject(name, projectNames) {
                    headingProject = project
                    hasParent = false
                    continue
                }
                body = name
            }

            // Subtask or new task?
            var isSubtask = false
            if hasParent {
                if afterBlank {
                    isSubtask = level > parentLevel
                        && (isBullet || !(items.last?.subtasks.isEmpty ?? true))
                } else if level > parentLevel {
                    isSubtask = true
                } else if level == parentLevel {
                    isSubtask = isGreaterThan || (isDashBullet && !parentIsDashBullet)
                }
            }

            if isSubtask {
                if parentCapped { continue }
                let pieces = TaskOutline.split(body)
                for piece in pieces {
                    guard piece.count >= 1 else { continue }
                    items[items.count - 1].proposal.subtasks.append(piece)
                }
                continue
            }

            // A new task line.
            let parts = TaskOutline.split(body)
            var title = parts[0]
            var notes: String?
            var prose = false
            if !isBullet, numbered == nil {
                let (first, rest) = NoteSplitter.splitFirstSentence(title)
                if let rest { title = first; notes = rest; prose = true }
                if title.count > proseLength { prose = true }
            } else if title.count > proseLength {
                prose = true
            }
            let parsed = parser.parse(title, projects: projectNames, today: today)
            guard !parsed.title.isEmpty else {
                dropped.append(DroppedLine(text: trimmed, lineIndex: index, reason: .noTitle))
                hasParent = false
                continue
            }
            guard parsed.title.count >= 2 else {
                dropped.append(DroppedLine(text: trimmed, lineIndex: index, reason: .tooShort))
                hasParent = false
                continue
            }

            parentLevel = level
            parentIsDashBullet = isDashBullet
            hasParent = true

            guard items.count < maxItems else {
                overflow += 1
                dropped.append(DroppedLine(text: trimmed, lineIndex: index, reason: .overCap))
                parentCapped = true
                continue
            }
            parentCapped = false
            let proposal = ProposedTask(
                title: parsed.title,
                projectName: parsed.projectName ?? headingProject,
                labelNames: parsed.labelName.map { [$0] } ?? [],
                priority: parsed.priority,
                effort: parsed.effort ?? .none,
                dueDay: parsed.dueDay,
                notes: notes,
                subtasks: Array(parts.dropFirst()),
                sourceLine: title)
            items.append(CaptureItem(proposal: proposal, lineIndex: index, looksLikeProse: prose))
        }

        let totalChars = text.trimmingCharacters(in: .whitespacesAndNewlines).count
        let proseShape = items.contains(where: \.looksLikeProse)
            || (totalChars > 200 && items.count <= 2)
        return CaptureOutline(items: items, dropped: dropped, overflow: overflow, looksLikeProse: proseShape)
    }

    // MARK: - Line classification

    /// `1. `, `2) ` prefix; the remaining text, or nil when the line is not numbered.
    private static func numberedBody(_ line: String) -> String? {
        guard let match = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) else { return nil }
        let rest = String(line[match.upperBound...]).trimmingCharacters(in: .whitespaces)
        return rest
    }

    private static func isCheckedBox(_ line: String) -> Bool {
        for box in ["- [x]", "* [x]", "• [x]", "- [X]", "* [X]", "• [X]"] where line.hasPrefix(box) { return true }
        return false
    }

    /// `// text`, `note: text`, `notes: text`, `NB: text`, `bilješka: text`, `napomena: text`.
    private static func explicitNote(_ body: String) -> String? {
        if body.hasPrefix("//") {
            let rest = body.dropFirst(2).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : rest
        }
        guard let colon = body.firstIndex(of: ":") else { return nil }
        let key = KTextFold.fold(String(body[..<colon]).trimmingCharacters(in: .whitespaces))
        guard ["nb", "note", "notes", "biljeska", "napomena"].contains(key) else { return nil }
        let rest = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }

    private static func markdownHeadingText(_ line: String) -> String? {
        guard let match = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) else { return nil }
        return String(line[match.upperBound...])
    }

    private static func knownProject(_ candidate: String, _ projectNames: [String]) -> String? {
        let folded = KTextFold.fold(candidate.trimmingCharacters(in: .whitespaces))
        return projectNames.first { KTextFold.fold($0) == folded }
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        line.range(of: #"^(-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression) != nil
    }
}

extension CaptureOutline {
    /// The proposals in line order, as the AI path's deterministic base result.
    public var proposals: [ProposedTask] { items.map(\.proposal) }
}

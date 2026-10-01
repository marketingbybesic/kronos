// The one rule for the "insert subtask marker" shortcut (Shift-Cmd-N inside an add field).
// `TaskOutline` reads ` > ` in the middle of a line as "next subtask" and `> ` at the start of a
// line as a bullet subtask of the line above, so the text to insert depends on where the caret is:
// after words it is " > " (a space on both sides, or the separator would not parse), on an empty
// line it is "> ". Spaces already next to the caret are never doubled.
import Foundation

public enum SubtaskMarker {

    /// The text to insert at the caret. `before` is everything in the field up to the caret,
    /// `after` everything behind it.
    public static func insertion(before: Substring, after: Substring) -> String {
        let line = before.split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
        let onEmptyLine = line.allSatisfy { $0 == " " || $0 == "\t" }
        let needsLeadingSpace = !onEmptyLine && !(before.last?.isWhitespace ?? true)
        let needsTrailingSpace = !(after.first.map { $0 == " " || $0 == "\t" } ?? false)
        return (needsLeadingSpace ? " " : "") + ">" + (needsTrailingSpace ? " " : "")
    }

    /// Pure form for tests and non-AppKit callers: the new text and the caret offset (in
    /// `Character`s) after the marker, for a caret at `caret` (a `Character` offset).
    public static func insert(into text: String, caret: Int) -> (text: String, caret: Int) {
        let clamped = max(0, min(caret, text.count))
        let idx = text.index(text.startIndex, offsetBy: clamped)
        let marker = insertion(before: text[..<idx], after: text[idx...])
        var out = text
        out.insert(contentsOf: marker, at: idx)
        return (out, clamped + marker.count)
    }
}

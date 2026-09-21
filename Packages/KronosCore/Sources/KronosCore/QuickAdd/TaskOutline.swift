// One outline grammar for every place a task can be typed (inline field, quick add, Capture):
//   one line:    Prepare the offer > find the template > fill in prices
//   many lines:  a line that is indented deeper than the task above it (Tab or spaces), or a
//                bulleted line under a plain line (`-`, `*`, `>`, `•`, `–`, `—`, or a checkbox),
//                is a SUBTASK of that task.
// A list where every line is bulleted at the same level stays a list of TASKS.
// Pure text in, structure out: the caller runs QuickAddParser on each task line.
import Foundation

public enum TaskOutline {
    public struct Item: Equatable, Sendable {
        public var line: String
        public var subtasks: [String]
        public init(line: String, subtasks: [String] = []) { self.line = line; self.subtasks = subtasks }
    }

    public static func parse(_ text: String) -> [Item] {
        var items: [Item] = []
        var parentLevel = 0
        var parentIsBullet = false
        for raw in text.components(separatedBy: .newlines) {
            guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let (level, isBullet, body) = dissect(raw)
            guard !body.isEmpty else { continue }
            let isSubtask = !items.isEmpty && (level > parentLevel || (level == parentLevel && isBullet && !parentIsBullet))
            if isSubtask {
                items[items.count - 1].subtasks.append(contentsOf: split(body))
            } else {
                let parts = split(body)
                items.append(Item(line: parts[0], subtasks: Array(parts.dropFirst())))
                parentLevel = level
                parentIsBullet = isBullet
            }
        }
        return items
    }

    /// "a > b > c" -> ["a", "b", "c"]. The separator needs a space on both sides, so "x>y" and
    /// "price > 100?" -like fragments with an empty side stay one piece.
    static func split(_ body: String) -> [String] {
        let parts = body.components(separatedBy: " > ").map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.contains(where: \.isEmpty) ? [body] : parts
    }

    /// Indent width (a tab counts as 4), whether the line starts with a list marker, and the text.
    static func dissect(_ raw: String) -> (level: Int, isBullet: Bool, body: String) {
        var level = 0
        var rest = Substring(raw)
        while let c = rest.first, c == " " || c == "\t" {
            level += c == "\t" ? 4 : 1
            rest = rest.dropFirst()
        }
        for marker in ["- [ ] ", "- [x] ", "- ", "* ", "> ", "• ", "– ", "— "] where rest.hasPrefix(marker) {
            return (level, true, rest.dropFirst(marker.count).trimmingCharacters(in: .whitespaces))
        }
        return (level, false, rest.trimmingCharacters(in: .whitespaces))
    }
}

// Coach/NotesLinks.swift — split out of AppleNotesBridge.swift, which went over the
// project's 500-line cap after adding `open(noteID:)`. `NoteLink`/`ContextLink` are pure
// text-encoding types with no dependency on the osascript machinery in that file, so they
// move here unchanged (same package, same import, same public API — no caller needed
// a change).
import Foundation

// MARK: - Note links (feature F.3)

/// Encodes/finds a `notes://<id>` line inside a task's notes text, so a task
/// can be linked to an Apple Note without a new stored field.
public enum NoteLink {
    private static let scheme = "notes://"

    /// A line to append to a task's notes text, linking it to `noteID`.
    public static func line(for noteID: String) -> String { scheme + noteID }

    /// The first linked note id found in `notesText`, or nil.
    public static func find(in notesText: String) -> String? {
        for line in notesText.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(scheme) {
                let id = String(trimmed.dropFirst(scheme.count))
                return id.isEmpty ? nil : id
            }
        }
        return nil
    }

    /// Appends a link line to `notesText`, replacing any existing link
    /// (a task links to at most one note at a time) rather than accumulating
    /// duplicates across re-linking.
    public static func appending(_ noteID: String, to notesText: String) -> String {
        let withoutExisting = notesText
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(scheme) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return withoutExisting.isEmpty ? line(for: noteID) : withoutExisting + "\n" + line(for: noteID)
    }
}

// MARK: - Context links (any dropped item, not just a note)
/// A task can be linked to any dropped item — an Apple Note, a local
/// file, a web page, or an email — encoded as one `link://` line per attachment
/// in the task's notes text, alongside (and in the same style as) `NoteLink`'s
/// `notes://` line. Reading the linked item's CONTENT is not this type's job:
/// it only encodes and finds the reference. A file link stores a security-scoped
/// bookmark (as base64, since the carrier is plain text) plus a display path,
/// exactly like `ProjectFolderLink.finder` — resolving it is the app's job.
public struct ContextLink: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case appleNote
        case file
        /// A dropped directory: distinct from `.file`, which reveals in Finder instead of
        /// opening. Without this case, `ListDrop.swift` collapsed every folder drop into
        /// `.file` and the inspector's `open()` had no way to tell them apart.
        case folder
        case web
        /// An email message dragged from Apple Mail. Reference is a `message://` URL.
        case email
    }

    public let kind: Kind
    /// The Apple Note id (`.appleNote`), the web URL string (`.web`), the
    /// base64-encoded security-scoped bookmark (`.file`/`.folder`), or the
    /// `message://` URL (`.email`).
    public let reference: String
    /// Human-readable label — the note's title, the file's display path, or
    /// the web page's URL/title. Never resolved from `reference` by this
    /// type; the caller supplies whatever it already has.
    public let displayName: String

    public init(kind: Kind, reference: String, displayName: String) {
        self.kind = kind
        self.reference = reference
        self.displayName = displayName
    }

    private static let scheme = "link://"

    /// One `link://<kind>|<displayName>|<reference>` line. `|` cannot appear
    /// in `displayName` or `reference` at parse time (see `escape`), so a
    /// name containing one is percent-escaped rather than corrupting the
    /// line's field count.
    public var encodedLine: String {
        Self.scheme + kind.rawValue + "|" + Self.escape(displayName) + "|" + Self.escape(reference)
    }

    /// The first `link://` line's `ContextLink`, or nil when the text has
    /// none or the line is malformed (an old/foreign line is ignored rather
    /// than thrown).
    public static func find(in notesText: String) -> ContextLink? {
        findAll(in: notesText).first
    }

    /// Every `link://` line in order — a task (or subtask) carries any number of attachments.
    public static func findAll(in notesText: String) -> [ContextLink] {
        notesText.components(separatedBy: "\n").compactMap(parse)
    }

    /// One line -> link, or nil for any other / malformed line.
    private static func parse(_ rawLine: String) -> ContextLink? {
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(scheme) else { return nil }
        let parts = trimmed.dropFirst(scheme.count).components(separatedBy: "|")
        guard parts.count == 3, let kind = Kind(rawValue: parts[0]) else { return nil }
        return ContextLink(kind: kind, reference: unescape(parts[2]), displayName: unescape(parts[1]))
    }

    /// `notesText` without `link` (matched on kind + reference); every other line, other
    /// links included, is kept.
    public static func removing(_ link: ContextLink, from notesText: String) -> String {
        notesText.components(separatedBy: "\n")
            .filter { line in
                guard let l = parse(line) else { return true }
                return !(l.kind == link.kind && l.reference == link.reference)
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Appends this link as its own line; already attached (same kind + reference) -> unchanged.
    public func appending(to notesText: String) -> String {
        if Self.findAll(in: notesText).contains(where: { $0.kind == kind && $0.reference == reference }) {
            return notesText
        }
        let trimmed = notesText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? encodedLine : trimmed + "\n" + encodedLine
    }

    /// The four literal lines a broken build (28.09.2026) wrote instead of a `link://` line:
    /// its `encodedLine` had every `\(` turned into `\n(`. Nothing else ever produces them.
    static let corruptLines: Set<String> = [
        "(Self.scheme)", "(kind.rawValue)|", "(Self.escape(displayName))|", "(Self.escape(reference))",
    ]

    /// `notesText` without those lines (and the blank runs they leave); nil when there were none.
    public static func strippingCorruptLines(_ notesText: String) -> String? {
        let lines = notesText.components(separatedBy: "\n")
        guard lines.contains(where: { corruptLines.contains($0.trimmingCharacters(in: .whitespaces)) }) else { return nil }
        var out: [String] = []
        for line in lines where !corruptLines.contains(line.trimmingCharacters(in: .whitespaces)) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty, out.last?.trimmingCharacters(in: .whitespaces).isEmpty ?? true { continue }
            out.append(line)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "|", with: "%7C")
            .replacingOccurrences(of: "\n", with: "%0A")
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "%0A", with: "\n")
            .replacingOccurrences(of: "%7C", with: "|")
            .replacingOccurrences(of: "%25", with: "%")
    }
}

